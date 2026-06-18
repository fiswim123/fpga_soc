set worklib [format "work_%s" [clock seconds]]
vlib $worklib
vmap work $worklib

vlog -sv -svinputport=compat -f filelist.f

vsim -voptargs=+acc tb_conv_top

view wave
add wave -divider TB
add wave -radix unsigned sim:/tb_conv_top/clk
add wave -radix unsigned sim:/tb_conv_top/rst_n
add wave -radix unsigned sim:/tb_conv_top/csr_wr_en
add wave -radix hexadecimal sim:/tb_conv_top/csr_addr
add wave -radix hexadecimal sim:/tb_conv_top/csr_wdata
add wave -radix unsigned sim:/tb_conv_top/busy
add wave -radix unsigned sim:/tb_conv_top/done
add wave -radix unsigned sim:/tb_conv_top/dbg_sa_rd_en
add wave -radix unsigned sim:/tb_conv_top/dbg_sa_rd_addr
add wave -radix hexadecimal sim:/tb_conv_top/dbg_sa_rd_data

add wave -divider DUT
add wave -radix unsigned sim:/tb_conv_top/dut/dmac_ram_wr
add wave -radix unsigned sim:/tb_conv_top/dut/dmac_ram_waddr
add wave -radix hexadecimal sim:/tb_conv_top/dut/dmac_ram_wdata
add wave -radix unsigned sim:/tb_conv_top/dut/u_dmac/state
add wave -radix unsigned sim:/tb_conv_top/dut/u_dmac/issue_addr
add wave -radix unsigned sim:/tb_conv_top/dut/u_dmac/row_base
add wave -radix unsigned sim:/tb_conv_top/dut/u_dmac/k_idx

set NoQuitOnFinish 1
onbreak {resume}
run 2ms
