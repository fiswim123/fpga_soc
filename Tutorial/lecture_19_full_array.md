# Lecture 19: 40x32 完整脉动阵列 -- 规模化与控制

> **目标**: 深入理解 40x32 脉动阵列的硬件架构，掌握子阵列拼接、权重加载、数据馈送与结果收集的完整机制。

> **参考源码**: `src/npu/mac_array_40x32_stream.sv`

---

## 1. 为什么需要 40x32 阵列

### 1.1 从 4x4 到 40x32

在 Lecture 16 中我们学习了卷积到矩阵乘法的映射。一个 Conv1 层的矩阵维度是：

```
  A 矩阵 (im2col):  1024 x 75    (1024个输出像素, 75=3x5x5 个展开元素)
  W 矩阵 (权重):    75 x 32      (75个输入展开, 32个输出通道)
  结果 C = A x W:   1024 x 32    (1024个像素, 32个通道)
```

一个 4x4 子阵列一次只能计算 4x4 = 16 个结果元素。要计算 1024x32 的结果矩阵，
我们需要 **80 个 4x4 子阵列** 按 10 行 x 8 列 排列，覆盖 40 行 x 32 列。

### 1.2 阵列规模计算

```
  子阵列尺寸:     SUB_M = 4 (每个 mm_systolic_4x4 是 4x4)
  目标行数:       TILE_ROWS = 40
  目标列数:       OUT_COLS  = 32

  行方向子阵列组: ROW_GROUPS = TILE_ROWS / SUB_M = 40 / 4 = 10
  列方向子阵列组: COL_GROUPS = OUT_COLS  / SUB_M = 32 / 4 = 8

  子阵列总数:     ROW_GROUPS x COL_GROUPS = 10 x 8 = 80
  PE 总数:        80 x 16 = 1280 个 MAC 单元
```

### 1.3 40x32 阵列的物理布局

```
         列方向 (8 个子阵列组, 共 32 列)
         cg=0     cg=1     cg=2  ...  cg=7
        +--------+--------+--------+--------+
  rg=0  | SA[0]  | SA[1]  | SA[2]  | SA[7]  |  4 行 x 32 列
        +--------+--------+--------+--------+
  rg=1  | SA[8]  | SA[9]  | SA[10] | SA[15] |  4 行 x 32 列
        +--------+--------+--------+--------+
  rg=2  | SA[16] | SA[17] | SA[18] | SA[23] |  4 行 x 32 列
        +--------+--------+--------+--------+
    ...                                            共 10 行子阵列
        +--------+--------+--------+--------+
  rg=9  | SA[72] | SA[73] | SA[74] | SA[79] |  4 行 x 32 列
        +--------+--------+--------+--------+

  总计: 10 x 8 = 80 个 mm_systolic_4x4 实例
  每个 SA 内部: 4x4 PE, 带移位/偏置/ReLU 后处理
```

---

## 设计视角：为什么这样设计？

### 动机分析

在设计脉动阵列时，我们面临的核心问题是：**阵列规模应该多大？** 这个问题没有唯一正确答案，但有明确的设计权衡。

### 关键设计决策

```
  决策 1: 为什么是 40x32 而不是 64x64 或 16x16?

  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │   阵列规模    │   PE 数量     │  BRAM 消耗    │  适配性       │
  ├──────────────┼──────────────┼──────────────┼──────────────┤
  │  16x16       │  256         │  少           │  tile 数过多  │
  │  40x32       │  1280        │  适中         │  Conv1/Conv2  │
  │  64x64       │  4096        │  大量         │  利用率低     │
  │  128x128     │  16384       │  不可接受     │  超出FPGA容量 │
  └──────────────┴──────────────┴──────────────┴──────────────┘

  40x32 的选择理由:
  - 40 行 = Conv1 输出 1024 像素 / 26 tile = 每 tile 40 行, 合理的 tile 粒度
  - 32 列 = Conv1 输出通道数恰好 32, 一次覆盖全部通道
  - 1280 PE 在 Zynq-7020 (53200 LUT) 上可实现
```

### 为什么是 80 个子阵列而非更大的子阵列？

```
  ┌────────────────┬───────────────┬──────────────────────┐
  │   子阵列规模    │   数量         │   设计复杂度          │
  ├────────────────┼───────────────┼──────────────────────┤
  │  4x4           │  10x8 = 80    │  简单, 可复用         │
  │  8x8           │  5x4 = 20     │  PE间连线更长         │
  │  16x16         │  3x2 = 6      │  内部扇出严重         │
  │  40x32 (整体)  │  1            │  不可综合, 验证困难   │
  └────────────────┴───────────────┴──────────────────────┘

  选择 4x4 的原因:
  1. 模块化: 每个 mm_systolic_4x4 独立验证, 可复用
  2. 布局: 4x4 的 PE 间走线短, 时序容易收敛
  3. 参数化: 通过 generate 循环拼接, 修改参数即可缩放
```

### Conv2 的两遍计算 (Two-Pass) 设计约束

```
  为什么 Conv2 需要 2 pass?

  约束: MAC 阵列只有 32 列
  Conv2 输出: 64 通道

  方案对比:
  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 扩展     │  将阵列扩展到 64 列                   │
  │  列宽到 64       │  代价: PE 翻倍, 权重 BRAM 翻倍        │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 两遍     │  第 1 遍算 ch[0..31]                 │
  │  计算 (当前)     │  第 2 遍算 ch[32..63]                │
  │                  │  代价: 时间 x2, 但硬件不变             │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B: 用时间换面积, 阵列利用率在 Conv1 时已经很高
  Conv1 利用率: 40x32 = 1280 PE 全部工作
  Conv2 pass 利用率: 40x32 = 1280 PE 全部工作 (只是做两次)
```

### 面积-性能权衡总结

```
  设计空间探索:

  性能 ──────────────────────────────────────────────►
  │
  │         ┌──────┐
  │         │64x64 │  高性能但面积大
  │         └──────┘
  │
  │    ┌──────────┐
  │    │  40x32   │  ◄── 当前设计: 最佳平衡点
  │    └──────────┘
  │
  │       ┌──────┐
  │       │16x16 │  面积小但 tile 数多
  │       └──────┘
  │
  └────────────────────────────────────────────────► 面积
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 确定计算需求

```
  输入: 神经网络层参数
  - Conv1: 输入 32x32x3, 输出 32x32x32, K=5x5
  - Conv2: 输入 16x16x32, 输出 16x16x64, K=5x5

  计算输出矩阵维度:
  - Conv1 结果矩阵: 1024 x 32  (1024 输出像素, 32 通道)
  - Conv2 结果矩阵: 256 x 64   (256 输出像素, 64 通道)

  确定最小 tile 粒度:
  - 行方向: 每 tile 覆盖 TILE_ROWS 个输出像素
  - 列方向: 每 tile 覆盖 OUT_COLS 个输出通道
```

### 第 2 步: 选择基础 PE 阵列

```
  决策过程:
  ┌─────────────────────────────────────────────────────┐
  │ 1. 选择基础 PE 单元: 4x4 子阵列 (mm_systolic_4x4)   │
  │    理由: 小规模, 易验证, 时序友好                      │
  │                                                     │
  │ 2. 确定输出通道分组: OUT_COLS = 32                    │
  │    理由: Conv1 输出 32 通道, 一次覆盖                 │
  │                                                     │
  │ 3. 确定行分组: TILE_ROWS = 40                        │
  │    理由: 1024 像素 / 40 = 26 tile, 均匀分割          │
  │                                                     │
  │ 4. 计算子阵列数量: 10 行组 x 8 列组 = 80 个           │
  └─────────────────────────────────────────────────────┘
```

### 第 3 步: 设计数据通路

```
  数据流设计:

  行方向 (A 数据):
  im2col 输出 -> 40 lane -> a_col_320b -> 扇出到 80 个 SA

  列方向 (W 数据):
  权重 BRAM -> feed_count 索引 -> w_lane[31:0] -> 扇出到 80 个 SA

  结果方向:
  80 个 SA -> sa_res[rg][cg] -> tile_data -> result_row_data() -> result RAM

  ┌──────────────────────────────────────────────────┐
  │  设计顺序:                                        │
  │  1. 先定义 SA 内部接口 (row_bar, col_bar, res)    │
  │  2. 再设计外部数据打包 (a_col_320b, w_lane)       │
  │  3. 最后设计结果收集和重排                         │
  └──────────────────────────────────────────────────┘
```

### 第 4 步: 设计控制 FSM

```
  FSM 设计过程:
  1. 识别必须的状态: IDLE (等待), FEED (馈送), WAIT (排空)
  2. 添加中间状态: FLUSH (清除累加器)
  3. 定义转移条件: start 脉冲, feed_count 完成, wait_count 到达

  验证要点:
  - FLUSH 到 FEED 的间隔是否足够清除所有累加器?
  - WAIT 的 8 拍是否覆盖所有子阵列的流水线延迟?
  - result_busy 的 40 拍是否覆盖所有 40 行的写出?
```

### 第 5 步: 验证与调优

```
  验证策略:
  1. 单元验证: 先验证单个 mm_systolic_4x4 的正确性
  2. 小规模集成: 用 2x2 子阵列验证扇出和结果收集
  3. 全规模验证: 80 个子阵列完整仿真
  4. 覆盖率: 确保 Conv1 和 Conv2 (含 2 pass) 全部路径覆盖

  调优项:
  - 检查关键路径时序 (扇出最大的信号)
  - 确认 BRAM 综合是否符合预期
  - 验证边界 tile (不足 40 行) 的处理
```

---

## 设计视角：架构模式与原则

### 模式 1: Tile-Based 计算模式

```
  核心思想: 将大规模矩阵运算分割为小 tile, 用固定规模硬件迭代完成

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  大矩阵 C (1024 x 32)                                │
  │  ┌────────────────────────────────────────┐           │
  │  │ tile[0]  40x32 │ tile[1]  40x32 │ ... │           │
  │  ├────────────────┼────────────────┼─────┤           │
  │  │ tile[26]       │ ...            │     │           │
  │  └────────────────────────────────────────┘           │
  │                                                       │
  │  硬件: 固定 40x32 阵列                                 │
  │  软件: 循环 26 次, 每次设置不同的 tile_base_row         │
  │                                                       │
  │  通用公式:                                             │
  │    tile_count = ceil(M / TILE_ROWS)                   │
  │    每 tile 计算 TILE_ROWS x OUT_COLS 个结果            │
  └───────────────────────────────────────────────────────┘

  优势:
  - 硬件规模固定, 与问题规模解耦
  - tile 间独立, 可流水线化
  - 通过参数缩放支持不同网络层

  应用场景:
  - Conv1: 26 tile x 75 K = 1950 周期
  - Conv2: 7 tile x 800 K x 2 pass = 11200 周期
```

### 模式 2: Two-Pass 通道扩展模式

```
  核心思想: 当输出通道数超过阵列列宽时, 分多次计算, 复用同一硬件

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  Conv2: 输出 64 通道, 阵列 32 列                       │
  │                                                       │
  │  Pass 0:  A x W_low  = C_low   (通道 0..31)          │
  │  Pass 1:  A x W_high = C_high  (通道 32..63)         │
  │                                                       │
  │  数据复用:                                             │
  │  - A 矩阵 (im2col): 两次 pass 完全相同                │
  │  - W 矩阵 (权重): 通过 out_pass 选择高低位            │
  │  - 结果: 通过 result_stride 交错写入                   │
  │                                                       │
  │  通用公式:                                             │
  │    pass_count = ceil(OUT_CH / OUT_COLS)               │
  │    每 pass 的 A 数据相同, 只切换 W 数据                 │
  └───────────────────────────────────────────────────────┘

  设计要点:
  - out_pass 信号控制权重 BRAM 的读取偏移
  - result_stride 用于将两次 pass 的结果交错存储
  - 两次 pass 之间的 A 数据可从 SA RAM 缓存读取, 无需重新计算
```

### 原则: 规模与复用的平衡

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 硬件规模应匹配最常见的计算模式              │
  │                                                     │
  │  本设计中:                                           │
  │  - 32 列匹配 Conv1 的 32 输出通道 (最常见情况)       │
  │  - 40 行提供合理的 tile 粒度 (26 个 tile)            │
  │  - 超出部分通过 pass 扩展 (Conv2 的 64 通道)         │
  │                                                     │
  │  反模式: 为最坏情况设计 (64 列)                       │
  │  - Conv1 时 50% 的列闲置                             │
  │  - 面积浪费, 功耗增加                                │
  └─────────────────────────────────────────────────────┘
```

---

## 2. 模块参数与接口

### 2.1 参数列表

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 6-26 行
module mac_array_40x32_stream #(
    parameter string W_FILE    = "conv1.dat",      // Conv1 权重文件
    parameter string W2_FILE   = "conv2.dat",      // Conv2 权重文件
    parameter string BIAS_FILE = "bias1.dat",      // Conv1 偏置文件
    parameter string BIAS2_FILE = "bias2.dat",     // Conv2 偏置文件
    parameter int MAX_DOT_K = 800,                 // 最大 K 维度
    parameter int L1_DOT_K = 75,                   // Conv1 的 K = 3x5x5
    parameter int L2_DOT_K = 800,                  // Conv2 的 K = 32x5x5
    parameter int TILE_ROWS = 40,                  // 每个 tile 的行数
    parameter int OUT_COLS = 32,                   // Conv1 输出通道数
    parameter int L2_OUT_COLS = 64,                // Conv2 输出通道数
    parameter int SUB_M = 4,                       // 子阵列维度
    parameter int ROW_GROUPS = TILE_ROWS / SUB_M,  // = 10
    parameter int COL_GROUPS = OUT_COLS / SUB_M,   // = 8
    parameter int W_AW = 10,                       // 权重地址宽度
    parameter int W_DW = OUT_COLS * 8,             // = 256, 权重数据宽度
    parameter int W2_DW = L2_OUT_COLS * 8,         // = 512, Conv2 权重数据宽度
    parameter int W_ADDR = MAX_DOT_K,              // = 800, 权重深度
    parameter int OUT_ROWS = 1024,                 // 输出 RAM 行数
    parameter int OUT_DW = OUT_COLS * 8,           // = 256, 输出数据宽度
    parameter int OUT_AW = (OUT_ROWS <= 1) ? 1 : $clog2(OUT_ROWS)  // = 10
)
```

### 2.2 接口信号分组

```
  mac_array_40x32_stream 接口
  ┌─────────────────────────────────────────────────────────┐
  │  时钟/复位                                               │
  │    clk, rst_n                                            │
  │                                                         │
  │  控制信号                                                │
  │    start          -- 开始计算脉冲                         │
  │    tile_base_row  -- 结果写入基地址                        │
  │    layer_sel      -- 0=Conv1, 1=Conv2                    │
  │    out_pass       -- Conv2 的通道分组 (0=ch0..31, 1=32..63) │
  │    active_dot_k   -- 当前层的 K 维度                      │
  │    active_out_rows-- 当前 tile 的输出行数                  │
  │    signed_mode    -- 有符号模式                            │
  │    out_shift      -- 输出右移位数                          │
  │    relu_en        -- ReLU 使能                            │
  │                                                         │
  │  A 侧输入 (im2col 数据流)                                │
  │    a_col_valid    -- 输入列有效                            │
  │    a_col_320b     -- 40 个 int8 值 = 320bit               │
  │    a_col_ready    -- 阵列准备好接收                        │
  │                                                         │
  │  输出                                                    │
  │    tile_valid     -- 一个 tile 计算完成                    │
  │    tile_data      -- 40x32 int8 完整结果                   │
  │    result_wr_en   -- 结果 RAM 写使能                      │
  │    result_wr_addr -- 结果 RAM 写地址                      │
  │    result_wr_data -- 结果 RAM 写数据                      │
  │    result_busy    -- 结果正在写出                          │
  │    result_done    -- 结果写出完成                          │
  └─────────────────────────────────────────────────────────┘
```

---

## 3. 权重加载机制

### 3.1 权重存储结构

权重在综合时通过 `$readmemh` 从文件加载到 Block RAM：

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 91-99 行
(* ram_style = "block" *) logic [W_DW-1:0] weight_buf [0:L1_DOT_K-1];   // Conv1: 75 x 256bit
(* ram_style = "block" *) logic [W2_DW-1:0] weight2_buf [0:L2_DOT_K-1]; // Conv2: 800 x 512bit

initial begin
    $readmemh(BIAS_FILE, bias_mem);    // 加载偏置
    $readmemh(BIAS2_FILE, bias2_mem);
    $readmemh(W_FILE, weight_buf);     // 加载权重
    $readmemh(W2_FILE, weight2_buf);
end
```

### 3.2 权重数据格式

```
  Conv1 权重 (weight_buf):
  每行 256 bit = 32 个 int8 值, 对应 32 个输出通道的一个 K 位置

  weight_buf[k][255:0] 的布局:
  ┌──────┬──────┬──────┬─────────────┬──────┐
  │ch[31]│ch[30]│ch[29]│    ...      │ch[ 0]│
  │ 8bit │ 8bit │ 8bit │             │ 8bit │
  └──────┴──────┴──────┴─────────────┴──────┘
   [255]  [247]  [239]                [7:0]

  共 L1_DOT_K = 75 行 (K = 3通道 x 5x5卷积核)
```

### 3.3 权重 lane 解码

每个时钟周期, 从权重 buffer 读取一行, 解码为 32 个 int8 值送给列方向:

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 105-111 行
for (int j = 0; j < OUT_COLS; j = j + 1) begin
    if (layer_sel) begin
        // Conv2: 从 weight2_buf 读取, out_pass 选择高/低 32 通道
        w_lane[j] = $signed(weight2_buf[feed_count][W2_DW-1 - (out_pass*OUT_COLS+j)*8 -: 8]);
    end else begin
        // Conv1: 直接从 weight_buf 读取
        w_lane[j] = $signed(weight_buf[feed_count][W_DW-1 - j*8 -: 8]);
    end
end
```

### 3.4 Conv2 权重的 out_pass 机制

Conv2 有 64 个输出通道, 但阵列只有 32 列。解决方案是分两次 pass:

```
  Conv2 权重 (weight2_buf): 每行 512 bit = 64 个 int8

  out_pass = 0: 取 ch[0..31]   (低 256 位)
  out_pass = 1: 取 ch[32..63]  (高 256 位)

  ┌─────────────────────┬─────────────────────┐
  │  ch[63] .. ch[32]   │  ch[31] .. ch[0]    │  512 bit
  │  out_pass=1 取这部分  │  out_pass=0 取这部分  │
  └─────────────────────┴─────────────────────┘
```

---

## 4. 子阵列实例化

### 4.1 generate 双重循环

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 148-172 行
genvar gi, gj;
generate
    for (gi = 0; gi < ROW_GROUPS; gi = gi + 1) begin : rg_gen
        for (gj = 0; gj < COL_GROUPS; gj = gj + 1) begin : cg_gen
            mm_systolic_4x4 #(
                .DOT_K(MAX_DOT_K)
            ) u_sa (
                .clk(clk),
                .rst_n(rst_n),
                .signed_mode(signed_mode),
                .row_bar(sa_row[gi][gj]),    // 4 个 A 值
                .col_bar(sa_col[gi][gj]),    // 4 个 W 值
                .bar_valid(sa_valid),
                .dot_k(active_dot_k),
                .out_shift(out_shift),
                .bias_vec(sa_bias[gj]),       // 列方向共享偏置
                .relu_en(relu_en),
                .res(sa_res[gi][gj]),         // 4x4 结果
                .res_valid(),
                .flush(flush),
                .add_mode(1'b0),
                .add_compute_valid(1'b0)
            );
        end
    end
endgenerate
```

### 4.2 数据扇出到 80 个子阵列

A 值(行方向)和 W 值(列方向)需要扇出到所有子阵列:

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 129-144 行
for (int rg = 0; rg < ROW_GROUPS; rg = rg + 1) begin
    for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
        // 行方向: 同一组的 4 行在所有列子阵列中共享
        sa_row[rg][cg] = {
            a_lane[rg*SUB_M+0],
            a_lane[rg*SUB_M+1],
            a_lane[rg*SUB_M+2],
            a_lane[rg*SUB_M+3]
        };
        // 列方向: 同一组的 4 列在所有行子阵列中共享
        sa_col[rg][cg] = {
            w_lane[cg*SUB_M+0],
            w_lane[cg*SUB_M+1],
            w_lane[cg*SUB_M+2],
            w_lane[cg*SUB_M+3]
        };
    end
end
```

**关键洞察**: 每个子阵列 `SA[rg][cg]` 接收的行数据来自 `a_lane[rg*4 .. rg*4+3]`,
列数据来自 `w_lane[cg*4 .. cg*4+3]`。这意味着:

```
  SA[rg][cg] 的输出结果 res[rg][cg] 对应:
    行范围: [rg*4 .. rg*4+3]  (全局行)
    列范围: [cg*4 .. cg*4+3]  (全局列 = 输出通道)
```

### 4.3 偏置向量的加载

偏置按列方向共享, 每个列子阵列组有自己的 4 个偏置值:

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 112-128 行
for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
    if (layer_sel) begin
        sa_bias[cg] = {
            bias2_mem[out_pass*OUT_COLS+cg*SUB_M+3],
            bias2_mem[out_pass*OUT_COLS+cg*SUB_M+2],
            bias2_mem[out_pass*OUT_COLS+cg*SUB_M+1],
            bias2_mem[out_pass*OUT_COLS+cg*SUB_M+0]
        };
    end else begin
        sa_bias[cg] = {
            bias_mem[cg*SUB_M+3],
            bias_mem[cg*SUB_M+2],
            bias_mem[cg*SUB_M+1],
            bias_mem[cg*SUB_M+0]
        };
    end
end
```

---

## 5. 状态机与计算流程

### 5.1 四状态 FSM

```
  S_IDLE ──start──> S_FLUSH ──1 clk──> S_FEED ──all K fed──> S_WAIT
    ^                                                            │
    │                                                    8 cycles|
    └────────────────────────────────────────────────────────────┘

  S_IDLE:  等待 start 脉冲
  S_FLUSH: 发送 flush 信号清除子阵列内部累加器
  S_FEED:  逐列馈送 A 数据, 每个时钟一个 K 位置
  S_WAIT:  等待子阵列内部流水线排空 (8 拍延迟)
```

### 5.2 馈送计数器

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 213-220 行
S_FEED: begin
    if (a_col_valid && a_col_ready) begin
        feed_count <= feed_count + 1'b1;
        if (feed_count == W_AW'(active_dot_k - 16'd1)) begin
            wait_count <= '0;
            state <= S_WAIT;
        end
    end
end
```

每个时钟周期, 当 `a_col_valid && a_col_ready` 同时为高:
- `feed_count` 递增
- 权重 buffer 按 `feed_count` 索引读取
- im2col 模块提供对应的 A 列数据

### 5.3 结果收集

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 223-233 行
S_WAIT: begin
    if (wait_count == 4'd8) begin
        // 收集所有子阵列的结果
        for (int rg = 0; rg < ROW_GROUPS; rg = rg + 1) begin
            for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
                tile_data[((rg*COL_GROUPS+cg)*SA_RES_DW) +: SA_RES_DW] <= sa_res[rg][cg];
                result_tile_buf[((rg*COL_GROUPS+cg)*SA_RES_DW) +: SA_RES_DW] <= sa_res[rg][cg];
            end
        end
        tile_valid <= 1'b1;
        // ... 设置结果写回参数
    end else begin
        wait_count <= wait_count + 1'b1;
    end
end
```

**为什么需要等 8 拍?** 子阵列 `mm_systolic_4x4` 内部有:
- 3 级输入延迟线 (行/列数据对齐)
- 1 拍 PE 累加
- 1 拍结果后处理 (移位 + 偏置 + ReLU + 饱和)
- 加上 flush 恢复需要的时间

总计约 8 个时钟周期的排空延迟。

### 5.4 完整时序示例 (Conv1)

```
  时间轴 (时钟周期):
  T=0:  start=1, flush=1
  T=1:  进入 S_FEED
  T=2:  feed k=0, 权重=w[0], A=im2col[0], 80个SA同时计算
  T=3:  feed k=1, 权重=w[1], A=im2col[1]
  ...
  T=76: feed k=74 (最后1个K位置)
  T=77~84: S_WAIT, 等待8拍排空
  T=85: tile_valid=1, 收集 40x32 = 1280 个 int8 结果
  T=86~125: result_busy, 逐行写出 40 行结果到结果 RAM
```

---

## 6. 结果写出机制

### 6.1 行式写出

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 247-260 行
if (result_busy) begin
    if (result_global_row() < result_out_rows) begin
        result_wr_en <= 1'b1;
        result_wr_addr <= OUT_AW'((result_base_row + OUT_AW'(result_wr_row))
                                   * result_stride + result_offset);
        result_wr_data <= result_row_data();
    end

    if (result_wr_row == TILE_ROWS[5:0] - 6'd1) begin
        result_busy <= 1'b0;
        result_done <= 1'b1;
    end else begin
        result_wr_row <= result_wr_row + 6'd1;
    end
end
```

### 6.2 结果重排函数

子阵列结果按 4x4 块存储, 需要重排为行优先格式:

```systemverilog
// 文件: src/npu/mac_array_40x32_stream.sv, 第 270-285 行
function automatic logic [OUT_DW-1:0] result_row_data();
    int rg;
    int rr;
    int bit_base;
    begin
        rg = result_wr_row / SUB_M;          // 子阵列行组索引
        rr = result_wr_row % SUB_M;          // 组内行偏移
        for (int cg = 0; cg < COL_GROUPS; cg = cg + 1) begin
            bit_base = ((rg * COL_GROUPS + cg) * SA_RES_DW) + (rr * SUB_M * 8);
            for (int cc = 0; cc < SUB_M; cc = cc + 1) begin
                result_row_data[(OUT_COLS-1-(cg*SUB_M+cc))*8 +: 8] =
                    result_tile_buf[bit_base + cc*8 +: 8];
            end
        end
    end
endfunction
```

**重排示意**:

```
  子阵列布局 (tile_data):           行优先输出 (result_wr_data):
  ┌─────┬─────┬─────┬─────┐        ┌────────────────────────────────┐
  │S[0] │S[1] │S[2] │S[7] │ row 0  │ ch0 ch1 ch2 ... ch31          │
  │4x4  │4x4  │4x4  │4x4  │        └────────────────────────────────┘
  ├─────┼─────┼─────┼─────┤        每行 32 个 int8 = 256 bit
  │S[8] │S[9] │... │S[15]│ row 1
  └─────┴─────┴─────┴─────┘
```

### 6.3 地址计算

```systemverilog
result_wr_addr = (result_base_row + result_wr_row) * result_stride + result_offset
```

- `result_base_row`: tile 在输出 RAM 中的起始行
- `result_stride`: 行间距 (用于 Conv2 分 pass 写入)
- `result_offset`: 地址偏移

---

## 7. Layer 选择机制

### 7.1 Conv1 vs Conv2 差异

```
  ┌──────────────┬──────────────┬──────────────┐
  │   特性        │   Conv1       │   Conv2       │
  ├──────────────┼──────────────┼──────────────┤
  │ layer_sel    │   0          │   1          │
  │ 权重文件     │ conv1.dat    │ conv2.dat    │
  │ 偏置文件     │ bias1.dat    │ bias2.dat    │
  │ K 维度       │ 75 (3x5x5)  │ 800 (32x5x5) │
  │ 输出通道     │ 32          │ 64 (2 passes) │
  │ 权重宽度     │ 256 bit     │ 512 bit      │
  │ 输入尺寸     │ 32x32x3     │ 16x16x32     │
  │ 输出尺寸     │ 32x32x32    │ 16x16x64     │
  └──────────────┴──────────────┴──────────────┘
```

### 7.2 Conv2 的两次 pass

```
  Conv2 第 1 次 (out_pass=0):
    计算 A(256x800) x W(800x32) = C(256x32)   -- 输出通道 0..31

  Conv2 第 2 次 (out_pass=1):
    计算 A(256x800) x W(800x32) = C(256x32)   -- 输出通道 32..63
    (A 数据相同, 权重取高 32 通道)
```

---

## 8. 资源消耗分析

### 8.1 子阵列资源

每个 `mm_systolic_4x4` 包含:
- 16 个 PE (每个 PE: 1 个乘法器 + 1 个累加器)
- 3 级行/列延迟线 (8 个 8bit 寄存器)
- 后处理: 移位 + 偏置加法 + ReLU + 饱和

### 8.2 整阵列资源估算

```
  80 个子阵列 x 16 PE = 1280 个 MAC 单元
  每个 MAC: 1 个 8x8 乘法器 + 1 个 32 位累加器

  权重存储:
    Conv1: 75 x 256 bit  = 2400 Bytes (BRAM)
    Conv2: 800 x 512 bit = 51200 Bytes (BRAM)

  偏置存储:
    Conv1: 32 x 8 bit    = 32 Bytes
    Conv2: 64 x 8 bit    = 64 Bytes

  结果 Tile 缓冲:
    40 x 32 x 8 bit      = 1280 Bytes (寄存器)
```

---

## 9. 关键知识点总结

```
  ┌─────────────────────────────────────────────────────────────┐
  │ 知识点 1: 80 个 4x4 子阵列组成 40x32 完整阵列               │
  │ 知识点 2: 行方向扇出 A 数据, 列方向扇出 W 数据               │
  │ 知识点 3: 权重通过 $readmemh 在综合时加载到 BRAM             │
  │ 知识点 4: Conv2 通过 out_pass 分两次计算 64 通道             │
  │ 知识点 5: 4 状态 FSM: IDLE->FLUSH->FEED->WAIT               │
  │ 知识点 6: 结果收集需要 8 拍排空等待                          │
  │ 知识点 7: 结果从子阵列块布局重排为行优先格式                  │
  │ 知识点 8: 偏置按列方向共享, 支持 layer_sel 切换              │
  └─────────────────────────────────────────────────────────────┘
```

---

## 10. 动手练习

### 练习 1: 计算 Conv1 的总延迟

**问题**: 假设时钟频率 100MHz, 计算 Conv1 层一个 tile (40 行) 的总延迟。

```
  提示:
  - Conv1 的 K = 75
  - S_FLUSH: 1 周期
  - S_FEED: 75 周期 (每周期馈送 1 个 K)
  - S_WAIT: 8 周期
  - result_busy: 40 周期 (写出 40 行)
  - 总周期数 = ?
  - 延迟 (us) = ?
```

### 练习 2: 分析 Conv2 完整推理延迟

**问题**: Conv2 有 256 个输出行, 需要 7 个 tile (每 tile 40 行, 最后一个 16 行),
每个 tile 需要 2 次 pass。计算 Conv2 层的总周期数。

```
  提示:
  - 每个 tile: S_FLUSH(1) + S_FEED(800) + S_WAIT(8) + result_busy(40) = 849
  - 7 个 tile x 2 次 pass = 14 次计算
  - 总周期数 = ?
```

### 练习 3: 修改阵列规模

**问题**: 如果要设计一个 20x16 的 MAC 阵列 (5x4 个 4x4 子阵列),
需要修改哪些参数? 列出所有受影响的信号和逻辑。

```
  需要修改的参数:
  - TILE_ROWS = ?
  - OUT_COLS = ?
  - ROW_GROUPS = ?
  - COL_GROUPS = ?

  受影响的信号:
  - a_col_320b 的位宽 = ?
  - tile_data 的位宽 = ?
  - w_lane 的位宽 = ?
```

### 练习 4: 分析扇出问题

**问题**: 在 80 个子阵列的架构中, `sa_valid` 信号需要扇出到多少个负载?
这对时序有什么影响? 如何缓解?

```
  提示:
  - sa_valid 连接到 80 个 mm_systolic_4x4 的 bar_valid 端口
  - 每个子阵列内部还有 16 个 PE 的 din_valid
  - 总扇出 = ?
  - 缓解方案: 寄存器复制 (register duplication)
```

---

## 11. 扩展阅读

1. **脉动阵列原理论文**: Google TPU v1 白皮书中的矩阵乘法单元设计
2. **权重预加载**: 了解权重驻留 (weight-stationary) vs 输出驻留 (output-stationary) 数据流
3. **面积优化**: 探索时分复用 (time-multiplexing) 减少 PE 数量的方案
4. **参考代码**: `src/npu/mm_systolic_4x4.sv` -- 子阵列内部 PE 互连与延迟线实现
