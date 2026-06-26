# Lecture 23: NPU存储子系统 -- RAM组织与数据布局

## 课程目标

本讲详细分析NPU内部的存储层次结构，包括本地RAM、im2col矩阵RAM、结果RAM、池化RAM以及权重ROM。完成本讲后，你将能够：
- 理解npu_ram的AXI4 Slave接口实现及其双端口架构
- 掌握image_sa_ram、result_ram、pool_ram的数据组织方式
- 了解权重ROM的层次化设计
- 分析NPU存储子系统的带宽需求与瓶颈

---

## 1. NPU存储层次总览

```
┌──────────────────────────────────────────────────────────────────┐
│                         npu_top                                  │
│                                                                  │
│  ┌──────────────────┐    ┌──────────────────────────────────┐    │
│  │    npu_ram        │    │          conv_top                 │    │
│  │  (4KB图像存储)     │    │                                  │    │
│  │  AXI4 Slave端口   │    │  ┌──────────────┐                │    │
│  │  + 简单读端口      │───►│  │image_sa_ram  │ 5600×320bit  │    │
│  │  (im2col用)       │    │  │(224KB)       │ im2col矩阵    │    │
│  └──────────────────┘    │  └──────┬───────┘                │    │
│                          │         │ MAC读取                  │    │
│                          │  ┌──────▼───────┐                │    │
│                          │  │  mac_array   │ 40×32脉动阵列   │    │
│                          │  └──────┬───────┘                │    │
│                          │         │ 结果写入                  │    │
│                          │  ┌──────▼───────┐                │    │
│                          │  │ result_ram   │ 1024×256bit    │    │
│                          │  │(32KB)        │ 卷积结果        │    │
│                          │  └──────┬───────┘                │    │
│                          │         │ MaxPool读取              │    │
│                          │  ┌──────▼───────┐                │    │
│                          │  │  pool_ram    │ 256×256bit     │    │
│                          │  │(8KB)         │ 池化结果        │    │
│                          │  └──────────────┘                │    │
│                          │                                  │    │
│                          │  ROMs:                            │    │
│                          │  ┌──────────────────────────────┐│    │
│                          │  │ image_rom  1024×24bit (3KB)  ││    │
│                          │  │ conv1_rom  75×256bit  (2.4KB)││    │
│                          │  │ conv2_rom  800×512bit (50KB) ││    │
│                          │  │ fc_weight  640×8bit   (640B) ││    │
│                          │  │ fc_bias    10×8bit    (10B)  ││    │
│                          │  └──────────────────────────────┘│    │
│                          └──────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

**存储总量统计：**

| 存储器 | 深度 | 宽度 | 容量 | 用途 |
|--------|------|------|------|------|
| npu_ram | 4096B | 8bit | 4KB | DMA写入的原始图像 |
| image_sa_ram | 5600 | 320bit | 224KB | im2col展开矩阵 |
| result_ram | 1024 | 256bit | 32KB | 卷积输出结果 |
| pool_ram | 256 | 256bit | 8KB | 池化输出结果 |
| image_rom | 1024 | 24bit | 3KB | 原始图像数据 |
| conv1_rom | 75 | 256bit | 2.4KB | 第一层卷积权重 |
| conv2_rom | 800 | 512bit | 50KB | 第二层卷积权重 |
| fc_weight | 640 | 8bit | 640B | FC层权重 |
| fc_bias | 10 | 8bit | 10B | FC层偏置 |
| **总计** | | | **~324KB** | |

---

## 设计视角：为什么这样设计？

### 动机分析

NPU 存储子系统的核心问题是：**如何为不同的数据流提供足够的带宽，同时控制存储面积？** 本设计采用分离式本地存储而非统一共享存储。

### 关键设计决策

```
  决策 1: 为什么用独立 RAM 而非统一存储?

  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 统一存储 │  所有数据共享一块大 RAM              │
  │                  │  优点: 面积利用率高                   │
  │                  │  缺点: 需要多端口仲裁, 带宽竞争       │
  │                  │        控制逻辑复杂                   │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 分离存储 │  每个数据流一块独立 RAM              │
  │  (当前)          │  优点: 无仲裁, 并行访问              │
  │                  │  缺点: 面积利用率低, 可能有碎片       │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B 的理由:
  - 各模块的数据访问模式完全不同 (不同大小、不同速率)
  - 分离存储消除仲裁延迟, 保证实时性
  - FPGA BRAM 资源充足 (Zynq-7020 有 140 个 36Kb BRAM)
```

### 为什么需要 4 块独立 RAM？

```
  ┌───────────────────────────────────────────────────────┐
  │  RAM 名称        │ 容量     │ 写入方     │ 读取方      │
  ├──────────────────┼──────────┼────────────┼─────────────┤
  │  npu_ram         │ 4KB      │ DMA Master │ im2col      │
  │  image_sa_ram    │ 224KB    │ DMAC       │ MAC 阵列    │
  │  result_ram      │ 32KB     │ MAC 阵列   │ MaxPool     │
  │  pool_ram        │ 8KB      │ MaxPool    │ GAP/调试    │
  └──────────────────┴──────────┴────────────┴─────────────┘

  为什么不能合并?
  - npu_ram: AXI4 Slave 接口, DMA 写入, 必须独立
  - image_sa_ram: 320bit 宽, 专为 MAC 阵列设计
  - result_ram: 256bit 宽, MAC 输出缓冲
  - pool_ram: 256bit 宽, MaxPool 输出 + GAP 输入

  宽度不同 (320bit vs 256bit) 导致无法共享同一块 RAM
```

### 为什么 image_sa_ram 需要 224KB？

```
  容量计算:
  SA_ROWS = max(ceil(1024/40) * 75, ceil(256/40) * 800)
          = max(1950, 5600) = 5600

  每行 320 bit = 40 字节
  总容量 = 5600 * 40 = 224,000 字节 ≈ 218.75 KB

  为什么 Conv2 需要 5600 行?
  - Conv2 有 256 个输出像素, 7 个 tile
  - Conv2 的 K = 800 (32x5x5), 远大于 Conv1 的 75
  - 7 * 800 = 5600 行

  面积代价: 224KB 需要约 50 个 36Kb BRAM (占 Zynq-7020 的 36%)
  这是本设计中最大的存储开销
```

### 为什么使用同步读而非异步读？

```
  ┌──────────────────┬─────────────────────────────────────┐
  │  异步读 (组合逻辑) │  rd_data = mem[rd_addr] (当拍)      │
  │                  │  优点: 0 延迟                        │
  │                  │  缺点: 无法映射到 BRAM               │
  │                  │        大容量时使用分布式 RAM (LUT)   │
  ├──────────────────┼─────────────────────────────────────┤
  │  同步读 (寄存器)  │  rd_data <= mem[rd_addr] (下一拍)   │
  │  (当前)          │  优点: 可映射到 BRAM                 │
  │                  │  缺点: 1 拍延迟                      │
  └──────────────────┴─────────────────────────────────────┘

  选择同步读的理由:
  - 大容量 RAM (224KB) 必须用 BRAM 实现
  - BRAM 天然是同步读 (时钟沿触发)
  - 1 拍延迟可通过 MAC 控制状态机补偿
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 分析数据流和带宽需求

```
  数据流分析:

  ┌─────────────────────────────────────────────────────┐
  │  数据流 1: 图像输入                                   │
  │  DMA → npu_ram → im2col                            │
  │  带宽: 32bit/cycle (AXI 数据宽度)                    │
  │  容量: 32x32x3 = 3072 字节 → 4KB                    │
  │                                                     │
  │  数据流 2: im2col 矩阵                               │
  │  im2col → SA RAM → MAC 阵列                        │
  │  带宽: 320bit/cycle (40 lane x 8bit)               │
  │  容量: 5600 x 320bit = 224KB                        │
  │                                                     │
  │  数据流 3: 卷积结果                                  │
  │  MAC 阵列 → result_ram → MaxPool                   │
  │  带宽: 256bit/cycle (32 通道 x 8bit)               │
  │  容量: 1024 x 256bit = 32KB                        │
  │                                                     │
  │  数据流 4: 池化结果                                  │
  │  MaxPool → pool_ram → GAP/FC                       │
  │  带宽: 256bit/cycle                                │
  │  容量: 256 x 256bit = 8KB                          │
  └─────────────────────────────────────────────────────┘
```

### 第 2 步: 确定存储器参数

```
  从数据流推导存储器参数:

  ┌──────────────┬────────┬────────┬──────────────────────┐
  │ 存储器        │ 深度    │ 宽度    │ 推导过程              │
  ├──────────────┼────────┼────────┼──────────────────────┤
  │ npu_ram      │ 4096B  │ 8bit   │ 32x32x3 = 3072B → 4KB│
  │ image_sa_ram │ 5600   │ 320bit │ max(L1,L2) tile*K    │
  │ result_ram   │ 1024   │ 256bit │ 32x32 = 1024 像素    │
  │ pool_ram     │ 256    │ 256bit │ 16x16 = 256 像素     │
  └──────────────┴────────┴────────┴──────────────────────┘

  设计要点:
  - 深度取所有层的最大值 (支持 Conv1 和 Conv2)
  - 宽度匹配数据通路 (MAC 阵列列数 x 8bit)
  - 使用参数化, 修改参数即可适配不同网络
```

### 第 3 步: 设计 RAM 接口

```
  统一 RAM 接口设计:

  module ram #(
      parameter DEPTH = 1024,
      parameter AW = clog2(DEPTH),
      parameter DW = 32
  )(
      input  clk,
      input  wr_en,       // 写使能
      input  [AW-1:0] wr_addr,  // 写地址
      input  [DW-1:0] wr_data,  // 写数据
      input  rd_en,       // 读使能
      input  [AW-1:0] rd_addr,  // 读地址
      output [DW-1:0] rd_data   // 读数据 (1拍延迟)
  );

  设计要点:
  - 单端口, 读写不能同时进行 (简化设计)
  - 同步读, 1 拍延迟
  - ram_style="block" 属性指导综合工具使用 BRAM
  - 支持可选的文件初始化 ($readmemh)
```

### 第 4 步: 设计端口分配

```
  各存储器的端口连接:

  npu_ram:
    写端口 ← AXI4 Slave (DMA 写入)
    读端口 → im2col 组合逻辑读取 (简单端口)

  image_sa_ram:
    写端口 ← DMAC (image_sa_writer)
    读端口 → MAC 阵列 或 调试端口 (MUX 切换)

  result_ram:
    写端口 ← MAC 阵列结果写出
    读端口 → MaxPool 或 调试端口 (MUX 切换)

  pool_ram:
    写端口 ← MaxPool 输出
    读端口 → GAP 累加 或 调试端口 (MUX 切换)
```

### 第 5 步: 验证与调优

```
  验证策略:
  1. 地址范围验证: 确保读写地址不越界
  2. 数据完整性: 写入后读出, 验证数据一致
  3. 带宽验证: MAC 阵列满速运行时, SA RAM 是否能跟上
  4. 容量验证: 所有层的数据是否能放入对应 RAM

  调优项:
  - 检查 BRAM 综合报告, 确认使用 BRAM 而非分布式 RAM
  - 调整 RAM 深度, 消除浪费 (如 pool_ram 的 256 是否足够)
  - 检查读延迟对 MAC 控制状态机的影响
```

---

## 设计视角：架构模式与原则

### 模式 1: 本地缓冲层次模式 (Local Buffer Hierarchy)

```
  核心思想: 为每个处理单元提供专用的本地缓冲, 减少共享冲突

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  存储层次:                                             │
  │                                                       │
  │  DDR (256KB)          全局存储, DMA 源                 │
  │    │                  带宽: 32bit/cycle                │
  │    ▼                                                 │
  │  npu_ram (4KB)        图像缓冲, DMA 目标              │
  │    │                  带宽: 32bit/cycle                │
  │    ▼                                                 │
  │  image_buf/pool_buf   寄存器文件, im2col 源           │
  │    │                  带宽: 全并行 (40 lane)           │
  │    ▼                                                 │
  │  image_sa_ram (224KB) 预计算缓冲, MAC 源              │
  │    │                  带宽: 320bit/cycle               │
  │    ▼                                                 │
  │  MAC 阵列 (寄存器)    计算单元, 无外部存储             │
  │    │                  带宽: 内部累加器                  │
  │    ▼                                                 │
  │  result_ram (32KB)    结果缓冲, MaxPool 源            │
  │    │                  带宽: 256bit/cycle               │
  │    ▼                                                 │
  │  pool_ram (8KB)       池化缓冲, GAP/FC 源             │
  │                       带宽: 256bit/cycle               │
  │                                                       │
  │  每一级的容量递减, 带宽递增 (靠近计算单元)              │
  └───────────────────────────────────────────────────────┘

  优势:
  - 每级只服务一个消费者, 无需仲裁
  - 数据局部性好, 减少远距离数据搬运
  - 各级可独立优化 (宽度、深度、端口数)
```

### 模式 2: 带宽匹配模式 (Bandwidth Matching)

```
  核心思想: 存储器带宽应匹配其消费者/生产者的速率

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  带宽匹配分析:                                        │
  │                                                       │
  │  image_sa_ram → MAC 阵列:                            │
  │    SA RAM 读带宽: 320bit/cycle                        │
  │    MAC 消耗速率: 320bit/cycle (每 cycle 1 个 K 列)   │
  │    匹配! ✓                                           │
  │                                                       │
  │  result_ram ← MAC 阵列:                              │
  │    MAC 产出速率: 40x32 = 1280 结果/tile               │
  │    result_ram 写带宽: 256bit/cycle = 32 结果/cycle    │
  │    写完一个 tile: 1280/32 = 40 cycles                 │
  │    匹配! ✓ (MAC 等待 result 写完再开始下一 tile)      │
  │                                                       │
  │  pool_ram ← MaxPool:                                 │
  │    MaxPool 产出速率: 1 像素/cycle (256bit)            │
  │    pool_ram 写带宽: 256bit/cycle                      │
  │    匹配! ✓                                           │
  │                                                       │
  │  反模式: 带宽不匹配                                   │
  │  如果 SA RAM 只有 8bit 宽:                            │
  │    MAC 需要等 40 cycle 才能读完一列                   │
  │    性能下降 40x!                                      │
  └───────────────────────────────────────────────────────┘

  设计要点:
  - RAM 宽度 = 数据通路宽度 (避免串行化)
  - RAM 深度 = 最大层的数据量 (避免溢出)
  - 读写端口数 = 最大并发访问数 (避免冲突)
```

### 原则: 分离关注点

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 存储器只负责存取, 不关心数据含义          │
  │                                                     │
  │  本设计中的应用:                                     │
  │                                                     │
  │  image_sa_ram:                                       │
  │  - 只知道: 深度 5600, 宽度 320bit                   │
  │  - 不知道: 每行是 40 个像素的 im2col 值              │
  │  - 不知道: 地址与 tile/K 的映射关系                  │
  │                                                     │
  │  result_ram:                                         │
  │  - 只知道: 深度 1024, 宽度 256bit                   │
  │  - 不知道: 每行是 32 通道的卷积结果                  │
  │  - 不知道: 地址与像素坐标的映射关系                  │
  │                                                     │
  │  好处:                                               │
  │  - RAM 模块可复用 (同一模块用于不同用途)             │
  │  - 接口简洁 (只有地址和数据)                         │
  │  - 易于替换实现 (如改用双端口 RAM)                   │
  │                                                     │
  │  数据语义由消费者/生产者负责:                         │
  │  - DMAC 负责写入正确的地址                           │
  │  - MAC 负责读取正确的地址                            │
  │  - RAM 本身是 "哑" 存储                              │
  └─────────────────────────────────────────────────────┘
```

---

## 2. npu_ram -- AXI4 Slave本地存储

### 2.1 模块接口

npu_ram是NPU的4KB图像数据存储，具有双端口：一个AXI4 Slave端口供DMA写入，一个简单读端口供im2col逻辑读取。

> 源码参考：`src/npu/npu_ram.sv`，共224行

```systemverilog
// 文件：src/npu/npu_ram.sv，第1-7行
module npu_ram #(
    parameter integer AXI_ID_W   = 8,
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 32,
    parameter integer MEM_BYTES  = 131072,   // 128KB (默认最大)
    parameter integer READ_LATENCY = 1
)(
```

**注意**：在npu_top中实例化时，MEM_BYTES被设置为4096（4KB）：

```systemverilog
// 文件：src/npu/npu_top.sv，第139-144行
npu_ram #(
    .AXI_ID_W(8),
    .AXI_ADDR_W(32),
    .AXI_DATA_W(32),
    .MEM_BYTES(4096),       // 4KB图像存储
    .READ_LATENCY(1)
) u_npu_ram (
```

### 2.2 字节寻址存储阵列

```systemverilog
// 文件：src/npu/npu_ram.sv，第59行
reg [7:0] mem [0:MEM_BYTES-1];  // 字节可寻址存储
```

存储器按字节组织，支持任意粒度的写入（通过wstrb字节使能）。

### 2.3 简单读端口（组合逻辑）

im2col模块通过简单读端口直接读取像素数据，无流水线延迟：

```systemverilog
// 文件：src/npu/npu_ram.sv，第62-64行
assign simple_rd_data = (simple_rd_addr + 3 < MEM_BYTES) ?
    {mem[simple_rd_addr+3], mem[simple_rd_addr+2],
     mem[simple_rd_addr+1], mem[simple_rd_addr]} : 32'h0;
```

**关键特点：**
- 组合逻辑读取，零延迟
- 按小端序拼接4个字节为32位字
- 越界保护：地址超出范围返回0

### 2.4 AXI4写通道状态机

```
                    s_awvalid && s_awready
                    ┌──────────┐
         ┌─────────│  空闲态   │
         │         │(awready=1)│
         │         └─────┬────┘
         │               │ AW握手
         │               ▼
         │         ┌──────────┐
         │         │ 数据接收  │
         │         │(wready=1)│
         │         └─────┬────┘
         │               │ wlast || wr_left==0
         │               ▼
         │         ┌──────────┐
         │         │ 写响应    │
         │         │(bvalid=1)│
         │         └─────┬────┘
         │               │ bready
         └───────────────┘
```

```systemverilog
// 文件：src/npu/npu_ram.sv，第127-168行 (关键写通道逻辑)
// AW握手：捕获地址和burst参数
if (s_awready && s_awvalid) begin
    wr_active <= 1'b1;
    wr_addr   <= s_awaddr;
    wr_left   <= s_awlen;
    wr_size   <= s_awsize;
    wr_burst  <= s_awburst;
    wr_id     <= s_awid;
    s_awready <= 1'b0;    // 关闭AW接收
    s_wready  <= 1'b1;    // 打开W接收
end

// W数据接收：按字节写入
if (s_wready && s_wvalid) begin
    for (b = 0; b < STRB_W; b = b + 1) begin
        if (s_wstrb[b]) begin
            byte_addr = wr_addr + b;
            if (byte_addr < MEM_BYTES)
                mem[byte_addr] <= s_wdata[8*b +: 8];
        end
    end
    // INCR burst地址自增
    if (wr_burst == 2'b01) begin
        wr_addr <= wr_addr + (1 << wr_size);
    end
end
```

### 2.5 AXI4读通道状态机

```
     s_arvalid && s_arready         延迟计数到0
     ┌──────────┐                 ┌──────────┐
     │  空闲态   │───AR握手───────►│ 延迟等待  │
     │(arready=1)│                 └─────┬────┘
     └──────────┘                       │
                                        ▼
     ┌──────────┐          ┌──────────────────────┐
     │ 读完成   │◄─rlast───│  R数据输出(rvalid=1)  │
     └──────────┘          └──────────────────────┘
         │                        ▲ rready && rvalid
         │                        │
         └────────────────────────┘
              还有剩余beat?
```

```systemverilog
// 文件：src/npu/npu_ram.sv，第178-221行 (关键读通道逻辑)
// AR握手：捕获读地址
if (s_arready && s_arvalid) begin
    rd_active  <= 1'b1;
    rd_addr    <= s_araddr;
    rd_left    <= s_arlen;
    rd_lat_cnt <= READ_LATENCY-1;  // 启动延迟计数
    s_arready  <= 1'b0;
end

// R数据输出：从字节拼接为32位
if (rd_active && !s_rvalid) begin
    if (rd_lat_cnt != 0) begin
        rd_lat_cnt <= rd_lat_cnt - 1'b1;  // 等待延迟
    end else begin
        for (b = 0; b < STRB_W; b = b + 1) begin
            byte_addr = rd_addr + b;
            s_rdata[8*b +: 8] <= (byte_addr < MEM_BYTES) ? mem[byte_addr] : 8'h00;
        end
        s_rvalid <= 1'b1;
        s_rlast  <= (rd_left == 0);  // 最后一个beat
    end
end
```

---

## 3. image_sa_ram -- im2col展开矩阵存储

### 3.1 存储规格

```systemverilog
// 文件：src/npu/conv_top.sv，第252-264行
ram #(
    .DEPTH(SA_ROWS),   // 5600行
    .AW(SA_AW),        // 13bit地址 (clog2(5600)=13)
    .DW(SA_DW)         // 320bit宽度 (40×8)
) u_image_sa_ram (
    .clk(clk),
    .wr_en(dmac_ram_wr),      // DMAC写入
    .wr_addr(dmac_ram_waddr),
    .wr_data(dmac_ram_wdata),
    .rd_en(image_sa_rd_en),   // MAC或调试读取
    .rd_addr(image_sa_rd_addr),
    .rd_data(image_sa_rd_data)
);
```

### 3.2 数据布局

每一行存储一个im2col展开的列向量，包含40个像素在同一卷积核位置的值：

```
image_sa_ram 布局 (5600行 × 320bit):
┌─────────────────────────────────────────────────────┐
│ 行地址 = tile_idx × K_LEN + k_idx                    │
│                                                     │
│  bit[319:312]  bit[311:304]  ...  bit[7:0]          │
│  ┌──────────┬──────────┬──────────┬──────────┐      │
│  │ A[row+0] │ A[row+1] │   ...    │ A[row+39]│      │
│  │ [k_idx]  │ [k_idx]  │          │ [k_idx]  │      │
│  └──────────┴──────────┴──────────┴──────────┘      │
│  ◄──────────────── 40个lane × 8bit ──────────────►  │
│                                                     │
│  Tile 0 (行0~74):      row_base=0, K_LEN=75        │
│  ├── k=0:  A[0..39][k=0]                           │
│  ├── k=1:  A[0..39][k=1]                           │
│  ├── ...                                            │
│  └── k=74: A[0..39][k=74]                          │
│                                                     │
│  Tile 1 (行75~149):    row_base=40, K_LEN=75       │
│  ├── k=0:  A[40..79][k=0]                          │
│  └── ...                                            │
│                                                     │
│  ...                                                │
│                                                     │
│  Tile 25 (行1875~1949): row_base=1000, K_LEN=75    │
│  └── ...                                            │
└─────────────────────────────────────────────────────┘
```

### 3.3 容量计算

```
Layer 1:  TILE_COUNT = ceil(1024/40) = 26 tiles
          SA_ROWS_L1 = 26 × 75 = 1950 行

Layer 2:  TILE_COUNT = ceil(256/40) = 7 tiles
          SA_ROWS_L2 = 7 × 800 = 5600 行

取最大值: SA_ROWS = 5600
总容量   = 5600 × 320bit = 5600 × 40B = 224,000B ≈ 218.75KB
```

### 3.4 内部RAM实现

通用RAM模块使用FPGA BRAM原语：

```systemverilog
// 文件：src/npu/ram.sv，第1-37行
module ram #(
    parameter int DEPTH = 1024,
    parameter int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int DW = 32,
    parameter string INIT_FILE = ""
)(
    input  logic clk,
    input  logic wr_en,
    input  logic [AW-1:0] wr_addr,
    input  logic [DW-1:0] wr_data,
    input  logic rd_en,
    input  logic [AW-1:0] rd_addr,
    output logic [DW-1:0] rd_data
);

    (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];
    //                              ^^^^^^^^^^^
    //                     Verilog属性：推断为BRAM

    // 可选初始化
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // 同步读写
    always_ff @(posedge clk) begin
        if (wr_en)  mem[wr_addr] <= wr_data;
        if (rd_en)  rd_data      <= mem[rd_addr];
    end
endmodule
```

**关键设计要点：**
- `(* ram_style = "block" *)` 属性指导综合工具使用BRAM而非分布式RAM
- 同步读写，1周期读延迟
- 支持可选的文件初始化（`$readmemh`）

---

## 4. result_ram -- 卷积结果存储

### 4.1 存储规格

```systemverilog
// 文件：src/npu/conv_top.sv，第266-278行
ram #(
    .DEPTH(OUT_ROWS),  // 1024行
    .AW(OUT_AW),        // 10bit地址
    .DW(OUT_DW)         // 256bit宽度 (32×8)
) u_result_ram (
    .clk(clk),
    .wr_en(result_ram_wr),          // MAC结果写入
    .wr_addr(result_ram_waddr),
    .wr_data(result_ram_wdata),
    .rd_en(dbg_result_rd_en),       // 调试读取
    .rd_addr(dbg_result_rd_addr),
    .rd_data(dbg_result_rd_data)
);
```

### 4.2 数据布局

```
result_ram 布局 (1024行 × 256bit):

每行存储一个像素位置的32个通道的卷积结果：

行地址 i 对应特征图的第i个像素
┌────────────────────────────────────────────────┐
│  bit[255:248]  bit[247:240]  ...  bit[7:0]     │
│  ┌──────────┬──────────┬──────────┬──────────┐ │
│  │  ch[0]   │  ch[1]   │   ...    │  ch[31]  │ │
│  │ int8     │ int8     │          │ int8     │ │
│  └──────────┴──────────┴──────────┴──────────┘ │
│                                                │
│  像素布局 (32×32特征图):                         │
│  行 0   → pixel[0][0], 32个通道                 │
│  行 1   → pixel[0][1], 32个通道                 │
│  ...                                           │
│  行 31  → pixel[0][31], 32个通道                │
│  行 32  → pixel[1][0], 32个通道                 │
│  ...                                           │
│  行 1023 → pixel[31][31], 32个通道              │
└────────────────────────────────────────────────┘
```

**容量：** 1024 × 256bit = 1024 × 32B = 32KB

---

## 5. pool_ram -- 池化结果存储

### 5.1 存储规格

```systemverilog
// 文件：src/npu/conv_top.sv，第280-292行
ram #(
    .DEPTH(POOL_ROWS),  // 256行
    .AW(POOL_AW),        // 8bit地址
    .DW(OUT_DW)          // 256bit宽度 (32×8)
) u_pool_ram (
    .clk(clk),
    .wr_en(ppu_pool_wr),       // MaxPool写入
    .wr_addr(ppu_pool_waddr),
    .wr_data(ppu_pool_wdata),
    .rd_en(dbg_pool_rd_en),    // 调试读取
    .rd_addr(dbg_pool_rd_addr),
    .rd_data(dbg_pool_rd_data)
);
```

### 5.2 MaxPool数据流

```
输入特征图 (32×32×32ch)          输出特征图 (16×16×32ch)
┌────────────────────┐          ┌────────────────────┐
│ ┌──┬──┬──┬──┬──┐   │          │ ┌──┬──┬──┬──┐      │
│ │2x2│  │  │  │   │  2×2      │ │  │  │  │  │      │
│ │max│  │  │  │   │  池化      │ │  │  │  │  │      │
│ ├──┤  │  │  │   │  ────→     │ ├──┤  │  │  │      │
│ │  │  │  │  │   │          │ │  │  │  │  │      │
│ └──┴──┴──┴──┘   │          │ └──┴──┴──┴──┘      │
│ 32×32            │          │ 16×16               │
└────────────────────┘          └────────────────────┘

pool_ram行地址计算:
  addr = (pool_h × out_size + pool_w) × stride + offset
```

### 5.3 ppu_maxpool流式处理

```systemverilog
// 文件：src/npu/ppu_maxpool.sv，第44-49行
// 坐标计算
assign h_idx = in_row_idx / cfg_in_size;   // 输入行号
assign w_idx = in_row_idx % cfg_in_size;   // 输入列号
assign pool_h = h_idx >> 1;                 // 池化行号 (÷2)
assign pool_w = w_idx >> 1;                 // 池化列号 (÷2)

// 2×2 MaxPool比较逻辑
assign hmax_data = max_vec_i8(left_pixel_buf, in_data);  // 水平方向取最大
assign vmax_data = max_vec_i8(row_max_buf[pool_w], hmax_data); // 垂直方向取最大
```

**流式处理策略：**
1. **奇数列**（`w_idx[0]==0`）：缓存到`left_pixel_buf`
2. **偶数行的偶数列**（`h_idx[0]==0`）：计算水平最大值，缓存到`row_max_buf`
3. **奇数行的奇数列**：计算垂直最大值，写入pool_ram

```
输入像素流 (逐行逐列):
  (0,0) → 缓存      (0,1) → hmax, 缓存row_max
  (0,2) → 缓存      (0,3) → hmax, 缓存row_max
  ...
  (1,0) → 缓存      (1,1) → hmax → vmax → 写入pool_ram
  (1,2) → 缓存      (1,3) → hmax → vmax → 写入pool_ram
  ...
```

---

## 6. 权重ROM设计

### 6.1 ROM模块实现

```systemverilog
// 文件：src/npu/rom.sv，第1-31行
module rom #(
    parameter FILE      = "param_init.dat",
    parameter AW        = 32,
    parameter DW        = 8,
    parameter ROM_DEPTH = 4096
)(
    input  logic clk,
    input  logic rst_n,
    input  logic [AW-1:0] instr_addr,
    output logic [DW-1:0] instr_out
);

    (* ram_style = "block" *) logic [DW-1:0] rom_mem [0:ROM_DEPTH-1];

    initial begin
        $readmemh(FILE, rom_mem);  // 从文件加载权重
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            instr_out <= '0;
        else
            instr_out <= rom_mem[instr_addr];  // 同步读取
    end
endmodule
```

### 6.2 权重ROM实例化层次

```
conv_top
├── u_image_rom   (1024×24bit)   原始图像数据
├── u_conv1_rom   (75×256bit)    Conv1权重: 5×5×3个kernel, 每个32通道
├── u_conv2_rom   (800×512bit)   Conv2权重: 5×5×32个kernel, 每个64通道
└── u_mac
    ├── bias_mem  (32×8bit)      Conv1偏置
    └── bias2_mem (64×8bit)      Conv2偏置

gap_fc_logits
├── fc_weight[640]  640×8bit     FC权重: 64输入×10输出
└── fc_bias[10]     10×8bit      FC偏置: 10个类别
```

### 6.3 Conv权重数据格式

```
Conv1权重 (conv1.dat): 75行 × 256bit
┌───────────────────────────────────────────────────┐
│ 每行 = 32个kernel在同一卷积核位置的权重值           │
│                                                   │
│ 行地址 = k_idx (0~74, 对应5×5×3=75个位置)         │
│ bit[255:248] = kernel[0]的权重 (int8)              │
│ bit[247:240] = kernel[1]的权重 (int8)              │
│ ...                                               │
│ bit[7:0]     = kernel[31]的权重 (int8)             │
│                                                   │
│ 总计: 75 × 32 = 2400个权重参数                     │
│ = 5×5×3(卷积核) × 32(输出通道)                     │
└───────────────────────────────────────────────────┘

Conv2权重 (conv2.dat): 800行 × 512bit
┌───────────────────────────────────────────────────┐
│ 每行 = 64个kernel在同一卷积核位置的权重值           │
│                                                   │
│ 行地址 = k_idx (0~799, 对应5×5×32=800个位置)      │
│ bit[511:504] = kernel[0]的权重 (int8)              │
│ ...                                               │
│ bit[7:0]     = kernel[63]的权重 (int8)             │
│                                                   │
│ 总计: 800 × 64 = 51200个权重参数                   │
│ = 5×5×32(卷积核) × 64(输出通道)                    │
└───────────────────────────────────────────────────┘
```

---

## 7. 存储带宽分析

### 7.1 各存储器带宽需求

```
┌─────────────────────────────────────────────────────────────┐
│ 存储器           │ 读带宽          │ 写带宽         │ 总带宽 │
├──────────────────┼─────────────────┼────────────────┼────────┤
│ npu_ram          │ 32bit/cycle     │ 32bit/cycle    │ 64bit  │
│ (简单读端口)      │ (im2col读取)    │ (DMA写入)      │        │
├──────────────────┼─────────────────┼────────────────┼────────┤
│ image_sa_ram     │ 320bit/cycle    │ 320bit/cycle   │ 640bit │
│                  │ (MAC读取)       │ (DMAC写入)     │        │
├──────────────────┼─────────────────┼────────────────┼────────┤
│ result_ram       │ 256bit/cycle    │ 256bit/cycle   │ 512bit │
│                  │ (调试读取)       │ (MAC写入)      │        │
├──────────────────┼─────────────────┼────────────────┼────────┤
│ pool_ram         │ 256bit/cycle    │ 256bit/cycle   │ 512bit │
│                  │ (调试/FC读取)    │ (MaxPool写入)  │        │
└──────────────────┴─────────────────┴────────────────┴────────┘
```

### 7.2 MAC阵列数据吞吐

```
MAC阵列: 40×32 = 1280 MAC/cycle

数据供给:
  A矩阵 (image_sa_ram): 每cycle读1行 = 320bit = 40个int8值 ✓
  W权重 (conv ROM):      每cycle读1行 = 256/512bit = 32/64个int8值 ✓

结果输出:
  每个tile: 40行×32列 = 1280个int8结果
  result_ram写入: 256bit/cycle = 32个结果/cycle
  写完一个tile需要: 1280/32 = 40 cycles
```

### 7.3 带宽瓶颈识别

```
Layer 1 关键路径:
  DMAC: im2col生成速率 = 1行/cycle (320bit)
  MAC:  消耗速率 = 1行/cycle (320bit)  → 匹配 ✓

Layer 2 关键路径:
  DMAC: im2col生成速率 = 1行/cycle (320bit)
  MAC:  消耗速率 = 1行/cycle (512bit宽度权重)  → 匹配 ✓
  但K_LEN=800，每个tile需要800 cycles

实际瓶颈:
  DMAC的im2col计算延迟（需要从pool_ram读取像素并展开）
  pool_ram读取需要通过调试端口（在非MAC状态下）
```

---

## 8. DMA图像加载路径

### 8.1 从DDR到npu_ram的数据流

```
DDR (256KB)
  │
  │ DMA Master AXI4
  │ (dma_axi_top)
  │
  ▼
AXI Crossbar ──→ NPU LMEM (mst1, 0x0000_1000~0x0002_0FFF)
  │
  │ AXI4 Slave
  ▼
npu_ram (4KB)
  │
  │ simple_rd_port (组合逻辑)
  ▼
dmac_im2col_stream
  │
  │ im2col展开
  ▼
image_sa_ram (224KB)
```

### 8.2 npu_ram的SoC地址映射

在soc_top中，npu_ram通过crossbar的mst1端口映射到地址空间：

```systemverilog
// 文件：src/soc_top.sv，第508-509行
// mst1: NPU LMEM (128KB @ 0x0000_1000)
.SLV1_START_ADDR(32'h0000_1000),
.SLV1_END_ADDR(32'h0002_0FFF),
```

**注意**：虽然crossbar配置了128KB地址范围，但npu_top内部的npu_ram只实例化了4KB（MEM_BYTES=4096）。超出部分的访问会返回0。

---

## 9. 关键知识点总结

1. **双端口RAM设计**：npu_ram通过AXI4 Slave端口接收DMA数据，通过简单读端口供im2col使用。两个端口独立工作，无需仲裁。

2. **im2col矩阵的tile化**：image_sa_ram按tile组织数据，每tile包含TILE_ROWS(40)行像素在K_LEN个卷积核位置的展开值。地址 = tile_idx × K_LEN + k_idx。

3. **流式MaxPool**：ppu_maxpool不需要额外的行缓冲，利用`left_pixel_buf`和`row_max_buf`实现流式2×2池化，按扫描线顺序处理。

4. **BRAM推断**：所有RAM和ROM都使用`(* ram_style = "block" *)`属性，确保综合工具映射到FPGA的BRAM资源。

5. **同步读延迟**：ram和rom模块都是1周期同步读延迟，MAC控制状态机通过`mac_rd_valid_q`寄存器补偿这个延迟。

6. **字节寻址 vs 行寻址**：npu_ram使用字节寻址（AXI标准），而image_sa_ram/result_ram/pool_ram使用行寻址（简化接口）。

---

## 10. 动手练习

### 练习1：计算image_sa_ram地址

给定Layer 1配置（K_LEN=75, TILE_ROWS=40），计算以下像素的im2col数据存储地址：
- 第0个tile的第10个卷积核位置
- 第3个tile的第0个卷积核位置
- 最后一个tile的第74个卷积核位置

<details>
<summary>参考答案</summary>

```
地址 = tile_idx × K_LEN + k_idx

第0个tile, k=10:  0 × 75 + 10 = 10
第3个tile, k=0:   3 × 75 + 0  = 225
最后一个tile (tile 25), k=74: 25 × 75 + 74 = 1949
```
</details>

### 练习2：存储容量扩展

如果要处理224×224的ImageNet图像（3通道，5×5卷积），重新计算各存储器的容量需求：
- image_sa_ram需要多少行？
- result_ram需要多少行？
- pool_ram需要多少行？

<details>
<summary>提示</summary>

```
输入: 224×224×3
Conv1: 5×5×3=75, 输出: 220×220×32 (假设valid padding)
Pool1: 110×110×32
Conv2: 5×5×32=800, 输出: 106×106×64
Pool2: 53×53×64

image_sa_ram: ceil(220×220/40) × 75 = 1210 × 75 = 90750行
result_ram:   220×220 = 48400行
pool_ram:     110×110 = 12100行

总容量将超过FPGA BRAM的典型限制！
这就是为什么本设计使用32×32的小图像。
```
</details>

### 练习3：添加ECC保护

为result_ram添加简单的奇偶校验ECC保护。每32bit数据附加1bit校验位。修改ram模块，使其DW参数自动增加校验位，并在读出时检查校验错误。

### 练习4：pool_ram双端口改造

当前pool_ram是单端口（读写不能同时进行）。请将其改为真双端口RAM，使MaxPool可以同时写入和FC层读取。画出修改后的接口框图。

---

## 11. 下一讲预告

下一讲（Lecture 24）将分析SoC顶层集成，包括：
- soc_top.sv的完整模块实例化列表
- AXI Crossbar的地址路由配置
- 所有模块间的信号连接关系
- 中断和状态信号的汇聚方式
