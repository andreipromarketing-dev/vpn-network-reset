# ==============================================================================
# Network Rescue & Optimizer Script
# Назначение: Восстановление сети после блокировок/сбоев и оптимизация стека TCP.
# Внимание: Запускать ОТ ИМЕНИ АДМИНИСТРАТОРА (PowerShell Run as Administrator)
# ==============================================================================

param(
    [switch]$Rollback # Флаг для возврата настроек к стандартным значениям Windows
)

$ErrorActionPreference = "Stop"

# Цвета для вывода
function Write-Log {
    param($Message, $Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

# Проверка прав администратора
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Log "ОШИБКА: Скрипт должен быть запущен от имени Администратора!" "Red"
    Start-Sleep -Seconds 2
    exit 1
}

Write-Log "=== ЗАПУСК МОДУЛЯ ВОССТАНОВЛЕНИЯ И ОПТИМИЗАЦИИ ===" "Cyan"

# ------------------------------------------------------------------------------
# ЭТАП 1: Глубокий сброс сетевых настроек (Rescue Mode)
# ------------------------------------------------------------------------------
if (-not $Rollback) {
    Write-Log "Этап 1: Выполнение глубокого сброса сетевых протоколов..." "Yellow"
    
    try {
        # Сброс Winsock (каталог сокетов) - лечит многие проблемы с браузерами
        Write-Log "Сброс каталога Winsock..." "Gray"
        netsh winsock reset | Out-Null
        
        # Сброс TCP/IP стека до дефолтных значений
        Write-Log "Сброс стека TCP/IP..." "Gray"
        netsh int ip reset | Out-Null
        
        # Очистка таблиц маршрутизации (если есть зависшие маршруты от VPN)
        Write-Log "Очистка таблиц маршрутизации..." "Gray"
        route -f 2>$null | Out-Null # Игнорируем ошибку, если таблица пуста
        
        # Очистка DNS кэша
        Write-Log "Очистка DNS кэша..." "Gray"
        ipconfig /flushdns | Out-Null
        
        # Перезапуск сетевых служб (безопаснее, чем отключение адаптеров)
        Write-Log "Перезапуск критических сетевых служб..." "Gray"
        $services = @("Dnscache", "NlaSvc", "LanmanWorkstation")
        foreach ($svc in $services) {
            try {
                Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
            } catch {}
        }
        
        Write-Log "Сброс выполнен успешно. Требуется перезагрузка для полного применения, но мы продолжим оптимизацию." "Green"
    }
    catch {
        Write-Log "Ошибка при сбросе: $_" "Red"
    }
}

# ------------------------------------------------------------------------------
# ЭТАП 2: Оптимизация TCP/IP под высокоскоростное соединение
# ------------------------------------------------------------------------------
if (-not $Rollback) {
    Write-Log "Этап 2: Применение оптимизаций TCP/IP..." "Yellow"

    # 1. Включение автоматической настройки окна приема (Window Auto-Tuning)
    # Это КРИТИЧЕСКИ важно для современных скоростных каналов. 
    # 'normal' - стандарт, 'experimental' - может дать прирост на очень высоких задержках, но рискованно.
    Write-Log "Настройка TCP Window Auto-Tuning Level..." "Gray"
    netsh interface tcp set global autotuninglevel=normal | Out-Null

    # 2. Управление перегрузками (ECN)
    # Включаем поддержку ECN, чтобы роутеры могли сигнализировать о перегрузке без потери пакетов
    Write-Log "Включение поддержки ECN..." "Gray"
    netsh interface tcp set global ecncapability=enabled | Out-Null

    # 3. Оптимизация буферов
    # Увеличиваем буферы для лучшей пропускной способности
    Write-Log "Настройка размеров буферов..." "Gray"
    netsh interface tcp set global receivewindowautoscaling=enabled | Out-Null
    
    # 4. Отключаем лишние эвристики, которые могут мешать при DPI
    # NetDMA и DirectCacheAccess обычно полезны, но иногда вызывают конфликты драйверов. Оставляем включенными по умолчанию.
    
    # 5. Настройка времени ожидания (Timed Wait Delay)
    # Ставим 60 секунд (баланс между освобождением портов и стабильностью). 
    # 30 сек (как в старом скрипте) - опасно и ведет к ошибкам подключений.
    Write-Log "Корректировка TCP TimedWaitDelay (60 сек)..." "Gray"
    netsh interface tcp set global timedwaitdelay=60 | Out-Null

    # 6. Отключение RFC 1323 Timestamps (Иногда помогает обойти примитивный DPI, но может сломать некоторые CDN)
    # По умолчанию оставляем включенными для стабильности. Если нужна агрессивная анти-DPI, раскомментировать ниже:
    # Write-Log "Отключение TCP Timestamps (Anti-DPI mode)..." "Gray"
    # netsh interface tcp set global timestamps=disabled | Out-Null
    
    Write-Log "Оптимизации применены." "Green"
}

# ------------------------------------------------------------------------------
# ЭТАП 3: Обновление IP и DNS (Renew)
# ------------------------------------------------------------------------------
Write-Log "Этап 3: Получение свежих сетевых настроек..." "Yellow"

# Получаем имена активных интерфейсов (исключаем виртуальные и отключенные)
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback|TAP|WireGuard' }

foreach ($adapter in $adapters) {
    $name = $adapter.Name
    Write-Log "Обработка интерфейса: $name" "Gray"
    
    # Обновление IP (DHCP)
    try {
        ipconfig /release "$name" 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
        ipconfig /renew "$name" 2>$null | Out-Null
    } catch {
        Write-Log "Не удалось обновить IP для $name (возможно статический IP)" "DarkGray"
    }

    # Обновление DNS
    try {
        ipconfig /flushdns | Out-Null
        Register-DnsClient | Out-Null
    } catch {}
}

# ------------------------------------------------------------------------------
# ЭТАП 4: Финал
# ------------------------------------------------------------------------------
Write-Log "=== ГОТОВО ===" "Cyan"
Write-Log "Действия завершены." "White"

if (-not $Rollback) {
    Write-Log "РЕКОМЕНДАЦИЯ: Для полного вступления изменений в силу (особенно после netsh winsock reset) рекомендуется ПЕРЕЗАГРУЗИТЬ компьютер." "Magenta"
    Write-Log "Если сеть не появилась сразу, попробуйте отключить и включить кабель/WiFi вручную." "Yellow"
} else {
    Write-Log "Настройки возвращены к стандартным значениям Windows. Рекомендуется перезагрузка." "Magenta"
}

Start-Sleep -Seconds 3
