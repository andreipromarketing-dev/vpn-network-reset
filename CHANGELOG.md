# Changelog VPN Network Reset

All notable changes to this project will be documented in this file.

---

## [3.2] - 2026-04-09

### Added
- **Manual Route Mode** - Apply collected IPs with TCP port check (80, 443, 8080, 5222, 4433)
- **Automatic Route Mode** - Background monitoring with auto-cleanup of unresponsive IPs (after 3 failures)
- **Network Speed Test** - Shows download speed and ping when scanning network [1]
- **Optimize Button [7]** - Manual network optimization without full reset
- **Clean Routes Button [8]** - Full cleanup of all collected IP routes
- **Exit Cleanup** - Automatic route cleanup on script exit (including Ctrl+C)
- **IP-based Proxy System** - Collect IPs from active VPN → apply as direct routes for selected apps

### Fixed
- TCP port check replaced ICMP ping (more reliable for web servers behind firewalls)
- Clean-RoutesOnExit now deletes only IPs from collected files (not all /32 routes)
- Clean-AllProxyRoutes removes persistent routes that survive reboot
- Menu items re-ordered with numbers (1-8 instead of letters)
- Version updated to v3.2 in menu

### Optimization
- Auto mode checks every 15 seconds
- Removes unresponsive IPs after 3 consecutive failures
- Persistent routes (-p) survive reboot but cleaned on script exit or [8]

### Known Limitations
- IP routes only work for non-blocked services (ISP DPI can block direct IPs)
- Telegram servers are blocked in Russia - need VPN for Telegram
- Telegram internal MTProto proxy adds its own persistent routes
- Use [8] Clean Routes before enabling VPN to clear conflicts
- DIRECT routes may not work when ChatVPN is active (tun2socks intercepts at lower level)
- Works best: VPN active → collect IPs → disable VPN → apply routes → use apps without VPN

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