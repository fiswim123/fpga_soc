# Lecture 05d: AXI Crossbar深入（六）— 流水线与FIFO

## 课程目标

本讲分析 `axicb_pipeline.sv` 和 `axicb_scfifo.sv`——Crossbar的流水线寄存器和同步FIFO，理解时序优化和缓冲机制。

---

## 1. 模块概览

### 1.1 流水线寄存器的作用

```text
问题：Crossbar的组合逻辑路径可能很长
  路径: slv_if → slv_switch(地址解码) → switch_top(重排) → mst_switch(仲裁) → mst_if
  如果200MHz时钟，这级组合逻辑可能超过5ns → 时序违例

解决方案：在路径中插入流水线寄存器（Pipeline Register）
  将长路径切成两段，每段的组合逻辑延迟减半
  代价：增加1个时钟周期的延迟
```

### 1.2 FIFO的作用

```text
FIFO在Crossbar中有两个用途：
  1. slv_if中的缓冲: 暂存Master的请求，提升Outstanding能力
  2. slv_ooo中的跟踪: 记录事务属性，支持乱序完成

FIFO的关键设计：
  - 同步FIFO: 单时钟域（本项目使用）
  - Wrap-bit编码: 用额外一位区分满和空
  - 可清空: srst信号清空所有数据
```

---

## 2. 设计视角：为什么这样设计？

### 2.1 为什么用递归流水线？

```text
方案A: 固定N级流水线
  每个通道固定插入N级寄存器
  问题: N太小→时序不够，N太大→延迟太大

方案B: 可配置流水线（本设计）
  通过MST_PIPELINE和SLV_PIPELINE参数配置级数
  0=不插入，1=插入1级，2=插入2级
  优点: 灵活配置，综合时根据时序需求选择

方案C: 异步流水线
  插入异步FIFO跨时钟域
  问题: 面积大，延迟不确定

选择B的理由：
  1. 灵活：可在综合时调整
  2. 简单：纯寄存器，无复杂逻辑
  3. 可预测：延迟 = 级数 × 时钟周期
```

### 2.2 为什么用Wrap-Bit FIFO？

```text
问题：如何区分FIFO的"满"和"空"？

方案A: 计数器
  用一个计数器记录FIFO中的数据量
  满: count == DEPTH
  空: count == 0
  问题: 计数器是加减法器，面积大，时序差

方案B: Wrap-Bit（本设计）
  读写指针各加1位wrap bit
  满: write_ptr == {~read_ptr[MSB], read_ptr[MSB-1:0]}
  空: write_ptr == read_ptr（包括wrap bit）
  优点: 只有比较器，无加减法器，面积小，时序好

方案C: 用RAM + 状态机
  更复杂，适合异步FIFO
  本项目用同步FIFO，不需要
```

---

## 3. 设计视角：如何从零开始设计？

### Step 1: 流水线寄存器设计

```text
递归N级流水线的设计：

  if (N == 0)
    // 直通，无寄存器
    assign o = i;
  else
    // 插入一级寄存器，然后递归
    always @(posedge clk)
      stage1 <= i;
    pipeline #(.N(N-1)) next (.i(stage1), .o(o));

Verilog的generate块可以实现这种递归。
```

### Step 2: 流水线插入位置

```text
Crossbar中流水线的两个插入点：

  Slave侧 (MST_PIPELINE):
    slv_if → [Pipeline] → switch_top
    作用: 切断slv_if到交换矩阵的路径

  Master侧 (SLV_PIPELINE):
    switch_top → [Pipeline] → mst_if
    作用: 切断交换矩阵到mst_if的路径

本项目: MST_PIPELINE=0, SLV_PIPELINE=0（不插入）
  原因: 4×4规模较小，组合逻辑延迟可接受
  如果扩展到8×8或更高频率，需要开启
```

### Step 3: 同步FIFO设计

```text
Wrap-Bit FIFO的核心组件：

  1. 读写指针（各 WIDTH+1 位，含wrap bit）
  2. 存储器（RAM或寄存器堆）
  3. 满/空判断逻辑

  写操作:
    if (!full) begin
      mem[write_ptr[WIDTH-1:0]] <= data_in;
      write_ptr <= write_ptr + 1;
    end

  读操作:
    if (!empty) begin
      data_out <= mem[read_ptr[WIDTH-1:0]];
      read_ptr <= read_ptr + 1;
    end

  满判断:
    full = (write_ptr == {~read_ptr[WIDTH], read_ptr[WIDTH-1:0]});

  空判断:
    empty = (write_ptr == read_ptr);
```

### Step 4: FIFO实现选择

```text
axicb_scfifo支持两种存储实现：

  RAM实现 (axicb_scfifo_ram):
    使用FPGA的Block RAM
    适合深度较大的FIFO（>16）
    面积小但读延迟1周期

  寄存器堆实现 (axicb_scfifo_regfile):
    使用触发器
    适合深度较小的FIFO（≤16）
    面积大但读延迟0周期（组合逻辑读出）

选择依据:
  深度 ≤ 8: 用寄存器堆（面积可接受，时序好）
  深度 > 8: 用RAM（面积优势明显）
```

### Step 5: 验证策略

```text
1. 流水线延迟: 插入N级后，数据延迟N个周期到达
2. FIFO满: 写满时wready=0，不再接受数据
3. FIFO空: 读空时rvalid=0，不输出无效数据
4. 清空: srst后所有指针归零，empty=1
5. 边界: 写满后读一个，full变0，可以继续写
```

---

## 4. 设计视角：架构模式

### 模式 1: 流水线切割（Pipeline Cut）

```text
┌─────────────────────────────────────────────────────────────┐
│ 模式: 流水线切割                                             │
│                                                             │
│ 核心: 在长组合逻辑路径中插入寄存器，切断时序路径              │
│                                                             │
│ 实现:                                                        │
│   组合逻辑A → [Reg] → 组合逻辑B                              │
│   延迟: A的延迟 + 1周期 + B的延迟                            │
│   原来: A的延迟 + B的延迟（可能超过时钟周期）                 │
│                                                             │
│ 权衡: 延迟↑ vs Fmax↑                                        │
│ 复用: 任何需要提升时序的长路径                               │
└─────────────────────────────────────────────────────────────┘
```

### 模式 2: Wrap-Bit FIFO

```text
┌─────────────────────────────────────────────────────────────┐
│ 模式: Wrap-Bit同步FIFO                                       │
│                                                             │
│ 核心: 读写指针各加1位wrap bit，用比较器判断满/空              │
│                                                             │
│ 满: write_ptr == {~read_ptr[MSB], read_ptr[MSB-1:0]}       │
│ 空: write_ptr == read_ptr                                   │
│                                                             │
│ 优点: 无加减法器，面积小，时序好                             │
│ 复用: 任何需要缓冲的同步数据通路                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. 本讲要点

| 要点 | 说明 |
|------|------|
| 流水线 | 在长路径中插入寄存器，提升Fmax |
| 递归实现 | generate块实现N级可配置流水线 |
| Wrap-Bit | 用额外1位区分满/空，无加减法器 |
| 两种FIFO | RAM实现(深度大) / 寄存器堆实现(深度小) |
| 插入位置 | Slave侧(MST_PIPELINE) / Master侧(SLV_PIPELINE) |
| 本项目配置 | 两级流水线都为0（4×4规模不需要） |

---

## 6. Crossbar完整架构总结

```text
┌─────────────────────────────────────────────────────────────┐
│                 AXI Crossbar 完整架构                        │
│                                                             │
│  外部Master                                                 │
│  ┌──────┐                                                   │
│  │ CPU  │──┐                                                │
│  └──────┘  │  ┌─────────┐  ┌───────────┐  ┌─────────┐     │
│            ├─►│ slv_if  │─►│slv_switch │─►│         │     │
│  ┌──────┐  │  │(打包)   │  │(地址路由)  │  │ switch  │     │
│  │ DMA  │──┤  └─────────┘  └───────────┘  │  _top   │     │
│  └──────┘  │                              │         │     │
│            │  ┌─────────┐  ┌───────────┐  │         │     │
│            │  │ slv_ooo │◄─┤(乱序管理)  │◄─┤         │     │
│            │  └─────────┘  └───────────┘  │         │     │
│            │                              │         │     │
│            │  ┌─────────┐  ┌───────────┐  │         │     │
│            │  │mst_switch│◄─┤(仲裁汇聚)  │◄─┤         │     │
│            │  └────┬────┘  └───────────┘  └─────────┘     │
│            │       │                                        │
│            │  ┌────▼────┐  ┌───────────┐                   │
│            │  │ mst_if  │──►│  DDR      │                   │
│            │  │(解包+翻译)│  └───────────┘                   │
│            │  └─────────┘                                   │
└─────────────────────────────────────────────────────────────┘

信号流: Master → slv_if(打包) → slv_switch(路由) → switch_top(重排)
        → mst_switch(仲裁) → mst_if(解包+翻译) → Slave

响应流: Slave → mst_if(打包) → slv_ooo(匹配) → slv_if(解包) → Master
```

---

## 7. 下节预告

下一讲回到 `axi2csr.sv`——将AXI4协议降级为简单CSR接口的桥接器。
