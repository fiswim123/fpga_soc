# Lecture 11: DMA CSR -- 寄存器文件的实现

## 课程目标

本讲逐行分析 `dma_csr.sv` 的实现细节。学完本讲后，你将能够：

- 理解 AXI-Lite 写通道的 AW/W 握手解耦机制
- 掌握字节选通（write strobe）的硬件实现
- 理解读通道的组合逻辑解码
- 掌握双描述符寄存器的索引编码
- 能够独立实现一个 AXI-Lite 从接口寄存器文件

---

## 1. 模块概览

### 1.1 端口列表

`dma_csr` 模块定义在 `src/dma/dma_csr.sv` 中，共 348 行。端口分为三组：

```
+----------------------------------------------------------+
|                      dma_csr                             |
|                                                          |
|  AXI4-Lite Slave 接口          DMA 控制/状态接口          |
|  +-------------------+        +---------------------+    |
|  | i_awvalid/ready   |        | o_dma_control_go    |    |
|  | i_awid/addr/prot  |        | o_dma_control_abort |    |
|  | i_wvalid/ready    |        | o_dma_control_max   |    |
|  | i_wdata/strb      |        | i_dma_status_done   |    |
|  | o_bvalid/ready    |        | i_dma_error_*       |    |
|  | o_bresp/bid       |        | o_dma_desc_*        |    |
|  | i_arvalid/ready   |        +---------------------+    |
|  | i_arid/addr/prot  |                                   |
|  | o_rvalid/ready    |                                   |
|  | o_rdata/resp/rid  |                                   |
|  +-------------------+                                   |
+----------------------------------------------------------+
```

### 1.2 参数化设计

```systemverilog
// src/dma/dma_csr.sv, 第 7-10 行
#(
  parameter int ID_WIDTH       = `AXI_TXN_ID_WIDTH,  // 默认 8 位
  parameter int ADDRESS_WIDTH  = `AXI_ADDR_WIDTH,     // 默认 32 位
  parameter int DATA_WIDTH     = `AXI_DATA_WIDTH      // 默认 32 位
)
```

参数化使得 CSR 模块可以适配不同的 AXI 配置。`DATA_WIDTH` 固定为 32 位是 AXI-Lite 标准的要求。

---

## 2. 设计视角：为什么这样设计？

### 2.1 设计动机

```text
核心问题：CPU 如何控制 DMA 的行为？

CPU 需要告诉 DMA：
  - 从哪里读数据（源地址）
  - 写到哪里去（目的地址）
  - 传多少字节（传输量）
  - 什么时候开始（go 信号）
  - 出了怎么办（abort 信号）

这些信息需要一个"控制面板"——这就是 CSR（Control/Status Register）。
CPU 通过写寄存器来配置 DMA，通过读寄存器来查询 DMA 状态。
```

### 2.2 设计备选方案

```text
方案A: AXI-Lite CSR（本设计采用）
  ┌─────────┐   AXI-Lite   ┌─────────┐
  │   CPU   ├──────────────►│  CSR    │──► DMA 控制信号
  └─────────┘   单拍读写    └─────────┘
  优点: 标准协议、接口简单、面积小
  缺点: 每次只能读写一个寄存器
  适用: 寄存器数量 < 64，访问频率不高

方案B: 自定义寄存器接口
  ┌─────────┐   自定义      ┌─────────┐
  │   CPU   ├──────────────►│  CSR    │──► DMA 控制信号
  └─────────┘   req/ack     └─────────┘
  优点: 最简单，面积最小
  缺点: 不通用，换 CPU 需要重新适配
  适用: 专用 SoC，不需要通用性

方案C: DMA 内部自带配置 ROM
  ┌─────────┐              ┌─────────┐
  │   CPU   │   不参与      │  ROM    │──► DMA 控制信号
  └─────────┘              └─────────┘
  优点: 零延迟，无需总线访问
  缺点: 不灵活，每次传输需要重新烧写
  适用: 固定模式的数据搬运

选择 A 的理由：
  1. 赛题强制要求 AXI-Lite memory-mapped 访问
  2. AXI-Lite 是业界标准，学习价值高
  3. CPU 需要动态配置不同的传输参数（源/目的/长度）
```

### 2.3 设计约束清单

```text
┌──────────────────────────────────────────────────────────────┐
│ 约束类型     │ 具体约束                    │ 来源           │
├──────────────────────────────────────────────────────────────┤
│ 协议约束     │ 必须 AXI-Lite               │ 赛题强制要求   │
│ 功能约束     │ 支持 2 个描述符              │ DMA 规格       │
│ 功能约束     │ 支持 go/abort 控制           │ DMA 规格       │
│ 接口约束     │ 32 位数据宽度               │ AXI-Lite 标准  │
│ 接口约束     │ 4 字节地址对齐               │ AXI-Lite 标准  │
│ 时序约束     │ 写响应 3 拍内返回            │ 性能要求       │
│ 时序约束     │ 读响应 2 拍内返回            │ 性能要求       │
│ 可靠性约束   │ STATUS 寄存器包含魔数 0xCAFE │ 自检需求       │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 设计视角：如何从零开始设计？

> 如果让你从空白开始设计这个 CSR 模块，你会怎么思考？以下是设计者的思考过程。

### Step 1: 列出所有寄存器

```text
从 DMA 的功能需求出发，需要以下寄存器：

控制类（CPU → DMA）：
  CONTROL  [0x00]  go(bit0), abort(bit1), max_burst(bit[9:2])

状态类（DMA → CPU）：
  STATUS      [0x08]  done(bit16), error(bit17), signature(bit[15:0]=0xCAFE)
  ERROR_ADDR  [0x10]  出错事务的地址
  ERROR_STATS [0x18]  错误类型/来源

描述符类（CPU → DMA，每组4个寄存器）：
  DESC0.SRC_ADDR  [0x20]  源地址
  DESC0.DST_ADDR  [0x30]  目的地址
  DESC0.NUM_BYTES [0x40]  传输字节数
  DESC0.CFG       [0x50]  wr_mode, rd_mode, enable
  DESC1.xxx       [0x24/0x34/0x44/0x54]  描述符1（同结构）

设计原则：
  - 地址 4 字节对齐（AXI-Lite 要求）
  - 控制/状态分离（RW vs RO）
  - 触发信号自清零（go 写 1 后硬件自动清零）
```

### Step 2: 设计写通道状态机

```text
关键问题：AXI-Lite 的 AW 和 W 通道是独立的，它们可以以任意顺序到达。

场景分析：
  情况1: AW 先到，W 后到 → 需要暂存 AW 地址，等待 W 数据
  情况2: W 先到，AW 后到 → 需要暂存 W 数据，等待 AW 地址
  情况3: AW 和 W 同时到达 → 可以立即执行写操作

解决方案：用两个 hold 寄存器分别暂存先到达的通道。

  ┌─────────────────────────────────────────────────────────┐
  │                    写通道状态机                          │
  │                                                         │
  │  IDLE ──(AW先到)──► HOLD_AW ──(W到)──► EXEC ──► IDLE    │
  │    │                                                   │
  │    ├──(W先到)──► HOLD_W ──(AW到)──► EXEC ──► IDLE       │
  │    │                                                   │
  │    └──(同时到)──► EXEC ──► IDLE                          │
  └─────────────────────────────────────────────────────────┘

这是 AXI-Lite 从接口的标准设计模式，掌握后可复用于任何 CSR 模块。
```

### Step 3: 设计读通道逻辑

```text
读操作比写操作简单——只有 AR 和 R 两个通道，不存在"谁先到"的问题。

设计决策：读数据什么时候返回？
  方案A: AR 握手后 1 拍返回（本设计采用）
  方案B: AR 握手后立即返回（组合逻辑，时序差）
  方案C: AR 握手后 N 拍返回（用于外部存储器）

选择 A 的理由：1 拍延迟，平衡时序和性能。
对于 CSR 来说，1 拍延迟完全可以接受（CPU 本身也有流水线）。
```

### Step 4: 设计地址解码

```text
地址解码的核心：用地址的低位选择目标寄存器。

  addr[7:0] → 256 个可能的地址 → 映射到 ~20 个寄存器

实现方式：
  always_comb begin
    case (addr[7:0])
      8'h00: ... // CONTROL
      8'h08: ... // STATUS
      8'h10: ... // ERROR_ADDR
      ...
      default: SLVERR  // 未知地址
    endcase
  end

设计要点：
  - 用 addr[7:2]（6位）作为索引，因为 addr[1:0]=00（4字节对齐）
  - 未命中的地址必须返回 SLVERR（不能静默忽略）
  - case 语句必须有 default 分支
```

### Step 5: 验证策略

```text
CSR 模块的验证重点：

1. 功能正确性
   - 写入寄存器后读回，值是否一致？
   - 字节选通是否正确工作？
   - 自清零信号是否正确脉冲？

2. 协议合规性
   - valid/ready 握手是否符合 AXI 规范？
   - 错误地址是否返回 SLVERR？
   - 响应是否在规定拍数内返回？

3. 边界条件
   - 同时读写同一地址？
   - 非对齐地址访问？
   - 写入只读寄存器（STATUS）？
```

---

## 4. 设计视角：架构模式与原则

> 这个设计体现了几个通用的架构模式，掌握后可以复用到其他场景。

### 模式 1: AW/W Hold 寄存器解耦

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: AW/W Hold 寄存器解耦                           │
│                                                         │
│ 适用场景: AXI-Lite 从接口需要同时接受独立的 AW 和 W 通道  │
│                                                         │
│ 核心思想: 用两个 hold 寄存器分别暂存先到达的通道数据，     │
│           等两个通道都就绪后再执行写操作。                  │
│                                                         │
│ 关键信号:                                                │
│   aw_hold: AW 通道已暂存（阻止新的 AW 握手）              │
│   w_hold:  W 通道已暂存（阻止新的 W 握手）                │
│   awready: = ~aw_hold（暂存满时不再接受）                 │
│   wready:  = ~w_hold（暂存满时不再接受）                  │
│                                                         │
│ 复用场景: 任何 AXI-Lite 从接口的寄存器文件                 │
│ 例如: NPU CSR、外设配置寄存器、中断控制器                  │
└─────────────────────────────────────────────────────────┘
```

### 模式 2: 地址解码 + case 选择

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 地址解码 + case 多路选择                       │
│                                                         │
│ 适用场景: 多个寄存器通过统一地址空间访问                   │
│                                                         │
│ 核心思想: 地址的低位作为 case 索引，选择目标寄存器。        │
│                                                         │
│ 实现:                                                    │
│   addr[7:2] → 6-bit 索引 → case 语句                    │
│   写操作: case 选择写入目标                               │
│   读操作: case 选择读出源                                 │
│                                                         │
│ 设计要点:                                                │
│   - 必须有 default 分支（返回 SLVERR）                    │
│   - 只读寄存器在写 case 中应忽略或报错                    │
│   - 地址对齐检查放在 case 之前                            │
│                                                         │
│ 复用场景: 任何基于地址映射的寄存器文件                      │
└─────────────────────────────────────────────────────────┘
```

### 模式 3: 自清零触发信号

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 自清零触发信号                                  │
│                                                         │
│ 适用场景: 控制寄存器中的"触发"位（如 go、abort）           │
│                                                         │
│ 问题: CPU 写 go=1 启动 DMA，但如果 go 保持为 1，          │
│       DMA FSM 会反复启动。                                │
│                                                         │
│ 解决: 硬件在检测到 go=1 后，自动将其清零。                 │
│                                                         │
│ 实现:                                                    │
│   if (wr_en && addr==CONTROL && wdata[0])               │
│     reg_go <= 1'b1;       // CPU 写 1，置位              │
│   else if (reg_go)                                      │
│     reg_go <= 1'b0;       // 下一周期自动清零             │
│                                                         │
│ 效果: go 信号只持续 1 个时钟周期，产生单周期脉冲。          │
│                                                         │
│ 复用场景: 任何需要"触发一次"的控制信号                      │
│ 例如: 中断清除、NPU 启动、看门狗喂狗、DMA abort            │
└─────────────────────────────────────────────────────────┘
```

---

## 5. 写通道处理

### 2.1 AW/W 握手解耦机制

AXI-Lite 规范中，写地址（AW）和写数据（W）通道是独立的，它们可以以任意顺序到达。`dma_csr` 使用两个 holding 寄存器来解耦这两个通道：

```systemverilog
// src/dma/dma_csr.sv, 第 88-93 行
logic [ID_WIDTH-1:0]         awid_q;      // 暂存的 AW ID
logic [ADDRESS_WIDTH-1:0]    awaddr_q;    // 暂存的写地址
logic [DATA_WIDTH-1:0]       wdata_q;     // 暂存的写数据
logic [DATA_WIDTH/8-1:0]     wstrb_q;     // 暂存的写选通
logic                        aw_hold;     // AW 已暂存标志
logic                        w_hold;      // W 已暂存标志
```

### 2.2 写通道时序图

```
时钟:   __|``|__|``|__|``|__|``|__|``|__|``|__|``|__
AW:     --<  A0  >----------<  A1  >-----------------
AWVALID:___/```\________________________________________
AWREADY:````````\___/````````````````\___/`````````````
                  ^                    ^
                  aw_hold=1            aw_hold=1

W:      ----------< D0 >--------< D1 >-----------------
WVALID: ___________/```\_____________/```\______________
WREADY: ````````````````\___/``````````````\___/````````
                         ^                  ^
                         w_hold=1           w_hold=1

B:      -------------------< R0 >----< R1 >-------------
BVALID: _______________________/```\_____/```\___________
BREADY: ````````````````````````````````````````````````

写执行:                       ^
                    aw_hold && w_hold && !bvalid_q
                    -> 执行寄存器写入
                    -> bvalid_q = 1
```

### 2.3 AW 通道捕获逻辑

```systemverilog
// src/dma/dma_csr.sv, 第 199-203 行
// capture AW
if (!aw_hold && i_awvalid) begin
  aw_hold  <= 1'b1;           // 标记已暂存
  awid_q   <= i_awid;         // 保存事务 ID
  awaddr_q <= i_awaddr;       // 保存写地址
end
```

关键点：
- 只有在 `aw_hold=0` 时才捕获新的 AW 事务
- 捕获后 `aw_hold` 立即拉高，阻止新的 AW 事务
- `o_awready = ~aw_hold`（第 124 行），当已暂存时不再接受新事务

### 2.4 W 通道捕获逻辑

```systemverilog
// src/dma/dma_csr.sv, 第 206-210 行
// capture W
if (!w_hold && i_wvalid) begin
  w_hold  <= 1'b1;            // 标记已暂存
  wdata_q <= i_wdata;         // 保存写数据
  wstrb_q <= i_wstrb;         // 保存写选通
end
```

与 AW 通道相同的模式：捕获后拉高 `w_hold`，`o_wready = ~w_hold`（第 125 行）。

### 2.5 写执行逻辑

当 AW 和 W 都已暂存，且没有待处理的写响应时，执行写操作：

```systemverilog
// src/dma/dma_csr.sv, 第 213-275 行
if (aw_hold && w_hold && !bvalid_q) begin
  // 地址校验
  if (!fn_addr_high_zero(awaddr_q) || !fn_addr_aligned_4(awaddr_q)) begin
    bresp_q <= AXI_RESP_SLVERR;    // 地址错误 -> Slave Error
  end else begin
    unique case (awaddr_q[7:0])    // 根据低 8 位地址解码
      A_CONTROL: begin
        // 读取旧值，应用 strobe，写入新值
        old_data_v[0]   = reg_go;
        old_data_v[1]   = reg_abort;
        old_data_v[9:2] = reg_max_burst;
        new_data_v      = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
        reg_go          <= new_data_v[0];
        reg_abort       <= new_data_v[1];
        reg_max_burst   <= new_data_v[9:2];
      end
      // ... 其他寄存器
      default: bresp_q <= AXI_RESP_SLVERR;  // 未知地址
    endcase
  end
  bvalid_q <= 1'b1;    // 产生写响应
  aw_hold  <= 1'b0;    // 释放 AW 暂存
  w_hold   <= 1'b0;    // 释放 W 暂存
end
```

### 2.6 写响应握手

```systemverilog
// src/dma/dma_csr.sv, 第 277 行
if (bvalid_q && i_bready) bvalid_q <= 1'b0;
```

当主设备拉高 `bready`，表示已接受响应，清除 `bvalid`。

---

## 3. 字节选通（Write Strobe）处理

### 3.1 fn_apply_wstrb 函数详解

字节选通是 AXI 协议的重要特性，允许主设备只写入数据的特定字节：

```systemverilog
// src/dma/dma_csr.sv, 第 136-147 行
function automatic [DATA_WIDTH-1:0] fn_apply_wstrb(
  input [DATA_WIDTH-1:0] oldv,      // 寄存器旧值
  input [DATA_WIDTH-1:0] newv,      // 写入的新值
  input [DATA_WIDTH/8-1:0] strb     // 字节选通掩码
);
  integer k;
  begin
    fn_apply_wstrb = oldv;           // 从旧值开始
    for (k = 0; k < DATA_WIDTH/8; k = k + 1)
      if (strb[k]) fn_apply_wstrb[k*8 +: 8] = newv[k*8 +: 8];
  end
endfunction
```

### 3.2 字节选通示例

假设要更新 CONTROL 寄存器的 `max_burst` 字段（位 [9:2]），但不影响 `go` 和 `abort`：

```
旧值:     reg_go=1, reg_abort=0, reg_max_burst=0xFF
写入数据: 0x00000002 (只想清除 max_burst 的高位)
wstrb:    0x00000001 (只写最低字节)

fn_apply_wstrb 执行过程:
  oldv = 0x000003FC  (go=1, abort=0, max_burst=0xFF)
  newv = 0x00000002
  strb = 0b0001

  k=0: strb[0]=1, 替换 [7:0]
    结果: 0x00000302
    即: go=1, abort=0, max_burst=0xC0

  最终写入: reg_go=1, reg_abort=0, reg_max_burst=0xC0
```

### 3.3 为什么需要字节选通？

```
场景: 软件只想修改 max_burst，不影响 go 和 abort

无字节选通:
  读取 CONTROL -> 修改 max_burst -> 写回 CONTROL
  问题: 在读和写之间，go/abort 可能被硬件修改（竞态条件）

有字节选通:
  直接写字节 [1] (max_burst 所在的字节)
  go 和 abort 不受影响，无竞态条件
```

---

## 4. 读通道处理

### 4.1 读通道设计

与写通道不同，读通道使用组合逻辑解码，无需 holding 寄存器：

```systemverilog
// src/dma/dma_csr.sv, 第 280-345 行
if (!rvalid_q && i_arvalid) begin
  arid_q  <= i_arid;           // 暂存 AR ID
  rresp_q <= AXI_RESP_OKAY;
  rdata_q <= '0;

  if (!fn_addr_high_zero(i_araddr) || !fn_addr_aligned_4(i_araddr)) begin
    rresp_q <= AXI_RESP_SLVERR;
    rdata_q <= '0;
  end else begin
    unique case (i_araddr[7:0])
      A_CONTROL: begin
        rdata_q[0]   <= reg_go;
        rdata_q[1]   <= reg_abort;
        rdata_q[9:2] <= reg_max_burst;
      end

      A_STATUS: begin
        rdata_q[15:0] <= 16'hCAFE;           // 魔数
        rdata_q[16]   <= i_dma_status_done;  // 来自 FSM
        rdata_q[17]   <= i_dma_error_stats_error_trig;
      end

      A_ERROR_ADDR: rdata_q[31:0] <= i_dma_error_addr_error_addr;

      A_ERROR_STATS: begin
        rdata_q[0] <= i_dma_error_stats_error_type;
        rdata_q[1] <= i_dma_error_stats_error_src;
        rdata_q[2] <= i_dma_error_stats_error_trig;
      end
      // ... 描述符寄存器
      default: begin
        rresp_q <= AXI_RESP_SLVERR;
        rdata_q <= '0;
      end
    endcase
  end
  rvalid_q <= 1'b1;            // 产生读响应
end

if (rvalid_q && i_rready) rvalid_q <= 1'b0;  // 响应被接受
```

### 4.2 读通道时序图

```
时钟:   __|``|__|``|__|``|__|``|__|``|__
AR:     --<  A0  >-----------------------
ARVALID:___/```\___________________________
ARREADY:``````````````````````````````````
              ^
              arvalid 检测，立即解码

R:      --------< D0 >--------------------
RVALID: _________/```\_____________________
RREADY: ````````````````\___/``````````````
                         ^
                         rvalid_q 清除
```

### 4.3 读通道与写通道的对比

| 特性 | 写通道 | 读通道 |
|------|--------|--------|
| 解耦方式 | AW/W holding 寄存器 | 直接解码 |
| 握手延迟 | 需要等待 AW+W 都到达 | 单周期响应 |
| 实现复杂度 | 较高 | 较低 |
| 原因 | AW 和 W 可能不同步到达 | AR 是单一通道 |

---

## 5. 地址校验函数

### 5.1 fn_addr_high_zero -- 高位地址校验

```systemverilog
// src/dma/dma_csr.sv, 第 149-152 行
function automatic logic fn_addr_high_zero(input logic [ADDRESS_WIDTH-1:0] a);
  if (ADDRESS_WIDTH <= 8) fn_addr_high_zero = 1'b1;
  else                    fn_addr_high_zero = (a[ADDRESS_WIDTH-1:8] == '0);
endfunction
```

此函数确保地址的高位为零。对于 32 位地址空间，只检查 `a[31:8]` 是否为零。这防止了对不存在的地址空间的访问。

### 5.2 fn_addr_aligned_4 -- 4字节对齐校验

```systemverilog
// src/dma/dma_csr.sv, 第 155-157 行
function automatic logic fn_addr_aligned_4(input logic [ADDRESS_WIDTH-1:0] a);
  fn_addr_aligned_4 = (a[1:0] == 2'b00);
endfunction
```

AXI-Lite 覀求 4 字节对齐访问。地址的低 2 位必须为零。

### 5.3 fn_desc_is_1 -- 描述符索引判断

```systemverilog
// src/dma/dma_csr.sv, 第 159-169 行
function automatic logic fn_desc_is_1(input logic [7:0] a);
  begin
    unique case (a)
      A_SRC1_32, A_SRC1_64,
      A_DST1_32, A_DST1_64,
      A_NUM1_32, A_NUM1_64,
      A_CFG1_32, A_CFG1_64: fn_desc_is_1 = 1'b1;
      default:              fn_desc_is_1 = 1'b0;
    endcase
  end
endfunction
```

此函数根据寄存器地址判断访问的是描述符 0 还是描述符 1。地址 `0x24/0x28/0x34/0x38/0x44/0x48/0x54/0x58` 对应描述符 1，其余对应描述符 0。

---

## 6. 描述符寄存器的索引编码

### 6.1 双描述符的地址编码

描述符寄存器使用统一的 case 语句处理，通过索引选择描述符：

```systemverilog
// src/dma/dma_csr.sv, 第 236-241 行 (写通道)
A_SRC0, A_SRC1_32, A_SRC1_64: begin
  idx_v = fn_desc_is_1(awaddr_q[7:0]);  // 0 或 1
  old_data_v = {{(DATA_WIDTH-32){1'b0}}, reg_src_addr[idx_v]};
  new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
  reg_src_addr[idx_v] <= new_data_v[31:0];
end
```

### 6.2 索引编码图

```
地址        描述符索引   字段
0x20        0           DESC0.SRC_ADDR
0x24        1           DESC1.SRC_ADDR (32-bit)
0x28        1           DESC1.SRC_ADDR (64-bit HI)

0x30        0           DESC0.DST_ADDR
0x34        1           DESC1.DST_ADDR (32-bit)
0x38        1           DESC1.DST_ADDR (64-bit HI)

0x40        0           DESC0.NUM_BYTES
0x44        1           DESC1.NUM_BYTES (32-bit)
0x48        1           DESC1.NUM_BYTES (64-bit HI)

0x50        0           DESC0.CFG
0x54        1           DESC1.CFG (32-bit)
0x58        1           DESC1.CFG (64-bit HI)
```

### 6.3 CFG 寄存器的位域

```systemverilog
// src/dma/dma_csr.sv, 第 257-266 行
A_CFG0, A_CFG1_32, A_CFG1_64: begin
  idx_v = fn_desc_is_1(awaddr_q[7:0]);
  old_data_v[0] = reg_wr_mode[idx_v];   // 写模式
  old_data_v[1] = reg_rd_mode[idx_v];   // 读模式
  old_data_v[2] = reg_enable[idx_v];    // 使能
  new_data_v = fn_apply_wstrb(old_data_v, wdata_q, wstrb_q);
  reg_wr_mode[idx_v] <= new_data_v[0];
  reg_rd_mode[idx_v] <= new_data_v[1];
  reg_enable[idx_v]  <= new_data_v[2];
end
```

CFG 寄存器只有 3 个有效位：
- 位 [0]: `wr_mode` -- 写模式（0=INCR, 1=FIXED）
- 位 [1]: `rd_mode` -- 读模式（0=INCR, 1=FIXED）
- 位 [2]: `enable`  -- 描述符使能

---

## 7. 输出信号连接

### 7.1 CSR 输出到功能逻辑

```systemverilog
// src/dma/dma_csr.sv, 第 114-122 行
assign o_dma_control_go               = reg_go;
assign o_dma_control_abort            = reg_abort;
assign o_dma_control_max_burst        = reg_max_burst;
assign o_dma_desc_src_addr_src_addr   = reg_src_addr;
assign o_dma_desc_dst_addr_dst_addr   = reg_dst_addr;
assign o_dma_desc_num_bytes_num_bytes = reg_num_bytes;
assign o_dma_desc_cfg_write_mode      = reg_wr_mode;
assign o_dma_desc_cfg_read_mode       = reg_rd_mode;
assign o_dma_desc_cfg_enable          = reg_enable;
```

这些输出信号直接连接到 `dma_axi_wrapper`，再由 wrapper 转换为 `s_dma_desc_t` 结构体传递给功能逻辑。

### 7.2 从功能逻辑输入

```systemverilog
// src/dma/dma_csr.sv, 第 49-53 行 (端口声明)
input  logic                     i_dma_status_done,         // 来自 FSM
input  logic                     i_dma_error_stats_error_trig,
input  logic [31:0]              i_dma_error_addr_error_addr,
input  logic                     i_dma_error_stats_error_type,
input  logic                     i_dma_error_stats_error_src,
```

这些输入信号来自 `dma_fsm` 和 `dma_axi_if`，在读取 STATUS 和 ERROR 寄存器时被采样。

### 7.3 信号流图

```
dma_csr 内部寄存器          输出端口              功能逻辑
+----------------+     +------------------+     +----------------+
| reg_go         |---->| o_dma_control_go |---->| dma_fsm.go     |
| reg_abort      |---->| o_dma_control_ab |---->| dma_fsm.abort  |
| reg_max_burst  |---->| o_dma_control_mb |---->| streamer.maxb  |
| reg_src_addr[] |---->| o_dma_desc_src[] |---->| desc[].src     |
| reg_dst_addr[] |---->| o_dma_desc_dst[] |---->| desc[].dst     |
| reg_num_bytes[]|---->| o_dma_desc_num[] |---->| desc[].num     |
| reg_wr_mode[]  |---->| o_dma_desc_wr[]  |---->| desc[].wr_mode |
| reg_rd_mode[]  |---->| o_dma_desc_rd[]  |---->| desc[].rd_mode |
| reg_enable[]   |---->| o_dma_desc_en[]  |---->| desc[].enable  |
+----------------+     +------------------+     +----------------+

功能逻辑                    输入端口              dma_csr 读取
+----------------+     +------------------+     +----------------+
| fsm.done       |---->| i_dma_status_done|---->| STATUS[16]     |
| axi_if.error   |---->| i_dma_error_*    |---->| ERROR_* 寄存器  |
+----------------+     +------------------+     +----------------+
```

---

## 8. 复位行为

### 8.1 复位值定义

```systemverilog
// src/dma/dma_csr.sv, 第 171-196 行
always_ff @(posedge i_clk or negedge i_rst_n) begin
  if (!i_rst_n) begin
    // AXI 通道状态
    aw_hold   <= 1'b0;
    w_hold    <= 1'b0;
    awid_q    <= '0;
    awaddr_q  <= '0;
    wdata_q   <= '0;
    wstrb_q   <= '0;
    arid_q    <= '0;
    bvalid_q  <= 1'b0;
    bresp_q   <= AXI_RESP_OKAY;
    rvalid_q  <= 1'b0;
    rresp_q   <= AXI_RESP_OKAY;
    rdata_q   <= '0;

    // DMA 控制寄存器
    reg_go        <= 1'b0;         // 不启动
    reg_abort     <= 1'b0;         // 不中止
    reg_max_burst <= 8'hFF;        // 最大突发 255

    // 描述符寄存器
    reg_src_addr  <= '{default:'0};
    reg_dst_addr  <= '{default:'0};
    reg_num_bytes <= '{default:'0};
    reg_wr_mode   <= '0;           // INCR 模式
    reg_rd_mode   <= '0;           // INCR 模式
    reg_enable    <= '0;           // 禁用
  end
```

注意 `reg_max_burst` 的复位值是 `8'hFF`（255），这意味着默认情况下 DMA 可以使用最大 256 beat 的突发。

---

## 9. 完整写操作流程示例

### 9.1 写入 DESC0.SRC_ADDR

假设 CPU 要写入描述符 0 的源地址 `0x1000`：

```
时间   事件                              dma_csr 内部状态
----   ----                              ----------------
T0     AW: addr=0x20, id=0x01            aw_hold=0, i_awvalid=1
       W:  data=0x00001000, strb=0xF     w_hold=0, i_wvalid=1

T1     AW 被捕获                          aw_hold=1, awaddr_q=0x20
       W 被捕获                           w_hold=1, wdata_q=0x1000
       o_awready=0, o_wready=0            awid_q=0x01

T2     aw_hold=1 && w_hold=1              开始写执行
       && !bvalid_q                       fn_addr_high_zero(0x20)=1
                                          fn_addr_aligned_4(0x20)=1
                                          awaddr_q[7:0]=0x20 -> A_SRC0
                                          fn_desc_is_1(0x20)=0 -> idx=0
                                          old_data_v=0x00000000
                                          new_data_v=fn_apply_wstrb(0, 0x1000, 0xF)
                                                    =0x00001000
                                          reg_src_addr[0] <= 0x00001000
                                          bvalid_q <= 1
                                          bresp_q <= OKAY

T3     bvalid_q=1                         o_bvalid=1, o_bresp=OKAY
       主设备拉高 bready                   o_bid=0x01

T4     bvalid_q && bready                 bvalid_q <= 0
       aw_hold <= 0                       释放，准备接受下一次写
       w_hold <= 0
```

---

## 10. 错误处理

### 10.1 写通道错误条件

```systemverilog
// src/dma/dma_csr.sv, 第 222-224 行
if (!fn_addr_high_zero(awaddr_q) || !fn_addr_aligned_4(awaddr_q)) begin
  bresp_q <= AXI_RESP_SLVERR;
end
```

两种情况会导致写错误：
1. 高位地址不为零 -- 访问了不存在的地址空间
2. 地址未 4 字节对齐 -- 违反 AXI-Lite 规范

### 10.2 读通道错误条件

```systemverilog
// src/dma/dma_csr.sv, 第 288-290 行
if (!fn_addr_high_zero(i_araddr) || !fn_addr_aligned_4(i_araddr)) begin
  rresp_q <= AXI_RESP_SLVERR;
  rdata_q <= '0;
end
```

以及未知地址的 case default 分支（第 335-338 行）。

### 10.3 错误响应时序

```
时间   事件                              dma_csr 内部状态
----   ----                              ----------------
T0     AR: addr=0x60 (未知地址)           i_arvalid=1

T1     fn_addr_high_zero=1                case(0x60) -> default
       fn_addr_aligned_4=1                rresp_q <= SLVERR
                                          rdata_q <= 0
                                          rvalid_q <= 1

T2     o_rvalid=1, o_rresp=SLVERR        主设备读取响应
       o_rdata=0x00000000

T3     主设备拉高 rready                   rvalid_q <= 0
```

---

## 11. 动手实验

### 实验 1: 追踪写操作

在仿真中，添加以下打印语句来追踪写操作：

```systemverilog
// 在 dma_csr.sv 的写执行块中添加
always_ff @(posedge i_clk) begin
  if (aw_hold && w_hold && !bvalid_q) begin
    $display("[CSR] Write: addr=0x%02x, data=0x%08x, strb=0x%02x",
             awaddr_q[7:0], wdata_q, wstrb_q);
  end
end
```

### 实验 2: 字节选通实验

编写测试用例，验证字节选通的行为：

```systemverilog
// 测试 1: 写入 CONTROL 寄存器的完整 32 位
// wstrb = 0xF, data = 0x00000301
// 期望: go=1, abort=0, max_burst=0xFF

// 测试 2: 只写入 CONTROL 的低字节
// wstrb = 0x1, data = 0x00000002
// 期望: go=0, abort=1, max_burst=0xFF (不变)

// 测试 3: 只写入 CONTROL 的第 2 字节
// wstrb = 0x2, data = 0x00000100
// 期望: go=1, abort=0, max_burst=0x01
```

### 实验 3: 添加新的寄存器

尝试在 CSR 中添加一个新的只读寄存器 `VERSION`，地址为 `0x04`，值为 `0x00000001`：

```systemverilog
// 1. 添加地址常量
localparam logic [7:0] A_VERSION = 8'h04;

// 2. 在读通道的 case 中添加
A_VERSION: rdata_q[31:0] <= 32'h0000_0001;

// 3. 写通道的 case 中添加 default 处理 (不需要特别处理，只读寄存器)
```

---

## 12. 本讲要点总结

| 要点 | 说明 |
|------|------|
| AW/W 解耦 | 使用 `aw_hold` 和 `w_hold` 两个寄存器独立捕获 AW 和 W 通道 |
| 字节选通 | `fn_apply_wstrb` 函数逐字节应用选通掩码 |
| 读通道 | 组合逻辑解码，单周期响应 |
| 地址校验 | 高位为零 + 4 字节对齐 |
| 描述符索引 | `fn_desc_is_1` 函数根据地址判断描述符编号 |
| 魔数 0xCAFE | STATUS 寄存器的标识，用于硬件检测 |
| 复位值 | `max_burst=0xFF`，其他寄存器清零 |
| 错误处理 | 未知地址或未对齐地址返回 SLVERR |

---

## 13. 下节预告

下一讲（Lecture 12）将深入分析 `dma_fsm.sv` 的实现细节，包括：
- 四状态控制器的状态转换
- 描述符调度与完成跟踪
- 读/写 Streamer 的独立调度
- Abort 处理机制
