# Lecture 25: 验证方法学 -- 测试架构与 BFM

## 课程目标

本讲深入讲解 FPGA SoC 项目的验证架构设计。学完本讲后，你将能够：

1. 理解 `soc_tb.sv` 的整体结构与模块层次关系
2. 掌握 AXI-Lite BFM task 的实现原理（force/release 驱动）
3. 区分三种测试层级：单元测试、集成测试、系统测试
4. 独立编写新的 DMA CSR 驱动 task
5. 理解 force/release 在验证中的正确使用方式

---

## 1. 验证架构总览

### 1.1 DUT 与 Testbench 的层次关系

```
  soc_tb (顶层测试平台)
    |
    +-- soc_top (DUT: 被测设计)
    |     |
    |     +-- u_cpu    (picorv32 RISC-V CPU)
    |     +-- u_crossbar (AXI Crossbar, 3主3从)
    |     |     +-- slv0: DDR
    |     |     +-- slv1: NPU
    |     |     +-- slv2: (未使用)
    |     |     +-- mst0: CPU bridge
    |     |     +-- mst1: DMA
    |     |     +-- mst2: CPU CSR access
    |     +-- u_dma    (DMA 控制器)
    |     |     +-- u_dma_axi_wrapper
    |     |     |     +-- u_dma_csr    (CSR 寄存器文件)
    |     |     |     +-- u_dma_func_wrapper
    |     |     |           +-- u_dma_fifo
    |     |     |           +-- u_dma_streamer
    |     |     |           +-- u_dma_axi_if
    |     |     |           +-- u_dma_fsm
    |     +-- u_ddr    (DDR 控制器 + 存储)
    |     +-- u_npu    (NPU 加速器)
    |           +-- u_conv (卷积引擎)
    |           |     +-- u_csr (NPU CSR)
    |           |     +-- u_mac (MAC 阵列)
    |           +-- u_fc   (全连接层)
    |           +-- u_npu_ram (本地 SRAM)
    |
    +-- 辅助 task / BFM (在 soc_tb 内部定义)
```

**关键设计原则**：Testbench 通过层次路径（hierarchical path）直接访问 DUT 内部信号，
这使得我们可以用 `force/release` 驱动任意内部节点，绕过正常的数据通路。

### 1.2 地址映射常量

```systemverilog
// 文件: tb/soc_tb.sv, 第 6-9 行
localparam logic [31:0] DDR_BASE      = 32'h4000_0000;  // DDR 起始地址
localparam logic [31:0] NPU_LMEM_BASE = 32'h0000_1000;  // NPU 本地 SRAM
localparam logic [31:0] NPU_CSR_BASE  = 32'h0003_0000;  // NPU CSR 寄存器
localparam logic [31:0] DMA_CSR_BASE  = 32'h0002_1000;  // DMA CSR 寄存器
```

这些常量与 `soc_top.sv` 中的地址解码保持一致，测试中所有地址计算都基于这些基址。

---

### 设计视角：为什么这样设计？

验证架构的设计选择直接影响测试的可维护性、覆盖率和调试效率。本节从动机、替代方案和约束三个维度分析关键设计决策。

**核心动机：**

本项目选择基于 force/release 的 BFM 方案，而非直接信号驱动或 UVM 方法学，这背后有明确的工程考量：

```
  设计决策树:

  验证方法选择
    │
    ├── 方案A: 直接信号连接 (port-level driver)
    │   优点: 信号关系明确, 编译时可检查
    │   缺点: 需要修改 DUT 端口列表, 增加引出信号
    │   问题: DUT 顶层仅暴露 3 个信号, 大量内部信号无法访问
    │
    ├── 方案B: UVM Agent + Driver + Monitor
    │   优点: 标准化, 可复用, 支持随机化
    │   缺点: 学习曲线陡峭, 代码量 10× 以上
    │   问题: 项目周期短, 团队规模小, 投入产出比低
    │
    └── 方案C: force/release BFM (本设计采用) ★
        优点: 无需修改 DUT, 可访问任意内部节点, 代码简洁
        缺点: 路径硬编码, DUT 层次变更需同步修改
        适用: FPGA 验证项目, 快速迭代, 小团队
```

**替代方案对比：**

| 维度 | Port-level Driver | UVM Agent | force/release BFM |
|------|-------------------|-----------|-------------------|
| DUT 修改 | 需要添加端口 | 不需要 | 不需要 |
| 内部信号访问 | 有限（需额外引出） | 需要 backdoor | 任意节点 |
| 代码量（同等功能） | ~500 行 | ~3000 行 | ~300 行 |
| 学习成本 | 低 | 高 | 低 |
| 可复用性 | 中 | 高 | 低 |
| 调试便利性 | 中 | 高（有 wave agent） | 高（层次路径直觉） |
| 适用规模 | 中小 | 大 | 中小 |

**项目约束分析：**

```
  约束条件                 影响                     设计决策
  ────────────────────────────────────────────────────────────────
  DUT 顶层仅 3 个信号       无法通过端口驱动内部       必须用层次路径访问
  团队 1-2 人               无法维护 UVM 框架          选择轻量级 BFM
  项目周期 ~2 个月          需要快速出结果              force/release 最快
  仿真器: ModelSim          对 UVM 支持有限            避免 UVM 依赖
  目标: 覆盖率 >= 95%       需要精确控制内部状态       force 可直达目标信号
  ────────────────────────────────────────────────────────────────
```

**为什么 force/release 而不是层次路径直接赋值？**

```
  直接赋值:   u_soc.u_dma.dma_s_awvalid = 1'b1;   // 仅在 initial/always 块中有效
  force:      force u_soc.u_dma.dma_s_awvalid = 1'b1;  // 覆盖任何驱动源

  区别:
  ┌────────────────────────────────────────────────────────┐
  │ 直接赋值: 与 DUT 内部驱动竞争, 结果不确定              │
  │ force:    强制覆盖, 无论 DUT 内部驱动为何值            │
  │                                                      │
  │ 场景: DMA CSR 输入端口由 crossbar 驱动                │
  │ 直接赋值: crossbar 的输出会覆盖赋值                    │
  │ force:    强制覆盖 crossbar 的输出, BFM 完全控制       │
  └────────────────────────────────────────────────────────┘
```

---

### 设计视角：如何从零开始设计？

构建一个 FPGA SoC 验证环境需要系统化的方法。以下是从零开始的五步设计流程。

**步骤 1：分析 DUT 接口与内部结构**

```
  输入: DUT 顶层 RTL (soc_top.sv)
  输出: 信号清单 + 层次路径表

  分析内容:
  ┌─────────────────────────────────────────────────────────┐
  │ 1. 列出 DUT 顶层端口 (clk, rst, dma_done, ...)         │
  │ 2. 遍历 DUT 内部模块层次 (u_cpu, u_crossbar, ...)      │
  │ 3. 识别关键内部信号路径:                                 │
  │    · CSR 寄存器地址 (DMA_CSR_BASE, NPU_CSR_BASE)       │
  │    · 存储器数组路径 (u_ddr.mem, u_npu_ram.mem)          │
  │    · 控制信号 (reg_go, reg_abort, dma_done)            │
  │ 4. 绘制 DUT 模块层次图                                  │
  └─────────────────────────────────────────────────────────┘
```

**步骤 2：定义地址映射与常量**

```
  // 建立地址映射常量 (与 DUT 保持一致)
  localparam DDR_BASE      = 32'h4000_0000;
  localparam NPU_LMEM_BASE = 32'h0000_1000;
  localparam NPU_CSR_BASE  = 32'h0003_0000;
  localparam DMA_CSR_BASE  = 32'h0002_1000;

  // 建立存储器访问宏
  `define DDR_MEM u_soc.u_ddr.mem
  `define NPU_MEM u_soc.u_npu.u_npu_ram.mem

  设计原则:
  · 所有地址常量集中定义, 修改时只需改一处
  · 存储器宏使用完整层次路径, 方便全局替换
```

**步骤 3：实现基础 Task（存储器访问 + 等待 + 检查）**

```
  Task 设计层次:

  Layer 1: 原子操作
  ├── ddr_write32(addr, data)    // DDR 单字写
  ├── ddr_read32(addr, data)     // DDR 单字读
  └── npu_write32(addr, data)    // NPU RAM 单字写

  Layer 2: 控制操作
  ├── wait_dma(timeout, ok)      // 带超时等待
  └── check(name, ok)            // PASS/FAIL 统计

  Layer 3: BFM 操作
  ├── axil_dma_write(addr, data) // AXI-Lite 写 BFM
  └── axil_dma_read(addr, data)  // AXI-Lite 读 BFM

  Layer 4: 业务操作
  ├── dma_force_csr(src, dst, nbytes, burst)  // 批量配置 DMA
  └── dma_release_csr()                        // 释放 DMA CSR

  从底层向上构建, 每层只调用下层 Task
```

**步骤 4：编写 BFM Task（协议级驱动）**

```
  BFM 设计模板:

  task axil_xxx_write(addr, data);
    // Phase 1: Force 驱动所有 AXI-Lite 写通道信号
    force awvalid = 1; force awaddr = addr;
    force wvalid  = 1; force wdata  = data;
    force bready  = 1;

    // Phase 2: 等待 AW+W 握手 (带超时)
    @(posedge clk);
    timeout = 100;
    while (timeout > 0 && !(awready && wready))
      begin @(posedge clk); timeout--; end

    // Phase 3: 释放 AW+W 信号
    release awvalid; release awaddr;
    release wvalid;  release wdata;

    // Phase 4: 等待 B 响应 (带超时)
    timeout = 100;
    while (timeout > 0 && !bvalid)
      begin @(posedge clk); timeout--; end
    @(posedge clk);
    release bready;
  endtask
```

**步骤 5：组织测试用例并建立回归流程**

```
  测试组织结构:

  initial begin
    // 阶段 1: 基础功能 (快速失败检测)
    test_ddr();           // 如果 DDR 都不通, 后续测试无意义
    test_npu_ram();

    // 阶段 2: 模块功能 (按复杂度递增)
    test_dma_burst();     // 先测基本传输
    test_dma_4kb();       // 再测边界条件
    test_dma_abort();     // 最后测异常处理

    // 阶段 3: 集成测试
    test_npu_conv1();     // NPU 卷积
    test_npu_fc();        // NPU 全连接

    // 阶段 4: 覆盖率补充
    test_xxx_backpressure();
    test_xxx_coverage();

    // 阶段 5: 端到端 (放最后)
    test_cpu_dma_npu();

    // 最终统计
    $display("PASS=%0d FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt > 0) $finish(1);
  end
```

---

### 设计视角：架构模式与原则

验证架构中存在多种可复用的设计模式。掌握这些模式可以快速构建可靠的验证环境。

**模式 1：BFM（Bus Functional Model）模式**

```
  BFM 模式的核心思想: 用 Task 封装协议行为, 对外提供读/写接口

  ┌─────────────────────────────────────────────────────────┐
  │                   BFM 模式结构                           │
  │                                                         │
  │  Test Case Layer                                        │
  │  ┌───────────┐  ┌───────────┐  ┌───────────┐           │
  │  │ test_01() │  │ test_02() │  │ test_03() │           │
  │  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘           │
  │        │              │              │                   │
  │  BFM Task Layer       │              │                   │
  │  ┌─────┴──────────────┴──────────────┴─────┐            │
  │  │  axil_write(addr, data)                  │            │
  │  │  axil_read(addr, data)                   │            │
  │  │  dma_force_csr(src, dst, len, burst)     │            │
  │  └─────────────────┬───────────────────────┘            │
  │                    │                                     │
  │  Signal Layer      │                                     │
  │  ┌─────────────────┴───────────────────────┐            │
  │  │  force / release (直接驱动 DUT 内部信号)   │            │
  │  └──────────────────────────────────────────┘            │
  └─────────────────────────────────────────────────────────┘

  优点:
  · 测试用例不关心协议细节 (握手时序由 BFM 处理)
  · 协议变更只需修改 BFM, 测试用例无需改动
  · 多个测试复用同一套 BFM Task
```

**模式 2：Force/Release 定向测试模式**

```
  适用场景: 需要覆盖正常流程中难以到达的内部状态

  ┌─────────────────────────────────────────────────────────┐
  │              Force/Release 定向测试模式                   │
  │                                                         │
  │  正常流程:                                               │
  │    CPU → Crossbar → DMA CSR → DMA FSM → 数据搬运        │
  │    (路径长, 难以精确控制 DMA FSM 状态)                    │
  │                                                         │
  │  Force 定向:                                             │
  │    TB --force--> DMA CSR.reg_go     (直接触发)           │
  │    TB --force--> DMA CSR.reg_abort  (精确中止)           │
  │    TB --force--> DDR.st = ST_WRESP  (制造反压)           │
  │                                                         │
  │  模式流程:                                               │
  │    1. force 目标信号到特定值                              │
  │    2. repeat(N) @(posedge clk)  // 等待信号传播          │
  │    3. 观察 DUT 行为                                      │
  │    4. release 目标信号                                   │
  │    5. 校验结果                                           │
  │                                                         │
  │  注意事项:                                               │
  │    · 每个 force 必须有对应的 release                     │
  │    · force 后至少等待 1 个时钟周期                       │
  │    · 测试结束时检查是否有遗漏的 force                    │
  └─────────────────────────────────────────────────────────┘

  典型应用 (本项目):
  · Test 25: force reg_abort 制造 DMA 中止场景
  · Test 51: force DDR FSM 制造反压场景
  · Test 53: force rst 制造复位覆盖场景
```

**模式 3：超时保护模式（Timeout Guard）**

```
  任何等待 DUT 响应的操作都必须有超时保护:

  ┌─────────────────────────────────────────────────────────┐
  │               超时保护模式 (fork/join_any)                │
  │                                                         │
  │  task wait_with_timeout(input int max_ns, output bit ok);│
  │    ok = 0;                                              │
  │    fork                                                 │
  │      begin                                              │
  │        wait(dut_done_signal);                           │
  │        ok = 1;  // DUT 正常完成                          │
  │      end                                                │
  │      begin                                              │
  │        #max_ns;                                         │
  │        $display("[TB] TIMEOUT after %0dns", max_ns);    │
  │        // ok 保持 0 → 测试判定为 FAIL                    │
  │      end                                                │
  │    join_any                                             │
  │    disable fork;  // 终止未完成的线程                     │
  │  endtask                                                │
  │                                                         │
  │  为什么需要超时保护?                                     │
  │  · DUT 可能因 bug 挂死 (死锁/活锁)                      │
  │  · 无超时的测试在 CI 中会永远卡住                        │
  │  · 超时后仍能输出诊断信息, 辅助定位 bug                  │
  └─────────────────────────────────────────────────────────┘

  BFM 中的超时应用:
  · AW/W 握手等待: timeout = 100 cycles
  · B 响应等待: timeout = 100 cycles
  · DMA 完成等待: timeout = 2,000,000 ns (2ms)
  · 端到端等待: timeout = 80,000,000 cycles (400ms)
```

---

## 2. 时钟与复位生成

```systemverilog
// 文件: tb/soc_tb.sv, 第 11-13 行
logic clk, rst;
initial begin clk=0; forever #2.5 clk=~clk; end   // 200MHz 时钟 (5ns 周期)
initial begin rst=1; #100 rst=0; end               // 100ns 复位脉冲
```

```
  时间轴:
  0ns       100ns                    --> 持续运行
  rst:  |=====|                       (高有效复位)
  clk:  |_|_|_|_|_|_|_|_|_|_|_|_...  (5ns 周期, 200MHz)
```

**要点**：
- 时钟周期 5ns = 200MHz，这是 FPGA SoC 的典型主频
- 复位 100ns = 20 个时钟周期，确保所有寄存器初始化完成
- `initial` 块在仿真开始时自动执行，无需外部触发

---

## 3. DUT 例化与信号连接

```systemverilog
// 文件: tb/soc_tb.sv, 第 15-19 行
logic dma_done, dma_error, cpu_trap;
soc_top #(.DDR_INIT_FILE("")) u_soc (
  .clk(clk), .rst(rst),
  .dma_done_o(dma_done), .dma_error_o(dma_error), .cpu_trap_o(cpu_trap)
);
```

DUT 顶层只暴露了 3 个状态输出信号：

| 信号 | 含义 | 何时置位 |
|------|------|---------|
| `dma_done` | DMA 传输完成 | DMA FSM 进入 DONE 状态 |
| `dma_error` | DMA 传输错误 | AXI 响应 SLVERR/DECERR |
| `cpu_trap` | CPU 异常 | 非法指令/中断 |

**设计意图**：Testbench 通过这三个信号判断测试结果，而不需要逐周期检查内部状态。

---

## 4. 存储器直接访问 Task

### 4.1 DDR 读写 Task

```systemverilog
// 文件: tb/soc_tb.sv, 第 21-34 行
`define DDR_MEM u_soc.u_ddr.mem
`define NPU_MEM u_soc.u_npu.u_npu_ram.mem

task ddr_write32(input logic[31:0] addr, input logic[31:0] data);
  int b; b = addr - DDR_BASE;
  `DDR_MEM[b+3]=data[31:24]; `DDR_MEM[b+2]=data[23:16];
  `DDR_MEM[b+1]=data[15:8];  `DDR_MEM[b+0]=data[7:0];
endtask

task ddr_read32(input logic[31:0] addr, output logic[31:0] data);
  int b; b = addr - DDR_BASE;
  data = {`DDR_MEM[b+3],`DDR_MEM[b+2],`DDR_MEM[b+1],`DDR_MEM[b+0]};
endtask
```

**字节序说明**：
- 存储器以字节（byte）为单位寻址
- 32 位数据按小端序（Little-Endian）存放
- `addr` 是绝对地址，减去 `DDR_BASE` 后得到存储器数组索引

```
  地址映射示意:
  绝对地址         存储器索引    字节
  0x4000_0000  --> mem[0]     = data[7:0]
  0x4000_0001  --> mem[1]     = data[15:8]
  0x4000_0002  --> mem[2]     = data[23:16]
  0x4000_0003  --> mem[3]     = data[31:24]
  0x4000_0004  --> mem[4]     = 下一个 word 的 [7:0]
```

### 4.2 NPU RAM 读写 Task

```systemverilog
// 文件: tb/soc_tb.sv, 第 35-42 行
task npu_write32(input logic[31:0] addr, input logic[31:0] data);
  int b; b = addr - NPU_LMEM_BASE;
  `NPU_MEM[b+3]=data[31:24]; `NPU_MEM[b+2]=data[23:16];
  `NPU_MEM[b+1]=data[15:8];  `NPU_MEM[b+0]=data[7:0];
endtask
```

与 DDR task 完全对称，只是基址不同（`NPU_LMEM_BASE = 0x1000`）。

---

## 5. DMA 等待与检查 Task

### 5.1 wait_dma -- 带超时的等待

```systemverilog
// 文件: tb/soc_tb.sv, 第 43-49 行
task wait_dma(input int ns, output bit ok);
  ok = 0;
  fork
    begin wait(dma_done||dma_error||cpu_trap); ok = 1; end
    begin #ns; $display("[TB] WARN: DMA TIMEOUT %0dns",ns); end
  join_any disable fork;
endtask
```

**fork/join_any 模式解析**：

```
  fork
    +-- 线程 A: wait(dma_done||dma_error||cpu_trap)  --> 如果先完成, ok=1
    +-- 线程 B: #ns (等待 ns 纳秒)                    --> 如果先超时, ok=0
  join_any   // 任一线程完成即继续
  disable fork;  // 终止未完成的线程
```

这是 SystemVerilog 中经典的 **超时保护** 模式，防止测试因 DUT 挂死而永远等待。

### 5.2 check -- 统计 PASS/FAIL

```systemverilog
// 文件: tb/soc_tb.sv, 第 51-56 行
bit _dma_ok;
int pass_cnt=0, fail_cnt=0;
task check(string name, bit ok);
  if(ok) begin $display("[TB] PASS: %s",name); pass_cnt++; end
  else    begin $error("[TB] FAIL: %s",name);  fail_cnt++; end
endtask
```

---

## 6. AXI-Lite BFM（总线功能模型）

### 6.1 什么是 BFM？

BFM（Bus Functional Model）是验证中用于模拟总线主设备行为的 task 集合。本项目中，
BFM 不是独立模块，而是直接写在 testbench 中的 task。

```
  正常数据通路:
  CPU --> CPU Bridge --> Crossbar --> DMA CSR
                    (复杂的协议转换)

  BFM 直接驱动:
  TB --force--> DMA CSR 输入端口
            (绕过 crossbar, 直接覆盖信号)
```

### 6.2 axil_dma_write -- AXI-Lite 写 BFM

```systemverilog
// 文件: tb/soc_tb.sv, 第 62-90 行
task axil_dma_write(input logic [31:0] addr, input logic [31:0] data);
  int timeout;
  // 第一步: force 驱动所有 AXI-Lite 写通道信号
  force u_soc.u_dma.dma_s_awvalid = 1'b1;
  force u_soc.u_dma.dma_s_awaddr  = addr;
  force u_soc.u_dma.dma_s_wvalid  = 1'b1;
  force u_soc.u_dma.dma_s_wdata   = data;
  force u_soc.u_dma.dma_s_wstrb   = 4'hF;   // 全字节有效
  force u_soc.u_dma.dma_s_bready  = 1'b1;

  // 第二步: 等待 AW+W 握手完成
  @(posedge clk);
  timeout = 100;
  while (timeout > 0) begin
    if (u_soc.u_dma.dma_s_awready && u_soc.u_dma.dma_s_wready) break;
    @(posedge clk); timeout--;
  end

  // 第三步: 释放 AW+W 信号
  release u_soc.u_dma.dma_s_awvalid;
  release u_soc.u_dma.dma_s_wvalid;
  release u_soc.u_dma.dma_s_awaddr;
  release u_soc.u_dma.dma_s_wdata;
  release u_soc.u_dma.dma_s_wstrb;

  // 第四步: 等待 B 响应
  timeout = 100;
  while (!u_soc.u_dma.dma_s_bvalid && timeout > 0) begin
    @(posedge clk); timeout--;
  end
  @(posedge clk);
  release u_soc.u_dma.dma_s_bready;
endtask
```

**时序图**：

```
  时钟:   _|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
  awvalid: ‾‾‾‾‾‾‾‾‾‾|_________________________
  awaddr:  == ADDR ============================___
  wvalid:  ‾‾‾‾‾‾‾‾‾‾|_________________________
  wdata:   == DATA ============================___
  awready: _________|‾‾‾‾‾‾‾|___________________
  wready:  _________|‾‾‾‾‾‾‾|___________________
  bvalid:  _______________________|‾‾‾‾‾‾‾|_____
  bready:  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|_____
           ^force    ^握手完成   ^release    ^B响应
```

**关键知识点**：

1. **force 覆盖**：`force` 语句可以覆盖任何线网或寄存器的值，包括模块端口
2. **必须 release**：每个 `force` 必须有对应的 `release`，否则信号会被永久锁定
3. **超时保护**：所有 while 循环都有 timeout 计数器，防止死锁
4. **stripped 地址**：BFM 使用的地址是 DMA CSR 内部偏移地址（如 `0x20` = SRC0），而非
   绝对地址（`0x0002_1020`），因为 force 直接作用于 DMA 模块端口

### 6.3 axil_dma_read -- AXI-Lite 读 BFM

```systemverilog
// 文件: tb/soc_tb.sv, 第 92-111 行
task axil_dma_read(input logic [31:0] addr, output logic [31:0] data);
  int timeout;
  data = 32'hDEAD_DEAD;  // 默认值，用于检测超时
  force u_soc.u_dma.dma_s_arvalid = 1'b1;
  force u_soc.u_dma.dma_s_araddr  = addr;
  force u_soc.u_dma.dma_s_rready  = 1'b1;
  @(posedge clk);
  timeout = 100;
  while (!u_soc.u_dma.dma_s_arready && timeout > 0) begin
    @(posedge clk); timeout--;
  end
  release u_soc.u_dma.dma_s_arvalid;
  release u_soc.u_dma.dma_s_araddr;
  // 等待 R 数据
  timeout = 100;
  while (!u_soc.u_dma.dma_s_rvalid && timeout > 0) begin
    @(posedge clk); timeout--;
  end
  if (u_soc.u_dma.dma_s_rvalid) data = u_soc.u_dma.dma_s_rdata;
  @(posedge clk);
  release u_soc.u_dma.dma_s_rready;
endtask
```

**读操作的两个阶段**：
1. **AR 握手**：发送读地址，等待 `arready`
2. **R 握手**：等待 `rvalid`，采样 `rdata`

---

## 7. DMA CSR Force/Release Task

### 7.1 dma_force_csr -- 批量配置 DMA 寄存器

```systemverilog
// 文件: tb/soc_tb.sv, 第 114-127 行
task dma_force_csr(
  input logic [31:0] src, dst, nbytes,
  input logic [7:0] max_burst
);
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_src_addr[0]  = src;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_dst_addr[0]  = dst;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_num_bytes[0] = nbytes;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_wr_mode[0]   = 1'b0;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0]   = 1'b0;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_enable[0]    = 1'b1;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_max_burst    = max_burst;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort        = 1'b0;
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go           = 1'b0;
endtask
```

**寄存器说明**：

| 寄存器 | 作用 | 示例值 |
|--------|------|--------|
| `reg_src_addr[0]` | 源地址（描述符 0） | `0x4000_0000` |
| `reg_dst_addr[0]` | 目标地址（描述符 0） | `0x0000_1000` |
| `reg_num_bytes[0]` | 传输字节数 | `4096` |
| `reg_max_burst` | 最大突发长度 | `255` (256 拍) |
| `reg_enable[0]` | 描述符使能 | `1` |
| `reg_go` | 触发 DMA 启动 | 先 force 0，后单独 force 1 |

**设计要点**：`reg_go` 在 `dma_force_csr` 中被设为 0，需要单独 force 为 1 来触发 DMA。
这是因为 `go` 是一个脉冲信号，需要精确控制其上升沿时刻。

### 7.2 dma_release_csr -- 释放所有强制信号

```systemverilog
// 文件: tb/soc_tb.sv, 第 129-138 行
task dma_release_csr();
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_src_addr[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_dst_addr[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_num_bytes[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_wr_mode[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_enable[0];
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_max_burst;
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort;
endtask
```

**force/release 配对原则**：

```
  dma_force_csr(...)    // 设置所有寄存器
  force reg_go = 1;     // 触发 DMA
  @(posedge clk);
  release reg_go;       // 释放 go
  wait_dma(...);        // 等待完成
  dma_release_csr();    // 释放所有寄存器
```

每个测试 task 都必须遵循 **force -> 触发 -> 等待 -> release** 的完整流程。

---

## 8. 典型 DMA 测试模式

### 8.1 DMA 传输的完整流程

```
  +-------------------+
  | 1. 预加载源存储器  |  ddr_write32() 或直接操作 DDR_MEM
  +--------+----------+
           |
  +--------v----------+
  | 2. 清空目标存储器  |  NPU_MEM[i] = 0
  +--------+----------+
           |
  +--------v----------+
  | 3. Force DMA CSR  |  dma_force_csr(src, dst, nbytes, burst)
  +--------+----------+
           |
  +--------v----------+
  | 4. 触发 reg_go    |  force reg_go = 1; @(posedge clk); release
  +--------+----------+
           |
  +--------v----------+
  | 5. 等待完成       |  wait_dma(timeout, ok)
  +--------+----------+
           |
  +--------v----------+
  | 6. 释放 CSR       |  dma_release_csr()
  +--------+----------+
           |
  +--------v----------+
  | 7. 校验数据       |  比较源和目标存储器内容
  +-------------------+
```

### 8.2 Go 脉冲的精确控制

```systemverilog
// 典型的 DMA 触发序列
dma_force_csr(DDR_BASE, NPU_LMEM_BASE, 32'd4096, 8'd255);
repeat(3) @(posedge clk);                          // 等待 3 个周期让 force 生效
force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go = 1'b1;
@(posedge clk);                                     // go=1 持续 1 个周期
release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go;
wait_dma(2_000_000, _dma_ok);                       // 最长等待 2ms
dma_release_csr();
repeat(5) @(posedge clk);                          // 等待信号稳定
```

---

## 9. 测试分类体系

### 9.1 三级测试分类

```
  +------------------------------------------------------------------+
  |                     系统测试 (System Test)                        |
  |  Test 28: CPU 执行 ROM 指令, 配置 DMA, 搬运图像,                 |
  |           触发 NPU 推理, 读取预测结果                              |
  |  特点: 全链路经过 CPU -> Crossbar -> DMA -> NPU                   |
  +------------------------------------------------------------------+
          |
  +------------------------------------------------------------------+
  |                   集成测试 (Integration Test)                     |
  |  Test 3-5:  DMA 搬运 DDR -> NPU RAM (多种 burst 长度)            |
  |  Test 6-7:  NPU conv1 + FC 完整推理流程                          |
  |  Test 18:   DMA 4KB 边界穿越                                     |
  |  特点: 多模块协作, 但通过 force 绕过部分路径                       |
  +------------------------------------------------------------------+
          |
  +------------------------------------------------------------------+
  |                    单元测试 (Unit Test)                           |
  |  Test 1:    DDR 基本读写                                         |
  |  Test 2:    NPU RAM 读写                                         |
  |  Test 8:    NPU CSR 寄存器读写                                   |
  |  Test 11:   DDR 越界访问                                         |
  |  特点: 单模块功能验证, 覆盖特定代码路径                           |
  +------------------------------------------------------------------+
```

### 9.2 覆盖率驱动的补充测试

```
  +------------------------------------------------------------------+
  |              覆盖率补充测试 (Coverage Boost Tests)                |
  |  Test 47: NPU CSR backpressure                                   |
  |  Test 48: DMA CSR backpressure                                   |
  |  Test 49: AXI handshake condition coverage                       |
  |  Test 50: Comprehensive coverage boost                           |
  |  Test 51: DDR backpressure via FSM force                         |
  |  特点: 针对未覆盖的条件分支, 通过 force 制造特定场景              |
  +------------------------------------------------------------------+
```

---

## 10. 知识要点总结

| 编号 | 知识点 | 核心概念 |
|------|--------|---------|
| K1 | 存储器直接访问 | 通过层次路径 `u_soc.u_ddr.mem` 操作存储器数组 |
| K2 | 字节序 | 小端序: 低地址存放低字节 |
| K3 | fork/join_any | 超时保护模式, 防止测试挂死 |
| K4 | force/release | 覆盖内部信号, 必须成对使用 |
| K5 | BFM | 总线功能模型, 模拟协议握手 |
| K6 | AXI-Lite 写 | AW 握手 + W 握手 + B 响应 |
| K7 | AXI-Lite 读 | AR 握手 + R 数据 |
| K8 | DMA 触发 | force CSR -> force go -> release go -> wait |
| K9 | 测试分类 | 单元/集成/系统三级 |

---

## 11. 动手练习

### 练习 1: 分析 DMA BFM 时序

阅读 `tb/soc_tb.sv` 第 62-90 行的 `axil_dma_write` task，回答：

1. 如果 DUT 的 `dma_s_awready` 始终为 0，BFM 会等待多少个时钟周期后超时？
2. `dma_s_wstrb = 4'hF` 表示什么含义？如果改为 `4'h1` 会怎样？
3. 为什么 `bready` 的 release 放在 `bvalid` 检测之后，而不是和 awvalid 一起释放？

### 练习 2: 编写新的 DMA BFM Task

参考 `axil_dma_write`，编写一个 `axil_dma_write_strb` task，支持自定义 `wstrb` 参数：

```systemverilog
task axil_dma_write_strb(
  input logic [31:0] addr,
  input logic [31:0] data,
  input logic [3:0]  strb    // 新增: 自定义字节选通
);
  // 你的代码...
endtask
```

### 练习 3: 分析 force/release 时序

在 `test_dma_burst()`（第 186-206 行）中，标注每个 `force` 和 `release` 语句的执行时刻，
绘制完整的时序图，说明信号在每个时钟沿的状态变化。

### 练习 4: 设计 NPU CSR BFM

当前 testbench 对 NPU CSR 的操作使用直接 force（如第 382-416 行的 `test_npu_csr`），
而 DMA CSR 有完整的 BFM task。请参考 `axil_dma_write/read`，设计 `axil_npu_write` 和
`axil_npu_read` BFM task，驱动 NPU 的 AXI-Lite 从接口端口。

---

## 下一讲预告

[Lecture 26](lecture_26_test_cases.md) 将深入解析 57 个测试用例中的典型代表，包括 DDR 基础读写、
DMA 多种传输模式、4KB 边界穿越、DMA Abort、CPU 驱动的端到端推理等。
