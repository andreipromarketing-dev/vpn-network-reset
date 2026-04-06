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
    Write-Host ("{0,-20} | {1,-6} | {2,-18} | {3,-5} | {4,-5}" -f "Application", "PID", "Remote IP", "Port", "VPN") -ForegroundColor White
    Write-Host ("-" * 90) -ForegroundColor Gray
    
    $index = 1
    foreach ($app in $apps) {
        $vpnStatus = $null
        if ($prefs.apps -and $prefs.apps.PSObject.Properties[$app.Name]) {
            $vpnStatus = $prefs.apps.PSObject.Properties[$app.Name].Value
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
        
        Write-Host ("[{0,2}] {1,-18} | {2,-6} | {3,-18} | {4,-5} | {5,-5}" -f $index, $app.Name, $app.PID, $app.RemoteAddr, $app.RemotePort, $vpnIcon)
        $index++
    }
    Write-Host ("-" * 90) -ForegroundColor Gray
    Write-Host "[+] - IDET CHEREZ VPN   [-] - IDET NAPRYAMUYU   [0] - NE NASTROENO" -ForegroundColor Gray
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
    }
}

function Show-MainMenu {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  VPN Network Controller v3.1" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Scan Network   - Skanirovanie seti"
    Write-Host "[2] Preferences    - Nastrojka prilozhenij"
    Write-Host "[3] Show Prefs     - Pokazat nastrojki"
    Write-Host "[4] Snapshots      - Istorija snaphotov"
    Write-Host ""
    Write-Host "[5] Start VPN      - Vklyuchit ChatVPN"
    Write-Host "[6] Stop VPN       - Otklyuchit ChatVPN"
    Write-Host "[7] VPN Status     - Status VPN"
    Write-Host ""
        Write-Host "[8] Vosstanovit Internet"
    Write-Host "[0] Exit"
    Write-Host ""
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

function Show-SnapshotsMenu {
    Write-Host ""
    Write-Host "=== ISTORIJA SNAPSHOTOV ===" -ForegroundColor Cyan
    
    $files = Get-ChildItem $SnapshotsDir -Filter "*.json" | Where-Object { $_.Name -ne "preferences.json" } | Sort-Object LastWriteTime -Descending | Select-Object -First 20
    
    if ($files.Count -eq 0) {
        Write-Host "Snapshots ne najdeny." -ForegroundColor Gray
        return
    }
    
    $index = 1
    foreach ($file in $files) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($content) {
            $info = if ($content.ip) { "IP: $($content.ip)" } elseif ($content.timestamp) { $content.timestamp } else { "N/A" }
            Write-Host ("[{0,2}] {1} - {2}" -f $index, $file.Name, $info)
        } else {
            Write-Host ("[{0,2}] {1}" -f $index, $file.Name)
        }
        $index++
    }
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
Write-Host "  VPN Network Controller v3.1" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "=== SOHRANENIE TEKUSCHEGO SOSTOANIJA SETI ===" -ForegroundColor Cyan
$current = Get-NetworkSnapshot
Write-Status "Current IP: $($current.ip), Gateway: $($current.gateway)" "info"
Save-Snapshot $current
Write-Host ""

# Main menu loop
while ($true) {
    Show-MainMenu
    
    $input = Read-Host "Viberite punkt"
    if ([string]::IsNullOrWhiteSpace($input)) {
        $menuChoice = ""
    } else {
        $menuChoice = $input.Trim()
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
            Show-SnapshotsMenu
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "5" {
            Start-ChatVPN
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "6" {
            Stop-ChatVPN
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "7" {
            $status = Get-VPNStatus
            Write-Host ""
            if ($status.Connected) {
                Write-Host "VPN: PODKLYUCHEN" -ForegroundColor Green
                foreach ($a in $status.Adapters) {
                    Write-Host "  - $($a.Name) ($($a.Status))"
                }
            } else {
                Write-Host "VPN: OTLUCHEN" -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "Najmite Enter dlja prodolzhenija..." -ForegroundColor Gray
            Read-Host
        }
        "8" {
            break
        }
        "0" {
            Write-Host "Vyhod..." -ForegroundColor Yellow
            exit 0
        }
        default {
            Write-Host "Nepravilnyj punkt" -ForegroundColor Red
        }
    }
    
    if ($menuChoice -eq "8") { break }
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
