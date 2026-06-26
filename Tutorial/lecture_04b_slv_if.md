# Lecture 04b: AXI Crossbar深入（一）-- Slave接口模块

## 课程概要

本讲是 AXI Crossbar 深入系列的第一篇，聚焦于 `axicb_slv_if.sv` -- Crossbar 的
**Slave接口模块**。这个模块位于外部 Master 与 Crossbar 交换矩阵之间，负责将
分散的 AXI 信号**打包**为内部宽总线，并可选地插入 CDC（跨时钟域）或缓冲级。

> **命名提醒**：`slv_if` = "Slave Interface"，是从 Crossbar 自身视角命名的。
> 它是 Crossbar **接收外部 Master 请求**的接口，即 SoC 层面 Master 设备
> （CPU、DMA）连接到 Crossbar 的入口。

---

## 1. slv_if 在 Crossbar 中的位置

### 1.1 系统架构回顾

```
  外部 Master (CPU/DMA)
        │
        │  标准 AXI 信号（分散的 awaddr, awlen, awsize, ...）
        ▼
  ┌─────────────────────────────────────────────────────────┐
  │                    axicb_crossbar_top                    │
  │                                                         │
  │  ┌─────────────┐    ┌──────────────┐    ┌────────────┐ │
  │  │  slv0_if  ──┼──► │              │ ──►│  mst0_if   │ │
  │  │  slv1_if  ──┼──► │ switch_top   │ ──►│  mst1_if   │ │
  │  │  slv2_if  ──┼──► │  (交换矩阵)   │ ──►│  mst2_if   │ │
  │  │  slv3_if  ──┼──► │              │ ──►│  mst3_if   │ │
  │  └─────────────┘    └──────────────┘    └────────────┘ │
  │   本讲聚焦这一层          Lecture 04c        Lecture 04d │
  └─────────────────────────────────────────────────────────┘
        │
        │  打包后的内部总线（i_awch, i_wch, i_arch, ...）
        ▼
  交换矩阵（地址解码 + 仲裁 + 路由）
```

### 1.2 slv_if 的三大职责

```
┌─────────────────────────────────────────────────────────┐
│                  axicb_slv_if 的职责                      │
├──────────┬──────────────────────────────────────────────┤
│ 职责 1   │ 信号打包：分散的 AXI 信号 → 宽内部总线         │
│ 职责 2   │ CDC/缓冲：可选的跨时钟域或同步 FIFO 级         │
│ 职责 3   │ Outstanding 跟踪：通过 FIFO 深度控制并发       │
└──────────┴──────────────────────────────────────────────┘
```

---

## 2. 信号打包机制

### 2.1 为什么要打包？

在 Crossbar 内部，4 个 Master 的信号需要同时传递到交换矩阵。如果保持分散的
AXI 信号，每个 Master 需要约 50 根线，4 个 Master 就是 200 根线。
打包后，每个 Master 只需要 5 根宽总线（AWCH, WCH, BCH, ARCH, RCH）加握手信号。

```
分散信号（打包前）:                    打包后:
  awaddr [31:0]  ─┐                   ┌─────────────────────┐
  awid   [7:0]   ─┤                   │  o_awch [AWCH_W-1:0]│
  awlen  [7:0]   ─┤                   │                     │
  awsize [2:0]   ─┼── 打包 ──────►    │  所有信号拼接在一起  │
  awburst [1:0]  ─┤                   │  一根宽总线          │
  awlock         ─┤                   └─────────────────────┘
  awcache [3:0]  ─┤
  awprot [2:0]   ─┤
  awqos  [3:0]   ─┤
  awregion [3:0] ─┘
```

### 2.2 打包宽度计算

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 41~45

    parameter AWCH_W = 8,   // 写地址通道宽度
    parameter WCH_W  = 8,   // 写数据通道宽度
    parameter BCH_W  = 8,   // 写响应通道宽度
    parameter ARCH_W = 8,   // 读地址通道宽度
    parameter RCH_W  = 8    // 读数据通道宽度
```

实际宽度由上层 `axicb_crossbar_top.sv` 计算（行 694~704）：

```
AXI4 模式下的通道宽度:
  AWCH_W = AXI_ADDR_W + AXI_ID_W + 29 + AUSER_W
         = 32 + 8 + 29 + 0 = 69 bits

  WCH_W  = AXI_DATA_W + AXI_DATA_W/8 + WUSER_W
         = 32 + 4 + 0 = 36 bits

  BCH_W  = AXI_ID_W + 2 + BUSER_W
         = 8 + 2 + 0 = 10 bits

  ARCH_W = AWCH_W = 69 bits

  RCH_W  = AXI_DATA_W + AXI_ID_W + 2 + RUSER_W
         = 32 + 8 + 2 + 0 = 42 bits
```

### 2.3 AW 通道打包（AXI4 模式）

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 176~190

    // AXI4 模式，带 USER 字段
    assign awch = {
        i_awuser,      // [AWCH_W-1 : AWCH_W-AUSER_W]
        i_awregion,    // [68:65]  4-bit
        i_awqos,       // [64:61]  4-bit
        i_awprot,      // [60:58]  3-bit
        i_awcache,     // [57:54]  4-bit
        i_awlock,      // [53]     1-bit
        i_awburst,     // [52:51]  2-bit
        i_awsize,      // [50:48]  3-bit
        i_awlen,       // [47:40]  8-bit
        i_awid,        // [39:32]  8-bit
        i_awaddr       // [31:0]   32-bit
    };
```

打包顺序图解：

```
  AWCH [68:0] 打包布局:
  ┌──────────┬────────┬─────┬──────┬───────┬───────┬────────┬───────┬──────┬─────┬───────────┐
  │ awuser   │awregion│awqos│awprot│awcache│awlock │awburst │awsize │awlen │awid │  awaddr   │
  │ (opt)    │ 4-bit  │4-bit│3-bit │4-bit  │1-bit  │2-bit   │3-bit  │8-bit │8-bit│  32-bit   │
  └──────────┴────────┴─────┴──────┴───────┴───────┴────────┴───────┴──────┴─────┴───────────┘
  高位                                                              低位（地址在最底部）
```

### 2.4 AXI4-Lite 模式简化

当 `AXI_SIGNALING==0` 时，AXI4-Lite 没有 burst 相关信号，打包大幅简化：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 140~172

    // AXI4-Lite 模式
    assign awch = {
        i_awprot,    // 3-bit
        i_awid,      // 8-bit
        i_awaddr     // 32-bit
    };
    // 总计: 43 bits（比 AXI4 的 69 bits 少很多）
```

### 2.5 W/R/B 通道打包与解包

W 通道打包（行 238~244）：
```
    // W 通道打包
    assign wch = {i_wuser, i_wstrb, i_wdata};
    //           可选      4-bit    32-bit  = 36 bits
```

B 通道解包（行 246~252）：
```
    // B 通道解包（注意方向相反：从宽总线拆出信号）
    assign {i_buser, i_bresp, i_bid} = bch;
    //        可选     2-bit   8-bit  = 10 bits
```

R 通道解包（行 254~260）：
```
    // R 通道解包
    assign {i_ruser, i_rdata, i_rresp, i_rid} = rch;
    //        可选    32-bit   2-bit    8-bit  = 42 bits
```

### 2.6 wlast 特殊处理

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 262~268

    if (AXI_SIGNALING==0) begin: AXI4_LITE_WLAST
        assign wlast = 1'b1;     // AXI4-Lite: 始终为 1（单拍传输）
    end else begin: AXI4_WLAST
        assign wlast = i_wlast;  // AXI4: 直接透传
    end
```

---

## 2.1+ 设计视角：为什么这样设计？

### 核心设计决策

#### 决策1：为什么用信号打包而非保持分散？

```text
问题：Crossbar 内部有 4 个 Master × 5 个通道 = 20 组信号需要路由
     如果每组信号保持分散（50+ 根线），内部布线将极其复杂

方案A：保持分散信号
  - 每个 AXI 信号独立路由
  - 优点：调试直观，信号名清晰
  - 缺点：布线数量 = O(MST_NB × 信号数 × SLV_NB)，面积大

方案B：打包为宽总线（本项目选择）
  - 每个通道的所有信号拼接成一根宽总线
  - 优点：布线数量 = O(MST_NB × 通道数 × SLV_NB)，大幅减少
  - 缺点：需要打包/解包逻辑，调试时需手动拆解总线

方案C：分组打包
  - 按功能分组（地址组、控制组、数据组）
  - 折中方案
```

**选择理由**：

| 对比维度 | 方案A：分散信号 | 方案B：全打包 | 方案C：分组打包 |
|----------|--------------|-------------|--------------|
| 布线数量 | 极多 | 少 | 中 |
| 面积 | 大 | 小 | 中 |
| 调试难度 | 低 | 高 | 中 |
| 灵活性 | 高 | 低 | 中 |
| 典型应用 | 小规模互连 | ASIC互连 | FPGA互连 |

#### 决策2：为什么需要 CDC 级？

```text
问题：当 Master 和 Crossbar 工作在不同时钟域时，如何安全传递数据？

场景：
  CPU 工作在 100MHz 时钟域
  Crossbar 工作在 200MHz 时钟域
  直接连接会导致亚稳态（Metastability）

解决方案：异步 FIFO（async_fifo）
  - 写端口连接 Master 时钟域
  - 读端口连接 Crossbar 时钟域
  - 内部使用格雷码指针实现安全的跨域传递
  - 代价：增加 2~3 个时钟周期的延迟
```

#### 决策3：为什么地址要 tie-off 为零？

```text
问题：当 CDC FIFO 为空时，地址总线上的值是什么？

如果没有 tie-off：
  FIFO 空时，输出端的数据可能是 X（仿真）或随机值（硬件）
  → 交换矩阵的地址解码器会看到随机地址
  → 可能误命中某个 Slave，产生虚假请求

解决方案（行 350~354）：
  o_awch[0+:AXI_ADDR_W] = (aw_empty) ? '0 : awch_f[0+:AXI_ADDR_W];
  // FIFO 空时地址强制为 0，非空时正常输出

  为什么选 0 而不是其他值？
  - 0 通常不在任何 Slave 的地址范围内
  - 即使命中，也不会产生有害操作
```

---

## 2.2+ 设计视角：如何设计通道打包接口？

### Step 1：确定通道信号集合

```text
输入：AXI 协议规范

分析：
  写地址通道（AW）：addr, id, len, size, burst, lock, cache, prot, qos, region, user
  写数据通道（W）：data, strb, user
  写响应通道（B）：id, resp, user
  读地址通道（AR）：同 AW
  读数据通道（R）：data, id, resp, last, user

决策：
  - 每个通道独立打包为一根宽总线
  - 打包顺序必须在 slv_if 和 mst_if 之间保持一致
  - 低位放地址/数据（便于位选择），高位放控制信号
```

### Step 2：计算打包宽度

```text
对于每个通道，宽度 = 所有信号位宽之和

  AWCH_W = ADDR_W + ID_W + 8(len) + 3(size) + 2(burst)
          + 1(lock) + 4(cache) + 3(prot) + 4(qos) + 4(region) + AUSER_W

  注意：AXI4-Lite 模式下，burst 相关信号不存在
  → 需要用 generate 根据 AXI_SIGNALING 参数选择不同的打包方式
```

### Step 3：用 generate 实现条件打包

```text
核心模式：双层 generate

  外层：if (AXI_SIGNALING==0) → AXI4-Lite 模式
        else                  → AXI4 模式

  内层：if (USER_SUPPORT>0)   → 包含 USER 字段
        else                  → 不包含 USER 字段

  优点：
    - 编译时确定打包格式，零运行时开销
    - 同一套代码支持 4 种组合（AXI4/Lite × USER开/关）
    - 不需要的信号被优化掉，不浪费面积
```

### Step 4：保持打包/解包一致性

```text
关键约束：slv_if 的打包顺序必须与 mst_if 的解包顺序完全一致！

  slv_if (打包):   awch = {awuser, awregion, ..., awid, awaddr}
  mst_if (解包):   {o_awuser, o_awregion, ..., o_awid, awaddr} = awch

  如果顺序不一致，信号会被错误解读 → 系统功能错误

最佳实践：
  - 将打包/解包的信号顺序定义为文档化的"协议"
  - 或者使用 struct/union 类型（SystemVerilog）自动保证一致性
```

---

## 2.3+ 设计视角：通道打包模式

### 模式：Channel Concatenation Pattern（通道拼接模式）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Channel Concatenation（通道信号拼接）          │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将一个 AXI 通道的所有信号按固定顺序拼接成一根宽总线，    │
│   通过 generate 块根据参数选择不同的拼接格式，             │
│   在模块边界进行打包（入方向）和解包（出方向）。           │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 用 Verilog 拼接操作符 {} 将信号组合                  │
│   2. 用 generate 根据参数选择不同的拼接组合               │
│   3. 打包和解包使用相同的信号顺序                         │
│   4. 可选信号通过 USER_SUPPORT 参数控制是否包含           │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   slv_if: 分散信号 → 打包总线 ({} 拼接)                  │
│   mst_if: 打包总线 → 分散信号 ({} 解构)                  │
│   5 个通道独立打包，宽度由参数计算确定                     │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何需要减少模块间连线的设计                          │
│   - AXI/AHB/APB 桥接器内部                              │
│   - DMA 引擎的描述符传递                                │
│   - 网络路由器的包头压缩                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 3. CDC（跨时钟域）阶段

### 3.1 三种工作模式

`axicb_slv_if` 通过参数组合选择三种互斥的工作模式：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 270~274

    generate
    if (MST_CDC > 0) begin: CDC_STAGE         // 模式 1: 异步 FIFO
    ...
    end else if (MST_OSTDREQ_NUM > 0) begin:  // 模式 2: 同步 FIFO
    ...
    end else begin:                            // 模式 3: 直通
    ...
    endgenerate
```

### 3.2 模式 1：CDC 模式（MST_CDC > 0）

当 Master 和 Crossbar 在不同时钟域时，使用异步 FIFO 进行跨时钟域传输：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 323~356

    async_fifo
    #(
    .DSIZE       (AWCH_W),        // 数据宽度 = 打包后的通道宽度
    .ASIZE       (AW_ASIZE),      // 地址宽度 = log2(OSTDREQ_NUM)
    .FALLTHROUGH ("TRUE")         // 直通模式（空时写入可直接到读出）
    )
    aw_dcfifo
    (
    .wclk    (i_aclk),            // 写时钟 = Master 时钟
    .wrst_n  (i_aresetn),         // 写复位
    .winc    (aw_winc),           // 写使能
    .wdata   (awch),              // 写数据 = 打包后的 AW 通道
    .wfull   (aw_full),           // 写满标志
    .rclk    (o_aclk),            // 读时钟 = Crossbar 时钟
    .rrst_n  (o_aresetn),         // 读复位
    .rinc    (aw_rinc),           // 读使能
    .rdata   (awch_f),            // 读数据
    .rempty  (aw_empty)           // 读空标志
    );
```

CDC 模式下的 5 个 FIFO：

```
┌──────────┬──────────┬───────────┬──────────┬──────────┬────────────┐
│ FIFO     │ 数据宽度 │ 写时钟    │ 读时钟   │ 方向     │ 用途       │
├──────────┼──────────┼───────────┼──────────┼──────────┼────────────┤
│ aw_dcfifo│ AWCH_W   │ i_aclk    │ o_aclk   │ MST→CB   │ 写地址     │
│ w_dcfifo │ WCH_W+1  │ i_aclk    │ o_aclk   │ MST→CB   │ 写数据     │
│ b_dcfifo │ BCH_W    │ o_aclk    │ i_aclk   │ CB→MST   │ 写响应     │
│ ar_dcfifo│ ARCH_W   │ i_aclk    │ o_aclk   │ MST→CB   │ 读地址     │
│ r_dcfifo │ RCH_W+1  │ o_aclk    │ i_aclk   │ CB→MST   │ 读数据     │
└──────────┴──────────┴───────────┴──────────┴──────────┴────────────┘

注意：
  - W 和 R 通道多 1 bit（携带 wlast/rlast）
  - B 和 R 通道方向相反（从 Crossbar 回到 Master）
```

FIFO 深度计算：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 278~296

    localparam AW_ASIZE = $clog2(MST_OSTDREQ_NUM);
    localparam W_ASIZE  = $clog2(MST_OSTDREQ_NUM * MST_OSTDREQ_SIZE);
    localparam B_ASIZE  = $clog2(MST_OSTDREQ_NUM);
    localparam AR_ASIZE = $clog2(MST_OSTDREQ_NUM);
    localparam R_ASIZE  = $clog2(MST_OSTDREQ_NUM * MST_OSTDREQ_SIZE);

    // 所有 ASIZE 最小为 2（FIFO 至少 4 深度）

    // 示例：MST_OSTDREQ_NUM=4, MST_OSTDREQ_SIZE=1
    //   AW_ASIZE = log2(4) = 2  → FIFO 深度 = 4
    //   W_ASIZE  = log2(4×1) = 2 → FIFO 深度 = 4
```

### 3.3 模式 2：缓冲模式（MST_CDC==0, OSTDREQ_NUM > 0）

同 时钟域但需要缓冲时，使用同步 FIFO：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 522~540

    axicb_scfifo
    #(
    .PASS_THRU  (0),              // 非直通模式
    .ADDR_WIDTH (AW_ASIZE),       // 最小为 1（深度 2）
    .DATA_WIDTH (AWCH_W)
    )
    aw_scfifo
    (
    .aclk     (i_aclk),
    .aresetn  (i_aresetn),
    .srst     (i_srst),
    .data_in  (awch),             // 输入 = 打包后的 AW 通道
    .push     (aw_winc),
    .full     (aw_full),
    .data_out (awch_f),           // 输出
    .pull     (aw_rinc),
    .empty    (aw_empty)
    );
```

### 3.4 模式 3：直通模式（MST_CDC==0, OSTDREQ_NUM==0）

没有任何缓冲，信号直接连接：

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 669~700

    // AW 通道直通
    assign o_awvalid = i_awvalid;
    assign i_awready = o_awready;
    assign o_awch    = awch;

    // W 通道直通
    assign o_wvalid  = i_wvalid;
    assign i_wready  = o_wready;
    assign o_wlast   = wlast;
    assign o_wch     = wch;

    // B 通道直通（方向相反）
    assign i_bvalid  = o_bvalid;
    assign o_bready  = i_bready;
    assign bch       = o_bch;

    // AR 通道直通
    assign o_arvalid = i_arvalid;
    assign i_arready = o_arready;
    assign o_arch    = arch;

    // R 通道直通（方向相反）
    assign i_rvalid  = o_rvalid;
    assign o_rready  = i_rready;
    assign i_rlast   = o_rlast;
    assign rch       = o_rch;
```

---

## 4. Outstanding 请求跟踪

### 4.1 FIFO 深度与 Outstanding 的关系

```
MST_OSTDREQ_NUM = 4  → 最多 4 个未完成请求
  → AW FIFO 深度 = 4（可以缓存 4 个写地址）
  → W  FIFO 深度 = 4 × MST_OSTDREQ_SIZE（可以缓存 4 个 burst 的数据）
  → B  FIFO 深度 = 4（可以缓存 4 个写响应）
  → AR FIFO 深度 = 4（可以缓存 4 个读地址）
  → R  FIFO 深度 = 4 × MST_OSTDREQ_SIZE（可以缓存 4 个 burst 的数据）
```

### 4.2 反压机制

当 FIFO 满时，通过 `ready` 信号反压上游：

```
    assign i_awready = ~aw_full;     // FIFO 满时，不接受新请求
    assign aw_winc = i_awvalid & ~aw_full;  // FIFO 满时，不写入
```

当 FIFO 空时，不向下游发送请求：

```
    assign o_awvalid = ~aw_empty;    // FIFO 空时，不向交换矩阵发送
```

### 4.3 地址 Tie-off 防止 X 传播

```
文件: src/axi_crossbar/axicb_slv_if.sv, 行 350~354

    always @ (*) begin
        o_awch[AXI_ADDR_W +: (AWCH_W-AXI_ADDR_W)] =
            awch_f[AXI_ADDR_W +: (AWCH_W-AXI_ADDR_W)];
        // FIFO 空时地址强制为 0，防止 X 传播到地址解码器
        o_awch[0 +: AXI_ADDR_W] = (aw_empty) ? '0 :
                                    awch_f[0 +: AXI_ADDR_W];
    end
```

```
为什么只 tie-off 地址位？
  - 控制信号（len, size 等）不影响路由决策
  - 地址位会进入地址解码器，X 会导致误路由
  - 只需要在 FIFO 空时保护，非空时数据有效
```

---

## 5. 完整数据流示例

### 5.1 CPU 发起写请求的 slv_if 内部流程

```
时间线（CDC 模式，i_aclk=100MHz, o_aclk=200MHz）:

T0 (i_aclk): CPU 发出 AWVALID, AWADDR=0x4000_0000, AWID=0x05

  [信号打包]
    awch = {awregion, awqos, awprot, awcache, awlock,
            awburst, awsize, awlen, awid, awaddr}
         = {4'h0, 4'h0, 3'h0, 4'h0, 1'h0,
            2'h1, 3'h2, 8'h0, 8'h05, 32'h4000_0000}

  [FIFO 写入]
    aw_winc = 1 (awvalid & ~aw_full)
    awch 写入 aw_dcfifo

  [反压]
    i_awready = ~aw_full = 1  ← CPU 可以继续发下一个请求

T1 (o_aclk): FIFO 读出
    awch_f = awch 的值
    o_awvalid = ~aw_empty = 1
    o_awch = {控制信号, awch_f[31:0]}  ← 地址正常输出

T2 (o_aclk): 交换矩阵接收
    地址解码: 0x4000_0000 → SLV0 (DDR)
    o_awready = 1
    aw_rinc = 1 ← FIFO 条目被消费
```

---

## 6. 本讲关键知识点总结

| 知识点 | 要点 |
|--------|------|
| 命名约定 | slv_if 是 Crossbar 接收外部 Master 请求的接口 |
| 信号打包 | 分散 AXI 信号拼接为宽总线，减少内部连线 |
| 打包顺序 | slv_if 打包顺序必须与 mst_if 解包顺序一致 |
| CDC 模式 | 使用 async_fifo 实现跨时钟域传输，5 个 FIFO |
| 缓冲模式 | 使用 sync_fifo 提供同域缓冲，5 个 FIFO |
| 直通模式 | 无缓冲，零延迟，信号直接连接 |
| 地址 Tie-off | FIFO 空时地址强制为 0，防止 X 传播 |
| FIFO 深度 | 由 MST_OSTDREQ_NUM 和 MST_OSTDREQ_SIZE 决定 |

---

## 7. 动手练习

### 练习 1: 打包宽度计算

给定参数：`AXI_ADDR_W=32, AXI_ID_W=8, AXI_DATA_W=32, AUSER_W=0`

计算以下通道的打包宽度（AXI4 模式，无 USER 字段）：
1. AWCH_W = ?
2. WCH_W = ?
3. BCH_W = ?
4. ARCH_W = ?
5. RCH_W = ?

### 练习 2: 打包/解包对应

给定 slv_if 的 AW 通道打包代码（AXI4 模式，无 USER）：
```
awch = {awregion, awqos, awprot, awcache, awlock,
        awburst, awsize, awlen, awid, awaddr}
```

写出 mst_if 中对应的解包代码。

### 练习 3: CDC FIFO 深度分析

```
MST_OSTDREQ_NUM = 8, MST_OSTDREQ_SIZE = 2
```

计算：
1. AW FIFO 的 ASIZE 和实际深度
2. W FIFO 的 ASIZE 和实际深度
3. 如果 CPU 每个时钟周期发 1 个请求，最多可以连续发多少个而不被反压？

### 练习 4: 地址 Tie-off 的必要性

假设去掉地址 tie-off 逻辑（行 350~354），当 FIFO 为空时：
1. 交换矩阵的地址解码器会看到什么？
2. 可能产生什么后果？
3. 如果目标地址范围包含 0x0000_0000，会发生什么？

### 练习 5: 代码阅读

阅读 `src/axi_crossbar/axicb_slv_if.sv` 的 CDC 模式部分（行 274~492），
回答：
1. B 通道和 R 通道的 FIFO 写时钟和读时钟分别是什么？为什么与 AW/W/AR 通道相反？
2. W 通道 FIFO 的数据宽度为什么是 `WCH_W+1` 而不是 `WCH_W`？

---

## 8. 参考源文件

| 文件 | 说明 |
|------|------|
| `src/axi_crossbar/axicb_slv_if.sv` | Slave 接口模块（718 行） |
| `src/axi_crossbar/axicb_mst_if.sv` | Master 接口模块（解包端，详见 Lecture 04d） |
| `src/axi_crossbar/axicb_crossbar_top.sv` 行 694~704 | 通道宽度计算 |
| `src/axi_crossbar/axicb_crossbar_top.sv` 行 756~1134 | slv_if 实例化 |
| `src/axi_crossbar/async_fifo.sv` | 异步 FIFO（CDC 核心） |
| `src/axi_crossbar/axicb_scfifo.sv` | 同步 FIFO（缓冲模式） |
