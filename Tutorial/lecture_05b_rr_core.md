# Lecture 05b: AXI Crossbar深入（四）-- Round-Robin仲裁核心

## 课程概要

本讲深入分析 Crossbar 中最核心的组合逻辑模块 -- `axicb_round_robin_core.sv`。
这个模块实现了**Mask-based Round-Robin**仲裁算法，是整个 Crossbar 公平性的基石。
我们将逐行解读其 2~32 位参数化实现，理解 mask 更新机制、lonely request 回退逻辑，
以及它如何被上层 `axicb_round_robin` 包装为带优先级的仲裁器。

---

## 1. 模块总览

### 1.1 在 Crossbar 中的位置

```
文件: src/axi_crossbar/axicb_round_robin.sv (上层封装)

  axicb_round_robin (带优先级的仲裁器)
    │
    ├── 优先级分层: 将 req 按 P0~P3 分桶
    │
    ├── rr_p0: axicb_round_robin_core  ← 本讲主角
    ├── rr_p1: axicb_round_robin_core
    ├── rr_p2: axicb_round_robin_core
    └── rr_p3: axicb_round_robin_core

  最终 grant = 高优先级桶优先，桶内公平轮转
```

### 1.2 模块接口

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 67~79

module axicb_round_robin_core
    #(
        parameter REQ_NB = 4      // 请求者数量: 2 ~ 32
    )(
        input  wire                   aclk,
        input  wire                   aresetn,
        input  wire                   srst,
        input  wire                   en,        // 使能信号
        input  wire  [REQ_NB-1:0]    req,        // 请求向量
        output logic [REQ_NB-1:0]    grant       // 授权向量 (one-hot)
    );
```

**关键信号**：
- `req`: 每个 bit 对应一个请求者，1 = 有请求
- `grant`: one-hot 输出，只有一个 bit 为 1
- `en`: 使能信号，为 0 时 grant 保持上次的值

---

## 2. Mask-based Round-Robin 算法详解

### 2.1 核心思想

算法用一个 **动态 bitmask** 记录"已服务"的请求者。每次授权后，mask 将
已服务的 bit 及其更低 bit 全部清零，迫使下一次优先服务更高 bit 的请求者。
当最高 bit 也被服务后，mask 重置为全 1，开始新一轮轮转。

```
核心状态机:

  mask = 0 (初始/重置)
      │
      ▼
  mask = 全1 ◄──────────── 授权了最高位请求者
      │
      │ 授权 req[N]
      ▼
  mask = 11...100...0 ──→ 授权 req[N+1]
      │                      ...
      ▼
  mask = 100...0 ───────→ 授权 req[MSB]
      │
      ▼
  mask = 全1 (新一轮)
```

### 2.2 三步算法

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 87~111 (以 REQ_NB==2 为例)

步骤 1: 施加 mask
    masked = mask & req;
    // 只保留 mask 允许范围内的请求

步骤 2: 查找第一个 active 的请求
    if (|masked) begin
        // masked 范围内有请求 → 从 LSB 开始找
        if (masked[0]) grant_c = 2'd1;
        else if (masked[1]) grant_c = 2'd2;
    end else begin
        // masked 范围内无请求 → 回退到全范围
        if (req[0]) grant_c = 2'd1;
        else if (req[1]) grant_c = 2'd2;
    end

步骤 3: 更新 mask (时序逻辑)
    if (en && |grant) begin
        if (grant[0]) mask <= 2'b10;   // 授权 bit0, mask 掉 bit0
        else if (grant[1]) mask <= '1; // 授权 bit1(最高位), 重置
    end
```

### 2.3 4 位宽度完整追踪

以 `REQ_NB=4` 为例，手推完整的仲裁序列：

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 174~218

初始: mask = 4'b0000 (复位后)

场景: req = 4'b1111 (所有请求者同时活跃)

周期  req    mask   masked  grant   next_mask  说明
────  ────   ────   ─────   ─────   ─────────  ──────────────
T0    1111   0000   0000    0001    1110       masked=0, 回退找 req[0]
T1    1111   1110   1110    0010    1100       masked[1]=1, 授权 req[1]
T2    1111   1100   1100    0100    1000       masked[2]=1, 授权 req[2]
T3    1111   1000   1000    1000    1111       masked[3]=1, 授权 req[3], 重置
T4    1111   1111   1111    0001    1110       新一轮, 从 req[0] 开始
T5    1111   1110   1110    0010    1100       继续轮转
```

**观察**: 每个请求者都获得了公平的服务机会，顺序为 0→1→2→3→0→1→...

### 2.4 Sparse Request 场景

当部分请求者不活跃时，算法自动跳过：

```
场景: req = 4'b1010 (只有 req1 和 req3)

周期  req    mask   masked  grant   next_mask  说明
────  ────   ────   ─────   ─────   ─────────  ──────────────
T0    1010   0000   0000    0010    1100       回退找 req[1]
T1    1010   1100   1000    1000    1111       masked[3]=1, 授权 req[3]
T2    1010   1111   1010    0010    1100       新一轮, 授权 req[1]
T3    1010   1100   1000    1000    1111       授权 req[3], 重置
```

**观察**: req0 和 req2 不存在，算法在它们之间跳过，只在活跃的 req1 和 req3 间轮转。

---

## 3. Lonely Request 机制

### 3.1 什么是 Lonely Request？

当 mask 范围内的请求全部不活跃，但 mask 范围外有请求时，
算法回退到全范围搜索。这就是 **lonely request** 机制：

```
场景: req = 4'b0011, mask = 4'b1100

  masked = mask & req = 1100 & 0011 = 0000  ← mask 内无匹配!

  回退: 直接在 req 中搜索
  req[0]=1 → grant = 4'b0001

  next_mask = 1110
```

### 3.2 源码实现

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 95~110

    // 1. 施加 mask
    masked = mask & req;

    // 2.1 优先在 masked 范围内查找
    if (|masked) begin
        if      (masked[0]) grant_c = 2'd1;
        else if (masked[1]) grant_c = 2'd2;
        else                grant_c = '0;

    // 2.2 masked 范围内无匹配 → lonely request 回退
    end else begin
        if      (req[0]) grant_c = 2'd1;
        else if (req[1]) grant_c = 2'd2;
        else             grant_c = '0;
    end
```

### 3.3 Lonely Request 完整追踪

```
场景: req = 4'b0011 (只有 req0 和 req1 活跃)

周期  req    mask   masked  grant   next_mask  说明
────  ────   ────   ─────   ─────   ─────────  ──────────────
T0    0011   0000   0000    0001    1110       回退: 授权 req[0]
T1    0011   1110   0010    0010    1100       masked[1]=1, 授权 req[1]
T2    0011   1100   0000    0001    1110       masked 内无匹配, 回退 req[0]
T3    0011   1110   0010    0010    1100       授权 req[1]
  ... (无限重复 0→1→0→1...)
```

**关键观察**: mask 范围为 `1100` 时，req0 和 req1 都在 mask 之外。
此时 masked=0，触发回退逻辑，仍然从 req0 开始搜索。这保证了
即使请求者不在 mask 允许范围内，也不会被饿死。

---

## 4. Mask 更新逻辑

### 4.1 更新规则

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 203~218

    if (en && |grant) begin
        if      (grant[0]) mask <= 4'b1110;  // 授权 bit0 → mask 掉 bit0
        else if (grant[1]) mask <= 4'b1100;  // 授权 bit1 → mask 掉 bit0~1
        else if (grant[2]) mask <= 4'b1000;  // 授权 bit2 → mask 掉 bit0~2
        else if (grant[3]) mask <= '1;       // 授权 bit3(最高) → 重置为全1
    end
```

### 4.2 推广到 N 位

对于任意 N 位宽度，mask 更新规律为：

```
授权 req[K] 后:
  if (K == N-1)   // 最高位
      mask <= 全1;  // 重置
  else
      mask <= (N位) 11...100...0  // 高 (N-K-1) 位为1, 低 (K+1) 位为0
      // 即: mask <= ~((1 << (K+1)) - 1)  在 N 位范围内
```

示例 (8 位):

```
grant[0] → mask <= 8'b11111110
grant[1] → mask <= 8'b11111100
grant[2] → mask <= 8'b11111000
...
grant[6] → mask <= 8'b10000000
grant[7] → mask <= 8'b11111111  (重置)
```

### 4.3 Mask 更新的时序

```
                    ┌──────────────┐
        req ───────►│              │
        en  ───────►│  grant_c     │──── grant (组合输出)
                    │  (组合逻辑)   │
                    └──────────────┘
                           │
                    ┌──────▼──────┐
                    │  mask 寄存器  │──── mask (时序更新)
                    │  (时序逻辑)   │
                    └──────────────┘

时序关系:
  - grant_c: 纯组合逻辑, 在 req/mask 变化后立即更新
  - mask: 时序逻辑, 在下一个时钟沿更新
  - grant: 由 en 控制, en=0 时保持 grant_r (上次的值)
```

---

## 5. 使能与输出寄存器

### 5.1 使能控制

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 2757~2774

    // 输出寄存器: 在 en 有效时锁存 grant_c
    always @ (posedge aclk or negedge aresetn) begin
        if (!aresetn)
            grant_r <= '0;
        else if (srst)
            grant_r <= '0;
        else if (en)
            grant_r <= grant_c;
    end

    // 最终输出: en 有效时用组合输出, 否则用寄存器输出
    always @ (*) begin
        if (en)
            grant = grant_c;
        else
            grant = grant_r;
    end
```

**设计意图**:
- `en=1`: grant 直接跟随组合逻辑输出, 实现**单周期仲裁**
- `en=0`: grant 保持上次的值, 避免无效翻转节省功耗

### 5.2 与上层的配合

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 88~94

    axicb_round_robin_core #(.REQ_NB(REQ_NB))
    rr_p0 (
        .aclk    (aclk),
        .aresetn (aresetn),
        .srst    (srst),
        .en      (en & p0_active),  // 只在该优先级桶活跃时使能
        .req     (req_p0),
        .grant   (grant_p0)
    );
```

上层 `axicb_round_robin` 通过 `en & p0_active` 控制每个桶的使能，
确保只有活跃的优先级桶才会产生 grant 输出。

---

## 6. 参数化实现: Generate Block

### 6.1 为什么用 Generate 而不是 for 循环？

```
文件: src/axi_crossbar/axicb_round_robin_core.sv, 行 87~2755

该模块为 REQ_NB = 2, 3, 4, ..., 32 每种情况都写了独立的 generate 块:

    generate
    if (REQ_NB==2) begin : GRANT_2
        // 2 位的实现 (行 89~128)
    end

    if (REQ_NB==3) begin : GRANT_3
        // 3 位的实现 (行 130~172)
    end

    if (REQ_NB==4) begin : GRANT_4
        // 4 位的实现 (行 174~218)
    end
    // ... 一直到 REQ_NB==32
    endgenerate
```

### 6.2 为什么不用 for 循环？

```
方案A: 用 for 循环 + 优先级编码 (被弃用)

    always @ (*) begin
        grant_c = '0;
        for (int i=0; i<REQ_NB; i++) begin
            if (masked[i]) begin
                grant_c = (1 << i);
                break;  // ← break 在综合中不可靠!
            end
        end
    end

问题:
  1. break 在 combinational always 中综合行为不确定
  2. 不同工具对 for + break 的综合结果不一致
  3. 无法保证单周期完成

方案B: 独立 generate 块 (本项目选择)

    每种宽度一个完整的 if-else 链
    综合工具可以精确优化每种情况
    时序路径完全确定
```

### 6.3 代码重复的代价

```
文件统计:
  axicb_round_robin_core.sv: 2780 行
  其中有效逻辑: ~90 行 (单个宽度)
  重复次数: 31 (REQ_NB=2~32)
  总行数: 90 × 31 ≈ 2780 行

这是典型的"用代码量换确定性"的设计模式。
虽然代码很长，但每个 generate 块都是经过验证的、时序确定的实现。
```

---

## 7. 设计视角

### 7.1 WHY: 为什么用 Mask-based RR？

```text
问题: 如何在硬件中实现公平轮转仲裁？

方案对比:

  方案A: 计数器法
    - 用计数器记录上次服务的编号
    - 下次从 count+1 开始顺序查找
    - 问题: 查找延迟 = O(N), N 为请求数

  方案B: 轮转优先级编码器
    - 每个周期旋转优先级
    - 优点: 组合逻辑, 无状态
    - 问题: 面积 = O(N^2), N 大时不可接受

  方案C: Mask-based (本项目)
    - 用 mask 将搜索空间分为"已服务"和"未服务"
    - 先在"未服务"空间查找, 找不到再回退
    - 查找延迟 = O(N) 但关键路径短
    - 面积 = O(N), 仅需一个 N-bit 寄存器
```

### 7.2 HOW: 如何保证无饥饿？

```text
无饥饿的三个保障:

  1. Mask 回退机制
     即使请求者不在 mask 范围内, lonely request 机制也会
     回退到全范围搜索, 确保每个请求者都有机会被服务。

  2. Mask 自动重置
     当最高位请求者被服务后, mask 重置为全 1,
     保证新一轮轮转从最低位开始。

  3. 时序确定性
     每个 grant 在单个时钟周期内产生,
     不会出现"查找超时"导致某些请求者被跳过。
```

### 7.3 PATTERN: Mask-based Round-Robin 模式

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
│   if (grant[MSB])                                       │
│     mask <= 全1;                // 最高位→重置            │
│   else                                                    │
│     mask <= ~((grant << 1)-1);  // 清除已服务位及以下     │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   axicb_round_robin_core.sv:                            │
│     参数化 2~32 位, generate 块展开                       │
│     mask 在每次有效 grant 后更新                          │
│     en=0 时 grant 保持寄存器值                            │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要公平轮转的仲裁场景                            │
│   - 内存控制器的 Bank 仲裁                                │
│   - 网络交换机的端口调度                                  │
│   - DMA 引擎的通道仲裁                                   │
│   - 总线仲裁器的 Master 选择                              │
└─────────────────────────────────────────────────────────┘
```

---

## 8. 与上层 axicb_round_robin 的集成

### 8.1 优先级分桶

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 52~70

将 4 个请求者按优先级分配到 4 个桶:

    req_p0[0] = (REQ0_PRIORITY==0) ? req[0] : 0;  // P0 桶
    req_p0[1] = (REQ1_PRIORITY==0) ? req[1] : 0;
    req_p0[2] = (REQ2_PRIORITY==0) ? req[2] : 0;
    req_p0[3] = (REQ3_PRIORITY==0) ? req[3] : 0;

    req_p1[0] = (REQ0_PRIORITY==1) ? req[0] : 0;  // P1 桶
    // ... 类推
```

### 8.2 优先级屏蔽

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 72~76

    assign p3_active = |req_p3;              // P3 有请求？
    assign p2_active = |req_p2 & ~p3_active; // P2 有且 P3 无
    assign p1_active = |req_p1 & ~p2_active; // P1 有且 P2 无
    assign p0_active = |req_p0 & ~p1_active; // P0 有且 P1 无

效果: 高优先级桶完全屏蔽低优先级桶
```

### 8.3 最终 Grant 选择

```
文件: src/axi_crossbar/axicb_round_robin.sv, 行 167~170

    assign grant = (|grant_p3) ? grant_p3 :
                   (|grant_p2) ? grant_p2 :
                   (|grant_p1) ? grant_p1 :
                                 grant_p0 ;

每个桶内部用 axicb_round_robin_core 做公平轮转,
桶之间用优先级选择。
```

### 8.4 实例: 本项目的仲裁配置

```
文件: src/soc_top.sv (Crossbar 参数)

  DDR 端口仲裁:
    MST0_PRIORITY = 0  (CPU, 低优先级)
    MST1_PRIORITY = 0  (DMA, 低优先级)
    MST2_PRIORITY = 0  (外部, 低优先级)
    MST3_PRIORITY = 0  (外部, 低优先级)

    → 所有 Master 同优先级, 纯 Round-Robin

  NPU LMEM 端口仲裁:
    同样配置, 所有 Master 平等轮转
```

---

## 9. 时序分析

### 9.1 关键路径

```
组合逻辑延迟分析 (以 REQ_NB=4 为例):

  req ──→ AND (masked = mask & req)
       ──→ OR  (|masked)
       ──→ MUX (if-else 链, 最多 4 级)
       ──→ grant_c

  总延迟: 1 AND + 1 OR + N 级 MUX

  对于 N=4: ~3 门延迟
  对于 N=32: ~31 门延迟
```

### 9.2 时序约束

```
Fmax 估算:

  假设每级 MUX 延迟 = 0.1ns, 门延迟 = 0.05ns
  N=4:  0.05 + 0.05 + 4×0.1 = 0.5ns → Fmax ≈ 2GHz
  N=32: 0.05 + 0.05 + 32×0.1 = 3.3ns → Fmax ≈ 300MHz

  实际 Crossbar 中 N 通常 ≤ 4, 时序非常宽松。
```

---

## 10. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| Mask 算法三步 | masked = mask & req → 找 first_one → 更新 mask |
| Lonely Request | masked=0 时回退到全范围搜索, 防止饥饿 |
| Mask 重置 | 授权最高位后 mask 重置为全1, 开始新轮转 |
| Generate 展开 | 2~32 位各一个独立实现, 用代码量换确定性 |
| 使能控制 | en=0 时 grant 保持寄存器值, 节省功耗 |
| 优先级集成 | 上层分桶 + 桶内 RR, 兼顾公平和优先级 |
| 时序特性 | 单周期组合逻辑输出, 延迟与请求者数量成线性 |

---

## 11. 动手练习

### 练习 1: 6 位 Mask 算法手推

给定 `REQ_NB=6`, `req = 6'b101010` (只有 req1, req3, req5 活跃)。
初始 `mask = 6'b000000`。请手推 6 个周期的 grant 和 mask 变化:

```
T0: req=101010, mask=000000, masked=______, grant=______, next_mask=______
T1: req=101010, mask=______, masked=______, grant=______, next_mask=______
T2: req=101010, mask=______, masked=______, grant=______, next_mask=______
T3: req=101010, mask=______, masked=______, grant=______, next_mask=______
T4: req=101010, mask=______, masked=______, grant=______, next_mask=______
T5: req=101010, mask=______, masked=______, grant=______, next_mask=______
```

### 练习 2: Lonely Request 分析

给定 `REQ_NB=4`:
```
T0: req=0001, mask=0000 → grant=____
T1: req=0001, mask=1110 → grant=____ (此时 masked=?)
```

解释: 为什么 T1 中 req[0] 活跃但 mask 不允许它, 最终结果是什么？

### 练习 3: 最大延迟路径计算

对于 `REQ_NB=32`, 假设每级 MUX 延迟 = 0.15ns:
1. 计算最坏情况下的组合逻辑延迟
2. 如果目标 Fmax = 500MHz (周期=2ns), 这个延迟是否满足时序？
3. 如果不满足, 你会如何优化？(提示: 流水线切片)

### 练习 4: 代码修改 -- 双授权仲裁器

当前 `axicb_round_robin_core` 每次只产生一个 grant。
请设计一个修改方案, 使其能同时授权两个请求者 (双发射仲裁):

```text
输入:  req = 4'b1111
输出:  grant_a = 4'b0001, grant_b = 4'b0010  (同时授权两个)
```

思考:
- mask 更新逻辑如何修改？
- 如何保证两个 grant 不重复？
- 对公平性有什么影响？

### 练习 5: 集成验证

阅读 `src/axi_crossbar/axicb_round_robin.sv` 完整代码。
假设配置:
```
REQ0_PRIORITY = 0 (CPU)
REQ1_PRIORITY = 2 (DMA)
REQ2_PRIORITY = 0 (外部)
REQ3_PRIORITY = 0 (外部)
```

当 `req = 4'b1111` 时:
1. 画出 4 个桶的 req_p0 ~ req_p3 的值
2. 计算 p0_active ~ p3_active 的值
3. 确定最终 grant 输出
4. DMA 被服务后, 下一轮的 grant 是什么？

---

## 12. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_round_robin_core.sv` | Mask-based RR 核心算法 (2780 行) |
| `src/axi_crossbar/axicb_round_robin.sv` | 带优先级的 RR 顶层封装 |
| `src/soc_top.sv` | Crossbar 参数配置 (优先级、Outstanding) |
