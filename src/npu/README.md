# NPU (Neural Processing Unit) - CIFAR-10 图像分类硬件加速器

一个基于SystemVerilog的神经网络处理单元(NPU)实现，专门用于CIFAR-10图像分类任务。该项目采用脉动阵列架构，支持INT8量化推理，包含完整的RTL设计、验证环境和软件工具链。

## 项目概述

本项目实现了一个完整的CNN推理加速器，具有以下特点：

- **双层卷积网络**：支持两层卷积层，每层后接最大池化
- **全连接分类器**：GAP（全局平均池化）+ 全连接层输出10类分类结果
- **脉动阵列架构**：40×32 MAC阵列，支持高效矩阵运算
- **INT8量化**：全链路INT8推理，减少计算和存储开销
- **流式处理**：支持流式数据传输，减少内存访问
- **CSR接口**：通过控制状态寄存器进行配置和状态读取

## 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                         npu_top                             │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   conv_top   │    │ gap_fc_logits│    │  npu_csr   │     │
│  │  (卷积层)    │───▶│  (全连接层)  │    │  (寄存器)   │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                  │                  │             │
│         ▼                  ▼                  ▼             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ mac_array_   │    │  ppu_maxpool │    │  ram/rom    │     │
│  │ 40x32_stream │    │  (池化层)    │    │  (存储器)   │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

## 文件结构

```
phytium_cadence/npu/
├── RTL设计文件/
│   ├── npu_top.sv              # 顶层模块
│   ├── conv_top.sv             # 卷积层顶层
│   ├── mac_array_40x32_stream.sv # 40×32 MAC阵列
│   ├── mm_systolic_4x4.sv      # 4×4脉动阵列单元
│   ├── pe.sv                   # 处理单元(PE)
│   ├── gap_fc_logits.sv        # GAP+全连接+argmax
│   ├── ppu_maxpool.sv          # 最大池化层
│   ├── npu_csr_regs.sv         # CSR寄存器接口
│   ├── npu_dmac_frontend.sv    # DMA控制器前端
│   ├── dmac_im2col_stream.sv   # Im2col流式转换
│   ├── dmac_image_sa_writer.sv # 图像SA写入器
│   ├── dmac_tile_scheduler.sv  # Tile调度器
│   ├── ram.sv                  # RAM模块
│   └── rom.sv                  # ROM模块
├── 验证文件/
│   ├── tb_npu_top.sv           # 顶层测试平台
│   ├── tb_conv_top.sv          # 卷积层测试平台
│   └── sim/                    # 仿真目录
│       ├── run_npu_top_wave.do # ModelSim波形脚本
│       ├── run.do              # 基础仿真脚本
│       ├── filelist.f          # 文件列表
│       └── run_npu_top_image_batch.py # 批量测试脚本
├── 数据文件/
│   ├── image_data.dat          # 图像数据
│   ├── image.dat               # Im2col图像数据
│   ├── conv1.dat               # 第一层卷积权重
│   ├── conv2.dat               # 第二层卷积权重
│   ├── bias1.dat               # 第一层偏置
│   ├── bias2.dat               # 第二层偏置
│   └── export_cifar/           # CIFAR-10导出工具
│       ├── cifar10_int8_pow2_fused/      # INT8权重
│       ├── cifar10_int8_pow2_fused_bias_i8/ # INT8偏置
│       └── *.py                # Python训练导出脚本
└── 文档/
    ├── docs/fc_layer_changes.md # 全连接层改动说明
    └── README.md               # 本文件
```

## 快速开始

### 1. 环境要求

- **ModelSim**：2020.4或更高版本
- **Python**：3.8+（用于训练和导出）
- **PyTorch**：1.8+（用于模型训练）

### 2. 仿真运行

#### 基础仿真（命令行模式）

```bash
# 进入仿真目录
cd sim

# 编译设计
vlog -sv -f filelist.f

# 运行仿真
vsim -c tb_npu_top -do "run -all; quit"
```

#### 波形仿真（GUI模式）

```bash
# 进入仿真目录
cd sim

# 编译设计
vlog -sv -f filelist.f

# 启动ModelSim并加载波形脚本
vsim -do run_npu_top_wave.do
```

#### 批量测试

```bash
# 先编译一次
cd sim
vlog -sv -f filelist.f
cd ..

# 运行批量测试（测试10张图像）
python sim/run_npu_top_image_batch.py --count 10 --timeout 180
```

### 3. 预期输出

成功的仿真将显示：

```
[LOGITS] 3 -4 -6 32 -10 12 15 -12 -1 -19
[PRED] class_id=3 logit=32

===== PASS: npu_top final pool RAM and 10 logits match reference =====
```

## 详细设计说明

### 1. 卷积层架构

#### 第一层卷积 (conv1)
- **输入**：32×32×3 RGB图像
- **权重**：32个5×5卷积核
- **输出**：28×28×32特征图
- **池化**：2×2最大池化，输出14×14×32

#### 第二层卷积 (conv2)
- **输入**：14×14×32特征图
- **权重**：64个5×5卷积核
- **输出**：10×10×64特征图
- **池化**：2×2最大池化，输出5×5×64

### 2. MAC阵列设计

采用40×32的脉动阵列架构：

```verilog
// 10×8个4×4脉动阵列实例
// 每个时钟周期处理40个A值和32通道权重行
mac_array_40x32_stream #(
    .TILE_ROWS(40),    // 40行
    .OUT_COLS(32),     // 32列
    .SUB_M(4)          // 4×4子阵列
) u_mac_array (...);
```

### 3. 全连接层实现

GAP（全局平均池化）+ 全连接层：

```verilog
// GAP计算：64个通道，每通道8×8=64个值取平均
gap_i8[channel] = sat_i8(gap_sum[channel] >>> 6);

// FC计算：64输入 × 10输出
dot[class] = sum(gap_i8[ch] * fc_weight_i8[class][ch])
logit_i8 = sat_i8((dot[class] >>> 7) + fc_bias_i8[class])
```

### 4. CSR寄存器映射

| 地址 | 名称 | 描述 |
|------|------|------|
| 0x00 | REG_CTRL | 控制寄存器（bit0: 启动） |
| 0x04 | REG_STATUS | 状态寄存器 |
| 0x08 | REG_SHAPE0 | 形状寄存器0 |
| 0x0c | REG_SHAPE1 | 形状寄存器1 |
| 0x10 | REG_TILE | Tile寄存器 |
| 0x20 | REG_PRED | 预测结果 |
| 0x24 | REG_LOGIT0 | Logit 0-3 |
| 0x28 | REG_LOGIT1 | Logit 4-7 |
| 0x2c | REG_LOGIT2 | Logit 8-9 |

### 5. 数据流

```
图像输入 → Im2col → 卷积计算 → 池化 → GAP → 全连接 → Argmax → 分类结果
```

## Python工具链

### 1. 模型训练

```bash
cd export_cifar

# 训练CIFAR-10模型
python train_cifar10_5x5.py
```

### 2. INT8量化导出

```bash
# 导出融合BatchNorm的INT8权重
python export_cifar10_int8_pow2_fused.py \
  --checkpoint checkpoint/tiny_cifar10_5x5.pth \
  --out-dir cifar10_int8_pow2_fused

# 导出INT8图像数据
python export_cifar10_image_int8.py \
  --asset-dir cifar10_int8_pow2_fused \
  --data-dir data \
  --index 0 \
  --out-dir cifar10_image_int8
```

### 3. 推理验证

```bash
# 运行INT8推理验证
python infer_cifar10_int8_pow2_fused.py \
  --asset-dir cifar10_int8_pow2_fused \
  --data-dir data
```

## 性能指标

### 1. 时序性能

- **时钟频率**：100MHz（10ns周期）
- **卷积延迟**：约276μs（27672个周期）
- **全连接延迟**：约950ns（95个周期）
- **总推理时间**：约277μs

### 2. 资源占用

- **MAC单元**：40×32 = 1280个INT8乘法器
- **存储器**：约5600行权重存储
- **寄存器**：约1024行结果存储

### 3. 精度指标

- **量化精度**：INT8（权重和激活）
- **分类精度**：80%（10张测试图像）
- **输出格式**：10类logit值 + argmax预测

## 波形调试建议

重点观察信号：

```verilog
// 顶层状态机
/tb_npu_top/dut/top_state
/tb_npu_top/dut/fc_start
/tb_npu_top/dut/fc_done

// 卷积层
/tb_npu_top/dut/u_conv/state
/tb_npu_top/dut/u_conv/tile_valid

// 全连接层
/tb_npu_top/dut/u_fc/state
/tb_npu_top/dut/u_fc/class_idx
/tb_npu_top/dut/u_fc/gap_sum
/tb_npu_top/dut/u_fc/logit_q

// 预测结果
/tb_npu_top/dut/pred_valid
/tb_npu_top/dut/pred_class_id
/tb_npu_top/dut/pred_logit
```

## 设计特点

### 1. 流式处理架构
- 采用流式数据传输，减少内存访问
- 支持流水线处理，提高吞吐量

### 2. 模块化设计
- 清晰的模块层次结构
- 良好的接口定义和参数化

### 3. 验证完备
- 完整的测试平台
- 自动化批量测试
- 详细的日志输出

### 4. 可扩展性
- 参数化设计，支持不同配置
- 易于集成到更大系统

## 常见问题

### Q: 仿真失败怎么办？
A: 检查以下几点：
1. 确保所有数据文件存在
2. 检查ModelSim版本兼容性
3. 查看仿真日志中的错误信息

### Q: 如何修改网络参数？
A: 修改以下文件：
1. `npu_top.sv`中的参数定义
2. `conv_top.sv`中的卷积参数
3. `gap_fc_logits.sv`中的全连接参数

### Q: 如何添加新的层？
A: 参考现有模块结构：
1. 创建新的RTL模块
2. 在`npu_top.sv`中实例化
3. 更新CSR寄存器映射
4. 添加相应的测试平台

## 参考文献

1. CIFAR-10数据集：https://www.cs.toronto.edu/~kriz/cifar.html
2. 脉动阵列架构：Google TPU论文
3. INT8量化：TensorRT量化指南

## 许可证

本项目仅供学习和研究使用。

## 联系方式

如有问题，请通过GitHub Issues反馈。