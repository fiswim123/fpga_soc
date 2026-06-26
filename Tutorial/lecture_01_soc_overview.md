# 第1讲 SoC全景 — 从一张图开始

> 本讲目标：建立整个异构处理器的全局认知，理解"谁和谁连接、数据怎么流、代码在哪里"。
> 学完本讲后，你应该能画出完整的SoC框图并解释每个模块的角色。

---

## 1.1 项目背景

本项目来自**第九届中国研究生创"芯"大赛飞腾企业命题——赛题三：智核融合·低耗强算**。

赛题核心要求：

- 设计一款 **32位低功耗RISC处理器 + 32位NPU** 的异构SoC
- 通过 **AXI总线** 实现CPU与NPU的高效协同通信
- 面向物联网、边缘AI推理场景
- CPU负责逻辑控制与任务调度，NPU负责矩阵/卷积并行计算

本项目的具体任务是：**在CIFAR-10数据集上完成10类图像分类推理**。

---

## 1.2 什么是异构SoC？

在深入代码之前，先理解"异构"的含义：

```text
同构处理器：所有核心相同（如多核CPU，每个核都能做同样的事）
异构处理器：不同类型的核心各司其职（CPU做控制，NPU做计算）
```

为什么需要异构？

```text
场景：一张32×32的RGB图片要做卷积分类

如果只用CPU：
  - 需要执行 5×5×3×32 = 2400 次乘累加（仅Conv1的一个输出像素）
  - 整张图 32×32×32 = 32,768 个输出像素
  - 总计约 780万次 乘累加
  - PicoRV32 @ 200MHz，每条指令1周期，乘累加需要2条指令
  - 耗时：780万 × 2 / 200MHz ≈ 78ms

如果用NPU（1280个MAC并行）：
  - 1280个MAC同时工作
  - 耗时：~22,715 cycles / 200MHz ≈ 0.114ms
  - 快了约 680倍！
```

这就是异构的意义：**让合适的核心做合适的事**。

---

## 1.3 SoC整体架构

下面是本项目的完整SoC架构框图：

```text
┌─────────────────────────────────────────────────────────────────────┐
│                              soc_top                                │
│                                                                     │
│  ┌──────────┐    AXI-Lite     ┌────────────┐    AXI4               │
│  │          ├────────────────►│ axi_lite2axi├───────┐              │
│  │ PicoRV32 │                 └────────────┘       │              │
│  │  (CPU)   │    ┌────────┐                        │              │
│  │          │    │ 4KB    │               ┌────────▼────────┐     │
│  │          │◄──►│ ROM    │               │                 │     │
│  │          │    │ +RAM   │               │  AXI Crossbar   │     │
│  └──────────┘    └────────┘               │    4 × 4        │     │
│                                            │                 │     │
│  ┌──────────┐    AXI4 Master              │  slv0: CPU      │     │
│  │          ├─────────────────────────────►│  slv1: DMA      │     │
│  │   DMA    │                             │  slv2: (空)     │     │
│  │Controller│    AXI-Lite Slave           │  slv3: (空)     │     │
│  │          │◄────────────────────────┐   │                 │     │
│  └──────────┘                         │   │  mst0: DDR      │     │
│                                       │   │  mst1: NPU RAM  │     │
│                                       │   │  mst2: DMA CSR  │     │
│                                       │   │  mst3: NPU CSR  │     │
│                                       │   └──┬───┬───┬───┬─┘     │
│                                       │      │   │   │   │        │
│  ┌────────────────────────────────────┼──────┼───┼───┼───┼──────┐ │
│  │                                    │      │   │   │   │      │ │
│  │  ┌─────┐  ┌──────────┐  ┌───────┐ │ ┌────▼─┐│   │   │      │ │
│  │  │     │  │          │  │ axi2csr│ │ │      ││   │   │      │ │
│  │  │ DDR │  │ NPU RAM  │  │  桥   │ │ │axi2axi│   │   │      │ │
│  │  │256KB│  │  128KB   │  │       │ │ │_lite  ││   │   │      │ │
│  │  │     │  │          │  │       │ │ │ 桥   ││   │   │      │ │
│  │  └──▲──┘  └────▲─────┘  └───▲───┘ │ └──▲───┘│   │   │      │ │
│  │     │          │             │     │    │    │   │   │      │ │
│  │     └──────────┼─────────────┼─────┼────┼────┘   │   │      │ │
│  │                │             │     │             │   │      │ │
│  │            ┌───┴─────────────┴─────┴─────────────┘   │      │ │
│  │            │                                         │      │ │
│  │            │         NPU 子系统                       │      │ │
│  │            │  ┌─────────────────────────────────────┐ │      │ │
│  │            │  │ npu_top                             │ │      │ │
│  │            │  │  ┌──────────┐  ┌──────────────────┐│ │      │ │
│  │            │  │  │ npu_csr  │  │ conv_top         ││ │      │ │
│  │            │  │  │ _regs    │  │  ┌──────────────┐││ │      │ │
│  │            │  │  │          │  │  │ mac_array    │││ │      │ │
│  │            │  │  │ CTRL     │  │  │ 40×32        │││ │      │ │
│  │            │  │  │ STATUS   │  │  │ (1280 PE)    │││ │      │ │
│  │            │  │  │ PRED     │  │  └──────────────┘││ │      │ │
│  │            │  │  └──────────┘  │  ┌──────────────┐││ │      │ │
│  │            │  │                │  │ ppu_maxpool  │││ │      │ │
│  │            │  │                │  └──────────────┘││ │      │ │
│  │            │  │                └──────────────────┘│ │      │ │
│  │            │  │  ┌──────────────────────────────┐  │ │      │ │
│  │            │  │  │ gap_fc_logits                │  │ │      │ │
│  │            │  │  │ GAP + FC(64→10) + Argmax     │  │ │      │ │
│  │            │  │  └──────────────────────────────┘  │ │      │ │
│  │            │  └─────────────────────────────────────┘ │      │ │
│  │            └─────────────────────────────────────────┘      │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 各模块角色一览

| 模块 | 角色 | 类比 |
|------|------|------|
| **PicoRV32 (CPU)** | 大脑：执行固件、配置外设备、调度任务 | 公司CEO |
| **AXI Crossbar** | 神经系统：连接所有主设备和从设备 | 公司内部通信网络 |
| **DMA Controller** | 搬运工：在DDR和NPU RAM之间搬运数据 | 快递员 |
| **NPU** | 肌肉：执行卷积/矩阵乘法等密集计算 | 工厂流水线 |
| **DDR** | 仓库：存储程序和数据 | 仓库 |
| **NPU RAM** | 工作台：NPU就近取数据的地方 | 工厂原料区 |

---

## 1.4 地址映射表 — SoC的"门牌号"

CPU访问外设时，靠的是**地址**。每个外设被分配一个地址范围，就像每栋楼有门牌号。

```text
┌─────────────────────────────────────────────────────────┐
│                    32位地址空间 (4GB)                     │
├──────────────┬──────────┬───────────────────────────────┤
│ 地址范围      │ 大小     │ 设备                          │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x0000_0000  │          │                               │
│     ~        │ 4KB      │ CPU ROM（固件代码）            │
│ 0x0000_0FFF  │          │                               │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x0000_1000  │          │                               │
│     ~        │ 128KB    │ NPU Local RAM（图像/特征图）   │
│ 0x0002_0FFF  │          │                               │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x0002_1000  │          │                               │
│     ~        │ 4KB      │ DMA CSR寄存器                 │
│ 0x0002_1FFF  │          │                               │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x0003_0000  │          │                               │
│     ~        │ 4KB      │ NPU CSR寄存器                 │
│ 0x0003_0FFF  │          │                               │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x1000_0000  │          │                               │
│     ~        │ 4KB      │ CPU RAM（栈/变量）            │
│ 0x1000_0FFF  │          │                               │
├──────────────┼──────────┼───────────────────────────────┤
│ 0x4000_0000  │          │                               │
│     ~        │ 256KB    │ DDR（主存：程序+数据）         │
│ 0x4003_FFFF  │          │                               │
└──────────────┴──────────┴───────────────────────────────┘
```

### 地址映射的硬件实现

在 `src/soc_top.sv` 第491-515行，Crossbar的参数配置定义了这些地址范围：

```systemverilog
// mst0: DDR (256KB @ 0x4000_0000)
.SLV0_START_ADDR(32'h4000_0000), .SLV0_END_ADDR(32'h4003_FFFF),

// mst1: NPU LMEM (128KB @ 0x0000_1000)
.SLV1_START_ADDR(32'h0000_1000), .SLV1_END_ADDR(32'h0002_0FFF),

// mst2: DMA CSR (4KB @ 0x0002_1000)
.SLV2_START_ADDR(32'h0002_1000), .SLV2_END_ADDR(32'h0002_1FFF),

// mst3: NPU CSR (4KB @ 0x0003_0000)
.SLV3_START_ADDR(32'h0003_0000), .SLV3_END_ADDR(32'h0003_0FFF),
```

当CPU发出地址`0x4000_0000`的读请求时，Crossbar内部的地址解码器会判断：
- `0x4000_0000` 落在 `SLV0_START_ADDR ~ SLV0_END_ADDR` 范围内
- 因此将请求路由到 **mst0端口**（连接DDR）

这就是**地址映射**的硬件本质：**高位比较 + 多路选择**。

---

## 1.5 数据流全景 — 一张图像的旅程

让我们追踪一张CIFAR-10图像从DDR到分类结果的完整路径：

### 阶段1：CPU启动

```text
CPU执行固件 (instr_data.S):
  1. 配置DMA描述符:
     - SRC_ADDR = 0x4000_0000 (DDR中的图像数据)
     - DST_ADDR = 0x0000_1000 (NPU RAM)
     - NUM_BYTES = 4096 (1024像素 × 4字节)
  2. 写DMA CONTROL寄存器，启动传输
```

CPU通过**AXI-Lite**接口发出写操作：

```text
CPU → AXI-Lite → axi_lite2axi(桥) → AXI4 → Crossbar(slv0)
  → 地址解码: 0x0002_1000 命中 DMA CSR (mst2)
  → axi2axi_lite(桥) → AXI-Lite → DMA CSR寄存器
```

### 阶段2：DMA搬运

```text
DMA控制器启动:
  1. 读端口: 发AXI4读请求到DDR (0x4000_0000)
     DMA → AXI4 → Crossbar(slv1) → mst0 → DDR
  2. 写端口: 发AXI4写请求到NPU RAM (0x0000_1000)
     DMA → AXI4 → Crossbar(slv1) → mst1 → NPU RAM
  3. 数据流: DDR → DMA读引擎 → FIFO → DMA写引擎 → NPU RAM
```

### 阶段3：NPU推理

```text
CPU触发NPU:
  1. CPU写NPU CSR寄存器 (0x0003_0000, CTRL[0]=1)
     CPU → AXI-Lite → Crossbar(slv0) → mst3 → axi2csr → NPU CSR
  2. NPU启动推理流水线:
     NPU RAM → im2col变换 → 脉动阵列(40×32 MAC) → MaxPool → GAP → FC → Argmax
  3. NPU完成: PRED寄存器有效
```

### 阶段4：CPU读取结果

```text
CPU读取NPU结果:
  1. CPU读NPU PRED寄存器 (0x0003_0000 + 0x20)
     CPU → AXI-Lite → Crossbar(slv0) → mst3 → axi2csr → NPU CSR
  2. 解析: class_id = PRED[11:8], logit = PRED[23:16]
  3. 分类完成!
```

### 数据流总结图

```text
┌──────┐  AXI-Lite   ┌─────────┐  AXI4   ┌─────────┐  AXI4   ┌─────┐
│ CPU  ├────────────►│ Lite2AXI ├───────►│Crossbar ├───────►│ DDR │
│      │             │   桥     │        │  slv0   │  mst0  │     │
└──┬───┘             └─────────┘        └────┬────┘        └─────┘
   │                                         │
   │ AXI-Lite (写CSR)                        │ AXI4 (mst2)
   │                                         ▼
   │                                    ┌─────────┐
   │                                    │axi2axi  │
   │                                    │_lite 桥 │
   │                                    └────┬────┘
   │                                         │ AXI-Lite
   │                                         ▼
   │                                    ┌─────────┐
   │                                    │  DMA    │
   │                                    │ CSR     │
   │                                    └────┬────┘
   │                                         │
   │ AXI4 (slv1)                             ▼
   │                                    ┌─────────┐
   │                                    │  DMA    │
   ├───────────────────────────────────►│ Engine  │
   │                                    └────┬────┘
   │                                         │ AXI4 (slv1)
   │                                         ▼
   │                                    ┌─────────┐  AXI4   ┌─────────┐
   │                                    │Crossbar ├───────►│NPU RAM  │
   │                                    │  slv1   │  mst1  │ 128KB   │
   │                                    └─────────┘        └────┬────┘
   │                                                            │
   │ AXI-Lite (写NPU CSR)                                       │ NPU内部读取
   │                                                            ▼
   │  ┌─────────┐  AXI4   ┌─────────┐                    ┌─────────┐
   └─►│Crossbar ├───────►│ axi2csr ├──────► NPU CSR ────►│   NPU   │
      │  slv0   │  mst3  │   桥    │         寄存器      │ 计算核心 │
      └─────────┘        └─────────┘                     └─────────┘
```

---

## 1.6 源码目录结构导航

```text
fpga_soc/
├── src/                          ← 所有RTL源码
│   ├── soc_top.sv                ← 【顶层】SoC集成 (847行)
│   ├── ddr.sv                    ← DDR行为模型 (314行)
│   ├── instr_data.S              ← CPU固件 (100行)
│   ├── instr_data.dat            ← 编译后的固件hex
│   ├── image_data.dat            ← CIFAR-10测试图像
│   │
│   ├── cpu/                      ← CPU子系统
│   │   ├── picorv32.v            ← PicoRV32核心 (2510行，第三方)
│   │   └── picorv32_axi.v        ← AXI Wrapper (542行)
│   │
│   ├── axi_crossbar/             ← AXI Crossbar (约22个文件，第三方)
│   │   ├── axicb_crossbar_top.sv ← Crossbar顶层 (1606行)
│   │   ├── axicb_switch_top.sv   ← 交换矩阵
│   │   ├── axicb_slv_ooo.sv      ← 乱序完成管理
│   │   ├── axicb_round_robin*.sv ← 仲裁器
│   │   ├── axi_lite2axi.sv       ← AXI-Lite→AXI4桥
│   │   ├── axi2axi_lite.sv       ← AXI4→AXI-Lite桥
│   │   └── axi2csr.sv            ← AXI4→CSR桥
│   │
│   ├── dma/                      ← DMA控制器 (自研，7层)
│   │   ├── dma_axi_top.sv        ← 最外层：信号打包 (207行)
│   │   ├── dma_axi_wrapper.sv    ← CSR+功能集成 (125行)
│   │   ├── dma_csr.sv            ← CSR寄存器文件 (348行)
│   │   ├── dma_fsm.sv            ← 4状态控制器 (182行)
│   │   ├── dma_func_wrapper.sv   ← 功能核心集成 (171行)
│   │   ├── dma_streamer.sv       ← 读/写突发引擎 (383行)
│   │   ├── dma_axi_if.sv         ← AXI4 Master接口 (515行)
│   │   ├── dma_fifo.sv           ← 同步FIFO (102行)
│   │   └── inc/                  ← 包和宏定义
│   │       ├── amba_axi.svh      ← AXI信号宏
│   │       ├── amba_axi_pkg.sv   ← AXI类型包
│   │       ├── dma_pkg.svh       ← DMA参数包
│   │       └── dma_utils_pkg.sv  ← DMA工具函数
│   │
│   └── npu/                      ← NPU子系统 (自研)
│       ├── npu_top.sv            ← NPU顶层 (312行)
│       ├── conv_top.sv           ← 卷积层控制器 (549行)
│       ├── mac_array_40x32_stream.sv ← 40×32脉动阵列 (287行)
│       ├── mm_systolic_4x4.sv    ← 4×4子阵列 (164行)
│       ├── pe.sv                 ← 单个PE (98行)
│       ├── gap_fc_logits.sv      ← GAP+FC+Argmax (312行)
│       ├── ppu_maxpool.sv        ← MaxPool (112行)
│       ├── npu_csr_regs.sv       ← NPU CSR寄存器 (117行)
│       ├── npu_ram.sv            ← NPU本地RAM (224行)
│       ├── dmac_im2col_stream.sv ← im2col变换 (167行)
│       ├── dmac_image_sa_writer.sv ← SA写入器 (218行)
│       ├── dmac_tile_scheduler.sv  ← Tile调度器 (97行)
│       ├── npu_dmac_frontend.sv  ← DMA前端 (116行)
│       └── export_cifar/         ← Python训练/量化工具
│
├── tb/
│   └── soc_tb.sv                 ← SoC级测试bench (2638行，50个测试)
│
├── sim/                          ← 仿真脚本
│   ├── test.tcl                  ← 基本仿真脚本
│   ├── cov_soc_tb.tcl            ← 覆盖率仿真脚本
│   └── coverage_exclude.cfg     ← 覆盖率排除配置
│
└── docs/                         ← 文档
    ├── DESIGN_REPORT.md          ← 设计报告 (1778行)
    ├── NPU_DESIGN_REPORT.md      ← NPU数据通路分析 (640行)
    └── DEMAND.md                 ← 赛题需求 (243行)
```

### 代码量统计

| 模块 | 行数 | 自研/第三方 | 说明 |
|------|------|------------|------|
| `soc_top.sv` | 847 | 自研 | SoC集成 |
| `picorv32.v` | 2,510 | 第三方 | RISC-V核心 |
| `picorv32_axi.v` | 542 | 自研 | CPU AXI包装器 |
| `axi_crossbar/` | ~4,000 | 第三方 | AXI交叉矩阵 |
| `dma/*.sv` | ~2,033 | 自研 | DMA控制器 |
| `npu/*.sv` | ~2,966 | 自研 | NPU子系统 |
| `ddr.sv` | 314 | 自研 | DDR模型 |
| `soc_tb.sv` | 2,638 | 自研 | 测试bench |
| **总计** | **~15,850** | | |

其中自研代码约 **8,800行**，这是我们要学习的重点。

---

## 1.6+ 设计视角：为什么这样设计？

在深入代码之前，我们先从架构师的角度思考：**为什么这个SoC长成这个样子？**

### 核心设计决策

#### 决策1：为什么选择异构而非同构？

```text
问题：需要在CIFAR-10上做图像分类推理，应该用什么架构？

方案A：多核同构CPU（如4个PicoRV32）
  - 每个核都能做同样的事
  - 需要复杂的任务调度和同步机制
  - 乘累加操作仍是标量执行，无并行加速
  - 面积大，但性能提升有限

方案B：CPU + 专用加速器（本项目选择）
  - CPU负责控制流，NPU负责数据流
  - NPU内部1280个MAC并行，天然适合矩阵运算
  - 软硬件解耦，各自优化
  - 面积效率高，性能提升680倍

方案C：纯NPU（无CPU）
  - 无法处理复杂的控制逻辑（条件分支、异常处理）
  - 无法灵活加载不同的模型
  - 不具备通用性
```

**选择理由**：

| 对比维度 | 方案A：多核CPU | 方案B：CPU+NPU（本项目） | 方案C：纯NPU |
|----------|---------------|------------------------|-------------|
| 控制灵活性 | 高 | 高 | 低 |
| 计算吞吐量 | 低 | 极高（680x） | 极高 |
| 面积效率 | 低 | 高 | 最高 |
| 可编程性 | 高 | 中（CPU可编程） | 低 |
| 开发复杂度 | 低 | 中 | 高 |

#### 决策2：为什么选择这个地址映射？

```text
约束条件：
  1. PicoRV32复位地址固定在0x0000_0000
  2. ROM必须在地址0处（存放固件入口）
  3. NPU RAM紧邻ROM（便于DMA连续搬运）
  4. CSR寄存器地址需要4KB对齐（Crossbar限制）
  5. DDR放在高地址空间（0x4000_0000），与本地存储分离
```

地址分配原则：
- **低地址（0x0000_xxxx）**：CPU本地资源（ROM、RAM）和NPU资源
- **中地址（0x0002_xxxx ~ 0x0003_xxxx）**：控制寄存器（DMA CSR、NPU CSR）
- **高地址（0x4000_xxxx）**：大容量存储（DDR）

#### 决策3：为什么用轮询而非中断？

```text
方案A：轮询（Polling）— 本项目选择
  - CPU反复读STATUS寄存器，检查done位
  - 实现简单，延迟确定
  - 缺点：CPU在等待期间无法做其他事

方案B：中断（Interrupt）
  - DMA/NPU完成后触发中断信号
  - CPU可以去做其他任务
  - 缺点：需要中断控制器、上下文保存、延迟不确定

方案C：DMA链式描述符
  - DMA自动执行多个传输任务
  - CPU只需初始配置一次
  - 缺点：实现复杂，调试困难
```

**选择理由**：本项目是单任务场景（一张图像的推理），CPU没有其他工作可做。
轮询是最简单、最确定的方案。在实际产品中，通常会选择中断或DMA链式描述符。

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    设计约束                              │
├───────────────┬─────────────────────────────────────────┤
│ 赛题约束       │ 32位RISC-V + 32位NPU，AXI总线           │
│ 面积约束       │ FPGA资源有限，需控制MAC阵列规模           │
│ 时序约束       │ 目标频率200MHz，关键路径需优化             │
│ 功能约束       │ CIFAR-10 10类分类，精度>80%              │
│ 接口约束       │ PicoRV32只有AXI-Lite接口                 │
│ 存储约束       │ 片上SRAM有限，大模型需DDR                 │
└───────────────┴─────────────────────────────────────────┘
```

---

## 1.6++ 设计视角：如何从零开始设计？

假设你从零开始设计这个SoC，以下是推荐的设计流程：

### Step 1：需求分析与架构选择

```text
输入：赛题要求（CIFAR-10推理，RISC-V + NPU）

分析：
  1. 计算量评估 → 决定NPU MAC阵列规模
     - Conv1: 5×5×3×32 = 2400 MAC/pixel × 32×32 pixels = ~780万次
     - 需要并行度 > 1000 才能在合理时间内完成

  2. 存储需求评估 → 决定RAM/DDR容量
     - 图像: 32×32×3 = 3072 字节
     - 特征图: 32×32×32×4 = 131072 字节
     - 权重: ~50KB
     - 总计: ~200KB → 需要DDR + 本地SRAM

  3. 带宽需求评估 → 决定总线架构
     - DMA搬运: 4096字节 / 22715 cycles ≈ 0.18 B/cycle
     - 单通道AXI32bit即可满足
     - 但需要并发：DMA搬运 + CPU配置同时进行 → 需要Crossbar

输出：架构决策文档
  - CPU: PicoRV32（开源、轻量、AXI-Lite接口）
  - NPU: 40×32脉动阵列（1280 MAC）
  - 总线: 4×4 AXI Crossbar
  - 存储: 256KB DDR + 128KB NPU SRAM + 4KB ROM
```

### Step 2：定义地址映射与接口规范

```text
输入：架构决策

工作：
  1. 分配地址空间
     - CPU ROM: 0x0000_0000 (4KB)
     - NPU LMEM: 0x0000_1000 (128KB)
     - DMA CSR: 0x0002_1000 (4KB)
     - NPU CSR: 0x0003_0000 (4KB)
     - DDR: 0x4000_0000 (256KB)

  2. 定义每个模块的接口
     - CPU: AXI-Lite Master
     - DMA: AXI4 Master + AXI-Lite Slave (CSR)
     - NPU: AXI4 Slave (RAM) + CSR Slave (寄存器)
     - DDR: AXI4 Slave

  3. 确定Crossbar拓扑
     - 4个Slave端口: CPU, DMA, (预留×2)
     - 4个Master端口: DDR, NPU LMEM, DMA CSR, NPU CSR

输出：接口规范文档、地址映射表
```

### Step 3：选择或设计IP核

```text
输入：接口规范

决策：
  ┌─────────────┬────────────┬──────────────────────┐
  │ 模块         │ 决策       │ 理由                  │
  ├─────────────┼────────────┼──────────────────────┤
  │ CPU核心      │ 第三方IP   │ PicoRV32成熟可用      │
  │ AXI Crossbar │ 第三方IP   │ 设计复杂，验证成本高   │
  │ DMA控制器    │ 自研       │ 需要定制化4KB边界处理  │
  │ NPU子系统    │ 自研       │ 赛题核心竞争力        │
  │ DDR模型      │ 自研       │ 仿真用，简单即可      │
  └─────────────┴────────────┴──────────────────────┘

自研模块需要详细设计；第三方IP需要学习其接口和配置。
```

### Step 4：逐模块实现与集成

```text
实现顺序（推荐）：

  Phase 1: 最小可运行系统
    1. CPU + ROM（能执行固件）
    2. 加入DDR（有存储）
    3. 加入Crossbar（能访问DDR）
    → 验证：CPU能读写DDR

  Phase 2: 加入DMA
    4. 实现DMA控制器
    5. 加入AXI-Lite桥（CPU配置DMA）
    → 验证：CPU能配置DMA搬运数据

  Phase 3: 加入NPU
    6. 实现NPU CSR寄存器
    7. 实现MAC阵列
    8. 实现卷积控制器
    9. 实现GAP+FC+Argmax
    → 验证：NPU能完成推理

  Phase 4: 端到端验证
    10. 编写CPU固件（instr_data.S）
    11. 运行完整仿真
    12. 检查分类结果
```

### Step 5：验证、调试与优化

```text
验证策略：
  1. 单元测试：每个模块独立验证
  2. 集成测试：模块间接口验证
  3. 系统测试：端到端功能验证
  4. 覆盖率分析：确保代码路径全覆盖

常见调试技巧：
  - 在仿真中加入波形观察（$dumpfile/$dumpvars）
  - 使用断言（assert）检查协议违规
  - 在关键路径加入计数器统计性能
```

---

## 1.6+++ 设计视角：架构模式与原则

在本项目的设计中，隐藏着几个可复用的架构模式。理解这些模式，可以帮助你在其他项目中快速做出设计决策。

### 模式1：Master-Slave 异构协作模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Master-Slave 异构协作                           │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将系统分为"控制面"和"数据面"，由Master负责调度，          │
│   Slave负责执行。两者通过共享寄存器接口通信。               │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. CPU（Master）通过CSR寄存器配置DMA/NPU                │
│   2. DMA/NPU（Slave）执行完成后设置状态位                  │
│   3. CPU轮询状态位或接收中断                              │
│   4. 数据搬运由DMA独立完成，不占用CPU                      │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   CPU写DMA CSR → DMA搬运数据 → CPU写NPU CSR              │
│   → NPU推理 → CPU读NPU PRED                              │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - GPU驱动：CPU配置GPU寄存器，GPU执行渲染                 │
│   - 网络处理器：CPU配置DMA描述符，NIC搬运数据包             │
│   - 存储控制器：CPU配置RAID控制器，硬件执行校验             │
└─────────────────────────────────────────────────────────┘
```

### 模式2：Memory-Mapped IO 模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Memory-Mapped IO (MMIO)                        │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将外设的控制寄存器映射到CPU的地址空间中，                  │
│   CPU通过普通的load/store指令访问外设，                     │
│   不需要特殊的I/O指令。                                    │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 地址解码器将地址路由到对应外设                         │
│   2. 每个外设分配唯一的地址范围                             │
│   3. 外设内部将地址偏移映射到具体寄存器                     │
│   4. Crossbar硬件自动完成路由，无需软件干预                 │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   CPU执行 sw t0, 0x00(s1) 写NPU CSR                     │
│   → 地址0x0003_0000经Crossbar路由到axi2csr桥              │
│   → 桥转换为csr_wr_en + csr_addr + csr_wdata              │
│   → NPU内部寄存器被写入                                    │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 嵌入式系统中访问UART、SPI、GPIO等外设                   │
│   - 操作系统中映射设备寄存器到虚拟地址空间                   │
│   - FPGA设计中连接自定义加速器                              │
└─────────────────────────────────────────────────────────┘
```

### 模式3：地址解码 + 路由模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 地址解码路由 (Address Decoding & Routing)       │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   通过比较地址的高位来决定请求应该送往哪个目标设备，          │
│   实现一对多的路由选择。                                    │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 每个目标设备配置 START_ADDR 和 END_ADDR              │
│   2. 对每个请求，逐一比较地址是否落在范围内                  │
│   3. 生成one-hot路由向量                                   │
│   4. 路由向量与MST_ROUTES取交集（权限控制）                 │
│   5. 无匹配时返回DECERR（解码错误）                         │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   Crossbar内部:                                          │
│     addr=0x0003_0010 → 比较4个范围 → 命中SLV3              │
│     → 路由到mst3_if → axi2csr桥 → NPU CSR                 │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要地址路由的总线互连                              │
│   - PCIe BAR地址解码                                      │
│   - Cache Tag比较和命中判断                                │
│   - 虚拟地址到物理地址的页表翻译                            │
└─────────────────────────────────────────────────────────┘
```

### 模式在SoC中的协同工作

```text
  ┌──────────────────────────────────────────────────────────┐
  │                    SoC 架构模式协同                        │
  │                                                          │
  │   CPU ──MMIO──► Crossbar ──地址解码路由──► DMA CSR        │
  │     │                │                                    │
  │     │ Master-Slave    │ 地址解码路由                       │
  │     │ 异构协作        ▼                                    │
  │     └──────────► DMA ──MMIO──► NPU RAM                   │
  │                    │                                      │
  │                    │ Master-Slave                          │
  │                    │ 异构协作                               │
  │                    ▼                                      │
  │                  NPU ──► 推理完成                          │
  └──────────────────────────────────────────────────────────┘

三种模式层层嵌套：
  - 最外层：Master-Slave异构协作（CPU调度，DMA/NPU执行）
  - 中间层：MMIO（CPU通过地址访问所有外设）
  - 最内层：地址解码路由（Crossbar自动完成请求转发）
```

---

## 1.7 关键源码文件逐行导读

### `soc_top.sv` — SoC顶层 (847行)

这是整个SoC的"接线图"。我们分段来看：

**第6-49行：参数和端口定义**

```systemverilog
module soc_top #(
  parameter int AXI_ADDR_W = 32,        // 地址总线宽度
  parameter int AXI_DATA_W = 32,        // 数据总线宽度
  parameter int AXI_ID_W   = 8,         // AXI ID宽度

  // CPU 本地存储
  parameter logic [31:0] CPU_ROM_BASE = 32'h0000_0000,  // ROM基地址
  parameter int          CPU_ROM_AW   = 12,              // 4KB (2^12)

  // DDR
  parameter int DDR_SIZE_BYTES = 256*1024,  // 256KB

  // NPU/DMA CSR 基地址
  parameter logic [31:0] NPU_CSR_BASE = 32'h0003_0000,
  parameter logic [31:0] DMA_CSR_BASE = 32'h0002_1000,
)(
  input  logic clk,     // 全局时钟
  input  logic rst,     // 同步复位，高有效

  // 中断输出
  output logic dma_done_o,      // DMA传输完成
  output logic dma_error_o,     // DMA错误
  output logic cpu_trap_o,      // CPU异常

  // NPU 状态输出
  output logic       npu_busy,         // NPU正在推理
  output logic       npu_done,         // NPU推理完成
  output logic       npu_pred_valid,   // 预测结果有效
  output logic [3:0] npu_pred_class_id,// 分类结果 (0-9)
  output logic [7:0] npu_pred_logit    // 置信度
);
```

**第57-97行：CPU AXI-Lite信号**

```systemverilog
// CPU 产生的 AXI-Lite 信号（简单，无burst）
logic        cpu_lite_awvalid, cpu_lite_awready;
logic [31:0] cpu_lite_awaddr;
logic        cpu_lite_wvalid, cpu_lite_wready;
logic [31:0] cpu_lite_wdata;
logic [3:0]  cpu_lite_wstrb;   // 字节使能（4位=4字节）
// ... AR/R通道类似

// 经过 axi_lite2axi 桥之后的 AXI4 信号（增加了burst支持）
logic [AXI_ID_W-1:0]   cpu_axi_awid;    // 事务ID
logic [7:0]            cpu_axi_awlen;   // burst长度-1
logic [2:0]            cpu_axi_awsize;  // 每拍字节数=2^size
logic [1:0]            cpu_axi_awburst; // burst类型
// ... 其他信号
```

注意对比AXI-Lite和AXI4的信号差异——AXI4多了`id`、`len`、`size`、`burst`等信号。

**第329-355行：CPU实例化**

```systemverilog
picorv32_axi #(
  .PROGADDR_RESET(32'h0000_0000),  // 复位后从地址0开始取指
  .LOCAL_ROM_INIT_FILE(LOCAL_ROM_INIT_FILE)  // 固件文件
) u_cpu (
  .clk(clk), .resetn(resetn), .trap(cpu_trap_o),
  .mem_axi_awvalid(cpu_lite_awvalid),  // AXI-Lite写地址
  .mem_axi_awready(cpu_lite_awready),
  // ... 其他AXI-Lite信号
);
```

**第491-677行：Crossbar实例化（核心！）**

```systemverilog
axicb_crossbar_top #(
  .MST_NB(4), .SLV_NB(4),     // 4主4从

  // 主设备配置（连接到Crossbar的Slave端口）
  .MST0_ID_MASK(8'h10),       // CPU的ID前缀: 0x10
  .MST1_ID_MASK(8'h20),       // DMA的ID前缀: 0x20
  .MST0_OSTDREQ_NUM(4),       // CPU最多4个outstanding事务
  .MST1_OSTDREQ_NUM(4),       // DMA最多4个outstanding事务

  // 从设备地址范围（Crossbar的Master端口）
  .SLV0_START_ADDR(32'h4000_0000),  // DDR
  .SLV0_END_ADDR  (32'h4003_FFFF),
  .SLV1_START_ADDR(32'h0000_1000),  // NPU RAM
  .SLV1_END_ADDR  (32'h0002_0FFF),
  .SLV2_START_ADDR(32'h0002_1000),  // DMA CSR
  .SLV2_END_ADDR  (32'h0002_1FFF),
  .SLV3_START_ADDR(32'h0003_0000),  // NPU CSR
  .SLV3_END_ADDR  (32'h0003_0FFF)
) u_crossbar (
  // Slave 0: CPU
  .slv0_awvalid(cpu_axi_awvalid), .slv0_awready(cpu_axi_awready),
  // ...
  // Slave 1: DMA
  .slv1_awvalid(dma_axi_awvalid), .slv1_awready(dma_axi_awready),
  // ...
  // Master 0: DDR
  .mst0_awvalid(xbar_mst0_awvalid), .mst0_awready(xbar_mst0_awready),
  // ...
  // Master 1: NPU RAM
  .mst1_awvalid(xbar_mst1_awvalid), .mst1_awready(xbar_mst1_awready),
  // ...
);
```

**第682-703行：DDR实例化**

```systemverilog
ddr #(
  .DDR_SIZE_BYTES(DDR_SIZE_BYTES)  // 256KB
) u_ddr (
  .aclk(clk), .aresetn(resetn),
  .s_awvalid(xbar_mst0_awvalid),  // 来自Crossbar mst0
  .s_awready(xbar_mst0_awready),
  // ...
);
```

**第766-845行：NPU实例化**

```systemverilog
npu_top #(
  .IMAGE_DATA_FILE(NPU_IMAGE_DATA_FILE),
  .CONV1_FILE(NPU_CONV1_FILE),
  // ...
) u_npu (
  .clk(clk), .rst_n(resetn),
  // CSR接口 (经axi2csr桥驱动)
  .csr_wr_en(npu_csr_wr_en),
  .csr_rd_en(npu_csr_rd_en),
  .csr_addr(npu_csr_addr),
  .csr_wdata(npu_csr_wdata),
  .csr_rdata(npu_csr_rdata),
  // AXI4 Slave (DMA写入图像数据)
  .s_ram_awvalid(xbar_mst1_awvalid),  // 来自Crossbar mst1
  .s_ram_awready(xbar_mst1_awready),
  // ...
);
```

---

### `ddr.sv` — DDR行为模型 (314行)

这是一个简化的DDR存储模型，不是真正的DDR控制器。

**核心存储：**

```systemverilog
logic [7:0] mem [0:DDR_SIZE_BYTES-1];  // 字节数组，256KB
```

**初始化：**

```systemverilog
initial begin
  for (i = 0; i < DDR_SIZE_BYTES; i = i + 1)
    mem[i] = 8'h00;           // 清零
  if (DDR_INIT_FILE != "")
    $readmemh(DDR_INIT_FILE, mem);  // 从文件加载
end
```

**状态机：**

```systemverilog
typedef enum logic [1:0] {ST_IDLE, ST_WDATA, ST_WRESP, ST_RDATA} st_t;
```

- `ST_IDLE`：空闲，等待读或写请求
- `ST_WDATA`：接收写数据
- `ST_WRESP`：发送写响应
- `ST_RDATA`：发送读数据

**地址计算：**

```systemverilog
function automatic logic [31:0] beat_addr(
  input logic [31:0] base,   // 起始地址
  input logic [7:0]  beat,   // 第几拍
  input logic [2:0]  size,   // 每拍字节数=2^size
  input logic [1:0]  burst   // 00=FIXED, 01=INCR
);
  step = (beat << size);     // 偏移 = 拍号 × 每拍字节数
  case (burst)
    2'b00: beat_addr = base;         // FIXED: 地址不变
    2'b01: beat_addr = base + step;  // INCR: 地址递增
  endcase
endfunction
```

---

### `instr_data.S` — CPU固件 (100行)

这是CPU执行的程序，也是理解软硬件协同的关键：

```asm
# 内存映射:
#   0x4000_0000  DDR (预加载图像数据)
#   0x0000_1000  NPU RAM (DMA目标)
#   0x0002_1000  DMA CSR
#   0x0003_0000  NPU CSR

_start:
    # Step 1: 配置DMA描述符
    li   s0, 0x00021000       # DMA CSR基地址

    li   t0, 0x40000000       # 源地址: DDR
    sw   t0, 0x20(s0)         # 写 SRC_ADDR_0

    li   t0, 0x00001000       # 目的地址: NPU RAM
    sw   t0, 0x30(s0)         # 写 DST_ADDR_0

    li   t0, 0x1000           # 传输4096字节
    sw   t0, 0x40(s0)         # 写 NUM_BYTES_0

    li   t0, 0x04             # enable=1
    sw   t0, 0x50(s0)         # 写 CFG_0

    # Step 2: 启动DMA
    li   t0, 0x3FD            # go=1, max_burst=255
    sw   t0, 0x00(s0)         # 写 CONTROL

    # Step 3: 轮询DMA完成
poll_dma:
    lw   t1, 0x08(s0)         # 读 STATUS
    li   t2, 0x10000          # bit 16 = done
    and  t3, t1, t2
    beq  t3, x0, poll_dma     # 未完成则继续轮询

    # Step 4: 触发NPU
    li   s1, 0x00030000       # NPU CSR基地址
    li   t0, 0x01
    sw   t0, 0x00(s1)         # 写 CTRL[0]=1

    # Step 5: 轮询NPU完成
poll_npu:
    lw   t1, 0x20(s1)         # 读 PRED
    andi t2, t1, 0x01         # bit[0] = valid
    beq  t2, x0, poll_npu

    # Step 6: 读取结果
    srli t2, t1, 8
    andi s2, t2, 0x0F         # s2 = class_id (0-9)

done:
    jal  x0, done             # 死循环
```

这段100行的汇编，就是CPU驱动整个SoC的完整逻辑。

---

## 1.8 模块间接口协议总结

| 连接 | 协议 | 方向 | 说明 |
|------|------|------|------|
| CPU → Crossbar | AXI4 | Master→Slave | 经过Lite2AXI桥 |
| DMA → Crossbar | AXI4 | Master→Slave | DMA是独立主设备 |
| Crossbar → DDR | AXI4 | Master→Slave | 全功能AXI4 |
| Crossbar → NPU RAM | AXI4 | Master→Slave | DMA写入图像数据 |
| Crossbar → DMA CSR | AXI-Lite | Master→Slave | 经过AXI2AXI-Lite桥 |
| Crossbar → NPU CSR | CSR | Master→Slave | 经过AXI2CSR桥 |
| NPU内部 | 自定义 | — | im2col、脉动阵列等 |

---

## 1.9 本讲小结

本讲建立了以下认知：

1. **异构SoC的概念**：CPU做控制，NPU做计算，各司其职
2. **SoC架构**：CPU、DMA、NPU、DDR通过AXI Crossbar互联
3. **地址映射**：每个外设分配唯一的地址范围，Crossbar负责路由
4. **数据流**：CPU配置→DMA搬运→NPU计算→CPU读结果
5. **源码结构**：自研代码约8800行，集中在dma/和npu/目录
6. **关键文件**：soc_top.sv是接线图，instr_data.S是软件入口

---

## 1.10 课后任务

### 任务1：手画SoC框图

不看本文档，凭记忆画出SoC的完整框图，要求标注：
- 每个模块的名称和角色
- 每条连接线的协议类型（AXI4/AXI-Lite/CSR）
- 地址映射表

### 任务2：代码导航

用编辑器打开以下文件，找到对应行：

1. `src/soc_top.sv`：找到Crossbar实例化的位置（约第491行）
2. `src/soc_top.sv`：找到DDR地址范围参数（SLV0_START_ADDR）
3. `src/instr_data.S`：找到DMA启动的指令（写CONTROL寄存器）
4. `src/ddr.sv`：找到状态机定义（ST_IDLE等）

### 任务3：思考题

1. 为什么CPU用AXI-Lite而不是完整的AXI4？
2. 为什么DMA需要作为独立的主设备，而不是CPU的一个外设？
3. NPU为什么需要自己的本地RAM（128KB），不能直接用DDR吗？
4. Crossbar的slv2和slv3端口为什么是空的（未连接外部主设备）？

---

## 下一讲预告

**第2讲：AXI4协议基础 — 五通道握手**

我们将深入AXI4协议的五个通道，理解valid/ready握手机制，为后续理解Crossbar和DMA打下基础。
