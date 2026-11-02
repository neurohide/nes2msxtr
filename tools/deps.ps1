# usage: tools\deps.ps1 [-Check] [-Distro Ubuntu]
# Windows: nes2msxtr builds with make and shell scripts, so it runs in WSL
# (Windows Subsystem for Linux). This script installs WSL with Ubuntu when no
# Linux distribution is there yet, then runs tools/deps.sh inside it, which
# installs python3, make, z80asm, cc65 and openMSX with apt and checks the
# FS-A1GT system ROMs (copy your own dumps into ~/.openMSX/share/systemroms/
# in WSL). openMSX opens its window through WSLg (Windows 11, or Windows 10
# with a recent WSL). -Check only reports what is missing.
# If scripts are blocked, run tools\deps.cmd instead.
param(
    [switch]$Check,
    [string]$Distro = ""
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "missing  WSL: needs Windows 10 version 2004 or later, or Windows 11"
    exit 1
}

# wsl.exe lists distributions in UTF-16
$enc = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::Unicode
$distros = @(wsl.exe --list --quiet 2>$null | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
[Console]::OutputEncoding = $enc

if ($Distro -ne "" -and $distros -notcontains $Distro) { $distros = @() }
if ($distros.Count -eq 0) {
    $name = if ($Distro -ne "") { $Distro } else { "Ubuntu" }
    Write-Host "missing  WSL distribution $name"
    if ($Check) { exit 1 }
    Write-Host "installing WSL with $name (administrator rights; Windows may ask to restart)"
    Start-Process wsl.exe -ArgumentList "--install", "-d", $name -Verb RunAs -Wait
    Write-Host "Finish the $name setup (it asks for a user name and password),"
    Write-Host "restart Windows if asked, then run tools\deps.ps1 again."
    exit 1
}
Write-Host "found    WSL distribution $(if ($Distro -ne '') { $Distro } else { $distros[0] + ' (default)' })"

$wslArgs = @()
if ($Distro -ne "") { $wslArgs += "-d", $Distro }
$wslArgs += "--cd", $Root, "--", "sh", "tools/deps.sh"
if ($Check) { $wslArgs += "--check" }
& wsl.exe @wslArgs
$status = $LASTEXITCODE
if ($status -eq 0) {
    Write-Host ""
    Write-Host "Build and play from a WSL shell in this folder, for example:"
    Write-Host "  wsl --cd `"$Root`" make ROM=mygame"
}
exit $status
