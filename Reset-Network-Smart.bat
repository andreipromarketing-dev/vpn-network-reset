@echo off
title Network Reset (Smart)
cd /d "%~dp0"

echo ========================================
echo    NETWORK RESET - SMART MODE
echo ========================================
echo.
echo Auto: if no internet -> full reset
echo If OK -> just optimize
echo.

powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\"' -Verb RunAs"

exit