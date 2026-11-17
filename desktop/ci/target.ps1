# A plain text box in its own process: the "other app" that dictation pastes
# into. Whatever is in the box is mirrored to the file given as the argument.
param([Parameter(Mandatory)][string]$Out)
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = "Target"
$form.TopMost = $true
$box = New-Object Windows.Forms.TextBox
$box.Multiline = $true
$box.Dock = "Fill"
$form.Controls.Add($box)
$box.Add_TextChanged({ Set-Content -Path $Out -Value $box.Text -NoNewline })
$form.Add_Shown({
    $form.Activate()
    $box.Focus()
    Set-Content -Path "$Out.ready" -Value "ready"
})
[Windows.Forms.Application]::Run($form)
