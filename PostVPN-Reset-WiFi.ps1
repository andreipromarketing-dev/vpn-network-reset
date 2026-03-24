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

function Get-WiFiAdapter {
    Get-NetAdapter | Where-Object { 
        $_.Status -eq "Up" -and (
            $_.Name -like "*Wi*" -or 
            $_.Name -like "*WLAN*" -or
            $_.Name -like "*802.11*" -or
            $_.Name -like "*Wireless*" -or
            $_.InterfaceDescription -like "*Wireless*" -or
            $_.InterfaceDescription -like "*Wi-Fi*"
        ) -and $_.Name -notlike "*Bluetooth*"
    } | Select-Object -First 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   VPN NETWORK RESET (SAFE VERSION)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$wifi = Get-WiFiAdapter
if ($wifi) {
    Write-Status "Wi-Fi adapter: $($wifi.Name)" "info"
} else {
    Write-Status "No active Wi-Fi adapter found!" "warning"
    Write-Status "Make sure Wi-Fi is enabled and connected." "warning"
    pause
    exit 1
}

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

Write-Status "[2] Registering DNS..." "info"
ipconfig /registerdns 2>$null

Write-Status "[3] Releasing IP..." "info"
ipconfig /release 2>$null

Start-Sleep -Seconds 2

Write-Status "[4] Renewing IP..." "info"
ipconfig /renew 2>$null

Write-Status "[5] Setting DNS servers..." "info"
$dnsServers = @("8.8.8.8", "1.1.1.1")
try {
    Set-DnsClientServerAddress -InterfaceIndex $wifi.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction SilentlyContinue
} catch {}

Write-Status "[6] Flushing ARP cache..." "info"
netsh interface ip delete arpcache 2>$null

Start-Sleep -Seconds 5

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 2: Network Adapter Reset ===" "info"

Write-Status "[1] Disabling Wi-Fi adapter..." "info"
try {
    Disable-NetAdapter -Name $wifi.Name -Confirm:$false -ErrorAction Stop
} catch {
    Write-Status "Cannot disable adapter (needs admin). Trying netsh..." "warning"
    netsh interface set interface "$($wifi.Name)" admin=disabled 2>$null
}

Start-Sleep -Seconds 3

Write-Status "[2] Enabling Wi-Fi adapter..." "info"
try {
    Enable-NetAdapter -Name $wifi.Name -Confirm:$false -ErrorAction Stop
} catch {
    Write-Status "Cannot enable adapter (needs admin). Trying netsh..." "warning"
    netsh interface set interface "$($wifi.Name)" admin=enabled 2>$null
}

Start-Sleep -Seconds 5

Write-Status "[3] Re-configuring DNS..." "info"
try {
    Set-DnsClientServerAddress -InterfaceIndex $wifi.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction SilentlyContinue
} catch {}

Start-Sleep -Seconds 5

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored!" "success"
    pause
    exit 0
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "   MANUAL INTERVENTION NEEDED" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Status "Try these steps:" "info"
Write-Status "  1. Restart your router" "info"
Write-Status "  2. Restart your computer" "info"
Write-Status "  3. Toggle Wi-Fi off/on manually" "info"
Write-Status "  4. Use Ethernet cable" "info"
Write-Host ""
Write-Status "--- ADAPTER STATUS ---" "warning"
Get-NetAdapter | Select Name, Status | Format-Table -AutoSize
Write-Host ""
pause
exit 1
