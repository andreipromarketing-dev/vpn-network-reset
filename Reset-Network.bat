@echo off
title Network Auto-Reset
cd /d "%~dp0"

echo ========================================
echo    NETWORK AUTO-RESET
echo ========================================
echo.

powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\"' -Verb RunAs"

exit
