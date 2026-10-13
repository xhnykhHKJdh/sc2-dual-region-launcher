@echo off
chcp 65001 >nul
call "%~dp0开始修复.cmd"
exit /b %errorlevel%
