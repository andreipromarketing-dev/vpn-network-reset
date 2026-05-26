@echo off
title Network Reset (Force)
cd /d "%~dp0"

echo ========================================
echo    NETWORK RESET - FORCE MODE
echo ========================================
echo.
echo Forcefully resets adapter + optimizes
echo.

powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\" -ForceReset' -Verb RunAs"

exit