# Lecture 06: AXI Crossbar（三）-- CSR 桥与完整数据通路

## 课程概要

本讲是 AXI Crossbar 三部曲的最后一篇，聚焦于 **CSR 桥接器**、**流水线切片**、
**错误处理**以及**完整的系统级数据通路**。我们将深入分析 `axi2csr.sv` 如何将
AXI4 协议转换为简单的 CSR 寄存器接口，并追踪 CPU 写 NPU CSR、DMA 读 NPU RAM
等典型场景的端到端数据流。

---

## 1. axi2csr -- AXI4 到 CSR 桥接器

### 1.1 为什么需要桥接器？

NPU 内部的寄存器和 RAM 使用**简单 CSR 接口**（wr_en/rd_en/addr/data），
而不是完整的 AXI4 协议。`axi2csr` 模块充当翻译器：

```
  AXI4 (来自 Crossbar)              CSR (送往 NPU)
  ┌─────────────────┐              ┌─────────────────┐
  │ AW/W/B/R 通道    │  ────────→   │ wr_en/rd_en     │
  │ ID, burst, ...  │  axi2csr     │ addr, wdata     │
  │ 握手协议         │              │ rdata           │
  └─────────────────┘              └─────────────────┘
       复杂协议                        简单接口
```

### 1.2 axi2csr 模块接口

```
文件: src/axi_crossbar/axi2csr.sv, 行 7~55

module axi2csr #(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_ID_W   = 8,
    parameter int CSR_ADDR_W = 8      // CSR 地址宽度（可小于 AXI 地址宽度）
)(
    // AXI4 Slave 接口（来自 Crossbar mst3）
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [AXI_ADDR_W-1:0]  s_awaddr,
    input  logic [7:0]             s_awlen,
    input  logic [2:0]             s_awsize,
    input  logic [AXI_ID_W-1:0]   s_awid,
    // ... W, B, AR, R 通道 ...

    // 简单 CSR Master 接口（送往 NPU）
    output logic                    csr_wr_en,
    output logic                    csr_rd_en,
    output logic [CSR_ADDR_W-1:0]  csr_addr,
    output logic [AXI_DATA_W-1:0]  csr_wdata,
    input  logic [AXI_DATA_W-1:0]  csr_rdata
);
```

### 1.3 核心状态机

axi2csr 使用一个极简的状态管理：两个寄存器 `bvalid_r` 和 `rvalid_r`
分别跟踪写响应和读响应是否 pending。

```
文件: src/axi_crossbar/axi2csr.sv, 行 57~64

    logic                  bvalid_r, rvalid_r;   // 响应 pending 标志
    logic [AXI_ID_W-1:0]  bid_r, rid_r;          // 锁存的 ID
    logic [AXI_DATA_W-1:0] rdata_r;               // 锁存的读数据
    logic [CSR_ADDR_W-1:0] addr_r;                // 锁存的地址

    // 空闲条件：没有 pending 的响应
    wire idle = !bvalid_r && !rvalid_r;
```

### 1.4 写事务处理

```
文件: src/axi_crossbar/axi2csr.sv, 行 67~68, 76~77, 111~115

    // 写接受条件：空闲 + AW 有效 + W 有效
    wire wr_accept = idle && s_awvalid && s_wvalid;

    // 写时序:
    //   Cycle 0: AW 和 W 同时到达 → wr_accept=1
    //           → csr_wr_en=1, csr_addr=AWADDR, csr_wdata=WDATA
    //           → 锁存 ID 到 bid_r
    //   Cycle 1: bvalid_r=1 → s_bvalid=1
    //           → 等待 s_bready 握手
    //   Cycle 2: bvalid_r 清零 → 回到空闲
```

时序图：

```
         ┌───┐   ┌───┐   ┌───┐   ┌───┐
  clk    │   │   │   │   │   │   │   │
      ───┘   └───┘   └───┘   └───┘   └───

  awvalid ──────────┐
  wvalid  ──────────┤
  awready ──────────┘──────────────────
  wready  ──────────┘──────────────────
  csr_wr_en ───────┐
  csr_addr  ═══════╪═══
  csr_wdata ═══════╪═══
  bvalid_r  ───────┤──────┐
  bvalid    ───────┤──────┘────────────
  bready    ──────────────────┐
                              └────────
```

### 1.5 读事务处理

```
文件: src/axi_crossbar/axi2csr.sv, 行 69, 74, 78~81, 117~123

    // 读接受条件：空闲 + AR 有效 + 无写请求在前
    wire rd_accept = idle && s_arvalid && !s_awvalid;

    // 读时序:
    //   Cycle 0: AR 到达 → rd_accept=1
    //           → csr_rd_en=1, csr_addr=ARADDR
    //           → 同周期捕获 csr_rdata
    //   Cycle 1: rvalid_r=1, rdata_r=csr_rdata
    //           → s_rvalid=1, s_rdata=rdata_r, s_rlast=1
    //           → 等待 s_rready 握手
    //   Cycle 2: rvalid_r 清零 → 回到空闲
```

### 1.6 写优先策略

```
文件: src/axi_crossbar/axi2csr.sv, 行 67~69

    wire wr_accept = idle && s_awvalid && s_wvalid;          // 写优先
    wire rd_accept = idle && s_arvalid && !s_awvalid;        // 读等待写
```

**设计意图**：当写和读同时到达时，写优先。这避免了写数据丢失
（AW+W 同时到达意味着写数据已经在总线上了）。

### 1.7 地址截取

```
文件: src/axi_crossbar/axi2csr.sv, 行 79~80

    assign csr_addr = wr_accept ? s_awaddr[CSR_ADDR_W-1:0] :
                      rd_accept ? s_araddr[CSR_ADDR_W-1:0] : addr_r;
```

CSR_ADDR_W=8，而 AXI_ADDR_W=32，所以只取低 8 位。
这意味着 NPU 内部有 256 个字节的寄存器空间（0x00~0xFF）。

---

## 1.1+ 设计视角：为什么这样设计？

CSR桥是连接高速总线和低速寄存器接口的关键组件，其设计需要在功能完整性和实现简单性之间取得平衡。

### 核心设计决策

#### 决策1：为什么需要axi2csr桥？为什么不直接用AXI4连接NPU？

```text
问题：NPU的控制寄存器应该如何被CPU访问？

方案A：NPU实现完整的AXI4 Slave接口
  - NPU内部需要实现完整的AXI4状态机
  - 需要处理burst、ID、wlast等信号
  - 优点：无需桥接，直连
  - 缺点：NPU设计复杂度大幅增加
          寄存器访问场景不需要burst能力
          面积浪费

方案B：NPU使用简单CSR接口 + axi2csr桥（本项目选择）
  - NPU只实现简单的wr_en/rd_en/addr/data接口
  - axi2csr桥负责AXI4到CSR的转换
  - 优点：NPU设计简单，专注于计算
          桥可以被多个模块复用
          调试容易（CSR接口易于观察）
  - 缺点：增加一个桥模块，增加1-2周期延迟

方案C：CPU直接用AXI-Lite访问NPU
  - 不经过Crossbar，CPU直接连接NPU
  - 优点：路径最短，延迟最低
  - 缺点：无法通过Crossbar统一管理
          CPU需要额外的地址解码逻辑
          不支持DMA访问NPU CSR
```

**选择理由**：

| 对比维度 | 方案A：NPU直连AXI4 | 方案B：CSR桥 | 方案C：CPU直连 |
|----------|------------------|-------------|--------------|
| NPU复杂度 | 高 | 低 | 低 |
| 可复用性 | 低 | 高（桥可复用） | 低 |
| 延迟 | 低 | 中（+1-2周期） | 最低 |
| 灵活性 | 高 | 高 | 低（仅CPU可访问） |
| 调试难度 | 高 | 低 | 低 |

#### 决策2：为什么axi2csr只支持单拍事务？

```text
问题：axi2csr是否应该支持burst传输？

  CSR寄存器的特点：
    - 每个寄存器有独立的地址
    - 通常一次只读写一个寄存器
    - 不需要连续传输多个数据

  如果支持burst：
    - 需要burst计数器
    - 需要地址递增逻辑
    - 需要处理wlast/rlast
    - 复杂度大幅增加

  只支持单拍（本项目选择）：
    - awlen必须为0，arlen必须为0
    - 不需要burst相关逻辑
    - 实现极简
    - 对于寄存器访问完全够用
```

#### 决策3：为什么写优先于读？

```text
问题：当写和读同时到达时，应该先处理哪个？

  axi2csr的优先级逻辑：
    wr_accept = idle && s_awvalid && s_wvalid;     // 写优先
    rd_accept = idle && s_arvalid && !s_awvalid;   // 读等待写

  为什么写优先？
    1. 写数据已经在总线上了（AW+W同时到达）
       如果不立即接收，写数据会丢失
    2. 读可以等待（AR发出后，Master可以等）
    3. 写通常用于配置，读通常用于状态查询
       配置操作的实时性更重要

  潜在问题：
    如果CPU持续写NPU CSR，读请求会被推迟（饥饿）
    实际影响：CSR操作通常低频，不会发生饥饿
```

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    CSR 桥设计约束                         │
├───────────────┬─────────────────────────────────────────┤
│ 协议约束       │ 只支持单拍事务（awlen=0, arlen=0）        │
│ 地址约束       │ CSR地址宽度通常小于AXI地址宽度             │
│ 时序约束       │ 写操作2周期完成，读操作2周期完成            │
│ 优先级约束     │ 写优先于读（避免写数据丢失）                │
│ 面积约束       │ 桥应尽量小，不引入大容量缓冲                │
│ 错误约束       │ burst请求应被检测并返回SLVERR               │
└───────────────┴─────────────────────────────────────────┘
```

---

## 1.2+ 设计视角：如何从零开始设计？

设计一个AXI到CSR的桥接器，需要理解两个协议的本质差异。

### Step 1：分析两个协议的信号差异

```text
AXI4信号（输入）：
  写：awvalid, awready, awaddr, awid, awlen, awsize
      wvalid, wready, wdata, wstrb, wlast
      bvalid, bready, bid, bresp

  读：arvalid, arready, araddr, arid, arlen, arsize
      rvalid, rready, rdata, rlast, rid, rresp

CSR信号（输出）：
  wr_en, rd_en, addr[7:0], wdata[31:0], rdata[31:0]

差异分析：
  - AXI4有握手（valid/ready），CSR无握手
  - AXI4有burst参数，CSR只有单拍
  - AXI4有ID，CSR无ID
  - AXI4有响应通道，CSR无响应
  - AXI4地址32位，CSR地址8位
```

### Step 2：设计写事务处理

```text
写事务时序：

  Cycle 0: AW和W同时到达
    - 检测 awvalid && wvalid && idle
    - 产生 csr_wr_en 脉冲
    - 锁存 awaddr[7:0] → csr_addr
    - 锁存 wdata → csr_wdata
    - 锁存 awid → bid_r
    - 设置 bvalid_r = 1

  Cycle 1: B响应
    - bvalid_r = 1 → s_bvalid = 1
    - 等待 s_bready 握手
    - 握手完成后 bvalid_r = 0，回到idle

  总延迟：2个周期
```

### Step 3：设计读事务处理

```text
读事务时序：

  Cycle 0: AR到达
    - 检测 arvalid && idle && !awvalid（写优先）
    - 产生 csr_rd_en 脉冲
    - 锁存 araddr[7:0] → csr_addr
    - 锁存 arid → rid_r
    - 同周期捕获 csr_rdata → rdata_r
    - 设置 rvalid_r = 1

  Cycle 1: R响应
    - rvalid_r = 1 → s_rvalid = 1
    - s_rdata = rdata_r
    - s_rlast = 1（单拍）
    - 等待 s_rready 握手
    - 握手完成后 rvalid_r = 0，回到idle

  总延迟：2个周期
```

### Step 4：处理边界情况

```text
需要处理的边界情况：

  1. 写和读同时到达
     → 写优先（wr_accept优先于rd_accept）

  2. burst请求到达
     → 检测 awlen!=0 或 arlen!=0
     → 返回SLVERR（本项目中axi2csr未显式检测，
       因为Crossbar保证只发单拍）

  3. 地址超出CSR范围
     → 只取低8位，高位被截断
     → 如果CSR空间小于256字节，需要额外的范围检查

  4. 复位后状态
     → bvalid_r = 0, rvalid_r = 0
     → 所有输出信号为0
```

---

## 1.3+ 设计视角：架构模式与原则

CSR桥设计中蕴含了两个核心设计模式。

### 模式1：协议降级模式 (Protocol Downgrade)

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 协议降级 (Protocol Downgrade)                  │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将复杂协议的事务转换为简单协议的事务，                    │
│   剥离复杂协议中简单协议不需要的特性，                     │
│   保留两者共有的核心语义。                                 │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 识别两个协议的共同语义（如地址+数据+读写方向）         │
│   2. 剥离上游协议的高级特性（如burst、ID、乱序）            │
│   3. 用状态机吸收时序差异                                  │
│   4. 对不支持的特性返回错误响应                            │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axi2csr: AXI4 → CSR                                   │
│     保留：地址、数据、读写方向                             │
│     剥离：burst、ID、wlast/rlast、握手                    │
│     转换：AXI4握手 → CSR使能脉冲                          │
│                                                         │
│   axi2axi_lite: AXI4 → AXI-Lite                         │
│     保留：地址、数据、strb、prot、resp                     │
│     剥离：burst参数                                      │
│     检测：burst请求 → SLVERR                              │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - AXI到APB桥：高速总线到低速外设总线                     │
│   - AXI到SPI桥：总线到串行接口                             │
│   - AXI到I2C桥：总线到低速设备                             │
│   - 任何需要将复杂协议简化为寄存器访问的场景                │
└─────────────────────────────────────────────────────────┘
```

### 模式2：Pipeline Slice 流水线切片模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Pipeline Slice (流水线切片)                     │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   在数据通路中插入寄存器级，将长组合逻辑路径切割为           │
│   多个短路径，以牺牲延迟为代价提升时钟频率。                 │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   NB_PIPELINE = 0: 直通（零延迟，组合逻辑）               │
│   NB_PIPELINE = 1: 单级寄存器（+1周期延迟）               │
│   NB_PIPELINE = N: N级寄存器（+N周期延迟）                │
│                                                         │
│   单级实现：                                              │
│     if (~full) begin                                    │
│       o_valid <= i_valid;                               │
│       o_data  <= i_data;                                │
│     end                                                 │
│     full = o_valid & ~o_ready;  // 下游未ready时锁存     │
│     i_ready = !full;                                    │
│                                                         │
│   多级实现：递归实例化N个单级pipeline                      │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   Crossbar中的MST_PIPELINE和SLV_PIPELINE参数：            │
│     = 0: 本项目使用，零延迟直通                           │
│     = 1: 可选，+1周期延迟换20-40% Fmax提升               │
│                                                         │
│   axi2csr桥本身也可以看作一个pipeline slice：             │
│     输入寄存器：锁存AW/W/AR信号                          │
│     输出寄存器：锁存B/R响应                              │
│     切割了Crossbar到NPU之间的组合逻辑路径                  │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要改善时序的长路径                              │
│   - 高速Crossbar的Master/Slave侧插入                     │
│   - DDR控制器的地址/数据通路                              │
│   - 高速串行接口（SerDes）的并行侧                       │
│   - 流水线处理器的各级之间                                │
└─────────────────────────────────────────────────────────┘
```

---

## 2. axi2csr 在 soc_top 中的实例化

### 2.1 实例化位置

```
文件: src/soc_top.sv, 行 710~756

  // NPU CSR AXI4→CSR 桥 (从设备 3)
  axi2csr #(
    .AXI_ADDR_W (AXI_ADDR_W),     // 32
    .AXI_DATA_W (AXI_DATA_W),     // 32
    .AXI_ID_W   (AXI_ID_W),       // 8
    .CSR_ADDR_W (8)                // 8-bit CSR 地址
  ) u_npu_csr_bridge (
    .clk       (clk),
    .rst_n     (resetn),
    // AXI4 Slave ← Crossbar mst3 输出
    .s_awvalid (xbar_mst3_awvalid),
    .s_awready (xbar_mst3_awready),
    .s_awaddr  (xbar_mst3_awaddr),
    // ... 其他 AXI 信号 ...
    // Simple CSR → npu_top
    .csr_wr_en (npu_csr_wr_en),
    .csr_rd_en (npu_csr_rd_en),
    .csr_addr  (npu_csr_addr),
    .csr_wdata (npu_csr_wdata),
    .csr_rdata (npu_csr_rdata)
  );
```

### 2.2 信号连接图

```
  Crossbar mst3 端口                axi2csr                npu_top
  ┌───────────────┐          ┌─────────────────┐     ┌──────────────┐
  │ xbar_mst3_aw* │─────────→│ s_aw*           │     │              │
  │ xbar_mst3_w*  │─────────→│ s_w*            │     │              │
  │ xbar_mst3_b*  │←─────────│ s_b*            │     │              │
  │ xbar_mst3_ar* │─────────→│ s_ar*           │     │              │
  │ xbar_mst3_r*  │←─────────│ s_r*            │     │              │
  └───────────────┘          │                 │     │              │
                             │ csr_wr_en ──────│────→│ npu_csr_wr_en│
                             │ csr_rd_en ──────│────→│ npu_csr_rd_en│
                             │ csr_addr  ──────│────→│ npu_csr_addr │
                             │ csr_wdata ──────│────→│ npu_csr_wdata│
                             │ csr_rdata ←─────│←────│ npu_csr_rdata│
                             └─────────────────┘     └──────────────┘
```

---

## 3. Pipeline 流水线切片

### 3.1 作用

Pipeline 切片在 Crossbar 内部的 Master/Slave 侧插入寄存器，
用于**切割组合逻辑路径**，改善时序：

```
MST_PIPELINE = 0 → Master 侧无流水线（默认，零延迟）
SLV_PIPELINE = 0 → Slave  侧无流水线（默认，零延迟）
MST_PIPELINE = 1 → Master 侧加一级流水线（+1 周期延迟，改善 Fmax）
SLV_PIPELINE = 1 → Slave  侧加一级流水线（+1 周期延迟，改善 Fmax）
```

### 3.2 Pipeline 实现

```
文件: src/axi_crossbar/axicb_pipeline.sv

// NB_PIPELINE = 0: 直通
if (NB_PIPELINE==0) begin
    assign o_valid = i_valid;
    assign o_data  = i_data;
    assign i_ready = o_ready;

// NB_PIPELINE = 1: 单级寄存器
end else if (NB_PIPELINE==1) begin
    logic full;
    always @ (posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            o_valid <= 1'b0;
            o_data <= '0;
        end else if (~full) begin
            o_valid <= i_valid;
            o_data <= i_data;
        end
    end
    assign full = (o_valid & ~o_ready);  // 下游未 ready 时锁存
    assign i_ready = !full;

// NB_PIPELINE > 1: 递归实例化
end else begin
    // 递归连接 N 个单级 pipeline
    axicb_pipeline #(.NB_PIPELINE(1)) pipe_n (...);
    axicb_pipeline #(.NB_PIPELINE(NB_PIPELINE-1)) pipe_n_m1 (...);
end
```

### 3.3 Pipeline 的性能影响

```
场景: MST_PIPELINE=1, SLV_PIPELINE=1

  CPU → [slv_if] → [slv_pipe] → [switch] → [mst_pipe] → [mst_if] → DDR
                  +1 cycle               +1 cycle

  额外延迟: 2 个周期（写方向）+ 2 个周期（读方向）= 4 个周期往返
  收益: Fmax 可能提升 20%~40%
```

---

## 4. Error Slave（错误从设备）

### 4.1 什么是 Error Slave？

当一个请求的地址不匹配任何 Slave 的地址范围时，
需要有一个"兜底"设备来返回错误响应，避免总线死锁。

### 4.2 本项目的实现

在本项目中，未匹配的地址请求会由 Crossbar 内部处理。
`MST2_ROUTES=4'b0000` 和 `MST3_ROUTES=4'b0000` 意味着
外部 Master 2/3 无法访问任何 Slave，它们的请求会被静默丢弃。

对于 CPU/DMA（MST0/MST1），如果访问了不在映射表中的地址
（如 `0x5000_0000`），路由结果为全 0，Crossbar 会返回
`SLVERR`（AXI 错误响应）。

---

## 5. 完整数据通路追踪

### 5.1 路径 1: CPU 写 NPU CSR 寄存器

这是最典型的 CSR 配置路径：

```
Step 1: CPU 核心发起 AXI4 写事务
──────────────────────────────────
  AWADDR = 0x0003_0010    (NPU CSR 基址 + 偏移 0x10)
  AWDATA = 0x0000_00FF    (配置值)
  AWID   = 0x05           (CPU 的事务 ID)
  AWLEN  = 0              (单拍)

Step 2: Crossbar slv0_if (CPU 接口)
──────────────────────────────────
  文件: src/axi_crossbar/axicb_crossbar_top.sv, 行 756~846

  - 接收 AW/W 信号
  - 打包为内部总线 i_awch, i_wch
  - AWID XOR MST0_ID_MASK → 0x05 ^ 0x10 = 0x15（存入 OOO FIFO）

Step 3: axicb_switch_top 地址解码
──────────────────────────────────
  文件: src/axi_crossbar/axicb_switch_top.sv

  - 解析 i_awch 中的地址 0x0003_0010
  - SLV0: 0x4000_0000 <= 0x0003_0010 <= 0x4003_FFFF ?  NO
  - SLV1: 0x0000_1000 <= 0x0003_0010 <= 0x0002_0FFF ?  NO
  - SLV2: 0x0002_1000 <= 0x0003_0010 <= 0x0002_1FFF ?  NO
  - SLV3: 0x0003_0000 <= 0x0003_0010 <= 0x0003_0FFF ?  YES
  → 路由到 SLV3 (NPU CSR)

Step 4: axicb_switch_top 仲裁
──────────────────────────────────
  - SLV3 此时无其他 Master 请求
  - MST0 直接获得 grant

Step 5: axicb_mst_if (mst3_if)
──────────────────────────────────
  文件: src/axi_crossbar/axicb_crossbar_top.sv, 行 1512~1603

  - 解包内部总线为标准 AXI4 信号
  - KEEP_BASE_ADDR=0: 减去 SLV3_START_ADDR (0x0003_0000)
    → 输出 AWADDR = 0x0003_0010 - 0x0003_0000 = 0x0010

Step 6: axi2csr 桥接器
──────────────────────────────────
  文件: src/axi_crossbar/axi2csr.sv

  - AW 和 W 同时到达 → wr_accept=1
  - csr_wr_en = 1
  - csr_addr = 0x0010[7:0] = 0x10
  - csr_wdata = 0x0000_00FF
  - 下一个周期: bvalid_r=1 → BRESP=OKAY 返回

Step 7: NPU 顶层接收
──────────────────────────────────
  - npu_csr_wr_en=1, npu_csr_addr=0x10, npu_csr_wdata=0xFF
  - NPU 内部寄存器 reg[0x10] = 0xFF

完整路径时序:
  T0: CPU 发 AW+W
  T1: Crossbar 解码 + 仲裁 (纯组合逻辑)
  T2: mst3_if 输出 + axi2csr 接受 → CSR 写脉冲
  T3: axi2csr 返回 BRESP → Crossbar 路由回 CPU
  T4: CPU 收到 BRESP

  总延迟: ~4 个时钟周期
```

### 5.2 路径 2: DMA 读 NPU LMEM (RAM)

这是高带宽数据传输路径：

```
Step 1: DMA 引擎发起 AXI4 读事务
──────────────────────────────────
  ARADDR = 0x0001_0000    (NPU LMEM 基址 + 偏移)
  ARLEN  = 7              (8 拍 burst)
  ARSIZE = 2              (4 字节/拍)
  ARID   = 0x03

Step 2: Crossbar slv1_if (DMA 接口)
──────────────────────────────────
  - 接收 AR 信号
  - 打包为内部总线
  - ARID XOR MST1_ID_MASK → 0x03 ^ 0x20 = 0x23

Step 3: 地址解码
──────────────────────────────────
  0x0001_0000 → SLV1 (NPU LMEM) ✓

Step 4: 仲裁 + 路由到 mst1_if
──────────────────────────────────
  - mst1_if 输出 ARADDR = 0x0001_0000 - 0x0000_1000 = 0x0F000
    (注意: KEEP_BASE_ADDR=0 时减去基地址)

Step 5: NPU LMEM 返回 8 拍读数据
──────────────────────────────────
  每个 RVALID/RDATA 通过 Crossbar 路由回 DMA
  OOO 模块跟踪 burst 完成进度

Step 6: 最后一拍 (RLAST=1)
──────────────────────────────────
  OOO 模块 pull FIFO 条目
  事务完成
```

### 5.3 路径 3: CPU 写 DDR + DMA 读 NPU LMEM（并发）

```
时序图:

  T0  T1  T2  T3  T4  T5  T6  T7  T8  T9
  │   │   │   │   │   │   │   │   │   │
  CPU 写 DDR (SLV0):
  AW+W → [解码] → [仲裁 SLV0] → [mst0_if] → DDR
                                              BRESP ←

  DMA 读 LMEM (SLV1):
  AR → [解码] → [仲裁 SLV1] → [mst1_if] → LMEM
                                            R[0] ←
                                            R[1] ←
                                            ...
                                            R[7] ←

  关键: 两个路径使用不同的 Slave (SLV0 vs SLV1)
        → 无冲突，完全并行！
        → 总吞吐量 = 单通道 x 2
```

---

## 6. DMA CSR 路径（CPU 配置 DMA）

```
路径: CPU → Crossbar SLV2 → DMA CSR 寄存器

  CPU 写 ARADDR = 0x0002_1000 (DMA CSR 基址)
  → Crossbar 解码到 SLV2
  → mst2_if 输出 (减去基址后 ARADDR = 0x0000)
  → DMA 控制寄存器被写入

注意: DMA CSR 端没有 axi2csr 桥，DMA 自身实现了 AXI4 Slave 接口
     （DMA 控制器内部直接处理 AXI 协议）
```

---

## 7. 系统级内存映射总览

```
  0x0000_0000  ┌─────────────────────────┐
               │      未映射区域          │
  0x0000_1000  ├─────────────────────────┤
               │      NPU LMEM           │  128 KB
               │      (本地 SRAM)         │
  0x0002_0FFF  ├─────────────────────────┤
  0x0002_1000  │      DMA CSR            │  4 KB
               │      (DMA 控制寄存器)    │
  0x0002_1FFF  ├─────────────────────────┤
               │      未映射区域          │
  0x0003_0000  ├─────────────────────────┤
               │      NPU CSR            │  4 KB
               │      (axi2csr 桥接)     │
  0x0003_0FFF  ├─────────────────────────┤
               │      未映射区域          │
  0x4000_0000  ├─────────────────────────┤
               │      DDR                │  256 KB
               │      (外部存储器)        │
  0x4003_FFFF  └─────────────────────────┘
```

---

## 8. 常见设计陷阱与注意事项

### 8.1 CSR 桥只支持单拍事务

```
文件: src/axi_crossbar/axi2csr.sv

axi2csr 只处理 AWLEN=0, ARLEN=0 的单拍事务。
如果 Crossbar 发送 burst 请求，桥接器会忽略后续 beat，
导致数据丢失。

设计约束: NPU CSR 地址范围应只被单拍访问（CSR 寄存器操作）
```

### 8.2 地址偏移计算

```
KEEP_BASE_ADDR 参数:
  = 0: mst_if 输出地址 = 输入地址 - SLVx_START_ADDR
  = 1: mst_if 输出地址 = 输入地址（保留绝对地址）

本项目全部使用 KEEP_BASE_ADDR=0，意味着：
  NPU 看到的地址是相对于其基址的偏移量
  DMA CSR 看到的地址也是相对于其基址的偏移量
```

### 8.3 写优先的副作用

```
axi2csr 中 rd_accept = idle && s_arvalid && !s_awvalid

如果 CPU 持续写 NPU CSR（AW 始终有效），
读请求会被无限推迟（饥饿）。

实际影响: CSR 操作通常低频，不会发生饥饿。
```

---

## 9. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| axi2csr 功能 | AXI4 单拍事务 → CSR wr_en/rd_en 接口 |
| 写时序 | AW+W 同时到达 → CSR 写 → 下一周期 BRESP |
| 读时序 | AR 到达 → CSR 读 → 同周期捕获 rdata → 下一周期 RVALID |
| 写优先 | 写和读同时到达时，写优先（避免数据丢失） |
| 地址截取 | CSR_ADDR_W=8，只取低 8 位地址 |
| Pipeline | 可选的流水线切片，0=直通，增加延迟换 Fmax |
| Error Slave | 未匹配地址返回 SLVERR，避免死锁 |
| 端到端延迟 | CPU→NPU CSR 约 4 周期；CPU→DDR 约 3 周期 |
| 并发优势 | 不同 Slave 的请求完全并行，无冲突 |

---

## 10. 动手练习

### 练习 1: axi2csr 时序分析

给定以下输入时序，画出完整的输出时序图：

```
  T0: s_awvalid=1, s_awaddr=0x20, s_awid=0x05
      s_wvalid=1, s_wdata=0xABCD_1234
  T1: s_bready=1
  T2: (idle)
  T3: s_arvalid=1, s_araddr=0x20, s_arid=0x07
  T4: s_rready=1
```

需要画出：awready, wready, csr_wr_en, csr_addr, csr_wdata,
bvalid, bid, bresp, arready, csr_rd_en, rvalid, rdata, rid, rresp

### 练习 2: 地址偏移计算

CPU 发起以下请求，计算到达各目标设备时的实际地址：

```
(a) ARADDR = 0x4000_0010, 目标 DDR
    → mst0_if 输出地址 = ?

(b) ARADDR = 0x0001_0000, 目标 NPU LMEM
    → mst1_if 输出地址 = ?

(c) AWADDR = 0x0002_1004, 目标 DMA CSR
    → mst2_if 输出地址 = ?

(d) AWADDR = 0x0003_0020, 目标 NPU CSR
    → mst3_if 输出地址 = ?
    → axi2csr 的 csr_addr = ?
```

### 练习 3: 并发带宽计算

假设：
- 时钟频率 = 100 MHz
- AXI_DATA_W = 32 bit
- DDR 延迟 = 10 周期（单次访问）
- NPU LMEM 延迟 = 1 周期

计算：
1. CPU 单独访问 DDR 的最大读带宽（使用 Outstanding=4）
2. DMA 单独访问 NPU LMEM 的最大写带宽
3. 两者同时访问时的总带宽

### 练习 4: 错误路径分析

CPU 发出 `ARADDR = 0x1000_0000`（不在任何 Slave 范围内）：

1. Crossbar 地址解码的结果是什么？
2. 最终 CPU 会收到什么响应？
3. 这个过程中 axi2csr 会被触发吗？

### 练习 5: 端到端代码追踪

在 `tb/soc_tb.sv` 中找到 CPU 写 NPU CSR 的测试用例，
追踪以下信号在波形中的变化：
1. `cpu_axi_awvalid` / `cpu_axi_awaddr`
2. `xbar_mst3_awvalid` / `xbar_mst3_awaddr`
3. `npu_csr_wr_en` / `npu_csr_addr` / `npu_csr_wdata`
4. `cpu_axi_bvalid` / `cpu_axi_bresp`

---

## 11. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axi2csr.sv` | AXI4 到 CSR 桥接器（127 行） |
| `src/soc_top.sv` 行 710~756 | axi2csr 实例化 |
| `src/soc_top.sv` 行 491~677 | Crossbar 实例化（含完整地址映射） |
| `src/axi_crossbar/axicb_crossbar_top.sv` | Crossbar 顶层 |
| `src/axi_crossbar/axicb_pipeline.sv` | Pipeline 流水线切片 |
| `src/axi_crossbar/axicb_mst_if.sv` | Master 接口（含地址偏移逻辑） |
| `src/axi_crossbar/axicb_slv_if.sv` | Slave 接口（含 Outstanding 缓冲） |

---

## 12. 三讲回顾

```
Lecture 04: 顶层架构
  - Crossbar 拓扑（4x4）
  - 地址解码机制
  - ID Mask 原理
  - 端口命名约定

Lecture 05: 仲裁与 OOO
  - 优先级 Round-Robin 仲裁器
  - Mask 算法详解
  - 乱序完成管理（三阶段 FIFO）
  - Outstanding 事务跟踪

Lecture 06: CSR 桥与数据通路
  - axi2csr 协议转换
  - Pipeline 流水线切片
  - 端到端数据通路追踪
  - 并发通信与带宽分析
```

掌握这三讲内容，你就能完整理解本 FPGA SoC 项目中 AXI Crossbar 的
架构设计、仲裁策略、协议转换和数据流管理。
