# Lecture 04c: AXI Crossbar深入（二）— 交换矩阵与路由

## 课程目标

本讲分析 `axicb_switch_top.sv` 及其子模块——Crossbar的核心交换矩阵，理解信号如何在多个Master和Slave之间路由。

---

## 1. 模块概览

### 1.1 交换矩阵的角色

```text
┌─────────────────────────────────────────────────────────────┐
│                    Crossbar 内部结构                         │
│                                                             │
│  slv_if[0] ──┐                              ┌── mst_if[0]  │
│  (CPU)       │    ┌──────────────────┐      │   (DDR)       │
│              ├───►│                  │──────┤               │
│  slv_if[1] ──┤    │  switch_top     │      ├── mst_if[1]   │
│  (DMA)       │    │  (交换矩阵)      │      │   (NPU RAM)   │
│              ├───►│                  │──────┤               │
│  slv_if[2] ──┤    │  · 地址路由      │      ├── mst_if[2]   │
│  (空)        │    │  · 仲裁汇聚      │      │   (DMA CSR)   │
│              ├───►│  · 乱序管理      │──────┤               │
│  slv_if[3] ──┘    │  · 流水线       │      └── mst_if[3]   │
│  (空)              └──────────────────┘          (NPU CSR)  │
└─────────────────────────────────────────────────────────────┘

switch_top 是Crossbar的"大脑"，负责：
  1. 地址路由：根据地址选择目标Slave
  2. 仲裁汇聚：多个Master访问同一Slave时仲裁
  3. 乱序管理：跟踪Outstanding事务
  4. 信号重排：per-Master视角 → per-Slave视角
```

### 1.2 模块层次

```text
axicb_switch_top
├── axicb_slv_switch × SLV_NB   — 每个Master的路由分发
│   ├── axicb_slv_switch_wr      — 写通道路由
│   └── axicb_slv_switch_rd      — 读通道路由
├── axicb_mst_switch × MST_NB   — 每个Slave的仲裁汇聚
│   ├── axicb_mst_switch_wr      — 写通道仲裁
│   └── axicb_mst_switch_rd      — 读通道仲裁
├── axicb_slv_ooo                — 乱序完成管理
└── axicb_pipeline               — 可配置流水线
```

---

## 2. 设计视角：为什么这样设计？

### 2.1 为什么读写路由独立？

```text
AXI协议的读和写是完全独立的：
  - 写: AW → W → B (3个通道)
  - 读: AR → R (2个通道)

如果读写共享路由逻辑：
  - 写操作会阻塞读操作（反之亦然）
  - 总线利用率降低50%

本设计：读写完全独立路由
  slv_switch_wr: 只处理AW通道
  slv_switch_rd: 只处理AR通道
  → 读写可以同时进行，带宽翻倍
```

### 2.2 为什么需要信号重排？

```text
问题：信号在slv_if中是按"per-Master"组织的。
      但mst_if需要"per-Slave"的信号。

per-Master视角（slv_if输出）：
  slv0_awvalid[0] → 发往Slave0
  slv0_awvalid[1] → 发往Slave1
  slv1_awvalid[0] → 发往Slave0
  slv1_awvalid[1] → 发往Slave1

per-Slave视角（mst_if需要）：
  mst0_awvalid[0] ← 来自Master0
  mst0_awvalid[1] ← 来自Master1
  mst1_awvalid[0] ← 来自Master0
  mst1_awvalid[1] ← 来自Master1

交换矩阵的核心操作就是这个视角转换。
```

### 2.3 方案对比

```text
┌─────────────┬──────────────────┬──────────────┬─────────────┐
│ 方案        │ 原理             │ 优点         │ 缺点        │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ A.Crossbar  │ N×M全连接矩阵   │ 任意并发     │ 面积O(N×M)  │
│ (本设计)    │                  │ 带宽最高     │             │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ B.共享总线  │ 一条总线+仲裁    │ 面积最小     │ 只能1对1    │
│             │                  │              │ 带宽最低    │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ C.Ring/NoC  │ 环形或网格       │ 可扩展       │ 延迟大      │
│             │                  │              │ 设计复杂    │
└─────────────┴──────────────────┴──────────────┴─────────────┘

本项目4×4规模，Crossbar面积可接受，带宽最优。
```

---

## 3. 设计视角：如何从零开始设计？

### Step 1: 地址解码逻辑

```text
每个Master需要知道"我要访问的地址属于哪个Slave"。

实现：将地址与每个Slave的地址范围比较

  for (每个Slave i) begin
    match[i] = (addr >= START_ADDR[i]) && (addr <= END_ADDR[i]);
  end

  target_slave = one-hot编码的match信号;

本项目地址范围：
  Slave0: 0x4000_0000 ~ 0x4003_FFFF (DDR)
  Slave1: 0x0000_1000 ~ 0x0002_0FFF (NPU RAM)
  Slave2: 0x0002_1000 ~ 0x0002_1FFF (DMA CSR)
  Slave3: 0x0003_0000 ~ 0x0003_0FFF (NPU CSR)
```

### Step 2: 路由掩码过滤

```text
MST_ROUTES参数控制每个Master可以访问哪些Slave：

  MST0_ROUTES = 4'b1111  → CPU可以访问所有Slave
  MST1_ROUTES = 4'b1111  → DMA可以访问所有Slave
  MST2_ROUTES = 4'b0000  → 未使用
  MST3_ROUTES = 4'b0000  → 未使用

过滤逻辑：
  final_match = address_match & MST_ROUTES;

如果final_match=0 → 地址未命中 → 产生DECERR
```

### Step 3: 信号重排矩阵

```text
核心操作：per-Master → per-Slave 的信号转置

  // 伪代码
  for (slave_i = 0; slave_i < SLV_NB; slave_i++)
    for (master_j = 0; master_j < MST_NB; master_j++)
      mst_valid[slave_i][master_j] = slv_valid[master_j][slave_i];

这是纯组合逻辑的信号重连，无需时序逻辑。
```

### Step 4: 仲裁汇聚

```text
当多个Master同时访问同一Slave时，需要仲裁：

  Slave0的写通道：
    Master0要写 → awvalid[0]=1
    Master1要写 → awvalid[1]=1
    → 仲裁器选择一个 → grant[0]或grant[1]
    → 获胜Master的信号连接到Slave0

仲裁策略：Round-Robin（下一讲详细分析）
```

### Step 5: 验证策略

```text
1. 路由正确性：地址0x4000_0000是否正确路由到DDR？
2. 仲裁公平性：两个Master轮流访问同一Slave时是否公平？
3. 并发能力：不同Master访问不同Slave时是否无阻塞？
4. 错误处理：访问未映射地址时是否返回DECERR？
```

---

## 4. 设计视角：架构模式

### 模式 1: Crossbar交换矩阵

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: Crossbar交换矩阵                                   │
│                                                         │
│ 核心: N×M全连接，每个输入可到达任意输出                  │
│                                                         │
│ 实现:                                                    │
│   前向: 地址解码 → 选择目标Slave                         │
│   反向: 仲裁 → 选择获胜Master                           │
│   数据: 多路选择器树                                     │
│                                                         │
│ 复用: 任何多对多互连（Crossbar、NoC、开关网络）           │
└─────────────────────────────────────────────────────────┘
```

### 模式 2: 信号重排（Per-Master → Per-Slave）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: 信号视角转换                                       │
│                                                         │
│ 核心: 将信号从"per-发起方"组织转为"per-接收方"组织       │
│                                                         │
│ 实现: 纯组合逻辑的信号重连（generate循环）               │
│                                                         │
│ 复用: 任何多端口互连结构                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 5. 地址路由详解

### 5.1 slv_switch_wr 写通道路由

```text
每个Master实例化一个slv_switch_wr：

  输入: i_awvalid, i_awch (打包的AW信号，含地址)
  输出: o_awvalid[SLV_NB-1:0] (one-hot，目标Slave)

路由逻辑：
  1. 从awch中提取地址
  2. 与所有Slave的地址范围比较
  3. 应用MST_ROUTES掩码过滤
  4. 输出one-hot的valid信号

如果多个Slave匹配（地址重叠）→ 错误配置
如果没有Slave匹配 → misroute标记
```

### 5.2 slv_switch_rd 读通道路由

```text
与写通道完全相同的逻辑，但处理AR通道：

  输入: i_arvalid, i_arch (打包的AR信号)
  输出: o_arvalid[SLV_NB-1:0]

读写独立，互不阻塞。
```

---

## 6. 信号重排矩阵详解

### 6.1 从per-Master到per-Slave

```text
slv_if输出（per-Master视角）：
  slv0: awvalid → {发往S0, 发往S1, 发往S2, 发往S3} = awvalid_m0[3:0]
  slv1: awvalid → {发往S0, 发往S1, 发往S2, 发往S3} = awvalid_m1[3:0]

mst_if需要（per-Slave视角）：
  mst0: awvalid ← {来自M0, 来自M1, 来自M2, 来自M3} = awvalid_s0[3:0]
  mst1: awvalid ← {来自M0, 来自M1, 来自M2, 来自M3} = awvalid_s1[3:0]

转换：
  awvalid_s0[0] = awvalid_m0[0]  // M0→S0
  awvalid_s0[1] = awvalid_m1[0]  // M1→S0
  awvalid_s1[0] = awvalid_m0[1]  // M0→S1
  awvalid_s1[1] = awvalid_m1[1]  // M1→S1
```

### 6.2 Verilog实现

```systemverilog
// 简化的重排逻辑
for (i = 0; i < SLV_NB; i++)      // 遍历每个Slave
  for (j = 0; j < MST_NB; j++)    // 遍历每个Master
    // Slave i 从 Master j 接收的valid
    assign mst_awvalid[i*MST_NB+j] = slv_awvalid[j*SLV_NB+i];

// 反向：Slave j 给 Master i 的ready
for (i = 0; i < MST_NB; i++)
  for (j = 0; j < SLV_NB; j++)
    assign slv_awready[i*SLV_NB+j] = mst_awready[j*MST_NB+i];
```

---

## 7. 本讲要点

| 要点 | 说明 |
|------|------|
| 交换矩阵 | Crossbar核心，实现N×M全连接 |
| 读写独立 | AW和AR通道独立路由，互不阻塞 |
| 地址解码 | 与Slave地址范围比较 + MST_ROUTES过滤 |
| 信号重排 | per-Master → per-Slave 视角转换 |
| 仲裁汇聚 | 多Master访问同一Slave时用RR仲裁 |
| misroute | 地址未命中时产生DECERR |

---

## 8. 下节预告

下一讲分析 `axicb_mst_if.sv`——连接外部Slave的接口模块，含地址翻译逻辑。
