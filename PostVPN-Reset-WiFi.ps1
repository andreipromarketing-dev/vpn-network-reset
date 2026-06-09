<#
.SYNOPSIS
    Network Rescue & Optimizer v6.0
    Восстановление доступа к сети после блокировки провайдером + оптимизация под железо
    
    Особенности:
    - Расширенная диагностика сети (шлюз, DNS, внешние хосты)
    - Безопасное восстановление БЕЗ отключения адаптеров
    - Работа без перезагрузки (сброс служб и стека)
    - Понятное интерактивное меню
    - Автоматический выбор действий по результатам проверки
    - Мягкие TCP-настройки для совместимости
    
    Использование:
      .\Network_Rescue_Optimizer.ps1              # Интерактивный режим
      .\Network_Rescue_Optimizer.ps1 -Auto        # Авто-восстановление при проблемах
      .\Network_Rescue_Optimizer.ps1 -Optimize    # Только оптимизация
      .\Network_Rescue_Optimizer.ps1 -Restore     # Восстановить исходные настройки
#>

param(
    [switch]$Auto,      # Автоматическое восстановление при обнаружении проблем
    [switch]$Optimize,  # Только оптимизация без проверок
    [switch]$Restore    # Восстановить исходные настройки из снапшота
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
    # Тестовые хосты для проверки доступа к сети
    TestHosts       = @("8.8.8.8", "1.1.1.1", "8.8.4.4")
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

function Show-TcpSettings {
    Write-Host ""
    Write-Host "=== CURRENT TCP SETTINGS ===" -ForegroundColor Cyan
    $globalText = netsh int tcp show global
    $relevant = @(
        'Add-On Congestion Control Provider',
        'RFC 1323 Timestamps',
        'Initial RTO',
        'Receive-Side Scaling State',
        'Direct Cache Access \(DCA\)',
        'Receive Window Auto-Tuning Level',
        'ECN Capability',
        'Fast Open'
    )
    foreach ($line in $globalText) {
        foreach ($pat in $relevant) {
            if ($line -match $pat) {
                Write-Host "  $line" -ForegroundColor Gray
                break
            }
        }
    }
    Write-Host ""
    Write-Host "=== DYNAMIC PORTS ===" -ForegroundColor Cyan
    $v4 = netsh int ipv4 show dynamicport tcp
    foreach ($line in $v4) { if ($line -match '^\s*(Start Port|Number of Ports)') { Write-Host "  IPv4: $line" -ForegroundColor Gray } }
    $v6 = netsh int ipv6 show dynamicport tcp
    foreach ($line in $v6) { if ($line -match '^\s*(Start Port|Number of Ports)') { Write-Host "  IPv6: $line" -ForegroundColor Gray } }
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
    }
    Write-Host ""
}

function Test-Network {
    param([string]$TestHost = $null)
    
    # Расширенная проверка сети с детальной диагностикой
    $result = @{
        HasInternet = $false
        HasGateway = $false
        HasDns = $false
        GatewayReachable = $false
        DnsResolved = $false
        Details = @()
    }
    
    # 1. Проверка шлюза по умолчанию
    try {
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.NextHop -and $_.NextHop -notmatch "127\.0\.0\.1" } | 
                    Select-Object -First 1).NextHop
        if ($gateway) {
            $result.HasGateway = $true
            $result.Details += "Шлюз: $gateway"
            
            # Пинг шлюза
            if (Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue) {
                $result.GatewayReachable = $true
                $result.Details += "Шлюз доступен (ping OK)"
            } else {
                $result.Details += "Шлюз НЕ отвечает на ping"
            }
        } else {
            $result.Details += "Шлюз по умолчанию не найден"
        }
    } catch {
        $result.Details += "Ошибка получения шлюза: $_"
    }
    
    # 2. Проверка DNS
    try {
        $adapter = Get-ActiveAdapter
        if ($adapter) {
            $ifIndex = (Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue).ifIndex
            if ($ifIndex) {
                $dnsServers = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                              Select-Object -ExpandProperty ServerAddresses -ErrorAction SilentlyContinue
                if ($dnsServers -and $dnsServers.Count -gt 0) {
                    $result.HasDns = $true
                    $result.Details += "DNS серверы: $($dnsServers -join ', ')"
                    
                    # Тест разрешения имени
                    try {
                        $resolved = [System.Net.Dns]::GetHostEntry("www.microsoft.com")
                        if ($resolved) {
                            $result.DnsResolved = $true
                            $result.Details += "DNS работает (microsoft.com разрешён)"
                        }
                    } catch {
                        $result.Details += "DNS НЕ разрешает имена"
                    }
                } else {
                    $result.Details += "DNS серверы не настроены"
                }
            }
        }
    } catch {
        $result.Details += "Ошибка проверки DNS: $_"
    }
    
    # 3. Проверка доступа к внешним хостам
    $hostsToTest = if ($TestHost) { @($TestHost) } else { $ScriptConfig.TestHosts }
    foreach ($host in $hostsToTest) {
        try {
            $pingResult = Test-Connection -ComputerName $host -Count 2 -Quiet -TimeoutSeconds $ScriptConfig.PingTimeout -ErrorAction Stop
            if ($pingResult) {
                $result.HasInternet = $true
                $result.Details += "Доступ к $host: OK"
                break
            }
        } catch {
            $result.Details += "Доступ к $host: НЕТ"
        }
    }
    
    # Итоговый вердикт
    $result.IsOnline = $result.HasInternet -and $result.HasGateway -and $result.GatewayReachable
    
    return $result
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
    # БЕЗОПАСНАЯ версия: НЕ отключаем адаптеры, только логируем найденные VPN
    # Отключение адаптеров вызывает проблемы после перезагрузки
    Write-Status "Поиск VPN-адаптеров (только диагностика, не отключаем)..." "info"
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Name -notmatch 'Bluetooth' }
    $foundVpn = $false
    foreach ($adapter in $adapters) {
        foreach ($pattern in $ScriptConfig.VpnPatterns) {
            if ($adapter.Name -imatch $pattern) {
                Write-Status "  Найден VPN-адаптер: $($adapter.Name) (не отключаем)" "warning"
                $foundVpn = $true
                break
            }
        }
    }
    if (-not $foundVpn) {
        Write-Status "  VPN-адаптеры не обнаружены" "success"
    }
    return $foundVpn
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
    # Оптимизация под железо с более мягкими настройками для совместимости
    $cores = [Math]::Max([int]$Profile.PhysicalCores, 1)
    $rss = [Math]::Min($cores, 4)
    $linkOk = $Profile.LinkSpeedMbps -and [int]$Profile.LinkSpeedMbps -ge 100
    $rttOk = $Profile.GatewayRttMs -and [int]$Profile.GatewayRttMs -le 50
    
    # Более консервативные настройки для избежания проблем с соединениями
    $initialRto = if ($linkOk -and $rttOk) { 300 } else { 500 }
    $timedWait = if ($rttOk) { 60 } else { 90 }  # Увеличено с 30/60 до 60/90 для совместимости
    $disableTimestamps = $false  # Отключено: timestamps могут быть нужны для некоторых соединений
    $autotuning = if ([double]$Profile.RamGB -lt 8) { "restricted" } else { "normal" }
    $enableDca = (-not $Profile.OnBattery)
    if ($Profile.OnBattery) { $rss = [Math]::Max([Math]::Ceiling($rss / 2), 1) }
    
    return @{ 
        InitialRto=$initialRto
        TcpTimedWaitDelay=$timedWait
        RssMaxProcessors=$rss
        DisableTimestamps=$disableTimestamps
        EnableDca=$enableDca
        AutotuningLevel=$autotuning
        PortRangeStart=10000
        PortRangeCount=55534
        MaxUserPort=65534
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
        if ($ln -match '^\s*Add-On Congestion Control Provider\s*:\s*(.+)') { $snap.TcpCongestionProvider = $matches[1].Trim() }
        if ($ln -match '^\s*RFC 1323 Timestamps\s*:\s*(.+)') { $snap.TcpTimestamps = $matches[1].Trim() }
        if ($ln -match '^\s*Initial RTO\s*:\s*(.+)') { $snap.TcpInitialRto = $matches[1].Trim() }
        if ($ln -match '^\s*Receive-Side Scaling State\s*:\s*(.+)') { $snap.TcpRss = $matches[1].Trim() }
        if ($ln -match '^\s*Receive Window Auto-Tuning Level\s*:\s*(.+)') { $snap.TcpAutotuningLevel = $matches[1].Trim() }
    }
    $v4t = netsh int ipv4 show dynamicport tcp
    $v4start = if ($v4t -match 'Start Port\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    $v4num = if ($v4t -match 'Number of Ports\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    if ($v4start -and $v4num) { $snap.DynamicPortV4Start = $v4start; $snap.DynamicPortV4Num = $v4num }
    $v6t = netsh int ipv6 show dynamicport tcp
    $v6start = if ($v6t -match 'Start Port\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    $v6num = if ($v6t -match 'Number of Ports\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
    if ($v6start -and $v6num) { $snap.DynamicPortV6Start = $v6start; $snap.DynamicPortV6Num = $v6num }
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

function Get-TcpValue {
    param([string]$Label)
    $lines = netsh int tcp show global
    foreach ($ln in $lines) {
        if ($ln -match "^$Label\s*:\s*(.+)") { return $matches[1].Trim() }
    }
    return "(not found)"
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

    try {
        $before = (netsh int tcp show supplemental template=internet) -match "ctcp"
        $beforeStr = if ($before) { "ctcp" } else { "default" }
        Write-Host "  [1/9] CTCP: $beforeStr -> ctcp" -ForegroundColor Gray
        netsh int tcp set supplemental template=internet congestionprovider=ctcp 2>&1 | Out-Null
        $after = (netsh int tcp show supplemental template=internet) -match "ctcp"
        if ($after) { Write-Status "  CTCP: $beforeStr -> ctcp" "success" } else { Write-Status "  CTCP: not available" "warning" }
    } catch { Write-Log "CTCP step failed: $_" "warning" }

    try {
        $ts = if ($comp.DisableTimestamps) { "disabled" } else { "enabled" }
        $before = Get-TcpValue "RFC 1323 Timestamps"
        Write-Host "  [2/9] Timestamps: $before -> $ts" -ForegroundColor Gray
        netsh int tcp set global timestamps=$ts 2>&1 | Out-Null
        $after = Get-TcpValue "RFC 1323 Timestamps"
        if ($LASTEXITCODE -eq 0 -and $after -eq $ts) { Write-Status "  Timestamps: $before -> $after" "success" }
        else { Write-Status "  Timestamps: failed (current: $after)" "warning" }
    } catch { Write-Log "Timestamps step failed: $_" "warning" }

    try {
        $before = Get-TcpValue "Initial RTO"
        Write-Host "  [3/9] Initial RTO: $before -> $($comp.InitialRto)ms" -ForegroundColor Gray
        netsh int tcp set global initialRto=$($comp.InitialRto) 2>&1 | Out-Null
        $after = Get-TcpValue "Initial RTO"
        if ($LASTEXITCODE -eq 0 -and $after -match "$($comp.InitialRto)") { Write-Status "  Initial RTO: $before -> $after" "success" }
        else { Write-Status "  Initial RTO: failed (current: $after)" "warning" }
    } catch { Write-Log "RTO step failed: $_" "warning" }

    try {
        $before = Get-TcpValue "Receive-Side Scaling State"
        Write-Host "  [4/9] RSS: $before -> enabled" -ForegroundColor Gray
        netsh int tcp set global rss=enabled 2>&1 | Out-Null
        $after = Get-TcpValue "Receive-Side Scaling State"
        if ($LASTEXITCODE -eq 0 -and $after -eq "enabled") { Write-Status "  RSS: $before -> $after" "success" }
        else { Write-Status "  RSS: not available (current: $after)" "warning" }
        if ($comp.EnableDca) {
            $before = Get-TcpValue "Direct Cache Access \(DCA\)"
            netsh int tcp set global dca=enabled 2>&1 | Out-Null
            $after = Get-TcpValue "Direct Cache Access \(DCA\)"
            if ($LASTEXITCODE -eq 0 -and $after -eq "enabled") { Write-Status "  DCA: $before -> $after" "success" }
            else { Write-Status "  DCA: not available (safe to ignore)" "warning" }
        } else { Write-Status "  DCA: skipped (battery mode)" "info" }
    } catch { Write-Log "RSS/DCA step failed: $_" "warning" }

    try {
        $endPort = $comp.PortRangeStart + $comp.PortRangeCount - 1
        $v4raw = netsh int ipv4 show dynamicport tcp
        $before = if ($v4raw -match 'Start Port\s*:\s*(\d+).*Number of Ports\s*:\s*(\d+)') { "$($matches[1])-$([int]$matches[1] + [int]$matches[2] - 1)" } else { "unknown" }
        Write-Host "  [5/9] Port range: $before -> $($comp.PortRangeStart)-$endPort" -ForegroundColor Gray
        netsh int ipv4 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
        netsh int ipv6 set dynamicport tcp start=$($comp.PortRangeStart) num=$($comp.PortRangeCount) 2>&1 | Out-Null
        $v4check = netsh int ipv4 show dynamicport tcp
        if ($LASTEXITCODE -eq 0 -and $v4check -match "Start Port\s*:\s*$($comp.PortRangeStart)") {
            Write-Status "  Port range: $before -> $($comp.PortRangeStart)-$endPort" "success"
        } else { Write-Status "  Port range: failed" "warning" }
    } catch { Write-Log "Port range step failed: $_" "warning" }

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        $before = (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort
        $beforeStr = if ($before) { "$before" } else { "5000 (default)" }
        Write-Host "  [6/9] MaxUserPort: $beforeStr -> $($comp.MaxUserPort)" -ForegroundColor Gray
        reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /d $($comp.MaxUserPort) /t REG_DWORD /f 2>&1 | Out-Null
        $after = (Get-ItemProperty $regPath -Name MaxUserPort -ErrorAction SilentlyContinue).MaxUserPort
        if ($after -eq $comp.MaxUserPort) { Write-Status "  MaxUserPort: $beforeStr -> $after" "success" }
        else { Write-Status "  MaxUserPort: failed" "warning" }
    } catch { Write-Log "MaxUserPort step failed: $_" "warning" }

    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        $before = (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
        $beforeStr = if ($before) { "${before}s" } else { "120s (default)" }
        Write-Host "  [7/9] TcpTimedWaitDelay: $beforeStr -> $($comp.TcpTimedWaitDelay)s" -ForegroundColor Gray
        reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v TcpTimedWaitDelay /d $($comp.TcpTimedWaitDelay) /t REG_DWORD /f 2>&1 | Out-Null
        $after = (Get-ItemProperty $regPath -Name TcpTimedWaitDelay -ErrorAction SilentlyContinue).TcpTimedWaitDelay
        if ($after -eq $comp.TcpTimedWaitDelay) { Write-Status "  TcpTimedWaitDelay: $beforeStr -> ${after}s" "success" }
        else { Write-Status "  TcpTimedWaitDelay: failed" "warning" }
    } catch { Write-Log "TcpTimedWaitDelay step failed: $_" "warning" }

    try {
        $before = Get-TcpValue "Receive Window Auto-Tuning Level"
        Write-Host "  [8/9] Auto-tuning: $before -> $($comp.AutotuningLevel)" -ForegroundColor Gray
        netsh int tcp set global autotuninglevel=$($comp.AutotuningLevel) 2>&1 | Out-Null
        $after = Get-TcpValue "Receive Window Auto-Tuning Level"
        if ($LASTEXITCODE -eq 0 -and $after -eq $comp.AutotuningLevel) { Write-Status "  Auto-tuning: $before -> $after" "success" }
        else { Write-Status "  Auto-tuning: failed (current: $after)" "warning" }
    } catch { Write-Log "Auto-tuning step failed: $_" "warning" }

    try {
        Write-Host "  [9/9] Flushing DNS cache..." -ForegroundColor Gray
        ipconfig /flushdns 2>&1 | Out-Null
        Write-Status "  DNS cache flushed" "success"
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
    param([switch]$Soft)  # Мягкий сброс - только службы и кэши, без IP renewal
    
    Write-Host ""
    Write-Host "=== ВОССТАНОВЛЕНИЕ СЕТИ ===" -ForegroundColor Cyan
    Write-Log "Starting network rescue (Soft=$Soft)" "info"
    
    $adapter = Get-ActiveAdapter
    if (-not $adapter) {
        Write-Status "Адаптер не найден!" "error"
        Write-Log "Rescue aborted: no adapter" "error"
        return $false
    }
    
    $adapterObj = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
    if ($adapterObj) {
        if ($adapterObj.Status -ne 'Up') {
            Write-Status "Адаптер в состоянии $($adapterObj.Status) - пытаемся включить..." "warning"
            try {
                Enable-NetAdapter -Name $adapter -Confirm:$false -ErrorAction Stop
                Write-Status "Адаптер включён, ждём готовности..." "info"
                Start-Sleep -Seconds 3
            } catch { Write-Log "Failed to enable adapter: $_" "warning" }
        }
        
        # Для WiFi - проверка подключения к сети
        if ($adapterObj.InterfaceType -eq 71) {
            $wlanInfo = netsh wlan show interfaces 2>$null | Out-String
            if ($wlanInfo -notmatch "SSID\s*:\s*.+") {
                Write-Status "WiFi не подключён - сканируем известные сети..." "warning"
                $profiles = netsh wlan show profiles 2>$null | Out-String
                $matchedProfiles = [regex]::Matches($profiles, "All User Profile\s*:\s*(.+)")
                if ($matchedProfiles.Count -gt 0) {
                    $ssid = $matchedProfiles[$matchedProfiles.Count - 1].Groups[1].Value.Trim()
                    Write-Status "Попытка подключения к $ssid..." "info"
                    $null = netsh wlan connect name="$ssid" 2>&1 | Out-Null
                    Start-Sleep -Seconds 5
                }
            } else {
                Write-Status "WiFi подключён к сети" "success"
            }
        }
    }
    
    if (-not (Wait-AdapterReady -Adapter $adapter -Timeout 10)) {
        Write-Status "Адаптер не готов, пробуем другой..." "warning"
        $adapter = Get-ActiveAdapter
        if (-not $adapter) {
            Write-Status "Нет доступных адаптеров" "error"
            return $false
        }
    }
    
    Write-Status "Используемый адаптер: $adapter" "info"
    $ifIndex = (Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue).ifIndex
    if (-not $ifIndex) { Write-Status "Адаптер потерян" "error"; return $false }
    
    # Этап 1: Диагностика VPN-адаптеров (без отключения!)
    Write-Status "[1/6] Проверка VPN-адаптеров..." "info"
    Disable-AllVPNAdapters
    Start-Sleep -Seconds 1
    
    # Этап 2: Сброс сетевых служб БЕЗ разрыва соединений
    Write-Status "[2/6] Перезапуск сетевых служб (без разрыва активных соединений)..." "info"
    try {
        # Перезапускаем только DNS Client, не трогая DHCP для сохранения сессий
        Restart-Service -Name "Dnscache" -Force -ErrorAction SilentlyContinue
        Write-Status "  DNS Client служба перезапущена" "success"
    } catch { Write-Log "DNS service restart failed: $_" "warning" }
    
    try {
        # Сброс Winsock без перезагрузки
        netsh winsock reset catalog 2>&1 | Out-Null
        Write-Status "  Winsock каталог сброшен (требуется перезагрузка для полного применения)" "warning"
    } catch { Write-Log "Winsock reset failed: $_" "warning" }
    
    # Этап 3: Очистка кэшей и маршрутов
    Write-Status "[3/6] Очистка кэшей и таблиц маршрутизации..." "info"
    try {
        ipconfig /flushdns 2>&1 | Out-Null
        $null = netsh int ip delete destinationcache 2>&1
        Write-Status "  DNS кэш очищен, таблица маршрутов обновлена" "success"
    } catch { Write-Log "Cache clear failed: $_" "warning" }
    
    # Этап 4: Обновление IP (только если не мягкий режим)
    if (-not $Soft) {
        Write-Status "[4/6] Обновление IP-адреса..." "info"
        try {
            ipconfig /release $adapter 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            ipconfig /renew $adapter 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $ipInfo = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' }
            if ($ipInfo) {
                Write-Status "  IP-адрес обновлён: $($ipInfo.IPAddress)" "success"
            } else {
                Write-Status "  IP получен (проверьте подключение)" "success"
            }
        } catch { Write-Log "IP renew error: $_" "warning" }
    } else {
        Write-Status "[4/6] Пропуск обновления IP (мягкий режим)" "info"
        $ipInfo = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' }
        if ($ipInfo) {
            Write-Status "  Текущий IP: $($ipInfo.IPAddress)" "info"
        }
    }
    
    # Этап 5: Проверка сети с детальной диагностикой
    Write-Status "[5/6] Проверка доступа к сети..." "info"
    $networkResult = Test-Network
    
    # Вывод результатов диагностики
    Write-Host ""
    Write-Host "  Результаты диагностики:" -ForegroundColor Cyan
    foreach ($detail in $networkResult.Details) {
        $color = "Gray"
        if ($detail -match "OK|доступен|работает") { $color = "Green" }
        elseif ($detail -match "НЕ|НЕТ|ошибка") { $color = "Red" }
        Write-Host "    $detail" -ForegroundColor $color
    }
    Write-Host ""
    
    if ($networkResult.IsOnline) {
        Write-Status "Сеть работает корректно!" "success"
        Write-Log "Network restored after rescue" "success"
    } else {
        Write-Status "Обнаружены проблемы с сетью" "error"
        Write-Log "Network issues detected after rescue" "error"
        
        # Попытка дополнительного восстановления
        Write-Status "Попытка дополнительного восстановления..." "warning"
        try {
            # Сброс TCP/IP стека
            netsh int ip reset all 2>&1 | Out-Null
            Write-Status "  TCP/IP стек сброшен (требуется перезагрузка)" "warning"
            
            # Повторная проверка
            Start-Sleep -Seconds 3
            $networkResult = Test-Network
            if ($networkResult.IsOnline) {
                Write-Status "Сеть восстановлена после сброса TCP/IP!" "success"
            } else {
                Write-Status "Проблемы сохраняются. Проверьте роутер или кабель." "error"
                return $false
            }
        } catch { Write-Log "Additional reset failed: $_" "error"; return $false }
    }
    
    # Этап 6: Оптимизация
    Write-Status "[6/6] Применение оптимизаций..." "info"
    Optimize-NetworkSpeed -Adapter $adapter
    
    Write-Host ""
    Write-Status "Восстановление завершено успешно!" "success"
    Write-Status "Примечание: некоторые изменения могут потребовать перезагрузки" "warning"
    return $true
}

function Invoke-SmartMode {
    param([switch]$Auto)
    
    Write-Log "=== Smart mode started (Auto=$Auto) ===" "info"
    
    # Расширенная проверка сети
    $networkResult = Test-Network
    
    if ($Auto) {
        # Автоматический режим: действуем только если есть проблемы
        if (-not $networkResult.IsOnline) {
            Write-Status "Обнаружены проблемы с сетью - запускаем восстановление..." "warning"
            $success = $false
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                if (Invoke-NetworkReset -Soft) {
                    $success = $true
                    break
                }
                if ($attempt -lt 2) {
                    Write-Status "Попыка не удалась, повторяем ($attempt/2)..." "warning"
                    Start-Sleep -Seconds 3
                }
            }
            if ($success) {
                Write-Status "Сеть восстановлена!" "success"
                Write-Log "Network recovered after rescue" "success"
            } else {
                Write-Status "Восстановление не удалось. Проверьте роутер или кабель." "error"
                Write-Log "Rescue failed after 2 attempts" "error"
            }
        } else {
            Write-Status "Сеть работает нормально - оптимизация не требуется" "success"
            Write-Log "Network OK, no action needed" "info"
        }
        return
    }
    
    # Интерактивный режим
    if ($networkResult.IsOnline) {
        Write-Status "Сеть работает корректно" "success"
    } else {
        Write-Status "Обнаружены проблемы с сетью" "error"
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
    Write-Log "=== Script started (Auto=$Auto Optimize=$Optimize Restore=$Restore) ===" "info"

    # Обработка ключей командной строки
    if ($Restore) {
        Invoke-Restore
        return
    }
    
    if ($Optimize) {
        Write-Status "Запуск оптимизации сети..." "info"
        $ScriptConfig.ProfileSettings = Get-SystemProfile
        if (-not (Save-Snapshot -Adapter (Get-ActiveAdapter))) {
            Write-Status "Не удалось создать снапшот, продолжаем..." "warning"
        }
        Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter)
        return
    }
    
    if ($Auto) {
        Write-Status "Автоматический режим: проверка и восстановление при необходимости..." "info"
        $ScriptConfig.ProfileSettings = Get-SystemProfile
        Save-Snapshot -Adapter (Get-ActiveAdapter) | Out-Null
        Invoke-SmartMode -Auto
        return
    }

    # Интерактивный режим с понятным меню
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     Network Rescue & Optimizer v6.0                      ║" -ForegroundColor Cyan
    Write-Host "║     Восстановление и оптимизация сети                    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Проверка наличия старого снапшота
    if (Test-Path $ScriptConfig.SnapshotFile) {
        Write-Host ""
        Write-Host "⚠ Предыдущий запуск оставил изменения!" -ForegroundColor Yellow
        Write-Host "  [U] Отменить изменения (восстановить исходное состояние)" -ForegroundColor Yellow
        Write-Host "  [C] Продолжить (удалить старый снапшот)" -ForegroundColor Yellow
        Write-Host "  [Q] Выход" -ForegroundColor Yellow
        Write-Host ""
        switch ((Read-Host "Выберите [U/C/Q]").ToUpper()) {
            'U' { Invoke-Restore; return }
            'C' { Remove-Item -Path $ScriptConfig.SnapshotFile -Force; Write-Status "Старый снапшот удалён" "warning" }
            default { return }
        }
    }

    # Создание профиля системы и снапшота
    $ScriptConfig.ProfileSettings = Get-SystemProfile
    if (-not (Save-Snapshot -Adapter (Get-ActiveAdapter))) {
        Write-Status "Не удалось создать снапшот для восстановления" "warning"
        Write-Status "Продолжить без гарантии отката? [Y/N]" "warning"
        if ((Read-Host).ToUpper() -ne 'Y') { return }
    }

    # Первичная диагностика
    Write-Host ""
    Write-Host "📋 Выполняется диагностика сети..." -ForegroundColor Cyan
    $networkResult = Test-Network
    
    Write-Host ""
    Write-Host "  Результаты проверки:" -ForegroundColor Cyan
    foreach ($detail in $networkResult.Details) {
        $color = "Gray"
        if ($detail -match "OK|доступен|работает") { $color = "Green" }
        elseif ($detail -match "НЕ|НЕТ|ошибка") { $color = "Red" }
        Write-Host "    $detail" -ForegroundColor $color
    }
    Write-Host ""
    
    if ($networkResult.IsOnline) {
        Write-Status "✅ Сеть работает нормально" "success"
    } else {
        Write-Status "❌ Обнаружены проблемы с сетью" "error"
        Write-Host ""
        Write-Host "Рекомендуемые действия:" -ForegroundColor Yellow
        Write-Host "  1. Быстрое восстановление (без разрыва соединений) - нажмите [R]" -ForegroundColor Yellow
        Write-Host "  2. Полное восстановление со сбросом IP - нажмите [F]" -ForegroundColor Yellow
    }

    # Главное меню
    do {
        $networkResult = Test-Network
        $netIcon = if ($networkResult.IsOnline) { "✅ [ОНЛАЙН]" } else { "❌ [ОФФЛАЙН]" }
        $netColor = if ($networkResult.IsOnline) { "Green" } else { "Red" }
        
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║                    ГЛАВНОЕ МЕНЮ                          ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host -NoNewline "  Статус сети: "; Write-Host $netIcon -ForegroundColor $netColor
        Write-Host ""
        Write-Host "  ВОССТАНОВЛЕНИЕ:" -ForegroundColor Yellow
        Write-Host "    [R] Быстрое восстановление (мягкий сброс, без разрыва сессий)" -ForegroundColor White
        Write-Host "    [F] Полное восстановление (с обновлением IP, может разорвать соединения)" -ForegroundColor White
        Write-Host ""
        Write-Host "  ОПТИМИЗАЦИЯ:" -ForegroundColor Green
        Write-Host "    [O] Оптимизировать только (безопасно, не трогает адаптер)" -ForegroundColor White
        Write-Host "    [S] Показать текущие настройки TCP и план оптимизации" -ForegroundColor White
        Write-Host ""
        Write-Host "  ДРУГОЕ:" -ForegroundColor Gray
        Write-Host "    [U] Отменить все изменения (восстановить из снапшота)" -ForegroundColor White
        Write-Host "    [Q] Выход" -ForegroundColor White
        Write-Host ""
        $mc = (Read-Host "  Выберите действие [R/F/O/S/U/Q]").ToUpper()
        
        switch ($mc) {
            'S' { Show-TcpSettings }
            'O' { 
                Write-Log "Menu: Optimize only" "info"
                Optimize-NetworkSpeed -Adapter (Get-ActiveAdapter)
            }
            'R' { 
                Write-Log "Menu: Soft reset" "info"
                Invoke-NetworkReset -Soft
            }
            'F' { 
                Write-Log "Menu: Full reset" "info"
                Invoke-NetworkReset
            }
            'U' { 
                Write-Log "Menu: Undo" "info"
                Invoke-Restore
                $mc = 'Q'
                continue
            }
        }
    } while ($mc -ne 'Q')
}

# Запуск скрипта
Main