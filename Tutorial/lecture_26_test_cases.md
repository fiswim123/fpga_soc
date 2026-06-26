# Lecture 26: 典型测试用例深度解析

## 课程目标

本讲深入解析 FPGA SoC 项目中 57 个测试用例的典型代表。学完本讲后，你将能够：

1. 理解每类测试用例的设计意图与覆盖目标
2. 掌握 DMA 传输的各种边界条件测试方法
3. 理解 CPU 驱动的端到端推理测试流程
4. 学会分析覆盖率补充测试的设计思路
5. 能够独立设计新的测试用例

---

## 1. 测试用例全景图

```
  测试编号    分类            测试内容                    状态
  ─────────────────────────────────────────────────────────
  Test  1     DDR         基本读写 + FSM 覆盖             活跃
  Test  2     NPU         NPU RAM 读写                    活跃
  Test  3     DMA         DDR→NPU, burst=255              活跃
  Test  3b    DMA         DDR→NPU, burst=4                活跃
  Test  3c    DMA         DDR→NPU, burst=1                活跃
  Test  4     DMA         反向搬运 NPU→DDR                活跃
  Test  5     DMA         双描述符搬运                    活跃
  Test  6     NPU         Conv1 + MaxPool                 活跃
  Test  7     NPU         FC + 预测结果                   活跃
  Test  8     NPU         CSR 寄存器读写                  活跃
  Test 10     DMA         全 0 / 全 1 边界数据            活跃
  Test 11     DDR         越界访问                        活跃
  Test 14     DMA         4KB 边界穿越                    活跃
  Test 18     DMA         4KB 边界穿越 (验证版)           活跃
  Test 25     DMA         Abort 中止                      活跃
  Test 27     DMA         写后读回验证                    活跃
  Test 28     系统        CPU 驱动端到端推理               活跃
  Test 36     DMA         Streamer 全 burst 覆盖          活跃
  Test 47     覆盖率      NPU CSR backpressure            补充
  Test 49     覆盖率      AXI 握手条件覆盖                补充
  Test 50     覆盖率      综合覆盖率提升                  补充
  Test 51     覆盖率      DDR 反压 via FSM force          补充
  Test 52     覆盖率      DMA abort + AXI pending         补充
  Test 53     覆盖率      NPU 处理中复位                  补充
  Test 57     覆盖率      NPU FC 饱和值                   补充
  ─────────────────────────────────────────────────────────
```

---

### 设计视角：为什么这样设计？

测试用例的设计不是随意罗列，而是有明确的工程目标和优先级策略。本节分析 50+ 测试用例背后的设计动机。

**核心问题：为什么需要 50+ 个测试用例？**

```
  测试数量的驱动因素:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  因素 1: 代码覆盖率要求 >= 95%                           │
  │  ├── 每个 if/else 分支至少执行一次                       │
  │  ├── 每个条件组合 (a && b) 的 TT/TF/FT/FF               │
  │  ├── 每个 FSM 状态和转换路径                             │
  │  └── 正常测试 ~20 个能覆盖 ~85%, 剩下 10% 需定向补充     │
  │                                                         │
  │  因素 2: 多模块交互的组合爆炸                             │
  │  ├── DMA: 8 种 burst × 3 种方向 × 4 种边界 = 96 场景    │
  │  ├── NPU: Conv × MaxPool × FC × ReLU 的排列组合         │
  │  └── 系统: CPU × Crossbar × DMA × NPU 全链路            │
  │                                                         │
  │  因素 3: 边界条件和异常路径                               │
  │  ├── 4KB 边界穿越 (AXI 协议约束)                        │
  │  ├── DMA Abort 中止 (异常处理路径)                       │
  │  ├── 越界地址访问 (保护机制验证)                         │
  │  └── 反压场景 (backpressure, 正常流程难以触发)           │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**测试排序的设计考量：**

为什么先测 DDR 基础读写，最后测 CPU 端到端？这不是随意安排：

```
  排序原则               原因                        示例
  ────────────────────────────────────────────────────────────────
  1. 基础模块在前         基础不通则上层无意义          Test 1: DDR R/W
  2. 单模块功能其次       隔离问题, 快速定位            Test 2: NPU RAM
  3. 多模块集成再次       验证模块间交互                Test 3-5: DMA
  4. 异常路径补充         覆盖错误处理                  Test 25: Abort
  5. 覆盖率补充最后       针对未覆盖的条件分支          Test 47-57
  6. 端到端放最最后       复位 CPU, 污染其他测试状态    Test 28: CPU+E2E
  ────────────────────────────────────────────────────────────────

  失败快速反馈 (Fail-Fast) 策略:
  Test 1 (DDR) 失败 → 后续所有 DMA 测试必然失败 → 立即停止, 节省仿真时间
```

**为什么 Test 28 必须放在最后？**

```
  Test 28 的特殊性:
  ┌─────────────────────────────────────────────────────────┐
  │ 1. 释放 CPU 复位 → CPU 开始自主执行 ROM 指令            │
  │ 2. CPU 执行过程中会修改 DMA/NPU 的 CSR 状态             │
  │ 3. 如果后续还有其他测试, 需要重新复位 CPU               │
  │ 4. 重新复位可能影响已完成测试的验证状态                  │
  │                                                         │
  │ 解决方案: 将 Test 28 放在所有其他测试之后               │
  │ 这样即使 CPU 状态被污染, 也不影响任何测试结果            │
  └─────────────────────────────────────────────────────────┘
```

---

### 设计视角：如何从零开始设计？

设计一个 FPGA SoC 的测试计划需要系统化的方法。以下是五步设计流程。

**步骤 1：识别测试目标（需求分解）**

```
  输入: 设计规格书 + 覆盖率要求
  输出: 测试目标清单

  分解方法:
  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  Level 1: 按模块分解                                    │
  │  ├── DDR 控制器 → 需要测试: 读写、越界、FSM、反压       │
  │  ├── DMA 控制器 → 需要测试: 各种 burst、方向、边界       │
  │  ├── NPU 加速器 → 需要测试: Conv、FC、CSR、复位         │
  │  └── AXI Crossbar → 需要测试: 仲裁、反压、并发          │
  │                                                         │
  │  Level 2: 按场景分解                                    │
  │  ├── 正常路径 → 基本功能测试                            │
  │  ├── 边界条件 → 4KB 边界、最大 burst、单字节            │
  │  ├── 异常路径 → Abort、越界、错误响应                   │
  │  └── 覆盖率缺口 → 反压、特定条件组合                    │
  │                                                         │
  │  Level 3: 按优先级排序                                  │
  │  P0 (必须): 基本功能, 不通过则无法使用                   │
  │  P1 (重要): 边界条件, 影响可靠性                        │
  │  P2 (补充): 覆盖率提升, 影响验证完整性                   │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**步骤 2：设计测试用例模板**

```
  每个测试用例应包含:

  task test_xxx();
    $display("\n[TB] === Test N: 描述 ===");

    // Step 1: 环境准备 (清空存储器、复位状态)
    for(int i=0; i<SIZE; i++) `MEM[i] = 0;
    repeat(10) @(posedge clk);

    // Step 2: 配置 (设置 DMA/NPU 参数)
    dma_force_csr(src, dst, nbytes, burst);
    repeat(3) @(posedge clk);

    // Step 3: 触发 (启动操作)
    force reg_go = 1'b1;
    @(posedge clk); release reg_go;

    // Step 4: 等待 (带超时保护)
    wait_dma(TIMEOUT, _dma_ok);
    dma_release_csr();
    repeat(5) @(posedge clk);

    // Step 5: 校验 (检查结果)
    mismatch = 0;
    for(int i=0; i<SIZE; i++)
      if(`MEM[i] !== expected[i]) mismatch = 1;
    check("Test N: 描述", !dma_error && dma_done && !mismatch);
  endtask

  模板确保每个测试结构一致, 易于维护和调试
```

**步骤 3：实现功能覆盖矩阵**

```
  功能覆盖矩阵 (Feature Coverage Matrix):

  ┌─────────────┬──────────┬──────────┬──────────┬──────────┐
  │ 功能特性      │ 正常路径  │ 边界条件  │ 异常路径  │ 覆盖率    │
  ├─────────────┼──────────┼──────────┼──────────┼──────────┤
  │ DDR 读写      │ Test 1   │ Test 11  │ Test 51  │ Test 49  │
  │ DMA burst=255 │ Test 3   │ Test 14  │ Test 25  │ Test 36  │
  │ DMA burst=1   │ Test 3c  │ Test 18  │ Test 52  │ Test 50  │
  │ DMA 反向      │ Test 4   │ ---      │ ---      │ ---      │
  │ DMA 双描述符  │ Test 5   │ ---      │ ---      │ ---      │
  │ NPU Conv      │ Test 6   │ ---      │ Test 53  │ Test 47  │
  │ NPU FC        │ Test 7   │ Test 57  │ Test 53  │ ---      │
  │ NPU CSR       │ Test 8   │ ---      │ ---      │ Test 47  │
  │ CPU 端到端    │ Test 28  │ ---      │ ---      │ ---      │
  └─────────────┴──────────┴──────────┴──────────┴──────────┘

  矩阵帮助识别覆盖盲区: 如果某个功能特性的某列为空, 说明缺少该类测试
```

**步骤 4：逐步构建并验证**

```
  增量式构建策略:

  Round 1: 基础功能 (Test 1-8)
  ├── 运行仿真 → 确认基本流程通畅
  ├── 收集覆盖率 → 基线 ~85%
  └── 识别未覆盖项

  Round 2: 边界条件 (Test 10-27)
  ├── 针对 Round 1 的未覆盖项设计补充测试
  ├── 运行仿真 → 覆盖率提升到 ~91%
  └── 识别剩余缺口

  Round 3: 覆盖率补充 (Test 36-57)
  ├── 分析条件覆盖率报告, 识别未覆盖的条件组合
  ├── 用 force 制造特定场景
  ├── 运行仿真 → 覆盖率提升到 ~96%
  └── 阈值检查: PASS (>= 95%)

  每轮迭代都运行完整的回归测试, 确保新测试不破坏已有测试
```

**步骤 5：建立回归测试流程**

```
  回归测试自动化:

  #!/bin/bash
  # run_regression.sh
  cd sim/

  # 编译 (带覆盖率)
  vlog -cover bcestf ../src/**/*.sv ../tb/soc_tb.sv

  # 仿真 (带覆盖率收集)
  vsim -c -coverage -do cov_soc_tb.tcl

  # 检查阈值
  vsim -c -viewcov cov_soc_tb.ucdb -do check_coverage_threshold.tcl

  # 判断结果
  if grep -q "RESULT: PASS" threshold_report.txt; then
    echo "REGRESSION PASS"
  else
    echo "REGRESSION FAIL"
    exit 1
  fi

  回归测试应在每次 RTL 修改后运行, 确保不引入新问题
```

---

### 设计视角：架构模式与原则

测试用例设计中存在多种可复用的模式和原则。掌握这些可以高效地设计新测试。

**模式 1：自底向上验证模式（Bottom-Up Verification）**

```
  核心思想: 从最底层模块开始验证, 逐层向上集成

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  Layer 4: 系统测试                                      │
  │  ┌─────────────────────────────────────────────┐        │
  │  │ Test 28: CPU → Crossbar → DMA → NPU         │        │
  │  │ 前提: 所有下层模块已验证通过                   │        │
  │  └─────────────────────────────────────────────┘        │
  │           ▲ 前提                                        │
  │  Layer 3: 集成测试                                      │
  │  ┌─────────────────────────────────────────────┐        │
  │  │ Test 3-5: DMA + DDR + NPU RAM               │        │
  │  │ Test 6-7: NPU Conv + FC                     │        │
  │  │ 前提: 各模块单元测试已通过                     │        │
  │  └─────────────────────────────────────────────┘        │
  │           ▲ 前提                                        │
  │  Layer 2: 模块功能测试                                  │
  │  ┌─────────────────────────────────────────────┐        │
  │  │ Test 3: DMA burst 传输                       │        │
  │  │ Test 8: NPU CSR 读写                         │        │
  │  │ 前提: 基础存储器访问正常                       │        │
  │  └─────────────────────────────────────────────┘        │
  │           ▲ 前提                                        │
  │  Layer 1: 基础单元测试                                  │
  │  ┌─────────────────────────────────────────────┐        │
  │  │ Test 1: DDR 基本读写                         │        │
  │  │ Test 2: NPU RAM 读写                         │        │
  │  └─────────────────────────────────────────────┘        │
  │                                                         │
  │  原则: 每层只在下层验证通过后才开始测试                   │
  │  好处: 失败时快速定位问题层级                             │
  └─────────────────────────────────────────────────────────┘
```

**模式 2：覆盖率驱动测试模式（Coverage-Driven Testing）**

```
  核心思想: 以覆盖率指标为导向, 迭代补充测试

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  ┌──────────┐     ┌──────────┐     ┌──────────┐        │
  │  │ 编写测试  │────►│ 运行仿真  │────►│ 收集覆盖率│        │
  │  └──────────┘     └──────────┘     └─────┬────┘        │
  │       ▲                                   │             │
  │       │                                   ▼             │
  │       │           ┌──────────┐     ┌──────────┐        │
  │       └───────────│ 设计补充  │◄────│ 分析报告  │        │
  │                   │ 测试      │     │ (未覆盖项)│        │
  │                   └──────────┘     └──────────┘        │
  │                                                         │
  │  迭代终止条件: 覆盖率 >= 95% 或所有可覆盖项已覆盖        │
  │                                                         │
  │  本项目的迭代历程:                                       │
  │  Round 1: 功能测试 (Test 1-22)     → 85%               │
  │  Round 2: 边界测试 (Test 23-34)    → 91%               │
  │  Round 3: 补充测试 (Test 35-46)    → 93%               │
  │  Round 4: 覆盖率定向 (Test 47-57)  → 96%               │
  └─────────────────────────────────────────────────────────┘
```

**模式 3：定向测试模式（Directed Testing）**

```
  核心思想: 针对特定的条件分支, 精确构造测试场景

  适用场景:
  · 正常流程无法覆盖的条件组合
  · 需要特定时序关系的场景
  · 异常路径和错误处理

  ┌─────────────────────────────────────────────────────────┐
  │              定向测试设计流程                              │
  │                                                         │
  │  Step 1: 分析覆盖率报告, 识别未覆盖的条件分支            │
  │  例: DDR 控制器中 (ar_req && aw_req) = 1 未覆盖          │
  │                                                         │
  │  Step 2: 分析为什么正常流程无法触发                       │
  │  例: DMA 读写请求通常不会同时到达 DDR                    │
  │                                                         │
  │  Step 3: 设计 force 方案制造目标场景                     │
  │  例: 同时启动两个 DMA 传输, 让读写请求并发               │
  │                                                         │
  │  Step 4: 编写测试并验证                                  │
  │  force u_soc.u_ddr.st = ST_WRESP;                       │
  │  repeat(5) @(posedge clk);                              │
  │  release u_soc.u_ddr.st;                                │
  │                                                         │
  │  Step 5: 确认覆盖率提升                                  │
  └─────────────────────────────────────────────────────────┘

  本项目中的定向测试:
  · Test 47: NPU CSR 反压 (写后延迟读, 覆盖流水线反压路径)
  · Test 49: AXI 握手条件覆盖 (并发读写, 制造仲裁场景)
  · Test 51: DDR 反压 (force FSM 状态, 覆盖 ready=0 路径)
  · Test 53: NPU 复位覆盖 (在不同 FSM 阶段施加复位)
```

---

## 2. Test 1: DDR 基本读写 + FSM 覆盖

### 2.1 测试目标

验证 DDR 控制器的基本读写功能，同时通过大量连续访问覆盖 FSM 的所有状态转换。

### 2.2 代码解析

```systemverilog
// 文件: tb/soc_tb.sv, 第 143-164 行
task test_ddr();
  logic[31:0] rdata;
  bit ok;
  $display("\n[TB] === Test 1: DDR R/W + FSM ===");
  repeat(20) @(posedge clk); ok=1;

  // 阶段1: 散点读写 (覆盖基本路径)
  ddr_write32(DDR_BASE+0, 32'hA5A5_5A5A);
  ddr_write32(DDR_BASE+4, 32'hFFFF_0000);
  ddr_write32(DDR_BASE+8, 32'h1234_5678);
  ddr_write32(DDR_BASE+32'h3FFF0, 32'hCAFE_BABE);  // DDR 末尾附近
  ddr_read32(DDR_BASE+0, rdata);  if(rdata!==32'hA5A5_5A5A) ok=0;
  ddr_read32(DDR_BASE+4, rdata);  if(rdata!==32'hFFFF_0000) ok=0;
  ddr_read32(DDR_BASE+8, rdata);  if(rdata!==32'h1234_5678) ok=0;
  ddr_read32(DDR_BASE+32'h3FFF0, rdata); if(rdata!==32'hCAFE_BABE) ok=0;

  // 阶段2: 密集连续读写 (覆盖 FSM 所有状态)
  for(int i=0;i<256;i++) ddr_write32(DDR_BASE+i*4, 32'h1000_0000+i);
  for(int i=0;i<256;i++) begin
    ddr_read32(DDR_BASE+i*4, rdata);
    if(rdata!==(32'h1000_0000+i)) ok=0;
  end
  check("DDR R/W + FSM", ok);
endtask
```

### 2.3 DDR FSM 状态图

```
              rst
               |
               v
  +--------> ST_IDLE <--------+
  |            |               |
  |     aw_req |         bvalid|
  |     & !ar  |         & bresp
  |            v               |
  |      ST_WDATA --------> ST_WRESP
  |            |
  |     ar_req |
  |     & !aw  |
  |            v
  +-------- ST_RDATA
```

256 次连续写入确保 FSM 在 `ST_IDLE -> ST_WDATA -> ST_WRESP -> ST_IDLE` 循环多次，
256 次连续读出确保 `ST_IDLE -> ST_RDATA -> ST_IDLE` 循环多次。

---

## 3. Test 3: DMA 基本传输（多种 burst 长度）

### 3.1 测试目标

验证 DMA 在不同 burst 长度下的传输正确性，覆盖 DMA streamer 的多种工作模式。

### 3.2 Test 3: burst=255（最大突发）

```systemverilog
// 文件: tb/soc_tb.sv, 第 186-206 行
task test_dma_burst();
  bit mismatch;
  $display("\n[TB] === Test 3: DMA DDR->NPU (burst=255) ===");

  // 1. 预加载 DDR: 4096 字节, 内容 = 地址低 8 位
  for(int i=0;i<4096;i++) `DDR_MEM[i] = i[7:0];

  // 2. 清空 NPU RAM
  for(int i=0;i<4096;i++) `NPU_MEM[i] = 8'h00;
  repeat(10) @(posedge clk);

  // 3. 配置 DMA: src=DDR, dst=NPU, 4096B, burst=255
  dma_force_csr(DDR_BASE, NPU_LMEM_BASE, 32'd4096, 8'd255);
  repeat(3) @(posedge clk);

  // 4. 触发 DMA
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go = 1'b1;
  @(posedge clk);
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_go;

  // 5. 等待完成 (最长 2ms)
  wait_dma(2_000_000, _dma_ok);
  dma_release_csr();
  repeat(5) @(posedge clk);

  // 6. 校验: NPU RAM 应与 DDR 内容一致
  mismatch = 0;
  for(int i=0;i<4096;i++) if(`NPU_MEM[i] !== i[7:0]) mismatch = 1;
  check("DMA burst=255", !dma_error && dma_done && !mismatch);
endtask
```

### 3.3 三种 burst 长度对比

```
  测试      burst    字节数    每次传输拍数    DMA 循环次数
  ──────────────────────────────────────────────────────
  Test 3     255      4096      256 拍          16 次
  Test 3b      4       256        5 拍          52 次
  Test 3c      1        16        2 拍           8 次
  ──────────────────────────────────────────────────────
```

**burst 长度的含义**：`max_burst = N` 表示每次 AXI 突发最多传 `N+1` 拍。DMA streamer
会根据剩余字节数和 4KB 边界限制动态调整实际 burst 长度。

---

## 4. Test 4: DMA 反向搬运

### 4.1 测试目标

验证 DMA 从 NPU RAM 搬运到 DDR 的反向路径，覆盖 DMA 读端（NPU 侧）和写端（DDR 侧）的
完整协议路径。

```systemverilog
// 文件: tb/soc_tb.sv, 第 249-267 行
task test_dma_reverse();
  bit mismatch;
  $display("\n[TB] === Test 4: DMA NPU_RAM->DDR ===");

  // 源: NPU RAM, 目标: DDR
  for(int i=0;i<256;i++) `NPU_MEM[i] = 8'hA0+i[7:0];
  for(int i=0;i<256;i++) `DDR_MEM['h3000+i] = 8'h00;
  repeat(10) @(posedge clk);

  // 注意: src 和 dst 参数交换
  dma_force_csr(NPU_LMEM_BASE, DDR_BASE+32'h3000, 32'd256, 8'd16);
  // ... 触发 + 等待 + 校验 ...
  check("DMA reverse", !dma_error && dma_done && !mismatch);
endtask
```

**关键区别**：`dma_force_csr` 的第一个参数是源地址，第二个是目标地址。反向搬运时
交换这两个参数即可，DMA 硬件会自动处理读/写方向。

---

## 5. Test 5: DMA 双描述符

### 5.1 测试目标

验证 DMA 的多描述符功能——两次独立的搬运操作，使用不同的源/目标地址。

```
  描述符 0: DDR[0x4000] ──> NPU_RAM[0x000]  (128B)
  描述符 1: DDR[0x4100] ──> NPU_RAM[0x800]  (128B)

  DDR 存储器布局:
  0x4000: [10 11 12 ... 8F]  (描述符 0 源数据)
  0x4100: [80 81 82 ... FF]  (描述符 1 源数据)

  NPU RAM 布局 (搬运后):
  0x000: [10 11 12 ... 8F]  (描述符 0 结果)
  0x800: [80 81 82 ... FF]  (描述符 1 结果)
```

```systemverilog
// 文件: tb/soc_tb.sv, 第 272-304 行
task test_dma_two_desc();
  // 描述符 0
  dma_force_csr(DDR_BASE+32'h4000, NPU_LMEM_BASE, 32'd128, 8'd16);
  // ... 触发 + 等待 ...
  dma_release_csr();
  repeat(5) @(posedge clk);

  // 描述符 1 (注意不同的地址)
  dma_force_csr(DDR_BASE+32'h4100, NPU_LMEM_BASE+32'h800, 32'd128, 8'd16);
  // ... 触发 + 等待 ...
  dma_release_csr();

  // 校验两段
  mismatch = 0;
  for(int i=0;i<128;i++) if(`NPU_MEM[i] !== 8'(8'h10+i[7:0])) mismatch = 1;
  for(int i=0;i<128;i++) if(`NPU_MEM['h800+i] !== 8'(8'h80+i[7:0])) mismatch = 1;
  check("DMA two desc", !dma_error && dma_done && !mismatch);
endtask
```

**两次搬运之间必须 `dma_release_csr()` + `repeat(5) @(posedge clk)`**，确保前一次
DMA 的内部状态完全清零后再配置下一次。

---

## 6. Test 14/18: 4KB 边界穿越

### 6.1 为什么 4KB 边界很重要？

AXI4 协议规定：一次突发事务不能跨越 4KB 地址边界。这是因为从设备可能按 4KB 页映射，
跨页传输会导致地址回绕。

```
  4KB 边界示意图:
  地址空间:
  0x4000_0000 ───────────────────── 0x4000_0FFF (第 0 页, 4KB)
  0x4000_1000 ───────────────────── 0x4000_1FFF (第 1 页, 4KB)
  ...
  0x4000_3000 ───────────────────── 0x4000_3FFF (第 3 页, 4KB)
  0x4000_4000 ───────────────────── 0x4000_4FFF (第 4 页, 4KB)

  DMA streamer 必须在 4KB 边界处拆分突发:
  起始: 0x4000_3FE0, 长度: 256B
  第 1 段: 0x3FE0 -> 0x3FFF (32B, 到 4KB 边界)
  第 2 段: 0x4000 -> 0x40DF (224B, 跨页后新突发)
```

### 6.2 Test 18: 4KB 边界穿越验证

```systemverilog
// 文件: tb/soc_tb.sv, 第 620-635 行
task test_dma_4kb_boundary();
  bit mismatch;
  $display("\n[TB] === Test 18: DMA 4KB boundary crossing ===");

  // 从 0x3FE0 开始搬 256B, 跨越 0x4000 边界
  for(int i=0;i<256;i++) `DDR_MEM['h3FE0+i] = 8'hC0+i[7:0];
  for(int i=0;i<256;i++) `NPU_MEM[i] = 8'h00;
  repeat(10) @(posedge clk);

  dma_force_csr(DDR_BASE+32'h3FE0, NPU_LMEM_BASE, 32'd256, 8'd255);
  // ... 触发 + 等待 ...

  mismatch = 0;
  for(int i=0;i<256;i++) if(`NPU_MEM[i] !== 8'(8'hC0+i[7:0])) mismatch = 1;
  check("DMA 4KB boundary", !dma_error && dma_done && !mismatch);
endtask
```

**DMA streamer 内部的 4KB 拆分逻辑**（`dma_streamer.sv`）：

```
  burst_r4KB = 4096 - (addr & 12'hFFF);  // 到下一个 4KB 边界的字节数
  actual_burst = min(max_burst, burst_r4KB, remaining_bytes);
```

---

## 7. Test 25/52: DMA Abort

### 7.1 Test 25: 基本 Abort

```systemverilog
// 文件: tb/soc_tb.sv, 第 740-765 行
task test_dma_abort();
  $display("\n[TB] === Test 25: DMA abort ===");

  // 配置大传输 (4096B)
  for(int i=0;i<4096;i++) `DDR_MEM['hC000+i] = i[7:0];
  dma_force_csr(DDR_BASE+32'hC000, NPU_LMEM_BASE, 32'd4096, 8'd255);
  repeat(3) @(posedge clk);
  force reg_go = 1'b1;
  @(posedge clk); release reg_go;

  // 等 50 个周期后发送 abort
  repeat(50) @(posedge clk);
  $display("[TB]   Forcing abort...");
  force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort = 1'b1;
  repeat(5) @(posedge clk);
  release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_abort;

  // 等待 DMA 响应
  fork
    begin wait(dma_done || dma_error); end
    begin #2ms; end
  join_any disable fork;

  check("DMA abort", 1'b1);  // 只要不挂死就算通过
endtask
```

**Abort 测试的验证标准**：不检查数据正确性（因为传输被中止），只检查 DMA 是否能正常
响应 abort 信号并回到 IDLE 状态。

### 7.2 Test 52: Abort + AXI Pending

Test 52 在 Test 25 基础上增加了更极端的场景：

```
  场景 1: DMA 写通道被 DDR 反压 (wready=0), 然后 abort
  场景 2: DMA 读通道被 DDR 反压 (rready=0), 然后 abort
  场景 3: DMA FIFO 满 (full_o=1), 然后 abort
```

```systemverilog
// 文件: tb/soc_tb.sv, 第 2194-2266 行
task test_dma_abort_pending();
  // 场景 1: 写通道反压 + abort
  dma_force_csr(DDR_BASE+32'hF000, NPU_LMEM_BASE, 32'd256, 8'd16);
  // ... 触发 ...
  repeat(3) @(posedge clk);
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;  // DDR 进入写响应状态
  repeat(3) @(posedge clk);
  force reg_abort = 1'b1;                          // 此时 DMA 有 pending 写请求
  repeat(5) @(posedge clk);
  release u_soc.u_ddr.st;
  release reg_abort;
  // ... 等待 ...
endtask
```

---

## 8. Test 28: CPU 驱动的端到端推理

### 8.1 测试目标

这是整个测试套件中最复杂的测试，模拟真实使用场景：CPU 从 ROM 取指执行，通过 CSR 总线
配置 DMA，DMA 搬运图像到 NPU，CPU 触发 NPU 推理，最终读取预测结果。

### 8.2 完整流程图

```
  TB                    CPU                DMA              NPU
   |                     |                  |                |
   | 1. 预加载 DDR 图像  |                  |                |
   |---------------------|                  |                |
   |                     |                  |                |
   | 2. 释放复位         |                  |                |
   |----rst=0----------->|                  |                |
   |                     |                  |                |
   |                     | 3. 取指执行 ROM  |                |
   |                     |   (CSR 写 DMA)   |                |
   |                     |----------------->|                |
   |                     |                  |                |
   |                     | 4. 写 DMA GO     |                |
   |                     |----------------->|                |
   |                     |                  | 5. 搬运图像    |
   |                     |                  |-------------->|
   |                     |                  |                |
   |                     | 6. DMA done IRQ  |                |
   |                     |<-----------------|                |
   |                     |                  |                |
   |                     | 7. 写 NPU CTRL   |                |
   |                     |---------------------------------->|
   |                     |                  |                |
   |                     |                  |    8. 推理     |
   |                     |                  |                |
   | 9. 轮询 pred_valid  |                  |                |
   |<--------------------------------------------pred_valid-|
   |                     |                  |                |
   | 10. 读取预测结果    |                  |                |
   |---------------------|                  |                |
```

### 8.3 代码解析

```systemverilog
// 文件: tb/soc_tb.sv, 第 811-900 行
task test_cpu_dma_npu();
  $display("\n[TB] === Test 28: CPU-driven DMA + NPU Inference ===");

  // 步骤 1: 预加载 DDR (与 test_npu_conv1 相同)
  fd = $fopen("../src/npu/image_data.dat", "r");
  // ... 读取 1024 个像素, 写入 DDR ...

  // 步骤 2: 释放 CPU 复位 (CPU 从 ROM 地址 0 开始取指)
  rst = 1'b1;
  repeat(20) @(posedge clk);
  rst = 1'b0;
  $display("[TB]   CPU released from reset, executing ROM...");

  // 步骤 3: 等待 NPU pred_valid (CPU 完成全链路)
  timeout = 0;
  ok = 0;
  while (timeout < 80_000_000) begin    // 最长 400ms (80M 个 5ns 周期)
    @(posedge clk);
    timeout++;
    if (u_soc.u_npu.pred_valid) begin
      ok = 1;
      break;
    end
  end

  // 步骤 4: 读取预测结果
  class_id = u_soc.u_npu.pred_class_id;
  logit    = u_soc.u_npu.pred_logit;
  $display("[TB]   pred_class_id = %0d", class_id);
  $display("[TB]   pred_logit    = %0d", $signed(logit));

  // 步骤 5: 校验 DMA 搬运正确性
  for (int i = 0; i < 64; i++) begin
    if (`NPU_MEM[i] !== `DDR_MEM[i]) begin
      ok = 0; break;
    end
  end

  check("CPU DMA+NPU", ok);
endtask
```

**关键区别**：这个测试 **不使用 force**，CPU 完全自主执行 ROM 中的程序。
这与 Test 6/7（通过 force 直接触发 NPU）形成对比，覆盖了 CPU -> Crossbar ->
DMA/NPU 的完整数据通路。

---

## 9. Test 36: DMA Streamer 全 Burst 覆盖

### 9.1 测试目标

通过遍历所有 2 的幂次 burst 长度（0, 1, 3, 7, 15, 31, 63, 127, 255），覆盖 DMA streamer
中所有与 burst 长度相关的条件分支。

```
  burst    实际拍数    字节数    覆盖的 streamer 条件
  ──────────────────────────────────────────────────
    0         1          4       min_burst 路径
    1         2          8       小 burst 路径
    3         4         16       中小 burst 路径
    7         8         32       中 burst 路径
   15        16         64       中大 burst 路径
   31        32        128       大 burst 路径
   63        64        256       更大 burst 路径
  127       128        512       接近最大 burst 路径
  255       256       1024       最大 burst 路径
  ──────────────────────────────────────────────────
```

### 9.2 额外覆盖: FIXED 模式和 Abort

```systemverilog
// 文件: tb/soc_tb.sv, 第 1180-1193 行
// DMA_MODE_FIXED: rd_mode=FIXED
force u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0] = 1'b1;
dma_force_csr(DDR_BASE, NPU_LMEM_BASE, 32'd16, 8'd3);
// ... 触发 + 等待 ...
release u_soc.u_dma.u_dma_axi_wrapper.u_dma_csr.reg_rd_mode[0];
```

FIXED 模式下，DMA 每拍都访问同一个地址（不递增），用于访问 FIFO 类外设。

---

## 10. Test 47/49/50: 覆盖率补充测试

### 10.1 设计思路

这些测试在功能测试完成后添加，目的是提升条件覆盖率（condition coverage）。它们通过
`force` 制造正常流程中难以出现的场景。

### 10.2 Test 47: NPU CSR Backpressure

```systemverilog
// 文件: tb/soc_tb.sv, 第 1458-1485 行
task test_npu_csr_backpressure();
  // 写后延迟 5 个周期再读, 覆盖 CSR 内部流水线反压路径
  force u_soc.u_npu.u_conv.u_csr.csr_wr_en = 1'b1;
  force u_soc.u_npu.u_conv.u_csr.csr_addr = 8'h00;
  force u_soc.u_npu.u_conv.u_csr.csr_wdata = 32'h01;
  @(posedge clk);
  release u_soc.u_npu.u_conv.u_csr.csr_wr_en;
  // ...
  repeat(5) @(posedge clk);   // 5 周期间隔 = 反压

  force u_soc.u_npu.u_conv.u_csr.csr_rd_en = 1'b1;
  force u_soc.u_npu.u_conv.u_csr.csr_addr = 8'h04;
  @(posedge clk);
  release u_soc.u_npu.u_conv.u_csr.csr_rd_en;
  // ...
endtask
```

### 10.3 Test 49: AXI Handshake Condition Coverage

```systemverilog
// 文件: tb/soc_tb.sv, 第 1528-1590 行
task test_axi_handshake_coverage();
  // 场景 1: 并发读写 (ar_req && aw_req)
  // 同时启动两个 DMA, 制造 DDR 同时收到读写请求的场景

  // 场景 2: DDR arready=0 (读地址反压)
  force u_soc.u_ddr.s_arready = 1'b0;
  // ... DMA 操作 ...
  release u_soc.u_ddr.s_arready;

  // 场景 3: DDR awready=0 (写地址反压)
  force u_soc.u_ddr.s_awready = 1'b0;
  // ...
  release u_soc.u_ddr.s_awready;

  // 场景 4: DDR wready=0 (写数据反压)
  force u_soc.u_ddr.s_wready = 1'b0;
  // ...
  release u_soc.u_ddr.s_wready;
endtask
```

### 10.4 Test 50: Comprehensive Coverage Boost

Test 50 将多种小场景合并到一个测试中，减少仿真时间：

```
  Test 50 子场景:
  1. 多种小 DMA 传输 (burst=0,1,2,3)
  2. DDR 边界访问
  3. NPU CSR 寄存器读写
  4. NPU FC debug 接口
  5. DMA AXI-Lite BFM 读写
  6. STATUS/CONTROL 寄存器读取
```

---

## 11. Test 51: DDR 反压 via FSM Force

### 11.1 设计思路

通过 force DDR 控制器的 FSM 状态，制造正常流程中难以触发的反压场景。

```systemverilog
// 文件: tb/soc_tb.sv, 第 2027-2187 行
task test_ddr_backpressure();
  // 场景 1: DDR 在 WRESP 状态, s_awready=0, s_wready=0
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;
  repeat(5) @(posedge clk);
  release u_soc.u_ddr.st;

  // 场景 2: DDR 在 RDATA 状态, s_arready=0
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_RDATA;
  repeat(5) @(posedge clk);
  release u_soc.u_ddr.st;

  // 场景 3: WRESP + bready=0 (写响应反压)
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;
  force u_soc.u_ddr.s_bready = 1'b0;
  repeat(3) @(posedge clk);
  release u_soc.u_ddr.s_bready;
  release u_soc.u_ddr.st;

  // 场景 4: RDATA + rready=0 (读数据反压)
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_RDATA;
  force u_soc.u_ddr.s_rready = 1'b0;
  repeat(3) @(posedge clk);
  release u_soc.u_ddr.s_rready;
  release u_soc.u_ddr.st;

  // 场景 5: 并发读写 (ar_req && aw_req)
  // 同时启动两个 DMA 传输

  // 场景 6: 写错误 (wr_err_q=1)
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;
  force u_soc.u_ddr.wr_err_q = 1'b1;
  repeat(3) @(posedge clk);
  release u_soc.u_ddr.wr_err_q;
  release u_soc.u_ddr.st;

  // 场景 7: 读错误 (rd_err_q=1)
  force u_soc.u_ddr.st = u_soc.u_ddr.ST_RDATA;
  force u_soc.u_ddr.rd_err_q = 1'b1;
  repeat(3) @(posedge clk);
  release u_soc.u_ddr.rd_err_q;
  release u_soc.u_ddr.st;

  // 场景 8/9: 越界地址 (awaddr_q/araddr_q = 0)
  force u_soc.u_ddr.awaddr_q = 32'h0000_0000;
  repeat(2) @(posedge clk);
  release u_soc.u_ddr.awaddr_q;
endtask
```

---

## 12. Test 53: NPU 处理中复位

### 12.1 测试目标

在 NPU 推理的不同阶段施加复位，覆盖所有 FSM 状态到 IDLE 的复位转换路径。

```
  NPU Top FSM:
  T_IDLE -> T_LOAD_IMG -> T_WAIT_CONV -> T_WAIT_FC -> T_DONE

  施加复位的时机:
  时机 1: T_LOAD_IMG 阶段
  时机 2: T_WAIT_CONV 阶段
  时机 3: FC S_PREP_FC 阶段
  时机 4: FC S_MUL 阶段
  时机 5: FC S_ADD32..S_ADD1 阶段
  时机 6: FC S_WRITE/S_DONE 阶段
```

```systemverilog
// 文件: tb/soc_tb.sv, 第 2273-2367 行
task test_npu_reset_coverage();
  // 时机 1: T_LOAD_IMG 阶段复位
  force csr_wdata = 32'h01;  // 触发 img_load
  @(posedge clk); release csr_wdata;
  repeat(2) @(posedge clk);
  rst = 1'b1; repeat(5) @(posedge clk); rst = 1'b0;
  repeat(20) @(posedge clk);

  // 时机 2: T_WAIT_CONV 阶段复位
  force csr_wdata = 32'h01;
  @(posedge clk); release csr_wdata;
  repeat(10) @(posedge clk);  // 等 conv 开始
  rst = 1'b1; repeat(5) @(posedge clk); rst = 1'b0;
  // ... 后续 4 个时机 ...
endtask
```

---

## 13. 测试执行顺序

```systemverilog
// 文件: tb/soc_tb.sv, 第 2582-2645 行 (initial 块)
initial begin
  // 阶段 1: 基础功能测试
  test_ddr();              // DDR 基本读写
  test_ddr_oob();          // DDR 越界
  test_ddr_strb();         // DDR 字节选通
  test_npu_ram();          // NPU RAM 读写

  // 阶段 2: DMA 功能测试 (按复杂度递增)
  test_dma_burst();        // burst=255
  test_dma_small_burst();  // burst=4
  test_dma_min_burst();    // burst=1
  test_dma_max_burst();    // 最大 burst
  test_dma_unaligned();    // 非对齐
  test_dma_1byte();        // 单字节
  test_dma_reverse();      // 反向
  test_dma_two_desc();     // 双描述符
  test_dma_boundary();     // 边界数据
  test_dma_4kb_boundary(); // 4KB 边界
  test_dma_sequential();   // 连续多次
  // ...

  // 阶段 3: NPU 功能测试
  test_npu_csr();          // CSR 读写
  test_npu_conv1();        // Conv1 + MaxPool
  test_npu_fc();           // FC + 预测
  test_npu_conv2();        // Conv1 + Conv2 完整流程

  // 阶段 4: 覆盖率补充测试
  test_npu_csr_backpressure();
  test_dma_csr_backpressure();
  test_axi_handshake_coverage();
  test_comprehensive_coverage();
  test_ddr_backpressure();
  test_dma_abort_pending();
  test_npu_reset_coverage();
  // ...

  // 阶段 5: 端到端测试 (放最后避免污染其他测试)
  test_cpu_dma_npu();
end
```

**执行顺序的设计原则**：
1. 基础测试在前，确保 DUT 基本功能正常
2. 功能测试按模块分组，按复杂度递增
3. 覆盖率补充测试在功能测试之后
4. 端到端测试放在最后（它会复位 CPU，可能影响后续测试的状态）

---

## 14. 知识要点总结

| 编号 | 知识点 | 核心概念 |
|------|--------|---------|
| K1 | 测试金字塔 | 单元 > 集成 > 系统，数量递减 |
| K2 | DMA burst | max_burst=N 表示最多 N+1 拍 |
| K3 | 4KB 边界 | AXI 协议限制，DMA streamer 自动拆分 |
| K4 | Abort | 中止进行中的传输，验证 FSM 回归能力 |
| K5 | Backpressure | force ready=0 制造反压场景 |
| K6 | FSM Force | force FSM 状态到特定值，覆盖难以到达的路径 |
| K7 | Reset Coverage | 在不同 FSM 阶段施加复位 |
| K8 | 端到端测试 | CPU 自主执行，不使用 force |

---

## 15. 动手练习

### 练习 1: 分析 Test 3 的校验逻辑

在 `test_dma_burst()` 中，校验使用 `if(`NPU_MEM[i] !== i[7:0])`。解释为什么用 `!==`
而不是 `!=`，以及 `i[7:0]` 的含义。

### 练习 2: 设计 DMA 2KB 边界测试

参考 Test 18（4KB 边界），设计一个测试用例，验证 DMA 在 2KB 边界处的行为。需要考虑：
- 起始地址应设为多少？
- 传输长度应设为多少？
- 预期 DMA streamer 如何处理？

### 练习 3: 分析 Test 28 的超时设置

Test 28 的超时设为 `80_000_000` 个时钟周期（400ms）。分析：
1. 为什么比其他测试的 `2_000_000`（2ms）长 200 倍？
2. 如果 CPU ROM 程序有 bug 导致死循环，测试会怎样？
3. 如何修改测试使其在 CPU 死循环时能输出更多调试信息？

### 练习 4: 设计 NPU 错误注入测试

参考 Test 30（DMA error path），设计一个测试用例，在 NPU 卷积计算过程中 force
`u_conv.u_mac.a_col_valid = 0`，验证 NPU 是否能正确处理数据无效的情况。

---

## 下一讲预告

[Lecture 27](lecture_27_coverage.md) 将讲解覆盖率驱动验证方法学，包括覆盖率类型、收集配置、
排除规则、分析改进流程。
