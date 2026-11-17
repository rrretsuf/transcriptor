# Screenshots of every screen, for a person to look at after a CI run.
#   pwsh ci/screens-windows.ps1 <transcriptor.exe> <output folder>
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Out)
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Shot([string]$Name, [double]$Wait = 1.5) {
    Start-Sleep -Seconds $Wait
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($screen.Left, $screen.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $Out "windows-$Name.png"))
    $graphics.Dispose()
    $bitmap.Dispose()
}

$env:TRANSCRIPTOR_DATA_DIR = New-Item -ItemType Directory (Join-Path $env:TEMP "transcriptor-screens-$PID")
Start-Process $Exe
Shot "onboarding" 8
Get-Process transcriptor | Stop-Process -Force
Start-Sleep 1

Set-Content (Join-Path $env:TRANSCRIPTOR_DATA_DIR "config.json") '{"onboarded": true}'
Copy-Item (Join-Path $PSScriptRoot "sample-history.json") (Join-Path $env:TRANSCRIPTOR_DATA_DIR "history.json")
Start-Process $Exe -ArgumentList "--show", "history"
Shot "history" 8
foreach ($view in "meeting", "file", "settings") {
    Start-Process $Exe -ArgumentList "--show", $view -Wait
    Shot $view
}
Start-Process $Exe -ArgumentList "--toggle" -Wait
Shot "pill" 1
Get-Process transcriptor | Stop-Process -Force
Get-ChildItem $Out
