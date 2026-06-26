# Lecture 18: 4×4 脉动子阵列 — 数据流与对齐

> **目标**: 深入理解 4×4 脉动子阵列的硬件设计，掌握 Time-Skew 对齐、偏置加、ReLU 等后处理机制。

---

## 1. 4×4 子阵列概述

### 1.1 模块功能

`mm_systolic_4x4` 是 NPU 的基本计算模块，包含:
- 16 个 PE (4×4 网格)
- 输入延迟线 (Time-Skew 对齐)
- 偏置加法器
- ReLU 激活函数
- INT8 量化截断

### 1.2 在整体架构中的位置

```
mac_array_40x32_stream (顶层)
├── Row Group 0 (rg=0): 处理行 0-3
│   ├── mm_systolic_4x4 [0][0]: 列 0-3
│   ├── mm_systolic_4x4 [0][1]: 列 4-7
│   ├── ...
│   └── mm_systolic_4x4 [0][7]: 列 28-31
├── Row Group 1 (rg=1): 处理行 4-7
│   └── ...
├── ...
└── Row Group 9 (rg=9): 处理行 36-39
    └── ...

总计: 10 × 8 = 80 个 mm_systolic_4x4 实例
     = 80 × 16 = 1280 个 PE
```

### 1.3 接口信号

**源码位置**: `src/npu/mm_systolic_4x4.sv`

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 6-27
module mm_systolic_4x4 #(
    parameter int DOT_K = 5          // 点积长度 (可配置)
)(
    input  logic clk,                // 时钟
    input  logic rst_n,              // 异步复位

    input  logic signed_mode,        // 有符号模式
    input  logic [31:0] row_bar,     // 4个激活值 × 8bit = 32bit
    input  logic [31:0] col_bar,     // 4个权重值 × 8bit = 32bit
    input  logic bar_valid,          // 输入数据有效
    input  logic [15:0] dot_k,       // 点积长度
    input  logic [4:0] out_shift,    // 量化移位量
    input  logic [4*8-1:0] bias_vec, // 4个偏置值 × 8bit
    input  logic relu_en,            // ReLU 使能

    output logic [(4*4*8)-1:0] res,  // 16个结果 × 8bit = 128bit
    output logic [15:0] res_valid,   // 16个结果有效标志

    input  logic flush,              // 清零累加器
    input  logic add_mode,           // 加法模式
    input  logic add_compute_valid   // 加法计算有效
);
```

**接口分类**:

| 方向 | 信号 | 位宽 | 功能 |
|------|------|------|------|
| 输入 | row_bar | 32b | 4个激活值 (4×8bit) |
| 输入 | col_bar | 32b | 4个权重值 (4×8bit) |
| 输入 | bar_valid | 1b | 数据有效 |
| 输入 | out_shift | 5b | 量化移位量 (5/6/7/8) |
| 输入 | bias_vec | 32b | 4个偏置值 (4×8bit) |
| 输入 | relu_en | 1b | ReLU 使能 |
| 输出 | res | 128b | 16个结果 (16×8bit) |
| 输出 | res_valid | 16b | 16个结果有效标志 |

---

## 设计视角：为什么这样设计？

### 动机：为什么需要 Time-Skew 对齐？

脉动阵列的核心特性是数据像波浪一样流过 PE 阵列。为了让所有 PE
正确计算同一组数据的点积，输入数据必须错开到达。

```
  问题: 4×4 阵列的数据对齐

  如果所有输入同时到达:
    Cycle 0: PE[0][0] 看到 A0, PE[0][1] 也看到 A0
    问题: PE[0][1] 应该在 Cycle 1 才看到 A0!

  原因: 激活值水平传播，每个 PE 延迟 1 周期
    PE[0][0] 在 Cycle 0 看到 A0
    PE[0][1] 在 Cycle 1 看到 A0 (经过 PE[0][0] 转发)
    PE[0][2] 在 Cycle 2 看到 A0 (经过 2 个 PE 转发)

  解决: 输入延迟线 (Time-Skew)
    row_in[0] 无延迟    → PE[0][*]
    row_in[1] 延迟 1 周期 → PE[1][*]
    row_in[2] 延迟 2 周期 → PE[2][*]
    row_in[3] 延迟 3 周期 → PE[3][*]
```

### 为什么在子阵列内做偏置加和 ReLU？

```
  后处理位置选择:

  方案 A: 在顶层做后处理
    80 个子阵列的 1280 个结果 → 汇总 → 量化 → 偏置加 → ReLU
    问题: 需要 1280 条结果总线汇聚，布线拥塞

  方案 B (本设计): 在子阵列内做后处理
    每个子阵列: 16 个 PE 结果 → 量化 → 偏置加 → ReLU → 128bit 输出
    优势:
      - 后处理与计算紧耦合，延迟低
      - 输出已经是 INT8，减少总线宽度
      - 80 个子阵列并行处理，吞吐量高

  面积开销:
    每个子阵列: 16 个量化单元 + 16 个加法器 + 16 个 ReLU
    总计: 1280 个简单组合逻辑单元 (远小于 PE 中的乘法器)
```

### 设计约束总结

```
4×4 子阵列设计约束:

  约束 1: Time-Skew 延迟 = 3 周期 (4×4 阵列最大)
  约束 2: 后处理必须是组合逻辑 (零延迟)
  约束 3: add_mode 必须旁路延迟线 (逐元素操作)
  约束 4: bias 按列共享 (同一列 4 个 PE 用相同偏置)
  约束 5: 输出格式 = 16×8bit INT8 (量化后)
```

---

## 设计视角：如何从零开始设计？

### 步骤 1: 设计 PE 网格连接

```
  4×4 PE 网格的信号连接:

  row_wire[i][j] → row_wire[i][j+1]  (水平, 经 PE 延迟)
  col_wire[i][j] → col_wire[i+1][j]  (垂直, 经 PE 延迟)

  边界赋值:
    row_wire[0][0] = row_in[0]  (无延迟)
    row_wire[1][0] = row_d1[1]  (延迟 1 周期)
    row_wire[2][0] = row_d2[2]  (延迟 2 周期)
    row_wire[3][0] = row_d3[3]  (延迟 3 周期)

  PE 实例化 (generate 循环):
    for i in 0..3:
      for j in 0..3:
        pe(row_i=row_wire[i][j],
           col_i=col_wire[i][j],
           row_o=row_wire[i][j+1],
           col_o=col_wire[i+1][j])
```

### 步骤 2: 实现输入延迟线

```
  延迟线结构 (以行为例):

  row_in[0] ──────────────────────────────→ row_wire[0][0]
  row_in[1] ──→ [DFF] ──→ row_d1[1] ──────→ row_wire[1][0]
  row_in[2] ──→ [DFF] ──→ [DFF] ──→ row_d2[2] → row_wire[2][0]
  row_in[3] ──→ [DFF] ──→ [DFF] ──→ [DFF] ──→ row_d3[3] → row_wire[3][0]

  列方向同理 (col_in[0..3])

  Valid 信号也需要延迟:
    bar_valid ──→ [DFF] ──→ [DFF] ──→ [DFF]
    对应:        Row 0   Row 1   Row 2   Row 3
```

### 步骤 3: 设计 add_mode 旁路

```
  加法模式需要所有输入同时到达:

  row_wire[0][0] = row_in[0]
  row_wire[1][0] = (add_mode) ? row_in[1] : row_d1[1]
  row_wire[2][0] = (add_mode) ? row_in[2] : row_d2[2]
  row_wire[3][0] = (add_mode) ? row_in[3] : row_d3[3]

  用 MUX 选择:
    add_mode=0: 使用延迟线 (脉动模式)
    add_mode=1: 旁路延迟线 (加法模式)
```

### 步骤 4: 实现后处理流水线

```
  后处理是纯组合逻辑:

  对于每个 PE[m][n]:
    步骤 1: 量化截断
      pe_res_i8 = {pe_res[31], pe_res[out_shift +: 7]}
      // 取符号位 + 7bit 有效数据

    步骤 2: 偏置加
      biased = sign_extend(pe_res_i8) + sign_extend(bias_vec[n])
      // INT8 + INT8 → INT32

    步骤 3: ReLU + 饱和
      if (relu_en && biased <= 0)
        output = 0
      else
        output = sat_i8(biased)  // clamp to [-128, 127]
```

### 步骤 5: 打包输出

```
  16 个 PE 的结果打包为 128bit:

  res[127:0] = {pe[0][0], pe[0][1], ..., pe[3][3]}
               每个 PE 占 8bit

  res_valid[15:0] = {valid[0][0], valid[0][1], ..., valid[3][3]}
                    每个 PE 的结果有效标志

  输出接口:
    res [127:0]     → 16 个 INT8 结果
    res_valid [15:0] → 16 个有效标志
```

---

## 设计视角：架构模式与原则

### 模式 1: Time-Skew 对齐模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  用延迟线让不同 PE 在不同时刻看到属于同一次计算的数据      │
  │                                                          │
  │  输入: N 路数据                                          │
  │  延迟: 第 i 路延迟 i 个周期                              │
  │  效果: 所有 PE 在同一时刻处理同一组数据                   │
  │                                                          │
  │  row[0] ──────────────────────→ PE[0]                    │
  │  row[1] ──→ [DFF] ────────────→ PE[1]                    │
  │  row[2] ──→ [DFF]→[DFF] ──────→ PE[2]                    │
  │  row[3] ──→ [DFF]→[DFF]→[DFF] → PE[3]                    │
  │                                                          │
  │  适用场景:                                                │
  │    - 脉动阵列输入对齐                                     │
  │    - FFT 蝶形单元                                         │
  │    - 任何需要"波浪式"数据传播的规则阵列                   │
  │                                                          │
  │  注意: 阵列越大，最大延迟越大                             │
  │        N×N 阵列需要 N-1 周期延迟                         │
  └──────────────────────────────────────────────────────────┘
```

### 模式 2: 后处理流水线模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  在计算单元输出端紧耦合后处理逻辑                          │
  │                                                          │
  │  计算结果 (INT32)                                        │
  │      │                                                   │
  │      ▼                                                   │
  │  量化截断 (右移 + 取高 8 位)                              │
  │      │                                                   │
  │      ▼                                                   │
  │  偏置加 (INT8 + INT8 → INT32)                            │
  │      │                                                   │
  │      ▼                                                   │
  │  ReLU (条件置零)                                         │
  │      │                                                   │
  │      ▼                                                   │
  │  饱和 (clamp to INT8)                                    │
  │      │                                                   │
  │      ▼                                                   │
  │  输出 (INT8)                                             │
  │                                                          │
  │  关键: 全部是组合逻辑，零额外时钟周期                     │
  │                                                          │
  │  优势:                                                    │
  │    - 结果立即可用，无需等待额外周期                       │
  │    - 输出宽度从 32bit 压缩到 8bit，减少总线拥塞           │
  │    - 每个子阵列独立处理，并行度高                         │
  └──────────────────────────────────────────────────────────┘
```

### 模式 3: MUX 旁路模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  用 MUX 在两种数据通路间切换                              │
  │                                                          │
  │  本设计: add_mode 控制延迟线旁路                          │
  │                                                          │
  │  row_in ──→ [延迟线] ──→ MUX ──→ PE                     │
  │                    ↑        │                            │
  │  row_in ───────────┘────────┘                            │
  │                (旁路)                                    │
  │                                                          │
  │  add_mode=0: 选择延迟线输出 (脉动模式)                   │
  │  add_mode=1: 选择旁路输入 (加法模式)                     │
  │                                                          │
  │  适用场景:                                                │
  │    - 多模式计算单元 (乘法/加法切换)                      │
  │    - 流水线旁路 (调试或低延迟模式)                       │
  │    - 功能复用 (同一硬件支持多种操作)                     │
  │                                                          │
  │  注意: MUX 增加了组合逻辑延迟                            │
  │        需要确保在时钟周期内满足建立时间                   │
  └──────────────────────────────────────────────────────────┘
```

---

## 2. 输入数据分解

### 2.1 4 元素分解

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 36-41
wire [7:0] row_in [0:3];  // 4个激活值
wire [7:0] col_in [0:3];  // 4个权重值

// 按照原代码逻辑进行切分
assign {row_in[0], row_in[1], row_in[2], row_in[3]} = row_bar;
assign {col_in[0], col_in[1], col_in[2], col_in[3]} = col_bar;
```

**数据分解示意**:
```
row_bar (32bit):
┌────────────────────────────────────────────────┐
│ row_in[0] │ row_in[1] │ row_in[2] │ row_in[3] │
│  [31:24]  │  [23:16]  │  [15:8]   │   [7:0]   │
└────────────────────────────────────────────────┘

col_bar (32bit):
┌────────────────────────────────────────────────┐
│ col_in[0] │ col_in[1] │ col_in[2] │ col_in[3] │
│  [31:24]  │  [23:16]  │  [15:8]   │   [7:0]   │
└────────────────────────────────────────────────┘
```

---

## 3. Time-Skew 对齐

### 3.1 为什么需要 Time-Skew?

在脉动阵列中，不同 PE 在不同时刻看到属于同一次计算的数据。

```
问题: 如何让 4×4 阵列中的 16 个 PE 同时处理同一组数据?

解决方案: 输入延迟线 (Time-Skew)
  - 行方向: row_in[i] 延迟 i 个周期
  - 列方向: col_in[j] 延迟 j 个周期
```

### 3.2 延迟线实现

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 44-68
// 4x4 阵列需要最多 3 拍延迟
reg [7:0] row_d1 [1:3], col_d1 [1:3]; // 第一级延迟
reg [7:0] row_d2 [2:3], col_d2 [2:3]; // 第二级延迟
reg [7:0] row_d3 [3:3], col_d3 [3:3]; // 第三级延迟

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 初始化延迟寄存器
        integer k;
        for(k=1; k<=3; k=k+1) begin row_d1[k] <= 8'h0; col_d1[k] <= 8'h0; end
        for(k=2; k<=3; k=k+1) begin row_d2[k] <= 8'h0; col_d2[k] <= 8'h0; end
        for(k=3; k<=3; k=k+1) begin row_d3[k] <= 8'h0; col_d3[k] <= 8'h0; end
    end else begin
        // 第一级
        row_d1[1] <= row_in[1]; col_d1[1] <= col_in[1];
        row_d1[2] <= row_in[2]; col_d1[2] <= col_in[2];
        row_d1[3] <= row_in[3]; col_d1[3] <= col_in[3];
        // 第二级
        row_d2[2] <= row_d1[2]; col_d2[2] <= col_d1[2];
        row_d2[3] <= row_d1[3]; col_d2[3] <= col_d1[3];
        // 第三级
        row_d3[3] <= row_d2[3]; col_d3[3] <= col_d2[3];
    end
end
```

**延迟线结构图**:
```
row_in[0] ──────────────────────────────────────→ row_wire[0][0]
row_in[1] ──→ [DFF] ──→ row_d1[1] ──────────────→ row_wire[1][0]
row_in[2] ──→ [DFF] ──→ row_d1[2] ──→ [DFF] ──→ row_d2[2] ──→ row_wire[2][0]
row_in[3] ──→ [DFF] ──→ row_d1[3] ──→ [DFF] ──→ row_d2[3] ──→ [DFF] ──→ row_d3[3] ──→ row_wire[3][0]

col_in[0] ──────────────────────────────────────→ col_wire[0][0]
col_in[1] ──→ [DFF] ──→ col_d1[1] ──────────────→ col_wire[0][1]
col_in[2] ──→ [DFF] ──→ col_d1[2] ──→ [DFF] ──→ col_d2[2] ──→ col_wire[0][2]
col_in[3] ──→ [DFF] ──→ col_d1[3] ──→ [DFF] ──→ col_d2[3] ──→ [DFF] ──→ col_d3[3] ──→ col_wire[0][3]
```

### 3.3 Valid 信号延迟

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 70-78
reg [2:0] bar_valid_delay;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bar_valid_delay <= 3'b0;
    end else begin
        bar_valid_delay <= {bar_valid_delay[1:0], bar_valid};
    end
end
```

**Valid 延迟链**:
```
bar_valid ──→ bar_valid_delay[0] ──→ bar_valid_delay[1] ──→ bar_valid_delay[2]
    │              │                       │                       │
    ▼              ▼                       ▼                       ▼
Row 0          Row 1                   Row 2                   Row 3
(无延迟)      (延迟1周期)            (延迟2周期)            (延迟3周期)
```

---

## 4. PE 网格连接

### 4.1 连接逻辑

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 80-101
// 定义 PE 间的互连线，多定义一维用于边界
wire [7:0] row_wire [0:4][0:4];
wire [7:0] col_wire [0:4][0:4];
wire vld_wire [0:4][0:4];

// 输入边界赋值 (根据 add_mode 决定是否跳过延迟线)
assign row_wire[0][0] = row_in[0];
assign row_wire[1][0] = (add_mode) ? row_in[1] : row_d1[1];
assign row_wire[2][0] = (add_mode) ? row_in[2] : row_d2[2];
assign row_wire[3][0] = (add_mode) ? row_in[3] : row_d3[3];

assign col_wire[0][0] = col_in[0];
assign col_wire[0][1] = (add_mode) ? col_in[1] : col_d1[1];
assign col_wire[0][2] = (add_mode) ? col_in[2] : col_d2[2];
assign col_wire[0][3] = (add_mode) ? col_in[3] : col_d3[3];

assign vld_wire[0][0] = bar_valid;
assign vld_wire[1][0] = (add_mode) ? bar_valid : bar_valid_delay[0];
assign vld_wire[2][0] = (add_mode) ? bar_valid : bar_valid_delay[1];
assign vld_wire[3][0] = (add_mode) ? bar_valid : bar_valid_delay[2];
```

### 4.2 PE 实例化

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 102-128
generate
    genvar i, j;
    for (i = 0; i < 4; i = i + 1) begin : row_gen
        for (j = 0; j < 4; j = j + 1) begin : col_gen
            pe #(
                .DOT_K(DOT_K)
            ) pe_inst(
                .clk(clk),
                .rst_n(rst_n),
                .flush(flush),
                .row_i(row_wire[i][j]),        // 激活输入
                .col_i(col_wire[i][j]),        // 权重输入
                .din_valid(vld_wire[i][j]),    // 有效信号
                .signed_mode(signed_mode),
                .dot_k(dot_k),
                .row_o(row_wire[i][j+1]),      // 激活输出 (右侧)
                .col_o(col_wire[i+1][j]),      // 权重输出 (下方)
                .dout_valid(vld_wire[i][j+1]), // 有效输出
                .res(pe_res[i][j]),            // 累加结果
                .res_valid(pe_res_valid[i][j]),// 结果有效
                .add_mode(add_mode),
                .add_compute_valid(add_compute_valid)
            );
        end
    end
endgenerate
```

### 4.3 4×4 网格连接图

```
      col_wire[0][0]  col_wire[0][1]  col_wire[0][2]  col_wire[0][3]
           │              │              │              │
           ▼              ▼              ▼              ▼
row_wire[0][0]→ PE[0][0] ──→ PE[0][1] ──→ PE[0][2] ──→ PE[0][3]
           │   ↓              ↓              ↓              ↓
           │   col_wire[1][0] col_wire[1][1] col_wire[1][2] col_wire[1][3]
           ▼              ▼              ▼              ▼
row_wire[1][0]→ PE[1][0] ──→ PE[1][1] ──→ PE[1][2] ──→ PE[1][3]
           │   ↓              ↓              ↓              ↓
           ▼              ▼              ▼              ▼
row_wire[2][0]→ PE[2][0] ──→ PE[2][1] ──→ PE[2][2] ──→ PE[2][3]
           │   ↓              ↓              ↓              ↓
           ▼              ▼              ▼              ▼
row_wire[3][0]→ PE[3][0] ──→ PE[3][1] ──→ PE[3][2] ──→ PE[3][3]

数据流方向:
  row_wire[i][j] → row_wire[i][j+1]  (水平向右, 经过PE内部1周期延迟)
  col_wire[i][j] → col_wire[i+1][j]  (垂直向下, 经过PE内部1周期延迟)
```

---

## 5. add_mode: 延迟线旁路

### 5.1 加法模式 vs 乘法模式

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 87-100
assign row_wire[0][0] = row_in[0];
assign row_wire[1][0] = (add_mode) ? row_in[1] : row_d1[1];
assign row_wire[2][0] = (add_mode) ? row_in[2] : row_d2[2];
assign row_wire[3][0] = (add_mode) ? row_in[3] : row_d3[3];
```

**两种模式对比**:

```
乘法模式 (add_mode = 0):
  ┌─────────────────────────────────────────────────────────┐
  │  使用延迟线，4个输入错开到达各PE                          │
  │  用于脉动阵列的矩阵乘法                                  │
  │                                                         │
  │  Cycle 0: row_wire[0][0]=A0, row_wire[1][0]=X           │
  │  Cycle 1: row_wire[0][0]=A1, row_wire[1][0]=A0          │
  │  Cycle 2: row_wire[0][0]=A2, row_wire[1][0]=A1          │
  └─────────────────────────────────────────────────────────┘

加法模式 (add_mode = 1):
  ┌─────────────────────────────────────────────────────────┐
  │  旁路延迟线，4个输入同时到达各PE                           │
  │  用于逐元素加法 (偏置加、残差连接)                         │
  │                                                         │
  │  Cycle 0: row_wire[0][0]=A0, row_wire[1][0]=A1          │
  │           row_wire[2][0]=A2, row_wire[3][0]=A3          │
  │  (所有输入同时到达)                                       │
  └─────────────────────────────────────────────────────────┘
```

### 5.2 使用场景

| 模式 | 用途 | 数据到达方式 |
|------|------|--------------|
| add_mode=0 | 矩阵乘法 | 错开到达 (Time-Skew) |
| add_mode=1 | 逐元素加法 | 同时到达 |

---

## 6. 后处理: 量化 + 偏置 + ReLU

### 6.1 后处理流水线

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 130-142
generate
    genvar m, n;
    for (m = 0; m < 4; m = m + 1) begin : out_row_gen
        for (n = 0; n < 4; n = n + 1) begin : out_col_gen
            // 1. 量化截断: 32bit → 8bit
            assign pe_res_i8[m][n] = {pe_res[m][n][31], pe_res[m][n][out_shift +: 7]};

            // 2. 偏置加: INT8 + INT8 → INT32
            assign biased_val[m][n] = {{24{pe_res_i8[m][n][7]}}, pe_res_i8[m][n]}
                                    + {{24{bias_vec[n*8+7]}}, bias_vec[n*8 +: 8]};

            // 3. ReLU + 饱和: INT32 → INT8
            assign pe_post_i8[m][n] = relu_en && (biased_val[m][n] <= 32'sd0)
                                    ? 8'sd0
                                    : sat_i8(biased_val[m][n]);

            // 4. 结果有效标志
            assign res_valid[(m*4)+n] = pe_res_valid[m][n];
        end
    end
endgenerate
```

### 6.2 量化截断详解

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 134
pe_res_i8[m][n] = {pe_res[m][n][31], pe_res[m][n][out_shift +: 7]};
```

**截断过程**:
```
pe_res[m][n] (32bit):
┌────────┬────────────────────────────────────────────────────┐
│ bit[31]│ bit[30] ... bit[out_shift+7] ... bit[out_shift] ... bit[0] │
│  符号  │                    有效数据                        │
└────────┴────────────────────────────────────────────────────┘

取符号位 + 7bit 有效数据:
pe_res_i8 = {bit[31], bit[out_shift+6 : out_shift]}

等效于: pe_res_i8 = (pe_res >> out_shift)[7:0]
```

**out_shift 参数**:
- Layer 1: out_shift = 7 (累加范围约 ±16384)
- Layer 2: out_shift = 8 (累加范围约 ±32768)

### 6.3 偏置加法

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 135
biased_val[m][n] = {{24{pe_res_i8[m][n][7]}}, pe_res_i8[m][n]}
                  + {{24{bias_vec[n*8+7]}}, bias_vec[n*8 +: 8]};
```

**偏置加示意**:
```
pe_res_i8[m][n] (INT8):
┌─────────────────┐
│ -128 ~ +127     │
└─────────────────┘
        ↓ sign_extend
┌─────────────────────────────────────────────────────────────┐
│ INT32: -128 ~ +127                                          │
└─────────────────────────────────────────────────────────────┘
        +
bias_vec[n] (INT8):
┌─────────────────┐
│ -128 ~ +127     │
└─────────────────┘
        ↓ sign_extend
┌─────────────────────────────────────────────────────────────┐
│ INT32: -128 ~ +127                                          │
└─────────────────────────────────────────────────────────────┘
        =
biased_val[m][n] (INT32):
┌─────────────────────────────────────────────────────────────┐
│ -256 ~ +254                                                 │
└─────────────────────────────────────────────────────────────┘
```

**注意**: 偏置只按列索引 n 寻址，同一列的 4 个 PE 共享相同的偏置值。

### 6.4 ReLU 激活

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 136-138
pe_post_i8[m][n] = relu_en && (biased_val[m][n] <= 32'sd0)
                ? 8'sd0
                : sat_i8(biased_val[m][n]);
```

**ReLU 逻辑**:
```
if (relu_en && biased_val <= 0):
    pe_post_i8 = 0          // 负值截断为0
else:
    pe_post_i8 = sat_i8(biased_val)  // 饱和到INT8

示例:
  biased_val = -10  → pe_post_i8 = 0 (ReLU)
  biased_val = 0    → pe_post_i8 = 0 (ReLU)
  biased_val = 50   → pe_post_i8 = 50 (正常)
  biased_val = 200  → pe_post_i8 = 127 (饱和)
```

### 6.5 饱和函数

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 152-162
function automatic signed [7:0] sat_i8(input logic signed [31:0] vin);
    begin
        if (vin > 32'sd127) begin
            sat_i8 = 8'sd127;      // 上溢饱和
        end else if (vin < -32'sd128) begin
            sat_i8 = -8'sd128;     // 下溢饱和
        end else begin
            sat_i8 = vin[7:0];     // 正常范围
        end
    end
endfunction
```

---

## 7. 结果输出

### 7.1 结果打包

```systemverilog
// 文件: src/npu/mm_systolic_4x4.sv, line 144-150
always_comb begin
    for (int rr = 0; rr < 4; rr++) begin
        for (int cc = 0; cc < 4; cc++) begin
            res[((rr*4+cc)*8) +: 8] = pe_post_i8[rr][cc];
        end
    end
end
```

**结果布局**:
```
res (128bit):
┌────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ pe[0][0] │ pe[0][1] │ pe[0][2] │ pe[0][3] │ pe[1][0] │ pe[1][1] │ ... │ pe[3][2] │ pe[3][3] │
│  [127:120]│ [119:112]│ [111:104]│ [103:96] │  [95:88] │  [87:80] │ ... │  [15:8]  │   [7:0]  │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

res_valid (16bit):
┌────────────────────────────────────────────────────────────┐
│ valid[0][0] │ valid[0][1] │ ... │ valid[3][2] │ valid[3][3] │
│    [15]     │     [14]    │ ... │     [1]     │     [0]     │
└────────────────────────────────────────────────────────────┘
```

### 7.2 后处理流水线图

```
                    ┌─────────────────────────────────────────────────┐
                    │            mm_systolic_4x4 后处理                │
                    │                                                 │
  pe_res[0][0] ────┤──→ 量化 ──→ 偏置加 ──→ ReLU ──→ sat_i8 ──→ res[0][0]
  pe_res[0][1] ────┤──→ 量化 ──→ 偏置加 ──→ ReLU ──→ sat_i8 ──→ res[0][1]
  ...              │                                                 │
  pe_res[3][3] ────┤──→ 量化 ──→ 偏置加 ──→ ReLU ──→ sat_i8 ──→ res[3][3]
                    │                                                 │
                    │  out_shift    bias_vec[n]   relu_en             │
                    │      ↑            ↑            ↑                │
                    │  (配置信号)   (配置信号)   (配置信号)            │
                    └─────────────────────────────────────────────────┘
```

---

## 8. 计算时序示例

### 8.1 Conv1 计算 (DOT_K=75)

```
初始化:
  - flush=1, 清零所有PE累加器
  - 权重通过 col_bar 加载到各PE

计算阶段 (75个周期):
  Cycle 0:  flush=1, bar_valid=1
            row_bar = {A[0][0], A[0][1], A[0][2], A[0][3]}
            col_bar = {W[0][0], W[0][1], W[0][2], W[0][3]}

            PE[0][0]: acc = A[0][0] × W[0][0]
            PE[0][1]: acc = A[0][0] × W[0][1] (延迟1周期)
            PE[0][2]: acc = A[0][0] × W[0][2] (延迟2周期)
            PE[0][3]: acc = A[0][0] × W[0][3] (延迟3周期)

  Cycle 1:  flush=0, bar_valid=1
            row_bar = {A[1][0], A[1][1], A[1][2], A[1][3]}
            col_bar = {W[1][0], W[1][1], W[1][2], W[1][3]}

            PE[0][0]: acc += A[1][0] × W[1][0]
            PE[0][1]: acc += A[1][0] × W[1][1]
            PE[0][2]: acc += A[1][0] × W[1][2]
            PE[0][3]: acc += A[1][0] × W[1][3]

            PE[1][0]: acc = A[0][0] × W[0][0] (第一个beat到达)
            PE[1][1]: acc = A[0][0] × W[0][1] (延迟1+1=2周期)
            ...

  Cycle 74: flush=0, bar_valid=1
            PE[0][0]: acc += A[74][0] × W[74][0], res_valid=1
            PE[0][1]: acc += A[74][0] × W[74][1], res_valid=1
            ...

结果输出:
  res[0][0] = Σ_{k=0}^{74} A[k][0] × W[k][0]  (量化+偏置+ReLU后)
  res[0][1] = Σ_{k=0}^{74} A[k][0] × W[k][1]
  ...
```

### 8.2 偏置加时序

```
PE 结果输出后，立即进行后处理:

  pe_res[0][0] = Σ A[k][0] × W[k][0]  (INT32)
      ↓
  pe_res_i8[0][0] = (pe_res >> out_shift)[7:0]  (INT8)
      ↓
  biased_val[0][0] = pe_res_i8[0][0] + bias_vec[0]  (INT32)
      ↓
  pe_post_i8[0][0] = relu_en ? max(0, sat_i8(biased_val)) : sat_i8(biased_val)
      ↓
  res[0] = pe_post_i8[0][0]  (INT8)

注意: 偏置加是组合逻辑，与 PE 结果输出在同一周期完成!
```

### 8.3 完整时序图

```
Cycle:  0    1    2    3    ...   74   75   76
        │    │    │    │         │    │    │
flush:  1    0    0    0    ...   0    0    0
valid:  1    1    1    1    ...   1    0    0
        │    │    │    │         │    │    │
PE累加: 初始 +1   +1   +1   ...  +1   ─    ─
        │    │    │    │         │    │    │
量化:   ─    ─    ─    ─    ...  ─    输出 ─
偏置:   ─    ─    ─    ─    ...  ─    加   ─
ReLU:   ─    ─    ─    ─    ...  ─    激活 ─
        │    │    │    │         │    │    │
res_valid: ─  ─    ─    ─    ...  ─    1    0

注意: 后处理 (量化+偏置+ReLU) 是组合逻辑，在 res_valid=1 的同一周期完成。
```

---

## 9. 关键知识点总结

### 9.1 模块功能

| 功能 | 实现 | 延迟 |
|------|------|------|
| 4×4 PE 阵列 | generate 循环实例化 | - |
| Time-Skew 对齐 | 延迟线 (DFF 链) | 0-3 周期 |
| 量化截断 | 右移 + 取高8位 | 0 (组合) |
| 偏置加 | INT8 加法 | 0 (组合) |
| ReLU | 条件赋值 | 0 (组合) |
| 饱和 | sat_i8 函数 | 0 (组合) |

### 9.2 设计特点

1. **全组合后处理**: 量化、偏置加、ReLU 都是组合逻辑，零延迟
2. **add_mode 旁路**: 加法模式跳过延迟线，所有输入同时到达
3. **参数化设计**: DOT_K 可配置，支持不同层的点积长度
4. **16 路并行**: 4×4 阵列每周期输出 16 个结果

### 9.3 资源占用

```
单个 mm_systolic_4x4:
  - 16 个 PE (每个含 1 个乘法器 + 1 个累加器)
  - 9 个延迟寄存器 (3+3+3)
  - 3 个 valid 延迟寄存器
  - 16 个量化 + 偏置 + ReLU 单元

总计 (80 个实例):
  - 1280 个 PE
  - 720 个延迟寄存器
  - 240 个 valid 延迟寄存器
  - 1280 个后处理单元
```

---

## 10. 动手练习

### 练习 1: Time-Skew 时序分析

给定输入序列:
```
Cycle:  0    1    2    3    4
row_bar: A0   A1   A2   A3   A4
col_bar: W0   W1   W2   W3   W4
valid:   1    1    1    1    1
```

1. 写出每个周期 row_wire[0][0], row_wire[1][0], row_wire[2][0], row_wire[3][0] 的值
2. 写出每个周期 col_wire[0][0], col_wire[0][1], col_wire[0][2], col_wire[0][3] 的值
3. 说明 PE[2][1] 在哪个周期处理 A0×W0

### 练习 2: 后处理计算

给定 PE 结果:
```
pe_res[0][0] = 1000
pe_res[0][1] = -500
pe_res[0][2] = 200
pe_res[0][3] = -150

out_shift = 7
bias_vec = {10, -20, 30, -40}
relu_en = 1
```

计算 res[0][0], res[0][1], res[0][2], res[0][3] 的值

### 练习 3: add_mode 对比

假设要执行逐元素加法: C[i] = A[i] + B[i], i=0,1,2,3

1. 如何设置 add_mode 和 add_compute_valid?
2. 写出 row_bar 和 col_bar 的内容
3. 绘制 PE 内部的计算过程

### 练习 4: 阅读源码

阅读 `src/npu/mm_systolic_4x4.sv`，回答:

1. 为什么延迟线寄存器需要多定义一维 (line 46-48)?
2. `bar_valid_delay` 为什么是 3bit 而不是 4bit?
3. `biased_val` 的计算中，为什么使用 `{{24{...}}, ...}` 符号扩展?

### 练习 5: 性能分析

计算 Conv1 层 (1024×75 矩阵乘 75×32 矩阵) 的总周期数:
- 阵列: 40×32 = 1280 PE
- Tile 数: ceil(1024/40) = 26
- DOT_K: 75
- Drain 延迟: 4 周期 (Time-Skew 最大延迟)

总周期数 = ? (忽略数据加载和结果写回)

---

## 11. 下节预告

**Lecture 19: MAC 阵列顶层 — 40×32 数据广播**
- `mac_array_40x32_stream.sv` 详细解析
- 80 个 mm_systolic_4x4 的连接
- A/W 数据广播机制
- Tile 循环控制
- 双 Pass 扩展 (64 通道)

---

## 参考资料

- 源码: `src/npu/mm_systolic_4x4.sv` (4×4 子阵列完整实现)
- 源码: `src/npu/pe.sv` (PE 基本单元)
- 源码: `src/npu/mac_array_40x32_stream.sv` (顶层阵列)
- 文档: `docs/NPU_DESIGN_REPORT.md` 第 4.2 节
