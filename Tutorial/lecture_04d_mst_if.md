# Lecture 04d: AXI Crossbar深入（三）— Master接口与地址翻译

## 课程目标

本讲分析 `axicb_mst_if.sv`——Crossbar中连接外部**从设备**（DDR、NPU RAM）的接口模块，以及 `axicb_mst_switch` 的仲裁汇聚逻辑。

---

## 1. 模块概览

### 1.1 命名说明

```text
axicb_mst_if 的 "mst" 是从 Crossbar 内部视角命名的：
  - 对 Crossbar 内部来说，这是"Master接口"（Crossbar是主，外部是从）
  - 对外部来说，这是"Slave连接点"（外部从设备连接到这里）

本项目连接：
  mst0 → DDR (0x4000_0000)
  mst1 → NPU RAM (0x0000_1000)
  mst2 → DMA CSR (0x0002_1000)
  mst3 → NPU CSR (0x0003_0000)
```

### 1.2 模块功能

```text
┌─────────────────────────────────────────────────────────┐
│                    axicb_mst_if                         │
│                                                         │
│  Crossbar内部              →    外部从设备               │
│  打包通道总线                     独立AXI信号            │
│  ┌───────────────┐              ┌───────────────┐      │
│  │ i_awvalid     │              │ o_awvalid     │      │
│  │ i_awch[AWCH_W]│   解包       │ o_awaddr[31:0]│      │
│  │               │ ──────────► │ o_awlen[7:0]  │      │
│  │               │ + 地址翻译   │ o_awid[7:0]   │      │
│  └───────────────┘              └───────────────┘      │
│                                                         │
│  功能: 打包通道总线 → 独立AXI信号 + 地址翻译             │
│  模式: CDC / 缓冲 / 直通                                 │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 设计视角：为什么这样设计？

### 2.1 为什么需要地址翻译？

```text
问题：Crossbar内部使用全局地址（如0x4000_0000），但DDR模型的地址从0开始。

全局地址: CPU访问 0x4000_0000 → Crossbar路由到mst0 → DDR
DDR本地地址: DDR内部地址从 0x0000_0000 开始

如果直接把0x4000_0000传给DDR：
  DDR需要知道自己在全局地址空间中的位置 → 增加DDR设计复杂度
  或者DDR需要支持任意基地址 → 面积增大

解决方案：mst_if在输出前减去基地址
  输入: addr = 0x4000_0000 (全局地址)
  输出: addr = 0x4000_0000 - 0x4000_0000 = 0x0000_0000 (本地地址)

KEEP_BASE_ADDR参数控制：
  KEEP_BASE_ADDR = 0: 减去基地址（本项目使用）
  KEEP_BASE_ADDR = 1: 保持全局地址不变
```

### 2.2 为什么需要仲裁汇聚？

```text
问题：多个Master可能同时访问同一个Slave。

场景：CPU和DMA同时访问DDR
  CPU发: awvalid_s0[0] = 1 (Master0→Slave0)
  DMA发: awvalid_s0[1] = 1 (Master1→Slave0)
  DDR只有一个接口，不能同时接受两个写请求

解决方案：用Round-Robin仲裁器选择一个
  mst_switch_wr: 在Master0和Master1之间仲裁
  获胜者: 其AW信号连接到DDR
  失败者: 等待下一轮
```

### 2.3 方案对比

```text
┌─────────────┬──────────────────┬──────────────┬─────────────┐
│ 方案        │ 地址翻译         │ 仲裁         │ 适用场景    │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ A.mst_if    │ 减去基地址       │ RR仲裁       │ 标准Crossbar│
│ (本设计)    │                  │              │             │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ B.Slave自行 │ Slave内部处理    │ 无仲裁       │ Slave是智能 │
│ 翻译        │                  │ (Slave仲裁)  │ 设备        │
├─────────────┼──────────────────┼──────────────┼─────────────┤
│ C.无翻译    │ 保持全局地址     │ RR仲裁       │ 统一编址    │
│             │                  │              │ 的存储器    │
└─────────────┴──────────────────┴──────────────┴─────────────┘
```

---

## 3. 设计视角：如何从零开始设计？

### Step 1: 信号解包

```text
与slv_if的打包相反，mst_if需要解包：

  输入: i_awch (打包的通道总线)
  输出: o_awaddr, o_awid, o_awlen, o_awsize, o_awburst, ...

解包逻辑：
  assign {o_awregion, o_awqos, o_awprot, o_awcache, o_awlock,
          o_awburst, o_awsize, o_awlen, o_awid, o_awaddr} = i_awch;

必须与slv_if的打包顺序完全一致！
```

### Step 2: 地址翻译

```text
如果KEEP_BASE_ADDR = 0：
  o_awaddr = i_awch中的地址 - BASE_ADDR

如果KEEP_BASE_ADDR = 1：
  o_awaddr = i_awch中的地址 (不变)

BASE_ADDR在实例化时通过参数传入：
  mst0: BASE_ADDR = 0x4000_0000 (DDR)
  mst1: BASE_ADDR = 0x0000_1000 (NPU RAM)
  mst2: BASE_ADDR = 0x0002_1000 (DMA CSR)
  mst3: BASE_ADDR = 0x0003_0000 (NPU CSR)
```

### Step 3: 仲裁汇聚（mst_switch）

```text
每个Slave端口实例化一个mst_switch：

  输入: 来自所有Master的请求 (awvalid[0], awvalid[1], ...)
  输出: 一个获胜者的请求连接到外部Slave

仲裁器: Round-Robin (axicb_round_robin)
  - 轮流服务每个Master
  - 无饥饿（mask-based算法）
  - 读写独立仲裁
```

### Step 4: 输出握手

```text
获胜Master的valid/ready信号连接到外部Slave：

  o_awvalid = grant_valid;        // 获胜者的valid
  获胜者的_awready = o_awready;   // 外部Slave的ready返回给获胜者

其他Master的ready = 0;           // 未获胜者等待
```

### Step 5: 验证策略

```text
1. 地址翻译：全局地址0x4000_0000 → 本地地址0x0000_0000
2. 仲裁公平：两个Master轮流访问DDR时是否公平？
3. 并发无阻塞：CPU访问DDR + DMA访问NPU RAM时是否无冲突？
4. 反压处理：DDR忙时ready=0，是否正确反压到CPU？
```

---

## 4. 设计视角：架构模式

### 模式 1: 地址翻译（Address Translation）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: 地址翻译                                           │
│                                                         │
│ 核心: 全局地址 → 本地地址 (减去基地址)                   │
│                                                         │
│ 实现:                                                    │
│   if (KEEP_BASE_ADDR)                                   │
│     o_addr = i_addr;                                    │
│   else                                                  │
│     o_addr = i_addr - BASE_ADDR;                        │
│                                                         │
│ 复用: 任何需要地址重映射的互连结构                       │
│ 例如: Crossbar、PCIe桥、内存控制器                       │
└─────────────────────────────────────────────────────────┘
```

### 模式 2: 仲裁汇聚（Arbitration Merge）

```text
┌─────────────────────────────────────────────────────────┐
│ 模式: 多对一仲裁汇聚                                     │
│                                                         │
│ 核心: 多个请求者 → 仲裁器 → 一个获胜者                   │
│                                                         │
│ 实现:                                                    │
│   - 每个请求者一个valid信号                              │
│   - 仲裁器输出grant (one-hot)                           │
│   - MUX选择获胜者的信号连接到输出                        │
│                                                         │
│ 复用: 任何多对一的资源竞争场景                           │
│ 例如: 总线仲裁、内存控制器、DMA通道                      │
└─────────────────────────────────────────────────────────┘
```

---

## 5. 本讲要点

| 要点 | 说明 |
|------|------|
| 地址翻译 | 全局地址减去基地址 → 本地地址 |
| KEEP_BASE_ADDR | =0翻译, =1保持全局地址 |
| 仲裁汇聚 | 多Master访问同一Slave时RR仲裁 |
| 读写独立 | mst_switch_wr和mst_switch_rd独立 |
| 信号解包 | 打包通道总线 → 独立AXI信号 |

---

## 6. 下节预告

下一讲深入 `axicb_round_robin_core.sv`——Crossbar的仲裁核心算法。
