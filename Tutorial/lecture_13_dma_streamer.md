# Lecture 13: DMA Streamer -- 读写突发引擎

## 课程目标

本讲深入分析 `dma_streamer.sv` 模块，这是 DMA 引擎的核心突发计算单元。
完成本讲后，你将掌握：

- DMA Streamer 的状态机与工作流程
- AXI 突发拆分（burst splitting）的完整逻辑
- 地址递增策略（INCR vs FIXED）
- 字节使能（byte enable / strobe）的生成算法
- 4KB 边界检测与规避机制
- 非对齐传输的处理方法

---

## 1. 模块总览

### 1.1 在 DMA 架构中的位置

```
+----------------------------------------------------------+
|                     DMA_FUNC_WRAPPER                       |
|                                                           |
|  +----------+    +------------------+    +-------------+  |
|  | DMA_FSM  |--->| DMA_STREAMER(RD)|--->|             |  |
|  |          |    +------------------+    |             |  |
|  | 控制/状态|                            | DMA_AXI_IF  |---> AXI Master
|  |          |    +------------------+    |             |  |
|  |          |--->| DMA_STREAMER(WR)|--->|             |  |
|  +----------+    +------------------+    +-------------+  |
|                       |                     |             |
|                       v                     v             |
|                  DMA_DESC (CSRs)      DMA_FIFO (数据)     |
+----------------------------------------------------------+
```

`dma_streamer.sv` 是一个**参数化模块**，通过 `STREAM_TYPE` 参数实例化两次：
- `STREAM_TYPE=0`：读流器（Read Streamer），从源地址读取数据
- `STREAM_TYPE=1`：写流器（Write Streamer），向目标地址写入数据

### 1.2 端口定义

**文件**: `src/dma/dma_streamer.sv`，第 10-28 行

```systemverilog
module dma_streamer
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;
#(
  parameter bit STREAM_TYPE = 0 // 0 - Read, 1 - Write
) (
  input                                     clk,           // 时钟
  input                                     rst,           // 复位
  // From/To CSRs
  input   s_dma_desc_t [`DMA_NUM_DESC-1:0]  dma_desc_i,    // DMA 描述符数组
  input                                     dma_abort_i,   // 中止请求
  input   maxb_t                            dma_maxb_i,    // 最大突发长度配置
  // From/To AXI I/F
  output  s_dma_axi_req_t                   dma_axi_req_o, // AXI 请求输出
  input   s_dma_axi_resp_t                  dma_axi_resp_i,// AXI 响应输入
  // To/From DMA FSM
  input   s_dma_str_in_t                    dma_stream_i,  // FSM 控制输入
  output  s_dma_str_out_t                   dma_stream_o   // FSM 状态输出
);
```

**关键知识点**: Streamer 位于 FSM 和 AXI 接口之间，负责将一个完整的 DMA 描述符（可能包含数千字节）拆分为多个符合 AXI 协议的突发事务。

---

## 设计视角：为什么这样设计？

### 动机：为什么需要突发拆分？

DMA 传输的字节数可能远超 AXI 协议的单次突发限制。一个描述符可能要求传输
4KB、64KB 甚至更多数据，但 AXI4 协议规定：
- 单次突发最多 256 beats（AxLEN 最大 255）
- 突发不能跨越 4KB 地址边界

因此，Streamer 的核心职责就是将"大传输"拆分为多个"合规小突发"。

### 为什么需要 4KB 边界检测？

```
AXI4 协议 4KB 边界规则 (Section A3.4.1):

  +------------------+
  |   4KB Page N     |
  |                  |
  |  addr=0x0FFE ──► |── 突发开始
  |  .................|── 4KB 边界 (0x1000)
  |   4KB Page N+1   |
  |                  |
  +------------------+

  如果突发跨越 4KB 边界:
    - 某些从设备可能在边界处有独立的地址解码
    - 突发可能被路由到两个不同的从设备
    - 导致未定义行为或总线错误

  因此: 每个突发必须严格限制在单个 4KB 页内
```

### 为什么需要突发拆分而不是直接传输？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 单拍逐个传输 | 最简单 | 效率极低，每个 beat 都需要地址握手 |
| 不拆分直接发大突发 | 高效 | 违反 4KB 边界和 max_burst 限制 |
| **智能拆分（本设计）** | **兼顾效率和合规** | **需要额外的计算逻辑** |

### 设计约束总结

```
Streamer 必须同时满足以下约束:

  约束 1: AxLEN <= dma_maxb_i      (软件配置上限)
  约束 2: AxLEN <= DMA_MAX_BEAT_BURST (硬件上限, 255)
  约束 3: 突发不跨越 4KB 边界       (AXI 协议要求)
  约束 4: 最后一拍的字节数 <= 剩余字节 (不能多传)

  最终 AxLEN = min(约束1, 约束2, 约束3, 约束4) - 1
```

---

## 设计视角：如何从零开始设计？

### 步骤 1: 定义输入输出接口

从功能需求出发，Streamer 需要：
- 输入：描述符（源地址、字节数、突发模式）
- 输出：AXI 请求（地址、长度、strobe）

```
  DMA FSM                    Streamer                   AXI IF
  ────────                   ────────                   ──────
  valid, idx ──────────────► 解析描述符
  dma_desc[] ──────────────► 获取 addr, bytes, mode
                              │
                              ▼
                           计算突发参数 ──────────────► req(addr, alen, strb)
                              │                         │
                              ▼                         ▼
                           地址递增 ◄──────────────── ready 握手
                           字节递减
                              │
                              ▼
                           bytes==0 ──────────────────► done
```

### 步骤 2: 设计状态机

最简单的两态 FSM 足以覆盖所有场景：

```
  IDLE ◄──────────────────── 传输完成 (bytes==0)
   │                              ^
   │ valid                        │ bytes > 0
   ▼                              │
  RUN ───────────────────────────►│
   │                              │
   │ abort && !last_txn_proc      │
   └──────────────────────────────┘
```

### 步骤 3: 实现核心计算函数 great_alen

```
  输入: addr, bytes, maxb_cfg, data_width
  输出: axi_alen

  算法伪代码:
    max_beats = min(hw_limit, sw_limit)
    max_beats = min(max_beats, bytes / bytes_per_beat)
    max_beats = min(max_beats, beats_to_4KB_boundary(addr))
    return max_beats - 1
```

### 步骤 4: 处理非对齐地址

当起始地址未对齐到数据总线宽度时：
1. 先发一个单拍事务对齐地址
2. 计算需要多少字节才能对齐
3. 生成对应的 strobe 掩码

```
  addr=0x1002, DATA_WIDTH=32:
    bytes_to_align = 4 - 2 = 2
    第一个事务: addr=0x1000, strb=0b1100, len=0
    之后地址变为 0x1004 (已对齐)
    后续可以发完整突发
```

### 步骤 5: 集成地址递增和完成判断

```
  每个突发发出后:
    if (mode == INCR)
      desc_addr += txn_bytes
    desc_bytes -= txn_bytes
    if (desc_bytes == 0)
      last_txn = 1  // 标记最后一个事务
```

---

## 设计视角：架构模式与原则

### 模式 1: 约束叠加计算模式

多个独立约束取最小值，是硬件设计中的常见模式。

```
  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
  │ 硬件上限    │   │ 软件配置    │   │ 剩余字节    │   │ 4KB 边界    │
  │ 256 beats   │   │ maxb+1      │   │ bytes/bw    │   │ to_page/bw  │
  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘
         │                 │                 │                 │
         └────────┬────────┴────────┬────────┘                 │
                  │                 │                          │
                  ▼                 ▼                          │
              min(sw, hw)      min(remaining)                  │
                  │                 │                          │
                  └────────┬────────┘                          │
                           │                                   │
                           ▼                                   │
                    min(prev, bytes)                           │
                           │                                   │
                           └────────┬──────────────────────────┘
                                    │
                                    ▼
                              min(全部约束)
                                    │
                                    ▼
                               axi_alen
```

**应用场景**: 任何需要同时满足多个独立约束的硬件计算，如仲裁器的
带宽分配、缓存的替换策略等。

### 模式 2: 地址自增模式

```
  地址自增模式适用于:
    - DMA 传输（连续内存访问）
    - 串行外设访问（FIFO 地址固定）
    - 缓存行填充（连续地址突发）

  设计要点:
    ┌──────────────────────────────────────────────────┐
    │  addr_reg                                        │
    │  ┌──────────────────────────────────────────┐    │
    │  │  if (mode == INCR)                       │    │
    │  │    next_addr = addr + burst_bytes        │    │
    │  │  else  // FIXED                          │    │
    │  │    next_addr = addr  (保持不变)           │    │
    │  └──────────────────────────────────────────┘    │
    │                                                  │
    │  关键: 地址更新发生在突发被 AXI 接受之后          │
    │        (valid && ready 握手完成)                  │
    └──────────────────────────────────────────────────┘
```

### 模式 3: 安全中止模式

```
  中止操作必须保证 AXI 事务的原子性:

  规则: 已发出的 AXI 请求不能中途撤销

  ┌─────────────────────────────────────────────────────────────┐
  │  if (abort)                                                 │
  │    if (req.valid && !ready)                                 │
  │      last_txn_proc = 1  // 正在等握手，不能中断              │
  │    else                                                     │
  │      清除请求，返回 IDLE                                     │
  │                                                             │
  │  状态机转换条件中加入 last_txn_proc 保护:                    │
  │    IDLE ← RUN: 仅当 !last_txn_proc 时允许中止               │
  └─────────────────────────────────────────────────────────────┘

  这个模式广泛应用于:
    - DMA 中止
    - AXI 事务取消
    - 流水线冲刷 (pipeline flush)
```

---

## 2. 状态机详解

### 2.1 两态 FSM

**文件**: `src/dma/dma_streamer.sv`，第 218-246 行

```
         dma_stream_i.valid
  +-------+        +---------+
  | IDLE  |------->|  RUN    |
  +-------+        +---------+
    ^                   |
    |   desc_bytes==0   |
    +-------------------+
    |   dma_abort &&    |
    |   !last_txn_proc  |
    +-------------------+
```

```systemverilog
// 第 220-246 行
always_comb begin : streamer_dma_ctrl
  next_st = DMA_ST_SM_IDLE;
  case (cur_st_ff)
    DMA_ST_SM_IDLE: begin
      if (dma_stream_i.valid) begin
        next_st = DMA_ST_SM_RUN;    // FSM 发出有效信号，启动传输
      end
    end
    DMA_ST_SM_RUN: begin
      if (dma_abort_i) begin
        if (last_txn_proc) begin
          next_st = DMA_ST_SM_RUN;  // 正在处理最后一个事务，不能中断
        end
        else begin
          next_st = DMA_ST_SM_IDLE; // 中止并返回空闲
        end
      end
      else begin
        if (desc_bytes_ff > 0) begin
          next_st = DMA_ST_SM_RUN;  // 还有字节要传输
        end
        else if (last_txn_ff && ~dma_axi_resp_i.ready) begin
          next_st = DMA_ST_SM_RUN;  // 最后事务已发出，等待 AXI 确认
        end
      end
    end
  endcase
end
```

### 2.2 状态转换条件总结

| 当前状态 | 条件 | 下一状态 | 说明 |
|---------|------|---------|------|
| IDLE | `dma_stream_i.valid` | RUN | FSM 启动传输 |
| RUN | `desc_bytes_ff > 0` | RUN | 还有剩余字节 |
| RUN | `last_txn_ff && !ready` | RUN | 等待 AXI 响应 |
| RUN | `dma_abort_i && !last_txn_proc` | IDLE | 中止传输 |
| RUN | `desc_bytes==0 && (!last_txn \|\| ready)` | IDLE | 传输完成 |

**关键知识点**: `last_txn_proc` 信号确保正在发送的最后一个突发事务不会被中途打断，这是 AXI 协议合规性的要求。

---

## 3. 描述符初始化

### 3.1 从 IDLE 到 RUN 的过渡

**文件**: `src/dma/dma_streamer.sv`，第 261-279 行

```systemverilog
// 第 261-279 行
if ((cur_st_ff == DMA_ST_SM_IDLE) && (next_st == DMA_ST_SM_RUN)) begin
  next_desc_bytes = dma_desc_i[dma_stream_i.idx].num_bytes;

  if (STREAM_TYPE) begin  // 写流器
    next_desc_addr = dma_desc_i[dma_stream_i.idx].dst_addr;
    next_dma_mode  = dma_desc_i[dma_stream_i.idx].wr_mode;
  end
  else begin              // 读流器
    next_desc_addr = dma_desc_i[dma_stream_i.idx].src_addr;
    next_dma_mode  = dma_desc_i[dma_stream_i.idx].rd_mode;
  end
end
```

**关键知识点**: 读流器使用 `src_addr` + `rd_mode`，写流器使用 `dst_addr` + `wr_mode`。这意味着源和目标可以使用不同的突发模式。

### 3.2 描述符数据结构

参考 `src/dma/inc/dma_pkg.svh`：

```systemverilog
typedef struct packed {
  desc_addr_t src_addr;   // 源地址 (32-bit)
  desc_addr_t dst_addr;   // 目标地址 (32-bit)
  desc_num_t  num_bytes;  // 传输字节数 (32-bit)
  dma_mode_t  wr_mode;    // 写模式: INCR 或 FIXED
  dma_mode_t  rd_mode;    // 读模式: INCR 或 FIXED
  logic       enable;     // 描述符使能
} s_dma_desc_t;
```

---

## 4. 突发计算核心逻辑

### 4.1 请求发送条件

**文件**: `src/dma/dma_streamer.sv`，第 290 行

```systemverilog
if ((~dma_req_ff.valid || (dma_req_ff.valid && dma_axi_resp_i.ready)) && ~last_txn_ff) begin
```

这个条件的含义是：
1. 当前没有有效的请求（首次发送），**或者**
2. 当前请求已被 AXI 接口接受（`valid && ready` 握手完成）
3. **并且**这不是最后一个事务

```
时序图：请求发送流程

   Streamer          AXI_IF
      |                  |
      |-- req(valid) ---->|   (1) 首次发送
      |                  |
      |<--- ready -------|   (2) AXI 接受
      |                  |
      |-- req(valid) ---->|   (3) 发送下一个
      |                  |
```

### 4.2 对齐检测与突发分类

**文件**: `src/dma/dma_streamer.sv`，第 297-323 行

突发计算分为三种情况：

```
情况 A: 对齐 + 足够数据 -> 完整突发 (full burst)
情况 B: 未对齐 + 足够数据 -> 单拍对齐事务 (起始非对齐)
情况 C: 对齐 + 不足数据 -> 单拍事务 (末尾残余)
情况 D: 未对齐 + 不足数据 -> 单拍事务 (小描述符)
```

```systemverilog
if (is_aligned(desc_addr_ff) && enough_for_burst(desc_bytes_ff)) begin
  // 情况 A: 最优路径，发送完整突发
  next_dma_req.alen = great_alen(desc_addr_ff, desc_bytes_ff);
  next_dma_req.strb = '1;           // 全部字节使能
  full_burst = 1'b1;
end
else begin
  // 情况 B/C/D: 单拍事务
  next_dma_req.alen = axi_alen_t'('0);  // alen=0 表示单拍
  if (`DMA_EN_UNALIGNED) begin
    if (enough_for_burst(desc_bytes_ff)) begin
      // 情况 B: 起始非对齐
      num_unalign_bytes = bytes_to_align(desc_addr_ff);
      next_dma_req.strb = get_strb(desc_addr_ff[2:0], num_unalign_bytes);
    end
    else if (is_aligned(desc_addr_ff)) begin
      // 情况 C: 末尾残余
      num_unalign_bytes = desc_bytes_ff[3:0];
      next_dma_req.strb = get_strb('d0, num_unalign_bytes);
    end
    else begin
      // 情况 D: 小描述符（非对齐且不足）
      num_unalign_bytes = desc_bytes_ff[3:0];
      next_dma_req.strb = get_strb(desc_addr_ff[2:0], num_unalign_bytes);
    end
  end
end
```

### 4.3 流程图

```
                    +-------------------+
                    | desc_addr 对齐?   |
                    +-------------------+
                     |              |
                    YES             NO
                     |              |
                     v              v
            +-------------+   +------------------+
            | bytes >=    |   | bytes >=         |
            | DATA_WIDTH  |   | bytes_to_align?  |
            | /8 ?        |   +------------------+
            +-------------+     |           |
             |          |      YES          NO
            YES         NO      |           |
             |          |       v           v
             v          v    起始非对齐   小描述符
        完整突发     末尾残余   单拍        单拍
        (great_alen)  单拍
```

---

## 5. great_alen 函数 -- 突发长度计算

### 5.1 算法详解

**文件**: `src/dma/dma_streamer.sv`，第 142-175 行

这是整个 Streamer 最关键的函数，它决定每次 AXI 突发传输多少个 beat。

```systemverilog
function automatic axi_alen_t great_alen(axi_addr_t addr, desc_num_t bytes);
  int max_beats;
  int hw_max_beats;
  int cfg_max_beats;
  int bytes_per_beat;
  int max_by_bytes;
  int bytes_to_page;
  int beats_to_page;

  // 1. 硬件和软件限制
  hw_max_beats = `DMA_MAX_BEAT_BURST;       // 硬件最大 256 beats
  bytes_per_beat = `DMA_DATA_WIDTH / 8;      // 每 beat 字节数 (4 或 8)
  cfg_max_beats = dma_maxb_i + 1;           // 软件配置的最大 beat 数

  // 取硬件和软件限制的较小值
  max_beats = (cfg_max_beats < hw_max_beats) ? cfg_max_beats : hw_max_beats;

  // 2. 剩余字节限制
  max_by_bytes = bytes / bytes_per_beat;
  if (max_by_bytes < max_beats) max_beats = max_by_bytes;

  // 3. 4KB 边界限制
  bytes_to_page = 4096 - (addr & 12'hFFF);
  beats_to_page = (bytes_to_page + bytes_per_beat - 1) / bytes_per_beat;
  if (beats_to_page < max_beats) max_beats = beats_to_page;

  // 5. 返回 AXI len 值 (beat 数 - 1)
  return (max_beats - 1);
endfunction
```

### 5.2 三重限制机制

```
最终 max_beats = min(硬件限制, 软件限制, 剩余字节限制, 4KB边界限制)

+------------------+     +------------------+     +------------------+
| DMA_MAX_BEAT_BURST|     | dma_maxb_i + 1   |     | 剩余字节/每beat  |
| (硬件, 最大256)   |     | (软件配置)        |     | (传输量限制)      |
+------------------+     +------------------+     +------------------+
         |                       |                        |
         +-----------+-----------+-----------+------------+
                     |
                     v
              min(所有限制)
                     |
                     v
           +------------------+
           | 4KB 边界限制     |
           | (AXI 协议要求)   |
           +------------------+
                     |
                     v
              max_beats - 1 = AXI alen
```

### 5.3 4KB 边界计算示例

```
假设: addr = 0x0000_0FFE, DATA_WIDTH = 32 (4 bytes/beat)

bytes_to_page = 4096 - (0x0FE & 0xFFF)
             = 4096 - 4094
             = 2 bytes

beats_to_page = ceil(2 / 4) = 1 beat

因此: 最多只能发 1 个 beat，不能跨 4KB 边界

地址布局:
  0x0000_0000 +------------------+
              |                  |
              |   当前 4KB 页     |
              |                  |
  0x0000_0FFE |--- addr --------|  <-- 起始地址
  0x0000_0FFF |-----------------|  <-- 4KB 边界
  0x0000_1000 +------------------+  <-- 下一个 4KB 页
```

---

## 6. 地址递增逻辑

### 6.1 INCR vs FIXED 模式

**文件**: `src/dma/dma_streamer.sv`，第 330-335 行

```systemverilog
if (dma_mode_ff == DMA_MODE_FIXED) begin
  next_desc_addr = desc_addr_ff;           // FIXED: 地址不变
end
else begin
  next_desc_addr = desc_addr_ff + axi_addr_t'(txn_bytes);  // INCR: 地址递增
end
```

```
INCR 模式 (递增):
  突发 1: addr=0x1000, len=3 -> 访问 0x1000, 0x1004, 0x1008, 0x100C
  突发 2: addr=0x1010, len=3 -> 访问 0x1010, 0x1014, 0x1018, 0x101C
            (地址自动递增)

FIXED 模式 (固定):
  突发 1: addr=0x1000, len=3 -> 访问 0x1000, 0x1000, 0x1000, 0x1000
  突发 2: addr=0x1000, len=3 -> 访问 0x1000, 0x1000, 0x1000, 0x1000
            (地址始终不变，用于 FIFO 类外设)
```

**关键知识点**: FIXED 模式通常用于访问 FIFO 接口的外设，每次读/写都访问同一个地址。INCR 模式用于访问连续内存区域。

### 6.2 txn_bytes 计算

**文件**: `src/dma/dma_streamer.sv`，第 325-326 行

```systemverilog
txn_bytes = full_burst ? max_bytes_t'((next_dma_req.alen+8'd1)*bytes_p_burst) :
                         max_bytes_t'(num_unalign_bytes);
```

- 完整突发: `txn_bytes = (alen + 1) * bytes_per_beat`
- 单拍事务: `txn_bytes = num_unalign_bytes`（实际有效字节数）

### 6.3 传输完成判断

**文件**: `src/dma/dma_streamer.sv`，第 329 行

```systemverilog
next_desc_bytes = desc_bytes_ff - desc_num_t'(txn_bytes);
next_last_txn   = (next_desc_bytes == '0);
```

当剩余字节数减为 0 时，标记为最后一个事务。

---

## 7. 字节使能（Strobe）生成

### 7.1 get_strb 函数

**文件**: `src/dma/dma_streamer.sv`，第 47-81 行

```systemverilog
function automatic axi_wr_strb_t get_strb(logic [2:0] addr, logic [3:0] bytes);
  axi_wr_strb_t strobe;
  if (`DMA_DATA_WIDTH == 64) begin
    case (bytes)
      'd1:  strobe = 'b0000_0001;
      'd2:  strobe = 'b0000_0011;
      'd3:  strobe = 'b0000_0111;
      'd4:  strobe = 'b0000_1111;
      'd5:  strobe = 'b0001_1111;
      'd6:  strobe = 'b0011_1111;
      'd7:  strobe = 'b0111_1111;
      default: strobe = '0;
    endcase
  end
  else begin  // 32-bit DATA_WIDTH
    case (bytes)
      'd1:  strobe = 'b0001;
      'd2:  strobe = 'b0011;
      'd3:  strobe = 'b0111;
      'd4:  strobe = 'b1111;
      default: strobe = '0;
    endcase
  end

  // 非对齐偏移
  if (`DMA_EN_UNALIGNED) begin
    for (logic [3:0] i=0; i<8; i++) begin
      if (addr == i[2:0]) begin
        strobe = strobe << i;
      end
    end
  end
  return strobe;
endfunction
```

### 7.2 Strobe 生成示例

```
DATA_WIDTH = 32 (4 bytes per beat)

情况 1: addr=0x0000, bytes=4 (对齐，完整)
  strobe = 0b1111

情况 2: addr=0x0002, bytes=2 (非对齐，起始)
  基础 strobe = 0b0011 (2 bytes)
  左移 2 位   = 0b1100
  含义: 只写 byte[2] 和 byte[3]

情况 3: addr=0x0000, bytes=3 (对齐，末尾残余)
  strobe = 0b0111
  含义: 只写 byte[0], byte[1], byte[2]

DATA_WIDTH = 64 (8 bytes per beat)

情况 4: addr=0x0003, bytes=5 (非对齐)
  基础 strobe = 0b0001_1111 (5 bytes)
  左移 3 位   = 0b1111_1000
  含义: 只写 byte[3] 到 byte[7]
```

### 7.3 对齐辅助函数

**文件**: `src/dma/dma_streamer.sv`，第 83-99 行

```systemverilog
// 计算到对齐边界还需要多少字节
function automatic logic [3:0] bytes_to_align(axi_addr_t addr);
  if (`DMA_DATA_WIDTH == 32) begin
    return (4'd4 - {2'b00,addr[1:0]});  // 32-bit: 按 4 字节对齐
  end
  else if (`DMA_DATA_WIDTH == 64) begin
    return (4'd8 - {1'b0,addr[2:0]});   // 64-bit: 按 8 字节对齐
  end
endfunction

// 将地址向下对齐
function automatic axi_addr_t aligned_addr(axi_addr_t addr);
  if (`DMA_DATA_WIDTH == 32) begin
    return {addr[`DMA_ADDR_WIDTH-1:2], 2'b00};  // 清除低 2 位
  end
  else begin
    return {addr[`DMA_ADDR_WIDTH-1:3], 3'b000};  // 清除低 3 位
  end
endfunction
```

---

## 8. 4KB 边界检测

### 8.1 burst_r4KB 函数

**文件**: `src/dma/dma_streamer.sv`，第 128-140 行

```systemverilog
function automatic logic burst_r4KB(axi_addr_t base, axi_addr_t fut);
  if (fut[`DMA_ADDR_WIDTH-1:12] < base[`DMA_ADDR_WIDTH-1:12]) begin
    return 0;  // 溢出，撞到边界
  end
  else begin
    if (fut[`DMA_ADDR_WIDTH-1:12] > base[`DMA_ADDR_WIDTH-1:12]) begin
      return (fut[11:0] == '0);  // 刚好在边界上，允许
    end
    else begin
      return 1;  // 同一 4KB 页内，安全
    end
  end
endfunction
```

### 8.2 边界检测图解

```
4KB 页边界检测原理:

地址空间 (以 12 位地址为例):
  0x000 - 0xFFF  : 页 0
  0x1000 - 0x1FFF: 页 1
  0x2000 - 0x2FFF: 页 2

case 1: base=0x0800, fut=0x1000
  base[11:12] = 0, fut[11:12] = 1
  fut > base 且 fut[11:0] == 0
  返回 1 (允许，刚好到边界)

case 2: base=0x0800, fut=0x1004
  base[11:12] = 0, fut[11:12] = 1
  fut > base 且 fut[11:0] != 0
  返回 0 (拒绝，跨越边界)

case 3: base=0x0800, fut=0x0C00
  base[11:12] = 0, fut[11:12] = 0
  同一页内
  返回 1 (允许)
```

**关键知识点**: AXI4 协议规定，突发事务不能跨越 4KB 边界。这是因为某些从设备可能在 4KB 边界处有地址解码逻辑，跨越边界可能导致未定义行为。

---

## 9. 完整数据通路示例

### 9.1 示例: 传输 100 字节

假设:
- `DMA_DATA_WIDTH = 32` (4 bytes/beat)
- `src_addr = 0x0000_1002` (非对齐)
- `num_bytes = 100`
- `rd_mode = DMA_MODE_INCR`
- `dma_maxb_i = 15` (最大 16 beats)

```
步骤 1: 初始状态
  desc_addr  = 0x0000_1002
  desc_bytes = 100
  mode       = INCR

步骤 2: 第一个事务 (非对齐起始)
  is_aligned(0x1002)? NO (低 2 位 = 10)
  enough_for_burst(100)? YES (100 >= 4)
  -> 起始非对齐处理
  bytes_to_align(0x1002) = 4 - 2 = 2
  strb = get_strb(2, 2) = 0b1100
  alen = 0 (单拍)
  txn_bytes = 2

  发出: addr=0x1000, alen=0, strb=0b1100
  desc_addr  = 0x1002 + 2 = 0x1004 (递增)
  desc_bytes = 100 - 2 = 98

步骤 3: 第二个事务 (对齐，完整突发)
  is_aligned(0x1004)? YES
  enough_for_burst(98)? YES (98 >= 4)
  great_alen(0x1004, 98):
    max_beats = min(16, 256, 98/4=24, 4KB限制)
    bytes_to_page = 4096 - (0x1004 & 0xFFF) = 4092
    beats_to_page = ceil(4092/4) = 1023
    max_beats = min(16, 24, 1023) = 16
    alen = 16 - 1 = 15

  发出: addr=0x1004, alen=15, strb=0xFFFF
  txn_bytes = 16 * 4 = 64
  desc_addr  = 0x1004 + 64 = 0x1044
  desc_bytes = 98 - 64 = 34

步骤 4: 第三个事务 (对齐，完整突发)
  great_alen(0x1044, 34):
    max_by_bytes = 34/4 = 8
    max_beats = min(16, 8) = 8
    alen = 8 - 1 = 7

  发出: addr=0x1044, alen=7, strb=0xFFFF
  txn_bytes = 8 * 4 = 32
  desc_addr  = 0x1044 + 32 = 0x1064
  desc_bytes = 34 - 32 = 2

步骤 5: 第四个事务 (末尾残余)
  is_aligned(0x1064)? YES
  enough_for_burst(2)? NO (2 < 4)
  -> 末尾残余处理
  num_unalign_bytes = 2
  strb = get_strb(0, 2) = 0b0011
  alen = 0 (单拍)

  发出: addr=0x1064, alen=0, strb=0b0011
  txn_bytes = 2
  desc_bytes = 2 - 2 = 0  -> last_txn = 1

总结: 100 字节 = 4 个 AXI 事务
  事务 1: 单拍, addr=0x1000, strb=0b1100 (2 bytes)
  事务 2: 16 拍, addr=0x1004 (64 bytes)
  事务 3: 8 拍,  addr=0x1044 (32 bytes)
  事务 4: 单拍, addr=0x1064, strb=0b0011 (2 bytes)
```

---

## 10. 中止处理

### 10.1 Abort 流程

**文件**: `src/dma/dma_streamer.sv`，第 353-360 行

```systemverilog
else begin  // dma_abort_i == 1
  if (dma_req_ff.valid && ~dma_axi_resp_i.ready) begin
    last_txn_proc = 'b1;   // 正在等待 AXI 响应，标记为正在处理
  end
  else begin
    next_dma_req = s_dma_axi_req_t'('0);  // 清除请求
  end
end
```

```
Abort 时序:

  Streamer          AXI_IF
      |                  |
      |-- req(valid) ---->|   正在传输中...
      |                  |
      |   dma_abort=1    |   收到中止信号
      |                  |
      |<--- ready -------|   等待当前事务完成
      |                  |
      | 清除 req         |   清理状态
      | -> IDLE          |
```

**关键知识点**: 中止不是立即生效的。如果一个 AXI 事务已经发出但尚未被接受（`valid=1, ready=0`），Streamer 必须等待该事务完成或被接受后才能安全退出。`last_txn_proc` 信号防止状态机在等待期间提前跳转到 IDLE。

---

## 11. 关键知识点总结

### 11.1 设计要点

| 特性 | 实现方式 | 说明 |
|------|---------|------|
| 突发拆分 | `great_alen` + 状态机 | 自动将大传输拆为多个 AXI 突发 |
| 4KB 边界 | `great_alen` 中的 `beats_to_page` | AXI 协议硬性要求 |
| 非对齐支持 | `get_strb` + `bytes_to_align` | 通过 strobe 掩码实现 |
| INCR/FIXED | `dma_mode_ff` 条件分支 | 支持两种 AXI 突发模式 |
| 中止保护 | `last_txn_proc` 信号 | 确保 AXI 事务完整性 |
| 可配置性 | `dma_maxb_i` 参数 | 软件可动态调整最大突发长度 |

### 11.2 性能考量

- **最佳情况**: 地址对齐 + 大数据量 -> 单个最大突发 (256 beats = 1KB @32-bit)
- **最差情况**: 非对齐 + 小数据量 -> 多个单拍事务，效率最低
- **4KB 边界**: 每 4KB 最多传 256 beats，需要多个事务跨越大地址范围

---

## 12. 动手实验

### 实验 1: 突发长度计算

给定以下参数，手动计算 `great_alen` 的返回值：

```
DATA_WIDTH = 32, DMA_MAX_BEAT_BURST = 256
dma_maxb_i = 7 (最大 8 beats)

a) addr = 0x1000, bytes = 1024
b) addr = 0x1FFC, bytes = 64
c) addr = 0x1002, bytes = 8
d) addr = 0x0FF0, bytes = 256
```

### 实验 2: Strobe 模式生成

为以下场景计算 strobe 值 (DATA_WIDTH=32):

```
a) addr=0x0000, bytes=1 -> strobe = ?
b) addr=0x0001, bytes=2 -> strobe = ?
c) addr=0x0003, bytes=1 -> strobe = ?
d) addr=0x0000, bytes=3 -> strobe = ?
```

### 实验 3: 完整传输追踪

模拟传输 50 字节，`src_addr=0x0000_2001`，`DATA_WIDTH=64`，`dma_maxb_i=15`：

```
列出每个 AXI 事务的:
- 地址 (addr)
- 突发长度 (alen)
- 字节使能 (strb)
- 传输字节数
```

### 实验 4: 代码修改

尝试修改 `dma_streamer.sv`，添加以下功能：

1. 在 `great_alen` 函数中添加 `$display` 调试信息（参考被注释掉的代码，第 170-171 行）
2. 修改 4KB 边界限制，使其支持 2KB 边界（某些旧从设备的要求）
3. 添加一个计数器，统计每个描述符产生了多少个 AXI 事务

---

## 13. 常见问题

**Q1: 为什么 `great_alen` 返回 `max_beats - 1` 而不是 `max_beats`?**

A: AXI 协议规定 `AxLEN` 字段的值 = 实际突发拍数 - 1。即 `AxLEN=0` 表示 1 拍，`AxLEN=15` 表示 16 拍。

**Q2: 为什么非对齐事务要先发一个单拍？**

A: 第一个非对齐事务的目标是将地址推到对齐边界。例如地址 `0x1002` 需要先传输 2 字节到 `0x1000-0x1003`，然后地址变为 `0x1004`（对齐），后续可以发完整突发。

**Q3: FIXED 模式下为什么还需要 `great_alen`?**

A: FIXED 模式仍然受 4KB 边界和软件配置的 `max_burst` 限制。虽然地址不递增，但突发长度仍需遵守这些约束。

**Q4: `last_txn_ff` 和 `last_txn_proc` 有什么区别？**

A: `last_txn_ff` 表示"最后一个事务已经发出"（等待 AXI 确认）。`last_txn_proc` 表示"正在处理中的事务不能被 abort 中断"。两者配合确保中止操作的安全性。

---

## 下一讲预告

[Lecture 14: DMA AXI接口 -- 五通道引擎与SVA断言](lecture_14_dma_axi_if.md)

我们将深入分析 `dma_axi_if.sv`，了解它如何管理 AXI 五通道的状态机、跟踪 outstanding 事务，以及使用 SVA 断言验证 AXI 协议合规性。
