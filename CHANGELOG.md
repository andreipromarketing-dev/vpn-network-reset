# Changelog VPN Network Reset

All notable changes to this project will be documented in this file.

---

## [3.1] - 2026-04-07

### Added
- **Network Scanning** - Scan active network connections and show applications with their remote IPs
- **App Preferences System** - Configure which apps go through VPN or direct connection
- **VPN Status Detection** - Check both adapter status AND running process for accurate VPN detection
- **Russian Transliterated UI** - English-friendly transliterated menu (avoids Cyrillic encoding issues)
- **Gateway-based Network Test** - Before reset, checks gateway first - if reachable, skips reset and only optimizes

### Fixed
- Fixed JSON parsing for preferences (was using .PSObject.Properties incorrectly)
- Fixed duplicate function definitions that caused syntax errors
- Fixed column alignment in network apps table

### Optimization
- Network test now pings gateway first before external DNS
- If network is working, only optimization runs (no reset)
- Maintains history of 50 network snapshots

---

## [3.0] - 2026-04-06

### Added
- TCP optimization (CTCP, timestamps, RTO, RSS/DCA, dynamic ports)
- Registry optimizations (TTL, MaxUserPort, TcpTimedWaitDelay)
- Auto-cleanup of old snapshots (keeps last 50)

### Fixed
- Network detection reliability
- Multiple reset steps for better recovery

---

## [2.x] - Earlier versions

- Basic network reset functionality
- Snapshot system
- VPN adapter detection