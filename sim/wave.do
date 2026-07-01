# ============================================================
# wave.do — 验证报告波形截图信号列表
# 按图号分组，仿真后缩放到对应时间段即可截图
# ============================================================

onerror {resume}
quietly WaveActivateNextPane {} 0

# ------------------------------------------------------------
# 全局时钟/复位
# ------------------------------------------------------------
add wave -divider {Global}
add wave -radix unsigned /soc_tb/clk
add wave -radix unsigned /soc_tb/rst

# ------------------------------------------------------------
# 图1-1 / 图2-1: CPU ROM取指
#   关注: 复位释放后 PC 从 0 开始取指，instr_rdata 读出指令
# ------------------------------------------------------------
add wave -divider {CPU ROM Fetch (图1-1/2-1)}
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/reg_pc
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/dbg_insn_addr
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/dbg_insn_opcode
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_rdata
add wave -radix hexadecimal /soc_tb/u_soc/u_cpu/picorv32_core/mem_rdata_latched
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_valid
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_ready
add wave -radix unsigned    /soc_tb/u_soc/u_cpu/picorv32_core/mem_instr

# ------------------------------------------------------------
# 图1-2 / 图2-2: DMA CSR配置
#   关注: CPU 通过 AXI-Lite 写 DMA CSR (src/dst/len/go)
# ------------------------------------------------------------
add wave -divider {DMA CSR Config (图1-2/2-2)}
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_awready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_awaddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wready
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_wdata
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bvalid
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_bready
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix unsigned    /soc_tb/dma_error

# ------------------------------------------------------------
# 图1-2 / 图2-3: AXI Crossbar 路由
#   关注: slv0(CPU) slv1(DMA) 到 mst0(DDR) mst1(NPU RAM) 的路由
# ------------------------------------------------------------
add wave -divider {AXI Crossbar Routing (图1-2/2-3)}
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
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_awvalid
add wave -radix unsigned    /soc_tb/u_soc/u_crossbar/mst1_awready
add wave -radix hexadecimal /soc_tb/u_soc/u_crossbar/mst1_awaddr

# ------------------------------------------------------------
# 图1-4 / 图2-4: DDR → NPU RAM 搬运
#   关注: DMA 读通道 (AR/R) 和写通道 (AW/W/B)
# ------------------------------------------------------------
add wave -divider {DDR to NPU RAM Transfer (图1-4/2-4)}
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
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_wlast
add wave -radix unsigned    /soc_tb/dma_done

# ------------------------------------------------------------
# 图1-3 / 图2-5: NPU 状态机
#   关注: top_state 转换 T_IDLE → T_LOAD_IMG → T_WAIT_CONV → T_WAIT_FC → T_IDLE
# ------------------------------------------------------------
add wave -divider {NPU FSM (图1-3/2-5)}
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

# ------------------------------------------------------------
# 图1-3 / 图2-6: NPU 分类输出
#   关注: pred_valid 置位, class_id, logit
# ------------------------------------------------------------
add wave -divider {NPU Prediction (图1-3/2-6)}
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/pred_logit
add wave -radix hexadecimal /soc_tb/u_soc/u_npu/u_fc/pred_valid
add wave -radix unsigned    /soc_tb/u_soc/u_npu/u_fc/pred_class_id
add wave -radix decimal     /soc_tb/u_soc/u_npu/u_fc/pred_logit

# ------------------------------------------------------------
# 图1-5 / 图2-7: SoC 总体验证 (合并关键状态)
# ------------------------------------------------------------
add wave -divider {SoC Overview (图1-5/2-7)}
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
add wave -radix unsigned    /soc_tb/cpu_trap

# ------------------------------------------------------------
# 图1-6: 异常/边界 (需要额外测试用例，此处为 DMA abort 信号)
# ------------------------------------------------------------
add wave -divider {DMA Robustness (图1-6)}
add wave -radix hexadecimal /soc_tb/u_soc/dma_axi_araddr
add wave -radix unsigned    /soc_tb/u_soc/dma_axi_arlen
add wave -radix unsigned    /soc_tb/dma_done
add wave -radix unsigned    /soc_tb/dma_error

# ------------------------------------------------------------
# 带宽监控
# ------------------------------------------------------------
add wave -divider {Bandwidth Monitor}
add wave -radix unsigned    /soc_tb/dma_mon_en
add wave -radix unsigned    /soc_tb/dma_total_cycles
add wave -radix unsigned    /soc_tb/dma_data_beats
add wave -radix unsigned    /soc_tb/dma_ar_handshakes
add wave -radix unsigned    /soc_tb/dma_w_handshakes

# ------------------------------------------------------------
# 图4 (FPGA): 以下信号在综合后由 Vivado ILA 抓取，不在 ModelSim 中
#   图4-1 FPGA原型系统结构图 — 手绘框图
#   图4-2 FPGA综合资源与时序 — Vivado 报告截图
#   图4-3 FPGA板级ILA波形 — Vivado ILA 抓取
# ------------------------------------------------------------

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
