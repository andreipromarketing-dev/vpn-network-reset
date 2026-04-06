# 🔄 VPN Network Reset

Автоматический сброс сети после VPN (ChatVPN и др.) без перезагрузки компьютера.

[![Stars](https://img.shields.io/github/stars/andreipromarketing-dev/vpn-network-reset?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/stargazers)
[![Forks](https://img.shields.io/github/forks/andreipromarketing-dev/vpn-network-reset?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/network/members)
[![Download](https://img.shields.io/badge/Download-v3.0-blue?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/releases/tag/v3.0)

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?style=flat-square)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10/11-green?style=flat-square)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

---

## 📖 Описание

После использования VPN (в частности ChatVPN) Windows часто показывает "DNS-сервер недоступен" и не предлагает решений.

Этот скрипт:
1. Автоматически определяет активный Wi-Fi адаптер
2. Очищает DNS-кэш и переподключает адаптер
3. Восстанавливает сеть из сохранённых пресетов
4. Применяет оптимизацию TCP для максимальной скорости
5. Сохраняет до 50 рабочих конфигураций

**Результат:** интернет работает без перезагрузки.

---

## 🚀 Быстрый старт

### Вариант 1: Ярлык на рабочем столе (рекомендуется)

1. Скачайте файл `Reset-Network.bat`
2. Кликните правой кнопкой → "Создать ярлык"
3. Перенесите ярлык на рабочий стол
4. Готово! Клик = сброс сети

### Вариант 2: Запуск напрямую

1. Скачайте `PostVPN-Reset-WiFi.ps1`
2. ПКМ по файлу → "Выполнить с PowerShell"
3. Или: PowerShell от администратора → `.\PostVPN-Reset-WiFi.ps1`

---

## 📋 Как это работает

```
[PRE] Checking network...
  ↓ Если сеть работает
[SAVE] Сохранение текущей конфигурации
  ↓ Если сеть НЕ работает
[1] DNS & IP Reset    ← DNS flush + IP renew + Google DNS
[2] Presets Restore   ← Восстановление из 50 сохранённых конфигов
[3] Aggressive Reset  ← Winsock + TCP/IP сброс
[OPTIMIZE]            ← TCP оптимизация для скорости
```

### Шаг 1: Безопасный сброс
- Отключение VPN адаптеров
- Перезапуск Wi-Fi адаптера
- `ipconfig /flushdns` — очистка DNS-кэша
- `ipconfig /release` + `/renew` — обновление IP
- Установка DNS 8.8.8.8 + 1.1.1.1
- Очистка proxy настроек

### Шаг 2: Восстановление из пресетов
- Последовательное применение сохранённых конфигураций
- Проверка сети после каждого пресета
- Автоматическое определение адаптера

### Шаг 3: Агрессивный сброс
- `netsh winsock reset`
- `netsh int ip reset`
- Финальный перезапуск адаптера

### Оптимизация после восстановления
- CTCP (Compound TCP) для высокого пинга
- TCP timestamps выключены
- Initial RTO 300ms
- RSS/DCA включены
- Dynamic ports 10000-65534
- Registry оптимизация (TTL, MaxUserPort, TcpTimedWaitDelay)

---

## 🎯 Возможности

| Функция | Описание |
|---------|----------|
| Универсальный адаптер | Работает на любом языке Windows |
| 50 снапшотов | Хранит последние 50 рабочих конфигураций |
| TCP оптимизация | Ускоряет интернет после восстановления |
| VPN protection | Автоматически отключает VPN адаптеры |
| Preset restore | Восстанавливает сеть из сохранённых настроек |
| Safe reset | Не затрагивает Bluetooth |

---

## ⚙️ Требования

- Windows 10/11
- PowerShell 5.1+
- Права администратора
- Wi-Fi адаптер

---

## ⚠️ Важно

- Скрипт **НЕ перезагружает** систему без необходимости
- Скрипт **НЕ отключает** Bluetooth устройства
- TCP оптимизация требует перезагрузки для полного эффекта
- Все настройки безопасны для Windows 10/11

---

## 🤝 Вклад

Форки и Pull Request'ы приветствуются!

---

## 📄 Лицензия

MIT License — используйте свободно!

---

## ⚠️ Дисклеймер

Скрипт выполняет операции с сетевыми настройками Windows. Автор не несёт ответственности за возможные проблемы. Всегда создавайте резервные копии важных данных.
