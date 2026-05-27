<#
.SYNOPSIS
    Network Smart Reset v5.0
    Auto-detect: if internet DOWN then full reset + optimize; if UP then just optimize
    Use -ForceReset to force adapter reset even when internet works
#>

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
    AdapterTimeout  = 15
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

function Test-Network {
    param([string]$TestHost = "8.8.8.8")
    try {
        $ping = Test-Connection -ComputerName $TestHost -Count 2 -Quiet -ErrorAction Stop
        if ($ping) { return $true }
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -and $_.NextHop -notmatch "127\.0\.0\.1" } | Select-Object -First 1).NextHop
        if ($gateway) { return (Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue) }
        return $false
    } catch { Write-Log "Test-Network error: $_" "warning"; return $false }
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
    $cores = [Math]::Max([int]$Profile.PhysicalCores, 1)
    $rss = [Math]::Min($cores, 4)
    $linkOk = $Profile.LinkSpeedMbps -and [int]$Profile.LinkSpeedMbps -ge 100
    $rttOk = $Profile.GatewayRttMs -and [int]$Profile.GatewayRttMs -le 50
    $initialRto = if ($linkOk -and $rttOk) { 300 } else { 500 }
    $timedWait = if ($rttOk) { 30 } else { 60 }
    $disableTimestamps = ([int]$Profile.InterfaceType -eq 71)
    $autotuning = if ([double]$Profile.RamGB -lt 8) { "restricted" } else { "normal" }
    $enableDca = (-not $Profile.OnBattery)
    if ($Profile.OnBattery) { $rss = [Math]::Max([Math]::Ceiling($rss / 2), 1) }
    return @{ InitialRto=$initialRto; TcpTimedWaitDelay=$timedWait; RssMaxProcessors=$rss; DisableTimestamps=$disableTimestamps; EnableDca=$enableDca; AutotuningLevel=$autotuning; PortRangeStart=10000; PortRangeCount=55534; MaxUserPort=65534 }
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
            if ($cacheAge.TotalDays -le 30 -and $adapterOk -and $speedOk) {
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
        $cores = $cs.NumberOfLogicalProcessors
        if (-not $cores -or $cores -le 0) { $cores = 2 }
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
        Write-Status "Snapshot already exists" "warning"
        Write-Status "Previous run may have left changes. Use -Restore to revert or -Force to overwrite." "warning"
        return $false
    }
    Write-Status "Saving pre-modification snapshot..." "info"
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    $snap = @{ TakenAt=(Get-Date -Format "yyyy-MM-ddTHH:mm:ss"); RegMaxUserPort=$null; RegTcpTimedWaitDelay=$null; TcpCongestionProvider=$null; TcpTimestamps=$null; TcpInitialRto=$null; TcpRss=$null; TcpAutotuningLevel=$null; DynamicPortV4Start=$null; DynamicPortV4Num=$null; DynamicPortV6Start=$null; DynamicPortV6Num=$null; DnsServers=$null }
    $p1 = Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue
    $snap.RegMaxUserPort = if ($null -ne $p1) { $p1.MaxUserPort } else { $null }
    $p2 = Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue
    $snap.RegTcpTimedWaitDelay = if ($null -ne $p2) { $p2.TcpTimedWaitDelay } else { $null }
    $globalText = netsh int tcp show global | Out-String
    $lines = $globalText -split "`r`n|`n"
    foreach ($ln in $lines) {
        if ($ln -match '^\s*Congestion Provider\s*:\s*(.+)') { $snap.TcpCongestionProvider = $matches[1].Trim() }
        if ($ln -match '^\s*Timestamps\s*:\s*(.+)') { $snap.TcpTimestamps = $matches[1].Trim() }
        if ($ln -match '^\s*Initial RTO\s*:\s*(.+)') { $snap.TcpInitialRto = $matches[1].Trim() }
        if ($ln -match '^\s*Receive-Side Scaling State\s*:\s*(.+)') { $snap.TcpRss = $matches[1].Trim() }
        if ($ln -match '^\s*Autotuninglevel\s*:\s*(.+)') { $snap.TcpAutotuningLevel = $matches[1].Trim() }
    }
    $v4t = netsh int ipv4 show dynamicport tcp | Out-String
    $v6t = netsh int ipv6 show dynamicport tcp | Out-String
    if ($v4t -match 'start\s*:\s*(\d+)\s*num\s*:\s*(\d+)') { $snap.DynamicPortV4Start = [int]$matches[1]; $snap.DynamicPortV4Num = [int]$matches[2] }
    if ($v6t -match 'start\s*:\s*(\d+)\s*num\s*:\s*(\d+)') { $snap.DynamicPortV6Start = [int]$matches[1]; $snap.DynamicPortV6Num = [int]$matches[2] }
    if ($Adapter) {
        try {
            $ifIdx = (Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue).ifIndex
            if ($ifIdx) { $dns = Get-DnsClientServerAddress -InterfaceIndex $ifIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue; if ($dns -and $dns.ServerAddresses) { $snap.DnsServers = $dns.ServerAddresses -join ',' } }
        } catch { Write-Log "DNS capture failed: $_" "warning" }
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
    try { if ([string]::IsNullOrEmpty("$($snap.RegMaxUserPort)")) { Remove-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue; Write-Status "MaxUserPort restored (key removed)" "success" } else { Set-ItemProperty $regPath -Name MaxUserPort -Value $snap.RegMaxUserPort; Write-Status "MaxUserPort restored to $($snap.RegMaxUserPort)" "success" } } catch { Write-Log "MaxUserPort restore failed: $_" "warning" }
    try { if ([string]::IsNullOrEmpty("$($snap.RegTcpTimedWaitDelay)")) { Remove-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue; Write-Status "TcpTimedWaitDelay restored (key removed)" "success" } else { Set-ItemProperty $regPath -Name TcpTimedWaitDelay -Value $snap.RegTcpTimedWaitDelay; Write-Status "TcpTimedWaitDelay restored to $($snap.RegTcpTimedWaitDelay)" "success" } } catch { Write-Log "TcpTimedWaitDelay restore failed: $_" "warning" }
    Write-Status "[2/4] Restoring TCP globals..." "info"
    try { if ($snap.TcpCongestionProvider) { netsh int tcp set supplemental template=internet congestionprovider=$($snap.TcpCongestionProvider) 2>&1 | Out-Null; Write-Status "CTCP restored: $($snap.TcpCongestionProvider)" "success" } } catch { Write-Log "CTCP restore failed: $_" "warning" }
    try { if ($snap.TcpTimestamps) { netsh int tcp set global timestamps=$($snap.TcpTimestamps) 2>&1 | Out-Null; Write-Status "Timestamps restored: $($snap.TcpTimestamps)" "success" } } catch { Write-Log "Timestamps restore failed: $_" "warning" }
    try { if ($snap.TcpInitialRto) { netsh int tcp set global initialRto=$($snap.TcpInitialRto) 2>&1 | Out-Null; Write-Status "InitialRTO restored: $($snap.TcpInitialRto)" "success" } } catch { Write-Log "InitialRTO restore failed: $_" "warning" }
    try { if ($snap.TcpRss) { netsh int tcp set global rss=$($snap.TcpRss) 2>&1 | Out-Null; Write-Status "RSS restored: $($snap.TcpRss)" "success" } } catch { Write-Log "RSS restore failed: $_" "warning" }
    try { if ($snap.TcpAutotuningLevel) { netsh int tcp set global autotuninglevel=$($snap.TcpAutotuningLevel) 2>&1 | Out-Null; Write-Status "Autotuning restored: $($snap.TcpAutotuningLevel)" "success" } } catch { Write-Log "Autotuning restore failed: $_" "warning" }
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

function Optimize-NetworkSpeed {
    param([string]$Adapter)
    $comp = $ScriptConfig.ProfileSettings.ComputedSettings
    if (-not $comp) {
        Write-Status "No computed settings available, using defaults" "warning"
        return
    }

    Write-Status "" "info"
    Write-Status "=== OPTIMIZING NETWORK SPEED ===" "info"

    try {
        Write-Status "[1/9] Setting TCP congestion..." "info"
        netsh int tcp set supplemental template=internet congestionprovider=ctcp 2>&1 | Out-Null
        if ((netsh int tcp show supplemental template=internet) -match "ctcp") { Write-Status "CTCP enabled" "success" } else { Write-Status "CTCP not available" "warning" }
    } catch { Write-Log "CTCP step failed: $_" "warning" }

    try {
        $ts = if ($comp.DisableTimestamps) { "disabled" } else { "enabled" }
        Write-Status "[2/9] Setting TCP timestamps to $ts..." "info"
        netsh int tcp set global timestamps=$ts 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or (netsh int tcp show global) -match "RFC 1323 Timestamps\s*:\s*$ts") {
            Write-Status "TCP timestamps $ts" "success"
        } else { Write-Status "Failed to set timestamps to $ts" "warning" }
    } catch { Write-Log "Timestamps step failed: $_" "warning" }

    try {
        Write-Status "[3/9] Setting Initial RTO to $($comp.InitialRto)ms..." "info"
        netsh int tcp set global initialRto=$($comp.InitialRto) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or (netsh int tcp show global) -match "Initial RTO\s*:\s*$($comp.InitialRto)") {
            Write-Status "Initial RTO set to $($comp.InitialRto)ms" "success"
        } else { Write-Status "Failed to set initialRto" "warning" }
    } catch { Write-Log "RTO step failed: $_" "warning" }

    try {
        Write-Status "[4/9] Enabling RSS..." "info"
        netsh int tcp set global rss=enabled 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or (netsh int tcp show global) -match "Receive-Side Scaling State\s*:\s*enabled") {
            Write-Status "RSS enabled" "success"
        } else { Write-Status "RSS not available" "warning" }
        if ($comp.EnableDca) {
            netsh int tcp set global dca=enabled 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Status "DCA enabled" "success" } else { Write-Status "DCA not available (safe to ignore)" "warning" }
        } else { Write-Status "DCA skipped (battery/conservative mode)" "info" }
    } catch { Write-Log "RSS/DCA step failed: $_" "warning" }

    try {
        $endPort = $comp.PortRangeStart + $comp.PortRangeCount - 1
        Write-Status "[5/9] Expanding dynamic port range to $($comp.PortRangeStart)-$endPort..." "info"
        netsh int ipv4 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
        netsh int ipv6 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or ((netsh int ipv4 show dynamicport tcp) -match "Start Port\s*:\s*$($comp.PortRangeStart)" -and (netsh int ipv6 show dynamicport tcp) -match "Start Port\s*:\s*$($comp.PortRangeStart)")) {
            Write-Status "Dynamic port range set to $($comp.PortRangeStart)-$endPort" "success"
        } else { Write-Status "Failed to set dynamic port range" "warning" }
    } catch { Write-Log "Port range step failed: $_" "warning" }

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        Write-Status "[6/9] Setting MaxUserPort to $($comp.MaxUserPort)..." "info"
        reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /d $($comp.MaxUserPort) /t REG_DWORD /f 2>&1 | Out-Null
        $mup = (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort
        if ($mup -eq $comp.MaxUserPort) { Write-Status "MaxUserPort set to $($comp.MaxUserPort)" "success" } else { Write-Status "Failed to set MaxUserPort" "warning" }
    } catch { Write-Log "MaxUserPort step failed: $_" "warning" }

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        Write-Status "[7/9] Setting TcpTimedWaitDelay to $($comp.TcpTimedWaitDelay)s..." "info"
        reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /d $($comp.TcpTimedWaitDelay) /t REG_DWORD /f 2>&1 | Out-Null
        $twd = (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
        if ($twd -eq $comp.TcpTimedWaitDelay) { Write-Status "TcpTimedWaitDelay set to $($comp.TcpTimedWaitDelay)s" "success" } else { Write-Status "Failed to set TcpTimedWaitDelay" "warning" }
    } catch { Write-Log "TcpTimedWaitDelay step failed: $_" "warning" }

    try {
        Write-Status "[8/9] Setting TCP auto-tuning to $($comp.AutotuningLevel)..." "info"
        netsh int tcp set global autotuninglevel=$($comp.AutotuningLevel) 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -or (netsh int tcp show global) -match "Receive Window Auto-Tuning Level\s*:\s*$($comp.AutotuningLevel)") {
            Write-Status "TCP auto-tuning set to $($comp.AutotuningLevel)" "success"
        } else { Write-Status "Failed to set auto-tuning level" "warning" }
    } catch { Write-Log "Auto-tuning step failed: $_" "warning" }

    try {
        Write-Status "[9/9] Clearing DNS cache..." "info"
        ipconfig /flushdns 2>&1 | Out-Null
        Write-Status "DNS cache flushed" "success"
    } catch { Write-Log "DNS flush step failed: $_" "warning" }

    if ($Adapter) {
        try { $ai = Get-NetAdapter -Name $Adapter -ErrorAction Stop; Write-Status "Link speed: $($ai.LinkSpeed)" "info" } catch { }
    }

    Write-Status "" "info"
    Write-Status "Optimization complete!" "success"
    Write-Status "Some changes require reboot to take full effect." "warning"
    Write-Log "Network optimization completed" "info"
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
            $wlanInfo = netsh wlan show interfaces 2>$null | Out-String
            if ($wlanInfo -notmatch "SSID\s*:\s*.+") {
                Write-Status "WiFi not connected - scanning for known networks..." "warning"
                $profiles = netsh wlan show profiles 2>$null | Out-String
                $matchedProfiles = [regex]::Matches($profiles, "All User Profile\s*:\s*(.+)")
                if ($matchedProfiles.Count -gt 0) {
                    $ssid = $matchedProfiles[$matchedProfiles.Count - 1].Groups[1].Value.Trim()
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
    Optimize-NetworkSpeed -Adapter $adapter
    Write-Host ""
    Write-Status "Reset complete." "success"
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
        Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter)
        Write-Status "Optimization done!" "success"
        Write-Log "Optimization completed, network was OK" "success"
    }
}

function Check-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "This script requires Administrator privileges." -ForegroundColor Red
        Write-Host "Restart with 'Run as Administrator' or use Reset-Network.bat" -ForegroundColor Yellow
        exit 1
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
        Write-Host "  [R] Restore -- otkatit izmenenia iz snapshota" -ForegroundColor Yellow
        Write-Host "  [F] Overwrite -- snova sdelat snapshot i prodolzhit" -ForegroundColor Yellow
        Write-Host "  [Q] Quit -- vyjti" -ForegroundColor Yellow
        Write-Host ""
        switch ((Read-Host "Vyberite [R/F/Q]").ToUpper()) {
            'R' { Invoke-Restore; return }
            'F' { Remove-Item -Path $ScriptConfig.SnapshotFile -Force; Write-Status "Snapshot perezapisan" "warning" }
            default { Write-Host "Vyhod..." -ForegroundColor Gray; return }
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
        Write-Host ""
        Write-Host "=== NETWORK MENU ===" -ForegroundColor Cyan
        Write-Host "  [F] Force reset -- polnyj sbros + optimizacia"
        Write-Host "  [O] Re-run optimization -- zapustit optimizaciu snova"
        Write-Host "  [R] Restore -- otkatit vse izmenenia iz snapshota"
        Write-Host "  [Q] Quit -- vyjti"
        Write-Host ""
        $mc = (Read-Host "Vyberite [F/O/R/Q]").ToUpper()
        switch ($mc) {
            'F' { Write-Log "Menu: Force reset" "info"; Invoke-NetworkReset }
            'O' { Write-Log "Menu: Re-optimize" "info"; Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter) }
            'R' { Write-Log "Menu: Restore" "info"; Invoke-Restore; $mc = 'Q'; continue }
        }
    } while ($mc -ne 'Q')
}

Main