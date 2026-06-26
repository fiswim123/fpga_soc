# Lecture 08: CPU Wrapper — 地址路由与 AXI 适配

> **参考源码**: `src/cpu/picorv32_axi.v`
> **前置知识**: Lecture 07 PicoRV32 核心、Lecture 01 SoC 架构与地址映射
> **本节目标**: 理解 picorv32_axi 如何将 CPU 的简单存储器接口适配为 AXI-Lite 主端口,
>              以及地址路由器如何将访存请求分发到本地 ROM/RAM 或 AXI 总线

---

## 8.1 为什么需要 Wrapper?

PicoRV32 核心对外只暴露一组极简的 valid/ready 存储器接口:

```
  PicoRV32 Core (picorv32.v)
  ┌──────────────────┐
  │  mem_valid  ──────│──→ 请求有效
  │  mem_addr   ──────│──→ 32位地址
  │  mem_wdata  ──────│──→ 写数据
  │  mem_wstrb  ──────│──→ 字节写使能 (4'b0000=读)
  │  mem_instr  ──────│──→ 1=取指, 0=数据
  │  mem_ready  ←─────│── 应答
  │  mem_rdata  ←─────│── 读数据
  └──────────────────┘
```

但 SoC 中的外设 (DDR、DMA、NPU) 都挂载在 **AXI 总线** 上。
因此需要一个 Wrapper 模块完成两件事:

1. **地址路由**: 将访存请求按地址分发到本地 ROM/RAM 或 AXI 总线
2. **协议转换**: 将 valid/ready 信号转换为 AXI4-Lite 协议

---

## 8.1B 设计视角：为什么这样设计？

### 设计动机

CPU Wrapper 的存在源于一个根本矛盾: **CPU 核心用极简接口, SoC 外设用标准总线**。
PicoRV32 只暴露 7 根信号 (valid/ready/addr/wdata/wstrb/instr/rdata), 但 DDR 控制器、
DMA、NPU 都挂载在 AXI 总线上。Wrapper 就是连接这两个世界的桥梁。

### 方案对比

| 设计维度 | 本项目方案 | 纯 AXI 方案 | 总线桥方案 |
|----------|-----------|------------|-----------|
| CPU 接口 | valid/ready (极简) | AXI4-Lite (原生) | valid/ready |
| 路由方式 | 硬件地址比较 | AXI 互联 | 独立桥模块 |
| 本地存储 | 直连 (零等待) | 经 AXI (多周期) | 经桥 (1-2 周期) |
| 取指延迟 | 1 周期 (ROM) | 3-5 周期 | 2-3 周期 |
| 面积 | 小 (路由器+适配器) | 中 (AXI 逻辑) | 大 (桥+AXI) |

### 关键设计决策

**决策 1: 为什么需要地址路由器?**

```
没有路由器的方案 (所有访问走 AXI):
  CPU 取指 → AXI 适配器 → AXI 总线 → ROM (AXI Slave)
  延迟: 3-5 个周期

  问题: 每条指令都要等 AXI 握手, 性能极差

有路由器的方案 (本项目):
  CPU 取指 → 路由器 → ROM (直连, 组合逻辑读出)
  延迟: 0-1 个周期

  优势: 本地 ROM/RAM 访问零等待, 只有外设访问才走 AXI
```

**决策 2: 为什么分离 ROM 和 RAM?**

```
ROM (只读, 存代码):
  ├── 复位后 CPU 从地址 0x0 取指 → 必须是 ROM
  ├── 组合逻辑读出 → 零等待
  ├── 仿真时通过 $readmemh 加载 .dat 文件
  └── 不需要写端口 → 面积更小

RAM (可读写, 存数据):
  ├── CPU 固件的临时变量需要可写存储
  ├── 支持字节写使能 (wstrb) → SB/SH/SW 指令
  ├── 地址 0x1000_0000, 与 ROM 分开 → 路由逻辑简单
  └── 4KB 足够存放固件的中间数据

合并方案的缺点:
  ├── 用一个双端口 RAM → 面积更大
  ├── 需要处理读写冲突 → 控制逻辑复杂
  └── 取指和数据访问共享带宽 → 性能下降
```

### 约束条件

| 约束 | 影响 | 应对策略 |
|------|------|----------|
| CPU 核心接口极简 | 无法直接连 AXI | 需要适配器做协议转换 |
| 取指延迟敏感 | 多 1 周期 = IPC 降 20% | 本地 ROM 直连, 组合逻辑读 |
| AXI 外设延迟不确定 | DDR 可能需要几十周期 | valid/ready 握手, CPU 自动等待 |
| FPGA 资源有限 | 不能用复杂缓存 | 无缓存, 本地存储足够小 |

---

## 8.1C 设计视角：如何从零开始设计？

假设你要为一个简单的 CPU 核心设计总线 Wrapper, 以下是推荐的设计步骤:

### Step 1: 定义地址映射

```
第一步: 确定地址空间分配

  地址空间:
  0x0000_0000 ┌──────────────┐
              │  CPU ROM     │ 4KB, 只读, 存放固件
  0x0000_3FFF ├──────────────┤
              │  未映射       │ 路由到 AXI
  0x1000_0000 ├──────────────┤
              │  CPU RAM     │ 4KB, 可读写, 存放数据
  0x1000_3FFF ├──────────────┤
              │  未映射       │ 路由到 AXI
  0x4000_0000 ├──────────────┤
              │  DDR         │ 路由到 AXI
  ...         └──────────────┘

设计原则:
  ├── 本地存储放在地址空间的"两端" → 路由比较只用高位
  ├── 基地址对齐到存储大小的整数倍 → 比较逻辑最简
  └── 保留足够地址空间给 AXI 外设
```

### Step 2: 设计地址路由器

```
路由器核心逻辑:

  input  [31:0] mem_addr
  input         mem_valid, mem_instr, mem_wstrb[3:0]
  output        use_local_rom, use_local_ram

  // ROM 匹配: 取指 + 地址在 ROM 范围内
  use_local_rom = mem_valid && mem_instr && (mem_wstrb == 0)
                  && (mem_addr[31:14] == ROM_BASE[31:14]);

  // RAM 匹配: 数据访问 + 地址在 RAM 范围内
  use_local_ram = mem_valid && !mem_instr
                  && (mem_addr[31:14] == RAM_BASE[31:14]);

  // AXI: 不命中本地存储
  use_axi = mem_valid && !use_local_rom && !use_local_ram;
```

### Step 3: 实现本地存储

```
ROM 实现:
  ├── 用 reg 数组: reg [31:0] rom [0:DEPTH-1]
  ├── 初始化: initial $readmemh("firmware.dat", rom)
  ├── 读出: assign rdata = rom[addr[ADDR_WIDTH+1:2]] (组合逻辑)
  └── 无需写端口

RAM 实现:
  ├── 用 reg 数组: reg [31:0] ram [0:DEPTH-1]
  ├── 读出: assign rdata = ram[addr[ADDR_WIDTH+1:2]] (组合逻辑)
  ├── 写入: always @(posedge clk) if (wen) 逐字节写
  └── 支持字节写使能 (wstrb)
```

### Step 4: 设计 AXI 适配器

```
适配器状态机:

  IDLE ──→ 检测 mem_valid
    │
    ├── 写请求: 发出 AW + W 通道, 等待 B 响应
    │     └── awvalid → wvalid → 等待 bvalid → mem_ready
    │
    └── 读请求: 发出 AR 通道, 等待 R 响应
          └── arvalid → 等待 rvalid → mem_ready

关键寄存器:
  ├── ack_awvalid: 已发出 AW, 不重复
  ├── ack_wvalid:  已发出 W,  不重复
  ├── ack_arvalid: 已发出 AR, 不重复
  └── pending_rd/wr: 正在等待响应
```

### Step 5: 集成与验证

```
集成步骤:
  1. 实例化 CPU Core
  2. 实例化路由器, 连接 CPU 的 mem_* 信号
  3. 实例化 ROM 和 RAM, 连接路由器的本地端口
  4. 实例化 AXI 适配器, 连接路由器的 AXI 端口
  5. 将 AXI 适配器的输出连接到 SoC 的 AXI 互联

验证要点:
  ├── 本地 ROM 取指: 1 周期完成
  ├── 本地 RAM 读写: 1 周期完成
  ├── AXI 外设访问: 多周期, 正确等待响应
  └── 地址边界: ROM/RAM 范围外的地址正确路由到 AXI
```

---

## 8.1D 设计视角：架构模式与原则

### 模式 1: 地址空间分区模式 (Address Space Partition Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  CPU 地址空间被划分为多个区域, 每个区域由独立的硬件服务  │
  │                                                          │
  │  路由器通过高位地址比较判断请求属于哪个区域               │
  │  不同区域可以有不同的延迟特性 (本地 vs 总线)              │
  └──────────────────────────────────────────────────────────┘

实现模板:
  // 地址比较 (以 ROM 为例)
  assign in_region = addr[31:ADDR_WIDTH+2] == BASE[31:ADDR_WIDTH+2];

  // 路由决策
  assign mem_ready = use_local ? 1'b1 : axi_mem_ready;
  assign mem_rdata = use_rom ? rom_rdata :
                     use_ram ? ram_rdata : axi_rdata;

适用场景:
  ├── 任何需要将 CPU 访存请求分发到不同目标的设计
  ├── 嵌入式 SoC (CPU + ROM/RAM + 外设)
  └── 多核系统 (本地 cache vs 共享存储)
```

### 模式 2: 总线适配器模式 (Bus Adapter Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  在简单接口和标准总线协议之间插入适配器                    │
  │                                                          │
  │  简单接口 (valid/ready)  ←→  适配器  ←→  标准总线 (AXI)  │
  │                                                          │
  │  适配器负责:                                             │
  │  1. 协议转换 (握手信号映射)                               │
  │  2. 请求排队 (跟踪多个 outstanding 事务)                  │
  │  3. 响应路由 (将总线响应返回给正确的请求方)                │
  └──────────────────────────────────────────────────────────┘

AXI 适配器的关键设计:
  ├── 写事务: 需要跟踪 AW 和 W 两个通道的握手状态
  ├── 读事务: 只需要跟踪 AR 通道的握手状态
  ├── bready/rready 持续有效: 防止错过响应
  └── 用 ack 寄存器避免重复发送请求

适用场景:
  ├── CPU 核心接口与 SoC 总线不匹配
  ├── 需要将简单 SRAM 接口桥接到 AXI
  └── 任何需要协议转换的场景
```

---

## 8.2 picorv32_axi 整体架构

`picorv32_axi` 模块 (第 7-262 行) 由三个子模块组成:

```
                    ┌─────────────────────────────────────────────────┐
                    │              picorv32_axi                       │
                    │                                                 │
  AXI-Lite  ◄──────┤  ┌──────────────────┐                          │
  Master    ◄──────┤  │  axi_adapter     │◄── AXI4-Lite 总线        │
  Interface  ◄─────┤  │  (协议转换)       │                          │
                    │  └────────┬─────────┘                          │
                    │           │ axi_mem_*                           │
                    │           ▼                                     │
                    │  ┌──────────────────┐                          │
                    │  │  mem_router      │                          │
                    │  │  (地址路由)       │                          │
                    │  └──┬──────────┬────┘                          │
                    │     │          │                                │
                    │     ▼          ▼                                │
                    │  ┌──────┐  ┌──────┐                            │
                    │  │ ROM  │  │ RAM  │  本地存储器                 │
                    │  │ 4KB  │  │ 4KB  │                            │
                    │  └──────┘  └──────┘                            │
                    │                    ▲                            │
                    │                    │ core_mem_*                 │
                    │           ┌────────┴───────┐                   │
                    │           │  picorv32      │                   │
                    │           │  (CPU Core)    │                   │
                    │           └────────────────┘                   │
                    └─────────────────────────────────────────────────┘
```

### 数据流详解

CPU 发出一次访存请求时, 数据流经以下路径:

```
  CPU Core                    mem_router              axi_adapter
  ┌──────┐   core_mem_*    ┌────────────┐           ┌───────────┐
  │      │────────────────→│ 地址判断    │           │           │
  │      │                 │            │           │           │
  │      │                 │ ROM范围? ──→│── 直接读ROM│           │
  │      │                 │            │   (1周期)  │           │
  │      │                 │ RAM范围? ──→│── 直接读写 │           │
  │      │                 │            │   RAM(1周期)│           │
  │      │                 │ 都不是? ───→│───────────→│ 转AXI-Lite│
  │      │                 │            │           │ (多周期)   │
  └──────┘                 └────────────┘           └───────────┘
```

---

## 8.3 地址路由器 (picorv32_mem_router)

地址路由器实现在第 269-349 行, 它是整个 CPU Wrapper 的核心。

### 地址范围判断

```verilog
// src/cpu/picorv32_axi.v 第 304-309 行
assign in_rom_region = mem_addr[31:LOCAL_ROM_ADDR_WIDTH+2]
                    == LOCAL_ROM_BASE[31:LOCAL_ROM_ADDR_WIDTH+2];
assign in_ram_region = mem_addr[31:LOCAL_RAM_ADDR_WIDTH+2]
                    == LOCAL_RAM_BASE[31:LOCAL_RAM_ADDR_WIDTH+2];

assign use_local_rom = mem_valid && mem_instr && (mem_wstrb == 4'b0000) && in_rom_region;
assign use_local_ram = mem_valid && !mem_instr && in_ram_region;
assign use_local     = use_local_rom || use_local_ram;
```

**地址匹配原理**:

以 ROM 为例, `LOCAL_ROM_BASE = 32'h0000_0000`, `LOCAL_ROM_ADDR_WIDTH = 12`:
- ROM 有 2^12 = 4096 个 32 位字, 字节地址范围 0x0000_0000 ~ 0x0000_3FFF
- 匹配条件: `mem_addr[31:14] == 32'h0000_0000[31:14]` 即 `mem_addr[31:14] == 0`
- 实际上 ADDR_WIDTH=12 意味着 12 位字地址 + 2 位字节偏移 = 14 位, 所以比较的是高 18 位

```
  31                    14 13              2 1 0
  ┌───────────────────────┬────────────────┬───┐
  │  比较区域 (高18位)     │  字地址(12位)  │字节│
  └───────────────────────┴────────────────┴───┘
  │← LOCAL_ROM_BASE 比较 →│← ROM 内部寻址 →│   │
```

### 路由决策逻辑

```verilog
// src/cpu/picorv32_axi.v 第 311-319 行
// 应答来源: 本地存储 (即时) 或 AXI (需等待)
assign mem_ready = use_local ? 1'b1 : axi_mem_ready;

// 读数据来源选择
assign mem_rdata = use_local_rom ? local_rom_rdata :
                   (use_local_ram ? local_ram_rdata : axi_mem_rdata);

// AXI 请求: 仅当不命中本地存储时才发出
assign axi_mem_valid = mem_valid && !use_local;
assign axi_mem_addr  = mem_addr;
assign axi_mem_wdata = mem_wdata;
assign axi_mem_wstrb = mem_wstrb;
```

**关键设计决策**:

1. **本地 ROM/RAM 访问是零等待的** —— `mem_ready` 直接接 `1'b1`,
   因为 ROM 是组合逻辑读出, RAM 是同步写但组合逻辑读
2. **只读取指访问走 ROM** —— `use_local_rom` 要求 `mem_instr && !mem_wstrb`
3. **数据读写都可走 RAM** —— `use_local_ram` 只要求 `!mem_instr && in_ram_region`

### 本项目的地址映射表

| 地址范围 | 设备 | 本地/AXI | 路由条件 |
|----------|------|----------|----------|
| 0x0000_0000 ~ 0x0000_3FFF | CPU ROM (4KB) | 本地 | 取指 + 在范围内 |
| 0x1000_0000 ~ 0x1000_3FFF | CPU RAM (4KB) | 本地 | 数据访问 + 在范围内 |
| 0x0000_4000+ (其他) | AXI 外设 | AXI | 不命中本地存储 |

---

## 8.4 本地 ROM (picorv32_local_rom)

ROM 实现在第 356-381 行, 结构非常简单:

```verilog
// src/cpu/picorv32_axi.v 第 356-381 行
module picorv32_local_rom #(
    parameter integer ADDR_WIDTH = 12,
    parameter  INIT_FILE = "instr_data.dat"
) (
    input  [31:0] addr,
    output [31:0] rdata
);
    localparam integer DEPTH = (1 << ADDR_WIDTH);
    reg [31:0] mem [0:DEPTH-1];

    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 32'h00000013;        // 默认填充 NOP (addi x0, x0, 0)
        if (INIT_FILE != 0)
            $readmemh(INIT_FILE, mem);     // 从 .dat 文件加载指令
    end

    assign rdata = mem[addr[ADDR_WIDTH+1:2]];  // 组合逻辑读出
endmodule
```

**要点**:
- `$readmemh` 在仿真开始时执行一次, 将 `instr_data.dat` 的内容加载到 ROM
- 未初始化的位置填 NOP (`0x00000013` = `addi x0, x0, 0`)
- 读出是纯组合逻辑, **零等待** —— 地址变化后 rdata 立即更新
- ROM 只读, 不支持写操作

---

## 8.5 本地 RAM (picorv32_local_ram)

RAM 实现在第 388-419 行:

```verilog
// src/cpu/picorv32_axi.v 第 388-419 行
module picorv32_local_ram #(
    parameter integer ADDR_WIDTH = 12
) (
    input clk, resetn,
    input wen,
    input [31:0] addr,
    input [31:0] wdata,
    input [ 3:0] wstrb,
    output [31:0] rdata
);
    reg [31:0] mem [0:DEPTH-1];
    wire [ADDR_WIDTH-1:0] word_addr;

    assign word_addr = addr[ADDR_WIDTH+1:2];
    assign rdata = mem[word_addr];              // 组合逻辑读

    always @(posedge clk) begin
        if (!resetn) begin
            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= 0;                    // 复位清零
        end else if (wen) begin
            if (wstrb[0]) mem[word_addr][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[word_addr][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[word_addr][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[word_addr][31:24] <= wdata[31:24];
        end
    end
endmodule
```

**字节写使能 (wstrb) 的含义**:

```
  wstrb = 4'b1111  →  写整个 32 位字 (SW 指令)
  wstrb = 4'b0011  →  写低 16 位 (SH 指令, 地址对齐)
  wstrb = 4'b1100  →  写高 16 位 (SH 指令, 地址+2)
  wstrb = 4'b0001  →  写最低字节 (SB 指令, 地址+0)
  wstrb = 4'b0010  →  写次低字节 (SB 指令, 地址+1)
  wstrb = 4'b0100  →  写次高字节 (SB 指令, 地址+2)
  wstrb = 4'b1000  →  写最高字节 (SB 指令, 地址+3)
```

---

## 8.6 AXI-Lite 适配器 (picorv32_axi_adapter)

当访存地址不在本地 ROM/RAM 范围内时, 请求通过 AXI-Lite 适配器
转发到 AXI 总线。适配器实现在第 426-542 行。

### AXI4-Lite 协议速览

AXI4-Lite 是 AXI4 的简化版本, 去掉了 burst 传输, 每次只传一个数据。

```
  写事务 (Write Transaction):
  ┌─────┐              ┌─────┐              ┌─────┐
  │ CPU │              │ AXI │              │Slave│
  └──┬──┘              └──┬──┘              └──┬──┘
     │  AW: awvalid/addr  │                    │
     │───────────────────→│───────────────────→│
     │  W:  wvalid/data   │                    │
     │───────────────────→│───────────────────→│
     │                    │  B: bvalid/resp    │
     │←───────────────────│←───────────────────│
     │  mem_ready=1       │                    │

  读事务 (Read Transaction):
  ┌─────┐              ┌─────┐              ┌─────┐
  │ CPU │              │ AXI │              │Slave│
  └──┬──┘              └──┬──┘              └──┬──┘
     │  AR: arvalid/addr  │                    │
     │───────────────────→│───────────────────→│
     │                    │  R: rvalid/data    │
     │←───────────────────│←───────────────────│
     │  mem_ready=1       │                    │
```

### 适配器状态机

```verilog
// src/cpu/picorv32_axi.v 第 474-498 行
wire is_write = mem_valid && (|mem_wstrb);
wire is_read  = mem_valid && !(|mem_wstrb);

// 请求通道
assign mem_axi_awvalid = is_write && !ack_awvalid;
assign mem_axi_wvalid  = is_write && !ack_wvalid;
assign mem_axi_arvalid = is_read  && !ack_arvalid;

// 应答通道: 只在等待响应时 ready
assign mem_axi_bready = pending_wr_rsp;
assign mem_axi_rready = pending_rd_rsp;

// CPU 侧应答
assign mem_ready = (pending_wr_rsp && mem_axi_bvalid) ||
                   (pending_rd_rsp && mem_axi_rvalid);
```

### 握手跟踪寄存器

适配器使用 `ack_awvalid`, `ack_wvalid`, `ack_arvalid` 三个寄存器
跟踪 AXI 通道的握手完成状态:

```
  写事务状态转移:
  ┌──────────┐   awready   ┌──────────┐   wready    ┌──────────┐
  │ 发出 AW  │────────────→│ AW 已握手 │────────────→│ AW+W完成 │
  │ awvalid=1│             │ ack_aw=1 │             │ 等待 B   │
  └──────────┘             └──────────┘             └────┬─────┘
                                                         │ bvalid
                                                         ▼
                                                    ┌──────────┐
                                                    │ 写完成   │
                                                    │ mem_ready│
                                                    └──────────┘

  读事务状态转移:
  ┌──────────┐   arready   ┌──────────┐
  │ 发出 AR  │────────────→│ 等待 R   │
  │ arvalid=1│             │ ack_ar=1 │
  └──────────┘             └────┬─────┘
                                │ rvalid
                                ▼
                           ┌──────────┐
                           │ 读完成   │
                           │ mem_ready│
                           └──────────┘
```

### 关键设计细节

第 490-491 行的注释说明了一个重要的设计决策:

```verilog
// src/cpu/picorv32_axi.v 第 490 行
// IMPORTANT: keep ready high during pending response (avoid missing pulse)
assign mem_axi_bready = pending_wr_rsp;
assign mem_axi_rready = pending_rd_rsp;
```

`bready`/`rready` 在等待响应期间持续为高, 而不是只在 `mem_valid` 时才拉高。
这是因为 CPU 核心可能在 AXI 响应返回之前就撤销了 `mem_valid` (比如被更高
优先级的操作打断), 如果 `bready` 跟随 `mem_valid`, 就会错过 AXI 响应。

---

## 8.7 AXI4-Lite 信号连接

适配器将 CPU 的 valid/ready 接口映射到 AXI4-Lite 的 5 个通道:

| AXI 通道 | 信号 | 方向 | 说明 |
|----------|------|------|------|
| Write Address (AW) | awvalid, awaddr, awprot | Master→Slave | 写地址 |
| Write Data (W) | wvalid, wdata, wstrb | Master→Slave | 写数据 |
| Write Response (B) | bvalid, bready | Slave→Master | 写响应 |
| Read Address (AR) | arvalid, araddr, arprot | Master→Slave | 读地址 |
| Read Data (R) | rvalid, rdata, rready | Slave→Master | 读数据 |

**注意**: `awprot` 和 `arprot` 在本设计中固定为:
- `arprot = 3'b100` when `mem_instr` (取指访问, 标记为"安全")
- `arprot = 3'b000` otherwise (数据访问)
- `awprot = 3'b000` (写始终为数据)

---

## 8.8 完整的访存路径示例

以 `LW t1, 0(s0)` 为例, 假设 `s0 = 0x4000_0000` (DDR 地址):

```
  时钟周期  │ CPU Core          │ mem_router        │ axi_adapter
  ──────────┼───────────────────┼───────────────────┼──────────────
  T1        │ mem_valid=1       │ in_rom? No        │ is_read=1
            │ mem_addr=0x4000_0 │ in_ram? No        │ arvalid=1
            │ mem_wstrb=0       │ use_local=0       │ araddr=0x4000_0
            │                   │ axi_valid=1       │
  ──────────┼───────────────────┼───────────────────┼──────────────
  T2        │ (等待)            │ (透传)            │ arready=1 (假设)
            │                   │                   │ ack_ar=1
            │                   │                   │ pending_rd=1
  ──────────┼───────────────────┼───────────────────┼──────────────
  T3..Tn    │ (等待)            │ (透传)            │ (等待 DDR 响应)
  ──────────┼───────────────────┼───────────────────┼──────────────
  Tn+1      │ mem_ready=1       │ mem_rdata=DDR数据  │ rvalid=1
            │ mem_rdata=数据    │                   │ rready=1
            │ → t1 = 数据       │                   │ pending_rd=0
```

对比 `LW t1, 0(s0)` 在本地 RAM (`s0 = 0x1000_0000`):

```
  时钟周期  │ CPU Core          │ mem_router
  ──────────┼───────────────────┼───────────────────
  T1        │ mem_valid=1       │ in_ram? Yes
            │ mem_addr=0x1000_0 │ use_local_ram=1
            │                   │ mem_ready=1 (组合逻辑!)
            │                   │ mem_rdata=RAM数据
            │ → t1 = 数据       │
```

**本地 RAM 只需 1 个周期, AXI 外设需要多个周期** —— 这就是为什么
把频繁访问的数据放在 CPU RAM 中性能更好。

---

## 8.9 关键知识点总结

1. **picorv32_axi = CPU Core + 路由器 + AXI 适配器**: 三层结构清晰分离
2. **地址路由器用高位比较**: `mem_addr[31:ADDR_WIDTH+2]` 与基地址高位比较
3. **本地存储零等待**: ROM 组合逻辑读, RAM 组合逻辑读 + 同步写
4. **AXI 适配器跟踪握手状态**: 用 ack 寄存器避免重复发送请求
5. **bready/rready 持续有效**: 防止错过 AXI 响应
6. **ROM 只响应取指**: `mem_instr && !wstrb` 才走 ROM
7. **RAM 只响应数据访问**: `!mem_instr` 才走 RAM

---

## 8.10 动手练习

### 练习 1: 地址路由判断

给定以下地址, 判断每次访存请求会走哪条路径 (ROM / RAM / AXI):

| 地址 | 操作 | mem_instr | 路径 |
|------|------|-----------|------|
| 0x0000_0004 | 取指 | 1 | ? |
| 0x0000_1000 | 读数据 | 0 | ? |
| 0x1000_0000 | 读数据 | 0 | ? |
| 0x1000_0004 | 写数据 | 0 | ? |
| 0x4000_0000 | 读数据 | 0 | ? |
| 0x0002_1000 | 读数据 | 0 | ? |
| 0x0003_0000 | 写数据 | 0 | ? |

### 练习 2: 扩展地址空间

如果要把 CPU ROM 从 4KB 扩展到 16KB, 需要修改哪些参数?
写出新的参数值和对应地址范围。

### 练习 3: 路由器时序分析

分析当 CPU 同时取指和读数据时 (通过 prefetch), 路由器的行为。
提示: 看 `picorv32.v` 中 `mem_do_prefetch` 和 `mem_do_rdata` 的关系。

### 练习 4: AXI 适配器调试

假设 AXI slave 永远不返回 `bvalid`, 会发生什么?
CPU 会永久卡死吗? 如何在硬件层面检测这种超时?

---

## 8.11 延伸阅读

- AXI4-Lite 协议规范 (ARM AMBA AXI4-Lite)
- `src/cpu/picorv32_axi.v` 全文 (约 540 行)
- `src/soc_top.sv` 中 `picorv32_axi` 的实例化 (第 329-355 行)
