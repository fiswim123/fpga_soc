transcript on

# 关闭已有仿真实例（如果有）
if {[string length [runStatus]]} {
    quit -sim
}

# 库（统一用 work）
if {![file exists work]} {
    vlib work
}
vmap work work

# 编译
vlog  ../src//dma/inc/amba_axi_pkg.sv
vlog  ../src/dma/inc/dma_utils_pkg.sv
vlog ../src/cpu/*.v
vlog ../src/axi_crossbar/*.sv
vlog ../src/dma/*.sv
vlog ../src/npu/*.sv
vlog ../src/ddr.sv
vlog ../tb/soc_tb.sv

# 随机种子
set rnd_seed [clock seconds]
puts "SEED=$rnd_seed"

# 启动仿真（GUI）
vsim -t 1ps -L work +SEED=$rnd_seed -voptargs="+acc" soc_tb

# 波形
add wave -r /*

# 运行到TB中的$stop
run -all

puts "Simulation stopped. GUI stays open."