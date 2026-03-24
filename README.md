# 🔄 VPN Network Reset

Автоматический сброс сети после VPN (ChatVPN и др.) без перезагрузки компьютера.

[![Stars](https://img.shields.io/github/stars/andreipromarketing-dev/vpn-network-reset?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/stargazers)
[![Forks](https://img.shields.io/github/forks/andreipromarketing-dev/vpn-network-reset?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/network/members)
[![Watchers](https://img.shields.io/github/watchers/andreipromarketing-dev/vpn-network-reset?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/watchers)
[![Download](https://img.shields.io/badge/Download-v1.1.0-blue?style=flat-square)](https://github.com/andreipromarketing-dev/vpn-network-reset/releases/tag/v1.1.0)

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue?style=flat-square)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10/11-green?style=flat-square)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)

---

## 📖 Описание

После использования VPN (особенно ChatVPN) Windows часто показывает "DNS-сервер недоступен" и не предлагает решений.

Этот скрипт безопасно:
1. Очищает DNS-кэш
2. Переподключает Wi-Fi адаптер
3. Устанавливает стабильные DNS серверы
4. **Не затрагивает Bluetooth** (защита от отключения мышек/наушников)

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
[1] Safe DNS & IP Reset     ← DNS flush + IP renew
   ↓ Если не помогло
[2] Adapter Reset           ← Disable/Enable Wi-Fi only
   ↓ Если не помогло
[FAILED]                    ← Рекомендации пользователю
```

### Шаг 1: Безопасный сброс
- `ipconfig /flushdns` — очистка DNS-кэша
- `ipconfig /release` + `/renew` — обновление IP
- Установка DNS 8.8.8.8 + 1.1.1.1
- Очистка ARP-кэша

### Шаг 2: Сброс адаптера
- Отключение Wi-Fi адаптера
- Включение Wi-Fi адаптера
- Перенастройка DNS

---

## 🎯 Для чего это нужно

| Проблема | Решение |
|----------|---------|
| DNS-сервер недоступен после VPN | Автоматический сброс DNS |
| VPN "ломает" интернет | Безопасное переподключение |
| Не хочется перезагружать ПК | Работает без перезагрузки |
| Bluetooth отключается при сбросе | Защита от этого ✓ |

---

## ⚙️ Требования

- Windows 10/11
- PowerShell 5.1+
- Права администратора
- Wi-Fi адаптер

---

## ⚠️ Важно

- Скрипт **НЕ перезапускает системные службы** массово
- Скрипт **НЕ отключает все адаптеры** — только Wi-Fi
- Скрипт **НЕ затрагивает Bluetooth** устройства
- Адаптеры Bluetooth часто совмещены с Wi-Fi на ноутбуках

---

## 🤝 Вклад

Форки и Pull Request'ы приветствуются!

---

## 📄 Лицензия

MIT License — используйте свободно!

---

## ⚠️ Дисклеймер

Скрипт выполняет операции с сетевыми настройками Windows. Автор не несёт ответственности за возможные проблемы. Всегда создавайте резервные копии важных данных.
