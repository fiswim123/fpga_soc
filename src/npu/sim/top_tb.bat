@echo off
cd /d "%~dp0"

D:\modeltech64_2020.4\win64\modelsim -do run.do

:clean_workspace

if exist work rmdir /S /Q work
if exist vsim.wlf del /Q vsim.wlf
if exist transcript del /Q transcript

:end
