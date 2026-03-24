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

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   VPN NETWORK RESET (SAFE VERSION)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Status "--- PRE CHECK ---" "info"
if (Test-Network) { 
    Write-Status "Network: OK - No reset needed!" "success"
    pause
    exit 0 
}
Write-Status "Network: DOWN - Starting safe reset..." "warning"

Write-Status "" "info"
Write-Status "=== STEP 1: Safe DNS & IP Reset ===" "info"

Write-Status "[1] Flushing DNS..." "info"
ipconfig /flushdns 2>$null

Write-Status "[2] Releasing IP..." "info"
ipconfig /release "*" 2>$null

Start-Sleep -Seconds 2

Write-Status "[3] Renewing IP..." "info"
ipconfig /renew 2>$null

Write-Status "[4] Setting Google DNS..." "info"
netsh interface ip set dns "Беспроводная сеть" static 8.8.8.8 2>$null
netsh interface ip add dns "Беспроводная сеть" 1.1.1.1 index=2 2>$null

Start-Sleep -Seconds 5

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 2: Reset Network Stack (VPN Fix) ===" "info"

Write-Status "[1] Resetting Winsock..." "info"
netsh winsock reset 2>$null

Write-Status "[2] Resetting TCP/IP..." "info"
netsh int ip reset 2>$null

Write-Status "[3] Removing VPN routes..." "info"
route print | Select-String "0.0.0.0" | ForEach-Object { 
    $parts = $_.Line -split '\s+'
    if ($parts.Count -gt 3) {
        $gateway = $parts[2]
        if ($gateway -and $gateway -ne "0.0.0.0" -and $gateway -ne "On-link") {
            Write-Status "   Removing route via $gateway" "info"
            route delete 0.0.0.0 $gateway 2>$null
        }
    }
}

Write-Status "[4] Releasing and renewing..." "info"
ipconfig /release "*" 2>$null
Start-Sleep -Seconds 2
ipconfig /renew 2>$null

Write-Status "[5] Flushing DNS again..." "info"
ipconfig /flushdns 2>$null

Start-Sleep -Seconds 10

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    Write-Status "NOTE: You may need to restart some apps." "info"
    pause
    exit 0
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "   MANUAL INTERVENTION NEEDED" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Status "Network reset complete but still not working." "warning"
Write-Status "" "info"
Write-Status "Try these additional steps:" "info"
Write-Status "  1. Restart your computer (recommended)" "info"
Write-Status "  2. Check if VPN client is still connected" "info"
Write-Status "  3. Disconnect from VPN manually" "info"
Write-Status "  4. Restart your router" "info"
Write-Host ""
Write-Host ""
pause
exit 1
