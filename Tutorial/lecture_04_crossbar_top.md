# Lecture 04: AXI Crossbar（一）-- 顶层架构与地址解码

## 课程概要

本讲是 AXI Crossbar 三部曲的第一篇，聚焦于 Crossbar 的**顶层架构**和**地址解码**机制。
我们将从共享总线 vs Crossbar 的对比出发，深入分析 `axicb_crossbar_top.sv` 的内部结构，
理解 4x4 交换矩阵如何将 CPU、DMA 的请求路由到 DDR、NPU LMEM、DMA CSR、NPU CSR 四个目标。

---

## 1. 共享总线 vs Crossbar

### 1.1 传统共享总线（Shared Bus）

```
  ┌──────┐   ┌──────┐   ┌──────┐
  │ MST0 │   │ MST1 │   │ MST2 │
  └──┬───┘   └──┬───┘   └──┬───┘
     │          │          │
  ═══╪══════════╪══════════╪════  ← 共享总线（同一时刻只能一对通信）
     │          │          │
  ┌──┴───┐   ┌──┴───┐   ┌──┴───┐
  │ SLV0 │   │ SLV1 │   │ SLV2 │
  └──────┘   └──────┘   └──────┘
```

**特点**：
- 同一时刻只有一个 Master 能占用总线
- 其他 Master 必须等待，带宽被所有 Master 分时共享
- 仲裁简单，但吞吐量低

### 1.2 Crossbar 互连（Crossbar Interconnect）

```
             SLV0(DDR)  SLV1(LMEM) SLV2(DMA) SLV3(NPU)
               │          │          │          │
  ┌────────────┼──────────┼──────────┼──────────┼────────┐
  │            ▼          ▼          ▼          ▼        │
  │   ┌────────────────────────────────────────────┐     │
  │   │          Switching Fabric（交换矩阵）        │     │
  │   │   允许多对 Master-Slave 同时通信（无冲突时）  │     │
  │   └────────────────────────────────────────────┘     │
  │            ▲          ▲                               │
  │            │          │                               │
  └────────────┼──────────┼───────────────────────────────┘
               │          │
  ┌──────┐   ┌─┴────┐   ┌┴─────┐
  │ MST0 │   │ MST1  │   │ MST2  │  ...
  │ CPU  │   │ DMA   │   │(ext)  │
  └──────┘   └───────┘   └───────┘
```

**关键优势**：
- 多个不冲突的 Master-Slave 对可以**同时**通信
- 例如 CPU 读 DDR 的同时，DMA 写 NPU LMEM，互不阻塞
- 吞吐量 = min(MST_NB, SLV_NB) x 单通道带宽

---

## 1.1+ 设计视角：为什么这样设计？

Crossbar互连是SoC设计的核心组件，其设计决策直接影响系统的性能、面积和可扩展性。

### 核心设计决策

#### 决策1：为什么选择Crossbar而非共享总线？

```text
问题：CPU、DMA、NPU需要访问DDR、本地RAM、CSR寄存器，如何互连？

方案A：共享总线（Shared Bus）
  - 所有Master共享一条总线
  - 同一时刻只有一对Master-Slave能通信
  - 仲裁简单（固定优先级或轮转）
  - 带宽 = 单通道带宽 / Master数量

方案B：Crossbar互连（本项目选择）
  - 每个Master有独立的通路到每个Slave
  - 无冲突的Master-Slave对可以同时通信
  - 仲裁复杂（每个Slave端口独立仲裁）
  - 带宽 = 单通道带宽 × min(MST_NB, SLV_NB)

方案C：分层总线（Hierarchical Bus）
  - 高速设备用Crossbar，低速设备用共享总线
  - 折中方案，常见于大型SoC
  - 设计复杂度最高
```

**选择理由**：

| 对比维度 | 方案A：共享总线 | 方案B：Crossbar | 方案C：分层总线 |
|----------|--------------|----------------|--------------|
| 并发能力 | 低（1对） | 高（多对） | 中 |
| 面积 | 小 | 大（N×M交叉开关） | 中 |
| 延迟 | 低（直连） | 低（直连） | 中（需桥接） |
| 可扩展性 | 差 | 好 | 好 |
| 设计复杂度 | 低 | 中 | 高 |
| 典型规模 | 2-3个Master | 4-8个Master | 16+个Master |

#### 决策2：为什么选择4×4而不是其他规模？

```text
本项目的设备统计：
  Master设备：CPU、DMA、(预留×2) → 需要4个Slave端口
  Slave设备：DDR、NPU LMEM、DMA CSR、NPU CSR → 需要4个Master端口

  ┌──────────────────────────────────────────────┐
  │ Crossbar端口配置                              │
  ├──────────┬───────────────────────────────────┤
  │ Slave端口 │ 连接的Master设备                   │
  ├──────────┼───────────────────────────────────┤
  │ slv0     │ CPU (通过axi_lite2axi桥)           │
  │ slv1     │ DMA控制器                          │
  │ slv2     │ 预留（未使用）                      │
  │ slv3     │ 预留（未使用）                      │
  ├──────────┼───────────────────────────────────┤
  │ Master端口│ 连接的Slave设备                    │
  ├──────────┼───────────────────────────────────┤
  │ mst0     │ DDR (256KB)                        │
  │ mst1     │ NPU LMEM (128KB)                   │
  │ mst2     │ DMA CSR (通过axi2axi_lite桥)        │
  │ mst3     │ NPU CSR (通过axi2csr桥)             │
  └──────────┴───────────────────────────────────┘

为什么预留2个Master端口？
  - 赛题要求支持扩展（如添加第二个DMA或外设）
  - Crossbar端口数固定后不可扩展，提前预留
  - 未使用的端口通过MST_ROUTES=4'b0000禁用
```

#### 决策3：为什么Crossbar内部命名与SoC层相反？

```text
从SoC层看：
  CPU是Master（发起请求），DDR是Slave（响应请求）

从Crossbar内部看：
  CPU连接到Crossbar的"从设备接口"（slv_if，接收请求）
  DDR连接到Crossbar的"主设备接口"（mst_if，发出请求）

  ┌──────────────────────────────────────────────┐
  │ 视角转换                                      │
  │                                              │
  │ SoC层:  CPU ──Master──► Crossbar ──Slave──► DDR │
  │                      │                        │
  │ Crossbar内部:  slv_if ◄── 外部Master请求       │
  │                mst_if ──► 向外部Slave发出请求   │
  └──────────────────────────────────────────────┘

这种命名方式在互连设计中很常见：
  - 从Crossbar自身的角度定义接口方向
  - "Slave接口"= 接收外部请求的接口
  - "Master接口"= 向外发出请求的接口
```

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    Crossbar 设计约束                      │
├───────────────┬─────────────────────────────────────────┤
│ 端口数约束     │ 4×4（固定，不可运行时扩展）               │
│ 地址范围约束   │ 每个Slave的地址范围不能重叠                │
│ Outstanding约束│ 每个端口的并发深度受缓冲区大小限制         │
│ 时序约束       │ 地址解码+仲裁必须在1个周期内完成           │
│ 面积约束       │ 交叉开关面积 = O(N×M)，N/M不能太大        │
│ ID宽度约束     │ ID必须能区分所有Master的事务               │
└───────────────┴─────────────────────────────────────────┘
```

---

## 1.2+ 设计视角：如何从零开始设计？

设计一个AXI Crossbar互连，需要系统化的方法。

### Step 1：确定端口规模和地址映射

```text
输入：系统中所有需要互连的设备

工作：
  1. 统计Master设备数量 → 确定Slave端口数
  2. 统计Slave设备数量 → 确定Master端口数
  3. 为每个Slave分配不重叠的地址范围
  4. 确定每个Master可以访问哪些Slave（路由掩码）

输出：
  端口配置表、地址映射表、路由掩码表
```

### Step 2：设计地址解码器

```text
输入：地址映射表

设计：
  对于每个Master请求，需要判断地址命中哪个Slave：

  for each slave in [SLV0, SLV1, SLV2, SLV3]:
    if (START_ADDR <= ADDR <= END_ADDR):
      route[slave] = 1
    else:
      route[slave] = 0

  // 与路由掩码取交集
  final_route = route & MST_ROUTES[master_id]

  // 如果无命中，返回DECERR
  if (final_route == 0):
    return DECERR

实现：
  - 地址比较用组合逻辑（AND门+比较器）
  - 路由向量是one-hot编码
  - 每个Master独立解码，无共享状态
```

### Step 3：设计交换矩阵

```text
核心问题：如何将Master的请求路由到正确的Slave？

方案A：多路选择器矩阵
  - 每个Slave端口用一个N选1的MUX
  - 选择信号来自地址解码器
  - 简单直接，但MUX延迟随N增大

方案B：总线矩阵（本项目使用）
  - 内部使用打包的宽总线（i_awch, i_wch等）
  - 每个Slave端口从宽总线中选择对应的Master数据
  - 用valid信号控制数据流

  ┌──────────────────────────────────────────────┐
  │ 内部总线结构                                  │
  │                                              │
  │ slv0_if ──┐                                  │
  │ slv1_if ──┼── i_awch[4*AWCH_W-1:0] ──┬── mst0_if │
  │ slv2_if ──┤                          ├── mst1_if │
  │ slv3_if ──┘                          ├── mst2_if │
  │                                      └── mst3_if │
  └──────────────────────────────────────────────┘
```

### Step 4：设计仲裁逻辑

```text
问题：多个Master同时请求同一个Slave时，谁先获得访问？

设计选择：
  - 固定优先级：简单，但低优先级可能饥饿
  - Round-Robin：公平，但实现复杂
  - 优先级+Round-Robin：本项目选择，兼顾公平和优先级

每个Slave端口独立仲裁：
  SLV0仲裁器：处理所有请求DDR的Master
  SLV1仲裁器：处理所有请求NPU LMEM的Master
  ...
```

### Step 5：设计ID管理机制

```text
问题：多个Master发出的事务ID可能相同（如CPU和DMA都用ID=5）
     Slave返回响应时，Crossbar如何知道这是给谁的？

解决方案：ID Mask
  - 每个Master分配唯一的ID_MASK
  - Master发出的ID会被XOR上ID_MASK后存入FIFO
  - Slave返回的响应ID也XOR上ID_MASK
  - 匹配成功则路由回对应Master

  CPU  (MASK=0x10): ID=0x05 → XOR → 0x15（存入FIFO）
  DMA  (MASK=0x20): ID=0x05 → XOR → 0x25（存入FIFO）
  Slave返回ID=0x05 → XOR 0x10 = 0x15 → 匹配CPU
                   → XOR 0x20 = 0x25 → 匹配DMA
```

---

## 1.3+ 设计视角：架构模式与原则

Crossbar互连中蕴含了三个核心设计模式。

### 模式1：Crossbar 交换模式 (Crossbar Switching)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Crossbar 交换矩阵 (Crossbar Switching Matrix)  │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   使用N×M的交叉开关矩阵，允许任意Master与任意Slave建立      │
│   独立的通信路径，无冲突的路径可以同时工作。                 │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 每个Master有独立的请求通道                           │
│   2. 每个Slave有独立的仲裁器                              │
│   3. 地址解码生成one-hot路由向量                          │
│   4. 交换矩阵根据路由向量连接Master到Slave                 │
│   5. 内部使用打包宽总线减少物理连线                        │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   4×4 Crossbar:                                         │
│     4个slv_if接收外部Master请求                           │
│     4个mst_if驱动外部Slave接口                            │
│     switch_top内部完成地址解码+仲裁+路由                   │
│     CPU→DDR 和 DMA→NPU LMEM 可以同时进行                 │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 多核CPU的L2 Cache互连                                │
│   - NoC（Network on Chip）中的路由器                      │
│   - PCIe Switch的端口互连                                │
│   - 内存控制器的多通道交叉                                │
└─────────────────────────────────────────────────────────┘
```

### 模式2：地址路由模式 (Address Routing)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 基于地址范围的路由 (Address-Range Routing)      │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   为每个目标设备分配唯一的地址范围，                        │
│   通过比较请求地址与各设备的地址范围来决定路由目标。         │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 每个设备配置 START_ADDR 和 END_ADDR                 │
│   2. 对每个请求：if (START <= addr <= END) → 命中         │
│   3. 生成one-hot路由向量                                  │
│   4. 与Master的路由掩码取交集（权限控制）                  │
│   5. 无命中时返回DECERR（解码错误）                        │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   Crossbar地址解码：                                     │
│     addr=0x4000_0000 → 命中SLV0 (DDR)                   │
│     addr=0x0000_1000 → 命中SLV1 (NPU LMEM)              │
│     addr=0x0002_1000 → 命中SLV2 (DMA CSR)               │
│     addr=0x0003_0000 → 命中SLV3 (NPU CSR)               │
│     addr=0x5000_0000 → 无命中 → DECERR                   │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何基于地址的设备选择                                │
│   - Cache的Tag比较                                       │
│   - 虚拟内存的页表翻译                                    │
│   - PCIe BAR地址解码                                     │
└─────────────────────────────────────────────────────────┘
```

### 模式3：ID Mask 身份标识模式 (ID Masking)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: ID Mask 身份标识 (ID Masking for Source ID)    │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   当多个Master共享总线时，通过XOR掩码为每个Master的事务     │
│   添加唯一标识，使得响应能正确路由回原始Master。             │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 每个Master分配唯一的ID_MASK（如CPU=0x10, DMA=0x20）  │
│   2. 事务发出时：stored_id = original_id XOR ID_MASK      │
│   3. 响应返回时：matched = (response_id XOR ID_MASK)      │
│   4. 用stored_id在FIFO中查找对应的事务信息                 │
│   5. 将响应路由回正确的Master                              │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   CPU (MASK=0x10) 发出 ID=0x05                           │
│     → 存入FIFO: 0x05 XOR 0x10 = 0x15                    │
│   DMA (MASK=0x20) 发出 ID=0x05                           │
│     → 存入FIFO: 0x05 XOR 0x20 = 0x25                    │
│   Slave返回 ID=0x05                                      │
│     → XOR 0x10 = 0x15 → 匹配CPU的FIFO条目               │
│     → XOR 0x20 = 0x25 → 匹配DMA的FIFO条目               │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何多Master共享Slave的互连                           │
│   - 网络交换机的源端口标记                                │
│   - 多线程处理器的事务追踪                                │
│   - 分布式系统中的请求-响应匹配                           │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 本项目的 4x4 Crossbar 拓扑

### 2.1 系统级视图

```
  ┌─────────────────────────────────────────────────────────────┐
  │                    AXI Crossbar (4x4)                       │
  │                                                             │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
  │  │ slv0_if  │  │ slv1_if  │  │ slv2_if  │  │ slv3_if  │   │
  │  │ (CPU)    │  │ (DMA)    │  │ (ext)    │  │ (ext)    │   │
  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
  │       │             │             │             │           │
  │  ┌────┴─────────────┴─────────────┴─────────────┴────┐     │
  │  │           axicb_switch_top (交换逻辑)               │     │
  │  │    ┌────────────────────────────────────────┐     │     │
  │  │    │ slv_switch_wr / slv_switch_rd (写/读)   │     │     │
  │  │    │ mst_switch_wr / mst_switch_rd (写/读)   │     │     │
  │  │    └────────────────────────────────────────┘     │     │
  │  └────┬─────────────┬─────────────┬─────────────┬────┘     │
  │       │             │             │             │           │
  │  ┌────┴─────┐  ┌────┴─────┐  ┌────┴─────┐  ┌────┴─────┐   │
  │  │ mst0_if  │  │ mst1_if  │  │ mst2_if  │  │ mst3_if  │   │
  │  │ (DDR)    │  │ (LMEM)   │  │ (DMA CSR)│  │ (NPU CSR)│   │
  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
  └─────────────────────────────────────────────────────────────┘
```

### 2.2 端口命名约定（重要！）

Crossbar 内部的命名视角**与 soc_top 相反**：

| 方向 | Crossbar 端口名 | 含义 |
|------|-----------------|------|
| Master→Crossbar | `slv0_`, `slv1_`, ... | Crossbar 视角：这些是**从设备接口**（接收请求） |
| Crossbar→Slave | `mst0_`, `mst1_`, ... | Crossbar 视角：这些是**主设备接口**（发出请求） |

> **关键理解**：从 Crossbar 自身来看，CPU/DMA 是"连接到我的 Slave"，
> DDR/NPU 是"我驱动的 Master"。这与 SoC 层面的 Master/Slave 定义正好反过来。

---

## 3. axicb_crossbar_top.sv 内部结构

### 3.1 三大部分

源文件: `src/axi_crossbar/axicb_crossbar_top.sv`

```
axicb_crossbar_top
  │
  ├─ [1] 4x axicb_slv_if    (slv0_if ~ slv3_if)   行 756~1134
  │       接收外部 Master 的 AXI 请求
  │       输出：打包后的内部总线 i_awch, i_arch 等
  │
  ├─ [2] 1x axicb_switch_top (switchs)              行 1140~1214
  │       核心交换逻辑：地址解码 + 仲裁 + 路由
  │
  └─ [3] 4x axicb_mst_if    (mst0_if ~ mst3_if)    行 1221~1603
          驱动外部 Slave 的 AXI 接口
          将内部总线解包为标准 AXI 信号
```

### 3.2 内部总线打包

为了减少模块间连线，所有 AXI 通道信号被打包成宽总线：

```
文件: src/axi_crossbar/axicb_crossbar_top.sv, 行 694~704

    // AXI4 signaling 下的通道宽度
    localparam AWCH_W = AXI_ADDR_W + AXI_ID_W + 29 + AUSER_W;  // 写地址通道
    localparam WCH_W  = AXI_DATA_W + AXI_DATA_W/8 + WUSER_W;    // 写数据通道
    localparam BCH_W  = AXI_ID_W + 2 + BUSER_W;                  // 写响应通道
    localparam ARCH_W = AWCH_W;                                   // 读地址通道
    localparam RCH_W  = AXI_DATA_W + AXI_ID_W + 2 + RUSER_W;    // 读数据通道
```

打包方式（以 AW 通道为例）：

```
AWCH_W 位的打包内容:
┌──────────────────────────────────────────────────────┐
│ [AWCH_W-1 : AWCH_W-AUSER_W]  awuser                  │
│ [AWCH_W-AUSER_W-1 : 29]      awid                    │
│ [28:21]                       awlen (8bit)            │
│ [20:18]                       awsize (3bit)           │
│ [17:16]                       awburst (2bit)          │
│ [15]                          awlock                  │
│ [14:11]                       awcache (4bit)          │
│ [10:8]                        awprot (3bit)           │
│ [7:4]                         awqos (4bit)            │
│ [3:0]                         awregion (4bit)         │
│ [ADDR_W-1:0]                  awaddr                  │
└──────────────────────────────────────────────────────┘
```

### 3.3 端口连接映射

```
文件: src/axi_crossbar/axicb_crossbar_top.sv, 行 716~749

内部信号（打包后）:
  i_awvalid[3:0]  ← 各 slv_if 的输出（Master 请求）
  i_awch[4*AWCH_W-1:0]  ← 打包后的写地址
  i_arvalid[3:0]  ← 各 slv_if 的读请求
  o_awvalid[3:0]  → 各 mst_if 的输出（送往 Slave）
  o_awch[4*AWCH_W-1:0]  → 打包后的写地址
```

---

## 4. 地址解码逻辑

### 4.1 地址映射表

本项目的地址映射在 `soc_top.sv` 行 491~515 中配置：

```
文件: src/soc_top.sv, 行 504~515

    // Slave 0: DDR (256KB @ 0x4000_0000)
    .SLV0_START_ADDR(32'h4000_0000), .SLV0_END_ADDR(32'h4003_FFFF),
    // Slave 1: NPU LMEM (128KB @ 0x0000_1000)
    .SLV1_START_ADDR(32'h0000_1000), .SLV1_END_ADDR(32'h0002_0FFF),
    // Slave 2: DMA CSR (4KB @ 0x0002_1000)
    .SLV2_START_ADDR(32'h0002_1000), .SLV2_END_ADDR(32'h0002_1FFF),
    // Slave 3: NPU CSR (4KB @ 0x0003_0000)
    .SLV3_START_ADDR(32'h0003_0000), .SLV3_END_ADDR(32'h0003_0FFF),
```

整理成表：

```
┌──────────┬─────────────┬─────────────┬───────────┬────────────┐
│ Slave ID │ 起始地址     │ 结束地址     │ 大小      │ 目标设备    │
├──────────┼─────────────┼─────────────┼───────────┼────────────┤
│ SLV0     │ 0x4000_0000 │ 0x4003_FFFF │ 256 KB    │ DDR        │
│ SLV1     │ 0x0000_1000 │ 0x0002_0FFF │ 128 KB    │ NPU LMEM   │
│ SLV2     │ 0x0002_1000 │ 0x0002_1FFF │ 4 KB      │ DMA CSR    │
│ SLV3     │ 0x0003_0000 │ 0x0003_0FFF │ 4 KB      │ NPU CSR    │
└──────────┴─────────────┴─────────────┴───────────┴────────────┘
```

### 4.2 地址解码规则

解码逻辑位于 `axicb_switch_top.sv` 中，规则非常简单：

```
路由条件:  START_ADDR <= ADDR <= END_ADDR
```

当一个地址同时命中多个 Slave 时（地址重叠），编号较小的 Slave 优先。

实际的解码代码在 `axicb_slv_switch_wr.sv` 和 `axicb_slv_switch_rd.sv` 中，
对每个 Master 请求，检查其地址是否落在各 Slave 的地址范围内，生成 one-hot 路由向量。

### 4.3 地址解码示例

```
CPU 发起读请求: ARADDR = 0x0003_0004

解码过程:
  SLV0: 0x4000_0000 <= 0x0003_0004 <= 0x4003_FFFF ?  NO
  SLV1: 0x0000_1000 <= 0x0003_0004 <= 0x0002_0FFF ?  NO
  SLV2: 0x0002_1000 <= 0x0003_0004 <= 0x0002_1FFF ?  NO
  SLV3: 0x0003_0000 <= 0x0003_0004 <= 0x0003_0FFF ?  YES → 路由到 NPU CSR
```

### 4.4 MST_ROUTES 路由掩码

除了地址解码，每个 Master 还有一个**路由掩码**，限制它可以访问哪些 Slave：

```
文件: src/soc_top.sv, 行 496~503

    .MST0_ROUTES(4'b1111),   // CPU   → 可访问所有 4 个 Slave
    .MST1_ROUTES(4'b1111),   // DMA   → 可访问所有 4 个 Slave
    .MST2_ROUTES(4'b0000),   // 外部2  → 未使用（全0 = 禁止访问任何 Slave）
    .MST3_ROUTES(4'b0000),   // 外部3  → 未使用
```

路由掩码与地址解码**取交集**：
```
最终路由 = 地址解码结果 & MSTx_ROUTES
```

如果最终路由全为 0，说明该 Master 无权访问该地址，请求会被拒绝（或路由到 error slave）。

---

## 5. ID Mask 机制

### 5.1 问题背景

AXI 协议允许多个 Outstanding 事务（Outstanding Transaction），即 Master 发出请求后
不必等响应就可以发下一个。当多个 Master 共享同一个 Slave 时，Slave 返回的响应中
只有 ID，没有"这是给哪个 Master 的"信息。

Crossbar 需要知道：**这个响应应该路由回哪个 Master？**

### 5.2 ID Mask 的工作原理

每个 Master 被分配一个唯一的 ID Mask：

```
文件: src/soc_top.sv, 行 497~503

    .MST0_ID_MASK(8'h10),   // CPU   的 ID 掩码
    .MST1_ID_MASK(8'h20),   // DMA   的 ID 掩码
    .MST2_ID_MASK(8'h30),   // 外部2  的 ID 掩码
    .MST3_ID_MASK(8'h40),   // 外部3  的 ID 掩码
```

**原理**：
1. Master 发出的 AXI ID 会被 XOR 上其 ID_MASK 后存入 FIFO
2. Slave 返回的响应 ID 也会 XOR 上各 Master 的 ID_MASK
3. 匹配成功 → 响应路由回对应的 Master

```
                      ┌─────────────┐
  CPU 发出 ID=0x05    │             │
  XOR MST0_MASK=0x10  │  Slave 返回  │    XOR MST0_MASK=0x10
  → 存入 FIFO: 0x15  │  ID=0x05    │  → 匹配: 0x15 == 0x15 ✓
                      │             │    → 路由回 CPU
                      └─────────────┘
```

### 5.3 ID Mask 在 axicb_slv_ooo.sv 中的使用

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 123

    // Unmasked Address Channel ID to target the right FIFO
    always_comb a_id_m = a_id ^ MST_ID_MASK;
```

当响应到达时，用同样的 XOR 运算反查原始 ID，再与 FIFO 中存储的信息匹配，
从而确定该响应属于哪个 Outstanding 事务。

---

## 6. 完整的数据流路径

### 6.1 CPU 写 NPU CSR 的完整路径

```
CPU 核心
  │
  ▼ AXI4 写请求 (AWADDR=0x0003_0000, AWID=0x05)
  │
[1] axicb_slv_if (slv0_if)
  │   接收 AXI 信号，打包为内部总线
  │   AWID XOR MST0_ID_MASK → 0x15
  ▼
[2] axicb_switch_top
  │   地址解码: 0x0003_0000 → SLV3 (NPU CSR)
  │   仲裁: CPU(MST0) 获得 SLV3 的访问权
  │   路由: 写请求转发到 SLV3 端口
  ▼
[3] axicb_mst_if (mst3_if)
  │   解包内部总线为标准 AXI 信号
  │   可能进行地址偏移（KEEP_BASE_ADDR=0 时减去基地址）
  ▼
[4] axi2csr 桥 (u_npu_csr_bridge)
  │   AXI4 单拍事务 → CSR 简单接口
  │   csr_wr_en=1, csr_addr=0x00, csr_wdata=写入值
  ▼
[5] NPU 顶层 (npu_top)
    接收 CSR 写入，执行寄存器配置
```

### 6.2 DMA 读 DDR 的完整路径

```
DMA 引擎
  │
  ▼ AXI4 读请求 (ARADDR=0x4000_1000)
  │
[1] axicb_slv_if (slv1_if)     ← DMA 连接在 slv1
  ▼
[2] axicb_switch_top
  │   地址解码: 0x4000_1000 → SLV0 (DDR)
  │   仲裁: DMA(MST1) 获得 SLV0 的访问权
  ▼
[3] axicb_mst_if (mst0_if)     ← DDR 连接在 mst0
  ▼
[4] DDR 控制器
    返回读数据，ID 经 XOR 后路由回 DMA
```

### 6.3 并发通信示例

```
时钟周期   CPU→NPU CSR      DMA→DDR          冲突？
───────── ─────────────── ──────────────── ──────
T1        写请求发出        读请求发出        无冲突（不同Slave）
T2        NPU CSR 响应      DDR 返回 beat0    无冲突
T3        (idle)            DDR 返回 beat1    -
T4        (idle)            DDR 返回 beat2    -

结论: CPU 和 DMA 同时在通信，互不阻塞！
```

---

## 7. 关键参数详解

### 7.1 Outstanding 请求参数

```
文件: src/axi_crossbar/axicb_crossbar_top.sv, 行 66~88

参数含义:
  MSTx_OSTDREQ_NUM  : 该 Master 最多可以同时有多少个未完成请求
  MSTx_OSTDREQ_SIZE : 每个未完成请求的数据阶段大小（拍数）
  SLVx_OSTDREQ_NUM  : 该 Slave 最多可以缓存多少个未完成请求
  SLVx_OSTDREQ_SIZE : 每个缓存请求的数据阶段大小
```

内部缓冲区大小计算：
```
SIZE = AXI_DATA_W x OSTDREQ_NUM x OSTDREQ_SIZE (bits)

例如 CPU 端: 32bit x 4 x 1 = 128 bits = 16 bytes 缓冲
```

### 7.2 Pipeline 参数

```
MST_PIPELINE = 0  → Master 侧无流水线（零延迟）
SLV_PIPELINE = 0  → Slave  侧无流水线（零延迟）
```

Pipeline 的实现在 `axicb_pipeline.sv` 中，当 `NB_PIPELINE=0` 时直接透传：
```
文件: src/axi_crossbar/axicb_pipeline.sv, 行 28~31

    if (NB_PIPELINE==0) begin: NO_PIPELINE
        assign o_valid = i_valid;
        assign o_data  = i_data;
        assign i_ready = o_ready;
    end
```

### 7.3 AXI_SIGNALING 参数

```
AXI_SIGNALING = 1  → 支持完整 AXI4（包括 awlen, awburst 等）
AXI_SIGNALING = 0  → 仅支持 AXI4-Lite（无 burst 传输）
```

---

## 8. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| Crossbar vs Shared Bus | Crossbar 允许多对同时通信；共享总线同一时刻只能一对 |
| 端口命名反转 | Crossbar 内部 slv_* 接收请求，mst_* 发出请求 |
| 地址解码 | START_ADDR <= ADDR <= END_ADDR，与 MST_ROUTES 取交集 |
| ID Mask | 通过 XOR 运算在响应中识别原始 Master |
| 内部打包 | AXI 信号被打包为宽总线减少连线 |
| Outstanding | OSTDREQ_NUM 控制并发深度，影响性能和面积 |
| Pipeline | 可选的流水线级数，0=直通，增加延迟换取时序 |

---

## 9. 动手练习

### 练习 1: 地址解码判断

给定以下地址映射，判断下列地址分别路由到哪个 Slave：

```
SLV0: 0x4000_0000 ~ 0x4003_FFFF  (DDR)
SLV1: 0x0000_1000 ~ 0x0002_0FFF  (NPU LMEM)
SLV2: 0x0002_1000 ~ 0x0002_1FFF  (DMA CSR)
SLV3: 0x0003_0000 ~ 0x0003_0FFF  (NPU CSR)
```

地址列表：
- (a) `0x4000_0000` → SLV?
- (b) `0x0001_0000` → SLV?
- (c) `0x0002_1004` → SLV?
- (d) `0x0003_0008` → SLV?
- (e) `0x5000_0000` → SLV?（不在任何范围内）

### 练习 2: ID Mask 计算

```
MST0_ID_MASK = 0x10  (CPU)
MST1_ID_MASK = 0x20  (DMA)
```

假设 CPU 发出 ID=0x03，DMA 发出 ID=0x03（ID 相同！）：

1. 存入 FIFO 时的 XOR 值分别是多少？
2. Slave 返回 ID=0x03 的响应，Crossbar 如何区分这是给 CPU 还是 DMA 的？

### 练习 3: 路由掩码分析

```
MST2_ROUTES = 4'b0000
```

解释：如果外部 Master 2 发出一个地址为 `0x4000_0000` 的请求，会发生什么？

### 练习 4: 代码阅读

阅读 `src/axi_crossbar/axicb_crossbar_top.sv` 行 644~678 的参数检查代码，
回答：
1. 如果 `MST0_OSTDREQ_NUM=4` 但 `MST0_OSTDREQ_SIZE=0`，会发生什么？
2. 为什么 `MST0_ID_MASK` 不能为 0？

---

## 10. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_crossbar_top.sv` | Crossbar 顶层，实例化 slv_if/switch/mst_if |
| `src/soc_top.sv` 行 491~677 | Crossbar 在 SoC 中的实例化和参数配置 |
| `src/axi_crossbar/axicb_switch_top.sv` | 交换逻辑顶层，包含地址解码和仲裁 |
| `src/axi_crossbar/axicb_slv_if.sv` | Slave 接口（接收 Master 请求） |
| `src/axi_crossbar/axicb_mst_if.sv` | Master 接口（驱动 Slave） |
| `src/axi_crossbar/axicb_pipeline.sv` | 可选的流水线寄存器 |
