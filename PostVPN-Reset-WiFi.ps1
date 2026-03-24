# PostVPN Network Reset Script
$ErrorActionPreference = "Continue"

function Write-Status($msg, $type) {
    $colors = @{info="Cyan"; success="Green"; warning="Yellow"; error="Red"}
    Write-Host -ForegroundColor $colors[$type] $msg
}

function Test-Network {
    $ping = Test-Connection 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
    return $ping
}

function Get-WiFi {
    Get-NetAdapter | Where-Object { $_.Name -like "*Wi*" } | Select-Object -First 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   NETWORK RESET AFTER ChatVPN" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Status "[PRE] Checking network..." "info"
if (Test-Network) { Write-Status "[PRE] Network: OK" "success" }
else { Write-Status "[PRE] Network: DOWN" "warning" }

# LIGHT RESET
Write-Status "[1] Light reset..." "info"
ipconfig /flushdns | Out-Null
ipconfig /release | Out-Null
ipconfig /renew | Out-Null
$w = Get-WiFi
if ($w) {
    Disable-NetAdapter $w.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 3
    Enable-NetAdapter $w.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 3
}
netsh winsock reset | Out-Null
Start-Sleep 3

if (Test-Network) {
    Write-Status "[RESULT] Network RESTORED!" "success"
    exit 0
}

# HARD RESET
Write-Status "[2] Hard reset..." "warning"
netsh int ip reset | Out-Null
netsh int tcp reset | Out-Null
netsh winsock reset | Out-Null
ipconfig /flushdns | Out-Null
ipconfig /release | Out-Null
ipconfig /renew | Out-Null
$w = Get-WiFi
if ($w) {
    Disable-NetAdapter $w.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 5
    Enable-NetAdapter $w.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 5
}
Set-DnsClientServerAddress -InterfaceAlias $w.Name -ServerAddresses ("8.8.8.8","1.1.1.1") -ErrorAction SilentlyContinue
Start-Sleep 3

if (Test-Network) {
    Write-Status "[RESULT] Network RESTORED (attempt 2)!" "success"
    exit 0
}

Write-Host "========================================" -ForegroundColor Red
Write-Host "   FAILED after 2 attempts" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host "Try: Restart router, reconnect WiFi" -ForegroundColor Red
Get-NetAdapter | Select Name, Status | Format-Table
