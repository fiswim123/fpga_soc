# Lecture 04c: AXI Crossbar深入（二）-- 交换矩阵与路由

## 课程概要

本讲是 AXI Crossbar 深入系列的第二篇，聚焦于 Crossbar 的**核心交换逻辑**：
`axicb_switch_top.sv`（交换矩阵顶层）、`axicb_slv_switch.sv`（Master 侧路由）、
以及写/读通道的独立路由实现。我们将理解地址如何被解码、请求如何被路由、
以及信号重排矩阵如何将"per-Master 视图"转换为"per-Slave 视图"。

---

## 1. 交换矩阵的架构

### 1.1 switch_top 的角色

```
文件: src/axi_crossbar/axicb_switch_top.sv

axicb_switch_top 是 Crossbar 的核心，它完成三件事：
  1. 每个 Master 的地址解码（per-master slv_switch）
  2. 信号重排（per-master view → per-slave view）
  3. 每个 Slave 的仲裁（per-slave mst_switch）
```

### 1.2 整体数据流

```
  ┌────────────────────────────────────────────────────────────────┐
  │                    axicb_switch_top                            │
  │                                                                │
  │  阶段 1: Per-Master 路由                                       │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
  │  │slv_switch│  │slv_switch│  │slv_switch│  │slv_switch│      │
  │  │  MST0    │  │  MST1    │  │  MST2    │  │  MST3    │      │
  │  │地址解码   │  │地址解码   │  │地址解码   │  │地址解码   │      │
  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
  │       │             │             │             │              │
  │  ┌────┴─────────────┴─────────────┴─────────────┴────┐        │
  │  │              信号重排矩阵 (Reordering)              │        │
  │  │    per-Master 视图 ──→ per-Slave 视图               │        │
  │  └────┬─────────────┬─────────────┬─────────────┬────┘        │
  │       │             │             │             │              │
  │  阶段 2: Per-Slave 仲裁                                       │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
  │  │mst_switch│  │mst_switch│  │mst_switch│  │mst_switch│      │
  │  │  SLV0    │  │  SLV1    │  │  SLV2    │  │  SLV3    │      │
  │  │仲裁+路由  │  │仲裁+路由  │  │仲裁+路由  │  │仲裁+路由  │      │
  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
  └────────────────────────────────────────────────────────────────┘
```

### 1.3 内部信号声明

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 112~143

    // ID Mask 拼接
    parameter [4*AXI_ID_W-1:0] MST_ID_MASK =
        {MST3_ID_MASK, MST2_ID_MASK, MST1_ID_MASK, MST0_ID_MASK};

    // per-master × per-slave 路由信号（重排前）
    logic [MST_NB*SLV_NB-1:0] slv_awvalid;  // [mst][slv]
    logic [MST_NB*SLV_NB-1:0] slv_awready;
    logic [MST_NB*SLV_NB-1:0] slv_arvalid;
    // ... 其他通道类似

    // per-slave × per-master 路由信号（重排后）
    logic [MST_NB*SLV_NB-1:0] mst_awvalid;  // [slv][mst]
    logic [MST_NB*SLV_NB-1:0] mst_awready;
    // ... 其他通道类似
```

关键理解：`slv_*` 和 `mst_*` 信号的**索引顺序不同**：
- `slv_awvalid[master*SLV_NB + slave]` -- per-Master 视图
- `mst_awvalid[slave*SLV_NB + master]` -- per-Slave 视图

---

## 2. Per-Master 路由：slv_switch

### 2.1 为什么需要 Per-Master 路由？

```
问题：Master 0 (CPU) 发出一个地址为 0x4000_0000 的请求
     这个请求应该路由到哪个 Slave？

  slv_switch 的工作：
    1. 从打包的 AW 通道中提取地址
    2. 比较地址与各 Slave 的地址范围
    3. 生成 one-hot 路由向量：slv_aw_targeted = 4'b0001
    4. 将请求转发到命中的 Slave 端口
```

### 2.2 slv_switch 实例化

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 150~327

    generate
    for (i=0; i<MST_NB; i=i+1) begin: SLV_SWITCHS_GEN

        // 1. Pipeline 级（5 个通道各一个）
        axicb_pipeline #(.DATA_BUS_W(AWCH_W), .NB_PIPELINE(SLV_PIPELINE))
        awch_slv_pipe (...);

        // 2. Per-Master 路由模块
        axicb_slv_switch
        #(
            .MST_ROUTES      (MST_ROUTES[i*SLV_NB+:SLV_NB]),  // 该 Master 的路由掩码
            .MST_OSTDREQ_NUM (MST_OSTDREQ_NUM[i*8+:8]),       // 该 Master 的 Outstanding 数
            .MST_ID_MASK     (MST_ID_MASK[i*AXI_ID_W+:AXI_ID_W]), // 该 Master 的 ID 掩码
            // ... 地址范围参数
        )
        slv_switch (...);
    end
    endgenerate
```

### 2.3 地址解码逻辑

地址解码在 `axicb_slv_switch_wr.sv` 和 `axicb_slv_switch_rd.sv` 中实现，
写通道和读通道**独立解码**：

```
文件: src/axi_crossbar/axicb_slv_switch_wr.sv, 行 119~153

    generate

    if (MST_ROUTES[0]==1'b1) begin : SLV0_AW_ROUTE_ON
        assign slv_aw_targeted[0] =
            (i_awch[0+:AXI_ADDR_W] >= slv0_start_addr[0+:AXI_ADDR_W] &&
             i_awch[0+:AXI_ADDR_W] <= slv0_end_addr[0+:AXI_ADDR_W]) ? 1'b1 : 1'b0;
    end else begin : SLV0_AW_ROUTE_OFF
        assign slv_aw_targeted[0] = 1'b0;  // 路由禁用
    end

    // SLV1, SLV2, SLV3 类似...

    endgenerate
```

地址解码的核心公式：

```
  路由条件: START_ADDR <= ADDR <= END_ADDR

  slv_aw_targeted[n] = (MST_ROUTES[n]) ?
                        (addr >= SLVn_START_ADDR && addr <= SLVn_END_ADDR) :
                        1'b0;
```

### 2.4 路由掩码 MST_ROUTES

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 268

    .MST_ROUTES (MST_ROUTES[i*SLV_NB+:SLV_NB])

每个 Master 有独立的 SLV_NB 位路由掩码：

  MST0_ROUTES = 4'b1111  (CPU 可访问所有 4 个 Slave)
  MST1_ROUTES = 4'b1111  (DMA 可访问所有 4 个 Slave)
  MST2_ROUTES = 4'b0000  (外部2 禁止访问任何 Slave)
  MST3_ROUTES = 4'b0000  (外部3 禁止访问任何 Slave)

路由掩码的作用：
  - 硬件级权限控制
  - 编译时通过 generate 禁用不需要的地址比较器
  - MST_ROUTES[n]=0 时，对应的地址比较器被完全优化掉
```

### 2.5 slv_switch 内部结构

`axicb_slv_switch` 是一个纯结构性封装，内部拆分为写和读两个子模块：

```
文件: src/axi_crossbar/axicb_slv_switch.sv, 行 94~188

axicb_slv_switch
  │
  ├── axicb_slv_switch_wr  (写通道: AW + W + B)
  │     - AW 地址解码
  │     - W 通道路由（FIFO 同步）
  │     - B 响应路由（OoO 管理）
  │
  └── axicb_slv_switch_rd  (读通道: AR + R)
        - AR 地址解码
        - R 响应路由（OoO 管理）
```

---

## 2.1+ 设计视角：为什么独立的读/写路由？

### 核心设计决策

#### 决策：为什么写通道和读通道独立路由？

```text
问题：为什么不把 AW 和 AR 通道合并为一个地址通道路由？

方案A：合并路由
  - AW 和 AR 共享一个地址解码器
  - 仲裁时需要同时考虑读和写
  - 优点：面积小（共享解码器）
  - 缺点：读写互相阻塞，吞吐量减半

方案B：独立路由（本项目选择）
  - AW 和 AR 各有独立的地址解码器
  - 写通道和读通道完全独立
  - 优点：读写可以同时进行，吞吐量翻倍
  - 缺点：面积略大（解码器 x2）

实际影响：
  CPU 写 DDR 的同时，DMA 可以读 NPU LMEM
  如果合并路由，这两个操作会互相阻塞
```

| 对比维度 | 方案A：合并路由 | 方案B：独立路由 |
|----------|--------------|---------------|
| 吞吐量 | 低（读写互斥） | 高（读写并行） |
| 面积 | 小 | 大（约 2x 解码器） |
| 延迟 | 高（等待互斥释放） | 低（无互斥） |
| 设计复杂度 | 中 | 低（更简单） |
| 典型应用 | 低带宽互连 | 高性能 SoC |

---

## 3. W 通道同步机制

### 3.1 问题：AW 和 W 通道的时序关系

AXI 协议允许 AW 和 W 通道独立握手，但一个 burst 的 W 数据必须
跟随其 AW 地址发送到**同一个 Slave**。

```
  AW 通道: CPU 发 AWADDR=0x4000_0000 → 路由到 SLV0 (DDR)
  W 通道:  CPU 发 WDATA=0x12345678   → 必须也路由到 SLV0

  问题：如果 W 通道比 AW 通道先到达，怎么知道该路由到哪个 Slave？
```

### 3.2 解决方案：Grant FIFO

```
文件: src/axi_crossbar/axicb_slv_switch_wr.sv, 行 190~232

    // Grant FIFO：存储 AW 的路由信息，供 W 通道使用
    axicb_scfifo
    #(
    .PASS_THRU  (0),
    .ADDR_WIDTH (8),              // 深度 256
    .DATA_WIDTH (1 + SLV_NB + AXI_ID_W)  // misroute + target + id
    )
    wch_gnt_fifo
    (
    .data_in  ({aw_misrouting_c, slv_aw_targeted, i_awch[AXI_ADDR_W+:AXI_ID_W]}),
    .push     (i_awvalid & i_awready),   // AW 握手成功时 push
    .data_out ({a_mr, slv_w_targeted, a_id}),
    .pull     (i_wvalid & i_wready & i_wlast),  // W 最后一拍时 pull
    .empty    (wch_empty)
    );
```

FIFO 工作流程：

```
  ┌─────────────────────────────────────────────────────────┐
  │  Grant FIFO 工作流程                                     │
  │                                                         │
  │  AW 握手时 (push):                                      │
  │    存入 {aw_misrouting_c, slv_aw_targeted, awid}        │
  │    例如: {0, 4'b0001, 8'h05}  ← 路由到 SLV0, ID=5     │
  │                                                         │
  │  W 通道使用 (pop):                                      │
  │    读出 slv_w_targeted → 知道 W 数据应该发给哪个 Slave   │
  │    o_wvalid[n] = !wch_empty & slv_w_targeted[n]         │
  │                                                         │
  │  W 最后一拍时 (pull):                                   │
  │    FIFO 条目被消费，为下一个 burst 腾出空间              │
  └─────────────────────────────────────────────────────────┘
```

### 3.3 W 通道路由

```
文件: src/axi_crossbar/axicb_slv_switch_wr.sv, 行 214~232

    // WVALID 由 FIFO 中的路由信息决定
    assign o_wvalid[0] = (!wch_empty & slv_w_targeted[0]) ? i_wvalid : 1'b0;
    assign o_wvalid[1] = (!wch_empty & slv_w_targeted[1]) ? i_wvalid : 1'b0;
    assign o_wvalid[2] = (!wch_empty & slv_w_targeted[2]) ? i_wvalid : 1'b0;
    assign o_wvalid[3] = (!wch_empty & slv_w_targeted[3]) ? i_wvalid : 1'b0;

    // WREADY 回传：只有被选中的 Slave 的 ready 有效
    assign i_wready = (slv_w_targeted[0]) ? o_wready[0] :
                      (slv_w_targeted[1]) ? o_wready[1] :
                      (slv_w_targeted[2]) ? o_wready[2] :
                      (slv_w_targeted[3]) ? o_wready[3] :
                      (a_mr) ? 1'b1 :    // 误路由时吸收数据
                      1'b0;
```

---

## 4. 误路由（Misroute）处理

### 4.1 什么是误路由？

当一个请求的地址不在任何 Slave 的地址范围内时，发生误路由：

```
  CPU 发出 ARADDR=0x5000_0000
  地址解码: 不在任何 Slave 的范围内
  → ar_misrouting_c = 1

  如果不做处理：
    - ARVALID 保持为 1，但没有 Slave 响应 ARREADY
    - CPU 永远等待 → 死锁！
```

### 4.2 误路由处理机制

```
文件: src/axi_crossbar/axicb_slv_switch_wr.sv, 行 168~184

    // 检测误路由
    assign aw_misrouting_c = (slv_aw_targeted == '0);

    // 生成单周期脉冲（防止重复握手）
    always @ (posedge aclk or negedge aresetn) begin
        if (!aresetn) aw_misrouting <= 1'b0;
        else if (srst) aw_misrouting <= 1'b0;
        else begin
            if (i_awvalid && aw_misrouting_c && !aw_misrouting)
                aw_misrouting <= 1'b1;   // 误路由检测到
            else
                aw_misrouting <= 1'b0;   // 下一周期清除
        end
    end
```

误路由的 AWREADY 生成：

```
    // 正常路由: AWREADY 来自目标 Slave
    // 误路由:   AWREADY 由 misrouting 脉冲生成（假握手）
    assign i_awready = (slv_aw_targeted[0]) ? o_awready[0] & !bch_full & !wch_full :
                       (slv_aw_targeted[1]) ? o_awready[1] & !bch_full & !wch_full :
                       (slv_aw_targeted[2]) ? o_awready[2] & !bch_full & !wch_full :
                       (slv_aw_targeted[3]) ? o_awready[3] & !bch_full & !wch_full :
                       (aw_misrouting) ? 1'b1 :  // 误路由: 假握手
                       1'b0;
```

### 4.3 误路由的响应：SLVERR

误路由的请求不会丢失，而是被 OoO 模块记录，在响应阶段返回 SLVERR：

```
  写通道误路由:
    AW 握手完成 → Grant FIFO 存入 {mr=1, target=0, id}
    W 数据被吸收（i_wready=1）
    B 响应: OoO 模块生成 {resp=SLVERR, id=原始ID} 返回给 Master

  读通道误路由:
    AR 握手完成 → OoO 模块存入 {mr=1, target=0, id, len}
    R 响应: OoO 模块生成 {resp=SLVERR, id=原始ID, rlast=1} 返回给 Master
```

---

## 5. 信号重排矩阵

### 5.1 为什么需要重排？

```
slv_switch 输出的信号索引：[master][slave]
  slv_awvalid[0*4+0] = MST0→SLV0 的请求
  slv_awvalid[0*4+1] = MST0→SLV1 的请求
  slv_awvalid[1*4+0] = MST1→SLV0 的请求

mst_switch 需要的信号索引：[slave][master]
  mst_awvalid[0*4+0] = MST0→SLV0 的请求
  mst_awvalid[0*4+1] = MST1→SLV0 的请求
  mst_awvalid[1*4+0] = MST0→SLV1 的请求

  需要一个矩阵转置！
```

### 5.2 重排逻辑

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 347~373

    generate

    // 请求方向重排: slv → mst
    for (i=0; i<SLV_NB; i=i+1) begin: REORDERING_TO_MST
        for (j=0; j<MST_NB; j=j+1) begin: SLV_IF_PARSING
            assign mst_awvalid[i*SLV_NB+j] = slv_awvalid[j*MST_NB+i];
            assign mst_wvalid[i*SLV_NB+j]  = slv_wvalid[j*MST_NB+i];
            assign mst_wlast[i*SLV_NB+j]   = slv_wlast[j*MST_NB+i];
            assign mst_bready[i*SLV_NB+j]  = slv_bready[j*MST_NB+i];
            assign mst_arvalid[i*SLV_NB+j] = slv_arvalid[j*MST_NB+i];
            assign mst_rready[i*SLV_NB+j]  = slv_rready[j*MST_NB+i];
        end
    end

    // 响应方向重排: mst → slv
    for (i=0; i<MST_NB; i=i+1) begin: REORDERING_TO_SLV
        for (j=0; j<SLV_NB; j=j+1) begin: MST_IF_PARSING
            assign slv_awready[i*MST_NB+j] = mst_awready[j*SLV_NB+i];
            assign slv_wready[i*MST_NB+j]  = mst_wready[j*SLV_NB+i];
            assign slv_bvalid[i*MST_NB+j]  = mst_bvalid[j*SLV_NB+i];
            assign slv_arready[i*MST_NB+j] = mst_arready[j*SLV_NB+i];
            assign slv_rvalid[i*MST_NB+j]  = mst_rvalid[j*SLV_NB+i];
            assign slv_rlast[i*MST_NB+j]   = mst_rlast[j*SLV_NB+i];
        end
    end

    endgenerate
```

### 5.3 重排矩阵图解

```
  重排前 (per-Master 视图):
  slv_awvalid[master*SLV_NB + slave]

         SLV0  SLV1  SLV2  SLV3
  MST0 [  a     b     c     d  ]  ← MST0 的路由结果
  MST1 [  e     f     g     h  ]  ← MST1 的路由结果
  MST2 [  i     j     k     l  ]  ← MST2 的路由结果
  MST3 [  m     n     o     p  ]  ← MST3 的路由结果

  重排后 (per-Slave 视图):
  mst_awvalid[slave*SLV_NB + master]

         MST0  MST1  MST2  MST3
  SLV0 [  a     e     i     m  ]  ← SLV0 收到的请求
  SLV1 [  b     f     j     n  ]  ← SLV1 收到的请求
  SLV2 [  c     g     k     o  ]  ← SLV2 收到的请求
  SLV3 [  d     h     l     p  ]  ← SLV3 收到的请求

  转置操作: mst[i][j] = slv[j][i]
```

---

## 5.1+ 设计视角：如何设计非阻塞交换？

### 核心设计决策

#### 决策1：为什么用重排矩阵而非直接 MUX？

```text
问题：如何将 N 个 Master 的请求路由到 M 个 Slave？

方案A：全交叉 MUX 矩阵
  - 每个 Slave 端口有一个 N:1 MUX
  - 选择信号来自地址解码器
  - 优点：延迟低（一级 MUX）
  - 缺点：面积 O(N×M×数据宽度)，布线复杂

方案B：分时共享总线
  - 所有 Master 共享一条内部总线
  - 仲裁器选择哪个 Master 使用总线
  - 优点：面积小
  - 缺点：同一时刻只有一对通信

方案C：分层路由（本项目选择）
  - 第一层：per-Master 地址解码 → 生成路由向量
  - 第二层：信号重排 → per-Slave 视图
  - 第三层：per-Slave 仲裁 → 选择一个 Master
  - 优点：模块化，可扩展，读写独立
  - 缺点：需要重排逻辑（纯连线，无逻辑门）
```

#### 决策2：为什么重排是纯连线？

```text
信号重排（Reordering）本质上是一个矩阵转置：

  mst_awvalid[i*SLV_NB+j] = slv_awvalid[j*MST_NB+i]

这不是逻辑运算，而是信号重连！
  - 综合工具会将其优化为纯连线
  - 不消耗任何逻辑门
  - 不增加任何延迟
  - 只影响布局布线

这正是 Crossbar 交换矩阵高效的关键：
  地址解码和仲裁是逻辑运算（有延迟）
  信号重排是纯连线（零延迟）
```

---

## 5.2+ 设计视角：Crossbar 交换模式

### 模式：Crossbar Switching Pattern（交叉开关交换模式）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Crossbar Switching Matrix（交叉开关交换矩阵）  │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   使用分层路由架构：                                       │
│   第一层 per-source 地址解码，                             │
│   中间层信号重排（纯连线），                               │
│   第三层 per-destination 仲裁，                           │
│   实现非阻塞的任意到任意连接。                             │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 每个源（Master）独立解码目标地址                      │
│   2. 生成 per-source 的路由向量                           │
│   3. 矩阵转置将路由向量重排为 per-destination 视图        │
│   4. 每个目标（Slave）独立仲裁多个源的请求                 │
│   5. 读写路径完全独立，互不阻塞                           │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   4×4 Crossbar:                                         │
│     4 个 slv_switch (per-Master) + 信号重排               │
│     4 个 mst_switch (per-Slave) + 5 通道 pipeline        │
│     无冲突的 Master-Slave 对可同时通信                    │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何 N×M 的非阻塞互连                                │
│   - 网络交换机的交叉开关                                  │
│   - 多核处理器的缓存一致性互连                            │
│   - 内存控制器的多通道交叉                                │
└─────────────────────────────────────────────────────────┘
```

---

## 6. Per-Slave 仲裁：mst_switch

### 6.1 mst_switch 的角色

重排后，每个 Slave 端口可能收到来自多个 Master 的请求。
`mst_switch` 负责仲裁这些请求，选择一个 Master 先获得访问权。

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 382~557

    generate
    for (i=0; i<SLV_NB; i=i+1) begin: MST_SWITCHS_GEN

        axicb_mst_switch
        #(
            .MST_NB          (MST_NB),
            .MST0_ID_MASK    (MST0_ID_MASK),
            .MST1_ID_MASK    (MST1_ID_MASK),
            .MST2_ID_MASK    (MST2_ID_MASK),
            .MST3_ID_MASK    (MST3_ID_MASK),
            .MST0_PRIORITY   (MST0_PRIORITY),
            .MST1_PRIORITY   (MST1_PRIORITY),
            .MST2_PRIORITY   (MST2_PRIORITY),
            .MST3_PRIORITY   (MST3_PRIORITY),
            // ... 通道宽度参数
        )
        mst_switch (...);

        // Pipeline 级（5 个通道各一个）
        axicb_pipeline #(.DATA_BUS_W(AWCH_W), .NB_PIPELINE(MST_PIPELINE))
        awch_mst_pipe (...);
    end
    endgenerate
```

### 6.2 mst_switch 内部结构

`axicb_mst_switch` 是一个结构性封装，拆分为写和读两个子模块：

```
axicb_mst_switch
  │
  ├── axicb_mst_switch_wr  (写通道: AW + W + B)
  │     - AW 仲裁 (Round-Robin)
  │     - W 通道同步 (Grant FIFO)
  │     - B 响应路由 (ID Mask 匹配)
  │
  └── axicb_mst_switch_rd  (读通道: AR + R)
        - AR 仲裁 (Round-Robin)
        - R 响应路由 (ID Mask 匹配)
```

### 6.3 写通道仲裁流程

```
文件: src/axi_crossbar/axicb_mst_switch_wr.sv, 行 90~141

    // 1. 请求源 = 各 Master 的 AWVALID
    assign awch_req = i_awvalid;

    // 2. Round-Robin 仲裁器
    axicb_round_robin #(
        .REQ_NB        (MST_NB),
        .REQ0_PRIORITY (MST0_PRIORITY),
        .REQ1_PRIORITY (MST1_PRIORITY),
        .REQ2_PRIORITY (MST2_PRIORITY),
        .REQ3_PRIORITY (MST3_PRIORITY)
    )
    awch_round_robin (
        .en    (awch_en),
        .req   (awch_req),
        .grant (awch_grant)
    );

    // 3. AWVALID MUX：选择获胜 Master
    assign o_awvalid = (awch_grant[0]) ? i_awvalid[0] :
                       (awch_grant[1]) ? i_awvalid[1] :
                       (awch_grant[2]) ? i_awvalid[2] :
                       (awch_grant[3]) ? i_awvalid[3] : 1'b0;

    // 4. AWREADY 回传：只给获胜 Master
    assign i_awready = awch_grant & {MST_NB{o_awready & !wch_full}};
```

### 6.4 W 通道同步（Grant FIFO）

与 slv_switch 类似，mst_switch 也需要用 FIFO 同步 AW 和 W 通道：

```
文件: src/axi_crossbar/axicb_mst_switch_wr.sv, 行 148~166

    axicb_scfifo #(
        .PASS_THRU  (0),
        .ADDR_WIDTH (8),           // 深度 256
        .DATA_WIDTH (MST_NB)       // 存储 grant 向量
    )
    wch_gnt_fifo
    (
        .data_in  (awch_grant),           // AW 仲裁结果
        .push     (o_awvalid & o_awready), // AW 握手成功时 push
        .data_out (wch_grant),             // W 通道使用
        .pull     (o_wvalid & o_wready & o_wlast), // W 最后一拍 pull
        .empty    (wch_empty)
    );
```

### 6.5 B 响应路由（ID Mask 匹配）

```
文件: src/axi_crossbar/axicb_mst_switch_wr.sv, 行 190~212

    // BCH = {RESP, ID}

    // 用 ID Mask 匹配：这个响应是给哪个 Master 的？
    assign mst0_bch_targeted = ((MST0_ID_MASK & o_bch[0+:AXI_ID_W]) == MST0_ID_MASK);
    assign mst1_bch_targeted = ((MST1_ID_MASK & o_bch[0+:AXI_ID_W]) == MST1_ID_MASK);
    assign mst2_bch_targeted = ((MST2_ID_MASK & o_bch[0+:AXI_ID_W]) == MST2_ID_MASK);
    assign mst3_bch_targeted = ((MST3_ID_MASK & o_bch[0+:AXI_ID_W]) == MST3_ID_MASK);

    // BVALID 只发给匹配的 Master
    assign i_bvalid[0] = (mst0_bch_targeted) ? o_bvalid : 1'b0;
    assign i_bvalid[1] = (mst1_bch_targeted) ? o_bvalid : 1'b0;
    assign i_bvalid[2] = (mst2_bch_targeted) ? o_bvalid : 1'b0;
    assign i_bvalid[3] = (mst3_bch_targeted) ? o_bvalid : 1'b0;

    // BREADY 从匹配的 Master 回传
    assign o_bready = (mst0_bch_targeted) ? i_bready[0] :
                      (mst1_bch_targeted) ? i_bready[1] :
                      (mst2_bch_targeted) ? i_bready[2] :
                      (mst3_bch_targeted) ? i_bready[3] : 1'b0;
```

---

## 7. Pipeline 级

### 7.1 Pipeline 的作用

```
文件: src/axi_crossbar/axicb_switch_top.sv, 行 172~188（slv 侧）
      行 465~481（mst 侧）

每个 Master/Slave 端口有 5 个 pipeline 寄存器（每个通道一个）：

  SLV_PIPELINE 控制 slv 侧 pipeline 深度
  MST_PIPELINE 控制 mst 侧 pipeline 深度

  当 NB_PIPELINE=0 时，直接透传（零延迟）：
    assign o_valid = i_valid;
    assign o_data  = i_data;
    assign i_ready = o_ready;

  当 NB_PIPELINE>0 时，插入寄存器：
    - 改善时序（切断关键路径）
    - 代价：增加延迟（每级 +1 周期）
```

### 7.2 Pipeline 在 Crossbar 中的位置

```
  外部 Master
       │
  ┌────┴─────┐
  │ slv_pipe │  ← SLV_PIPELINE 级（可选）
  └────┬─────┘
       │
  ┌────┴──────────┐
  │  slv_switch   │  地址解码 + W 同步 + B/OoO
  └────┬──────────┘
       │
  ┌────┴─────────────┐
  │  信号重排矩阵     │  纯连线，零延迟
  └────┬─────────────┘
       │
  ┌────┴──────────┐
  │  mst_switch   │  仲裁 + W 同步 + B 路由
  └────┬──────────┘
       │
  ┌────┴─────┐
  │ mst_pipe │  ← MST_PIPELINE 级（可选）
  └────┬─────┘
       │
  外部 Slave
```

---

## 8. 完整路由示例

### 场景：CPU 读 DDR，同时 DMA 写 NPU LMEM

```
时钟周期 T0:

  [CPU → DDR]
    slv0_if: ARADDR=0x4000_0000, ARVALID=1
    slv_switch[0]: 地址解码 → slv_ar_targeted = 4'b0001 (SLV0)
    重排: mst_arvalid[0*4+0] = 1  ← SLV0 收到 CPU 的请求

  [DMA → NPU LMEM]
    slv1_if: AWADDR=0x0000_1000, AWVALID=1
    slv_switch[1]: 地址解码 → slv_aw_targeted = 4'b0010 (SLV1)
    重排: mst_awvalid[1*4+1] = 1  ← SLV1 收到 DMA 的请求

  仲裁:
    mst_switch[0] (DDR): 只有 CPU 请求 → grant = MST0
    mst_switch[1] (LMEM): 只有 DMA 请求 → grant = MST1

  结果: CPU 读 DDR 和 DMA 写 LMEM 同时进行，无冲突！
```

---

## 9. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| 分层路由 | per-Master 解码 → 信号重排 → per-Slave 仲裁 |
| 地址解码 | START_ADDR <= ADDR <= END_ADDR，受 MST_ROUTES 控制 |
| 读写独立 | AW 和 AR 各有独立的解码器，互不阻塞 |
| Grant FIFO | 同步 AW 和 W 通道，确保 W 数据跟随 AW 路由 |
| 误路由 | 地址无命中时生成假握手，响应返回 SLVERR |
| 信号重排 | 纯连线矩阵转置，零延迟，零逻辑门 |
| ID Mask 路由 | 响应通过 ID Mask 匹配路由回正确的 Master |
| Pipeline | 可选的流水线级，0=直通，增加延迟换取时序 |

---

## 10. 动手练习

### 练习 1: 地址解码判断

给定参数：
```
SLV0: 0x4000_0000 ~ 0x4003_FFFF
SLV1: 0x0000_1000 ~ 0x0002_0FFF
MST0_ROUTES = 4'b1111
MST1_ROUTES = 4'b0011  (只能访问 SLV0 和 SLV1)
```

当 DMA (MST1) 发出 ARADDR=0x4000_0000 时：
1. 地址解码结果 `slv_ar_targeted` = ?
2. 最终路由结果 = ?（考虑 MST1_ROUTES）
3. 如果 DMA 发出 ARADDR=0x0003_0000（NPU CSR 地址），结果是什么？

### 练习 2: 信号重排手推

给定以下 slv_awvalid 信号（per-Master 视图）：
```
slv_awvalid[0*4+0] = 1  (MST0→SLV0)
slv_awvalid[0*4+1] = 0
slv_awvalid[0*4+2] = 1  (MST0→SLV2)
slv_awvalid[0*4+3] = 0
slv_awvalid[1*4+0] = 1  (MST1→SLV0)
slv_awvalid[1*4+1] = 1  (MST1→SLV1)
slv_awvalid[1*4+2] = 0
slv_awvalid[1*4+3] = 0
slv_awvalid[2*4+0] = 0
slv_awvalid[2*4+1] = 0
slv_awvalid[2*4+2] = 0
slv_awvalid[2*4+3] = 0
slv_awvalid[3*4+0] = 0
slv_awvalid[3*4+1] = 0
slv_awvalid[3*4+2] = 0
slv_awvalid[3*4+3] = 0
```

计算重排后的 mst_awvalid 信号（per-Slave 视图），并回答：
1. SLV0 收到了几个 Master 的请求？分别是哪些？
2. SLV1 收到了几个 Master 的请求？
3. SLV0 的仲裁器需要在哪些 Master 之间仲裁？

### 练习 3: Grant FIFO 分析

假设 CPU 连续发出 3 个写 burst 到不同的 Slave：
```
Burst 1: AWADDR=0x4000_0000 (SLV0), AWLEN=3 (4拍)
Burst 2: AWADDR=0x0000_1000 (SLV1), AWLEN=7 (8拍)
Burst 3: AWADDR=0x0003_0000 (SLV3), AWLEN=0 (1拍)
```

画出 Grant FIFO 的内容变化时间线：
1. 每个 burst 的 AW 握手时 push 了什么？
2. 每个 burst 的 W 最后一拍时 pull 了什么？
3. FIFO 的最大深度需求是多少？

### 练习 4: 误路由 SLVERR 验证

假设 CPU 发出写请求到地址 0x5000_0000（不在任何 Slave 范围内）：
1. 描述从 AW 握手到 B 响应的完整流程
2. B 响应的 BRESP 值是什么？
3. B 响应的 BID 是什么？（提示：来自 Grant FIFO）

### 练习 5: 代码阅读

阅读 `src/axi_crossbar/axicb_mst_switch_wr.sv` 行 120 和行 180，
回答：
1. AWREADY 为什么包含 `!wch_full` 条件？
2. WREADY 为什么用 `wch_grant` 而不是 `awch_grant`？
3. 如果去掉 `!wch_full` 条件，会产生什么 bug？

---

## 11. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_switch_top.sv` | 交换矩阵顶层（560 行） |
| `src/axi_crossbar/axicb_slv_switch.sv` | Per-Master 路由封装（192 行） |
| `src/axi_crossbar/axicb_slv_switch_wr.sv` | 写通道地址解码+路由（317 行） |
| `src/axi_crossbar/axicb_slv_switch_rd.sv` | 读通道地址解码+路由（290 行） |
| `src/axi_crossbar/axicb_mst_switch.sv` | Per-Slave 仲裁封装 |
| `src/axi_crossbar/axicb_mst_switch_wr.sv` | 写通道仲裁+路由 |
| `src/axi_crossbar/axicb_mst_switch_rd.sv` | 读通道仲裁+路由 |
| `src/axi_crossbar/axicb_round_robin.sv` | Round-Robin 仲裁器 |
| `src/axi_crossbar/axicb_slv_ooo.sv` | 乱序完成管理器 |
