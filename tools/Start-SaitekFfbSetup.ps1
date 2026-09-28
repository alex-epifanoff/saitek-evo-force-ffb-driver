#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('Menu','Check','Install','Restore','Support','Shortcut','Exit')][string]$Action='Menu',
    [string]$BridgeDirectory,[string]$OutputPath,[string]$ShortcutPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-SaitekSetupScript([string]$ScriptPath,[hashtable]$Parameters) {
    if (-not [IO.File]::Exists($ScriptPath)) { throw 'A required package tool is missing. Extract the complete package again.' }
    $global:LASTEXITCODE=0
    & $ScriptPath @Parameters
    if ($global:LASTEXITCODE -ne 0) { throw ('The selected tool failed (exit code '+$global:LASTEXITCODE+'). Review the error above; no success is assumed.') }
}
function Invoke-SaitekSetupAction {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([ValidateSet('Check','Install','Restore','Support','Shortcut','Exit')][string]$Selected='Check',
        [string]$Directory,[string]$ReportPath,[string]$LinkPath,[string]$ToolsRoot=$PSScriptRoot)
    $package=Split-Path -Parent $ToolsRoot
    switch ($Selected) {
        Check {
            Write-Host 'Passive check: hardware and forces are not checked. No installation or Bridge launch occurs.'
            Invoke-SaitekSetupScript (Join-Path $ToolsRoot 'Get-SaitekFfbSupport.ps1') @{BridgeDirectory=$Directory}
        }
        Support {
            Invoke-SaitekSetupScript (Join-Path $ToolsRoot 'Get-SaitekFfbSupport.ps1') @{BridgeDirectory=$Directory;OutputPath=$ReportPath;WhatIf=[bool]$WhatIfPreference}
        }
        Install {
            $manifest=Join-Path $package 'release-manifest.json'
            if (-not [IO.File]::Exists($manifest)) { throw 'No release-manifest.json found. Use the complete extracted binary package; source checkout builds are documented separately.' }
            Invoke-SaitekSetupScript (Join-Path $ToolsRoot 'Install-SaitekFfbDriver.ps1') @{Mode='Apply';ReleaseManifest=$manifest;WhatIf=[bool]$WhatIfPreference}
        }
        Restore {
            Invoke-SaitekSetupScript (Join-Path $ToolsRoot 'Install-SaitekFfbDriver.ps1') @{Mode='Restore';WhatIf=[bool]$WhatIfPreference}
        }
        Shortcut {
            if (-not $LinkPath) { throw 'Choose an explicit shortcut destination first.' }
            Invoke-SaitekSetupScript (Join-Path $ToolsRoot 'New-SaitekFfbShortcut.ps1') @{DestinationPath=$LinkPath;BridgeDirectory=$Directory;WhatIf=[bool]$WhatIfPreference}
        }
        Exit { return }
    }
}
function Start-SaitekSetupMenu([string]$Directory) {
    Write-Host 'Saitek Cyborg Evo Force - experimental unsigned alpha'
    Write-Host 'Exact device 06A3:FFB5, x64 only. Read README.md before installation.'
    do {
        Write-Host ''
        Write-Host '[1] Check (default, passive)   [2] Install   [3] Restore'
        Write-Host '[4] Support report   [5] Create Bridge shortcut   [0] Exit'
        $choice=Read-Host 'Choose an action; Enter checks only'
        try {
            switch ($choice) {
                {$_ -in @('','1')} { Invoke-SaitekSetupAction -Selected Check -Directory $Directory }
                '2' {
                    Write-Host 'Close Bridge (including tray), X-Plane and diagnostic apps. Preview follows.'
                    Invoke-SaitekSetupAction -Selected Install -WhatIf
                    if ((Read-Host 'Type INSTALL to apply this per-user driver registration, or Enter to cancel') -ceq 'INSTALL') {
                        Invoke-SaitekSetupAction -Selected Install
                    }
                }
                '3' {
                    Write-Host 'Close Bridge (including tray), X-Plane and diagnostic apps. Preview follows.'
                    Invoke-SaitekSetupAction -Selected Restore -WhatIf
                    if ((Read-Host 'Type RESTORE to restore the saved per-user state, or Enter to cancel') -ceq 'RESTORE') {
                        Invoke-SaitekSetupAction -Selected Restore
                    }
                }
                '4' {
                    $report=Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('Saitek-support-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.json')
                    Write-Host ('Suggested local report: '+$report)
                    $selected=Read-Host 'Enter another full filename, or Enter to use the suggestion'
                    if ($selected) { $report=$selected }
                    Invoke-SaitekSetupAction -Selected Support -Directory $Directory -ReportPath $report
                    Write-Host 'Report saved locally. Review it before sharing; nothing was uploaded.'
                }
                '5' {
                    $bridge=$Directory
                    if (-not $bridge) {
                        $bridge=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ffb-bridge'
                        if (-not [IO.File]::Exists((Join-Path $bridge 'FfbBridge.Desktop.exe'))) {
                            $bridge=Read-Host 'Enter the folder containing the separately installed official FfbBridge.Desktop.exe (blank cancels)'
                            if (-not $bridge) { break }
                        }
                    }
                    $link=Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Saitek FFB-Bridge.lnk'
                    Write-Host ('Suggested shortcut: '+$link)
                    $selected=Read-Host 'Enter another full .lnk filename, or Enter to use the suggestion'
                    if ($selected) { $link=$selected }
                    Invoke-SaitekSetupAction -Selected Shortcut -Directory $bridge -LinkPath $link -WhatIf
                    if ((Read-Host 'Type CREATE to create this shortcut, or Enter to cancel') -ceq 'CREATE') {
                        Invoke-SaitekSetupAction -Selected Shortcut -Directory $bridge -LinkPath $link
                    }
                }
                '0' { return }
                default { Write-Host 'Choose 0 through 5. No action was performed.' }
            }
        } catch { Write-Host ('Action failed: '+$_.Exception.Message) -ForegroundColor Red }
    } while ($true)
}
if ($MyInvocation.InvocationName -ne '.') {
    if (-not [Environment]::Is64BitProcess) { throw 'Use native 64-bit Windows PowerShell on x64 Windows.' }
    if ($Action -eq 'Menu') { Start-SaitekSetupMenu -Directory $BridgeDirectory }
    else { Invoke-SaitekSetupAction -Selected $Action -Directory $BridgeDirectory -ReportPath $OutputPath -LinkPath $ShortcutPath -WhatIf:$WhatIfPreference }
}
