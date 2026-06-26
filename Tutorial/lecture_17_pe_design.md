# Lecture 17: PE — 脉动阵列的基本单元

> **目标**: 深入理解 Processing Element (PE) 的硬件设计，掌握 MAC 运算、流水线、数据转发等核心机制。

---

## 1. PE 概述

### 1.1 什么是 PE?

PE (Processing Element) 是脉动阵列的基本计算单元，负责执行**乘累加 (MAC)** 运算。

```
┌─────────────────────────────────────────┐
│                  PE                      │
│                                         │
│  row_i ──→ ┌─────┐ ──→ row_o           │
│            │ MAC │                      │
│  col_i ──→ │     │ ──→ col_o           │
│            └──┬──┘                      │
│               │                         │
│               ▼                         │
│            res (累加结果)                │
└─────────────────────────────────────────┘

功能: psum_out = psum_in + W × A_in
     (累加)    (权重)  (激活)
```

### 1.2 PE 在阵列中的位置

```
        col_i[0]  col_i[1]  col_i[2]  col_i[3]
           │         │         │         │
           ▼         ▼         ▼         ▼
row_i[0]→ PE[0][0]→ PE[0][1]→ PE[0][2]→ PE[0][3]
           │         │         │         │
           ▼         ▼         ▼         ▼
row_i[1]→ PE[1][0]→ PE[1][1]→ PE[1][2]→ PE[1][3]
           │         │         │         │
           ▼         ▼         ▼         ▼
row_i[2]→ PE[2][0]→ PE[2][1]→ PE[2][2]→ PE[2][3]
           │         │         │         │
           ▼         ▼         ▼         ▼
row_i[3]→ PE[3][0]→ PE[3][1]→ PE[3][2]→ PE[3][3]

数据流方向:
  row_i (激活) → 水平向右 → row_o
  col_i (权重) → 垂直向下 → col_o
  res   (累加) → 本PE内部累积
```

---

## 设计视角：为什么这样设计？

### 动机：为什么选择 Weight-Stationary 数据流？

脉动阵列有三种经典数据流模式，选择取决于权重复用模式：

```
  三种数据流对比:

  Weight-Stationary (WS):          Output-Stationary (OS):
    权重驻留在 PE 中                  输出驻留在 PE 中
    激活流过阵列                      权重和激活流入
    ┌───┐   ┌───┐   ┌───┐           ┌───┐   ┌───┐   ┌───┐
    │ W0│──►│ W1│──►│ W2│           │acc│──►│acc│──►│acc│
    └───┘   └───┘   └───┘           └───┘   └───┘   └───┘
    A0→A1→A2                        W0,A0 → W1,A0 → W2,A0

  选择 WS 的原因:
    - CNN 权重在整个推理过程中不变
    - 一次加载权重，多次复用 (每个输入像素都用同一组权重)
    - 减少权重数据的片上移动，节省带宽
```

### 为什么选择 2 级流水线？

```
  流水线级数分析:

  1 级流水线 (MAC + 转发同一周期):
    ┌─────────────────────────────────┐
    │  row_i ──→ MAC ──→ row_o       │  组合逻辑路径长
    │  col_i ──→ MAC ──→ col_o       │  时钟频率受限
    │  acc += row_i × col_i           │
    └─────────────────────────────────┘
    问题: 乘法器 + 累加器 + 转发 MUX 在同一周期
          关键路径长，频率低

  2 级流水线 (本设计):
    ┌─────────────────────────────────┐
    │  Stage 1: 数据转发 (DFF)        │
    │    row_o = row_i (寄存)         │
    │    col_o = col_i (寄存)         │
    │                                 │
    │  Stage 2: MAC 累加              │
    │    acc += row_i × col_i         │
    └─────────────────────────────────┘
    优势: 每级关键路径短，频率高
          转发和计算并行进行

  3 级流水线:
    额外的流水线级增加延迟
    脉动阵列需要精确的时序对齐
    收益不大，复杂度增加
```

### 设计约束总结

```
PE 设计约束:

  约束 1: 每周期 1 次 MAC 运算 (吞吐率)
  约束 2: 数据转发延迟 = 1 周期 (脉动对齐)
  约束 3: 支持可变点积长度 (dot_k 运行时配置)
  约束 4: flush 时不丢失数据 (新旧计算边界)
  约束 5: INT8 输入, INT32 累加 (精度要求)
```

---

## 设计视角：如何从零开始设计？

### 步骤 1: 定义 PE 接口

```
  PE 的输入输出:

  输入:
    row_i [7:0]  ─── 激活值 (A 矩阵元素)
    col_i [7:0]  ─── 权重值 (B 矩阵元素)
    din_valid     ─── 输入有效
    flush         ─── 清零累加器，启动新点积
    dot_k [15:0] ─── 点积长度

  输出:
    row_o [7:0]  ─── 激活转发 (给右侧 PE)
    col_o [7:0]  ─── 权重转发 (给下方 PE)
    dout_valid    ─── 转发有效
    res [31:0]   ─── 累加结果
    res_valid     ─── 结果有效脉冲
```

### 步骤 2: 实现数据转发

```
  转发是脉动阵列的基础:
    每个 PE 接收数据后，延迟 1 周期转发给邻居

  always_ff @(posedge clk):
    row_o <= row_i      // 水平转发
    col_o <= col_i      // 垂直转发
    dout_valid <= din_valid  // 有效信号同步

  关键: 转发是无条件的，即使 din_valid=0 也转发
        这保证了数据流的连续性
```

### 步骤 3: 实现 MAC 累加

```
  组合逻辑 (计算):
    op_res = row_i × col_i  // INT8 × INT8 → INT32

  时序逻辑 (累加):
    if (flush && din_valid)
      acc = op_res           // 第一个 beat，直接赋值
      cnt = 1
    else if (din_valid)
      acc = acc + op_res     // 后续 beat，累加
      cnt = cnt + 1

  结果输出:
    if (cnt == dot_k)
      res = acc + op_res     // 最后一个 beat 的结果
      res_valid = 1          // 脉冲信号
      acc = 0                // 清零，准备下一次
      cnt = 0
```

### 步骤 4: 处理 flush 边界

```
  问题: flush 和 din_valid 同时有效时怎么办？

  方案 A (丢弃第一个 beat):
    flush → acc=0, cnt=0
    下一周期: acc = op_res, cnt=1
    问题: 浪费 1 个周期

  方案 B (本设计, 不丢弃):
    flush && din_valid → acc=op_res, cnt=1
    优势: 零浪费，第一个 beat 立即处理

  代码:
    if (flush)
      if (do_compute)
        acc <= op_res        // 直接赋值，不是累加
        cnt <= 1
      else
        acc <= 0
        cnt <= 0
```

### 步骤 5: 添加可配置性

```
  运行时可配置参数:
    dot_k: 点积长度 (Conv1=75, Conv2=800)
    signed_mode: 有符号/无符号乘法
    add_mode: 乘法/加法模式

  设计要点:
    - dot_k 用寄存器存储，运行时可修改
    - signed_mode 控制符号扩展方式
    - add_mode 切换乘法器为加法器
```

---

## 设计视角：架构模式与原则

### 模式 1: 脉动 PE 模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  脉动 PE 是规则阵列计算的基本构建块                        │
  │                                                          │
  │  核心特征:                                                │
  │    - 接收输入，计算，转发给邻居                           │
  │    - 转发延迟固定 (通常 1 周期)                           │
  │    - 数据像波浪一样流过阵列                               │
  │                                                          │
  │  ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐               │
  │  │ PE0 │───►│ PE1 │───►│ PE2 │───►│ PE3 │               │
  │  └──┬──┘    └──┬──┘    └──┬──┘    └──┬──┘               │
  │     │          │          │          │                   │
  │     ▼          ▼          ▼          ▼                   │
  │  结果0      结果1      结果2      结果3                  │
  │                                                          │
  │  适用场景:                                                │
  │    - 矩阵乘法 / 卷积加速                                  │
  │    - FIR 滤波器                                          │
  │    - 排序网络                                            │
  └──────────────────────────────────────────────────────────┘
```

### 模式 2: 数据转发模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  用寄存器级实现固定延迟的数据传递                          │
  │                                                          │
  │  设计要点:                                                │
  │    - 转发是无条件的 (不依赖 valid)                        │
  │    - 转发延迟 = 1 个时钟周期                              │
  │    - valid 信号与数据同步延迟                             │
  │                                                          │
  │  row_i ──→ [DFF] ──→ row_o                               │
  │  col_i ──→ [DFF] ──→ col_o                               │
  │  valid  ──→ [DFF] ──→ dout_valid                         │
  │                                                          │
  │  为什么无条件转发?                                        │
  │    - 简化控制逻辑                                         │
  │    - 保证数据流连续                                       │
  │    - 阵列中所有 PE 行为一致                               │
  │                                                          │
  │  适用场景:                                                │
  │    - 脉动阵列                                             │
  │    - 流水线数据传递                                       │
  │    - 延迟线 (delay line)                                  │
  └──────────────────────────────────────────────────────────┘
```

### 模式 3: flush 安全累加模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  在新旧计算边界不丢失数据的累加器设计                      │
  │                                                          │
  │  状态机:                                                  │
  │    IDLE → flush → 累加中 → 完成 → IDLE                   │
  │                                                          │
  │  flush && valid 同时有效时:                               │
  │    acc <= op_res   (不是 acc <= 0)                       │
  │    cnt <= 1        (不是 cnt <= 0)                       │
  │                                                          │
  │  关键: flush 清零和第一个 beat 处理在同一步完成           │
  │                                                          │
  │  Cycle:  -1    0     1     2     3                       │
  │  flush:   1    0     0     0     0                       │
  │  valid:   0    1     1     1     1                       │
  │  acc:     0    A0×W0  +A1   +A2   +A3                   │
  │  cnt:     0    1     2     3     4                       │
  │                                                          │
  │  适用场景:                                                │
  │    - 任何需要在"新旧计算切换"时不丢数据的累加器           │
  │    - 流水线 flush 恢复                                    │
  └──────────────────────────────────────────────────────────┘
```

---

## 2. pe.sv 逐行解析

### 2.1 模块接口

**源码位置**: `src/npu/pe.sv`

```systemverilog
// 文件: src/npu/pe.sv, line 6-27
module pe #(
    parameter int DOT_K = 75        // 点积长度参数 (可配置)
)(
    input logic clk,                // 时钟
    input logic rst_n,              // 异步复位 (低有效)
    input logic flush,              // 清零累加器, 启动新点积

    input logic signed [7:0] row_i, // 激活输入 (INT8, 有符号)
    input logic signed [7:0] col_i, // 权重输入 (INT8, 有符号)
    input logic din_valid,          // 输入数据有效
    input logic signed_mode,        // 1=有符号乘法, 0=无符号
    input logic [15:0] dot_k,       // 点积长度 (运行时可配置)

    output logic [7:0] row_o,       // 激活输出 (转发到右侧PE)
    output logic [7:0] col_o,       // 权重输出 (转发到下方PE)
    output logic dout_valid,        // 输出有效

    output logic signed [31:0] res, // 累加结果 (INT32)
    output logic res_valid,         // 结果有效 (点积完成时脉冲)
    input logic add_mode,           // 1=加法模式, 0=乘法模式
    input logic add_compute_valid   // 加法模式下的有效信号
);
```

**接口分类**:

| 方向 | 信号 | 位宽 | 功能 |
|------|------|------|------|
| 输入 | row_i | 8b | 激活值 (A矩阵的一列) |
| 输入 | col_i | 8b | 权重值 (B矩阵的一行) |
| 输入 | din_valid | 1b | 数据有效标志 |
| 输入 | flush | 1b | 清零累加器 |
| 输出 | row_o | 8b | 激活值转发 (给右侧PE) |
| 输出 | col_o | 8b | 权重值转发 (给下方PE) |
| 输出 | res | 32b | 累加结果 |
| 输出 | res_valid | 1b | 结果有效脉冲 |

### 2.2 内部信号声明

```systemverilog
// 文件: src/npu/pe.sv, line 29-33
logic signed [31:0] acc;          // 累加器 (32bit 有符号)
logic signed [31:0] op_res;       // 当前操作结果 (乘法或加法)
logic               do_compute;   // 实际计算使能
logic [15:0]        mac_cnt;      // MAC 计数器 (记录已处理的beat数)
```

**关键信号**:
- `acc`: 核心累加器，存储点积的部分和
- `op_res`: 当前周期的乘法/加法结果
- `mac_cnt`: 计数器，追踪已接收的输入beat数

---

## 3. MAC 运算逻辑

### 3.1 组合逻辑: 计算 op_res

```systemverilog
// 文件: src/npu/pe.sv, line 34-52
always @* begin
    do_compute = din_valid;
    op_res = 32'sd0;

    if (add_mode) begin
        // 加法模式: op_res = row_i + col_i
        if (add_compute_valid) begin
            op_res = $signed(row_i) + $signed(col_i);
        end else begin
            do_compute =1'b0;
            op_res = 32'sd0;
        end
    end else begin
        // 乘法模式: op_res = row_i × col_i
        if (signed_mode) begin
            op_res = $signed({{24{row_i[7]}}, row_i}) * $signed({{24{col_i[7]}}, col_i});
        end else begin
            op_res = $signed({24'b0, row_i}) * $signed({24'b0, col_i});
        end
    end
end
```

**两种模式详解**:

#### 乘法模式 (add_mode = 0)
```
signed_mode = 1 (有符号):
  op_res = sign_extend(row_i, 32) * sign_extend(col_i, 32)
  row_i = 0x80 (-128) → sign_extend → 0xFFFFFF80
  col_i = 0x02 (2)    → sign_extend → 0x00000002
  op_res = 0xFFFFFF80 × 0x00000002 = 0xFFFFFF00 (-256)

signed_mode = 0 (无符号):
  op_res = zero_extend(row_i, 32) * zero_extend(col_i, 32)
  row_i = 0x80 (128)  → zero_extend → 0x00000080
  col_i = 0x02 (2)    → zero_extend → 0x00000002
  op_res = 0x00000080 × 0x00000002 = 0x00000100 (256)
```

#### 加法模式 (add_mode = 1)
```
add_compute_valid = 1:
  op_res = sign_extend(row_i) + sign_extend(col_i)

add_compute_valid = 0:
  op_res = 0, do_compute = 0 (不执行累加)
```

### 3.2 时序逻辑: 累加与输出

```systemverilog
// 文件: src/npu/pe.sv, line 54-96
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_o <= 8'd0;
        col_o <= 8'd0;
        dout_valid <= 1'b0;
    end else begin
        // 数据转发: 延迟1周期
        row_o <= row_i;
        col_o <= col_i;
        dout_valid <= din_valid;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        res <= 32'sd0;
        acc <= 32'sd0;
        mac_cnt <= 16'd0;
        res_valid <= 1'b0;
    end else begin
        res_valid <= 1'b0;

        if (flush) begin
            // flush 与 din_valid 同时有效: 不丢失第一个beat
            if (do_compute) begin
                acc <= op_res;
                mac_cnt <= 16'd1;
            end else begin
                acc <= 32'sd0;
                mac_cnt <= 16'd0;
            end
        end else if (do_compute) begin
            if (mac_cnt == (dot_k - 16'd1)) begin
                // 最后一个beat: 输出最终结果
                res <= acc + op_res;
                res_valid <= 1'b1;
                acc <= 32'sd0;
                mac_cnt <= 16'd0;
            end else begin
                // 中间beat: 累加
                acc <= acc + op_res;
                mac_cnt <= mac_cnt + 1'b1;
            end
        end
    end
end
```

---

## 4. 2级流水线设计

PE 内部有两条并行的流水线:

### 4.1 流水线结构图

```
              ┌─────────────────────────────────────────────────────┐
              │                    PE 内部                          │
              │                                                     │
  row_i ──────┤──→ [DFF] ──→ row_o                                 │
              │      ↑                                              │
              │   1周期延迟                                          │
              │                                                     │
  col_i ──────┤──→ [DFF] ──→ col_o                                 │
              │      ↑                                              │
              │   1周期延迟                                          │
              │                                                     │
  din_valid ──┤──→ [DFF] ──→ dout_valid                            │
              │      ↑                                              │
              │   1周期延迟                                          │
              │                                                     │
  row_i × col_i ──→ [acc += op_res] ──→ res (当 mac_cnt == dot_k-1)│
              │      ↑                                              │
              │   累加器                                            │
              └─────────────────────────────────────────────────────┘

时序图:
  Cycle:  0    1    2    3    ...   K-1   K
          │    │    │    │         │     │
  row_i:  A0   A1   A2   A3  ...  A(K-1) A(K)
  col_i:  W0   W1   W2   W3  ...  W(K-1) W(K)
  acc:    0    A0×W0 A0×W0    ...  Σ
                         +A1×W1
  res:                                ← res_valid=1
  row_o:       A0   A1   A2  ...  A(K-2) A(K-1)
  col_o:       W0   W1   W2  ...  W(K-2) W(K-1)
```

### 4.2 关键时序特性

1. **数据转发延迟**: row_o/col_o 比 row_i/col_i 延迟 1 个时钟周期
2. **累加器复用**: 每个时钟周期执行一次 MAC，结果累加到 acc
3. **结果输出**: 在第 K 个输入 beat 时输出最终结果，同时清零累加器
4. **flush 兼容**: flush 和 din_valid 可同时有效，不丢失数据

---

## 5. 数据转发机制 (row_o, col_o)

### 5.1 为什么需要数据转发?

脉动阵列中，每个 PE 的输出是相邻 PE 的输入。数据像"波浪"一样流过阵列。

```
时间步 0:     时间步 1:     时间步 2:
A0→PE0       A1→PE0       A2→PE0
              A0→PE1       A1→PE1
                            A0→PE2

PE0: acc+=A0×W0  acc+=A1×W0  acc+=A2×W0
PE1:             acc+=A0×W1  acc+=A1×W1
PE2:                         acc+=A0×W2
```

### 5.2 转发实现

```systemverilog
// 文件: src/npu/pe.sv, line 54-64
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        row_o <= 8'd0;
        col_o <= 8'd0;
        dout_valid <= 1'b0;
    end else begin
        row_o <= row_i;       // 水平转发: 延迟1周期
        col_o <= col_i;       // 垂直转发: 延迟1周期
        dout_valid <= din_valid;  // 有效信号同步延迟
    end
end
```

**关键点**:
- 转发是无条件的 (即使 din_valid=0 也会转发)
- 转发延迟 = 1 时钟周期
- dout_valid 与 row_o/col_o 同步

### 5.3 在 4×4 阵列中的转发路径

```
      col_in[0]    col_in[1]    col_in[2]    col_in[3]
         │            │            │            │
         ▼            ▼            ▼            ▼
row_in[0]→ PE[0][0] ──→ PE[0][1] ──→ PE[0][2] ──→ PE[0][3]
            │   ↓         │   ↓         │   ↓         │   ↓
            │  col_o      │  col_o      │  col_o      │  col_o
            ▼            ▼            ▼            ▼
row_in[1]→ PE[1][0] ──→ PE[1][1] ──→ PE[1][2] ──→ PE[1][3]
            │   ↓         │   ↓         │   ↓         │   ↓
            ▼            ▼            ▼            ▼
row_in[2]→ PE[2][0] ──→ PE[2][1] ──→ PE[2][2] ──→ PE[2][3]
            │   ↓         │   ↓         │   ↓         │   ↓
            ▼            ▼            ▼            ▼
row_in[3]→ PE[3][0] ──→ PE[3][1] ──→ PE[3][2] ──→ PE[3][3]

数据流:
  row_o[i][j] → row_i[i][j+1]  (水平向右)
  col_o[i][j] → col_i[i+1][j]  (垂直向下)
```

---

## 6. Weight-Stationary 数据流

### 6.1 什么是 Weight-Stationary?

在脉动阵列中，有三种主要的数据流模式:

| 模式 | 权重位置 | 激活流 | 适用场景 |
|------|----------|--------|----------|
| Weight-Stationary (WS) | 驻留在PE中 | 流过阵列 | 权重复用高 |
| Output-Stationary (OS) | 流入PE | 输出驻留 | 输出复用高 |
| Input-Stationary (IS) | 流入PE | 驻留在PE中 | 输入复用高 |

### 6.2 我们的设计: Weight-Stationary

```
初始化阶段:
  ┌──────────────────────────────────────┐
  │  权重通过 col_i 加载到每个 PE         │
  │  PE 内部的 acc 用于存储权重            │
  │  (第一次计算时，权重作为第一个beat)     │
  └──────────────────────────────────────┘

计算阶段:
  ┌──────────────────────────────────────┐
  │  权重固定在 PE 中 (不再变化)           │
  │  激活值通过 row_i 流过阵列             │
  │  每个时钟周期执行一次 MAC              │
  └──────────────────────────────────────┘

结果输出:
  ┌──────────────────────────────────────┐
  │  经过 K 个周期后，PE 输出累加结果       │
  │  res_valid 脉冲信号标记结果有效         │
  └──────────────────────────────────────┘
```

### 6.3 权重加载时序

```
时序: flush → 权重流入 → 计算开始

Cycle:  -1     0      1      2     ...    K-1    K
        │      │      │      │            │      │
flush:  1      0      0      0     ...    0      0
row_i:  X      A0     A1     A2    ...   A(K-1) A(K)
col_i:  X      W0     W1     W2    ...   W(K-1) W(K)

注意: flush=1 时，如果 din_valid=1，第一个beat会被处理
      (代码第77行: if (do_compute) acc <= op_res)
```

### 6.4 权重更新策略

在我们的 NPU 中，权重在仿真开始时加载到 `weight_buf`，整个推理过程不变:

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, line 98
$readmemh(CONV1_FILE, weight_buf);   // Conv1 权重
$readmemh(CONV2_FILE, weight2_buf);  // Conv2 权重

// 权重在 feed 阶段每周期读取一行
w_lane[j] = $signed(weight_buf[feed_count][...]);
```

**优势**: 权重不需要每次计算都加载，减少数据移动开销。

---

## 7. signed_mode 和 add_mode

### 7.1 signed_mode: 有符号/无符号乘法

```systemverilog
// 文件: src/npu/pe.sv, line 46-51
if (signed_mode) begin
    op_res = $signed({{24{row_i[7]}}, row_i}) * $signed({{24{col_i[7]}}, col_i});
end else begin
    op_res = $signed({24'b0, row_i}) * $signed({24'b0, col_i});
end
```

**符号扩展示意**:
```
row_i = 0x80 (-128 有符号, 128 无符号)

signed_mode = 1:
  sign_extend(0x80) = 0xFFFFFF80 (-128)

signed_mode = 0:
  zero_extend(0x80) = 0x00000080 (128)
```

**使用场景**:
- CNN 权重和激活通常是有符号的 (signed_mode=1)
- 某些特殊计算可能需要无符号模式

### 7.2 add_mode: 加法/乘法模式

```systemverilog
// 文件: src/npu/pe.sv, line 38-51
if (add_mode) begin
    // 加法模式: 用于偏置加或其他逐元素操作
    if (add_compute_valid) begin
        op_res = $signed(row_i) + $signed(col_i);
    end else begin
        do_compute = 1'b0;
        op_res = 32'sd0;
    end
end else begin
    // 乘法模式: 正常 MAC 运算
    // ... (乘法逻辑)
end
```

**加法模式用途**:
1. **偏置加**: 将偏置值加到累加结果上
2. **逐元素加**: 特征图相加 (残差连接)
3. **测试调试**: 验证数据通路

### 7.3 add_compute_valid 的作用

```
add_mode = 1, add_compute_valid = 1:
  PE 执行: acc += (row_i + col_i)
  用途: 累加多个加法结果

add_mode = 1, add_compute_valid = 0:
  PE 执行: 不累加 (do_compute = 0)
  用途: 暂停加法计算，保持 acc 不变
```

---

## 8. flush 机制详解

### 8.1 flush 的作用

```
flush = 1 时:
  1. 清零累加器 acc
  2. 重置计数器 mac_cnt = 0
  3. 如果 din_valid=1，处理第一个beat (不丢失数据)

触发时机:
  - 每次新的点积计算前
  - 每个 tile 计算开始时
```

### 8.2 flush 与 din_valid 同时有效

```systemverilog
// 文件: src/npu/pe.sv, line 74-83
if (flush) begin
    // 关键设计: flush 和 valid 同时有效时，不丢失第一个beat
    if (do_compute) begin
        acc <= op_res;        // 第一个beat的结果直接赋值给acc
        mac_cnt <= 16'd1;     // 计数器从1开始 (而不是0)
    end else begin
        acc <= 32'sd0;
        mac_cnt <= 16'd0;
    end
end
```

**时序图**:
```
Case 1: flush 单独有效 (无数据输入)
  Cycle:  0    1    2    3
  flush:  1    0    0    0
  valid:  0    0    0    0
  acc:    0    0    0    0
  cnt:    0    0    0    0

Case 2: flush 与 valid 同时有效
  Cycle:  0    1    2    3
  flush:  1    0    0    0
  valid:  1    1    1    1
  op_res: A0×W0 A1×W1 A2×W2 A3×W3
  acc:    A0×W0 A0×W0+A1×W1 ...
  cnt:    1    2    3    4

  注意: 第一个beat (A0×W0) 被正确处理，没有丢失!
```

### 8.3 点积完成条件

```systemverilog
// 文件: src/npu/pe.sv, line 85
if (mac_cnt == (dot_k - 16'd1)) begin
    res <= acc + op_res;      // 输出最终结果
    res_valid <= 1'b1;        // 结果有效脉冲
    acc <= 32'sd0;            // 清零累加器
    mac_cnt <= 16'd0;         // 重置计数器
end
```

**计算过程**:
```
dot_k = 75 (Conv1 的点积长度)

Cycle 0: flush + valid → acc = A0×W0, cnt = 1
Cycle 1: acc += A1×W1, cnt = 2
Cycle 2: acc += A2×W2, cnt = 3
...
Cycle 74: acc += A74×W74, cnt = 75

  检查: cnt == dot_k - 1 = 74? YES!
  输出: res = acc + A74×W74
  清零: acc = 0, cnt = 0
```

---

## 9. 完整计算流程示例

### 9.1 4×1 点积计算

假设 dot_k=4，计算 C[0] = A[0]×W[0] + A[1]×W[1] + A[2]×W[2] + A[3]×W[3]

```
Cycle 0: flush=1, valid=1
  row_i = A[0], col_i = W[0]
  op_res = A[0] × W[0]
  acc = op_res = A[0]×W[0]
  mac_cnt = 1

Cycle 1: flush=0, valid=1
  row_i = A[1], col_i = W[1]
  op_res = A[1] × W[1]
  acc = A[0]×W[0] + A[1]×W[1]
  mac_cnt = 2

Cycle 2: flush=0, valid=1
  row_i = A[2], col_i = W[2]
  op_res = A[2] × W[2]
  acc = A[0]×W[0] + A[1]×W[1] + A[2]×W[2]
  mac_cnt = 3

Cycle 3: flush=0, valid=1
  row_i = A[3], col_i = W[3]
  op_res = A[3] × W[3]
  mac_cnt == dot_k-1 == 3? YES!
  res = acc + op_res = A[0]×W[0] + A[1]×W[1] + A[2]×W[2] + A[3]×W[3]
  res_valid = 1
  acc = 0, mac_cnt = 0
```

### 9.2 数据转发时序

```
          PE[0][0]              PE[0][1]              PE[0][2]
          row_i: A0             row_i: row_o[0][0]    row_i: row_o[0][1]
Cycle 0:  row_o: X             row_o: X              row_o: X
Cycle 1:  row_o: A0            row_o: X              row_o: X
Cycle 2:  row_o: A1            row_o: A0             row_o: X
Cycle 3:  row_o: A2            row_o: A1             row_o: A0

PE[0][0] 在 Cycle 0 看到 A0
PE[0][1] 在 Cycle 1 看到 A0 (延迟1周期)
PE[0][2] 在 Cycle 2 看到 A0 (延迟2周期)
```

---

## 10. 关键知识点总结

### 10.1 PE 核心功能

| 功能 | 说明 | 实现 |
|------|------|------|
| MAC | 乘累加 | acc += row_i × col_i |
| 转发 | 数据传递 | row_o = row_i (延迟1周期) |
| 清零 | 启动新计算 | flush → acc=0, cnt=0 |
| 输出 | 结果有效 | res_valid 脉冲 |

### 10.2 设计特点

1. **2级流水线**: 数据转发(1级) + MAC累加(1级)
2. **flush 安全**: flush 与 valid 同时有效时不丢失数据
3. **双模式**: 支持乘法模式和加法模式
4. **符号可配**: signed_mode 控制有符号/无符号乘法
5. **运行时可配**: dot_k 参数可在运行时设置

### 10.3 性能指标

```
单个 PE:
  - 每周期执行 1 次 MAC
  - 点积长度: K 个周期
  - 吞吐率: 1 MAC/周期

4×4 子阵列:
  - 16 个 PE 并行
  - 吞吐率: 16 MAC/周期

40×32 阵列:
  - 1280 个 PE 并行
  - 吞吐率: 1280 MAC/周期
```

---

## 11. 动手练习

### 练习 1: 手算 MAC 过程

给定 dot_k=3，权重 W=[2, -1, 3]，激活 A=[1, 4, -2]:

1. 写出每个周期的 acc 值
2. 计算最终结果 res
3. 验证: res = 2×1 + (-1)×4 + 3×(-2) = ?

### 练习 2: 符号扩展计算

给定 row_i = 0x80, col_i = 0x02:

1. signed_mode=1 时，op_res = ?
2. signed_mode=0 时，op_res = ?
3. 解释两者差异

### 练习 3: flush 时序分析

给定以下信号序列:
```
Cycle:  0  1  2  3  4  5  6
flush:  1  0  0  0  1  0  0
valid:  1  1  1  1  1  1  1
dot_k:  4  4  4  4  4  4  4
```

1. 绘制 acc 和 mac_cnt 的变化
2. 标记 res_valid 何时为1
3. 说明两个点积的边界

### 练习 4: 阅读源码

阅读 `src/npu/pe.sv`，回答:

1. 为什么 `row_o` 和 `col_o` 使用单独的 always_ff 块 (line 54-64)?
2. `do_compute` 信号在什么情况下会为 0?
3. 如果 `flush` 和 `din_valid` 同时为 0，PE 的状态如何变化?

### 练习 5: 性能计算

计算 Conv1 层的计算时间:
- 输入: 1024 × 75 (im2col 矩阵)
- 权重: 75 × 32
- 阵列: 40 × 32 PE
- Tile 数: ceil(1024/40) = 26
- 每 tile 计算: dot_k=75 周期 + drain=8 周期

总周期数 = ?

---

## 12. 下节预告

**Lecture 18: 4×4 脉动子阵列 — 数据流与对齐**
- `mm_systolic_4x4.sv` 详细解析
- 4×4 PE 网格连接
- Time-Skew 对齐
- 偏置加和 ReLU
- 计算时序示例

---

## 参考资料

- 源码: `src/npu/pe.sv` (PE 完整实现)
- 源码: `src/npu/mm_systolic_4x4.sv` (4×4 子阵列)
- 文档: `docs/NPU_DESIGN_REPORT.md` 第 4.1 节
