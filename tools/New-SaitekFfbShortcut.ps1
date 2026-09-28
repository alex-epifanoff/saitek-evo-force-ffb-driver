#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param([Parameter(Mandatory=$true)][string]$DestinationPath,[string]$BridgeDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function New-SaitekBridgeShortcut {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([Parameter(Mandatory=$true)][string]$Path,[string]$Directory,[string]$LauncherPath=(Join-Path $PSScriptRoot 'Start-SaitekFfbBridge.ps1'))
    $full=[IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($full) -ine '.lnk') { throw 'Choose a shortcut filename ending in .lnk.' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($full))) { throw 'The destination folder must already exist.' }
    if (Test-Path -LiteralPath $full) { throw 'A file already exists at the shortcut destination; choose a new name.' }
    $launcher=[IO.Path]::GetFullPath($LauncherPath)
    if (-not [IO.File]::Exists($launcher)) { throw 'The Bridge launcher is missing from this package.' }
    foreach ($value in @($full,$launcher,$Directory)) {
        if ($value -match '["\r\n\x00]') { throw 'Shortcut paths contain an unsupported character.' }
    }
    if ($Directory) { $Directory=[IO.Path]::GetFullPath($Directory).TrimEnd('\')+'\.' }
    $arguments='-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "'+$launcher+'"'
    if ($Directory) { $arguments+=' -BridgeDirectory "'+$Directory+'"' }
    $powershell=Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($PSCmdlet.ShouldProcess($full,'Create Bridge launcher shortcut (does not launch Bridge)')) {
        $shell=$null; $shortcut=$null
        try {
            $shell=New-Object -ComObject WScript.Shell
            $shortcut=$shell.CreateShortcut($full)
            $shortcut.TargetPath=$powershell
            $shortcut.Arguments=$arguments
            $shortcut.WorkingDirectory=Split-Path -Parent $launcher
            $shortcut.Description='Saitek private alpha: verified Bridge launcher; Arm remains manual'
            $shortcut.Save()
        } finally {
            if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
            if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        }
        [pscustomobject]@{Status='Created';DestinationPath=$full}
    }
}
if ($MyInvocation.InvocationName -ne '.') { New-SaitekBridgeShortcut -Path $DestinationPath -Directory $BridgeDirectory -WhatIf:$WhatIfPreference }
