# Lecture 02: AXI4 协议基础 -- 五通道握手

## 课程目标

本讲深入讲解 AMBA AXI4 协议的核心机制。学完本讲后，你将能够：

1. 画出 AXI4 五通道的信号连接图
2. 解释 Valid/Ready 握手的三条规则
3. 区分 INCR、FIXED、WRAP 三种突发类型
4. 理解 4KB 边界限制及其工程原因
5. 阅读本项目中的 AXI 类型定义文件

---

## 1. 为什么需要 AXI？

在 SoC 中，CPU、DMA、NPU、DDR 控制器等模块需要互相通信。AXI（Advanced eXtensible
Interface）是 ARM AMBA 总线家族中最常用的高性能协议。

```
  +--------+     +--------+     +--------+
  |  CPU   |     |  DMA   |     |  NPU   |
  +---+----+     +---+----+     +---+----+
      |              |              |
      v              v              v
  +------------------------------------------+
  |          AXI Interconnect (Crossbar)     |
  +------------------------------------------+
                    |
                    v
              +-----+-----+
              | DDR Ctrl  |
              +-----------+
```

AXI 相比旧协议（AHB/APB）的核心优势：
- **分离的读/写通道**：读和写可以同时进行
- **突发传输**：一次地址握手可以传多个数据拍
- **乱序完成**：通过 ID 标记支持 out-of-order

---

## 2. 五通道架构

AXI4 协议定义了 **5 个独立通道**（channel），每个通道都有自己的一组信号和独立的
Valid/Ready 握手。

```
  Master                                Slave
  +-------+                            +-------+
  |       | --- AW Channel (写地址) --> |       |
  |       | --- W  Channel (写数据) --> |       |
  |       | <-- B  Channel (写响应) --- |       |
  |       | --- AR Channel (读地址) --> |       |
  |       | <-- R  Channel (读数据) --- |       |
  +-------+                            +-------+
```

### 2.1 通道信号详解

下表列出本项目实际使用的 AXI4 信号定义（来源：`amba_axi_pkg.sv`）。

#### 写地址通道（AW）-- Master 到 Slave

| 信号 | 宽度 | 说明 |
|------|------|------|
| `awid` | 8 bit | 事务 ID，用于乱序匹配 |
| `awaddr` | 32 bit | 起始地址 |
| `awlen` | 8 bit | 突发长度 = awlen+1 拍（0 表示 1 拍） |
| `awsize` | 3 bit | 每拍字节数 = 2^awsize |
| `awburst` | 2 bit | 突发类型：FIXED/INCR/WRAP |
| `awvalid` | 1 bit | Master 表示地址有效 |
| `awready` | 1 bit | Slave 表示可以接收 |

#### 写数据通道（W）-- Master 到 Slave

| 信号 | 宽度 | 说明 |
|------|------|------|
| `wdata` | 32 bit | 写数据 |
| `wstrb` | 4 bit | 字节选通（哪几个字节有效） |
| `wlast` | 1 bit | 最后一拍标志 |
| `wvalid` | 1 bit | Master 表示数据有效 |
| `wready` | 1 bit | Slave 表示可以接收 |

#### 写响应通道（B）-- Slave 到 Master

| 信号 | 宽度 | 说明 |
|------|------|------|
| `bid` | 8 bit | 与 awid 对应 |
| `bresp` | 2 bit | 响应码：OKAY/EXOKAY/SLVERR/DECERR |
| `bvalid` | 1 bit | Slave 表示响应有效 |
| `bready` | 1 bit | Master 表示可以接收 |

#### 读地址通道（AR）-- Master 到 Slave

| 信号 | 宽度 | 说明 |
|------|------|------|
| `arid` | 8 bit | 事务 ID |
| `araddr` | 32 bit | 起始地址 |
| `arlen` | 8 bit | 突发长度 |
| `arsize` | 3 bit | 每拍字节数 |
| `arburst` | 2 bit | 突发类型 |
| `arvalid` | 1 bit | Master 表示地址有效 |
| `arready` | 1 bit | Slave 表示可以接收 |

#### 读数据通道（R）-- Slave 到 Master

| 信号 | 宽度 | 说明 |
|------|------|------|
| `rid` | 8 bit | 与 arid 对应 |
| `rdata` | 32 bit | 读数据 |
| `rresp` | 2 bit | 响应码 |
| `rlast` | 1 bit | 最后一拍标志 |
| `rvalid` | 1 bit | Slave 表示数据有效 |
| `rready` | 1 bit | Master 表示可以接收 |

---

## 2.1+ 设计视角：为什么这样设计？

AXI4 协议的设计并非随意，每一个特性都对应着具体的工程需求和权衡。

### 核心设计决策

#### 决策1：为什么用5个通道而不是1个？

```text
问题：Master和Slave之间需要传输哪些信息？

  写操作需要传输：
    1. 写地址（告诉Slave写到哪里）
    2. 写数据（实际要写入的值）
    3. 写响应（Slave确认写入完成）

  读操作需要传输：
    1. 读地址（告诉Slave从哪里读）
    2. 读数据（Slave返回的值）

方案A：单一通道（时分复用）
  - 所有信息通过一根总线传输
  - 同一时刻只能传一种信息
  - 简单，但吞吐量低

方案B：读写分离通道（AHB的做法）
  - 写通道：地址+数据+响应共享
  - 读通道：地址+数据共享
  - 读写可以并行，但写操作内部仍串行

方案C：5通道分离（AXI4的选择）
  - 写地址、写数据、写响应各自独立
  - 读地址、读数据各自独立
  - 最大化并行度
```

**选择理由**：

| 对比维度 | 方案A：单通道 | 方案B：读写分离 | 方案C：5通道（AXI4） |
|----------|-------------|---------------|-------------------|
| 并行度 | 低 | 中 | 最高 |
| 信号线数 | 最少 | 中等 | 最多 |
| 吞吐量 | 低 | 中 | 高 |
| 设计复杂度 | 低 | 中 | 高 |
| 典型协议 | SPI | AHB | AXI4 |

#### 决策2：为什么用 Valid/Ready 握手？

```text
问题：Master和Slave的速度不同，如何协调？

方案A：固定时序（无握手）
  - 假设Slave总能在N个周期内响应
  - 如果Slave偶尔慢了，数据丢失
  - 不可靠

方案B：仅用Valid信号
  - Master发Valid表示数据有效
  - Slave必须在同一周期接收
  - Slave没有反压能力

方案C：Valid/Ready双向握手（AXI4选择）
  - Master发Valid表示数据有效
  - Slave发Ready表示可以接收
  - 两者同时为1时完成传输
  - 双方都有控制权
```

**Valid/Ready的优势**：
- Master可以提前准备好数据（Valid早于Ready）
- Slave可以提前表示就绪（Ready早于Valid）
- 支持反压：Slave忙时不发Ready，Master保持Valid等待
- 无死锁风险（遵守三条黄金规则时）

#### 决策3：为什么支持Burst传输？

```text
问题：传输一块连续数据需要多少次地址握手？

方案A：无Burst（逐拍传输）
  - 每传一个数据都需要发一次地址
  - 传输64字节需要16次地址握手（每次4字节）
  - 地址开销 = 16/16 = 100%

方案B：Burst传输（AXI4选择）
  - 发一次地址，传N个数据
  - 传输64字节只需1次地址握手（16拍burst）
  - 地址开销 = 1/16 = 6.25%
  - 带宽利用率提升约16倍
```

### 设计约束清单

```text
┌─────────────────────────────────────────────────────────┐
│                    AXI4 协议设计约束                      │
├───────────────┬─────────────────────────────────────────┤
│ 物理约束       │ 信号线数量受布线面积限制                   │
│ 时序约束       │ 握手信号路径不能太长（影响Fmax）            │
│ 兼容性约束     │ 需要向后兼容AHB/APB                       │
│ 扩展性约束     │ 需要支持不同数据宽度（8/16/32/64/128bit）  │
│ 互操作性约束   │ 不同厂商的IP需要能互连                     │
│ 验证约束       │ 协议规则必须无歧义，可形式化验证            │
└───────────────┴─────────────────────────────────────────┘
```

---

## 2.2+ 设计视角：如何从零开始设计？

假设你需要从零设计一个总线协议，以下是推荐的设计流程：

### Step 1：分析传输需求

```text
输入：系统中有哪些模块？它们需要传输什么数据？

分析：
  ┌──────────┬──────────────┬──────────────┐
  │ 模块      │ 传输类型      │ 带宽需求      │
  ├──────────┼──────────────┼──────────────┤
  │ CPU      │ 寄存器读写    │ 低（单拍）     │
  │ DMA      │ 大块数据搬运  │ 高（burst）    │
  │ NPU      │ 权重加载      │ 中（burst）    │
  │ DDR      │ 程序+数据存储  │ 高（burst）    │
  └──────────┴──────────────┴──────────────┘

结论：需要支持单拍和burst两种模式
```

### Step 2：定义通道结构

```text
基于传输需求，定义必要的通道：

  写操作需要：
    - 写地址通道（独立，可提前发送地址）
    - 写数据通道（独立，可与地址并行或延迟发送）
    - 写响应通道（独立，Slave可异步返回确认）

  读操作需要：
    - 读地址通道（独立）
    - 读数据通道（独立，Slave可按任意顺序返回）

  共5个通道，每个通道独立握手。
```

### Step 3：设计握手机制

```text
核心问题：如何让速度快的模块不丢失数据，速度慢的模块能反压？

设计Valid/Ready握手：
  1. 定义Valid信号（数据发送方驱动）
  2. 定义Ready信号（数据接收方驱动）
  3. 定义握手完成条件：valid && ready 同时为1
  4. 制定三条黄金规则防止死锁

时序验证：
  - 场景1：Valid先于Ready → 数据保持到Ready到来
  - 场景2：Ready先于Valid → 接收方等待数据到来
  - 场景3：同时有效 → 单周期完成
```

### Step 4：设计Burst机制

```text
如何高效传输连续数据？

参数设计：
  - awlen: burst长度（0=1拍, 255=256拍）
  - awsize: 每拍字节数（2^size）
  - awburst: 地址变化模式（FIXED/INCR/WRAP）

地址计算：
  FIXED: addr[i] = base（用于FIFO）
  INCR:  addr[i] = base + i × 2^size（用于连续内存）
  WRAP:  addr[i] = (base + i × 2^size) 对齐回卷（用于Cache）
```

### Step 5：添加边界约束

```text
实际工程问题：
  - Slave通常按页管理内存（4KB页）
  - 一个burst跨越页边界会导致路由混乱
  - 解决方案：限制单个burst不能跨越4KB边界

  如果需要传输跨越4KB的数据：
    → 由Master（如DMA）拆分为多个不跨界的burst
```

---

## 2.3+ 设计视角：架构模式与原则

AXI4协议中蕴含了多个可复用的设计模式，这些模式在其他硬件设计中同样适用。

### 模式1：Valid/Ready 握手模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: Valid/Ready 双向握手 (Decoupled Handshake)     │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将数据传输分为"数据有效"和"接收就绪"两个独立信号，        │
│   任何一方都可以先就绪，握手在两者同时有效时完成。           │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   always @(posedge clk) begin                           │
│     if (valid && ready) begin                           │
│       // 握手完成，传输数据                               │
│       data_out <= data_in;                              │
│     end                                                 │
│   end                                                   │
│                                                         │
│   // Valid一旦拉高，必须保持到握手完成                      │
│   // Ready可以随时变化                                    │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   AXI4所有5个通道都使用此模式                              │
│   axi_lite2axi桥中：awvalid在SEND状态拉高，               │
│   等待awready后才清除                                     │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - Stream接口（AXI-Stream）                              │
│   - FIFO读写接口                                         │
│   - 任何需要流量控制的数据传输                             │
│   - NoC（Network on Chip）中的包传输                      │
└─────────────────────────────────────────────────────────┘
```

### 模式2：Burst 传输模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 地址+数据解耦的Burst传输                        │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   将"告诉去哪里"（地址）和"实际搬运"（数据）解耦，           │
│   一次地址握手驱动多次数据传输，减少地址开销。               │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   1. 地址通道：发送base_addr + len + size + burst         │
│   2. 数据通道：连续发送len+1个数据拍                       │
│   3. 最后一拍设置wlast/rlast标志                          │
│   4. 从设备内部用计数器跟踪burst进度                       │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   DMA搬运4096字节：                                      │
│     - awlen=255, awsize=2 (4B/拍), 256拍 × 4B = 1024B   │
│     - 需要4个burst完成4096字节                            │
│     - 每个burst内部连续传输，无需重新发地址                 │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - DMA控制器的流式数据搬运                               │
│   - DDR控制器的行缓冲填充                                 │
│   - GPU的纹理加载                                        │
│   - 任何大块连续数据传输                                  │
└─────────────────────────────────────────────────────────┘
```

### 模式3：4KB 边界约束模式

```text
┌─────────────────────────────────────────────────────────┐
│ 模式名称: 页边界约束的事务拆分 (Page-Boundary Splitting)  │
├─────────────────────────────────────────────────────────┤
│ 核心思想:                                                │
│   在协议层强制约束单个事务不能跨越内存页边界，               │
│   简化从设备的地址解码和缓冲管理。                          │
│   需要跨越边界时，由主设备拆分为多个事务。                   │
├─────────────────────────────────────────────────────────┤
│ 关键实现:                                                │
│   协议约束：一个burst的所有拍必须在同一个4KB页内             │
│                                                         │
│   主设备拆分逻辑：                                        │
│     remaining = total_bytes;                             │
│     while (remaining > 0) {                              │
│       page_left = 4096 - (addr % 4096);                 │
│       burst_bytes = min(remaining, page_left);           │
│       burst_bytes = min(burst_bytes, 256 * beat_size);  │
│       issue_burst(addr, burst_bytes);                    │
│       addr += burst_bytes;                               │
│       remaining -= burst_bytes;                          │
│     }                                                    │
├─────────────────────────────────────────────────────────┤
│ 本项目实例:                                              │
│   DMA streamer中实现了4KB边界拆分：                       │
│     dma_streamer.sv 计算每个burst不跨界的最大长度           │
├─────────────────────────────────────────────────────────┤
│ 复用场景:                                                │
│   - 任何按页管理的存储系统                                │
│   - PCIe的Max Read Request Size限制                      │
│   - RDMA的Memory Region边界检查                          │
│   - 虚拟内存系统的页边界处理                              │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 本项目中的类型定义

### 3.1 宏定义文件 `amba_axi.svh`

**文件路径**: `src/dma/inc/amba_axi.svh`

该文件通过宏定义总线宽度参数，可在编译时被覆盖：

```systemverilog
// src/dma/inc/amba_axi.svh (第 5-43 行)
`ifndef AXI_ADDR_WIDTH
  `define AXI_ADDR_WIDTH        32
`endif

`ifndef AXI_DATA_WIDTH
  `define AXI_DATA_WIDTH        32
`endif

`ifndef AXI_ALEN_WIDTH
  `define AXI_ALEN_WIDTH        8
`endif

`ifndef AXI_ASIZE_WIDTH
  `define AXI_ASIZE_WIDTH       3
`endif

`ifndef AXI_TXN_ID_WIDTH
  `define AXI_TXN_ID_WIDTH      8
`endif
```

**知识点**: 使用 `` `ifndef`` 保护允许在编译命令行（如 `+define+AXI_DATA_WIDTH=64`）
覆盖默认值，实现参数化设计。

### 3.2 Package 文件 `amba_axi_pkg.sv`

**文件路径**: `src/dma/inc/amba_axi_pkg.sv`

该文件定义了整个项目使用的 AXI 类型系统。

#### Size 枚举（第 14-24 行）

```systemverilog
typedef enum logic [`AXI_ASIZE_WIDTH-1:0] {
  AXI_BYTE,        // 3'b000 = 1 字节
  AXI_HALF_WORD,   // 3'b001 = 2 字节
  AXI_WORD,        // 3'b010 = 4 字节
  AXI_DWORD,       // 3'b011 = 8 字节
  AXI_BYTES_16,    // 3'b100 = 16 字节
  AXI_BYTES_32,    // 3'b101 = 32 字节
  AXI_BYTES_64,    // 3'b110 = 64 字节
  AXI_BYTES_128    // 3'b111 = 128 字节
} axi_size_t;
```

**知识点**: `awsize` / `arsize` 的值等于 `log2(字节数)`。对于 32 位数据总线，
常用 `AXI_WORD`（值为 2，即 2^2 = 4 字节）。

#### Burst 枚举（第 26-31 行）

```systemverilog
typedef enum logic [1:0] {
  AXI_FIXED,     // 2'b00
  AXI_INCR,      // 2'b01
  AXI_WRAP,      // 2'b10
  AXI_RESERVED   // 2'b11
} axi_burst_t;
```

#### Response 枚举（第 33-38 行）

```systemverilog
typedef enum logic [1:0] {
  AXI_OKAY,      // 2'b00 - 成功
  AXI_EXOKAY,    // 2'b01 - 独占访问成功
  AXI_SLVERR,    // 2'b10 - 从设备错误
  AXI_DECERR     // 2'b11 - 解码错误（地址不存在）
} axi_resp_t;
```

#### Protection 枚举（第 40-44 行）

```systemverilog
typedef enum logic [2:0] {
  AXI_INSTRUCTION = 'b100,  // 指令访问
  AXI_NONSECURE   = 'b010,  // 非安全访问
  AXI_SECURE      = 'b001   // 安全访问
} axi_prot_t;
```

#### Master-In-Slave-Out 结构体 `s_axi_miso_t`（第 52-71 行）

```systemverilog
typedef struct packed {
  logic           awready;     // 写地址通道就绪
  axi_tid_t       bid;         // 写响应 ID
  axi_resp_t      bresp;       // 写响应
  axi_user_rsp_t  buser;       // 用户响应信号
  logic           bvalid;      // 写响应有效
  logic           arready;     // 读地址通道就绪
  axi_tid_t       rid;         // 读数据 ID
  axi_data_t      rdata;       // 读数据
  axi_resp_t      rresp;       // 读响应
  logic           rlast;       // 读最后一拍
  axi_user_req_t  ruser;       // 用户信号
  logic           rvalid;      // 读数据有效
} s_axi_miso_t;
```

**知识点**: `packed struct` 在综合时被展平为一根宽总线，方便模块端口连接。
`s_axi_miso_t` 包含了 Slave 返回给 Master 的所有信号（即 AW/W/AR 的 ready 和
B/R 通道的全部信号）。

#### Master-Out-Slave-In 结构体 `s_axi_mosi_t`（第 73-111 行）

```systemverilog
typedef struct packed {
  axi_tid_t       awid;
  axi_addr_t      awaddr;
  axi_alen_t      awlen;
  axi_size_t      awsize;
  axi_burst_t     awburst;
  logic           awlock;
  logic [3:0]     awcache;
  axi_prot_t      awprot;
  logic [3:0]     awqos;
  logic [3:0]     awregion;
  axi_user_req_t  awuser;
  logic           awvalid;
  // -- 写数据通道 --
  axi_data_t      wdata;
  axi_wr_strb_t   wstrb;
  logic           wlast;
  axi_user_data_t wuser;
  logic           wvalid;
  logic           bready;
  // -- 读地址通道 --
  axi_tid_t       arid;
  axi_addr_t      araddr;
  axi_alen_t      arlen;
  axi_size_t      arsize;
  axi_burst_t     arburst;
  logic           arlock;
  logic [3:0]     arcache;
  axi_prot_t      arprot;
  logic [3:0]     arqos;
  logic [3:0]     arregion;
  axi_user_req_t  aruser;
  logic           arvalid;
  logic           rready;
} s_axi_mosi_t;
```

**注意第 88 行注释**: `//logic wid; //Only on AXI3` -- AXI4 中移除了 `wid` 信号，
要求写数据必须与写地址顺序相同。

---

## 4. Valid/Ready 握手机制

AXI 所有 5 个通道都使用相同的 Valid/Ready 握手机制来传输数据。

### 4.1 三条黄金规则

```
规则 1: Valid 信号不能等待 Ready 信号
        （Master 发出 valid 后，不能因为 slave 没给 ready 就撤回）

规则 2: Ready 可以在 Valid 之前、之后、或同时有效

规则 3: 握手完成的条件：valid && ready 同时为 1（在时钟上升沿）
```

### 4.2 三种握手时序

```
情况 A: Valid 先于 Ready
       ___________                ___________
valid           |________________|
       _______________
ready              |______________|
                   ^
                   | 此处握手完成 (valid=1 && ready=1)


情况 B: Ready 先于 Valid
       _______________
ready              |______________|
       ___________                ___________
valid           |________________|
                   ^
                   | 此处握手完成


情况 C: Valid 和 Ready 同时有效
       ___________                ___________
valid           |________________|
       ___________                ___________
ready           |________________|
                ^
                | 此处握手完成（单周期完成）
```

### 4.3 代码中的握手机制

在 `axi_lite2axi.sv`（第 109-116 行）中可以看到典型的握手逻辑：

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 109-116 行)
// Slave 端的 ready 信号：只有在 IDLE 状态且缓冲区为空时才接收
assign s_axi_lite_awready = (wr_state == WR_IDLE) && !aw_buf_v;
assign s_axi_lite_wready  = (wr_state == WR_IDLE) && !w_buf_v;

// Master 端的 valid 信号：在 SEND 状态且缓冲区有数据且未发送
assign m_axi_awvalid = (wr_state == WR_SEND) && aw_buf_v && !aw_sent;
assign m_axi_wvalid  = (wr_state == WR_SEND) && w_buf_v  && !w_sent;
```

**分析**:
- `awready` 在 `WR_IDLE` 状态且缓冲区空时为高，表示可以接收地址
- `awvalid` 在 `WR_SEND` 状态且缓冲区有数据时为高，表示要发送地址
- 两者在不同时钟周期出现，实现了"先收后发"的缓冲转换

### 4.4 握手违规的后果

如果违反规则 1（Valid 等待 Ready），可能会导致死锁：

```
错误示例（会导致死锁）:
  always @(posedge clk)
    if (some_condition)
      valid <= 1;  // 只在某个条件下拉高
    else if (ready)
      valid <= 0;  // ready 来了才拉低 -- 违规！
```

**正确做法**: Valid 一旦拉高，必须保持到握手完成（ready 也拉高）才能变低。

---

## 5. 突发传输（Burst Transfer）

AXI 的一个关键特性是**突发传输**：一次地址握手可以传输多个数据拍。

### 5.1 突发参数

```
awlen / arlen  : 突发长度 = 传输拍数 - 1
                （0 = 1拍，1 = 2拍，...，255 = 256拍）

awsize / arsize: 每拍字节数 = 2^size
                （0=1B, 1=2B, 2=4B, 3=8B, ...）

awburst / arburst: 突发类型
```

### 5.2 三种突发类型

#### INCR（递增突发）-- 最常用

```
地址递增，每次增加一个拍的大小。

示例: awaddr=0x1000, awlen=3, awsize=2 (4字节), awburst=INCR

  拍0: 0x1000  ----+
  拍1: 0x1004  ----+-- 地址每次 +4
  拍2: 0x1008  ----+
  拍3: 0x100C  ----+

  +--------+--------+--------+--------+
  | 0x1000 | 0x1004 | 0x1008 | 0x100C |
  +--------+--------+--------+--------+
```

在 `axi_lite2axi.sv`（第 90-91 行）中，桥默认使用 INCR：

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 90-91 行)
assign m_axi_awburst = 2'b01; // INCR
assign m_axi_arburst = 2'b01; // INCR
```

#### FIXED（固定突发）

```
地址不变，始终访问同一个地址。

示例: awaddr=0x2000, awlen=2, awsize=2, awburst=FIXED

  拍0: 0x2000  ----+
  拍1: 0x2000  ----+-- 地址不变
  拍2: 0x2000  ----+

  应用场景: FIFO 访问（每次读写同一个端口地址）
```

#### WRAP（回卷突发）

```
地址递增到边界后回卷到起始边界。

示例: awaddr=0x1004, awlen=3, awsize=2, awburst=WRAP

  回卷边界 = (awlen+1) * 2^awsize = 4 * 4 = 16 字节
  起始对齐地址 = 0x1000 (对齐到 16 字节边界)

  拍0: 0x1004  (起始)
  拍1: 0x1008
  拍2: 0x100C
  拍3: 0x1000  (回卷!)

  地址轨迹:
  0x1000 --> 0x1004 --> 0x1008 --> 0x100C --> 0x1000
                 ^                              |
                 +------- 回卷 -----------------+

  应用场景: Cache line fill（缓存行填充）
```

---

## 6. 4KB 边界限制

### 6.1 规则说明

AXI 协议规定：**一个突发事务不能跨越 4KB 地址边界**。

```
4KB = 4096 字节 = 0x1000

地址空间按 4KB 分页:
  Page 0: 0x0000_0000 ~ 0x0000_0FFF
  Page 1: 0x0000_1000 ~ 0x0000_1FFF
  Page 2: 0x0000_2000 ~ 0x0000_2FFF
  ...
```

### 6.2 为什么是 4KB？

4KB 是大多数系统中内存页的大小。限制突发不跨页可以简化 Slave 端的地址解码和
缓冲管理。如果一个 Slave 只负责一个 4KB 页，跨页突发会导致部分拍发往错误的
Slave。

### 6.3 违反 4KB 边界的示例

```
错误示例:
  awaddr = 0x0FF0
  awlen  = 7    (8 拍)
  awsize = 2    (4 字节/拍)
  总字节 = 8 * 4 = 32 字节

  拍0: 0x0FF0
  拍1: 0x0FF4
  拍2: 0x0FF8
  拍3: 0x0FFC  <-- Page 0 的最后一个地址
  拍4: 0x1000  <-- 跨越 4KB 边界! 违规!
  拍5: 0x1004
  拍6: 0x1008
  拍7: 0x100C

  |<-- Page 0 -->|<-- Page 1 -->|
  0x0FF0 ... 0x0FFF  0x1000 ... 0x100C
                 ^
                 | 4KB 边界
```

### 6.4 DMA 中的 4KB 处理

DMA 控制器需要将大块传输拆分为多个不跨 4KB 边界的突发。例如：

```
用户请求: 从 0x0FF0 传输 32 字节

DMA 内部拆分:
  事务1: addr=0x0FF0, len=3, size=2  (4拍, 16字节, 到 0x0FFF)
  事务2: addr=0x1000, len=3, size=2  (4拍, 16字节, 到 0x100C)
```

---

## 7. 写事务时序详解

### 7.1 单拍写事务

```
时钟:  _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_

AW通道:
awvalid _____|‾‾‾‾‾|_________
awready __________|‾‾‾‾‾|____
awaddr  ========X==========X==
                ^ 握手1

W通道:
wvalid  __________|‾‾‾‾‾|____
wready  __________|‾‾‾‾‾|____
wdata   =========X==========X==
wstrb   =========X==========X==
wlast   __________|‾‾‾‾‾|____
                 ^ 握手2

B通道:
bvalid  ________________|‾‾‾‾‾|___
bready  ________________|‾‾‾‾‾|___
bresp   ===============X========X==
bvalid               ^ 握手3

时间线:  T0    T1    T2    T3    T4    T5
```

### 7.2 多拍突发写事务（awlen=2, 3 拍）

```
时钟:  _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_

AW通道:
awvalid _____|‾‾‾‾‾|____________________
awready _____|‾‾‾‾‾|____________________
awaddr  =====X====X======================   (握手 T0)
awlen   =====X=2=X======================   (burst length = 3)

W通道:
wvalid  _____|‾‾‾‾‾‾‾‾‾‾‾‾‾|____________
wready  __________|‾‾‾‾‾‾‾‾‾‾‾‾‾|_______
wdata   =====X====X====X====X====X=======   (3 拍数据)
wlast   ____________________|‾‾‾‾‾|______   (最后一拍)
wstrb   =====X====X====X====X====X=======

        T0    T1    T2    T3    T4    T5

B通道:
bvalid  ________________________|‾‾‾‾‾|___
bready  ________________________|‾‾‾‾‾|___
bresp   =======================X=======X==
```

**知识点**: 在 AXI4 中，写数据可以与写地址同时发送，也可以在地址之后发送。
但写数据必须按照地址顺序排列（因为 AXI4 没有 `wid` 信号）。

---

## 8. 读事务时序详解

### 8.1 单拍读事务

```
时钟:  _|‾|_|‾|_|‾|_|‾|_|‾|_

AR通道:
arvalid _____|‾‾‾‾‾|________
arready _____|‾‾‾‾‾|________
araddr  =====X====X=========   (握手 T0)

R通道:
rvalid  __________|‾‾‾‾‾|____
rready  __________|‾‾‾‾‾|____
rdata   =========X====X======
rresp   =========X====X======
rlast   __________|‾‾‾‾‾|____

        T0    T1    T2    T3
```

### 8.2 多拍突发读事务（arlen=2, 3 拍）

```
时钟:  _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_

AR通道:
arvalid _____|‾‾‾‾‾|_____________________
arready _____|‾‾‾‾‾|_____________________
araddr  =====X====X=======================   (握手 T0)

R通道:
rvalid  __________|‾‾‾‾‾‾‾‾‾‾‾‾‾|________
rready  __________|‾‾‾‾‾‾‾‾‾‾‾‾‾|________
rdata   =========X=====X=====X=====X======
rlast   __________________________|‾‾‾‾‾|_

        T0    T1    T2    T3    T4    T5
```

**知识点**: Slave 可以在不同的时钟周期返回读数据，每个拍的 `rvalid` 可以
间隔任意周期（只要不违反协议的 ordering 规则）。

---

## 9. 综合实例：axi_lite2axi 桥的状态机

**文件路径**: `src/axi_crossbar/axi_lite2axi.sv`

该桥将 AXI-Lite 转换为 AXI4，是一个学习状态机驱动握手的好例子。

### 9.1 写通道状态机（第 97-98 行, 第 160-212 行）

```
状态定义:
  WR_IDLE = 2'd0   -- 等待接收 AW 和 W
  WR_SEND = 2'd1   -- 向 AXI4 侧发送 AW 和 W
  WR_RESP = 2'd2   -- 等待 B 响应

状态转移图:

            AW+W 都已缓存
  WR_IDLE ───────────────> WR_SEND
     ^                         |
     |   B 握手完成            | AW+W 都已发送
     +─────────────────────────+
     ^                         |
     |                         | B 响应到达
     +────── WR_RESP <─────────+
```

关键代码片段（第 161-212 行）：

```systemverilog
case (wr_state)
  WR_IDLE: begin
    // 独立捕获 AW 和 W（可以同时到达，也可以先后到达）
    if (s_axi_lite_awvalid && s_axi_lite_awready) begin
      aw_buf_v <= 1'b1;
      awaddr_q <= s_axi_lite_awaddr;
    end
    if (s_axi_lite_wvalid && s_axi_lite_wready) begin
      w_buf_v  <= 1'b1;
      wdata_q  <= s_axi_lite_wdata;
      wstrb_q  <= s_axi_lite_wstrb;
    end
    // 两者都捕获后，转入发送状态
    if ((aw_buf_v || ...) && (w_buf_v || ...)) begin
      wr_state <= WR_SEND;
    end
  end

  WR_SEND: begin
    // 分别跟踪 AW 和 W 的发送状态
    if (!aw_sent && m_axi_awvalid && m_axi_awready) aw_sent <= 1'b1;
    if (!w_sent  && m_axi_wvalid  && m_axi_wready ) w_sent  <= 1'b1;
    // 两者都发送完成后，进入响应等待
    if (aw_sent && w_sent)
      wr_state <= WR_RESP;
  end

  WR_RESP: begin
    // 等待 B 通道握手
    if (b_v && s_axi_lite_bready) begin
      wr_state <= WR_IDLE;
    end
  end
endcase
```

### 9.2 固定信号赋值（第 81-92 行）

```systemverilog
// src/axi_crossbar/axi_lite2axi.sv (第 81-92 行)
localparam [2:0] AXSIZE = $clog2(DATA_WIDTH/8);

assign m_axi_awid    = M_AXI_ID;      // 固定 ID
assign m_axi_wid     = M_AXI_ID;
assign m_axi_arid    = M_AXI_ID;
assign m_axi_awlen   = 8'd0;          // 单拍突发 (len=0, 1拍)
assign m_axi_arlen   = 8'd0;          // 单拍突发
assign m_axi_awsize  = AXSIZE;        // 自动计算: $clog2(32/8) = 2
assign m_axi_arsize  = AXSIZE;
assign m_axi_awburst = 2'b01;         // INCR
assign m_axi_arburst = 2'b01;         // INCR
assign m_axi_wlast   = 1'b1;          // 单拍，永远是最后一拍
```

**知识点**: AXI-Lite 没有 burst 能力，所以桥必须将 `len` 固定为 0（单拍），
`wlast` 固定为 1。`size` 根据 `DATA_WIDTH` 参数自动计算。

---

## 10. 关键知识点总结

| 概念 | 要点 |
|------|------|
| 五通道 | AW(写地址), W(写数据), B(写响应), AR(读地址), R(读数据) |
| Valid/Ready | Valid 不能等 Ready；握手 = valid && ready 同时为 1 |
| awlen | 实际传输拍数 = awlen + 1 |
| awsize | 每拍字节数 = 2^awsize |
| INCR | 地址递增，最常用 |
| FIXED | 地址不变，用于 FIFO |
| WRAP | 地址回卷，用于 Cache |
| 4KB 边界 | 一个突发不能跨越 4KB 地址对齐边界 |
| wlast | 标记写突发的最后一拍 |
| rlast | 标记读突发的最后一拍 |
| ID | 用于乱序和 interleaving（AXI4 中读支持乱序，写必须顺序） |

---

## 11. 动手练习

### 练习 1: 信号计算

给定以下参数，计算每拍的地址序列：
- `awaddr` = 0x8000_0100
- `awlen` = 5（6 拍）
- `awsize` = 2（4 字节）
- `awburst` = INCR

请写出每拍的地址。

<details>
<summary>参考答案</summary>

```
拍0: 0x8000_0100
拍1: 0x8000_0104
拍2: 0x8000_0108
拍3: 0x8000_010C
拍4: 0x8000_0110
拍5: 0x8000_0114
```

</details>

### 练习 2: 4KB 边界检查

以下突发事务是否违反 4KB 边界限制？如果是，请说明如何拆分。
- `awaddr` = 0x0000_0FF8
- `awlen` = 15（16 拍）
- `awsize` = 3（8 字节）

<details>
<summary>参考答案</summary>

```
总字节数 = 16 * 8 = 128 字节
起始地址 = 0x0000_0FF8
结束地址 = 0x0000_0FF8 + 128 - 1 = 0x0000_1077

跨越了 0x1000 边界，违反 4KB 规则!

拆分方案:
  事务1: addr=0x0FF8, 传到 0x0FFF
         字节数 = (0x1000 - 0x0FF8) = 8 字节
         = 1 拍, len=0, size=3

  事务2: addr=0x1000, 剩余 120 字节
         = 15 拍, len=14, size=3
```

</details>

### 练习 3: 代码阅读

阅读 `src/dma/inc/amba_axi_pkg.sv` 中的 `s_axi_mosi_t` 结构体，回答：

1. 写地址通道共有多少个信号？
2. 哪个信号在 AXI3 中存在但 AXI4 中被移除了？（提示：看注释）
3. `awlock` 信号的用途是什么？

<details>
<summary>参考答案</summary>

1. 写地址通道有 12 个信号: awid, awaddr, awlen, awsize, awburst, awlock,
   awcache, awprot, awqos, awregion, awuser, awvalid

2. `wid` 信号在 AXI3 中存在（用于写数据 interleaving），AXI4 中被移除，
   要求写数据必须按顺序发送。

3. `awlock` 用于原子操作（exclusive access 和 locked access）。
   AXI4 中只支持 exclusive（1 bit），不再支持 locked。
```

</details>

### 练习 4: 时序分析

根据下面的波形，判断这是一个什么类型的事务，并画出完整的时序图：

```
T0: awvalid=1, awready=0, awaddr=0x4000, awlen=1, awsize=2
T1: awvalid=1, awready=1
T2: wvalid=1, wready=1, wdata=0xAABBCCDD, wlast=0
T3: wvalid=1, wready=1, wdata=0x11223344, wlast=1
T4: bvalid=0, bready=1
T5: bvalid=1, bready=1, bresp=0
```

<details>
<summary>参考答案</summary>

这是一个 2 拍 INCR 写突发。

```
T0: AW 握手未完成（ready=0）
T1: AW 握手完成，地址 0x4000，burst len=1（2拍），size=2（4B）
T2: W 第 1 拍握手，数据 0xAABBCCDD
T3: W 第 2 拍握手，数据 0x11223344，wlast=1 表示最后一拍
T4: 等待 B 响应
T5: B 握手完成，bresp=0（OKAY）
```

</details>

---

## 12. 参考资料

| 文件 | 路径 | 内容 |
|------|------|------|
| AXI 宏定义 | `src/dma/inc/amba_axi.svh` | 总线宽度参数 |
| AXI 类型包 | `src/dma/inc/amba_axi_pkg.sv` | 所有 AXI 类型定义 |
| AXI-Lite->AXI 桥 | `src/axi_crossbar/axi_lite2axi.sv` | 协议转换桥实现 |

---

*下一讲: [Lecture 03 - AXI-Lite 与协议转换桥](lecture_03_axi_lite_bridge.md)*
