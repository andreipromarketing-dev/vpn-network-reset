$ScriptPath = Join-Path $PSScriptRoot "Save-NetworkSnapshot.ps1"
$TaskName = "NetworkSnapshotMonitor"
$TriggerTime = "09:00"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Task '$TaskName' already exists. Removing..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
$trigger = New-ScheduledTaskTrigger -Daily -At $TriggerTime
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Auto-save network snapshot when parameters change" | Out-Null

Write-Host "Scheduled task created: '$TaskName'" -ForegroundColor Green
Write-Host "Runs daily at $TriggerTime"
Write-Host ""
Write-Host "To run manually: .\Save-NetworkSnapshot.ps1"
