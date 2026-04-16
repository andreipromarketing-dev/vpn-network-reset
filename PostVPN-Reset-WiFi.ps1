# VPN Network Controller v3.5 - Interactive Menu Mode
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SnapshotsDir = Join-Path $ScriptDir "snapshots"
$LastSnapshot = Join-Path $SnapshotsDir "last-known-good.json"
$LogFile = Join-Path $ScriptDir "reset.log"
$PreferencesFile = Join-Path $SnapshotsDir "preferences.json"
$ProxyConfigFile = Join-Path $SnapshotsDir "proxies.json"
$GoodbyeDPIDir = Join-Path $ScriptDir "goodbyedpi"
$GoodbyeDPIExe = Join-Path $GoodbyeDPIDir "x86_64\goodbyedpi.exe"
$CustomBlacklistFile = Join-Path $GoodbyeDPIDir "custom-blacklist.txt"
$CustomSitelistFile = Join-Path $GoodbyeDPIDir "custom-sitelist.txt"

if (-not (Test-Path $SnapshotsDir)) {
    New-Item -ItemType Directory -Path $SnapshotsDir | Out-Null
}

# Note: No auto-cleanup on exit to avoid conflicts

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
    
    $adapter = Get-ActiveAdapter
    
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
    if ($adapter) {
        $adapterInfo = Get-NetAdapter -Name $adapter -ErrorAction SilentlyContinue
        if ($adapterInfo) {
            Write-Status "Current link speed: $($adapterInfo.LinkSpeed)" "info"
        }
    }
}

function Get-ActiveAdapter {
    $wifiAdapter = Get-NetAdapter | Where-Object { $_.InterfaceType -eq 71 -and $_.Status -eq 'Up' } | Select-Object -First 1
    if ($wifiAdapter) { return $wifiAdapter.Name }
    
    $connected = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'Tunnel|Virtual|Loopback|TAP|TUN|Bluetooth|NULL|isatap|Teredo' } | Select-Object -First 1
    if ($connected) { return $connected.Name }
    
    return "Wi-Fi"
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

$PreferencesFile = Join-Path $SnapshotsDir "preferences.json"
$ProxyConfigFile = Join-Path $SnapshotsDir "proxies.json"
$GoodbyeDPIDir = Join-Path $ScriptDir "goodbyedpi"
$GoodbyeDPIExe = Join-Path $GoodbyeDPIDir "x86_64\goodbyedpi.exe"
$CustomBlacklistFile = Join-Path $GoodbyeDPIDir "custom-blacklist.txt"
$CustomSitelistFile = Join-Path $GoodbyeDPIDir "custom-sitelist.txt"

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
    
    Write-Host "Sobirayus IP s aktivnyh soedinenij..." -ForegroundColor Yellow
    
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

function Download-FreeProxies {
    Write-Host ""
    Write-Host "=== SKACHIVANIE BESPLATNYH PROXY ===" -ForegroundColor Cyan
    
    $proxyUrls = @(
        "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt",
        "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt"
    )
    
    $proxies = @()
    
    foreach ($url in $proxyUrls) {
        Write-Host "Skachivayus: $(Split-Path $url -Leaf)" -ForegroundColor Yellow
        
        try {
            $curlPath = "C:\Windows\System32\curl.exe"
            if (-not (Test-Path $curlPath)) {
                $curlPath = "curl"
            }
            
            $tempFile = "$env:TEMP\proxies_$(Get-Random).txt"
            & $curlPath -sL -o $tempFile $url --silent --max-time 60
            
            if ((Test-Path $tempFile) -and (Get-Item $tempFile).Length -gt 100) {
                $content = Get-Content $tempFile
                foreach ($line in $content) {
                    if ($line -match "^(\S+://)?(\d+\.\d+\.\d+\.\d+):(\d+)") {
                        $proxies += "$($matches[2]):$($matches[3])"
                    }
                }
                Remove-Item $tempFile -Force
            }
        } catch {
            Write-Host "OSHIBKA: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    $proxies = $proxies | Select-Object -Unique
    
    Write-Host "Naydeno proxy: $($proxies.Count)" -ForegroundColor Green
    
    if ($proxies.Count -gt 0) {
        Write-Host "Proveryayu dostupnost..." -ForegroundColor Yellow
        
        $working = @()
        $testCount = 0
        $maxTests = 20
        
        foreach ($p in $proxies) {
            if ($testCount -ge $maxTests) { break }
            $testCount++
            
            $parts = $p.Split(':')
            $ip = $parts[0]
            $port = [int]$parts[1]
            
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $result = $tcp.BeginConnect($ip, $port, $null, $null)
                $wait = $result.AsyncWaitHandle.WaitOne(2000, $false)
                
                if ($wait -and $tcp.Connected) {
                    $working += $p
                    Write-Host "   [OK] $p" -ForegroundColor Green
                }
                $tcp.Close()
            } catch { }
        }
        
        Write-Host ""
        Write-Host "Rabotayuschih: $($working.Count)" -ForegroundColor Cyan
        
        if ($working.Count -gt 0) {
            $proxyData = @{
                timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
                ipCount = $working.Count
                type = "free_proxies"
                ips = $working
            }
            
            $proxyFile = Join-Path $SnapshotsDir "free-proxies-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
            $proxyData | ConvertTo-Json -Depth 3 | Out-File -FilePath $proxyFile -Encoding UTF8
            Write-Status "Sohraneno: $proxyFile" "success"
            
            Write-Host ""
            Write-Host "Rabotayuschie proxy:" -ForegroundColor Cyan
            $working | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" }
        }
    }
}

function Apply-FreeProxies {
    Write-Host ""
    Write-Host "=== PRIMENENIE SKACHANNYH PROXY ===" -ForegroundColor Cyan
    
    $proxyFiles = Get-ChildItem $SnapshotsDir -Filter "free-proxies-*.json" | Sort-Object LastWriteTime -Descending
    
    if ($proxyFiles.Count -eq 0) {
        Write-Host "Net skachannyh proxy. Snachala skachajte [4]." -ForegroundColor Yellow
        return
    }
    
    $latestFile = $proxyFiles[0]
    Write-Host "Ispolzuyu: $($latestFile.Name)" -ForegroundColor Green
    
    $content = Get-Content $latestFile.FullName -Raw | ConvertFrom-Json
    $proxies = $content.ips
    
    Write-Host "Dostupno proxy: $($proxies.Count)" -ForegroundColor Cyan
    
    if ($proxies.Count -eq 0) {
        Write-Host "Net rabotayuschih proxy!" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "Nastrojka sistemnyh proxy..." -ForegroundColor Yellow
    
    $firstProxy = $proxies[0]
    $proxyHost = $firstProxy.Split(":")[0]
    $proxyPort = $firstProxy.Split(":")[1]
    
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value "$proxyHost`:$proxyPort" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 1 -ErrorAction SilentlyContinue
    
    Write-Host "Proxy ustanovlen: $proxyHost`:$proxyPort" -ForegroundColor Green
    
    $env:HTTP_PROXY = "http://$proxyHost`:$proxyPort"
    $env:HTTPS_PROXY = "http://$proxyHost`:$proxyPort"
    
    Write-Host ""
    Write-Host "Proxy aktivirovan! Internet dolzhen idti cherez proxy." -ForegroundColor Cyan
    Write-Host "Dlya otmeny: [8] Clean Routes" -ForegroundColor Gray
}

function Test-IPLatency($ip, $timeout = 2000) {
    $testPorts = @(80, 443, 8080)
    foreach ($port in $testPorts) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connect = $tcpClient.BeginConnect($ip, $port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne($timeout, $false)
            
            if ($wait -and $tcpClient.Connected) {
                $tcpClient.Close()
                return 1
            }
            $tcpClient.Close()
        } catch { }
    }
    return -1
}

function Test-IPAviaTCP($ip) {
    $testPorts = @(80, 443, 8080, 5222, 4433)
    foreach ($port in $testPorts) {
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $connect = $tcpClient.BeginConnect($ip, $port, $null, $null)
            $wait = $connect.AsyncWaitHandle.WaitOne(1500, $false)
            
            if ($wait -and $tcpClient.Connected) {
                $tcpClient.Close()
                return $true
            }
            $tcpClient.Close()
        } catch { }
    }
    return $false
}

function Show-CollectedIPsMenu {
    Write-Host ""
    Write-Host "=== SOBRANNYE IP ADRESA ===" -ForegroundColor Cyan
    
    $collectedFiles = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending
    
    if ($collectedFiles.Count -eq 0) {
        Write-Host "Net sobrannyh fajlov. Ispolzujte [4] dlya sbora." -ForegroundColor Gray
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

function Apply-CollectedIPsWithPingCheck($filePath) {
    Write-Host ""
    Write-Host "=== PROVERKA I PRIMENENIE IP ===" -ForegroundColor Cyan
    
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
    Write-Host "Proveryajem dostupnost IP..." -ForegroundColor Yellow
    Write-Host ""
    
    $ipResults = @()
    $total = $content.ips.Count
    $current = 0
    
    foreach ($ip in $content.ips) {
        $current++
        $isWorking = Test-IPAviaTCP $ip
        $status = if ($isWorking) { "OK" } else { "FAIL" }
        $color = if ($status -eq "OK") { "Green" } else { "Red" }
        
        if ($isWorking) {
            Write-Host "[$current/$total] $ip - OK" -ForegroundColor $color
        } else {
            Write-Host "[$current/$total] $ip - TIMEOUT" -ForegroundColor Red
        }
        
        $ipResults += [PSCustomObject]@{
            IP = $ip
            Status = $status
        }
    }
    
    Write-Host ""
    Write-Host "=== REZULTATY ===" -ForegroundColor Cyan
    $okIPs = $ipResults | Where-Object { $_.Status -eq "OK" }
    $failIPs = $ipResults | Where-Object { $_.Status -eq "FAIL" }
    
    Write-Host "Dostupnye: $($okIPs.Count)" -ForegroundColor Green
    Write-Host "Ne dostupnye: $($failIPs.Count)" -ForegroundColor Red
    Write-Host ""
    
    if ($okIPs.Count -eq 0) {
        Write-Status "Net dostupnyh IP!" "error"
        return
    }
    
    Write-Host "Primenyajem marshruty dlya dostupnyh IP..." -ForegroundColor Cyan
    
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    
    $appliedCount = 0
    foreach ($result in $ipResults) {
        if ($result.Status -eq "OK") {
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
    Write-Host "Najmite [8] dlya ostanovki avtorezhima"
    Write-Host ""
    
    $script:AutoModeRunning = $true
    $script:AutoModeFilePath = $filePath
    $script:AutoModeApps = $viaVpnApps
    $script:FailedIPs = @{}
    
    $wifiGateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch "ChatVPN|VPN|Tunnel" } | Select-Object -First 1).NextHop
    
    while ($script:AutoModeRunning) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        
        $ipResults = @()
        $workingCount = 0
        foreach ($ip in $content.ips) {
            $isWorking = Test-IPAviaTCP $ip
            if ($isWorking) {
                $workingCount++
                $ipResults += [PSCustomObject]@{
                    IP = $ip
                    Latency = 1
                }
                if ($script:FailedIPs.ContainsKey($ip)) {
                    $script:FailedIPs[$ip] = 0
                }
            } else {
                if (-not $script:FailedIPs.ContainsKey($ip)) {
                    $script:FailedIPs[$ip] = 1
                } else {
                    $script:FailedIPs[$ip]++
                }
                
                if ($script:FailedIPs[$ip] -ge 3) {
                    $existing = Get-NetRoute -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -notmatch "127\.0\.0\.1|::" }
                    if ($existing) {
                        try {
                            $null = route delete $ip mask 255.255.255.255 2>$null
                            Write-Host "[$timestamp] Udalen neotvechajushij IP: $ip" -ForegroundColor Yellow
                        } catch { }
                    }
                    $script:FailedIPs[$ip] = 0
                }
            }
        }
        
        if ($ipResults.Count -gt 0) {
            Write-Host "[$timestamp] Rabotayut: $($ipResults.Count)/$($content.ips.Count) IP" -ForegroundColor Green
            
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
            if ($key -eq "8") {
                Write-Host ""
                Write-Host "Avtomaticheskij rezhim ostanovlen." -ForegroundColor Yellow
                $script:AutoModeRunning = $false
                break
            }
        }
    }
}

function Get-GoodbyeDPI {
    Write-Host ""
    Write-Host "=== SKACHIVANIE GOODBYEDPI ===" -ForegroundColor Cyan
    
    if (-not (Test-Path $GoodbyeDPIDir)) {
        New-Item -ItemType Directory -Path $GoodbyeDPIDir | Out-Null
    }
    
    if (Test-Path $GoodbyeDPIExe) {
        Write-Status "GoodbyeDPI already exists" "info"
        return $true
    }
    
    Write-Status "Trying alternative download methods..." "info"
    
    $urls = @(
        "https://github.com/ValdikSS/GoodbyeDPI/releases/download/v0.2.2/goodbyedpi-0.2.2.zip",
        "https://github.com/ValdikSS/GoodbyeDPI/releases/download/0.2.2/goodbyedpi-0.2.2.zip"
    )
    
    $zipPath = Join-Path $ScriptDir "goodbyedpi.zip"
    
    foreach ($zipUrl in $urls) {
        $fileName = $zipUrl -split '/' | Select-Object -Last 1
        Write-Status "Trying: $fileName" "info"
        
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            [Net.ServicePointManager]::DefaultConnectionLimit = 12
            
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $webClient.DownloadFile($zipUrl, $zipPath)
            
            if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 10000) {
                Write-Status "Downloaded! Size: $((Get-Item $zipPath).Length / 1KB) KB" "success"
                
                Expand-Archive -Path $zipPath -DestinationPath $GoodbyeDPIDir -Force
                
                $extractedExe = Join-Path $GoodbyeDPIDir "goodbyedpi.exe"
                if (-not (Test-Path $extractedExe)) {
                    $files = Get-ChildItem $GoodbyeDPIDir -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue
                    if ($files.Count -gt 0) {
                        $extractedExe = $files[0].FullName
                    }
                }
                
                if (Test-Path $extractedExe) {
                    Write-Status "GoodbyeDPI ready!" "success"
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }
        } catch {
            Write-Status "Failed: $($_.Exception.Message)" "warning"
        }
    }
    
    Write-Status "Trying curl.exe fallback..." "info"
    
    $curlPath = "C:\Windows\System32\curl.exe"
    if (-not (Test-Path $curlPath)) {
        $curlPath = "curl"
    }
    
    try {
        $tempZip = "$env:TEMP\goodbyedpi.zip"
        & $curlPath -L -o $tempZip "https://github.com/ValdikSS/GoodbyeDPI/releases/download/v0.2.2/goodbyedpi-0.2.2.zip" --silent --max-time 120
        
        if ((Test-Path $tempZip) -and (Get-Item $tempZip).Length -gt 10000) {
            Write-Status "Downloaded via curl! Size: $((Get-Item $tempZip).Length / 1KB) KB" "success"
            Copy-Item $tempZip $zipPath -Force
            Expand-Archive -Path $zipPath -DestinationPath $GoodbyeDPIDir -Force
            
            $extractedExe = Join-Path $GoodbyeDPIDir "goodbyedpi.exe"
            if (-not (Test-Path $extractedExe)) {
                $files = Get-ChildItem $GoodbyeDPIDir -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue
                if ($files.Count -gt 0) {
                    $extractedExe = $files[0].FullName
                }
            }
            
            if (Test-Path $extractedExe) {
                Write-Status "GoodbyeDPI ready!" "success"
                Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return $true
            }
        }
    } catch {
        Write-Status "Curl failed: $($_.Exception.Message)" "warning"
    }
    
    Write-Host ""
    Write-Status "Auto-download failed. Possible causes:" "error"
    Write-Status "  - Internet connection blocked" "info"
    Write-Status "  - VPN/Proxy interference" "info"
    Write-Status "  - GitHub access restricted" "info"
    Write-Host ""
    Write-Host "=== MANUAL SETUP ===" -ForegroundColor Yellow
    Write-Host "1. Open browser and go to:" -ForegroundColor White
    Write-Host "   https://github.com/ValdikSS/GoodbyeDPI/releases" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Download: goodbyedpi-0.2.2.zip" -ForegroundColor White
    Write-Host ""
    Write-Host "3. Extract ZIP contents to:" -ForegroundColor White
    Write-Host "   $GoodbyeDPIDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "4. Run this script again" -ForegroundColor White
    Write-Host ""
    
    return $false
}

function Start-GoodbyeDPI {
    param(
        [string]$Mode = "2",
        [string]$ProxyHost = "",
        [int]$ProxyPort = 0,
        [string]$ProxyType = ""
    )
    
    if (-not (Test-Path $GoodbyeDPIExe)) {
        $downloaded = Get-GoodbyeDPI
        if (-not $downloaded) {
            Write-Status "Cannot download GoodbyeDPI!" "error"
            return $false
        }
    }
    
    $running = Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Status "GoodbyeDPI already running (PID: $($running.Id))" "info"
        return $true
    }
    
    Write-Host ""
    Write-Host "=== ZAPUSK GOODBYEDPI (REZHIM: $Mode) ===" -ForegroundColor Cyan
    
    $customBlacklist = Join-Path $GoodbyeDPIDir "custom-blacklist.txt"
    $russiaBlacklist = Join-Path $GoodbyeDPIDir "russia-blacklist.txt"
    
    $blacklistArg = "--blacklist `"$russiaBlacklist`""
    if (Test-Path $customBlacklist) {
        $blacklistArg = "--blacklist `"$customBlacklist`""
        Write-Status "Using custom blacklist (ChatGPT, Claude, Perplexity)" "info"
    }
    
    $proxyArg = ""
    if ($ProxyHost -and $ProxyPort -gt 0) {
        if ($ProxyType -eq "socks5") {
            $proxyArg = "--portable-proxy 127.0.0.1:8888"
            Write-Status "Will use SOCKS5 proxy: $ProxyHost`:$ProxyPort" "info"
        } else {
            $proxyArg = "--portable-proxy 127.0.0.1:8888"
            Write-Status "Will use HTTP proxy: $ProxyHost`:$ProxyPort" "info"
        }
    }
    
    $exePath = $GoodbyeDPIExe
    
    $dpiArgs = switch ($Mode) {
        "1" { "-5 $blacklistArg --dns-addr 77.88.8.8 --dns-port 1253 $proxyArg" }
        "2" { "-5 $blacklistArg --dns-addr 77.88.8.8 --dns-port 1253 $proxyArg" }
        "3" { "-2 $proxyArg" }
        "4" { "-5 --dns-addr 77.88.8.8 --dns-port 1253 $proxyArg" }
        "5" { "--set-ttl 58 --auto-ttl $proxyArg" }
        "6" { "-9 $proxyArg" }
        default { "-5 $blacklistArg --dns-addr 77.88.8.8 --dns-port 1253 $proxyArg" }
    }
    
    try {
        Write-Status "Running: goodbyedpi.exe $dpiArgs" "info"
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exePath
        $psi.Arguments = $dpiArgs
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        
        $process = [System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Seconds 3
        
        if ($ProxyHost -and $ProxyPort -gt 0) {
            Write-Status "Starting proxy forwarder..." "info"
            Start-Process "netsh" -ArgumentList "interface portproxy add v4tov4 listenport=8888 connectaddress=$ProxyHost connectport=$ProxyPort" -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        
        $running = Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue
        if ($running) {
            Write-Status "GoodbyeDPI running! (PID: $($running.Id))" "success"
            if ($ProxyHost) {
                Write-Host "Traffic will go through proxy: $ProxyHost`:$ProxyPort" -ForegroundColor Green
            } else {
                Write-Host "ChatGPT, Claude, Perplexity, YouTube should work now!" -ForegroundColor Green
            }
            return $true
        }
    } catch {
        Write-Status "Failed to start: $($_.Exception.Message)" "error"
    }
    
    return $false
}

function Stop-GoodbyeDPI {
    Write-Host ""
    Write-Host "=== OSTANOVKA GOODBYEDPI ===" -ForegroundColor Cyan
    
    $procs = Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue
    if ($procs) {
        foreach ($p in $procs) {
            Write-Status "Stopping PID: $($p.Id)" "info"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Write-Status "GoodbyeDPI stopped" "success"
    } else {
        Write-Status "Not running" "info"
    }
}

function Show-GoodbyeDPIMenu {
    Write-Host ""
    Write-Host "=== GOODBYEDPI - OBHOD DPI ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "DPI = Deep Packet Inspection (inspekciya traffika)." -ForegroundColor White
    Write-Host "GoodbyeDPI skryvaet SNI - provider ne vidit сайты." -ForegroundColor White
    Write-Host ""
    Write-Host "VNIMANIE: Geoblokirovannye saity (ChatGPT, YouTube" -ForegroundColor Yellow
    Write-Host "v Rossii) GoodbyeDPI NE obhodit - nuzhen VPN!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "=== REZHIMY RABOTY ===" -ForegroundColor Cyan
    Write-Host "[1] Russia        - Blacklist + DNS (dlya DPI)"
    Write-Host "[2] Universal     - Universalnyj rezhim"
    Write-Host "[3] DNS Only       - Tolko DNS redirect"
    Write-Host ""
    Write-Host "[S] Start"
    Write-Host "[K] Stop"
    Write-Host "[T] Test connection"
    Write-Host "[0] Nazad"
    Write-Host ""
    Write-Host "Viberite punkt: " -ForegroundColor Yellow -NoNewline
    $choice = Read-Host
    
    switch ($choice) {
        "1" { Start-GoodbyeDPI -Mode "2" }
        "2" { Start-GoodbyeDPI -Mode "3" }
        "3" { Start-GoodbyeDPI -Mode "4" }
        "s" { Start-GoodbyeDPI -Mode "2" }
        "k" { Stop-GoodbyeDPI }
        "t" {
            Write-Host ""
            Write-Host "Testing sites..." -ForegroundColor Cyan
            
            $tests = @(
                @{ name = "Telegram"; host = "telegram.org" },
                @{ name = "Google"; host = "google.com" }
            )
            
            foreach ($test in $tests) {
                try {
                    $result = Test-NetConnection -ComputerName $test.host -Port 443 -WarningAction SilentlyContinue
                    if ($result.TcpTestSucceeded) {
                        Write-Host "   [$($test.name)] OK" -ForegroundColor Green
                    } else {
                        Write-Host "   [$($test.name)] BLOCKED" -ForegroundColor Red
                    }
                } catch {
                    Write-Host "   [$($test.name)] ERROR" -ForegroundColor Red
                }
            }
        }
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

function Test-Network {
    try {
        $gateway = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
        if ($gateway) {
            $ping = Test-Connection -ComputerName $gateway -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($ping) { return $true }
        }
        $ping = Test-Connection 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping) { return $true }
        $dns = Resolve-DnsName google.com -Server 8.8.8.8 -ErrorAction SilentlyContinue
        return ($dns -ne $null)
    } catch { return $false }
}

function Test-NetworkSpeed {
    Write-Host "Proveryayu skorost interneta..." -ForegroundColor Yellow
    
    $pingTest = Test-Connection -ComputerName "8.8.8.8" -Count 3 -ErrorAction SilentlyContinue
    if ($pingTest) {
        $avgPing = [math]::Round(($pingTest | Measure-Object ResponseTime -Average).Average, 1)
        Write-Host "Ping: $avgPing ms" -ForegroundColor Green
        
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Proxy = $null
            $startTime = Get-Date
            $tempFile = "$env:TEMP\speedtest_$PID.dat"
            
            $null = $wc.DownloadFileTaskAsync("https://speed.cloudflare.com/__down?bytes=5000000", $tempFile)
            Start-Sleep -Seconds 3
            $wc.CancelAsync()
            
            if (Test-Path $tempFile) {
                $fileInfo = Get-Item $tempFile
                $downloaded = $fileInfo.Length
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                
                $endTime = Get-Date
                $duration = ($endTime - $startTime).TotalSeconds
                
                if ($duration -gt 0.5 -and $downloaded -gt 10000) {
                    $speedMbps = [math]::Round(($downloaded * 8) / $duration / 1024 / 1024, 1)
                    Write-Host "Skachivanie: $speedMbps Mbit/s" -ForegroundColor Green
                    return @{
                        Download = $speedMbps
                        Ping = $avgPing
                        Success = $true
                    }
                }
            }
        } catch { }
        
        return @{
            Download = $null
            Ping = $avgPing
            Success = $true
        }
    }
    
    Write-Host "Set ne dostupna!" -ForegroundColor Red
    return @{
        Download = $null
        Ping = $null
        Success = $false
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
    Write-Host "  VPN Network Controller v3.5" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Scan Network   - Skanirovanie seti"
    Write-Host "[2] Proxy Routes   - Nastrojki programm"
    Write-Host "[3] Show Prefs     - Pokazat nastrojki"
    Write-Host "[4] Free Proxies   - Skachat besplatnye proxy"
    Write-Host "[5] Apply Proxy    - Primenit skachanny proxy"
    Write-Host "[6] Reset Network - Prinudit vosstanovlenie"
    Write-Host "[7] Optimize      - Optimizatsiya seti"
    Write-Host "[8] Clean Routes  - Ochistit marshruty"
    Write-Host "[G] GoodbyeDPI   - Obhod DPI"
    Write-Host "[0] Exit"
    Write-Host ""
}

function Clean-RoutesOnExit {
    Write-Host ""
    Write-Host "=== OCHISTKA MARSHRUTOV PRI VYHODE ===" -ForegroundColor Yellow
    
    $recentFiles = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 3
    
    if ($recentFiles.Count -eq 0) {
        Write-Status "Net fajlov s IP dlya ochistki" "info"
        Write-Host "Optimizacii seti: sokhraneny" -ForegroundColor Green
        return
    }
    
    $ipsToClean = @()
    foreach ($file in $recentFiles) {
        try {
            $content = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($content.ips) {
                $ipsToClean += $content.ips
            }
        } catch { }
    }
    $ipsToClean = $ipsToClean | Select-Object -Unique
    
    Write-Host "IP dlya ochistki: $($ipsToClean.Count)" -ForegroundColor Cyan
    
    $deletedCount = 0
    foreach ($ip in $ipsToClean) {
        $null = route delete $ip mask 255.255.255.255 2>$null
        $deletedCount++
    }
    
    if ($deletedCount -gt 0) {
        Write-Status "Udaleno marshrutov: $deletedCount" "success"
    } else {
        Write-Status "Net marshrutov dlya ochistki" "info"
    }
    
    Write-Host "Optimizacii seti: sokhraneny (ne sbrasyvayutsya)" -ForegroundColor Green
    
    $latestFile = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestFile) {
        Write-Host "Snippets (poslednie IP): $($latestFile.Name)" -ForegroundColor Green
    }
}

function Clean-AllProxyRoutes {
    Write-Host ""
    Write-Host "=== POLNAYA OCHISTKA VSEH MARSHRUTOV ===" -ForegroundColor Cyan
    
    $recentFiles = Get-ChildItem $SnapshotsDir -Filter "proxy-collected-*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 10
    
    if ($recentFiles.Count -eq 0) {
        Write-Host "Net fajlov." -ForegroundColor Yellow
        return
    }
    
    $ipsToClean = @()
    foreach ($file in $recentFiles) {
        try {
            $content = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($content.ips) {
                $ipsToClean += $content.ips
            }
        } catch { }
    }
    $ipsToClean = $ipsToClean | Select-Object -Unique
    
    Write-Host " Ochischayetsya $($ipsToClean.Count) IP..." -ForegroundColor Yellow
    
    $deletedCount = 0
    foreach ($ip in $ipsToClean) {
        $null = route delete $ip mask 255.255.255.255 2>$null
        $deletedCount++
    }
    
    Write-Status "Udaleno marshrutov: $deletedCount" "success"
}



# ============ MENU MODE ============
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
            Write-Host ""
            $speed = Test-NetworkSpeed
            if ($speed.Success) {
                Write-Host ""
                Write-Host "=== SKOROST INTERNETA ===" -ForegroundColor Cyan
                if ($speed.Download) {
                    Write-Host "Skachivanie: $($speed.Download) Mbit/s" -ForegroundColor Green
                }
                if ($speed.Ping) {
                    Write-Host "Ping: $($speed.Ping) ms" -ForegroundColor $(if ($speed.Ping -lt 50) { "Green" } elseif ($speed.Ping -lt 100) { "Yellow" } else { "Red" })
                }
            }
            
            Write-Host ""
            Write-Host "=== SKANIROVANIE SETI ===" -ForegroundColor Cyan
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
            Download-FreeProxies
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "5" {
            Apply-FreeProxies
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
        "7" {
            Optimize-NetworkSpeed
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "8" {
            Clean-AllProxyRoutes
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "g" {
            Show-GoodbyeDPIMenu
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "G" {
            Show-GoodbyeDPIMenu
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
    }
}
# Auto-reset mode runs if menu mode is disabled
if ($args.Count -gt 0 -and $args[0] -eq "-Auto") {
    goto :AutoReset
}

# Exit menu mode if running auto-reset
exit 0

:AutoReset
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
    Write-Status "=== OPTIMIZING NETWORK SPEED ===" "info"
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
