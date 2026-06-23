# Changelog

## v5.1 — 2026-06-23

Safety + polish pass: auto-rollback, locale-independent WiFi, cleaner code.

### Added
- **Post-optimization connectivity check + auto-rollback** — after every optimization run, waits 5s then tests internet. If broken, automatically calls `Invoke-Restore` to revert changes. User is never left without network.
- `Optimize-NetworkSpeed` now returns `$true`/`$false` (applied / rolled back) so callers can report the outcome.
- `Invoke-NetworkReset` and `Invoke-SmartMode` handle the new return value and show whether optimizations stuck or were rolled back.

### Changed
- WiFi reconnect: replaced broken `netsh wlan` (mojibake on non-English locales) with `Get-NetConnectionProfile` (CIM API, locale-independent). SSID saved to snapshot for reconnect after reset.
- `Check-Admin`: uses `throw` instead of `exit 1` (works correctly when dot-sourced or called from other scripts).
- `Save-Snapshot`: backs up existing snapshot instead of refusing (last run may have left unapplied changes).
- Profile cache TTL: 30d → 7d (laptops change networks frequently).
- `Invoke-Restore`: broken into readable per-step blocks instead of one monolithic block.
- Menu `[U]`: does not force-quit after undo — returns to menu so user can verify connectivity.

### Removed
- `Get-TcpValue` (dead code — never called, netsh mojibake on non-English).
- `AdapterTimeout` parameter (unused).

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
