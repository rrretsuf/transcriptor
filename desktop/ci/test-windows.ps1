# Everything that can be checked on Windows without a person:
#   pwsh ci/test-windows.ps1 <transcriptor.exe>
# 1. the self-test: storage, hotkey registration, Credential Manager, overlay, TLS to Soniox
# 2. end to end: a text box in another process has the keyboard, the global
#    hotkey is pressed with real input events, and the text must arrive there.
param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference = "Stop"
$Exe = (Resolve-Path $Exe).Path

function Run-App([string]$Mode, [string]$DataDir, [int]$Seconds) {
    $env:TRANSCRIPTOR_DATA_DIR = $DataDir
    $app = Start-Process $Exe -ArgumentList $Mode -PassThru
    $null = $app.Handle # without the handle PowerShell cannot read the exit code later
    if (-not $app.WaitForExit($Seconds * 1000)) { $app.Kill(); throw "$Mode did not finish in $Seconds s" }
    Get-Content (Join-Path $DataDir "selftest.txt")
    return $app.ExitCode
}

Write-Host "== self-test"
$dir = New-Item -ItemType Directory (Join-Path $env:TEMP "transcriptor-selftest-$PID")
$lines = Run-App "--selftest" $dir 120
$lines[0..($lines.Count - 2)] | Write-Host
if ($lines[-1] -ne 0) { throw "self-test failed" }

Write-Host "== hotkey and paste into another app"
$dir = New-Item -ItemType Directory (Join-Path $env:TEMP "transcriptor-e2e-$PID")
$typed = Join-Path $dir "typed.txt"
$target = Start-Process powershell -PassThru -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "target.ps1"), $typed
for ($i = 0; $i -lt 100 -and -not (Test-Path "$typed.ready"); $i++) { Start-Sleep -Milliseconds 200 }
if (-not (Test-Path "$typed.ready")) { throw "the target window did not open" }

$env:TRANSCRIPTOR_DATA_DIR = $dir
$app = Start-Process $Exe -ArgumentList "--selftest-e2e" -PassThru
$null = $app.Handle
for ($i = 0; $i -lt 150 -and -not (Test-Path (Join-Path $dir "selftest-ready")); $i++) { Start-Sleep -Milliseconds 200 }
Start-Sleep -Milliseconds 500

Add-Type -Namespace Native -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr window, System.Text.StringBuilder text, int max);
'@
function Foreground {
    $title = New-Object System.Text.StringBuilder 256
    [Native.Keys]::GetWindowText([Native.Keys]::GetForegroundWindow(), $title, 256) | Out-Null
    $title.ToString()
}
if ((Foreground) -ne "Target") { throw "the target window does not have the keyboard, '$(Foreground)' has it" }

$control, $shift, $space, $up = 0x11, 0x10, 0x20, 2
foreach ($key in $control, $shift, $space) { [Native.Keys]::keybd_event($key, 0, 0, [UIntPtr]::Zero) }
foreach ($key in $space, $shift, $control) { [Native.Keys]::keybd_event($key, 0, $up, [UIntPtr]::Zero) }
Start-Sleep -Milliseconds 500
if ((Foreground) -ne "Target") { throw "the pill took the keyboard: '$(Foreground)' is in front" }

if (-not $app.WaitForExit(90000)) { $app.Kill(); throw "the end-to-end run did not finish" }
Start-Sleep -Milliseconds 800
Get-Content (Join-Path $dir "selftest.txt") | Write-Host
$text = if (Test-Path $typed) { Get-Content $typed -Raw } else { "" }
Write-Host "typed into the other app: $text"
Write-Host "keys the other app saw: $(if (Test-Path "$typed.keys") { (Get-Content "$typed.keys") -join ' | ' })"
Write-Host "clipboard: $(Get-Clipboard)   in front: $(Foreground)"
Stop-Process -Id $target.Id -Force
if ($app.ExitCode -ne 0) { throw "end-to-end self-test failed" }
if ($text -notmatch "Hello from Transcriptor") { throw "the text did not arrive in the other app" }
Write-Host "ok   hotkey -> pill -> paste into another app"
