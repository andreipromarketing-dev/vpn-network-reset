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

function Disable-AllVPNAdapters {
    $vpnPatterns = @("VPN", "Cisco", "OpenVPN", "WireGuard", "TAP", "TUN", "NordVPN", "ExpressVPN", "CyberGhost")
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        foreach ($pattern in $vpnPatterns) {
            if ($adapter.Name -match $pattern) {
                Write-Status "   Disconnecting VPN adapter: $($adapter.Name)" "warning"
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
                break
            }
        }
    }
}

function Wait-AdapterReady($adapter, $timeout = 15) {
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $status = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
        if ($status.Status -eq "Up") { return $true }
        Start-Sleep -Seconds 1
        $elapsed++
    }
    return $false
}

function Clean-OldSnapshots($keepCount = 50) {
    $snapshots = Get-ChildItem $SnapshotsDir -Filter "snapshot-*.json" | Sort-Object LastWriteTime -Descending
    if ($snapshots.Count -gt $keepCount) {
        $toRemove = $snapshots | Select-Object -Skip $keepCount
        foreach ($file in $toRemove) {
            Write-Status "   Removing old snapshot: $($file.Name)" "info"
            Remove-Item $file.FullName -Force
        }
    }
}

function Optimize-NetworkSpeed {
    Write-Status "" "info"
    Write-Status "=== OPTIMIZING NETWORK SPEED ===" "info"
    
    Write-Status "[1/10] Setting TCP congestion provider..." "info"
    $tcpResult = netsh int tcp set supplemental template=internet congestionprovider=ctcp 2>&1
    Write-Status "   CTCP enabled" "success"
    
    Write-Status "[2/10] Disabling TCP timestamps..." "info"
    netsh int tcp set global timestamps=disabled 2>$null
    
    Write-Status "[3/10] Setting Initial RTO to 300ms..." "info"
    netsh int tcp set global initialRto=300 2>$null
    
    Write-Status "[4/10] Disabling RSC (Receive Segment Coalescing)..." "info"
    netsh int tcp set global rsc=disabled 2>$null
    
    Write-Status "[5/10] Enabling RSS and DCA..." "info"
    netsh int tcp set global rss=enabled dca=enabled 2>$null
    
    Write-Status "[6/10] Disabling Non-SACK RTT Resiliency..." "info"
    netsh int tcp set global nonsackrttresiliency=disabled 2>$null
    
    Write-Status "[7/10] Setting max SYN retransmissions to 2..." "info"
    netsh int tcp set global maxsynretransmissions=2 2>$null
    
    Write-Status "[8/10] Expanding dynamic port range..." "info"
    netsh int ipv4 set dynamicport tcp start=10000 num=55534 2>$null
    netsh int ipv6 set dynamicport tcp start=10000 num=55534 2>$null
    
    Write-Status "[9/10] Optimizing registry settings..." "info"
    reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v DefaultTTL /d 64 /t REG_DWORD /f 2>$null | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /d 65534 /t REG_DWORD /f 2>$null | Out-Null
    reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /d 30 /t REG_DWORD /f 2>$null | Out-Null
    
    Write-Status "[10/10] Clearing DNS cache..." "info"
    ipconfig /flushdns 2>$null
    
    Write-Status "" "info"
    Write-Status "Optimization complete! Reboot recommended." "success"
    Write-Status "Current link speed: $((Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue).LinkSpeed)" "info"
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
    $wifiAdapter = Get-NetAdapter | Where-Object { $_.InterfaceType -eq 71 -and $_.Status -eq 'Up' } | Select-Object -First 1
    if ($wifiAdapter) { return $wifiAdapter.Name }
    
    $connected = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|TAP|TUN|Bluetooth|NULL|isatap|Teredo' } | Select-Object -First 1
    if ($connected) { return $connected.Name }
    
    return "Wi-Fi"
}

function Get-NetworkSnapshot {
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
        $wlanInfo = netsh wlan show interfaces 2>$null | Out-String
        if ($wlanInfo -match "SSID\s*:\s*(.+)") { $snapshot.ssid = $matches[1].Trim() }
        if ($wlanInfo -match "BSSID\s*:\s*([0-9a-fA-F:]+)") { $snapshot.bssid = $matches[1].Trim() }
        
        $netAdapter = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
        if ($netAdapter) {
            $ipAddr = Get-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ipAddr) { $snapshot.ip = $ipAddr.IPAddress }
            
            $route = Get-NetRoute -InterfaceIndex $netAdapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($route) { $snapshot.gateway = $route.NextHop }
            
            $dns = Get-DnsClientServerAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dns.ServerAddresses) { $snapshot.dns = $dns.ServerAddresses }
        }
    } catch {}
    return $snapshot
}

function Save-Snapshot($snapshot) {
    $snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $LastSnapshot -Encoding UTF8
    Write-Status "Snapshot saved: $LastSnapshot" "success"
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $SnapshotsDir "snapshot-$timestamp.json"
    $snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Status "Backup: $backupFile" "info"
}

function Compare-WithLast($current) {
    if (-not (Test-Path $LastSnapshot)) { return $true }
    $previous = Get-Content $LastSnapshot -Raw | ConvertFrom-Json
    if ($current.ip -ne $previous.ip) { return $true }
    if ($current.gateway -ne $previous.gateway) { return $true }
    if (($current.dns -join ",") -ne ($previous.dns -join ",")) { return $true }
    return $false
}

function Apply-Presets {
    param([string]$Adapter)
    
    $presetFiles = Get-ChildItem $SnapshotsDir -Filter "snapshot-*.json" | Sort-Object LastWriteTime -Descending
    foreach ($file in $presetFiles) {
        try {
            $preset = Get-Content $file.FullName -Raw | ConvertFrom-Json
            Write-Status "Trying preset: $($file.Name)" "info"
            
            if ($preset.gateway) {
                Write-Status "   Setting gateway: $($preset.gateway)" "info"
                netsh interface ip set address $Adapter static $preset.ip 255.255.255.0 $preset.gateway 2>$null
            }
            
            if ($preset.dns -and $preset.dns.Count -gt 0) {
                Write-Status "   Setting DNS: $($preset.dns[0])" "info"
                netsh interface ip set dns $Adapter static $preset.dns[0] 2>$null
                for ($i = 1; $i -lt $preset.dns.Count; $i++) {
                    netsh interface ip add dns $Adapter $preset.dns[$i] index=$($i+1) 2>$null
                }
            }
            
            Start-Sleep -Seconds 3
            if (Test-Network) {
                Write-Status "Preset worked: $($file.Name)" "success"
                return $true
            }
        } catch {
            Write-Status "Preset failed: $($file.Name)" "warning"
        }
    }
    return $false
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   NETWORK AUTO-RESET v3.0" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "===== Network Auto-Reset Started ====="
$adapter = Get-ActiveAdapter
Write-Status "Detected adapter: $adapter" "info"

Write-Status "--- CHECKING NETWORK ---" "info"
if (Test-Network) {
    Write-Status "Network is working!" "success"
    Write-Status "Saving current configuration..." "info"
    
    $current = Get-NetworkSnapshot
    Write-Status "Current IP: $($current.ip), Gateway: $($current.gateway)" "info"
    
    if (Compare-WithLast $current) {
        Write-Status "Configuration changed - saving snapshot..." "info"
        Save-Snapshot $current
    } else {
        Write-Status "No changes from last snapshot." "info"
    }
    
    Write-Log "Network working, snapshot saved"
    Write-Host ""
    pause
    exit 0
}

Write-Status "Network is DOWN. Starting reset..." "warning"

Write-Status "" "info"
Write-Status "=== STEP 1: DNS & IP Reset ===" "info"

Write-Status "[1/8] Disabling VPN adapters..." "info"
Disable-AllVPNAdapters

Write-Status "[2/8] Restarting network adapter..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Enable-NetAdapter -Name $adapter -Confirm:$false -ErrorAction SilentlyContinue

if (-not (Wait-AdapterReady $adapter 15)) {
    Write-Status "   Adapter did not come up in time" "warning"
}

Write-Status "[3/8] Flushing DNS..." "info"
ipconfig /flushdns 2>$null

Write-Status "[4/8] Releasing IP..." "info"
$releaseResult = ipconfig /release $adapter 2>&1
if ($releaseResult -match "No operation|не удается|error") {
    Write-Status "   Release skipped (adapter not ready)" "info"
}

Start-Sleep -Seconds 2

Write-Status "[5/8] Renewing IP..." "info"
$renewResult = ipconfig /renew $adapter 2>&1
if ($renewResult -match "No operation|не удается|error") {
    Write-Status "   Renew skipped (adapter not ready)" "info"
}

Write-Status "[6/8] Setting Google DNS..." "info"
$dnsResult1 = netsh interface ip set dns "$adapter" static 8.8.8.8 2>&1
if ($dnsResult1 -match "error|Error|ошибка") {
    Write-Status "   Primary DNS failed, retrying..." "warning"
    Start-Sleep -Seconds 2
    $dnsResult1 = netsh interface ip set dns "$adapter" static 8.8.8.8 2>&1
}
$dnsResult2 = netsh interface ip add dns "$adapter" 1.1.1.1 index=2 2>&1

Write-Status "[7/8] Clearing proxy..." "info"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value "" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue

Write-Status "[8/8] Waiting for network..." "info"
Start-Sleep -Seconds 10

if (Test-Network) {
    Write-Host ""
    Write-Status "[SUCCESS] Network restored!" "success"
    $current = Get-NetworkSnapshot
    Save-Snapshot $current
    Clean-OldSnapshots 50
    Optimize-NetworkSpeed
    Write-Log "Success - network restored after Step 1"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 2: Trying Saved Presets ===" "info"

if (Apply-Presets -Adapter $adapter) {
    Write-Host ""
    Write-Status "[SUCCESS] Network restored via preset!" "success"
    $current = Get-NetworkSnapshot
    Save-Snapshot $current
    Clean-OldSnapshots 50
    Optimize-NetworkSpeed
    Write-Log "Success - network restored via preset"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 3: Aggressive Reset ===" "info"

Write-Status "[1/4] Disabling VPN adapters..." "info"
Disable-AllVPNAdapters

Write-Status "[2/4] Resetting Winsock..." "info"
netsh winsock reset 2>$null

Write-Status "[3/4] Resetting TCP/IP..." "info"
netsh int ip reset 2>$null

Write-Status "[4/4] Final adapter restart..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 3
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 3
Wait-AdapterReady $adapter 15 | Out-Null

Start-Sleep -Seconds 15

if (Test-Network) {
    Write-Host ""
    Write-Status "[SUCCESS] Network restored!" "success"
    $current = Get-NetworkSnapshot
    Save-Snapshot $current
    Clean-OldSnapshots 50
    Optimize-NetworkSpeed
    Write-Log "Success - network restored after Step 3"
    pause
    exit 0
}

Write-Host ""
Write-Status "[FAILED] Network still down." "error"
Write-Status "" "info"
Write-Status "Manual steps:" "info"
Write-Status "  1. Unplug router for 30 sec" "info"
Write-Status "  2. Disconnect VPN manually" "info"
Write-Status "  3. Restart computer" "info"

Write-Log "===== Network Reset FAILED ====="

Write-Status "" "info"
Write-Status "Cleaning up old snapshots..." "info"
Clean-OldSnapshots 50

pause
exit 1
