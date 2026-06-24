transcript on

set PROJ "C:/Users/14658/Desktop/phytium_cadence/vivado_soc"

if {[string length [runStatus]]} { quit -sim }
if {![file exists work]} { vlib work }
vmap work work

# 编译 RTL（开启覆盖率）
vlog +cover=bcfst $PROJ/src/dma/inc/amba_axi_pkg.sv
vlog +cover=bcfst $PROJ/src/dma/inc/dma_utils_pkg.sv
vlog +cover=bcfst $PROJ/src/cpu/*.v
vlog +cover=bcfst $PROJ/src/axi_crossbar/*.sv
vlog +cover=bcfst $PROJ/src/dma/*.sv
vlog +cover=bcfst $PROJ/src/npu/*.sv
vlog +cover=bcfst $PROJ/src/ddr.sv
vlog +cover=bcfst $PROJ/src/soc_top.sv
vlog +cover=bcfst $PROJ/tb/soc_tb.sv

# 仿真（开启覆盖率收集，cd 到 sim 目录以匹配 testbench 相对路径）
cd ${PROJ}/sim
vsim -t 1ps -cover -L work -voptargs="+acc" soc_tb

# 运行
run -all

# 排除第三方 IP 模块（picorv32 CPU 核 + crossbar 内部逻辑）
coverage exclude -du picorv32
coverage exclude -du picorv32_regs
coverage exclude -du picorv32_pcpi_mul
coverage exclude -du picorv32_pcpi_fast_mul
coverage exclude -du picorv32_pcpi_div
coverage exclude -du picorv32_mem_router
coverage exclude -du picorv32_local_rom
coverage exclude -du picorv32_local_ram
coverage exclude -du picorv32_axi_adapter
coverage exclude -du picorv32_axi
coverage exclude -du axicb_mst_if
coverage exclude -du axicb_slv_if
coverage exclude -du axicb_switch_top
coverage exclude -du axicb_mst_switch
coverage exclude -du axicb_mst_switch_rd
coverage exclude -du axicb_mst_switch_wr
coverage exclude -du axicb_slv_switch
coverage exclude -du axicb_slv_switch_rd
coverage exclude -du axicb_slv_switch_wr
coverage exclude -du axicb_slv_ooo
coverage exclude -du axicb_pipeline
coverage exclude -du axicb_scfifo
coverage exclude -du axicb_scfifo_ram
coverage exclude -du axicb_scfifo_regfile
coverage exclude -du axicb_round_robin
coverage exclude -du axicb_round_robin_core
coverage exclude -du axicb_checker

# 输出覆盖率报告
coverage report -detail -output ${PROJ}/sim/cov_report.txt
coverage report -summary -output ${PROJ}/sim/cov_summary.txt

# 输出到控制台
puts "\n========== COVERAGE SUMMARY =========="
set fp [open "${PROJ}/sim/cov_summary.txt" r]
while {[gets fp line] >= 0} { puts $line }
close fp
puts "======================================="

quit -f
