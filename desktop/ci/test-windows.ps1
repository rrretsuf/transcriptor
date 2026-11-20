# Everything that can be checked on Windows without a person:
#   pwsh ci/test-windows.ps1 <transcriptor.exe>
# 1. the self-test: storage, hotkey registration, Credential Manager, overlay, TLS to Soniox
# 2. end to end: a text box in another process has the keyboard, the global
#    hotkey is pressed with real input events, and the text must arrive there.
# On a machine with a sound card whose microphone hears what the speakers play
# (CI installs the VB-CABLE virtual one), a sound plays and the test also covers
# the microphone, the loopback, a dictation and a meeting against a stand-in for Soniox.
param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference = "Stop"
$Exe = (Resolve-Path $Exe).Path

Add-Type -Namespace Native -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr window, System.Text.StringBuilder text, int max);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.UIntPtr extra);
'@
function Foreground {
    $title = New-Object System.Text.StringBuilder 256
    [Native.Keys]::GetWindowText([Native.Keys]::GetForegroundWindow(), $title, 256) | Out-Null
    $title.ToString()
}
function Press-Hotkey {
    $control, $shift, $space, $up = 0x11, 0x10, 0x20, 2
    foreach ($key in $control, $shift, $space) { [Native.Keys]::keybd_event($key, 0, 0, [UIntPtr]::Zero) }
    foreach ($key in $space, $shift, $control) { [Native.Keys]::keybd_event($key, 0, $up, [UIntPtr]::Zero) }
}
function Wait-For([string]$File, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds * 5 -and -not (Test-Path $File); $i++) { Start-Sleep -Milliseconds 200 }
    if (-not (Test-Path $File)) { throw "$File did not appear in $Seconds s" }
}
function New-DataDir([string]$Name) {
    $env:TRANSCRIPTOR_DATA_DIR = New-Item -ItemType Directory (Join-Path $env:TEMP "transcriptor-$Name-$PID")
    $env:TRANSCRIPTOR_DATA_DIR
}
function Start-App([string]$Mode) {
    $app = Start-Process $Exe -ArgumentList $Mode -PassThru
    $null = $app.Handle # without the handle PowerShell cannot read the exit code later
    $app
}
function Self-Test([string]$Name) {
    $dir = New-DataDir $Name
    $app = Start-App "--selftest"
    if (-not $app.WaitForExit(120000)) { $app.Kill(); throw "the self-test did not finish" }
    $report = Get-Content (Join-Path $dir "selftest.txt")
    $report | Write-Host
    if ($app.ExitCode -ne 0) { throw "self-test failed" }
    $report
}

# The hotkey is pressed while another app's text box has the keyboard. With
# $Dictation the text is spoken (a sound is playing) and a meeting follows.
function End-To-End([bool]$Dictation, [string]$Expect) {
    $dir = New-DataDir "e2e-$Dictation"
    $typed = Join-Path $dir "typed.txt"
    $target = Start-Process powershell -PassThru -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "target.ps1"), $typed
    Wait-For "$typed.ready" 20
    $app = Start-App "--selftest-e2e"
    Wait-For (Join-Path $dir "selftest-ready") 30
    Start-Sleep -Milliseconds 500
    if ((Foreground) -ne "Target") { throw "the target window does not have the keyboard, '$(Foreground)' has it" }

    # The meeting banner's Dismiss is clicked; the other app must keep the keyboard.
    Wait-For (Join-Path $dir "selftest-banner") 20
    $x, $y = (Get-Content (Join-Path $dir "selftest-banner")).Split(" ")
    [Native.Keys]::SetCursorPos([int]$x, [int]$y) | Out-Null
    [Native.Keys]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [Native.Keys]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 500
    $bannerFront = Foreground
    Set-Content (Join-Path $dir "selftest-banner-clicked") "clicked"
    Start-Sleep -Seconds 1
    Write-Host "in front after the banner click: '$bannerFront', then '$(Foreground)'"

    Press-Hotkey
    Start-Sleep -Milliseconds 500
    if ((Foreground) -ne "Target") { throw "the pill took the keyboard: '$(Foreground)' is in front" }
    if ($Dictation) {
        Start-Sleep -Seconds 4
        Press-Hotkey
        Wait-For (Join-Path $dir "selftest-meeting") 60
        Start-Sleep -Seconds 4
        Set-Content (Join-Path $dir "selftest-meeting-played") "played"
    }
    if (-not $app.WaitForExit(120000)) { $app.Kill(); throw "the end-to-end run did not finish" }
    Start-Sleep -Milliseconds 800

    Get-Content (Join-Path $dir "selftest.txt") | Write-Host
    $text = if (Test-Path $typed) { Get-Content $typed -Raw } else { "" }
    Write-Host "typed into the other app: $text"
    if ($text -notmatch $Expect) {
        Write-Host "keys the other app saw: $(if (Test-Path "$typed.keys") { (Get-Content "$typed.keys") -join ' | ' })"
        Write-Host "clipboard: $(Get-Clipboard)   in front: $(Foreground)"
    }
    Stop-Process -Id $target.Id -Force
    if ($bannerFront -ne "Target") { throw "the meeting banner took the keyboard: '$bannerFront' was in front" }
    if ($app.ExitCode -ne 0) { throw "end-to-end self-test failed" }
    if ($text -notmatch $Expect) { throw "the text did not arrive in the other app" }
    Write-Host "ok   hotkey -> pill -> paste into another app"
}

Write-Host "== self-test"
$report = Self-Test "selftest"

Write-Host "== hotkey and paste into another app"
End-To-End $false "Hello from Transcriptor"

if ($report -match "input=None|output=None") {
    Write-Host "== no sound card on this machine: microphone, loopback, dictation and meeting are not tested"
    exit 0
}

# This part depends on a virtual sound card that CI installs. When it does not
# work there, that says nothing about the app: the run stays green and the log
# says NOT VERIFIED in capitals.
$player = $null
try {
    # A steady tone: the system sounds have quiet moments, and a quiet moment reads as "not heard".
    $tone = Join-Path $env:TEMP "transcriptor-tone-$PID.wav"
    $rate = 16000
    $samples = $rate * 2
    $writer = New-Object System.IO.BinaryWriter ([System.IO.File]::Create($tone))
    $writer.Write([char[]]"RIFF"); $writer.Write([int](36 + $samples * 2)); $writer.Write([char[]]"WAVEfmt ")
    $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]$rate)
    $writer.Write([int]($rate * 2)); $writer.Write([int16]2); $writer.Write([int16]16)
    $writer.Write([char[]]"data"); $writer.Write([int]($samples * 2))
    for ($i = 0; $i -lt $samples; $i++) { $writer.Write([int16](12000 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate))) }
    $writer.Close()
    $player = New-Object System.Media.SoundPlayer $tone
    $player.PlayLooping()
    Start-Sleep -Seconds 1

    Write-Host "== self-test with a tone playing: the microphone and the loopback must hear it"
    $env:TRANSCRIPTOR_EXPECT_AUDIO = "mic,loopback"
    Self-Test "sound" | Out-Null
    Remove-Item Env:TRANSCRIPTOR_EXPECT_AUDIO

    Write-Host "== dictation and meeting, against a stand-in for Soniox"
    $mock = Start-Process python -PassThru -WindowStyle Hidden -ArgumentList (Join-Path $PSScriptRoot "mock-soniox.py"), "8765"
    Start-Sleep -Seconds 2
    $env:SONIOX_API_KEY = "mock"
    $env:TRANSCRIPTOR_SONIOX_URL = "ws://127.0.0.1:8765"
    End-To-End $true "heard"
    Stop-Process -Id $mock.Id -Force
    Write-Host "ok   VERIFIED WITH A VIRTUAL SOUND CARD: microphone, loopback, dictation, meeting"
} catch {
    Write-Host "NOT VERIFIED ON THIS MACHINE: microphone, loopback, dictation and meeting ($_)"
} finally {
    if ($player) { $player.Stop() }
}
