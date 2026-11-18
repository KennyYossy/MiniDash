# MiniDash: register auto-start for this folder and launch it
$dir   = $PSScriptRoot
$ps1   = Join-Path $dir 'MiniDash.ps1'
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$args_ = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""

$sh  = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'MiniDash.lnk'))
$lnk.TargetPath = $psExe
$lnk.Arguments = $args_
$lnk.WorkingDirectory = $dir
$lnk.WindowStyle = 7
$lnk.IconLocation = (Join-Path $env:WINDIR 'System32\taskmgr.exe') + ',0'
$lnk.Save()
Write-Host "Auto-start registered: $ps1"

Start-Process -FilePath $psExe -ArgumentList $args_ -WorkingDirectory $dir -WindowStyle Hidden
Write-Host 'MiniDash started.'
