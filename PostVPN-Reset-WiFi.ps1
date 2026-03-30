$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SnapshotsDir = Join-Path $ScriptDir "snapshots"
$LastSnapshot = Join-Path $SnapshotsDir "last-known-good.json"
$LogFile = Join-Path $ScriptDir "reset.log"

if (-not (Test-Path $SnapshotsDir)) {
    New-Item -ItemType Directory -Path $SnapshotsDir | Out-Null
}

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp | $msg" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Write-Status($msg, $type) {
    $colors = @{info="Cyan"; success="Green"; warning="Yellow"; error="Red"}
    Write-Host -ForegroundColor $colors[$type] $msg
    Write-Log "[$type.ToUpper()] $msg"
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
        if ($available -match [regex]::Escape($name)) { return $name }
    }
    return $adapters[0]
}

function Get-CurrentConfig {
    $cfg = @{
        Adapter = ""
        IP = ""
        Gateway = ""
        DNS = @()
        SSID = ""
    }
    try {
        $ipConfig = ipconfig | Out-String
        if ($ipConfig -match "192\.168\.\d+\.\d+") {
            $cfg.IP = $matches[0]
        }
        if ($ipConfig -match "Основной шлюз.*?(\d+\.\d+\.\d+\.\d+)") {
            $cfg.Gateway = $matches[1]
        }
    } catch {}
    return $cfg
}

function Save-NetworkSnapshot {
    $snapshot = @{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        adapter = $adapter
        ssid = ""
        bssid = ""
        ip = ""
        gateway = ""
        dns = @()
    }
    try {
        $wlanInfo = netsh wlan show interfaces | Out-String
        if ($wlanInfo -match "SSID.*?:\s*(.+)" ) { $snapshot.ssid = $matches[1].Trim() }
        if ($wlanInfo -match "BSSID.*?:\s*(.+)" ) { $snapshot.bssid = $matches[1].Trim() }
        
        $ipConfig = ipconfig | Out-String
        if ($ipConfig -match "IPv4.*?(\d+\.\d+\.\d+\.\d+)") { $snapshot.ip = $matches[1] }
        if ($ipConfig -match "Основной шлюз.*?(\d+\.\d+\.\d+\.\d+)") { $snapshot.gateway = $matches[1] }
        
        $dnsMatch = [regex]::Matches($ipConfig, "DNS.*?(\d+\.\d+\.\d+\.\d+)")
        foreach ($m in $dnsMatch) { $snapshot.dns += $m.Groups[1].Value }
        $snapshot.dns = $snapshot.dns | Select-Object -Unique
    } catch {}
    
    $snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $LastSnapshot -Encoding UTF8
    Write-Status "Snapshot saved: $LastSnapshot" "info"
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $SnapshotsDir "snapshot-$timestamp.json"
    $snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFile -Encoding UTF8
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   VPN NETWORK RESET v3.0" -ForegroundColor Cyan
Write-Host "   (With logging & diagnostics)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$startTime = Get-Date
$whatHelped = @()

Write-Log "===== Network Reset Started ====="
$adapter = Get-ActiveAdapter
Write-Status "Detected adapter: $adapter" "info"

$currentCfg = Get-CurrentConfig
Write-Status "Current IP: $($currentCfg.IP)" "info"
Write-Status "Current Gateway: $($currentCfg.Gateway)" "info"

Write-Status "--- PRE CHECK ---" "info"
if (Test-Network) { 
    Write-Status "Network: OK - No reset needed!" "success"
    Write-Log "Network already working, exiting"
    pause
    exit 0 
}
Write-Status "Network: DOWN - Starting reset..." "warning"

Write-Status "" "info"
Write-Status "=== STEP 1: DNS & IP Reset ===" "info"

Write-Status "[1/6] Flushing DNS..." "info"
ipconfig /flushdns 2>$null

Write-Status "[2/6] Releasing IP..." "info"
ipconfig /release $adapter 2>$null

Start-Sleep -Seconds 3

Write-Status "[3/6] Renewing IP..." "info"
ipconfig /renew $adapter 2>$null

Write-Status "[4/6] Setting Google DNS for $adapter..." "info"
netsh interface ip set dns $adapter static 8.8.8.8 2>$null
netsh interface ip add dns $adapter 1.1.1.1 index=2 2>$null

Write-Status "[5/6] Clearing proxy settings..." "info"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value "" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
netsh winhttp reset proxy 2>$null
[Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "User")
[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "User")

Write-Status "[6/6] Saving network snapshot..." "info"
Save-NetworkSnapshot

Start-Sleep -Seconds 5

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored after Step 1!" "success"
    $whatHelped += "DNS+IP Reset (Step 1)"
    Write-Log "Success! What helped: DNS+IP Reset"
    pause
    exit 0 
}

Write-Status "" "info"
Write-Status "=== STEP 2: VPN Route Cleanup ===" "info"

Write-Status "[1/4] Removing extra 0.0.0.0 routes (VPN artifacts)..." "info"
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

Write-Status "[2/4] Restarting Network Adapter..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 2
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null

Write-Status "[3/4] Flushing DNS again..." "info"
ipconfig /flushdns 2>$null

Write-Status "[4/4] Renewing IP after adapter restart..." "info"
ipconfig /renew $adapter 2>$null

Start-Sleep -Seconds 10

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored after Step 2!" "success"
    $whatHelped += "Route Cleanup + Adapter Restart (Step 2)"
    Write-Log "Success! What helped: Route Cleanup + Adapter Restart"
    pause
    exit 0 
}

Write-Host ""
Write-Status "=== STEP 3: Aggressive Reset (Last Resort) ===" "info"

Write-Status "[1/3] Resetting Winsock..." "info"
netsh winsock reset 2>$null

Write-Status "[2/3] Resetting TCP/IP stack..." "info"
netsh int ip reset 2>$null

Write-Status "[3/3] Final adapter restart..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 3
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null

Start-Sleep -Seconds 15

if (Test-Network) {
    Write-Host ""
    Write-Status "[RESULT] SUCCESS! Network restored after Step 3!" "success"
    $whatHelped += "Winsock+TCP/IP Reset (Step 3)"
    Write-Log "Success! What helped: Winsock+TCP/IP Reset"
    pause
    exit 0 
}

$elapsed = (Get-Date) - $startTime

Write-Host ""
Write-Status "Network still down after all steps." "error"
Write-Status "" "info"
Write-Status "=== DIAGNOSTIC INFO ===" "info"
Write-Status "Time elapsed: $($elapsed.ToString('mm\:ss'))" "info"
Write-Status "What was tried: Step 1, Step 2, Step 3" "info"
Write-Status "" "info"
Write-Status "Manual steps to try:" "info"
Write-Status "  1. Unplug router for 30 seconds, plug back" "info"
Write-Status "  2. Disconnect VPN manually in VPN client" "info"
Write-Status "  3. Toggle Wi-Fi off/on on this PC" "info"
Write-Status "  4. Restart computer" "info"
Write-Host ""
Write-Status "Working preset saved at: $PresetFile" "info"
Write-Status "Log file: $LogFile" "info"

Write-Log "===== Network Reset FAILED ====="
Write-Log "Elapsed: $($elapsed.ToString('mm\:ss'))"

pause
exit 1
