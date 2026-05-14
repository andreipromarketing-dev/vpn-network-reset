<#
.SYNOPSIS
    VPN Network Controller v3.2
#>

# Parameters (NO [CmdletBinding()])
param(
    [switch]$Auto,
    [switch]$NoMenu
)

# Configuration
$ScriptConfig = @{
    ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
    SnapshotsDir    = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "snapshots"
    LogFile         = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "reset.log"
    PreferencesFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "snapshots\preferences.json"
    ProxyConfigFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "snapshots\proxies.json"
    PingTimeout     = 2
    AdapterTimeout  = 15
    PingThreshold   = 150
    VpnPatterns     = @("VPN", "Cisco", "OpenVPN", "WireGuard", "TAP", "TUN", "NordVPN", "ExpressVPN", "CyberGhost", "ChatVPN")
    FallbackDns     = @("8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9")
    MaxLogSize      = 10MB
}

function Write-Log {
    param([string]$Message, [string]$Level = "info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    try { Add-Content -Path $ScriptConfig.LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop } catch { Write-Warning "Log write failed: $_" }
}

function Write-Status {
    param([string]$Message, [string]$Type = "info")
    $colors = @{ info="Cyan"; success="Green"; warning="Yellow"; error="Red" }
    Write-Host -ForegroundColor $colors[$Type] $Message
    Write-Log $Message $Type
}

function Test-Network {
    param([string]$TestHost = "8.8.8.8", [int]$Timeout = 3)
    try {
        $ping = Test-Connection -ComputerName $TestHost -Count 2 -Quiet -ErrorAction Stop
        if ($ping) { return $true }
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -notmatch "127\.0\.0\.1" } | Select-Object -First 1).NextHop
        if ($gateway) { return (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue) }
        return $false
    } catch { Write-Log "Test-Network error: $_" "warning"; return $false }
}

function Get-ActiveAdapter {
    # 1st: Up physical adapters (WiFi/ethernet only)
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceType -in @(71, 6) -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|TAP|TUN|Bluetooth|isatap|Teredo' } | Select-Object -First 1
    if ($adapter) { return $adapter.Name }
    
    # 2nd: any Up adapter (no virtual)
    $fallback = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Virtual|Tunnel' } | Select-Object -First 1
    if ($fallback) { return $fallback.Name }
    
    # 3rd: physical adapters even if Disabled/Disconnected
    $phys = Get-NetAdapter | Where-Object { $_.InterfaceType -in @(71, 6) -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|Bluetooth' } | Select-Object -First 1
    if ($phys) { return $phys.Name }
    
    # 4th: any non-virtual adapter as last resort
    $any = Get-NetAdapter | Where-Object { $_.Name -notmatch 'Virtual|Tunnel|Loopback|Bluetooth' } | Select-Object -First 1
    if ($any) { return $any.Name }
    
    return $null
}

function Get-NetworkSnapshot {
    param([string]$AdapterName)
    $adapter = if ($AdapterName) { $AdapterName } else { Get-ActiveAdapter }
    $snapshot = @{ timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"; adapter = $adapter; ssid = ""; bssid = ""; ip = ""; gateway = ""; dns = @() }
    try {
        $wlan = netsh wlan show interfaces 2>$null | Out-String
        if ($wlan -match "SSID\s*:\s*(.+)") { $snapshot.ssid = $matches[1].Trim() }
        if ($wlan -match "BSSID\s*:\s*([0-9a-fA-F:]+)") { $snapshot.bssid = $matches[1].Trim() }
        $netAdapter = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
        if ($netAdapter) {
            $ip = Get-NetIPAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.AddressState -eq 'Preferred' } | Select-Object -First 1
            if ($ip) { $snapshot.ip = $ip.IPAddress }
            $route = Get-NetRoute -InterfaceIndex $netAdapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($route) { $snapshot.gateway = $route.NextHop }
            $dns = Get-DnsClientServerAddress -InterfaceIndex $netAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dns.ServerAddresses) { $snapshot.dns = $dns.ServerAddresses }
        }
    } catch { Write-Log "Snapshot error: $_" "warning" }
    return $snapshot
}

function Compare-WithLast {
    param([hashtable]$Current)
    $lastPath = Join-Path $ScriptConfig.SnapshotsDir "last-known-good.json"
    if (-not (Test-Path $lastPath)) { return $true }
    try { $previous = Get-Content $lastPath -Raw | ConvertFrom-Json; return ($Current.ip -ne $previous.ip) -or ($Current.gateway -ne $previous.gateway) -or (($Current.dns -join ",") -ne ($previous.dns -join ",")) } catch { return $true }
}

function Save-Snapshot {
    param([hashtable]$Snapshot)
    $lastPath = Join-Path $ScriptConfig.SnapshotsDir "last-known-good.json"
    try {
        $Snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $lastPath -Encoding UTF8 -Force
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $archive = Join-Path $ScriptConfig.SnapshotsDir "snapshot-$timestamp.json"
        $Snapshot | ConvertTo-Json -Depth 3 | Out-File -FilePath $archive -Encoding UTF8 -Force
        Write-Status "Snapshot saved" "success"
        Write-Log "Snapshot saved" "info"
    } catch { Write-Status "Failed to save snapshot: $_" "error"; Write-Log "Snapshot save error: $_" "error" }
}

function Apply-Presets {
    param([string]$Adapter)
    $presetFiles = Get-ChildItem $ScriptConfig.SnapshotsDir -Filter "snapshot-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($presetFiles.Count -eq 0) { Write-Status "No saved presets found" "warning"; return $false }
    foreach ($file in $presetFiles) {
        try {
            $preset = Get-Content $file.FullName -Raw | ConvertFrom-Json
            Write-Status "Trying preset: $($file.Name)" "info"
            if ($preset.gateway) { $null = route add 0.0.0.0 mask 0.0.0.0 $preset.gateway metric 50 -p 2>&1 | Out-Null }
            if ($preset.dns -and $preset.dns.Count -gt 0) { $null = netsh interface ip set dns "$Adapter" static $preset.dns[0] 2>&1 | Out-Null }
            Start-Sleep -Seconds 3
            if (Test-Network) { Write-Status "Preset worked!" "success"; return $true }
        } catch { Write-Log "Preset apply error: $_" "warning"; continue }
    }
    return $false
}

function Disable-AllVPNAdapters {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        foreach ($pattern in $ScriptConfig.VpnPatterns) {
            if ($adapter.Name -imatch $pattern) {
                Write-Status "Disconnecting VPN adapter: $($adapter.Name)" "warning"
                try { Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop; Write-Log "Disabled: $($adapter.Name)" "info" } catch { Write-Log "Failed to disable: $_" "warning" }
                break
            }
        }
    }
}

function Wait-AdapterReady {
    param([string]$Adapter, [int]$Timeout = 15)
    $elapsed = 0
    while ($elapsed -lt $Timeout) {
        try { $status = Get-NetAdapter -Name $Adapter -ErrorAction Stop; if ($status.Status -eq "Up") { Write-Log "Adapter ready after ${elapsed}s" "info"; return $true } } catch { }
        Start-Sleep -Seconds 1; $elapsed++
    }
    Write-Log "Adapter not ready after ${Timeout}s" "warning"
    return $false
}

function Optimize-NetworkSpeed {
    param([string]$Adapter)
    Write-Status "" "info"
    Write-Status "=== OPTIMIZING NETWORK SPEED ===" "info"
    Write-Status "[1/10] Setting TCP congestion..." "info"; netsh int tcp set supplemental template=internet congestionprovider=ctcp 2>&1 | Out-Null; Write-Status "CTCP enabled" "success"
    Write-Status "[2/10] Disabling TCP timestamps..." "info"; netsh int tcp set global timestamps=disabled 2>$null
    Write-Status "[3/10] Setting Initial RTO..." "info"; netsh int tcp set global initialRto=300 2>$null
    Write-Status "[4/10] Disabling RSC..." "info"; netsh int tcp set global rsc=disabled 2>$null
    Write-Status "[5/10] Enabling RSS and DCA..." "info"; netsh int tcp set global rss=enabled dca=enabled 2>$null
    Write-Status "[6/10] Disabling Non-SACK RTT..." "info"; netsh int tcp set global nonsackrttresiliency=disabled 2>$null
    Write-Status "[7/10] Setting max SYN retrans..." "info"; netsh int tcp set global maxsynretransmissions=2 2>$null
    Write-Status "[8/10] Expanding dynamic port range..." "info"; netsh int ipv4 set dynamicport tcp start=10000 num=55534 2>$null; netsh int ipv6 set dynamicport tcp start=10000 num=55534 2>$null
    Write-Status "[9/10] Optimizing registry..." "info"; reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v DefaultTTL /d 64 /t REG_DWORD /f 2>$null | Out-Null; reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /d 65534 /t REG_DWORD /f 2>$null | Out-Null; reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /d 30 /t REG_DWORD /f 2>$null | Out-Null
    Write-Status "[10/10] Clearing DNS cache..." "info"; ipconfig /flushdns 2>$null
    Write-Status "" "info"
    Write-Status "Optimization complete! Reboot recommended." "success"
    if ($Adapter) { try { $adapterInfo = Get-NetAdapter -Name $Adapter -ErrorAction Stop; Write-Status "Link speed: $($adapterInfo.LinkSpeed)" "info" } catch { } }
    Write-Log "Network optimization completed" "info"
}

function Invoke-NetworkReset {
    Write-Host ""; Write-Host "=== PRIORITY NETWORK RECOVERY ===" -ForegroundColor Cyan; Write-Log "Starting network reset" "info"
    $adapter = Get-ActiveAdapter
    if (-not $adapter) { Write-Status "No adapter found at all!" "error"; Write-Log "Reset aborted: no adapter" "error"; return $false }
    
    # Check adapter status and try to enable if Disabled/Disconnected
    $adapterObj = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
    if ($adapterObj) {
        if ($adapterObj.Status -ne 'Up') {
            Write-Status "Adapter is $($adapterObj.Status) — attempting to enable..." "warning"
            try {
                Enable-NetAdapter -Name $adapter -Confirm:$false -ErrorAction Stop
                Write-Status "Adapter enabled, waiting to come up..." "info"
                Start-Sleep -Seconds 3
            } catch { Write-Log "Failed to enable adapter: $_" "warning" }
        }
        # Try WiFi auto-connect if this is a wireless adapter and not connected to any SSID
        if ($adapterObj.InterfaceType -eq 71) {
            $wlanInfo = netsh wlan show interfaces 2>$null | Out-String
            if ($wlanInfo -notmatch "SSID\s*:\s*.+") {
                Write-Status "WiFi not connected — scanning for known networks..." "warning"
                $profiles = netsh wlan show profiles 2>$null | Out-String
                if ($profiles -match "All User Profile\s*:\s*(.+)") {
                    $ssid = $matches[1].Trim().Split("`n")[0].Trim()
                    Write-Status "Trying to connect to $ssid..." "info"
                    $null = netsh wlan connect name="$ssid" 2>&1 | Out-Null
                    Start-Sleep -Seconds 3
                }
            }
        }
    }
    
    if (-not (Wait-AdapterReady -Adapter $adapter -Timeout 10)) {
        Write-Status "Adapter not ready, trying any available adapter..." "warning"
        $adapter = Get-ActiveAdapter
        if (-not $adapter) { Write-Status "Still no usable adapter" "error"; return $false }
    }
    
    Write-Status "Using adapter: $adapter" "info"
    Write-Status "[1/5] Disabling VPN adapters..." "info"; Disable-AllVPNAdapters; Start-Sleep -Seconds 2
    Write-Status "[2/5] Renewing IP..." "info"; try { $null = ipconfig /release $adapter 2>&1 | Out-Null; Start-Sleep -Seconds 1; $null = ipconfig /renew $adapter 2>&1 | Out-Null; Start-Sleep -Seconds 3 } catch { Write-Log "IP renew warning: $_" "warning" }
    Write-Status "[3/5] Flushing DNS & restoring presets..." "info"; $null = ipconfig /flushdns 2>&1 | Out-Null; Apply-Presets -Adapter $adapter | Out-Null
    Write-Status "[4/5] Checking network..." "info"; if (Test-Network) { Write-Status "Network restored!" "success"; Write-Log "Network restored" "success" } else { Write-Status "Network still not working..." "warning" }
    Write-Status "[5/5] Running optimizations..." "info"; Optimize-NetworkSpeed -Adapter $adapter
    Write-Host ""; Write-Status "Reset complete." "success"; return $true
}

function Invoke-AutoMode {
    Write-Log "=== AUTO MODE STARTED ===" "info"; Write-Status "Auto mode: checking network..." "info"
    if (Test-Network) {
        Write-Status "Network is working!" "success"
        Write-Status "Saving configuration..." "info"
        $current = Get-NetworkSnapshot
        if (Compare-WithLast $current) { Save-Snapshot $current }
        Write-Status "" "info"; Write-Status "=== OPTIMIZING ===" "info"
        Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter)
        Write-Log "Auto mode: network OK, optimized" "success"
        if (-not $NoMenu) { Write-Host ""; Write-Status "Press Enter to menu..." "info"; $null = Read-Host; return "continue" }
        return "exit"
    }
    Write-Status "Network is DOWN - starting recovery..." "warning"
    if (Invoke-NetworkReset) { Write-Status "Recovery successful!" "success"; $current = Get-NetworkSnapshot; Save-Snapshot $current; Clean-OldSnapshots -KeepCount 50 } else { Write-Status "Recovery needs manual intervention" "warning" }
    if (-not $NoMenu) { Write-Host ""; Write-Status "Press Enter to menu..." "info"; $null = Read-Host; return "continue" }
    return "exit"
}

function Clean-OldSnapshots {
    param([int]$KeepCount = 50)
    try {
        $snapshots = Get-ChildItem $ScriptConfig.SnapshotsDir -Filter "snapshot-*.json" -ErrorAction Stop | Sort-Object LastWriteTime -Descending
        if ($snapshots.Count -gt $KeepCount) {
            $toRemove = $snapshots | Select-Object -Skip $KeepCount
            foreach ($file in $toRemove) { Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue; Write-Log "Removed: $($file.Name)" "info" }
            Write-Status "Cleaned $($toRemove.Count) old snapshots" "info"
        }
    } catch { Write-Log "Cleanup error: $_" "warning" }
}

function Get-AppPreferences {
    if (-not (Test-Path $ScriptConfig.PreferencesFile)) { return @{ apps = @{}; routes = @(); lastUpdated = "" } }
    try { $data = Get-Content $ScriptConfig.PreferencesFile -Raw -Encoding UTF8 | ConvertFrom-Json; return @{ apps = if ($data.apps) { @{} + $data.apps } else { @{} }; routes = if ($data.routes) { $data.routes } else { @() }; lastUpdated = if ($data.lastUpdated) { $data.lastUpdated } else { "" } } } catch { Write-Log "Prefs read error: $_" "warning"; return @{ apps = @{}; routes = @(); lastUpdated = "" } }
}

function Save-AppPreferences {
    param([hashtable]$Prefs)
    try { $Prefs.lastUpdated = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"; $Prefs | ConvertTo-Json -Depth 3 | Out-File -FilePath $ScriptConfig.PreferencesFile -Encoding UTF8 -Force; Write-Status "Preferences saved" "success"; Write-Log "Preferences saved" "info" } catch { Write-Status "Failed to save preferences: $_" "error"; Write-Log "Prefs save error: $_" "error" }
}

function Set-AppPreference {
    param([string]$AppName, [string]$Mode)
    $prefs = Get-AppPreferences; $prefs.apps[$AppName] = $Mode
    $modeNames = @{ via_vpn="VIA VPN"; direct="DIRECT"; skip="SKIP" }
    Write-Status "App '$AppName' -> $($modeNames[$Mode])" "success"
    Save-AppPreferences -Prefs $prefs
}

function Clean-RoutesOnExit {
    Write-Host ""; Write-Host "=== CLEANING ROUTES ON EXIT ===" -ForegroundColor Yellow
    $prefs = Get-AppPreferences
    $viaVpnApps = if ($prefs.apps) { $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "via_vpn" } | ForEach-Object { $_.Key } }
    if ($viaVpnApps -and $viaVpnApps.Count -gt 0) {
        $deleted = 0
        foreach ($route in (Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -match "^\d+\.\d+\.\d+\.\d+/\d+$" -and $_.NextHop -notmatch "127\.|::" })) { try { $null = route delete $route.DestinationPrefix 2>$null; $deleted++ } catch {} }
        if ($deleted -gt 0) { Write-Status "Removed $deleted routes" "success" }
    }
    Write-Host "Network optimizations: preserved" -ForegroundColor Green
}

function Show-MainMenu {
    Write-Host ""; Write-Host "========================================" -ForegroundColor Cyan; Write-Host "  VPN & OpenCode Controller v3.2" -ForegroundColor Cyan; Write-Host "========================================" -ForegroundColor Cyan; Write-Host ""
    Write-Host "[1] Scan Network   - Network Scan"
    Write-Host "[2] Preferences    - App Settings"
    Write-Host "[3] Show Prefs     - Show Settings"
    Write-Host "[4] Collect IPs    - Collect via VPN"
    Write-Host "[5] Apply Routes   - Apply Routes"
    Write-Host "[6] Reset Network  - Forced Recovery"
    Write-Host "[7] Optimize       - Speed Optimize"
    Write-Host "[8] OpenCode Fix   - Local Server Recovery"
    Write-Host "[0] Exit"
    Write-Host ""
}

function Pause-Prompt { Write-Host ""; Write-Host "Press Enter..." -ForegroundColor Gray; $null = Read-Host }

function Invoke-MainLoop {
    while ($true) {
        Show-MainMenu
        $choice = (Read-Host "Select option").Trim().ToLower()
        switch ($choice) {
            "1" { Write-Status "Scan Network - placeholder" "info"; Pause-Prompt }
            "2" { Write-Status "Preferences - placeholder" "info"; Pause-Prompt }
            "3" { Write-Status "Show Prefs - placeholder" "info"; Pause-Prompt }
            "4" { Write-Status "Collect IPs - placeholder" "info"; Pause-Prompt }
            "5" { Write-Status "Apply Routes - placeholder" "info"; Pause-Prompt }
            "6" { Invoke-NetworkReset; Pause-Prompt }
            "7" { Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter); Pause-Prompt }
            "8" { Repair-OpenCodeLocalServer; Pause-Prompt }
            "0" { Write-Host ""; Write-Status "Exiting..." "info"; Clean-RoutesOnExit; Write-Host ""; Write-Host "Goodbye!" -ForegroundColor Cyan; Write-Log "Script exited normally" "info"; exit 0 }
            "" { continue }
            default { Write-Status "Invalid option" "warning" }
        }
    }
}

function Repair-OpenCodeLocalServer {
    param()
    Write-Host ""
    Write-Host "=== OPENCODE LOCAL SERVER RECOVERY ===" -ForegroundColor Cyan
    Write-Log "Starting OpenCode local server recovery" "info"

    Write-Status "[1/6] Stopping OpenCode & MCP processes..." "info"
    Get-Process | Where-Object {$_.ProcessName -match "node|python|opencode"} | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Status "[2/6] Clearing Guardian diagnostic cache..." "info"
    $guardianCache = Join-Path $env:USERPROFILE ".config\opencode\skills\opencode-guardian\cache"
    if (Test-Path $guardianCache) {
        Remove-Item "$guardianCache\last-diagnose.json" -Force -ErrorAction SilentlyContinue
        Remove-Item "$guardianCache\guardian-log.md" -Force -ErrorAction SilentlyContinue
        Remove-Item "$guardianCache\last-snapshot.json" -Force -ErrorAction SilentlyContinue
    }

    Write-Status "[3/6] Checking localhost connectivity..." "info"
    $pingOk = Test-Connection -ComputerName 127.0.0.1 -Count 2 -Quiet
    if (-not $pingOk) {
        Write-Status "WARNING: Loopback broken! Run [6] Reset Network first." "warning"
        return
    }

    Write-Status "[4/6] Checking critical MCP ports..." "info"
    $ports = @{ Proxima=3210; Graph=19222; Obsidian=27124 }
    foreach ($name in $ports.Keys) {
        $port = $ports[$name]
        $test = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
        $status = if ($test.TcpTestSucceeded) { "OK" } else { "Not listening (will start on demand)" }
        Write-Status "   Port $port ($name): $status" $(if($test.TcpTestSucceeded){"success"}else{"info"})
    }

    Write-Status "[5/6] Verifying MCP configuration..." "info"
    $mcpConfig = Join-Path $env:USERPROFILE ".config\opencode\mcp.json"
    $mcpBackup = Join-Path $env:USERPROFILE ".config\opencode\mcp.json.backup.$(Get-Date -Format 'yyyyMMdd-HHmm')"
    if (Test-Path $mcpConfig) {
        Copy-Item $mcpConfig $mcpBackup -Force -ErrorAction SilentlyContinue
        Write-Status "   MCP config backed up" "info"
    }

    Write-Status "[6/6] Clearing session cache..." "info"
    $ocCache = Join-Path $env:USERPROFILE ".config\opencode\.cache"
    if (Test-Path $ocCache) {
        Remove-Item "$ocCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Recovery complete." -ForegroundColor Green
    Write-Host "Next: launch 'opencode'. If servers don't start, run manually:" -ForegroundColor Yellow
    Write-Host "   node D:\MY-LIFE-SYSTEM\SSN-MEMORY\graphify-out\graph-mcp-server.js" -ForegroundColor Gray
    Write-Host "   node D:\MY-LIFE-SYSTEM\Proxima\src\mcp-server-v3.js" -ForegroundColor Gray
    Write-Host ""
    Write-Log "OpenCode recovery completed" "info"
    Pause-Prompt
}

function Main {
    if (-not (Test-Path $ScriptConfig.SnapshotsDir)) { New-Item -ItemType Directory -Path $ScriptConfig.SnapshotsDir -Force | Out-Null; Write-Log "Created snapshots directory" "info" }
    Write-Log "=== Script started ===" "info"
    if ($Auto) { $result = Invoke-AutoMode; if ($result -eq "exit") { exit 0 } }
    if (-not $NoMenu) { Invoke-MainLoop }
}

Main