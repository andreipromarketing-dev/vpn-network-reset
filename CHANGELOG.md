# Changelog

## v5.0 — 2026-05-27

Major rewrite: adaptive optimization, snapshot/restore, interactive menu.

### Added
- Adaptive TCP optimization: detects CPU, RAM, WiFi/Ethernet, LinkSpeed, RTT, battery → computes optimal values (no hardcode)
- System profile detection, cached to `network-profile.json` (stale check: 30 days / adapter change / speed delta >50%)
- Snapshot + Restore: saves registry, netsh, port range, DNS state to `reset-snapshot.json` before any modification
- `-Restore` flag reverts all changes from snapshot
- Interactive menu after auto-action: Force reset, Re-optimize, Restore, Quit
- Reset-snapshot escape hatch: prompts user on relaunch if snapshot exists from crashed run
- TCP auto-tuning level set based on RAM
- Russian translit in menu prompts

### Changed
- `Save-Snapshot` moved to script start (before any action, not just before optimize)
- One-entry-point UX: single shortcut, menu handles everything
- Atomic snapshot write (`.tmp` → rename) to prevent corruption on power loss

### Removed
- Separate desktop shortcuts for each mode (single entry point now)

## v4.1 — 2026-05-27

Safety fixes based on Claude code review.

### Fixed
- `ipconfig /release` now targets specific adapter name (was releasing all adapters, including Bluetooth PAN)
- Bluetooth exclusion added to `Disable-AllVPNAdapters` (belt and suspenders)
- Removed `netsh winsock reset` and `netsh int ip reset` (require reboot, pointless in automated flow)
- Replaced with `netsh int ip delete destinationcache` (clears stale VPN routes, no reboot)
- Removed hardcoded DNS override (`Set-DnsClientServerAddress`) — `/renew` restores DHCP DNS
- WiFi auto-connect now picks last saved profile, not first alphabetical
- `Optimize-NetworkSpeed` broken into per-step try/catch (was one monolithic block)
- DCA verification relaxed: warning instead of throw (DCA is server-only feature)

## v4.0 — 2026-05-27

Complete rewrite: smart auto-detect, no interactive menu.

### Added
- Smart mode: detects internet DOWN → full reset; UP → optimize only
- `-ForceReset` flag to force reset when internet is already working
- Admin check at script entry
- Improved adapter detection with fallback chain
- Log rotation at 1MB

### Removed
- Interactive menu (script runs once, shows result, waits for Enter, exits)
- All snapshot/preset/proxy/menu functions
- `-Auto`, `-NoMenu`, `-Optimize` parameters (superseded by smart mode)

## v3.x — earlier

Interactive menu version with manual mode selection, presets, proxy config, and snapshot history.
