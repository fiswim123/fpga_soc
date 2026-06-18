# NPU 设计报告 — 权重与图像数据加载及计算全流程分析

> 本文档详细分析 NPU（Neural Processing Unit）的内部数据通路，重点阐述**权重数据**和**图像数据**如何从文件加载到 NPU 内部存储，并驱动脉动阵列完成 CNN 推理计算。

---

## 1. NPU 整体架构

### 1.1 模块层次

```
npu_top                           ← 顶层，状态机控制 conv→fc 流程
├── conv_top                      ← 卷积层控制器
│   ├── npu_csr_regs              ← CSR 寄存器（CPU 通过 AXI-Lite 写入）
│   ├── rom ×3                    ← 调试用 ROM（image_data / conv1 / conv2），地址硬接零
│   ├── dmac_image_sa_writer      ← im2col DMA 引擎，将图像数据变换后写入 SA RAM
│   │   └── dmac_im2col_stream    ← 组合逻辑 im2col 变换核
│   ├── ram (image_sa_ram)        ← im2col 矩阵存储，5600行 × 320bit
│   ├── mac_array_40x32_stream    ← 40×32 脉动阵列（80 个 mm_systolic_4x4）
│   │   └── mm_systolic_4x4 ×80  ← 4×4 脉动子阵列（含偏置加 + ReLU）
│   │       └── pe ×16            ← 单个 MAC 处理单元
│   ├── ram (result_ram)          ← 卷积结果存储，1024行 × 256bit
│   ├── ram (pool_ram)            ← MaxPool 结果存储，256行 × 256bit
│   └── ppu_maxpool               ← 流式 2×2 最大池化单元
└── gap_fc_logits                 ← GAP + FC(64→10) + argmax 分类器
```

### 1.2 关键参数

| 参数 | 值 | 含义 |
|------|-----|------|
| TILE_ROWS | 40 | 每个 tile 处理的输出行数 |
| OUT_COLS | 32 | 脉动阵列列数（输出通道数/子集） |
| SUB_M | 4 | 基础脉动子阵列维度 (4×4) |
| SA_ROWS | 5600 | image_sa RAM 深度 |
| OUT_ROWS | 1024 | result RAM 深度 |
| POOL_ROWS | 256 | pool RAM 深度 |
| MAC 总数 | 1280 | 40×32 = 10×8 个 4×4 子阵列 × 16 PE |

### 1.3 网络结构

```
输入: 32×32×3 RGB 图像 (CIFAR-10)
  │
  ▼
Conv1: 5×5, 3→32ch, pad=2  → 32×32×32 → ReLU → MaxPool(2×2) → 16×16×32
  │
  ▼
Conv2: 5×5, 32→64ch, pad=2 → 16×16×64 → ReLU → MaxPool(2×2) → 8×8×64
  │
  ▼
GAP: 8×8×64 → 64 (全局平均池化)
  │
  ▼
FC: 64→10 (全连接) → argmax → 预测类别
```

---

## 2. 数据文件格式与加载机制

### 2.1 数据文件总览

| 文件 | 格式 | 行数 | 每行位宽 | 加载目标 | 加载方式 |
|------|------|------|----------|----------|----------|
| `image_data.dat` | Hex, 6字符 | 1024 | 24bit (RGB) | `image_buf[0:1023]` | `$fopen`/`$fscanf` (initial block) |
| `conv1.dat` | Hex, 64字符 | 75 | 256bit (32ch×8b) | `weight_buf[0:74]` | `$readmemh` |
| `conv2.dat` | Hex, 128字符 | 800 | 512bit (64ch×8b) | `weight2_buf[0:799]` | `$readmemh` |
| `bias1.dat` | Hex, 2字符 | 32 | 8bit | `bias_mem[0:31]` | `$readmemh` |
| `bias2.dat` | Hex, 2字符 | 64 | 8bit | `bias2_mem[0:63]` | `$readmemh` |
| `fc_weight_i8.memh` | Hex, 2字符 | 640 | 8bit | `fc_weight[0:639]` | `$readmemh` |
| `fc_bias_i8.memh` | Hex, 2字符 | 10 | 8bit | `fc_bias[0:9]` | `$readmemh` |

### 2.2 图像数据加载 (`image_data.dat`)

**文件格式**：每行一个 6 位十六进制数，表示一个 24bit RGB 像素。

```
14f9d8    ← 像素0: R=0x14, G=0xf9, B=0xd8
15f8d6    ← 像素1: R=0x15, G=0xf8, B=0xd6
...
```

**加载位置**：`dmac_im2col_stream.sv` 的 `initial` 块（非 `$readmemh`，而是 `$fopen` + `$fscanf`）。

```systemverilog
// dmac_im2col_stream.sv, line 69-86
integer fd, rc;
logic [23:0] tmp_pixel;
initial begin
    fd = $fopen(IMAGE_DATA_FILE, "r");
    for (int i = 0; i < 1024; i++) begin
        rc = $fscanf(fd, "%h", tmp_pixel);
        image_buf[i] = tmp_pixel;
    end
    $fclose(fd);
end
```

**存储结构**：`image_buf[0:1023]`，每个元素 24bit，存储 32×32×3 = 3072 字节的图像数据。实际上 1024 个条目足以覆盖 32×32=1024 个像素位置（每像素 3 字节 RGB 紧密排列在 24bit 中）。

**通道提取**：im2col 变换时，从 24bit 像素中提取各通道：
- 通道 0 (R)：`pixel[23:16]`
- 通道 1 (G)：`pixel[15:8]`
- 通道 2 (B)：`pixel[7:0]`

### 2.3 卷积权重加载

#### 2.3.1 Conv1 权重 (`conv1.dat`)

**维度**：75 行 × 256bit/行
- 75 = 3 通道 × 5 × 5 卷积核（im2col 展开后的 K 维度）
- 256bit = 32 个输出通道 × 8bit/通道

**加载**：`mac_array_40x32_stream.sv` 第 98 行：
```systemverilog
$readmemh(CONV1_FILE, weight_buf);
```

**数据排列**：`weight_buf[k]` 的 256bit 中：
```
weight_buf[k] = {w[k][31], w[k][30], ..., w[k][1], w[k][0]}
                [255:248]  [247:240]       [15:8]   [7:0]
```
其中 `w[k][ch]` 是 kernel position k 对应输出通道 ch 的 INT8 权重。

#### 2.3.2 Conv2 权重 (`conv2.dat`)

**维度**：800 行 × 512bit/行
- 800 = 32 通道 × 5 × 5 卷积核
- 512bit = 64 个输出通道 × 8bit/通道

**加载**：同上，`$readmemh(CONV2_FILE, weight2_buf)`

**两 Pass 机制**：由于 MAC 阵列只有 32 列，而 Conv2 有 64 个输出通道，需要两次 Pass：
- Pass 0：使用 `weight2_buf[k][255:0]`（通道 0–31）
- Pass 1：使用 `weight2_buf[k][511:256]`（通道 32–63）

```systemverilog
// mac_array_40x32_stream.sv, line 107
w_lane[j] = layer_sel ?
    $signed(weight2_buf[feed_count][W2_DW-1 - (out_pass*OUT_COLS+j)*8 -: 8]) :
    $signed(weight_buf[feed_count][OUT_DW-1 - j*8 -: 8]);
```

### 2.4 偏置加载

**Conv1 偏置** (`bias1.dat`)：32 个 INT8 值，对应 32 个输出通道。
```systemverilog
$readmemh(BIAS1_FILE, bias_mem);   // bias_mem[0:31]
```

**Conv2 偏置** (`bias2.dat`)：64 个 INT8 值，对应 64 个输出通道。
```systemverilog
$readmemh(BIAS2_FILE, bias2_mem);  // bias2_mem[0:63]
```

**使用位置**：`mm_systolic_4x4.sv` 中，偏置在脉动阵列输出后加到累加结果上：
```systemverilog
// mm_systolic_4x4.sv, line 135-141
bias_val = layer_sel ? bias2_vec : bias_vec;
biased_val = pe_res_i8 + bias_val;
relu_out = (relu_en && biased_val <= 0) ? 8'sd0 : sat_i8(biased_val);
```

### 2.5 FC 层权重与偏置加载

**FC 权重** (`fc_weight_i8.memh`)：640 个 INT8 值 = 10 类 × 64 通道。
```systemverilog
// gap_fc_logits.sv, line 77
$readmemh(FC_WEIGHT_FILE, fc_weight);  // fc_weight[0:639]
```

**FC 偏置** (`fc_bias_i8.memh`)：10 个 INT8 值，每类一个。
```systemverilog
// gap_fc_logits.sv, line 78
$readmemh(FC_BIAS_FILE, fc_bias);     // fc_bias[0:9]
```

**FC 权重排列**：`fc_weight[class * 64 + channel]`，先行主序（10 类为行，64 通道为列）。

---

## 3. im2col 变换 — 图像数据到脉动阵列的桥梁

### 3.1 im2col 原理

卷积运算 `Y = X * W` 通过 im2col 转换为矩阵乘法 `Y = A × B`：

```
A 矩阵 (im2col 展开):        B 矩阵 (权重):
  行 = 输出位置 (oh×ow)        行 = K²×C_in (kernel 展开)
  列 = K²×C_in (kernel展开)    列 = C_out (输出通道数)

Conv1: A = 1024 × 75,    B = 75 × 32
Conv2: A = 256 × 800,    B = 800 × 64
```

### 3.2 im2col 组合逻辑实现

`dmac_im2col_stream.sv` 中的 `get_lane_data(lane)` 函数是纯组合逻辑，零延迟完成 im2col 变换：

```systemverilog
// dmac_im2col_stream.sv, line 109-152
function automatic signed [7:0] get_lane_data(input int lane);
    int row, oh, ow, ch, kh, kw, ih, iw;
    logic signed [7:0] val;
    begin
        row = row_base + lane;              // 全局输出行索引
        oh  = row / cfg_in_w;               // 输出 H 坐标
        ow  = row % cfg_in_w;               // 输出 W 坐标
        ch  = k_idx / (cfg_kernel * cfg_kernel);  // 输入通道
        kh  = (k_idx % (cfg_kernel * cfg_kernel)) / cfg_kernel;
        kw  = k_idx % cfg_kernel;
        ih  = oh + kh - cfg_pad;            // 输入 H (含 padding)
        iw  = ow + kw - cfg_pad;            // 输入 W (含 padding)

        // 边界检查 (padding = 0)
        if (row >= cfg_in_w * cfg_in_h || ch >= cfg_in_ch ||
            ih < 0 || ih >= cfg_in_h || iw < 0 || iw >= cfg_in_w)
            val = 8'sd0;
        else if (layer_sel == 1'b0)
            val = image_pixel_channel(image_buf[ih * cfg_in_w + iw], ch);
        else
            val = pool_buf[ih * cfg_in_w + iw][255 - ch*8 -: 8];
        get_lane_data = val;
    end
endfunction
```

### 3.3 DMAC 写入流程

`dmac_image_sa_writer.sv` 控制 im2col 数据写入 `image_sa_ram`：

```
状态机: S_IDLE → S_RUN → S_DONE

S_RUN 时:
  1. 生成 issue_addr (0 到 active_sa_rows-1)
  2. 计算 row_base = (issue_addr / K_LEN) * TILE_ROWS
  3. 计算 k_idx   = issue_addr % K_LEN
  4. 发送请求给 dmac_im2col_stream
  5. im2col 组合逻辑返回 40 lane 数据 (320bit)
  6. pack_image_sa() 字节反转后写入 image_sa_ram
```

**Layer 1 参数**：
- `active_sa_rows = ceil(1024/40) × 75 = 26 × 75 = 1950`
- 每个地址产生 40 个 lane 的 im2col 数据

**Layer 2 参数**：
- `active_sa_rows = ceil(256/40) × 800 = 7 × 800 = 5600`
- 读取 `pool_buf` 而非 `image_buf`（Layer 1 的池化输出作为 Layer 2 的输入）

### 3.4 image_sa_ram 数据布局

```
image_sa_ram[row] = 320bit = 40 × 8bit

对于 tile t, kernel position k:
  地址 = t × K_LEN + k
  内容 = {lane[39], lane[38], ..., lane[1], lane[0]}
         [319:312]  [311:304]       [15:8]   [7:0]

  其中 lane[i] = input[oh_i + kh - pad][ow_i + kw - pad][ch]
        oh_i, ow_i 由 row_base + i 决定
```

---

## 4. 脉动阵列计算

### 4.1 单个 PE (Processing Element)

`pe.sv` 实现一个 MAC 单元：

```
每个时钟周期 (din_valid=1):
  acc ← acc + row_i × col_i    (INT8 × INT8 → INT32 累加)

当 mac_cnt == dot_k - 1 时:
  res ← acc + row_i × col_i    (最终结果)
  res_valid ← 1
```

**关键特性**：
- `flush` 信号清零累加器和计数器，启动新的点积
- 支持 flush 与 din_valid 同时有效（不丢失第一个 beat）

### 4.2 4×4 脉动子阵列

`mm_systolic_4x4.sv` 包含 16 个 PE，采用**时间偏斜 (skew)** 对齐：

```
行方向偏斜:
  Row 0: A 数据无延迟
  Row 1: A 数据延迟 1 周期
  Row 2: A 数据延迟 2 周期
  Row 3: A 数据延迟 3 周期

列方向偏斜:
  Col 0: W 数据无延迟
  Col 1: W 数据延迟 1 周期
  Col 2: W 数据延迟 2 周期
  Col 3: W 数据延迟 3 周期
```

这确保了 4×4 阵列中所有 16 个 PE 在同一时刻看到属于同一次乘法的数据。

### 4.3 40×32 阵列组装

```
mac_array_40x32_stream
├── Row Group 0 (rg=0): 处理行 0-3
│   ├── mm_systolic_4x4 [0][0]: 列 0-3
│   ├── mm_systolic_4x4 [0][1]: 列 4-7
│   ├── ...
│   └── mm_systolic_4x4 [0][7]: 列 28-31
├── Row Group 1 (rg=1): 处理行 4-7
│   └── ...
├── ...
└── Row Group 9 (rg=9): 处理行 36-39
    └── ...
```

**数据广播模式**：
- A 数据：同一 Row Group 内所有 Column Group 共享相同的 4 个 A 值
- W 数据：同一 Column Group 内所有 Row Group 共享相同的 4 个 W 值

```
A 广播 (行方向):     W 广播 (列方向):
  rg0 → [cg0,cg1,...,cg7]    cg0 → [rg0,rg1,...,rg9]
  rg1 → [cg0,cg1,...,cg7]    cg1 → [rg0,rg1,...,rg9]
  ...
```

### 4.4 MAC 控制状态机

```
M_IDLE → M_WAIT_DMAC → M_FEED → M_WAIT_TILE
                                    │
                                    ├── 有更多 tile → M_FEED
                                    └── 最后一个 tile → 完成

M_FEED 状态:
  每周期从 image_sa_ram 读取一行 (320bit)
  → 分解为 40 个 a_lane[0:39]
  → 同时从 weight_buf/weight2_buf 读取对应行
  → 分解为 32 个 w_lane[0:31]
  → 广播到 80 个 mm_systolic_4x4 实例
  → feed_count 从 0 递增到 DOT_K-1
```

### 4.5 后处理流水线

每个 `mm_systolic_4x4` 在点积完成后执行：

```systemverilog
// 1. 量化截断: 32bit → 8bit
pe_res_i8 = {pe_res[31], pe_res[out_shift +: 7]};

// 2. 偏置加
biased_val = pe_res_i8 + bias_val;

// 3. ReLU
relu_out = (relu_en && biased_val <= 0) ? 8'sd0 : sat_i8(biased_val);
```

**out_shift 参数**：
- Layer 1: `out_shift = 7`
- Layer 2: `out_shift = 8`

### 4.6 结果写回

MAC 阵列计算完成后，40 行结果逐行写入 `result_ram`：

```systemverilog
result_ram[base_row + i] = result_row_data;  // 256bit = 32ch × 8b
```

Layer 2 使用 `stride=2, offset=0/1` 将 64 通道分成两个 32 通道块交替存放。

---

## 5. MaxPool 池化

### 5.1 流式 2×2 最大池化

`ppu_maxpool.sv` 以流式方式处理 `result_ram` 的写入数据，无需额外读取：

```
输入流: result_ram 的写入数据 (每周期一行)

2×2 窗口滑动:
  (h,w) 偶偶 → 暂存到 left_pixel_buf
  (h,w) 偶奇 → hmax = max(暂存, 当前) → 存入 row_max_buf
  (h,w) 奇偶 → 暂存到 left_pixel_buf
  (h,w) 奇奇 → vmax = max(row_max_buf, 当前) → 写入 pool_ram
```

### 5.2 数据流

```
Layer 1:
  result_ram (32×32×32) → PPU → pool_ram (16×16×32)

Layer 2:
  result_ram (16×16×64) → PPU → pool_ram (8×8×64)
  (64ch 分两个 pass 处理，每 pass 32ch)
```

### 5.3 pool_buf 回写

池化结果同时写入 `dmac_im2col_stream` 内部的 `pool_buf[0:255]`，供下一层 im2col 使用：

```systemverilog
if (pool_wr_en) begin
    pool_buf[pool_wr_pixel] <= pool_wr_data;  // 256bit
end
```

---

## 6. GAP + FC 分类

### 6.1 GAP（全局平均池化）

`gap_fc_logits.sv` 在卷积阶段**被动累积**池化输出：

```systemverilog
// 每次 pool 写入时
if (stream_wr_en) begin
    for (lane = 0; lane < 32; lane++) begin
        if (stream_wr_addr[0])
            gap_sum[32 + lane] += sign_extend(stream_wr_data[lane]);
        else
            gap_sum[lane] += sign_extend(stream_wr_data[lane]);
    end
end
```

**启动 FC 时**：
```systemverilog
gap_feat[ch] = sat_i8(gap_sum[ch] >>> 6);  // ÷64 (8×8 空间平均)
```

### 6.2 FC 层 (64→10)

**8 级流水线树形归约**：

```
Cycle 0: S_MUL   → 64 个并行乘法: prod[i] = gap_feat[i] × fc_weight[cls*64+i]
Cycle 1: S_ADD32 → 32 个加法: sum32[i] = prod[2i] + prod[2i+1]
Cycle 2: S_ADD16 → 16 个加法
Cycle 3: S_ADD8  → 8 个加法
Cycle 4: S_ADD4  → 4 个加法
Cycle 5: S_ADD2  → 2 个加法
Cycle 6: S_ADD1  → 1 个加法: 标量 sum
Cycle 7: S_WRITE → logit = sat_i8((sum >>> 7) + fc_bias[cls])
                   argmax 更新
```

每类 8 周期 × 10 类 = ~80 周期（含状态机开销约 95 周期）。

### 6.3 预测输出

```systemverilog
// 10 个 logit 值
logit_q[0:9]

// argmax 预测
pred_class_id = argmax(logit_q)
pred_logit    = logit_q[pred_class_id]
pred_valid    = 1  (全部 10 类计算完成后)
```

---

## 7. 完整推理时序

### 7.1 Layer 1 推理

```
Phase 1: DMAC 填充 image_sa_ram
  活动行数: ceil(1024/40) × 75 = 1950 行
  耗时: ~1950 周期 (每周期写 1 行)

Phase 2: MAC 计算 (26 个 tile)
  每 tile:
    - 从 image_sa_ram 读取 75 列 → 75 周期
    - 脉动阵列计算 (含 drain) → 8 周期
    - 结果写回 result_ram (40 行) → 40 周期
    - PPU 并行处理 (与写回重叠)
  每 tile 耗时: 75 + 8 + 40 = 123 周期
  总计: 26 × 123 = 3198 周期

Layer 1 总计: 1950 + 3198 ≈ 5148 周期
```

### 7.2 Layer 2 推理

```
Phase 1: DMAC 填充 image_sa_ram
  活动行数: ceil(256/40) × 800 = 5600 行
  耗时: ~5600 周期

Phase 2: MAC 计算 (2 Pass × 7 Tile)
  每 tile:
    - 读取 800 列 → 800 周期
    - drain → 8 周期
    - 写回 40 行 → 40 周期
  每 tile: 848 周期
  总计: 2 × 7 × 848 = 11872 周期

Layer 2 总计: 5600 + 11872 ≈ 17472 周期
```

### 7.3 FC 推理

```
GAP: 0 周期 (与卷积并行累积)
FC:  10 类 × 8 周期/类 + 状态机开销 ≈ 95 周期
```

### 7.4 总计

```
Layer 1:  ~5148 周期
Layer 2: ~17472 周期
FC:         ~95 周期
─────────────────────
总计:     ~22715 周期

@100MHz → ~227 μs
@200MHz → ~114 μs
```

---

## 8. 数据流全景图

```
                        ┌──────────────────────────────────────────────────┐
                        │              image_data.dat                      │
                        │         (32×32×3 RGB, INT8)                      │
                        └──────────────────────┬───────────────────────────┘
                                               │ $fopen/$fscanf
                                               ▼
                        ┌──────────────────────────────────────────────────┐
                        │              image_buf[0:1023]                   │
                        │            (24bit/pixel, on-chip)                │
                        └──────────────────────┬───────────────────────────┘
                                               │ im2col (组合逻辑)
                                               │ get_lane_data(lane)
                                               ▼
┌───────────────┐     ┌────────────────────────────────────────────────────┐
│  conv1.dat    │────→│              image_sa_ram[0:5599]                  │
│  (75×256bit)  │     │         (320bit/行 = 40lane × 8b)                  │
└───────────────┘     └──────────────────────┬─────────────────────────────┘
       │                                      │ 每周期读 1 行
       │                                      ▼
       │            ┌────────────────────────────────────────────────────┐
       │            │          mac_array_40x32_stream                    │
       ├───────────→│  ┌─────────────────────────────────┐              │
       │            │  │  10×8 = 80 个 mm_systolic_4x4   │              │
       │            │  │  每个含 16 PE (共 1280 MAC)      │              │
       │            │  └─────────────────────────────────┘              │
       │            │  + bias add + ReLU + quantize                      │
       │            └──────────────────────┬─────────────────────────────┘
       │                                    │
       │                                    ▼
       │            ┌────────────────────────────────────────────────────┐
       │            │              result_ram[0:1023]                     │
       │            │           (256bit/行 = 32ch × 8b)                   │
       │            └──────────────────────┬─────────────────────────────┘
       │                                    │ 流式写入
       │                                    ▼
       │            ┌────────────────────────────────────────────────────┐
       │            │              ppu_maxpool                            │
       │            │           (2×2 MaxPool)                             │
       │            └──────────────────────┬─────────────────────────────┘
       │                                    │
       │                      ┌─────────────┴─────────────┐
       │                      ▼                           ▼
       │            ┌──────────────────┐    ┌──────────────────────────┐
       │            │   pool_ram       │    │   pool_buf (im2col输入)   │
       │            │  (256行×256bit)  │    │   → Layer 2 im2col 源    │
       │            └──────────────────┘    └──────────────────────────┘
       │
       │                      Layer 2 重复上述流程 (conv2.dat 权重)
       │
       │                                    │
       │                                    ▼
       │            ┌────────────────────────────────────────────────────┐
       │            │              gap_fc_logits                          │
       │            │  ┌──────────┐  ┌───────────┐  ┌───────────┐       │
       │            │  │   GAP    │→│  FC 64→10  │→│  argmax   │       │
       │            │  │ (累积)   │  │ (树形归约) │  │ (比较器)  │       │
       │            │  └──────────┘  └───────────┘  └───────────┘       │
       │            └────────────────────────────────────────────────────┘
       │                                    │
       │                                    ▼
       │                          pred_class_id + pred_logit
```

---

## 9. 存储资源汇总

| 存储 | 位宽 | 深度 | 总容量 | 用途 |
|------|------|------|--------|------|
| image_buf | 24b | 1024 | 3 KB | 原始图像像素 |
| pool_buf | 256b | 256 | 8 KB | 池化输出缓存 (Layer 2 im2col 源) |
| weight_buf | 256b | 75 | 2.4 KB | Conv1 权重 |
| weight2_buf | 512b | 800 | 50 KB | Conv2 权重 |
| bias_mem | 8b | 32 | 32 B | Conv1 偏置 |
| bias2_mem | 8b | 64 | 64 B | Conv2 偏置 |
| fc_weight | 8b | 640 | 640 B | FC 权重 |
| fc_bias | 8b | 10 | 10 B | FC 偏置 |
| image_sa_ram | 320b | 5600 | 224 KB | im2col 矩阵 |
| result_ram | 256b | 1024 | 32 KB | 卷积结果 |
| pool_ram | 256b | 256 | 8 KB | 池化结果 |
| **总计** | | | **~328 KB** | |

---

## 10. 设计特点总结

1. **全文件预加载**：所有权重和图像数据在仿真开始时通过 `$readmemh`/`$fopen` 加载到片上存储，运行时无需外部访存。

2. **组合逻辑 im2col**：im2col 变换为纯组合逻辑，零延迟完成地址计算和数据提取。

3. **权重驻留**：权重在仿真开始时加载到 `weight_buf`/`weight2_buf`，整个推理过程中保持不变（Weight Stationary）。

4. **Tile 化计算**：40 行为一个 tile，逐 tile 复用同一组权重，减少权重加载开销。

5. **流式 MaxPool**：池化与结果写回并行执行，无需额外的读-处理-写回周期。

6. **被动 GAP 累积**：GAP 求和在卷积阶段并行完成，FC 启动时仅需一次移位和饱和操作。

7. **双 Pass 扩展**：通过 `out_pass` 信号将 64 通道卷积分为两次 32 通道计算，以有限阵列宽度支持更大输出通道数。
