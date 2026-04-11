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

$PreferencesFile = Join-Path $SnapshotsDir "preferences.json"
$ProxyConfigFile = Join-Path $SnapshotsDir "proxies.json"

function Get-AppPreferences {
    if (Test-Path $PreferencesFile) {
        try {
            $json = Get-Content $PreferencesFile -Raw
            $data = $json | ConvertFrom-Json
            
            $apps = @{}
            
            if ($data.apps) {
                $data.apps.PSObject.Properties | ForEach-Object {
                    $apps[$_.Name] = $_.Value
                }
            }
            
            return @{
                apps = $apps
                routes = if ($data.routes) { $data.routes } else { @() }
                lastUpdated = if ($data.lastUpdated) { $data.lastUpdated } else { "" }
            }
        } catch {
            return @{ apps = @{}; routes = @(); lastUpdated = "" }
        }
    }
    return @{ apps = @{}; routes = @(); lastUpdated = "" }
}

function Set-AppPreference($appName, $mode) {
    $prefs = Get-AppPreferences
    $prefs.apps[$appName] = $mode
    $prefs.lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    
    $prefs | ConvertTo-Json -Depth 3 | Out-File -FilePath $PreferencesFile -Encoding UTF8
    Write-Status "Nastrojka: $appName -> $mode" "success"
}

function Save-AppPreferences($prefs) {
    $prefs.lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    $prefs | ConvertTo-Json -Depth 3 | Out-File -FilePath $PreferencesFile -Encoding UTF8
    Write-Status "Preferences saved" "success"
}

function Show-PreferencesMenu {
    $prefs = Get-AppPreferences
    
    Write-Host ""
    Write-Host "=== TEKUSCHIE NASTROJKI ===" -ForegroundColor Cyan
    
    $appCount = 0
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | ForEach-Object {
            $appName = $_.Key
            $mode = $_.Value
            $icon = switch ($mode) {
                "via_vpn" { "[+]" }
                "direct" { "[-]" }
                "skip" { "[0]" }
                default { "[?]" }
            }
            Write-Host "$icon $appName"
            $appCount++
        }
    }
    
    if ($appCount -eq 0) {
        Write-Host "Nastrojki ne ustanovleny." -ForegroundColor Gray
    }
}

function Set-PreferencesMenu {
    $prefs = Get-AppPreferences
    $apps = Scan-NetworkApps
    Show-NetworkAppsTable $apps
    
    Write-Host ""
    Write-Host "Vvedite nomer prilozhenija (a=vse, 0=vyhod): " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    
    if ($choice -eq "0" -or $choice -eq "") { return }
    if ($choice -eq "a" -or $choice -eq "A") {
        foreach ($app in $apps) {
            Set-AppPreference $app.Name "via_vpn"
        }
        Write-Host "Vse prilozhenija: CHEREZ VPN" -ForegroundColor Green
        return
    }
    
    $index = [int]$choice - 1
    if ($index -ge 0 -and $index -lt $apps.Count) {
        $selectedApp = $apps[$index]
        
        Write-Host ""
        Write-Host "Nastrojka: $($selectedApp.Name)" -ForegroundColor Cyan
        Write-Host "[V] CHEREZ VPN"
        Write-Host "[D] NAPRYAMUYU (obhod VPN)"  
        Write-Host "[S] PROPUSTIT"
        Write-Host ""
        Write-Host "Vybor: " -ForegroundColor Yellow -NoNewline
        $mode = Read-Host
        
        switch ($mode.ToLower()) {
            "v" { Set-AppPreference $selectedApp.Name "via_vpn" }
            "d" { Set-AppPreference $selectedApp.Name "direct" }
            "s" { Set-AppPreference $selectedApp.Name "skip" }
            default { Write-Host "Propusheno" -ForegroundColor Gray }
        }
    }
}

function Get-ProxyConfig {
    if (Test-Path $ProxyConfigFile) {
        try {
            return Get-Content $ProxyConfigFile -Raw | ConvertFrom-Json
        } catch { return $null }
    }
    return $null
}

function Save-ProxyConfig($proxies) {
    $proxies | ConvertTo-Json -Depth 3 | Out-File -FilePath $ProxyConfigFile -Encoding UTF8
    Write-Status "Proxy config saved: $ProxyConfigFile" "success"
}

function Apply-ProxyConfig($proxyUrl) {
    try {
        if ($proxyUrl -match "tg://proxy\?server=(.+?)&port=(\d+)&secret=(.+)") {
            $server = $matches[1]
            $port = $matches[2]
            $secret = $matches[3]
            
            Write-Status "Setting Telegram proxy: $server`:$port" "info"
            
            $telegramProxy = "https://tgram.dev/go?url=tg%3A%2F%2Fproxy%3Fserver%3D$server%26port%3D$port%26secret%3D$secret"
            
            return @{
                server = $server
                port = $port
                secret = $secret
                url = $proxyUrl
            }
        }
    } catch {
        Write-Status "Failed to parse proxy URL: $_" "error"
    }
    return $null
}

function Apply-TelegramProxy($proxy) {
    if (-not $proxy) { return }
    
    try {
        $telegramPath = "C:\Program Files (x86)\Telegram Desktop\Telegram.exe"
        if (-not (Test-Path $telegramPath)) {
            $telegramPath = "C:\Program Files\Telegram Desktop\Telegram.exe"
        }
        
        if (Test-Path $telegramPath) {
            $proxyParam = "-proxy=$($proxy.server):$($proxy.port)"
            Write-Status "Starting Telegram with proxy..." "info"
            Start-Process -FilePath $telegramPath -ArgumentList "-proxy=$($proxy.server):$($proxy.port)" -ErrorAction SilentlyContinue
            Write-Status "Telegram started with proxy: $($proxy.server):$($proxy.port)" "success"
        }
    } catch {
        Write-Status "Failed to start Telegram with proxy: $_" "error"
    }
}

function Collect-ProxyFromVPN {
    Write-Host ""
    Write-Host "=== SBOR PROXY S AKTIVNYH SOEDINENIJ ===" -ForegroundColor Cyan
    
    $vpnStatus = Get-VPNStatus
    if (-not $vpnStatus.Connected) {
        Write-Status "VPN ne podklyuchen! Podklyuchite VPN period sбора." "warning"
        return
    }
    
    $collected = @()
    
    $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name = if ($proc) { $proc.ProcessName } else { "Unknown" }
            RemoteAddr = $_.RemoteAddress
            RemotePort = $_.RemotePort
        }
    } | Where-Object { $_.RemoteAddr -notmatch "^127\.|^::|^0\.0\.0\.0" } | Sort-Object RemoteAddr -Unique
    
    $ipList = @()
    foreach ($conn in $connections) {
        if ($conn.RemoteAddr -match "^(\d+\.\d+\.\d+\.\d+)$") {
            $ipList += $conn.RemoteAddr
        }
    }
    
    Write-Host "Najdeno IP: $($ipList.Count)" -ForegroundColor Green
    
    if ($ipList.Count -gt 0) {
        $proxyData = @{
            timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            ipCount = $ipList.Count
            ips = $ipList
        }
        
        $proxyFile = Join-Path $SnapshotsDir "proxy-collected-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $proxyData | ConvertTo-Json -Depth 3 | Out-File -FilePath $proxyFile -Encoding UTF8
        Write-Status "Proxy sohraneny: $proxyFile" "success"
        
        Write-Host ""
        Write-Host "Pervye 10 IP:" -ForegroundColor Cyan
        $ipList | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" }
    }
}

function Show-ProxyMenu {
    Write-Host ""
    Write-Host "=== PROXY NASTROJKI ===" -ForegroundColor Cyan
    
    $proxies = Get-ProxyConfig
    
    if ($proxies) {
        Write-Host "Soyhranennye proxy:" -ForegroundColor Green
        if ($proxies.telegram) {
            foreach ($p in $proxies.telegram) {
                Write-Host "  [Telegram] $($p.server):$($p.port)"
            }
        }
        if ($proxies.http) {
            foreach ($p in $proxies.http) {
                Write-Host "  [HTTP] $($p.server):$($p.port)"
            }
        }
    } else {
        Write-Host "Proxy ne sohraneny." -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "[1] Dobavit Telegram proxy (tg://...)"
    Write-Host "[2] Dobavit HTTP/SOCKS proxy"
    Write-Host "[3] Ochistit vse proxy"
    Write-Host "[4] Zapustit Telegram s proxy"
    Write-Host "[0] Nazad"
    Write-Host ""
    Write-Host "Vybor: " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    
    switch ($choice) {
        "1" {
            Write-Host "Vvedite tg:// proxy ssylku: " -ForegroundColor Yellow -NoNewline
            $url = Read-Host
            if ($url -match "tg://proxy\?server=(.+?)&port=(\d+)&secret=(.+)") {
                $proxy = @{
                    server = $matches[1]
                    port = $matches[2]
                    secret = $matches[3]
                    url = $url
                    added = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                }
                
                $currentProxies = Get-ProxyConfig
                if (-not $currentProxies) { $currentProxies = @{ telegram = @() } }
                if (-not $currentProxies.telegram) { $currentProxies.telegram = @() }
                
                $currentProxies.telegram += $proxy
                Save-ProxyConfig $currentProxies
                Write-Status "Telegram proxy dobavlen!" "success"
            } else {
                Write-Status "Nepravilnyj format. Ispolzuyte: tg://proxy?server=...&port=...&secret=..." "error"
            }
        }
        "2" {
            Write-Host "Server (ip ili hostname): " -ForegroundColor Yellow -NoNewline
            $server = Read-Host
            Write-Host "Port: " -ForegroundColor Yellow -NoNewline
            $port = Read-Host
            Write-Host "Tip (http/socks5): " -ForegroundColor Yellow -NoNewline
            $type = Read-Host
            
            if ($server -and $port) {
                $proxy = @{
                    server = $server
                    port = $port
                    type = $type
                    added = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                }
                
                $currentProxies = Get-ProxyConfig
                if (-not $currentProxies) { $currentProxies = @{ http = @() } }
                if (-not $currentProxies.http) { $currentProxies.http = @() }
                
                $currentProxies.http += $proxy
                Save-ProxyConfig $currentProxies
                Write-Status "HTTP proxy dobavlen!" "success"
            }
        }
        "3" {
            if (Test-Path $ProxyConfigFile) {
                Remove-Item $ProxyConfigFile -Force
                Write-Status "Vse proxy ochisheny" "success"
            }
        }
        "4" {
            $proxies = Get-ProxyConfig
            if ($proxies -and $proxies.telegram -and $proxies.telegram.Count -gt 0) {
                Apply-TelegramProxy $proxies.telegram[0]
            } else {
                Write-Status "Net soyhranennyh Telegram proxy!" "warning"
            }
        }
    }
}

function Show-CollectedIPsMenu {
    Write-Host ""
    Write-Host "=== SOBRANNYE IP ADRESA ===" -ForegroundColor Cyan
    
    $collectedFiles = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending
    
    if ($collectedFiles.Count -eq 0) {
        Write-Host "Net sobrannyh fajlov. Ispolzujte [S] dlya sbora." -ForegroundColor Gray
        return
    }
    
    Write-Host "Dostupnye fajly:" -ForegroundColor Green
    Write-Host ""
    
    $index = 1
    foreach ($file in $collectedFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $ipCount = if ($content.ipCount) { $content.ipCount } else { "?" }
        $ts = if ($content.timestamp) { $content.timestamp } else { $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm") }
        Write-Host "[$index] $ts - $ipCount IP"
        $index++
    }
    
    Write-Host ""
    Write-Host "[M] Manualnyj rezhim - primenit s proverkoj pinga"
    Write-Host "[A] Avtomaticheskij rezhim - background monitoring"
    Write-Host "[0] Vyhod"
    Write-Host ""
    Write-Host "Viberite punkt: " -ForegroundColor Yellow -NoNewline
    $menuChoice = Read-Host
    
    if ($menuChoice -eq "0" -or $menuChoice -eq "") { return }
    
    if ($menuChoice -eq "a" -or $menuChoice -eq "A") {
        $selectedFile = $collectedFiles[0]
        Start-AutoMode $selectedFile.FullName
        return
    }
    
    if ($menuChoice -ne "m" -and $menuChoice -ne "M") { return }
    
    Write-Host ""
    Write-Host "Viberite nomer fajla (0=vyhod): " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    
    if ($choice -eq "0" -or $choice -eq "") { return }
    
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $collectedFiles.Count) {
        $selectedFile = $collectedFiles[$idx]
        Apply-CollectedIPsWithPingCheck $selectedFile.FullName
    }
}

function Test-IPLatency($ip, $timeout = 2000) {
    try {
        $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue -TimeoutSeconds 2
        if ($ping) {
            $result = Test-Connection -ComputerName $ip -Count 1 -ErrorAction SilentlyContinue -TimeoutSeconds 2
            if ($result) {
                return $result.ResponseTime
            }
        }
    } catch { }
    return -1
}

function Apply-CollectedIPsWithPingCheck($filePath) {
    Write-Host ""
    Write-Host "=== PROVERKA PING I PRIMENENIE ===" -ForegroundColor Cyan
    
    $content = Get-Content $filePath -Raw | ConvertFrom-Json
    
    $prefs = Get-AppPreferences
    $viaVpnApps = @()
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "via_vpn" } | ForEach-Object {
            $viaVpnApps += $_.Key
        }
    }
    
    if ($viaVpnApps.Count -eq 0) {
        Write-Host "Net programm s rezhimom 'via_vpn' (+). Najmite [2] dlya nastroyki." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Programmy (+): $($viaVpnApps -join ', ')" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Pinguem IP adresa..." -ForegroundColor Yellow
    Write-Host ""
    
    $ipResults = @()
    $total = $content.ips.Count
    $current = 0
    
    foreach ($ip in $content.ips) {
        $current++
        $latency = Test-IPLatency $ip
        $status = if ($latency -gt 0 -and $latency -lt 150) { "OK" } elseif ($latency -gt 0) { "SLOW" } else { "FAIL" }
        $color = if ($status -eq "OK") { "Green" } elseif ($status -eq "SLOW") { "Yellow" } else { "Red" }
        
        if ($latency -gt 0) {
            Write-Host "[$current/$total] $ip - ${latency}ms" -ForegroundColor $color
        } else {
            Write-Host "[$current/$total] $ip - TIMEOUT" -ForegroundColor Red
        }
        
        $ipResults += [PSCustomObject]@{
            IP = $ip
            Latency = $latency
            Status = $status
        }
    }
    
    Write-Host ""
    Write-Host "=== REZULTATY ===" -ForegroundColor Cyan
    $okIPs = $ipResults | Where-Object { $_.Status -eq "OK" }
    $slowIPs = $ipResults | Where-Object { $_.Status -eq "SLOW" }
    $failIPs = $ipResults | Where-Object { $_.Status -eq "FAIL" }
    
    Write-Host "Bystrye (<150ms): $($okIPs.Count)" -ForegroundColor Green
    Write-Host "Medlennye (150ms+): $($slowIPs.Count)" -ForegroundColor Yellow
    Write-Host "Ne dostupnye: $($failIPs.Count)" -ForegroundColor Red
    Write-Host ""
    
    if ($okIPs.Count -eq 0) {
        Write-Status "Net dostupnyh IP!" "error"
        return
    }
    
    $threshold = 150
    Write-Host "Primenyajem marshruty s pingom < ${threshold}ms..." -ForegroundColor Cyan
    
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    
    $appliedCount = 0
    foreach ($result in $ipResults) {
        if ($result.Latency -gt 0 -and $result.Latency -lt $threshold) {
            $existing = Get-NetRoute -DestinationPrefix "$($result.IP)/32" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -notmatch "127\.0\.0\.1|::" }
            if (-not $existing) {
                if ($wifiGateway) {
                    $null = route add $result.IP mask 255.255.255.255 $wifiGateway metric 5 -p 2>&1
                } else {
                    $null = route add $result.IP mask 255.255.255.255 0.0.0.0 metric 5 -p 2>&1
                }
                $appliedCount++
            }
        }
    }
    
    Write-Status "Dobavleno $appliedCount marshrutov" "success"
    Write-Host "Programmy (+): $($viaVpnApps -join ', ')" -ForegroundColor Green
    Write-Host ""
    Write-Host "Zapustite programmy bez VPN." -ForegroundColor Green
}

$script:AutoModeRunning = $false
$script:AutoModePID = $null

function Start-AutoMode($filePath) {
    Write-Host ""
    Write-Host "=== AVTOMATICHESKIJ REZHIM ===" -ForegroundColor Cyan
    
    $content = Get-Content $filePath -Raw | ConvertFrom-Json
    
    $prefs = Get-AppPreferences
    $viaVpnApps = @()
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "via_vpn" } | ForEach-Object {
            $viaVpnApps += $_.Key
        }
    }
    
    if ($viaVpnApps.Count -eq 0) {
        Write-Host "Net programm s rezhimom 'via_vpn' (+)." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Programmy: $($viaVpnApps -join ', ')" -ForegroundColor Cyan
    Write-Host "IP adresov: $($content.ips.Count)"
    Write-Host ""
    Write-Host "Zapuskaju avtomaticheskij monitoring..." -ForegroundColor Green
    Write-Host "Najmite [7] dlya ostanovki avtorezhima"
    Write-Host ""
    
    $script:AutoModeRunning = $true
    $script:AutoModeFilePath = $filePath
    $script:AutoModeApps = $viaVpnApps
    
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    
    while ($script:AutoModeRunning) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        
        $ipResults = @()
        foreach ($ip in $content.ips) {
            $latency = Test-IPLatency $ip
            if ($latency -gt 0) {
                $ipResults += [PSCustomObject]@{
                    IP = $ip
                    Latency = $latency
                }
            }
        }
        
        if ($ipResults.Count -gt 0) {
            $best = ($ipResults | Sort-Object Latency | Select-Object -First 1)
            $avg = [math]::Round(($ipResults | Measure-Object Latency -Average).Average, 1)
            
            Write-Host "[$timestamp] Luchshij IP: $($best.IP) ($($best.Latency)ms) | Srednij: ${avg}ms | Rabotayut: $($ipResults.Count)/$($content.ips.Count)" -ForegroundColor Cyan
            
            foreach ($ip in $content.ips) {
                $existing = Get-NetRoute -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -notmatch "127\.0\.0\.1|::" }
                if (-not $existing) {
                    if ($wifiGateway) {
                        $null = route add $ip mask 255.255.255.255 $wifiGateway metric 5 -p 2>&1
                    } else {
                        $null = route add $ip mask 255.255.255.255 0.0.0.0 metric 5 -p 2>&1
                    }
                }
            }
        } else {
            Write-Host "[$timestamp] Net dostupnyh IP! Proverte internet." -ForegroundColor Red
        }
        
        Start-Sleep -Seconds 15
        
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true).Key
            if ($key -eq "7") {
                Write-Host ""
                Write-Host "Avtomaticheskij rezhim ostanovlen." -ForegroundColor Yellow
                $script:AutoModeRunning = $false
                break
            }
        }
    }
}

function Invoke-NetworkReset {
    Write-Host ""
    Write-Host "=== PRIORITY VOSSTANOVLENIE SETI ===" -ForegroundColor Cyan
    
    Write-Status "[1/5] Disabling VPN adapters..." "info"
    Disable-AllVPNAdapters
    Start-Sleep -Seconds 2
    
    Write-Status "[2/5] Renewing IP..." "info"
    $adapter = Get-ActiveAdapter
    if ($adapter) {
        $null = ipconfig /release $adapter 2>$null
        Start-Sleep -Seconds 1
        $null = ipconfig /renew $adapter 2>$null
        Start-Sleep -Seconds 3
    }
    
    Write-Status "[3/5] Flushing DNS..." "info"
    $null = ipconfig /flushdns 2>$null
    
    Write-Status "[4/5] Checking network..." "info"
    if (Test-Network) {
        Write-Status "Network restored!" "success"
    } else {
        Write-Status "Network still not working..." "warning"
    }
    
    Write-Status "[5/5] Running optimizations..." "info"
    Optimize-NetworkSpeed
    
    Write-Host ""
    Write-Status "Reset complete." "success"
}

function Add-DirectRoute($ip) {
    if ($ip -match "^(\d+\.\d+\.\d+\.\d+)$") {
        $existing = Get-NetRoute -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -notmatch "127\.0\.0\.1|::" }
        if (-not $existing) {
            $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
            if ($wifiGateway) {
                $result = route add $ip mask 255.255.255.255 $wifiGateway metric 5 -p 2>&1
            } else {
                $result = route add $ip mask 255.255.255.255 0.0.0.0 metric 5 -p 2>&1
            }
            if ($result -notmatch "already exists|уже существует") {
                Write-Status "   Added route for $ip via $wifiGateway" "info"
            }
        }
    }
}

function Remove-DirectRoutes {
    $prefs = Get-AppPreferences
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "direct" } | ForEach-Object {
            $appName = $_.Key
            $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
                $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq $appName) {
                    return $_.RemoteAddress
                }
            } | Select-Object -Unique
            
            foreach ($ip in $connections) {
                if ($ip -notmatch "^::|127\.|0\.0\.0\.0") {
                    route delete $ip mask 255.255.255.255 $wifiGateway 2>$null | Out-Null
                    route delete $ip mask 255.255.255.255 2>$null | Out-Null
                }
            }
        }
    }
    
    $dnsServers = @("8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "208.67.222.222", "8.26.56.26", "8.20.247.20")
    foreach ($dns in $dnsServers) {
        route delete $dns mask 255.255.255.255 $wifiGateway 2>$null | Out-Null
    }
    
    Write-Status "Direct routes cleared" "success"
}

function Clear-AllDirectRoutes {
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    if (-not $wifiGateway) { 
        Write-Status "Cannot find WiFi gateway! Try restarting router." "error"
        return 
    }
    
    $prefs = Get-AppPreferences
    $allIPs = @()
    
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | ForEach-Object { $allIPs += $_.Key }
    }
    
    $dnsServers = @("8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1")
    $allIPs += $dnsServers
    
    Write-Status "Cleaning routes via $wifiGateway..." "warning"
    
    foreach ($ip in $allIPs) {
        route delete $ip mask 255.255.255.255 $wifiGateway 2>$null | Out-Null
    }
    
    Write-Status "Routes cleared. Wait 5 sec..." "info"
    Start-Sleep -Seconds 5
    
    if (Test-Network) {
        Write-Status "Internet OK!" "success"
    } else {
        Write-Status "No internet! Restart router manually!" "error"
    }
}

function Apply-DirectRoutes {
    $prefs = Get-AppPreferences
    if (-not $prefs.apps) { return }
    
    Write-Status "Applying direct routes..." "info"
    
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    if (-not $wifiGateway) {
        Write-Status "WiFi gateway not found! Aborting." "error"
        return
    }
    Write-Status "WiFi Gateway: $wifiGateway" "info"
    
    $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "direct" } | ForEach-Object {
        $appName = $_.Key
        Write-Status "   Processing: $appName" "info"
        
        $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq $appName) {
                return $_.RemoteAddress
            }
        } | Select-Object -Unique
        
        foreach ($ip in $connections) {
            if ($ip -notmatch "^::|127\.|0\.0\.0\.0|255\.|255\.255\.255\.255") {
                Add-DirectRoute $ip
            }
        }
    }
    
    $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    if ($routes) {
        Write-Status "Active default routes:" "info"
        foreach ($r in $routes) {
            Write-Status "   $($r.DestinationPrefix) -> $($r.NextHop) ($($r.InterfaceAlias))" "info"
        }
    }
}

function Get-VPNStatus {
    $vpnAdapters = Get-NetAdapter | Where-Object { $_.Name -match "ChatVPN|TAP|TUN|VPN|OpenVPN|WireGuard" }
    $connected = $vpnAdapters | Where-Object { $_.Status -eq "Up" }
    
    $chatVpnProcess = Get-Process | Where-Object { $_.Name -match "ChatVPN|vpnchat" } -ErrorAction SilentlyContinue
    
    if ($connected -or $chatVpnProcess) {
        return @{
            Connected = $true
            Adapters = $connected
            Process = $chatVpnProcess
        }
    }
    return @{
        Connected = $false
        Adapters = $vpnAdapters
        Process = $null
    }
}

function Scan-NetworkApps {
    Write-Host ""
    Write-Host "=== SCANNING NETWORK CONNECTIONS ===" -ForegroundColor Cyan
    
    $connections = Get-NetTCPConnection -State Established,TimeWait | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name = if ($proc) { $proc.ProcessName } else { "Unknown" }
            PID = $_.OwningProcess
            LocalAddr = $_.LocalAddress
            LocalPort = $_.LocalPort
            RemoteAddr = $_.RemoteAddress
            RemotePort = $_.RemotePort
            State = $_.State
        }
    } | Sort-Object Name -Unique
    
    $udpConnections = Get-NetUDPEndpoint | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name = if ($proc) { $proc.ProcessName } else { "Unknown" }
            PID = $_.OwningProcess
            LocalAddr = $_.LocalAddress
            LocalPort = $_.LocalPort
            RemoteAddr = $_.RemoteAddress
            RemotePort = $_.RemotePort
            State = "UDP"
        }
    } | Sort-Object Name -Unique
    
    $allApps = ($connections + $udpConnections) | Sort-Object Name -Unique
    
    $appsList = @()
    foreach ($app in $allApps) {
        if ($app.Name -ne "Unknown" -and $app.Name -ne "System" -and $app.Name -notmatch "^svchost") {
            $appsList += [PSCustomObject]@{
                Name = $app.Name
                PID = $app.PID
                RemoteAddr = $app.RemoteAddr
                RemotePort = $app.RemotePort
                Protocol = if ($app.State -eq "UDP") { "UDP" } else { "TCP" }
            }
        }
    }
    
    return $appsList | Sort-Object Name
}

function Show-NetworkAppsTable($apps) {
    $prefs = Get-AppPreferences
    $vpnConnected = (Get-VPNStatus).Connected
    
    Write-Host ""
    Write-Host " Active Network Connections " -ForegroundColor Yellow
    if ($vpnConnected) {
        Write-Host " [VPN PODKLYUCHEN] " -ForegroundColor Green
    } else {
        Write-Host " [VPN OTLUCHEN] " -ForegroundColor Red
    }
    Write-Host ("-" * 90) -ForegroundColor Gray
    Write-Host ("{0,-23} | {1,-6} | {2,-18} | {3,-5} | {4,-5}" -f "Application   ", "PID", "Remote IP", "Port", "VPN") -ForegroundColor White
    Write-Host ("-" * 90) -ForegroundColor Gray
    
    $index = 1
    foreach ($app in $apps) {
        $vpnStatus = $null
        if ($prefs.apps -and $prefs.apps[$app.Name]) {
            $vpnStatus = $prefs.apps[$app.Name]
        }
        
        if ($vpnConnected) {
            $vpnIcon = switch ($vpnStatus) {
                "direct" { "[-]" }
                default { "[+]" }
            }
        } else {
            $vpnIcon = switch ($vpnStatus) {
                "direct" { "[-]" }
                "via_vpn" { "[+]" }
                default { "[0]" }
            }
        }
        
        Write-Host ("[{0,2}] {1,-21} | {2,-6} | {3,-18} | {4,-5} | {5,-5}" -f $index, $app.Name, $app.PID, $app.RemoteAddr, $app.RemotePort, $vpnIcon)
        $index++
    }
    Write-Host ("-" * 90) -ForegroundColor Gray
    Write-Host "[+] - IDET CHEREZ VPN   [-] - IDET NAPRYAMUYU   [0] - NE NASTROENO" -ForegroundColor Gray
}

function Save-AppPreferences {
    param([hashtable]$prefs)
    
    $json = @{
        apps = $prefs.apps
        routes = $prefs.routes
        lastUpdated = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
    
    $json | ConvertTo-Json -Depth 3 | Out-File -FilePath $PreferencesFile -Encoding UTF8
    Write-Status "Preferences saved" "success"
}

function Set-AppPreference($appName, $mode) {
    $prefs = Get-AppPreferences
    
    if ($mode -eq "direct") {
        $prefs.apps[$appName] = "direct"
        Write-Status "App '$appName' set to: DIRECT" "success"
    } elseif ($mode -eq "via_vpn") {
        $prefs.apps[$appName] = "via_vpn"
        Write-Status "App '$appName' set to: VIA VPN" "success"
    } elseif ($mode -eq "skip") {
        $prefs.apps[$appName] = "skip"
        Write-Status "App '$appName' set to: SKIP" "info"
    }
    
    Save-AppPreferences $prefs
}

function Get-ChatVPNPath {
    $paths = @(
        "C:\Program Files (x86)\ChatVPN\ChatVPN.exe",
        "C:\Program Files\ChatVPN\ChatVPN.exe",
        "${env:ProgramFiles(x86)}\ChatVPN\ChatVPN.exe",
        "${env:ProgramFiles}\ChatVPN\ChatVPN.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Start-ChatVPN {
    $path = Get-ChatVPNPath
    if ($path) {
        Write-Status "Starting ChatVPN..." "info"
        Start-Process -FilePath $path -PassThru
        Start-Sleep -Seconds 3
        Write-Status "ChatVPN started" "success"
    } else {
        Write-Status "ChatVPN not found at expected paths" "error"
    }
}

function Stop-ChatVPN {
    $procs = Get-Process | Where-Object { $_.Name -match "ChatVPN|vpnchat" -or $_.Path -match "ChatVPN" }
    foreach ($p in $procs) {
        Write-Status "Stopping $($p.ProcessName) (PID: $($p.Id))" "info"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Status "ChatVPN stopped" "success"
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  VPN Network Controller v3.1" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Scan Network   - Skanirovanie seti"
    Write-Host "[2] Preferences    - Nastrojki programm"
    Write-Host "[3] Show Prefs     - Pokazat nastrojki"
    Write-Host "[4] Collect IPs    - Sobrat IP s VPN"
    Write-Host "[5] Apply Routes  - Primenit sobrannye IP"
    Write-Host "[6] Reset Network - Prinudit vosstanovlenie"
    Write-Host "[0] Exit"
    Write-Host ""
}

function Clean-RoutesOnExit {
    Write-Host ""
    Write-Host "=== OCHISTKA MARSHRUTOV PRI VYHODE ===" -ForegroundColor Yellow
    
    $prefs = Get-AppPreferences
    $viaVpnApps = @()
    if ($prefs.apps) {
        $prefs.apps.GetEnumerator() | Where-Object { $_.Value -eq "via_vpn" } | ForEach-Object {
            $viaVpnApps += $_.Key
        }
    }
    
    if ($viaVpnApps.Count -gt 0) {
        $deletedCount = 0
        foreach ($app in $viaVpnApps) {
            $routes = Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { 
                $_.DestinationPrefix -match "^\d+\.\d+\.\d+\.\d+/\d+$" -and 
                $_.NextHop -notmatch "127\.0\.0\.1|::" 
            }
            
            foreach ($route in $routes) {
                try {
                    $null = route delete $route.DestinationPrefix 2>$null
                    $deletedCount++
                } catch { }
            }
        }
        
        if ($deletedCount -gt 0) {
            Write-Status "Udaleno marshrutov: $deletedCount" "success"
        } else {
            Write-Status "Net marshrutov dlya ochistki" "info"
        }
    }
    
    Write-Host "Optimizacii seti: sokhraneny (ne sbrasyvayutsya)" -ForegroundColor Green
    
    $latestFile = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestFile) {
        Write-Host "Snippets (poslednie IP): $latestFile" -ForegroundColor Green
    }
}

# Main menu loop
while ($true) {
    Show-MainMenu
    
    $input = Read-Host "Viberite punkt"
    if ([string]::IsNullOrWhiteSpace($input)) {
        $menuChoice = ""
    } else {
        $menuChoice = $input.Trim().ToLower()
    }
    
    switch ($menuChoice) {
        "1" {
            $apps = Scan-NetworkApps
            Show-NetworkAppsTable $apps
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "2" {
            Set-PreferencesMenu
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "3" {
            Show-PreferencesMenu
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "4" {
            Collect-ProxyFromVPN
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "5" {
            Show-CollectedIPsMenu
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "6" {
            Invoke-NetworkReset
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "0" {
            Write-Host ""
            Write-Host "Vyhod iz programmy..." -ForegroundColor Yellow
            Write-Host "Ochistka marshrutov..." -ForegroundColor Yellow
            
            Clean-RoutesOnExit
            
            Write-Host ""
            Write-Host "Do svidaniya!" -ForegroundColor Cyan
            exit 0
        }
        "" {
        }
        default {
            Write-Host "Nepravilnyj punkt" -ForegroundColor Red
        }
    }
}

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
    
    Write-Host ""
    Write-Status "=== OPTIMIZING NETWORK SPEED (SET RABOTAET) ===" "info"
    Optimize-NetworkSpeed
    
    Write-Log "Network working, optimized"
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
