# Lecture 14: DMA AXI接口 -- 五通道引擎与SVA断言

## 课程目标

本讲深入分析 `dma_axi_if.sv` 模块，这是 DMA 引擎与 AXI 总线之间的桥梁。
完成本讲后，你将掌握：

- AXI4 五通道（AR/R/AW/W/B）的独立状态机管理
- Outstanding 事务跟踪与流控机制
- 写数据通道的 FIFO 缓冲策略
- 读数据通道的 strobe 应用机制
- SVA 断言在 AXI 协议验证中的应用
- 错误检测与报告机制

---

## 1. 模块总览

### 1.1 在 DMA 架构中的位置

```
+------------------------------------------------------------------+
|                      DMA_FUNC_WRAPPER                              |
|                                                                   |
|  +----------+    +------------------+                             |
|  | DMA_FSM  |--->| DMA_STREAMER(RD)|----+                         |
|  |          |    +------------------+    |                         |
|  |          |                            |   +-----------------+  |
|  |          |    +------------------+    +-->|                 |  |
|  |          |--->| DMA_STREAMER(WR)|------->|  DMA_AXI_IF    |---> AXI Master
|  |          |    +------------------+    +-->|                 |  |
|  +----------+                            |   +-----------------+  |
|                                          |        |              |
|                                          v        v              |
|                                      DMA_FIFO (数据缓冲)          |
+------------------------------------------------------------------+
```

`dma_axi_if.sv` 是 DMA 引擎的**总线接口层**，负责：
1. 将 Streamer 产生的请求转换为标准 AXI4 协议信号
2. 管理五个 AXI 通道的握手逻辑
3. 跟踪 outstanding（进行中）事务数量
4. 缓冲写数据并应用读数据的 strobe 掩码
5. 检测和报告 AXI 错误（SLVERR/DECERR）

### 1.2 端口定义

**文件**: `src/dma/dma_axi_if.sv`，第 10-35 行

```systemverilog
module dma_axi_if
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;
#(
  parameter int DMA_ID_VAL = 0    // AXI Transaction ID
)(
  input                     clk,
  input                     rst,
  // From/To Streamers (读写流器接口)
  input   s_dma_axi_req_t   dma_axi_rd_req_i,    // 读请求
  output  s_dma_axi_resp_t  dma_axi_rd_resp_o,    // 读响应
  input   s_dma_axi_req_t   dma_axi_wr_req_i,     // 写请求
  output  s_dma_axi_resp_t  dma_axi_wr_resp_o,    // 写响应
  // Master AXI I/F (AXI 主接口)
  output  s_axi_mosi_t      dma_mosi_o,           // Master Out Slave In
  input   s_axi_miso_t      dma_miso_i,           // Master In Slave Out
  // From/To FIFOs interface (FIFO 接口)
  output  s_dma_fifo_req_t  dma_fifo_req_o,       // FIFO 读写请求
  input   s_dma_fifo_resp_t dma_fifo_resp_i,      // FIFO 响应
  // From/To DMA FSM (FSM 接口)
  output  logic             axi_pend_txn_o,       // 有待处理事务
  output  s_dma_error_t     axi_dma_err_o,        // 错误输出
  input                     clear_dma_i,          // 清除 DMA
  input                     dma_abort_i,          // 中止请求
  input                     dma_active_i          // DMA 激活
);
```

---

## 设计视角：为什么这样设计？

### 动机：为什么需要独立的 AXI 接口层？

DMA 引擎需要与外部总线通信，但 AXI4 协议非常复杂：
- 5 个独立通道，各有自己的握手规则
- Outstanding 事务需要精确跟踪
- 协议违规可能导致死锁或数据丢失

将 AXI 协议细节封装在独立模块中，让 Streamer 只需关注"发请求、等响应"。

### 为什么需要 19 个 SVA 断言？

```
AXI4 协议的核心规则 (ARM IHI 0022E):

  规则 1: valid 一旦拉高，在 ready 响应前不能撤销
  规则 2: valid 期间，所有控制/数据信号必须保持稳定
  规则 3: 不允许在 valid=0 时驱动 ready 依赖的信号

  违反规则 1 → 死锁风险 (slave 等 valid, master 等 ready)
  违反规则 2 → 数据错误 (地址/长度在传输中变化)
  违反规则 3 → 协议未定义行为

  每个通道需要检查:
    AR: arvalid 保持 + araddr/arlen/arsize/arburst 稳定 = 5 个
    AW: awvalid 保持 + awaddr/awlen/awsize/awburst 稳定 = 5 个
    W:  wvalid 保持 + wdata/wstrb/wlast 稳定 = 4 个
    B:  bvalid 保持 + bresp 稳定 = 2 个
    R:  rvalid 保持 + rdata/rlast 稳定 = 3 个
    总计 = 19 个断言
```

### 为什么分离 5 个通道的控制逻辑？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 统一 FSM 管理所有通道 | 状态集中 | 状态爆炸，5 通道组合 |
| **独立组合逻辑每通道** | **逻辑清晰，可独立验证** | **需要协调信号** |
| 每通道独立 FSM | 完全解耦 | 面积开销大 |

本设计采用"独立组合逻辑 + 共享寄存器"方案：每个通道的控制逻辑独立，
但通过 outstanding 计数器和共享信号协调。

### 设计约束总结

```
AXI IF 必须满足的约束:

  约束 1: AXI4 握手规则 (valid-before-ready)
  约束 2: Outstanding 上限 (DMA_RD_TXN_BUFF / DMA_WR_TXN_BUFF)
  约束 3: 写数据必须在写地址之后发送 (保守策略)
  约束 4: 错误必须可追溯到具体地址
  约束 5: 中止操作不能破坏进行中的事务
```

---

## 设计视角：如何从零开始设计？

### 步骤 1: 定义通道接口

```
  Streamer (内部)              AXI IF                  AXI Slave (外部)
  ────────────                 ──────                  ──────────────
  rd_req(addr,alen,strb) ───► AR 通道 ───────────────► arvalid/araddr/arlen
                              R 通道  ◄─────────────── rvalid/rdata/rlast
                              ───► rd_resp(ready)
  wr_req(addr,alen,strb) ───► AW 通道 ───────────────► awvalid/awaddr/awlen
                              W 通道  ──────────────── wvalid/wdata/wstrb/wlast
                              B 通道  ◄─────────────── bvalid/bresp
                              ───► wr_resp(ready)
```

### 步骤 2: 实现 Outstanding 跟踪

```
  核心思想: 用计数器跟踪"已发出但未完成"的事务数

  读通道:
    发出 AR 握手 → rd_counter++
    收到 R(last) → rd_counter--

  写通道:
    发出 AW 握手 → wr_counter++
    收到 B 响应  → wr_counter--

  流控:
    if (rd_counter >= BUFF_SIZE)
      阻塞新的 AR 请求 (arvalid = 0)
```

### 步骤 3: 处理 valid-before-ready 规则

```
  问题: Streamer 的 valid 可能只持续 1 个周期
        但 AXI 要求 valid 保持到 ready 到来

  解决: 用寄存器锁存握手状态

  aw_txn_started_ff:
    if (awvalid && !awready)
      aw_txn_started <= 1   // 锁存，保持 awvalid
    if (awvalid && awready)
      aw_txn_started <= 0   // 握手完成，释放
```

### 步骤 4: 添加 SVA 断言

```
  两个基础属性可覆盖所有断言:

  属性 1: valid_before_handshake(valid, ready)
    valid && !ready |-> ##1 valid
    含义: valid 拉高后必须保持到 ready 到来

  属性 2: stable_before_handshake(valid, ready, signal)
    valid && !ready |-> ##1 $stable(signal)
    含义: valid 期间信号不能变化

  对每个通道的每个信号实例化这两个属性即可
```

### 步骤 5: 错误追溯机制

```
  问题: AXI 错误响应 (SLVERR/DECERR) 在事务完成时才返回
        此时原始地址信息已不在总线上

  解决: 用 FIFO 保存每个事务的地址

  AR 握手时: 将 addr 存入 rd_error_fifo
  R(last)时: 从 fifo 取出 addr
             如果 rresp==SLVERR/DECERR → 报告错误地址
```

---

## 设计视角：架构模式与原则

### 模式 1: Outstanding 跟踪模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  Outstanding 跟踪是 AXI Master 设计的核心模式             │
  │                                                          │
  │  计数器操作:                                              │
  │    发出请求 (握手成功) → counter++                        │
  │    收到响应 (事务完成) → counter--                        │
  │                                                          │
  │  流控:                                                    │
  │    if (counter >= MAX_OUTSTANDING)                        │
  │      阻塞新请求                                           │
  │                                                          │
  │  适用场景:                                                │
  │    - AXI Master 接口                                      │
  │    - 网络包缓冲管理                                       │
  │    - 流水线深度控制                                       │
  │                                                          │
  │  关键: counter 位宽 = clog2(MAX_OUTSTANDING+1)            │
  │        溢出保护: counter != 0 时才允许 --                  │
  └──────────────────────────────────────────────────────────┘
```

### 模式 2: 协议合规断言模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  将协议规则转化为可重用的 SVA 属性                         │
  │                                                          │
  │  基础属性 (定义一次，多次实例化):                          │
  │                                                          │
  │  property valid_stable(valid, ready, signal);             │
  │    @(posedge clk) disable iff (rst)                      │
  │    valid && !ready |-> ##1 valid && $stable(signal);      │
  │  endproperty                                             │
  │                                                          │
  │  实例化 (对每个通道的每个信号):                            │
  │                                                          │
  │  a_arvalid: assert property(valid_stable(arvalid,         │
  │                              arready, araddr));           │
  │  a_awvalid: assert property(valid_stable(awvalid,         │
  │                              awready, awaddr));           │
  │  ...                                                     │
  │                                                          │
  │  优势: 19 个断言只需 2 个属性模板                         │
  └──────────────────────────────────────────────────────────┘
```

### 模式 3: 地址 FIFO 追溯模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  当需要在事务完成时回溯事务发起时的信息                    │
  │                                                          │
  │  发起时: 信息入队 (与握手同步)                             │
  │  完成时: 信息出队 (与响应同步)                             │
  │                                                          │
  │  AR 握手 ──→ addr 入 FIFO ──→ R(last) 时取出 addr         │
  │  AW 握手 ──→ addr 入 FIFO ──→ B 响应 时取出 addr          │
  │                                                          │
  │  FIFO 深度 = Outstanding 上限                             │
  │  FIFO 宽度 = 需要追溯的信息位宽                           │
  │                                                          │
  │  适用场景:                                                │
  │    - AXI 错误地址追溯                                     │
  │    - 乱序总线的事务匹配                                   │
  │    - 性能计数器 (延迟测量)                                │
  └──────────────────────────────────────────────────────────┘
```

---

## 2. AXI4 五通道概述

### 2.1 AXI4 通道架构

```
  Master (DMA)                          Slave (Memory/Peripheral)
  +--------+                            +--------+
  |        |--- AR (Read Address)  ---->|        |
  |        |<-- R  (Read Data)     -----|        |
  |        |                            |        |
  |        |--- AW (Write Address) ---->|        |
  |        |--- W  (Write Data)    ---->|        |
  |        |<-- B  (Write Response) ----|        |
  +--------+                            +--------+

每个通道独立握手:
  AR: arvalid / arready  (地址读)
  R:  rvalid  / rready   (数据读)
  AW: awvalid / awready  (地址写)
  W:  wvalid  / wready   (数据写)
  B:  bvalid  / bready   (写响应)
```

### 2.2 握手协议规则

```
AXI 握手基本规则:
1. Master 拉高 valid，等待 slave 拉高 ready
2. valid 一旦拉高，在 ready 拉高之前不能撤销
3. valid 拉高时，所有控制/数据信号必须保持稳定
4. 允许 valid 和 ready 在同一周期拉高（单周期握手）

时序示例:

  CLK    |  1  |  2  |  3  |  4  |  5  |
  -------+-----+-----+-----+-----+-----+
  valid  |  0  |  1  |  1  |  1  |  0  |
  ready  |  0  |  0  |  0  |  1  |  0  |
  data   |  X  | 0xAA| 0xAA| 0xAA|  X  |
         |     |     |     |     |     |
         |     | valid保持| 握手  |     |
         |     | 数据稳定 | 完成  |     |
```

---

## 3. Outstanding 事务跟踪

### 3.1 计数器机制

**文件**: `src/dma/dma_axi_if.sv`，第 36-37 行

```systemverilog
pend_rd_t     rd_counter_ff, next_rd_counter;  // 读 outstanding 计数器
pend_wr_t     wr_counter_ff, next_wr_counter;  // 写 outstanding 计数器
```

### 3.2 事件定义

**文件**: `src/dma/dma_axi_if.sv`，第 273-278 行

```systemverilog
// 四个关键握手事件
rd_txn_hpn  = dma_mosi_o.arvalid && dma_miso_i.arready;  // 读地址握手
rd_resp_hpn = dma_miso_i.rvalid && dma_miso_i.rlast &&
              dma_mosi_o.rready;                           // 读数据最后拍
wr_txn_hpn  = dma_mosi_o.awvalid && dma_miso_i.awready;  // 写地址握手
wr_resp_hpn = dma_miso_i.bvalid && dma_mosi_o.bready;    // 写响应握手
```

### 3.3 计数器更新逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 281-299 行

```systemverilog
if (dma_active_i) begin
  // 读通道: 发出地址 +1, 收到最后数据 -1
  if (rd_txn_hpn && !rd_resp_hpn) begin
    next_rd_counter = rd_counter_ff + 'd1;
  end else if (!rd_txn_hpn && rd_resp_hpn) begin
    next_rd_counter = (rd_counter_ff != '0) ? (rd_counter_ff - 'd1) : '0;
  end

  // 写通道: 发出地址 +1, 收到响应 -1
  if (wr_txn_hpn && !wr_resp_hpn) begin
    next_wr_counter = wr_counter_ff + 'd1;
  end else if (!wr_txn_hpn && wr_resp_hpn) begin
    next_wr_counter = (wr_counter_ff != '0) ? (wr_counter_ff - 'd1) : '0;
  end
end
```

### 3.4 Outstanding 计数器时序图

```
读通道 outstanding 跟踪:

  事件:     AR握手     R(last)握手    AR握手     R(last)握手
  时间:  ----|----------|------------|----------|----------->
            T1         T2           T3         T4

  counter: 0 -> 1      1 -> 0       0 -> 1     1 -> 0

  +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
  T0 T1 T2 T3 T4 T5 T6 T7 T8 T9 ...

  T1: AR握手 -> counter = 1 (一个读事务在进行中)
  T2: R(last)握手 -> counter = 0 (读事务完成)
  T3: AR握手 -> counter = 1
  T4: R(last)握手 -> counter = 0
```

**关键知识点**: 读通道的 outstanding 以 `rlast` 为标志减少计数，因为一个突发事务可能包含多个数据拍（beats），只有最后一个 beat 才算事务完成。写通道则以 B 通道响应为标志。

### 3.5 Pending 事务判断

**文件**: `src/dma/dma_axi_if.sv`，第 236-239 行

```systemverilog
axi_pend_txn_o = dma_active_i &&
             ((|rd_counter_ff) || (|wr_counter_ff) ||
              dma_axi_rd_req_i.valid || dma_axi_wr_req_i.valid ||
              dma_miso_i.rvalid || dma_miso_i.bvalid || aw_txn_started_ff);
```

这个信号告诉 DMA FSM：当前还有未完成的事务，不能进入 DONE 状态。

```
axi_pend_txn_o 为真的条件 (任一满足):
  +-- rd_counter != 0        (读通道有 outstanding)
  +-- wr_counter != 0        (写通道有 outstanding)
  +-- rd_req.valid           (Streamer 有待发的读请求)
  +-- wr_req.valid           (Streamer 有待发的写请求)
  +-- rvalid                 (Slave 正在发读数据)
  +-- bvalid                 (Slave 正在发写响应)
  +-- aw_txn_started_ff      (AW 通道握手未完成)
```

---

## 4. 读地址通道 (AR Channel)

### 4.1 AR 通道逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 372-383 行

```systemverilog
// Address Read Channel - AR*
dma_mosi_o.arprot = AXI_NONSECURE;                    // 非安全访问
dma_mosi_o.arid   = axi_tid_t'(DMA_ID_VAL);           // 事务 ID

dma_mosi_o.arvalid = (rd_counter_ff < `DMA_RD_TXN_BUFF) ?
                      dma_axi_rd_req_i.valid : 1'b0;   // 流控: 缓冲区满则阻塞

if (dma_mosi_o.arvalid) begin
  dma_axi_rd_resp_o.ready = dma_miso_i.arready;        // 传递 ready 给 Streamer
  dma_mosi_o.araddr  = dma_axi_rd_req_i.addr;           // 地址
  dma_mosi_o.arlen   = dma_axi_rd_req_i.alen;           // 突发长度
  dma_mosi_o.arsize  = dma_axi_rd_req_i.size;           // 每拍字节数
  dma_mosi_o.arburst = (dma_axi_rd_req_i.mode == DMA_MODE_INCR) ?
                        AXI_INCR : AXI_FIXED;           // 突发模式
end
```

### 4.2 AR 通道流控

```
AR 通道流控机制:

  Streamer                 AXI_IF                    Slave
     |                       |                         |
     |-- req(valid, addr) -->|                         |
     |                       |-- arvalid, araddr ----->|
     |                       |                         |
     |                       |  if (rd_counter < BUFF) |
     |                       |    传递 valid           |
     |                       |  else                   |
     |                       |    阻塞 (arvalid=0)     |
     |                       |                         |
     |<-- ready -------------|<-- arready -------------|
```

**关键知识点**: `DMA_RD_TXN_BUFF` 限制了同时进行的读事务数量（默认 8）。当 outstanding 计数器达到上限时，新的读请求会被阻塞，防止 AXI 从设备被过多事务淹没。

---

## 5. 读数据通道 (R Channel)

### 5.1 R 通道逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 385-393 行

```systemverilog
// Read Data Channel - R*
dma_mosi_o.rready = (~dma_fifo_resp_i.full || dma_abort_i);

if (dma_miso_i.rvalid && (~dma_fifo_resp_i.full || dma_abort_i)) begin
  dma_fifo_req_o.wr      = dma_abort_i ? 1'b0 : 1'b1;    // 中止时不写入 FIFO
  dma_fifo_req_o.data_wr = apply_strb(dma_miso_i.rdata, rd_txn_last_strb);

  if (dma_miso_i.rlast && dma_mosi_o.rready) begin
    rd_err_hpn = (dma_miso_i.rresp == AXI_SLVERR) ||
                 (dma_miso_i.rresp == AXI_DECERR);         // 检测错误响应
  end
end
```

### 5.2 Strobe 应用函数

**文件**: `src/dma/dma_axi_if.sv`，第 65-76 行

```systemverilog
function automatic axi_data_t apply_strb(axi_data_t data, axi_wr_strb_t mask);
  axi_data_t out_data;
  for (int i=0; i<$bits(axi_wr_strb_t); i++) begin
    if (mask[i] == 1'b1) begin
      out_data[(8*i)+:8] = data[(8*i)+:8];    // 保留该字节
    end
    else begin
      out_data[(8*i)+:8] = 8'd0;              // 清零该字节
    end
  end
  return out_data;
endfunction
```

### 5.3 读 Strobe FIFO

**文件**: `src/dma/dma_axi_if.sv`，第 104-120 行

```systemverilog
dma_fifo #(
  .SLOTS  (`DMA_RD_TXN_BUFF),
  .WIDTH  ($bits(axi_wr_strb_t))
) u_fifo_rd_strb (
  .clk    (clk),
  .rst    (rst),
  .write_i(rd_txn_hpn),              // AR 握手时存入 strobe
  .read_i (rd_resp_hpn),             // R(last) 握手时取出
  .data_i (dma_axi_rd_req_i.strb),
  .data_o (rd_txn_last_strb),        // 应用到最后一个 beat
  ...
);
```

```
Strobe FIFO 工作流程:

  AR 握手时: 存入该事务的 strobe 掩码
  R(last) 握手时: 取出 strobe 掩码，应用到数据上

  FIFO 内容示例 (3 个 outstanding 读事务):
  +--------+--------+--------+
  | strb_0 | strb_1 | strb_2 |  <- 按发出顺序存入
  +--------+--------+--------+
    ^                           <- 下一个取出
    read_ptr

  为什么需要这个 FIFO?
  - 读数据的 strobe 由 Streamer 在 AR 阶段计算
  - 但 strobe 需要在 R 阶段应用到数据上
  - 由于可能有多个 outstanding 事务，需要 FIFO 来匹配
```

**关键知识点**: 读通道的 strobe 用于处理非对齐传输。当读地址非对齐时，返回的数据中只有部分字节有效，strobe 掩码用于清除无效字节。

---

## 6. 写地址通道 (AW Channel)

### 6.1 AW 通道逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 395-415 行

```systemverilog
// Address Write Channel - AW*
dma_mosi_o.awprot = AXI_NONSECURE;
dma_mosi_o.awid   = axi_tid_t'(DMA_ID_VAL);

// AW 通道的 valid 条件:
// 1. outstanding 未满 (wr_counter < BUFF)
// 2. 有新请求 (valid) 或 之前的握手未完成 (aw_txn_started)
dma_mosi_o.awvalid = (wr_counter_ff < `DMA_WR_TXN_BUFF) ?
                      (dma_axi_wr_req_i.valid || aw_txn_started_ff) : 1'b0;

if (dma_mosi_o.awvalid) begin
  dma_axi_wr_resp_o.ready = dma_miso_i.awready;
  dma_mosi_o.awaddr  = dma_axi_wr_req_i.addr;
  dma_mosi_o.awlen   = dma_axi_wr_req_i.alen;
  dma_mosi_o.awsize  = dma_axi_wr_req_i.size;
  dma_mosi_o.awburst = (dma_axi_wr_req_i.mode == DMA_MODE_INCR) ?
                        AXI_INCR : AXI_FIXED;
  next_aw_txn = ~dma_miso_i.awready;  // 未握手则保持
end
```

### 6.2 aw_txn_started 信号

```systemverilog
// 第 414 行
next_aw_txn = ~dma_miso_i.awready;
```

这个寄存器的作用是确保 AXI 的 valid-before-ready 规则：

```
时序示例:

  CLK   |  1  |  2  |  3  |  4  |
  ------+-----+-----+-----+-----+
  awvalid|  0  |  1  |  1  |  0  |
  awready|  0  |  0  |  1  |  0  |
  aw_txn |  0  |  1  |  0  |  0  |
        |     |     |     |     |
  T2: awvalid=1, awready=0 -> aw_txn_started=1 (保持 awvalid)
  T3: awvalid=1, awready=1 -> 握手完成, aw_txn_started=0
```

**关键知识点**: 如果没有 `aw_txn_started`，当 Streamer 的 valid 信号在一个周期后撤销时，AW 通道的 valid 也会撤销，违反 AXI 协议。这个寄存器确保 valid 一旦拉高就保持到握手完成。

---

## 7. 写数据通道 (W Channel)

### 7.1 写请求 FIFO

**文件**: `src/dma/dma_axi_if.sv`，第 82-98 行

```systemverilog
dma_fifo #(
  .SLOTS  (`DMA_WR_TXN_BUFF),
  .WIDTH  ($bits(s_wr_req_t))
) u_fifo_wr_data (
  .clk    (clk),
  .rst    (rst),
  .write_i(wr_new_txn),          // AW 握手时存入
  .read_i (wr_data_txn_hpn),     // W(last) 握手时取出
  .data_i (wr_data_req_in),
  .data_o (wr_data_req_out),
  ...
);
```

`s_wr_req_t` 结构体包含：
```systemverilog
typedef struct packed {
  axi_alen_t    alen;    // 突发长度 (用于生成 wlast)
  axi_wr_strb_t wstrb;   // 字节使能掩码
} s_wr_req_t;
```

### 7.2 写请求入队

**文件**: `src/dma/dma_axi_if.sv`，第 352-359 行

```systemverilog
always_comb begin
  wr_new_txn = 1'b0;
  if (dma_axi_wr_req_i.valid && dma_axi_wr_resp_o.ready) begin
    wr_new_txn = 1'b1;                        // AW 握手成功，入队
    wr_data_req_in.alen  = dma_axi_wr_req_i.alen;
    wr_data_req_in.wstrb = dma_axi_wr_req_i.strb;
  end
end
```

### 7.3 W 通道逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 417-425 行

```systemverilog
// Write Data Channel - W*
if (~wr_data_req_empty && (~dma_fifo_resp_i.empty || dma_abort_i)) begin
  dma_fifo_req_o.rd = dma_abort_i ? 1'b0 : dma_miso_i.wready;
  dma_mosi_o.wdata  = dma_fifo_resp_i.data_rd;           // 从数据 FIFO 读取
  dma_mosi_o.wstrb  = wr_data_req_out.wstrb;              // 从请求 FIFO 读取
  dma_mosi_o.wlast  = (beat_counter_ff == wr_data_req_out.alen);  // 最后一拍
  dma_mosi_o.wvalid = 1'b1;
end
```

### 7.4 Beat 计数器

**文件**: `src/dma/dma_axi_if.sv`，第 337-348 行

```systemverilog
wr_beat_hpn = dma_mosi_o.wvalid && dma_miso_i.wready;
next_beat_count = beat_counter_ff;

// 每个 beat 握手成功时递增
if (wr_beat_hpn) begin
  next_beat_count = beat_counter_ff + 'd1;
end

// 最后一个 beat 完成时清零
if (wr_data_txn_hpn) begin  // wvalid && wlast && wready
  next_beat_count = axi_alen_t'('0);
end
```

### 7.5 写数据通路完整流程

```
写数据通路时序 (2-beat 突发):

  阶段 1: AW 通道握手
  CLK   |  1  |  2  |  3  |  4  |  5  |  6  |  7  |  8  |
  ------+-----+-----+-----+-----+-----+-----+-----+-----+
  awvalid|  0  |  1  |  0  |  0  |  0  |  0  |  0  |  0  |
  awready|  0  |  1  |  0  |  0  |  0  |  0  |  0  |  0  |
  awaddr |  X  |0x100|  X  |  X  |  X  |  X  |  X  |  X  |
  awlen  |  X  |  1  |  X  |  X  |  X  |  X  |  X  |  X  |
        |     |     |     |     |     |     |     |     |
  阶段 2: W 通道数据传输
  wvalid |  0  |  0  |  1  |  1  |  0  |  0  |  0  |  0  |
  wready |  0  |  0  |  1  |  1  |  0  |  0  |  0  |  0  |
  wdata  |  X  |  X  | D0  | D1  |  X  |  X  |  X  |  X  |
  wlast  |  X  |  X  |  0  |  1  |  X  |  X  |  X  |  X  |
  beat   |  0  |  0  |  0  |  1  |  0  |  0  |  0  |  0  |
        |     |     |     |     |     |     |     |     |
  阶段 3: B 通道响应
  bvalid |  0  |  0  |  0  |  0  |  0  |  1  |  0  |  0  |
  bready |  0  |  0  |  0  |  0  |  0  |  1  |  0  |  0  |
  bresp  |  X  |  X  |  X  |  X  |  X  | OKAY|  X  |  X  |
```

**关键知识点**: AW 和 W 通道可以同时发出（AXI4 允许），这可以打破死锁依赖（AXI4 Spec A3.3）。但在本设计中，W 通道依赖 AW 握手后才开始发送数据，这是更保守但更安全的策略。

---

## 8. 写响应通道 (B Channel)

### 8.1 B 通道逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 427-431 行

```systemverilog
// Write Response Channel - B*
dma_mosi_o.bready = 1'b1;                     // 始终准备接收响应
if (dma_miso_i.bvalid) begin
  wr_err_hpn = (dma_miso_i.bresp == AXI_SLVERR) ||
               (dma_miso_i.bresp == AXI_DECERR);  // 检测错误
end
```

**关键知识点**: `bready` 始终为 1，这意味着 DMA 主设备永远不会反压写响应通道。这是合理的，因为写响应只包含少量信息（resp 信号），不涉及大量数据传输。

---

## 9. 错误检测与报告

### 9.1 错误捕获逻辑

**文件**: `src/dma/dma_axi_if.sv`，第 246-267 行

```systemverilog
if (~dma_active_i) begin
  next_err_lock = 1'b0;
end
else begin
  next_err_lock = rd_err_hpn || wr_err_hpn;  // 锁定错误状态
end

if (~err_lock_ff) begin
  if (rd_err_hpn) begin
    next_dma_error.valid    = 1'b1;
    next_dma_error.type_err = DMA_ERR_OPE;      // 操作错误
    next_dma_error.src      = DMA_ERR_RD;       // 来自读通道
    next_dma_error.addr     = rd_txn_addr;       // 错误地址
  end
  else if (wr_err_hpn) begin
    next_dma_error.valid    = 1'b1;
    next_dma_error.type_err = DMA_ERR_OPE;
    next_dma_error.src      = DMA_ERR_WR;       // 来自写通道
    next_dma_error.addr     = wr_txn_addr;
  end
end
```

### 9.2 错误地址 FIFO

**文件**: `src/dma/dma_axi_if.sv`，第 126-160 行

```systemverilog
// 读错误地址 FIFO
dma_fifo #(
  .SLOTS  (`DMA_RD_TXN_BUFF),
  .WIDTH  (`DMA_ADDR_WIDTH)
) u_fifo_rd_error (
  .write_i(rd_txn_hpn),      // AR 握手时存入地址
  .read_i (rd_resp_hpn),     // R(last) 握手时取出
  .data_i (dma_axi_rd_req_i.addr),
  .data_o (rd_txn_addr),     // 错误发生时可追溯地址
  ...
);

// 写错误地址 FIFO (类似)
dma_fifo #(
  .SLOTS  (`DMA_WR_TXN_BUFF),
  .WIDTH  (`DMA_ADDR_WIDTH)
) u_fifo_wr_error (
  .write_i(wr_txn_hpn),
  .read_i (wr_resp_hpn),
  .data_i (dma_axi_wr_req_i.addr),
  .data_o (wr_txn_addr),
  ...
);
```

### 9.3 错误处理流程

```
错误检测与报告流程:

  1. AXI Slave 返回 SLVERR 或 DECERR
     |
     v
  2. err_hpn 信号拉高
     |
     v
  3. 从错误地址 FIFO 取出对应地址
     |
     v
  4. 构造 s_dma_error_t 结构体
     |
     v
  5. err_lock_ff 锁定，防止后续错误覆盖
     |
     v
  6. DMA FSM 读取错误信息并报告

错误结构体:
  +------------------+
  | valid (1-bit)    |  -> 错误有效标志
  | type_err (1-bit) |  -> DMA_ERR_CFG 或 DMA_ERR_OPE
  | src (1-bit)      |  -> DMA_ERR_RD 或 DMA_ERR_WR
  | addr (32-bit)    |  -> 发生错误的地址
  +------------------+
```

---

## 10. SVA 断言详解

### 10.1 AXI4 协议验证断言

**文件**: `src/dma/dma_axi_if.sv`，第 456-514 行

本模块使用 SystemVerilog Assertions (SVA) 来验证 AXI4 协议合规性。这些断言在仿真时自动检查，如果违反协议会报告错误。

### 10.2 两个核心属性

```systemverilog
// 属性 1: valid 必须保持到握手完成
property valid_before_handshake(valid, ready);
   valid && !ready |-> ##1 valid;
endproperty

// 属性 2: valid 期间控制/数据信号必须稳定
property stable_before_handshake(valid, ready, control);
  valid && !ready |-> ##1 $stable(control);
endproperty
```

```
属性 1 图示:

  CLK   |  1  |  2  |  3  |  4  |
  ------+-----+-----+-----+-----+
  valid |  1  |  1  |  1  |  0  |   <-- 必须保持到 ready
  ready |  0  |  0  |  1  |  0  |
        |     |     |     |     |
  如果 T2 valid=0 (ready 还没来), 断言失败!

属性 2 图示:

  CLK   |  1  |  2  |  3  |  4  |
  ------+-----+-----+-----+-----+
  valid |  1  |  1  |  1  |  0  |
  ready |  0  |  0  |  1  |  0  |
  addr  |0xAA|0xBB|0xBB|  X  |   <-- T2 addr 变化了! 断言失败!
        |     | ^   |     |     |
        |     | 错误!|     |     |
```

### 10.3 AR 通道断言 (5 个)

```systemverilog
// ARVALID 必须保持到 ARREADY
axi4_arvalid_arready : assert property(
  disable iff (rst)
  valid_before_handshake(dma_mosi_o.arvalid, dma_miso_i.arready)
) else $error("Violation AXI4: Once ARVALID is asserted it must remain asserted...");

// ARADDR 必须稳定
axi4_arvalid_araddr : assert property(
  disable iff (rst)
  stable_before_handshake(dma_mosi_o.arvalid, dma_miso_i.arready, dma_mosi_o.araddr)
) else $error("Violation AXI4: ...ADDR... must remain stable...");

// ARLEN 必须稳定
axi4_arvalid_arlen : assert property(...);

// ARSIZE 必须稳定
axi4_arvalid_arsize : assert property(...);

// ARBURST 必须稳定
axi4_arvalid_arburst : assert property(...);
```

### 10.4 完整断言列表

| 通道 | 断言名 | 检查内容 |
|------|--------|---------|
| AR | `axi4_arvalid_arready` | ARVALID 保持 |
| AR | `axi4_arvalid_araddr` | ARADDR 稳定 |
| AR | `axi4_arvalid_arlen` | ARLEN 稳定 |
| AR | `axi4_arvalid_arsize` | ARSIZE 稳定 |
| AR | `axi4_arvalid_arburst` | ARBURST 稳定 |
| AW | `axi4_awvalid_awready` | AWVALID 保持 |
| AW | `axi4_awvalid_awaddr` | AWADDR 稳定 |
| AW | `axi4_awvalid_awlen` | AWLEN 稳定 |
| AW | `axi4_awvalid_awsize` | AWSIZE 稳定 |
| AW | `axi4_awvalid_awburst` | AWBURST 稳定 |
| W | `axi4_wvalid_wready` | WVALID 保持 |
| W | `axi4_wvalid_wdata` | WDATA 稳定 |
| W | `axi4_wvalid_wstrb` | WSTRB 稳定 |
| W | `axi4_wvalid_wlast` | WLAST 稳定 |
| B | `axi4_bvalid_bready` | BVALID 保持 |
| B | `axi4_bvalid_bresp` | BRESP 稳定 |
| R | `axi4_rvalid_rready` | RVALID 保持 |
| R | `axi4_rvalid_rdata` | RDATA 稳定 |
| R | `axi4_rvalid_rlast` | RLAST 稳定 |

**共 19 个断言，覆盖 AXI4 协议的全部五个通道。**

### 10.5 条件编译

```systemverilog
`ifndef NO_ASSERTIONS
  `ifndef VERILATOR
    // 所有断言在这里
  `endif
`endif
```

**关键知识点**: 断言通过 `NO_ASSERTIONS` 宏可以全局禁用，通过 `VERILATOR` 宏排除 Verilator 仿真器（因为 Verilator 不完全支持 SVA）。在 VCS、Questa 等商业仿真器中，这些断言会自动生效。

---

## 11. DMA 活跃状态与清理

### 11.1 DMA 非活跃时的行为

**文件**: `src/dma/dma_axi_if.sv`，第 246-248 行

```systemverilog
if (~dma_active_i) begin
  next_err_lock = 1'b0;    // 清除错误锁定
end
```

以及第 296-298 行：
```systemverilog
end else begin
  next_rd_counter = '0;    // 清零 outstanding 计数器
  next_wr_counter = '0;
end
```

### 11.2 清除 DMA

**文件**: `src/dma/dma_axi_if.sv`，第 268-271 行

```systemverilog
if (clear_dma_i) begin
  next_dma_error = s_dma_error_t'('0);  // 清除错误状态
  next_wr_lock   = 1'b0;               // 清除写锁定
end
```

---

## 12. 内部 FIFO 总结

### 12.1 四个内部 FIFO

```
dma_axi_if 内部 FIFO 架构:

  +-------------------------------------------+
  |                DMA_AXI_IF                  |
  |                                            |
  |  +-------------+    +-------------+        |
  |  | u_fifo_wr   |    | u_fifo_rd   |        |
  |  | _data       |    | _strb       |        |
  |  | (alen+strb) |    | (strb mask) |        |
  |  | SLOTS=8     |    | SLOTS=8     |        |
  |  +-------------+    +-------------+        |
  |        ^                  ^                 |
  |        | AW握手           | AR握手          |
  |        | 入队             | 入队            |
  |        |                  |                 |
  |        v                  v                 |
  |  W(last)出队        R(last)出队            |
  |                                            |
  |  +-------------+    +-------------+        |
  |  | u_fifo_wr   |    | u_fifo_rd   |        |
  |  | _error      |    | _error      |        |
  |  | (addr)      |    | (addr)      |        |
  |  | SLOTS=8     |    | SLOTS=8     |        |
  |  +-------------+    +-------------+        |
  |        ^                  ^                 |
  |        | AW握手           | AR握手          |
  |        | 入队             | 入队            |
  |        v                  v                 |
  |  B响应出队         R(last)出队              |
  +-------------------------------------------+
```

| FIFO | 用途 | 入队时机 | 出队时机 | 宽度 |
|------|------|---------|---------|------|
| `u_fifo_wr_data` | 写事务参数 | AW 握手 | W(last) 握手 | alen + strb |
| `u_fifo_rd_strb` | 读 strobe 掩码 | AR 握手 | R(last) 握手 | strb |
| `u_fifo_rd_error` | 读错误地址 | AR 握手 | R(last) 握手 | addr |
| `u_fifo_wr_error` | 写错误地址 | AW 握手 | B 握手 | addr |

---

## 13. 关键知识点总结

### 13.1 设计模式

| 模式 | 实现 | 说明 |
|------|------|------|
| 流控 | outstanding 计数器 | 防止从设备过载 |
| 缓冲 | 内部 FIFO | 解耦 AW 和 W 通道 |
| 错误追溯 | 地址 FIFO | 精确定位错误地址 |
| 协议合规 | SVA 断言 | 19 个断言覆盖全通道 |
| 中止处理 | abort 旁路 | 中止时忽略数据 FIFO |

### 13.2 性能与面积权衡

- `DMA_RD_TXN_BUFF` / `DMA_WR_TXN_BUFF` 越大，允许的 outstanding 越多，吞吐量越高，但面积越大
- 默认值 8 是一个平衡点，适合大多数应用场景
- 写数据 FIFO 深度影响写操作的流水线程度

---

## 14. 动手实验

### 实验 1: Outstanding 计数器追踪

给定以下时序，计算 `rd_counter_ff` 的值：

```
时间 | 事件
-----|-----
T0   | 初始化 (counter=0)
T1   | AR 握手
T2   | AR 握手
T3   | R(last) 握手
T4   | AR 握手
T5   | R(last) 握手
T6   | R(last) 握手
```

### 实验 2: SVA 断言分析

以下时序是否会触发断言？如果会，是哪个断言？

```
CLK   |  1  |  2  |  3  |  4  |
------+-----+-----+-----+-----+
arvalid|  0  |  1  |  0  |  0  |
arready|  0  |  0  |  1  |  0  |
araddr |  X  |0x100|0x200|  X  |
```

### 实验 3: FIFO 深度计算

如果 `DMA_WR_TXN_BUFF=4`，`DMA_DATA_WIDTH=32`，最多可以缓冲多少字节的写数据？
（提示: 每个写事务可以包含多个 beats）

### 实验 4: 代码分析

分析 `dma_axi_if.sv` 第 417 行的条件：
```systemverilog
if (~wr_data_req_empty && (~dma_fifo_resp_i.empty || dma_abort_i)) begin
```
为什么 W 通道需要同时检查两个 FIFO 的状态？如果只检查一个会怎样？

### 实验 5: 添加新断言

尝试为 `dma_axi_if.sv` 添加以下 SVA 断言：

1. 检查 `wlast` 在突发的最后一拍必须为 1
2. 检查 `bready` 始终为 1
3. 检查 outstanding 计数器不会超过 `DMA_RD_TXN_BUFF`

---

## 15. 常见问题

**Q1: 为什么读通道用 `rlast` 而写通道用 B 响应来减少 outstanding 计数？**

A: 读通道的数据传输由从设备控制，`rlast` 标志着数据传输完成。写通道的数据传输由主设备控制，B 响应才是从设备确认写入完成的标志。

**Q2: `aw_txn_started_ff` 和 `wr_lock_ff` 有什么区别？**

A: `aw_txn_started_ff` 用于保持 AW 通道的 valid 信号直到握手完成（AXI 协议要求）。`wr_lock_ff` 用于防止写操作在错误发生后继续进行。

**Q3: 为什么 B 通道的 `bready` 始终为 1？**

A: 写响应只包含一个 resp 信号，没有大量数据。不反压 B 通道可以简化设计，避免死锁风险。如果反压 B 通道，从设备可能会阻塞 W 通道，导致复杂的依赖关系。

**Q4: SVA 断言在综合时会怎样？**

A: SVA 断言只在仿真时生效，综合时会被忽略（通过 `ifndef NO_ASSERTIONS` 条件编译）。它们不会消耗任何硬件资源。

---

## 下一讲预告

[Lecture 15: DMA FIFO与完整数据通路](lecture_15_dma_fifo_datapath.md)

我们将分析 `dma_fifo.sv` 的同步 FIFO 设计，`dma_func_wrapper.sv` 的集成架构，以及完整的 DMA 工作流程和性能分析。
