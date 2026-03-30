@echo off
title Save Network Snapshot
cd /d "%~dp0"

echo ========================================
echo    SAVE NETWORK SNAPSHOT
echo ========================================
echo.

powershell -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Normal -File \"%~dp0Save-NetworkSnapshot.ps1\"' -Verb RunAs"

exit
