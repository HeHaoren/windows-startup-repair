@echo off
setlocal
title Windows Startup Repair

rem Check admin rights; if not elevated, relaunch this script elevated (UAC prompt).
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0StartupRepair.ps1" %*

pause
