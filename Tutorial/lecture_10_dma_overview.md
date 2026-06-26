# Lecture 10: DMA 架构总览 -- 7层层次化设计

## 课程目标

本讲深入分析 FPGA SoC 中 DMA（Direct Memory Access）子系统的整体架构。学完本讲后，你将能够：

- 理解 DMA 在 SoC 中的核心作用和设计动机
- 画出 DMA 模块的 7 层层次结构图
- 理解双描述符（Dual Descriptor）设计的意图
- 掌握 DMA CSR 寄存器映射全貌
- 理解各子模块之间的接口信号流

---

## 1. 为什么需要 DMA？

### 1.1 CPU 搬运数据的瓶颈

在没有 DMA 的系统中，CPU 必须亲自执行每一次数据搬运：

```
传统方式（无 DMA）:
  CPU 读取源地址 -> CPU 写入目标地址 -> 循环 N 次

  时间线:
  |---读---|---写---|---读---|---写---|---读---|---写---|
  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  CPU 全程被占用，无法执行其他任务
```

对于一个 1024 字节的数据块，假设每次搬运 4 字节，CPU 需要执行 256 次读写循环。在此期间，CPU 无法处理中断、无法执行计算任务。

### 1.2 DMA 的解决方案

DMA 引擎独立于 CPU，拥有自己的 AXI Master 接口，可以直接访问系统总线：

```
DMA 方式:
  CPU: 写入描述符（源地址、目标地址、字节数）-> 启动 DMA -> 去做别的事
  DMA: 自动读取源数据 -> 缓冲 -> 写入目标 -> 完成后产生中断

  时间线:
  CPU: |---配置---|........空闲，可执行其他任务........|---处理中断---|
  DMA:            |---读---|---写---|---读---|---写---|
```

### 1.3 DMA 的典型应用场景

| 场景 | 说明 |
|------|------|
| 内存拷贝 | DDR 到 DDR 的大块数据搬移 |
| 外设数据传输 | 从外设寄存器到内存的批量读取 |
| NPU 推理 | 将模型权重和输入数据加载到 NPU |
| 环形缓冲区 | 音频/视频流的连续数据搬运 |
| 零拷贝网络 | 网络数据包直接到用户缓冲区 |

---

## 1.1B 设计视角：为什么这样设计？

### 设计动机

DMA 的核心价值是 **用硬件换 CPU 时间**。在本 SoC 中, CPU 需要将 4KB
图像数据从 DDR 搬到 NPU 本地存储器。如果 CPU 逐字搬运, 需要 1024 次
读写循环, 全程无法做其他事。DMA 引擎独立完成搬运, CPU 只需写 5 个
寄存器即可启动。

### 方案对比

| 设计维度 | 本项目方案 (描述符驱动) | 简单 DMA (寄存器直控) | 链式 DMA (scatter-gather) |
|----------|------------------------|--------------------|-----------------------|
| 配置方式 | 描述符 (src/dst/num/cfg) | 逐个寄存器写入 | 描述符链表 (内存中) |
| 多次传输 | 双描述符, 顺序执行 | 每次重新配置 | 自动遍历链表 |
| CPU 开销 | 5 个寄存器写 + 1 个启动 | N 个寄存器写 | 1 次启动 (链表预加载) |
| 灵活性 | 中等 | 低 | 高 |
| 面积 | 中等 | 最小 | 较大 |
| 适用场景 | 固定流程, 2-3 次传输 | 单次简单传输 | 复杂 I/O, 网络 |

### 关键设计决策

**决策 1: 为什么需要 DMA 而不是让 CPU 搬运?**

```
CPU 搬运 4KB 数据:
  循环 1024 次:
    lw t0, 0(src)     # 3 周期 (取指+读rs+读mem)
    sw t0, 0(dst)     # 3 周期 (取指+读rs+写mem)
    addi src, src, 4   # 3 周期
    addi dst, dst, 4   # 3 周期
    blt ...            # 3 周期
  总计: 1024 * 15 = 15360 周期 (50MHz 下约 307 us)

DMA 搬运 4KB 数据:
  CPU 写 5 个寄存器: 5 * 5 = 25 周期
  DMA burst 传输: 4096/4 = 1024 beat, burst 256 beat
    → 4 个 burst, 每个 ~260 周期 = 1040 周期
  总计: ~1065 周期 (50MHz 下约 21 us)

  性能提升: ~14 倍
  CPU 利用率: 从 100% 降到 <2%
```

**决策 2: 为什么选择 7 层模块层次?**

```
层次分解的原则: 每层只做一件事

  层次 1 (dma_axi_top):     信号格式转换 (struct <-> 扁平)
  层次 2 (dma_axi_wrapper): CSR 与功能逻辑的桥梁
  层次 3 (dma_csr):          寄存器读写 (AXI-Lite 从接口)
        (dma_func_wrapper):  功能子模块集成
  层次 4 (dma_fsm):          描述符调度与状态控制
        (dma_streamer x2):   突发参数计算 (读/写各一个)
        (dma_fifo):          数据缓冲
        (dma_axi_if):        AXI 协议处理

优势:
  ├── 每个模块可独立验证
  ├── 修改一层不影响其他层 (如替换 FIFO 深度)
  ├── 综合工具可以更好地优化
  └── 代码可读性和可维护性高
```

**决策 3: 为什么用双描述符?**

```
单描述符的局限:
  ├── 只能做一次传输
  ├── 加载 NPU 输入 + 加载 NPU 权重 → 需要两次 DMA 配置
  └── CPU 需要在两次传输之间介入

双描述符的优势:
  ├── DESC0: 加载输入数据 (DDR → NPU Input)
  ├── DESC1: 加载权重数据 (DDR → NPU Weight)
  ├── DMA 按 DESC0 → DESC1 顺序自动执行
  └── CPU 只需配置一次, 启动一次

  时间线:
  CPU: |配置DESC0+DESC1|启动|............等待............|读结果|
  DMA:                  |---DESC0 传输---|---DESC1 传输---|
```

### 约束条件

| 约束 | 影响 | 应对策略 |
|------|------|----------|
| AXI 总线带宽 | DMA 与 CPU 共享带宽 | DMA 用 burst 传输, 减少总线占用 |
| FIFO 深度有限 | 读写速度不匹配时会停顿 | 调整 FIFO 深度 (默认 16 级) |
| 4KB 边界限制 | AXI 协议要求 burst 不跨 4KB | Streamer 自动拆分 burst |
| 描述符数量固定 | 无法动态扩展 | 用 `DMA_NUM_DESC` 参数配置 |

---

## 1.1C 设计视角：如何从零开始设计？

假设你要从零设计一个 DMA 控制器, 以下是推荐的设计步骤:

### Step 1: 定义寄存器接口

```
第一步: 确定 CPU 如何配置 DMA

  最小寄存器集:
  ├── CONTROL (0x00): go (启动), abort (中止)
  ├── STATUS  (0x08): done (完成), error (错误)
  ├── SRC_ADDR (0x10): 源起始地址
  ├── DST_ADDR (0x18): 目标起始地址
  ├── NUM_BYTES (0x20): 传输字节数
  └── CFG (0x28): 使能, 模式 (INCR/FIXED)

  接口协议: AXI-Lite Slave (简单, 32 位数据宽度)
```

### Step 2: 设计描述符调度器 (FSM)

```
第二步: 设计控制状态机

  IDLE → CFG → RUN → DONE

  IDLE: 等待 go=1
  CFG:  检查描述符有效性 (enable=1 && num_bytes>0)
  RUN:  调度描述符给 Streamer, 等待所有完成
  DONE: 保持直到 go=0

  调度逻辑:
  for (i = 0; i < NUM_DESC; i++) {
    if (desc[i].enable && desc[i].num_bytes > 0 && !done[i]) {
      dispatch(desc[i]);  // 发送给 Streamer
      break;              // 一次只调度一个
    }
  }
```

### Step 3: 设计数据搬运引擎 (Streamer)

```
第三步: 设计突发参数计算模块

  Streamer 职责:
  ├── 将大块数据拆分为多个 burst
  ├── 计算每个 burst 的起始地址和长度
  ├── 处理 4KB 边界对齐
  └── 处理非对齐传输

  突发计算逻辑:
    burst_len = min(剩余字节/4, max_beats)
    burst_len = min(burst_len, 4KB边界内剩余beat数)
    burst_addr = 当前地址

    AXI 协议要求:
    ├── burst 不能跨 4KB 边界
    ├── INCR 模式: 最大 256 beat
    └── 地址必须对齐到数据宽度
```

### Step 4: 设计数据缓冲 (FIFO)

```
第四步: 在读写路径之间插入 FIFO

  FIFO 的作用:
  ├── 解耦读写速度: 读可能比写快 (或反之)
  ├── 缓冲突发数据: 一次 burst 的数据暂存在 FIFO 中
  └── 简化控制: 读写可以独立进行

  参数选择:
  ├── 深度: 16 级 (默认), 可配置
  ├── 宽度: 32 位 (与数据总线一致)
  └── 类型: 同步 FIFO (单时钟域)
```

### Step 5: 设计 AXI Master 接口

```
第五步: 实现 AXI4 协议

  AXI Master 需要处理的通道:
  ├── AR (读地址): 发出读请求
  ├── R  (读数据): 接收读数据
  ├── AW (写地址): 发出写请求
  ├── W  (写数据): 发出写数据
  └── B  (写响应): 接收写确认

  关键设计点:
  ├── 读写通道独立: 可以同时进行
  ├── Outstanding 事务: 支持多个未完成请求
  ├── 错误处理: 检测 SLVERR/DECERR
  └── 4KB 边界: 由 Streamer 保证, AXI-IF 不需要关心
```

---

## 1.1D 设计视角：架构模式与原则

### 模式 1: 描述符驱动 DMA 模式 (Descriptor-Driven DMA Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  用描述符 (Descriptor) 定义一次 DMA 传输的所有参数        │
  │  CPU 只需写描述符寄存器, DMA 硬件自动完成传输              │
  └──────────────────────────────────────────────────────────┘

描述符结构:
  struct descriptor {
    src_addr;    // 源地址
    dst_addr;    // 目标地址
    num_bytes;   // 传输字节数
    rd_mode;     // 读模式: INCR / FIXED
    wr_mode;     // 写模式: INCR / FIXED
    enable;      // 使能位
  };

调度流程:
  1. CPU 写描述符寄存器 (5 个 sw 指令)
  2. CPU 写 CONTROL.go = 1
  3. FSM 检查描述符有效性
  4. FSM 将描述符发送给 Streamer
  5. Streamer 计算突发参数, 驱动 AXI 接口
  6. 数据经 FIFO 从源传输到目标
  7. 完成后 FSM 置位 STATUS.done

适用场景:
  ├── 任何需要 CPU 配置、硬件执行的数据搬运
  ├── 嵌入式系统中的外设数据传输
  └── 加速器的数据加载 (如本项目的 NPU)
```

### 模式 2: 层次化模块模式 (Hierarchical Module Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  将复杂系统分解为多层模块, 每层只负责一个关注点            │
  │  上层处理接口和集成, 底层处理具体功能                      │
  └──────────────────────────────────────────────────────────┘

本项目的 4 层结构:
  层次 1: 顶层 (dma_axi_top)
    └── 职责: 信号格式转换, 端口定义

  层次 2: 包装层 (dma_axi_wrapper)
    └── 职责: CSR 与功能逻辑的连接桥梁

  层次 3: 功能层 (dma_csr + dma_func_wrapper)
    └── 职责: 寄存器管理 + 子模块集成

  层次 4: 核心层 (dma_fsm + streamer + fifo + axi_if)
    └── 职责: 状态控制 + 突发计算 + 数据缓冲 + 协议处理

设计原则:
  ├── 单一职责: 每个模块只做一件事
  ├── 接口清晰: 用 struct 定义模块间通信
  ├── 可替换: 可以单独替换 FIFO 或 AXI-IF
  └── 可测试: 每层可以独立仿真验证
```

---

## 2. DMA 在 SoC 中的位置

### 2.1 系统总线拓扑

```
                    +-----------+
                    |   CPU     |
                    | (RISC-V)  |
                    +-----+-----+
                          |
                    +-----+-----+
                    |  AXI-Lite |
                    |  Intercon |
                    +-----+-----+
                          |
          +---------------+---------------+
          |               |               |
    +-----+-----+  +-----+-----+  +-----+-----+
    | DMA CSR   |  |  NPU CSR  |  | GPIO/UART |
    | (Slave)   |  |  (Slave)  |  |  (Slave)  |
    +-----------+  +-----------+  +-----------+
          |
    +-----+-----+
    | DMA Master|---------> AXI4 Interconnect ---------> DDR / SRAM
    | (Data)    |                                  |
    +-----------+                                  |
                                            +-----+-----+
                                            | DDR Ctrl  |
                                            +-----------+
```

关键点：
- DMA 有两个 AXI 接口：**Slave（AXI-Lite）** 用于 CPU 配置，**Master（AXI4）** 用于数据搬运
- CSR 通道是低带宽的寄存器访问，数据通道是高带宽的突发传输

### 2.2 双接口设计的优势

```
AXI-Lite Slave 接口（CPU -> DMA）:
  - 低带宽，32位数据宽度
  - 用于写入控制寄存器和描述符
  - 只需要简单的握手逻辑

AXI4 Master 接口（DMA -> 存储器）:
  - 高带宽，支持突发传输（Burst）
  - 最多 256 beats / 突发
  - 支持 INCR 和 FIXED 两种突发模式
  - 自动处理 4KB 边界对齐
```

---

## 3. 七层模块层次结构

### 3.1 层次总览

DMA 子系统由 7 个模块组成，分为 4 个层次：

```
层次 1: dma_axi_top          -- 顶层：信号解包，struct 封装
层次 2: dma_axi_wrapper      -- 结构包装：连接 CSR 与功能逻辑
层次 3: dma_csr              -- 寄存器文件：AXI-Lite 从接口
       dma_func_wrapper      -- 功能集成：实例化 4 个子模块
层次 4: dma_fsm              -- 状态机：描述符调度
       dma_streamer (x2)     -- 流读/写器：突发计算
       dma_fifo              -- 数据缓冲：读写路径之间的 FIFO
       dma_axi_if            -- AXI 主接口：协议处理
```

### 3.2 模块层次图

```
+=====================================================================+
|  dma_axi_top                                                        |
|  (信号解包: 扁平端口 <-> struct)                                      |
|                                                                      |
|  +================================================================+  |
|  |  dma_axi_wrapper                                                |  |
|  |  (CSR <-> 功能逻辑的桥梁)                                         |  |
|  |                                                                 |  |
|  |  +-------------------+     +---------------------------------+  |  |
|  |  |     dma_csr       |     |     dma_func_wrapper            |  |  |
|  |  |  (AXI-Lite 寄存器) |     |  (功能子模块集成)                |  |  |
|  |  |                   |     |                                 |  |  |
|  |  |  CONTROL  0x00    |     |  +----------+  +----------+    |  |  |
|  |  |  STATUS   0x08    |     |  | dma_fsm  |  | dma_fifo |    |  |  |
|  |  |  ERR_ADDR 0x10    |     |  | (4状态)  |  | (缓冲)   |    |  |  |
|  |  |  ERR_STAT 0x18    |     |  +----+-----+  +----+-----+    |  |  |
|  |  |  DESC0.SRC 0x20   |     |       |              |          |  |  |
|  |  |  DESC0.DST 0x30   |     |  +----+----+   +----+-----+    |  |  |
|  |  |  DESC0.NUM 0x40   |     |  |streamer|   |streamer  |    |  |  |
|  |  |  DESC0.CFG 0x50   |     |  |  (RD)  |   |  (WR)    |    |  |  |
|  |  |  DESC1...         |     |  +----+----+   +----+-----+    |  |  |
|  |  +-------------------+     |       |              |          |  |  |
|  |                             |  +----+--------------+-----+   |  |  |
|  |                             |  |      dma_axi_if        |   |  |  |
|  |                             |  |  (AXI4 Master 协议)     |   |  |  |
|  |                             |  +------------------------+   |  |  |
|  |                             +---------------------------------+  |  |
|  +================================================================+  |
+=====================================================================+
```

### 3.3 各模块职责详解

| 模块 | 文件 | 行数 | 职责 |
|------|------|------|------|
| `dma_axi_top` | `src/dma/dma_axi_top.sv` | 207 | 顶层端口定义，扁平信号与 struct 互转 |
| `dma_axi_wrapper` | `src/dma/dma_axi_wrapper.sv` | 125 | 连接 CSR 与功能逻辑，描述符向量到 struct 的转换 |
| `dma_csr` | `src/dma/dma_csr.sv` | 348 | AXI-Lite 从接口，寄存器读写，字节选通 |
| `dma_func_wrapper` | `src/dma/dma_func_wrapper.sv` | 171 | 实例化 FSM、Streamer、FIFO、AXI-IF |
| `dma_fsm` | `src/dma/dma_fsm.sv` | 182 | 四状态控制器，描述符调度与完成跟踪 |
| `dma_streamer` | `src/dma/dma_streamer.sv` | 383 | 突发参数计算，地址对齐，4KB 边界处理 |
| `dma_fifo` | `src/dma/dma_fifo.sv` | 102 | 同步 FIFO，读写路径之间的数据缓冲 |
| `dma_axi_if` | `src/dma/dma_axi_if.sv` | 515 | AXI4 Master 协议实现，通道仲裁，错误检测 |

---

## 4. 数据流路径

### 4.1 读路径与写路径

DMA 的核心数据流分为两个阶段：

```
读阶段 (Read Streamer):                写阶段 (Write Streamer):

  源存储器                               DMA FIFO
  (DDR/SRAM)                            (数据缓冲)
       |                                     |
       v                                     v
  [dma_axi_if]                        [dma_axi_if]
  AR 通道发出读请求                     AW 通道发出写请求
       |                                     |
       v                                     v
  R 通道接收数据                         W 通道发送数据
       |                                     |
       v                                     v
  [dma_fifo] 写入 FIFO                 目标存储器
       |                               (DDR/SRAM)
       v
  等待写阶段消费
```

### 4.2 完整数据流示例

假设我们要将 DDR 中地址 0x1000 处的 256 字节拷贝到 0x2000：

```
Step 1: CPU 通过 AXI-Lite 写入描述符
  写 0x20 = 0x00001000  (DESC0.src_addr)
  写 0x30 = 0x00002000  (DESC0.dst_addr)
  写 0x40 = 0x00000100  (DESC0.num_bytes = 256)
  写 0x50 = 0x00000004  (DESC0.cfg: enable=1, rd_mode=INCR, wr_mode=INCR)

Step 2: CPU 启动 DMA
  写 0x00 = 0x00000001  (CONTROL.go = 1)

Step 3: DMA 内部自动执行
  FSM: IDLE -> CFG -> RUN
  Read Streamer: 计算突发参数，通过 AR 通道发送读请求
  AXI-IF: 从 DDR 读取数据，写入 FIFO
  Write Streamer: 从 FIFO 读取数据，通过 W 通道写入 DDR
  FSM: 所有描述符完成 -> DONE

Step 4: DMA 产生中断
  dma_done_o 信号拉高
  CPU 读取 STATUS 寄存器确认完成
```

---

## 5. 双描述符设计

### 5.1 描述符的概念

描述符（Descriptor）是 DMA 传输的配置单元，定义了一次数据搬运的参数：

```c
struct s_dma_desc_t {
    desc_addr_t src_addr;   // 源地址
    desc_addr_t dst_addr;   // 目标地址
    desc_num_t  num_bytes;  // 传输字节数
    dma_mode_t  wr_mode;    // 写模式: INCR / FIXED
    dma_mode_t  rd_mode;    // 读模式: INCR / FIXED
    logic       enable;     // 使能位
};
// 来源: src/dma/inc/dma_pkg.svh, 第 92-99 行
```

### 5.2 为什么需要两个描述符？

本设计支持 `DMA_NUM_DESC = 2` 个描述符（可在 `dma_pkg.svh` 第 10 行配置）：

```
场景 1: 单描述符 -- 简单拷贝
  DESC0: DDR[0x1000] -> DDR[0x2000], 256 字节

场景 2: 双描述符 -- 链式传输
  DESC0: DDR[0x1000] -> NPU_Input,   128 字节  (加载输入数据)
  DESC1: DDR[0x3000] -> NPU_Weight,  1024 字节 (加载模型权重)

  DMA 会按 DESC0 -> DESC1 的顺序依次执行
```

### 5.3 描述符调度机制

```
                FSM 调度逻辑
                    |
                    v
        +-----desc_done_ff[0]-----+
        |  desc_done_ff[1]         |
        +--------------------------+
                    |
        遍历所有描述符，找到第一个:
        - enable = 1
        - num_bytes > 0
        - done = 0
                    |
                    v
        发送给对应的 Streamer
```

FSM 使用 `rd_desc_done_ff` 和 `wr_desc_done_ff` 两个位图跟踪每个描述符的读/写完成状态。读和写是独立跟踪的，因为读路径和写路径可能以不同速度完成。

---

## 6. DMA CSR 寄存器映射

### 6.1 完整寄存器表

```
偏移地址   名称           读/写   位域描述
--------   ----           ----    --------
0x00       CONTROL        R/W     [0]    go          - 启动 DMA
                                   [1]    abort       - 中止请求
                                   [9:2]  max_burst   - 最大突发长度

0x08       STATUS         R       [15:0] magic       - 固定值 0xCAFE
                                   [16]   done        - 传输完成标志
                                   [17]   error       - 错误标志

0x10       ERROR_ADDR     R       [31:0] error_addr  - 出错的地址

0x18       ERROR_STATS    R       [0]    error_type  - 错误类型
                                   [1]    error_src   - 错误来源 (RD/WR)
                                   [2]    error_trig  - 错误触发

--- 描述符 0 ---
0x20       DESC0.SRC      R/W     [31:0] src_addr    - 源地址
0x30       DESC0.DST      R/W     [31:0] dst_addr    - 目标地址
0x40       DESC0.NUM      R/W     [31:0] num_bytes   - 字节数
0x50       DESC0.CFG      R/W     [0]    wr_mode     - 写模式
                                   [1]    rd_mode     - 读模式
                                   [2]    enable      - 使能

--- 描述符 1 (32位系统) ---
0x24       DESC1.SRC      R/W     [31:0] src_addr
0x34       DESC1.DST      R/W     [31:0] dst_addr
0x44       DESC1.NUM      R/W     [31:0] num_bytes
0x54       DESC1.CFG      R/W     [0]    wr_mode
                                   [1]    rd_mode
                                   [2]    enable

--- 描述符 1 (64位系统，高32位) ---
0x28       DESC1.SRC_HI   R/W     [31:0] src_addr[63:32]
0x38       DESC1.DST_HI   R/W     [31:0] dst_addr[63:32]
0x48       DESC1.NUM_HI   R/W     [31:0] num_bytes[63:32]
0x58       DESC1.CFG_HI   R/W     同 DESC1.CFG
```

### 6.2 寄存器地址分布图

```
0x00 +------------------+
     | CONTROL          |
0x08 +------------------+
     | STATUS           |
0x10 +------------------+
     | ERROR_ADDR       |
0x18 +------------------+
     | ERROR_STATS      |
0x20 +------------------+
     | DESC0.SRC        |
0x24 +------------------+ (DESC1.SRC 在 32-bit 模式)
     | ...              |
0x28 +------------------+ (DESC1.SRC_HI 在 64-bit 模式)
     | ...              |
0x30 +------------------+
     | DESC0.DST        |
0x34 +------------------+ (DESC1.DST)
     | ...              |
0x38 +------------------+ (DESC1.DST_HI)
     | ...              |
0x40 +------------------+
     | DESC0.NUM        |
0x44 +------------------+ (DESC1.NUM)
     | ...              |
0x48 +------------------+ (DESC1.NUM_HI)
     | ...              |
0x50 +------------------+
     | DESC0.CFG        |
0x54 +------------------+ (DESC1.CFG)
     | ...              |
0x58 +------------------+ (DESC1.CFG_HI)
     +------------------+
```

### 6.3 关键设计细节

**STATUS 寄存器的魔数 0xCAFE**：
```systemverilog
// src/dma/dma_csr.sv, 第 299-303 行
A_STATUS: begin
  rdata_q[15:0] <= 16'hCAFE;        // 魔数，用于软件验证 DMA 存在
  rdata_q[16]   <= i_dma_status_done;
  rdata_q[17]   <= i_dma_error_stats_error_trig;
end
```
这个魔数允许软件通过读取 STATUS 寄存器来检测 DMA 硬件是否存在。如果读到 0xCAFE，说明 DMA 模块已正确实例化。

**CONTROL.go 的自清行为**：
- 软件写入 `go=1` 启动 DMA
- DMA FSM 在 `DONE` 状态时保持 `go` 的值
- 软件需要写入 `go=0` 来清除，然后才能发起下一次传输

**描述符 1 的地址编码**：
描述符 1 支持 32 位和 64 位两种地址模式。在 32 位系统中，描述符 1 的寄存器位于描述符 0 之后 4 字节（如 `0x24`）。在 64 位系统中，高 32 位位于 8 字节之后（如 `0x28`）。

---

## 7. 模块间接口信号

### 7.1 关键接口类型定义

所有接口类型定义在 `src/dma/inc/dma_pkg.svh` 中：

```systemverilog
// 描述符结构体 (第 92-99 行)
typedef struct packed {
    desc_addr_t src_addr;   // 源地址
    desc_addr_t dst_addr;   // 目标地址
    desc_num_t  num_bytes;  // 字节数
    dma_mode_t  wr_mode;    // 写模式
    dma_mode_t  rd_mode;    // 读模式
    logic       enable;     // 使能
} s_dma_desc_t;

// 控制信号 (第 108-112 行)
typedef struct packed {
    logic       go;         // 启动
    logic       abort_req;  // 中止请求
    maxb_t      max_burst;  // 最大突发长度
} s_dma_control_t;

// 状态信号 (第 114-117 行)
typedef struct packed {
    logic       error;      // 错误标志
    logic       done;       // 完成标志
} s_dma_status_t;

// 错误信息 (第 100-106 行)
typedef struct packed {
    desc_addr_t addr;       // 出错地址
    err_type_t  type_err;   // 错误类型
    err_src_t   src;        // 错误来源
    logic       valid;      // 有效标志
} s_dma_error_t;

// FSM -> Streamer 接口 (第 120-123 行)
typedef struct packed {
    logic       valid;      // 有效
    idx_desc_t  idx;        // 描述符索引
} s_dma_str_in_t;

// Streamer -> FSM 接口 (第 125-127 行)
typedef struct packed {
    logic       done;       // 完成
} s_dma_str_out_t;
```

### 7.2 dma_axi_wrapper 中的连接

`dma_axi_wrapper` 是连接 CSR 和功能逻辑的桥梁。它将 CSR 输出的扁平向量转换为结构体：

```systemverilog
// src/dma/dma_axi_wrapper.sv, 第 53-60 行
for (int i=0; i<`DMA_NUM_DESC; i++) begin : connecting_structs_with_csr
  dma_desc[i].src_addr  = dma_desc_src_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
  dma_desc[i].dst_addr  = dma_desc_dst_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
  dma_desc[i].num_bytes = dma_desc_byt_vec[i*`DMA_ADDR_WIDTH +: `DMA_ADDR_WIDTH];
  dma_desc[i].wr_mode   = dma_mode_t'(dma_desc_wr_mod[i]);
  dma_desc[i].rd_mode   = dma_mode_t'(dma_desc_rd_mod[i]);
  dma_desc[i].enable    = dma_desc_en[i];
end
```

这段代码展示了如何将位向量（bit vector）解包为结构体数组。每个描述符的字段通过位选择操作符 `+:` 从打包的向量中提取。

### 7.3 信号流全景图

```
CPU (AXI-Lite)
     |
     v
dma_axi_top  (扁平 <-> struct 转换)
     |
     v
dma_axi_wrapper
     |
     +---> dma_csr  (寄存器读写)
     |         |
     |         +---> reg_go, reg_abort, reg_max_burst     -> s_dma_control_t
     |         +---> reg_src_addr[], reg_dst_addr[]       -> s_dma_desc_t[]
     |         +---> reg_num_bytes[], reg_wr_mode[]       -> s_dma_desc_t[]
     |         +---> reg_rd_mode[], reg_enable[]          -> s_dma_desc_t[]
     |         |
     |         +<-- i_dma_status_done, i_dma_error_*      <- s_dma_status_t
     |
     +---> dma_func_wrapper
               |
               +---> dma_fsm  (状态控制)
               |         |
               |         +---> dma_stream_rd_o  -> dma_streamer(RD)
               |         +---> dma_stream_wr_o  -> dma_streamer(WR)
               |         +<-- dma_stream_rd_i   <- dma_streamer(RD)
               |         +<-- dma_stream_wr_i   <- dma_streamer(WR)
               |         +<-- axi_pend_txn_i    <- dma_axi_if
               |
               +---> dma_streamer(RD)  (读突发计算)
               |         +---> dma_axi_rd_req  -> dma_axi_if
               |
               +---> dma_streamer(WR)  (写突发计算)
               |         +---> dma_axi_wr_req  -> dma_axi_if
               |
               +---> dma_fifo  (数据缓冲)
               |         +<-- dma_fifo_req     <- dma_axi_if
               |         +---> dma_fifo_resp   -> dma_axi_if
               |
               +---> dma_axi_if  (AXI4 Master)
                         +---> dma_mosi_o      -> DDR/SRAM
                         +<-- dma_miso_i       <- DDR/SRAM
```

---

## 8. 关键设计参数

### 8.1 可配置参数一览

```systemverilog
// 来源: src/dma/inc/dma_pkg.svh
`define DMA_NUM_DESC          2      // 描述符数量
`define DMA_ADDR_WIDTH        32     // 地址宽度 (= AXI_ADDR_WIDTH)
`define DMA_DATA_WIDTH        32     // 数据宽度 (= AXI_DATA_WIDTH)
`define DMA_BYTES_WIDTH       32     // 字节数宽度
`define DMA_RD_TXN_BUFF       8      // 读事务缓冲深度
`define DMA_WR_TXN_BUFF       8      // 写事务缓冲深度
`define DMA_FIFO_DEPTH        16     // 数据 FIFO 深度
`define DMA_MAX_BEAT_BURST    256    // 最大突发 beat 数
`define DMA_EN_UNALIGNED      1      // 使能非对齐传输
`define DMA_MAX_BURST_EN      1      // 使能最大突发限制
```

### 8.2 参数对性能的影响

| 参数 | 增大时的效果 | 减小时的效果 |
|------|-------------|-------------|
| `DMA_FIFO_DEPTH` | 增加吞吐量，减少停顿 | 节省面积，可能增加停顿 |
| `DMA_MAX_BEAT_BURST` | 更大突发，更高带宽 | 更小突发，更频繁的事务 |
| `DMA_RD/WR_TXN_BUFF` | 更多 outstanding 事务 | 更少 outstanding，面积更小 |
| `DMA_NUM_DESC` | 更多链式传输 | 更少描述符，逻辑更简单 |

---

## 9. 动手实验

### 实验 1: 模块层次识别

在 `src/dma/` 目录下，打开以下文件并验证模块实例化关系：

1. 打开 `dma_axi_top.sv`，找到 `dma_axi_wrapper` 的实例化（第 194-205 行）
2. 打开 `dma_axi_wrapper.sv`，找到 `dma_csr` 和 `dma_func_wrapper` 的实例化
3. 打开 `dma_func_wrapper.sv`，找到 `dma_fsm`、`dma_streamer`(x2)、`dma_fifo`、`dma_axi_if` 的实例化

**练习**: 画出完整的模块实例化树，标注每个实例的名称。

### 实验 2: 寄存器映射验证

编写一个简单的测试程序，通过 AXI-Lite 接口读写 DMA 寄存器：

```systemverilog
// 伪代码: 在 testbench 中
// 1. 读取 STATUS 寄存器 (0x08)，验证魔数 0xCAFE
// 2. 写入 DESC0.SRC (0x20) = 0x1000
// 3. 写入 DESC0.DST (0x30) = 0x2000
// 4. 写入 DESC0.NUM (0x40) = 256
// 5. 写入 DESC0.CFG (0x50) = 0x04 (enable=1)
// 6. 写入 CONTROL (0x00) = 0x01 (go=1)
// 7. 等待 dma_done_o 信号
// 8. 读取 STATUS，验证 done=1
```

### 实验 3: 参数修改实验

尝试修改 `dma_pkg.svh` 中的参数，观察综合结果的变化：

1. 将 `DMA_NUM_DESC` 从 2 改为 4，需要同时更新 CSR 中的描述符寄存器映射
2. 将 `DMA_FIFO_DEPTH` 从 16 改为 8，观察资源占用减少
3. 将 `DMA_MAX_BEAT_BURST` 从 256 改为 16，观察突发行为变化

---

## 10. 本讲要点总结

| 要点 | 说明 |
|------|------|
| DMA 的核心价值 | 释放 CPU，实现高速数据搬运 |
| 双接口设计 | AXI-Lite Slave 配置 + AXI4 Master 数据 |
| 7 层模块层次 | top -> wrapper -> {csr, func_wrapper} -> {fsm, streamer x2, fifo, axi_if} |
| 双描述符 | 支持链式传输，按序执行 |
| 寄存器映射 | CONTROL/STATUS/ERROR + 每个描述符 4 个寄存器 |
| 魔数 0xCAFE | STATUS 寄存器的标识，用于硬件检测 |
| 可配置参数 | 描述符数、FIFO 深度、突发长度等均可配置 |

---

## 11. 下节预告

下一讲（Lecture 11）将深入分析 `dma_csr.sv` 的实现细节，包括：
- AXI-Lite 写通道的 AW/W 握手解耦
- 寄存器写入的字节选通（write strobe）处理
- 读通道的组合逻辑解码
- 地址对齐和错误处理
