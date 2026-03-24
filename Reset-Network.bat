@echo off
title Network Reset After VPN
cd /d "%~dp0"

echo ========================================
echo    NETWORK RESET AFTER ChatVPN
echo ========================================
echo.

powershell -Command "Start-Process cmd -ArgumentList '/c powershell -ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\"' -Verb RunAs"

echo.
echo Waiting for admin session...
pause
