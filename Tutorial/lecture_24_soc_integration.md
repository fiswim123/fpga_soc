# Lecture 24: SoC顶层集成 -- 模块连接与信号汇聚

## 课程目标

本讲逐段分析`soc_top.sv`（847行），它是整个FPGA SoC的顶层模块，负责将CPU、DMA、NPU、DDR、AXI Crossbar等所有子系统连接在一起。完成本讲后，你将能够：
- 理解SoC的完整模块组成和层次结构
- 掌握AXI Crossbar的地址路由配置
- 了解AXI协议桥接的设计模式
- 学会分析和调试SoC级别的信号连接

---

## 1. SoC模块层次结构

```
soc_top (847行)
├── u_cpu          picorv32_axi         RISC-V CPU (AXI4-Lite接口)
├── u_cpu_bridge   axi_lite2axi         AXI4-Lite → AXI4 协议桥
├── u_dma          dma_axi_top          DMA控制器 (CSR Slave + AXI4 Master)
├── u_crossbar     axicb_crossbar_top   4×4 AXI交叉开关
├── u_ddr          ddr                  DDR存储器模型 (256KB)
├── u_npu_csr_bridge  axi2csr           AXI4 → CSR寄存器桥
└── u_npu          npu_top              神经处理单元
    ├── u_npu_ram     npu_ram            4KB图像存储 (AXI4 Slave)
    └── u_conv        conv_top           卷积处理器
        ├── u_csr        npu_csr_regs     CSR寄存器
        ├── u_image_rom  rom              图像数据ROM
        ├── u_conv1_rom  rom              Conv1权重ROM
        ├── u_conv2_rom  rom              Conv2权重ROM
        ├── u_dmac       dmac_image_sa_writer  im2col数据搬运
        ├── u_image_sa_ram  ram            im2col矩阵RAM (224KB)
        ├── u_result_ram    ram            卷积结果RAM (32KB)
        ├── u_pool_ram      ram            池化结果RAM (8KB)
        ├── u_mac        mac_array_40x32_stream  40×32脉动MAC阵列
        └── u_ppu        ppu_maxpool      流式2×2 MaxPool
    └── u_fc         gap_fc_logits        GAP+FC分类器
```

---

## 设计视角：为什么这样设计？

### 动机分析

SoC 顶层集成的核心问题是：**如何将多个独立设计的模块连接成一个协同工作的系统？** 这涉及协议转换、地址路由、信号汇聚等多方面挑战。

### 关键设计决策

```
  决策 1: 为什么用 Crossbar 而非总线仲裁?

  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: 共享总线 │  所有 Master 共享一条 AXI 总线      │
  │                  │  仲裁器在同一时刻只允许一个 Master   │
  │                  │  优点: 面积小                       │
  │                  │  缺点: 带宽受限, 仲裁延迟            │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: Crossbar │  N Master x M Slave 全交叉开关     │
  │  (当前)          │  不同 Master 可同时访问不同 Slave   │
  │                  │  优点: 最大并行度, 无仲裁延迟        │
  │                  │  缺点: 面积较大 (N*M 个交叉点)      │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B 的理由:
  - CPU 和 DMA 经常同时访问不同目标 (CPU 写 NPU CSR, DMA 写 NPU LMEM)
  - Crossbar 允许这两个事务并行完成
  - 4x4 Crossbar 的面积开销在 FPGA 上可接受
```

### 为什么 DMA CSR 用手动桥而非 axi2csr？

```
  ┌───────────────────────────────────────────────────────┐
  │  axi2csr 模块:                                        │
  │  - 要求 AW 和 W 同时到达 (简化设计)                    │
  │  - 产生 csr_wr_en 脉冲                                │
  │  - 代码量: ~100 行                                    │
  │                                                       │
  │  DMA CSR 手动桥:                                      │
  │  - Crossbar 输出 AXI4 (可能 AW 先于 W)               │
  │  - DMA 输入 AXI4-Lite (无 ID, 无 burst)              │
  │  - 需要锁存 ID, 过滤非单拍传输                        │
  │  - 代码量: ~40 行 (组合逻辑)                           │
  │                                                       │
  │  为什么不用 axi2csr?                                  │
  │  - DMA 的 CSR 接口不是简单 CSR (有 ready 信号)        │
  │  - axi2csr 输出的是 wr_en/rd_en 脉冲                 │
  │  - DMA 需要 awvalid/wvalid 等 AXI 信号               │
  │                                                       │
  │  为什么不用 axi2axi_lite 桥?                          │
  │  - 没有现成的 axi2axi_lite 模块                       │
  │  - 手动桥更简单, 且只需支持单拍传输                    │
  └───────────────────────────────────────────────────────┘
```

### 为什么 NPU 用 axi2csr 而 DMA 用手动桥？

```
  ┌───────────────────────────────────────────────────────┐
  │  NPU CSR 接口:                                        │
  │  - 纯寄存器读写 (wr_en/rd_en/addr/data)              │
  │  - 无握手信号, 组合逻辑直连                           │
  │  - axi2csr 完美匹配                                   │
  │                                                       │
  │  DMA CSR 接口:                                        │
  │  - AXI4-Lite 协议 (有 awvalid/awready 等)            │
  │  - 需要保持握手时序                                   │
  │  - axi2csr 不适用 (输出不是 AXI 信号)                │
  │                                                       │
  │  结论: 不同的 Slave 接口需要不同的桥接方案            │
  │  这是 SoC 集成中常见的异构性挑战                      │
  └───────────────────────────────────────────────────────┘
```

### 为什么 CPU 需要 axi_lite2axi 桥？

```
  PicoRV32 输出 AXI4-Lite 协议:
  - 无 ID 信号 (所有事务视为同一来源)
  - 无 burst 信号 (每次传输 1 个 beat)
  - 无 size 信号 (固定 4 字节)

  Crossbar 要求 AXI4 协议:
  - 需要 ID 区分事务来源
  - 支持 burst 传输
  - 需要 size 信号

  桥接转换:
  - 添加固定 ID (0x10)
  - awlen=0, wlast=1 (单拍)
  - awsize=2 (4 字节)

  为什么不直接改 PicoRV32?
  - PicoRV32 是第三方 IP, 不宜修改
  - 桥接方案保持模块独立性
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 确定模块清单和接口

```
  模块清单:

  ┌──────────────┬────────────────────┬────────────────────┐
  │ 模块          │ 接口类型           │ 角色                │
  ├──────────────┼────────────────────┼────────────────────┤
  │ PicoRV32     │ AXI4-Lite Master   │ CPU, 控制器         │
  │ DMA          │ AXI4-Lite Slave    │ DMA CSR             │
  │              │ AXI4 Master        │ DMA 数据搬运        │
  │ NPU          │ CSR Slave          │ NPU 控制            │
  │              │ AXI4 Slave         │ NPU 图像存储        │
  │ DDR          │ AXI4 Slave         │ 主存储              │
  └──────────────┴────────────────────┴────────────────────┘

  接口差异分析:
  - CPU 输出 AXI4-Lite, Crossbar 需要 AXI4 → 需要桥
  - DMA CSR 是 AXI4-Lite, Crossbar 输出 AXI4 → 需要桥
  - NPU CSR 是简单信号, Crossbar 输出 AXI4 → 需要 axi2csr
```

### 第 2 步: 设计地址映射

```
  地址空间分配:

  1. 确定各模块的地址范围大小:
     - CPU ROM: 4KB (0x1000)
     - NPU LMEM: 128KB (0x20000) [实际 4KB]
     - DMA CSR: 4KB (0x1000)
     - NPU CSR: 4KB (0x1000)
     - DDR: 256KB (0x40000)

  2. 分配基地址 (避免冲突):
     - 0x0000_0000: CPU ROM (内部, 不经 Crossbar)
     - 0x0000_1000: NPU LMEM
     - 0x0002_1000: DMA CSR
     - 0x0003_0000: NPU CSR
     - 0x1000_0000: CPU RAM (内部, 不经 Crossbar)
     - 0x4000_0000: DDR

  3. 配置 Crossbar 地址路由:
     SLV0: 0x4000_0000 ~ 0x4003_FFFF (DDR)
     SLV1: 0x0000_1000 ~ 0x0002_0FFF (NPU LMEM)
     SLV2: 0x0002_1000 ~ 0x0002_1FFF (DMA CSR)
     SLV3: 0x0003_0000 ~ 0x0003_0FFF (NPU CSR)
```

### 第 3 步: 设计协议桥接

```
  桥接设计清单:

  ┌──────────────────┬────────────────┬────────────────────┐
  │ 桥接              │ 源协议          │ 目标协议            │
  ├──────────────────┼────────────────┼────────────────────┤
  │ axi_lite2axi     │ AXI4-Lite      │ AXI4               │
  │ (CPU → Crossbar) │ (无 ID/burst)  │ (有 ID/burst)      │
  ├──────────────────┼────────────────┼────────────────────┤
  │ 手动桥           │ AXI4           │ AXI4-Lite          │
  │ (Crossbar → DMA) │ (有 ID/burst)  │ (无 ID/burst)      │
  ├──────────────────┼────────────────┼────────────────────┤
  │ axi2csr          │ AXI4           │ 简单 CSR           │
  │ (Crossbar → NPU) │ (有 ID/burst)  │ (wr_en/rd_en)     │
  └──────────────────┴────────────────┴────────────────────┘

  设计要点:
  - 每个桥只做一件事: 协议转换
  - 桥接逻辑应尽量简单 (组合逻辑优先)
  - ID 信号需要锁存后返回 (因为 AXI-Lite 没有 ID)
```

### 第 4 步: 连接信号

```
  信号连接顺序:

  1. 时钟和复位: 所有模块共享 clk 和 resetn
  2. CPU 子系统: CPU → Bridge → Crossbar SLV0
  3. DMA 子系统: DMA CSR ← Crossbar MST2
                 DMA Master → Crossbar SLV1
  4. NPU 子系统: NPU CSR ← Crossbar MST3
                 NPU RAM ← Crossbar SLV1 (DMA 写入)
  5. DDR:        DDR ← Crossbar SLV0
  6. 状态输出:   各模块的 busy/done/pred → SoC 顶层输出
  7. 未用信号:   调试端口接零, 中断接零
```

### 第 5 步: 验证集成

```
  验证策略:
  1. 地址路由验证: 写入各基地址, 确认路由到正确的 Slave
  2. 协议桥验证: 通过桥发送 AXI 事务, 检查时序
  3. 端到端验证: CPU 写 DMA CSR → DMA 搬运 → NPU 推理 → 读结果
  4. 冲突验证: CPU 和 DMA 同时访问不同 Slave, 确认不冲突

  关键检查点:
  - Crossbar 地址解码是否正确
  - ID 信号是否正确锁存和返回
  - 非单拍传输是否被正确拒绝 (SLVERR)
  - 未连接端口是否接零 (避免 X 传播)
```

---

## 设计视角：架构模式与原则

### 模式 1: SoC 集成模式 (SoC Integration Pattern)

```
  核心思想: 用 Crossbar 连接所有 Master 和 Slave, 通过地址路由实现寻址

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  标准 SoC 架构:                                       │
  │                                                       │
  │  ┌──────┐  ┌──────┐                                  │
  │  │ CPU  │  │ DMA  │  Master 端                       │
  │  └──┬───┘  └──┬───┘                                  │
  │     │         │                                      │
  │     ▼         ▼                                      │
  │  ┌──────────────────┐                                │
  │  │   AXI Crossbar   │  互联网络                       │
  │  │   (N x M)        │                                │
  │  └──┬───┬───┬───┬──┘                                │
  │     │   │   │   │                                    │
  │     ▼   ▼   ▼   ▼                                    │
  │  ┌───┐┌───┐┌───┐┌───┐  Slave 端                     │
  │  │DDR││LMEM││DMA││NPU│                               │
  │  └───┘└───┘└───┘└───┘                                │
  │                                                       │
  │  地址路由: 组合逻辑比较地址范围                        │
  │  ID 管理: 不同 Master 使用不同 ID 前缀               │
  │  仲裁: 同一 Slave 的并发访问由 Crossbar 内部仲裁      │
  └───────────────────────────────────────────────────────┘

  通用步骤:
  1. 列出所有 Master 和 Slave
  2. 分配地址空间 (避免重叠)
  3. 配置 Crossbar 参数 (路由表, ID mask)
  4. 连接信号 (注意协议匹配)
  5. 处理未用端口 (接零)
```

### 模式 2: 桥接插入模式 (Bridge Insertion Pattern)

```
  核心思想: 当两个模块的接口协议不匹配时, 插入桥接模块

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  协议不匹配的三种情况:                                 │
  │                                                       │
  │  情况 1: Master 协议 ≠ Crossbar 协议                  │
  │  ┌──────┐    ┌─────────────┐    ┌──────────┐        │
  │  │ CPU  │───►│axi_lite2axi │───►│ Crossbar │        │
  │  │Lite  │    │  (桥接)      │    │  AXI4    │        │
  │  └──────┘    └─────────────┘    └──────────┘        │
  │                                                       │
  │  情况 2: Crossbar 协议 ≠ Slave 协议                   │
  │  ┌──────────┐    ┌─────────┐    ┌──────┐            │
  │  │ Crossbar │───►│手动桥    │───►│ DMA  │            │
  │  │  AXI4    │    │  (桥接)  │    │ Lite │            │
  │  └──────────┘    └─────────┘    └──────┘            │
  │                                                       │
  │  情况 3: Crossbar 协议 ≠ 自定义协议                   │
  │  ┌──────────┐    ┌─────────┐    ┌──────┐            │
  │  │ Crossbar │───►│ axi2csr │───►│ NPU  │            │
  │  │  AXI4    │    │  (桥接)  │    │ CSR  │            │
  │  └──────────┘    └─────────┘    └──────┘            │
  │                                                       │
  │  设计原则:                                             │
  │  - 桥接模块应尽量薄 (只做协议转换, 不做业务逻辑)       │
  │  - 桥接模块应可复用 (axi2csr 可用于任何 CSR Slave)    │
  │  - 特殊情况可用手动组合逻辑桥 (如 DMA CSR)            │
  └───────────────────────────────────────────────────────┘

  桥接选择指南:
  - 有现成 IP → 使用现成 IP (如 axi_lite2axi)
  - 目标是简单寄存器 → 使用 axi2csr
  - 目标是 AXI-Lite Slave → 手动组合逻辑桥
```

### 原则: 接口标准化与适配

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 内部模块可使用自定义接口, 顶层必须标准化  │
  │                                                     │
  │  本设计中的层次:                                     │
  │                                                     │
  │  外部接口 (AXI4):                                   │
  │  - Crossbar 的所有 Master/Slave 端口都是 AXI4       │
  │  - 便于连接任何标准 AXI IP                          │
  │                                                     │
  │  内部接口 (自定义):                                  │
  │  - NPU CSR: wr_en/rd_en/addr/data                  │
  │  - RAM: wr_en/rd_en/addr/data                      │
  │  - 简单、高效、面积小                               │
  │                                                     │
  │  桥接层:                                            │
  │  - axi2csr: AXI4 → NPU CSR                        │
  │  - 手动桥: AXI4 → DMA AXI-Lite                    │
  │  - 职责: 协议转换, 不做业务逻辑                     │
  │                                                     │
  │  好处:                                              │
  │  - 内部模块可自由优化接口                           │
  │  - 外部接口符合行业标准                             │
  │  - 桥接层可独立验证                                 │
  └─────────────────────────────────────────────────────┘
```

---

## 2. 参数化设计

### 2.1 AXI总线参数

```systemverilog
// 文件：src/soc_top.sv，第6-9行
module soc_top #(
  parameter int AXI_ADDR_W = 32,    // 32位地址总线
  parameter int AXI_DATA_W = 32,    // 32位数据总线
  parameter int AXI_ID_W   = 8,     // 8位事务ID
```

### 2.2 存储器配置参数

```systemverilog
// 文件：src/soc_top.sv，第12-19行
// CPU本地存储
parameter [8*128-1:0] LOCAL_ROM_INIT_FILE = "../src/instr_data.dat",  // ROM初始化文件
parameter logic [31:0] CPU_ROM_BASE      = 32'h0000_0000,  // ROM基地址
parameter int          CPU_ROM_AW        = 12,              // ROM地址宽度 (4KB)
parameter logic [31:0] CPU_RAM_BASE      = 32'h1000_0000,  // RAM基地址
parameter int          CPU_RAM_AW        = 12,              // RAM地址宽度 (4KB)

// DDR主存储
parameter int          DDR_SIZE_BYTES    = 256*1024,        // 256KB
parameter [8*128-1:0]  DDR_INIT_FILE     = "",              // DDR初始化文件（可选）
```

### 2.3 外设基地址参数

```systemverilog
// 文件：src/soc_top.sv，第22-23行
parameter logic [31:0] NPU_CSR_BASE  = 32'h0003_0000,  // NPU CSR基地址 (4KB)
parameter logic [31:0] DMA_CSR_BASE  = 32'h0002_1000,  // DMA CSR基地址 (4KB)
```

### 2.4 NPU数据文件参数

```systemverilog
// 文件：src/soc_top.sv，第27-33行
parameter string NPU_IMAGE_DATA_FILE = "../src/npu/image_data.dat",
parameter string NPU_CONV1_FILE      = "../src/npu/conv1.dat",
parameter string NPU_CONV2_FILE      = "../src/npu/conv2.dat",
parameter string NPU_BIAS1_FILE      = "../src/npu/bias1.dat",
parameter string NPU_BIAS2_FILE      = "../src/npu/bias2.dat",
parameter string NPU_FC_WEIGHT_FILE  = "../src/npu/export_cifar/.../fc_weight_i8.memh",
parameter string NPU_FC_BIAS_FILE    = "../src/npu/export_cifar/.../fc_bias_i8.memh"
```

---

## 3. AXI Crossbar地址路由

### 3.1 地址映射表

```
┌─────────────────────────────────────────────────────────────────┐
│                    SoC 地址空间映射                               │
│                                                                 │
│  0x0000_0000 ┌──────────────────────┐                           │
│              │   CPU ROM (4KB)      │ PicoRV32内部ROM            │
│  0x0000_0FFF └──────────────────────┘                           │
│              │                      │                           │
│  0x0000_1000 ┌──────────────────────┐                           │
│              │   NPU LMEM (128KB)   │ Crossbar SLV1             │
│              │   npu_ram (实际4KB)   │ → npu_top.s_ram           │
│  0x0002_0FFF └──────────────────────┘                           │
│                                                                 │
│  0x0002_1000 ┌──────────────────────┐                           │
│              │   DMA CSR (4KB)      │ Crossbar SLV2             │
│              │                      │ → dma_axi_top CSR         │
│  0x0002_1FFF └──────────────────────┘                           │
│                                                                 │
│  0x0003_0000 ┌──────────────────────┐                           │
│              │   NPU CSR (4KB)      │ Crossbar SLV3             │
│              │                      │ → axi2csr → npu_top       │
│  0x0003_0FFF └──────────────────────┘                           │
│                                                                 │
│  0x1000_0000 ┌──────────────────────┐                           │
│              │   CPU RAM (4KB)      │ PicoRV32内部RAM            │
│  0x1000_0FFF └──────────────────────┘                           │
│              │                      │                           │
│  0x4000_0000 ┌──────────────────────┐                           │
│              │   DDR (256KB)        │ Crossbar SLV0             │
│              │                      │ → ddr模块                  │
│  0x4003_FFFF └──────────────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Crossbar配置详解

```systemverilog
// 文件：src/soc_top.sv，第491-516行
axicb_crossbar_top #(
    // 全局参数
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_ID_W(AXI_ID_W), .AXI_DATA_W(AXI_DATA_W),
    .MST_NB(4), .SLV_NB(4),          // 4主4从
    .MST_PIPELINE(0), .SLV_PIPELINE(0), // 无流水线
    .AXI_SIGNALING(1),                // 完整AXI信号
    .USER_SUPPORT(0),                 // 不支持user信号
    .TIMEOUT_ENABLE(0),               // 不使能超时

    // Master 0: CPU (ID mask 0x10)
    .MST0_ROUTES(4'b1111),            // CPU可访问所有4个从设备
    .MST0_ID_MASK(8'h10),             // ID前缀0x10
    .MST0_OSTDREQ_NUM(4),             // 最多4个未完成请求

    // Master 1: DMA (ID mask 0x20)
    .MST1_ROUTES(4'b1111),            // DMA可访问所有4个从设备
    .MST1_ID_MASK(8'h20),             // ID前缀0x20
    .MST1_OSTDREQ_NUM(4),

    // Master 2/3: 未使用（外部Master接口）
    .MST2_ROUTES(4'b0000),
    .MST3_ROUTES(4'b0000),

    // Slave 0: DDR @ 0x4000_0000 - 0x4003_FFFF (256KB)
    .SLV0_START_ADDR(32'h4000_0000),
    .SLV0_END_ADDR(32'h4003_FFFF),

    // Slave 1: NPU LMEM @ 0x0000_1000 - 0x0002_0FFF (128KB)
    .SLV1_START_ADDR(32'h0000_1000),
    .SLV1_END_ADDR(32'h0002_0FFF),

    // Slave 2: DMA CSR @ 0x0002_1000 - 0x0002_1FFF (4KB)
    .SLV2_START_ADDR(32'h0002_1000),
    .SLV2_END_ADDR(32'h0002_1FFF),

    // Slave 3: NPU CSR @ 0x0003_0000 - 0x0003_0FFF (4KB)
    .SLV3_START_ADDR(32'h0003_0000),
    .SLV3_END_ADDR(32'h0003_0FFF)
) u_crossbar ( ... );
```

### 3.3 Crossbar信号连接图

```
           ┌──────────────────────────────────────┐
           │          AXI Crossbar                 │
           │          (4 Masters × 4 Slaves)       │
           │                                       │
  SLV0 ────┤  ┌─────┐   ┌─────┐   ┌─────┐        │
  (CPU)    │  │ MST0│   │ MST1│   │MST2 │ MST3   │
           │  │     │   │     │   │     │  │      │
  SLV1 ────┤  │ DDR │   │NPU  │   │ DMA │ NPU    │
  (DMA)    │  │     │   │LMEM │   │ CSR │  CSR   │
           │  │     │   │     │   │     │  │      │
  SLV2 ────┤  └──┬──┘   └──┬──┘   └──┬──┘ └─┬──┘ │
  (未用)    │     │         │         │       │    │
           │     ▼         ▼         ▼       ▼    │
  SLV3 ────┤   DDR      npu_ram   DMA CSR  axi2csr│
  (未用)    │   模块      (4KB)    寄存器    桥     │
           └──────────────────────────────────────┘

  Master端口:
    SLV0 (CPU):  cpu_axi_*     ← 来自axi_lite2axi桥
    SLV1 (DMA):  dma_axi_*     ← 来自dma_axi_top

  Slave端口:
    MST0 (DDR):     xbar_mst0_* → ddr模块
    MST1 (NPU LMEM): xbar_mst1_* → npu_top.s_ram_*
    MST2 (DMA CSR):  xbar_mst2_* → DMA CSR桥接逻辑
    MST3 (NPU CSR):  xbar_mst3_* → axi2csr桥
```

---

## 4. CPU子系统

### 4.1 PicoRV32实例化

```systemverilog
// 文件：src/soc_top.sv，第329-355行
picorv32_axi #(
    .ENABLE_TRACE         (1),                    // 使能trace输出
    .PROGADDR_RESET       (32'h0000_0000),        // 复位向量
    .PROGADDR_IRQ         (32'h0000_0010),        // 中断向量
    .LOCAL_ROM_BASE       (CPU_ROM_BASE),          // 内部ROM基地址
    .LOCAL_ROM_ADDR_WIDTH (CPU_ROM_AW),            // ROM地址宽度
    .LOCAL_RAM_BASE       (CPU_RAM_BASE),          // 内部RAM基地址
    .LOCAL_RAM_ADDR_WIDTH (CPU_RAM_AW),            // RAM地址宽度
    .LOCAL_ROM_INIT_FILE  (LOCAL_ROM_INIT_FILE)    // 程序初始化文件
) u_cpu (
    .clk(clk), .resetn(resetn),
    .trap(cpu_trap_o),                             // 陷阱输出
    .mem_axi_awvalid(cpu_lite_awvalid),            // AXI4-Lite接口
    ...
    .trace_valid(trace_valid), .trace_data(trace_data)  // Trace调试
);
```

**PicoRV32关键特性：**
- 32位RISC-V RV32IMC处理器
- 内置4KB ROM和4KB RAM（地址映射到AXI空间之外，直接访问）
- AXI4-Lite主接口用于访问外部存储器和外设
- 支持trace输出用于调试

### 4.2 AXI4-Lite到AXI4桥接

CPU输出AXI4-Lite协议，需要转换为AXI4才能连接到Crossbar：

```systemverilog
// 文件：src/soc_top.sv，第360-391行
axi_lite2axi #(
    .DATA_WIDTH(AXI_DATA_W),
    .ADDR_WIDTH(AXI_ADDR_W),
    .ID_WIDTH(AXI_ID_W)
) u_cpu_bridge (
    .aclk(clk), .aresetn(resetn),
    // AXI4-Lite Slave端 (连接CPU)
    .s_axi_lite_awaddr(cpu_lite_awaddr),
    .s_axi_lite_awvalid(cpu_lite_awvalid),
    .s_axi_lite_awready(cpu_lite_awready),
    ...
    // AXI4 Master端 (连接Crossbar SLV0)
    .m_axi_awid(cpu_axi_awid),        // 固定ID = 0x10
    .m_axi_awlen(8'd0),               // 单拍传输
    .m_axi_awsize(3'd2),              // 4字节
    .m_axi_awburst(2'b01),            // INCR模式
    .m_axi_wlast(1'b1),               // 总是last
    ...
);
```

**桥接要点：**
- AXI4-Lite没有ID、burst、size信号，桥自动填充默认值
- `awlen=0`表示每次传输只有一个beat（单拍）
- `wlast=1`因为只有1个beat
- ID固定为`M_AXI_ID = 8'h10`

```
  AXI4-Lite (CPU)          AXI4 (Crossbar)
  ┌──────────────┐         ┌──────────────┐
  │ awaddr       │────────►│ awid=0x10    │
  │ awvalid      │────────►│ awaddr       │
  │ awready      │◄────────│ awlen=0      │
  │              │         │ awsize=2     │
  │ wdata        │────────►│ awburst=INCR │
  │ wstrb        │────────►│ awvalid      │
  │ wvalid       │────────►│ awready      │
  │ wready       │◄────────│              │
  │              │         │ wdata        │
  │ bresp        │◄────────│ wstrb        │
  │ bvalid       │◄────────│ wlast=1      │
  │ bready       │────────►│ wvalid       │
  └──────────────┘         └──────────────┘
```

---

## 5. DMA控制器连接

### 5.1 DMA双接口架构

DMA有两个AXI接口：
1. **Slave AXI-Lite**：CPU通过此接口配置DMA寄存器
2. **Master AXI4**：DMA通过此接口执行数据搬运

```systemverilog
// 文件：src/soc_top.sv，第396-436行
dma_axi_top u_dma (
    .clk(clk), .rst(rst),
    .dma_done_o(dma_done_o),           // DMA完成中断
    .dma_error_o(dma_error_o),         // DMA错误中断

    // Slave AXI-Lite (来自Crossbar MST2)
    .dma_s_awaddr(dma_csr_awaddr),
    .dma_s_awvalid(dma_csr_awvalid),
    .dma_s_awready(dma_csr_awready),
    ...

    // Master AXI4 (连接Crossbar SLV1)
    .dma_m_awid(dma_axi_awid),         // ID = 0x20
    .dma_m_awaddr(dma_axi_awaddr),
    .dma_m_awlen(dma_axi_awlen),       // 支持burst传输
    ...
);
```

### 5.2 DMA CSR桥接逻辑

Crossbar的MST2输出AXI4协议，但DMA的CSR接口是AXI4-Lite。soc_top中用组合逻辑手动实现桥接：

```systemverilog
// 文件：src/soc_top.sv，第441-481行

// 写ID寄存器
always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        mst2_wr_id_q <= '0;
        mst2_rd_id_q <= '0;
    end else begin
        if (xbar_mst2_awvalid && xbar_mst2_awready)
            mst2_wr_id_q <= xbar_mst2_awid;  // 锁存写ID
        if (xbar_mst2_arvalid && xbar_mst2_arready)
            mst2_rd_id_q <= xbar_mst2_arid;  // 锁存读ID
    end
end

// 组合逻辑桥接
always_comb begin
    // 只接受单拍、4字节的传输（AXI-Lite约束）
    dma_csr_awvalid = xbar_mst2_awvalid &&
                      (xbar_mst2_awlen == 8'd0) &&   // 单拍
                      (xbar_mst2_awsize == 3'd2);     // 4字节
    dma_csr_awaddr  = xbar_mst2_awaddr;
    dma_csr_wvalid  = xbar_mst2_wvalid;
    dma_csr_wdata   = xbar_mst2_wdata;
    dma_csr_wstrb   = xbar_mst2_wstrb;
    dma_csr_bready  = xbar_mst2_bready;
    dma_csr_arvalid = xbar_mst2_arvalid &&
                      (xbar_mst2_arlen == 8'd0) &&
                      (xbar_mst2_arsize == 3'd2);
    ...

    // 反向连接：DMA响应 → Crossbar
    xbar_mst2_awready = dma_csr_awready;
    xbar_mst2_wready  = dma_csr_wready;
    xbar_mst2_bvalid  = dma_csr_bvalid;
    xbar_mst2_bresp   = dma_csr_bresp;
    xbar_mst2_bid     = mst2_wr_id_q;   // 返回锁存的ID
    ...
end
```

**桥接设计要点：**
- 通过检查`awlen==0`和`awsize==2`过滤掉非单拍传输（产生SLVERR）
- ID信号需要锁存一拍后返回，因为AXI-Lite没有ID概念
- `rlast`固定为1（单拍传输）

---

## 6. NPU CSR桥接

### 6.1 axi2csr模块

axi2csr将AXI4事务转换为简单的寄存器读写接口：

```systemverilog
// 文件：src/soc_top.sv，第714-756行
axi2csr #(
    .AXI_ADDR_W (AXI_ADDR_W),
    .AXI_DATA_W (AXI_DATA_W),
    .AXI_ID_W   (AXI_ID_W),
    .CSR_ADDR_W (8)              // 8位CSR地址
) u_npu_csr_bridge (
    .clk       (clk),
    .rst_n     (resetn),
    // AXI4 Slave (来自Crossbar MST3)
    .s_awvalid (xbar_mst3_awvalid),
    .s_awready (xbar_mst3_awready),
    ...
    // Simple CSR Master (连接NPU)
    .csr_wr_en (npu_csr_wr_en),
    .csr_rd_en (npu_csr_rd_en),
    .csr_addr  (npu_csr_addr),
    .csr_wdata (npu_csr_wdata),
    .csr_rdata (npu_csr_rdata)
);
```

### 6.2 axi2csr内部工作原理

```systemverilog
// 文件：src/axi_crossbar/axi2csr.sv，第64-81行

// 空闲条件：没有待处理的响应
wire idle = !bvalid_r && !rvalid_r;

// 写接受：AW和W同时到达且空闲
wire wr_accept = idle && s_awvalid && s_wvalid;
// 读接受：AR到达、无写请求且空闲
wire rd_accept = idle && s_arvalid && !s_awvalid;

// Ready信号
assign s_awready = wr_accept;   // 写地址ready
assign s_wready  = wr_accept;   // 写数据ready（同时接受）
assign s_arready = rd_accept;   // 读地址ready

// CSR输出
assign csr_wr_en = wr_accept;   // 写使能脉冲
assign csr_rd_en = rd_accept;   // 读使能脉冲
assign csr_addr  = wr_accept ? s_awaddr[7:0] :   // 写地址
                   rd_accept ? s_araddr[7:0] : addr_r;
assign csr_wdata = s_wdata;
```

**关键设计：** axi2csr要求AW和W同时到达（与AXI4协议允许的AW先于W到达不同），这简化了设计但限制了兼容性。对于CPU的单拍传输，这个约束自然满足。

```
时序图：写操作
         ___     ___     ___     ___
clk   __|   |___|   |___|   |___|   |___
          ┌───────────────┐
awvalid ──┘               └───────────────
          ┌───────────────┐
wvalid  ──┘               └───────────────
          ┌───────────────┐
awready ──┘               └───────────────
          ┌───────────────┐
wready  ──┘               └───────────────
                              ┌───────────
csr_wr_en ────────────────────┘
                              ┌───────────
bvalid  ──────────────────────┘
```

---

## 7. NPU顶层连接

### 7.1 NPU实例化

```systemverilog
// 文件：src/soc_top.sv，第766-845行
npu_top #(
    .IMAGE_DATA_FILE (NPU_IMAGE_DATA_FILE),
    .CONV1_FILE      (NPU_CONV1_FILE),
    .CONV2_FILE      (NPU_CONV2_FILE),
    .BIAS1_FILE      (NPU_BIAS1_FILE),
    .BIAS2_FILE      (NPU_BIAS2_FILE),
    .FC_WEIGHT_FILE  (NPU_FC_WEIGHT_FILE),
    .FC_BIAS_FILE    (NPU_FC_BIAS_FILE)
) u_npu (
    .clk       (clk),
    .rst_n     (resetn),

    // CSR接口 (来自axi2csr桥)
    .csr_wr_en (npu_csr_wr_en),
    .csr_rd_en (npu_csr_rd_en),
    .csr_addr  (npu_csr_addr),
    .csr_wdata (npu_csr_wdata),
    .csr_rdata (npu_csr_rdata),

    // 状态输出
    .busy      (npu_busy_i),
    .done      (npu_done_i),

    // 调试端口（SoC中未使用，全部接零）
    .dbg_sa_rd_en    (1'b0),        // 未连接
    .dbg_sa_rd_addr  ('0),
    .dbg_sa_rd_data  (),            // 悬空
    .dbg_result_rd_en  (1'b0),
    .dbg_result_rd_addr('0),
    .dbg_result_rd_data(),
    .dbg_pool_rd_en    (1'b0),
    .dbg_pool_rd_addr  ('0),
    .dbg_pool_rd_data  (),
    .dbg_logit_rd_en   (1'b0),
    .dbg_logit_rd_addr ('0),
    .dbg_logit_rd_data (),

    // 推理结果
    .pred_valid    (npu_pred_valid_i),
    .pred_class_id (npu_pred_class_id_i),
    .pred_logit    (npu_pred_logit_i),

    // MAC调试（未使用）
    .mac_dbg_tile_valid(),
    .mac_dbg_tile_data (),

    // AXI4 Slave (DMA写入图像，连接Crossbar MST1)
    .s_ram_awvalid (xbar_mst1_awvalid),
    .s_ram_awready (xbar_mst1_awready),
    .s_ram_awaddr  (xbar_mst1_awaddr),
    ...
    .s_ram_rid     (xbar_mst1_rid)
);
```

### 7.2 NPU信号连接汇总

```
┌───────────────────────────────────────────────────────────────┐
│ npu_top 信号连接                                               │
│                                                               │
│ CSR控制路径:                                                   │
│   Crossbar MST3 → axi2csr → csr_wr_en/rd_en/addr/wdata       │
│                             ← csr_rdata                       │
│                                                               │
│ 数据路径 (DMA写入图像):                                         │
│   DMA Master → Crossbar MST1 → s_ram_aw/w/b/ar/r              │
│                                  → npu_ram (4KB)              │
│                                                               │
│ 状态输出:                                                      │
│   npu_busy_i  → npu_busy (SoC顶层输出)                         │
│   npu_done_i  → npu_done (SoC顶层输出)                         │
│   pred_valid  → npu_pred_valid (SoC顶层输出)                   │
│   pred_class_id → npu_pred_class_id (SoC顶层输出)              │
│   pred_logit  → npu_pred_logit (SoC顶层输出)                   │
│                                                               │
│ 调试端口: 全部接零（SoC中不使用）                                 │
│   dbg_sa_rd_en = 0                                            │
│   dbg_result_rd_en = 0                                        │
│   dbg_pool_rd_en = 0                                          │
│   dbg_logit_rd_en = 0                                         │
└───────────────────────────────────────────────────────────────┘
```

---

## 8. DDR存储器连接

### 8.1 DDR模块接口

```systemverilog
// 文件：src/soc_top.sv，第682-703行
ddr #(
    .AXI_ID_W(AXI_ID_W),
    .AXI_ADDR_W(AXI_ADDR_W),
    .AXI_DATA_W(AXI_DATA_W),
    .DDR_SIZE_BYTES(DDR_SIZE_BYTES),   // 256KB
    .DDR_INIT_FILE(DDR_INIT_FILE)
) u_ddr (
    .aclk(clk), .aresetn(resetn),
    // 直接连接Crossbar MST0
    .s_awvalid(xbar_mst0_awvalid),
    .s_awready(xbar_mst0_awready),
    .s_awaddr(xbar_mst0_awaddr),
    ...
);
```

### 8.2 DDR内部状态机

DDR模块实现了完整的AXI4 Slave协议，包含Round-Robin仲裁：

```
DDR内部状态机:
  ┌──────────┐
  │  ST_IDLE  │◄─────────────────────────┐
  └────┬─────┘                          │
       │                                │
       ├─ AR先到 ──→ ST_RDATA ──rlast──→│
       │                                │
       ├─ AW先到 ──→ ST_WDATA ──wlast──→ ST_WRESP ──bready──→│
       │                                │
       └─ 同时到 ──→ RR选择 ──→ (同上)  │
                     (rr_sel_ff翻转)     │

  Round-Robin仲裁: rr_sel_ff在每次接受后翻转
  奇数次优先读，偶数次优先写
```

---

## 9. 中断和状态信号汇聚

### 9.1 SoC顶层输出信号

```systemverilog
// 文件：src/soc_top.sv，第38-49行
// 中断输出
output logic dma_done_o,      // DMA完成中断
output logic dma_error_o,     // DMA错误中断
output logic cpu_trap_o,      // CPU陷阱（异常）

// NPU状态输出
output logic       npu_busy,          // NPU忙标志
output logic       npu_done,          // NPU完成脉冲
output logic       npu_pred_valid,    // 推理结果有效
output logic [3:0] npu_pred_class_id, // 预测类别
output logic [7:0] npu_pred_logit     // 预测置信度
```

### 9.2 信号路由

```
┌──────────────────────────────────────────────────────────────┐
│                    SoC 状态/中断信号路由                       │
│                                                              │
│  dma_axi_top                                                 │
│  ├── dma_done_o  ────────────────────► SoC dma_done_o        │
│  └── dma_error_o ────────────────────► SoC dma_error_o       │
│                                                              │
│  picorv32_axi                                                │
│  └── trap  ──────────────────────────► SoC cpu_trap_o        │
│                                                              │
│  npu_top                                                     │
│  ├── busy (= conv_busy||fc_busy||top_state!=IDLE)            │
│  │   └───────────────────────────────► SoC npu_busy          │
│  ├── done (= top_done_pulse)                                 │
│  │   └───────────────────────────────► SoC npu_done          │
│  ├── pred_valid ─────────────────────► SoC npu_pred_valid    │
│  ├── pred_class_id ─────────────────► SoC npu_pred_class_id │
│  └── pred_logit ────────────────────► SoC npu_pred_logit    │
│                                                              │
│  内部未使用信号:                                               │
│  ├── trace_valid, trace_data  (CPU trace, 仿真用)             │
│  ├── pcpi_*                   (协处理器接口, 接零)             │
│  └── irq, eoi                 (中断输入, 接零)                │
└──────────────────────────────────────────────────────────────┘
```

---

## 10. 完整数据流路径

### 10.1 NPU推理的端到端数据流

```
步骤1: CPU配置DMA (AXI4-Lite → Bridge → Crossbar → DMA CSR)
  CPU写DMA_CSR_BASE+0x00: src_addr = DDR中的图像地址 (0x4000_0000)
  CPU写DMA_CSR_BASE+0x04: dst_addr = NPU LMEM地址 (0x0000_1000)
  CPU写DMA_CSR_BASE+0x08: length   = 3072 (32×32×3)
  CPU写DMA_CSR_BASE+0x0C: control  = START

步骤2: DMA搬运图像 (DDR → Crossbar → npu_ram)
  DMA Master读DDR (0x4000_0000, burst)
  DMA Master写npu_ram (0x0000_1000, burst)
  完成后: dma_done_o中断

步骤3: CPU启动NPU (AXI4-Lite → Bridge → Crossbar → axi2csr → npu)
  CPU写NPU_CSR_BASE+0x00: CTRL = 0x01 (START)
  → npu_top状态机: T_IDLE → T_LOAD_IMG → T_WAIT_CONV → T_WAIT_FC → T_IDLE

步骤4: CPU读取结果
  CPU读NPU_CSR_BASE+0x20: PRED寄存器
  → class_id + logit
```

### 10.2 事务追踪图

```
时间轴 ─────────────────────────────────────────────────────►

CPU (AXI4-Lite):
  │ wr DMA_CSR    │ wr DMA_CSR   │ wr DMA_CSR  │ wr DMA_CSR │
  │ src_addr      │ dst_addr     │ length      │ START      │
  │               │              │             │            │
  ▼               ▼              ▼             ▼            │
Bridge:                                                           │
  │ AW+W 单拍    │ AW+W 单拍    │ AW+W 单拍  │ AW+W 单拍  │
  ▼               ▼              ▼             ▼            │
Crossbar:                                                         │
  │ → MST2       │ → MST2       │ → MST2     │ → MST2     │
  ▼               ▼              ▼             ▼            │
DMA CSR:                                                          │
  │ 写SRC_REG    │ 写DST_REG    │ 写LEN_REG  │ 写CTRL_REG │
  │               │              │             │            │
  ▼               ▼              ▼             ▼            │
DMA Master:                                                       │
  │              │              │             │ 读DDR      │
  │              │              │             │ 写npu_ram  │
  │              │              │             │            │
  │              │              │             │ dma_done   │
  │              │              │             │            │
CPU:                                                              │
  │              │              │             │ wr NPU_CSR │
  │              │              │             │ CTRL=0x01  │
  │              │              │             │            │
NPU:                                                              │
  │              │              │             │ 推理执行    │
  │              │              │             │ ...        │
  │              │              │             │ done=1     │
  │              │              │             │            │
CPU:                                                              │
  │              │              │             │ rd NPU_CSR │
  │              │              │             │ PRED       │
  ◄────────────────────────────────────────────────────────┘
```

---

## 11. 未连接信号处理

soc_top中有一些信号被显式接零或悬空：

```systemverilog
// 文件：src/soc_top.sv，第288-299行
// 桥不输出 awprot/arprot，默认 0
assign cpu_axi_awprot = 3'b000;
assign cpu_axi_arprot = 3'b000;

// PCPI协处理器接口（未使用）
assign pcpi_wr = 0; assign pcpi_rd = 0;
assign pcpi_wait = 0; assign pcpi_ready = 0;

// 中断输入（未使用）
assign irq = 0;
```

**为什么IRQ接零？** 当前设计中CPU通过轮询方式检测DMA和NPU状态。如果要使用中断方式，需要：
1. 将`dma_done_o`和`npu_done`连接到中断控制器
2. 中断控制器输出连接到`irq`
3. CPU软件中使能中断并编写ISR

---

## 12. Crossbar Slave 2/3未使用端口

Crossbar有4个Slave输入端口（连接外部Master），但只使用了SLV0（CPU）和SLV1（DMA）：

```systemverilog
// 文件：src/soc_top.sv，第562-588行
// Slave 2/3 未连接（外部Master）
.slv2_aclk(clk), .slv2_aresetn(resetn), .slv2_srst(rst),
.slv2_awvalid(1'b0),           // 全部接零
.slv2_awaddr('0), .slv2_awlen('0), .slv2_awsize('0),
...
.slv3_aclk(clk), .slv3_aresetn(resetn), .slv3_srst(rst),
.slv3_awvalid(1'b0),           // 全部接零
...
```

这些端口为SoC扩展预留。例如可以添加：
- 第二个DMA引擎
- 调试接口（JTAG → AXI）
- 外部主设备（PCIe、以太网等）

---

## 13. 关键知识点总结

1. **参数化设计**：所有关键参数（地址宽度、数据宽度、存储大小、基地址）都通过parameter传递，便于SoC配置和移植。

2. **四层协议转换**：CPU的AXI4-Lite → axi_lite2axi → AXI4 → Crossbar → axi2csr → CSR简单接口。每一层都解决特定的协议差异。

3. **地址路由是组合逻辑**：Crossbar的地址解码是纯组合逻辑（比较地址范围），不引入额外延迟。

4. **ID管理**：不同Master使用不同的ID前缀（CPU=0x10, DMA=0x20），Crossbar通过ID_MASK区分事务来源。

5. **调试端口接零**：在SoC集成中，NPU的调试端口被接零。如果需要在线调试，可以通过添加调试总线或使用ILA核来连接这些端口。

6. **中断vs轮询**：当前设计使用轮询方式。`dma_done_o`和`npu_done`信号已经输出到顶层，可以方便地接入中断控制器实现中断驱动模式。

---

## 14. 动手练习

### 练习1：地址解码验证

给定以下CPU访问地址，判断每个地址路由到哪个从设备：

```
(a) 0x0000_0500  → ???
(b) 0x0001_0000  → ???
(c) 0x0002_1004  → ???
(d) 0x0003_0020  → ???
(e) 0x4001_0000  → ???
(f) 0x2000_0000  → ???
```

<details>
<summary>参考答案</summary>

```
(a) 0x0000_0500 → CPU ROM (内部，不经Crossbar)
(b) 0x0001_0000 → SLV1: NPU LMEM (0x0000_1000~0x0002_0FFF)
(c) 0x0002_1004 → SLV2: DMA CSR (0x0002_1000~0x0002_1FFF)
(d) 0x0003_0020 → SLV3: NPU CSR (0x0003_0000~0x0003_0FFF)
(e) 0x4001_0000 → SLV0: DDR (0x4000_0000~0x4003_FFFF)
(f) 0x2000_0000 → 无匹配，返回SLVERR/DECERR
```
</details>

### 练习2：添加SPI外设

假设要添加一个SPI控制器作为SoC的新外设：
- 基地址：0x0004_0000
- 大小：4KB
- 接口：AXI4-Lite Slave

列出需要修改的内容：
1. Crossbar参数需要如何调整？
2. 需要添加哪些新的信号线？
3. 是否需要额外的协议桥？

<details>
<summary>提示</summary>

```
方案A：使用现有的Crossbar Slave端口
  - 使用SLV2或SLV3（当前未连接的Master端口）
  - 添加axi2csr或axi_lite桥
  - 添加SLV4地址范围配置

方案B：扩展Crossbar
  - 将MST_NB/SLV_NB从4改为5
  - 添加SLV4的地址配置 (0x0004_0000~0x0004_0FFF)
  - 添加SLV4端口的信号连接

方案C：使用GPIO方式
  - 在CPU的内部RAM空间映射SPI寄存器
  - 不需要修改Crossbar
```
</details>

### 练习3：中断驱动改造

将当前的轮询式NPU控制改为中断驱动方式。画出改造后的信号连接图，并写出CPU端的中断处理伪代码。

### 练习4：性能分析

计算CPU通过AXI4-Lite写入4KB图像数据到npu_ram所需的时钟周期数。假设：
- AXI4-Lite每次传输4字节
- Crossbar延迟2个周期
- 每次传输需要约5个周期（AW+W+B握手）

<details>
<summary>参考答案</summary>

```
4KB = 4096字节 = 1024次AXI4-Lite传输
每次传输: 5个周期
总周期: 1024 × 5 = 5120个周期

优化方案：
- 如果CPU支持burst，可以通过bridge发送burst传输
- 或者使用DMA搬运（从DDR到npu_ram），burst模式下约 4096/4 = 1024 beats × 2周期 = 2048周期
```
</details>

---

## 15. 下一讲预告

下一讲将分析SoC的验证环境（testbench），包括：
- soc_tb.sv的测试架构
- AXI BFM（总线功能模型）的使用
- 测试用例的编写方法
- 覆盖率收集与分析
