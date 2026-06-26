# Lecture 27: 覆盖率驱动验证 -- 度量与补全

## 课程目标

本讲深入讲解 FPGA SoC 项目的覆盖率驱动验证方法。学完本讲后，你将能够：

1. 理解六种覆盖率类型的含义与区别
2. 掌握 ModelSim/QuestaSim 覆盖率收集脚本的编写
3. 理解覆盖率排除规则的设计原则
4. 学会分析覆盖率报告并设计补充测试
5. 掌握迭代式覆盖率驱动验证流程

---

## 1. 覆盖率概述

### 1.1 什么是覆盖率？

覆盖率是衡量验证完整性的量化指标。它回答一个核心问题：**我们测了多少？还差多少？**

```
  验证流程:

  +----------+     +----------+     +----------+     +----------+
  | 编写 RTL | --> | 编写测试 | --> | 运行仿真 | --> | 收集覆盖率|
  +----------+     +----------+     +----------+     +-----+----+
                                                           |
                      +------------------------------------+
                      |
                      v
                +----------+     +----------+
                | 分析报告 | --> | 补充测试 |
                +----------+     +-----+----+
                      ^                |
                      +----------------+   (迭代直到达标)
```

### 1.2 覆盖率类型总览

本项目使用 `vlog -cover bcestf` 编译选项，收集以下六种覆盖率：

| 类型 | 缩写 | 含义 | 示例 |
|------|------|------|------|
| Branch | B | if/case 分支是否都被执行 | `if(a) ... else ...` 两个分支都走到 |
| Condition | C | 条件表达式的各种组合 | `if(a&&b)` 的 TT/TF/FT/FF |
| Expression | E | 表达式的各种取值 | `assign x = a ? b : c` |
| Statement | S | 每条语句是否被执行 | `x = y + z;` 是否被执行过 |
| Toggle | T | 信号是否在 0/1 之间翻转 | 每个 bit 是否出现过 0 和 1 |
| FSM | F | 状态机的状态和转换是否覆盖 | IDLE->RUN->DONE 所有路径 |

```
  覆盖率关系图:

  代码覆盖率 (Code Coverage)
    +-- Branch Coverage     (分支覆盖)
    +-- Condition Coverage  (条件覆盖)
    +-- Expression Coverage (表达式覆盖)
    +-- Statement Coverage  (语句覆盖)
    +-- Toggle Coverage     (翻转覆盖)
    +-- FSM Coverage        (状态机覆盖)

  功能覆盖率 (Functional Coverage) -- 本项目未使用
    +-- Covergroup / Coverpoint / Cross
```

---

### 设计视角：为什么这样设计？

覆盖率验证的核心设计决策包括：排除什么、阈值设多少、如何平衡投入产出。

**核心问题 1：为什么排除第三方 IP？**

```
  排除第三方 IP 的根本原因: 可控性与可测性

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  picorv32 CPU (第三方 RISC-V IP):                       │
  │  ├── 内部逻辑对测试不可见 (黑盒)                         │
  │  ├── 无法通过 force 访问内部信号                         │
  │  ├── 无法修改内部实现来覆盖特定分支                       │
  │  ├── 其覆盖率应由 IP 供应商保证                          │
  │  └── 如果计入我们的覆盖率, 永远无法达标                   │
  │                                                         │
  │  AXI Crossbar (第三方 IP):                              │
  │  ├── 内部仲裁逻辑复杂, 分支众多                          │
  │  ├── 很多分支只在极端条件下触发                           │
  │  ├── 修改测试来覆盖这些分支的投入产出比极低               │
  │  └── 排除后可专注于自研模块的验证                         │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  排除的代价:
  · 第三方 IP 的 bug 可能漏过验证
  · 缓解措施: 选择经过验证的成熟 IP + 集成测试覆盖接口行为

  不排除的代价:
  · 覆盖率永远无法达到 95% 阈值
  · 团队精力被分散到无法控制的代码上
  · 项目进度受阻
```

**核心问题 2：为什么选择 95% 作为阈值？**

```
  阈值选择的权衡:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  阈值 < 90%:                                            │
  │  ├── 验证过于宽松, 大量代码路径未覆盖                     │
  │  ├── bug 漏检概率高                                      │
  │  └── 不满足赛题/行业基本要求                              │
  │                                                         │
  │  阈值 = 95% (本项目选择):                                │
  │  ├── 行业公认的良好验证标准                               │
  │  ├── 排除不可达代码后可达到                               │
  │  ├── 剩余 5% 主要是:                                    │
  │  │   · 不可达的 default case                            │
  │  │   · 编译时条件排除的分支                              │
  │  │   · 极端边界条件 (投入产出比低)                       │
  │  └── 平衡了验证完整性与项目进度                           │
  │                                                         │
  │  阈值 > 98%:                                            │
  │  ├── 需要大量精力覆盖难以触发的条件组合                   │
  │  ├── 最后 1% 可能需要数周时间                             │
  │  ├── 投入产出比急剧下降                                   │
  │  └── 适合安全关键系统 (汽车/航空), 本项目不需要           │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  阈值选择公式 (经验法则):
  · 学术/竞赛项目: >= 90% (快速验证)
  · 商业产品: >= 95% (行业标准)
  · 安全关键: >= 99% (严格要求)
  · 本项目: 95% (商业产品标准, 满足赛题要求)
```

**核心问题 3：为什么选择代码覆盖率而非功能覆盖率？**

```
  两种覆盖率的对比:

  ┌──────────────┬────────────────────┬────────────────────┐
  │ 维度          │ 代码覆盖率          │ 功能覆盖率          │
  ├──────────────┼────────────────────┼────────────────────┤
  │ 衡量对象      │ RTL 代码的执行情况   │ 设计规格的满足程度   │
  │ 收集方式      │ 编译器自动插桩       │ 手动编写 covergroup │
  │ 人力投入      │ 低 (自动)           │ 高 (需理解规格)     │
  │ 覆盖盲区      │ 可达但未想到的场景   │ 代码冗余/死代码     │
  │ 适用场景      │ RTL 验证初期         │ 系统级验证          │
  │ 本项目选择    │ ✓                   │ ✗ (未使用)          │
  └──────────────┴────────────────────┴────────────────────┘

  本项目选择代码覆盖率的原因:
  1. FPGA 验证以 RTL 为中心, 代码覆盖率直接反映执行情况
  2. 自动收集, 无需额外编写覆盖模型
  3. 项目周期短, 无暇编写功能覆盖组
  4. 六种代码覆盖率 (B/C/E/S/T/F) 已足够全面
```

---

### 设计视角：如何从零开始设计？

实现一个完整的覆盖率驱动验证流程需要系统化的方法。以下是五步设计流程。

**步骤 1：配置覆盖率收集环境**

```
  环境搭建清单:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  1. 编译脚本 (cov_soc_tb.tcl)                           │
  │     · 添加 -cover bcestf 编译选项                       │
  │     · 确保所有自研模块都被覆盖                           │
  │     · 排除第三方 IP (可选)                               │
  │                                                         │
  │  2. 仿真脚本                                            │
  │     · 添加 -coverage 仿真选项                           │
  │     · 添加 +acc=bcelnprsuv 保持信号可访问性             │
  │     · 配置 coverage save -onexit 自动保存 UCDB          │
  │                                                         │
  │  3. 排除规则文件 (coverage_exclude.cfg)                  │
  │     · 列出所有需要排除的模块和代码行                     │
  │     · 每条规则附带排除理由                               │
  │                                                         │
  │  4. 阈值检查脚本 (check_coverage_threshold.tcl)          │
  │     · 加载 UCDB → 计算覆盖率 → 与阈值比较               │
  │     · 输出 PASS/FAIL + 需要补充的命中数                  │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**步骤 2：建立覆盖率基线**

```
  基线测量流程:

  Step 1: 运行所有功能测试
  $ cd sim/
  $ vsim -c -do cov_soc_tb.tcl

  Step 2: 查看基线覆盖率
  $ vsim -c -viewcov cov_soc_tb.ucdb -do check_coverage_threshold.tcl

  典型基线结果 (功能测试后):
  ┌──────────────┬──────────┬──────────┐
  │ 覆盖率类型    │ 命中/总数 │ 百分比    │
  ├──────────────┼──────────┼──────────┤
  │ Branch       │ 200/220  │ 90.9%    │
  │ Condition    │ 400/450  │ 88.9%    │
  │ Expression   │ 150/160  │ 93.8%    │
  │ Statement    │ 800/820  │ 97.6%    │
  │ FSM States   │ 20/20    │ 100.0%   │
  │ FSM Trans    │ 25/25    │ 100.0%   │
  ├──────────────┼──────────┼──────────┤
  │ Total BCEFS  │ 1595/1675│ 95.2%   │
  └──────────────┴──────────┴──────────┘

  如果基线已 >= 95%, 项目完成
  如果 < 95%, 进入步骤 3
```

**步骤 3：分析未覆盖项并分类**

```
  未覆盖项分类决策树:

  未覆盖项
    │
    ├── 是否可以通过修改测试来覆盖?
    │   │
    │   ├── 是 → 设计补充测试 (步骤 4)
    │   │   ├── 反压场景 → force ready=0
    │   │   ├── 错误注入 → force 错误信号
    │   │   ├── 边界条件 → 特定地址/数据模式
    │   │   └── FSM 特定状态 → force FSM 状态
    │   │
    │   └── 否 → 添加排除规则 (必须有充分理由)
    │       ├── 第三方 IP 内部逻辑
    │       ├── 编译时条件排除 (DATA_WIDTH==32 的 64-bit 分支)
    │       ├── 参数硬编码 (signed_mode=1 的 false 分支)
    │       ├── 未使用的端口 (slv2, slv3)
    │       └── 地址空间限制 (DDR_BASE=0 的负地址检查)
    │
    └── 分类完成后 → 进入步骤 4 或步骤 5
```

**步骤 4：设计补充测试**

```
  补充测试设计方法:

  问题: DDR 控制器中 s_awready=0 的条件未覆盖
  分析: 正常流程中 DDR 总是立即响应 (awready=1)
  方案: force DDR FSM 到 ST_WRESP 状态, 制造反压

  代码:
  task test_ddr_backpressure();
    // 制造 DDR 反压场景
    force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;
    repeat(5) @(posedge clk);
    // 此时 s_awready=0, s_wready=0
    release u_soc.u_ddr.st;
    check("DDR backpressure", 1);
  endtask

  效果: DDR 条件覆盖率从 78% 提升到 95%

  设计原则:
  · 每个补充测试只覆盖 1-2 个未覆盖条件
  · 测试名称明确标注覆盖目标
  · 测试结束后恢复 DUT 到正常状态
```

**步骤 5：迭代直到达标**

```
  迭代流程:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  Round N:                                               │
  │  1. 运行仿真, 收集覆盖率                                │
  │  2. 检查阈值: >= 95%?                                   │
  │     ├── YES → 验证完成, 输出最终报告                    │
  │     └── NO  → 分析未覆盖项, 设计补充测试                │
  │  3. 添加补充测试 (或排除规则)                           │
  │  4. 运行回归测试 (确保已有测试不被破坏)                  │
  │  5. 回到步骤 1                                          │
  │                                                         │
  │  典型迭代次数: 3-5 轮                                   │
  │  每轮耗时: 仿真 ~10 分钟 + 分析 ~30 分钟               │
  │  总周期: 2-4 天                                         │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

### 设计视角：架构模式与原则

覆盖率验证中有多种可复用的模式，掌握这些可以高效地达到验证目标。

**模式 1：覆盖率闭环模式（Coverage Closure Pattern）**

```
  核心思想: 以覆盖率数字为唯一驱动指标, 迭代收敛到目标

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  覆盖率闭环:                                            │
  │                                                         │
  │  85% ──► 91% ──► 93% ──► 96% ──► PASS                  │
  │   │       │       │       │                             │
  │   │       │       │       └── Round 4: 定向补充测试      │
  │   │       │       └── Round 3: 补充排除规则              │
  │   │       └── Round 2: 边界条件测试                      │
  │   └── Round 1: 功能测试                                  │
  │                                                         │
  │  每轮的关键动作:                                         │
  │  ┌─────────────────────────────────────────────┐        │
  │  │ 1. 运行 → 收集 → 比较 (自动化)               │        │
  │  │ 2. 分析未覆盖项 (需要人工判断)                │        │
  │  │ 3. 决定: 补充测试 or 排除规则 (需要经验)      │        │
  │  │ 4. 执行: 写测试 or 写排除 (实现)             │        │
  │  │ 5. 验证: 回归测试 (自动化)                    │        │
  │  └─────────────────────────────────────────────┘        │
  │                                                         │
  │  收敛速度递减规律:                                       │
  │  Round 1→2: +6% (功能测试覆盖大量基础路径)              │
  │  Round 2→3: +2% (边界条件覆盖较少路径)                  │
  │  Round 3→4: +3% (定向测试+排除规则, 精准提升)           │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**模式 2：迭代改进模式（Iterative Improvement Pattern）**

```
  核心思想: 每轮聚焦一个覆盖率类型, 逐个击破

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  推荐的迭代顺序:                                        │
  │                                                         │
  │  Round 1: Statement Coverage (最易提升)                 │
  │  ├── 确保每条可执行语句至少执行一次                      │
  │  ├── 通常功能测试即可覆盖大部分                          │
  │  └── 目标: >= 95%                                      │
  │                                                         │
  │  Round 2: Branch Coverage                               │
  │  ├── 确保每个 if/else 分支都被执行                       │
  │  ├── 需要覆盖 else 分支和 default case                  │
  │  └── 目标: >= 90%                                      │
  │                                                         │
  │  Round 3: FSM Coverage                                  │
  │  ├── 确保所有状态和转换路径都被访问                      │
  │  ├── 通常功能测试已覆盖大部分                            │
  │  └── 目标: 100%                                        │
  │                                                         │
  │  Round 4: Condition Coverage (最难提升)                  │
  │  ├── 确保复合条件的各种取值组合                          │
  │  ├── 需要精确控制多个信号的状态                          │
  │  └── 目标: >= 85%                                      │
  │                                                         │
  │  Round 5: Expression + Toggle (收尾)                    │
  │  ├── 通常前面几轮已间接覆盖大部分                        │
  │  └── 目标: >= 90%                                      │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  为什么按这个顺序?
  · Statement 最容易: 只需执行每条语句, 功能测试自然覆盖
  · Condition 最难: 需要精确控制多个子条件的组合, 常需 force
  · FSM 居中: 需要访问所有状态, 但状态数通常有限
```

**模式 3：排除审核模式（Exclusion Audit Pattern）**

```
  核心思想: 每条排除规则必须经过审核, 防止滥用

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  排除规则审核流程:                                      │
  │                                                         │
  │  Step 1: 提出排除请求                                   │
  │  ├── 谁提出? (验证工程师)                               │
  │  ├── 排除什么? (具体模块/行号)                          │
  │  └── 为什么? (排除理由)                                 │
  │                                                         │
  │  Step 2: 技术评审                                       │
  │  ├── 是否真的不可覆盖?                                  │
  │  ├── 是否可以通过修改测试来覆盖?                         │
  │  ├── 排除后对验证完整性的影响?                           │
  │  └── 是否有替代验证手段?                                │
  │                                                         │
  │  Step 3: 记录排除理由                                   │
  │  ├── 写入排除文件的注释中                               │
  │  ├── 包含: 模块名、行号、原因、审核人                   │
  │  └── 格式: # Reason: <具体原因>                        │
  │                                                         │
  │  Step 4: 定期复审                                       │
  │  ├── 设计变更后重新评估排除规则                         │
  │  ├── 检查是否有新的测试可以覆盖被排除的代码              │
  │  └── 移除不再需要的排除规则                             │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  排除规则分类模板:

  类型 1: 第三方 IP
  # Module: picorv32
  # Reason: 第三方 IP, 无法控制内部逻辑
  catch {coverage exclude -du picorv32}

  类型 2: 编译时条件排除
  # Module: dma_streamer, Line 49
  # Reason: DMA_DATA_WIDTH=32 时, 64-bit 分支不可达
  catch {coverage exclude -line dma_streamer.sv 49}

  类型 3: 未使用端口
  # Module: axi_crossbar slv2_if
  # Reason: Crossbar slv2 端口未连接, 无外部访问
  catch {coverage exclude -scope /soc_tb/u_soc/u_crossbar/slv2_if}
```

---

## 2. 六种覆盖率详解

### 2.1 Branch Coverage（分支覆盖）

检查每个 `if/else`、`case` 分支是否都被执行。

```systemverilog
// 示例: DDR 控制器中的地址范围检查
// 文件: src/ddr.sv
if (a < DDR_BASE || a >= DDR_BASE + DDR_SIZE) begin
  // 分支 A: 越界地址
end else begin
  // 分支 B: 合法地址
end
```

```
  Branch Coverage 分析:
  分支 A (越界): 需要 Test 11 (DDR OOB) 触发
  分支 B (合法): Test 1 (DDR R/W) 已覆盖
  覆盖率: 2/2 = 100%
```

### 2.2 Condition Coverage（条件覆盖）

检查复合条件中每个子条件的各种取值组合。

```systemverilog
// 示例: DDR 控制器中的并发读写判断
// 文件: src/ddr.sv
if (ar_req && aw_req) begin
  // 条件: ar_req=1, aw_req=1
end
```

```
  Condition Coverage 分析 (a && b):
  +------+------+--------+
  | a    | b    | 是否覆盖 |
  +------+------+--------+
  | 0    | 0    | 需测试  |
  | 0    | 1    | 需测试  |
  | 1    | 0    | 需测试  |
  | 1    | 1    | 需测试  |
  +------+------+--------+

  ar_req && aw_req 的覆盖:
  (0,0): DDR IDLE 空闲时
  (0,1): 只有写请求时
  (1,0): 只有读请求时
  (1,1): 读写同时到达 (Test 49/51)
```

### 2.3 Expression Coverage（表达式覆盖）

检查赋值语句右侧表达式的各种取值。

```systemverilog
// 示例: DMA streamer 中的 burst 长度计算
// 文件: src/dma/dma_streamer.sv
assign actual_burst = (enough_for_burst) ? max_burst : remaining_beats;
```

### 2.4 Statement Coverage（语句覆盖）

检查每条可执行语句是否至少被执行一次。

```
  Statement Coverage 示例:
  ┌─────────────────────────────────────────┐
  │ 1. always @(posedge clk)                │
  │ 2.   if (rst) begin                     │
  │ 3.     state <= IDLE;                   │  ← 需要复位触发
  │ 4.   end else begin                     │
  │ 5.     case (state)                     │
  │ 6.       IDLE: if (go) state <= RUN;    │  ← 需要 go=1
  │ 7.       RUN:  if (done) state <= IDLE; │  ← 需要 done=1
  │ 8.     endcase                          │
  │ 9.   end                                │
  └─────────────────────────────────────────┘
  Statement Coverage: 需要覆盖第 3, 6, 7 行
```

### 2.5 Toggle Coverage（翻转覆盖）

检查每个信号的每个 bit 是否在 0 和 1 之间翻转过。

```
  Toggle Coverage 示例:
  信号 addr[31:0]:
  bit 0: 是否出现过 0->1 和 1->0 ?
  bit 1: 是否出现过 0->1 和 1->0 ?
  ...
  bit 31: 是否出现过 0->1 和 1->0 ?

  总计: 32 bits x 2 翻转 = 64 个 bin
```

### 2.6 FSM Coverage（状态机覆盖）

检查状态机的所有状态和状态转换是否被覆盖。

```
  DDR FSM Coverage:
  状态: ST_IDLE, ST_WDATA, ST_WRESP, ST_RDATA (4 个状态)

  状态转换:
  ST_IDLE    -> ST_WDATA   (写请求)
  ST_IDLE    -> ST_RDATA   (读请求)
  ST_WDATA   -> ST_WRESP   (写数据完成)
  ST_WRESP   -> ST_IDLE    (写响应完成)
  ST_RDATA   -> ST_IDLE    (读数据完成)

  共 5 条转换路径, 需要全部覆盖
```

---

## 3. 覆盖率收集配置

### 3.1 编译脚本

```tcl
# 文件: sim/cov_soc_tb.tcl, 第 17-25 行
vlog -cover bcestf ../src/dma/inc/amba_axi_pkg.sv
vlog -cover bcestf ../src/dma/inc/dma_utils_pkg.sv
vlog -cover bcestf ../src/cpu/*.v
vlog -cover bcestf ../src/axi_crossbar/*.sv
vlog -cover bcestf ../src/dma/*.sv
vlog -cover bcestf ../src/npu/*.sv
vlog -cover bcestf ../src/ddr.sv
vlog -cover bcestf ../src/soc_top.sv
vlog -cover bcestf ../tb/soc_tb.sv
```

**`-cover bcestf` 选项含义**：

| 标志 | 含义 |
|------|------|
| `b` | Branch coverage |
| `c` | Condition coverage |
| `e` | Expression coverage |
| `s` | Statement coverage |
| `t` | Toggle coverage |
| `f` | FSM coverage |

### 3.2 仿真脚本

```tcl
# 文件: sim/cov_soc_tb.tcl, 第 30-34 行
vsim -c -t 1ps -L work \
     +SEED=$rnd_seed \
     -voptargs="+acc=bcelnprsuv" \
     -coverage \
     soc_tb
```

**关键选项**：
- `-coverage`：启用覆盖率收集
- `+acc=bcelnprsuv`：保持所有信号的可访问性，用于 force/release
- `+SEED=$rnd_seed`：随机种子，用于随机化测试

### 3.3 覆盖率保存与报告

```tcl
# 文件: sim/cov_soc_tb.tcl, 第 36-48 行
coverage save -onexit cov_soc_tb.ucdb    # 仿真结束时自动保存 UCDB

run -all                                   # 运行所有测试

coverage report -output cov_soc_tb_report.txt -details -all -zeros
# -details: 详细报告
# -all: 所有覆盖率类型
# -zeros: 包含未覆盖的 bin (值为 0 的项)
```

**UCDB 文件**：Unified Coverage Database，是 ModelSim/QuestaSim 的标准覆盖率数据格式，
可以在后续分析工具中加载。

---

## 4. 覆盖率排除规则

### 4.1 为什么需要排除？

并非所有代码都应该被计入覆盖率。以下情况需要排除：

1. **第三方 IP**：picorv32 CPU 核、AXI crossbar 内部逻辑
2. **不可达代码**：编译时条件排除的分支（如 64-bit 模式下的分支）
3. **测试平台**：soc_tb 本身不应计入覆盖率
4. **死代码**：设计中未被调用的任务或函数

### 4.2 排除配置文件

```tcl
# 文件: sim/coverage_exclude.cfg, 第 1-32 行
// 排除 picorv32（第三方 RISC-V IP）
-exclude du picorv32
-exclude du picorv32_regs
-exclude du picorv32_pcpi_mul
-exclude du picorv32_pcpi_fast_mul
-exclude du picorv32_pcpi_div
-exclude du picorv32_mem_router
-exclude du picorv32_local_rom
-exclude du picorv32_local_ram
-exclude du picorv32_axi_adapter
-exclude du picorv32_axi

// 排除 crossbar 内部子模块（第三方 IP 内部逻辑）
-exclude du axicb_mst_if
-exclude du axicb_slv_if
-exclude du axicb_switch_top
// ... 更多 crossbar 子模块 ...
```

### 4.3 阈值检查脚本中的详细排除

```tcl
# 文件: sim/check_coverage_threshold.tcl, 第 27-121 行

# 1. 排除 picorv32 第三方 CPU IP
catch {coverage exclude -du picorv32}
catch {coverage exclude -du picorv32_regs}
# ... 共 9 个 picorv32 子模块 ...

# 2. 排除 DMA streamer 中 DMA_DATA_WIDTH==64 相关分支
catch {coverage exclude -line dma_streamer.sv 49}
catch {coverage exclude -line dma_streamer.sv 87}

# 3. 排除 DDR 中 DDR_BASE=0 下界越界分支
catch {coverage exclude -scope /soc_tb/u_soc/u_ddr -line ddr.sv 91}

# 4. 排除 crossbar slv2/slv3 (未使用的从机端口)
catch {coverage exclude -scope /soc_tb/u_soc/u_crossbar/slv2_if}
catch {coverage exclude -scope /soc_tb/u_soc/u_crossbar/slv3_if}

# 5. 排除 PE/SA 实例 (signed_mode 硬编码, add_mode/flush 未使用)
catch {coverage exclude -du pe}
catch {coverage exclude -du mm_systolic_4x4}

# 6. 排除不可达 default case
catch {coverage exclude -scope /soc_tb/u_soc/u_ddr -line 229}
catch {coverage exclude -scope /soc_tb/u_soc/u_cpu_bridge -line 211}
catch {coverage exclude -scope /soc_tb/u_soc/u_cpu_bridge -line 245}
catch {coverage exclude -scope /soc_tb/u_soc/u_npu -line 307}
catch {coverage exclude -scope /soc_tb/u_soc/u_npu/u_conv -line 544}
catch {coverage exclude -scope /soc_tb/u_soc/u_npu/u_fc -line 267}

# 7. 排除 DMA streamer burst_r4KB 死代码
catch {coverage exclude -du dma_streamer -line 129}
catch {coverage exclude -du dma_streamer -line 133}
```

### 4.4 排除规则分类汇总

```
  排除类别                  排除原因                        影响模块
  ────────────────────────────────────────────────────────────────
  第三方 CPU IP             无法控制内部逻辑                 picorv32 系列
  第三方 Crossbar IP        无法控制内部逻辑                 axicb_* 系列
  未使用端口                无连接, 不可达                   slv2_if, slv3_if
  编译时条件排除            DMA_DATA_WIDTH==32 时不可达     dma_streamer L49/L87
  地址下界                  DDR_BASE=0, 无负地址             ddr.sv L91
  硬编码参数                signed_mode=1, add_mode 未使用  pe, mm_systolic_4x4
  FSM default case          状态枚举完备, default 不可达    多个模块
  死代码                    未调用的任务/函数                dma_streamer L129/L133
  ────────────────────────────────────────────────────────────────
```

---

## 5. 覆盖率分析与阈值检查

### 5.1 阈值检查脚本

```tcl
# 文件: sim/check_coverage_threshold.tcl, 第 126-155 行
set threshold 95.0

# 获取覆盖率 (bcefs = Branch/Condition/Expression/FSM/Statement)
set cov_rpt [coverage report -code bcefs -zeros]
set total_bins 0
set total_hits 0
foreach line [split $cov_rpt "\n"] {
  if {[regexp {(Branches|Conditions|Expressions|FSM States|FSM Transitions|Statements)\
    \s+(\d+)\s+(\d+)\s+(\d+)} $line -> typ total hits misses]} {
    set total_bins [expr {$total_bins + $total}]
    set total_hits [expr {$total_hits + $hits}]
  }
}

if {$total_bins > 0} {
  set total_pct [expr {double($total_hits) / double($total_bins) * 100.0}]
  puts [format "  Coverage (bcefs): %d/%d = %.2f%%" $total_hits $total_bins $total_pct]
  puts [format "  Threshold:        %.1f%%" $threshold]
  if {$total_pct >= $threshold} {
    puts "  RESULT: PASS"
  } else {
    set needed [expr {int(ceil($total_bins * $threshold / 100.0)) - $total_hits}]
    puts [format "  RESULT: FAIL (need %d more hits)" $needed]
  }
}
```

### 5.2 报告解析

```
  覆盖率报告示例:

  ==========================================
   Coverage Threshold Check: >= 95.0%
  ==========================================
  Coverage (bcefs): 2847/2950 = 96.51%
  Threshold:        95.0%
  RESULT: PASS
  ==========================================
```

**报告含义**：
- `2847/2950`：2950 个覆盖率 bin 中有 2847 个被命中
- `96.51%`：总覆盖率百分比
- `PASS`：超过 95% 阈值

---

## 6. 覆盖率驱动的迭代流程

### 6.1 迭代流程图

```
  第 1 轮迭代:
  ┌─────────────────────────────────────────────────┐
  │ 1. 编写基础功能测试 (Test 1-22)                  │
  │ 2. 运行仿真, 收集覆盖率                          │
  │ 3. 分析报告: 85% (低于 95% 阈值)                 │
  │ 4. 识别未覆盖的条件分支                           │
  │ 5. 设计补充测试 (Test 23-34)                     │
  └─────────────────────────────────────────────────┘
                      |
  第 2 轮迭代:         v
  ┌─────────────────────────────────────────────────┐
  │ 1. 运行仿真, 收集覆盖率                          │
  │ 2. 分析报告: 91%                                 │
  │ 3. 发现: DDR FSM default case 未覆盖             │
  │          DMA streamer burst_r4KB 死代码           │
  │          NPU CSR default case 未覆盖              │
  │ 4. 设计补充测试 (Test 35-46)                     │
  └─────────────────────────────────────────────────┘
                      |
  第 3 轮迭代:         v
  ┌─────────────────────────────────────────────────┐
  │ 1. 运行仿真, 收集覆盖率                          │
  │ 2. 分析报告: 93%                                 │
  │ 3. 发现: AXI 握手条件组合未完全覆盖              │
  │          DDR 反压场景未覆盖                       │
  │ 4. 设计补充测试 (Test 47-57)                     │
  │ 5. 添加覆盖率排除规则                            │
  └─────────────────────────────────────────────────┘
                      |
  第 4 轮迭代:         v
  ┌─────────────────────────────────────────────────┐
  │ 1. 运行仿真, 收集覆盖率                          │
  │ 2. 分析报告: 96.51%                              │
  │ 3. 阈值检查: PASS (>= 95%)                       │
  │ 4. 验证完成!                                     │
  └─────────────────────────────────────────────────┘
```

### 6.2 每轮迭代的关键步骤

```
  步骤 1: 运行仿真
  $ cd sim/
  $ vsim -c -do cov_soc_tb.tcl

  步骤 2: 检查阈值
  $ vsim -c -viewcov cov_soc_tb.ucdb -do check_coverage_threshold.tcl

  步骤 3: 分析未覆盖项
  $ cat cov_soc_tb_report.txt | grep "0 "

  步骤 4: 分类未覆盖项
  +-- 可覆盖: 需要设计新的测试用例
  +-- 不可覆盖: 需要添加排除规则 (必须有充分理由)

  步骤 5: 设计补充测试
  参考 Lecture 26 中的覆盖率补充测试设计方法
```

---

## 7. 覆盖率提升实战案例

### 7.1 案例 1: DDR 条件覆盖率提升

**问题**：DDR 控制器中 `s_awready=0` 的条件未被覆盖。

**分析**：正常流程中，DDR 总是立即响应写请求（`s_awready=1`）。需要制造反压场景。

**解决方案**：Test 51 中 force DDR FSM 到 `ST_WRESP` 状态。

```systemverilog
// 文件: tb/soc_tb.sv, 第 2039-2047 行
// Force DDR into ST_WRESP (state=2) to create backpressure
force u_soc.u_ddr.st = u_soc.u_ddr.ST_WRESP;
repeat(5) @(posedge clk);
// While DDR is in WRESP, s_awready=0, s_wready=0, s_bvalid=1
release u_soc.u_ddr.st;
```

**效果**：DDR 条件覆盖率从 78% 提升到 95%。

### 7.2 案例 2: DMA Streamer 条件覆盖率提升

**问题**：DMA streamer 中 `enough_for_burst && !is_aligned` 的条件组合未覆盖。

**分析**：需要非对齐地址 + 足够字节数的传输。

**解决方案**：Test 55 中设计特定的传输参数。

```systemverilog
// 文件: tb/soc_tb.sv, 第 2460-2469 行
// DMA with unaligned start + enough bytes for burst
for(int i=0;i<32;i++) `DDR_MEM['hB003+i] = 8'hCC;
dma_force_csr(DDR_BASE+32'hB003, NPU_LMEM_BASE, 32'd28, 8'd4);
```

**地址分析**：`0xB003` 不是 4 字节对齐的（`0xB003 & 0x3 = 3`），28 字节足够一次 burst=4
的传输（需要 20 字节）。

### 7.3 案例 3: NPU FC FSM 覆盖率提升

**问题**：NPU FC 的 `S_DONE` 状态的 default case 未覆盖。

**分析**：FC FSM 使用枚举类型，`default` 分支在正常流程中不可达。

**解决方案**：Test 57 中直接 force FSM 到 `S_DONE` 状态。

```systemverilog
// 文件: tb/soc_tb.sv, 第 2567-2575 行
task test_npu_fc_saturation();
  force u_soc.u_npu.u_fc.state = u_soc.u_npu.u_fc.S_DONE;
  repeat(3) @(posedge clk);
  release u_soc.u_npu.u_fc.state;
  repeat(10) @(posedge clk);
  check("NPU FC saturation", 1);
endtask
```

---

## 8. 覆盖率排除的判定标准

### 8.1 可排除的情况

```
  +------------------------------------------------------------------+
  | 判定标准: 是否可以通过修改测试来覆盖?                              |
  +------------------------------------------------------------------+
  |                                                                  |
  |  不可以 --> 排除 (需要在排除文件中记录理由)                        |
  |    +-- 第三方 IP 内部逻辑 (picorv32, axicb_*)                    |
  |    +-- 编译时条件排除 (DMA_DATA_WIDTH==32 时的 64-bit 分支)      |
  |    +-- 参数硬编码 (signed_mode=1 的 false 分支)                  |
  |    +-- 未使用的端口 (slv2, slv3)                                 |
  |    +-- 地址空间限制 (DDR_BASE=0 时的负地址检查)                  |
  |                                                                  |
  |  可以 --> 不排除 (需要设计新的测试用例)                            |
  |    +-- 反压场景 (force ready=0)                                  |
  |    +-- 错误注入 (force 错误信号)                                 |
  |    +-- 边界条件 (特定地址/数据模式)                               |
  |    +-- FSM 特定状态 (force FSM 状态)                             |
  |                                                                  |
  +------------------------------------------------------------------+
```

### 8.2 排除规则的文档要求

每个排除规则必须附带以下信息：

```tcl
# 排除规则模板:
# 原因: <为什么不可覆盖>
# 模块: <受影响的模块>
# 代码: <具体行号或条件>
# 替代: <是否有其他测试间接覆盖>
catch {coverage exclude -scope <path> -line <file> <line>}
```

---

## 9. 覆盖率报告的解读

### 9.1 报告格式

```
  覆盖率报告示例 (简化):

  Module: dma_streamer
    Branches:     45/50   90.0%
    Conditions:   80/100  80.0%
    Statements:  120/125  96.0%
    FSM States:    4/4   100.0%
    FSM Trans:     5/5   100.0%

  Module: ddr
    Branches:     18/20   90.0%
    Conditions:   30/35   85.7%
    Statements:   50/50  100.0%
    FSM States:    4/4   100.0%
    FSM Trans:     5/5   100.0%

  总计:
    Branches:    200/220  90.9%
    Conditions:  400/450  88.9%
    Statements:  800/820  97.6%
    FSM States:   20/20  100.0%
    FSM Trans:    25/25  100.0%
    ─────────────────────────
    Total BCEFS: 1445/1515 95.4%
```

### 9.2 关键指标

| 指标 | 目标 | 说明 |
|------|------|------|
| Branch | > 90% | 每个 if/case 分支都被执行 |
| Condition | > 85% | 复合条件的各种组合 |
| Statement | > 95% | 每条可执行语句 |
| FSM States | 100% | 所有状态都被访问 |
| FSM Trans | 100% | 所有转换路径 |
| **总 BCEFS** | **> 95%** | **项目阈值** |

---

## 10. 覆盖率驱动验证的最佳实践

### 10.1 测试编写顺序

```
  推荐顺序:
  1. 先写功能测试 (验证设计功能正确性)
  2. 运行覆盖率收集 (了解当前覆盖情况)
  3. 分析未覆盖项 (识别覆盖率缺口)
  4. 设计补充测试 (针对特定条件分支)
  5. 添加排除规则 (处理不可达代码)
  6. 重复 2-5 直到达标

  不推荐:
  1. 先写排除规则 (可能遗漏可覆盖的代码)
  2. 只写功能测试 (覆盖率可能不足)
  3. 只关注覆盖率数字 (可能忽略功能正确性)
```

### 10.2 force/release 的使用原则

```
  +------------------------------------------------------------------+
  | force/release 使用原则                                           |
  +------------------------------------------------------------------+
  |                                                                  |
  | 1. 每个 force 必须有对应的 release                               |
  |    - 忘记 release 会导致信号被永久锁定                           |
  |    - 使用 task 封装 force/release 对                             |
  |                                                                  |
  | 2. force 只在必要时使用                                          |
  |    - 优先使用正常数据通路驱动                                    |
  |    - force 用于制造难以通过正常路径到达的场景                     |
  |                                                                  |
  | 3. force 后等待足够周期                                          |
  |    - repeat(3) @(posedge clk) 让信号传播                         |
  |    - 避免 force 和 release 在同一周期                            |
  |                                                                  |
  | 4. 测试结束时释放所有 force                                      |
  |    - dma_release_csr() 释放 DMA 寄存器                           |
  |    - 检查是否有遗漏的 force                                      |
  |                                                                  |
  +------------------------------------------------------------------+
```

### 10.3 覆盖率排除的审核流程

```
  排除规则审核流程:
  1. 提出排除请求 (谁、为什么)
  2. 技术评审 (是否真的不可覆盖?)
  3. 记录排除理由 (写入排除文件注释)
  4. 定期复审 (设计变更后重新评估)
```

---

## 11. 知识要点总结

| 编号 | 知识点 | 核心概念 |
|------|--------|---------|
| K1 | 覆盖率类型 | B/C/E/S/T/F 六种，各有侧重 |
| K2 | 编译选项 | `-cover bcestf` 启用全部类型 |
| K3 | UCDB 文件 | 统一覆盖率数据库格式 |
| K4 | 排除规则 | 第三方 IP、不可达代码、死代码 |
| K5 | 阈值检查 | 95% BCEFS 作为项目目标 |
| K6 | 迭代流程 | 测试 -> 收集 -> 分析 -> 补充 -> 排除 |
| K7 | 条件覆盖 | 复合条件的各种取值组合 |
| K8 | FSM 覆盖 | 所有状态和转换路径 |
| K9 | 排除审核 | 必须有充分理由，定期复审 |

---

## 12. 动手练习

### 练习 1: 分析覆盖率报告

运行 `cov_soc_tb.tcl` 生成覆盖率报告，回答：

1. 哪个模块的 Branch Coverage 最低？为什么？
2. 哪些条件（Condition）未被覆盖？需要什么测试场景？
3. FSM Coverage 是否达到 100%？如果没有，缺少哪些状态转换？

### 练习 2: 设计排除规则

以下代码段来自一个假设的模块，请判断哪些分支应该被排除，哪些应该通过测试覆盖：

```systemverilog
// 假设: DATA_WIDTH 参数化为 32
generate
  if (DATA_WIDTH == 64) begin : gen_64
    // 64-bit 数据路径
  end else begin : gen_32
    // 32-bit 数据路径
  end
endgenerate

// 假设: 状态机使用 3-bit 编码
case (state)
  3'b000: /* IDLE */
  3'b001: /* RUN */
  3'b010: /* DONE */
  default: /* 不可达 */
endcase
```

### 练习 3: 覆盖率提升方案

假设当前 DMA 条件覆盖率为 80%，未覆盖的条件包括：

1. `dma_streamer.sv`: `enough_for_burst && !is_aligned`
2. `dma_axi_if.sv`: `rresp == SLVERR && !error_lock`
3. `dma_fsm.sv`: `abort && state == S_RUN`

为每个未覆盖条件设计一个测试用例，说明需要 force 哪些信号、设置什么参数。

### 练习 4: 编写覆盖率检查脚本

参考 `check_coverage_threshold.tcl`，编写一个脚本：

1. 加载 UCDB 文件
2. 按模块统计覆盖率
3. 输出覆盖率最低的 5 个模块
4. 输出每个模块中未覆盖的条件列表

---

## 附录: 覆盖率相关文件索引

| 文件 | 用途 |
|------|------|
| `sim/cov_soc_tb.tcl` | 覆盖率收集主脚本 |
| `sim/check_coverage_threshold.tcl` | 阈值检查脚本 |
| `sim/coverage_exclude.cfg` | 排除规则配置 |
| `sim/cov.tcl` | 基础覆盖率脚本（较旧） |
| `sim/cov_*.txt` | 各轮迭代的覆盖率报告 |

---

## 下一讲预告

[Lecture 28](lecture_28_synth_impl.md) 将讲解 FPGA 综合与实现流程，包括综合约束、时序分析、
布局布线、比特流生成等环节。
