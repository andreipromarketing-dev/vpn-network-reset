# Create Desktop Shortcut
$WshShell = New-Object -ComObject WScript.Shell
$Desktop = [Environment]::GetFolderPath("Desktop")
$Shortcut = $WshShell.CreateShortcut("$Desktop\Network Reset.lnk")
$Shortcut.TargetPath = "$PSScriptRoot\Reset-Network.bat"
$Shortcut.WorkingDirectory = $PSScriptRoot
$Shortcut.Description = "Reset network after VPN - no restart needed"
$Shortcut.IconLocation = "$env:SystemRoot\System32\shield.dll,0"
$Shortcut.Save()
Write-Host "Shortcut created: $Desktop\Network Reset.lnk"
Write-Host "Double-click to run the network reset script!"
