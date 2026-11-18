# MiniDash: stop it and remove auto-start
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'MiniDash.lnk'
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host 'Auto-start removed.' } else { Write-Host 'Auto-start was not registered.' }

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*MiniDash.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped MiniDash (pid $($_.ProcessId))." }

$cfg = Join-Path $env:APPDATA 'MiniDash'
if (Test-Path $cfg) { Remove-Item $cfg -Recurse -Force; Write-Host 'Settings removed.' }
Write-Host 'Done. You can delete this folder now.'
