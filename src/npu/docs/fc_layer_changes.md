# 全连接层改动说明

本文档记录当前工程中为了接入 CIFAR-10 最后一层全连接分类器所做的 RTL、验证脚本和运行方式更改。核心原则是：`conv_top` 仍然保持卷积/池化子系统边界，完整网络由新增 `npu_top` 串接 `conv_top` 和 `gap_fc_logits`。

## 1. 总体结构

完整网络入口改为 `npu_top.sv`：

```text
CSR start
   |
   v
conv_top
   |
   | final_pool_wr_en/final_pool_wr_addr/final_pool_wr_data
   v
gap_fc_logits
   |
   +--> dbg_logit_rd_data[7:0]
   +--> pred_valid / pred_class_id / pred_logit
```

`conv_top.sv` 不负责全连接计算。它只在第二层最终池化结果写入 pool RAM 时额外导出一组写流信号，供 `gap_fc_logits` 同步累加 GAP。这样 FC 不需要在卷积结束后重新读 128 行 pool RAM，节省了读取时间。

## 2. 新增和修改的文件

### 新增 `npu_top.sv`

`npu_top` 是完整网络顶层，实例化：

- `conv_top u_conv`
- `gap_fc_logits u_fc`

顶层状态机：

```text
T_IDLE -> T_WAIT_CONV -> T_WAIT_FC -> T_IDLE
```

行为：

- CSR 写 `REG_CTRL[0] = 1` 后启动 `conv_top`。
- `conv_done` 拉高后，`npu_top` 给 FC 一个周期的 `fc_start`。
- `fc_done` 拉高后，`npu_top.done` 输出一个完成脉冲。
- `busy = conv_busy || fc_busy || top_state != T_IDLE`。

新增输出：

- `dbg_logit_rd_en`
- `dbg_logit_rd_addr[3:0]`
- `dbg_logit_rd_data[7:0]`
- `pred_valid`
- `pred_class_id[3:0]`
- `pred_logit[7:0]`

其中 `dbg_logit_rd_data` 是 10 个 int8 logit 的调试读口，地址范围是 `0..9`。`pred_*` 是 FC 末尾硬件 argmax 的结果。现在同一份结果也已经接入 `npu_csr_regs.sv`，可以通过 CSR 地址读取。

### 修改 `conv_top.sv`

`conv_top` 增加最终池化写流输出：

```systemverilog
output logic final_pool_wr_en,
output logic [POOL_AW-1:0] final_pool_wr_addr,
output logic [OUT_DW-1:0] final_pool_wr_data
```

输出来源是已有 pool 写口：

```systemverilog
final_pool_wr_en   = ppu_pool_wr && layer2_final_pool_phase;
final_pool_wr_addr = ppu_pool_waddr;
final_pool_wr_data = ppu_pool_wdata;
```

这些端口只在第二层最终 `8x8x64` pool 写入时有效。`conv_top` 的 CSR、debug RAM、内部状态机和卷积/池化职责没有改成 FC 顶层。

同时 `conv_top` 增加了一组结果输入，只用于把 `npu_top` 中 FC/argmax 的结果送进已有 CSR 模块：

```systemverilog
input logic result_valid,
input logic [3:0] result_class_id,
input logic [7:0] result_logit,
input logic [79:0] result_logits_flat
```

这组信号不参与卷积计算，只作为 CSR 读数据源。

### 新增 `gap_fc_logits.sv`

`gap_fc_logits` 是 GAP + FC + argmax 模块。输入是 `conv_top` 导出的最终 pool 写流。

参数：

```systemverilog
parameter string FC_WEIGHT_FILE = "export_cifar/cifar10_int8_pow2_fused/fc_weight_i8.memh"
parameter string FC_BIAS_FILE   = "export_cifar/cifar10_int8_pow2_fused_bias_i8/fc_bias_i8.memh"
parameter int CHANNELS = 64
parameter int OUT_CLASSES = 10
parameter int LANES = 32
parameter int FC_SHIFT = 7
```

权重和 bias 通过 `$readmemh` 读取：

- `fc_weight_i8.memh`：`10 x 64` int8，展平后一行一个 8-bit hex。
- `fc_bias_i8.memh`：`10` 个 int8 bias，来自新的 bias-i8 工具链。

模块额外导出打包后的 10 个 logit：

```systemverilog
output logic [(OUT_CLASSES*8)-1:0] logits_flat
```

打包规则是：

```text
logits_flat[0*8 +: 8] -> class 0 logit
logits_flat[1*8 +: 8] -> class 1 logit
...
logits_flat[9*8 +: 8] -> class 9 logit
```

## 3. Conv 到 FC 的数据格式

卷积层给全连接层的数据是最终 pool2 特征图：

```text
8 x 8 x 64, int8
```

它通过 256-bit 写流传出，每拍 32 个 channel：

```text
addr = (ph * 8 + pw) * 2 + pass
pass = 0 -> ch0..31
pass = 1 -> ch32..63
```

在 256-bit word 内：

```text
[255:248] -> 当前 pass 的第 0 个 channel
[247:240] -> 当前 pass 的第 1 个 channel
...
[7:0]     -> 当前 pass 的第 31 个 channel
```

`gap_fc_logits` 根据 `stream_wr_addr[0]` 判断当前写流属于低 32 个 channel 还是高 32 个 channel。

## 4. GAP 实现

GAP 不再等卷积完成后读 RAM，而是在最终 pool 写流到达时直接累加：

```systemverilog
gap_sum[channel] += final_pool_value;
```

每个 channel 一共累加 `8 x 8 = 64` 个 int8 值。卷积完成、FC 启动时生成 GAP 特征：

```text
gap_i8[channel] = sat_i8(gap_sum[channel] >>> 6)
```

这里 `>>> 6` 等价于除以 64，使用算术右移，保留符号。

## 5. FC 计算逻辑

当前 FC 的数学语义是：

```text
dot[class]  = sum(gap_i8[ch] * fc_weight_i8[class][ch]), ch=0..63
logit_i8   = sat_i8((dot[class] >>> 7) + fc_bias_i8[class])
```

最终输出是 int8 logit，不是 int32 accumulator。

### 时序流水加法树

FC 每次计算一个 class，10 个 class 顺序计算。单个 class 内部使用 64 个并行乘法器和寄存器分级加法树：

```text
S_MUL    : 64 个 int8 x int8 乘法，生成 64 个 32-bit product
S_ADD32  : 64 -> 32
S_ADD16  : 32 -> 16
S_ADD8   : 16 -> 8
S_ADD4   : 8 -> 4
S_ADD2   : 4 -> 2
S_ADD1   : 2 -> 1
S_WRITE  : 右移、加 bias、饱和、写 logit、更新 argmax
```

因此一个 class 约 8 个周期，10 个 class 约 80 个周期。加上启动、结束等状态，当前从卷积结束到完整网络 `done` 的仿真测量约为：

```text
950 ns = 95 cycles, clk = 10 ns
```

## 6. Argmax 输出

`gap_fc_logits` 在 `S_WRITE` 写每个 logit 时同步更新当前最大值：

```text
best_class_id
best_logit
```

当最后一个 class 写完后输出：

```text
pred_valid    = 1
pred_class_id = argmax(logit_q[0..9])
pred_logit    = logit_q[pred_class_id]
```

`npu_top` 将这三个信号直接暴露到顶层。

## 7. CSR 结果寄存器

最终结果已经接入 `npu_csr_regs.sv`。原有控制寄存器保持不变：

```text
0x00 REG_CTRL
0x04 REG_STATUS
0x08 REG_SHAPE0
0x0c REG_SHAPE1
0x10 REG_TILE
```

新增结果寄存器：

```text
0x20 REG_PRED
0x24 REG_LOGIT0
0x28 REG_LOGIT1
0x2c REG_LOGIT2
```

`REG_PRED` 格式：

```text
bit  0      : result_valid
bits 11:8   : pred_class_id
bits 23:16  : pred_logit[7:0]
bits 31:24  : pred_logit sign extension
```

`REG_LOGIT0` 格式：

```text
bits  7:0   : logit0
bits 15:8   : logit1
bits 23:16  : logit2
bits 31:24  : logit3
```

`REG_LOGIT1` 格式：

```text
bits  7:0   : logit4
bits 15:8   : logit5
bits 23:16  : logit6
bits 31:24  : logit7
```

`REG_LOGIT2` 格式：

```text
bits  7:0   : logit8
bits 15:8   : logit9
bits 31:16  : 0
```

这些 logit 都是 int8 二补码。软件读取后如果要当有符号数使用，需要按 8-bit signed 解释。

## 8. Testbench 和批量测试

### `tb_npu_top.sv`

新增完整网络 testbench，验证内容包括：

- 第一层/第二层卷积相关 golden。
- 最终 `8x8x64` pool RAM。
- GAP golden。
- 10 个 int8 logit。
- 硬件 `pred_*` 是否等于 testbench 对 logit 做 argmax 的结果。
- 通过 CSR 地址 `0x20/0x24/0x28/0x2c` 读回结果并比较。

运行：

```powershell
cd C:\Code\npu(1)\npu\sim
vlog -sv -f filelist.f
vsim -c tb_npu_top -do "run -all; quit"
```

期望输出包含：

```text
[LOGITS] ...
[PRED] class_id=... logit=...
===== PASS: npu_top final pool RAM and 10 logits match reference =====
```

### `sim/run_npu_top_image_batch.py`

该脚本自动替换根目录下：

- `image_data.dat`
- `image.dat`

然后循环运行 `tb_npu_top`。用于多张 CIFAR-10 图像的 RTL 推理统计。

推荐流程是先手动编译一次：

```powershell
cd C:\Code\npu(1)\npu\sim
vlog -sv -f filelist.f
cd ..
python .\sim\run_npu_top_image_batch.py --count 10 --timeout 180
```

当前 10 张图的已测结果：

```text
Simulation PASS: 10/10
RTL predicted accuracy: 80.000% (8/10)
```

## 9. 波形观察建议

如果要看 FC 波形，建议打开：

```powershell
cd C:\Code\npu(1)\npu\sim
vsim -voptargs=+acc tb_npu_top
```

重点加这些信号：

```text
/tb_npu_top/dut/top_state
/tb_npu_top/dut/fc_start
/tb_npu_top/dut/fc_done
/tb_npu_top/dut/final_pool_wr_en
/tb_npu_top/dut/final_pool_wr_addr
/tb_npu_top/dut/u_fc/state
/tb_npu_top/dut/u_fc/class_idx
/tb_npu_top/dut/u_fc/gap_sum
/tb_npu_top/dut/u_fc/gap_feat
/tb_npu_top/dut/u_fc/prod_stage
/tb_npu_top/dut/u_fc/sum32_stage
/tb_npu_top/dut/u_fc/sum16_stage
/tb_npu_top/dut/u_fc/sum8_stage
/tb_npu_top/dut/u_fc/sum4_stage
/tb_npu_top/dut/u_fc/sum2_stage
/tb_npu_top/dut/u_fc/sum1_stage
/tb_npu_top/dut/u_fc/logit_q
/tb_npu_top/dut/u_conv/u_csr/result_valid
/tb_npu_top/dut/u_conv/u_csr/result_class_id
/tb_npu_top/dut/u_conv/u_csr/result_logit
/tb_npu_top/dut/u_conv/u_csr/result_logits_flat
/tb_npu_top/dut/pred_valid
/tb_npu_top/dut/pred_class_id
/tb_npu_top/dut/pred_logit
```

## 10. 当前实现特点

- `conv_top` 仍是卷积/池化边界。
- `npu_top` 是完整网络入口。
- FC 输入是最终 pool2 的 `8x8x64 int8`。
- GAP 使用写流同步累加，减少卷积结束后的额外读 RAM 时间。
- FC 使用 64 个并行乘法器和时序流水加法树。
- 输出 logit 是 int8。
- 顶层已经暴露 10 个 logit 调试读口和最终 argmax 预测结果。
- 最终结果已经接入 `npu_csr_regs.sv`，可通过 CSR 读取。
