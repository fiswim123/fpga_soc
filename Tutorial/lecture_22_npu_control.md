# Lecture 22: NPU控制 -- CSR寄存器与状态机

## 课程目标

本讲深入分析NPU（神经处理单元）的软件控制接口和内部调度状态机。完成本讲后，你将能够：
- 理解NPU CSR寄存器映射及其位域定义
- 掌握npu_top四状态顶层状态机的工作流程
- 了解conv_top内部的多层级流水线控制
- 学会通过调试接口观察NPU内部状态

---

## 1. NPU控制架构总览

```
+----------------------------------------------------------+
|                     soc_top                              |
|                                                          |
|   CPU ──→ AXI Crossbar ──→ axi2csr ──→ npu_top          |
|              (mst3)        bridge     CSR简单接口         |
|                                    ┌──────────────┐      |
|                                    │ npu_csr_regs │      |
|                                    │   6个寄存器   │      |
|                                    └──────┬───────┘      |
|                                           │              |
|                                    ┌──────▼───────┐      |
|                                    │   conv_top   │      |
|                                    │  DMAC+MAC+PPU │      |
|                                    └──────┬───────┘      |
|                                           │              |
|                                    ┌──────▼───────┐      |
|                                    │gap_fc_logits │      |
|                                    │  GAP+FC分类   │      |
|                                    └──────────────┘      |
+----------------------------------------------------------+
```

**关键知识点：** CPU通过AXI总线写入CSR寄存器来控制NPU的启动和配置。axi2csr桥将AXI4事务转换为简单的寄存器读写信号。

---

## 设计视角：为什么这样设计？

### 动机分析

NPU 控制模块的核心问题是：**谁来协调多层卷积的执行顺序？** 有两种根本不同的方案：CPU 软件驱动或硬件自动序列器。

### 关键设计决策

```
  决策 1: 为什么用硬件序列器而非 CPU 驱动?

  ┌──────────────────┬─────────────────────────────────────┐
  │  方案 A: CPU 驱动 │  CPU 逐层配置并启动 NPU             │
  │                  │  每层完成后 CPU 中断, 配置下一层      │
  │                  │  优点: 灵活, 易修改                  │
  │                  │  缺点: 中断延迟 + CSR 写入延迟        │
  │                  │        每层切换增加 ~100 周期         │
  ├──────────────────┼─────────────────────────────────────┤
  │  方案 B: 硬件序列器│  npu_top 内部 FSM 自动调度          │
  │  (当前)          │  Conv1 → MaxPool → Conv2 → MaxPool  │
  │                  │  → GAP → FC 全部自动完成             │
  │                  │  优点: 层间切换 0 延迟               │
  │                  │  缺点: 灵活性低, 修改需改硬件        │
  └──────────────────┴─────────────────────────────────────┘

  选择方案 B 的理由:
  - CIFAR-10 分类网络结构固定, 无需运行时灵活性
  - 消除 CPU 介入的延迟开销 (每层节省 ~100 周期)
  - CPU 只需 1 次写入启动, 1 次读取结果 (最简软件接口)
```

### 为什么 CSR 寄存器这样分组？

```
  ┌───────────────────────────────────────────────────────┐
  │  寄存器设计原则: 最少的寄存器, 最大的配置能力          │
  │                                                       │
  │  CTRL (1 个寄存器):                                   │
  │  - bit[0] START: 启动脉冲 (自清除)                    │
  │  - bit[1] LSEL:  层选择 (Conv1/Conv2)                │
  │  为什么不分开? 启动和层选择总是一起配置                │
  │                                                       │
  │  SHAPE0 + SHAPE1 (2 个寄存器):                        │
  │  - 将输入尺寸和卷积参数打包到 2 个 32-bit 寄存器      │
  │  - 为什么不每个参数一个寄存器? 减少 CSR 地址空间       │
  │                                                       │
  │  STATUS (1 个只读寄存器):                              │
  │  - busy + done 两个状态位                              │
  │  - 为什么不分开读? 软件一次读取即可判断状态            │
  │                                                       │
  │  PRED (1 个只读寄存器):                                │
  │  - valid + class_id + logit 打包到 32-bit             │
  │  - 一次读取获取完整结果                                │
  └───────────────────────────────────────────────────────┘
```

### 为什么使用自清除脉冲？

```
  问题: 如果 START 是电平信号, 软件写 1 后忘记写 0 怎么办?

  ┌───────────────────────────────────────────────────────┐
  │  方案 A: 电平信号                                      │
  │  - 软件写 1 启动, 必须写 0 清除                        │
  │  - 风险: 忘记清除会导致重复触发                        │
  │                                                       │
  │  方案 B: 自清除脉冲 (当前)                             │
  │  - 软件写 1 启动, 硬件 1 周期后自动清零                │
  │  - 优势: 软件无需关心清除, 天然防重复                  │
  │                                                       │
  │  实现:                                                 │
  │  always_ff @(posedge clk) begin                       │
  │      start_pulse <= 1'b0;  // 默认清零                 │
  │      if (csr_wr_en && addr==CTRL)                     │
  │          start_pulse <= csr_wdata[0];                 │
  │  end                                                  │
  │                                                       │
  │  时序: 写入当拍 start_pulse=1, 下一拍自动清零          │
  └───────────────────────────────────────────────────────┘
```

### 为什么 NPU 用简单 CSR 而非 AXI-Lite？

```
  ┌──────────────────┬─────────────────────────────────────┐
  │  AXI4-Lite Slave │  完整的 AW/W/B/AR/R 通道           │
  │                  │  需要状态机管理握手                   │
  │                  │  代码量: ~200 行                     │
  ├──────────────────┼─────────────────────────────────────┤
  │  简单 CSR 接口   │  wr_en/rd_en/addr/wdata/rdata       │
  │  (当前)          │  无握手, 纯寄存器读写                │
  │                  │  代码量: ~60 行                      │
  └──────────────────┴─────────────────────────────────────┘

  分工:
  - axi2csr 桥负责 AXI4 → CSR 协议转换 (~100 行)
  - npu_csr_regs 只关心寄存器逻辑 (~60 行)
  - 总代码量与直接 AXI-Lite 相当, 但职责分离更清晰
```

---

## 设计视角：如何从零开始设计？

### 第 1 步: 确定控制需求

```
  从推理流程提取控制需求:

  ┌─────────────────────────────────────────────────────┐
  │  推理流程:                                           │
  │  1. CPU 写入图像数据 (DMA)                           │
  │  2. 启动 Conv1: 配置输入形状, 启动 DMAC + MAC        │
  │  3. 等待 Conv1 完成, 自动触发 MaxPool                │
  │  4. 启动 Conv2: 配置新的形状参数                     │
  │  5. 等待 Conv2 完成, 自动触发 MaxPool + GAP          │
  │  6. 启动 FC: 等待计算完成                            │
  │  7. CPU 读取结果                                     │
  │                                                     │
  │  控制信号提取:                                       │
  │  - 输入: start, layer_sel, 形状参数                  │
  │  - 输出: busy, done, pred_valid, pred_class_id      │
  └─────────────────────────────────────────────────────┘
```

### 第 2 步: 设计顶层状态机

```
  状态机设计过程:

  1. 识别必经阶段:
     IDLE → 加载图像 → 等待卷积 → 等待FC → 回到IDLE

  2. 确定状态:
     T_IDLE      (等待启动)
     T_LOAD_IMG  (加载图像到 image_buf)
     T_WAIT_CONV (等待 Conv1+Conv2+MaxPool)
     T_WAIT_FC   (等待 FC 计算)

  3. 确定转移条件:
     T_IDLE → T_LOAD_IMG:     CSR 写入 CTRL[0]=1
     T_LOAD_IMG → T_WAIT_CONV: img_load_done
     T_WAIT_CONV → T_WAIT_FC:  conv_done
     T_WAIT_FC → T_IDLE:       fc_done

  4. 确定输出动作:
     T_LOAD_IMG: img_load_start = 1
     T_WAIT_CONV: (等待)
     T_WAIT_FC: fc_start = 1
     T_IDLE: top_done_pulse = 1 (在 fc_done 时)
```

### 第 3 步: 设计 CSR 寄存器映射

```
  设计过程:

  1. 列出所有需要软件配置的参数:
     - 输入宽度、高度、通道数
     - 卷积核大小、padding、K 长度
     - 层选择、启动控制

  2. 列出所有需要软件读取的状态:
     - 忙/完成状态
     - 推理结果 (类别、logit)

  3. 打包到最少的 32-bit 寄存器:
     CTRL:   [1:0] = {LSEL, START}
     SHAPE0: [21:0] = {IN_CH, IN_H, IN_W}
     SHAPE1: [25:0] = {K_LEN, PAD, KERNEL}
     STATUS: [1:0] = {DONE, BUSY}
     PRED:   [23:0] = {LOGIT, CLASS_ID, VALID}

  4. 分配地址偏移:
     0x00, 0x04, 0x08, 0x0C, 0x10, 0x20
```

### 第 4 步: 设计 conv_top 内部调度

```
  conv_top 需要管理两层卷积的细粒度调度:

  run_phase 状态机:
  P_IDLE → P_LAYER1 → P_LAYER2_DMAC → P_LAYER2_MAC_PASS0
         → P_LAYER2_MAC_PASS1 → P_IDLE

  mac_ctrl_state 状态机:
  M_IDLE → M_WAIT_DMAC → M_FEED → M_WAIT_TILE
         → (循环 tile) → M_IDLE

  设计要点:
  - run_phase 管理层间切换 (粗粒度)
  - mac_ctrl_state 管理 tile 间切换 (细粒度)
  - 两个状态机协同工作, 各司其职
```

### 第 5 步: 验证控制流

```
  验证策略:
  1. CSR 写入验证: 写入各寄存器, 读回确认
  2. 状态机追踪: 监控状态转移, 确认顺序正确
  3. 边界情况: Conv1 完成后立即启动 Conv2 (无间隙)
  4. 异常处理: 复位后状态是否回到 IDLE

  关键检查点:
  - start_pulse 是否正确自清除
  - conv_done 是否在所有 tile 完成后才拉高
  - fc_start 是否在 conv_done 后正确触发
  - top_done_pulse 是否在 fc_done 后正确产生
```

---

## 设计视角：架构模式与原则

### 模式 1: 硬件序列器模式 (Hardware Sequencer)

```
  核心思想: 用 FSM 自动执行多步骤任务, 软件只需启动和读结果

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  软件视角 (极简):                                     │
  │  1. 写 SHAPE0, SHAPE1 (配置参数)                      │
  │  2. 写 CTRL = 0x01 (启动)                             │
  │  3. 等待 STATUS.DONE                                  │
  │  4. 读 PRED (结果)                                    │
  │                                                       │
  │  硬件视角 (自动):                                     │
  │  ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐          │
  │  │ 加载  │──►│Conv1 │──►│Conv2 │──►│ FC   │          │
  │  │ 图像  │   │+Pool │   │+Pool │   │+argmax│         │
  │  └──────┘   └──────┘   └──────┘   └──────┘          │
  │  自动流转, 无需 CPU 介入                               │
  │                                                       │
  │  优势:                                                 │
  │  - CPU 在推理期间可执行其他任务                        │
  │  - 层间切换零延迟 (硬件直接触发)                       │
  │  - 软件接口极简 (1 次写 + 1 次读)                     │
  └───────────────────────────────────────────────────────┘

  适用场景:
  - 推理流程固定, 无需运行时动态调整
  - 延迟敏感, 不能容忍 CPU 介入开销
  - 嵌入式场景, CPU 算力有限
```

### 模式 2: 多层级 FSM 模式 (Multi-Level FSM)

```
  核心思想: 将复杂的控制逻辑分解为多个层级的 FSM, 各司其职

  ┌───────────────────────────────────────────────────────┐
  │                                                       │
  │  层级 1: npu_top (顶层调度)                           │
  │  ┌─────────────────────────────────────────────┐     │
  │  │ T_IDLE → T_LOAD_IMG → T_WAIT_CONV → T_WAIT_FC│   │
  │  │ 管理: 推理的整体生命周期                       │     │
  │  └──────────────────────┬──────────────────────┘     │
  │                         │ conv_done, fc_done          │
  │                         ▼                             │
  │  层级 2: conv_top (卷积调度)                          │
  │  ┌─────────────────────────────────────────────┐     │
  │  │ P_IDLE → P_LAYER1 → P_LAYER2_DMAC → P_LAYER2 │   │
  │  │ 管理: 两层卷积的切换                           │     │
  │  └──────────────────────┬──────────────────────┘     │
  │                         │ dmac_done, tile_done        │
  │                         ▼                             │
  │  层级 3: mac_ctrl_state (tile 调度)                   │
  │  ┌─────────────────────────────────────────────┐     │
  │  │ M_IDLE → M_WAIT_DMAC → M_FEED → M_WAIT_TILE │   │
  │  │ 管理: 单层内的 tile 循环和数据馈送             │     │
  │  └─────────────────────────────────────────────┘     │
  │                                                       │
  │  层级间通信: done 信号向上, start 信号向下             │
  └───────────────────────────────────────────────────────┘

  设计要点:
  - 每层 FSM 只关心自己的职责, 不了解下层细节
  - 层间通过 done/start 脉冲信号通信
  - 新增层 (如 BatchNorm) 只需添加新的 run_phase 状态
```

### 原则: 脉冲信号 vs 电平信号

```
  ┌─────────────────────────────────────────────────────┐
  │  设计原则: 控制信号用脉冲, 状态信号用电平            │
  │                                                     │
  │  脉冲信号 (自清除, 1 周期高):                        │
  │  - start_pulse: 触发动作, 不需要持续                 │
  │  - fc_start: 触发 FC 计算                            │
  │  - top_done_pulse: 通知完成                          │
  │                                                     │
  │  电平信号 (持续有效):                                │
  │  - busy: 反映当前是否在工作                          │
  │  - conv_busy: 卷积模块正在计算                       │
  │  - fc_busy: FC 模块正在计算                          │
  │                                                     │
  │  为什么这样区分?                                     │
  │  - 脉冲信号用于触发, 边沿敏感 (上升沿触发动作)       │
  │  - 电平信号用于查询, 电平敏感 (高电平表示忙)         │
  │  - 混用会导致重复触发或遗漏触发                      │
  │                                                     │
  │  实现模式:                                           │
  │  always_ff @(posedge clk) begin                     │
  │      pulse_signal <= 1'b0;      // 默认清零          │
  │      if (trigger_condition)                          │
  │          pulse_signal <= 1'b1;  // 条件置位          │
  │  end                                                │
  └─────────────────────────────────────────────────────┘
```

---

## 2. CSR寄存器映射 (npu_csr_regs.sv)

### 2.1 寄存器地址表

| 地址偏移 | 名称     | 读/写 | 功能描述                |
|----------|----------|-------|------------------------|
| 0x00     | CTRL     | R/W   | 控制寄存器（启动/层选择）|
| 0x04     | STATUS   | R     | 状态寄存器（忙/完成）    |
| 0x08     | SHAPE0   | R/W   | 输入尺寸（W/H/CH）      |
| 0x0C     | SHAPE1   | R/W   | 卷积参数（kernel/pad/k_len）|
| 0x10     | TILE     | R/W   | Tile行基地址            |
| 0x20     | PRED     | R     | 推理结果（class_id/logit）|

> 源码参考：`src/npu/npu_csr_regs.sv` 第36-41行定义了寄存器地址常量。

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第36-41行
localparam logic [AW-1:0] REG_CTRL     = 8'h00;
localparam logic [AW-1:0] REG_STATUS   = 8'h04;
localparam logic [AW-1:0] REG_SHAPE0   = 8'h08;
localparam logic [AW-1:0] REG_SHAPE1   = 8'h0c;
localparam logic [AW-1:0] REG_TILE     = 8'h10;
localparam logic [AW-1:0] REG_PRED     = 8'h20;
```

### 2.2 CTRL寄存器（0x00）位域

```
  Bit 31        Bit 8  Bit 1  Bit 0
  ┌────────────┬───────┬──────┬──────┐
  │  Reserved  │  ...  │ LSEL │START │
  └────────────┴───────┴──────┴──────┘
                 写0忽略  层选择  启动脉冲
```

- **Bit [0] START**：写1产生启动脉冲`start_pulse`，触发NPU开始推理
- **Bit [1] LSEL**：层选择，0=第一层卷积，1=第二层卷积
- 写入后`start_pulse`自动在一个时钟周期后清零（自清除脉冲）

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第57-61行
// 写CTRL时的处理逻辑
REG_CTRL: begin
    start_pulse <= csr_wdata[0];  // bit0 → 启动脉冲
    layer_sel   <= csr_wdata[1];  // bit1 → 层选择
end
```

### 2.3 STATUS寄存器（0x04）位域

```
  Bit 31        Bit 2  Bit 1    Bit 0
  ┌────────────┬──────┬────────┬────────┐
  │  Reserved  │  ... │ DMAC_  │ DMAC_  │
  │            │      │ DONE   │ BUSY   │
  └────────────┴──────┴────────┴────────┘
```

- **Bit [0] DMAC_BUSY**：im2col数据搬运器正在工作
- **Bit [1] DMAC_DONE**：im2col数据搬运完成标志

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第89-92行
REG_STATUS: begin
    csr_rdata[0] = dmac_busy;   // 组合逻辑读取
    csr_rdata[1] = dmac_done;
end
```

### 2.4 SHAPE0寄存器（0x08）位域

```
  Bit 31       Bit 22 Bit 21    Bit 16 Bit 14 Bit 13    Bit 8 Bit 6 Bit 5      Bit 0
  ┌────────────┬──────┬─────────┬──────┬──────┬─────────┬─────┬────┬───────────┐
  │  Reserved  │  ... │  IN_CH  │  ... │ IN_H │   ...   │     │    │   IN_W    │
  └────────────┴──────┴─────────┴──────┴──────┴─────────┴─────┴────┴───────────┘
                  6bit输入通道数    6bit输入高度              6bit输入宽度
```

- **Bit [5:0] IN_W**：输入特征图宽度，默认32
- **Bit [13:8] IN_H**：输入特征图高度，默认32
- **Bit [21:16] IN_CH**：输入通道数，默认3

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第62-66行
REG_SHAPE0: begin
    cfg_in_w  <= csr_wdata[5:0];    // 宽度
    cfg_in_h  <= csr_wdata[13:8];   // 高度
    cfg_in_ch <= csr_wdata[21:16];  // 通道数
end
```

### 2.5 SHAPE1寄存器（0x0C）位域

```
  Bit 25        Bit 16  Bit 10  Bit 8  Bit 2  Bit 0
  ┌─────────────┬───────┬───────┬──────┬──────┬───────┐
  │   Reserved  │ K_LEN │  PAD  │  ... │      │KERNEL │
  └─────────────┴───────┴───────┴──────┴──────┴───────┘
    10bit k_len    3bit填充    3bit卷积核
```

- **Bit [2:0] KERNEL**：卷积核大小，默认5（5x5卷积）
- **Bit [10:8] PAD**：填充大小，默认2
- **Bit [25:16] K_LEN**：im2col展开后的行长度，默认75（5*5*3）

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第67-70行
REG_SHAPE1: begin
    cfg_kernel <= csr_wdata[2:0];    // 卷积核大小
    cfg_pad    <= csr_wdata[10:8];   // 填充
    cfg_k_len  <= csr_wdata[25:16];  // im2col k长度
end
```

### 2.6 PRED寄存器（0x20）位域

```
  Bit 31    Bit 24  Bit 23    Bit 16  Bit 11    Bit 8  Bit 0
  ┌─────────┬───────┬─────────┬───────┬─────────┬──────┬─────────┐
  │ SE(logit│       │  LOGIT  │       │ CLASS_  │      │ PRED_   │
  │ 符号扩展│       │  预测值 │       │   ID    │      │ VALID   │
  └─────────┴───────┴─────────┴───────┴─────────┴──────┴─────────┘
     8bit                  8bit置信度    4bit类别     1bit有效
```

- **Bit [0]**：`result_valid` -- 推理结果有效标志
- **Bit [11:8]**：`result_class_id` -- 预测类别（CIFAR-10的0-9）
- **Bit [23:16]**：`result_logit` -- 预测置信度（int8有符号）
- **Bit [31:24]**：logit的符号扩展（方便软件直接当做有符号数读取）

```systemverilog
// 文件：src/npu/npu_csr_regs.sv，第106-111行
REG_PRED: begin
    csr_rdata[0]      = result_valid;
    csr_rdata[11:8]   = result_class_id;
    csr_rdata[23:16]  = result_logit;
    csr_rdata[31:24]  = {8{result_logit[7]}};  // 符号扩展
end
```

---

## 3. npu_top顶层状态机

### 3.1 状态定义

```systemverilog
// 文件：src/npu/npu_top.sv，第98-103行
typedef enum logic [2:0] {
    T_IDLE,       // 空闲，等待启动命令
    T_LOAD_IMG,   // 从npu_ram加载图像到image_buf
    T_WAIT_CONV,  // 等待卷积层完成（conv1+pool1+conv2+pool2）
    T_WAIT_FC     // 等待全连接层完成
} top_state_t;
```

### 3.2 状态转移图

```
                    CSR写入CTRL[0]=1
                    ┌───────────┐
                    │           │
                    ▼           │
              ┌──────────┐      │
     ┌───────│  T_IDLE  │◄─────┼─────────────────┐
     │        └────┬─────┘      │                 │
     │             │            │                 │
     │      img_load_start      │                 │
     │             │            │                 │
     │             ▼            │                 │
     │     ┌──────────────┐     │                 │
     │     │ T_LOAD_IMG   │     │                 │
     │     └──────┬───────┘     │                 │
     │            │             │                 │
     │     img_load_done        │                 │
     │            │             │                 │
     │            ▼             │                 │
     │     ┌──────────────┐     │                 │
     │     │ T_WAIT_CONV  │     │                 │
     │     └──────┬───────┘     │                 │
     │            │             │                 │
     │       conv_done          │                 │
     │     fc_start=1           │                 │
     │            │             │                 │
     │            ▼             │                 │
     │     ┌──────────────┐     │                 │
     └────►│  T_WAIT_FC   │─────┘                 │
           └──────┬───────┘                       │
                  │                               │
             fc_done                              │
           top_done_pulse=1                       │
                  │                               │
                  └───────────────────────────────┘
```

### 3.3 状态机完整代码分析

```systemverilog
// 文件：src/npu/npu_top.sv，第266-310行
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        top_state      <= T_IDLE;
        fc_start       <= 1'b0;
        top_done_pulse <= 1'b0;
        img_load_start <= 1'b0;
    end else begin
        // 默认清除脉冲信号
        fc_start       <= 1'b0;
        top_done_pulse <= 1'b0;
        img_load_start <= 1'b0;

        unique case (top_state)
            T_IDLE: begin
                // 检测CSR写入CTRL寄存器且bit0=1
                if (csr_wr_en && (csr_addr == REG_CTRL) && csr_wdata[0]) begin
                    img_load_start <= 1'b1;  // 触发图像加载
                    top_state      <= T_LOAD_IMG;
                end
            end

            T_LOAD_IMG: begin
                // 等待npu_ram → image_buf 拷贝完成
                if (img_load_done) begin
                    top_state <= T_WAIT_CONV;
                end
            end

            T_WAIT_CONV: begin
                // conv_done由conv_top产生，标志两层卷积全部完成
                if (conv_done) begin
                    fc_start  <= 1'b1;    // 触发FC层
                    top_state <= T_WAIT_FC;
                end
            end

            T_WAIT_FC: begin
                if (fc_done) begin
                    top_done_pulse <= 1'b1;  // 产生完成脉冲
                    top_state      <= T_IDLE;
                end
            end

            default: top_state <= T_IDLE;
        endcase
    end
end
```

**设计要点：**
- `start_pulse`、`fc_start`、`img_load_start`、`top_done_pulse`都是自清除脉冲信号，在每个时钟周期默认清零，只在特定条件下置位一个周期
- `busy`信号是组合逻辑：`busy = conv_busy || fc_busy || (top_state != T_IDLE)`
- `done`信号只在完成瞬间产生一个时钟周期的高脉冲

---

## 4. conv_top内部调度状态机

### 4.1 运行阶段状态机 (run_phase)

conv_top管理两层卷积的完整流水线：

```systemverilog
// 文件：src/npu/conv_top.sv，第114-120行
typedef enum logic [2:0] {
    P_IDLE,              // 空闲
    P_LAYER1,            // 第一层卷积（conv1 3→32通道）
    P_LAYER2_DMAC,       // 第二层im2col数据准备
    P_LAYER2_MAC_PASS0,  // 第二层卷积pass0（输出0-31通道）
    P_LAYER2_MAC_PASS1   // 第二层卷积pass1（输出32-63通道）
} run_phase_t;
```

### 4.2 MAC控制状态机 (mac_ctrl_state)

```
     ┌──────────┐
     │  M_IDLE  │◄──────────────────────────────────┐
     └────┬─────┘                                    │
          │ csr_start_pulse                          │
          ▼                                          │
     ┌──────────────┐                                │
     │ M_WAIT_DMAC  │◄─── Layer2开始时也回到这里      │
     └──────┬───────┘                                │
            │ dmac_done                              │
            ▼                                        │
     ┌──────────┐                                    │
     │ M_FEED   │─── 从image_sa_ram读取数据送给MAC    │
     └────┬─────┘                                    │
          │ 所有K列数据已送入                          │
          ▼                                          │
     ┌──────────────┐                                │
     │ M_WAIT_TILE  │─── 等待MAC输出一个tile          │
     └──────┬───────┘                                │
            │                                        │
            ├─ 还有更多tile? → 回到M_FEED             │
            │                                        │
            └─ 所有tile完成且result_done && ppu_done  │
               ├─ Layer1完成 → M_WAIT_DMAC (准备L2)   │
               ├─ L2 PASS0完成 → M_FEED (开始PASS1)   │
               └─ L2 PASS1完成 → M_IDLE (全部完成)     │
```

### 4.3 两层卷积的完整执行流程

```
时间线：
─────────────────────────────────────────────────────────►

Layer 1 (conv1: 3ch→32ch, 32x32):
  ┌──────┐  ┌───────────────┐  ┌───────────┐  ┌──────────┐
  │ DMAC │→│ MAC (26 tiles) │→│ MaxPool   │→│ 写pool_ram│
  │im2col│  │ 40行×32列×75K │  │ 32→16    │  │          │
  └──────┘  └───────────────┘  └───────────┘  └──────────┘

Layer 2 (conv2: 32ch→64ch, 16x16):
  ┌──────┐  ┌───────────────┐  ┌───────────┐  ┌──────────┐
  │ DMAC │→│ MAC PASS0     │→│ MaxPool   │→│ 写pool    │
  │im2col│  │ (32输出通道)   │  │ 16→8     │  │  RAM     │
  └──────┘  ├───────────────┤  ├───────────┤  ├──────────┤
            │ MAC PASS1     │→│ MaxPool   │→│ 写pool    │
            │ (后32输出通道) │  │ 16→8     │  │  RAM     │
            └───────────────┘  └───────────┘  └──────────┘
```

**关键参数（默认配置）：**
- Layer 1: `K_LEN=75`(5×5×3), `TILE_ROWS=40`, `OUT_ROWS=1024`(32×32), 需要26个tile
- Layer 2: `K_LEN=800`(5×5×32), `TILE_ROWS=40`, `OUT_ROWS=256`(16×16), 需要7个tile/pass, 两个pass

---

## 5. 调试接口

### 5.1 可用的调试端口

npu_top提供了四组只读调试端口，可在仿真或运行时直接读取内部存储器内容：

```
┌─────────────────────────────────────────────────────┐
│ npu_top 调试端口                                     │
│                                                     │
│  dbg_sa_rd_en/addr/data ──→ image_sa_ram (im2col矩阵)│
│  dbg_result_rd_en/addr/data → result_ram (卷积结果)   │
│  dbg_pool_rd_en/addr/data ──→ pool_ram (池化结果)     │
│  dbg_logit_rd_en/addr/data → logit_q[] (FC输出)      │
│                                                     │
│  mac_dbg_tile_valid/data ──→ MAC第一个tile调试数据    │
└─────────────────────────────────────────────────────┘
```

### 5.2 image_sa_ram多路复用

image_sa_ram的读端口在MAC工作和调试之间进行多路复用：

```systemverilog
// 文件：src/npu/conv_top.sv，第294-296行
// MAC工作时给MAC用，空闲时给调试用
assign image_sa_rd_en   = (mac_ctrl_state == M_FEED) ? mac_sa_rd_en   : dbg_sa_rd_en;
assign image_sa_rd_addr = (mac_ctrl_state == M_FEED) ? mac_sa_rd_addr : dbg_sa_rd_addr;
assign dbg_sa_rd_data   = image_sa_rd_data;  // 调试数据始终输出
```

---

## 6. NPU性能指标分析

### 6.1 推理延迟估算

| 阶段 | 计算量 | 时钟周期（估算）|
|------|--------|----------------|
| DMAC Layer1 | 1024×75次im2col | ~1024 |
| MAC Layer1 | 1024×32×75 = 2.4M MAC | ~75×26 = 1950 |
| MaxPool1 | 1024→256 | ~1024 |
| DMAC Layer2 | 256×800次im2col | ~800×2 |
| MAC Layer2 | 256×64×800 = 13M MAC | ~800×14 = 11200 |
| MaxPool2 | 256→64 | ~256 |
| GAP+FC | 64×10+10 | ~740 |
| **总计** | | **~16000 cycles** |

在100MHz时钟下，单次推理延迟约 **160微秒**。

### 6.2 MAC阵列效率

MAC阵列为40×32的脉动阵列（`mac_array_40x32_stream`），由10×8个4×4子阵列组成：
- 每个时钟周期完成 40×32 = 1280 次乘累加
- Layer1总MAC：1024×32×75 = 2,457,600
- 理论最优周期数：2,457,600 / 1280 = 1920 cycles

---

## 7. 软件控制流程示例

### 7.1 典型的NPU推理启动序列

```c
// 伪代码：CPU启动NPU推理
// 1. 配置输入形状
writel(0x0020_2020, NPU_CSR_BASE + 0x08);  // SHAPE0: W=32, H=32, CH=3
writel(0x04B_0205,  NPU_CSR_BASE + 0x0C);  // SHAPE1: K_LEN=75, PAD=2, KERNEL=5

// 2. 启动推理
writel(0x01, NPU_CSR_BASE + 0x00);         // CTRL: START=1

// 3. 轮询等待完成
while (!(readl(NPU_CSR_BASE + 0x04) & 0x02));  // 等待STATUS.DONE

// 4. 读取推理结果
uint32_t pred = readl(NPU_CSR_BASE + 0x20);     // PRED寄存器
int valid    = pred & 0x01;
int class_id = (pred >> 8) & 0x0F;
int logit    = (int8_t)((pred >> 16) & 0xFF);   // 有符号
```

---

## 8. 关键知识点总结

1. **自清除脉冲设计**：`start_pulse`在写入后自动清零，防止重复触发。这是硬件控制寄存器的常见模式。

2. **分离的忙/完成信号**：`busy`反映当前状态（组合逻辑），`done`产生单周期脉冲（时序逻辑）。软件应使用中断或轮询`done`脉冲。

3. **两级状态机架构**：npu_top的四状态机管理顶层流程，conv_top的双状态机（run_phase + mac_ctrl_state）管理卷积子任务的细粒度调度。

4. **PASS机制**：Layer2需要两个PASS是因为MAC阵列宽度为32，而输出通道数为64，需要分两次计算。

5. **调试端口复用**：RAM读端口在MAC工作时供MAC使用，空闲时供外部调试读取，通过组合逻辑MUX切换。

---

## 9. 动手练习

### 练习1：寄存器位域计算

给定以下软件写入值，计算各寄存器的实际配置：

```
SHAPE0 = 0x0014_1420  →  IN_W=___, IN_H=___, IN_CH=___
SHAPE1 = 0x0320_0303  →  KERNEL=___, PAD=___, K_LEN=___
```

<details>
<summary>参考答案</summary>

```
SHAPE0 = 0x0014_1420:
  IN_W  = 0x20 & 0x3F = 32
  IN_H  = (0x1420 >> 8) & 0x3F = 0x14 & 0x3F = 20
  IN_CH = (0x0014_1420 >> 16) & 0x3F = 0x14 & 0x3F = 20

SHAPE1 = 0x0320_0303:
  KERNEL = 0x03 & 0x07 = 3
  PAD    = (0x0303 >> 8) & 0x07 = 0x03 & 0x07 = 3
  K_LEN  = (0x0320_0303 >> 16) & 0x3FF = 0x0320 & 0x3FF = 800
```
</details>

### 练习2：状态机追踪

假设CPU执行以下操作序列，画出npu_top状态机的转移路径和每个状态的持续时间：

```
T=0:    CPU写入CTRL=0x01
T=5:    img_load_done拉高
T=100:  conv_done拉高
T=200:  fc_done拉高
```

### 练习3：修改NPU支持更多分类

当前FC层输出10类（CIFAR-10）。如果要支持ImageNet的1000类分类，需要修改哪些模块和参数？列出具体需要改动的文件和参数。

<details>
<summary>提示</summary>

需要修改：
1. `gap_fc_logits.sv`的`OUT_CLASSES`参数
2. `npu_top.sv`中`gap_fc_logits`实例化的参数
3. FC权重和偏置的ROM文件
4. PRED寄存器中class_id的位宽（4bit→10bit）
5. `dbg_logit_rd_addr`的位宽
</details>

### 练习4：添加超时保护

在npu_top的状态机中添加超时计数器。如果在任何一个状态停留超过100000个时钟周期，自动返回IDLE并置位错误标志。写出修改后的`T_WAIT_CONV`状态代码。

---

## 10. 下一讲预告

下一讲（Lecture 23）将深入分析NPU的存储子系统，包括：
- npu_ram的AXI4 Slave接口实现
- image_sa_ram、result_ram、pool_ram的组织结构
- 权重ROM的数据布局
- 存储带宽分析与瓶颈识别
