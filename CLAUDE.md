# Network Smart Reset — project memory

## Stack
- PowerShell 5.1, Windows 11 Home, single Wi-Fi adapter
- No external dependencies (pure PS + netsh + reg)

## Entry point
`PostVPN-Reset-WiFi.ps1` — run as Admin. One shortcut on desktop, no flags needed.

## Key architecture decisions
- **Smart mode**: test internet → DOWN: full reset + optimize, UP: just optimize
- **ForceReset**: overrides smart mode, always resets
- **Adaptive optimization**: CPU/RAM/WiFi-eth/LinkSpeed/RTT/battery detected once, cached to `network-profile.json`
- **Snapshot first**: before ANY modification, saves registry + netsh + ports + DNS to `reset-snapshot.json` (atomic .tmp → rename)
- **Restore**: `-Restore` flag or menu [R] reverts all changes from snapshot
- **Interactive menu**: after auto-action, menu stays open until user quits
- **No winsock/ip reset**: requires reboot, removed from automated flow. Use `netsh int ip delete destinationcache` instead
- **No DNS hardcoding**: `/renew` restores DHCP DNS automatically. Removed `Set-DnsClientServerAddress`
- **Targeted ipconfig**: `/release` and `/renew` use adapter name, not blanket (protects Bluetooth PAN)
- **Bluetooth safe**: excluded from VPN disable and adapter detection
- **WiFi auto-connect**: uses last saved profile, not first alphabetical

## File structure
```
PostVPN-Reset-WiFi.ps1     # main script (507 lines)
Reset-Network.bat           # launch shortcut (no args)
Reset-Network-Smart.bat     # legacy alias
Create-Shortcut.ps1         # creates desktop shortcuts
network-profile.json        # auto-generated system profile cache
reset-snapshot.json         # auto-generated pre-modification state
reset.log                   # activity log (rotated at 1MB)
```

## Key functions
| Function | Role |
|----------|------|
| `Get-SystemProfile` | Detect HW, cache to JSON, compute TCP settings |
| `Compute-OptimizationSettings` | Pure logic: profile → InitialRto/Timestamps/DCA/PortRange/etc |
| `Save-Snapshot` | Atomic save of registry + netsh + ports + DNS |
| `Invoke-Restore` | Read snapshot, revert all in reverse order |
| `Optimize-NetworkSpeed` | Reads computed settings instead of hardcoded values |
| `Invoke-NetworkReset` | Full reset flow: disable VPNs → IP renew → flush → optimize |
| `Invoke-SmartMode` | Auto-detect: reset path or optimize-only path |

## CLI flags
- `-ForceReset` — force full reset even if internet works
- `-Restore` — revert all changes from last snapshot

## Safety invariants
- Snapshot always taken before first modification
- Snapshot never overwritten without user consent (escape hatch prompt)
- Restore never re-enables VPN adapters (user-managed)
- Registry keys deleted on restore if they didn't exist before (not set to 0)
- Auto-tuning level set based on RAM (restricted < 8GB, normal >= 8GB)
- DCA attempt non-fatal (server feature, not on WiFi)
- CTCP default: `ctcp` (Compound TCP)
- Win11 default port range: start=49152 num=16384

## Detected parameters → computed settings
| Detected | Rule |
|----------|------|
| CPU cores | RSS = min(cores, 4); halve on battery |
| RAM | autotuning = restricted if <8GB, normal if >=8GB |
| WiFi (type 71) | timestamps disabled |
| LinkSpeed < 100mbps OR RTT > 50ms | initialRto = 500 (else 300) |
| RTT > 50ms | TcpTimedWaitDelay = 60 (else 30) |
| On battery | DCA skipped, RSS halved |
| Defaults | PortRange 10000-55534, MaxUserPort 65534 |

## Version history
- v3.x: interactive menu, presets, proxy, snapshot history (removed)
- v4.0: smart mode, no menu, single -ForceReset flag
- v4.1: targeted ipconfig, no winsock/ip reset, no hardcoded DNS, per-step try/catch
- v5.0: adaptive optimization, snapshot+restore, interactive menu, single entry point
