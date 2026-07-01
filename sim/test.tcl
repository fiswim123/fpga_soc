transcript on

if {[string length [runStatus]]} { quit -sim }
if {![file exists work]} { vlib work }
vmap work work

vlog  ../src//dma/inc/amba_axi_pkg.sv
vlog  ../src/dma/inc/dma_utils_pkg.sv
vlog ../src/cpu/*.v
vlog ../src/axi_crossbar/*.sv
vlog ../src/dma/*.sv
vlog ../src/npu/*.sv
vlog ../src/ddr.sv
vlog ../src/soc_top.sv
vlog ../tb/soc_tb.sv

set rnd_seed [clock seconds]
puts "SEED=$rnd_seed"

vsim -t 1ps -L work +SEED=$rnd_seed -voptargs="+acc" soc_tb

source wave.do

run -all

puts "Simulation stopped. GUI stays open."
