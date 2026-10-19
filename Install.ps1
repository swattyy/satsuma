# Installs Satsuma for the current user (no admin needed):
#   copies dist\Satsuma to %LOCALAPPDATA%\Programs\Satsuma, adds a Start menu shortcut, and starts it.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1            install / update and start
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Uninstall  remove it again
param([switch]$Uninstall, [switch]$NoStart)
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'Programs\Satsuma'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Satsuma.lnk'

Get-Process Satsuma -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

if ($Uninstall) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Satsuma' -ErrorAction SilentlyContinue
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Satsuma removed. (Settings are kept in %APPDATA%\Satsuma; delete that folder too if you like.)'
    return
}

$src = Join-Path $PSScriptRoot 'dist\Satsuma'
if (-not (Test-Path (Join-Path $src 'Satsuma.exe'))) {
    throw "No build found in $src. Build it first: dotnet publish src\Satsuma -c Release -r win-x64 --self-contained false -o dist\Satsuma"
}

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $src '*') $dest -Recurse -Force

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = Join-Path $dest 'Satsuma.exe'
$link.WorkingDirectory = $dest
$link.Description = 'Drag a file, tap Shift, drop.'
$link.Save()

# If "start when I sign in" was turned on from another copy, point it at the installed one.
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Get-ItemProperty -Path $run -Name 'Satsuma' -ErrorAction SilentlyContinue) {
    Set-ItemProperty -Path $run -Name 'Satsuma' -Value ('"' + (Join-Path $dest 'Satsuma.exe') + '" --background')
}

Write-Host "Installed to $dest"
if (-not $NoStart) { Start-Process (Join-Path $dest 'Satsuma.exe') }
