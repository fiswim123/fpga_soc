transcript on

if {[string length [runStatus]]} { quit -sim }
if {![file exists work]} { vlib work }
vmap work work

# 编译 RTL（开启覆盖率）
vlog +cover=bcfst ../src/dma/inc/amba_axi_pkg.sv
vlog +cover=bcfst ../src/dma/inc/dma_utils_pkg.sv
vlog +cover=bcfst ../src/cpu/*.v
vlog +cover=bcfst ../src/axi_crossbar/*.sv
vlog +cover=bcfst ../src/dma/*.sv
vlog +cover=bcfst ../src/npu/*.sv
vlog +cover=bcfst ../src/ddr.sv
vlog +cover=bcfst ../src/soc_top.sv
vlog +cover=bcfst ../tb/soc_tb.sv

# 仿真（开启覆盖率收集）
vsim -t 1ps -cover -L work -voptargs="+acc" soc_tb

# 运行
run -all

# 输出覆盖率报告
coverage report -detail -file cov_report.txt
coverage report -summary -file cov_summary.txt

# 输出到控制台
puts "\n========== COVERAGE SUMMARY =========="
set fp [open cov_summary.txt r]
while {[gets fp line] >= 0} { puts $line }
close fp
puts "======================================="

quit -f
