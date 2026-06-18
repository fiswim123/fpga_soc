vlib work
vlog -sv -f filelist.f
vsim -voptargs=+acc tb_npu_top

add wave -divider TB
add wave -r sim:/tb_npu_top/*

add wave -divider NPU_TOP
add wave -r sim:/tb_npu_top/dut/*

add wave -divider FC
add wave -r sim:/tb_npu_top/dut/u_fc/*

run -all