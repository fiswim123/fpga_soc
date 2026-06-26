# Lecture 20: NPU 数据准备 -- im2col 与图像写入

> **目标**: 深入理解 NPU 数据通路中的 im2col 变换、SA RAM 写入、tile 调度和 DMA 前端的完整数据流。

> **参考源码**:
> - `src/npu/dmac_im2col_stream.sv`
> - `src/npu/dmac_image_sa_writer.sv`
> - `src/npu/dmac_tile_scheduler.sv`
> - `src/npu/npu_dmac_frontend.sv`

---

## 1. 数据流全景

### 1.1 从 DDR 到 MAC 阵列

```
  ┌─────┐    DMA     ┌─────────┐   load    ┌──────────┐  im2col  ┌───────────┐
  │ DDR │ ────────> │ npu_ram  │ ───────> │ image_buf │ ──────> │ im2col    │
  │     │  AXI burst │ (BRAM)  │  逐像素   │ (Reg)    │  组合逻辑 │ streaming │
  └─────┘           └─────────┘           └──────────┘          └─────┬─────┘
                                                                      │
                                                                      v
  ┌──────────────────┐    req/ack    ┌──────────────────┐    a_col_320b
  │ dmac_tile_       │ <──────────> │ dmac_image_sa_   │ ──────────────>
  │ scheduler        │   k_idx      │ writer           │    (to MAC array)
  └──────────────────┘              └──────────────────┘
        │                                    │
        │ CSR 配置                           │ ram_wr
        v                                    v
  ┌──────────────────┐              ┌──────────────────┐
  │ npu_dmac_        │              │ image_sa RAM     │
  │ frontend         │              │ (预计算的 im2col) │
  └──────────────────┘              └──────────────────┘
```

### 1.2 两条数据路径

本项目有两种 im2col 数据供给模式:

```
  路径 A (SA RAM 预计算):
    DMA → npu_ram → image_buf → im2col → image_sa RAM → MAC 阵列
    (用于 Conv1: 一次性预计算所有 tile 的 im2col 矩阵)

  路径 B (实时流式):
    DMA → npu_ram → image_buf/pool_buf → im2col → MAC 阵列
    (用于 Conv2 或实时模式: 按需计算每个 K 列)
```

---

## 设计视角：为什么这样设计？

### 动机分析

NPU 数据准备模块的核心挑战是：**如何高效地将原始图像数据转换为脉动阵列所需的矩阵格式？** im2col 变换涉及复杂的地址计算，但必须跟上 MAC 阵列每周期一个 K 列的消耗速率。

### 关键设计决策

```
  决策 1: 为什么 im2col 使用组合逻辑而非流水线?

  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 流水线   │  每级 1 拍, 共 3-4 级               │
  │  im2col          │  优点: 时序好, fmax 高              │
  │                  │  缺点: 每次请求 3-4 拍延迟           │
  │                  │        需要复杂的 valid 打包          │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 组合逻辑  │  0 拍延迟, 请求当拍出结果           │
  │  im2col (当前)   │  优点: 接口简单, req_ready 直通      │
  │                  │  缺点: 关键路径长, fmax 受限         │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B 的理由:
  - 100MHz 时钟下组合逻辑延迟可接受 (约 6-8 级逻辑)
  - 与 MAC 阵列的 feed 节奏自然同步
  - 避免流水线握手的复杂性
```

### 为什么需要独立的 SA Writer？

```
  ┌───────────────────────────────────────────────────────┐
  │  为什么不直接流式喂入 MAC 阵列?                         │
  │                                                       │
  │  直接喂入的问题:                                       │
  │  - Conv1 有 26 个 tile, 每个 tile 的 im2col 不同      │
  │  - MAC 阵列切换 tile 时需要 flush + 重新馈送           │
  │  - 中间的 tile 切换间隙无法掩盖                        │
  │                                                       │
  │  预计算到 SA RAM 的优势:                               │
  │  - 所有 tile 的 im2col 一次性计算完成                  │
  │  - MAC 阵列连续读取 SA RAM, 无停顿                    │
  │  - DMAC 和 MAC 可以完全解耦                            │
  └───────────────────────────────────────────────────────┘

  代价: 需要 224KB 的 SA RAM 存储预计算结果
  权衡: 用存储换吞吐, 确保 MAC 阵列 100% 利用率
```

### 两条数据路径的设计考量

```
  路径 A (SA RAM 预计算): Conv1 专用
  ┌──────────────────────────────────────────┐
  │ DMA → npu_ram → image_buf → im2col      │
  │        → SA RAM → MAC 阵列              │
  │                                          │
  │ 特点: 一次性预计算所有 tile               │
  │ 延迟: DMAC ~1950 周期 + MAC ~3224 周期   │
  │ 优势: MAC 阵列连续工作, 无数据饥饿        │
  └──────────────────────────────────────────┘

  路径 B (实时流式): Conv2 专用
  ┌──────────────────────────────────────────┐
  │ DMA → npu_ram → pool_buf → im2col       │
  │        → MAC 阵列 (逐 K 列)              │
  │                                          │
  │ 特点: 按需计算, 每次一个 K 列             │
  │ 延迟: 与 MAC 计算重叠                    │
  │ 优势: 无需额外 SA RAM (Conv2 数据量大)   │
  └──────────────────────────────────────────┘
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 定义 im2col 变换的数学接口

```
  输入: (row_base, k_idx)
  输出: a_col_320b = 40 个 int8 值

  变换公式:
    for lane in 0..39:
      row = row_base + lane
      oh  = row / out_w
      ow  = row % out_w
      ch  = k_idx / (K * K)
      kh  = (k_idx % (K * K)) / K
      kw  = k_idx % K
      ih  = oh + kh - pad
      iw  = ow + kw - pad
      if in_bounds(ih, iw):
        output[lane] = feature_map[ch][ih][iw]
      else:
        output[lane] = 0

  设计要点: 先写纯数学公式, 再映射到硬件
```

### 第 2 步: 设计缓冲区结构

```
  缓冲区需求分析:

  ┌─────────────────────────────────────────────────────┐
  │  输入数据特征:                                       │
  │  - Conv1: 32x32x3 = 3072 字节 = 1024 像素 x 24bit  │
  │  - Conv2: 16x16x32 = 8192 字节 = 256 像素 x 256bit │
  │                                                     │
  │  设计选择: 两个独立缓冲区                            │
  │  - image_buf: 1024 x 24bit (Conv1 专用)            │
  │  - pool_buf:  256 x 256bit (Conv2 专用)            │
  │                                                     │
  │  为什么不用统一缓冲区?                               │
  │  - 数据格式不同 (24bit vs 256bit)                   │
  │  - 访问模式不同 (3 通道 vs 32 通道)                 │
  │  - 生命周期不同 (Conv1 vs Conv2 之后)               │
  └─────────────────────────────────────────────────────┘
```

### 第 3 步: 设计地址计算逻辑

```
  地址计算的层次化分解:

  层次 1: 线性索引 → 坐标
    row → (oh, ow)    除法和取模
    k_idx → (ch, kh, kw)  除法和取模

  层次 2: 坐标 → 物理地址
    (ch, ih, iw) → pixel_idx = ih * W + iw

  层次 3: 物理地址 → 数据值
    pixel_idx → image_buf[pixel_idx] → 通道选择

  硬件映射:
  - 层次 1 和 2 用组合逻辑 (加减乘除)
  - 层次 3 用寄存器文件读取 + MUX
```

### 第 4 步: 设计写入流水线

```
  SA Writer 流水线设计:

  T=0: issue_addr 递增, 发出 req_valid
       │
       v
  T=1: im2col 组合逻辑计算 (req → out 延迟 1 拍)
       │
       v
  T=2: out_valid 有效, pack_image_sa 打包
       ram_wr 有效, 写入 SA RAM

  流水线深度: 2 级 (请求 + 计算)
  吞吐: 1 个地址/周期 (流水线满载后)
  总延迟: SA_ROWS + 2 周期
```

### 第 5 步: 验证与集成

```
  验证策略:
  1. 单元验证: 验证 get_lane_data 函数的地址计算正确性
  2. 边界测试: padding 区域、图像边界、通道边界
  3. 集成验证: SA Writer + im2col + MAC 阵列联合仿真
  4. 覆盖率: 确保 Conv1 和 Conv2 的所有 tile 路径覆盖

  关键检查点:
  - pack_image_sa 的位序反转是否正确
  - SA RAM 地址是否与 MAC 阵列的 feed_count 对齐
  - 加载 FSM 的 ld_idx 是否正确映射到 npu_ram 地址
```

---

## 设计视角：架构模式与原则

### 模式 1: 零延迟变换模式 (Zero-Latency Transform)

```
  核心思想: 用组合逻辑实现地址变换, 请求当拍即得结果

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  req (row_base, k_idx) ──┐                           │
  │                          │ 组合逻辑                    │
  │                          ▼                            │
  │  ┌──────────────────────────────────────┐             │
  │  │ 40 路并行地址计算                      │             │
  │  │ lane[0]: row=rb+0, oh, ow, ch, ih, iw│             │
  │  │ lane[1]: row=rb+1, oh, ow, ch, ih, iw│             │
  │  │ ...                                  │             │
  │  │ lane[39]: row=rb+39, ...             │             │
  │  └──────────────┬───────────────────────┘             │
  │                 │                                     │
  │                 ▼                                     │
  │  out (a_col_320b) ← 当拍输出, 0 周期延迟              │
  │                                                       │
  │  代价: 组合逻辑深度约 6-8 级                           │
  │  收益: 接口极简, 无需 valid/ready 流水线管理           │
  └───────────────────────────────────────────────────────┘

  适用场景:
  - 变换逻辑不太复杂 (除法/取模可用移位代替)
  - 时钟频率不高 (100MHz 以下)
  - 需要与下游严格同步 (每周期一个 K 列)
```

### 模式 2: 流式写入器模式 (Streaming Writer)

```
  核心思想: 写入器独立遍历所有地址, 自动产生请求序列

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  SA Writer 状态机:                                    │
  │                                                       │
  │  S_IDLE ──start──> S_RUN ──done──> S_DRAIN ──> S_DONE│
  │                       │               │              │
  │                       ▼               ▼              │
  │                  issue_addr      等待流水线排空       │
  │                  0 → SA_ROWS                        │
  │                       │                              │
  │                       ▼                              │
  │               req_valid ──> im2col ──> ram_wr        │
  │                                                       │
  │  地址生成公式:                                         │
  │    row_base = (addr / K_LEN) * TILE_ROWS             │
  │    k_idx    = addr % K_LEN                           │
  │                                                       │
  │  优势: 地址生成与数据计算解耦                          │
  │  写入器只关心 "下一个地址是什么"                        │
  │  im2col 模块只关心 "给定地址如何变换"                   │
  └───────────────────────────────────────────────────────┘

  通用化:
  - 修改 SA_ROWS、K_LEN、TILE_ROWS 参数即可适配不同层
  - layer_sel 切换 image_buf / pool_buf 数据源
```

### 原则: 预计算与实时计算的选择

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 当数据可完全缓存时, 预计算优于实时计算     │
  │                                                     │
  │  判断标准:                                           │
  │  1. 数据量是否能放入本地存储?                        │
  │     Conv1: 1024 像素 x 24bit = 3KB → 可以           │
  │     Conv2: 256 像素 x 256bit = 8KB → 可以           │
  │                                                     │
  │  2. 预计算时间是否可接受?                             │
  │     Conv1: 1950 周期 (远小于 MAC 的 3224 周期)       │
  │     Conv2: 5600 周期 (与 MAC 的 11200 周期可比)      │
  │                                                     │
  │  3. 预计算是否能消除停顿?                             │
  │     是: MAC 阵列从 SA RAM 读取, 无数据饥饿           │
  │                                                     │
  │  结论: 预计算策略适用于本设计的存储/计算比             │
  └─────────────────────────────────────────────────────┘
```

---

## 2. dmac_im2col_stream -- 组合逻辑 im2col 变换

### 2.1 模块功能

这个模块是整个数据通路的核心。它接收一个 `(row_base, k_idx)` 请求,
在同一周期内通过组合逻辑计算出 40 个像素在该 K 位置的 im2col 值。

```
  输入:  req_valid + (row_base, k_idx)
  输出:  a_col_320b = { A[row_base+39][k_idx], ..., A[row_base+0][k_idx] }

  其中 A[row][k] 是 im2col 矩阵的元素:
    row = oh * W_out + ow  (输出像素的线性索引)
    k   = ch * K*K + kh * K + kw  (卷积核展开索引)
```

### 2.2 参数配置

```systemverilog
// 文件: src/npu/dmac_im2col_stream.sv, 第 8-18 行
module dmac_im2col_stream #(
    parameter string IMAGE_DATA_FILE = "image_data.dat",
    parameter int LANE_NUM = 40,           // 并行 lane 数 = TILE_ROWS
    parameter int MAX_IMG_W = 32,          // 最大图像宽度
    parameter int MAX_IMG_H = 32,          // 最大图像高度
    parameter int MAX_POOL_W = 16,         // 最大池化后宽度
    parameter int MAX_POOL_H = 16,         // 最大池化后高度
    parameter int MAX_POOL_CH = 32,        // 最大池化后通道数
    parameter int PIXEL_AW = 10,           // 像素地址宽度
    parameter int POOL_PIXEL_AW = 8        // 池化像素地址宽度
)
```

### 2.3 两个特征图缓冲区

```systemverilog
// 文件: src/npu/dmac_im2col_stream.sv, 第 58-59 行
logic [23:0] image_buf [0:(MAX_IMG_W*MAX_IMG_H)-1];      // 32x32 = 1024 像素, 每像素 24bit (RGB)
logic [MAX_POOL_CH*8-1:0] pool_buf [0:(MAX_POOL_W*MAX_POOL_H)-1];  // 16x16 = 256 像素, 每像素 256bit (32ch)
```

```
  image_buf (Conv1 输入):
  ┌────────────────────────────────────┐
  │ pixel[0] = {R[7:0], G[7:0], B[7:0]} │  24 bit per pixel
  │ pixel[1] = {R, G, B}                │  共 1024 个像素
  │ ...                                  │
  │ pixel[1023]                         │
  └────────────────────────────────────┘

  pool_buf (Conv2 输入, MaxPool 后的特征图):
  ┌────────────────────────────────────┐
  │ pixel[0] = {ch31, ch30, ..., ch0}  │  256 bit per pixel
  │ pixel[1] = {ch31, ..., ch0}        │  共 256 个像素
  │ ...                                 │
  │ pixel[255]                          │
  └────────────────────────────────────┘
```

### 2.4 加载 FSM (npu_ram -> image_buf)

```systemverilog
// 文件: src/npu/dmac_im2col_stream.sv, 第 62-100 行
typedef enum logic [1:0] { LD_IDLE, LD_READ, LD_DONE } ld_state_t;
ld_state_t ld_state;
logic [9:0] ld_idx;   // pixel index 0~1023

assign load_done = (ld_state == LD_DONE);
assign req_ready = (ld_state == LD_DONE) || (ld_state == LD_IDLE && !load_start);

// 驱动 npu_ram 读地址
assign pixel_rd_addr = (ld_state == LD_READ) ? {22'd0, ld_idx, 2'd0} : 32'd0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ld_state <= LD_IDLE;
        ld_idx   <= 10'd0;
    end else begin
        unique case (ld_state)
            LD_IDLE: begin
                ld_idx <= 10'd0;
                if (load_start) ld_state <= LD_READ;
            end
            LD_READ: begin
                image_buf[ld_idx] <= pixel_rd_data[23:0];  // 低 24 位 = RGB
                if (ld_idx == (MAX_IMG_W*MAX_IMG_H - 1))
                    ld_state <= LD_DONE;
                ld_idx <= ld_idx + 10'd1;
            end
            LD_DONE: begin
                if (load_start) ld_state <= LD_READ;  // 支持重新加载
            end
        endcase
    end
end
```

**加载时序**:
```
  T=0:  load_start=1, ld_state -> LD_READ, ld_idx=0
  T=1:  pixel_rd_addr=0x00, 读取 pixel 0
  T=2:  latch pixel[0], ld_idx=1, pixel_rd_addr=0x04
  T=3:  latch pixel[1], ld_idx=2, pixel_rd_addr=0x08
  ...
  T=1024: latch pixel[1023], ld_state -> LD_DONE, load_done=1
```

### 2.5 im2col 组合逻辑 -- get_lane_data 函数

这是最核心的函数, 实现了 im2col 变换的地址计算:

```systemverilog
// 文件: src/npu/dmac_im2col_stream.sv, 第 122-165 行
function automatic logic [7:0] get_lane_data(input int lane);
    int row, oh, ow, ch, rem, kh, kw, ih, iw, pixel_idx;
    logic [23:0] pixel;
    logic [MAX_POOL_CH*8-1:0] word;
    begin
        // 1. 从 lane 索引计算输出像素坐标
        row = row_base + lane;
        oh = row / cfg_in_w;        // 输出行
        ow = row % cfg_in_w;        // 输出列

        // 2. 从 k_idx 解码卷积核坐标
        ch = k_idx / (cfg_kernel * cfg_kernel);      // 输入通道
        rem = k_idx % (cfg_kernel * cfg_kernel);
        kh = rem / cfg_kernel;                        // 核行
        kw = rem % cfg_kernel;                        // 核列

        // 3. 计算输入坐标 (带 padding)
        ih = oh + kh - cfg_pad;
        iw = ow + kw - cfg_pad;

        // 4. 边界检查 (padding 区域填零)
        if ((row >= (cfg_in_w * cfg_in_h)) ||
            (ch >= cfg_in_ch) ||
            (ih < 0) || (ih >= cfg_in_h) ||
            (iw < 0) || (iw >= cfg_in_w)) begin
            get_lane_data = 8'd0;        // padding zero
        end

        // 5. 从对应 buffer 读取数据
        else if (!layer_sel) begin       // Conv1: 从 image_buf
            pixel_idx = ih * cfg_in_w + iw;
            pixel = image_buf[pixel_idx];
            unique case (ch)
                0: get_lane_data = pixel[23:16];  // R
                1: get_lane_data = pixel[15:8];   // G
                default: get_lane_data = pixel[7:0]; // B
            endcase
        end else begin                   // Conv2: 从 pool_buf
            pixel_idx = ih * cfg_in_w + iw;
            word = pool_buf[pixel_idx];
            get_lane_data = word[(MAX_POOL_CH-1-ch)*8 +: 8];
        end
    end
endfunction
```

### 2.6 im2col 地址计算详解

以 Conv1 为例, K=5, P=2, 输入 32x32x3:

```
  给定: row_base=0, k_idx=12, cfg_kernel=5, cfg_pad=2

  解码 k_idx:
    ch  = 12 / 25 = 0       (通道 0 = R)
    rem = 12 % 25 = 12
    kh  = 12 / 5  = 2       (核行 2)
    kw  = 12 % 5  = 2       (核列 2)

  对于 lane=0 (第 0 个输出像素):
    row = 0, oh = 0/32 = 0, ow = 0%32 = 0
    ih = 0 + 2 - 2 = 0
    iw = 0 + 2 - 2 = 0
    pixel_idx = 0*32 + 0 = 0
    取 image_buf[0] 的 R 通道 (pixel[23:16])

  对于 lane=1 (第 1 个输出像素):
    row = 1, oh = 0, ow = 1
    ih = 0 + 2 - 2 = 0
    iw = 1 + 2 - 2 = 1
    pixel_idx = 0*32 + 1 = 1
    取 image_buf[1] 的 R 通道

  对于 lane=32 (第 33 个输出像素):
    row = 32, oh = 1, ow = 0
    ih = 1 + 2 - 2 = 1
    iw = 0 + 2 - 2 = 0
    pixel_idx = 1*32 + 0 = 32
    取 image_buf[32] 的 R 通道
```

### 2.7 Padding 处理

```
  输入 5x5 卷积, padding=2:

  原始输入 (32x32):
  ┌────────────────────────────────┐
  │                                │
  │     实际像素区域                │
  │                                │
  └────────────────────────────────┘

  带 padding 的逻辑视图:
  ┌──────────────────────────────────────┐
  │ 0  0  0  0  0  0  0 ... 0  0  0  0 │  ← pad=2, 上边填零
  │ 0  0  0  0  0  0  0 ... 0  0  0  0 │
  │ 0  0  P  P  P  P  P ... P  P  0  0 │  ← 实际像素
  │ 0  0  P  P  P  P  P ... P  P  0  0 │
  │ ...                                  │
  │ 0  0  P  P  P  P  P ... P  P  0  0 │
  │ 0  0  0  0  0  0  0 ... 0  0  0  0 │
  │ 0  0  0  0  0  0  0 ... 0  0  0  0 │  ← pad=2, 下边填零
  └──────────────────────────────────────┘

  当 ih < 0 || ih >= 32 || iw < 0 || iw >= 32 时, 返回 0
```

### 2.8 40 lane 并行计算

```systemverilog
// 文件: src/npu/dmac_im2col_stream.sv, 第 113-119 行
if (req_valid && req_ready) begin
    for (int lane = 0; lane < LANE_NUM; lane = lane + 1) begin
        a_col_320b[lane*8 +: 8] <= get_lane_data(lane);
    end
    out_valid <= 1'b1;
end
```

**关键**: 40 个 `get_lane_data` 调用是**并行**的组合逻辑。
每个调用独立计算自己的 `(oh, ow, ch, kh, kw, ih, iw)` 并读取对应的 buffer 元素。
这在硬件上表现为 40 套独立的地址计算和多路选择器。

---

## 3. dmac_image_sa_writer -- SA RAM 写入器

### 3.1 模块功能

这个模块驱动 im2col 流, 将结果写入 SA RAM, 供 MAC 阵列后续读取。

```
  dmac_image_sa_writer
  ┌───────────────────────────────────────────────┐
  │                                               │
  │  start ──> 状态机遍历所有 (tile, k) 组合      │
  │            │                                   │
  │            v                                   │
  │  ┌─────────────────┐    req    ┌────────────┐ │
  │  │ issue_addr 计算  │ ────────> │ im2col     │ │
  │  │ tile_idx, k_idx │          │ stream     │ │
  │  └─────────────────┘          └─────┬──────┘ │
  │                                     │        │
  │                                     v        │
  │                              ┌──────────────┐│
  │                              │ pack_image_  ││
  │                              │ sa (位反转)   ││
  │                              └──────┬───────┘│
  │                                     │        │
  │                                     v        │
  │                              ┌──────────────┐│
  │                              │ SA RAM 写入   ││
  │                              └──────────────┘│
  └───────────────────────────────────────────────┘
```

### 3.2 参数与层配置

```systemverilog
// 文件: src/npu/dmac_image_sa_writer.sv, 第 8-27 行
parameter int L1_IMG_ROWS = 1024,   // Conv1 输出像素数 (32x32)
parameter int L1_K_LEN    = 75,     // Conv1 K 维度 (3x5x5)
parameter int L1_IMG_W    = 32,
parameter int L1_IMG_H    = 32,
parameter int L1_IMG_CH   = 3,
parameter int L1_KERNEL   = 5,
parameter int L1_PAD      = 2,
parameter int L2_IMG_ROWS = 256,     // Conv2 输出像素数 (16x16)
parameter int L2_K_LEN    = 800,     // Conv2 K 维度 (32x5x5)
parameter int L2_IMG_W    = 16,
parameter int L2_IMG_H    = 16,
parameter int L2_IMG_CH   = 32,
parameter int L2_KERNEL   = 5,
parameter int L2_PAD      = 2,
```

### 3.3 SA RAM 行数计算

```
  SA_ROWS = ceil(IMG_ROWS / TILE_ROWS) * K_LEN

  Conv1: SA_ROWS = ceil(1024/40) * 75  = 26 * 75  = 1950
  Conv2: SA_ROWS = ceil(256/40)  * 800 = 7  * 800 = 5600

  每个 SA RAM 行存储 40 个 int8 值 (320 bit)
```

### 3.4 地址生成

```systemverilog
// 文件: src/npu/dmac_image_sa_writer.sv, 第 81-83 行
assign row_base = 10'((issue_addr / active_k_len) * TILE_ROWS);
assign k_idx = 10'(issue_addr % active_k_len);
assign req_valid = (state == S_RUN) && (issue_addr < active_sa_rows);
```

**地址遍历顺序**:

```
  issue_addr: 0, 1, 2, ..., K_LEN-1, K_LEN, K_LEN+1, ...

  对于 Conv1 (K_LEN=75):
  issue_addr=0:   tile=0, k=0    (第0个tile, 第0个K位置)
  issue_addr=1:   tile=0, k=1
  ...
  issue_addr=74:  tile=0, k=74
  issue_addr=75:  tile=1, k=0    (第1个tile, 第0个K位置)
  issue_addr=76:  tile=1, k=1
  ...
  issue_addr=1949: tile=25, k=74  (最后一个tile, 最后一个K)

  SA RAM 布局:
  ┌─────────────────────────────────────────┐
  │ addr 0..74:    tile 0, k=0..74          │
  │ addr 75..149:  tile 1, k=0..74          │
  │ ...                                     │
  │ addr 1875..1949: tile 25, k=0..74       │
  └─────────────────────────────────────────┘
```

### 3.5 数据打包 -- pack_image_sa

```systemverilog
// 文件: src/npu/dmac_image_sa_writer.sv, 第 114-122 行
function automatic logic [TILE_ROWS*8-1:0] pack_image_sa(
    input logic [TILE_ROWS*8-1:0] lane_lsb
);
    begin
        for (int lane = 0; lane < TILE_ROWS; lane = lane + 1) begin
            pack_image_sa[TILE_ROWS*8-1 - lane*8 -: 8] = lane_lsb[lane*8 +: 8];
        end
    end
endfunction
```

**位序反转**:

```
  im2col 输出 (lane_lsb):             SA RAM 存储 (pack_image_sa):
  [7:0]=lane0, [15:8]=lane1, ...      [319:312]=lane0, [311:304]=lane1, ...
  [319:312]=lane39                     [7:0]=lane39

  即: lane_lsb[lane*8 +: 8]  -->  pack_image_sa[(39-lane)*8 +: 8]

  原因: MAC 阵列的 a_col_320b 格式要求高位对应较小的行索引
```

### 3.6 写入流水线

```systemverilog
// 文件: src/npu/dmac_image_sa_writer.sv, 第 149-158 行
if (req_valid && req_ready) begin
    issue_addr_d <= issue_addr;       // 保存地址 (1拍延迟)
    issue_valid_d <= 1'b1;
end

if (out_valid && issue_valid_d) begin
    ram_wr <= 1'b1;
    ram_waddr <= issue_addr_d;        // 延迟1拍的地址
    ram_wdata <= pack_image_sa(a_col_lsb);  // 打包后的数据
end
```

**流水线时序**:
```
  T=0: issue_addr=0, req_valid=1 -> im2col 开始计算
  T=1: issue_addr_d=0, im2col 计算中 (组合逻辑)
  T=2: out_valid=1, ram_wr=1, ram_waddr=0, 写入 SA RAM
  T=3: out_valid=0 (下一拍), 同时 issue_addr=1 的请求已发出
  ...
```

### 3.7 状态机

```systemverilog
// 文件: src/npu/dmac_image_sa_writer.sv, 第 160-214 行
unique case (state)
    S_IDLE: begin
        busy <= 1'b0;
        if (start) begin
            busy <= 1'b1;
            issue_addr <= '0;
            // 根据 layer_sel 加载对应层的参数
            if (layer_sel) begin
                active_img_rows <= 10'(L2_IMG_ROWS);
                active_k_len <= 10'(L2_K_LEN);
                // ...
            end else begin
                active_img_rows <= 10'(L1_IMG_ROWS);
                active_k_len <= 10'(L1_K_LEN);
                // ...
            end
            state <= S_RUN;
        end
    end

    S_RUN: begin
        if (req_valid && req_ready) begin
            issue_addr <= issue_addr + SA_AW'(1);
            if (issue_addr == active_sa_rows - SA_AW'(1)) begin
                state <= S_DRAIN;     // 最后一个请求发出
            end
        end
    end

    S_DRAIN: begin
        if (!out_valid && !issue_valid_d) begin
            state <= S_DONE;          // 流水线排空
        end
    end

    S_DONE: begin
        busy <= 1'b0;
        done <= 1'b1;
        state <= S_IDLE;
    end
endcase
```

---

## 4. dmac_tile_scheduler -- Tile 调度器

### 4.1 模块功能

调度器负责向 im2col 模块发送 `k_idx = 0, 1, ..., k_len-1` 的请求序列,
并收集返回的 `a_col_320b` 数据流。

```systemverilog
// 文件: src/npu/dmac_tile_scheduler.sv, 第 6-8 行
// Schedules one im2col tile for the 40-row SA input.
// After start, it issues k_idx=0..k_len-1.
```

### 4.2 请求/响应流水线

```
  调度器                          im2col 模块
  ┌──────────┐   req_valid        ┌──────────┐
  │ issue_k  │ ────────────────> │ get_lane │
  │ 计数器    │   dmac_req_ready  │ _data()  │
  │          │ <──────────────── │ (组合)    │
  └──────────┘                    └────┬─────┘
       ^                               │
       │ dmac_out_valid                │ dmac_a_col
       │                               v
  ┌──────────┐                    a_col_320b
  │ rsp_k    │
  │ 计数器    │
  └──────────┘
```

### 4.3 请求侧逻辑

```systemverilog
// 文件: src/npu/dmac_tile_scheduler.sv, 第 43-44 行
assign dmac_row_base = cfg_row_base;
assign dmac_k_idx = issue_k;
assign dmac_req_valid = (state == S_RUN) && (issue_k < cfg_k_len);
```

### 4.4 响应侧逻辑

```systemverilog
// 文件: src/npu/dmac_tile_scheduler.sv, 第 59-63 行
if (dmac_out_valid) begin
    out_valid <= 1'b1;
    a_col_320b <= dmac_a_col;
    out_k_idx <= rsp_k;
    rsp_k <= rsp_k + 10'd1;
end
```

### 4.5 完成条件

```systemverilog
// 文件: src/npu/dmac_tile_scheduler.sv, 第 81-83 行
if ((rsp_k == cfg_k_len) && (issue_k == cfg_k_len)) begin
    state <= S_DONE;
end
```

**关键**: 必须等待**所有请求发出** (`issue_k == cfg_k_len`) 且**所有响应收到**
(`rsp_k == cfg_k_len`) 才能标记完成。这允许请求和响应之间有流水线延迟。

### 4.6 流水线深度分析

```
  周期:   T0    T1    T2    T3    T4    T5    ...
  issue_k: 0     1     2     3     4     5    ...
  rsp_k:   -     -     0     1     2     3    ...

  请求发出后约 2 个周期收到响应 (取决于 im2col 的组合逻辑延迟)
  最优吞吐: 每周期 1 个 K 列 (流水线满载时)
```

---

## 5. npu_dmac_frontend -- CSR 可配置前端

### 5.1 模块功能

这是顶层集成模块, 将 CSR 寄存器、调度器和 im2col 模块连接在一起。

```systemverilog
// 文件: src/npu/npu_dmac_frontend.sv, 第 3-4 行
// CSR-configurable DMAC frontend for the 40x32 systolic array A side.
```

### 5.2 内部子模块连接

```
  npu_dmac_frontend
  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  CSR 总线 ──> npu_csr_regs ──> 配置参数                 │
  │   (csr_wr_en,                  │                        │
  │    csr_rd_en,                  v                        │
  │    csr_addr,        ┌─────────────────────┐             │
  │    csr_wdata,       │ start_pulse         │             │
  │    csr_rdata)       │ layer_sel           │             │
  │                     │ cfg_in_w, cfg_in_h  │             │
  │                     │ cfg_in_ch           │             │
  │                     │ cfg_kernel, cfg_pad │             │
  │                     │ cfg_row_base        │             │
  │                     │ cfg_k_len           │             │
  │                     └────────┬────────────┘             │
  │                              │                          │
  │                              v                          │
  │  ┌─────────────────────────────────────────────┐       │
  │  │ dmac_tile_scheduler                          │       │
  │  │   start ──> 逐 k 发请求                      │       │
  │  │   dmac_req_valid/ready ──> im2col            │       │
  │  │   dmac_out_valid <── im2col 结果              │       │
  │  │   out_valid/a_col_320b ──> 输出               │       │
  │  └─────────────────┬───────────────────────────┘       │
  │                    │                                    │
  │                    v                                    │
  │  ┌─────────────────────────────────────────────┐       │
  │  │ dmac_im2col_stream                           │       │
  │  │   req_valid/ready <── scheduler              │       │
  │  │   layer_sel ──> 选择 image_buf 或 pool_buf   │       │
  │  │   out_valid/a_col_320b ──> 输出               │       │
  │  └─────────────────────────────────────────────┘       │
  │                                                         │
  │  输出:                                                  │
  │    a_col_valid, a_col_320b ──> MAC 阵列                 │
  │    busy, done                                           │
  └─────────────────────────────────────────────────────────┘
```

### 5.3 CSR 寄存器映射

通过 `npu_csr_regs` 模块暴露的寄存器:

```
  ┌──────────────┬─────────┬─────────────────────────────┐
  │ 寄存器        │ 偏移    │ 说明                         │
  ├──────────────┼─────────┼─────────────────────────────┤
  │ CTRL         │ 0x00    │ [0]=start, [1]=layer_sel     │
  │ CFG_IN_W     │ 0x04    │ 输入宽度 (默认32或16)         │
  │ CFG_IN_H     │ 0x08    │ 输入高度                      │
  │ CFG_IN_CH    │ 0x0C    │ 输入通道数 (3或32)            │
  │ CFG_KERNEL   │ 0x10    │ 卷积核大小 (5)                │
  │ CFG_PAD      │ 0x14    │ Padding (2)                  │
  │ CFG_ROW_BASE │ 0x18    │ 当前 tile 的行基地址          │
  │ CFG_K_LEN    │ 0x1C    │ K 维度长度                    │
  │ STATUS       │ 0x20    │ [0]=busy, [1]=done           │
  └──────────────┴─────────┴─────────────────────────────┘
```

---

## 6. 完整数据流时序

### 6.1 Conv1 数据准备时序

```
  阶段 1: DMA 加载图像到 npu_ram
  ┌──────────────────────────────────────────────────┐
  │ CPU 配置 DMA 控制器                               │
  │ DMA 从 DDR 读取 32x32x3 = 3072 字节              │
  │ DMA 写入 npu_ram (地址 0x0000 ~ 0x0BFF)          │
  └──────────────────────────────────────────────────┘

  阶段 2: 加载 image_buf
  ┌──────────────────────────────────────────────────┐
  │ load_start=1                                      │
  │ 逐像素从 npu_ram 读取到 image_buf                 │
  │ 1024 个像素, 每周期 1 个, 共 1024 周期            │
  │ load_done=1                                       │
  └──────────────────────────────────────────────────┘

  阶段 3: 预计算 SA RAM (image_sa_writer)
  ┌──────────────────────────────────────────────────┐
  │ start=1                                           │
  │ 遍历 26 个 tile x 75 个 K = 1950 个地址          │
  │ 每个地址: im2col 组合逻辑 + 写入 SA RAM           │
  │ 约 1950 + 2 (流水线) = ~1952 周期                 │
  │ done=1                                            │
  └──────────────────────────────────────────────────┘

  阶段 4: MAC 阵列计算 (逐 tile)
  ┌──────────────────────────────────────────────────┐
  │ 对于每个 tile (共 26 个):                          │
  │   从 SA RAM 读取 75 列 x 320bit                   │
  │   逐列喂入 mac_array_40x32_stream                 │
  │   每列 1 周期, 共 75 + 1(flush) + 8(wait) = 84   │
  │   + 40 (result write) = 124 周期/tile             │
  │ 总计: 26 x 124 = ~3224 周期                       │
  └──────────────────────────────────────────────────┘
```

### 6.2 Conv2 数据准备时序

```
  Conv2 使用 pool_buf (16x16x32), 由 PPU MaxPool 输出填充。

  阶段: SA RAM 预计算
  ┌──────────────────────────────────────────────────┐
  │ 7 个 tile x 800 个 K = 5600 个地址               │
  │ im2col 从 pool_buf 读取 256bit 像素               │
  │ 约 5602 周期                                      │
  └──────────────────────────────────────────────────┘
```

---

## 7. 关键知识点总结

```
  ┌─────────────────────────────────────────────────────────────┐
  │ 知识点 1: im2col 是组合逻辑变换, 一个周期完成 40 lane 并行  │
  │ 知识点 2: 两个缓冲区 image_buf (RGB) 和 pool_buf (多通道)   │
  │ 知识点 3: SA RAM 预计算模式将 im2col 结果存储供后续使用      │
  │ 知识点 4: tile_scheduler 实现请求/响应流水线调度             │
  │ 知识点 5: pack_image_sa 进行位序反转以匹配 MAC 阵列格式     │
  │ 知识点 6: CSR 寄存器提供软件可配置的层参数                   │
  │ 知识点 7: padding 通过边界检查实现, 越界返回 0              │
  │ 知识点 8: 加载 FSM 逐像素从 npu_ram 复制到 image_buf        │
  └─────────────────────────────────────────────────────────────┘
```

---

## 8. 动手练习

### 练习 1: 手动计算 im2col 地址

**问题**: 对于 Conv1 (32x32x3, 5x5, pad=2), 给定 `row_base=40, k_idx=37`,
计算 lane=0 和 lane=15 对应的 `(oh, ow, ch, kh, kw, ih, iw)` 和读取的像素索引。

```
  提示:
  k_idx=37: ch = 37/25 = 1, rem = 37%25 = 12, kh = 12/5 = 2, kw = 12%5 = 2

  lane=0:
    row = 40+0 = 40, oh = 40/32 = ?, ow = 40%32 = ?
    ih = oh + 2 - 2 = ?, iw = ow + 2 - 2 = ?
    pixel_idx = ih * 32 + iw = ?
    取 image_buf[pixel_idx] 的哪个字节? (ch=1 -> G 通道)
```

### 练习 2: 计算 SA RAM 总容量

**问题**: 计算 Conv1 和 Conv2 的 SA RAM 总容量 (bit 数), 并估算需要多少 Block RAM (假设 BRAM 为 36Kbit)。

```
  提示:
  Conv1: SA_ROWS = ceil(1024/40) * 75 = ?
  Conv2: SA_ROWS = ceil(256/40) * 800 = ?
  每行 320 bit
  总容量 = ?
```

### 练习 3: 分析组合逻辑深度

**问题**: `get_lane_data` 函数从输入 `(row_base, k_idx, lane)` 到输出 `a_col_320b[lane*8 +: 8]` 的关键路径包含哪些操作? 估算组合逻辑级数。

```
  提示:
  1. 除法/取模 (row -> oh, ow)
  2. 除法/取模 (k_idx -> ch, kh, kw)
  3. 加减法 (ih, iw)
  4. 比较 (边界检查)
  5. 乘法 (pixel_idx)
  6. 数组索引 (image_buf 读取)
  7. 多路选择 (通道选择)

  这些操作是否可以在一个周期内完成? 如果不能, 如何优化?
```

### 练习 4: 设计流水线优化

**问题**: 当前 im2col 是纯组合逻辑。如果时序不满足, 设计一个 2 级流水线方案。
哪些操作放在第 1 级, 哪些放在第 2 级?

```
  方案建议:
  第 1 级: 地址计算 (oh, ow, ch, kh, kw, ih, iw, pixel_idx)
  第 2 级: buffer 读取 + 通道选择 + 边界填零

  需要修改的信号:
  - 在 req_valid 和 out_valid 之间插入 1 拍延迟
  - 需要缓冲哪些中间结果?
```

---

## 9. 扩展阅读

1. **im2col 论文**: "Caffe: Convolutional Architecture for Fast Feature Embedding" 中的 im2col 实现
2. **Winograd 变换**: 另一种减少乘法次数的卷积优化方法
3. **参考代码**: `src/npu/mac_array_40x32_stream.sv` -- 消费 im2col 数据的 MAC 阵列
4. **参考代码**: `src/npu/ppu_maxpool.sv` -- 产生 pool_buf 数据的后处理模块
