#requires -Version 5.1
<# Passive allowlisted report. No installer import, device discovery, subprocess or network. #>
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$BridgeDirectory,[string]$OutputPath,[switch]$AsObject)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-SaitekSupportVersion([object]$Value) {
    if ($Value -is [string] -and $Value -cmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}(\.\d{1,5})?$') { return $Value }
    return $null
}
function Get-SaitekSupportHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-SaitekSupportFileIdentity([string]$Path,[switch]$NumericVersion) {
    $result=[ordered]@{Present=$false;Version=$null;Sha256=$null;Category='Missing'}
    try {
        if ([IO.File]::Exists($Path)) {
            $result.Present=$true
            $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $result.Version=Get-SaitekSupportVersion $info.FileVersion
            if ($NumericVersion -and $info.FileVersion) {
                $result.Version=Get-SaitekSupportVersion ('{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart)
            }
            $hash=Get-SaitekSupportHash $Path
            if ($hash -isnot [string] -or $hash -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid hash.' }
            $result.Sha256=$hash; $result.Category='Read'
        }
    } catch { $result.Category='Unreadable'; $result.Sha256=$null }
    [pscustomobject]$result
}
function Get-SaitekSupportRegistration {
    $result=[ordered]@{Category='Read';NativeClassPresent=$false;DeviceOverridePresent=$false;RoutesToNativeClass=$false}
    $base=$null; $class=$null; $oem=$null
    try {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry64')
        $class=$base.OpenSubKey('Software\Classes\CLSID\{1DB0C28F-6D99-416E-8D05-73DE59E6E170}')
        $oem=$base.OpenSubKey('System\CurrentControlSet\Control\MediaProperties\PrivateProperties\Joystick\OEM\VID_06A3&PID_FFB5\OEMForceFeedback')
        $result.NativeClassPresent=($null -ne $class); $result.DeviceOverridePresent=($null -ne $oem)
        if ($null -ne $oem) { $value=$oem.GetValue('CLSID',$null,'DoNotExpandEnvironmentNames'); $result.RoutesToNativeClass=[bool]($value -is [string] -and $value -eq '{1DB0C28F-6D99-416E-8D05-73DE59E6E170}') }
    } catch { $result.Category='Unreadable' }
    finally { if ($null -ne $oem) {$oem.Dispose()}; if ($null -ne $class) {$class.Dispose()}; if ($null -ne $base) {$base.Dispose()} }
    [pscustomobject]$result
}
function Get-SaitekSupportTransactions([string]$Root) {
    # Inspect marker existence only. Never read manifests containing SID/registry trees.
    $result=[ordered]@{Category='Read';ActiveCount=0;AppliedCount=0;IncompleteCount=0}
    try {
        $backups=Join-Path $Root 'backups'
        foreach ($parent in @($Root,$backups)) {
            if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Link refused.' }
        }
        if ([IO.Directory]::Exists($backups)) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $backups -Directory -Force)) {
                if ($entry.Name -cnotmatch '^[0-9]{8}T[0-9]{9}Z-[a-f0-9]{32}$' -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                if ([IO.File]::Exists((Join-Path $entry.FullName 'manifest.json')) -and
                    -not [IO.File]::Exists((Join-Path $entry.FullName 'restored.json')) -and
                    -not [IO.File]::Exists((Join-Path $entry.FullName 'rolled-back.json'))) {
                    $result.ActiveCount++
                    if ([IO.File]::Exists((Join-Path $entry.FullName 'applied.json'))) { $result.AppliedCount++ } else { $result.IncompleteCount++ }
                }
            }
        }
    } catch { $result.Category='Unreadable'; $result.ActiveCount=$null; $result.AppliedCount=$null; $result.IncompleteCount=$null }
    [pscustomobject]$result
}
function Get-SaitekSupportPackage([string]$Root) {
    $result=[ordered]@{Category='ManifestMissing';Version=$null;Channel=$null;Architecture=$null;DeclaredBinarySha256=$null;ActualBinarySha256=$null;BinaryMatches=$false;ManifestSha256=$null;IntegrityValidated=$false}
    try {
        $path=Join-Path $Root 'release-manifest.json'
        if ([IO.File]::Exists($path)) {
            if ((Get-Item -LiteralPath $path).Length -gt 2097152) { throw 'Manifest too large.' }
            $m=[IO.File]::ReadAllText($path) | ConvertFrom-Json
            if ($m -isnot [pscustomobject]) { throw 'Invalid manifest object.' }
            foreach ($name in @('Product','Version','Channel','Architecture','BinaryPath','BinarySha256')) {
                if ($m.$name -isnot [string]) { throw 'Invalid manifest string type.' }
            }
            if (($m.SchemaVersion -isnot [int] -and $m.SchemaVersion -isnot [long]) -or $m.SchemaVersion -ne 1 -or
                $m.Product -cne 'SaitekNativeFfb' -or $m.Version.Length -gt 100 -or
                $m.Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.(0|[1-9][0-9]*)\z' -or
                $m.Channel -cnotin @('private-alpha','experimental-alpha') -or $m.Architecture -cne 'x64' -or
                $m.BinaryPath -cne 'bin/SaitekFfbDriver.dll' -or $m.BinarySha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Unsupported manifest.' }
            $result.Version=$m.Version; $result.Channel=$m.Channel; $result.Architecture='x64'
            $result.DeclaredBinarySha256=[string]$m.BinarySha256
            $result.ManifestSha256=Get-SaitekSupportHash $path
            $identity=Get-SaitekSupportFileIdentity (Join-Path $Root 'bin\SaitekFfbDriver.dll')
            $result.ActualBinarySha256=$identity.Sha256
            $result.BinaryMatches=($identity.Sha256 -ceq $result.DeclaredBinarySha256)
            $result.Category='IdentityRead'
        }
    } catch { $result.Category='InvalidOrUnreadable'; $result.Version=$null; $result.ManifestSha256=$null }
    # This intentionally does not assert the installer's full manifest validation.
    [pscustomobject]$result
}
function New-SaitekSupportReport([string]$Directory,[string]$PackageRoot=(Split-Path -Parent $PSScriptRoot),[string]$StorageRoot,[string]$SystemDirectory) {
    if (-not $Directory) { $Directory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ffb-bridge' }
    if (-not $StorageRoot) { $StorageRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SaitekNativeFfb' }
    if (-not $SystemDirectory) { $SystemDirectory=[Environment]::SystemDirectory }
    $dinput=Get-SaitekSupportFileIdentity (Join-Path $SystemDirectory 'dinput8.dll') -NumericVersion
    $dinput | Add-Member -NotePropertyName Compatible -NotePropertyValue ($dinput.Sha256 -ceq 'B0F10001FCCD05E9863D84588BE9B9F8389656D95177287DD4C6CF3BE4BF1DFE')
    $app=Get-SaitekSupportFileIdentity (Join-Path $Directory 'FfbBridge.Desktop.exe')
    $assembly=Get-SaitekSupportFileIdentity (Join-Path $Directory 'FfbBridge.Desktop.dll')
    $core=Get-SaitekSupportFileIdentity (Join-Path $Directory 'System.Private.CoreLib.dll')
    $runtimeVersion=$null; $runtimeCategory='Missing'; $runtimeCompatible=$false
    try {
        $config=Join-Path $Directory 'FfbBridge.Desktop.runtimeconfig.json'
        if ([IO.File]::Exists($config)) {
            if ((Get-Item -LiteralPath $config).Length -gt 1048576) { throw 'Config too large.' }
            $runtime=[IO.File]::ReadAllText($config) | ConvertFrom-Json
            if ($runtime -isnot [pscustomobject] -or $runtime.runtimeOptions -isnot [pscustomobject] -or
                $runtime.runtimeOptions.tfm -isnot [string] -or $runtime.runtimeOptions.includedFrameworks -isnot [array]) { throw 'Invalid runtime config types.' }
            foreach ($framework in $runtime.runtimeOptions.includedFrameworks) {
                if ($framework -isnot [pscustomobject] -or $framework.name -isnot [string] -or $framework.version -isnot [string]) { throw 'Invalid framework identity types.' }
            }
            $frameworks=@($runtime.runtimeOptions.includedFrameworks | Where-Object {$_.name -ceq 'Microsoft.NETCore.App'})
            $runtimeCategory='Read'
            if ($frameworks.Count -eq 1) { $runtimeVersion=Get-SaitekSupportVersion $frameworks[0].version }
            $runtimeCompatible=($runtime.runtimeOptions.tfm -ceq 'net10.0' -and $runtimeVersion -ceq '10.0.12')
        }
    } catch { $runtimeCategory='InvalidOrUnreadable'; $runtimeVersion=$null; $runtimeCompatible=$false }
    [pscustomobject][ordered]@{
        SchemaVersion=1; Product='SaitekNativeFfb'; Collection='PassiveRedacted';
        OS=[pscustomobject]@{Version=[Environment]::OSVersion.Version.ToString();Is64BitOperatingSystem=[Environment]::Is64BitOperatingSystem;Is64BitProcess=[Environment]::Is64BitProcess};
        DirectInput=$dinput;
        Bridge=[pscustomobject]@{Application=$app;Assembly=$assembly;CoreLibrary=$core;BundledRuntime=$runtimeVersion;RuntimeCategory=$runtimeCategory;Compatible=($app.Version -ceq '1.5.3.0' -and $assembly.Version -ceq '1.5.3.0' -and $runtimeCompatible -and $core.Sha256 -ceq '1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678')};
        Package=(Get-SaitekSupportPackage $PackageRoot); Registration=(Get-SaitekSupportRegistration); Transactions=(Get-SaitekSupportTransactions $StorageRoot);
        Hardware=[pscustomobject]@{Device='NotChecked';Descriptor='NotChecked';Forces='NotChecked'}
    }
}
function Write-SaitekSupportReport {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param($Report,[string]$Path,[switch]$Object)
    $json=$Report | ConvertTo-Json -Depth 8
    if ($Path) {
        try {
            $full=[IO.Path]::GetFullPath($Path)
            if ($PSCmdlet.ShouldProcess($full,'Write redacted support JSON (new file only)')) {
                $stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try { $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json); $stream.Write($bytes,0,$bytes.Length) }
                finally { $stream.Dispose() }
            }
        } catch { throw 'SupportOutputWriteFailed: choose a new filename in an existing writable folder.' }
    }
    if ($Object) { $Report } else { $json }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $report=New-SaitekSupportReport -Directory $BridgeDirectory
        Write-SaitekSupportReport -Report $report -Path $OutputPath -Object:$AsObject -WhatIf:$WhatIfPreference
    } catch { throw 'SupportCollectionFailed: no raw diagnostic details were included.' }
}
