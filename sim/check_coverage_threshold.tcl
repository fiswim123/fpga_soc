# ============================================================
# 覆盖率阈值检查脚本
# 排除 picorv32.v 和 crossbar 内部子模块
# 用法：vsim -c -viewcov cov_soc_tb.ucdb -do check_coverage_threshold.tcl
# ============================================================

set threshold 95.0

puts "=========================================="
puts " Coverage Threshold Check: >= ${threshold}%"
puts "=========================================="
puts " Exclusions: picorv32.*, axicb_* sub-modules"
puts " Included: DMA, DDR, NPU, axi_lite2axi, crossbar_top"
puts ""

# 排除 TB
catch {coverage exclude -scope /soc_tb}

# 排除 picorv32
catch {coverage exclude -du picorv32}
catch {coverage exclude -du picorv32_regs}
catch {coverage exclude -du picorv32_pcpi_mul}
catch {coverage exclude -du picorv32_pcpi_fast_mul}
catch {coverage exclude -du picorv32_pcpi_div}
catch {coverage exclude -du picorv32_mem_router}
catch {coverage exclude -du picorv32_local_rom}
catch {coverage exclude -du picorv32_local_ram}
catch {coverage exclude -du picorv32_axi_adapter}
catch {coverage exclude -du picorv32_axi}

# 排除 crossbar 内部子模块
catch {coverage exclude -du axicb_mst_if}
catch {coverage exclude -du axicb_slv_if}
catch {coverage exclude -du axicb_switch_top}
catch {coverage exclude -du axicb_mst_switch}
catch {coverage exclude -du axicb_mst_switch_rd}
catch {coverage exclude -du axicb_mst_switch_wr}
catch {coverage exclude -du axicb_slv_switch}
catch {coverage exclude -du axicb_slv_switch_rd}
catch {coverage exclude -du axicb_slv_switch_wr}
catch {coverage exclude -du axicb_slv_ooo}
catch {coverage exclude -du axicb_pipeline}
catch {coverage exclude -du axicb_scfifo}
catch {coverage exclude -du axicb_scfifo_ram}
catch {coverage exclude -du axicb_scfifo_regfile}
catch {coverage exclude -du axicb_round_robin}
catch {coverage exclude -du axicb_round_robin_core}
catch {coverage exclude -du axicb_checker}

# 获取覆盖率
set cov_rpt [coverage report -code bcesf -zeros]
set total_pct -1.0
foreach line [split $cov_rpt "\n"] {
    if {[regexp {Total Coverage By Instance.*?:\s*([\d.]+)%} $line -> val]} {
        set total_pct $val
        break
    }
}

puts ""
if {$total_pct >= 0} {
    puts [format "  Path Coverage (bcesf): %.2f%%" $total_pct]
    puts [format "  Threshold:             %.1f%%" $threshold]
    if {$total_pct >= $threshold} {
        puts "  RESULT: PASS"
    } else {
        puts "  RESULT: FAIL"
    }
} else {
    puts "  Could not parse coverage data"
}
puts "=========================================="

quit -f
