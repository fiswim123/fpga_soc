# Lecture 07: PicoRV32 RISC-V 核心 — 指令集与流水线

> **参考源码**: `src/cpu/picorv32.v`
> **前置知识**: Lecture 01 SoC 整体架构、基本数字逻辑
> **本节目标**: 理解 PicoRV32 的 RV32I 指令集实现、两级流水线结构、寄存器堆与 ALU 设计

---

## 7.1 PicoRV32 概述

PicoRV32 是 Claire Wolf 设计的一个极简 RISC-V (RV32I) 处理器核心。
它的设计哲学是 **面积最小化** —— 不追求高性能，而是用最少的逻辑资源实现
一个功能完整的 32 位 CPU。

### 核心参数一览

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `ENABLE_COUNTERS` | 1 | 使能 `rdcycle`/`rdinstr` 指令 |
| `ENABLE_REGS_16_31` | 1 | 使能 x16-x31 高端寄存器 (设为0可省面积) |
| `ENABLE_REGS_DUALPORT` | 1 | 双端口寄存器堆 (同时读 rs1/rs2) |
| `TWO_STAGE_SHIFT` | 1 | 移位分两阶段执行 (减组合逻辑深度) |
| `BARREL_SHIFTER` | 0 | 桶形移位器 (面积换速度) |
| `COMPRESSED_ISA` | 0 | 支持 RV32C 压缩指令 |
| `CATCH_MISALIGN` | 1 | 捕获非对齐访存异常 |
| `CATCH_ILLINSN` | 1 | 捕获非法指令异常 |
| `PROGADDR_RESET` | 0x00000000 | 复位后 PC 起始地址 |
| `PROGADDR_IRQ` | 0x00000010 | 中断入口地址 |

**本项目中的配置** (见 `src/soc_top.sv` 第 329-355 行):
- `PROGADDR_RESET = 32'h0000_0000` (从 ROM 起始处取指)
- `PROGADDR_IRQ = 32'h0000_0010`
- `ENABLE_TRACE = 1` (仿真调试用)

### 设计哲学: "忙等"而非"流水线冲刷"

与经典 5 级流水线 RISC-V 不同, PicoRV32 **没有分支预测器**。
遇到分支时, 处理器会等待比较结果确定后再取下一条指令。
这种设计虽然每条分支指令要多花几个周期, 但大幅简化了控制逻辑。

---

## 7.1B 设计视角：为什么这样设计？

### 设计动机

PicoRV32 的设计目标是 **最小面积的 RV32I 软核**。在嵌入式 FPGA 场景中,
面积往往比性能更重要 —— 省下的 LUT 可以留给加速器、DSP 或更大的存储。

### 方案对比

| 设计维度 | PicoRV32 (本项目) | 经典 5 级流水线 (如 Rocket) | 超标量 (如 BOOM) |
|----------|-------------------|---------------------------|------------------|
| 流水线深度 | 2 级 (取指+执行) | 5 级 (IF/ID/EX/MEM/WB) | 10+ 级 |
| 分支预测 | 无 (忙等) | BHT + BTB | TAGE 预测器 |
| MUL/DIV | 无 (PCPI 扩展) | 硬件乘除法 | 多周期流水 |
| 面积 (LUT) | ~800 | ~3000 | ~15000 |
| DMIPS/MHz | ~0.30 | ~1.0 | ~2.5 |
| 时钟频率 | 100-250 MHz | 50-100 MHz | 50-80 MHz |

### 关键设计决策

**决策 1: 为什么选择 2 级而非 5 级流水线?**

```
5 级流水线的代价:
  ├── 分支惩罚: 2-3 个周期的气泡 (需要分支预测器消除)
  ├── 数据冒险: 需要 forwarding 网络 (多路 MUX)
  ├── 控制复杂度: stall/flush 逻辑面积大
  └── 面积开销: 流水线寄存器 + forwarding + 预测器

2 级流水线的优势:
  ├── 无分支惩罚: 取指和执行串行, 天然无冒险
  ├── 无 forwarding: 同一周期内完成读+执行
  ├── 控制极简: 8 态 FSM 即可
  └── 面积最小: 几乎全是组合逻辑
```

**决策 2: 为什么没有分支预测器?**

```
分支预测器的成本:
  ├── BHT (Branch History Table): 256-1024 条目 x 2 位 = 512-2048 位 SRAM
  ├── BTB (Branch Target Buffer): 256 条目 x 32 位 = 8192 位 SRAM
  ├── 预测正确率: 简单预测器 ~85%, 复杂预测器 ~95%
  └── 面积: 预测器本身可能比 PicoRV32 还大

PicoRV32 的选择:
  ├── 遇到分支 → 等待比较结果 → 取下一条指令
  ├── 代价: 每条分支多 1-2 个周期
  └── 收益: 面积减少 ~30%, 控制逻辑极简
```

**决策 3: 为什么没有硬件 MUL/DIV?**

```
硬件乘法器:
  ├── 32x32 乘法器 ≈ 400-800 LUT (FPGA DSP 块可替代)
  ├── 32/32 除法器 ≈ 600-1200 LUT (迭代实现)
  └── 本项目 NPU 不需要乘除法指令

替代方案: PCPI (Pico Co-Processor Interface)
  ├── CPU 遇到 MUL/DIV → 通过 PCPI 接口发送给协处理器
  ├── 协处理器可以是硬件乘法器或软件模拟
  └── 本项目使用软件模拟 (移位+加法)
```

### 约束条件

| 约束 | 影响 | 应对策略 |
|------|------|----------|
| FPGA LUT 数量有限 | 不能用复杂流水线 | 2 级流水线 + 无预测器 |
| 时钟频率要求低 | 无需高速关键路径 | 组合逻辑读寄存器堆 |
| 单一推理任务 | 不需要多线程/乱序 | 简单顺序执行 |
| 固件代码量小 | 不需要缓存 | 直连 ROM/RAM |

---

## 7.1C 设计视角：如何从零开始设计？

假设你要从零设计一个最小 RISC-V 核心, 以下是推荐的设计步骤:

### Step 1: 定义指令子集

首先确定要支持哪些指令。PicoRV32 选择了 RV32I 的绝大部分:

```
最小可用子集 (约 15 条指令):
  ├── 算术: ADD, SUB, ADDI
  ├── 逻辑: AND, OR, XOR, ANDI, ORI, XORI
  ├── 移位: SLL, SRL, SRA, SLLI, SRLI, SRAI
  ├── 比较: SLT, SLTU, SLTI, SLTIU
  ├── 加载: LUI, AUIPC
  ├── 跳转: JAL, JALR, BEQ, BNE
  ├── 访存: LW, SW
  └── 系统: FENCE

设计原则: 先实现最少指令, 让一个简单程序能跑起来
```

### Step 2: 设计寄存器堆

```
寄存器堆规格:
  ├── 32 个 32 位寄存器 (x0 硬连线为 0)
  ├── 2 个读端口 (rs1, rs2)
  ├── 1 个写端口 (rd)
  └── 写优先 (write-first) 或 旁路 (bypass)

实现选择:
  ├── FPGA: 用 Distributed RAM 或 Register
  ├── 双端口读: 组合逻辑直接读出 (无时钟延迟)
  └── 单周期写: 时钟上升沿写入
```

### Step 3: 设计 ALU

```
ALU 操作:
  ├── 加减法器: ADD/SUB 共用 (通过减法控制信号切换)
  ├── 逻辑运算: AND, OR, XOR (直接连线)
  ├── 移位器: SLL, SRL, SRA (迭代或桶形)
  ├── 比较器: SLT/SLTU (用减法器结果判断符号)
  └── 最终选择: 用 MUX 根据指令类型选择输出
```

### Step 4: 设计状态机

```
PicoRV32 的 8 态 FSM:
  1. FETCH    — 取指 (读 ROM)
  2. LD_RS1   — 读寄存器 rs1 (和 rs2, 如果双端口)
  3. LD_RS2   — 仅单端口模式: 读 rs2
  4. EXEC     — 执行 ALU 操作/分支判断
  5. LDMEM    — Load 指令: 读存储器
  6. STMEM    — Store 指令: 写存储器
  7. SHIFT    — 移位指令: 迭代移位
  8. TRAP     — 异常停机

状态转移取决于指令类型:
  ALU 指令: FETCH → LD_RS1 → EXEC → FETCH
  LW 指令:  FETCH → LD_RS1 → LDMEM → FETCH
  SW 指令:  FETCH → LD_RS1 → STMEM → FETCH
  JAL:      FETCH → FETCH (直接跳转)
```

### Step 5: 集成存储器接口

```
存储器接口信号:
  ├── mem_valid (输出): CPU 发出请求
  ├── mem_addr  (输出): 32 位地址
  ├── mem_wdata (输出): 写数据
  ├── mem_wstrb (输出): 字节写使能
  ├── mem_instr (输出): 1=取指, 0=数据
  ├── mem_ready (输入): 存储器应答
  └── mem_rdata (输入): 读数据

设计原则: 用 valid/ready 握手, 不假设存储器延迟
```

---

## 7.1D 设计视角：架构模式与原则

### 模式 1: 最小流水线模式 (Minimal Pipeline Pattern)

PicoRV32 展示了如何用最少的流水线级数实现功能完整的 CPU:

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  取指 (FETCH)  ──→  执行 (EXEC)  ──→  写回 (FETCH)     │
  │       ↑                                     │           │
  │       └─────────────────────────────────────┘           │
  │                                                          │
  │  关键: 写回与下一次取指重叠, 节省 1 个周期               │
  └──────────────────────────────────────────────────────────┘

适用场景:
  ├── 面积极度受限的嵌入式系统
  ├── 不追求 IPC, 只需要功能正确
  └── 控制密集型任务 (非计算密集型)

PicoRV32 的实现技巧:
  ├── 写回在 FETCH 阶段开头完成 (第 1313-1333 行)
  ├── 寄存器读在 LD_RS1 阶段完成 (组合逻辑, 无延迟)
  └── ALU 在 EXEC 阶段完成 (组合逻辑)
```

### 模式 2: 双端口寄存器堆模式 (Dual-Port Register File Pattern)

```
问题: R-type 指令 (如 ADD rd, rs1, rs2) 需要同时读两个源寄存器

方案 A: 双端口寄存器堆 (ENABLE_REGS_DUALPORT = 1)
  ├── 一个周期同时读 rs1 和 rs2
  ├── 代价: 每个寄存器需要 2 个读端口
  └── FPGA: Distributed RAM 天然支持双端口读

方案 B: 单端口 + 额外周期 (ENABLE_REGS_DUALPORT = 0)
  ├── 第一个周期读 rs1 (LD_RS1 状态)
  ├── 第二个周期读 rs2 (LD_RS2 状态)
  ├── 代价: 每条 R-type 指令多 1 个周期
  └── 收益: 寄存器堆面积减半

  时序对比:
  双端口: FETCH → LD_RS1(读rs1+rs2) → EXEC → FETCH  (3 周期)
  单端口: FETCH → LD_RS1(读rs1) → LD_RS2(读rs2) → EXEC → FETCH  (4 周期)
```

这个模式在所有需要寄存器堆的设计中都适用 —— 根据面积/性能权衡
选择单端口或双端口。PicoRV32 默认选择双端口, 因为 FPGA 的
Distributed RAM 读端口成本很低。

---

## 7.2 RV32I 指令集速查

RV32I 是 RISC-V 的基础整数指令集, 共 47 条指令。PicoRV32 实现了其中
绝大部分, 并通过 PCPI 协处理器接口支持 M 扩展 (乘除法)。

### 指令格式 (4 种基本格式)

```
  31       25 24   20 19   15 14  12 11    7 6      0
  ┌─────────┬───────┬───────┬──────┬───────┬────────┐
R │ funct7  │  rs2  │  rs1  │funct3│  rd   │ opcode │
  ├─────────┼───────┼───────┼──────┼───────┼────────┤
I │   imm[11:0]     │  rs1  │funct3│  rd   │ opcode │
  ├─────────┼───────┼───────┼──────┼───────┼────────┤
S │imm[11:5]│  rs2  │  rs1  │funct3│imm[4:0]│ opcode │
  ├─────────┴───────┼───────┼──────┼───────┼────────┤
B │imm[12|10:5]     │  rs2  │  rs1 │imm[11│imm[4:1]│
  │                 │       │      │  :8]  │        │opcode│
  ├─────────────────────────┼──────┼───────┼────────┤
U │      imm[31:12]         │  rd  │       │ opcode │
  ├─────────┬───────┬───────┼──────┼───────┼────────┤
J │imm[20|10:1|11|19:12]    │  rd  │       │ opcode │
  └─────────┴───────┴───────┴──────┴───────┴────────┘
```

### 指令分类与解码逻辑

在 `picorv32.v` 第 646-653 行, 解码器将指令分为以下类别:

```
┌─────────────────────────────────────────────────────────────┐
│                     RV32I 指令分类                          │
├──────────────┬──────────────────────────────────────────────┤
│  立即数加载   │ LUI (0110111), AUIPC (0010111)             │
│  跳转        │ JAL (1101111), JALR (1100111)               │
│  条件分支     │ BEQ/BNE/BLT/BGE/BLTU/BGEU (1100011)       │
│  加载        │ LB/LH/LW/LBU/LHU (0000011)                 │
│  存储        │ SB/SH/SW (0100011)                          │
│  ALU-立即数   │ ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI │
│  ALU-寄存器   │ ADD/SUB/SLL/SLT/SLTU/XOR/SRL/SRA/OR/AND   │
│  系统        │ FENCE, ECALL, EBREAK                        │
│  性能计数     │ RDCYCLE, RDCYCLEH, RDINSTR, RDINSTRH       │
└──────────────┴──────────────────────────────────────────────┘
```

解码器通过 opcode (指令最低 7 位) 先分类, 再用 funct3/funct7 区分具体指令。
关键代码在第 866-884 行:

```verilog
// src/cpu/picorv32.v 第 866-878 行
if (mem_do_rinst && mem_done) begin
    instr_lui     <= mem_rdata_latched[6:0] == 7'b0110111;
    instr_auipc   <= mem_rdata_latched[6:0] == 7'b0010111;
    instr_jal     <= mem_rdata_latched[6:0] == 7'b1101111;
    instr_jalr    <= mem_rdata_latched[6:0] == 7'b1100111 && mem_rdata_latched[14:12] == 3'b000;

    is_beq_bne_blt_bge_bltu_bgeu <= mem_rdata_latched[6:0] == 7'b1100011;
    is_lb_lh_lw_lbu_lhu          <= mem_rdata_latched[6:0] == 7'b0000011;
    is_sb_sh_sw                  <= mem_rdata_latched[6:0] == 7'b0100011;
    is_alu_reg_imm               <= mem_rdata_latched[6:0] == 7'b0010011;
    is_alu_reg_reg               <= mem_rdata_latched[6:0] == 7'b0110011;
end
```

然后在第 1037-1134 行, 用 funct3/funct7 做二次解码:

```verilog
// src/cpu/picorv32.v 第 1040-1077 行 (部分)
instr_beq  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b000;
instr_bne  <= is_beq_bne_blt_bge_bltu_bgeu && mem_rdata_q[14:12] == 3'b001;
instr_add  <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0000000;
instr_sub  <= is_alu_reg_reg && mem_rdata_q[14:12] == 3'b000 && mem_rdata_q[31:25] == 7'b0100000;
```

---

## 7.3 两级流水线结构

PicoRV32 采用 **取指 + 执行** 的两级流水线, 通过 8 个状态的有限状态机
(FSM) 实现。状态定义在第 1172-1179 行:

```
┌──────────────────────────────────────────────────────────────────┐
│                   PicoRV32 状态机                                │
│                                                                  │
│  ┌─────────┐    取指完成     ┌─────────┐   立即数/分支   ┌──────┐│
│  │  FETCH  │──────────────→│  LD_RS1 │──────────────→│ EXEC ││
│  │ (取指)  │               │ (读rs1) │               │(执行)││
│  └────┬────┘               └────┬────┘               └──┬───┘│
│       │                        │                        │    │
│       │                        │ 需要rs2   ┌─────────┐  │    │
│       │                        ├──────────→│ LD_RS2  │──┘    │
│       │                        │           │ (读rs2) │       │
│       │                        │           └─────────┘       │
│       │                        │                              │
│       │                        │ Load指令  ┌─────────┐       │
│       │                        ├──────────→│ LDMEM   │───────┘
│       │                        │           │(读存储器)│  → 回 FETCH
│       │                        │           └─────────┘
│       │                        │
│       │                        │ Store指令 ┌─────────┐
│       │                        ├──────────→│ STMEM   │───────┐
│       │                        │           │(写存储器)│       │
│       │                        │           └─────────┘       │
│       │                        │                              │
│       │                        │ 移位指令  ┌─────────┐       │
│       │                        ├──────────→│ SHIFT   │───────┘
│       │                        │           │ (移位)  │  → 回 FETCH
│       │                        │           └─────────┘
│       │                        │
│       │ 非法指令                │
│       └──────────→ TRAP        │
└──────────────────────────────────────────────────────────────────┘
```

### 典型指令的执行周期数

| 指令类型 | 执行路径 | 最少周期 |
|----------|----------|----------|
| ADD/ADDI 等 ALU | FETCH → LD_RS1 → EXEC → FETCH | 3 |
| LW (本地ROM/RAM) | FETCH → LD_RS1 → LDMEM → FETCH | 3+ |
| SW (本地ROM/RAM) | FETCH → LD_RS1 → STMEM → FETCH | 3+ |
| SLL/SRL/SRA | FETCH → LD_RS1 → SHIFT → ... → FETCH | 3+ (取决于移位量) |
| BEQ (不跳转) | FETCH → LD_RS1 → EXEC → FETCH | 3 |
| BEQ (跳转) | FETCH → LD_RS1 → EXEC → FETCH | 3+ |
| JAL | FETCH → FETCH (立即跳转) | 2 |
| LW (AXI 外设) | FETCH → LD_RS1 → LDMEM → ... → FETCH | 更多 (等待 AXI) |

### 为什么 JAL 最快?

注意第 1567-1571 行, JAL 在 FETCH 阶段就直接计算跳转目标并发起下一次取指,
不需要进入 LD_RS1:

```verilog
// src/cpu/picorv32.v 第 1567-1571 行
if (instr_jal) begin
    mem_do_rinst <= 1;
    reg_next_pc <= current_pc + decoded_imm_j;
    latched_branch <= 1;
end
```

---

## 7.4 寄存器堆 (Register File)

RV32I 定义了 32 个 32 位通用寄存器 x0-x31。PicoRV32 的寄存器堆
实现在第 203-211 行:

```verilog
// src/cpu/picorv32.v 第 203 行
`ifndef PICORV32_REGS
    reg [31:0] cpuregs [0:regfile_size-1];
```

### 双端口 vs 单端口

当 `ENABLE_REGS_DUALPORT = 1` 时, 寄存器堆可以同时读取 rs1 和 rs2,
这在 LD_RS1 阶段就能把两个操作数都准备好 (第 1351-1357 行):

```verilog
// src/cpu/picorv32.v 第 1351-1357 行
if (ENABLE_REGS_DUALPORT) begin
    cpuregs_rs1 = decoded_rs1 ? cpuregs[decoded_rs1] : 0;
    cpuregs_rs2 = decoded_rs2 ? cpuregs[decoded_rs2] : 0;
end
```

当 `ENABLE_REGS_DUALPORT = 0` 时, 需要两个周期分别读取 rs1 和 rs2,
此时会多出一个 LD_RS2 状态。

### 写回逻辑

寄存器写回发生在 FETCH 阶段的开头 (第 1313-1333 行), 这是一种
"写回与取指重叠" 的优化:

```verilog
// src/cpu/picorv32.v 第 1313-1333 行
if (cpu_state == cpu_state_fetch) begin
    (* parallel_case *)
    case (1'b1)
        latched_branch: begin
            cpuregs_wrdata = reg_pc + (latched_compr ? 2 : 4);
            cpuregs_write = 1;
        end
        latched_store && !latched_branch: begin
            cpuregs_wrdata = latched_stalu ? alu_out_q : reg_out;
            cpuregs_write = 1;
        end
    endcase
end
```

---

## 7.5 ALU (算术逻辑单元)

ALU 是组合逻辑, 在第 1229-1290 行实现:

```
┌─────────────────────────────────────────────────────┐
│                    ALU 结构                          │
│                                                      │
│  reg_op1 ──┐                                        │
│            ├──→ [加减法器] ──→ alu_add_sub           │
│  reg_op2 ──┘     (+/-)                              │
│                                                      │
│  reg_op1 ──┐                                        │
│            ├──→ [比较器] ──→ alu_eq, alu_lts, alu_ltu│
│  reg_op2 ──┘   (==, <, <u)                          │
│                                                      │
│  reg_op1 ──┐                                        │
│            ├──→ [左移] ──→ alu_shl                   │
│  reg_op2 ──┘                                        │
│                                                      │
│  reg_op1 ──┐                                        │
│            ├──→ [右移] ──→ alu_shr (算术/逻辑)       │
│  reg_op2 ──┘                                        │
│                                                      │
│  最终选择: alu_out = 根据指令类型选择上述结果之一      │
└─────────────────────────────────────────────────────┘
```

### 加减法器 (第 1231-1236 行)

```verilog
// src/cpu/picorv32.v 第 1231 行
alu_add_sub <= instr_sub ? reg_op1 - reg_op2 : reg_op1 + reg_op2;
```

SUB 和 ADD 共用同一个加法器, 通过 `instr_sub` 控制减法取反。

### 移位器的两种实现

**默认: TWO_STAGE_SHIFT** (第 1829-1852 行):
每次移位 1 或 4 位, 需要多个周期完成。对于 32 位移位, 最坏情况约 8 个周期。

```verilog
// src/cpu/picorv32.v 第 1835-1841 行
end else if (TWO_STAGE_SHIFT && reg_sh >= 4) begin
    case (1'b1)
        instr_slli || instr_sll: reg_op1 <= reg_op1 << 4;
        instr_srli || instr_srl: reg_op1 <= reg_op1 >> 4;
        instr_srai || instr_sra: reg_op1 <= $signed(reg_op1) >>> 4;
    endcase
    reg_sh <= reg_sh - 4;
```

**可选: BARREL_SHIFTER** (第 1235-1236 行):
一个周期完成任意移位量, 但占用更多 LUT。

---

## 7.6 异常处理机制

PicoRV32 支持两类异常: **同步陷阱 (trap)** 和 **外部中断 (IRQ)**。

### 同步陷阱

当发生以下情况时, CPU 进入 `cpu_state_trap` 状态并永久停机:
1. **非法指令** (`CATCH_ILLINSN = 1`): 指令 opcode 不匹配任何已知指令
2. **非对齐访存** (`CATCH_MISALIGN = 1`): 字访问地址非 4 字节对齐
3. **EBREAK 指令**: 调试断点

```verilog
// src/cpu/picorv32.v 第 1922-1937 行
if (CATCH_MISALIGN && resetn && (mem_do_rdata || mem_do_wdata)) begin
    if (mem_wordsize == 0 && reg_op1[1:0] != 0) begin
        // 非对齐字访问
        if (ENABLE_IRQ && !irq_mask[irq_buserror] && !irq_active) begin
            next_irq_pending[irq_buserror] = 1;
        end else
            cpu_state <= cpu_state_trap;
    end
end
```

### 外部中断 (IRQ)

当 `ENABLE_IRQ = 1` 时, PicoRV32 支持 32 个中断源。
中断入口地址为 `PROGADDR_IRQ` (默认 0x10)。

中断处理流程:
1. `irq` 信号置位 → `irq_pending` 锁存
2. 在 FETCH 阶段检测到 `irq_pending & ~irq_mask` 非零
3. 保存 PC 到内部寄存器, 跳转到 `PROGADDR_IRQ`
4. 软件执行 `RETIRQ` 指令返回

**本项目中 IRQ 未启用** (`ENABLE_IRQ = 0`), 因此 DMA/NPU 完成信号
通过轮询 (polling) 方式检测。

---

## 7.7 存储器接口

PicoRV32 使用一个简单的 valid/ready 握手接口与存储器通信:

```
         PicoRV32                    存储器 / 路由器
        ┌──────────┐                ┌──────────────┐
        │          │──mem_valid────→│              │
        │          │──mem_instr────→│              │
        │  CPU     │──mem_addr─────→│   Router     │
        │  Core    │──mem_wdata────→│   / Memory   │
        │          │──mem_wstrb────→│              │
        │          │←─mem_ready────│              │
        │          │←─mem_rdata────│              │
        └──────────┘                └──────────────┘
```

- `mem_valid`: CPU 发出请求
- `mem_instr`: 1=取指, 0=数据访问
- `mem_wstrb`: 字节写使能 (4'b0000=读)
- `mem_ready`: 存储器应答
- `mem_rdata`: 读数据

这个接口是 PicoRV32 与外部世界的唯一通道 —— 所有 ROM、RAM、
AXI 外设的访问都通过这组信号完成。下一讲将详细讲解地址路由器
如何将这组信号分发到不同的目标。

---

## 7.8 关键知识点总结

1. **PicoRV32 不是经典流水线**: 没有分支预测, 分支指令会阻塞等待
2. **两级流水线 = 取指 + 执行**: 通过 8 态 FSM 控制
3. **ALU 是组合逻辑**: 加减法器共用, 移位器可选桶形
4. **寄存器堆写回与取指重叠**: 减少一个周期的浪费
5. **存储器接口极简**: valid/ready 握手, 无 burst, 无缓存
6. **异常 = trap (停机) 或 IRQ (可恢复)**

---

## 7.9 动手练习

### 练习 1: 指令解码追踪

给定指令编码 `0x005202B3`, 请手动解码:
1. 提取 opcode (低 7 位)
2. 确定指令类别 (ALU-reg-reg / ALU-reg-imm / Load / Store / Branch)
3. 提取 funct3, funct7, rs1, rs2, rd
4. 确定具体指令

**提示**: 参照 `picorv32.v` 第 866-878 行的解码逻辑。

### 练习 2: 周期数分析

分析以下代码片段在 PicoRV32 上的执行周期数 (假设所有访存命中本地 ROM/RAM):

```assembly
    li   t0, 0x10000000    # 伪指令, 实际是 lui + addi
    lw   t1, 0(t0)         # 从本地 RAM 读
    add  t2, t1, t1        # 加法
    sw   t2, 4(t0)         # 写回 RAM
```

### 练习 3: 参数调优

如果目标 FPGA 只有 1000 个 LUT, 你会如何设置 PicoRV32 的参数?
写出具体的参数列表并解释每个选择的理由。

---

## 7.10 延伸阅读

- [PicoRV32 官方文档](https://github.com/YosysHQ/picorv32)
- [RISC-V 指令集手册 Volume I](https://riscv.org/technical/specifications/)
- `src/cpu/picorv32.v` 全文 (约 2500 行, 建议逐段阅读)
