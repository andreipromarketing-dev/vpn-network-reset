$WshShell = New-Object -ComObject WScript.Shell
$Desktop = [Environment]::GetFolderPath("Desktop")

$s1 = $WshShell.CreateShortcut("$Desktop\Network Reset (Force).lnk")
$s1.TargetPath = "$PSScriptRoot\Reset-Network.bat"
$s1.WorkingDirectory = $PSScriptRoot
$s1.Description = "Force reset adapter + optimize"
$s1.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$s1.Save()

$s2 = $WshShell.CreateShortcut("$Desktop\Network Reset (Smart).lnk")
$s2.TargetPath = "$PSScriptRoot\Reset-Network-Smart.bat"
$s2.WorkingDirectory = $PSScriptRoot
$s2.Description = "Auto: reset if down, optimize if OK"
$s2.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
$s2.Save()

Write-Host "Shortcuts created:"
Write-Host "  $Desktop\Network Reset (Force).lnk"
Write-Host "  $Desktop\Network Reset (Smart).lnk"
Write-Host "Run Create-Shortcut.ps1 to re-create."