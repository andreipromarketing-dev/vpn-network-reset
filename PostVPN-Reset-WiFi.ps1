#Requires -Version 5.1
<#
.SYNOPSIS
    Network Smart Reset v5.1
    Auto-detect: if internet DOWN then full reset + optimize; if UP then just optimize
    Use -ForceReset to force adapter reset even when internet works
    Use -Restore to revert all changes from last snapshot
#>

[CmdletBinding()]
param(
    [switch]$ForceReset,
    [switch]$Restore
)

$ScriptConfig = @{
    ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
    LogFile         = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "reset.log"
    ProfileFile     = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "network-profile.json"
    SnapshotFile    = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "reset-snapshot.json"
    PingTimeout     = 2
    VpnPatterns     = @("VPN", "Cisco", "OpenVPN", "WireGuard", "TAP", "TUN", "NordVPN", "ExpressVPN", "CyberGhost", "ChatVPN")
    MaxLogSize      = 1MB
    ProfileSettings = $null
}

function Write-Log {
    param([string]$Message, [string]$Level = "info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    try {
        if ((Get-Item -Path $ScriptConfig.LogFile -ErrorAction SilentlyContinue).Length -gt $ScriptConfig.MaxLogSize) {
            $rotated = $ScriptConfig.LogFile -replace '\.log$', '-old.log'
            Move-Item -Path $ScriptConfig.LogFile -Destination $rotated -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $ScriptConfig.LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Warning "Log write failed: $_" }
}

function Write-Status {
    param([string]$Message, [string]$Type = "info")
    $colors = @{ info="Cyan"; success="Green"; warning="Yellow"; error="Red" }
    Write-Host -ForegroundColor $colors[$Type] $Message
    Write-Log $Message $Type
}

function Get-TcpGlobals {
    <#
        Locale-independent reader for TCP global state.
        Uses Get-NetTCPSetting (CIM API — completely ignores UI language).
        Returns hashtable with normalized lowercase string values:
        CongestionProvider, Timestamps, InitialRto, Rss, AutotuningLevel
        NOTE: netsh output is broken under non-English locales (mojibake),
        so we rely solely on the CIM API + registry.
    #>
    $r = @{ CongestionProvider=$null; Timestamps=$null; InitialRto=$null; Rss=$null; AutotuningLevel=$null }
    try {
        $s = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ($s.CongestionProvider)   { $r.CongestionProvider = "$($s.CongestionProvider)".ToLower() }
        if ($null -ne $s.Timestamps) { $r.Timestamps = if ("$($s.Timestamps)" -match 'Enabled|True|^1$') { 'enabled' } else { 'disabled' } }
        if ($s.AutoTuningLevelLocal) { $r.AutotuningLevel = "$($s.AutoTuningLevelLocal)".ToLower() }
        # NOTE: field is InitialRto (not InitialRtoMs) — value is already in ms.
        if ($s.InitialRto -and [int]$s.InitialRto -gt 0) { $r.InitialRto = "$($s.InitialRto)" }
    } catch { Write-Log "Get-NetTCPSetting failed: $_" "warning" }
    # RSS: registry flag is authoritative on Windows. Adapter RSS may be empty (client Wi-Fi).
    try {
        $rssFlag = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name EnableRSS -ErrorAction SilentlyContinue).EnableRSS
        if ($null -ne $rssFlag) { $r.Rss = if ([int]$rssFlag -eq 1) { 'enabled' } else { 'disabled' } }
    } catch {}
    if (-not $r.Rss) {
        try {
            $ad = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            if ($ad) {
                $arss = Get-NetAdapterRSS -Name $ad.Name -ErrorAction SilentlyContinue
                if ($arss -and $null -ne $arss.Enabled) { $r.Rss = if ($arss.Enabled) { 'enabled' } else { 'disabled' } }
            }
        } catch {}
    }
    if (-not $r.Rss) { $r.Rss = '(unknown)' }
    return $r
}

function Get-DynamicPorts {
    <# Returns @{V4=@{Start;Num}; V6=@{Start;Num}} via Get-NetTCPSetting (locale-independent). #>
    $res = @{ V4=@{Start=$null;Num=$null}; V6=@{Start=$null;Num=$null} }
    try {
        $s = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ($s -and $s.DynamicPortRangeStartPort -and $s.DynamicPortRangeNumberOfPorts) {
            $res.V4.Start = [int]$s.DynamicPortRangeStartPort
            $res.V4.Num   = [int]$s.DynamicPortRangeNumberOfPorts
            # On Windows IPv4 and IPv6 share the same configured range by default.
            $res.V6.Start = $res.V4.Start
            $res.V6.Num   = $res.V4.Num
        }
    } catch { Write-Log "Get-DynamicPorts failed: $_" "warning" }
    return $res
}

function Show-TcpSettings {
    Write-Host ""
    Write-Host "=== CURRENT TCP SETTINGS ===" -ForegroundColor Cyan
    $g = Get-TcpGlobals
    Write-Host "  Congestion Provider : $($g.CongestionProvider)" -ForegroundColor Gray
    Write-Host "  RFC 1323 Timestamps : $($g.Timestamps)" -ForegroundColor Gray
    Write-Host "  Initial RTO         : $(if ($g.InitialRto) { "$($g.InitialRto)ms" } else { '(default)' })" -ForegroundColor Gray
    Write-Host "  RSS State           : $($g.Rss)" -ForegroundColor Gray
    Write-Host "  Auto-Tuning Level   : $($g.AutotuningLevel)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "=== DYNAMIC PORTS ===" -ForegroundColor Cyan
    $dp = Get-DynamicPorts
    if ($dp.V4.Start) { Write-Host "  IPv4: $($dp.V4.Start)-$($dp.V4.Start + $dp.V4.Num - 1) ($($dp.V4.Num) ports)" -ForegroundColor Gray }
    if ($dp.V6.Start) { Write-Host "  IPv6: $($dp.V6.Start)-$($dp.V6.Start + $dp.V6.Num - 1) ($($dp.V6.Num) ports)" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "=== REGISTRY ===" -ForegroundColor Cyan
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    $mup = (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort
    $twd = (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
    Write-Host "  MaxUserPort: $(if ($mup) { $mup } else { '(not set, default 5000)' })" -ForegroundColor Gray
    Write-Host "  TcpTimedWaitDelay: $(if ($twd) { "${twd}s" } else { '(not set, default 120s)' })" -ForegroundColor Gray
    $comp = $ScriptConfig.ProfileSettings.ComputedSettings
    if ($comp) {
        Write-Host ""
        Write-Host "=== OPTIMIZATION TARGETS ===" -ForegroundColor Cyan
        Write-Host "  Timestamps:  $(if ($comp.DisableTimestamps) { 'disabled' } else { 'enabled' })" -ForegroundColor Gray
        Write-Host "  Initial RTO: $($comp.InitialRto)ms" -ForegroundColor Gray
        Write-Host "  Autotuning:  $($comp.AutotuningLevel)" -ForegroundColor Gray
        Write-Host "  Port range:  $($comp.PortRangeStart)-$($comp.PortRangeStart + $comp.PortRangeCount - 1)" -ForegroundColor Gray
        Write-Host "  MaxUserPort: $($comp.MaxUserPort)" -ForegroundColor Gray
        Write-Host "  TcpTimedWaitDelay: $($comp.TcpTimedWaitDelay)s" -ForegroundColor Gray
        Write-Host "  RSS Max CPUs: $($comp.RssMaxProcessors)" -ForegroundColor Gray
    }
    Write-Host ""
}

function Test-Network {
    <#
        Robust connectivity check that doesn't false-positive on DNS/ICMP blocks.
        Strategy (any success => online):
          1) TCP socket to public DNS (port 53) — works even where ICMP is blocked.
          2) Ping multiple public hosts (Cloudflare + Google).
          3) Reachability of local gateway (last resort — only proves LAN).
        Also short-circuits: if IPv4 has no default route at all, we're offline.
    #>
    $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -notmatch "127\.0\.0\.1" } |
        Select-Object -First 1).NextHop
    if (-not $gateway) { return $false }

    # Layer 1: TCP handshake to 53/DNS — fastest, immune to ICMP filtering.
    foreach ($h in @('1.1.1.1','8.8.8.8','9.9.9.9')) {
        try {
            $sock = New-Object System.Net.Sockets.TcpClient
            $iar = $sock.BeginConnect($h, 53, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($ScriptConfig.PingTimeout))) {
                if ($sock.Connected) { $sock.Close(); return $true }
            }
            $sock.Close()
        } catch {}
    }

    # Layer 2: ICMP to public hosts (covers TCP-blocked but ping-open networks).
    foreach ($h in @('1.1.1.1','8.8.8.8')) {
        if (Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
    }

    # Layer 3: gateway only — LAN alive, but internet still likely down.
    return (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

function Get-ActiveAdapter {
    $all = Get-NetAdapter
    $a = $all | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceType -in @(71, 6) -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|TAP|TUN|Bluetooth|isatap|Teredo' } | Select-Object -First 1
    if ($a) { return $a.Name }
    $b = $all | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Virtual|Tunnel' } | Select-Object -First 1
    if ($b) { return $b.Name }
    $c = $all | Where-Object { $_.InterfaceType -in @(71, 6) -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|Bluetooth' } | Select-Object -First 1
    if ($c) { return $c.Name }
    $d = $all | Where-Object { $_.Name -notmatch 'Virtual|Tunnel|Loopback|Bluetooth' } | Select-Object -First 1
    if ($d) { return $d.Name }
    return $null
}

function Disable-AllVPNAdapters {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Name -notmatch 'Bluetooth' }
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
        try { $st = Get-NetAdapter -Name $Adapter -ErrorAction Stop; if ($st.Status -eq "Up") { Write-Log "Adapter ready after ${elapsed}s" "info"; return $true } } catch { }
        Start-Sleep -Seconds 1
        $elapsed++
    }
    Write-Log "Adapter not ready after ${Timeout}s" "warning"
    return $false
}

function Compute-OptimizationSettings {
    param($Profile)
    # Use PHYSICAL cores (was logical processors before — 2x overcount on HT/SMT CPUs).
    $cores = [Math]::Max([int]$Profile.PhysicalCores, 1)
    # RSS queue budget: cap at 4 CPUs by default (Windows sweet spot), more on big desktops.
    $rss = [Math]::Min($cores, 4)
    $linkOk = $Profile.LinkSpeedMbps -and [int]$Profile.LinkSpeedMbps -ge 100
    $rttOk = $Profile.GatewayRttMs -and [int]$Profile.GatewayRttMs -le 50
    # RTT is the dominant factor for RTO: low RTT + good link => 300ms default.
    $initialRto = if ($linkOk -and $rttOk) { 300 } else { 500 }
    $timedWait = if ($rttOk) { 30 } else { 60 }
    # Wi-Fi (type 71) — timestamps off by default (saves header overhead on busy channels).
    $disableTimestamps = ([int]$Profile.InterfaceType -eq 71)
    # Autotuning: "normal" for >=8GB, "restricted" only for tiny RAM (prevents RWIN bloat).
    $autotuning = if ([double]$Profile.RamGB -lt 8) { "restricted" } else { "normal" }
    $enableDca = (-not $Profile.OnBattery)
    if ($Profile.OnBattery) { $rss = [Math]::Max([Math]::Ceiling($rss / 2), 1) }
    # Use the IANA-recommended ephemeral range (49152-65535) instead of the conflicting 10000-65533.
    return @{
        InitialRto=$initialRto
        TcpTimedWaitDelay=$timedWait
        RssMaxProcessors=$rss
        DisableTimestamps=$disableTimestamps
        EnableDca=$enableDca
        AutotuningLevel=$autotuning
        PortRangeStart=49152
        PortRangeCount=16384
        MaxUserPort=65535
        # Cubic is the modern Windows 10/11 default; ctcp was removed in 1709. See Win10+ tuning docs.
        CongestionProvider='cubic'
    }
}

function Get-SystemProfile {
    $profilePath = $ScriptConfig.ProfileFile
    if (Test-Path $profilePath) {
        try {
            $cached = Get-Content $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $currentAdapter = Get-ActiveAdapter
            $cacheAge = [datetime]::Now - [datetime]$cached.DetectedAt
            $adapterOk = ($cached.AdapterName -eq $currentAdapter)
            $speedOk = $true
            if ($currentAdapter -and $cached.LinkSpeedMbps) {
                $linkStr = (Get-NetAdapter -Name $currentAdapter -ErrorAction SilentlyContinue).LinkSpeed
                if ($linkStr -match '(\d+)') {
                    $currentSpeed = [int]$matches[1]
                    $ratio = [Math]::Abs($currentSpeed - [int]$cached.LinkSpeedMbps) / [Math]::Max($currentSpeed, 1)
                    $speedOk = ($ratio -lt 0.5)
                }
            }
            if ($cacheAge.TotalDays -le 7 -and $adapterOk -and $speedOk) {
                Write-Log "System profile loaded from cache" "info"
                return $cached
            }
            Write-Log "Profile cache stale (age=$([int]$cacheAge.TotalDays)d adapter=$adapterOk speed=$speedOk)" "info"
        } catch { Write-Log "Profile cache read failed: $_" "warning" }
    }
    Write-Status "Detecting system parameters..." "info"
    $adapter = Get-ActiveAdapter
    $adapterObj = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
    $linkSpeed = $null
    if ($adapterObj) {
        $linkStr = $adapterObj.LinkSpeed
        if ($linkStr -match '(\d+)\s*(Mbps|Gbps)') {
            $linkSpeed = [int]$matches[1]
            if ($matches[2] -eq 'Gbps') { $linkSpeed = $linkSpeed * 1000 }
        }
    }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        # PHYSICAL cores via Win32_Processor.NumberOfCores (sum across sockets for safety).
        # Was NumberOfLogicalProcessors before — overcounted 2x on HT/SMT CPUs (e.g. 8C/16T -> 16).
        $procs = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
        $cores = ($procs | ForEach-Object { [int]$_.NumberOfCores } | Measure-Object -Sum).Sum
        if (-not $cores -or $cores -le 0) {
            # Fallback: logical/2 (assumes SMT/HT enabled) — still better than the old "use logical" bug.
            $logical = $cs.NumberOfLogicalProcessors
            $cores = if ($logical -and $logical -ge 2) { [Math]::Max([Math]::Round($logical / 2), 1) } else { 2 }
        }
    } catch { Write-Log "CIM query failed: $_" "warning"; $ramGB = 8; $cores = 2 }
    $onBattery = $false
    try { $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue; if ($batt -and $batt.BatteryStatus -ne 2) { $onBattery = $true } } catch {}
    $rttMs = $null
    try {
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -notmatch '127\.0\.0\.1' } | Select-Object -First 1).NextHop
        if ($gateway) {
            $ping = Test-Connection -ComputerName $gateway -Count 3 -ErrorAction SilentlyContinue
            if ($ping) { $rttMs = [Math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 0) }
        }
    } catch {}
    $profile = @{ DetectedAt=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss"); AdapterName=$adapter; InterfaceType=$adapterObj.InterfaceType; LinkSpeedMbps=$linkSpeed; PhysicalCores=$cores; RamGB=$ramGB; GatewayRttMs=$rttMs; OnBattery=$onBattery }
    $profile.ComputedSettings = Compute-OptimizationSettings $profile
    try {
        $profile | ConvertTo-Json -Depth 3 | Set-Content -Path $profilePath -Encoding UTF8 -Force
        Write-Status "System profile saved to $(Split-Path $profilePath -Leaf)" "success"
    } catch { Write-Log "Profile save failed: $_" "warning" }
    return [PSCustomObject]$profile
}

function Save-Snapshot {
    param([string]$Adapter)
    $snapPath = $ScriptConfig.SnapshotFile
    if (Test-Path $snapPath) {
        # Backup existing snapshot instead of refusing — last run may have left unapplied changes.
        $backupPath = $snapPath -replace '\.json$', "-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        Move-Item -Path $snapPath -Destination $backupPath -Force -ErrorAction SilentlyContinue
        Write-Status "Previous snapshot backed up: $(Split-Path $backupPath -Leaf)" "info"
    }
    Write-Status "Saving pre-modification snapshot..." "info"
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    $snap = @{ TakenAt=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss"); RegMaxUserPort=$null; RegTcpTimedWaitDelay=$null; TcpCongestionProvider=$null; TcpTimestamps=$null; TcpInitialRto=$null; TcpRss=$null; TcpRssMaxProcessors=$null; TcpAutotuningLevel=$null; DynamicPortV4Start=$null; DynamicPortV4Num=$null; DynamicPortV6Start=$null; DynamicPortV6Num=$null; DnsServers=$null; SavedSsid=$null }
    $p1 = Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue
    $snap.RegMaxUserPort = if ($null -ne $p1.MaxUserPort) { $p1.MaxUserPort } else { $null }
    $p2 = Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue
    $snap.RegTcpTimedWaitDelay = if ($null -ne $p2.TcpTimedWaitDelay) { $p2.TcpTimedWaitDelay } else { $null }
    $g = Get-TcpGlobals
    $snap.TcpCongestionProvider = $g.CongestionProvider
    $snap.TcpTimestamps         = $g.Timestamps
    $snap.TcpInitialRto         = $g.InitialRto
    $snap.TcpRss                = $g.Rss
    $snap.TcpAutotuningLevel    = $g.AutotuningLevel
    # Capture RSS max processors per active adapter (locale-independent API).
    if ($Adapter) {
        try {
            $arss = Get-NetAdapterRSS -Name $Adapter -ErrorAction SilentlyContinue
            if ($arss -and $null -ne $arss.MaxProcessors) { $snap.TcpRssMaxProcessors = [int]$arss.MaxProcessors }
        } catch {}
    }
    $dp = Get-DynamicPorts
    if ($dp.V4.Start) { $snap.DynamicPortV4Start = $dp.V4.Start; $snap.DynamicPortV4Num = $dp.V4.Num }
    if ($dp.V6.Start) { $snap.DynamicPortV6Start = $dp.V6.Start; $snap.DynamicPortV6Num = $dp.V6.Num }
    if ($Adapter) {
        try {
            $ifIdx = (Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue).ifIndex
            if ($ifIdx) { $dns = Get-DnsClientServerAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue; if ($dns -and $dns.ServerAddresses) { $snap.DnsServers = $dns.ServerAddresses -join ',' } }
        } catch { Write-Log "DNS capture failed: $_" "warning" }
    # Save current WiFi SSID (locale-independent) for reconnect after reset.
    if ($Adapter) {
        try {
            $profile = Get-NetConnectionProfile -InterfaceAlias $Adapter -ErrorAction SilentlyContinue |
                Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
            if ($profile) { $snap.SavedSsid = $profile.Name }
        } catch {}
    }
    }
    $tmpPath = $snapPath + '.tmp'
    try {
        $snap | ConvertTo-Json | Set-Content -Path $tmpPath -Encoding UTF8 -Force
        Move-Item -Path $tmpPath -Destination $snapPath -Force
        Write-Status "Pre-modification snapshot saved" "success"
        return $true
    } catch {
        Write-Log "Snapshot write failed: $_" "error"
        Remove-Item -Path $tmpPath -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-Restore {
    $snapPath = $ScriptConfig.SnapshotFile
    if (-not (Test-Path $snapPath)) {
        Write-Status "No snapshot found to restore" "error"
        return $false
    }
    Write-Status "=== RESTORING PREVIOUS STATE ===" "warning"
    try { $snap = Get-Content $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Status "Failed to read snapshot: $_" "error"; return $false }
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"

    Write-Status "[1/4] Restoring registry..." "info"
    try {
        if ([string]::IsNullOrEmpty("$($snap.RegMaxUserPort)")) {
            Remove-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue
            Write-Status "MaxUserPort restored (key removed)" "success"
        } else {
            Set-ItemProperty $regPath -Name MaxUserPort -Value $snap.RegMaxUserPort
            Write-Status "MaxUserPort restored to $($snap.RegMaxUserPort)" "success"
        }
    } catch { Write-Log "MaxUserPort restore failed: $_" "warning" }
    try {
        if ([string]::IsNullOrEmpty("$($snap.RegTcpTimedWaitDelay)")) {
            Remove-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue
            Write-Status "TcpTimedWaitDelay restored (key removed)" "success"
        } else {
            Set-ItemProperty $regPath -Name TcpTimedWaitDelay -Value $snap.RegTcpTimedWaitDelay
            Write-Status "TcpTimedWaitDelay restored to $($snap.RegTcpTimedWaitDelay)" "success"
        }
    } catch { Write-Log "TcpTimedWaitDelay restore failed: $_" "warning" }

    Write-Status "[2/4] Restoring TCP globals..." "info"
    $validProviders = @('ctcp','cubic','newreno','compoundtcp','dctcp','bbr2','default','none')
    try {
        if ($snap.TcpCongestionProvider -and $validProviders -contains "$($snap.TcpCongestionProvider)".ToLower()) {
            netsh int tcp set supplemental template=internet congestionprovider=$($snap.TcpCongestionProvider) 2>&1 | Out-Null
            Write-Status "CongestionProvider restored: $($snap.TcpCongestionProvider)" "success"
        } else { Write-Status "CongestionProvider: kept (value not restorable)" "warning" }
    } catch { Write-Log "CongestionProvider restore failed: $_" "warning" }
    try { if ($snap.TcpTimestamps -in @('enabled','disabled')) { netsh int tcp set global timestamps=$($snap.TcpTimestamps) 2>&1 | Out-Null; Write-Status "Timestamps restored: $($snap.TcpTimestamps)" "success" } } catch { Write-Log "Timestamps restore failed: $_" "warning" }
    try { if ($snap.TcpInitialRto -match '^\d+$') { netsh int tcp set global initialRto=$($snap.TcpInitialRto) 2>&1 | Out-Null; Write-Status "InitialRTO restored: $($snap.TcpInitialRto)" "success" } } catch { Write-Log "InitialRTO restore failed: $_" "warning" }
    try { if ($snap.TcpRss -in @('enabled','disabled')) { netsh int tcp set global rss=$($snap.TcpRss) 2>&1 | Out-Null; Write-Status "RSS restored: $($snap.TcpRss)" "success" } } catch { Write-Log "RSS restore failed: $_" "warning" }
    try { if ($snap.TcpAutotuningLevel -and "$($snap.TcpAutotuningLevel)" -ne '') { netsh int tcp set global autotuninglevel=$($snap.TcpAutotuningLevel) 2>&1 | Out-Null; Write-Status "Autotuning restored: $($snap.TcpAutotuningLevel)" "success" } } catch { Write-Log "Autotuning restore failed: $_" "warning" }
    if ($snap.TcpRssMaxProcessors -and $snap.TcpRss -eq 'enabled') {
        try {
            $ad = Get-ActiveAdapter
            if ($ad) {
                $arss = Get-NetAdapterRSS -Name $ad -ErrorAction SilentlyContinue
                if ($arss -and $arss.Enabled) { Set-NetAdapterRSS -Name $ad -MaxProcessors $snap.TcpRssMaxProcessors -ErrorAction SilentlyContinue; Write-Status "RSS MaxProcessors restored: $($snap.TcpRssMaxProcessors)" "success" }
            }
        } catch { Write-Log "RSS MaxProcessors restore failed: $_" "warning" }
    }

    Write-Status "[3/4] Restoring dynamic port ranges..." "info"
    try { if ($snap.DynamicPortV4Start -and $snap.DynamicPortV4Num) { netsh int ipv4 set dynamicport tcp start=$($snap.DynamicPortV4Start) num=$($snap.DynamicPortV4Num) 2>&1 | Out-Null; Write-Status "IPv4 ports restored" "success" } } catch { Write-Log "Port v4 restore failed: $_" "warning" }
    try { if ($snap.DynamicPortV6Start -and $snap.DynamicPortV6Num) { netsh int ipv6 set dynamicport tcp start=$($snap.DynamicPortV6Start) num=$($snap.DynamicPortV6Num) 2>&1 | Out-Null; Write-Status "IPv6 ports restored" "success" } } catch { Write-Log "Port v6 restore failed: $_" "warning" }

    Write-Status "[4/4] Flushing DNS..." "info"
    try { ipconfig /flushdns 2>&1 | Out-Null; Write-Status "DNS flushed" "success" } catch {}
    $restoredPath = $snapPath -replace '\.json$', "-restored-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    Move-Item -Path $snapPath -Destination $restoredPath -Force
    Write-Status "Restore complete. Snapshot archived: $(Split-Path $restoredPath -Leaf)" "success"
    Write-Log "State restored from snapshot" "success"
    return $true
}

function Invoke-TcpStep {
    <#
        Generic before/after step wrapper (locale-independent).
        - $Index     step number like '1/9'
        - $Title     human label e.g. 'Timestamps'
        - $Apply     scriptblock that performs the change
        - $Verify    scriptblock returning current value AFTER change (string)
        - $Expected  the value we expect to see if change succeeded
    #>
    param(
        [string]$Index, [string]$Title,
        [scriptblock]$Apply, [scriptblock]$Verify, [string]$Expected,
        [string]$Before
    )
    Write-Host "  [$Index] $($Title): $Before -> $Expected" -ForegroundColor Gray
    try {
        & $Apply
        $after = & $Verify
        if ("$after" -eq "$Expected") { Write-Status "  $($Title): $Before -> $after" "success" }
        else { Write-Status "  $($Title): failed (current: $after)" "warning" }
    } catch { Write-Log "$Title step failed: $_" "warning"; Write-Status "  $($Title): exception - $_" "warning" }
}

function Optimize-NetworkSpeed {
    param([string]$Adapter)
    $comp = $ScriptConfig.ProfileSettings.ComputedSettings
    if (-not $comp) {
        Write-Status "No computed settings available, using defaults" "warning"
        return
    }

    Write-Host ""
    Write-Host "=== OPTIMIZING NETWORK SPEED ===" -ForegroundColor Cyan

    # Snapshot of current state to display as "before" — locale-independent.
    $gBefore = Get-TcpGlobals
    $dpBefore = Get-DynamicPorts

    # [1/9] Congestion provider. CTCP is unsupported on modern Windows (removed in 1709).
    # Prefer 'cubic' (modern Windows default, good RTT/loss behaviour) over the legacy 'ctcp'.
    $provider = if ($comp.CongestionProvider) { $comp.CongestionProvider } else { 'cubic' }
    $validProviders = @('cubic','ctcp','newreno','compoundtcp','dctcp','bbr2','default')
    $providerStr = if ($validProviders -contains "$provider".ToLower()) { $provider } else { 'cubic' }
    Invoke-TcpStep -Index '1/9' -Title 'CongestionProvider' `
        -Apply  { netsh int tcp set supplemental template=internet congestionprovider=$providerStr 2>&1 | Out-Null } `
        -Verify { (Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue).CongestionProvider } `
        -Expected $providerStr `
        -Before "$(if($gBefore.CongestionProvider){$gBefore.CongestionProvider}else{'default'})"

    # [2/9] Timestamps
    $ts = if ($comp.DisableTimestamps) { 'disabled' } else { 'enabled' }
    Invoke-TcpStep -Index '2/9' -Title 'Timestamps' `
        -Apply  { netsh int tcp set global timestamps=$ts 2>&1 | Out-Null } `
        -Verify { $t = (Get-NetTCPSetting -SettingName Internet).Timestamps; if ("$t" -match 'Enabled|True|1') {'enabled'} else {'disabled'} } `
        -Expected $ts `
        -Before "$(if($gBefore.Timestamps){$gBefore.Timestamps}else{'(default)'})"

    # [3/9] Initial RTO
    $rtoBefore = if ($gBefore.InitialRto) { "$($gBefore.InitialRto)ms" } else { '(default)' }
    Invoke-TcpStep -Index '3/9' -Title 'Initial RTO' `
        -Apply  { netsh int tcp set global initialRto=$($comp.InitialRto) 2>&1 | Out-Null } `
        -Verify { (Get-TcpGlobals).InitialRto } `
        -Expected "$($comp.InitialRto)" `
        -Before $rtoBefore

    # [4/9] RSS — only on adapters that support it (Wi-Fi adapters often don't).
    $rssBefore = if ($gBefore.Rss) { $gBefore.Rss } else { '(not supported)' }
    $rssSupported = $false
    if ($Adapter) {
        try { $arss = Get-NetAdapterRSS -Name $Adapter -ErrorAction Stop; $rssSupported = [bool]$arss } catch { $rssSupported = $false }
    }
    if ($rssSupported) {
        Invoke-TcpStep -Index '4/9' -Title 'RSS' `
            -Apply  { netsh int tcp set global rss=enabled 2>&1 | Out-Null } `
            -Verify { (Get-TcpGlobals).Rss } `
            -Expected 'enabled' `
            -Before $rssBefore
        if ($comp.RssMaxProcessors -and $comp.RssMaxProcessors -gt 0) {
            try {
                Set-NetAdapterRSS -Name $Adapter -MaxProcessors $comp.RssMaxProcessors -ErrorAction SilentlyContinue
                Write-Status "  RSS MaxProcessors set to $($comp.RssMaxProcessors)" "success"
            } catch { Write-Status "  RSS MaxProcessors: not supported on this adapter" "warning" }
        }
    } else {
        Write-Status "  [4/9] RSS: skipped (adapter has no RSS support)" "info"
    }
    # DCA: server-only feature, informational only — never fatal on client hardware.
    if ($comp.EnableDca) {
        try {
            reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v EnableDca /t REG_DWORD /d 1 /f 2>&1 | Out-Null
            $dcaVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name EnableDca -ErrorAction SilentlyContinue).EnableDca
            if ($dcaVal -eq 1) { Write-Status "  DCA: enabled" "success" }
            else { Write-Status "  DCA: not supported by hardware (safe to ignore)" "info" }
        } catch { Write-Status "  DCA: skipped (not supported)" "info" }
    } else { Write-Status "  DCA: skipped (battery mode)" "info" }

    # [5/9] Dynamic port range
    $endPort = $comp.PortRangeStart + $comp.PortRangeCount - 1
    $portBefore = if ($dpBefore.V4.Start) { "$($dpBefore.V4.Start)-$($dpBefore.V4.Start + $dpBefore.V4.Num - 1)" } else { '(default)' }
    Invoke-TcpStep -Index '5/9' -Title 'Port range' `
        -Apply  {
            netsh int ipv4 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
            netsh int ipv6 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
        } `
        -Verify { $d = Get-DynamicPorts; if ($d.V4.Start) { "$($d.V4.Start)" } else { '' } } `
        -Expected "$($comp.PortRangeStart)" `
        -Before $portBefore

    # [6/9] MaxUserPort (registry)
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    $mupBefore = (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort
    $mupBeforeStr = if ($mupBefore) { "$mupBefore" } else { '5000 (default)' }
    Invoke-TcpStep -Index '6/9' -Title 'MaxUserPort' `
        -Apply  { reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /d $($comp.MaxUserPort) /t REG_DWORD /f 2>&1 | Out-Null } `
        -Verify { (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort } `
        -Expected $comp.MaxUserPort `
        -Before $mupBeforeStr

    # [7/9] TcpTimedWaitDelay (registry)
    $twdBefore = (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
    $twdBeforeStr = if ($twdBefore) { "${twdBefore}s" } else { '120s (default)' }
    Invoke-TcpStep -Index '7/9' -Title 'TcpTimedWaitDelay' `
        -Apply  { reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /d $($comp.TcpTimedWaitDelay) /t REG_DWORD /f 2>&1 | Out-Null } `
        -Verify { (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay } `
        -Expected $comp.TcpTimedWaitDelay `
        -Before $twdBeforeStr

    # [8/9] Auto-tuning level
    Invoke-TcpStep -Index '8/9' -Title 'Auto-tuning' `
        -Apply  { netsh int tcp set global autotuninglevel=$($comp.AutotuningLevel) 2>&1 | Out-Null } `
        -Verify { (Get-NetTCPSetting -SettingName Internet).AutoTuningLevelLocal } `
        -Expected $comp.AutotuningLevel `
        -Before "$(if($gBefore.AutotuningLevel){$gBefore.AutotuningLevel}else{'(default)'})"

    # [9/9] Flush DNS
    Write-Host "  [9/9] Flushing DNS cache..." -ForegroundColor Gray
    try { ipconfig /flushdns 2>&1 | Out-Null; Write-Status "  DNS cache flushed" "success" } catch { Write-Log "DNS flush step failed: $_" "warning" }

    if ($Adapter) {
        try { $ai = Get-NetAdapter -Name $Adapter -ErrorAction Stop; Write-Status "Link speed: $($ai.LinkSpeed)" "info" } catch { }
    }

    Write-Status "" "info"

    # === POST-OPTIMIZATION CONNECTIVITY CHECK ===
    Write-Host ""
    Write-Host "=== POST-OPTIMIZATION CHECK ===" -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    if (Test-Network) {
        Write-Status "Internet connectivity: OK" "success"
        Write-Status "Optimization complete!" "success"
        Write-Status "Some changes require reboot to take full effect." "warning"
        Write-Log "Optimization completed, connectivity verified" "info"
        return $true
    } else {
        Write-Status "Internet connectivity: FAILED" "error"
        Write-Status "Optimization broke connection — rolling back..." "error"
        Write-Log "Post-optimization check FAILED, auto-restoring" "error"
        $restoreResult = Invoke-Restore
        if ($restoreResult) {
            Start-Sleep -Seconds 3
            if (Test-Network) {
                Write-Status "Rollback successful — connection restored!" "success"
                Write-Log "Auto-rollback succeeded" "info"
            } else {
                Write-Status "WARNING: Rollback done but internet still down — check router/ISP" "error"
                Write-Log "Auto-rollback done, connectivity still failed" "error"
            }
        }
        return $false
    }
}

function Invoke-NetworkReset {
    Write-Host ""
    Write-Host "=== NETWORK RESET ===" -ForegroundColor Cyan
    Write-Log "Starting network reset" "info"
    $adapter = Get-ActiveAdapter
    if (-not $adapter) {
        Write-Status "No adapter found at all!" "error"
        Write-Log "Reset aborted: no adapter" "error"
        return $false
    }
    $adapterObj = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
    if ($adapterObj) {
        if ($adapterObj.Status -ne 'Up') {
            Write-Status "Adapter is $($adapterObj.Status) - attempting to enable..." "warning"
            try {
                Enable-NetAdapter -Name $adapter -Confirm:$false -ErrorAction Stop
                Write-Status "Adapter enabled, waiting to come up..." "info"
                Start-Sleep -Seconds 3
            } catch { Write-Log "Failed to enable adapter: $_" "warning" }
        }
        if ($adapterObj.InterfaceType -eq 71) {
            # Use CIM API (locale-independent) instead of netsh wlan (mojibake on non-English).
            $profile = Get-NetConnectionProfile -InterfaceAlias $adapter -ErrorAction SilentlyContinue |
                Where-Object { $_.IPv4Connectivity -eq 'Internet' } | Select-Object -First 1
            $savedSsid = if ($profile) { $profile.Name } else { $null }
            if (-not $savedSsid) {
                Write-Status "WiFi not connected — checking saved SSID from snapshot..." "warning"
                if (Test-Path $ScriptConfig.SnapshotFile) {
                    try {
                        $snap = Get-Content $ScriptConfig.SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($snap.SavedSsid) { $savedSsid = $snap.SavedSsid }
                    } catch {}
                }
            }
            if ($savedSsid) {
                Write-Status "Reconnecting to: $savedSsid" "info"
                $null = netsh wlan connect name="$savedSsid" 2>&1 | Out-Null
                Start-Sleep -Seconds 3
            } else {
                Write-Status "No known SSID found — WiFi must be reconnected manually" "warning"
            }
        }
    }
    if (-not (Wait-AdapterReady -Adapter $adapter -Timeout 10)) {
        Write-Status "Adapter not ready, trying any available adapter..." "warning"
        $adapter = Get-ActiveAdapter
        if (-not $adapter) {
            Write-Status "Still no usable adapter" "error"
            return $false
        }
    }
    Write-Status "Using adapter: $adapter" "info"
    $ifIndex = (Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue).ifIndex
    if (-not $ifIndex) { Write-Status "Adapter $adapter lost" "error"; return $false }
    Write-Status "[1/5] Disabling VPN adapters..." "info"
    Disable-AllVPNAdapters
    Start-Sleep -Seconds 2
    Write-Status "[2/5] Renewing IP..." "info"
    try {
        ipconfig /release $adapter 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        ipconfig /renew $adapter 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $ipInfo = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' }
        if ($ipInfo) {
            Write-Status "IP renewed: $($ipInfo.IPAddress)" "success"
        } else {
            Write-Status "IP renewal completed (check connectivity)" "success"
        }
    } catch { Write-Log "IP renew error: $_" "warning" }
    Write-Status "[3/5] Flushing DNS and cleaning routes..." "info"
    try {
        ipconfig /flushdns 2>&1 | Out-Null
        $null = netsh int ip delete destinationcache 2>&1
        Write-Status "DNS flushed, route cache cleared" "success"
    } catch { Write-Log "Route cache warning: $_" "warning" }
    Write-Status "[4/5] Checking network..." "info"
    $networkOk = $false
    for ($i = 1; $i -le 3; $i++) {
        if (Test-Network) {
            Write-Status "Network restored! (attempt $i)" "success"
            Write-Log "Network restored after $i attempt(s)" "success"
            $networkOk = $true
            break
        } elseif ($i -lt 3) {
            Write-Status "Network not yet available... retrying" "warning"
            Start-Sleep -Seconds 5
        } else {
            Write-Status "Network still not working after 3 attempts" "error"
            Write-Log "Network recovery failed after 3 attempts" "error"
        }
    }
    if (-not $networkOk) { return $false }
    Write-Status "[5/5] Running optimizations..." "info"
    $optResult = Optimize-NetworkSpeed -Adapter $adapter
    Write-Host ""
    if ($optResult) {
        Write-Status "Reset + optimize complete." "success"
    } else {
        Write-Status "Reset complete, but optimizations rolled back (connectivity protected)." "warning"
    }
    return $true
}

function Invoke-SmartMode {
    Write-Log "=== Smart mode started ===" "info"
    $needReset = $ForceReset -or (-not (Test-Network))

    if ($needReset) {
        if ($ForceReset) {
            Write-Status "Force mode: resetting adapter..." "warning"
        } else {
            Write-Status "Network is DOWN - starting recovery..." "warning"
        }
        $success = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            if (Invoke-NetworkReset) {
                $success = $true
                break
            }
            if ($attempt -lt 3) {
                Write-Status "Reset failed, retrying ($attempt/3)..." "warning"
                Start-Sleep -Seconds 3
            }
        }
        if ($success) {
            Write-Status "Network restored successfully!" "success"
            Write-Log "Network recovered after reset" "success"
        } else {
            Write-Status "Reset failed after 3 attempts. Check router or cable." "error"
            Write-Log "Reset failed after 3 attempts" "error"
        }
    } else {
        Write-Status "Network is working - running optimization..." "success"
        $optResult = Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter)
        if ($optResult) {
            Write-Status "Optimization done!" "success"
        } else {
            Write-Status "Optimization rolled back to protect connectivity." "warning"
        }
        Write-Log "Optimize done (applied=$optResult), network was OK" "info"
    }
}

function Check-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "This script requires Administrator privileges." -ForegroundColor Red
        Write-Host "Restart with 'Run as Administrator' or use Reset-Network.bat" -ForegroundColor Yellow
        throw "Not running as Administrator"
    }
}

function Main {
    Check-Admin
    Write-Log "=== Script started (ForceReset=$ForceReset Restore=$Restore) ===" "info"

    if ($Restore) {
        Invoke-Restore
        return
    }

    if (Test-Path $ScriptConfig.SnapshotFile) {
        Write-Host ""
        Write-Host "WARNING: Previous run may have left unapplied changes." -ForegroundColor Yellow
        Write-Host "  [U] Undo -- restore to pre-change state" -ForegroundColor Yellow
        Write-Host "  [C] Continue -- overwrite snapshot, start fresh" -ForegroundColor Yellow
        Write-Host "  [Q] Quit" -ForegroundColor Yellow
        Write-Host ""
        switch ((Read-Host "Choose [U/C/Q]").ToUpper()) {
            'U' { Invoke-Restore; return }
            'C' { Remove-Item -Path $ScriptConfig.SnapshotFile -Force; Write-Status "Old snapshot removed" "warning" }
            default { return }
        }
    }

    $ScriptConfig.ProfileSettings = Get-SystemProfile
    if (-not (Save-Snapshot -Adapter (Get-ActiveAdapter))) {
        Write-Status "No snapshot - cannot guarantee restore if something breaks" "warning"
        Write-Status "Continue anyway? [Y/N]" "warning"
        if ((Read-Host).ToUpper() -ne 'Y') { return }
    }
    Invoke-SmartMode

    do {
        $netOk = Test-Network
        $netIcon = if ($netOk) { "[ONLINE]" } else { "[OFFLINE]" }
        $netColor = if ($netOk) { "Green" } else { "Red" }
        Write-Host ""
        Write-Host "=== NETWORK MENU ===" -ForegroundColor Cyan
        Write-Host -NoNewline "  Status: "; Write-Host $netIcon -ForegroundColor $netColor
        Write-Host "  [S] Show current TCP settings and optimization plan"
        Write-Host "  [O] Optimize only (safe, no adapter reset)"
        Write-Host "  [R] Full reset + optimize (drops connection briefly)"
        Write-Host "  [U] Undo all changes (restore snapshot)"
        Write-Host "  [Q] Quit"
        Write-Host ""
        $mc = (Read-Host "Choose [S/O/R/U/Q]").ToUpper()
        switch ($mc) {
            'S' { Show-TcpSettings }
            'O' { Write-Log "Menu: Optimize only" "info"; Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter) }
            'R' { Write-Log "Menu: Full reset" "info"; Invoke-NetworkReset }
            'U' { Write-Log "Menu: Undo" "info"; Invoke-Restore }
        }
    } while ($mc -ne 'Q')
}

Main