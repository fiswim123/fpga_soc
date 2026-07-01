# ============================================================
# wave.do — 验证报告波形截图信号列表
# 第1节(模块级仿真) 和 第2节(关键波形) 分开标注
# 仿真后按注释中的时间段缩放截图
# ============================================================

onerror {resume}
quietly WaveActivateNextPane {} 0

# ============================================================
# 全局信号 — 始终可见
# ============================================================
add wave -divider {── Global ──}
add wave -radix unsigned /soc_tb/clk
add wave -radix unsigned /soc_tb/rst


# ============================================================
#  第1节 模块级仿真
# ============================================================

# ----------------------------------------------------------
# 图1-1: CPU从ROM取指与指令执行仿真波形
#   时段: 0 ~ 3us (复位释放后CPU开始取指)
#   重点: PC连续推进, 指令读出无X态, CSR写入正确
# ----------------------------------------------------------
add wave -divider {══ 图1-1: CPU取指与指令执行 ══}
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/reg_pc
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/dbg_insn_opcode
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_rdata
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_valid
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_ready
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_instr
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_addr
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_wstrb

# ----------------------------------------------------------
# 图1-2: DMA突发搬运与AXI互联握手波形
#   时段: 3 ~ 6us (CPU配置DMA + DMA搬运期间)
#   重点: AXI-Lite CSR写入, AR/R读通道, AW/W/B写通道握手
# ----------------------------------------------------------
add wave -divider {══ 图1-2: DMA突发搬运与AXI握手 ══}
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_awaddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bready
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arlen
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_rdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rlast
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix unsigned    /soc_tb/dma_error

# ----------------------------------------------------------
# 图1-3: NPU卷积、池化、FC与预测输出波形
#   时段: 5 ~ 6us (NPU启动) + 117 ~ 118.2us (NPU输出)
#   重点: top_state转换, conv/fc done, pred_valid置位
# ----------------------------------------------------------
add wave -divider {══ 图1-3: NPU推理与预测输出 ══}
add wave -radix ascii       /soc_tb/u_soc/u_npu/top_state
add wave -radix unsigned    /soc_tb/u_soc/u_npu/img_load_start
add wave -radix unsigned    /soc_tb/u_soc/u_npu/img_load_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/conv_busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/conv_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_start
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/pred_logit

# ----------------------------------------------------------
# 图1-4: DDR到NPU RAM搬运后数据一致性波形
#   时段: 4 ~ 6us (DMA搬运期间)
#   重点: 写通道数据落点, wstrb全F, burst连续, done置位
# ----------------------------------------------------------
add wave -divider {══ 图1-4: DDR→NPU RAM数据搬运一致性 ══}
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arlen
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_rdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rlast
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_awaddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wdata
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wstrb
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wlast
add wave -radix unsigned    /soc_tb/dma_done

# ----------------------------------------------------------
# 图1-5: CPU-DMA-NPU协同推理闭环波形
#   时段: 0 ~ 120us (全景) 或分段: 0~6us + 117~118.2us
#   重点: CPU控制流 + DMA搬运 + NPU推理 全链路
# ----------------------------------------------------------
add wave -divider {══ 图1-5: SoC协同推理闭环 ══}
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/reg_pc
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_valid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rlast
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix ascii       /soc_tb/u_soc/u_npu/top_state
add wave -radix unsigned    /soc_tb/u_soc/u_npu/busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/pred_logit

# ----------------------------------------------------------
# 图1-6: DMA/CSR异常与边界场景波形
#   时段: 需要额外的边界测试用例 (当前test_cpu_dma_npu不含异常路径)
#   信号已列出, 需运行包含异常测试的soc_tb才能抓到波形
# ----------------------------------------------------------
add wave -divider {══ 图1-6: DMA异常/边界 (需额外测试) ══}
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arlen
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_awaddr
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix unsigned    /soc_tb/dma_error
add wave -radix unsigned    /soc_tb/cpu_trap


# ============================================================
#  第2节 关键仿真波形 (最终提交版)
# ============================================================

# ----------------------------------------------------------
# 图2-1: CPU ROM取指波形
#   时段: 0 ~ 3us
#   信号: PC, ROM地址, instr_data, 寄存器写回, CSR写事务
# ----------------------------------------------------------
add wave -divider {══ 图2-1: CPU ROM取指 ══}
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/reg_pc
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/dbg_insn_addr
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/dbg_insn_opcode
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_rdata
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_valid
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_instr
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_addr

# ----------------------------------------------------------
# 图2-2: DMA CSR配置波形
#   时段: 3 ~ 5us
#   信号: DMA CSR AW/W/B/AR/R, src/dst/len/start
# ----------------------------------------------------------
add wave -divider {══ 图2-2: DMA CSR配置 ══}
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_awaddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bready
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/dma_done

# ----------------------------------------------------------
# 图2-3: AXI Crossbar路由波形
#   时段: 4 ~ 6us (DMA搬运期间, 可观察slv1→mst0/mst1路由)
#   信号: CPU/DMA主端, DDR/NPU RAM从端
# ----------------------------------------------------------
add wave -divider {══ 图2-3: AXI Crossbar路由 ══}
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv0_arvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv0_arready
add wave -radix hexadecimal /soc_tb/u_soc/u_crossbar/slv0_araddr
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv1_arvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv1_arready
add wave -radix hexadecimal /soc_tb/u_soc/u_crossbar/slv1_araddr
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv1_awvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/slv1_awready
add wave -radix hexadecimal /soc_tb/u_soc/u_crossbar/slv1_awaddr
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst0_arvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst0_arready
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst0_rvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst0_rlast
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_awvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_awready
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_wvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_wready

# ----------------------------------------------------------
# 图2-4: DDR到NPU RAM搬运波形
#   时段: 4 ~ 6us
#   信号: AR/R, AW/W/B, wstrb, burst length, done
# ----------------------------------------------------------
add wave -divider {══ 图2-4: DDR→NPU RAM搬运 ══}
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arlen
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_rdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rlast
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awready
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wdata
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wstrb
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wlast
add wave -radix unsigned    /soc_tb/dma_done

# ----------------------------------------------------------
# 图2-5: NPU状态机波形
#   时段: 5 ~ 6us (启动) + 117 ~ 118.2us (完成)
#   信号: CTRL start, T_LOAD_IMG, T_WAIT_CONV, T_WAIT_FC, done
# ----------------------------------------------------------
add wave -divider {══ 图2-5: NPU状态机 ══}
add wave -radix ascii       /soc_tb/u_soc/u_npu/top_state
add wave -radix unsigned    /soc_tb/u_soc/u_npu/img_load_start
add wave -radix unsigned    /soc_tb/u_soc/u_npu/img_load_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/conv_busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/conv_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_start
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/fc_done
add wave -radix unsigned    /soc_tb/u_soc/u_npu/busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/done

# ----------------------------------------------------------
# 图2-6: NPU分类输出波形
#   时段: 117.5 ~ 118.2us
#   信号: pred_valid, pred_class_id, pred_logit, PRED CSR读回
# ----------------------------------------------------------
add wave -divider {══ 图2-6: NPU分类输出 ══}
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/pred_logit
add wave -radix unsigned    /soc_tb/u_soc/u_npu/u_fc/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/u_fc/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/u_fc/pred_logit

# ----------------------------------------------------------
# 图2-7: SoC总体验证波形
#   时段: 0 ~ 120us (全景概览)
#   信号: CPU, DMA, Crossbar, NPU关键状态合并展示
# ----------------------------------------------------------
add wave -divider {══ 图2-7: SoC总体验证 ══}
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/reg_pc
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_valid
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix unsigned    /soc_tb/dma_error
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_rlast
add wave -radix ascii       /soc_tb/u_soc/u_npu/top_state
add wave -radix unsigned    /soc_tb/u_soc/u_npu/busy
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/pred_logit


# ============================================================
#  带宽监控 (报告第5节用)
# ============================================================
add wave -divider {── Bandwidth Monitor ──}
add wave -radix unsigned    /soc_tb/dma_mon_en
add wave -radix unsigned    /soc_tb/dma_total_cycles
add wave -radix unsigned    /soc_tb/dma_data_beats
add wave -radix unsigned    /soc_tb/dma_ar_handshakes
add wave -radix unsigned    /soc_tb/dma_w_handshakes


# ============================================================
#  波形窗口配置
# ============================================================
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ps} 0}
configure wave -namecolwidth 280
configure wave -valuecolwidth 120
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {0 ps} {130 us}
