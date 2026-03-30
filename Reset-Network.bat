@echo off
title Network Tools
cd /d "%~dp0"

:main
cls
echo ========================================
echo    NETWORK TOOLS
echo ========================================
echo.
echo  [1] Reset Network (after VPN)
echo  [2] Save Working Snapshot
echo.
set /p choice="Choose: "

if "%choice%"=="1" goto reset
if "%choice%"=="2" goto snapshot
goto main

:reset
cls
echo ========================================
echo    NETWORK RESET AFTER VPN
echo ========================================
echo.
powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0PostVPN-Reset-WiFi.ps1\"' -Verb RunAs"
exit

:snapshot
cls
echo ========================================
echo    SAVE NETWORK SNAPSHOT
echo ========================================
echo.
powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0Save-NetworkSnapshot.ps1\"' -Verb RunAs"
exit
