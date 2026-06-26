# Lecture 21: NPU 后处理 -- MaxPool、GAP 与 FC 层

> **目标**: 深入理解 NPU 推理流水线的最后阶段: 流式 MaxPool 池化、全局平均池化 (GAP)、全连接层 (FC) 与 argmax 分类。

> **参考源码**:
> - `src/npu/ppu_maxpool.sv`
> - `src/npu/gap_fc_logits.sv`

---

## 1. 后处理在推理流水线中的位置

### 1.1 完整推理链

```
  输入图像 (32x32x3)
    │
    v
  ┌─────────────────────────────────────────────────────────────┐
  │ Conv1: mac_array_40x32_stream (im2col + 40x32 SA)           │
  │   输入: 32x32x3, K=5x5, pad=2                              │
  │   输出: 32x32x32 (1024 像素, 32 通道)                       │
  │   ReLU 激活                                                  │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                             v
  ┌─────────────────────────────────────────────────────────────┐
  │ MaxPool: ppu_maxpool                                        │
  │   输入: 32x32x32                                            │
  │   输出: 16x16x32 (256 像素, 32 通道)                        │
  │   2x2 窗口, stride=2                                        │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                             v
  ┌─────────────────────────────────────────────────────────────┐
  │ Conv2: mac_array_40x32_stream (im2col + 40x32 SA, 2 passes) │
  │   输入: 16x16x32, K=5x5, pad=2                             │
  │   输出: 16x16x64 (256 像素, 64 通道)                        │
  │   ReLU 激活                                                  │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                             v
  ┌─────────────────────────────────────────────────────────────┐
  │ MaxPool: ppu_maxpool (第二次)                                │
  │   输入: 16x16x64                                            │
  │   输出: 8x8x64 (64 像素, 64 通道)                           │
  └──────────────────────────┬──────────────────────────────────┘
                             │
                             v
  ┌─────────────────────────────────────────────────────────────┐
  │ GAP + FC: gap_fc_logits                                     │
  │   GAP: 8x8x64 -> 1x64 (全局平均池化)                        │
  │   FC:  64 -> 10 (全连接分类)                                 │
  │   argmax: 选出最大 logit 对应的类别                          │
  └─────────────────────────────────────────────────────────────┘
                             │
                             v
  预测类别 (0-9)
```

---

## 设计视角：为什么这样设计？

### 动机分析

后处理模块位于 MAC 阵列输出和最终分类之间，需要完成三个任务：池化降维、全局平均池化、全连接分类。核心挑战是：**如何在不增加额外延迟的情况下完成这些计算？**

### 关键设计决策

```
  决策 1: 为什么 MaxPool 是流式而非乒乓缓冲?

  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 乒乓缓冲 │  将整个特征图写入 RAM A              │
  │                  │  从 RAM A 读出, 池化后写入 RAM B     │
  │                  │  需要: 2 块 RAM, 额外延迟             │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 流式处理  │  输入像素逐个到达                    │
  │  (当前)          │  用 left_pixel_buf + row_max_buf     │
  │                  │  缓存 2x2 窗口的中间状态              │
  │                  │  需要: 1 个行缓冲 + 1 个像素寄存器    │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B 的理由:
  - 与 MAC 阵列的结果写出节奏完全同步
  - 无需额外的 RAM 块 (节省 BRAM 资源)
  - 零额外延迟: 输入像素到达当拍即可判断是否输出
```

### 为什么 GAP 使用被动累加？

```
  ┌───────────────────────────────────────────────────────┐
  │  传统方案: Conv 完成后, 专门读取 pool_ram 做 GAP       │
  │  - 需要额外的 128 次读取周期                           │
  │  - 与 Conv 计算串行, 增加总延迟                        │
  │                                                       │
  │  当前方案: GAP 累加与 MaxPool 输出并行                  │
  │  - MaxPool 每输出一个像素, stream_wr_en 触发累加       │
  │  - gap_sum 寄存器在 Conv2+MaxPool 运行时同步更新       │
  │  - Conv 完成时 GAP 也完成, 无需额外时间                │
  │                                                       │
  │  代价: 需要 64 个 32-bit 累加器 (64 x 4B = 256B 寄存器)│
  │  收益: 消除 GAP 阶段的全部延迟                          │
  └───────────────────────────────────────────────────────┘
```

### 为什么 FC 使用树形归约而非串行累加？

```
  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 串行累加  │  每周期 1 个乘累加                  │
  │                  │  64 维点积 = 64 周期/类别            │
  │                  │  10 类别 = 640 周期                  │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 树形归约  │  64 个乘法并行, 6 级加法树          │
  │  (当前)          │  64 维点积 = 8 周期/类别             │
  │                  │  10 类别 = 81 周期                   │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B: FC 是推理的最后一环, 直接影响端到端延迟
  代价: 64 个乘法器 + 63 个加法器 (面积增加)
  收益: 延迟从 640 周期降到 81 周期 (7.9x 加速)
```

### 设计约束总结

```
  ┌─────────────────────────────────────────────────────┐
  │  约束 1: MaxPool 必须跟上 MAC 阵列的输出速率          │
  │         MAC 每 tile 输出 40 行, 每行 1 周期           │
  │         MaxPool 必须每周期处理 1 个像素               │
  │                                                     │
  │  约束 2: GAP 不能增加额外延迟                         │
  │         Conv2 完成后应立即进入 FC                     │
  │                                                     │
  │  约束 3: FC 延迟应远小于 Conv 延迟                    │
  │         Conv 总延迟 ~20000 周期                      │
  │         FC 延迟 81 周期 (占比 < 0.5%)                │
  └─────────────────────────────────────────────────────┘
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 分析后处理需求

```
  输入: Conv 层输出的特征图
  输出: 分类结果 (class_id + logit)

  处理链:
  Conv1 (32x32x32) → MaxPool (16x16x32)
  Conv2 (16x16x64) → MaxPool (8x8x64) → GAP (1x64) → FC (1x10)

  确定每级的输入输出格式:
  ┌──────────┬──────────────┬──────────────┐
  │ 模块      │ 输入格式      │ 输出格式      │
  ├──────────┼──────────────┼──────────────┤
  │ MaxPool  │ 256bit/像素   │ 256bit/像素   │
  │ GAP      │ 256bit/像素   │ 64 x int32   │
  │ FC       │ 64 x int8    │ 10 x int8    │
  │ argmax   │ 10 x int8    │ class_id     │
  └──────────┴──────────────┴──────────────┘
```

### 第 2 步: 设计流式 MaxPool

```
  设计过程:
  1. 确定窗口大小: 2x2, stride=2 (标准池化)
  2. 分析输入顺序: 行优先 (0,0) (0,1) (0,2) ...
  3. 确定缓存需求:
     - 水平方向: 需要缓存 1 个像素 (left_pixel_buf)
     - 垂直方向: 需要缓存 1 行的最大值 (row_max_buf)
  4. 设计判断逻辑:
     - w_idx[0]==0: 缓存左像素
     - w_idx[0]==1 && h_idx[0]==0: 水平最大值存入行缓冲
     - w_idx[0]==1 && h_idx[0]==1: 垂直最大值, 输出结果

  关键公式:
    pool_h = h_idx >> 1
    pool_w = w_idx >> 1
    addr = (pool_h * out_size + pool_w) * stride + offset
```

### 第 3 步: 设计被动 GAP 累加器

```
  设计过程:
  1. 确定累加器数量: 64 个 (对应 Conv2 的 64 个输出通道)
  2. 确定累加器位宽: 32 bit (64 个 int8 最大和 = 64*127 = 8128)
  3. 设计触发机制: stream_wr_en 有效时累加
  4. 处理通道分裂: addr[0]==0 累加 ch[0..31], addr[0]==1 累加 ch[32..63]

  累加器生命周期:
    clear=1: 清零所有 gap_sum
    Conv2+MaxPool 运行期间: 持续累加
    Conv 完成后: gap_sum >> 6 得到 GAP 结果
```

### 第 4 步: 设计树形归约 FC

```
  设计过程:
  1. 确定归约深度: log2(64) = 6 级加法
  2. 设计流水线:
     S_MUL: 64 个乘法 (1 周期)
     S_ADD32: 64→32 (1 周期)
     S_ADD16: 32→16 (1 周期)
     S_ADD8:  16→8  (1 周期)
     S_ADD4:  8→4   (1 周期)
     S_ADD2:  4→2   (1 周期)
     S_ADD1:  2→1   (1 周期)
     S_WRITE: 后处理 (1 周期)
  3. 设计类别循环: 10 个类别串行, 每类 8 周期

  总延迟: 1(PREP) + 10 * 8 = 81 周期
```

### 第 5 步: 集成与验证

```
  验证策略:
  1. MaxPool 单元验证: 已知输入, 验证输出地址和值
  2. GAP 累加验证: 已知像素序列, 验证累加结果
  3. FC 计算验证: 已知权重和输入, 验证 logit 输出
  4. 端到端验证: 完整推理链, 与 Python 参考模型对比

  关键检查点:
  - MaxPool 的 row_max_buf 索引是否溢出
  - GAP 的 64 通道是否全部正确累加
  - FC 的乘法结果是否溢出 32 位
  - argmax 在 tie 情况下的行为
```

---

## 设计视角：架构模式与原则

### 模式 1: 流式重叠处理模式 (Streaming Overlap)

```
  核心思想: 让数据在流动过程中被处理, 而非先存储再处理

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  传统方案: 存储 → 处理 → 存储 → 处理 → ...            │
  │  Conv结果 → [RAM] → MaxPool读 → [RAM] → FC读         │
  │  延迟 = 写入 + 读出 + 写入 + 读出                      │
  │                                                       │
  │  流式方案: 数据到达即处理                              │
  │  Conv结果流 → MaxPool(当拍) → pool_wr(当拍)           │
  │                          ↓                            │
  │                    GAP累加(当拍)                       │
  │                                                       │
  │  延迟 = 0 (处理与传输重叠)                             │
  │                                                       │
  │  实现要点:                                             │
  │  - MaxPool 的 2x2 窗口只需 1 行 + 1 像素的寄存器      │
  │  - GAP 的 stream_wr_en 与 MaxPool 的 pool_wr_en 同步  │
  │  - 无需中间 RAM (或只用 1 个双端口 RAM)                │
  └───────────────────────────────────────────────────────┘

  适用场景:
  - 处理逻辑简单 (比较/累加)
  - 数据流是顺序扫描 (行优先)
  - 窗口大小较小 (2x2)
```

### 模式 2: 树形归约模式 (Tree Reduction)

```
  核心思想: 用二叉树结构将 N 个操作的延迟从 O(N) 降到 O(log N)

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  串行累加: a0 + a1 + a2 + ... + a63                   │
  │  延迟: 63 个加法器级联 = 63 周期                        │
  │                                                       │
  │  树形归约:                                             │
  │  Level 0: a0+a1, a2+a3, ..., a62+a63  → 32 个部分和  │
  │  Level 1: s0+s1, s2+s3, ..., s30+s31 → 16 个部分和   │
  │  Level 2: → 8 个部分和                                │
  │  Level 3: → 4 个部分和                                │
  │  Level 4: → 2 个部分和                                │
  │  Level 5: → 1 个最终和                                │
  │  延迟: 6 周期 (log2(64))                              │
  │                                                       │
  │  面积代价: 63 个加法器 (与串行相同)                     │
  │  延迟收益: 从 63 周期降到 6 周期 (10.5x)               │
  └───────────────────────────────────────────────────────┘

  流水线化:
  - 每级之间插入寄存器
  - 吞吐: 1 个点积/8 周期 (流水线深度)
  - 本设计未使用 FC 流水线 (10 类别串行处理)
```

### 原则: 零延迟设计

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 当两个操作有数据依赖时, 尽量重叠执行       │
  │                                                     │
  │  本设计中的应用:                                     │
  │                                                     │
  │  1. MaxPool 与 Conv 结果写出重叠                     │
  │     Conv 逐行写出 → MaxPool 逐像素处理               │
  │     不需要等 Conv 全部完成再开始池化                  │
  │                                                     │
  │  2. GAP 与 MaxPool 重叠                              │
  │     MaxPool 输出 → GAP 累加器同步更新                │
  │     不需要等 MaxPool 全部完成再开始累加               │
  │                                                     │
  │  3. argmax 与 FC 计算重叠                            │
  │     每个类别计算完成 → 立即比较更新最佳               │
  │     不需要等 10 个类别全部算完再找最大值              │
  │                                                     │
  │  反模式: 串行等待                                    │
  │  Conv → wait → MaxPool → wait → GAP → wait → FC    │
  │  总延迟 = 各阶段延迟之和                             │
  │                                                     │
  │  当前设计: 重叠执行                                   │
  │  总延迟 = max(Conv, MaxPool+GAP) + FC                │
  │         = Conv + 81 周期 (几乎无额外开销)            │
  └─────────────────────────────────────────────────────┘
```

---

## 2. ppu_maxpool -- 流式 2x2 最大池化

### 2.1 模块概述

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 4-5 行
// Streaming 2x2 maxpool for row-major feature maps.
// Input row is one spatial pixel with all channels packed into 256 bits.
```

**关键设计决策**: 输入数据按空间像素流式到达, 每个像素的所有通道打包在一个 256-bit 字中。
这与逐通道处理不同, 需要同时比较所有通道。

### 2.2 参数配置

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 6-13 行
parameter int IN_SIZE  = 32,           // 输入空间尺寸
parameter int CHANNELS = 32,           // 通道数
parameter int IN_ROWS  = IN_SIZE * IN_SIZE,  // = 1024 输入像素数
parameter int OUT_SIZE = IN_SIZE / 2,  // = 16 输出空间尺寸
parameter int DATA_DW  = CHANNELS * 8, // = 256, 数据位宽
parameter int IN_AW    = $clog2(IN_ROWS),   // 输入地址宽度
parameter int OUT_AW   = $clog2(OUT_SIZE*OUT_SIZE)  // 输出地址宽度
```

### 2.3 接口信号

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 14-31 行
// 控制
input  logic start,                    // 开始新帧
input  logic [5:0] cfg_in_size,        // 输入尺寸 (可配置)
input  logic [5:0] cfg_out_size,       // 输出尺寸
input  logic [1:0] cfg_addr_stride,    // 地址步长
input  logic [1:0] cfg_addr_offset,    // 地址偏移

// 输入流
input  logic in_valid,                 // 输入像素有效
input  logic [IN_AW-1:0] in_row_idx,   // 输入像素索引
input  logic [DATA_DW-1:0] in_data,    // 256-bit 像素数据

// 输出
output logic pool_wr_en,               // 池化结果写使能
output logic [OUT_AW-1:0] pool_wr_addr,// 池化结果地址
output logic [DATA_DW-1:0] pool_wr_data,// 池化结果数据
output logic busy,
output logic frame_done                // 帧完成
```

### 2.4 坐标计算

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 44-49 行
assign h_idx = in_row_idx / cfg_in_size;    // 输入行号
assign w_idx = in_row_idx % cfg_in_size;    // 输入列号
assign pool_h = h_idx >> 1;                 // 输出行号 (h/2)
assign pool_w = w_idx >> 1;                 // 输出列号 (w/2)
assign hmax_data = max_vec_i8(left_pixel_buf, in_data);  // 水平方向最大值
assign vmax_data = max_vec_i8(row_max_buf[pool_w], hmax_data);  // 垂直方向最大值
```

### 2.5 2x2 池化窗口的状态管理

池化窗口内的 4 个像素按行优先顺序到达, 需要缓存中间结果:

```
  输入像素到达顺序 (行优先):
  (0,0) (0,1) (0,2) (0,3) ...
  (1,0) (1,1) (1,2) (1,3) ...
  (2,0) (2,1) (2,2) (2,3) ...
  ...

  2x2 窗口:
  ┌─────────┬─────────┐
  │ (h,w)   │ (h,w+1) │  <- 同一行的两个像素
  ├─────────┼─────────┤
  │ (h+1,w) │ (h+1,w+1)│  <- 下一行的两个像素
  └─────────┴─────────┘

  处理步骤:
  1. (h,w):   w_idx[0]==0, 缓存到 left_pixel_buf
  2. (h,w+1): w_idx[0]==1, 与 left_pixel_buf 取水平最大值
              h_idx[0]==0, 缓存到 row_max_buf[w/2]
  3. (h+1,w): w_idx[0]==0, 缓存到 left_pixel_buf
  4. (h+1,w+1): w_idx[0]==1, 与 left_pixel_buf 取水平最大值
                h_idx[0]==1, 与 row_max_buf 取垂直最大值
                输出结果!
```

### 2.6 核心状态机

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 74-94 行
end else if (in_valid) begin
    busy <= 1'b1;
    if (w_idx[0] == 1'b0) begin
        // 偶数列: 缓存为左像素
        left_pixel_buf <= in_data;
    end else if (h_idx[0] == 1'b0) begin
        // 奇数列, 偶数行: 水平最大值缓存到行最大值
        row_max_buf[pool_w] <= hmax_data;
    end else begin
        // 奇数列, 奇数行: 垂直最大值, 输出结果
        pool_wr_en <= 1'b1;
        pool_wr_addr <= OUT_AW'((pool_h * cfg_out_size + pool_w)
                                 * cfg_addr_stride + cfg_addr_offset);
        pool_wr_data <= vmax_data;
        // 检查是否为最后一个像素
        if ((pool_h == cfg_out_size - 6'd1) &&
            (pool_w == cfg_out_size - 6'd1)) begin
            frame_done <= 1'b1;
            busy <= 1'b0;
        end
    end
end
```

### 2.7 向量化最大值函数

```systemverilog
// 文件: src/npu/ppu_maxpool.sv, 第 97-110 行
function automatic logic [DATA_DW-1:0] max_vec_i8(
    input logic [DATA_DW-1:0] a,
    input logic [DATA_DW-1:0] b
);
    logic signed [7:0] av;
    logic signed [7:0] bv;
    begin
        for (int i = 0; i < CHANNELS; i = i + 1) begin
            av = $signed(a[i*8 +: 8]);
            bv = $signed(b[i*8 +: 8]);
            max_vec_i8[i*8 +: 8] = (av >= bv) ? av : bv;
        end
    end
endfunction
```

**硬件实现**: 32 个并行 8-bit 有符号比较器, 每个比较器输出较大的值。
这是一个纯组合逻辑函数, 在一个周期内完成所有 32 通道的比较。

```
  max_vec_i8 硬件结构:

  a[255:248]  a[247:240]  ...  a[15:8]    a[7:0]
      │           │               │          │
      v           v               v          v
  ┌───────┐  ┌───────┐       ┌───────┐  ┌───────┐
  │ CMP_i8│  │ CMP_i8│  ...  │ CMP_i8│  │ CMP_i8│
  └───┬───┘  └───┬───┘       └───┬───┘  └───┬───┘
      │           │               │          │
      v           v               v          v
  out[255:248] out[247:240]   out[15:8]  out[7:0]

  共 32 个并行比较器, 延迟 = 1 级比较
```

### 2.8 MaxPool 时序示例

```
  Conv1 输出: 32x32x32, 1024 个像素流式到达

  T=0:   in_row_idx=0,  (h=0,w=0), w[0]=0 -> 缓存 left_pixel_buf
  T=1:   in_row_idx=1,  (h=0,w=1), w[0]=1, h[0]=0 -> row_max_buf[0] = max(left, in)
  T=2:   in_row_idx=2,  (h=0,w=2), w[0]=0 -> 缓存 left_pixel_buf
  T=3:   in_row_idx=3,  (h=0,w=3), w[0]=1, h[0]=0 -> row_max_buf[1] = max(left, in)
  ...
  T=32:  in_row_idx=32, (h=1,w=0), w[0]=0 -> 缓存 left_pixel_buf
  T=33:  in_row_idx=33, (h=1,w=1), w[0]=1, h[0]=1 -> vmax = max(row_max[0], hmax)
         pool_wr_en=1, 输出 (0,0) 的池化结果
  T=34:  in_row_idx=34, (h=1,w=2), w[0]=0 -> 缓存 left_pixel_buf
  T=35:  in_row_idx=35, (h=1,w=3), w[0]=1, h[0]=1 -> 输出 (0,1) 的池化结果
  ...
  T=1023: in_row_idx=1023, (h=31,w=31), 输出 (15,15) 的池化结果
         frame_done=1

  总延迟: 1024 个输入像素 = 1024 个周期
  输出: 16x16 = 256 个池化结果
```

### 2.9 地址计算与 stride/offset

```systemverilog
pool_wr_addr = (pool_h * cfg_out_size + pool_w) * cfg_addr_stride + cfg_addr_offset
```

```
  addr_stride 和 addr_offset 的用途:

  Conv1 后 MaxPool (stride=1, offset=0):
    地址 = pool_h * 16 + pool_w    (连续存储)

  Conv2 后 MaxPool (stride=1, offset=0):
    地址 = pool_h * 8 + pool_w     (连续存储)

  当需要在 RAM 中交替存放不同层的结果时:
    stride=2, offset=0: 写入偶数地址
    stride=2, offset=1: 写入奇数地址
```

---

## 3. gap_fc_logits -- GAP + FC + argmax

### 3.1 模块概述

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 4-6 行
// Final classifier stage for the 8x8x64 feature map.
// It accumulates the final-pool write stream into GAP sums while conv_top is
// still running, then runs a 64->10 int8 FC layer when start is asserted.
```

**关键设计**: GAP 累加与 Conv 计算**并行**进行。当 Conv2 + MaxPool 产生结果流时,
`gap_fc_logits` 同步累加每个通道的值。只有 FC 层需要额外的计算时间。

### 3.2 参数配置

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 7-16 行
parameter string FC_WEIGHT_FILE = "export_cifar/cifar10_int8_pow2_fused/fc_weight_i8.memh",
parameter string FC_BIAS_FILE   = "export_cifar/cifar10_int8_pow2_fused_bias_i8/fc_bias_i8.memh",
parameter int POOL_ROWS = 128,              // 池化结果 RAM 行数
parameter int DATA_DW = 256,               // 数据位宽
parameter int CHANNELS = 64,                // Conv2 输出通道数
parameter int OUT_CLASSES = 10,             // 输出类别数 (CIFAR-10)
parameter int LANES = 32,                   // 每个字的通道数
parameter int FC_SHIFT = 7                  // FC 后处理右移位数
```

### 3.3 接口信号

```
  gap_fc_logits 接口
  ┌─────────────────────────────────────────────────────────┐
  │  时钟/复位                                               │
  │    clk, rst_n                                            │
  │                                                         │
  │  控制                                                    │
  │    clear          -- 清除 GAP 累加器                     │
  │    start          -- 开始 FC 计算                        │
  │                                                         │
  │  池化结果 RAM 读端口 (用于 GAP 流式累加)                  │
  │    stream_wr_en   -- 池化结果写入 (来自 MaxPool)          │
  │    stream_wr_addr -- 池化结果地址                         │
  │    stream_wr_data -- 池化结果数据 (256-bit, 32 通道)      │
  │                                                         │
  │  池化结果 RAM 读端口 (用于 FC 计算)                       │
  │    pool_rd_en     -- 读使能                               │
  │    pool_rd_addr   -- 读地址                               │
  │    pool_rd_data   -- 读数据                               │
  │                                                         │
  │  输出                                                    │
  │    pred_valid     -- 预测有效                             │
  │    pred_class_id  -- 预测类别 (0-9)                       │
  │    pred_logit     -- 预测 logit 值                        │
  │    logits_flat    -- 所有 10 个 logit 值 (80-bit)         │
  │    busy, done                                            │
  └─────────────────────────────────────────────────────────┘
```

---

## 4. 全局平均池化 (GAP)

### 4.1 GAP 的数学定义

```
  GAP[c] = (1/N) * Σ_{i=0}^{N-1} feature_map[i][c]

  其中:
    N = 空间像素数 = 8x8 = 64
    c = 通道索引 (0..63)

  对于 int8 实现, 除法用右移 6 位 (>>6) 近似:
  GAP[c] ≈ (Σ feature_map[i][c]) >> 6
```

### 4.2 流式累加器

GAP 累加在 Conv2 + MaxPool 运行时**异步**进行:

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 155-163 行
end else if (stream_wr_en) begin
    for (int lane = 0; lane < LANES; lane = lane + 1) begin
        if (stream_wr_addr[0]) begin
            // 奇数地址: 累加到通道 32..63
            gap_sum[LANES + lane] <= gap_sum[LANES + lane]
                                      + sign_extend_pool_byte(stream_wr_data, lane);
        end else begin
            // 偶数地址: 累加到通道 0..31
            gap_sum[lane] <= gap_sum[lane]
                              + sign_extend_pool_byte(stream_wr_data, lane);
        end
    end
end
```

### 4.3 64 通道的分时累加

由于 MaxPool 输出每个时钟只有 32 个通道 (256-bit 字),
64 个通道需要分两次传输:

```
  MaxPool 输出流:
  T=0: addr=0, data={ch31..ch0}     -> 累加到 gap_sum[0..31]
  T=1: addr=1, data={ch63..ch32}    -> 累加到 gap_sum[32..63]
  T=2: addr=2, data={ch31..ch0}     -> 累加到 gap_sum[0..31]
  T=3: addr=3, data={ch63..ch32}    -> 累加到 gap_sum[32..63]
  ...
  T=126: addr=126, data={ch31..ch0} -> 累加到 gap_sum[0..31]
  T=127: addr=127, data={ch63..ch32} -> 累加到 gap_sum[32..63]

  共 128 次累加 (64 像素 x 2 次/像素)
  每个通道的最终累加值 = 该通道在 64 个像素上的求和
```

### 4.4 符号扩展函数

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 272-279 行
function automatic logic signed [7:0] sign_extend_pool_byte(
    input logic [DATA_DW-1:0] word,
    input int lane
);
    begin
        sign_extend_pool_byte = $signed(word[(LANES-1-lane)*8 +: 8]);
    end
endfunction
```

**字节序**: `word[255:248]` = ch0, `word[7:0]` = ch31。
lane=0 取高位 (ch0), lane=31 取低位 (ch31)。

### 4.5 GAP 后量化

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 177-179 行
for (int ch = 0; ch < CHANNELS; ch = ch + 1) begin
    gap_feat[ch] <= sat_i8(gap_sum[ch] >>> 6);
end
```

```
  gap_sum[ch]: 32-bit 累加值 (64 个 int8 的和)
  >>> 6:       右移 6 位 = 除以 64 (GAP 平均)
  sat_i8:      饱和到 [-128, 127]

  例: gap_sum[ch] = 3200
      3200 >>> 6 = 50
      sat_i8(50) = 50

  例: gap_sum[ch] = -8000
      -8000 >>> 6 = -125 (算术右移保持符号)
      sat_i8(-125) = -125
```

---

## 5. 全连接层 (FC) -- 64 到 10

### 5.1 FC 权重与偏置

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 62-63 行
logic signed [7:0] fc_weight [0:(OUT_CLASSES*CHANNELS)-1];  // 10x64 = 640 个 int8
logic signed [7:0] fc_bias [0:OUT_CLASSES-1];                // 10 个 int8

initial begin
    $readmemh(FC_WEIGHT_FILE, fc_weight);
    $readmemh(FC_BIAS_FILE, fc_bias);
end
```

```
  FC 权重布局:
  fc_weight[class_idx * 64 + ch] = 类别 class_idx 对应通道 ch 的权重

  fc_weight[0..63]:   类别 0 (airplane)  的 64 个权重
  fc_weight[64..127]:  类别 1 (automobile) 的 64 个权重
  ...
  fc_weight[576..639]: 类别 9 (truck)     的 64 个权重

  FC 计算:
  logit[c] = Σ_{ch=0}^{63} gap_feat[ch] * fc_weight[c*64+ch] + fc_bias[c]
```

### 5.2 8 级流水线树形归约

FC 层需要计算 64 个乘积累加。采用 8 级流水线树形归约:

```
  级数    操作              输入数    输出数    周期
  ─────────────────────────────────────────────────
  S_MUL:  64 个乘法          64       64       1
  S_ADD32: 32 个加法 (pair)   64       32       1
  S_ADD16: 16 个加法 (pair)   32       16       1
  S_ADD8:  8 个加法 (pair)    16        8       1
  S_ADD4:  4 个加法 (pair)     8        4       1
  S_ADD2:  2 个加法 (pair)     4        2       1
  S_ADD1:  1 个加法           2        1       1
  S_WRITE: 后处理             1        1       1
  ─────────────────────────────────────────────────
  总计:                                        8 周期/类别
```

### 5.3 树形归约详细实现

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 190-237 行

// 第 1 级: 64 个乘法
S_MUL: begin
    for (int lane = 0; lane < CHANNELS; lane = lane + 1) begin
        prod_stage[lane] <= sext_i8(gap_feat[lane]) *
                            sext_i8(fc_weight[int'(class_idx) * CHANNELS + lane]);
    end
    state <= S_ADD32;
end

// 第 2 级: 64 -> 32 (两两相加)
S_ADD32: begin
    for (int i = 0; i < 32; i = i + 1) begin
        sum32_stage[i] <= prod_stage[i*2] + prod_stage[i*2 + 1];
    end
    state <= S_ADD16;
end

// 第 3 级: 32 -> 16
S_ADD16: begin
    for (int i = 0; i < 16; i = i + 1) begin
        sum16_stage[i] <= sum32_stage[i*2] + sum32_stage[i*2 + 1];
    end
    state <= S_ADD8;
end

// 第 4 级: 16 -> 8
S_ADD8: begin
    for (int i = 0; i < 8; i = i + 1) begin
        sum8_stage[i] <= sum16_stage[i*2] + sum16_stage[i*2 + 1];
    end
    state <= S_ADD4;
end

// 第 5 级: 8 -> 4
S_ADD4: begin
    for (int i = 0; i < 4; i = i + 1) begin
        sum4_stage[i] <= sum8_stage[i*2] + sum8_stage[i*2 + 1];
    end
    state <= S_ADD2;
end

// 第 6 级: 4 -> 2
S_ADD2: begin
    for (int i = 0; i < 2; i = i + 1) begin
        sum2_stage[i] <= sum4_stage[i*2] + sum4_stage[i*2 + 1];
    end
    state <= S_ADD1;
end

// 第 7 级: 2 -> 1
S_ADD1: begin
    sum1_stage <= sum2_stage[0] + sum2_stage[1];
    state <= S_WRITE;
end
```

### 5.4 树形归约图示

```
  S_MUL: prod[0] prod[1] prod[2] prod[3] ... prod[62] prod[63]
           \      /       \      /             \       /
  S_ADD32: sum32[0]     sum32[1]    ...    sum32[31]
             \   /         \   /               \   /
  S_ADD16: sum16[0]     sum16[1]    ...    sum16[15]
              \ /           \ /                 \ /
  S_ADD8:  sum8[0]       sum8[1]    ...     sum8[7]
              \ /           \ /                 \ /
  S_ADD4:  sum4[0]       sum4[1]         sum4[2]  sum4[3]
              \   /           \   /
  S_ADD2:  sum2[0]         sum2[1]
                \     /
  S_ADD1:     sum1_stage  = Σ prod[0..63]
```

### 5.5 FC 后处理 -- 偏置加法与量化

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 287-298 行
function automatic logic signed [7:0] postproc_fc(
    input logic signed [31:0] acc,
    input logic signed [7:0] bias
);
    logic signed [31:0] shifted;
    logic signed [31:0] biased;
    begin
        shifted = acc >>> FC_SHIFT;                    // 右移 7 位
        biased = shifted + {{24{bias[7]}}, bias};      // 加偏置
        postproc_fc = sat_i8(biased);                  // 饱和到 int8
    end
endfunction
```

```
  后处理流水线:
  acc (32-bit 累加值)
    │
    v
  acc >>> 7  (右移 7 位 = 除以 128, 量化缩放)
    │
    v
  + bias     (加上类别偏置)
    │
    v
  sat_i8()   (饱和到 [-128, 127])
    │
    v
  logit (int8)
```

---

## 6. argmax 与预测输出

### 6.1 在线 argmax

FC 计算逐类别进行 (class_idx = 0, 1, ..., 9),
argmax 在 `S_WRITE` 阶段**边算边比较**:

```systemverilog
// 文件: src/npu/gap_fc_logits.sv, 第 238-258 行
S_WRITE: begin
    current_logit = postproc_fc(sum1_stage, fc_bias[class_idx]);
    logit_q[class_idx] <= current_logit;

    // 在线比较: 维护当前最佳类别
    if ((class_idx == 4'd0) || (current_logit > best_logit)) begin
        best_logit <= current_logit;
        best_class_id <= class_idx;
    end

    if (class_idx == OUT_CLASSES[3:0] - 4'd1) begin
        // 最后一个类别: 输出预测结果
        pred_valid <= 1'b1;
        if (current_logit > best_logit) begin
            pred_class_id <= class_idx;
            pred_logit <= current_logit;
        end else begin
            pred_class_id <= best_class_id;
            pred_logit <= best_logit;
        end
        state <= S_DONE;
    end else begin
        class_idx <= class_idx + 4'd1;
        state <= S_MUL;  // 继续下一个类别
    end
end
```

### 6.2 FC 计算总时序

```
  类别 0: S_PREP_FC(1) + S_MUL(1) + S_ADD32(1) + S_ADD16(1)
         + S_ADD8(1) + S_ADD4(1) + S_ADD2(1) + S_ADD1(1) + S_WRITE(1)
         = 9 周期

  类别 1~9: S_MUL(1) + S_ADD32(1) + S_ADD16(1) + S_ADD8(1)
           + S_ADD4(1) + S_ADD2(1) + S_ADD1(1) + S_WRITE(1)
           = 8 周期/类别

  总计: 9 + 9 x 8 = 81 周期 (从 start 到 pred_valid)
```

### 6.3 完整 FC 状态机图

```
  S_IDLE ──start──> S_PREP_FC ──> S_MUL ──> S_ADD32 ──> S_ADD16
                       │                                     │
                       v                                     v
                    初始化                              S_ADD8 ──> S_ADD4
                      │                                                │
                      v                                                v
                   gap_sum[]                                       S_ADD2 ──> S_ADD1
                   -> gap_feat[]                                               │
                                                                               v
                                                                           S_WRITE
                                                                             │
                                                    ┌─── class_idx < 9 <────┘
                                                    │   (继续 S_MUL)
                                                    v
                                              S_DONE <── class_idx == 9
                                                │
                                                v
                                           pred_valid=1
                                           pred_class_id
                                           pred_logit
```

---

## 7. 后处理整体时序分析

### 7.1 Conv1 后 MaxPool 时序

```
  Conv1 输出: 32x32x32 = 1024 像素
  MaxPool 输入: 1024 个 in_valid 脉冲
  MaxPool 输出: 16x16 = 256 个像素 (每个 256-bit)

  时间线:
  ┌──────────────────────────────────────────────────┐
  │ Conv1 计算中...                                   │
  │ MaxPool 等待 in_valid                             │
  └──────────────────────────────────────────────────┘
  ┌──────────────────────────────────────────────────┐
  │ Conv1 结果逐行写出 -> MaxPool in_valid            │
  │ 1024 个周期, 同时 MaxPool 处理                     │
  │ GAP 累加器在此阶段被清零 (clear=1)                 │
  └──────────────────────────────────────────────────┘
```

### 7.2 Conv2 后 MaxPool + GAP 时序

```
  Conv2 输出: 16x16x64 = 256 像素
  MaxPool 输出: 8x8 = 64 像素 (每个 256-bit = 32 通道)
  每个像素分 2 次传输 (addr 偶/奇), 共 128 次 stream_wr_en

  时间线:
  ┌──────────────────────────────────────────────────┐
  │ Conv2 结果逐行写出 -> MaxPool in_valid            │
  │ 256 个周期                                        │
  │ MaxPool 处理并输出 pool_wr_en                      │
  │ gap_fc_logits 通过 stream_wr_en 同步累加           │
  │ 128 次累加 (64 像素 x 2 次/像素)                  │
  └──────────────────────────────────────────────────┘
```

### 7.3 FC 计算时序

```
  ┌──────────────────────────────────────────────────┐
  │ start=1                                           │
  │ gap_sum[] -> gap_feat[] (1 周期)                  │
  │ FC 计算 10 个类别 x 8 周期/类别 = 80 周期         │
  │ + 1 周期 PREP = 81 周期                           │
  │ pred_valid=1, pred_class_id, pred_logit           │
  └──────────────────────────────────────────────────┘
```

### 7.4 从图像输入到预测输出的总延迟

```
  阶段                          周期数         说明
  ─────────────────────────────────────────────────────
  DMA 加载图像                   ~3072         32x32x3 字节
  加载 image_buf                 1024          逐像素复制
  SA RAM 预计算 (Conv1)          1952          26 tile x 75 K
  Conv1 MAC 计算                 ~3224         26 tile x 124
  Conv1 结果写出 + MaxPool       1024          流式处理
  DMA 加载 pool_buf              ~256          从 MaxPool 输出
  SA RAM 预计算 (Conv2)          5602          7 tile x 800 K
  Conv2 MAC 计算 (pass 0)       ~7424         7 tile x 2 x 1060
  Conv2 MAC 计算 (pass 1)       (包含在上行)
  Conv2 结果写出 + MaxPool+GAP  256           流式处理
  FC 计算                        81            10 类别
  ─────────────────────────────────────────────────────
  总计                           ~23,665       约 236us @100MHz
```

---

## 8. 关键知识点总结

```
  ┌─────────────────────────────────────────────────────────────┐
  │ 知识点 1: MaxPool 是流式的, 每个周期处理一个输入像素         │
  │ 知识点 2: 2x2 池化需要缓存左像素和行最大值                   │
  │ 知识点 3: max_vec_i8 并行比较 32 个通道                      │
  │ 知识点 4: GAP 累加与 Conv 计算并行进行, 不增加额外延迟       │
  │ 知识点 5: 64 通道分 2 次传输 (addr 偶/奇)                    │
  │ 知识点 6: GAP 用右移 6 位近似除法 (>>6 = /64)               │
  │ 知识点 7: FC 用 8 级流水线树形归约计算 64 维点积              │
  │ 知识点 8: argmax 边算边比较, 不需要额外周期                  │
  │ 知识点 9: FC 后处理: 右移 7 位 + 偏置 + 饱和                │
  └─────────────────────────────────────────────────────────────┘
```

---

## 9. 动手练习

### 练习 1: MaxPool 输出地址计算

**问题**: 对于 32x32 输入的 MaxPool, 当 `in_row_idx = 135` 时,
计算 `h_idx`, `w_idx`, `pool_h`, `pool_w`。
该像素是否会产生池化输出? 如果是, 输出地址是多少?

```
  提示:
  h_idx = 135 / 32 = ?
  w_idx = 135 % 32 = ?
  pool_h = h_idx >> 1 = ?
  pool_w = w_idx >> 1 = ?
  w_idx[0] = ?  h_idx[0] = ?
  是否处于 (奇数列, 奇数行) 位置?
```

### 练习 2: GAP 累加值范围分析

**问题**: 假设 Conv2+ReLU 输出范围为 [0, 127] (int8),
计算 `gap_sum[ch]` 的最大可能值。右移 6 位后是否会有精度损失?

```
  提示:
  - Conv2+ReLU 输出: [0, 127]
  - 64 个像素累加: max = 64 * 127 = ?
  - 右移 6 位: 8128 >> 6 = ?
  - 饱和到 int8: ?
  - 精度损失: 8128 % 64 = ? (余数被丢弃)
```

### 练习 3: FC 权重存储计算

**问题**: FC 层有 64 个输入和 10 个输出。计算:
1. 权重参数数量
2. 偏置参数数量
3. 总存储量 (字节)
4. 如果用 Block RAM (36Kbit = 4.5KB) 实现, 需要几个 BRAM?

```
  提示:
  权重: 64 * 10 = 640 个 int8
  偏置: 10 个 int8
  总计: 650 字节
```

### 练习 4: 树形归约深度优化

**问题**: 当前 FC 使用 64 -> 32 -> 16 -> 8 -> 4 -> 2 -> 1 的 6 级归约。
如果 CHANNELS 增加到 128, 需要几级归约? 如果增加到 256 呢?
写出通用公式。

```
  提示:
  归约级数 = log2(CHANNELS)
  64:  log2(64)  = 6 级
  128: log2(128) = ? 级
  256: log2(256) = ? 级

  需要增加哪些中间寄存器数组?
```

### 练习 5: 设计 LeakyReLU 替换

**问题**: 当前 MaxPool 使用标准 ReLU (负值截断为 0)。
如果要实现 LeakyReLU (负值乘以 0.125 = 右移 3 位),
修改 `max_vec_i8` 函数或在 MaxPool 之后添加处理逻辑。

```
  LeakyReLU(x) = x >= 0 ? x : x >>> 3

  方案 A: 在 Conv 输出后、MaxPool 前处理
  方案 B: 在 MaxPool 内部修改比较逻辑
  方案 C: 在 stream_wr_en 路径上添加

  哪种方案最简单? 为什么?
```

---

## 10. 扩展阅读

1. **Batch Normalization**: 了解 BN 层如何与卷积/FC 融合减少推理开销
2. **Softmax 层**: 当前输出 raw logits, 如果需要概率分布需要添加 softmax
3. **参考代码**: `src/npu/mac_array_40x32_stream.sv` -- 产生 Conv 输出的 MAC 阵列
4. **参考代码**: `src/npu/dmac_image_sa_writer.sv` -- 消费 pool_buf 的 im2col 模块
5. **CIFAR-10 数据集**: 10 个类别: airplane, automobile, bird, cat, deer, dog, frog, horse, ship, truck
