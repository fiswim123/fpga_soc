# Lecture 04b: AXI Crossbar深入（一）— Slave接口模块

## 课程目标

本讲深入分析 `axicb_slv_if.sv`——Crossbar中连接外部**主设备**（CPU、DMA）的接口模块。

- 理解为什么需要将AXI信号"打包"成通道总线
- 掌握信号打包的位拼接实现
- 理解CDC、缓冲、直通三种工作模式

---

## 1. 模块概览

### 1.1 命名说明

```text
axicb_slv_if 的 "slv" 是从 Crossbar 内部视角命名的：
  - 对 Crossbar 内部来说，这是"Slave接口"（Crossbar是主，这个接口是从）
  - 对外部来说，这是"Master连接点"（外部主设备连接到这里）

本项目连接：
  slv0 ← CPU (PicoRV32)
  slv1 ← DMA Controller
  slv2 ← (未连接)
  slv3 ← (未连接)
```

### 1.2 模块功能

```text
┌─────────────────────────────────────────────────────────┐
│                    axicb_slv_if                         │
│                                                         │
│  外部主设备              →        Crossbar内部           │
│  独立AXI信号                     打包通道总线            │
│  ┌───────────────┐              ┌───────────────┐      │
│  │ i_awvalid     │              │ o_awvalid     │      │
│  │ i_awaddr[31:0]│   打包       │ o_awch[AWCH_W]│      │
│  │ i_awlen[7:0]  │ ──────────► │ o_wvalid      │      │
│  │ i_awid[7:0]   │  (组合逻辑)  │ o_wch[WCH_W]  │      │
│  │ ...           │              │ ...           │      │
│  └───────────────┘              └───────────────┘      │
│                                                         │
│  功能: 独立AXI信号 ↔ 打包通道总线 (零延迟)               │
│  模式: CDC / 缓冲 / 直通                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 设计视角：为什么这样设计？

### 2.1 设计动机

```text
问题：Crossbar内部需要在多个Master和Slave之间路由信号。

直接传递独立信号的问题：
  5通道 × 每通道10+信号 = 50+根线/Master
  4个Master × 50根 = 200根线进入Crossbar
  内部交换矩阵需要200×200的多路选择器 → 面积巨大

解决方案：信号打包
  AW通道: {awregion, awqos, awprot, awcache, awlock, awburst, awsize, awlen, awid, awaddr}
  打包后: 一根 AWCH_W 位宽的总线
  4个Master × 5根通道线 = 只有20根线进入Crossbar
```

### 2.2 方案对比

```text
┌─────────────┬──────────────────┬──────────────┬─────────────┐
│ 方案        │ 原理             │ 优点         │ 缺点        │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ A.信号打包  │ 拼接成宽总线     │ 连线少,面积小│ 需打包逻辑  │
│ (本设计)    │                  │ 时序好       │             │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ B.直连      │ 50+根线/Master   │ 无需打包     │ 连线爆炸    │
│             │                  │              │ 面积大      │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ C.串行化    │ 时间复用一根线   │ 连线最少     │ 延迟大      │
│             │                  │              │ 带宽低      │
└─────────────┴──────────────────┴──────────────┴─────────────┘

选择A：打包是纯组合逻辑(零延迟)，业界标准做法。
```

---

## 3. 设计视角：如何从零开始设计？

### Step 1: 确定打包格式

```text
以AXI4的AW通道为例（本项目: ADDR=32, ID=8）：

  i_awaddr   [31:0]   → 32位
  i_awid     [7:0]    → 8位
  i_awlen    [7:0]    → 8位
  i_awsize   [2:0]    → 3位
  i_awburst  [1:0]    → 2位
  i_awlock            → 1位
  i_awcache  [3:0]    → 4位
  i_awprot   [2:0]    → 3位
  i_awqos    [3:0]    → 4位
  i_awregion [3:0]    → 4位
  ─────────────────────
  总计: 69位 → AWCH_W = 69

打包顺序（低位在前）：
  awch = {awregion, awqos, awprot, awcache, awlock, awburst, awsize, awlen, awid, awaddr}
```

### Step 2: 实现打包（发送方向）

```systemverilog
// src/axi_crossbar/axicb_slv_if.sv, 第 178-190 行
assign awch = {
    i_awregion,   // 最高位
    i_awqos,
    i_awprot,
    i_awcache,
    i_awlock,
    i_awburst,
    i_awsize,
    i_awlen,
    i_awid,
    i_awaddr      // 最低位
};
```

### Step 3: 实现解包（接收方向）

```systemverilog
// src/axi_crossbar/axicb_slv_if.sv, 第 248-250 行
assign {i_bresp, i_bid} = bch;
assign {i_rdata, i_rresp, i_rid} = rch;
```

### Step 4: 选择工作模式

```text
三种模式由参数控制：

模式1: CDC模式 (MST_CDC > 0)
  5个异步FIFO跨时钟域
  适用: 主设备和Crossbar不同时钟

模式2: 缓冲模式 (MST_OSTDREQ_NUM > 0, MST_CDC = 0)
  5个同步FIFO缓冲请求
  适用: 同时钟，需要提升Outstanding

模式3: 直通模式 (MST_CDC = 0, MST_OSTDREQ_NUM = 0)
  信号直接连接，零延迟零面积
  适用: 同时钟，不需要额外缓冲

本项目: 直通模式（所有模块同一时钟）
```

---

## 4. 设计视角：架构模式

### 模式 1: 信号打包（Channel Concatenation）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: 信号打包                                           │
│                                                         │
│ 核心: 将同通道的多个独立信号拼接成一根宽总线              │
│                                                         │
│ 发送端: assign ch = {sig_N, ..., sig_1, sig_0}          │
│ 接收端: assign {sig_N, ..., sig_1, sig_0} = ch          │
│                                                         │
│ 要点: 打包/解包顺序一致，纯组合逻辑，零延迟              │
│ 复用: Crossbar、NoC路由器、总线桥                        │
└─────────────────────────────────────────────────────────┘
```

### 模式 2: 三级模式选择（CDC / Buffer / Passthrough）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: 三级模式选择                                       │
│                                                         │
│ 核心: 用generate块根据参数选择不同实现                   │
│                                                         │
│ generate                                                │
│   if (CDC > 0)        → 异步FIFO                        │
│   else if (OSTD > 0)  → 同步FIFO                        │
│   else                → 直通                            │
│ endgenerate                                             │
│                                                         │
│ 要点: 共享接口定义，模式在综合时确定                     │
└─────────────────────────────────────────────────────────┘
```

---

## 5. 信号打包详解

### 5.1 AXI4 模式打包（本项目使用）

```systemverilog
// src/axi_crossbar/axicb_slv_if.sv, 第 208-219 行
assign awch = {
    i_awregion,  // 最高位
    i_awqos,
    i_awprot,
    i_awcache,
    i_awlock,
    i_awburst,
    i_awsize,
    i_awlen,
    i_awid,
    i_awaddr     // 最低位
};
```

### 5.2 W通道打包

```systemverilog
// 第 240-242 行
assign wch = {i_wstrb, i_wdata};  // 4+32 = 36位
```

### 5.3 B/R通道解包

```systemverilog
// 第 248-259 行
assign {i_bresp, i_bid} = bch;           // B通道解包
assign {i_rdata, i_rresp, i_rid} = rch;  // R通道解包
```

### 5.4 WLAST处理

```systemverilog
// 第 262-268 行
if (AXI_SIGNALING==0)
    assign wlast = 1'b1;      // AXI-Lite: 恒为1
else
    assign wlast = i_wlast;   // AXI4: 透传
```

---

## 6. 三种工作模式详解

### 6.1 CDC模式

```text
主设备时钟域              Crossbar时钟域
┌──────────┐            ┌──────────┐
│ i_aclk   │ 异步FIFO   │ o_aclk   │
│          │─[async]──►│          │
│ i_awvalid│            │ o_awvalid│
│ i_awch   │            │ o_awch   │
└──────────┘            └──────────┘

5个异步FIFO实例（AW/W/B/AR/R各一个）
```

### 6.2 缓冲模式

```text
同时钟，用同步FIFO提升Outstanding能力：
  深度 = MST_OSTDREQ_NUM (本项目=4)
  FIFO类型: axicb_scfifo
```

### 6.3 直通模式（本项目使用）

```systemverilog
// 第 673-699 行
assign o_awvalid = i_awvalid;
assign i_awready = o_awready;
assign o_awch    = awch;        // 打包信号直接输出
assign i_bvalid  = o_bvalid;
assign o_bready  = i_bready;
assign bch       = o_bch;       // 接收信号直接解包
```

---

## 7. 地址清零防X

```systemverilog
// 第 542-546 行
// FIFO为空时，地址输出0，防止解码器看到X值
o_awch[0 +: AXI_ADDR_W] = (aw_empty) ? '0 : awch_f[0 +: AXI_ADDR_W];
```

```text
为什么？FIFO空时输出X → 地址解码器X → 误路由 → 整个Crossbar污染
解决：空时输出地址=0 → 不命中任何Slave → 安全
```

---

## 8. 动手实验

### 实验1: 计算打包位宽

```text
本项目配置: ADDR=32, ID=8, DATA=32, AXI_SIGNALING=1

AW通道位宽 = awaddr(32) + awid(8) + awlen(8) + awsize(3) + awburst(2)
           + awlock(1) + awcache(4) + awprot(3) + awqos(4) + awregion(4) = ?

W通道位宽  = wdata(32) + wstrb(4) = ?
B通道位宽  = bid(8) + bresp(2) = ?
R通道位宽  = rdata(32) + rid(8) + rresp(2) = ?
```

### 实验2: 追踪信号路径

```text
CPU写DMA CSR: i_awaddr=0x00021000
→ slv_if打包: awch = {?,?,...,0x00021000}
→ switch_top路由: 地址解码命中mst2
→ mst_if解包: o_awaddr = 0x00021000
→ DMA CSR接收
```

---

## 9. 本讲要点

| 要点 | 说明 |
|------|------|
| 信号打包 | 独立AXI信号 → 通道总线，减少内部连线 |
| 打包格式 | {高位, ..., 低位}，打包解包顺序必须一致 |
| 三种模式 | CDC(异步FIFO) / 缓冲(同步FIFO) / 直通(零延迟) |
| 地址清零 | FIFO空时输出0，防止X传播 |
| 零延迟 | 打包/解包是纯组合逻辑 |

---

## 10. 下节预告

下一讲分析 `axicb_switch_top.sv`——Crossbar的核心交换矩阵。
