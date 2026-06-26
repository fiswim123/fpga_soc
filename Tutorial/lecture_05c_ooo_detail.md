# Lecture 05c: AXI Crossbar深入（五）-- 乱序完成机制详解

## 课程概要

本讲深入分析 `axicb_slv_ooo.sv` -- Crossbar 中负责**乱序完成（Out-of-Order
Completion）**管理的核心模块。我们将完整追踪其三阶段流水线（Grab → Arbitrate →
Complete），理解 Per-ID FIFO 如何跟踪 Outstanding 事务，以及 misrouted 事务的
优先处理机制。这个模块是 Crossbar 吞吐量的关键保障。

---

## 1. 为什么需要乱序完成？

### 1.1 顺序完成的瓶颈

```
假设 CPU 和 DMA 同时发起读请求:

  顺序完成 (In-Order):
    T0: CPU 发请求 A → DDR (延迟 100 周期)
    T1: DMA 发请求 B → NPU LMEM (延迟 5 周期)
    T2~T100: 等待 A 完成...
    T101: 返回 A 的结果给 CPU
    T102: 返回 B 的结果给 DMA      ← DMA 被迫等了 100 周期!

  问题: DMA 的快请求被 CPU 的慢请求阻塞
  总延迟 = max(100, 5) = 100 周期
```

### 1.2 乱序完成的优势

```
  乱序完成 (Out-of-Order):
    T0: CPU 发请求 A → DDR
    T1: DMA 发请求 B → NPU LMEM
    T6: B 先完成, 立即返回给 DMA    ← DMA 不被阻塞!
    T101: A 完成, 返回给 CPU

  效果: 每个 Master 独立获得响应
  总吞吐量 = 各 Slave 带宽之和
```

### 1.3 OOO 模块的职责

```
文件: src/axi_crossbar/axicb_slv_ooo.sv

  axicb_slv_ooo 的核心职责:
    1. 记录每个 Outstanding 事务的目标 Slave 和 ID
    2. 当 Slave 返回响应时, 匹配正确的事务
    3. 支持乱序: 不同 ID 的响应可以不按发出顺序返回
    4. 处理 misrouted 事务 (优先级最高)
    5. 反压地址通道 (FIFO 满时阻止新事务)
```

---

## 2. 模块接口

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 13~66

module axicb_slv_ooo
    #(
        parameter RD_PATH = 0,           // 1=读路径, 0=写路径
        parameter AXI_ID_W = 8,          // ID 位宽
        parameter SLV_NB = 4,            // Slave 数量
        parameter MST_OSTDREQ_NUM = 4,   // 最大 Outstanding 数
        parameter [AXI_ID_W-1:0] MST_ID_MASK = 'h00,  // Master ID 掩码
        parameter CCH_W = 8              // 完成通道位宽
    )(

    // === 地址通道输入 (Stage 1 使用) ===
    input  wire              a_valid,     // 地址通道有效
    input  wire              a_ready,     // 地址通道就绪
    output logic             a_full,      // FIFO 满标志 (反压)
    input  wire  [7:0]       a_len,       // Burst 长度 (仅读)
    input  wire  [AXI_ID_W-1:0] a_id,    // 事务 ID
    input  wire  [SLV_NB-1:0]   a_ix,    // 目标 Slave (one-hot)
    input  wire              a_mr,        // Misroute 标志

    // === 授权接口 (Stage 2 → Stage 3) ===
    input  wire              c_en,        // 仲裁使能
    output logic [SLV_NB-1:0] c_grant,   // 授权的 Slave
    output logic             c_mr,        // Misroute 标志
    output logic [7:0]       c_len,       // 完成长度
    output logic [AXI_ID_W-1:0] c_id,    // 完成 ID

    // === 完成通道输入 (来自 Slave) ===
    input  wire  [SLV_NB-1:0]   c_valid, // 各 Slave 的完成有效
    input  wire              c_ready,     // 完成就绪
    input  wire  [CCH_W*SLV_NB-1:0] c_ch,// 完成通道数据
    input  wire              c_end        // 完成结束标志
);
```

---

## 3. FIFO 结构

### 3.1 FIFO 参数计算

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 72~75

    localparam OSTDREQ_NUM = (MST_OSTDREQ_NUM < 2) ? 1 : MST_OSTDREQ_NUM;
    localparam NB_ID       = OSTDREQ_NUM;           // FIFO 数量 = Outstanding 数
    localparam FIFO_DEPTH  = $clog2(OSTDREQ_NUM);   // 每个 FIFO 的深度
    localparam FIFO_WIDTH  = (RD_PATH) ? 8 + SLV_NB + 1 + AXI_ID_W
                                        : SLV_NB + 1 + AXI_ID_W;

示例 (MST_OSTDREQ_NUM=4, AXI_ID_W=8, SLV_NB=4):
  NB_ID = 4  (4 个 FIFO, 每个 ID 一个)
  FIFO_DEPTH = 2  (每个 FIFO 最深 4 条)
  FIFO_WIDTH:
    读路径: 8 + 4 + 1 + 8 = 21 bits
    写路径: 4 + 1 + 8 = 13 bits
```

### 3.2 FIFO 条目内容

```
FIFO 条目位域 (读路径, FIFO_WIDTH=21):

  Bit [20:13]  a_len[7:0]    Burst 长度 (仅读路径)
  Bit [12:9]   a_ix[3:0]     目标 Slave (one-hot)
  Bit [8]      a_mr          Misroute 标志
  Bit [7:0]    a_id[7:0]     原始事务 ID

FIFO 条目位域 (写路径, FIFO_WIDTH=13):

  Bit [12:9]   a_ix[3:0]     目标 Slave (one-hot)
  Bit [8]      a_mr          Misroute 标志
  Bit [7:0]    a_id[7:0]     原始事务 ID
```

### 3.3 Per-ID FIFO 结构

```
  每个 Outstanding ID 对应一个独立的 FIFO:

  ID=0 ──→ FIFO[0]: [事务属性, 事务属性, ...]
  ID=1 ──→ FIFO[1]: [事务属性, ...]
  ID=2 ──→ FIFO[2]: [事务属性, 事务属性, ...]
  ID=3 ──→ FIFO[3]: [事务属性]

  FIFO 条目按时间顺序排列 (最老的在前)
  → 保证同 ID 的事务按顺序完成
```

---

## 4. Stage 1: Grab (抓取)

### 4.1 功能描述

```
监听地址通道, 当 (a_valid & a_ready) 握手成功时:
  1. 计算 unmasked ID: a_id_m = a_id ^ MST_ID_MASK
  2. 将事务属性 push 到对应 ID 的 FIFO
  3. 如果 FIFO 满, 设置 a_full=1 反压地址通道
```

### 4.2 ID 去掩码

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 123

    always_comb a_id_m = a_id ^ MST_ID_MASK;

为什么需要 XOR？

  Crossbar 中每个 Master 的 ID 被加上掩码以区分来源:
    CPU  (MST0) 发出 ID=0x05, 实际传输 ID = 0x05 ^ 0x00 = 0x05
    DMA  (MST1) 发出 ID=0x05, 实际传输 ID = 0x05 ^ 0x10 = 0x15

  收到响应时, 需要用 XOR 还原出原始 ID:
    收到 ID=0x15, 还原: 0x15 ^ 0x10 = 0x05 → 原始 ID=5

  FIFO 索引用原始 ID (去掩码后), 所以:
    FIFO[5] 对应原始 ID=5 的事务
```

### 4.3 Push 逻辑

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 126~128

    for (genvar i=0; i<NB_ID; i++) begin: FIFOS_GEN
        assign push[i] = (a_id_m == i[0+:AXI_ID_W]) ? a_valid & a_ready : 1'b0;
    end

逻辑:
  - 遍历所有 FIFO
  - 只有 ID 匹配的那个 FIFO 被 push
  - push 条件: a_valid & a_ready (握手成功)
```

### 4.4 反压机制

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 158

    always_comb a_full = |id_full;

  - 任何一个 FIFO 满, a_full 就为 1
  - a_full 连接到地址通道的反压逻辑
  - 效果: 阻止新的地址握手, 直到有 FIFO 被 pull

反压链路:

  a_full=1 → 阻止 a_valid & a_ready → 阻止新事务
  → 上游 Master 看到 ready=0 → 暂停发送
```

---

## 5. Stage 2: Arbitrate (仲裁)

### 5.1 功能描述

```
当 Slave 返回完成响应时:
  1. 优先处理 misrouted 事务
  2. 遍历所有 ID FIFO, 找到与 Slave 完成匹配的 ID
  3. 使用 round-robin 公平选择一个 ID 进行完成
```

### 5.2 Misrouted 优先

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 152, 186~188

    // 检查每个 FIFO 的 misroute 标志
    assign mr_reqs[i] = (id_empty[i]) ? 1'b0 : fifo_out[i*FIFO_WIDTH+AXI_ID_W];

    // 仲裁逻辑: misrouted 优先
    if (|mr_reqs) begin
        c_reqs = mr_reqs;   // 只看 misrouted 的
    end else begin
        // ... 正常匹配逻辑
    end

为什么 misrouted 优先？
  - Misrouted 事务意味着路由错误, 需要尽快处理
  - 如果不优先处理, misrouted 事务会阻塞 FIFO
  - 优先处理可以释放 FIFO 空间, 避免反压
```

### 5.3 ID 匹配逻辑

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 192~203

    for (int i=0; i<NB_ID; i++) begin : CREQS
        c_reqs[i] = '0;
        for (int j=0; j<SLV_NB; j++) begin
            // 条件1: FIFO[i] 记录的目标 Slave 是 j
            if (fifo_out[i*FIFO_WIDTH+AXI_ID_W+1+j] && !id_empty[i] && c_valid[j])
                // 条件2: Slave j 返回的 ID 与 FIFO[i] 匹配
                if ((c_ch[j*CCH_W+:AXI_ID_W] ^ MST_ID_MASK) == i[0+:AXI_ID_W])
                    c_reqs[i] = c_valid[j];
        end
    end

匹配条件详解:
  1. fifo_out[...+1+j]: FIFO[i] 记录的目标 Slave 包含 Slave j
  2. !id_empty[i]: FIFO[i] 非空
  3. c_valid[j]: Slave j 有有效的完成响应
  4. (c_ch[...] ^ MST_ID_MASK) == i: Slave j 返回的 ID 还原后等于 FIFO[i] 的索引

只有四个条件同时满足, c_reqs[i] 才为 1。
```

### 5.4 Round-Robin 仲裁

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 209~221

    axicb_round_robin_core
    #(
        .REQ_NB  (NB_ID)
    )
    cch_round_robin (
        .aclk    (aclk),
        .aresetn (aresetn),
        .srst    (srst),
        .en      (c_en),
        .req     (c_reqs),     // 每个 ID FIFO 的匹配请求
        .grant   (id_grant)    // 授权的 ID (one-hot)
    );

  - c_reqs: 每个 bit 对应一个 ID FIFO, 1=该 FIFO 有可完成的事务
  - id_grant: one-hot 输出, 选中一个 ID FIFO
  - 使用 axicb_round_robin_core 做公平轮转
```

---

## 6. Stage 3: Complete (完成)

### 6.1 功能描述

```
根据仲裁结果:
  1. 从选中的 FIFO 中取出事务属性
  2. 将完成路由回正确的 Master
  3. Pull FIFO 条目 (释放空间)
```

### 6.2 FIFO 数据选择

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 224~233

    always_comb begin
        c_select = '0;
        c_empty = '0;
        for (int i=0; i<NB_ID; i++) begin
            if (id_grant[i]) begin
                c_select = fifo_out[i*FIFO_WIDTH +: FIFO_WIDTH];
                c_empty = id_empty[i];
            end
        end
    end

  - 用 id_grant (one-hot) 选择对应的 FIFO 输出
  - c_select 包含完整的事务属性
```

### 6.3 完成属性提取

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 309~316 (读路径)

    // 从 c_select 中提取各字段
    if (c_empty)
        {c_len, c_grant, c_mr, c_id} = '0;
    else
        {c_len, c_grant, c_mr, c_id} = c_select;

  c_len:   burst 长度 (仅读路径)
  c_grant: 目标 Slave (one-hot)
  c_mr:    misroute 标志
  c_id:    原始事务 ID
```

### 6.4 FIFO Pull

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 207

    assign pull = (c_end) ? id_grant : '0;

  - pull 只在 c_end 时有效
  - c_end = c_valid & c_ready & c_last (读) 或 c_valid & c_ready (写)
  - 确保 FIFO 条目在事务完全完成后才被释放
```

---

## 7. 单 Outstanding 简化

### 7.1 什么时候出现？

```
当 MST_OSTDREQ_NUM = 1 时:
  - 只有 1 个 Outstanding 事务
  - 不需要 FIFO (没有乱序的可能)
  - 用一个简单的 pipeline 寄存器替代
```

### 7.2 简化实现

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 102~109

    if (OSTDREQ_NUM==1) begin : NO_ID_FIFO
        assign fifo_in = '0;
        assign fifo_out = '0;
        assign id_full = '0;
        assign id_empty = '0;
        assign a_id_m = '0;
        assign mr_reqs = '0;
    end

  - 所有 FIFO 信号接地
  - 不需要匹配逻辑
  - 完成路径直接用 pipeline 寄存器
```

### 7.3 Pipeline 替代

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 249~306

    if (OSTDREQ_NUM==1) begin : NO_PATH_CPL
        // 用 pipeline 寄存器存储事务属性
        axicb_pipeline #(.DATA_BUS_W(PIPE_W), .NB_PIPELINE(1))
        rd_cpl_pipe_no_or (
            .i_valid (a_valid & a_ready),  // 事务发出时锁存
            .o_ready (c_end),              // 完成时释放
            .i_data  (pipe_in),            // {a_len, a_id, a_mr}
            .o_data  (pipe_out)            // 输出事务属性
        );

        // 完成时直接用唯一的 Slave 通道
        assign c_grant = c_valid;
    end

  - 无需仲裁 (只有一个事务)
  - 无需匹配 (完成直接返回)
  - 面积和延迟都大幅降低
```

---

## 8. 完整数据流示例

### 8.1 场景: CPU 和 DMA 同时发读请求

```
配置: MST_OSTDREQ_NUM=4, AXI_ID_W=8, SLV_NB=4, MST_ID_MASK=0x00

T0: CPU 发出 AR (ARID=0x03, 目标=DDR)
    a_valid=1, a_ready=1, a_id=0x03, a_ix=0001
    → a_id_m = 0x03 ^ 0x00 = 0x03
    → push[3] = 1
    → FIFO[3] = {a_len, a_ix=0001, a_mr=0, a_id=0x03}

T1: DMA 发出 AR (ARID=0x05, 目标=NPU LMEM)
    a_valid=1, a_ready=1, a_id=0x05, a_ix=0010
    → a_id_m = 0x05 ^ 0x00 = 0x05
    → push[5] = 1
    → FIFO[5] = {a_len, a_ix=0010, a_mr=0, a_id=0x05}

T6: NPU LMEM 返回完成 (RVALID=1, RID=0x05)
    c_valid = 0010 (Slave 1 有效)
    c_ch[1] 的 ID = 0x05

    仲裁:
    遍历 FIFO:
      FIFO[3]: a_ix=0001, 但 Slave 1 的 ID=0x05, (0x05^0x00)==3? 否
      FIFO[5]: a_ix=0010, Slave 1 有效, (0x05^0x00)==5? 是!
    → c_reqs = 00100000 (bit5)
    → id_grant = 00100000

    完成:
    c_select = FIFO[5] 的内容
    c_grant = 0010, c_id = 0x05
    pull[5] = 1 (c_end 时)

T7: FIFO[5] 被清空, DMA 收到读数据

T101: DDR 返回完成 (RVALID=1, RID=0x03)
    c_valid = 0001 (Slave 0 有效)
    c_ch[0] 的 ID = 0x03

    仲裁:
    FIFO[3]: a_ix=0001, Slave 0 有效, (0x03^0x00)==3? 是!
    → c_reqs = 00001000 (bit3)
    → id_grant = 00001000

    完成:
    c_grant = 0001, c_id = 0x03
    pull[3] = 1

T102: FIFO[3] 被清空, CPU 收到读数据
```

---

## 9. 设计视角

### 9.1 WHY: 为什么需要乱序完成？

```text
问题: 为什么不按请求顺序返回响应？

场景分析:
  CPU 访问 DDR (慢, 100 周期)
  DMA 访问 NPU LMEM (快, 5 周期)

  如果强制顺序完成:
    - DMA 必须等 CPU 的 100 周期
    - 总吞吐量 = min(各 Slave 带宽) = 最慢 Slave 的带宽
    - DMA 的带宽被浪费

  如果允许乱序完成:
    - DMA 的 5 周期响应立即返回
    - CPU 的 100 周期响应稍后返回
    - 总吞吐量 = sum(各 Slave 带宽)
    - 每个 Master 独立享受带宽
```

### 9.2 HOW: 如何跟踪多个 Outstanding 事务？

```text
核心挑战: 同时有多个未完成的事务, 如何知道每个响应对应哪个事务？

解决方案: Per-ID FIFO 追踪

  1. 事务发出时 (Grab):
     - 用事务 ID 作为 FIFO 索引
     - 将事务属性 (目标 Slave, misroute 标志) push 到 FIFO
     - FIFO 保证同 ID 的事务按顺序排列

  2. 响应返回时 (Arbitrate):
     - 遍历所有 FIFO
     - 检查: FIFO 记录的目标 Slave 是否与响应的来源匹配
     - 检查: FIFO 记录的 ID 是否与响应的 ID 匹配
     - 用 round-robin 在多个匹配的 FIFO 间公平选择

  3. 完成时 (Complete):
     - 从选中的 FIFO 中取出事务属性
     - 将响应路由回正确的 Master
     - Pull FIFO 条目, 释放空间
```

### 9.3 PATTERN: Per-ID FIFO 追踪模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Per-ID FIFO 追踪 (Per-ID FIFO Tracking)       │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   为每个可能的事务ID分配一个独立的FIFO，                    │
│   用FIFO记录每个Outstanding事务的目标和状态，               │
│   当响应返回时，通过ID查找对应的FIFO条目。                  │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 事务发出时：根据ID将事务信息push到对应FIFO             │
│   2. 响应返回时：用ID查找FIFO，取出事务信息                 │
│   3. 用round-robin在多个就绪的FIFO间公平选择               │
│   4. FIFO满时反压地址通道（防止事务丢失）                   │
│                                                         │
│   FIFO条目内容：                                         │
│     - 原始事务ID                                         │
│     - 目标Slave（one-hot）                                │
│     - 误路由标志                                         │
│     - burst长度（仅读路径）                               │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axicb_slv_ooo.sv:                                     │
│     每个Master的每个ID对应一个FIFO                         │
│     三阶段流水线：抓取→仲裁→完成                           │
│     支持乱序完成：不同ID的响应可以不按发出顺序返回           │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要跟踪Outstanding事务的互连                     │
│   - 内存控制器的请求队列                                  │
│   - 网络路由器的包追踪                                    │
│   - 多线程处理器的指令窗口                                │
│   - DMA引擎的描述符队列                                  │
└─────────────────────────────────────────────────────────┘
```

---

## 10. 读路径与写路径的差异

### 10.1 参数差异

```
RD_PATH = 1 (读完成路径):
  - 需要存储 burst 长度 (ALEN = 8 bits)
  - FIFO_WIDTH = 8 + SLV_NB + 1 + AXI_ID_W
  - 完成时需要跟踪多个 beat (RVALID & RREADY & RLAST)

RD_PATH = 0 (写完成路径):
  - 不需要 burst 长度 (写完成只有单拍 BRESP)
  - FIFO_WIDTH = SLV_NB + 1 + AXI_ID_W
  - 完成更简单 (单拍)
```

### 10.2 FIFO 输入差异

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 116~119

    if (RD_PATH) begin : IN_RD_PATH_FIFO
        always_comb fifo_in = {a_len, a_ix, a_mr, a_id};
    end else begin: IN_WR_PATH_FIFO
        always_comb fifo_in = {a_ix, a_mr, a_id};
    end
```

### 10.3 完成路径差异

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 309~328

读路径:
    {c_len, c_grant, c_mr, c_id} = c_select;
    // c_len 用于跟踪 burst 的每个 beat

写路径:
    {c_grant, c_mr, c_id} = c_select;
    c_len = '0;  // 写完成不需要长度
```

---

## 11. 面积与性能分析

### 11.1 面积估算

```
MST_OSTDREQ_NUM=4, AXI_ID_W=8, SLV_NB=4:

  FIFO 数量: 4
  每个 FIFO 深度: 2 (clog2(4))
  每个 FIFO 宽度: 21 bits (读) 或 13 bits (写)

  总存储: 4 × 4 × 21 = 336 bits (读路径)
          4 × 4 × 13 = 208 bits (写路径)

  加上控制逻辑: ~500 gates
  总面积: ~1000 gates (很小)
```

### 11.2 延迟分析

```
Stage 1 (Grab): 1 个时钟周期 (FIFO push)
Stage 2 (Arbitrate): 1 个时钟周期 (round-robin + 匹配)
Stage 3 (Complete): 1 个时钟周期 (FIFO pull + 输出)

总延迟: 3 个时钟周期 (从地址握手到完成输出)

但注意: 这是流水线延迟, 不是吞吐量限制。
每个周期都可以处理一个新的事务 (流水线满载时)。
```

---

## 12. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| 三阶段流水线 | Grab → Arbitrate → Complete |
| Per-ID FIFO | 每个 Outstanding ID 一个 FIFO, 追踪事务属性 |
| ID 去掩码 | a_id ^ MST_ID_MASK 还原原始 ID 作为 FIFO 索引 |
| Misroute 优先 | misrouted 事务优先于正常事务处理 |
| Round-Robin 仲裁 | 多个 ID FIFO 匹配时, 用 RR 公平选择 |
| 反压机制 | 任一 FIFO 满时阻止新事务 |
| 单 Outstanding 简化 | OSTDREQ_NUM=1 时用 pipeline 替代 FIFO |
| 读/写路径差异 | 读路径多存 8bit burst 长度 |

---

## 13. 动手练习

### 练习 1: FIFO 条目追踪

给定配置: `MST_OSTDREQ_NUM=4, AXI_ID_W=8, SLV_NB=4, MST_ID_MASK=0x10`

```
T0: MST1 发出 AR (ARID=0x15, 目标=SLV0)
T1: MST1 发出 AR (ARID=0x16, 目标=SLV1)
T2: MST0 发出 AR (ARID=0x05, 目标=SLV0)
```

请写出:
1. 每个 FIFO 的 push 信号和内容
2. a_full 的值 (假设 FIFO 深度=2)

### 练习 2: 匹配逻辑追踪

沿用练习 1 的状态, 假设:
```
T10: SLV0 返回完成 (RVALID=1, RID=0x15)
T11: SLV1 返回完成 (RVALID=1, RID=0x16)
```

请写出:
1. c_reqs 的值 (哪些 FIFO 匹配)
2. id_grant 的值 (哪个 FIFO 被选中)
3. c_grant, c_id 的值 (完成输出)

### 练习 3: Misroute 处理

假设 FIFO[2] 的 a_mr=1 (misrouted), FIFO[5] 的 a_mr=0。
两个 FIFO 都有匹配的完成响应。

1. 哪个 FIFO 会优先被处理？为什么？
2. 如果没有 misroute 优先机制, 会有什么问题？

### 练习 4: Outstanding 深度计算

```
配置: MST_OSTDREQ_NUM=8, AXI_ID_W=8, SLV_NB=4
```

计算:
1. FIFO 数量和每个 FIFO 的深度
2. 总存储容量 (bits)
3. 如果 DDR 延迟=50 周期, CPU 发 8 个 Outstanding 读请求, 理论带宽利用率
4. 与 MST_OSTDREQ_NUM=1 相比, 带宽提升多少？

### 练习 5: 代码修改 -- 同 ID 顺序完成

当前设计中, 同 ID 的事务通过 FIFO 保证顺序完成。
如果去掉 FIFO, 改用一个简单的计数器跟踪每个 ID 的 Outstanding 数量:

1. 这样做的优点是什么？(提示: 面积)
2. 缺点是什么？(提示: 乱序能力)
3. 在什么场景下这种简化是可接受的？

---

## 14. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_slv_ooo.sv` | 乱序完成管理器 (336 行) |
| `src/axi_crossbar/axicb_round_robin_core.sv` | RR 仲裁核心 (OOO 内部使用) |
| `src/axi_crossbar/axicb_scfifo.sv` | 同步 FIFO (OOO 内部使用) |
| `src/axi_crossbar/axicb_pipeline.sv` | Pipeline (单 OR 简化路径使用) |
| `src/soc_top.sv` | Outstanding 参数配置 |
