# Windows installer: stages dist\win-x64 (the app next to the project files)
# and builds dist\nes2msxtr-<version>-win-x64-setup.exe with Inno Setup 6.
# Needs the .NET 8 SDK, Python 3 and Inno Setup (winget install JRSoftware.InnoSetup).
# usage: powershell -ExecutionPolicy Bypass -File installer\windows.ps1 [version]
param([string]$Version = "1.3")
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$stage = "dist\win-x64"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }

dotnet publish app/Nes2MsxTr.App -c Release -r win-x64 -o $stage
if ($LASTEXITCODE) { exit $LASTEXITCODE }
python tools/package_tool.py --dir $stage
if ($LASTEXITCODE) { exit $LASTEXITCODE }

$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
              "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
              "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "Inno Setup 6 not found: winget install JRSoftware.InnoSetup" }
& $iscc "/DVersion=$Version" installer\nes2msxtr.iss
exit $LASTEXITCODE
