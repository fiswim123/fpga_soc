# 第二十八讲：量化训练工具链 — 从Python到硬件

---

## 课程目标

本讲详细讲解如何将PyTorch训练的浮点CNN模型，经过INT8量化、BatchNorm融合、权重导出等步骤，最终生成可供FPGA NPU硬件直接加载的`.memh`数据文件。这是连接软件训练与硬件推理的**关键桥梁**。

**学完本讲你将掌握：**

1. PyTorch模型训练流程（`train_cifar10_5x5.py`）
2. BatchNorm融合（Fold BN into Conv）的数学原理
3. INT8 pow2量化策略及其硬件友好性
4. 权重导出为`.memh`文件的完整流程
5. 软件推理验证（`infer_cifar10_int8_pow2_fused.py`）
6. 软硬件数据对齐的关键要点

---

## 1. 整体流程概览

```
  浮点训练                量化导出                硬件加载
┌──────────┐          ┌──────────────┐          ┌──────────┐
│ PyTorch  │  .pth    │ BN融合        │  .memh   │ FPGA NPU │
│ FP32训练 ├─────────►│ INT8量化      ├─────────►│ INT8推理  │
│ 100 epoch│          │ 权重导出      │          │ 脉动阵列  │
└──────────┘          └──────────────┘          └──────────┘
     │                      │                        │
     │                      │                        │
  train_               export_                   RTL中
  cifar10_             cifar10_                  $readmemh
  5x5.py               int8_pow2                 加载权重
                       _fused.py
```

**关键文件路径：**

| 文件 | 路径 | 功能 |
|------|------|------|
| 训练脚本 | `src/npu/export_cifar/train_cifar10_5x5.py` | PyTorch FP32训练 |
| 导出脚本 | `src/npu/export_cifar/export_cifar10_int8_pow2_fused.py` | BN融合+INT8量化+导出 |
| 推理验证 | `src/npu/export_cifar/infer_cifar10_int8_pow2_fused.py` | 纯NumPy INT8推理 |
| 数据格式说明 | `src/npu/export_cifar/README_INT8_FUSED_EXPORT.md` | .memh格式规范 |

---

### 设计视角：为什么这样设计？

模型量化的核心设计决策直接影响硬件推理的精度、面积和功耗。本节分析关键决策背后的工程考量。

**核心问题 1：为什么选择 INT8 而不是 FP32/FP16？**

```
  精度格式的硬件代价对比:

  ┌──────────────┬────────────┬────────────┬────────────┐
  │ 格式          │ INT8       │ FP16       │ FP32       │
  ├──────────────┼────────────┼────────────┼────────────┤
  │ 数据位宽      │ 8 bit      │ 16 bit     │ 32 bit     │
  │ 乘法器面积    │ 1× (基准)   │ ~4×        │ ~16×       │
  │ 累加器位宽    │ 32 bit     │ 32 bit     │ 64 bit     │
  │ 存储需求      │ 1×         │ 2×         │ 4×         │
  │ 带宽需求      │ 1×         │ 2×         │ 4×         │
  │ 精度损失      │ 1-3%       │ <0.5%      │ 无          │
  │ 本设计选择    │ ✓          │ ✗          │ ✗          │
  └──────────────┴────────────┴────────────┴────────────┘

  选择 INT8 的根本原因:

  1. 面积约束: FPGA 资源有限, INT8 乘法器面积仅为 FP32 的 1/16
     · 本设计 2048 个 MAC 单元
     · 若用 FP32: 2048 × 16 = 32768 个等效 MAC 的面积 → FPGA 放不下
     · 用 INT8: 2048 个 MAC → FPGA 可容纳

  2. 带宽约束: 片上 SRAM 有限, INT8 数据搬运量为 FP32 的 1/4
     · 本设计片上存储 ~256KB
     · FP32 权重: ResNet-18 约 45MB → 远超片上容量
     · INT8 权重: ResNet-18 约 11MB → 仍需分块加载, 但可行

  3. 功耗约束: INT8 动态功耗为 FP32 的 ~1/16
     · P ∝ C × V² × f, 乘法器电容 C 与位宽成正比
     · INT8 × INT8 → INT32 累加: 功耗远低于 FP32 × FP32

  4. 精度可接受: CIFAR-10 上 INT8 量化精度损失 < 3%
     · FP32: 75% → INT8: 72-73%
     · 对于边缘推理场景, 精度损失可接受
```

**核心问题 2：为什么选择 pow2（2 的整数次幂）量化？**

```
  普通量化 vs pow2 量化:

  普通量化:
    q = clamp(round(x × scale), -127, 127)
    反量化: x ≈ q / scale
    硬件实现: 需要乘法器 (q × (1/scale))

  pow2 量化:
    q = clamp(round(x × 2^exp), -127, 127)
    反量化: x ≈ q >> exp  或  q << (-exp)
    硬件实现: 仅需移位器!

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  硬件实现对比:                                          │
  │                                                         │
  │  普通量化重量化:                                        │
  │  ┌─────────────────────────────────────┐                │
  │  │  acc (INT32)                        │                │
  │  │       │                             │                │
  │  │       ▼                             │                │
  │  │  ┌──────────┐                       │                │
  │  │  │ × multiplier │ ← INT32 乘法器    │                │
  │  │  └─────┬────┘     (面积大, 延迟长)   │                │
  │  │        ▼                             │                │
  │  │  ┌──────────┐                       │                │
  │  │  │ >> shift  │                       │                │
  │  │  └─────┬────┘                       │                │
  │  │        ▼                             │                │
  │  │  INT8 输出                           │                │
  │  └─────────────────────────────────────┘                │
  │                                                         │
  │  pow2 量化重量化:                                       │
  │  ┌─────────────────────────────────────┐                │
  │  │  acc (INT32)                        │                │
  │  │       │                             │                │
  │  │       ▼                             │                │
  │  │  ┌──────────┐                       │                │
  │  │  │ >> shift  │ ← 仅需移位器         │                │
  │  │  └─────┬────┘   (面积极小, 组合逻辑) │                │
  │  │        ▼                             │                │
  │  │  ┌──────────┐                       │                │
  │  │  │ clamp     │                       │                │
  │  │  └─────┬────┘                       │                │
  │  │        ▼                             │                │
  │  │  INT8 输出                           │                │
  │  └─────────────────────────────────────┘                │
  │                                                         │
  │  面积节省: 移位器 ≈ 多路选择器 ≈ 0.1× 乘法器面积        │
  │  延迟节省: 移位器 = 1 级组合逻辑 vs 乘法器 = 3-4 级     │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

  pow2 量化的代价:
  · scale 被约束为 2 的幂, 精度略低于最优浮点 scale
  · 典型精度损失: 0.5-1% Top-1 准确率
  · 本项目可接受 (CIFAR-10: FP32 75% → INT8 pow2 72-73%)
```

**核心问题 3：为什么需要 BatchNorm 融合？**

```
  BN 融合的动机:

  训练时 (Conv + BN 分离):
    y = BN(Conv(x)) = gamma × (Conv(x) - mu) / sqrt(var + eps) + beta
    需要: 存储 Conv 权重 + BN 四组参数 (gamma, beta, mu, var)
    推理时: 每次都需要计算 BN 的归一化

  推理时 (Conv + BN 融合):
    y = Conv_fused(x) = Conv(W_fused, x) + b_fused
    其中: W_fused = W × gamma / sqrt(var + eps)
          b_fused = beta - mu × gamma / sqrt(var + eps)
    需要: 仅存储融合后的权重和偏置

  好处:
  1. 存储减少: 无需存储 BN 的 4 组参数
  2. 计算减少: 无需每次推理计算 BN 归一化
  3. 精度无损: 数学等价变换, 结果完全一致
  4. 硬件简化: NPU 只需实现 Conv + ReLU, 无需 BN 单元
```

---

### 设计视角：如何从零开始设计？

将一个 PyTorch 模型量化到 FPGA 硬件需要系统化的方法。以下是五步设计流程。

**步骤 1：训练浮点模型**

```
  训练阶段的关键决策:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  1. 网络结构设计 (与硬件对齐)                            │
  │     · 卷积核选择 5×5 (匹配脉动阵列尺寸)                 │
  │     · 使用 BN (便于后续融合)                            │
  │     · 不使用 bias=True (BN 融合后会生成 bias)           │
  │     · 使用 ReLU (硬件实现简单)                          │
  │                                                         │
  │  2. 训练超参数                                          │
  │     · 优化器: SGD + momentum (经典配置)                 │
  │     · 学习率: 0.01 + 余弦退火 (稳定收敛)                │
  │     · 数据增强: 随机裁剪 + 水平翻转 (提升泛化)          │
  │     · 归一化: CIFAR-10 标准 mean/std (量化时复用)       │
  │                                                         │
  │  3. 保存检查点                                          │
  │     · 保存 best_acc 模型 (非最后一个 epoch)             │
  │     · 保存完整 state_dict (含 BN running stats)        │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**步骤 2：BatchNorm 融合**

```
  融合实现流程:

  for each (Conv, BN) pair:
    W = conv.weight                    # Conv 权重
    gamma = bn.weight                  # BN 缩放因子
    beta = bn.bias                     # BN 偏移
    mu = bn.running_mean               # BN 均值 (训练时统计)
    var = bn.running_var               # BN 方差 (训练时统计)
    eps = bn.eps                       # 数值稳定常数 (1e-5)

    # 融合公式
    scale = gamma / sqrt(var + eps)
    W_fused = W × scale                # 权重融合
    b_fused = beta - mu × scale        # 偏置融合

  验证: 用融合后的模型重新推理, 结果应与融合前完全一致 (浮点误差 < 1e-6)
```

**步骤 3：校准激活值范围**

```
  校准流程:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  1. 加载融合后的模型                                    │
  │                                                         │
  │  2. 注册 forward hook 到每层输出                        │
  │     · Conv1 输出 → 收集激活值                           │
  │     · Conv2 输出 → 收集激活值                           │
  │     · FC 输出 → 收集激活值                              │
  │                                                         │
  │  3. 用训练集的前 N 个 batch 做前向推理                   │
  │     · N = 16 (足够统计激活范围)                         │
  │     · 不需要标签 (只做前向, 不做反向)                    │
  │                                                         │
  │  4. 对每层激活值计算百分位数                             │
  │     · 取绝对值 → 排序 → 取 99.9% 位置的值               │
  │     · 该值作为该层激活的动态范围上限                     │
  │                                                         │
  │  5. 为什么用 99.9% 而不是 100% (最大值)?                │
  │     · 激活值中存在偶发离群点 (outlier)                  │
  │     · 用最大值会拉大 scale, 导致大部分值精度下降         │
  │     · 99.9% 截断 0.1% 的离群值, 整体精度更高            │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**步骤 4：计算 pow2 量化参数**

```
  量化参数计算流程:

  for each layer:
    # 计算最优浮点 scale
    scale_float = 127 / max_abs_activation

    # 取最近的 2 的幂
    exp = round(log2(scale_float))
    scale_pow2 = 2^exp

    # 计算重量化 shift
    # input_exp: 输入层的量化指数
    # weight_exp: 权重的量化指数
    # output_exp: 输出层的量化指数
    requant_shift = input_exp + weight_exp - output_exp

  参数示例 (本设计):
  ┌──────────┬───────────┬────────────┬─────────────────┐
  │ 层        │ scale     │ exp        │ requant_shift   │
  ├──────────┼───────────┼────────────┼─────────────────┤
  │ Input    │ 32        │ 5          │ ---             │
  │ Conv1    │ 16        │ 4          │ 5+7-4 = 8      │
  │ Conv2    │ 8         │ 3          │ 4+7-3 = 8      │
  │ FC       │ 4         │ 2          │ 3+7-2 = 8      │
  └──────────┴───────────┴────────────┴─────────────────┘
```

**步骤 5：导出 .memh 文件并验证**

```
  导出与验证流程:

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  Step 5a: 量化权重和偏置                                │
  │  · 权重: clamp(round(W_fused × 2^weight_exp), -127, 127)│
  │  · 偏置: round(b_fused × 2^(input_exp + weight_exp))    │
  │  · 偏置用 INT32 (累加器域, 不截断到 INT8)              │
  │                                                         │
  │  Step 5b: 导出 .memh 文件                               │
  │  · 每行一个 hex 标量值                                  │
  │  · 负数用二进制补码表示 (如 -1 = "ff")                  │
  │  · 排列顺序: OC → IC → KH → KW (与 PyTorch 一致)       │
  │                                                         │
  │  Step 5c: 生成 manifest.json                            │
  │  · 记录每层的 scale/exp/shift/shape                    │
  │  · 记录输入预处理参数 (mean, std)                       │
  │  · 硬件加载时参考此文件配置 CSR                          │
  │                                                         │
  │  Step 5d: 软件 INT8 推理验证                            │
  │  · 用纯 NumPy 实现 INT8 推理                            │
  │  · 验证量化后精度 (与 FP32 对比)                        │
  │  · 验证与硬件推理结果一致 (RTL 仿真)                    │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

### 设计视角：架构模式与原则

模型量化到硬件中有多种可复用的模式。掌握这些可以系统化地处理量化问题。

**模式 1：训练后量化模式（Post-Training Quantization, PTQ）**

```
  核心思想: 不修改训练过程, 在训练完成后直接量化

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  PTQ 流程:                                              │
  │                                                         │
  │  FP32 训练 ──► BN 融合 ──► 校准 ──► 量化 ──► 导出      │
  │  (100 epoch)   (数学等价)   (16 batch) (INT8)  (.memh) │
  │                                                         │
  │  优点:                                                  │
  │  · 不需要重新训练 (节省时间和 GPU 资源)                  │
  │  · 实现简单 (几行 Python 代码)                          │
  │  · 适用于大多数 INT8 场景                               │
  │                                                         │
  │  缺点:                                                  │
  │  · 精度损失通常 > 量化感知训练 (QAT)                    │
  │  · 对激活值中的离群点敏感                                │
  │  · 不适用于精度敏感的场景 (如目标检测)                   │
  │                                                         │
  │  vs 量化感知训练 (QAT):                                 │
  │  QAT 在训练过程中模拟量化误差, 让模型适应量化            │
  │  QAT 精度更高, 但需要修改训练代码 + 更长训练时间         │
  │  本项目选择 PTQ: 任务简单 (CIFAR-10 分类), PTQ 足够     │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**模式 2：BN 融合模式（BatchNorm Fusion Pattern）**

```
  核心思想: 将推理时的线性变换预计算到权重中

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  融合模式通用框架:                                      │
  │                                                         │
  │  任何 "线性层 + 归一化层" 的组合都可以融合:              │
  │                                                         │
  │  · Conv + BN → Fused Conv                              │
  │  · Linear + BN → Fused Linear                          │
  │  · Conv + LayerNorm → Fused Conv (类似)                │
  │                                                         │
  │  融合公式推导:                                          │
  │                                                         │
  │  原始: y = BN(W * x + b)                               │
  │       = gamma × (W*x + b - mu) / sqrt(var + eps) + beta│
  │       = gamma/sqrt(var+eps) × W × x                    │
  │       + gamma/sqrt(var+eps) × (b - mu) + beta          │
  │                                                         │
  │  融合: W' = gamma/sqrt(var+eps) × W                    │
  │        b' = gamma/sqrt(var+eps) × (b - mu) + beta      │
  │                                                         │
  │  推理: y = W' × x + b'  (无需 BN 计算)                 │
  │                                                         │
  │  注意: BN 的 running_mean 和 running_var 必须在         │
  │  训练时正确统计 (model.eval() 模式下使用)               │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

**模式 3：软硬件协同量化模式（SW/HW Co-Quantization）**

```
  核心思想: 量化参数的计算在软件完成, 硬件只执行量化后的计算

  ┌─────────────────────────────────────────────────────────┐
  │                                                         │
  │  软件侧 (离线, Python):                                 │
  │  ├── 训练 FP32 模型                                     │
  │  ├── BN 融合                                            │
  │  ├── 校准激活范围                                       │
  │  ├── 计算 pow2 scale/exp/shift                         │
  │  ├── 量化权重 → INT8                                   │
  │  ├── 量化偏置 → INT32                                  │
  │  └── 导出 .memh + manifest.json                        │
  │                                                         │
  │  硬件侧 (在线, RTL):                                    │
  │  ├── $readmemh 加载 INT8 权重到 PE 寄存器              │
  │  ├── MAC 计算: acc += input_q × weight_q  (INT8×INT8)  │
  │  ├── 偏置加: acc += bias_q               (INT32+INT32) │
  │  ├── 重量化: out = clamp(acc >> shift, -128, 127)      │
  │  └── ReLU: out = max(out, 0)                           │
  │                                                         │
  │  对齐要求:                                              │
  │  · 软件导出的权重排列顺序 = 硬件 $readmemh 加载顺序     │
  │  · manifest.json 中的 scale/shift = 硬件 CSR 配置值    │
  │  · 输入预处理 (mean/std) = 硬件 DMAC 的预处理逻辑      │
  │                                                         │
  │  验证方法:                                              │
  │  · 软件 NumPy 推理 vs 硬件 RTL 仿真 → 结果应完全一致   │
  │  · 逐层比对中间结果, 定位量化误差来源                   │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

## 2. 模型训练（train_cifar10_5x5.py）

### 2.1 网络结构定义

目标网络是一个极简的CNN，仅使用5x5卷积核，专门为NPU硬件设计：

```
输入: 3 x 32 x 32 (CIFAR-10 RGB图像)
    │
    ▼
[Conv2d]  3→32, kernel=5x5, pad=2, bias=False
[BatchNorm2d]  32通道
[ReLU]
[MaxPool2d]    2x2, stride=2
    │  → 32 x 16 x 16
    ▼
[Conv2d]  32→64, kernel=5x5, pad=2, bias=False
[BatchNorm2d]  64通道
[ReLU]
[MaxPool2d]    2x2, stride=2
    │  → 64 x 8 x 8
    ▼
[AdaptiveAvgPool2d]  8x8 → 1x1 (GAP)
[Flatten]
[Linear]  64→10
    │
    ▼
输出: 10类 logits
```

**源码位置：** `src/npu/export_cifar/train_cifar10_5x5.py` 第22-48行

```python
# train_cifar10_5x5.py, line 22-48
class TinyCIFAR10_5x5(nn.Module):
    """A very small CIFAR-10 CNN that only uses 5x5 convolution kernels."""

    def __init__(self, num_classes=10):
        super().__init__()
        self.features = nn.Sequential(
            # 3 x 32 x 32 -> 32 x 16 x 16
            nn.Conv2d(3, 32, kernel_size=5, padding=2, bias=False),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),

            # 32 x 16 x 16 -> 64 x 8 x 8
            nn.Conv2d(32, 64, kernel_size=5, padding=2, bias=False),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(kernel_size=2, stride=2),
        )
        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool2d((1, 1)),
            nn.Flatten(),
            nn.Linear(64, num_classes),
        )
```

**为什么选择5x5卷积核？**

NPU的脉动阵列在处理卷积时，需要将卷积展开为矩阵乘法（im2col）。5x5核展开后每行25个元素（per input channel），与16x16 PE阵列的尺寸匹配良好，硬件利用率高。

### 2.2 训练超参数

```python
# train_cifar10_5x5.py, line 151-168
parser.add_argument("--epochs", type=int, default=100)
parser.add_argument("--batch-size", type=int, default=128)
parser.add_argument("--lr", type=float, default=0.01)
```

**优化器与学习率调度：**

```python
# train_cifar10_5x5.py, line 192-194
optimizer = optim.SGD(model.parameters(), lr=args.lr,
                      momentum=0.9, weight_decay=5e-4)
scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer,
                                                  T_max=args.epochs)
```

| 参数 | 值 | 说明 |
|------|-----|------|
| 优化器 | SGD | 动量=0.9, 权重衰减=5e-4 |
| 初始学习率 | 0.01 | 余弦退火衰减 |
| 训练轮数 | 100 | 典型CIFAR-10训练 |
| 批大小 | 128 | 平衡速度与显存 |

### 2.3 数据增强

```python
# train_cifar10_5x5.py, line 52-57
transform_train = transforms.Compose([
    transforms.RandomCrop(32, padding=4),
    transforms.RandomHorizontalFlip(),
    transforms.ToTensor(),
    transforms.Normalize((0.4914, 0.4822, 0.4465),
                         (0.2023, 0.1994, 0.2010)),
])
```

CIFAR-10标准归一化参数（mean和std）将在量化导出时被复用，确保软硬件数据预处理一致。

### 2.4 训练循环与检查点保存

```python
# train_cifar10_5x5.py, line 199-213
for epoch in range(args.epochs):
    train_one_epoch(model, trainloader, criterion, optimizer, device, epoch)
    acc = evaluate(model, testloader, criterion, device)
    scheduler.step()

    if acc > best_acc:
        best_acc = acc
        ckpt_path = os.path.join(args.checkpoint_dir, "tiny_cifar10_5x5.pth")
        torch.save({
            "model": model.state_dict(),
            "best_acc": best_acc,
            "epoch": epoch,
            "model_name": "TinyCIFAR10_5x5",
        }, ckpt_path)
```

保存最佳模型的`state_dict`，后续导出脚本将从此checkpoint加载权重。

**运行训练：**

```bash
cd src/npu/export_cifar
python train_cifar10_5x5.py --epochs 100 --batch-size 128
```

---

## 3. INT8量化导出（export_cifar10_int8_pow2_fused.py）

### 3.1 量化流程总览

```
checkpoint (FP32 state_dict)
    │
    ▼
┌─────────────────────────┐
│ Step 1: BN融合           │
│ Conv + BN → Fused Conv   │
│ (数学等价变换)            │
└─────────┬───────────────┘
          │
          ▼
┌─────────────────────────┐
│ Step 2: 激活值校准        │
│ 前向推理收集各层输出范围   │
│ 计算百分位数 (99.9%)      │
└─────────┬───────────────┘
          │
          ▼
┌─────────────────────────┐
│ Step 3: pow2 scale计算   │
│ scale = 2^exp (硬件友好)  │
│ 量化 = clamp(round(x*s)) │
└─────────┬───────────────┘
          │
          ▼
┌─────────────────────────┐
│ Step 4: 权重/偏置量化     │
│ weight → INT8            │
│ bias → INT32 (累加器域)   │
└─────────┬───────────────┘
          │
          ▼
┌─────────────────────────┐
│ Step 5: 导出 .memh 文件   │
│ + manifest.json          │
└─────────────────────────┘
```

### 3.2 BatchNorm融合原理

BatchNorm在推理时是一个线性变换：

```
BN(x) = gamma * (x - mu) / sqrt(var + eps) + beta
```

可以等价地融合到卷积权重中：

```
W_fused = W * gamma / sqrt(var + eps)
b_fused = beta - mu * gamma / sqrt(var + eps)
```

**源码实现：** `src/npu/export_cifar/export_cifar10_int8_pow2_fused.py` 第127-153行

```python
# export_cifar10_int8_pow2_fused.py, line 127-153
def make_fused_state_dict(state_dict, bn_eps):
    fused = OrderedDict()
    w0, b0 = fuse_conv_bn_weight(
        state_dict["features.0.weight"],      # Conv1权重
        state_dict.get("features.0.bias"),    # Conv1偏置(None)
        state_dict["features.1.weight"],       # BN1 gamma
        state_dict["features.1.bias"],         # BN1 beta
        state_dict["features.1.running_mean"], # BN1 running mean
        state_dict["features.1.running_var"],  # BN1 running var
        bn_eps,
    )
    w4, b4 = fuse_conv_bn_weight(
        state_dict["features.4.weight"],       # Conv2权重
        state_dict.get("features.4.bias"),
        state_dict["features.5.weight"],       # BN2 gamma
        state_dict["features.5.bias"],
        state_dict["features.5.running_mean"],
        state_dict["features.5.running_var"],
        bn_eps,
    )
    fused["features.0.weight"] = w0
    fused["features.0.bias"] = b0
    fused["features.4.weight"] = w4
    fused["features.4.bias"] = b4
    fused["classifier.2.weight"] = state_dict["classifier.2.weight"]
    fused["classifier.2.bias"] = state_dict["classifier.2.bias"]
    return fused
```

**融合前后对比：**

```
融合前 (推理时):
  x → Conv(w, None) → BN(gamma, beta, mu, var) → ReLU → ...
  需要: 存储Conv权重 + BN四组参数 + 每次推理计算BN

融合后 (推理时):
  x → Conv(w_fused, b_fused) → ReLU → ...
  需要: 仅存储融合后的权重和偏置，计算量等价但无BN开销
```

### 3.3 激活值校准（Calibration）

量化需要知道每层激活值的动态范围，才能选择合适的scale。

```python
# export_cifar10_int8_pow2_fused.py, line 47-78
class ActivationCollector(nn.Module):
    def __init__(self, model, max_samples_per_layer=1048576, ...):
        super().__init__()
        self.sample_counts = {"conv1": 0, "conv2": 0, "logits": 0}
        self.outputs = {"conv1": [], "conv2": [], "logits": []}
        self.handles = [
            model.features[1].register_forward_hook(self._save("conv1")),
            model.features[4].register_forward_hook(self._save("conv2")),
            model.classifier[2].register_forward_hook(self._save("logits")),
        ]
```

**校准流程：**

```
1. 加载融合后的模型
2. 注册forward hook到Conv1输出、Conv2输出、FC输出
3. 用训练集的前16个batch做前向推理 (calib_batches=16)
4. 收集各层输出的绝对值
5. 取99.9百分位数作为该层的动态范围上限
```

### 3.4 pow2量化策略

**为什么选择pow2（2的整数次幂）scale？**

```
普通量化:  q = clamp(round(x * scale), -127, 127)
           其中 scale = 127 / max_abs

pow2量化:  q = clamp(round(x * 2^exp), -127, 127)
           其中 exp = round(log2(127 / max_abs))

硬件优势:
  普通乘法:  result = x * scale   → 需要乘法器
  pow2乘法:  result = x << exp    → 仅需移位器！面积省10倍+
```

**源码实现：** `src/npu/export_cifar/export_cifar10_int8_pow2_fused.py` 第85-99行

```python
# export_cifar10_int8_pow2_fused.py, line 85-99
def pow2_scale_from_tensor(tensor, percentile):
    values = tensor.detach().cpu().abs().reshape(-1).to(torch.float32)
    if values.numel() == 0:
        return 1.0, 0
    if percentile >= 100.0:
        ref = values.max().item()
    else:
        sorted_values, _ = torch.sort(values)
        index = int(round((percentile / 100.0) * (sorted_values.numel() - 1)))
        ref = sorted_values[index].item()
    if ref < 1e-12:
        return 1.0, 0
    scale = 127.0 / ref          # 计算最优scale
    exp = int(round(torch.log2(torch.tensor(scale)).item()))  # 取最近的2的幂
    return float(2.0**exp), exp
```

**量化精度损失分析：**

```
假设 max_abs = 5.3, percentile = 99.9%

最优scale = 127 / 5.3 = 23.96
pow2 scale = 2^5 = 32 (或 2^4 = 16, 取最近)

选择 2^5 = 32:
  有效范围 = 127/32 = 3.97  (截断了3.97~5.3的部分, ~0.1%样本)
  精度 = 1/32 = 0.03125

选择 2^4 = 16:
  有效范围 = 127/16 = 7.94  (完全覆盖, 但精度降低)
  精度 = 1/16 = 0.0625

通常选择更大的exp以保证覆盖率，牺牲少量精度。
```

### 3.5 权重与偏置量化

```python
# export_cifar10_int8_pow2_fused.py, line 102-108
def quantize_int8_tensor(tensor, scale):
    return torch.clamp(
        torch.round(tensor.detach().cpu().to(torch.float64) * scale),
        -127, 127
    ).to(torch.int32)

def quantize_bias_int32_tensor(tensor, input_scale, weight_scale):
    scale = float(input_scale) * float(weight_scale)
    return torch.round(tensor.detach().cpu().to(torch.float64) * scale).to(torch.int32)
```

**偏置量化的关键点：**

偏置在硬件中与卷积累加器相加，因此需要量化到累加器域（INT32）：

```
硬件计算流程:
  acc = sum(input_q * weight_q)        # INT8 x INT8 → INT32 累加
  acc_bias = acc + bias_q              # INT32 + INT32
  output = clamp(acc_bias >> shift, -128, 127)  # 重量化到INT8

偏置量化:
  bias_q = round(bias_float * input_scale * weight_scale)
```

### 3.6 重量化（Requantization）计算

每层输出后需要将INT32累加结果截断回INT8，这通过移位实现：

```python
# export_cifar10_int8_pow2_fused.py, line 292
shift = int(input_exp + weight_exp - output_exp)
```

**数学推导：**

```
浮点等式:
  y_float = sum(x_float * w_float) + b_float

量化后:
  x_q = round(x_float * 2^input_exp)
  w_q = round(w_float * 2^weight_exp)
  b_q = round(b_float * 2^(input_exp + weight_exp))

累加:
  acc = sum(x_q * w_q) + b_q
    ≈ sum(x_float * w_float) * 2^(input_exp + weight_exp) + b_float * 2^(input_exp + weight_exp)
    = (sum(x_float * w_float) + b_float) * 2^(input_exp + weight_exp)
    = y_float * 2^(input_exp + weight_exp)

重量化:
  y_q = clamp(acc >> shift, -128, 127)
  其中 shift = input_exp + weight_exp - output_exp

  y_q ≈ y_float * 2^output_exp  (正确量化到输出域)
```

### 3.7 导出文件格式

导出的`.memh`文件每行一个十六进制标量值，使用二进制补码表示：

```python
# export_cifar10_int8_pow2_fused.py, line 111-124
def int_to_twos_hex(value, bits):
    ivalue = int(value)
    if ivalue < 0:
        ivalue = (1 << bits) + ivalue
    return f"{ivalue & ((1 << bits) - 1):0{bits // 4}x}"

def write_memh(path, tensor, bits):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    flat = tensor.detach().cpu().reshape(-1).tolist()
    with open(path, "w", encoding="ascii") as f:
        for value in flat:
            f.write(int_to_twos_hex(value, bits))
            f.write("\n")
```

**输出目录结构：**

```
cifar10_int8_pow2_fused/
├── conv1_weight_i8.memh       # 32×3×5×5 = 2400 个 INT8
├── conv1_bias_acc_i32.memh    # 32 个 INT32
├── conv2_weight_i8.memh       # 64×32×5×5 = 51200 个 INT8
├── conv2_bias_acc_i32.memh    # 64 个 INT32
├── fc_weight_i8.memh          # 10×64 = 640 个 INT8
├── fc_bias_acc_i32.memh       # 10 个 INT32
└── manifest.json              # scale/shift/shape元信息
```

### 3.8 manifest.json 结构

```json
{
  "model": "TinyCIFAR10_5x5_int8_pow2_bn_fused",
  "quant_mode": "signed_int8_pow2_shift_only",
  "input_preprocess": {
    "layout": "NCHW_RGB",
    "shape": [3, 32, 32],
    "mean": [0.4914, 0.4822, 0.4465],
    "std": [0.2023, 0.1994, 0.2010],
    "quant": "q = clamp(round(((pixel/255 - mean) / std) * input_scale), -127, 127)"
  },
  "scales": {
    "input": {"scale": 32.0, "exp": 5},
    "conv1": {"scale": 16.0, "exp": 4},
    "conv2": {"scale": 8.0, "exp": 3},
    "logits": {"scale": 4.0, "exp": 2}
  },
  "layers": [
    {
      "name": "conv1",
      "weight_shape": [32, 3, 5, 5],
      "bias_shape": [32],
      "weight_scale_exp": 7,
      "requant_shift": 8,
      "relu": true
    },
    ...
  ]
}
```

---

## 4. 软件INT8推理验证（infer_cifar10_int8_pow2_fused.py）

### 4.1 推理引擎架构

推理脚本用纯NumPy实现完整的INT8推理流程，验证量化精度：

```
输入: .memh文件 (INT8图像 + INT8权重 + INT32偏置)
    │
    ▼
┌─────────────────────────────┐
│  Conv2D (im2col + GEMM)      │
│  acc = input_q @ weight_q.T  │
│  out = clamp((acc+bias)>>s)  │
│  out = max(out, 0)  (ReLU)   │
└─────────┬───────────────────┘
          │
          ▼
┌─────────────────────────────┐
│  MaxPool 2x2                 │
│  取2×2窗口最大值              │
└─────────┬───────────────────┘
          │
          ▼
┌─────────────────────────────┐
│  Conv2D + ReLU + MaxPool     │
│  (同上结构)                   │
└─────────┬───────────────────┘
          │
          ▼
┌─────────────────────────────┐
│  GAP (全局平均池化)           │
│  sum >> 6  (÷64)             │
└─────────┬───────────────────┘
          │
          ▼
┌─────────────────────────────┐
│  FC (全连接)                  │
│  acc = input @ weight.T      │
│  out = clamp((acc+bias)>>s)  │
└─────────┬───────────────────┘
          │
          ▼
      argmax → 预测类别
```

### 4.2 im2col实现

```python
# infer_cifar10_int8_pow2_fused.py, line 70-76
def im2col_nchw(x, kh, kw, pad, stride):
    x_pad = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)),
                   mode="constant")
    win = np.lib.stride_tricks.sliding_window_view(
        x_pad, (kh, kw), axis=(2, 3))
    win = win[:, :, ::stride, ::stride, :, :]
    n, c, out_h, out_w, _, _ = win.shape
    cols = win.transpose(0, 2, 3, 1, 4, 5).reshape(
        n * out_h * out_w, c * kh * kw)
    return cols.astype(np.int32), out_h, out_w
```

**im2col变换示意：**

```
原始输入: [N, C, H, W]
卷积核:   [OC, IC, KH, KW]

im2col展开:
  输入矩阵 A: [N*OH*OW, IC*KH*KW]  ← 每行是一个卷积窗口
  权重矩阵 B: [OC, IC*KH*KW]        ← 每行是一个输出通道的权重

矩阵乘法:
  Output = A @ B.T  →  [N*OH*OW, OC]
```

### 4.3 重量化实现

```python
# infer_cifar10_int8_pow2_fused.py, line 55-67
def apply_shift(arr, shift):
    out = arr.astype(np.int64)
    if shift >= 0:
        return out >> shift
    return out << (-shift)

def requantize(acc, bias, shift, relu):
    out = apply_shift(acc.astype(np.int64) + bias.astype(np.int64),
                      int(shift))
    out = np.clip(out, -128, 127).astype(np.int32)
    if relu:
        out = np.maximum(out, 0)
    return out.astype(np.int32)
```

### 4.4 完整推理流程

```python
# infer_cifar10_int8_pow2_fused.py, line 130-138
def infer_batch(images_q, layers):
    x = images_q.astype(np.int32)
    x = conv2d_int8(x, layers["conv1"]["weight"], layers["conv1"]["bias"],
                    layers["conv1"]["shift"], True)
    x = maxpool2x2(x)
    x = conv2d_int8(x, layers["conv2"]["weight"], layers["conv2"]["bias"],
                    layers["conv2"]["shift"], True)
    x = maxpool2x2(x)
    x = avgpool8x8_shift(x)
    logits = linear_int8(x, layers["fc"]["weight"], layers["fc"]["bias"],
                         layers["fc"]["shift"], False)
    return logits.astype(np.int32)
```

**运行推理验证：**

```bash
cd src/npu/export_cifar

# 单张图片推理
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8-dir cifar10_image_int8 \
  --image-index 0

# 批量推理计算准确率
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8-dir cifar10_image_int8
```

---

## 5. 软硬件数据对齐

### 5.1 权重排列顺序

软件导出的权重排列顺序必须与硬件`$readmemh`加载的顺序完全一致：

```
conv1_weight_i8.memh:
  shape = [32, 3, 5, 5]
  排列 = out_channel → in_channel → kernel_y → kernel_x

  线性地址 = (((oc * 3 + ic) * 5 + ky) * 5 + kx)

  等价于 PyTorch weight.reshape(-1) 的flatten顺序
```

```
fc_weight_i8.memh:
  shape = [10, 64]
  排列 = out_feature → in_feature

  addr = out_feature * 64 + in_feature
```

### 5.2 图像数据排列

```
输入图像 .memh:
  shape = [3, 32, 32]  (CHW, RGB)
  排列 = channel → row → col

  addr = (channel * 32 + row) * 32 + col

  channel 0 = R, channel 1 = G, channel 2 = B
```

### 5.3 硬件加载代码对应

在RTL中，权重通过`$readmemh`直接加载到存储器数组：

```verilog
// NPU权重加载 (简化示意)
$readmemh("conv1_weight_i8.memh", weight_buf);    // 2400个INT8
$readmemh("conv1_bias_acc_i32.memh", bias_mem);   // 32个INT32
$readmemh("fc_weight_i8.memh", fc_weight);        // 640个INT8
$readmemh("fc_bias_i8.memh", fc_bias);            // 10个INT32
```

**对齐检查清单：**

```
[x] 权重shape: PyTorch [OC, IC, KH, KW] → .memh flatten顺序一致
[x] 偏置shape: [OC] → 每行一个INT32
[x] 图像shape: [C, H, W] → CHW排列
[x] 数值范围: INT8 ∈ [-127, 127], INT32无截断
[x] 补码表示: 负数用二进制补码hex (如 -1 = "ff")
[x] scale/shift: manifest.json中的值与硬件CSR配置匹配
```

---

## 6. 硬件推理时的量化计算映射

### 6.1 NPU脉动阵列执行流程

```
硬件每层计算:

1. 权重预加载:
   $readmemh → weight_buf (PE内部寄存器驻留)

2. 输入数据流:
   image_sa_ram → 脉动阵列左端输入

3. MAC累加:
   PE[row][col].psum += input_q * weight_q   (INT8×INT8 → INT32)

4. 偏置加:
   result = psum + bias_q                     (INT32 + INT32)

5. 重量化 (移位):
   result_shifted = result >> requant_shift    (INT32 → INT8)

6. ReLU:
   output = max(result_shifted, 0)

7. 结果写回:
   output → result_ram
```

### 6.2 移位器 vs 乘法器

```
方案A: 通用乘法器
  output = (acc * multiplier) >> shift
  需要: INT32乘法器 (面积大, 延迟长)

方案B: pow2移位 (本设计采用)
  output = acc >> requant_shift
  需要: 移位器 (面积极小, 组合逻辑1级)

  ┌─────────────────────────────────────┐
  │  INT32 累加器 acc                    │
  │         │                           │
  │         ▼                           │
  │  ┌─────────────┐                    │
  │  │  >> shift    │  ← 移位器 (仅需    │
  │  │  (或 << -s)  │     多路选择器)     │
  │  └──────┬──────┘                    │
  │         │                           │
  │         ▼                           │
  │  ┌─────────────┐                    │
  │  │ clamp(-128,  │  ← 饱和截断       │
  │  │       127)   │                    │
  │  └──────┬──────┘                    │
  │         │                           │
  │         ▼                           │
  │  ┌─────────────┐                    │
  │  │ ReLU (可选)  │  ← max(0, x)      │
  │  └──────┬──────┘                    │
  │         │                           │
  │         ▼                           │
  │  INT8 输出                           │
  └─────────────────────────────────────┘
```

---

## 7. 关键知识点总结

| 知识点 | 说明 |
|--------|------|
| BN融合 | Conv+BN数学等价变换，减少推理计算量 |
| pow2量化 | scale=2^exp，硬件仅需移位器，面积省10倍+ |
| 校准(Calibration) | 用少量数据统计激活范围，确定量化参数 |
| 偏置INT32 | 偏置在累加器域量化，与MAC结果直接相加 |
| 重量化 | 通过移位将INT32累加结果截断回INT8 |
| .memh格式 | 每行一个hex标量，二进制补码，与$readmemh兼容 |
| 软硬件对齐 | 权重/图像排列顺序必须一致，否则推理结果错误 |

---

## 8. 动手练习

### 练习1：运行训练并观察收敛

```bash
cd src/npu/export_cifar
python train_cifar10_5x5.py --epochs 20 --batch-size 128
```

**任务：** 记录每5个epoch的训练准确率和测试准确率，绘制学习曲线。观察余弦退火调度器的效果。

### 练习2：分析量化精度损失

```bash
# 导出不同percentile的量化结果
python export_cifar10_int8_pow2_fused.py \
  --checkpoint checkpoint/tiny_cifar10_5x5.pth \
  --act-percentile 99.9

python export_cifar10_int8_pow2_fused.py \
  --checkpoint checkpoint/tiny_cifar10_5x5.pth \
  --act-percentile 99.99

# 分别推理对比准确率
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8-dir cifar10_image_int8
```

**任务：** 对比percentile=99.9和99.99的INT8推理准确率，分析精度差异原因。

### 练习3：验证软硬件数据一致性

**任务：** 编写Python脚本，读取`conv1_weight_i8.memh`文件，验证：
1. 总行数是否为2400（32×3×5×5）
2. 所有值是否在[-127, 127]范围内
3. 与PyTorch导出的权重是否一致（逐元素比对）

### 练习4：理解requant_shift的物理含义

**任务：** 对于conv1层，假设：
- `input_exp = 5` (input_scale = 2^5 = 32)
- `weight_exp = 7` (weight_scale = 2^7 = 128)
- `output_exp = 4` (conv1_scale = 2^4 = 16)

计算`requant_shift`，并解释为什么shift=8意味着"除以256"。

---

## 9. 常见问题

**Q1: 为什么权重范围用100%百分位，激活用99.9%百分位？**

权重是固定的，可以用最大值确保无截断。激活值有偶发离群点（outlier），用99.9%可以避免极少数异常值拉大scale导致大部分值精度下降。

**Q2: pow2量化会损失多少精度？**

典型情况下pow2量化比最优浮点scale损失0.5-1%的Top-1准确率。对于CIFAR-10这种小数据集，FP32约75% → INT8 pow2约72-73%。

**Q3: 为什么偏置用INT32而不是INT8？**

偏置直接加到INT32累加器上，如果截断到INT8会丢失大量精度。INT32偏置可以精确表示累加器域的偏移量。

**Q4: .memh文件中"ff"代表什么？**

"ff"是8位二进制补码的-1（256-1=255=0xff）。同理"80"代表-128，"7f"代表+127。

---

## 下一讲预告

[第二十九讲：低功耗设计 — 理论与实践](lecture_29_low_power.md) 将讲解FPGA SoC中的时钟门控、动态频率调整和电源门控技术，以及脉动阵列天然的低功耗特性。
