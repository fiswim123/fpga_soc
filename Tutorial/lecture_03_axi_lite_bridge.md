# Lecture 03: AXI-Lite 与协议转换桥

## 课程目标

本讲讲解 AXI4-Lite 协议与 AXI4 的区别，以及本项目中两个协议转换桥的详细实现。
学完本讲后，你将能够：

1. 列出 AXI-Lite 与 AXI4 的 6 个关键区别
2. 解释 axi_lite2axi 桥如何为 Lite 事务"补齐"AXI4 信号
3. 解释 axi2axi_lite 桥如何"剥离"AXI4 的 burst 能力
4. 手工推演两个桥的状态机运行过程
5. 理解桥在 SoC 中的部署位置

---

## 1. AXI-Lite 是什么？

AXI4-Lite 是 AXI4 的精简版，专为低速寄存器访问场景设计。很多 IP 核（如 UART、
SPI、GPIO 控制器）只需要简单的单拍读写，用完整的 AXI4 太浪费资源。

```
  AXI4 全功能                          AXI4-Lite 精简版
  +--------------------------+        +------------------+
  | 5 通道，每通道完整信号    |        | 5 通道，信号精简  |
  | Burst 传输 (最多 256 拍) |        | 仅支持单拍传输    |
  | 乱序完成 (ID)            |        | 无 burst 参数     |
  | 4KB 边界管理             |        | 无 len/size/burst |
  | Write interleaving       |        | 无 wlast/rlast    |
  +--------------------------+        +------------------+
```

---

## 2. AXI-Lite vs AXI4 信号对比

### 2.1 写地址通道

```
AXI4:                              AXI-Lite:
  awid    [ID_WIDTH-1:0]             awid    [ID_WIDTH-1:0]  (可选)
  awaddr  [ADDR_WIDTH-1:0]           awaddr  [ADDR_WIDTH-1:0]
  awlen   [7:0]                      -- 不存在 --
  awsize  [2:0]                      -- 不存在 --
  awburst [1:0]                      -- 不存在 --
  awlock                           -- 不存在 --
  awcache [3:0]                      -- 不存在 --
  awprot  [2:0]                      awprot  [2:0]
  awqos   [3:0]                      -- 不存在 --
  awregion [3:0]                     -- 不存在 --
  awuser                             -- 不存在 --
  awvalid                            awvalid
  awready                            awready
```

### 2.2 写数据通道

```
AXI4:                              AXI-Lite:
  wdata   [DATA_WIDTH-1:0]           wdata   [DATA_WIDTH-1:0]
  wstrb   [DATA_WIDTH/8-1:0]         wstrb   [DATA_WIDTH/8-1:0]
  wlast                             -- 不存在 --
  wuser                             -- 不存在 --
  wvalid                            wvalid
  wready                            wready
```

### 2.3 写响应通道

```
AXI4:                              AXI-Lite:
  bid     [ID_WIDTH-1:0]             bid     [ID_WIDTH-1:0]  (可选)
  bresp   [1:0]                      bresp   [1:0]
  buser                             -- 不存在 --
  bvalid                            bvalid
  bready                            bready
```

### 2.4 读地址通道

```
AXI4:                              AXI-Lite:
  arid    [ID_WIDTH-1:0]             arid    [ID_WIDTH-1:0]  (可选)
  araddr  [ADDR_WIDTH-1:0]           araddr  [ADDR_WIDTH-1:0]
  arlen   [7:0]                      -- 不存在 --
  arsize  [2:0]                      -- 不存在 --
  arburst [1:0]                      -- 不存在 --
  arlock                           -- 不存在 --
  arcache [3:0]                      -- 不存在 --
  arprot  [2:0]                      arprot  [2:0]
  arqos   [3:0]                      -- 不存在 --
  arregion [3:0]                     -- 不存在 --
  aruser                             -- 不存在 --
  arvalid                            arvalid
  arready                            arready
```

### 2.5 读数据通道

```
AXI4:                              AXI-Lite:
  rid     [ID_WIDTH-1:0]             rid     [ID_WIDTH-1:0]  (可选)
  rdata   [DATA_WIDTH-1:0]           rdata   [DATA_WIDTH-1:0]
  rresp   [1:0]                      rresp   [1:0]
  rlast                             -- 不存在 --
  ruser                             -- 不存在 --
  rvalid                            rvalid
  rready                            rready
```

### 2.6 关键区别总结

| 特性 | AXI4 | AXI-Lite |
|------|------|----------|
| Burst 传输 | 支持 (1~256 拍) | 不支持 (仅 1 拍) |
| awlen/arlen | 8 bit | 不存在 |
| awsize/arsize | 3 bit | 不存在 (隐式等于总线宽度) |
| awburst/arburst | 2 bit | 不存在 (隐式 INCR) |
| wlast/rlast | 必需 | 不存在 (永远 1 拍) |
| awlock/arlock | 1 bit | 不存在 |
| awcache/arcache | 4 bit | 不存在 |
| awqos/arqos | 4 bit | 不存在 |
| awregion/arregion | 4 bit | 不存在 |
| awuser/aruser/wuser/ruser/buser | 可选 | 不存在 |
| ID 信号 | 必需 | 可选 (本项目保留) |

---

## 1.1+ 设计视角：为什么这样设计？

协议转换桥是SoC设计中最常见的模块之一。理解其设计动机，有助于在其他项目中做出正确的架构决策。

### 核心设计决策

#### 决策1：为什么需要协议桥？为什么不统一用一种协议？

```text
问题：SoC中有CPU、DMA、NPU、DDR等不同模块，它们的接口协议不同。
      为什么不统一使用AXI4或AXI-Lite？

方案A：全部使用AXI4
  - 优点：无需桥接，直连即可
  - 缺点：简单外设（如UART、GPIO）不需要burst能力
          每个外设都需要实现完整的AXI4状态机
          面积浪费，验证成本高

方案B：全部使用AXI-Lite
  - 优点：接口简单，易于实现
  - 缺点：无法支持DMA的burst传输
          每次只能传4字节，带宽极低
          DDR控制器需要AXI4才能高效工作

方案C：混合使用 + 桥接（本项目选择）
  - CPU用AXI-Lite（简单，够用）
  - DMA用AXI4（需要burst能力）
  - DDR用AXI4（需要高带宽）
  - NPU CSR用简单CSR（只需寄存器访问）
  - 不同协议之间用桥接器转换
```

**选择理由**：

| 对比维度 | 方案A：全AXI4 | 方案B：全AXI-Lite | 方案C：混合+桥接 |
|----------|-------------|-----------------|----------------|
| 灵活性 | 低 | 低 | 高 |
| 面积效率 | 低（简单外设浪费） | 低（高性能模块受限） | 高（按需选择） |
| 设计复杂度 | 中 | 低 | 中 |
| 带宽利用率 | 高 | 低 | 高 |
| IP复用性 | 低 | 低 | 高（可用现成IP） |

#### 决策2：为什么桥需要状态机而不是纯组合逻辑？

```text
问题：桥接器能否用纯组合逻辑实现？

方案A：纯组合逻辑桥
  - 直接将AXI-Lite信号映射为AXI4信号
  - 优点：零延迟，面积小
  - 缺点：无法缓冲数据，无法处理时序差异
          如果上下游ready/valid时序不匹配，数据丢失

方案B：带缓冲的状态机桥（本项目选择）
  - 用寄存器缓冲地址和数据
  - 用状态机控制数据流方向
  - 优点：可以吸收上下游的时序差异
          可以在不同阶段独立握手
  - 缺点：增加1-2个周期延迟
```

#### 决策3：为什么 axi2axi_lite 桥需要检测burst错误？

```text
问题：如果AXI4 Master发了一个burst请求给AXI-Lite Slave会怎样？

  AXI4 Master: awlen=3（4拍burst）
  AXI-Lite Slave: 不认识awlen信号

  如果桥不检测：
    - 第1拍数据被写入Slave
    - 第2/3/4拍数据也到达，但Slave不知道还有更多拍
    - Slave可能在第1拍就返回响应
    - 后续拍的数据丢失或写入错误地址

  桥检测到burst后：
    - 不向Slave发送请求（避免混乱）
    - 直接返回SLVERR（告诉Master"不支持的操作"）
    - Master可以据此调整策略
```

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    协议桥设计约束                         │
├───────────────┬─────────────────────────────────────────┤
│ 协议合规约束   │ 必须严格遵守AXI4和AXI-Lite规范            │
│ 时序约束       │ 握手信号不能违反Valid/Ready三条规则        │
│ 错误处理约束   │ 不支持的操作必须返回错误响应（SLVERR）      │
│ 面积约束       │ 桥应尽量小，不引入不必要的缓冲              │
│ 延迟约束       │ 桥引入的延迟应尽量小（目标：1-2周期）       │
│ ID透传约束     │ 事务ID必须正确透传，用于乱序完成匹配        │
└───────────────┴─────────────────────────────────────────┘
```

---

## 1.2+ 设计视角：如何从零开始设计？

设计一个协议转换桥，需要遵循系统化的方法。

### Step 1：列出两个协议的信号差异

```text
输入：AXI4协议规范 + AXI-Lite协议规范

工作：制作信号对比表

  AXI4有但AXI-Lite没有的信号：
    写地址: awlen, awsize, awburst, awlock, awcache, awqos, awregion, awuser
    写数据: wlast, wuser
    写响应: buser
    读地址: arlen, arsize, arburst, arlock, arcache, arqos, arregion, aruser
    读数据: rlast, ruser

  AXI-Lite有但AXI4也有（可直接透传）：
    awaddr, awprot, awvalid, awready
    wdata, wstrb, wvalid, wready
    bresp, bvalid, bready
    araddr, arprot, arvalid, arready
    rdata, rresp, rvalid, rready

输出：差异表，明确哪些信号需要补齐、哪些需要剥离
```

### Step 2：确定补齐/剥离策略

```text
Lite→AXI4方向（补齐缺失信号）：
  ┌──────────────┬────────────────┬──────────────────────┐
  │ AXI4信号      │ 补齐值         │ 理由                  │
  ├──────────────┼────────────────┼──────────────────────┤
  │ awid/arid    │ 固定ID参数     │ 标识事务来源           │
  │ awlen/arlen  │ 0             │ Lite只有单拍           │
  │ awsize/arsize│ $clog2(DW/8)  │ 与数据总线宽度一致     │
  │ awburst      │ INCR (2'b01)  │ 最安全的burst类型      │
  │ wlast        │ 1             │ 单拍永远是最后一拍      │
  │ 其余         │ 0             │ 默认值，不影响功能      │
  └──────────────┴────────────────┴──────────────────────┘

AXI4→Lite方向（剥离多余信号）：
  - 忽略awlen/awsize/awburst（但要检测非法burst）
  - 忽略wlast/rlast
  - 透传addr/data/strb/prot/resp
  - 透传id信号（用于乱序匹配）
```

### Step 3：设计状态机

```text
状态机设计原则：
  1. 每个状态对应一个握手阶段
  2. 状态转移条件必须是握手完成（valid && ready）
  3. 必须有回到IDLE的路径（避免死锁）

Lite→AXI4写通道状态机：
  IDLE → 缓存AW和W（两者可任意顺序到达）
  SEND → 向AXI4侧发送AW和W
  RESP → 等待B响应并返回给Lite侧

关键设计点：
  - IDLE状态需要独立跟踪AW和W是否已缓存
  - SEND状态需要独立跟踪AW和W是否已发送
  - RESP状态需要缓存B响应直到Lite侧接收
```

### Step 4：验证边界情况

```text
需要验证的边界情况：

  1. AW和W同时到达
     → 桥能否在一个周期内同时捕获两者？

  2. AW先到，W后到（间隔多个周期）
     → 第一个缓冲区是否会阻塞第二个？

  3. 下游长时间不给ready
     → 桥是否会死锁？Valid是否保持？

  4. burst请求到达（AXI4→Lite方向）
     → 桥是否正确检测并返回SLVERR？

  5. 复位后状态
     → 所有缓冲区是否清空？状态机是否回到IDLE？
```

---

## 1.3+ 设计视角：架构模式与原则

协议桥接器中蕴含了两个核心设计模式，这些模式在任何需要"翻译"不同接口的场景中都适用。

### 模式1：协议适配器模式 (Protocol Adapter)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 协议适配器 (Protocol Adapter)                   │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   在两个不同协议的模块之间插入一个"翻译层"，                 │
│   将上游协议的语义转换为下游协议的语义，                     │
│   同时处理信号补齐、时序缓冲和错误检测。                     │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 信号映射表：定义每个上游信号对应哪个下游信号            │
│   2. 信号补齐：为下游需要但上游没有的信号赋默认值            │
│   3. 信号剥离：忽略上游有但下游不需要的信号                  │
│   4. 时序缓冲：用寄存器吸收上下游的时序差异                  │
│   5. 错误检测：检测不支持的操作并返回错误响应                │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axi_lite2axi: 补齐len/size/burst/wlast                 │
│   axi2axi_lite: 剥离burst参数，检测非法burst               │
│   axi2csr: 剥离所有AXI4信号，只保留addr/data/valid        │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - AXI到APB桥：高性能总线到低速外设总线                    │
│   - AXI到Wishbone桥：ARM生态到开源生态                     │
│   - PCIe到AXI桥：外部接口到片上总线                        │
│   - 时钟域桥：不同时钟域之间的协议转换                      │
│   - 数据宽度桥：32bit到64bit总线转换                       │
└─────────────────────────────────────────────────────────┘
```

### 模式2：信号补齐模式 (Signal Completion)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 信号补齐与剥离 (Signal Completion & Stripping)  │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   当两个协议的信号集合不完全相同时，                        │
│   对于"上游有下游无"的信号：剥离（忽略）                    │
│   对于"上游无下游有"的信号：补齐（赋默认值）                │
│   确保两个协议之间的语义等价转换。                          │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   补齐策略：                                              │
│     - 固定值：如awlen=0（单拍）                           │
│     - 计算值：如awsize=$clog2(DATA_WIDTH/8)              │
│     - 参数化：如awid=M_AXI_ID（实例化时指定）              │
│                                                         │
│   剥离策略：                                              │
│     - 忽略信号：不连接到下游                               │
│     - 检测+报错：检测到不支持的值时返回SLVERR               │
│     - 透传：某些信号两个协议都有，直接连接                  │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axi_lite2axi补齐表：                                   │
│     awid    → M_AXI_ID (固定参数)                        │
│     awlen   → 0 (固定值)                                 │
│     awsize  → $clog2(32/8)=2 (计算值)                    │
│     awburst → INCR (固定值)                              │
│     wlast   → 1 (固定值)                                 │
│                                                         │
│   axi2axi_lite剥离表：                                   │
│     awlen   → 检测!=0则报错                               │
│     awsize  → 忽略                                       │
│     awburst → 忽略                                       │
│     wlast   → 忽略                                       │
│     rlast   → 固定输出1                                  │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何两种相似但不完全兼容的协议转换                      │
│   - 数据格式转换（如大小端转换）                           │
│   - 接口版本升级（如AXI3到AXI4的适配）                     │
│   - 参数化IP的接口适配                                    │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 本项目中 AXI-Lite 类型定义

**文件路径**: `src/dma/inc/amba_axi_pkg.sv`（第 117-154 行）

```systemverilog
// src/dma/inc/amba_axi_pkg.sv (第 117-133 行)
// AXI-Lite Slave 输出结构体 (MISO: Master-In, Slave-Out)
typedef struct packed {
  logic           awready;
  logic           wready;
  axi_tid_t       bid;         // 本项目保留了 ID
  axi_resp_t      bresp;
  logic           bvalid;
  logic           arready;
  axi_tid_t       rid;         // 本项目保留了 ID
  axi_data_t      rdata;
  axi_resp_t      rresp;
  logic           rvalid;
} s_axil_miso_t;
```

```systemverilog
// src/dma/inc/amba_axi_pkg.sv (第 135-154 行)
// AXI-Lite Master 输出结构体 (MOSI: Master-Out, Slave-In)
typedef struct packed {
  axi_tid_t       awid;        // 本项目保留了 ID
  axi_addr_t      awaddr;
  axi_prot_t      awprot;
  logic           awvalid;
  axi_data_t      wdata;
  axi_wr_strb_t   wstrb;
  logic           wvalid;
  logic           bready;
  axi_tid_t       arid;        // 本项目保留了 ID
  axi_addr_t      araddr;
  axi_prot_t      arprot;
  logic           arvalid;
  logic           rready;
} s_axil_mosi_t;
```

**对比观察**: 将 `s_axil_mosi_t` 与 `s_axi_mosi_t` 对比，可以看到 AXI-Lite
移除了以下信号：
- `awlen`, `awsize`, `awburst`, `awlock`, `awcache`, `awqos`, `awregion`, `awuser`
- `wlast`, `wuser`
- `buser`
- `arlen`, `arsize`, `arburst`, `arlock`, `arcache`, `arqos`, `arregion`, `aruser`
- `rlast`, `ruser`

**注意**: 本项目在 AXI-Lite 中保留了 `awid`/`arid`/`bid`/`rid` 信号，这在标准
AXI-Lite 规范中是可选的。保留 ID 有助于调试和多主机识别。

---

## 4. axi_lite2axi.sv -- Lite 到 AXI4 桥

### 4.1 功能概述

这个桥将 AXI-Lite Master 的输出转换为完整的 AXI4 信号。核心工作是为缺少的
burst 参数补上固定值。

**文件路径**: `src/axi_crossbar/axi_lite2axi.sv`

### 4.2 模块参数（第 1-5 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 1-5 行)
module axi_lite2axi #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 8,
    parameter [ID_WIDTH-1:0] M_AXI_ID = 8'h10  // 固定事务 ID
) (
```

**知识点**: `M_AXI_ID` 参数为该桥发出的所有事务分配一个固定的 ID 值（0x10）。
在交叉互连中，不同的桥使用不同的 ID，便于 Slave 返回响应时区分来源。

### 4.3 补齐 AXI4 信号（第 81-92 行）

这是桥最核心的逻辑 -- 为 AXI-Lite 的"缺失信号"赋予固定值：

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 81-92 行)
localparam [2:0] AXSIZE = $clog2(DATA_WIDTH/8);

assign m_axi_awid    = M_AXI_ID;      // 固定 ID = 0x10
assign m_axi_wid     = M_AXI_ID;      // W 通道也用同一 ID (AXI3 兼容)
assign m_axi_arid    = M_AXI_ID;
assign m_axi_awlen   = 8'd0;          // 单拍突发: len=0 -> 1 拍
assign m_axi_arlen   = 8'd0;          // 单拍突发
assign m_axi_awsize  = AXSIZE;        // 自动计算: $clog2(4) = 2
assign m_axi_arsize  = AXSIZE;
assign m_axi_awburst = 2'b01;         // INCR (递增)
assign m_axi_arburst = 2'b01;         // INCR
assign m_axi_wlast   = 1'b1;          // 单拍永远是最后一拍
```

**信号补齐对照表**:

| AXI4 信号 | 补齐值 | 原因 |
|-----------|--------|------|
| awid / arid | M_AXI_ID (0x10) | 标识事务来源 |
| awlen / arlen | 0 | AXI-Lite 只有单拍 |
| awsize / arsize | $clog2(DATA_WIDTH/8) | 与数据总线宽度一致 |
| awburst / arburst | 01 (INCR) | 最安全的 burst 类型 |
| wlast | 1 | 单拍事务永远是 last |

**注意**: `awlock`, `awcache`, `awprot`, `awqos`, `awregion` 等信号未被赋值，
这意味着它们在综合后为默认值（0）。AXI-Lite 源端本身也没有这些信号。

### 4.4 写通道状态机

状态机使用 3 个状态完成一次完整的 Lite->AXI4 写转换：

```
状态定义 (第 97 行):
  WR_IDLE = 2'd0   空闲，等待接收 AW 和 W
  WR_SEND = 2'd1   向 AXI4 侧发送 AW 和 W
  WR_RESP = 2'd2   等待 B 响应并返回给 Lite 侧
```

```
状态转移图:

                AW 和 W 都已缓存
  +---------+  ─────────────────>  +---------+
  | WR_IDLE |                      | WR_SEND |
  +---------+  <─────────────────  +---------+
       ^       B 握手完成 (b_v &&     |
       |       s_axi_lite_bready)    | AW 和 W 都已发送
       |                             | (aw_sent && w_sent)
       |                             v
       |                         +---------+
       +──────────────────────── | WR_RESP |
                B 到达且 Lite     +---------+
                侧已接收完成
```

#### WR_IDLE 状态详解（第 162-182 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 162-182 行)
WR_IDLE: begin
  // 独立捕获 AW 和 W -- 两者可以同时到达，也可以先后到达
  if (s_axi_lite_awvalid && s_axi_lite_awready) begin
    aw_buf_v <= 1'b1;                    // 标记 AW 缓冲区有效
    awaddr_q <= s_axi_lite_awaddr;       // 锁存地址
  end
  if (s_axi_lite_wvalid && s_axi_lite_wready) begin
    w_buf_v  <= 1'b1;                    // 标记 W 缓冲区有效
    wdata_q  <= s_axi_lite_wdata;        // 锁存数据
    wstrb_q  <= s_axi_lite_wstrb;        // 锁存字节选通
  end

  // 当 AW 和 W 都已捕获（不论先后），转入发送状态
  if ((aw_buf_v || (s_axi_lite_awvalid && s_axi_lite_awready)) &&
      (w_buf_v  || (s_axi_lite_wvalid  && s_axi_lite_wready ))) begin
    aw_sent  <= 1'b0;
    w_sent   <= 1'b0;
    b_v      <= 1'b0;
    wr_state <= WR_SEND;
  end
end
```

**设计要点**: AXI 协议允许写地址和写数据以任意顺序到达。这个状态机用两个独立的
标志位 `aw_buf_v` 和 `w_buf_v` 分别跟踪两者是否已捕获，体现了协议的灵活性。

#### WR_SEND 状态详解（第 184-191 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 184-191 行)
WR_SEND: begin
  // 分别跟踪 AW 和 W 的发送完成状态
  if (!aw_sent && m_axi_awvalid && m_axi_awready) aw_sent <= 1'b1;
  if (!w_sent  && m_axi_wvalid  && m_axi_wready ) w_sent  <= 1'b1;

  // 两者都发送完成后，进入响应等待
  if (aw_sent && w_sent)
    wr_state <= WR_RESP;
end
```

**时序分析**: 在 WR_SEND 状态中，`awvalid` 和 `wvalid` 同时为高（因为数据已经
在缓冲区中了）。如果 Slave 的 `awready` 和 `wready` 也同时为高，则可以在同一个
时钟周期完成两个握手。

#### WR_RESP 状态详解（第 193-209 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 193-209 行)
WR_RESP: begin
  // 等待 B 通道响应到达
  if (!b_v && m_axi_bvalid) begin
    b_v     <= 1'b1;                     // 锁存响应
    bresp_q <= m_axi_bresp;
  end

  // 将响应转发给 AXI-Lite 侧，等待对方接收
  if (b_v && s_axi_lite_bready) begin
    b_v      <= 1'b0;
    aw_buf_v <= 1'b0;                    // 清除所有缓冲标志
    w_buf_v  <= 1'b0;
    aw_sent  <= 1'b0;
    w_sent   <= 1'b0;
    wr_state <= WR_IDLE;                 // 回到空闲
  end
end
```

### 4.5 写通道完整时序

```
假设: AXI-Lite Master 先发 AW，再发 W

时钟:  _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_

AXI-Lite 侧:
s_axi_lite_awvalid ___|‾‾‾‾‾|__________________________
s_axi_lite_awready ___|‾‾‾‾‾|__________________________
s_axi_lite_awaddr  ===X=====X==========================  (T0: AW 握手)

s_axi_lite_wvalid  __________|‾‾‾‾‾‾|__________________
s_axi_lite_wready  ________|‾‾‾‾‾‾‾‾|__________________
s_axi_lite_wdata   ========X========X===================  (T1-T2: W 握手)

状态:              IDLE        SEND        RESP
                   T0   T1   T2   T3   T4   T5   T6

AXI4 侧:
m_axi_awvalid      __________________|‾‾‾‾‾‾|__________  (T3: 发送 AW)
m_axi_awready      ________________________|‾‾‾‾‾‾|____
m_axi_wvalid       __________________|‾‾‾‾‾‾|__________  (T3: 发送 W)
m_axi_wready       ________________________|‾‾‾‾‾‾|____
m_axi_wlast        __________________|‾‾‾‾‾‾|__________  (永远为 1)

m_axi_bvalid       ______________________________|‾‾‾‾‾|  (T5: B 到达)
m_axi_bready       ________________________|‾‾‾‾‾‾‾‾‾‾‾|
```

### 4.6 读通道状态机

读通道比写通道简单，因为只有 AR 和 R 两个阶段。

```
状态定义 (第 126 行):
  RD_IDLE = 2'd0   等待 AR
  RD_SEND = 2'd1   向 AXI4 侧发送 AR
  RD_RESP = 2'd2   等待 R 数据并返回
```

```
状态转移图:

                AR 已缓存
  +---------+  ──────────>  +---------+
  | RD_IDLE |               | RD_SEND |
  +---------+  <──────────  +---------+
       ^       R 握手完成       |
       |       (r_v &&         | AR 已发送
       |       rready)         | (arvalid && arready)
       |                       v
       |                   +---------+
       +────────────────── | RD_RESP |
                           +---------+
```

关键代码（第 215-247 行）：

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 215-247 行)
case (rd_state)
  RD_IDLE: begin
    if (s_axi_lite_arvalid && s_axi_lite_arready) begin
      ar_buf_v <= 1'b1;
      araddr_q <= s_axi_lite_araddr;
      rd_state <= RD_SEND;
    end
  end

  RD_SEND: begin
    if (m_axi_arvalid && m_axi_arready) begin
      ar_buf_v <= 1'b0;
      r_v      <= 1'b0;
      rd_state <= RD_RESP;
    end
  end

  RD_RESP: begin
    if (!r_v && m_axi_rvalid) begin
      r_v     <= 1'b1;                    // 锁存读数据
      rdata_q <= m_axi_rdata;
      rresp_q <= m_axi_rresp;
    end
    if (r_v && s_axi_lite_rready) begin
      r_v      <= 1'b0;
      rd_state <= RD_IDLE;
    end
  end
endcase
```

### 4.7 Ready 信号生成逻辑（第 109-110 行, 第 136 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 109-110 行)
assign s_axi_lite_awready = (wr_state == WR_IDLE) && !aw_buf_v;
assign s_axi_lite_wready  = (wr_state == WR_IDLE) && !w_buf_v;

// 第 136 行
assign s_axi_lite_arready = (rd_state == RD_IDLE) && !ar_buf_v;
```

**设计分析**: Ready 只在 IDLE 状态且对应缓冲区为空时为高。这意味着：
- 如果 AW 先到达并被缓存（`aw_buf_v=1`），则 `awready` 变低，但 `wready` 仍然
  保持为高，允许 W 继续到达。
- 这种设计防止了数据丢失，同时保持了 AXI 协议的灵活性。

---

## 5. axi2axi_lite.sv -- AXI4 到 Lite 桥

### 5.1 功能概述

这个桥执行相反的转换：接收完整的 AXI4 事务，剥离 burst 参数，将其转为
AXI-Lite 格式。同时检测并拒绝非法的 burst 请求。

**文件路径**: `src/axi_crossbar/axi2axi_lite.sv`

### 5.2 模块参数（第 4-7 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 4-7 行)
module axi2axi_lite #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 32,
    parameter integer ID_WIDTH   = 8
) (
```

**注意**: 这个桥没有 `M_AXI_ID` 参数，因为它不需要生成新的 ID -- 它直接透传
上游 AXI4 事务的 ID。

### 5.3 突发错误检测（第 121-122 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 121-122 行)
wire awlen_err = (s_axi_awlen != 8'd0);   // 写突发长度不为 0 -> 错误
wire arlen_err = (s_axi_arlen != 8'd0);   // 读突发长度不为 0 -> 错误
```

**关键设计决策**: AXI-Lite 不支持 burst，所以任何 `len != 0` 的请求都是非法的。
桥检测到这种情况后，仍然完成事务，但返回 `SLVERR`（bresp/rresp = 2'b10）。

### 5.4 写通道状态机

状态定义（第 91 行）：

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 91 行)
localparam WR_IDLE = 2'd0, WR_ADDR = 2'd1, WR_DATA = 2'd2, WR_RESP = 2'd3;
```

```
状态转移图:

                AW 握手完成
  +---------+  ────────────>  +---------+
  | WR_IDLE |                 | WR_ADDR |
  +---------+                 +---------+
       ^                          |
       | B 转发完成               | AW-Lite 握手完成
       | (bvalid_q &&             v
       |  s_axi_bready)      +---------+
       |                     | WR_DATA |
       +──────────────────── +---------+
                                 |
                                 | W 握手完成
                                 | (wvalid && wready)
                                 v
                             +---------+
                             | WR_RESP |
                             +---------+
                                 |
                                 | B-Lite 到达
                                 | (bvalid && bready)
                                 v
                             (回到 WR_IDLE)
```

#### WR_IDLE -- 捕获 AW（第 175-183 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 175-183 行)
WR_IDLE: begin
    if (s_axi_awvalid && s_axi_awready) begin
        awid_q   <= s_axi_awid;       // 保存事务 ID
        awaddr_q <= s_axi_awaddr;     // 保存地址
        awprot_q <= s_axi_awprot;     // 保存保护属性
        error_aw <= awlen_err;         // 记录是否为非法 burst
        wr_state <= WR_ADDR;
    end
end
```

**知识点**: `awprot` 信号被完整透传。这是 AXI-Lite 中少数保留的控制信号之一，
用于区分安全/非安全和指令/数据访问。

#### WR_ADDR -- 转发 AW-Lite（第 185-189 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 185-189 行)
WR_ADDR: begin
    if (m_axi_lite_awvalid && m_axi_lite_awready) begin
        wr_state <= WR_DATA;
    end
end
```

在这个状态下，`m_axi_lite_awvalid` 被驱动为 `(wr_state == WR_ADDR) && !error_aw`。
如果检测到 burst 错误，`awvalid` 不会拉高，但状态机仍然继续（稍后返回 SLVERR）。

#### WR_DATA -- 转发 W（第 191-197 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 191-197 行)
WR_DATA: begin
    if (s_axi_wvalid && s_axi_wready) begin
        wdata_q  <= s_axi_wdata;
        wstrb_q  <= s_axi_wstrb;
        wr_state <= WR_RESP;
    end
end
```

**注意**: `s_axi_wready` 被连接为 `(wr_state == WR_DATA) && m_axi_lite_wready`，
意味着只有当下游 Lite 侧准备好接收时，才向上游 AXI4 侧发出 ready。

#### WR_RESP -- 转发 B（第 199-210 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 199-210 行)
WR_RESP: begin
    if (m_axi_lite_bvalid && m_axi_lite_bready) begin
        bid_q    <= awid_q;           // 用保存的 ID 回复
        bresp_q  <= error_aw ? 2'b10 : m_axi_lite_bresp;  // burst 错误返回 SLVERR
        bvalid_q <= 1'b1;
    end

    if (bvalid_q && s_axi_bready) begin
        bvalid_q <= 1'b0;
        wr_state <= WR_IDLE;
    end
end
```

**关键**: 如果 `error_aw` 为真（检测到 burst），桥忽略下游的真实响应，直接返回
`SLVERR`（2'b10）。这符合 AXI 规范 -- 向 Master 报告"不支持的操作"。

### 5.5 读通道状态机

状态定义（第 92 行）：

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 92 行)
localparam RD_IDLE = 2'd0, RD_ADDR = 2'd1, RD_DATA = 2'd2;
```

```
状态转移图:

                AR 握手完成
  +---------+  ────────────>  +---------+
  | RD_IDLE |                 | RD_ADDR |
  +---------+                 +---------+
       ^                          |
       | R 转发完成               | AR-Lite 握手完成
       | (rvalid_q &&             v
       |  s_axi_rready)      +---------+
       |                     | RD_DATA |
       +──────────────────── +---------+
                                 |
                                 | R-Lite 到达
                                 v
                             (回到 RD_IDLE)
```

关键代码（第 233-267 行）：

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 233-267 行)
case (rd_state)
    RD_IDLE: begin
        if (s_axi_arvalid && s_axi_arready) begin
            arid_q   <= s_axi_arid;
            araddr_q <= s_axi_araddr;
            arprot_q <= s_axi_arprot;       // 透传 prot
            error_ar <= arlen_err;           // 记录 burst 错误
            rd_state <= RD_ADDR;
        end
    end

    RD_ADDR: begin
        if (m_axi_lite_arvalid && m_axi_lite_arready) begin
            rd_state <= RD_DATA;
        end
    end

    RD_DATA: begin
        if (m_axi_lite_rvalid && m_axi_lite_rready) begin
            rid_q    <= arid_q;
            rdata_q  <= m_axi_lite_rdata;
            rresp_q  <= error_ar ? 2'b10 : m_axi_lite_rresp;  // burst -> SLVERR
            rlast_q  <= 1'b1;                                  // 永远标记为最后一拍
            rvalid_q <= 1'b1;
        end

        if (rvalid_q && s_axi_rready) begin
            rvalid_q <= 1'b0;
            rd_state <= RD_IDLE;
        end
    end
endcase
```

**注意**: `rlast_q` 被固定赋值为 `1'b1`，因为 AXI-Lite 只能返回单拍数据。

### 5.6 输出信号连接（第 127-156 行）

```systemverilog
// src/axi_crossbar/axi2axi_lite.sv (第 127-156 行)
// AXI-Lite Master 输出
assign m_axi_lite_awaddr  = awaddr_q;
assign m_axi_lite_awprot  = awprot_q;
assign m_axi_lite_awvalid = (wr_state == WR_ADDR) && !error_aw;

assign m_axi_lite_wdata   = wdata_q;
assign m_axi_lite_wstrb   = wstrb_q;
assign m_axi_lite_wvalid  = (wr_state == WR_DATA) && !error_aw;

assign m_axi_lite_araddr  = araddr_q;
assign m_axi_lite_arprot  = arprot_q;
assign m_axi_lite_arvalid = (rd_state == RD_ADDR) && !error_ar;

// AXI4 Slave 输出
assign s_axi_awready = (wr_state == WR_IDLE);
assign s_axi_wready  = (wr_state == WR_DATA) && m_axi_lite_wready;
assign s_axi_arready = (rd_state == RD_IDLE);

assign m_axi_lite_bready = (wr_state == WR_RESP) && s_axi_bready;
assign m_axi_lite_rready = (rd_state == RD_DATA) && s_axi_rready;
```

**设计分析**: `m_axi_lite_awvalid` 有一个 `&& !error_aw` 条件。当检测到 burst
错误时，桥不会向下游发送无效的 AW 请求，而是直接跳到响应阶段返回 SLVERR。这避免了
向下游 IP 发送它无法处理的请求。

---

## 6. 两个桥的对比

| 特性 | axi_lite2axi | axi2axi_lite |
|------|-------------|-------------|
| 方向 | Lite -> AXI4 | AXI4 -> Lite |
| 用途 | 让 Lite Master 访问 AXI 总线 | 让 AXI Master 访问 Lite Slave |
| ID 处理 | 分配固定 ID | 透传上游 ID |
| Burst 处理 | 补充 len=0, size=自动, burst=INCR | 检测 len!=0 并返回 SLVERR |
| wlast/rlast | 固定为 1 | 生成 rlast=1, 透传 wlast |
| 写通道状态数 | 3 (IDLE, SEND, RESP) | 4 (IDLE, ADDR, DATA, RESP) |
| 读通道状态数 | 3 (IDLE, SEND, RESP) | 3 (IDLE, ADDR, DATA) |
| 错误处理 | 无（假设上游合法） | 检测 burst 并返回 SLVERR |

---

## 7. 桥在 SoC 中的部署

### 7.1 典型部署位置

```
  CPU Core
     |
     | AXI-Lite (寄存器访问)
     v
  +-------------------+
  | axi_lite2axi      |  <-- 桥接: Lite -> AXI4
  +-------------------+
     |
     | AXI4
     v
  +-------------------+
  | AXI Crossbar      |  <-- 交叉互连
  +-------------------+
     |         |
     v         v
  +-------+ +-------+
  | DDR   | | DMA   |
  +-------+ +-------+

  DMA 的 CSR 端口
     |
     | AXI4 (来自 Crossbar)
     v
  +-------------------+
  | axi2axi_lite      |  <-- 桥接: AXI4 -> Lite
  +-------------------+
     |
     | AXI-Lite
     v
  +-------------------+
  | DMA CSR 寄存器     |
  +-------------------+
```

### 7.2 为什么需要两个方向的桥？

- **axi_lite2axi**: CPU 的外设总线通常是 AXI-Lite，但需要访问 DDR（AXI4）。
  桥将 Lite 请求提升为 AXI4 请求。

- **axi2axi_lite**: DMA 控制器的控制/状态寄存器（CSR）通常用 AXI-Lite 接口，
  但交叉互连可能只提供 AXI4 接口。桥将 AXI4 请求降级为 Lite 请求。

---

## 8. prot 信号透传

两个桥都透传了 `awprot`/`arprot` 信号。这个 3 位信号编码了访问权限：

```
bit 0: 0 = Unprivileged (非特权), 1 = Privileged (特权)
bit 1: 0 = Secure (安全), 1 = Non-secure (非安全)
bit 2: 0 = Data access, 1 = Instruction access
```

在 `amba_axi_pkg.sv`（第 40-44 行）中的定义：

```systemverilog
typedef enum logic [2:0] {
  AXI_INSTRUCTION = 'b100,  // 指令访问
  AXI_NONSECURE   = 'b010,  // 非安全访问
  AXI_SECURE      = 'b001   // 安全访问（特权）
} axi_prot_t;
```

**知识点**: `prot` 信号在 Lite 桥中被保留，因为很多外设需要用它来区分安全世界
和非安全世界的访问（TrustZone 安全机制）。

---

## 9. 关键知识点总结

| 概念 | 要点 |
|------|------|
| AXI-Lite | AXI4 的精简版，仅支持单拍读写 |
| 主要移除的信号 | len, size, burst, lock, cache, qos, region, last |
| 保留的信号 | addr, data, strb, prot, valid, ready, resp |
| axi_lite2axi | 补充 len=0, size=总线宽度, burst=INCR, wlast=1 |
| axi2axi_lite | 剥离 burst 参数，检测非法 burst 并返回 SLVERR |
| prot 信号 | 两桥都透传，用于安全/权限控制 |
| ID 处理 | Lite->AXI4 分配固定 ID；AXI4->Lite 透传 ID |
| 状态机设计 | Lite->AXI4 用 3 状态；AXI4->Lite 用 3-4 状态 |
| 错误处理 | AXI4->Lite 桥检测 len!=0 返回 SLVERR |

---

## 10. 动手练习

### 练习 1: 信号对比

列出 `s_axi_mosi_t`（AXI4）中有但 `s_axil_mosi_t`（AXI-Lite）中没有的所有信号，
并说明每个信号的用途。

<details>
<summary>参考答案</summary>

```
写地址通道中 AXI4 有但 Lite 没有的:
  awlen    - 突发长度
  awsize   - 每拍字节数
  awburst  - 突发类型
  awlock   - 原子操作类型
  awcache  - 缓存属性
  awqos    - 服务质量
  awregion - 区域标识
  awuser   - 用户自定义信号

写数据通道中 AXI4 有但 Lite 没有的:
  wlast    - 最后一拍标志
  wuser    - 用户自定义信号

读地址通道中 AXI4 有但 Lite 没有的:
  arlen, arsize, arburst, arlock, arcache, arqos, arregion, aruser
  (与写地址通道对应信号用途相同)

读数据通道中 AXI4 有但 Lite 没有的:
  rlast    - 最后一拍标志
  ruser    - 用户自定义信号

写响应通道中 AXI4 有但 Lite 没有的:
  buser    - 用户自定义信号
```

</details>

### 练习 2: 状态机推演

假设 `axi_lite2axi` 桥接收到以下输入序列，请推演状态机的完整运行过程：

```
T0: s_axi_lite_awvalid=1, awaddr=0x4000, s_axi_lite_wvalid=1, wdata=0xDEADBEEF
T1: m_axi_awready=1, m_axi_wready=1
T2: (无输入变化)
T3: m_axi_bvalid=1, m_axi_bresp=0, s_axi_lite_bready=1
```

<details>
<summary>参考答案</summary>

```
T0: 状态 = WR_IDLE
    - awvalid=1, awready = (IDLE && !aw_buf_v) = 1 -> AW 握手
    - aw_buf_v <= 1, awaddr_q <= 0x4000
    - wvalid=1, wready = (IDLE && !w_buf_v) = 1 -> W 握手
    - w_buf_v <= 1, wdata_q <= 0xDEADBEEF
    - 两者都已捕获: wr_state <= WR_SEND, aw_sent <= 0, w_sent <= 0

T1: 状态 = WR_SEND
    - awvalid = (SEND && aw_buf_v && !aw_sent) = 1
    - awready = 1 -> AW 发送完成: aw_sent <= 1
    - wvalid = (SEND && w_buf_v && !w_sent) = 1
    - wready = 1 -> W 发送完成: w_sent <= 1
    - aw_sent && w_sent -> wr_state <= WR_RESP

T2: 状态 = WR_RESP
    - bvalid = 0 -> 等待

T3: 状态 = WR_RESP
    - m_axi_bvalid=1, !b_v -> b_v <= 1, bresp_q <= 0
    - b_v=1 && s_axi_lite_bready=1 -> 清除所有标志, wr_state <= WR_IDLE

总延迟: 4 个时钟周期完成一次写事务。
```

</details>

### 练习 3: 错误处理分析

如果 `axi2axi_lite` 桥收到以下 AXI4 请求：
- `s_axi_awid` = 5
- `s_axi_awaddr` = 0x8000
- `s_axi_awlen` = 3（4 拍 burst）
- `s_axi_awsize` = 2

请描述桥的行为和返回的响应。

<details>
<summary>参考答案</summary>

```
1. WR_IDLE: awvalid && awready 握手
   - awid_q <= 5
   - awaddr_q <= 0x8000
   - awprot_q <= s_axi_awprot
   - error_aw <= (3 != 0) = 1  <-- 检测到 burst 错误
   - wr_state <= WR_ADDR

2. WR_ADDR:
   - m_axi_lite_awvalid = (WR_ADDR) && !error_aw = 0
   - AW-Lite 不会发出（因为 error_aw=1）
   - 但状态机仍然等待 awready
   - 如果下游 awready 一直为 0... 桥会卡在这里

   注意: 这里有一个设计细节 -- 桥在 error_aw=1 时不会发出 awvalid，
   但状态转移条件是 awvalid && awready。如果下游不给 ready，桥会卡住。
   在实际部署中，可能需要超时机制或额外的错误处理路径。

3. 如果下游最终给了 awready (或设计修正允许跳过):
   - wr_state <= WR_DATA

4. WR_DATA:
   - m_axi_lite_wvalid = (WR_DATA) && !error_aw = 0
   - W-Lite 不会发出
   - 等待 s_axi_wvalid && s_axi_wready
   - 这里 wready = (WR_DATA) && m_axi_lite_wready
   - 需要分析 m_axi_lite_wready 的来源...

   实际上，当 error_aw=1 时，这个桥的设计可能需要改进。
   但从协议角度，桥应该：
   - 吸收上游发来的所有写数据拍（只取第一拍）
   - 返回 SLVERR

5. WR_RESP:
   - 如果 bvalid 到达: bresp_q <= SLVERR (2'b10)
   - bid_q <= 5 (保存的 ID)
   - 返回给上游: bid=5, bresp=SLVERR
```

</details>

### 练习 4: 设计改进

`axi_lite2axi` 桥没有处理以下信号：`awlock`, `awcache`, `awprot`, `awqos`,
`awregion`。如果需要支持这些信号，应该如何修改代码？请给出修改方案。

<details>
<summary>参考答案</summary>

```systemverilog
// 方案 1: 在 axi_lite2axi 中添加输入端口并赋默认值
// 在端口列表中添加:
input wire [2:0]  s_axi_lite_awprot,
input wire [2:0]  s_axi_lite_arprot,

// 在 assign 区域添加:
assign m_axi_awprot  = awprot_q;  // 需要先缓存
assign m_axi_arprot  = arprot_q;

// 其余信号赋固定值:
assign m_axi_awlock  = 1'b0;      // 无原子操作
assign m_axi_awcache = 4'b0010;   // Normal Non-cacheable
assign m_axi_awqos   = 4'b0000;   // 无 QoS
assign m_axi_awregion = 4'b0000;  // 默认区域

// 方案 2: 使用参数化默认值
// 在模块参数中添加:
parameter [2:0] DEFAULT_AWPROT = 3'b010,  // Non-secure
parameter [3:0] DEFAULT_AWCACHE = 4'b0010,
```

</details>

### 练习 5: 时序对比

分别画出 `axi_lite2axi` 和 `axi2axi_lite` 处理一次读事务的时序图，对比两者的
延迟差异。

<details>
<summary>参考答案</summary>

```
axi_lite2axi (Lite->AXI4, 读):
  T0: AR 握手 (Lite 侧)
  T1: AR 发送 (AXI4 侧)
  T2: R 接收 (AXI4 侧)
  T3: R 返回 (Lite 侧)
  总延迟: 4 周期

axi2axi_lite (AXI4->Lite, 读):
  T0: AR 捕获 (AXI4 侧)
  T1: AR 转发 (Lite 侧)
  T2: R 接收 (Lite 侧)
  T3: R 返回 (AXI4 侧)
  总延迟: 4 周期

两者的延迟相同，都是 4 个时钟周期。这是因为两个桥的状态机结构
相似（3 状态: 捕获 -> 转发 -> 响应）。
```

</details>

---

## 11. 参考资料

| 文件 | 路径 | 内容 |
|------|------|------|
| AXI 宏定义 | `src/dma/inc/amba_axi.svh` | 总线宽度参数 |
| AXI 类型包 | `src/dma/inc/amba_axi_pkg.sv` | AXI4 和 AXI-Lite 类型定义 |
| Lite->AXI4 桥 | `src/axi_crossbar/axi_lite2axi.sv` | 协议提升桥 (249 行) |
| AXI4->Lite 桥 | `src/axi_crossbar/axi2axi_lite.sv` | 协议降级桥 (270 行) |

---

*上一讲: [Lecture 02 - AXI4 协议基础](lecture_02_axi_basics.md)*
*下一讲: Lecture 04 - AXI 交叉互连 (Crossbar)*
