# INT8 融合导出与推理说明


```text
PyTorch checkpoint
-> 融合 BatchNorm 到 Conv
-> 导出 INT8 pow2 权重与 INT32 accumulator bias
-> 导出 INT8 图片输入
-> 使用导出的权重和图片数据做 INT8 推理
```

## 1. 导出融合后的 INT8 权重

```bash
python export_cifar10_int8_pow2_fused.py \
  --checkpoint checkpoint/tiny_cifar10_5x5.pth \
  --out-dir cifar10_int8_pow2_fused
```

输出目录：

```text
cifar10_int8_pow2_fused/
├── conv1_weight_i8.memh      # 32 x 3 x 5 x 5 = 2,400 int8  = 2,400 bytes
├── conv1_bias_acc_i32.memh   # 32 int32                  = 128 bytes
├── conv2_weight_i8.memh      # 64 x 32 x 5 x 5 = 51,200 int8 = 51,200 bytes
├── conv2_bias_acc_i32.memh   # 64 int32                  = 256 bytes
├── fc_weight_i8.memh         # 10 x 64 = 640 int8        = 640 bytes
├── fc_bias_acc_i32.memh      # 10 int32                  = 40 bytes
└── manifest.json             # scale、shift、shape、文件名等元信息
```

导出时会融合：

```text
features.0 Conv + features.1 BatchNorm -> conv1
features.4 Conv + features.5 BatchNorm -> conv2
classifier.2 Linear -> fc
```

## 2. 导出 INT8 图片输入

导出 CIFAR-10 test 第 0 张图片：

```bash
python export_cifar10_image_int8.py \
  --asset-dir cifar10_int8_pow2_fused \
  --data-dir data \
  --index 0 \
  --out-dir cifar10_image_int8
```

批量导出 10 张：

```bash
python export_cifar10_image_int8.py \
  --asset-dir cifar10_int8_pow2_fused \
  --data-dir data \
  --start-index 0 \
  --count 10 \
  --out-dir cifar10_image_int8
```

导出普通 RGB 图片：

```bash
python export_cifar10_image_int8.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image your_image.png \
  --out-dir cifar10_image_int8
```

输出目录示例：

```text
cifar10_image_int8/
├── test_00000_nchw_i8.memh
├── test_00001_nchw_i8.memh
├── images_q_i8.memh
└── manifest.json
```

## 3. 使用导出数据做推理

使用目录 manifest 中列出的全部 INT8 图片：

```bash
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8-dir cifar10_image_int8
```

推理第 0 张导出图片：

```bash
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8-dir cifar10_image_int8 \
  --image-index 0
```

直接指定单个 INT8 图片文件：

```bash
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --image-int8 cifar10_image_int8/test_00000_nchw_i8.memh
```

## 4. 量化规则

所有 scale 都约束为 2 的整数次幂：

```text
scale = 2^exp
```

浮点到 INT8：

```text
q = clamp(round(x * scale), -127, 127)
```

图片输入量化：

```text
x_float = (pixel / 255 - mean) / std
image_q = clamp(round(x_float * input_scale), -127, 127)
```

CIFAR-10 归一化参数：

```text
mean = [0.4914, 0.4822, 0.4465]
std  = [0.2023, 0.1994, 0.2010]
```

每层后处理：

```text
acc = dot(input_q, weight_q)
acc_bias = acc + bias_acc
q_out = clamp(acc_bias >> requant_shift, -128, 127)
```

如果 `requant_shift < 0`，表示左移 `-requant_shift` 位。

`conv1` 和 `conv2` 后接 ReLU：

```text
q_out = max(q_out, 0)
```

`fc` 不接 ReLU，输出 `10` 个 INT8 logits，直接 `argmax`。

## 5. 权重数据格式

所有 `.memh` 默认都是：

```text
每行一个 scalar
低地址在文件前面
高地址在文件后面
```

### conv1_weight_i8.memh

来源：

```text
features.0 Conv + features.1 BatchNorm 融合后权重
```

shape：

```text
[32, 3, 5, 5]
```

排序：

```text
out_channel major
  in_channel
    kernel_y
      kernel_x
```

也就是最内层先变 `kernel_x`，然后 `kernel_y`，然后 `in_channel`，最后 `out_channel`。

线性地址：

```text
addr = (((out_channel * in_channels + in_channel) * kernel_h + kernel_y) * kernel_w + kernel_x)
```

对 `conv1_weight_i8.memh`：

```text
in_channels = 3
kernel_h = 5
kernel_w = 5

addr = (((oc * 3 + ic) * 5 + ky) * 5 + kx)
```

等价 PyTorch flatten 顺序：

```python
weight.reshape(-1)
```

即：

```text
W[0][0][0][0], W[0][0][0][1], ..., W[0][0][4][4],
W[0][1][0][0], ...,
W[31][2][4][4]
```

每行一个 int8，二进制补码 hex：

```text
00
7f
80
ff
```

分别表示：

```text
0, 127, -128, -1
```

### conv1_bias_acc_i32.memh

shape：

```text
[32]
```

排序：

```text
bias[0], bias[1], ..., bias[31]
```

线性地址：

```text
addr = out_channel
```

每行一个 int32 accumulator bias，二进制补码 hex，8 个 hex 字符。

### conv2_weight_i8.memh

来源：

```text
features.4 Conv + features.5 BatchNorm 融合后权重
```

shape：

```text
[64, 32, 5, 5]
```

排序：

```text
out_channel major
  in_channel
    kernel_y
      kernel_x
```

即 PyTorch 原始权重 `[out, in, kh, kw]` 的连续 flatten 顺序。

也就是最内层先变 `kernel_x`，然后 `kernel_y`，然后 `in_channel`，最后 `out_channel`。

线性地址：

```text
in_channels = 32
kernel_h = 5
kernel_w = 5

addr = (((oc * 32 + ic) * 5 + ky) * 5 + kx)
```

### conv2_bias_acc_i32.memh

shape：

```text
[64]
```

排序：

```text
bias[0], bias[1], ..., bias[63]
```

线性地址：

```text
addr = out_channel
```

每行一个 int32 accumulator bias。

### fc_weight_i8.memh

来源：

```text
classifier.2 Linear
```

shape：

```text
[10, 64]
```

排序：

```text
out_feature major
  in_feature
```

也就是先存第 0 个输出类别对应的 64 个输入权重，再存第 1 个输出类别，以此类推。

线性地址：

```text
in_features = 64

addr = out_feature * 64 + in_feature
```

即：

```text
W[0][0], W[0][1], ..., W[0][63],
W[1][0], ...,
W[9][63]
```

推理时计算：

```text
acc[class] = sum(input_q[i] * W[class][i])
```

### fc_bias_acc_i32.memh

shape：

```text
[10]
```

排序：

```text
bias[0], bias[1], ..., bias[9]
```

线性地址：

```text
addr = out_feature
```

每行一个 int32 accumulator bias。

## 6. 图片数据格式

单张图片文件：

```text
test_00000_nchw_i8.memh
```

shape：

```text
[3, 32, 32]
```

layout：

```text
CHW_RGB
```

排序：

```text
channel major
  row
    col
```

也就是先通道，再行，再列。最内层先变 `col`，然后 `row`，最后 `channel`。

线性地址：

```text
height = 32
width = 32

addr = (channel * 32 + row) * 32 + col
```

通道编号：

```text
channel 0 = R
channel 1 = G
channel 2 = B
```

即：

```text
R[0][0], R[0][1], ..., R[31][31],
G[0][0], G[0][1], ..., G[31][31],
B[0][0], B[0][1], ..., B[31][31]
```

每行一个 int8，二进制补码 hex。

多张图片合并文件：

```text
images_q_i8.memh
```

shape：

```text
[N, 3, 32, 32]
```

排序：

```text
image major
  channel
    row
      col
```

也就是先图片编号，再通道，再行，再列。

线性地址：

```text
channels = 3
height = 32
width = 32

addr = (((image_index * 3 + channel) * 32 + row) * 32 + col)
```

即第 0 张完整 CHW 后，接第 1 张完整 CHW。

## 7. 推理中间数据排布

推理脚本内部使用 NCHW 排布：

```text
batch
  channel
    row
      col
```

### conv1 输出

卷积后：

```text
[N, 32, 32, 32]
```

池化后：

```text
[N, 32, 16, 16]
```

### conv2 输出

卷积后：

```text
[N, 64, 16, 16]
```

池化后：

```text
[N, 64, 8, 8]
```

### 全局平均池化输入到 FC

`64 x 8 x 8` 经过平均池化后得到 `64` 个输入特征：

```text
fc_input[channel] = sum(feature[channel][0..7][0..7]) >> 6
```

FC 输入排序：

```text
channel 0, channel 1, ..., channel 63
```

## 8. manifest.json 说明

权重目录中的 `manifest.json` 记录：

```text
input_scale
conv1/conv2/fc weight_scale_exp
conv1/conv2/fc requant_shift
weight shape
bias shape
weight file
bias file
```

图片目录中的 `manifest.json` 记录：

```text
图片文件列表
每张图片 shape
layout
label
input_scale
归一化 mean/std
```

硬件侧建议以 `manifest.json` 为准读取 scale、shift、shape 和文件名。
