# ============================================================
# 覆盖率阈值检查脚本（95%）
# 用法：vsim -c -do check_coverage_threshold.tcl
# 前提：cov_soc_tb.ucdb 已存在
# ============================================================

set ucdb_file "cov_soc_tb.ucdb"

if {![file exists $ucdb_file]} {
    puts "ERROR: $ucdb_file not found"
    quit -f
}

# 加载 UCDB
coverage load $ucdb_file

# 覆盖率阈值
set threshold 95.0
set all_pass 1

puts "=========================================="
puts " Coverage Threshold Check: >= ${threshold}%"
puts "=========================================="

# 获取整体覆盖率（所有 DU 汇总）
set cov_data [coverage report -all -zeros -local]

# 解析各维度覆盖率
# ModelSim coverage report 格式：
#   Statement: XX.XX% (N/M)
#   Branch:    XX.XX% (N/M)
#   ...
set stmt_pct  -1.0
set brch_pct  -1.0
set cond_pct  -1.0
set fsm_pct   -1.0
set tgl_pct   -1.0
set expr_pct  -1.0

foreach line [split $cov_data "\n"] {
    # 匹配 "Category: XX.XX% (covered/total)"
    if {[regexp -nocase {statement\s*:\s*([\d.]+)%} $line -> val]} {
        set stmt_pct $val
    }
    if {[regexp -nocase {branch\s*:\s*([\d.]+)%} $line -> val]} {
        set brch_pct $val
    }
    if {[regexp -nocase {condition\s*:\s*([\d.]+)%} $line -> val]} {
        set cond_pct $val
    }
    if {[regexp -nocase {fsm\s*:\s*([\d.]+)%} $line -> val]} {
        set fsm_pct $val
    }
    if {[regexp -nocase {toggle\s*:\s*([\d.]+)%} $line -> val]} {
        set tgl_pct $val
    }
    if {[regexp -nocase {expression\s*:\s*([\d.]+)%} $line -> val]} {
        set expr_pct $val
    }
}

# 打印各维度结果
puts ""
puts "  Dimension    |  Actual  | Threshold | Status"
puts "  -------------|----------|-----------|--------"

proc check_dim {name pct threshold all_pass_var} {
    upvar $all_pass_var all_pass
    if {$pct < 0} {
        puts [format "  %-13s|  N/A     |  %5.1f%%   | SKIP" $name $threshold]
        return
    }
    if {$pct >= $threshold} {
        set status "PASS"
    } else {
        set status "FAIL"
        set all_pass 0
    }
    puts [format "  %-13s|  %6.2f%% |  %5.1f%%   | %s" $name $pct $threshold $status]
}

check_dim "Statement" $stmt_pct $threshold all_pass
check_dim "Branch"    $brch_pct $threshold all_pass
check_dim "Condition" $cond_pct $threshold all_pass
check_dim "FSM"       $fsm_pct  $threshold all_pass
check_dim "Toggle"    $tgl_pct  $threshold all_pass
check_dim "Expression" $expr_pct $threshold all_pass

puts ""
puts "=========================================="
if {$all_pass} {
    puts " RESULT: PASS - All dimensions >= ${threshold}%"
} else {
    puts " RESULT: FAIL - Some dimensions below ${threshold}%"
}
puts "=========================================="

puts ""
puts "For detailed per-file report, see:"
puts "  cov_soc_tb_report.txt"
puts "  cov_soc_tb_vcover_detail.txt"

quit -f
