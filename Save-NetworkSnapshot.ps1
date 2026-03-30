$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SnapshotsDir = Join-Path $ScriptDir "snapshots"
$LastSnapshot = Join-Path $SnapshotsDir "last-known-good.json"

if (-not (Test-Path $SnapshotsDir)) {
    New-Item -ItemType Directory -Path $SnapshotsDir | Out-Null
}

function Test-Network {
    try {
        $ping = Test-Connection 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping) { return $true }
        $dns = Resolve-DnsName google.com -Server 8.8.8.8 -ErrorAction SilentlyContinue
        return ($dns -ne $null)
    } catch { return $false }
}

function Get-NetworkSnapshot {
    $snapshot = @{
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        adapter = ""
        ssid = ""
        bssid = ""
        ip = ""
        subnet = ""
        gateway = ""
        dns = @()
        signal = ""
    }

    $adapters = @("Wi-Fi", "Беспроводная сеть", "Ethernet")
    $available = netsh interface show interface | Select-String "Enabled"
    foreach ($name in $adapters) {
        if ($available -match [regex]::Escape($name)) { 
            $snapshot.adapter = $name 
            break
        }
    }

    try {
        $ipConfig = ipconfig | Out-String
        if ($ipConfig -match "IPv4.*?(\d+\.\d+\.\d+\.\d+)") { $snapshot.ip = $matches[1] }
        if ($ipConfig -match "Маска подсети.*?(\d+\.\d+\.\d+\.\d+)") { $snapshot.subnet = $matches[1] }
        if ($ipConfig -match "Основной шлюз.*?(\d+\.\d+\.\d+\.\d+)") { $snapshot.gateway = $matches[1] }
        
        $dnsMatch = [regex]::Matches($ipConfig, "DNS.*?(\d+\.\d+\.\d+\.\d+)")
        foreach ($m in $dnsMatch) { $snapshot.dns += $m.Groups[1].Value }
        $snapshot.dns = $snapshot.dns | Select-Object -Unique
    } catch {}

    try {
        $wlanInfo = netsh wlan show interfaces | Out-String
        if ($wlanInfo -match "SSID.*?:\s*(.+)" ) { $snapshot.ssid = $matches[1].Trim() }
        if ($wlanInfo -match "BSSID.*?:\s*(.+)" ) { $snapshot.bssid = $matches[1].Trim() }
        if ($wlanInfo -match "Состояние.*?:\s*(.+)" ) { $snapshot.state = $matches[1].Trim() }
        if ($wlanInfo -match "Канал.*?:\s*(\d+)") { $snapshot.channel = $matches[1] }
        if ($wlanInfo -match "Signal.*?:\s*(\d+)") { $snapshot.signal = $matches[1] }
    } catch {}

    return $snapshot
}

function Compare-Snapshots($old, $new) {
    $changes = @()
    if ($old.ip -ne $new.ip) { $changes += "IP: $($old.ip) -> $($new.ip)" }
    if ($old.gateway -ne $new.gateway) { $changes += "Gateway: $($old.gateway) -> $($new.gateway)" }
    if (($old.dns -join ",") -ne ($new.dns -join ",")) { $changes += "DNS: $($old.dns) -> $($new.dns)" }
    if ($old.ssid -ne $new.ssid) { $changes += "SSID: $($old.ssid) -> $($new.ssid)" }
    if ($old.bssid -ne $new.bssid) { $changes += "BSSID: $($old.bssid) -> $($new.bssid)" }
    return $changes
}

Write-Host ""
Write-Host "=== Network Snapshot ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking network..." -ForegroundColor White
if (-not (Test-Network)) {
    Write-Host "Network is NOT working. Cannot save snapshot." -ForegroundColor Red
    Write-Host "Fix network connection first." -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "Network is working. Proceeding..." -ForegroundColor Green

$current = Get-NetworkSnapshot

Write-Host "Current state:" -ForegroundColor White
Write-Host "  Adapter: $($current.adapter)"
Write-Host "  SSID: $($current.ssid)"
Write-Host "  IP: $($current.ip)"
Write-Host "  Gateway: $($current.gateway)"
Write-Host "  DNS: $($current.dns -join ', ')"

if (Test-Path $LastSnapshot) {
    $previous = Get-Content $LastSnapshot -Raw | ConvertFrom-Json
    $changes = Compare-Snapshots $previous $current
    
    if ($changes.Count -eq 0) {
        Write-Host ""
        Write-Host "No changes detected. Skipping save." -ForegroundColor Yellow
        exit 0
    }
    
    Write-Host ""
    Write-Host "Changes detected:" -ForegroundColor Yellow
    $changes | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupFile = Join-Path $SnapshotsDir "snapshot-$timestamp.json"
    $current | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host ""
    Write-Host "Saved: $backupFile" -ForegroundColor Green
}

$current | ConvertTo-Json -Depth 3 | Out-File -FilePath $LastSnapshot -Encoding UTF8
Write-Host "Updated: last-known-good.json" -ForegroundColor Green
Write-Host ""

exit 0
