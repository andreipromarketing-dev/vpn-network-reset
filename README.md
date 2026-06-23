# Network Smart Reset

PowerShell script for Windows 11 that auto-detects network state after VPN disconnect and restores connectivity.

## How it works

Run the script (as Administrator). It detects your system hardware once, caches it, then:

- **Internet DOWN** — full IP renew + route cache clear + TCP optimization
- **Internet UP** — just runs TCP optimization

After auto-action, an interactive menu stays open for manual control.

### Safety: auto-rollback

After every optimization run, the script waits 5 seconds and tests internet connectivity. If the optimization broke your connection, it automatically reverts all changes — you are never left without network.

## Usage

### Desktop (one shortcut)

Just run the script. No flags needed.

```
PostVPN-Reset-WiFi.ps1
```

### CLI options

| Flag | Action |
|------|--------|
| `-ForceReset` | Force full reset even if internet is working |
| `-Restore` | Revert all changes from last snapshot |

### Interactive menu

After auto-detect and auto-action:

```
  [S] Show current TCP settings and optimization plan
  [O] Optimize only (safe, no adapter reset)
  [R] Full reset + optimize (drops connection briefly)
  [U] Undo all changes (restore snapshot)
  [Q] Quit
```

## What it does

### Network reset
1. Disables VPN adapters (by name patterns)
2. Releases/renews IP on the active adapter only
3. Flushes DNS and clears stale routes (`netsh int ip delete destinationcache`)
4. Verifies connectivity (up to 3 retries)

### Adaptive TCP optimization

Detects once, caches to `network-profile.json`:

| Detected | Affects |
|----------|---------|
| CPU cores | RSS processor count |
| RAM | TCP auto-tuning level |
| WiFi vs Ethernet | TCP timestamps |
| Link speed | Initial RTO |
| Gateway latency | Initial RTO, TcpTimedWaitDelay |
| Battery status | RSS count, DCA |

### Snapshot + Restore

Before any modification, saves current state to `reset-snapshot.json`:
- Registry keys (MaxUserPort, TcpTimedWaitDelay)
- netsh TCP globals (CTCP, timestamps, RSS, initialRTO, autotuning)
- Dynamic port ranges (IPv4 + IPv6)
- DNS server addresses
- Current WiFi SSID (for reconnect after reset)

If a snapshot already exists from a previous run, it is backed up with a timestamp instead of being discarded.

Use `-Restore` or menu option `[U]` to undo all changes.

## Files

| File | Purpose |
|------|---------|
| `PostVPN-Reset-WiFi.ps1` | Main script |
| `Reset-Network.bat` | Launch shortcut (no args) |
| `Reset-Network-Smart.bat` | Legacy alias (same as above) |
| `Create-Shortcut.ps1` | Creates desktop shortcuts |
| `network-profile.json` | Cached system profile (auto-generated) |
| `reset-snapshot.json` | Pre-modification state snapshot (auto-generated) |
| `reset.log` | Activity log |

## Requirements

- Windows 11 (or 10 with admin rights)
- PowerShell 5.1+
- Run as Administrator
