# Lecture 15: DMA FIFO与完整数据通路

## 课程目标

本讲分析 DMA 引擎的最后两个核心组件：同步 FIFO 和功能封装模块，并串联整个 DMA 数据通路。
完成本讲后，你将掌握：

- 同步 FIFO 的设计原理与实现细节
- `dma_func_wrapper.sv` 的模块集成架构
- DMA 从软件触发到数据传输完成的完整工作流程
- DMA 性能分析与优化策略
- 各模块间的接口协议与数据流动

---

## 1. 同步 FIFO 设计 -- dma_fifo.sv

### 1.1 FIFO 在 DMA 中的角色

```
DMA 数据通路中的 FIFO 位置:

  Source                                   Destination
  (DDR/外设)                                (DDR/外设)
      |                                         ^
      v                                         |
  +--------+    +--------+    +---------+    +--------+
  | Read   |--->| DMA    |--->|  DMA    |--->| Write  |
  | Streamer|   | FIFO   |   | AXI IF  |   | Streamer|
  +--------+    +--------+    +---------+    +--------+
                      ^
                      |
              数据缓冲区 (深度=16, 宽度=32/64 bit)
```

FIFO 在 DMA 中的作用：
1. **解耦读写速率**: 读操作可能比写操作快（或反之）
2. **突发缓冲**: 读端可能一次读入多个 beat，写端需要逐个写出
3. **流控**: 当 FIFO 满时暂停读操作，空时暂停写操作

### 1.2 端口定义

**文件**: `src/dma/dma_fifo.sv`，第 10-29 行

```systemverilog
module dma_fifo
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;
#(
  parameter int SLOTS = `DMA_FIFO_DEPTH,   // FIFO 深度 (默认 16)
  parameter int WIDTH = `DMA_DATA_WIDTH    // 数据宽度 (默认 32)
)(
  input                                       clk,      // 时钟
  input                                       rst,      // 复位
  input                                       clear_i,  // 清除 (同步复位)
  input                                       write_i,  // 写使能
  input                                       read_i,   // 读使能
  input         [WIDTH-1:0]                   data_i,   // 写数据
  output  logic [WIDTH-1:0]                   data_o,   // 读数据
  output  logic                               error_o,  // 错误 (溢出/下溢)
  output  logic                               full_o,   // 满标志
  output  logic                               empty_o,  // 空标志
  output  logic [$clog2(SLOTS>1?SLOTS:2):0]   ocup_o,   // 占用数
  output  logic [$clog2(SLOTS>1?SLOTS:2):0]   free_o    // 空闲数
);
```

### 1.3 内部结构

**文件**: `src/dma/dma_fifo.sv`，第 30-38 行

```systemverilog
`define MSB_SLOT  $clog2(SLOTS>1?SLOTS:2)
typedef logic [$clog2(SLOTS>1?SLOTS:2):0] msb_t;

logic [SLOTS-1:0] [WIDTH-1:0] fifo_ff;     // 存储数组
msb_t                         write_ptr_ff;  // 写指针
msb_t                         read_ptr_ff;   // 读指针
msb_t                         next_write_ptr;
msb_t                         next_read_ptr;
msb_t                         fifo_ocup;     // 当前占用
```

### 1.4 指针编码方案

```
指针编码 (以 SLOTS=4 为例):

  写指针: [2:0] 其中 [1:0] 是地址位, [2] 是绕回位
  读指针: [2:0] 其中 [1:0] 是地址位, [2] 是绕回位

  地址位用于索引 FIFO 数组
  绕回位用于判断满/空

  状态示例 (写入 3 个数据):
  write_ptr = 3'b011  (绕回=0, 地址=3)
  read_ptr  = 3'b000  (绕回=0, 地址=0)

  FIFO 内容:
  +----+----+----+----+
  | D0 | D1 | D2 |    |
  +----+----+----+----+
    ^              ^
    read_ptr       write_ptr

  当写指针绕回一圈后:
  write_ptr = 3'b100  (绕回=1, 地址=0)
  read_ptr  = 3'b000  (绕回=0, 地址=0)
  此时: 地址相同但绕回位不同 -> 满!
```

### 1.5 满/空判断逻辑

**文件**: `src/dma/dma_fifo.sv`，第 40-64 行

```systemverilog
always_comb begin
  if (SLOTS == 1) begin
    // 单槽 FIFO 特殊处理
    empty_o = (write_ptr_ff == read_ptr_ff);
    full_o  = (write_ptr_ff[0] != read_ptr_ff[0]);
    data_o  = empty_o ? '0 : fifo_ff[0];
  end
  else begin
    // 多槽 FIFO 标准处理
    empty_o = (write_ptr_ff == read_ptr_ff);
    full_o  = (write_ptr_ff[`MSB_SLOT-1:0] == read_ptr_ff[`MSB_SLOT-1:0]) &&
              (write_ptr_ff[`MSB_SLOT] != read_ptr_ff[`MSB_SLOT]);
    data_o  = empty_o ? '0 : fifo_ff[read_ptr_ff[`MSB_SLOT-1:0]];
  end
```

```
满/空判断逻辑图解:

  情况 1: 空 (write_ptr == read_ptr)
  write_ptr = 3'b000
  read_ptr  = 3'b000
  地址相同, 绕回位相同 -> 空

  情况 2: 满 (地址相同, 绕回位不同)
  write_ptr = 3'b100  (绕回=1, 地址=0)
  read_ptr  = 3'b000  (绕回=0, 地址=0)
  地址相同, 绕回位不同 -> 满

  情况 3: 半满 (地址不同)
  write_ptr = 3'b010
  read_ptr  = 3'b000
  地址不同 -> 既不满也不空

  判断公式:
  empty = (write_ptr == read_ptr)
  full  = (write_ptr[MSB-1:0] == read_ptr[MSB-1:0]) &&
          (write_ptr[MSB] != read_ptr[MSB])
```

### 1.6 读写指针更新

**文件**: `src/dma/dma_fifo.sv`，第 55-64 行

```systemverilog
  // 写指针更新: 写使能且未满时递增
  if (write_i && ~full_o)
    next_write_ptr = write_ptr_ff + 'd1;

  // 读指针更新: 读使能且未空时递增
  if (read_i && ~empty_o)
    next_read_ptr = read_ptr_ff + 'd1;

  // 错误检测: 溢出或下溢
  error_o = (write_i && full_o) || (read_i && empty_o);

  // 占用数和空闲数计算
  fifo_ocup = write_ptr_ff - read_ptr_ff;
  free_o = msb_t'(SLOTS) - fifo_ocup;
  ocup_o = fifo_ocup;
```

### 1.7 数据存储与时序

**文件**: `src/dma/dma_fifo.sv`，第 67-90 行

```systemverilog
always_ff @ (posedge clk) begin
  if (rst) begin
    write_ptr_ff <= '0;
    read_ptr_ff  <= '0;
  end
  else begin
    if (clear_i) begin
      write_ptr_ff <= '0;    // 同步清除
      read_ptr_ff  <= '0;
    end
    else begin
      write_ptr_ff <= next_write_ptr;
      read_ptr_ff  <= next_read_ptr;

      // 写数据到 FIFO 数组
      if (write_i && ~full_o) begin
        if (SLOTS == 1) begin
          fifo_ff[0] <= data_i;
        end
        else begin
          fifo_ff[write_ptr_ff[`MSB_SLOT-1:0]] <= data_i;
        end
      end
    end
  end
end
```

### 1.8 时序图

```
FIFO 读写时序 (SLOTS=4):

  CLK   |  1  |  2  |  3  |  4  |  5  |  6  |  7  |  8  |
  ------+-----+-----+-----+-----+-----+-----+-----+-----+
  write_i|  1  |  1  |  1  |  0  |  0  |  1  |  0  |  0  |
  read_i |  0  |  0  |  0  |  1  |  1  |  0  |  1  |  0  |
  data_i | 0xA | 0xB | 0xC |  X  |  X  | 0xD |  X  |  X  |
  ------+-----+-----+-----+-----+-----+-----+-----+-----+
  wr_ptr |  0  |  1  |  2  |  3  |  3  |  3  |  3  |  3  |  (下一周期)
  rd_ptr |  0  |  0  |  0  |  0  |  1  |  2  |  2  |  3  |  (下一周期)
  ocup   |  0  |  1  |  2  |  3  |  2  |  1  |  2  |  1  |
  data_o |  0  |  0  |  0  | 0xA | 0xB | 0xB | 0xC | 0xC |  (组合输出)
  empty  |  1  |  0  |  0  |  0  |  0  |  0  |  0  |  0  |
  full   |  0  |  0  |  0  |  0  |  0  |  0  |  0  |  0  |
  ------+-----+-----+-----+-----+-----+-----+-----+-----+
  T1: 写入 0xA, wr_ptr 从 0 变 1
  T2: 写入 0xB, wr_ptr 从 1 变 2
  T3: 写入 0xC, wr_ptr 从 2 变 3
  T4: 读出, data_o=0xA (组合逻辑输出), rd_ptr 从 0 变 1
  T5: 读出, data_o=0xB, rd_ptr 从 1 变 2
```

**关键知识点**: `data_o` 是组合逻辑输出（直接从 FIFO 数组读取），不是寄存器输出。这意味着读数据在 `read_i` 有效的同一周期即可使用，没有额外延迟。

### 1.9 断言检查

**文件**: `src/dma/dma_fifo.sv`，第 92-100 行

```systemverilog
`ifndef NO_ASSERTIONS
  initial begin
    // 断言 1: FIFO 深度必须是 2 的幂
    illegal_fifo_slot : assert (2**$clog2(SLOTS) == SLOTS)
    else $error("FIFO Slots must be power of 2");

    // 断言 2: FIFO 深度至少为 1
    min_fifo_size : assert (SLOTS >= 1)
    else $error("FIFO size of SLOTS defined is illegal!");
  end
`endif
```

**关键知识点**: FIFO 深度必须是 2 的幂，这是因为绕回位的判断依赖于地址位的自然溢出。如果深度不是 2 的幂，满/空判断逻辑会出错。

---

## 设计视角：为什么这样设计？

### 动机：为什么读写流器之间需要 FIFO？

DMA 的核心任务是"从源读数据，写到目标"。读和写使用不同的 AXI 通道，
速率可能不同。如果没有缓冲区：

```
  无 FIFO 的问题:

  读端 (Source)                    写端 (Destination)
  ─────────────                    ─────────────────
  DDR 突发读取: 16 beats/突发      DDR 突发写入: 16 beats/突发
  读延迟: ~20 cycles               写延迟: ~20 cycles

  场景 1: 读快写慢
    读端发出数据 → 写端还没准备好 → 数据丢失!

  场景 2: 写快读慢
    写端等待数据 → 读端还没读到 → 写端空转!

  解决: 中间加 FIFO 缓冲
    读端 → FIFO → 写端
    读端只管往 FIFO 写，写端只管从 FIFO 读
    FIFO 满则暂停读，空则暂停写
```

### 为什么不用直接连线？

| 方案 | 优点 | 缺点 |
|------|------|------|
| 直接连线 (无缓冲) | 零延迟，面积最小 | 读写速率必须完全匹配 |
| **FIFO 缓冲（本设计）** | **解耦读写速率** | **需要额外存储** |
| 双缓冲 (乒乓) | 最大吞吐 | 面积翻倍，控制复杂 |

### 为什么 FIFO 深度必须是 2 的幂？

```
  绕回位判断法需要地址位自然溢出:

  SLOTS = 4 (2^2):
    write_ptr = 3'b011  → 地址=3, 绕回=0
    write_ptr = 3'b100  → 地址=0, 绕回=1  (自然溢出!)
    满判断: 地址相同 && 绕回位不同 → 正确

  SLOTS = 3 (非 2 的幂):
    write_ptr = 2'b11   → 地址=3? 但只有 3 个槽!
    无法用绕回位判断满/空
    需要额外的比较逻辑，增加延迟和面积
```

### 设计约束总结

```
FIFO 设计约束:

  约束 1: 深度 >= 最大突发长度 (防止读端填满后阻塞)
  约束 2: 深度必须是 2 的幂 (绕回位判断)
  约束 3: 宽度 = 数据总线宽度 (32 或 64 bit)
  约束 4: 组合逻辑输出 (零延迟读取)
  约束 5: 支持同步清除 (DMA 完成后清空)
```

---

## 设计视角：如何从零开始设计？

### 步骤 1: 确定 FIFO 规格

```
  需求分析:
    - 数据宽度: 与 AXI_DATA_WIDTH 一致 (32 或 64 bit)
    - 深度: 能容纳至少一个完整突发
      默认 DMA_MAX_BEAT_BURST=256, 但 FIFO 深度=16
      这意味着读端需要等写端消费后才能继续
    - 接口: 同步 (单时钟域)

  端口定义:
    write_i, data_i  → 写接口
    read_i, data_o   → 读接口
    full_o, empty_o  → 状态标志
    ocup_o, free_o   → 计数输出
```

### 步骤 2: 设计指针和存储

```
  存储: reg [WIDTH-1:0] fifo_ff [0:SLOTS-1]

  指针: 多一位用于绕回判断
    write_ptr: [$clog2(SLOTS):0]  // 比地址多 1 位
    read_ptr:  [$clog2(SLOTS):0]

  SLOTS=8 时:
    指针位宽 = 4 bit
    [2:0] = 地址位 (索引 0~7)
    [3]   = 绕回位 (区分满和空)
```

### 步骤 3: 实现满/空判断

```
  empty = (write_ptr == read_ptr)
         // 所有位相同，包括绕回位

  full  = (write_ptr[ADDR-1:0] == read_ptr[ADDR-1:0]) &&
          (write_ptr[WRAP] != read_ptr[WRAP])
         // 地址位相同，绕回位不同

  图示:
    空状态: wr=0000, rd=0000 → 全同 → 空
    满状态: wr=1000, rd=0000 → 地址同(0), 绕回异 → 满
```

### 步骤 4: 实现读写操作

```
  写操作 (always_ff):
    if (write_i && !full_o)
      fifo_ff[write_ptr[ADDR-1:0]] <= data_i
      write_ptr <= write_ptr + 1

  读操作 (组合逻辑输出):
    data_o = empty_o ? '0 : fifo_ff[read_ptr[ADDR-1:0]]

  读指针更新 (always_ff):
    if (read_i && !empty_o)
      read_ptr <= read_ptr + 1
```

### 步骤 5: 添加辅助功能

```
  占用数计算:
    ocup = write_ptr - read_ptr  // 利用绕回位自然溢出

  空闲数计算:
    free = SLOTS - ocup

  错误检测:
    error = (write_i && full_o) || (read_i && empty_o)

  同步清除:
    if (clear_i)
      write_ptr <= 0
      read_ptr  <= 0
```

---

## 设计视角：架构模式与原则

### 模式 1: 生产者-消费者 FIFO 模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  FIFO 是解耦生产者和消费者速率的经典模式                   │
  │                                                          │
  │  生产者 (读 Streamer)          消费者 (写 Streamer)       │
  │  ────────────────────          ────────────────────       │
  │  写入 FIFO                     从 FIFO 读取              │
  │  if (!full) 写入               if (!empty) 读取          │
  │  full 时暂停                   empty 时暂停              │
  │                                                          │
  │  流控信号:                                                │
  │    full_o  → 反压生产者                                   │
  │    empty_o → 反压消费者                                   │
  │                                                          │
  │  适用场景:                                                │
  │    - DMA 数据缓冲                                        │
  │    - 跨时钟域数据传输 (异步 FIFO)                         │
  │    - 流水线级间缓冲                                      │
  │    - 网络包缓冲                                          │
  └──────────────────────────────────────────────────────────┘
```

### 模式 2: 绕回位满空判断模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  用 N+1 位指针表示 N 位地址 + 1 位绕回                    │
  │                                                          │
  │  指针结构: [绕回位 | 地址位]                               │
  │                                                          │
  │  空判断: write_ptr == read_ptr (所有位相同)               │
  │  满判断: 地址位相同 && 绕回位不同                         │
  │                                                          │
  │  优势:                                                    │
  │    - 只需要 2 个比较器 (面积小)                           │
  │    - 占用数 = write_ptr - read_ptr (自然溢出)            │
  │    - 深度必须是 2 的幂 (约束)                             │
  │                                                          │
  │  替代方案 (非 2 幂深度):                                  │
  │    - 额外的比较逻辑                                       │
  │    - 计数器法 (面积更大)                                  │
  └──────────────────────────────────────────────────────────┘
```

### 模式 3: 分层集成模式

```
  ┌──────────────────────────────────────────────────────────┐
  │  将复杂系统分解为职责单一的子模块                          │
  │                                                          │
  │  DMA_FUNC_WRAPPER 集成架构:                               │
  │                                                          │
  │  ┌──────────┐   ┌──────────┐   ┌──────────┐             │
  │  │ DMA_FSM  │   │ STREAMER │   │ AXI_IF   │             │
  │  │ 控制逻辑 │   │ 突发计算 │   │ 协议适配 │             │
  │  └────┬─────┘   └────┬─────┘   └────┬─────┘             │
  │       │              │              │                    │
  │       └──────────────┼──────────────┘                    │
  │                      │                                   │
  │               ┌──────┴──────┐                            │
  │               │   DMA_FIFO  │                            │
  │               │   数据缓冲  │                            │
  │               └─────────────┘                            │
  │                                                          │
  │  接口类型: struct (s_dma_axi_req_t, s_dma_fifo_req_t)    │
  │  优势: 类型安全，编译时检查，便于替换子模块                │
  │                                                          │
  │  适用场景:                                                │
  │    - 任何由多个独立功能块组成的系统                       │
  │    - 需要可测试性和可替换性的设计                         │
  └──────────────────────────────────────────────────────────┘
```

---

## 2. DMA 功能封装 -- dma_func_wrapper.sv

### 2.1 模块架构

**文件**: `src/dma/dma_func_wrapper.sv`，第 10-26 行

`dma_func_wrapper` 是 DMA 引擎的顶层封装，将所有子模块集成在一起。

```
dma_func_wrapper 架构:

+--------------------------------------------------------------------+
|                      DMA_FUNC_WRAPPER                                |
|                                                                     |
|  +----------+                                                      |
|  | DMA_FSM  |  控制状态机                                            |
|  | (dma_fsm |  IDLE -> CFG -> RUN -> DONE                          |
|  |   .sv)   |                                                      |
|  +----+-----+                                                      |
|       |                                                             |
|       | dma_stream_rd_in/out                                        |
|       | dma_stream_wr_in/out                                        |
|       v                                                             |
|  +----+-----+    +------------+    +------------+                  |
|  | RD       |    |            |    | WR         |                  |
|  | STREAMER |--->|            |<---| STREAMER   |                  |
|  | (type=0) |    | DMA_AXI_IF |    | (type=1)   |                  |
|  +----------+    |            |    +------------+                  |
|                  |  (dma_axi  |                                    |
|                  |   _if.sv)  |                                    |
|                  +-----+------+                                    |
|                        |                                            |
|                        | dma_mosi_o / dma_miso_i                    |
|                        v                                            |
|                  AXI Master Interface                               |
|                        |                                            |
|                  +-----+------+                                    |
|                  | DMA_FIFO   |  数据缓冲                           |
|                  | (dma_fifo  |  深度=16, 宽度=32/64                |
|                  |   .sv)     |                                    |
|                  +------------+                                    |
+--------------------------------------------------------------------+
```

### 2.2 子模块实例化

#### 2.2.1 DMA FSM

**文件**: `src/dma/dma_func_wrapper.sv`，第 42-60 行

```systemverilog
dma_fsm u_dma_fsm(
  .clk              (clk),
  .rst              (rst),
  // From/To CSRs
  .dma_ctrl_i       (dma_ctrl_i),        // 控制信号 (go, abort, max_burst)
  .dma_desc_i       (dma_desc_i),        // 描述符数组
  // From/To AXI I/F
  .axi_pend_txn_i   (axi_pend_txn),      // AXI 有待处理事务
  .axi_txn_err_i    (axi_dma_err),       // AXI 错误
  .dma_error_o      (dma_error_o),       // 错误输出到 CSR
  .clear_dma_o      (clear_dma),         // 清除信号
  .dma_active_o     (dma_active),        // DMA 激活标志
  // To/From streamers
  .dma_stats_o      (dma_stats_o),       // 状态输出 (done, error)
  .dma_stream_rd_o  (dma_rd_stream_in),  // 读流器控制
  .dma_stream_rd_i  (dma_rd_stream_out), // 读流器状态
  .dma_stream_wr_o  (dma_wr_stream_in),  // 写流器控制
  .dma_stream_wr_i  (dma_wr_stream_out)  // 写流器状态
);
```

#### 2.2.2 读 Streamer

**文件**: `src/dma/dma_func_wrapper.sv`，第 62-77 行

```systemverilog
dma_streamer #(
  .STREAM_TYPE(0)              // 0 = 读流器
) u_dma_rd_streamer (
  .clk              (clk),
  .rst              (rst),
  .dma_desc_i       (dma_desc_i),         // 描述符
  .dma_abort_i      (dma_ctrl_i.abort_req),// 中止请求
  .dma_maxb_i       (dma_ctrl_i.max_burst),// 最大突发配置
  .dma_axi_req_o    (dma_axi_rd_req),      // -> AXI IF
  .dma_axi_resp_i   (dma_axi_rd_resp),     // <- AXI IF
  .dma_stream_i     (dma_rd_stream_in),    // <- FSM
  .dma_stream_o     (dma_rd_stream_out)    // -> FSM
);
```

#### 2.2.3 写 Streamer

**文件**: `src/dma/dma_func_wrapper.sv`，第 79-94 行

```systemverilog
dma_streamer #(
  .STREAM_TYPE(1)              // 1 = 写流器
) u_dma_wr_streamer (
  .clk              (clk),
  .rst              (rst),
  .dma_desc_i       (dma_desc_i),
  .dma_abort_i      (dma_ctrl_i.abort_req),
  .dma_maxb_i       (dma_ctrl_i.max_burst),
  .dma_axi_req_o    (dma_axi_wr_req),      // -> AXI IF
  .dma_axi_resp_i   (dma_axi_wr_resp),     // <- AXI IF
  .dma_stream_i     (dma_wr_stream_in),    // <- FSM
  .dma_stream_o     (dma_wr_stream_out)    // -> FSM
);
```

#### 2.2.4 DMA FIFO

**文件**: `src/dma/dma_func_wrapper.sv`，第 96-109 行

```systemverilog
dma_fifo u_dma_fifo(
  .clk              (clk),
  .rst              (rst),
  .clear_i          (clear_dma),           // DMA 完成时清除
  .write_i          (dma_fifo_req.wr),     // 读数据写入
  .read_i           (dma_fifo_req.rd),     // 写数据读出
  .data_i           (dma_fifo_req.data_wr),// 写入数据
  .data_o           (dma_fifo_resp.data_rd),// 读出数据
  .error_o          (),                    // 错误 (未使用)
  .full_o           (dma_fifo_resp.full),  // 满标志
  .empty_o          (dma_fifo_resp.empty), // 空标志
  .ocup_o           (dma_fifo_resp.ocup),  // 占用数
  .free_o           (dma_fifo_resp.space)  // 空闲数
);
```

#### 2.2.5 DMA AXI IF

**文件**: `src/dma/dma_func_wrapper.sv`，第 111-133 行

```systemverilog
dma_axi_if #(
  .DMA_ID_VAL       (DMA_ID_VAL)           // AXI Transaction ID
) u_dma_axi_if (
  .clk              (clk),
  .rst              (rst),
  // From/To Streamers
  .dma_axi_rd_req_i (dma_axi_rd_req),      // 读请求
  .dma_axi_rd_resp_o(dma_axi_rd_resp),     // 读响应
  .dma_axi_wr_req_i (dma_axi_wr_req),      // 写请求
  .dma_axi_wr_resp_o(dma_axi_wr_resp),     // 写响应
  // Master AXI I/F
  .dma_mosi_o       (dma_mosi_o),          // AXI Master 输出
  .dma_miso_i       (dma_miso_i),          // AXI Slave 输入
  // From/To FIFOs interface
  .dma_fifo_req_o   (dma_fifo_req),        // FIFO 请求
  .dma_fifo_resp_i  (dma_fifo_resp),       // FIFO 响应
  // From/To DMA FSM
  .axi_pend_txn_o   (axi_pend_txn),        // 待处理事务
  .axi_dma_err_o    (axi_dma_err),         // 错误
  .clear_dma_i      (clear_dma),           // 清除
  .dma_abort_i      (dma_ctrl_i.abort_req),// 中止
  .dma_active_i     (dma_active)           // 激活
);
```

---

## 3. 内部信号互联

### 3.1 信号流图

**文件**: `src/dma/dma_func_wrapper.sv`，第 27-40 行

```systemverilog
// 内部信号声明
s_dma_str_in_t    dma_rd_stream_in;    // FSM -> 读 Streamer
s_dma_str_out_t   dma_rd_stream_out;   // 读 Streamer -> FSM
s_dma_str_in_t    dma_wr_stream_in;    // FSM -> 写 Streamer
s_dma_str_out_t   dma_wr_stream_out;   // 写 Streamer -> FSM
s_dma_axi_req_t   dma_axi_rd_req;      // 读 Streamer -> AXI IF
s_dma_axi_resp_t  dma_axi_rd_resp;     // AXI IF -> 读 Streamer
s_dma_axi_req_t   dma_axi_wr_req;      // 写 Streamer -> AXI IF
s_dma_axi_resp_t  dma_axi_wr_resp;     // AXI IF -> 写 Streamer
s_dma_fifo_req_t  dma_fifo_req;        // AXI IF -> FIFO
s_dma_fifo_resp_t dma_fifo_resp;       // FIFO -> AXI IF
s_dma_error_t     axi_dma_err;         // AXI IF -> FSM
logic             axi_pend_txn;        // AXI IF -> FSM
logic             clear_dma;           // FSM -> AXI IF, FIFO
logic             dma_active;          // FSM -> AXI IF
```

### 3.2 完整信号流图

```
DMA_FUNC_WRAPPER 内部信号流:

  CSR 寄存器
  +------------------+
  | dma_ctrl_i       |----+-------+-------+
  |  .go             |    |       |       |
  |  .abort_req      |    |       |       |
  |  .max_burst      |    |       |       |
  +------------------+    |       |       |
  | dma_desc_i[0..N] |----+---+   |       |
  |  .src_addr       |    |   |   |       |
  |  .dst_addr       |    |   |   |       |
  |  .num_bytes      |    |   |   |       |
  |  .rd_mode        |    |   |   |       |
  |  .wr_mode        |    |   |   |       |
  +------------------+    |   |   |       |
                          v   v   v       v
                     +-----------------------+
                     |      DMA_FSM          |
                     |                       |
                     | IDLE->CFG->RUN->DONE  |
                     +---+-----------+-------+
                         |           |
            dma_stream_rd_in    dma_stream_wr_in
            dma_stream_rd_out   dma_stream_wr_out
                         |           |
                         v           v
               +-----------+   +-----------+
               | RD        |   | WR        |
               | STREAMER  |   | STREAMER  |
               | (type=0)  |   | (type=1)  |
               +-----+-----+   +-----+-----+
                     |               |
          dma_axi_rd_req    dma_axi_wr_req
          dma_axi_rd_resp   dma_axi_wr_resp
                     |               |
                     v               v
               +---------------------------+
               |       DMA_AXI_IF          |
               |                           |
               | AR/R/AW/W/B 通道管理      |
               | Outstanding 跟踪          |
               | SVA 断言验证              |
               +---+-------------------+---+
                   |                   |
                   v                   v
             +----------+        +----------+
             | DMA_FIFO |        | AXI Master|
             | (数据)    |        | Interface |
             +----------+        +----------+
                   |                   |
                   v                   v
              内部缓冲              外部总线
```

---

## 4. 完整 DMA 工作流程

### 4.1 阶段 1: 配置 (IDLE -> CFG)

```
软件配置流程:

  1. 写描述符寄存器:
     DMA_DESC[0].src_addr  = 0x8000_0000  (源地址)
     DMA_DESC[0].dst_addr  = 0x9000_0000  (目标地址)
     DMA_DESC[0].num_bytes = 1024         (传输 1KB)
     DMA_DESC[0].rd_mode   = INCR         (读递增)
     DMA_DESC[0].wr_mode   = INCR         (写递增)
     DMA_DESC[0].enable    = 1            (使能)

  2. 写控制寄存器:
     DMA_CTRL.max_burst    = 15           (最大 16 beats)
     DMA_CTRL.go           = 1            (启动 DMA)

  3. DMA FSM 检测到 go=1，从 IDLE 进入 CFG
  4. CFG 阶段检查描述符有效性 (check_cfg)
  5. 如果有效，进入 RUN
```

### 4.2 阶段 2: 运行 (RUN)

```
RUN 阶段并行操作:

  DMA FSM:
    - 扫描描述符，找到第一个 enable=1 的描述符
    - 向读/写 Streamer 发送 valid + idx
    - 等待所有描述符处理完成
    - 等待 AXI 无待处理事务
    - 进入 DONE

  读 Streamer:
    - 从描述符获取 src_addr 和 num_bytes
    - 计算突发拆分 (great_alen)
    - 向 AXI IF 发送读请求
    - 递增地址，减少剩余字节
    - 所有字节传输完成后发出 done

  写 Streamer:
    - 从描述符获取 dst_addr 和 num_bytes
    - 计算突发拆分 (great_alen)
    - 向 AXI IF 发送写请求
    - 递增地址，减少剩余字节
    - 所有字节传输完成后发出 done

  AXI IF:
    - 管理 AR/R/AW/W/B 五个通道
    - 跟踪 outstanding 事务
    - 从数据 FIFO 读取数据发送到总线
    - 从总线接收数据写入数据 FIFO
    - 检测和报告错误
```

### 4.3 阶段 3: 完成 (DONE -> IDLE)

```
完成流程:

  1. 所有描述符处理完成 (pending_desc = 0)
  2. AXI 无待处理事务 (axi_pend_txn = 0)
  3. FSM 进入 DONE 状态
  4. 输出 dma_stats_o.done = 1
  5. 软件轮询或中断检测到 done=1
  6. 软件写 go=0 或新的 go=1
  7. FSM 发出 clear_dma 信号
  8. AXI IF 清除错误状态
  9. FIFO 清除所有数据
  10. FSM 返回 IDLE
```

### 4.4 完整时序图

```
DMA 传输 1KB 数据的完整时序:

  阶段    | IDLE | CFG |          RUN                    | DONE |
  --------+------+------+------+------+------+------+------+------+
  FSM状态 | IDLE | CFG  | RUN  | RUN  | RUN  | RUN  | RUN  | DONE |
  go      |  0   |  1   |  X   |  X   |  X   |  X   |  X   |  X   |
  --------+------+------+------+------+------+------+------+------+
  RD STRM | IDLE | IDLE | RUN  | RUN  | RUN  | IDLE | IDLE | IDLE |
  rd_valid|  0   |  0   |  1   |  1   |  0   |  0   |  0   |  0   |
  rd_done |  0   |  0   |  0   |  0   |  1   |  0   |  0   |  0   |
  --------+------+------+------+------+------+------+------+------+
  WR STRM | IDLE | IDLE | RUN  | RUN  | RUN  | RUN  | IDLE | IDLE |
  wr_valid|  0   |  0   |  1   |  1   |  1   |  0   |  0   |  0   |
  wr_done |  0   |  0   |  0   |  0   |  0   |  1   |  0   |  0   |
  --------+------+------+------+------+------+------+------+------+
  FIFO    |  空  |  空  | 填充 | 填充 | 消费 | 消费 | 清除 |  空  |
  FIFO_ocup|  0  |  0   |  4   |  8   |  4   |  0   |  0   |  0   |
  --------+------+------+------+------+------+------+------+------+
  AXI     |  无  |  无  | AR   | R    | AW+W | B    |  无  |  无  |
  --------+------+------+------+------+------+------+------+------+
  done    |  0   |  0   |  0   |  0   |  0   |  0   |  1   |  0   |
```

---

## 5. 数据流动详解

### 5.1 读数据路径

```
读数据流动:

  DDR Memory
      |
      v
  AXI Slave (返回 rdata)
      |
      v
  DMA_AXI_IF (R 通道)
      | apply_strb(rdata, strobe)  <- 清除非有效字节
      v
  DMA_FIFO (写入)
      | dma_fifo_req.wr = 1
      | dma_fifo_req.data_wr = rdata
      v
  DMA_FIFO (存储)
      | 深度 16, 每槽 32/64 bit
      v
  DMA_FIFO (读出)
      | dma_fifo_resp.data_rd
      v
  DMA_AXI_IF (W 通道)
      | 将 FIFO 数据发送到 AXI 总线
      v
  AXI Slave (接收 wdata)
      |
      v
  Destination Memory
```

### 5.2 写数据路径

```
写数据路径与读数据路径共享同一个 FIFO:

  读 Streamer 发出读请求 -> AXI IF 从总线读取数据 -> 写入 FIFO
  写 Streamer 发出写请求 -> AXI IF 从 FIFO 读取数据 -> 写到总线

  FIFO 作为中间缓冲:

  [Source] --AR/R--> [AXI IF] --wr--> [FIFO] --rd--> [AXI IF] --AW/W--> [Dest]
```

**关键知识点**: DMA 的读和写操作共享同一个数据 FIFO。这意味着读操作必须先于写操作将数据填入 FIFO，然后写操作才能从 FIFO 中取出数据发送。这种设计简化了硬件，但要求读写操作有一定的顺序依赖。

---

## 6. 多描述符传输

### 6.1 描述符扫描机制

**文件**: `src/dma/dma_fsm.sv`，rd_streamer 块

```systemverilog
// FSM 扫描描述符逻辑
if (cur_st_ff == DMA_ST_RUN) begin
  for (int i=0; i<`DMA_NUM_DESC; i++) begin
    if (dma_desc_i[i].enable && (|dma_desc_i[i].num_bytes) && (~rd_desc_done_ff[i])) begin
      dma_stream_rd_o.idx   = i;
      dma_stream_rd_o.valid = ~abort_ff;
      next_rd_idx           = i;   // 锁存当前 idx
      break;                        // 只处理第一个未完成的
    end
  end

  if (dma_stream_rd_i.done) begin
    next_rd_desc_done[rd_idx_ff] = 1'b1;  // 标记完成
  end
end
```

### 6.2 多描述符时序

```
两个描述符的传输时序:

  描述符 0: src=0x1000, dst=0x2000, bytes=256
  描述符 1: src=0x3000, dst=0x4000, bytes=128

  时间轴:
  +------+--------+--------+--------+--------+--------+--------+--------+
  |      | 描述符0 | 描述符0 | 描述符0 | 描述符1 | 描述符1 | 描述符1 |        |
  |      | RD     | RD+WR  | WR     | RD     | RD+WR  | WR     | DONE   |
  +------+--------+--------+--------+--------+--------+--------+--------+

  读 Streamer:
  T1: 处理描述符 0 (src_addr=0x1000, 256 bytes)
  T2: 描述符 0 完成 (done=1)
  T3: 处理描述符 1 (src_addr=0x3000, 128 bytes)
  T4: 描述符 1 完成 (done=1)

  写 Streamer:
  T1: 等待数据进入 FIFO
  T2: 处理描述符 0 (dst_addr=0x2000, 256 bytes)
  T3: 描述符 0 完成 (done=1)
  T4: 处理描述符 1 (dst_addr=0x4000, 128 bytes)
  T5: 描述符 1 完成 (done=1)
```

**关键知识点**: 读和写 Streamer 独立处理各自的描述符。由于共享 FIFO，读操作通常先于写操作开始（因为需要先填充数据）。FSM 通过 `rd_desc_done_ff` 和 `wr_desc_done_ff` 位图跟踪每个描述符的完成状态。

---

## 7. 性能分析

### 7.1 带宽计算

```
DMA 理论带宽 = AXI_DATA_WIDTH / 8 * AXI_CLK_FREQ

假设:
  AXI_DATA_WIDTH = 32 bit (4 bytes)
  AXI_CLK_FREQ = 100 MHz

理论带宽 = 4 * 100M = 400 MB/s

实际带宽需要考虑:
  1. 突发效率: alen 越大，效率越高
  2. 地址对齐: 非对齐会降低效率
  3. Outstanding: 多个 outstanding 可以隐藏延迟
  4. FIFO 深度: 深度越大，流水线越深
```

### 7.2 效率分析

```
场景 1: 最优情况
  - 地址对齐
  - 数据量大 (>1KB)
  - max_burst = 255 (最大 256 beats)

  每个突发: 256 beats * 4 bytes = 1024 bytes
  地址开销: 1 个 AR/AW 周期
  数据传输: 256 个周期 (假设无等待)
  效率 = 256 / (1 + 256) = 99.6%

场景 2: 最差情况
  - 地址非对齐
  - 数据量小 (4 bytes)
  - 每次只有 1 beat

  每个突发: 1 beat * 4 bytes = 4 bytes
  地址开销: 1 个 AR/AW 周期
  数据传输: 1 个周期
  效率 = 1 / (1 + 1) = 50%

场景 3: 4KB 边界限制
  - 地址 = 0x0FFE
  - 数据量 = 1024 bytes

  第一个事务: 1 beat (到 4KB 边界)
  后续事务: 256 beats * 4 = 1024 bytes (跨页后)
  总效率 = 1024 / (1+1 + 4) = 98% (假设 4 个突发)
```

### 7.3 延迟分析

```
DMA 传输延迟组成:

  1. FSM 延迟: IDLE -> CFG -> RUN (2-3 周期)
  2. Streamer 延迟: 突发计算 (1 周期/突发)
  3. AXI 延迟:
     - AR/AW 握手: 1+ 周期
     - 从设备延迟: 取决于目标 (DDR: 10-50 周期)
     - 数据传输: alen+1 周期
  4. FIFO 延迟: 0 周期 (组合输出)

  总延迟 = FSM延迟 + N*(Streamer延迟 + AXI延迟)
  其中 N = 突发数量

示例: 传输 1KB，DATA_WIDTH=32，max_burst=15
  N = ceil(1024 / (16*4)) = 16 个突发
  每个突发延迟 = 1(Streamer) + 1(AR) + 20(DDR) + 16(数据) = 38 周期
  总延迟 = 3 + 16*38 = 611 周期
  @100MHz = 6.11 us
```

---

## 8. 中止操作详解

### 8.1 中止流程

```
DMA 中止操作:

  1. 软件写 abort_req = 1
     |
     v
  2. DMA FSM 设置 abort_ff = 1
     |
     v
  3. Streamer 收到 dma_abort_i
     |
     +-- 如果有正在处理的事务 (last_txn_proc)
     |   -> 等待事务完成
     |
     +-- 如果没有正在处理的事务
     |   -> 清除请求，返回 IDLE
     |
     v
  4. AXI IF 收到 dma_abort_i
     |
     +-- R 通道: rready 保持为 1，但不写入 FIFO
     |   (dma_abort_i ? 0 : 1 用于 fifo_req.wr)
     |
     +-- W 通道: 从 FIFO 读取数据但不发送
     |   (dma_abort_i ? 0 : wready 用于 fifo_req.rd)
     |
     v
  5. 所有 outstanding 事务自然完成
     |
     v
  6. axi_pend_txn 变为 0
     |
     v
  7. FSM 进入 DONE，然后 IDLE
```

### 8.2 中止安全性

```
中止安全性保证:

  规则 1: 已发出的 AXI 事务必须完成
    - 不能在 valid=1 时撤销
    - 等待 ready 或最后一个 beat

  规则 2: 中止时不能写入新数据到 FIFO
    - 防止 FIFO 中残留无效数据

  规则 3: 中止时不能从 FIFO 读取数据发送
    - 防止发送不完整的数据

  规则 4: 中止后必须清除所有状态
    - FIFO clear
    - 错误状态清除
    - outstanding 计数器清零
```

---

## 9. 关键知识点总结

### 9.1 FIFO 设计要点

| 特性 | 实现 | 说明 |
|------|------|------|
| 同步设计 | 单一时钟域 | 所有逻辑在 clk 上升沿触发 |
| 绕回位 | 指针多一位 | 区分满和空 |
| 组合输出 | 直接读取数组 | 零延迟读取 |
| 参数化 | SLOTS, WIDTH | 可配置深度和宽度 |
| 清除功能 | clear_i | 支持同步复位 |

### 9.2 Wrapper 设计要点

| 特性 | 实现 | 说明 |
|------|------|------|
| 模块化 | 4 个子模块 | 清晰的职责分离 |
| 参数化 | DMA_ID_VAL | 支持多 DMA 实例 |
| 内部互联 | struct 接口 | 类型安全的信号连接 |
| 错误传播 | 多级错误收集 | 从 AXI IF 到 CSR |

### 9.3 DMA 系统特性

| 特性 | 值 | 说明 |
|------|-----|------|
| 描述符数量 | 2 (可配置) | 支持多段传输 |
| 最大突发 | 256 beats | AXI4 最大值 |
| FIFO 深度 | 16 slots | 可配置 |
| 数据宽度 | 32/64 bit | 可配置 |
| Outstanding | 8 (读/写) | 可配置 |
| 非对齐支持 | 可选 | 通过 DMA_EN_UNALIGNED |
| 错误检测 | SLVERR/DECERR | AXI 标准错误 |

---

## 10. 动手实验

### 实验 1: FIFO 深度计算

给定以下参数，计算 FIFO 的实际存储容量：

```
SLOTS = 16, WIDTH = 32
SLOTS = 8,  WIDTH = 64
SLOTS = 32, WIDTH = 32
```

### 实验 2: 带宽计算

计算以下场景的 DMA 理论带宽和实际带宽：

```
场景 A:
  DATA_WIDTH = 32, CLK = 100MHz
  传输 4KB，地址对齐，max_burst=15

场景 B:
  DATA_WIDTH = 64, CLK = 200MHz
  传输 1MB，地址对齐，max_burst=255
```

### 实验 3: FIFO 满/空判断

给定 SLOTS=8，以下指针状态是否为满或空？

```
a) write_ptr=4'b0000, read_ptr=4'b0000
b) write_ptr=4'b1000, read_ptr=4'b0000
c) write_ptr=4'b0100, read_ptr=4'b0000
d) write_ptr=4'b1100, read_ptr=4'b0100
```

### 实验 4: 多描述符传输

设计一个使用 2 个描述符的 DMA 传输方案：
- 描述符 0: 从 DDR 0x1000_0000 读取 512 字节到 DDR 0x2000_0000
- 描述符 1: 从 DDR 0x3000_0000 读取 256 字节到 DDR 0x4000_0000

列出：
1. CSR 配置值
2. 预期的突发数量和大小
3. 大致的传输时间

### 实验 5: 性能优化

当前设计中，读和写操作是串行的（先读后写）。提出一种改进方案，使读和写可以并行进行，分析需要修改哪些模块。

---

## 11. 常见问题

**Q1: 为什么读和写共享同一个 FIFO？**

A: 这是 DMA 的基本工作模式：从源读取数据，缓冲，然后写到目标。共享 FIFO 简化了设计，因为数据只需要一个缓冲区。如果需要同时进行多个独立的 DMA 传输，需要使用不同的 DMA 实例。

**Q2: FIFO 深度如何选择？**

A: FIFO 深度应大于最大突发长度，以防止读端填满 FIFO 后必须等待写端消费。默认深度 16 可以缓冲 16 * 4 = 64 字节（32-bit 模式）或 16 * 8 = 128 字节（64-bit 模式）。

**Q3: 如何处理 FIFO 溢出？**

A: AXI IF 的 R 通道通过 `dma_fifo_resp_i.full` 信号检查 FIFO 状态。如果 FIFO 满，`rready` 会拉低，反压从设备停止发送数据。这是一种自然的流控机制。

**Q4: `clear_dma` 信号何时有效？**

A: `clear_dma` 在 FSM 从 DONE 转换到 IDLE 时有效（`(cur_st_ff == DMA_ST_DONE) && (next_st == DMA_ST_IDLE)`）。它用于清除 FIFO 数据和错误状态，为下一次传输做准备。

**Q5: 如果传输过程中发生错误怎么办？**

A: AXI IF 检测到 SLVERR 或 DECERR 后，设置 `axi_dma_err_o.valid = 1`。FSM 将错误信息传递给 CSR，软件可以通过轮询 `dma_error` 寄存器获取错误类型和地址。DMA 会继续完成当前传输（不会自动中止），但错误状态会被锁定直到软件清除。

---

## 12. DMA 模块总结

### 12.1 模块层次结构

```
dma_func_wrapper (顶层封装)
  |
  +-- dma_fsm (控制状态机)
  |     - 4 状态: IDLE -> CFG -> RUN -> DONE
  |     - 描述符扫描与分发
  |     - 错误状态管理
  |
  +-- dma_streamer (读流器, STREAM_TYPE=0)
  |     - 突发拆分计算
  |     - 4KB 边界检测
  |     - 地址递增管理
  |
  +-- dma_streamer (写流器, STREAM_TYPE=1)
  |     - 与读流器相同逻辑
  |     - 使用目标地址和写模式
  |
  +-- dma_axi_if (AXI 接口)
  |     - 5 通道状态机
  |     - Outstanding 跟踪
  |     - 4 个内部 FIFO
  |     - 19 个 SVA 断言
  |     - 错误检测与报告
  |
  +-- dma_fifo (数据 FIFO)
        - 同步设计
        - 参数化深度/宽度
        - 组合逻辑输出
```

### 12.2 数据类型总结

| 类型 | 定义 | 用途 |
|------|------|------|
| `s_dma_desc_t` | 描述符结构体 | CSR -> FSM |
| `s_dma_control_t` | 控制结构体 | CSR -> FSM |
| `s_dma_status_t` | 状态结构体 | FSM -> CSR |
| `s_dma_error_t` | 错误结构体 | AXI IF -> FSM -> CSR |
| `s_dma_str_in_t` | Streamer 输入 | FSM -> Streamer |
| `s_dma_str_out_t` | Streamer 输出 | Streamer -> FSM |
| `s_dma_axi_req_t` | AXI 请求 | Streamer -> AXI IF |
| `s_dma_axi_resp_t` | AXI 响应 | AXI IF -> Streamer |
| `s_dma_fifo_req_t` | FIFO 请求 | AXI IF -> FIFO |
| `s_dma_fifo_resp_t` | FIFO 响应 | FIFO -> AXI IF |
| `s_wr_req_t` | 写请求缓冲 | AXI IF 内部 |

---

## 课程总结

通过 Lecture 13-15 的学习，我们完整分析了 DMA 引擎的三个核心模块：

1. **Lecture 13: dma_streamer.sv** -- 突发计算引擎
   - 两态 FSM (IDLE/RUN)
   - 三重限制的突发长度计算 (great_alen)
   - 4KB 边界检测
   - 非对齐传输的 strobe 处理

2. **Lecture 14: dma_axi_if.sv** -- AXI 总线接口
   - 五通道独立管理
   - Outstanding 事务跟踪
   - 4 个内部 FIFO 缓冲
   - 19 个 SVA 断言验证协议合规

3. **Lecture 15: dma_fifo.sv + dma_func_wrapper.sv** -- 数据通路与集成
   - 同步 FIFO 设计
   - 模块化集成架构
   - 完整工作流程
   - 性能分析

这三个模块协同工作，实现了一个高效、可靠、可配置的 DMA 引擎，支持：
- 多描述符传输
- 突发优化
- 非对齐访问
- 错误检测
- 中止操作
- AXI4 协议合规
