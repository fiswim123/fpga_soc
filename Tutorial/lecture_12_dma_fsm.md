# Lecture 12: DMA FSM -- 四状态控制器

## 课程目标

本讲逐行分析 `dma_fsm.sv` 的实现细节。学完本讲后，你将能够：

- 理解 DMA FSM 的四状态设计及其转换条件
- 掌握描述符调度的优先级编码逻辑
- 理解读/写 Streamer 的独立完成跟踪
- 掌握 Abort 处理机制
- 能够独立设计一个类似的多描述符调度状态机

---

## 1. 模块概览

### 1.1 端口列表

`dma_fsm` 模块定义在 `src/dma/dma_fsm.sv` 中，共 182 行。它是 DMA 子系统的控制核心。

```
+------------------------------------------------------------------+
|                           dma_fsm                                |
|                                                                  |
|  CSR 接口                    AXI 接口               Streamer 接口 |
|  +-----------------+        +------------------+    +----------+  |
|  | dma_ctrl_i.go   |        | axi_pend_txn_i   |    | dma_str_ |  |
|  | dma_ctrl_i.abort|        | axi_txn_err_i    |    | rd_o/i   |  |
|  | dma_ctrl_i.maxb |        | dma_error_o      |    | dma_str_ |  |
|  | dma_desc_i[0..1]|        | clear_dma_o      |    | wr_o/i   |  |
|  | dma_stats_o     |        | dma_active_o     |    |          |  |
|  +-----------------+        +------------------+    +----------+  |
+------------------------------------------------------------------+
```

### 1.2 内部寄存器

```systemverilog
// src/dma/dma_fsm.sv, 第 32-43 行
dma_st_t cur_st_ff, next_st;                          // 状态寄存器
logic [`DMA_NUM_DESC-1:0] rd_desc_done_ff, next_rd_desc_done;  // 读完成位图
logic [`DMA_NUM_DESC-1:0] wr_desc_done_ff, next_wr_desc_done;  // 写完成位图
idx_desc_t rd_idx_ff, next_rd_idx;                    // 读描述符索引锁存
idx_desc_t wr_idx_ff, next_wr_idx;                    // 写描述符索引锁存
logic pending_desc;                                   // 有待处理描述符
logic pending_rd_desc, pending_wr_desc;               // 读/写待处理
logic abort_ff;                                       // Abort 锁存
```

---

## 1.1B 设计视角：为什么这样设计？

### 设计动机

DMA FSM 是整个 DMA 子系统的"大脑" —— 它决定何时启动传输、
调度哪个描述符、何时结束。FSM 的设计直接影响 DMA 的可靠性
和效率。

### 方案对比

| 设计维度 | 本项目方案 (4 态) | 简单 2 态 (IDLE/RUN) | 复杂多态 (每描述符独立 FSM) |
|----------|------------------|---------------------|--------------------------|
| 状态数 | 4 (IDLE/CFG/RUN/DONE) | 2 | 2*N (N=描述符数) |
| 描述符调度 | FSM 内循环遍历 | 无 (单描述符) | 每个描述符独立状态机 |
| Abort 支持 | 硬件支持, 优雅停止 | 无 | 每个 FSM 独立 abort |
| 完成检测 | 位图跟踪 | 直接检测 | 汇总各 FSM 状态 |
| 面积 | 中等 | 最小 | 最大 |
| 可扩展性 | 参数化描述符数 | 仅单描述符 | 固定描述符数 |

### 关键设计决策

**决策 1: 为什么是 4 个状态而非更多或更少?**

```
2 态方案 (IDLE/RUN) 的问题:
  ├── 没有配置检查: go=1 直接开始传输, 如果描述符无效怎么办?
  ├── 没有完成保持: 传输完成后立即回到 IDLE, 软件来不及读状态
  └── Abort 处理困难: 在 RUN 中 abort 后如何回到 IDLE?

4 态方案的优势:
  ├── IDLE: 干净的初始状态, 等待 go=1
  ├── CFG:  专门检查描述符有效性, 无效则直接跳 DONE
  ├── RUN:  调度描述符, 等待所有完成
  └── DONE: 保持状态, 等待软件读取后清除 go

  CFG 状态的价值:
  如果没有 CFG, go=1 后直接 RUN, 但所有描述符都无效
  → RUN 中 pending_desc=0, axi_pend_txn=0 → 立即 DONE
  → 功能正确, 但语义不清晰, 调试困难

  DONE 状态的价值:
  如果没有 DONE, 传输完成后直接 IDLE
  → 软件必须在传输完成的那个周期读取状态, 否则错过
  → 软件时序要求极高, 不现实
```

**决策 2: 为什么读写完成要独立跟踪?**

```
问题: 读和写路径可能以不同速度完成

  场景: DESC0 传输 256 字节
  读路径: 4 个 burst, 每个 64 字节 → T3 完成
  写路径: 4 个 burst, 每个 64 字节 → T6 完成

  如果用同一个完成位:
    rd_done[0] = 1 时, 但 wr 还没完成
    如果 FSM 误以为 DESC0 完成 → 数据丢失!

  独立跟踪:
    rd_desc_done[0] = 1 (读完成)
    wr_desc_done[0] = 0 (写未完成)
    pending_desc = pending_rd || pending_wr = 0 || 1 = 1
    → FSM 继续在 RUN 状态等待
```

**决策 3: 为什么需要索引锁存?**

```
问题: Streamer 的 done 信号有延迟

  时间线:
  T0: FSM 发送 desc_idx=0 给 Streamer
  T1: FSM 发送 desc_idx=1 给 Streamer
  T2: Streamer 报告 done=1 (对应 desc_idx=0)

  如果用 dma_stream_rd_o.idx (当前输出):
    T2 时 idx=1, 但 done 对应的是 idx=0 → 错误!

  用 rd_idx_ff (锁存值):
    T0 时锁存 rd_idx=0
    T2 时用 rd_idx_ff=0 → 正确标记 desc 0 完成
```

### 约束条件

| 约束 | 影响 | 应对策略 |
|------|------|----------|
| 描述符数量可变 | FSM 逻辑不能硬编码 | 用 `for` 循环 + `DMA_NUM_DESC` 参数 |
| 读写速度不匹配 | 不能用同一个完成信号 | 独立的 rd/wr 完成位图 |
| Abort 需要优雅停止 | 不能立即中断进行中的事务 | 等待当前事务完成, 不发送新描述符 |
| AXI 事务可能挂起 | FSM 不能永远等在 RUN | axi_pend_txn 信号兜底 |

---

## 1.1C 设计视角：如何从零开始设计？

假设你要从零设计一个 DMA FSM, 以下是推荐的设计步骤:

### Step 1: 定义状态和转换

```
第一步: 画出状态转换图

  最小状态集:
  ├── IDLE: 等待启动信号 (go=1)
  ├── RUN:  执行传输, 调度描述符
  └── DONE: 传输完成, 等待确认

  扩展状态 (推荐):
  ├── IDLE → CFG:  go=1 时进入配置检查
  ├── CFG  → RUN:  描述符有效且无 abort
  ├── CFG  → DONE: 描述符无效或有 abort
  ├── RUN  → RUN:  还有 pending 事务
  ├── RUN  → DONE: 所有事务完成
  ├── DONE → DONE: go 仍为 1 (软件还没确认)
  └── DONE → IDLE: go=0 (软件确认)
```

### Step 2: 设计描述符调度逻辑

```
第二步: 用优先级编码器选择下一个描述符

  调度算法:
  for (i = 0; i < NUM_DESC; i++) {
    if (desc[i].enable && desc[i].num_bytes > 0 && !done[i]) {
      dispatch_to_streamer(desc[i].idx);
      break;  // 找到第一个就停止
    }
  }

  优先级: DESC0 > DESC1 > DESC2 > ...

  设计要点:
  ├── for 循环 + break = 优先级编码器
  ├── 综合工具会自动优化为 MUX 链
  └── 描述符数量用参数化, 不硬编码
```

### Step 3: 设计完成跟踪机制

```
第三步: 用位图跟踪每个描述符的完成状态

  寄存器:
  ├── rd_desc_done[NUM_DESC-1:0]: 每个描述符的读完成标志
  └── wr_desc_done[NUM_DESC-1:0]: 每个描述符的写完成标志

  更新逻辑:
  // 当 Streamer 报告 done 时
  if (stream_rd_i.done) rd_desc_done[latched_idx] = 1;
  if (stream_wr_i.done) wr_desc_done[latched_idx] = 1;

  pending 计算:
  pending_rd = (还有未完成的读描述符)? 1 : 0;
  pending_wr = (还有未完成的写描述符)? 1 : 0;
  pending = pending_rd || pending_wr;

  完成条件:
  RUN → DONE: pending=0 && axi_pend_txn=0
```

### Step 4: 设计 Abort 处理

```
第四步: 处理中途取消请求

  Abort 策略:
  1. CPU 写 CONTROL.abort=1
  2. FSM 锁存 abort_ff=1
  3. 不再发送新的描述符给 Streamer (valid=0)
  4. 等待当前进行中的事务完成
  5. 当 pending=0 时, 转到 DONE

  关键: 不能立即停止, 必须等当前事务完成
  原因: AXI 协议不支持中途取消 burst
```

### Step 5: 设计输出和状态报告

```
第五步: 定义 FSM 的输出信号

  必要输出:
  ├── dma_stats_o.done:  传输完成标志
  ├── dma_stats_o.error: 错误标志
  ├── dma_error_o:       错误详情 (地址、类型、来源)
  ├── clear_dma_o:       DONE→IDLE 时的清除脉冲
  └── dma_active_o:      DMA 正在运行

  clear_dma_o 的作用:
  ├── 清除 FIFO 数据
  ├── 清除 AXI 接口的错误锁存
  └── 重置内部状态, 准备下一次传输
```

---

## 1.1D 设计视角：架构模式与原则

### 模式 1: 描述符调度模式 (Descriptor Scheduling Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  用位图 (bitmap) 跟踪多个任务的完成状态                    │
  │  用优先级编码器选择下一个要处理的任务                       │
  │  读写路径独立调度, 互不阻塞                                │
  └──────────────────────────────────────────────────────────┘

实现模板:
  // 位图寄存器
  logic [NUM_DESC-1:0] done_bitmap;

  // 调度逻辑 (组合逻辑)
  always_comb begin
    next_task_valid = 0;
    next_task_idx   = 0;
    for (int i = 0; i < NUM_DESC; i++) begin
      if (task[i].enable && !done_bitmap[i]) begin
        next_task_valid = 1;
        next_task_idx   = i;
        break;
      end
    end
  end

  // 完成更新 (时序逻辑)
  always_ff @(posedge clk) begin
    if (worker_done) done_bitmap[done_idx] <= 1;
  end

适用场景:
  ├── 多通道 DMA (每个通道一个描述符)
  ├── 多任务调度器 (优先级+公平性)
  └── 任何需要从多个待处理任务中选择一个的场景
```

### 模式 2: 独立读写跟踪模式 (Independent RD/WR Tracking Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  当一个任务包含两个独立的子任务 (读和写) 时                 │
  │  为每个子任务维护独立的完成状态                              │
  │  总体完成 = 所有子任务都完成                                 │
  └──────────────────────────────────────────────────────────┘

为什么读写要独立跟踪:
  ├── 读路径: 源存储器 → FIFO (可能突发读, 速度快)
  ├── 写路径: FIFO → 目标存储器 (可能突发写, 速度慢)
  ├── 读写速度取决于源/目标存储器的响应速度
  └── 用同一个完成位会导致误判

实现模板:
  // 独立完成位图
  logic [NUM_DESC-1:0] rd_done_bitmap;
  logic [NUM_DESC-1:0] wr_done_bitmap;

  // 总体 pending
  assign pending = (|rd_todo) || (|wr_todo);
  // 其中 rd_todo = 有待处理的读描述符
  //      wr_todo = 有待处理的写描述符

  // 只有读写都完成才进入 DONE
  always_ff @(posedge clk) begin
    if (!pending && !axi_busy) state <= DONE;
  end

适用场景:
  ├── DMA 读写路径分离的设计
  ├── 网络数据包处理 (收发独立)
  └── 任何包含两个不对称子任务的系统
```

---

## 2. 四状态设计

### 2.1 状态定义

```systemverilog
// src/dma/inc/dma_pkg.svh, 第 79-84 行
typedef enum logic [1:0] {
  DMA_ST_IDLE,    // 00: 空闲，等待启动
  DMA_ST_CFG,     // 01: 配置检查
  DMA_ST_RUN,     // 10: 运行中，执行传输
  DMA_ST_DONE     // 11: 完成，等待确认
} dma_st_t;
```

### 2.2 状态转换图

```
                    +-----------+
                    |   IDLE    |
                    |  (00)     |
                    +-----+-----+
                          |
                    go=1  v
                    +-----+-----+
              +---->|    CFG    |
              |     |  (01)     |
              |     +-----+-----+
              |           |
              |  有效描述符  |  无有效描述符或 abort
              |  且无 abort  |  (check_cfg()=0 或 abort_req=1)
              |           |
              |     +-----v-----+
              |     |    RUN    |<--------+
              |     |  (10)     |         |
              |     +-----+-----+   pending_desc=1
              |           |           或 axi_pend_txn=1
              |  所有描述符  |
              |  完成且无    |
              |  pending    |
              |           |
              |     +-----v-----+
              |     |   DONE    |---------+
              |     |  (11)     |  go=1   |
              |     +-----+-----+---------+
              |           |
              |     go=0  v
              +-----------+
              (回到 IDLE，但 go=1 时停留在 DONE)
```

### 2.3 状态转换逻辑

```systemverilog
// src/dma/dma_fsm.sv, 第 57-89 行
always_comb begin : fsm_dma_ctrl
  next_st = DMA_ST_IDLE;
  pending_desc = pending_rd_desc || pending_wr_desc;

  case (cur_st_ff)
    DMA_ST_IDLE: begin
      if (dma_ctrl_i.go) begin
        next_st = DMA_ST_CFG;        // go=1 -> 进入配置检查
      end
    end

    DMA_ST_CFG: begin
      if (~dma_ctrl_i.abort_req && check_cfg()) begin
        next_st = DMA_ST_RUN;        // 有效描述符且无 abort -> 运行
      end else begin
        next_st = DMA_ST_DONE;       // 无效或 abort -> 直接完成
      end
    end

    DMA_ST_RUN: begin
      if (pending_desc || axi_pend_txn_i) begin
        next_st = DMA_ST_RUN;        // 还有工作 -> 继续运行
      end else begin
        next_st = DMA_ST_DONE;       // 所有完成 -> 进入完成状态
      end
    end

    DMA_ST_DONE: begin
      if (dma_ctrl_i.go) begin
        next_st = DMA_ST_DONE;       // go 仍为 1 -> 停留在 DONE
      end
      // go=0 时，next_st 保持 DMA_ST_IDLE（由 default 赋值）
    end
  endcase
end
```

### 2.4 DONE 状态的停留机制

DONE 状态有一个关键特性：当 `go` 信号仍为 1 时，FSM 会停留在 DONE 状态：

```
时间线:
  T0: go=1, FSM: IDLE -> CFG
  T1: 有效描述符, FSM: CFG -> RUN
  T2-T10: 传输进行中, FSM: RUN
  T11: 所有完成, FSM: RUN -> DONE
  T12: go 仍为 1, FSM: DONE -> DONE (停留)
  T13: 软件写 go=0, FSM: DONE -> IDLE
```

这个设计允许软件在传输完成后读取状态，然后再清除 `go` 位。

---

## 3. 描述符配置检查

### 3.1 check_cfg 函数

```systemverilog
// src/dma/dma_fsm.sv, 第 44-55 行
function automatic logic check_cfg();
  logic [`DMA_NUM_DESC-1:0] valid_desc;

  valid_desc = '0;

  for (int i=0; i<`DMA_NUM_DESC; i++) begin
    if (dma_desc_i[i].enable) begin
      valid_desc[i] = (|dma_desc_i[i].num_bytes);  // num_bytes > 0
    end
  end
  return |valid_desc;  // 任何一个描述符有效即可
endfunction
```

### 3.2 有效描述符的条件

一个描述符被认为是"有效"的，需要同时满足两个条件：

```
有效条件:
  1. enable = 1       (描述符已使能)
  2. num_bytes > 0    (有数据要传输)

无效情况:
  - enable = 0                 (未使能)
  - enable = 1, num_bytes = 0  (使能但无数据)
```

### 3.3 CFG 状态的决策

```
CFG 状态决策树:

  abort_req?
    |
    +-- 是 --> DONE (中止传输)
    |
    +-- 否 --> check_cfg()?
                |
                +-- 是 --> RUN (开始传输)
                |
                +-- 否 --> DONE (无有效描述符)
```

---

## 4. 描述符调度逻辑

### 4.1 读 Streamer 调度

```systemverilog
// src/dma/dma_fsm.sv, 第 92-119 行
always_comb begin : rd_streamer
  dma_stream_rd_o   = s_dma_str_in_t'('0);  // 默认无效
  next_rd_desc_done = rd_desc_done_ff;       // 保持当前状态
  pending_rd_desc   = 1'b0;
  dma_active_o      = (cur_st_ff == DMA_ST_RUN);
  next_rd_idx       = rd_idx_ff;

  if (cur_st_ff == DMA_ST_RUN) begin
    // 遍历所有描述符，找到第一个需要处理的
    for (int i=0; i<`DMA_NUM_DESC; i++) begin
      if (dma_desc_i[i].enable &&                    // 已使能
          (|dma_desc_i[i].num_bytes) &&              // 有数据
          (~rd_desc_done_ff[i])) begin               // 未完成
        dma_stream_rd_o.idx   = i;                   // 指定描述符索引
        dma_stream_rd_o.valid = ~abort_ff;           // abort 时无效
        next_rd_idx           = i;                   // 锁存索引
        break;                                        // 找到第一个就停止
      end
    end

    // 当 Streamer 报告完成时，标记对应描述符为已完成
    if (dma_stream_rd_i.done) begin
      next_rd_desc_done[rd_idx_ff] = 1'b1;           // 使用锁存的索引
    end

    pending_rd_desc = dma_stream_rd_o.valid;          // 有待处理的读描述符
  end

  // DONE 状态时清除所有完成标记
  if (cur_st_ff == DMA_ST_DONE) begin
    next_rd_desc_done = '0;
  end
end
```

### 4.2 写 Streamer 调度

写 Streamer 的调度逻辑与读 Streamer 完全对称：

```systemverilog
// src/dma/dma_fsm.sv, 第 122-148 行
always_comb begin : wr_streamer
  dma_stream_wr_o   = s_dma_str_in_t'('0);
  next_wr_desc_done = wr_desc_done_ff;
  pending_wr_desc   = 1'b0;
  next_wr_idx       = wr_idx_ff;

  if (cur_st_ff == DMA_ST_RUN) begin
    for (int i=0; i<`DMA_NUM_DESC; i++) begin
      if (dma_desc_i[i].enable && (|dma_desc_i[i].num_bytes) && (~wr_desc_done_ff[i])) begin
        dma_stream_wr_o.idx   = i;
        dma_stream_wr_o.valid = ~abort_ff;
        next_wr_idx           = i;
        break;
      end
    end

    if (dma_stream_wr_i.done) begin
      next_wr_desc_done[wr_idx_ff] = 1'b1;
    end

    pending_wr_desc = dma_stream_wr_o.valid;
  end

  if (cur_st_ff == DMA_ST_DONE) begin
    next_wr_desc_done = '0;
  end
end
```

### 4.3 索引锁存机制

索引锁存是调度逻辑的关键设计：

```
问题: Streamer 的 done 信号可能延迟到达

时间线:
  T0: FSM 发送 desc_idx=0 给 Streamer
  T1: FSM 发送 desc_idx=1 给 Streamer (desc 0 已被 Streamer 处理完)
  T2: Streamer 报告 done=1

  如果不锁存索引: FSM 不知道 done 对应的是 desc 0 还是 desc 1
  使用锁存索引: rd_idx_ff=0 (锁存于 T0)，所以 done 对应 desc 0
```

```
索引锁存时序:

  T0: dma_stream_rd_o={valid=1, idx=0}
      next_rd_idx=0 (锁存)
      rd_idx_ff <= 0

  T1: dma_stream_rd_o={valid=1, idx=1}
      next_rd_idx=1 (锁存)
      rd_idx_ff <= 1
      但 desc 0 的 done 可能还没到达

  T2: dma_stream_rd_i.done=1
      next_rd_desc_done[rd_idx_ff] = next_rd_desc_done[1] = 1
      (使用当前锁存的索引 1)
```

### 4.4 调度优先级

调度使用 for 循环 + break 实现优先级编码：

```
描述符优先级:
  DESC0 > DESC1 > DESC2 > ... > DESCn

遍历顺序:
  i=0: 检查 DESC0
    - 如果有效且未完成 -> 选中，break
    - 否则继续
  i=1: 检查 DESC1
    - 如果有效且未完成 -> 选中，break
    - 否则继续
  ...
```

这意味着描述符 0 总是优先于描述符 1 被处理。

---

## 5. 读/写独立完成跟踪

### 5.1 为什么需要独立跟踪？

DMA 的读和写路径是独立的硬件通道，它们可能以不同速度完成：

```
场景: 描述符 0 传输 256 字节

读路径:
  T0-T3: 读取 4 个突发，每个 64 字节
  T3: 读完成 -> rd_desc_done[0] = 1

写路径:
  T2-T6: 写入 4 个突发，每个 64 字节
  T6: 写完成 -> wr_desc_done[0] = 1

时间差: 读比写早 3 个周期完成
```

### 5.2 完成位图

```
rd_desc_done_ff:  [1:0] -- 每个描述符的读完成状态
wr_desc_done_ff:  [1:0] -- 每个描述符的写完成状态

示例:
  DESC0 读完成，DESC1 未完成:
    rd_desc_done_ff = 2'b01
    wr_desc_done_ff = 2'b00

  DESC0 读写都完成，DESC1 读完成但写未完成:
    rd_desc_done_ff = 2'b11
    wr_desc_done_ff = 2'b01
```

### 5.3 pending_desc 的计算

```systemverilog
// src/dma/dma_fsm.sv, 第 59 行
pending_desc = pending_rd_desc || pending_wr_desc;
```

`pending_rd_desc` 和 `pending_wr_desc` 分别表示读和写 Streamer 是否有待处理的描述符。只有当两者都为 0 时，FSM 才会从 RUN 转换到 DONE。

---

## 6. Abort 处理

### 6.1 Abort 信号链

```
CPU 写入 CONTROL.abort=1
          |
          v
    dma_csr 输出 o_dma_control_abort=1
          |
          v
    dma_axi_wrapper 传递给 dma_func_wrapper
          |
          +---> dma_fsm.dma_ctrl_i.abort_req
          +---> dma_streamer.dma_abort_i
          +---> dma_axi_if.dma_abort_i
```

### 6.2 FSM 中的 Abort 处理

```systemverilog
// src/dma/dma_fsm.sv, 第 179 行
abort_ff <= dma_ctrl_i.abort_req;  // 锁存 abort 信号
```

Abort 信号被锁存到 `abort_ff`，然后影响 Streamer 的调度：

```systemverilog
// src/dma/dma_fsm.sv, 第 103 行
dma_stream_rd_o.valid = ~abort_ff;  // abort 时不再发送新的描述符
```

### 6.3 Abort 时序图

```
时间   事件                              FSM 状态
----   ----                              --------
T0     FSM: RUN, 传输进行中               cur_st=RUN
T1     CPU 写入 abort=1                   abort_ff <= 1 (下一个周期生效)
T2     abort_ff=1                         dma_stream_rd_o.valid=0
                                          不再发送新描述符
T3     等待进行中的事务完成                 pending_desc=1 (还有事务)
T4     所有事务完成                        pending_desc=0
T5     FSM: RUN -> DONE                   cur_st=DONE
T6     CPU 读取 STATUS，确认完成
T7     CPU 写入 go=0, abort=0             FSM: DONE -> IDLE
```

### 6.4 Streamer 中的 Abort 处理

Streamer 在 abort 时会等待当前事务完成：

```systemverilog
// src/dma/dma_streamer.sv, 第 227-234 行
DMA_ST_SM_RUN: begin
  if (dma_abort_i) begin
    if (last_txn_proc) begin
      next_st = DMA_ST_SM_RUN;    // 正在处理最后一个事务，继续
    end else begin
      next_st = DMA_ST_SM_IDLE;   // 无待处理事务，回到 IDLE
    end
  end
end
```

---

## 7. 状态输出信号

### 7.1 dma_status 组合逻辑

```systemverilog
// src/dma/dma_fsm.sv, 第 150-162 行
always_comb begin : dma_status
  dma_error_o = s_dma_error_t'('0);

  if (axi_txn_err_i.valid) begin
    dma_error_o.addr     = axi_txn_err_i.addr;
    dma_error_o.type_err = DMA_ERR_OPE;
    dma_error_o.src      = axi_txn_err_i.src;
    dma_error_o.valid    = 1'b1;
  end

  dma_stats_o.error = axi_txn_err_i.valid;
  dma_stats_o.done  = (cur_st_ff == DMA_ST_DONE);
  clear_dma_o       = (cur_st_ff == DMA_ST_DONE) && (next_st == DMA_ST_IDLE);
end
```

### 7.2 输出信号说明

| 信号 | 来源 | 说明 |
|------|------|------|
| `dma_stats_o.done` | `cur_st == DONE` | 传输完成标志 |
| `dma_stats_o.error` | `axi_txn_err_i.valid` | 错误标志 |
| `dma_error_o` | `axi_txn_err_i` | 错误详情（地址、类型、来源） |
| `clear_dma_o` | DONE->IDLE 转换 | 清除 DMA 内部状态 |
| `dma_active_o` | `cur_st == RUN` | DMA 活跃标志 |

### 7.3 clear_dma_o 的作用

`clear_dma_o` 在 FSM 从 DONE 转换到 IDLE 时产生一个脉冲，用于：

```
clear_dma_o 信号的作用:

1. 清除 DMA FIFO 的数据
   -> dma_fifo.clear_i = clear_dma

2. 清除 AXI 接口的错误锁存
   -> dma_axi_if.clear_dma_i = clear_dma

3. 清除写事务锁
   -> wr_lock_ff <= 0
```

---

## 8. 时序寄存器更新

### 8.1 时序块

```systemverilog
// src/dma/dma_fsm.sv, 第 165-181 行
always_ff @(posedge clk) begin
  if (rst) begin
    cur_st_ff       <= dma_st_t'('0);    // IDLE
    rd_desc_done_ff <= '0;
    wr_desc_done_ff <= '0;
    rd_idx_ff       <= '0;
    wr_idx_ff       <= '0;
    abort_ff        <= '0;
  end else begin
    cur_st_ff       <= next_st;
    rd_desc_done_ff <= next_rd_desc_done;
    wr_desc_done_ff <= next_wr_desc_done;
    rd_idx_ff       <= next_rd_idx;
    wr_idx_ff       <= next_wr_idx;
    abort_ff        <= dma_ctrl_i.abort_req;
  end
end
```

### 8.2 复位行为

所有寄存器在复位时清零：
- `cur_st_ff` = IDLE
- `rd_desc_done_ff` = 0
- `wr_desc_done_ff` = 0
- `rd_idx_ff` = 0
- `wr_idx_ff` = 0
- `abort_ff` = 0

---

## 9. 完整传输流程示例

### 9.1 双描述符传输

假设配置了两个描述符：
- DESC0: src=0x1000, dst=0x2000, bytes=128, enable=1
- DESC1: src=0x3000, dst=0x4000, bytes=64, enable=1

```
时间   事件                              FSM 状态     调度
----   ----                              --------     ----
T0     CPU 写入 go=1                      IDLE
T1     go=1 检测到                        IDLE->CFG
T2     check_cfg()=1 (两个描述符有效)      CFG->RUN
       abort_req=0

T3     调度 DESC0 读                      RUN          rd: DESC0
       dma_stream_rd_o={valid=1, idx=0}
       调度 DESC0 写
       dma_stream_wr_o={valid=1, idx=0}

T4-T8  DESC0 读 Streamer 处理中            RUN          rd: DESC0
       DESC0 写 Streamer 处理中                       wr: DESC0

T9     DESC0 读完成                        RUN          rd: DESC1
       rd_desc_done[0]=1                              wr: DESC0
       调度 DESC1 读
       dma_stream_rd_o={valid=1, idx=1}

T10    DESC0 写完成                        RUN          rd: DESC1
       wr_desc_done[0]=1                              wr: DESC1
       调度 DESC1 写
       dma_stream_wr_o={valid=1, idx=1}

T11-T14 DESC1 读/写 Streamer 处理中        RUN          rd: DESC1
                                                      wr: DESC1

T15    DESC1 读完成                        RUN          (无)
       rd_desc_done[1]=1
       pending_rd_desc=0

T16    DESC1 写完成                        RUN          (无)
       wr_desc_done[1]=1
       pending_wr_desc=0
       pending_desc=0
       axi_pend_txn=0

T17    FSM: RUN -> DONE                   DONE
       dma_stats_o.done=1

T18    CPU 读取 STATUS                     DONE
       done=1, magic=0xCAFE

T19    CPU 写入 go=0                       DONE->IDLE
       clear_dma_o=1 (脉冲)
```

### 9.2 Abort 流程

```
时间   事件                              FSM 状态
----   ----                              --------
T0     FSM: RUN, DESC0 传输中             RUN
T1     CPU 写入 abort=1                    RUN
T2     abort_ff=1                          RUN
       dma_stream_rd_o.valid=0
       不再发送新描述符

T3     等待 DESC0 当前事务完成             RUN
       pending_desc=1 (还有事务)

T4     DESC0 读完成                        RUN
       rd_desc_done[0]=1
       但 wr 还未完成

T5     DESC0 写完成                        RUN
       wr_desc_done[0]=1
       pending_desc=0
       axi_pend_txn=0

T6     FSM: RUN -> DONE                   DONE
       DESC1 未被处理 (rd_desc_done[1]=0)

T7     CPU 读取 STATUS                     DONE
       done=1

T8     CPU 写入 go=0, abort=0             DONE->IDLE
```

---

## 10. 与 Streamer 的接口

### 10.1 FSM -> Streamer 接口

```systemverilog
// src/dma/inc/dma_pkg.svh, 第 120-123 行
typedef struct packed {
  logic       valid;    // 有效标志
  idx_desc_t  idx;      // 描述符索引
} s_dma_str_in_t;
```

FSM 通过这个接口告诉 Streamer：
- `valid=1`: 有新的描述符需要处理
- `idx`: 要处理的描述符编号

### 10.2 Streamer -> FSM 接口

```systemverilog
// src/dma/inc/dma_pkg.svh, 第 125-127 行
typedef struct packed {
  logic       done;     // 完成标志
} s_dma_str_out_t;
```

Streamer 通过这个接口告诉 FSM：
- `done=1`: 当前描述符处理完成

### 10.3 握手时序

```
FSM -> Streamer:
  T0: dma_stream_rd_o = {valid=1, idx=0}
  T1: Streamer 开始处理 DESC0
  ...
  Tn: Streamer 处理完成

Streamer -> FSM:
  Tn: dma_stream_rd_i = {done=1}
  Tn+1: FSM 设置 rd_desc_done[0]=1
  Tn+1: FSM 调度下一个描述符
```

---

## 11. 与 AXI 接口的交互

### 11.1 axi_pend_txn_i 信号

```systemverilog
// src/dma/dma_axi_if.sv, 第 236-239 行
axi_pend_txn_o = dma_active_i &&
             ((|rd_counter_ff) || (|wr_counter_ff) ||
              dma_axi_rd_req_i.valid || dma_axi_wr_req_i.valid ||
              dma_miso_i.rvalid || dma_miso_i.bvalid || aw_txn_started_ff);
```

这个信号表示 AXI 接口仍有待处理的事务。FSM 在 RUN 状态时检查此信号：

```systemverilog
// src/dma/dma_fsm.sv, 第 76-79 行
DMA_ST_RUN: begin
  if (pending_desc || axi_pend_txn_i) begin
    next_st = DMA_ST_RUN;    // 还有工作
  end else begin
    next_st = DMA_ST_DONE;   // 所有完成
  end
end
```

### 11.2 为什么需要检查 axi_pend_txn？

```
场景: 所有描述符都已发送给 Streamer，但 AXI 事务还未完成

时间线:
  T0: FSM 发送 DESC0 给 Streamer
  T1: Streamer 计算突发参数，发送给 AXI-IF
  T2: AXI-IF 发出 AR 请求
  T3: AXI-IF 等待 R 响应
  T4: R 响应到达，数据写入 FIFO
  T5: AXI-IF 发出 AW+W 请求
  T6: 等待 B 响应
  T7: B 响应到达，事务完成

  在 T2-T7 期间:
    pending_desc = 0 (已全部发送)
    axi_pend_txn = 1 (AXI 事务进行中)
    FSM 保持 RUN 状态
```

---

## 12. 动手实验

### 实验 1: 状态转换追踪

在仿真中添加打印语句追踪状态转换：

```systemverilog
// 在 dma_fsm.sv 中添加
always_ff @(posedge clk) begin
  if (cur_st_ff != next_st) begin
    $display("[FSM] State transition: %s -> %s at time %0t",
             cur_st_ff.name(), next_st.name(), $time);
  end
end

always_ff @(posedge clk) begin
  if (dma_stream_rd_o.valid) begin
    $display("[FSM] Dispatching RD desc %0d at time %0t",
             dma_stream_rd_o.idx, $time);
  end
  if (dma_stream_wr_o.valid) begin
    $display("[FSM] Dispatching WR desc %0d at time %0t",
             dma_stream_wr_o.idx, $time);
  end
end
```

### 实验 2: Abort 测试

编写测试用例验证 Abort 行为：

```systemverilog
// 测试步骤:
// 1. 配置 DESC0 和 DESC1
// 2. 写入 go=1 启动 DMA
// 3. 等待 DESC0 开始传输 (RUN 状态)
// 4. 写入 abort=1
// 5. 验证:
//    - DESC0 完成当前事务后停止
//    - DESC1 未被处理
//    - STATUS.done = 1
//    - clear_dma_o 脉冲产生
// 6. 写入 go=0, abort=0
// 7. 验证 FSM 回到 IDLE
```

### 实验 3: 多描述符调度

尝试配置 4 个描述符（需要修改 `DMA_NUM_DESC=4`），验证调度顺序：

```systemverilog
// 配置:
// DESC0: src=0x1000, dst=0x2000, bytes=64, enable=1
// DESC1: src=0x3000, dst=0x4000, bytes=64, enable=1
// DESC2: src=0x5000, dst=0x6000, bytes=64, enable=0  (禁用)
// DESC3: src=0x7000, dst=0x8000, bytes=64, enable=1

// 预期调度顺序:
// 读: DESC0 -> DESC1 -> DESC3 (跳过 DESC2)
// 写: DESC0 -> DESC1 -> DESC3 (跳过 DESC2)
```

---

## 13. 设计要点与常见陷阱

### 13.1 索引锁存的必要性

```
错误设计 (无锁存):
  if (dma_stream_rd_i.done) begin
    next_rd_desc_done[dma_stream_rd_o.idx] = 1'b1;  // 错误!
  end

  问题: dma_stream_rd_o.idx 可能已经指向下一个描述符
```

```
正确设计 (有锁存):
  next_rd_idx = i;  // 在发送时锁存
  ...
  if (dma_stream_rd_i.done) begin
    next_rd_desc_done[rd_idx_ff] = 1'b1;  // 使用锁存的索引
  end
```

### 13.2 pending_desc 的计算时机

```
注意: pending_desc 在组合逻辑块中计算，使用当前周期的值

  pending_rd_desc = dma_stream_rd_o.valid;
  pending_wr_desc = dma_stream_wr_o.valid;
  pending_desc = pending_rd_desc || pending_wr_desc;

  如果所有描述符都已完成:
    dma_stream_rd_o.valid = 0 (没有需要处理的)
    pending_desc = 0
    FSM: RUN -> DONE
```

### 13.3 clear_dma_o 的单周期脉冲

```
clear_dma_o = (cur_st_ff == DMA_ST_DONE) && (next_st == DMA_ST_IDLE);

这个信号只在 DONE->IDLE 转换的那个周期为 1
它被用于清除 FIFO 和错误状态
```

---

## 14. 本讲要点总结

| 要点 | 说明 |
|------|------|
| 四状态设计 | IDLE -> CFG -> RUN -> DONE |
| CFG 状态 | 检查描述符有效性和 abort |
| RUN 状态 | 调度描述符给 Streamer，等待完成 |
| DONE 状态 | 保持直到 go=0 |
| 描述符调度 | 优先级编码，DESC0 优先 |
| 索引锁存 | rd_idx_ff/wr_idx_ff 用于正确跟踪完成 |
| 独立完成跟踪 | rd_desc_done_ff 和 wr_desc_done_ff 分开 |
| Abort 处理 | 停止新描述符调度，等待进行中事务 |
| clear_dma_o | DONE->IDLE 时产生脉冲，清除状态 |

---

## 15. 下节预告

后续讲座将覆盖：
- DMA Streamer 的突发参数计算
- 4KB 边界处理
- AXI 接口的 Outstanding 事务管理
- DMA 与 NPU 的协同工作
