@echo off
title Network Smart Reset
cd /d "%~dp0"

echo ========================================
echo    NETWORK SMART RESET
echo ========================================
echo.
echo If internet is UP: optimize TCP settings
echo If internet is DOWN: full reset + optimize
echo.

powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\"' -Verb RunAs"

exit
