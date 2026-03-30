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

Write-Status "[1/6] Flushing DNS..." "info"
ipconfig /flushdns 2>$null

Write-Status "[2/6] Releasing IP..." "info"
ipconfig /release $adapter 2>$null

Start-Sleep -Seconds 3

Write-Status "[3/6] Renewing IP..." "info"
ipconfig /renew $adapter 2>$null

Write-Status "[4/6] Setting Google DNS..." "info"
netsh interface ip set dns $adapter static 8.8.8.8 2>$null
netsh interface ip add dns $adapter 1.1.1.1 index=2 2>$null

Write-Status "[5/6] Clearing proxy..." "info"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value "" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue

Write-Status "[6/6] Restarting adapter..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 3
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null

Start-Sleep -Seconds 10

if (Test-Network) {
    Write-Host ""
    Write-Status "[SUCCESS] Network restored!" "success"
    $current = Get-NetworkSnapshot
    Save-Snapshot $current
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
    Write-Log "Success - network restored via preset"
    pause
    exit 0
}

Write-Status "" "info"
Write-Status "=== STEP 3: Aggressive Reset ===" "info"

Write-Status "[1/3] Resetting Winsock..." "info"
netsh winsock reset 2>$null

Write-Status "[2/3] Resetting TCP/IP..." "info"
netsh int ip reset 2>$null

Write-Status "[3/3] Final adapter restart..." "info"
Disable-NetAdapter -Name $adapter -Confirm:$false 2>$null
Start-Sleep -Seconds 3
Enable-NetAdapter -Name $adapter -Confirm:$false 2>$null

Start-Sleep -Seconds 15

if (Test-Network) {
    Write-Host ""
    Write-Status "[SUCCESS] Network restored!" "success"
    $current = Get-NetworkSnapshot
    Save-Snapshot $current
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
pause
exit 1
