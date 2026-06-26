# Lecture 05: AXI Crossbar（二）-- 仲裁器与乱序完成

## 课程概要

本讲是 AXI Crossbar 三部曲的第二篇，深入分析 Crossbar 内部的**仲裁机制**和
**乱序完成（Out-of-Order Completion）**管理。我们将详细解读 `axicb_round_robin.sv`
和 `axicb_slv_ooo.sv`，理解多 Master 竞争同一 Slave 时如何公平仲裁，
以及 Outstanding 事务如何被正确地按 ID 排序返回。

---

## 1. 为什么需要仲裁器？

### 1.1 冲突场景

在 4x4 Crossbar 中，当多个 Master 同时请求同一个 Slave 时，必须由仲裁器决定
谁先获得访问权：

```
  CPU (MST0)  ──┐
                ├──→ 仲裁器  ──→  DDR (SLV0)
  DMA (MST1)  ──┘         ↑
                          │
                    同一时刻只能选一个
```

### 1.2 仲裁的两个维度

```
维度 1: 跨 Master 仲裁（谁先发请求？）
  → axicb_slv_switch_wr / axicb_slv_switch_rd 中的仲裁器

维度 2: 跨 Slave 响应排序（响应按什么顺序返回？）
  → axicb_slv_ooo 中的乱序完成管理器
```

---

## 1.1+ 设计视角：为什么这样设计？

仲裁器是Crossbar中最关键的调度组件，其设计直接影响系统的公平性和吞吐量。

### 核心设计决策

#### 决策1：为什么选择Round-Robin而非固定优先级？

```text
问题：多个Master同时请求同一个Slave时，如何决定谁先获得访问？

方案A：固定优先级（Fixed Priority）
  - 每个Master有固定的优先级（如CPU > DMA > 外设）
  - 高优先级Master总是先获得访问
  - 优点：实现简单，延迟确定
  - 缺点：低优先级Master可能永远得不到服务（饥饿）

方案B：纯Round-Robin（Pure Round-Robin）
  - 所有Master平等，轮流获得访问
  - 优点：绝对公平，无饥饿
  - 缺点：无法区分紧急和非紧急请求

方案C：优先级 + Round-Robin（本项目选择）
  - 将Master分到不同优先级桶（P0~P3）
  - 高优先级桶优先服务
  - 同一桶内的Master用Round-Robin公平轮转
  - 优点：兼顾公平和优先级
  - 缺点：实现复杂度最高
```

**选择理由**：

| 对比维度 | 方案A：固定优先级 | 方案B：纯Round-Robin | 方案C：优先级+RR |
|----------|----------------|-------------------|----------------|
| 公平性 | 差（可能饥饿） | 好（绝对公平） | 好（桶内公平） |
| 优先级支持 | 好 | 无 | 好 |
| 实现复杂度 | 低 | 中 | 高 |
| 吞吐量 | 中 | 高 | 高 |
| 典型应用 | 简单嵌入式 | 通用互连 | 高性能SoC |

#### 决策2：为什么需要Out-of-Order完成？

```text
问题：为什么不能按请求顺序返回响应？

场景：CPU和DMA同时访问不同Slave

  按序完成（In-Order）：
    CPU发请求A → DDR（慢，100周期）
    DMA发请求B → NPU LMEM（快，5周期）

    必须等A完成才能返回B的结果！
    → DMA被CPU的慢请求阻塞
    → 总吞吐量受限于最慢的Slave

  乱序完成（Out-of-Order，本项目选择）：
    CPU发请求A → DDR（慢）
    DMA发请求B → NPU LMEM（快）

    B先完成，立即返回给DMA！
    A完成后，再返回给CPU
    → 每个Master独立获得响应
    → 总吞吐量 = 各Slave带宽之和
```

#### 决策3：为什么用Mask算法实现Round-Robin？

```text
问题：如何高效实现公平轮转？

方案A：计数器法
  - 用一个计数器记录上次服务的Master
  - 下次从计数器+1开始查找
  - 优点：实现简单
  - 缺点：需要遍历所有请求，延迟随Master数增大

方案B：Mask法（本项目选择）
  - 用一个动态mask标记已服务的Master
  - 先在mask范围内查找，找不到再回退
  - 优点：查找延迟固定，不随Master数增大
  - 缺点：需要额外的mask寄存器

方案C：轮转优先级编码器
  - 每个周期旋转优先级
  - 优点：组合逻辑实现，无状态
  - 缺点：面积随Master数平方增长
```

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    仲裁器设计约束                         │
├───────────────┬─────────────────────────────────────────┤
│ 公平性约束     │ 同优先级的Master必须获得平等服务机会       │
│ 无饥饿约束     │ 任何Master都不能被无限期推迟              │
│ 延迟约束       │ 仲裁决策必须在1个周期内完成               │
│ 优先级约束     │ 高优先级请求必须优先于低优先级             │
│ 面积约束       │ 仲裁器面积应与Master数量成线性关系        │
│ 时序约束       │ 关键路径不能经过太多级逻辑                │
└───────────────┴─────────────────────────────────────────┘
```

---

## 1.2+ 设计视角：如何从零开始设计？

设计一个公平仲裁器，需要理解其核心算法。

### Step 1：确定仲裁策略

```text
输入：系统需求

分析：
  - 本项目有4个Master（CPU、DMA、预留×2）
  - CPU和DMA需要平等访问DDR
  - 预留端口未使用，优先级最低

决策：
  - 使用优先级+Round-Robin策略
  - CPU和DMA分配到同一优先级桶（P0）
  - 预留端口分配到低优先级桶（P1）
  - 同桶内用Round-Robin公平轮转
```

### Step 2：设计Mask算法

```text
核心思想：用一个bitmask标记"已服务"的请求

  初始状态：mask = 4'b1111（所有请求都可服务）

  服务req0后：mask = 4'b1110（mask掉bit0）
    → 下次优先服务req1、req2、req3

  服务req1后：mask = 4'b1100（mask掉bit0~1）
    → 下次优先服务req2、req3

  服务req3后：mask = 4'b1111（重置，从头开始）

  关键：如果mask范围内没有匹配的请求，用未mask的请求回退
```

### Step 3：实现优先级分层

```text
将4个请求分配到4个优先级桶：

  req_p0 = (PRIORITY==0) ? req : 0  // 最低优先级
  req_p1 = (PRIORITY==1) ? req : 0
  req_p2 = (PRIORITY==2) ? req : 0
  req_p3 = (PRIORITY==3) ? req : 0  // 最高优先级

优先级激活逻辑（高优先级屏蔽低优先级）：
  p3_active = |req_p3
  p2_active = |req_p2 & ~p3_active
  p1_active = |req_p1 & ~p2_active
  p0_active = |req_p0 & ~p1_active

最终grant选择：
  grant = p3_active ? grant_p3 :
          p2_active ? grant_p2 :
          p1_active ? grant_p1 :
                      grant_p0
```

### Step 4：集成到Crossbar

```text
每个Slave端口需要独立的仲裁器：

  SLV0仲裁器：处理所有请求DDR的Master
    - 输入：哪些Master正在请求DDR
    - 输出：哪个Master获得DDR的访问权

  SLV1仲裁器：处理所有请求NPU LMEM的Master
    - 输入：哪些Master正在请求NPU LMEM
    - 输出：哪个Master获得NPU LMEM的访问权

  ...以此类推

每个仲裁器独立运行，互不影响。
```

---

## 1.3+ 设计视角：架构模式与原则

仲裁器设计中蕴含了两个核心算法模式。

### 模式1：Mask-based Round-Robin 模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Mask-based Round-Robin (掩码轮转仲裁)          │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   使用动态bitmask记录"已服务"的请求者，                    │
│   优先在mask范围内查找下一个请求者，                       │
│   如果mask范围内无匹配，则回退到全范围查找。               │
│   每次服务后更新mask，实现公平轮转。                       │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   // 步骤1: 对请求施加mask                                │
│   masked = mask & req;                                   │
│                                                         │
│   // 步骤2: 在masked中找第一个active的                    │
│   if (|masked) begin                                    │
│     grant = first_one(masked);  // 优先级编码器           │
│   end else begin                                        │
│     grant = first_one(req);     // 回退到全范围           │
│   end                                                   │
│                                                         │
│   // 步骤3: 更新mask                                     │
│   if (grant完成) begin                                   │
│     mask <= ~((grant << 1) - 1);  // mask掉已服务的      │
│   end                                                   │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axicb_round_robin_core.sv:                            │
│     4位宽度，支持4个请求者                                 │
│     mask在每次有效grant后更新                              │
│     mask全为0时重置为全1（新一轮轮转）                     │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要公平轮转的仲裁场景                            │
│   - 内存控制器的Bank仲裁                                  │
│   - 网络交换机的端口调度                                  │
│   - 处理器的线程调度                                      │
│   - DMA引擎的通道仲裁                                    │
└─────────────────────────────────────────────────────────┘
```

### 模式2：Per-ID FIFO 追踪模式 (Per-ID FIFO Tracking)

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

## 2. Round-Robin 仲裁器架构

### 2.1 两级结构

仲裁器分为两层：外层是带优先级的调度器，内层是公平轮转核心。

```
文件: src/axi_crossbar/axicb_round_robin.sv

axicb_round_robin (顶层仲裁器)
  │
  ├── 优先级分层: 将请求按优先级分到 P0 ~ P3 四个桶
  │
  ├── 4x axicb_round_robin_core (每桶一个轮转核心)
  │     rr_p0 : 优先级 0 的请求做 round-robin
  │     rr_p1 : 优先级 1 的请求做 round-robin
  │     rr_p2 : 优先级 2 的请求做 round-robin
  │     rr_p3 : 优先级 3 的请求做 round-robin
  │
  └── 最终输出: 高优先级桶优先，桶内公平轮转
```

### 2.2 优先级分发逻辑

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 52~70

    // 将请求按优先级分配到对应桶
    assign req_p0[0] = (REQ0_PRIORITY==0) ? req[0] : 1'b0;
    assign req_p0[1] = (REQ1_PRIORITY==0) ? req[1] : 1'b0;
    assign req_p0[2] = (REQ2_PRIORITY==0) ? req[2] : 1'b0;
    assign req_p0[3] = (REQ3_PRIORITY==0) ? req[3] : 1'b0;

    assign req_p1[0] = (REQ0_PRIORITY==1) ? req[0] : 1'b0;
    // ... 类推到 req_p3
```

**优先级激活逻辑**（行 72~76）：
```
    assign p3_active = |req_p3;                          // P3 有请求？
    assign p2_active = |req_p2 & ~p3_active;             // P2 有请求且 P3 无
    assign p1_active = |req_p1 & ~p2_active;             // P1 有请求且 P2 无
    assign p0_active = |req_p0 & ~p1_active;             // P0 有请求且 P1 无
```

这意味着：**高优先级桶会完全屏蔽低优先级桶**。

### 2.3 最终 grant 选择

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 167~170

    assign grant = (|grant_p3) ? grant_p3 :    // P3 最高
                   (|grant_p2) ? grant_p2 :    // P2 次之
                   (|grant_p1) ? grant_p1 :    // P1 再次
                                 grant_p0 ;    // P0 最低
```

---

## 3. Round-Robin Core 的 Mask 算法

### 3.1 核心思想

`axicb_round_robin_core` 使用 **Masked Round-Robin** 算法，
通过一个动态 mask 实现公平轮转：

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 7~65
（注释中的算法说明）

    req    mask  grant  next-mask
    1111   1111   0001    1110     ← 从 req0 开始
    1111   1110   0010    1100     ← 下一个轮到 req1
    1111   1100   0100    1000     ← 再下一个 req2
    1111   1000   1000    1111     ← req3 之后 mask 重置
    1111   1111   0001    1110     ← 重新从 req0 开始
```

### 3.2 4 位宽度的具体实现

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 174~218 (REQ_NB==4 分支)

    // 步骤 1: 对请求施加 mask
    masked = mask & req;

    // 步骤 2: 在 masked 中找第一个 active 的（优先服务 mask 内的）
    if (|masked) begin
        if      (masked[0]) grant_c = 4'd1;
        else if (masked[1]) grant_c = 4'd2;
        else if (masked[2]) grant_c = 4'd4;
        else if (masked[3]) grant_c = 4'd8;
        else                grant_c = '0;
    // 步骤 3: 如果 mask 内没有匹配，用未 mask 的请求（回退）
    end else begin
        if      (req[0]) grant_c = 4'd1;
        else if (req[1]) grant_c = 4'd2;
        else if (req[2]) grant_c = 4'd4;
        else if (req[3]) grant_c = 4'd8;
        else             grant_c = '0;
    end
```

### 3.3 Mask 更新逻辑

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 203~218

    // Mask 在每次有效 grant 后更新
    if (en && |grant) begin
        if      (grant[0]) mask <= 4'b1110;  // 已服务 req0，mask 掉 bit0
        else if (grant[1]) mask <= 4'b1100;  // 已服务 req1，mask 掉 bit0~1
        else if (grant[2]) mask <= 4'b1000;  // 已服务 req2，mask 掉 bit0~2
        else if (grant[3]) mask <= '1;       // 已服务 req3，mask 重置（全1）
    end
```

### 3.4 Mask 算法图解

```
时间  req    mask   masked  grant   next_mask  说明
──── ────  ─────  ──────  ─────   ─────────  ──────────────
T0   0101  1111   0101    0001    1110       req0 先服务
T1   0101  1110   0100    0100    1000       mask 跳过 req0，服务 req2
T2   0110  1000   0000    0010    1100       mask 内无匹配，回退服务 req1
T3   1111  1100   1100    0100    1000       正常轮转到 req2
T4   1111  1000   1000    1000    1111       req3，之后 mask 重置
T5   1111  1111   1111    0001    1110       重新从 req0 开始

观察: 每个 req 都获得了公平的服务机会！
```

### 3.5 优先级 + 轮转的组合效果

```
场景: REQ2_PRIORITY=2, 其他=0

  req    mask   grant   说明
  ────  ─────  ─────   ──────────────────────
  1111  1111   0100    P2 桶有 req2，优先服务
  1011  1111   0001    P2 无请求，P0 桶轮转到 req0
  1011  1110   0010    P2 无请求，P0 桶轮转到 req1
  1111  1100   0100    P2 有 req2，再次优先服务
  1011  1100   1000    P2 无请求，P0 桶轮转到 req3
```

---

## 4. 乱序完成管理器 (axicb_slv_ooo)

### 4.1 问题描述

AXI 协议允许**乱序完成**：后发出的请求可以先返回。这在以下场景中很常见：

```
  CPU 发出:
    TXN_A (ID=0) → 访问 DDR（慢，100 周期）
    TXN_B (ID=1) → 访问 NPU LMEM（快，5 周期）

  如果 TXN_B 先完成返回，这就是"乱序完成"
```

但是，Crossbar 的 Slave 端口需要知道：**这个响应应该路由回哪个 Master？**

### 4.2 OOO 模块的角色

```
文件: src/axi_crossbar/axicb_slv_ooo.sv

axicb_slv_ooo 的职责:
  1. 跟踪每个 Outstanding 事务的目标 Slave 和 ID
  2. 当 Slave 返回响应时，正确匹配并路由
  3. 处理"误路由"（misrouted）的响应
  4. 使用 round-robin 公平调度多个 ID 的完成
```

### 4.3 内部 FIFO 结构

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 72~75

    localparam OSTDREQ_NUM = (MST_OSTDREQ_NUM < 2) ? 1 : MST_OSTDREQ_NUM;
    localparam NB_ID       = OSTDREQ_NUM;
    localparam FIFO_DEPTH  = $clog2(OSTDREQ_NUM);
    localparam FIFO_WIDTH  = (RD_PATH) ? 8 + SLV_NB + 1 + AXI_ID_W
                                        : SLV_NB + 1 + AXI_ID_W;
```

每个 Outstanding ID 对应一个 FIFO，存储以下信息：

```
FIFO 条目内容:
┌─────────────────────────────────────────────────────┐
│ [AXI_ID_W-1:0]              a_id    原始事务 ID     │
│ [AXI_ID_W]                  a_mr    误路由标志      │
│ [AXI_ID_W+1 : AXI_ID_W+SLV_NB]  a_ix  目标 Slave (one-hot) │
│ (仅读路径) [AXI_ID_W+SLV_NB+1 : +8]  a_len  burst 长度    │
└─────────────────────────────────────────────────────┘
```

### 4.4 三阶段流水线

OOO 模块内部有三个处理阶段：

```
阶段 1: 抓取（Grab）
─────────────────────
  监听地址通道，当 (a_valid & a_ready) 时:
  1. 计算 a_id_m = a_id ^ MST_ID_MASK（去掩码得到 FIFO 索引）
  2. 将事务信息 push 到对应 ID 的 FIFO
  3. 如果 FIFO 满，设置 a_full=1 反压地址通道

文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 116~158

    // 去掩码
    always_comb a_id_m = a_id ^ MST_ID_MASK;

    // 按 ID 索引 push 到对应 FIFO
    for (genvar i=0; i<NB_ID; i++) begin: FIFOS_GEN
        assign push[i] = (a_id_m == i[0+:AXI_ID_W]) ? a_valid & a_ready : 1'b0;
        // ... FIFO 实例化
    end

    // 任一 FIFO 满则反压
    always_comb a_full = |id_full;
```

```
阶段 2: 仲裁（Arbitrate）
──────────────────────────
  当 Slave 返回完成响应时:
  1. 优先处理"误路由"（misrouted）事务
  2. 正常情况：遍历所有 ID FIFO，找到与 Slave 完成匹配的 ID
  3. 使用 round-robin 公平选择一个 ID 进行完成

文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 183~221

    // 优先处理误路由
    if (|mr_reqs) begin
        c_reqs = mr_reqs;
    end else begin
        // 遍历 ID FIFO，匹配 Slave 完成通道
        for (int i=0; i<NB_ID; i++) begin : CREQS
            c_reqs[i] = '0;
            for (int j=0; j<SLV_NB; j++) begin
                if (fifo_out[i*FIFO_WIDTH+AXI_ID_W+1+j] && !id_empty[i] && c_valid[j])
                    if ((c_ch[j*CCH_W+:AXI_ID_W] ^ MST_ID_MASK) == i[0+:AXI_ID_W])
                        c_reqs[i] = c_valid[j];
            end
        end
    end

    // Round-robin 仲裁
    axicb_round_robin_core #(.REQ_NB(NB_ID))
    cch_round_robin (
        .aclk(aclk), .aresetn(aresetn), .srst(srst),
        .en(c_en), .req(c_reqs), .grant(id_grant)
    );
```

```
阶段 3: 完成（Complete）
─────────────────────────
  根据仲裁结果:
  1. 从 FIFO 中取出事务属性
  2. 将完成路由回正确的 Master
  3. pull FIFO 条目

文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 224~235

    // 从 grant 的 FIFO 中选择数据
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

    // 完成时 pull FIFO
    assign pull = (c_end) ? id_grant : '0;
```

### 4.5 单 Outstanding 简化路径

当 `MST_OSTDREQ_NUM=1` 时，OOO 模块大幅简化：

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 102~109, 249~306

    // 只有一个 Outstanding，不需要 FIFO
    if (OSTDREQ_NUM==1) begin : NO_ID_FIFO
        assign fifo_in = '0;
        assign fifo_out = '0;
        assign id_full = '0;
        assign id_empty = '0;
        assign a_id_m = '0;
        assign mr_reqs = '0;
    end

    // 完成路径用一个简单 pipeline 寄存器
    axicb_pipeline #(.DATA_BUS_W(PIPE_W), .NB_PIPELINE(1))
    rd_cpl_pipe_no_or (
        .i_valid(a_valid & a_ready),  // 事务发出时锁存
        .o_ready(c_end),              // 完成时释放
        // ...
    );
```

---

## 5. Outstanding 事务管理

### 5.1 什么是 Outstanding？

```
非 Outstanding（阻塞式）:
  T0: CPU 发请求 A
  T1: 等待...
  T2: 收到响应 A
  T3: CPU 发请求 B          ← 必须等 A 完成才能发 B
  T4: 等待...
  T5: 收到响应 B

Outstanding（流水线式）:
  T0: CPU 发请求 A
  T1: CPU 发请求 B          ← 不等 A 完成就发 B
  T2: CPU 发请求 C          ← 连续发出
  T3: 收到响应 A
  T4: 收到响应 B
  T5: 收到响应 C

  总时间: 6 周期 vs 非 Outstanding 的 6 周期（但延迟隐藏了！）
```

### 5.2 本项目的 Outstanding 配置

```
文件: src/soc_top.sv, 行 496~503

    .MST0_OSTDREQ_NUM(4),   // CPU:   最多 4 个 Outstanding
    .MST1_OSTDREQ_NUM(4),   // DMA:   最多 4 个 Outstanding
    .MST2_OSTDREQ_NUM(1),   // 外部2: 最多 1 个 Outstanding
    .MST3_OSTDREQ_NUM(1),   // 外部3: 最多 1 个 Outstanding

    .SLV0_OSTDREQ_NUM(4),   // DDR:   最多缓存 4 个请求
    .SLV1_OSTDREQ_NUM(4),   // LMEM:  最多缓存 4 个请求
    .SLV2_OSTDREQ_NUM(4),   // DMA CSR: 最多缓存 4 个请求
    .SLV3_OSTDREQ_NUM(4),   // NPU CSR: 最多缓存 4 个请求
```

### 5.3 Outstanding 与 FIFO 深度的关系

OOO 模块中的 FIFO 深度 = `MST_OSTDREQ_NUM`：

```
MST0_OSTDREQ_NUM = 4
  → OOO 中有 4 个 FIFO（每个 ID 一个）
  → 每个 FIFO 深度 = log2(4) = 2
  → 最多跟踪 4 个同时未完成的事务
```

---

## 6. 误路由（Misroute）处理

### 6.1 什么是误路由？

当一个请求被路由到错误的 Slave（例如地址重叠区域），或者 Slave 需要
将响应转发到非预期的 Master 时，就会发生误路由。

### 6.2 误路由标志

```
文件: src/axi_crossbar/axicb_slv_ooo.sv, 行 152

    // FIFO 中的误路由标志位
    assign mr_reqs[i] = (id_empty[i]) ? 1'b0 : fifo_out[i*FIFO_WIDTH+AXI_ID_W];
```

当 `mr_reqs` 非零时，OOO 模块优先处理这些误路由事务（行 186~188），
确保它们不会阻塞正常的数据通路。

---

## 7. 写通道与读通道的差异

OOO 模块通过 `RD_PATH` 参数区分读/写路径：

```
RD_PATH = 1 (读完成路径):
  - 需要存储 burst 长度 (ALEN=8bit)
  - FIFO_WIDTH = 8 + SLV_NB + 1 + AXI_ID_W
  - 完成时需要跟踪多个 beat

RD_PATH = 0 (写完成路径):
  - 不需要 burst 长度（写完成只有单拍 BRESP）
  - FIFO_WIDTH = SLV_NB + 1 + AXI_ID_W
  - 完成更简单
```

---

## 8. 完整仲裁流程示例

### 场景: CPU 和 DMA 同时请求 DDR

```
时间线:

T0: CPU 发出 AR (ARADDR=0x4000_0000, ARID=0x05)
    DMA 发出 AR (ARADDR=0x4000_1000, ARID=0x03)

    地址解码: 两个都命中 SLV0 (DDR)
    → 触发仲裁

    仲裁器 (MST0_PRIORITY=0, MST1_PRIORITY=0, 同优先级):
    mask 初始 = 4'b1111
    req = 4'b0011 (MST0 和 MST1 都在请求)
    masked = 4'b0011
    → grant_c = 4'b0001 (MST0 胜出)

T1: CPU 的读请求送达 DDR
    DMA 等待...
    mask 更新为 4'b1110

T2: DDR 返回 CPU 的第一个 beat
    DMA 继续等待...

T5: CPU 读完成
    DMA 的 mask 中 req[1] 被允许
    → grant_c = 4'b0010 (DMA 胜出)

T6: DMA 的读请求送达 DDR
    mask 更新为 4'b1100
```

---

## 9. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| 两级仲裁 | 优先级分层 + 桶内 Round-Robin |
| Mask 算法 | 动态 mask 实现公平轮转，跳过已服务的请求 |
| 优先级屏蔽 | 高优先级桶完全屏蔽低优先级桶 |
| OOO 三阶段 | 抓取(FIFO push) → 仲裁(RR) → 完成(FIFO pull) |
| ID Mask 匹配 | 通过 XOR 反查原始 ID，匹配 FIFO 条目 |
| 误路由优先 | misrouted 事务优先于正常事务处理 |
| 读/写路径差异 | 读路径多存 8bit burst 长度 |
| 单 Outstanding 简化 | OSTDREQ_NUM=1 时无需 FIFO，用 pipeline 替代 |

---

## 10. 动手练习

### 练习 1: Mask 算法手推

给定 `req = 4'b1010`（只有 req1 和 req3 活跃），初始 `mask = 4'b1111`。
请手推 6 个周期的 grant 和 mask 变化：

```
T0: req=1010, mask=1111, masked=____, grant=____, next_mask=____
T1: req=1010, mask=____, masked=____, grant=____, next_mask=____
T2: req=1010, mask=____, masked=____, grant=____, next_mask=____
T3: req=1010, mask=____, masked=____, grant=____, next_mask=____
T4: req=1010, mask=____, masked=____, grant=____, next_mask=____
T5: req=1010, mask=____, masked=____, grant=____, next_mask=____
```

### 练习 2: 优先级分析

假设配置：
```
MST0_PRIORITY = 0  (CPU)
MST1_PRIORITY = 2  (DMA)
MST2_PRIORITY = 0  (外部)
MST3_PRIORITY = 0  (外部)
```

当 4 个 Master 同时请求时，谁会先获得 grant？如果 DMA 请求被服务后，
剩余三个 Master 如何轮转？

### 练习 3: Outstanding 深度计算

```
AXI_DATA_W = 32, MST0_OSTDREQ_NUM = 4, MST0_OSTDREQ_SIZE = 1
```

计算：
1. Master 0 内部缓冲区总大小（bits）
2. OOO 模块中 FIFO 的数量和深度
3. 如果 DDR 延迟 = 10 周期，CPU 发 4 个 Outstanding 读请求，理论带宽利用率

### 练习 4: 代码追踪

阅读 `src/axi_crossbar/axicb_slv_ooo.sv` 行 192~203 的匹配逻辑，
画出当以下条件满足时的信号流：
- NB_ID=4, SLV_NB=4
- ID FIFO[2] 非空，记录目标为 SLV0
- SLV0 返回的完成通道 ID 为 0x12（MST_ID_MASK=0x10）
- 验证：`(0x12 ^ 0x10) == 2` → 匹配 ID FIFO[2]

---

## 11. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_round_robin.sv` | 仲裁器顶层，优先级分层 + 轮转 |
| `src/axi_crossbar/axicb_round_robin_core.sv` | Mask-based Round-Robin 核心算法 |
| `src/axi_crossbar/axicb_slv_ooo.sv` | 乱序完成管理器 |
| `src/axi_crossbar/axicb_scfifo.sv` | 同步 FIFO（OOO 中使用） |
| `src/axi_crossbar/axicb_pipeline.sv` | Pipeline 寄存器（单 OR 简化路径） |
| `src/soc_top.sv` 行 496~515 | Outstanding 和优先级参数配置 |
