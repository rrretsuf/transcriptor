# A plain text box in its own process: the "other app" that dictation pastes
# into. Whatever is in the box is mirrored to the file given as the argument.
param([Parameter(Mandatory)][string]$Out)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Native -Name Window -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr window);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
$form = New-Object Windows.Forms.Form
$form.Text = "Target"
$form.TopMost = $true
$box = New-Object Windows.Forms.TextBox
$box.Multiline = $true
$box.Dock = "Fill"
$form.Controls.Add($box)
$box.Add_TextChanged({ Set-Content -Path $Out -Value $box.Text -NoNewline })
$box.Add_KeyDown({ Add-Content -Path "$Out.keys" -Value "$($_.KeyData)" })
$form.Add_Shown({
    # Windows only lets a process take the foreground right after input; a tap on Alt counts.
    [Native.Window]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [Native.Window]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [Native.Window]::SetForegroundWindow($form.Handle) | Out-Null
    $form.Activate()
    $box.Focus()
    Set-Content -Path "$Out.ready" -Value "ready"
})
[Windows.Forms.Application]::Run($form)
