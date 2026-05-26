# Contributing

This is a personal utility script for a specific Windows 11 setup. Contributions are welcome if they improve reliability or safety.

## Guidelines

- No non-ASCII characters in `.ps1` files (PowerShell encoding compatibility)
- All user-facing messages in English (translit in menu is acceptable)
- Test all changes on a single-adapter WiFi system before submitting
- Preserve the admin check (`Check-Admin`) at script entry
- Keep the snapshot-first invariant: save state before any modification
- Do not reintroduce `netsh winsock reset` or `netsh int ip reset` in the automated flow
- Any change that stores a persistent value must have a corresponding restore path

## Code style

- PascalCase for functions and variables
- One-liner try/catch for simple error handling
- Prefer `Get-CimInstance` over `Get-WmiObject`
- `ConvertTo-Json -Depth 3` for nested structures
