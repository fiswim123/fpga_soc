# ============================================================
# soc_tb 覆盖率测试脚本
# 排除 picorv32.v 后检查路径覆盖率
# 用法：vsim -c -do ./cov_soc_tb.tcl
# ============================================================
transcript on
set StdStopFinish 1

if {[string length [runStatus]]} { quit -sim }
if {![file exists work]} { vlib work }
vmap work work

puts "=========================================="
puts " Compiling with coverage instrumentation"
puts "=========================================="

vlog -cover bcestf ../src/dma/inc/amba_axi_pkg.sv
vlog -cover bcestf ../src/dma/inc/dma_utils_pkg.sv
vlog -cover bcestf ../src/cpu/*.v
vlog -cover bcestf ../src/axi_crossbar/*.sv
vlog -cover bcestf ../src/dma/*.sv
vlog -cover bcestf ../src/npu/*.sv
vlog -cover bcestf ../src/ddr.sv
vlog -cover bcestf ../src/soc_top.sv
vlog -cover bcestf ../tb/soc_tb.sv

set rnd_seed [clock seconds]
puts "SEED=$rnd_seed"

vsim -c -t 1ps -L work \
     +SEED=$rnd_seed \
     -voptargs="+acc=bcelnprsuv" \
     -coverage \
     soc_tb

coverage save -onexit cov_soc_tb.ucdb

puts "=========================================="
puts " Running simulation..."
puts "=========================================="
run -all

puts "\n=========================================="
puts " Generating reports..."
puts "=========================================="

# 完整报告
coverage report -output cov_soc_tb_report.txt -details -all -zeros

puts "Full report: cov_soc_tb_report.txt"
puts "UCDB: cov_soc_tb.ucdb"
puts ""
puts "Post-sim analysis: run check_coverage_threshold.tcl"

quit -f
