# Lecture 09: CPU 固件 — 软硬件协同的入口

> **参考源码**: `src/instr_data.S`
> **前置知识**: Lecture 07 PicoRV32 核心, Lecture 08 CPU Wrapper 与地址路由
> **本节目标**: 逐行理解 CPU 固件的汇编代码, 掌握 MMIO 机制、轮询模式、
>              固件编译流程, 以及软硬件协同调试的基本方法

---

## 9.1 固件的角色

在本 SoC 中, CPU 固件 (firmware) 是一段运行在 PicoRV32 上的 RISC-V
汇编程序。它被编译为 `.dat` 文件, 通过 `$readmemh` 加载到 CPU ROM 中。

固件的职责是 **编排整个推理流程**: 配置 DMA → 启动 DMA → 轮询等待 → 触发 NPU → 轮询等待 → 读取结果。

---

## 9.1B 设计视角：为什么这样设计？

### 设计动机

CPU 固件是软硬件协同的"胶水层" —— 它不执行复杂计算, 只负责
**配置外设、启动传输、等待结果**。固件的设计直接影响 SoC 的
启动时间和可靠性。

### 方案对比

| 设计维度 | 本项目方案 (轮询) | 中断驱动方案 | 硬件自动方案 |
|----------|------------------|------------|------------|
| 控制方式 | CPU 主动轮询状态寄存器 | 外设完成时触发中断 | 硬件 FSM 自动串联 |
| CPU 占用 | 等待期间空转 | 等待期间可做其他事 | CPU 不参与 |
| 实现复杂度 | 低 (读+判断+跳转) | 高 (中断控制器+上下文保存) | 最高 (硬件编排逻辑) |
| 响应延迟 | 轮询间隔 (可预测) | 中断延迟 (不确定) | 零 (硬件直连) |
| 适用场景 | 单任务、短等待 | 多任务、长等待 | 固定流程、高性能 |

### 关键设计决策

**决策 1: 为什么选择轮询而非中断?**

```
中断方案的成本:
  ├── PicoRV32 中断入口固定在 0x10 → 只能放一条跳转指令
  ├── 需要保存/恢复上下文 (至少 4 条指令)
  ├── 中断优先级逻辑 → 硬件复杂度增加
  └── 本项目只有单一任务, 中断的优势 (多任务) 无法体现

轮询方案的优势:
  ├── 代码极简: 3 条指令 (lw + and + beq)
  ├── 延迟可预测: 固定轮询间隔
  ├── 无需中断控制器 → 面积更小
  └── 调试容易: 可以在轮询点打印状态
```

**决策 2: 为什么需要 DMA?**

```
没有 DMA 的方案:
  CPU 读 DDR → CPU 写 NPU RAM → 循环 1024 次
  时间: 1024 * (读周期 + 写周期) ≈ 4096 周期
  CPU 利用率: 100% (全程被占用)

有 DMA 的方案:
  CPU 写 5 个寄存器 (配置描述符) → DMA 自动搬运
  时间: 5 * 写周期 + DMA 并行搬运
  CPU 利用率: <5% (只做配置)

  DMA 的价值:
  ├── 释放 CPU: 配置完成后 CPU 可以做其他事
  ├── 高带宽: DMA 支持 burst 传输, 比 CPU 逐字搬运快 10-100 倍
  └── 可靠性: DMA 硬件自动处理地址对齐和突发边界
```

**决策 3: 为什么固件要回读验证 (read-back verify)?**

```
回读验证模式:
  sw t0, 0x50(s0)    # 写 CFG 寄存器
  lw t1, 0x50(s0)    # 回读 CFG
  bne t1, t2, fail   # 不一致则报错

为什么要回读:
  ├── 总线错误: AXI 写可能被 slave 拒绝 (SLVERR/DECERR)
  ├── 地址映射错误: 写到了错误的地址, 回读值不同
  ├── 寄存器保护: 某些寄存器可能有写保护
  └── 早期发现问题: 比等到 DMA 执行出错再排查更快
```

### 约束条件

| 约束 | 影响 | 应对策略 |
|------|------|----------|
| ROM 容量 4KB | 固件不能太大 | 精简代码, 避免库函数 |
| 无操作系统 | 无法用动态内存 | 全部用寄存器和栈 |
| 无 printf | 无法直接调试 | 用死循环 + testbench 检测 |
| 外设延迟不确定 | 不能用固定延时 | 必须轮询状态寄存器 |

---

## 9.1C 设计视角：如何从零开始设计？

假设你要为一个 SoC 编写裸机固件, 以下是推荐的设计步骤:

### Step 1: 梳理硬件资源

```
第一步: 列出所有外设及其寄存器

  外设          基地址          寄存器
  ─────────────────────────────────────
  DMA CSR       0x0002_1000    CONTROL, STATUS, SRC, DST, NUM, CFG
  NPU CSR       0x0003_0000    CTRL, STATUS, PRED
  DDR           0x4000_0000    (数据存储, 无寄存器)

  输出: 地址映射表 (就是本讲的 9.2 节)
```

### Step 2: 定义执行流程

```
第二步: 用伪代码描述固件逻辑

  main():
    // 1. 配置 DMA
    DMA.SRC     = 0x4000_0000      // DDR 源地址
    DMA.DST     = 0x0000_1000      // NPU RAM 目标地址
    DMA.NUM     = 4096             // 传输字节数
    DMA.CFG     = enable           // 使能描述符

    // 2. 启动 DMA
    DMA.CONTROL = go | max_burst

    // 3. 等待 DMA 完成
    while (DMA.STATUS.done == 0) {}
    if (DMA.STATUS.error) goto fail

    // 4. 启动 NPU
    NPU.CTRL = start

    // 5. 等待 NPU 完成
    while (NPU.PRED.valid == 0) {}

    // 6. 读取结果
    class_id = NPU.PRED.class_id
    logit    = NPU.PRED.logit

    goto done
```

### Step 3: 翻译为汇编

```
第三步: 将伪代码逐条翻译为 RISC-V 汇编

  关键技巧:
  ├── li 伪指令: 小立即数用 addi, 大立即数用 lui+addi
  ├── sw/lw 偏移: 寄存器基地址 + 固定偏移
  ├── 轮询循环: lw + and + beq 三条指令
  └── 死循环: jal x0, . (跳转到自身)

  示例:
    li   s0, 0x00021000       # → lui s0, 0x21 + addi s0, s0, 0
    li   t0, 0x40000000       # → lui t0, 0x40000
    sw   t0, 0x20(s0)         # 写 SRC_ADDR
```

### Step 4: 编译与验证

```
第四步: 编译汇编, 验证机器码

  编译命令:
    riscv32-unknown-elf-as -march=rv32i -o firmware.o firmware.S
    riscv32-unknown-elf-ld -Ttext 0x0 -o firmware.elf firmware.o
    riscv32-unknown-elf-objcopy -O verilog firmware.elf firmware.dat

  验证方法:
  ├── 反汇编: riscv32-unknown-elf-objdump -d firmware.elf
  ├── 逐条检查: 每条指令的机器码是否正确
  ├── 仿真: 将 .dat 加载到 ROM, 用 testbench 运行
  └── 对比: 仿真结果与预期一致
```

### Step 5: 调试与优化

```
第五步: 在仿真中调试固件

  调试手段:
  ├── ENABLE_TRACE: 每条指令打印 PC 和数据
  ├── ROM 打印: 仿真开始时输出 ROM 内容
  ├── 死循环检测: testbench 检测 PC 是否到达 done/fail
  └── 波形查看: 用 GTKWave 观察总线事务

  常见问题:
  ├── 地址错误: sw 写到了错误的地址 → 回读验证可发现
  ├── 立即数错误: lui/addi 组合错误 → 反汇编检查
  ├── 字节序: 小端 vs 大端 → 确认编译器设置
  └── 对齐: 非对齐访问 → PicoRV32 会 trap
```

---

## 9.1D 设计视角：架构模式与原则

### 模式 1: MMIO 驱动模式 (MMIO Driver Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  外设寄存器映射到 CPU 地址空间, 用普通 load/store 访问    │
  │                                                          │
  │  每个外设驱动 = 一组地址常量 + 读写函数                    │
  └──────────────────────────────────────────────────────────┘

C 语言视角:
  volatile uint32_t *dma = (uint32_t *)0x00021000;
  dma[8] = src_addr;    // 偏移 0x20 = 8*4
  dma[12] = dst_addr;   // 偏移 0x30 = 12*4

汇编视角:
  li   s0, 0x00021000    # 外设基地址
  sw   t0, 0x20(s0)      # 写寄存器
  lw   t1, 0x08(s0)      # 读寄存器

关键原则:
  ├── volatile: 告诉编译器不要优化掉 MMIO 访问
  ├── 基地址 + 偏移: 统一的寄存器访问模式
  ├── 回读验证: 写后立即读回确认
  └── 错误检查: 读状态寄存器判断操作是否成功
```

### 模式 2: 轮询等待模式 (Polling Wait Pattern)

```
模式要点:
  ┌──────────────────────────────────────────────────────────┐
  │  反复读取状态寄存器, 直到目标条件满足                      │
  │                                                          │
  │  标准模板:                                                │
  │    loop:                                                 │
  │      lw   t1, STATUS(s0)    # 读状态                     │
  │      and  t2, t1, MASK      # 提取目标位                  │
  │      beq  t2, x0, loop      # 未满足则继续                │
  └──────────────────────────────────────────────────────────┘

适用场景:
  ├── 外设完成时间短 (<1000 周期)
  ├── CPU 只有单一任务
  ├── 不需要中断优先级
  └── 调试阶段 (轮询点容易插入打印)

注意事项:
  ├── 死锁风险: 如果外设永远不会置位 done, CPU 永久卡死
  │   解决: 加入超时计数器, 或用 watchdog
  ├── 性能浪费: 空转期间 CPU 无法做其他事
  │   解决: 在轮询间隙插入轻量计算
  └── 一致性: 某些外设的状态寄存器读一次就清除
      解决: 读前确认寄存器行为 (读清/读保持)
```

---

## 9.2 内存映射 (Memory Map)

固件通过 **MMIO (Memory-Mapped I/O)** 访问硬件外设:

| 地址范围 | 设备 | 用途 |
|----------|------|------|
| 0x0000_0000 ~ 0x0000_0FFF | CPU ROM (4KB) | 存放固件指令 |
| 0x0000_1000 ~ 0x0002_0FFF | NPU LMEM (128KB) | DMA 传输目标 |
| 0x0002_1000 ~ 0x0002_1FFF | DMA CSR (4KB) | DMA 控制/状态 |
| 0x0003_0000 ~ 0x0003_0FFF | NPU CSR (4KB) | NPU 控制/状态 |
| 0x1000_0000 ~ 0x1000_3FFF | CPU RAM (4KB) | 本地数据存储 |
| 0x4000_0000 ~ 0x4003_FFFF | DDR (256KB) | 预加载图像数据 |

### DMA CSR 寄存器表 (基地址 0x0002_1000)

| 偏移 | 名称 | 位域 | 读写 |
|------|------|------|------|
| 0x00 | CONTROL | [0]=go, [1]=abort, [9:2]=max_burst | W |
| 0x08 | STATUS | [16]=done, [17]=error | R |
| 0x20 | SRC_ADDR_0 | [31:0] | W |
| 0x30 | DST_ADDR_0 | [31:0] | W |
| 0x40 | NUM_BYTES_0 | [31:0] | W |
| 0x50 | CFG_0 | [0]=wr_mode, [1]=rd_mode, [2]=enable | W |

### NPU CSR 寄存器表 (基地址 0x0003_0000)

| 偏移 | 名称 | 位域 | 读写 |
|------|------|------|------|
| 0x00 | CTRL | [0]=start | W |
| 0x04 | STATUS | [0]=busy, [1]=done | R |
| 0x20 | PRED | [0]=valid, [11:8]=class_id, [23:16]=logit | R |

---

## 9.3 逐行代码解析

下面逐段分析 `src/instr_data.S` 的每一行。

### 头部声明

```asm
# src/instr_data.S 第 25-27 行
.section .text
.globl _start

_start:
```

- `.section .text`: 将后续代码放入 `.text` 段 (代码段)
- `.globl _start`: 声明 `_start` 为全局符号, 作为程序入口点
- `_start:`: 入口标签, CPU 复位后从 `PROGADDR_RESET` (0x0000_0000) 开始执行

### Step 1: 配置 DMA 描述符

```asm
# src/instr_data.S 第 29-46 行
    # ---- Step 1: Configure DMA descriptor ----
    li   s0, 0x00021000       # DMA CSR base

    # SRC_ADDR = 0x4000_0000 (DDR)
    li   t0, 0x40000000
    sw   t0, 0x20(s0)

    # DST_ADDR = 0x0000_1000 (NPU RAM)
    li   t0, 0x00001000
    sw   t0, 0x30(s0)

    # NUM_BYTES = 4096 (1024 pixels x 4 bytes)
    li   t0, 0x1000
    sw   t0, 0x40(s0)

    # CFG_0: enable=1, rd_mode=INCR(0), wr_mode=INCR(0) -> bit[2]=1 -> 0x04
    li   t0, 0x04
    sw   t0, 0x50(s0)
```

**逐条指令分析**:

- `li s0, 0x00021000`: 加载 DMA CSR 基地址 (展开为 `lui` + `addi`)
- `sw t0, 0x20(s0)`: 写 SRC_ADDR = DDR 起始地址
- `sw t0, 0x30(s0)`: 写 DST_ADDR = NPU RAM 起始地址
- `sw t0, 0x40(s0)`: 写 NUM_BYTES = 4096
- `sw t0, 0x50(s0)`: 写 CFG = enable

**MMIO 写操作的硬件路径**:

```
  CPU (sw t0, 0x20(s0)) → mem_router (不在本地) → axi_adapter → AXI Crossbar → DMA CSR
```

### CFG 写验证

```asm
# src/instr_data.S 第 49-51 行
    lw   t1, 0x50(s0)       # 回读 CFG
    li   t2, 0x04
    bne  t1, t2, fail       # 不一致则跳转 fail
```

这是一个 **回读验证** 模式: 写入后立即读回检查。嵌入式固件常用此方法
检测总线错误或寄存器映射问题。

### Step 2: 启动 DMA

```asm
# src/instr_data.S 第 53-57 行
    # ---- Step 2: Start DMA ----
    # CONTROL: go=1 (bit[0]), max_burst=255 (bits[9:2])
    # (255 << 2) | 1 = 0x3FC | 0x01 = 0x3FD
    li   t0, 0x3FD
    sw   t0, 0x00(s0)
```

CONTROL 寄存器: `0x3FD = (255 << 2) | 1`, 即 max_burst=255, go=1。

写入 CONTROL 后, DMA 控制器开始从 DDR 读取数据并写入 NPU RAM。

### Step 3: 轮询 DMA 完成

```asm
# src/instr_data.S 第 60-65 行
    # ---- Step 3: Poll DMA done ----
    # STATUS[16] = done
poll_dma:
    lw   t1, 0x08(s0)
    li   t2, 0x10000          # bit 16
    and  t3, t1, t2
    beq  t3, x0, poll_dma
```

这是一个经典的 **轮询 (polling)** 循环:

```
  poll_dma:
      lw   t1, 0x08(s0)      # 读 DMA STATUS 寄存器
      li   t2, 0x10000        # 准备掩码 (bit 16)
      and  t3, t1, t2         # 提取 done 位
      beq  t3, x0, poll_dma   # done=0? 继续轮询
```

**执行流程**: 读 STATUS → 提取 done 位 → done=0 则回到 poll_dma, done=1 则继续。

**轮询的代价**: 每次循环大约消耗 8-10 个时钟周期 (3条指令,
每条 2-4 周期)。DMA 传输 4096 字节可能需要几百个周期,
因此 CPU 会空转几十次。但对于本应用来说, 这个开销可以接受。

### DMA 错误检查

```asm
# src/instr_data.S 第 68-70 行
    li   t2, 0x20000          # bit 17 = error
    and  t3, t1, t2
    bne  t3, x0, fail         # 有错误则跳转 fail
```

### Step 4: 触发 NPU

```asm
# src/instr_data.S 第 73-76 行
    li   s1, 0x00030000       # NPU CSR base
    li   t0, 0x01
    sw   t0, 0x00(s1)         # 写 CTRL[0]=1, 触发推理
```

### Step 5: 轮询 NPU 完成

```asm
# src/instr_data.S 第 79-83 行
poll_npu:
    lw   t1, 0x20(s1)        # 读 PRED 寄存器
    andi t2, t1, 0x01         # 提取 valid 位
    beq  t2, x0, poll_npu    # valid=0? 继续轮询
```

与 DMA 轮询结构相同, 读 NPU PRED 寄存器直到 valid 位置 1。

### Step 6: 读取推理结果

```asm
# src/instr_data.S 第 86-92 行
    srli t2, t1, 8            # 右移 8 位
    andi s2, t2, 0x0F         # s2 = class_id (PRED[11:8])

    srli t2, t1, 16           # 右移 16 位
    andi s3, t2, 0xFF         # s3 = logit   (PRED[23:16])
```

PRED 寄存器位域: `[0]=valid`, `[11:8]=class_id`, `[23:16]=logit`。
通过移位+掩码提取各字段, class_id 0-9 对应 CIFAR-10 的 10 个类别。

### Step 7: 死循环

```asm
# src/instr_data.S 第 95-99 行
done:
    jal  x0, done     # 死循环: 成功完成
fail:
    jal  x0, fail     # 死循环: 出错
```

`jal x0, target` 中 x0 是零寄存器, 返回地址被丢弃, 等价于无条件跳转。
仿真中测试平台检测 CPU 到达哪个死循环来判断测试结果。

---

## 9.4 `li` 伪指令的展开

`li` 是伪指令, 编译器根据立即数大小展开:

```asm
li t0, 0x04          # 小立即数 → addi t0, x0, 4          (1条指令)
li t0, 0x40000000    # 大立即数 → lui t0, 0x40000 + addi t0, t0, 0 (2条)
```

`lui rd, imm` 将 20 位立即数加载到 rd 高 20 位, 低 12 位清零。
所以 `lui s0, 0x21` 实际设置 `s0 = 0x00021000`。

---

## 9.5 轮询 vs 中断

本固件使用 **轮询 (Polling)** 方式等待 DMA 和 NPU 完成。
另一种方式是 **中断 (Interrupt)**。

### 轮询 vs 中断对比

| 维度 | 轮询 (Polling) | 中断 (Interrupt) |
|------|----------------|------------------|
| 实现复杂度 | 低 (读状态寄存器循环) | 高 (需中断控制器) |
| CPU 利用率 | 低 (空转等待) | 高 (可做其他任务) |
| 延迟可预测性 | 高 (固定轮询间隔) | 依赖中断优先级 |
| 适用场景 | 单任务、短等待 | 多任务、长等待 |

**本项目选择轮询的原因**: PicoRV32 中断机制简单 (向量地址固定 0x10),
固件只有单一任务, DMA/NPU 完成时间短, 轮询开销可忽略。

---

## 9.6 固件编译流程

从 `.S` 汇编源码到 `.dat` 文件的编译流程:

```
  .S → as → .o → ld → .elf → objcopy -O verilog → .dat → $readmemh → ROM
```

关键命令:
- `riscv32-unknown-elf-as -march=rv32i -mabi=ilp32 -o instr_data.o instr_data.S`
- `riscv32-unknown-elf-ld -Ttext 0x0 -o instr_data.elf instr_data.o`
- `riscv32-unknown-elf-objcopy -O verilog instr_data.elf instr_data.dat`

`-Ttext 0x0` 将代码段起始地址设为 0x0, 对应 ROM 起始地址。
`objcopy -O verilog` 输出每行一个 32 位十六进制数的格式, 供 `$readmemh` 使用。

`.dat` 文件每行一个 32 位十六进制数 (不含 `0x` 前缀), 对应一条指令。
注释在汇编阶段被丢弃。例如 `li s0, 0x00021000` 编译为 `00021437` (lui)。

---

## 9.7 调试技巧

| 方法 | 宏/代码位置 | 说明 |
|------|-------------|------|
| trace 输出 | `ENABLE_TRACE=1` | 每条指令执行后输出 PC 和数据 |
| ROM 打印 | `picorv32_axi.v` 第 374 行 | 仿真开始时打印 ROM 前 8 个字 |
| 寄存器监控 | `DEBUGREGS` 宏 | 暴露 x0-x31 的实时值 (`picorv32.v` 第 220 行) |
| 死循环检测 | testbench 中检测 `jal x0, .` | 判断 CPU 到达 `done` 还是 `fail` |

ROM 打印是最直接的验证手段 —— 仿真开始后控制台会输出:

```
[ROM] mem[0]=0x00021437
[ROM] mem[1]=0x400002b7
[ROM] mem[2]=0x02542023
...
```

将这些值与 `instr_data.dat` 对比, 可以确认固件是否正确加载。

---

## 9.8 MMIO 与链接脚本

### MMIO 的本质

MMIO (Memory-Mapped I/O) 的核心思想: **外设寄存器和存储器共享同一个地址空间**。
CPU 用普通的 `lw`/`sw` 指令访问特定地址, 总线硬件自动路由到对应外设。

```
  CPU 视角:                    硬件视角:
    sw t0, 0x20(s0)             地址 0x00021020 → DMA CSR → 触发寄存器写
    lw t1, 0x08(s0)             地址 0x00021008 → DMA CSR → 返回状态值
```

### 链接脚本

当前固件 (几十条指令, 无数据段, 无栈) 使用默认链接脚本即可,
链接器将代码放在地址 0x0, 对应 ROM 起始。如果固件变复杂则需要:

```ld
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 4K
}
SECTIONS {
    .text   : { *(.text) }   > ROM
    .data   : { *(.data) }   > RAM
    .bss    : { *(.bss)  }   > RAM
    .stack  : { . = ALIGN(4); . += 0x400; } > RAM
}
```

---

## 9.9 关键知识点总结

1. **固件 = 硬件的"驱动程序"**: 通过 MMIO 寄存器控制 DMA 和 NPU
2. **`li` 是伪指令**: 编译器自动展开为 `lui` + `addi`
3. **轮询简单但低效**: 适合单任务、短等待的场景
4. **中断高效但复杂**: 需要中断控制器, 适合多任务场景
5. **编译流程**: `.S` → `.o` → `.elf` → `.dat` → `$readmemh` 加载到 ROM
6. **调试方法**: trace、ROM 打印、寄存器监控、死循环检测

---

## 9.10 动手练习

### 练习 1: 手动汇编

将以下 C 代码翻译为 RISC-V 汇编:

```c
volatile int *dma_ctrl = (int *)0x00021000;
dma_ctrl[8] = 0x40000000;  // SRC_ADDR (偏移 0x20 = 8*4)
```

要求: 写出完整的汇编指令, 包括地址加载和存储操作。

### 练习 2: 编译验证

1. 安装 RISC-V 工具链 (`riscv32-unknown-elf-gcc`)
2. 使用上面的 Makefile 编译 `instr_data.S`
3. 对比生成的 `.dat` 文件和项目中的 `src/instr_data.dat`
4. 分析差异 (如果有) 的原因

### 练习 3: 性能分析

假设系统时钟 50MHz, DMA 传输需 1024 周期, NPU 推理需 2048 周期。
计算整个推理流程的总延迟 (微秒), 以及轮询期间 CPU 空转的周期数。

---

## 9.11 延伸阅读

- `src/instr_data.S` 全文 (99 行)
- `src/instr_data.dat` (编译后的 hex 文件)
- RISC-V 汇编手册: https://github.com/riscv/riscv-asm-manual
- PicoRV32 中断机制: https://github.com/YosysHQ/picorv32#native-irq-interface
