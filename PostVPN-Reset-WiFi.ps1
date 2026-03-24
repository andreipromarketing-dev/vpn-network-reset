$ErrorActionPreference = "Continue"

function Write-Status($msg, $type) {
    $colors = @{info="Cyan"; success="Green"; warning="Yellow"; error="Red"}
    Write-Host -ForegroundColor $colors[$type] $msg
}

function Test-Network {
    try {
        $ping = Test-Connection 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping) { return $true }
        $dns = Resolve-DnsName google.com -Server 8.8.8.8 -ErrorAction SilentlyContinue
        return ($dns -ne $null)
    } catch { return $false }
}

function Get-ActiveAdapter {
    $adapters = @("Wi-Fi", "Беспроводная сеть", "Ethernet", "Local Area Connection")
    $available = netsh interface show interface | Select-String "Enabled"
    foreach ($name in $adapters) {
        if ($available -match $name) { return $name }
    }
    return $adapters[0]
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   VPN NETWORK RESET v2.0" -ForegroundColor Cyan
Write-Host "   (Safe version - no aggressive resets)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$adapter = Get-ActiveAdapter
Write-Status "Detected adapter: $adapter" "info"

Write-Status "--- PRE CHECK ---" "info"
if (Test-Network) { 
    Write-Status "Network: OK - No reset needed!" "success"
    pause
    exit 0 
}
Write-Status "Network: DOWN - Starting reset..." "warning"

Write-Status "" "info"
Write-Status "=== STEP 1: DNS & IP Reset ===" "info"

Write-Status "[1] Flushing DNS..." "info"
ipconfig /flushdns 2>$null

Write-Status "[2] Releasing IP..." "info"
ipconfig /release $adapter 2>$null

Start-Sleep -Seconds 3

Write-Status "[3] Renewing IP..." "info"
ipconfig /renew $adapter 2>$null

Write-Status "[4] Setting Google DNS for $adapter..." "info"
netsh interface ip set dns $adapter static 8.8.8.8 2>$null
netsh interface ip add dns $adapter 1.1.1.1 index=2 2>$null

Write-Status "[5] Clearing proxy settings..." "info"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value ""
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0
netsh winhttp reset proxy 2>$null
[Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")

Start-Sleep -Seconds 5

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 2: VPN Route Cleanup ===" "info"

Write-Status "[1] Removing extra 0.0.0.0 routes (VPN artifacts)..." "info"
$routes = route print | Select-String "0.0.0.0"
$gatewayCount = 0
$routes | ForEach-Object { 
    $parts = $_.Line -split '\s+'
    if ($parts.Count -gt 3) {
        $gateway = $parts[2]
        if ($gateway -and $gateway -match '^\d+\.\d+\.\d+\.\d+$' -and $gateway -ne "0.0.0.0") {
            Write-Status "   Found route via $gateway" "info"
            route delete 0.0.0.0 $gateway 2>$null
            $gatewayCount++
        }
    }
}
if ($gatewayCount -eq 0) {
    Write-Status "   No extra routes found" "info"
}

Write-Status "[2] Restarting Network Adapter..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 2
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 5

Write-Status "[3] Flushing DNS again..." "info"
ipconfig /flushdns 2>$null

Start-Sleep -Seconds 10

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    pause
    exit 0
}

Write-Host ""
Write-Status "Network still down after safe reset." "warning"
Write-Status "" "info"
Write-Status "Manual steps to try:" "info"
Write-Status "  1. Disconnect VPN manually" "info"
Write-Status "  2. Unplug/plug router or toggle Wi-Fi" "info"
Write-Status "  3. Restart computer if needed" "info"
Write-Host ""
pause
exit 1
