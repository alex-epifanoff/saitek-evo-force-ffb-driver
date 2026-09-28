#requires -Version 5.1
# Offline owner workflow fixtures. No device/app access or production mutations.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root=[IO.Path]::GetFullPath((Join-Path $workspace ('out\owner tests '+[Guid]::NewGuid().ToString('N'))))
$expectedPrefix=[IO.Path]::GetFullPath((Join-Path $workspace 'out'))+'\'
if (-not $root.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture root.' }
$script:checks=0
function Check([bool]$Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw ('ASSERTION FAILED: '+$Message) } }
function Reject([scriptblock]$Body,[string]$Message) { $rejected=$false; try { & $Body | Out-Null } catch {$rejected=$true}; Check $rejected $Message }
function WriteFixture([string]$Path,[string]$Value) { [IO.File]::WriteAllText($Path,$Value) }
try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $bridge=Join-Path $root 'Bridge folder'; [IO.Directory]::CreateDirectory($bridge) | Out-Null
    $exe=Join-Path $bridge 'FfbBridge.Desktop.exe'; $dll=Join-Path $bridge 'FfbBridge.Desktop.dll'
    $core=Join-Path $bridge 'System.Private.CoreLib.dll'; $config=Join-Path $bridge 'FfbBridge.Desktop.runtimeconfig.json'
    WriteFixture $exe '1.5.3.0'; WriteFixture $dll '1.5.3.0'; WriteFixture $core 'synthetic exact core'
    $goodConfig='{"runtimeOptions":{"tfm":"net10.0","includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"10.0.12"}]}}'
    WriteFixture $config $goodConfig
    $toolNames=@('Start-SaitekFfbBridge.ps1','Get-SaitekFfbSupport.ps1','New-SaitekFfbShortcut.ps1','Start-SaitekFfbSetup.ps1')
    foreach ($name in $toolNames) {
        $tokens=$null; $parseErrors=$null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $workspace ('tools\'+$name)),[ref]$tokens,[ref]$parseErrors) | Out-Null
        Check ($parseErrors.Count -eq 0) ('PowerShell 5.1 syntax '+$name)
    }
    . (Join-Path $workspace 'tools\Start-SaitekFfbBridge.ps1')
    # Fixture adapters replace metadata, hash and process boundaries only. All
    # compatibility predicates and launch environment construction remain real.
    function Get-SaitekBridgeFileVersion([string]$Path) { [IO.File]::ReadAllText($Path) }
    function Get-SaitekBridgeHash([string]$Path) {
        if ([IO.File]::ReadAllText($Path) -ceq 'synthetic exact core') { '1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678' } else { '0'*64 }
    }
    $script:processes=@(); $script:launchCount=0; $script:lastStart=$null
    function Get-SaitekBridgeProcesses { $script:processes }
    function Start-SaitekBridgeProcess($StartInfo) {
        $script:launchCount++; $script:lastStart=$StartInfo
        $fake=[pscustomobject]@{Id=123}; $fake | Add-Member ScriptMethod Dispose {}; $fake
    }
    Check ((Get-SaitekBridgeIdentity $bridge).Directory -eq $bridge) 'relocated Bridge folder with spaces'
    Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf
    Check ($script:launchCount -eq 0) 'launcher WhatIf never starts a process'
    WriteFixture $exe '1.5.4.0'; Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'changed app refuses'; WriteFixture $exe '1.5.3.0'
    WriteFixture $dll '1.5.4.0'; Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'changed assembly refuses'; WriteFixture $dll '1.5.3.0'
    WriteFixture $config ($goodConfig.Replace('10.0.12','10.0.13')); Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'changed runtime refuses'; WriteFixture $config $goodConfig
    WriteFixture $config ($goodConfig.Replace('net10.0','net11.0')); Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'changed target framework refuses'; WriteFixture $config $goodConfig
    WriteFixture $core 'changed'; Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'changed CoreLib hash refuses'; WriteFixture $core 'synthetic exact core'
    $script:processes=@([pscustomobject]@{Id=987}); Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} 'existing process refuses even preview'; $script:processes=@()
    Reject {Get-SaitekBridgeIdentity (Join-Path $root 'missing')} 'missing installation refuses'
    $oldKeep=[Environment]::GetEnvironmentVariable('DOTNET_ThreadPool_ThreadsToKeepAlive','Process')
    $oldPool=[Environment]::GetEnvironmentVariable('DOTNET_ThreadPool_UseWindowsThreadPool','Process')
    Invoke-SaitekBridgeLaunch -Directory $bridge | Out-Null
    Check ($script:launchCount -eq 1 -and $script:lastStart.FileName -eq $exe -and $script:lastStart.WorkingDirectory -eq $bridge) 'intercepted launch uses exact separate executable and directory'
    Check ($script:lastStart.EnvironmentVariables['DOTNET_ThreadPool_ThreadsToKeepAlive'] -ceq '-1' -and $script:lastStart.EnvironmentVariables['DOTNET_ThreadPool_UseWindowsThreadPool'] -ceq '0') 'child-only workaround values'
    Check (-not $script:lastStart.UseShellExecute -and $script:lastStart.Arguments -eq '') 'no shell commands or arm arguments'
    Check ([Environment]::GetEnvironmentVariable('DOTNET_ThreadPool_ThreadsToKeepAlive','Process') -ceq $oldKeep -and [Environment]::GetEnvironmentVariable('DOTNET_ThreadPool_UseWindowsThreadPool','Process') -ceq $oldPool) 'parent environment unchanged'

    . (Join-Path $workspace 'tools\Get-SaitekFfbSupport.ps1')
    $supportSource=Get-Content -LiteralPath (Join-Path $workspace 'tools\Get-SaitekFfbSupport.ps1') -Raw
    $tokens=$null; $errors=$null
    $supportAst=[Management.Automation.Language.Parser]::ParseInput($supportSource,[ref]$tokens,[ref]$errors)
    $allowed=@('Get-SaitekSupportVersion','Get-SaitekSupportHash','Get-SaitekSupportFileIdentity','Get-SaitekSupportRegistration','Get-SaitekSupportTransactions','Get-SaitekSupportPackage','New-SaitekSupportReport','Write-SaitekSupportReport','Get-FileHash','Test-Path','Get-Item','Get-ChildItem','Join-Path','Split-Path','ConvertFrom-Json','ConvertTo-Json','Where-Object','Add-Member','New-Object','Set-StrictMode')
    foreach ($command in $supportAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
        Check ($command.GetCommandName() -in $allowed) ('collector command allowlist: '+$command.GetCommandName())
    }
    Check ($supportSource -notmatch '(?i)DllImport|Diagnostics\.Process|System\.Net|HidD_|DirectInput8Create|CreateFile|WindowsIdentity|GetEnvironmentVariables|Invoke-Expression|ScriptBlock\]::Create') 'collector has no native/device/process/network/identity escape'
    Check ($supportSource -notmatch '\.Exception|\$Error\b|Get-SaitekRegistryTree|Read-NativeBackup|Install-SaitekFfbDriver|Start-SaitekFfbBridge') 'collector never forwards errors, installer output or backup trees'
    $script:forbiddenCalls=0
    function Start-Process { $script:forbiddenCalls++; throw 'Forbidden subprocess' }
    function Stop-Process { $script:forbiddenCalls++; throw 'Forbidden process stop' }
    function Get-Process { $script:forbiddenCalls++; throw 'Forbidden process query' }
    function Invoke-WebRequest { $script:forbiddenCalls++; throw 'Forbidden network' }
    function Invoke-RestMethod { $script:forbiddenCalls++; throw 'Forbidden network' }
    function Get-SaitekSupportRegistration { [pscustomobject]@{Category='Read';NativeClassPresent=$false;DeviceOverridePresent=$false;RoutesToNativeClass=$false} }
    $package=Join-Path $root 'relocated package'; $bin=Join-Path $package 'bin'; [IO.Directory]::CreateDirectory($bin) | Out-Null
    $binary=Join-Path $bin 'SaitekFfbDriver.dll'; WriteFixture $binary 'synthetic binary'
    $binaryHash=(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    $manifest=@{SchemaVersion=1;Product='SaitekNativeFfb';Version='0.1.0-alpha.1';Channel='private-alpha';Architecture='x64';BinaryPath='bin/SaitekFfbDriver.dll';BinarySha256=$binaryHash;UserSid='S-1-5-21-111-222-333-1001';Computer='SECRETPC';SourcePath='C:\Users\SecretOwner\private'}
    WriteFixture (Join-Path $package 'release-manifest.json') ($manifest|ConvertTo-Json)
    $store=Join-Path $root 'storage'; $backup=Join-Path $store ('backups\20260928T010203456Z-'+('a'*32)); [IO.Directory]::CreateDirectory($backup) | Out-Null
    $sensitive='SecretOwner SECRETPC S-1-5-21-111-222-333-1001 C:\Users\SecretOwner\private SERIAL-SECRET'
    WriteFixture (Join-Path $backup 'manifest.json') $sensitive
    WriteFixture (Join-Path $backup 'applied.json') $sensitive
    $report=New-SaitekSupportReport -Directory $bridge -PackageRoot $package -StorageRoot $store -SystemDirectory $root
    $json=$report|ConvertTo-Json -Depth 8
    Check ($report.Hardware.Device -eq 'NotChecked' -and $report.Hardware.Descriptor -eq 'NotChecked' -and $report.Hardware.Forces -eq 'NotChecked') 'hardware explicitly unchecked'
    Check ($report.Package.BinaryMatches -and -not $report.Package.IntegrityValidated) 'package identity is not full integrity approval'
    Check ($report.Transactions.ActiveCount -eq 1 -and $report.Transactions.AppliedCount -eq 1 -and $report.Transactions.IncompleteCount -eq 0) 'narrow transaction marker counts without reading private manifest'
    Check ($json -notmatch 'SecretOwner|SECRETPC|S-1-5-21|SERIAL-SECRET|C:\\|owner tests|relocated package|UserSid|SourcePath') 'report excludes synthetic identity, backup content and all raw paths'
    Check ($script:forbiddenCalls -eq 0) 'passive collector makes no subprocess or network calls'
    # Supply reviewed file identities at the fixture boundary so runtime parsing
    # alone determines compatibility; malformed configs must fail both readers.
    $fileIdentityImplementation=(Get-Command Get-SaitekSupportFileIdentity).ScriptBlock
    function Get-SaitekSupportFileIdentity([string]$Path,[switch]$NumericVersion) {
        if ($Path -in @($exe,$dll,$core)) {
            [pscustomobject]@{Present=$true;Version='1.5.3.0';Sha256='1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678';Category='Read'}
        } else { & $fileIdentityImplementation $Path -NumericVersion:$NumericVersion }
    }
    try {
        $validRuntimeReport=New-SaitekSupportReport -Directory $bridge -PackageRoot $package -StorageRoot $store -SystemDirectory $root
        Check ($validRuntimeReport.Bridge.Compatible -and $validRuntimeReport.Bridge.BundledRuntime -ceq '10.0.12') 'supported scalar runtime config is compatible with reviewed fixture identities'
        foreach ($field in @('tfm','name','version')) {
            foreach ($shape in @('singleton','repeated','mixed','empty','null','number','object')) {
                $runtimeFixture=$goodConfig | ConvertFrom-Json
                if ($field -eq 'tfm') {$target=$runtimeFixture.runtimeOptions} else {$target=$runtimeFixture.runtimeOptions.includedFrameworks[0]}
                $value=$target.$field
                switch ($shape) {
                    singleton {$target.$field=@($value)}
                    repeated {$target.$field=@($value,$value)}
                    mixed {$target.$field=@($value,'invalid')}
                    empty {$target.$field=@()}
                    null {$target.$field=$null}
                    number {$target.$field=10}
                    object {$target.$field=[pscustomobject]@{value=$value}}
                }
                WriteFixture $config ($runtimeFixture | ConvertTo-Json -Depth 10)
                Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} "launcher rejects $shape runtime $field"
                $malformedReport=New-SaitekSupportReport -Directory $bridge -PackageRoot $package -StorageRoot $store -SystemDirectory $root
                Check (-not $malformedReport.Bridge.Compatible -and $malformedReport.Bridge.RuntimeCategory -ceq 'InvalidOrUnreadable' -and $null -eq $malformedReport.Bridge.BundledRuntime) "support rejects $shape runtime $field without false compatibility"
            }
        }
        foreach ($shape in @('options-array','frameworks-object','framework-array','framework-null')) {
            $runtimeFixture=$goodConfig | ConvertFrom-Json
            switch ($shape) {
                options-array {$runtimeFixture.runtimeOptions=@($runtimeFixture.runtimeOptions)}
                frameworks-object {$runtimeFixture.runtimeOptions.includedFrameworks=$runtimeFixture.runtimeOptions.includedFrameworks[0]}
                framework-array {$runtimeFixture.runtimeOptions.includedFrameworks[0]=@($runtimeFixture.runtimeOptions.includedFrameworks[0])}
                framework-null {$runtimeFixture.runtimeOptions.includedFrameworks[0]=$null}
            }
            WriteFixture $config ($runtimeFixture | ConvertTo-Json -Depth 10)
            Reject {Invoke-SaitekBridgeLaunch -Directory $bridge -WhatIf} "launcher rejects runtime object shape $shape"
            $malformedReport=New-SaitekSupportReport -Directory $bridge -PackageRoot $package -StorageRoot $store -SystemDirectory $root
            Check (-not $malformedReport.Bridge.Compatible -and $malformedReport.Bridge.RuntimeCategory -ceq 'InvalidOrUnreadable') "support rejects runtime object shape $shape"
        }
        Check ($script:launchCount -eq 1 -and $script:forbiddenCalls -eq 0) 'malformed runtime checks make no additional process or network calls'
    } finally {
        Set-Item -LiteralPath Function:\Get-SaitekSupportFileIdentity -Value $fileIdentityImplementation
        WriteFixture $config $goodConfig
    }
    $manifest.Version='0.1.0-SecretOwner'
    WriteFixture (Join-Path $package 'release-manifest.json') ($manifest|ConvertTo-Json)
    $hostilePackage=Get-SaitekSupportPackage $package
    Check ($hostilePackage.Category -eq 'InvalidOrUnreadable' -and ($hostilePackage|ConvertTo-Json) -notmatch 'SecretOwner|S-1-5-21|SECRETPC') 'unrecognized release text cannot leak identity through version'
    $manifest.Version='0.1.0-alpha.1'
    WriteFixture (Join-Path $package 'release-manifest.json') ($manifest|ConvertTo-Json)
    $savedPackageManifest=$manifest | ConvertTo-Json
    foreach ($candidate in @(
        [pscustomobject]@{Version='0.1.0-alpha.1';Channel='private-alpha'},
        [pscustomobject]@{Version='0.1.0-alpha.2';Channel='experimental-alpha'},
        [pscustomobject]@{Version='1.2.3-alpha.12';Channel='experimental-alpha'})) {
        $m=$savedPackageManifest | ConvertFrom-Json;$m.Version=$candidate.Version;$m.Channel=$candidate.Channel
        WriteFixture (Join-Path $package 'release-manifest.json') ($m|ConvertTo-Json)
        $packageReport=Get-SaitekSupportPackage $package
        Check ($packageReport.Category -ceq 'IdentityRead' -and $packageReport.Version -ceq $candidate.Version -and $packageReport.Channel -ceq $candidate.Channel -and $packageReport.BinaryMatches) 'support reads current public and historical private alpha identities'
    }
    foreach ($version in @('0.1.0','0.1.0-beta.1','01.1.0-alpha.2','0.1.0-alpha.02','../0.1.0-alpha.2','0.1.0-alpha.2+SecretOwner',"0.1.0-alpha.2`n")) {
        $m=$savedPackageManifest | ConvertFrom-Json;$m.Version=$version
        WriteFixture (Join-Path $package 'release-manifest.json') ($m|ConvertTo-Json)
        $packageReport=Get-SaitekSupportPackage $package
        Check ($packageReport.Category -ceq 'InvalidOrUnreadable' -and $null -eq $packageReport.Version -and ($packageReport|ConvertTo-Json) -notmatch 'SecretOwner') 'support rejects nonconforming or identity-bearing release versions'
    }
    foreach ($field in @('Product','Version','Channel','Architecture','BinaryPath','BinarySha256')) {
        foreach ($shape in @('singleton','repeated')) {
            $m=$savedPackageManifest | ConvertFrom-Json;$value=$m.$field
            if ($shape -eq 'singleton') {$m.$field=@($value)} else {$m.$field=@($value,$value)}
            WriteFixture (Join-Path $package 'release-manifest.json') ($m|ConvertTo-Json -Depth 8)
            $packageReport=Get-SaitekSupportPackage $package
            Check ($packageReport.Category -ceq 'InvalidOrUnreadable' -and $null -eq $packageReport.Version) "support rejects $shape array-valued manifest $field"
        }
    }
    $m=$savedPackageManifest | ConvertFrom-Json;$m.Channel='stable'
    WriteFixture (Join-Path $package 'release-manifest.json') ($m|ConvertTo-Json)
    Check ((Get-SaitekSupportPackage $package).Category -ceq 'InvalidOrUnreadable') 'support does not expand supported release channels'
    WriteFixture (Join-Path $package 'release-manifest.json') $savedPackageManifest
    $hashImplementation=(Get-Command Get-SaitekSupportHash).ScriptBlock
    function Get-SaitekSupportHash { throw $sensitive }
    WriteFixture $config ('{"runtimeOptions":{"tfm":"net10.0","includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"'+$sensitive.Replace('\','\\')+'"}]}}')
    $errorReport=New-SaitekSupportReport -Directory $bridge -PackageRoot $package -StorageRoot $store -SystemDirectory $root
    $errorJson=$errorReport | ConvertTo-Json -Depth 8
    Check ($errorJson -notmatch 'SecretOwner|SECRETPC|S-1-5-21|SERIAL-SECRET|C:\\') 'sensitive injected exception and runtime value are redacted'
    Check ($errorReport.Bridge.CoreLibrary.Category -eq 'Unreadable' -and $null -eq $errorReport.Bridge.BundledRuntime -and -not $errorReport.Bridge.Compatible) 'failure remains categorized without a false match'
    Set-Item -LiteralPath Function:\Get-SaitekSupportHash -Value $hashImplementation
    WriteFixture $config $goodConfig
    $reportFile=Join-Path $root 'support.json'
    Write-SaitekSupportReport -Report $report -Path $reportFile -WhatIf | Out-Null
    Check (-not [IO.File]::Exists($reportFile)) 'report WhatIf does not write'
    Write-SaitekSupportReport -Report $report -Path $reportFile | Out-Null
    Check (([IO.File]::ReadAllText($reportFile)|ConvertFrom-Json).Collection -eq 'PassiveRedacted') 'explicit report file is reviewable JSON'
    Reject {Write-SaitekSupportReport -Report $report -Path $reportFile} 'report does not overwrite existing file'

    . (Join-Path $workspace 'tools\New-SaitekFfbShortcut.ps1') -DestinationPath (Join-Path $root 'unused.lnk')
    $link=Join-Path $root 'Bridge shortcut.lnk'
    New-SaitekBridgeShortcut -Path $link -Directory $bridge -WhatIf
    Check (-not [IO.File]::Exists($link)) 'shortcut WhatIf has no file side effect'
    New-SaitekBridgeShortcut -Path $link -Directory $bridge | Out-Null
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$null
    try {
        $shortcut=$shell.CreateShortcut($link)
        Check ($shortcut.TargetPath -like '*\WindowsPowerShell\v1.0\powershell.exe') 'shortcut targets native PowerShell'
        Check ($shortcut.Arguments.Contains('"'+(Join-Path $workspace 'tools\Start-SaitekFfbBridge.ps1')+'"')) 'shortcut quotes relocated script'
        Check ($shortcut.Arguments.Contains('"'+$bridge+'\."') -and $shortcut.Arguments.Contains('-NoExit')) 'shortcut quotes spaced Bridge path and keeps errors visible'
    } finally { if ($null -ne $shortcut) {[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)}; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    $linkHash=(Get-FileHash -LiteralPath $link).Hash
    Reject {New-SaitekBridgeShortcut -Path $link -Directory $bridge} 'shortcut refuses replacement'
    Check ((Get-FileHash -LiteralPath $link).Hash -ceq $linkHash) 'existing shortcut bytes unchanged'
    Reject {New-SaitekBridgeShortcut -Path (Join-Path $root 'wrong.txt') -WhatIf} 'shortcut requires .lnk extension'

    . (Join-Path $workspace 'tools\Start-SaitekFfbSetup.ps1')
    $fixtureTools=Join-Path $package 'tools'; [IO.Directory]::CreateDirectory($fixtureTools) | Out-Null
    WriteFixture (Join-Path $fixtureTools 'Get-SaitekFfbSupport.ps1') 'param($BridgeDirectory,$OutputPath,[switch]$WhatIf) [pscustomobject]@{Tool="Support";Directory=$BridgeDirectory;Output=$OutputPath}'
    WriteFixture (Join-Path $fixtureTools 'Install-SaitekFfbDriver.ps1') 'param($Mode,$ReleaseManifest,[switch]$WhatIf) [pscustomobject]@{Mode=$Mode;Manifest=$ReleaseManifest;Preview=[bool]$WhatIf}'
    WriteFixture (Join-Path $fixtureTools 'New-SaitekFfbShortcut.ps1') 'param($DestinationPath,$BridgeDirectory,[switch]$WhatIf) [pscustomobject]@{Tool="Shortcut";Destination=$DestinationPath;Directory=$BridgeDirectory;Preview=[bool]$WhatIf}'
    $checked=Invoke-SaitekSetupAction -ToolsRoot $fixtureTools
    Check ($checked.Tool -eq 'Support') 'default noninteractive action is passive Check'
    $preview=Invoke-SaitekSetupAction -Selected Install -ToolsRoot $fixtureTools -WhatIf
    Check ($preview.Mode -eq 'Apply' -and $preview.Preview -and $preview.Manifest -eq (Join-Path $package 'release-manifest.json')) 'Install resolves relocated release manifest and propagates WhatIf'
    $restore=Invoke-SaitekSetupAction -Selected Restore -ToolsRoot $fixtureTools -WhatIf
    Check ($restore.Mode -eq 'Restore' -and $restore.Preview -and -not $restore.Manifest) 'Restore omits manifest and preserves preview'
    $shortcutPreview=Invoke-SaitekSetupAction -Selected Shortcut -Directory $bridge -LinkPath (Join-Path $root 'other.lnk') -ToolsRoot $fixtureTools -WhatIf
    Check ($shortcutPreview.Preview -and $shortcutPreview.Directory -eq $bridge -and $shortcutPreview.Destination -eq (Join-Path $root 'other.lnk')) 'shortcut paths and preview forwarded without string evaluation'
    WriteFixture (Join-Path $fixtureTools 'Install-SaitekFfbDriver.ps1') 'param($Mode,$ReleaseManifest,[switch]$WhatIf) exit 23'
    Reject {Invoke-SaitekSetupAction -Selected Install -ToolsRoot $fixtureTools -WhatIf} 'child script nonzero exit visibly fails'
    WriteFixture (Join-Path $fixtureTools 'Install-SaitekFfbDriver.ps1') 'param($Mode,$ReleaseManifest,[switch]$WhatIf) throw "Fixture failure"'
    Reject {Invoke-SaitekSetupAction -Selected Install -ToolsRoot $fixtureTools -WhatIf} 'child script terminating error visibly fails'
    # The interactive dispatcher is tested with intercepted action calls only.
    $script:menuInputs=New-Object 'Collections.Generic.Queue[string]'
    foreach ($inputValue in @('','2','','3','','0')) { $script:menuInputs.Enqueue($inputValue) }
    function Read-Host { $script:menuInputs.Dequeue() }
    $script:menuCalls=New-Object 'Collections.Generic.List[object]'
    function Invoke-SaitekSetupAction { [CmdletBinding(SupportsShouldProcess=$true)]param($Selected,$Directory,$ReportPath,$LinkPath) $script:menuCalls.Add([pscustomobject]@{Action=$Selected;Preview=[bool]$WhatIfPreference}) }
    Start-SaitekSetupMenu
    Check ($script:menuCalls.Count -eq 3 -and $script:menuCalls[0].Action -eq 'Check') 'Enter in interactive menu checks only'
    Check ($script:menuCalls[1].Action -eq 'Install' -and $script:menuCalls[1].Preview -and $script:menuCalls[2].Action -eq 'Restore' -and $script:menuCalls[2].Preview) 'blank mutation confirmations only preview'
    $script:menuCalls.Clear()
    foreach ($inputValue in @('2','INSTALL','3','RESTORE','0')) { $script:menuInputs.Enqueue($inputValue) }
    Start-SaitekSetupMenu
    Check ($script:menuCalls.Count -eq 4 -and $script:menuCalls[0].Preview -and -not $script:menuCalls[1].Preview -and $script:menuCalls[1].Action -eq 'Install' -and $script:menuCalls[2].Preview -and -not $script:menuCalls[3].Preview -and $script:menuCalls[3].Action -eq 'Restore') 'exact explicit confirmations apply after preview through mocked actions only'
    $cmd=Get-Content -LiteralPath (Join-Path $workspace 'Start.cmd') -Raw
    Check ($cmd -match '%~dp0tools\\Start-SaitekFfbSetup\.ps1' -and $cmd -notmatch '(?im)\b(copy|move|del|erase|rmdir|mkdir|start|reg|curl)\s') 'cmd entry invokes fixed quoted setup without filesystem or registry actions'
    Write-Host ('PASS: '+$script:checks+' owner-tool checks; fixtures only, no app/device/production mutation.')
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or $resolved -eq $expectedPrefix.TrimEnd('\')) { throw 'Refusing unsafe fixture cleanup.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
