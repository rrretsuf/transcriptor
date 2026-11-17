# The installer itself: install for this user without admin rights, run the
# installed app, uninstall, and the data folder must still be there.
#   pwsh ci/installed-windows.ps1 <setup.exe>
param([Parameter(Mandatory)][string]$Setup)
$ErrorActionPreference = "Stop"
$installed = Join-Path $env:LOCALAPPDATA "Transcriptor"
$data = Join-Path $env:APPDATA "Transcriptor"
Remove-Item Env:TRANSCRIPTOR_DATA_DIR -ErrorAction SilentlyContinue

Start-Process (Resolve-Path $Setup).Path -ArgumentList "/S" -Wait
$exe = Join-Path $installed "transcriptor.exe"
if (-not (Test-Path $exe)) { throw "not installed at $exe" }

$app = Start-Process $exe -ArgumentList "--selftest" -PassThru
$null = $app.Handle
if (-not $app.WaitForExit(120000)) { $app.Kill(); throw "the installed app did not finish its self-test" }
Get-Content (Join-Path $data "selftest.txt") | Write-Host
if ($app.ExitCode -ne 0) { throw "the installed app failed its self-test" }

Start-Process (Join-Path $installed "uninstall.exe") -ArgumentList "/S" -Wait
for ($i = 0; $i -lt 50 -and (Test-Path $exe); $i++) { Start-Sleep -Milliseconds 200 }
if (Test-Path $exe) { throw "still installed after uninstall" }
if (-not (Test-Path (Join-Path $data "config.json"))) { throw "uninstall removed the data folder" }
Write-Host "ok   installed without admin, ran, uninstalled; $data is still there"
