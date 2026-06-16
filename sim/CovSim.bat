@echo off
REM ============================================================
REM soc_tb 覆盖率仿真一键脚本
REM 用法：CovSim.bat
REM ============================================================
echo ==========================================
echo  soc_tb Coverage Simulation
echo ==========================================

REM 启动 ModelSim GUI 仿真（带覆盖率）
vsim -do ./cov_soc_tb.tcl

REM 仿真结束后用 vcover 生成报告
if exist cov_soc_tb.ucdb (
    echo.
    echo ==========================================
    echo  Post-sim: generating vcover reports
    echo ==========================================
    vcover report -details cov_soc_tb.ucdb > cov_soc_tb_vcover_detail.txt
    vcover report cov_soc_tb.ucdb > cov_soc_tb_vcover_summary.txt
    echo Reports:
    echo   cov_soc_tb_vcover_detail.txt
    echo   cov_soc_tb_vcover_summary.txt
    echo.
    echo ==========================================
    echo  Checking 95%% threshold...
    echo ==========================================
    vsim -c -do check_coverage_threshold.tcl
) else (
    echo ERROR: UCDB file not found - simulation may have failed
)

echo.
echo Done.
pause
