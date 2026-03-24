@echo off
title Network Reset After VPN
color 0A
echo.
echo ========================================
echo    NETWORK RESET AFTER ChatVPN
echo ========================================
echo.
powershell -ExecutionPolicy Bypass -WindowStyle Normal -File "%~dp0PostVPN-Reset-WiFi.ps1"
echo.
pause
