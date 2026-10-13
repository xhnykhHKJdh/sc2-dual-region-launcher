@echo off
setlocal
chcp 65001 >nul
title 星际争霸 II 国服与欧服分离工具
echo 自动识别安装并保留私人备份。游戏正在运行时，请先保存并退出。
echo 首次分离需要完整复制游戏，可能需要几分钟。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-SC2DualRegion.ps1" -Run
set "sc2_result=%errorlevel%"
echo.
if not "%sc2_result%"=="0" echo 未完成。请保留上方错误信息和备份，勿删除 Versions 或覆盖部分副本重试。
pause
exit /b %sc2_result%
