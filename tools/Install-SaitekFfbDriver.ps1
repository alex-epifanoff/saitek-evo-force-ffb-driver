#requires -Version 5.1
<#
.SYNOPSIS
Reversible per-user installation of the x64 Saitek FFB driver.
.DESCRIPTION
Inspect is read-only. Apply accepts a verified portable release manifest or a
current source-verified local build manifest, both with offline test evidence.
Restore uses its saved transaction identity and
does not require current sources, build artifacts, or a compiler. Only the native
COM class and this device's OEMForceFeedback subtree are changed. OEM routing is
shared across bitness; this build provides x64 FFB only. No HID bindings, axes,
calibration, kernel drivers or System32 files are changed.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium', DefaultParameterSetName='Artifact')]
param(
    [ValidateSet('Inspect','Apply','Restore')][string]$Mode='Inspect',
    [Parameter(ParameterSetName='Artifact')][string]$ArtifactManifest,
    [Parameter(ParameterSetName='Release',Mandatory=$true)][string]$ReleaseManifest,
    [ValidatePattern('^[0-9]{8}T[0-9]{9}Z-[a-f0-9]{32}$')][string]$BackupId
)
. (Join-Path $PSScriptRoot 'SaitekFfb.Common.ps1')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:NativeClsid='{1DB0C28F-6D99-416E-8D05-73DE59E6E170}'
$script:NativeWorkspace=Split-Path -Parent $PSScriptRoot
$script:NativeMaskDInputHash='B0F10001FCCD05E9863D84588BE9B9F8389656D95177287DD4C6CF3BE4BF1DFE'

function Get-NativeHash([string]$Path) {
    $stream=[IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function New-NativeContext {
    if (-not [Environment]::Is64BitProcess) { throw 'Run native 64-bit Windows PowerShell.' }
    [pscustomobject]@{
        User=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry64')
        UserOemPath='System\CurrentControlSet\Control\MediaProperties\PrivateProperties\Joystick\OEM\VID_06A3&PID_FFB5\OEMForceFeedback'
        ClassPath="Software\Classes\CLSID\$script:NativeClsid"
        Root=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SaitekNativeFfb')
        Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
}
function Get-NativeBinaryPath($Context,[string]$Hash) {
    if ($Hash -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid native binary hash.' }
    $path=Join-Path $Context.Root "bin\$Hash\SaitekFfbDriver.dll"
    Assert-SaitekSafePath $Context.Root $path
    $path
}
function Assert-NativeBinary([string]$Path,[string]$Hash) {
    if ($Hash -cnotmatch '^[A-F0-9]{64}$' -or -not [IO.File]::Exists([IO.Path]::GetFullPath($Path))) { throw 'Native DLL identity or file is invalid.' }
    $bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    if ($bytes.Length -lt 256 -or $bytes.Length -gt 16777216 -or (Get-NativeHash $Path) -cne $Hash) { throw 'Native DLL SHA-256 does not match its build/transaction identity.' }
    $pe=[BitConverter]::ToInt32($bytes,0x3c)
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a -or $pe -lt 64 -or $pe -gt ($bytes.Length-24) -or
        [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664 -or
        ([BitConverter]::ToUInt16($bytes,$pe+22) -band 0x2000) -eq 0) { throw 'Native artifact must be an AMD64 PE DLL.' }
}
function Get-NativeExpectedMetadata {
    $effects=@(
        @('13541C20','Constant Force',0x26,0x8601,0x3e5,0x144),
        @('13541C22','Square Wave',0x30,0x8603,0x3e5,0x144),
        @('13541C23','Sine Wave',0x31,0x8603,0x3e5,0x144),
        @('13541C24','Triangle Wave',0x32,0x8603,0x3e5,0x144),
        @('13541C25','Sawtooth Up',0x33,0x8603,0x3e5,0x144),
        @('13541C26','Sawtooth Down',0x34,0x8603,0x3e5,0x144),
        @('13541C27','Spring',0x40,0xf804,0x325,0x104),
        @('13541C28','Damper',0x41,0xf804,0x325,0x104)
    ) | ForEach-Object { [pscustomobject]@{Guid=('{'+$_[0]+'-8E33-11D0-9AD0-00A0C9A06E35}');Name=$_[1];Id=[int]$_[2];Type=[int]$_[3];StaticParams=[int]$_[4];DynamicParams=[int]$_[5];Coords=32} }
    # DIFFDEVICEATTRIBUTES.dwFlags is reserved and must be zero. DIDC_* flags
    # belong to DirectInput capabilities, not this registry structure.
    [pscustomobject]@{DeviceFlags=0; FFSamplePeriod=1000; FFMinTimeResolution=1000; Effects=@($effects)}
}
function Get-NativeMaskedEffects {
    @('13541C21-8E33-11D0-9AD0-00A0C9A06E35','13541C29-8E33-11D0-9AD0-00A0C9A06E35',
      '13541C2A-8E33-11D0-9AD0-00A0C9A06E35','13541C2B-8E33-11D0-9AD0-00A0C9A06E35',
      'B3873612-BCB7-11D0-A156-524153480000','B3873613-BCB7-11D0-A156-524153480000',
      'B3873614-BCB7-11D0-A156-524153480000','B3873615-BCB7-11D0-A156-524153480000') | ForEach-Object { '{'+$_+'}' }
}
function Assert-NativeEffectMaskCompatibility {
    # DirectInput merges machine and user effect keys. The tested Windows reader
    # skips a 20-byte Attributes entry when no coordinate bit is set. This is an
    # implementation-specific compatibility mask, not a documented PID feature.
    $path=Join-Path ([Environment]::SystemDirectory) 'dinput8.dll'
    if ((Get-NativeHash $path) -cne $script:NativeMaskDInputHash) {
        throw 'This DirectInput version has not been verified for per-user effect masking. Apply refused; Restore remains available.'
    }
}
function Read-NativeBuild([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path=Join-Path $script:NativeWorkspace 'out\driver\build-manifest.json' }
    Assert-SaitekSafePath $script:NativeWorkspace $Path
    $manifest=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.SchemaVersion -ne 1 -or $manifest.Clsid -ne $script:NativeClsid -or $manifest.Architecture -cne 'x64' -or
        $manifest.OfflineComTestsPassed -isnot [bool] -or -not $manifest.OfflineComTestsPassed -or
        $manifest.OfflineProtocolTestsPassed -isnot [bool] -or -not $manifest.OfflineProtocolTestsPassed) { throw 'Build manifest must identify this x64 class and both completed offline test suites.' }
    $binary=Join-Path $script:NativeWorkspace 'out\driver\SaitekFfbDriver.dll'
    if ([IO.Path]::GetFullPath($manifest.BinaryPath) -ne [IO.Path]::GetFullPath($binary)) { throw 'Build binary path is not the fixed workspace artifact.' }
    Assert-SaitekSafePath $script:NativeWorkspace $binary
    Assert-NativeBinary $binary $manifest.BinarySha256
    $sources=@('native\SaitekFfbDriver.cpp','native\HidPidDevice.cpp','native\HidPidDevice.h','native\SaitekFfbDriver.def',
        'native\tests\DriverTests.cpp','tests\HidPidDeviceTests.cpp','tests\Run-HidPidTests.ps1','tools\Build-Driver.ps1')
    if (@($manifest.SourceHashes).Count -ne $sources.Count) { throw 'Build source list is incomplete.' }
    $seen=@{}
    foreach ($source in @($manifest.SourceHashes)) {
        $full=[IO.Path]::GetFullPath($source.Path)
        Assert-SaitekSafePath $script:NativeWorkspace $full
        if ($seen.ContainsKey($full)) { throw 'Build source list contains duplicates.' }; $seen[$full]=$true
        if (@($sources | Where-Object {(Join-Path $script:NativeWorkspace $_) -eq $full}).Count -ne 1 -or
            $source.Sha256 -cnotmatch '^[A-F0-9]{64}$' -or (Get-NativeHash $full) -cne $source.Sha256) { throw "Source changed or unexpected build input: $full. Rebuild with tests before Apply." }
    }
    $expected=Get-NativeExpectedMetadata
    $actual=$manifest.RegistryMetadata
    if ($actual.DeviceFlags -ne $expected.DeviceFlags -or $actual.FFSamplePeriod -ne 1000 -or $actual.FFMinTimeResolution -ne 1000 -or @($actual.Effects).Count -ne 8) { throw 'Unsupported registry capability metadata.' }
    foreach ($effect in $expected.Effects) {
        $match=@($actual.Effects | Where-Object {$_.Guid -eq $effect.Guid})
        if ($match.Count -ne 1) { throw 'Effect GUID list is invalid.' }
        foreach ($property in @('Id','Type','StaticParams','DynamicParams','Coords')) { if ($match[0].$property -ne $effect.$property) { throw "Unsupported effect metadata: $($effect.Guid) $property" } }
    }
    Assert-NativeEffectMaskCompatibility
    $manifest
}
function Assert-NativeObjectProperties($Value,[string[]]$Names,[string]$Description) {
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw "Invalid $Description object." }
    $actual=@($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw "Unexpected $Description fields." }
    foreach ($name in $Names) { if ($name -cnotin $actual) { throw "Missing $Description field: $name" } }
}
function Test-NativeInteger($Value) {
    $Value -is [int] -or $Value -is [long]
}
function Assert-NativeReleaseMetadata($Metadata) {
    Assert-NativeObjectProperties $Metadata @('DeviceFlags','FFSamplePeriod','FFMinTimeResolution','Effects') 'registry metadata'
    $expected=Get-NativeExpectedMetadata
    foreach ($name in @('DeviceFlags','FFSamplePeriod','FFMinTimeResolution')) {
        if (-not (Test-NativeInteger $Metadata.$name) -or $Metadata.$name -ne $expected.$name) { throw "Unsupported registry metadata: $name" }
    }
    if ($Metadata.Effects -isnot [array] -or $Metadata.Effects.Count -ne 8) { throw 'Release must declare exactly eight supported effects.' }
    # Validate scalar types before comparisons: PowerShell collection comparison
    # can otherwise accept arrays containing the expected scalar value.
    foreach ($actual in $Metadata.Effects) {
        Assert-NativeObjectProperties $actual @('Guid','Name','Id','Type','StaticParams','DynamicParams','Coords') 'effect metadata'
        if ($actual.Guid -isnot [string] -or $actual.Name -isnot [string]) { throw 'Effect GUID and name must be strings.' }
        foreach ($name in @('Id','Type','StaticParams','DynamicParams','Coords')) {
            if (-not (Test-NativeInteger $actual.$name)) { throw "Release effect metadata must be an integer: $name" }
        }
    }
    foreach ($effect in $expected.Effects) {
        $matches=@($Metadata.Effects | Where-Object { $_.Guid -ceq $effect.Guid })
        if ($matches.Count -ne 1) { throw 'Unsupported or duplicate release effect GUID.' }
        $actual=$matches[0]
        if ($actual.Name -cne $effect.Name) { throw 'Unsupported effect name.' }
        foreach ($name in @('Id','Type','StaticParams','DynamicParams','Coords')) {
            if ($actual.$name -ne $effect.$name) { throw "Unsupported release effect metadata: $name" }
        }
    }
}
function Resolve-NativeReleaseFile([string]$Root,$RelativePath) {
    if ($RelativePath -isnot [string] -or [string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath -match '[\\<>:"|?*\x00-\x1f]' -or [IO.Path]::IsPathRooted($RelativePath)) { throw 'Unsafe release file path.' }
    foreach ($part in $RelativePath.Split('/')) {
        if ($part -in @('','.','..') -or $part -match '[ .]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Unsafe release path component.' }
    }
    $full=[IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Replace('/','\')))
    Assert-SaitekSafePath $Root $full
    $full
}
function Read-NativeRelease([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Release manifest path is required.' }
    $manifestPath=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetDirectoryName($manifestPath)
    Assert-SaitekSafePath $root $manifestPath
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-NativeObjectProperties $manifest @('SchemaVersion','Product','Version','Channel','Architecture','Clsid','BinaryPath','BinarySha256',
        'OfflineComTestsPassed','OfflineProtocolTestsPassed','RegistryMetadata','SourceIdentity','Build','Files') 'release manifest'
    foreach ($name in @('Product','Version','Channel','Architecture','Clsid','BinaryPath','BinarySha256')) {
        if ($manifest.$name -isnot [string]) { throw "Release identity must be a string: $name" }
    }
    if (-not (Test-NativeInteger $manifest.SchemaVersion) -or $manifest.SchemaVersion -ne 1 -or
        $manifest.Product -cne 'SaitekNativeFfb' -or $manifest.Channel -cnotin @('private-alpha','experimental-alpha') -or
        $manifest.Architecture -cne 'x64' -or $manifest.Clsid -cne $script:NativeClsid -or
        $manifest.Version -isnot [string] -or $manifest.Version.Length -gt 100 -or
        $manifest.Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$' -or
        $manifest.BinaryPath -cne 'bin/SaitekFfbDriver.dll' -or $manifest.BinarySha256 -isnot [string] -or
        $manifest.BinarySha256 -cnotmatch '^[A-F0-9]{64}$' -or
        $manifest.OfflineComTestsPassed -isnot [bool] -or -not $manifest.OfflineComTestsPassed -or
        $manifest.OfflineProtocolTestsPassed -isnot [bool] -or -not $manifest.OfflineProtocolTestsPassed) { throw 'Unsupported release identity or missing offline test evidence.' }
    Assert-NativeReleaseMetadata $manifest.RegistryMetadata
    Assert-NativeObjectProperties $manifest.SourceIdentity @('GitCommit','Dirty','InventorySha256') 'source identity'
    if (($null -ne $manifest.SourceIdentity.GitCommit -and $manifest.SourceIdentity.GitCommit -isnot [string]) -or
        $manifest.SourceIdentity.Dirty -isnot [bool] -or $manifest.SourceIdentity.InventorySha256 -isnot [string] -or
        $manifest.SourceIdentity.InventorySha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Malformed release source identity.' }
    Assert-NativeObjectProperties $manifest.Build @('Compiler','WindowsSdk','Command') 'build identity'
    foreach ($name in @('Compiler','WindowsSdk','Command')) {
        if ($manifest.Build.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.Build.$name)) { throw 'Malformed release build identity.' }
    }
    if ($manifest.Files -isnot [array] -or $manifest.Files.Count -eq 0) { throw 'Release file inventory must be a nonempty array.' }
    $seen=@{}
    foreach ($entry in $manifest.Files) {
        Assert-NativeObjectProperties $entry @('Path','Length','Sha256') 'release file entry'
        $full=Resolve-NativeReleaseFile $root $entry.Path
        if ($full -eq $manifestPath -or $seen.ContainsKey($full)) { throw 'Duplicate release path or manifest self-reference.' }
        $seen[$full]=$entry
        if (-not (Test-NativeInteger $entry.Length) -or $entry.Length -lt 0 -or $entry.Sha256 -isnot [string] -or
            $entry.Sha256 -cnotmatch '^[A-F0-9]{64}$' -or -not [IO.File]::Exists($full)) { throw 'Missing release file or invalid file identity.' }
        if ((Get-Item -LiteralPath $full -Force).Length -ne $entry.Length -or (Get-NativeHash $full) -cne $entry.Sha256) { throw "Release file length/hash mismatch: $($entry.Path)" }
    }
    # Walk one directory at a time so a junction is refused before enumeration.
    # Unlisted files are not part of the frozen release inventory.
    $directories=New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Enqueue($root)
    while ($directories.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $directories.Dequeue() -Force)) {
            Assert-SaitekSafePath $root $item.FullName
            if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
            elseif ($item.FullName -ne $manifestPath -and -not $seen.ContainsKey($item.FullName)) { throw 'Release contains an unlisted file.' }
        }
    }
    $binary=Resolve-NativeReleaseFile $root $manifest.BinaryPath
    if (-not $seen.ContainsKey($binary) -or $seen[$binary].Sha256 -cne $manifest.BinarySha256) { throw 'Release DLL must appear once with the declared identity.' }
    Assert-NativeBinary $binary $manifest.BinarySha256
    Assert-NativeEffectMaskCompatibility
    [pscustomobject]@{BinaryPath=$binary;BinarySha256=$manifest.BinarySha256;RegistryMetadata=$manifest.RegistryMetadata;Version=$manifest.Version}
}
function Read-NativeInstallInput([string]$Artifact,[string]$Release) {
    if ($Release) { Read-NativeRelease $Release } else { Read-NativeBuild $Artifact }
}
function Assert-NativeNoLegacyTransaction {
    # Read only the private legacy backup location; no legacy payload, registry
    # context, repair implementation or mutation is imported by the native kit.
    $legacy=[pscustomobject]@{Root=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SaitekFfbRepair')}
    if (@(Get-SaitekPendingBackupIds $legacy).Count) {
        throw 'An active legacy repair transaction exists. Restore it using the privately retained legacy recovery tool before applying the native driver.'
    }
}
function New-NativeTree { [pscustomobject]@{Exists=$true;Values=@();Children=@()} }
function Test-NativeRegistryTreeEqual($Left,$Right) {
    if ($Left.Exists -ne $Right.Exists -or @($Left.Values).Count -ne @($Right.Values).Count -or @($Left.Children).Count -ne @($Right.Children).Count) { return $false }
    # Registry key/value names are case-insensitive and retain the spelling used
    # when first created. String contents, binary bytes and value kinds are exact.
    foreach ($value in @($Left.Values)) {
        $match=@($Right.Values | Where-Object {[string]::Equals($_.Name,$value.Name,[StringComparison]::OrdinalIgnoreCase)})
        if ($match.Count -ne 1 -or $match[0].Kind -cne $value.Kind -or
            (ConvertTo-Json -InputObject $match[0].Data -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $value.Data -Depth 5 -Compress)) { return $false }
    }
    foreach ($child in @($Left.Children)) {
        $match=@($Right.Children | Where-Object {[string]::Equals($_.Name,$child.Name,[StringComparison]::OrdinalIgnoreCase)})
        if ($match.Count -ne 1 -or -not (Test-NativeRegistryTreeEqual $child.Tree $match[0].Tree)) { return $false }
    }
    return $true
}
function Convert-NativeDwords([int[]]$Values) {
    $bytes=New-Object 'System.Collections.Generic.List[byte]'
    foreach ($value in $Values) { $bytes.AddRange([BitConverter]::GetBytes($value)) }
    [Convert]::ToBase64String($bytes.ToArray())
}
function Get-NativeDesiredTrees($Context,[string]$Hash) {
    Assert-NativeEffectMaskCompatibility
    $metadata=Get-NativeExpectedMetadata
    $oem=New-NativeTree
    Set-SaitekTreeValue $oem 'CLSID' 'String' $script:NativeClsid
    Set-SaitekTreeValue $oem 'Attributes' 'Binary' (Convert-NativeDwords @($metadata.DeviceFlags,1000,1000))
    $effects=New-NativeTree
    foreach ($effect in $metadata.Effects) {
        $tree=New-NativeTree
        Set-SaitekTreeValue $tree '' 'String' $effect.Name
        Set-SaitekTreeValue $tree 'Attributes' 'Binary' (Convert-NativeDwords @($effect.Id,$effect.Type,$effect.StaticParams,$effect.DynamicParams,$effect.Coords))
        $effects.Children+= [pscustomobject]@{Name=$effect.Guid;Tree=$tree}
    }
    foreach ($guid in @(Get-NativeMaskedEffects)) {
        $tree=New-NativeTree
        Set-SaitekTreeValue $tree '' 'String' 'Unsupported inherited effect (disabled)'
        # Coords=0 makes this Windows reader skip the entry. The unmapped ID
        # also prevents a legacy barrier alias (ID0x40) becoming our spring.
        Set-SaitekTreeValue $tree 'Attributes' 'Binary' (Convert-NativeDwords @(-1,0,0,0,0))
        $effects.Children+= [pscustomobject]@{Name=$guid;Tree=$tree}
    }
    $effects.Children=@($effects.Children | Sort-Object Name)
    $oem.Children=@([pscustomobject]@{Name='Effects';Tree=$effects})
    $class=Get-SaitekRegistryTree $Context.User $Context.ClassPath; $class.Exists=$true
    $inproc=New-NativeTree
    Set-SaitekTreeValue $inproc '' 'String' (Get-NativeBinaryPath $Context $Hash)
    Set-SaitekTreeValue $inproc 'ThreadingModel' 'String' 'Both'
    $class.Children=@(@($class.Children | Where-Object {$_.Name -ne 'InprocServer32'})+@([pscustomobject]@{Name='InprocServer32';Tree=$inproc}) | Sort-Object Name)
    [pscustomobject]@{Oem=$oem;Class=$class}
}
function Read-NativeBackup($Context,[string]$Id) {
    $directory=Get-SaitekBackupDirectory $Context $Id
    $path=Join-Path $directory 'manifest.json'; Assert-SaitekSafePath $Context.Root $path
    $m=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($m.Schema -ne 1 -or $m.Product -cne 'SaitekNativeFfb' -or $m.BackupId -ne $Id -or $m.UserSid -ne $Context.Sid -or
        $m.RegistryView -cne 'Registry64' -or $m.Device -cne 'VID_06A3&PID_FFB5' -or $m.Clsid -ne $script:NativeClsid -or
        $m.BinaryExisted -isnot [bool] -or @($m.Registry).Count -ne 2) { throw 'Native backup identity/schema mismatch.' }
    if ($m.BinaryPath -ne (Get-NativeBinaryPath $Context $m.BinaryHash)) { throw 'Native backup binary path mismatch.' }
    $targets=@($Context.UserOemPath,$Context.ClassPath)
    for ($i=0;$i -lt 2;$i++) {
        if ($m.Registry[$i].Path -ne $targets[$i]) { throw 'Native backup registry target mismatch.' }
        Assert-SaitekTree $m.Registry[$i].Before
        foreach ($parent in @($m.Registry[$i].MissingParents)) {
            Assert-SaitekRegistryPath $parent
            if (-not $targets[$i].StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Native backup contains an unrelated parent key.' }
        }
    }
    $m
}
function Restore-NativeBackup($Context,$Manifest) {
    $failures=@()
    foreach ($item in @($Manifest.Registry)) {
        try { Set-SaitekRegistryTree $Context.User $item.Path $item.Before }
        catch { $failures+=$_.Exception.Message }
    }
    if ($failures.Count) { throw ('Registry rollback incomplete: '+($failures -join '; ')) }
    foreach ($item in @($Manifest.Registry)) {
        foreach ($path in @($item.MissingParents | Sort-Object Length -Descending)) {
            $key=$Context.User.OpenSubKey($path)
            if ($null -ne $key) {
                try { $empty=$key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0 } finally { $key.Dispose() }
                if ($empty) { $Context.User.DeleteSubKey($path,$false) }
            }
        }
    }
    $retained=$false
    if (-not $Manifest.BinaryExisted -and (Test-Path -LiteralPath $Manifest.BinaryPath)) {
        Assert-SaitekSafePath $Context.Root $Manifest.BinaryPath
        # A modified staged binary is preserved rather than deleted. Registry
        # recovery still completes independently of current build/file contents.
        if ((Get-NativeHash $Manifest.BinaryPath) -ceq $Manifest.BinaryHash) { Remove-Item -LiteralPath $Manifest.BinaryPath -Force }
        else { $retained=$true }
    }
    $retained
}
function Invoke-NativeApplyTransaction($Context,$Build) {
    Assert-NativeBinary $Build.BinaryPath $Build.BinarySha256
    $destination=Get-NativeBinaryPath $Context $Build.BinarySha256
    $desired=Get-NativeDesiredTrees $Context $Build.BinarySha256
    $binaryExisted=Test-Path -LiteralPath $destination
    if ($binaryExisted) { Assert-NativeBinary $destination $Build.BinarySha256 }
    $pending=@(Get-SaitekPendingBackupIds $Context)
    $matches=$binaryExisted -and (Test-NativeRegistryTreeEqual $desired.Oem (Get-SaitekRegistryTree $Context.User $Context.UserOemPath)) -and
        (Test-NativeRegistryTreeEqual $desired.Class (Get-SaitekRegistryTree $Context.User $Context.ClassPath))
    if ($pending.Count) {
        if ($pending.Count -eq 1 -and $matches) {
            $existing=Read-NativeBackup $Context $pending[0]
            if ($existing.BinaryHash -ceq $Build.BinarySha256 -and (Test-Path -LiteralPath (Join-Path (Get-SaitekBackupDirectory $Context $pending[0]) 'applied.json'))) {
                return [pscustomobject]@{Status='AlreadyApplied';BackupId=$pending[0];BinaryPath=$destination}
            }
        }
        throw 'An active or interrupted native installation exists. Restore it before applying another build.'
    }
    if ($matches) { return [pscustomobject]@{Status='AlreadyConfigured';BackupId=$null;BinaryPath=$destination} }
    $id=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N')
    $directory=Get-SaitekBackupDirectory $Context $id
    $m=[pscustomobject]@{
        Schema=1;Product='SaitekNativeFfb';BackupId=$id;CreatedUtc=[DateTime]::UtcNow.ToString('o');UserSid=$Context.Sid
        RegistryView='Registry64';Device='VID_06A3&PID_FFB5';Clsid=$script:NativeClsid
        BinaryHash=$Build.BinarySha256;BinaryPath=$destination;BinaryExisted=[bool]$binaryExisted
        EffectMaskDInputHash=$script:NativeMaskDInputHash
        Registry=@(
            [pscustomobject]@{Path=$Context.UserOemPath;Before=(Get-SaitekRegistryTree $Context.User $Context.UserOemPath);MissingParents=@(Get-SaitekMissingParents $Context $Context.UserOemPath)},
            [pscustomobject]@{Path=$Context.ClassPath;Before=(Get-SaitekRegistryTree $Context.User $Context.ClassPath);MissingParents=@(Get-SaitekMissingParents $Context $Context.ClassPath)}
        )
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Write-SaitekNewJson (Join-Path $directory 'manifest.json') $m
    $m=Read-NativeBackup $Context $id
    try {
        if (-not $binaryExisted) { [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null; [IO.File]::Copy($Build.BinaryPath,$destination,$false) }
        Assert-NativeBinary $destination $Build.BinarySha256
        Set-SaitekRegistryTree $Context.User $Context.UserOemPath $desired.Oem
        Set-SaitekRegistryTree $Context.User $Context.ClassPath $desired.Class
        if (-not (Test-NativeRegistryTreeEqual $desired.Oem (Get-SaitekRegistryTree $Context.User $Context.UserOemPath)) -or
            -not (Test-NativeRegistryTreeEqual $desired.Class (Get-SaitekRegistryTree $Context.User $Context.ClassPath))) { throw 'Native registry read-back verification failed.' }
        Write-SaitekMarker $Context $id 'applied.json'
        [pscustomobject]@{Status='Applied';BackupId=$id;BinaryPath=$destination;BackupDirectory=$directory}
    } catch {
        $cause=$_.Exception.Message
        try { Restore-NativeBackup $Context $m | Out-Null; Write-SaitekMarker $Context $id 'rolled-back.json' }
        catch { throw "Native Apply failed: $cause. AUTOMATIC ROLLBACK INCOMPLETE: $($_.Exception.Message). Backup: $directory" }
        throw "Native Apply failed and original registry state was restored: $cause. Backup: $directory"
    }
}
function Invoke-NativeRestoreTransaction($Context,[string]$Id) {
    $m=Read-NativeBackup $Context $Id
    $directory=Get-SaitekBackupDirectory $Context $Id
    if ((Test-Path -LiteralPath (Join-Path $directory 'restored.json')) -or (Test-Path -LiteralPath (Join-Path $directory 'rolled-back.json'))) { return [pscustomobject]@{Status='AlreadyRestored';BackupId=$Id} }
    $pending=@(Get-SaitekPendingBackupIds $Context)
    if ($pending.Count -ne 1 -or $pending[0] -ne $Id) { throw 'Native Restore requires the sole active transaction.' }
    $retained=Restore-NativeBackup $Context $m
    Write-SaitekMarker $Context $Id 'restored.json'
    [pscustomobject]@{Status='Restored';BackupId=$Id;ModifiedBinaryRetained=$retained}
}
if ($MyInvocation.InvocationName -ne '.') {
    $context=New-NativeContext; $mutex=$null; $held=$false
    try {
        if ($Mode -eq 'Inspect') {
            [pscustomobject]@{Mode='Inspect';Clsid=$script:NativeClsid;Architecture='x64';UserSid=$context.Sid;StorageRoot=$context.Root;
                ActiveBackups=@(Get-SaitekPendingBackupIds $context);Oem=(Get-SaitekRegistryTree $context.User $context.UserOemPath);
                NativeClass=(Get-SaitekRegistryTree $context.User $context.ClassPath);Scope='Only this user native COM/OEMForceFeedback; x64 FFB support; OEM routing shared across bitness.'}
        } else {
            if ($Mode -eq 'Apply') { $build=Read-NativeInstallInput $ArtifactManifest $ReleaseManifest; $description='Install tested x64 FFB driver and narrow per-user registration with immutable rollback backup' }
            else {
                if (-not $BackupId) { $pending=@(Get-SaitekPendingBackupIds $context); if ($pending.Count -ne 1) { throw 'Specify BackupId or have exactly one active native transaction.' }; $BackupId=$pending[0] }
                Read-NativeBackup $context $BackupId | Out-Null; $description="Restore exact per-user state from native backup $BackupId"
            }
            if ($PSCmdlet.ShouldProcess('Saitek Cyborg Evo Force VID_06A3&PID_FFB5 (current user, native x64)',$description)) {
                Assert-SaitekApplicationsClosed
                $running=@(Get-Process | Where-Object {$_.ProcessName -in @('DriverTests','HidPidDeviceTests')})
                if ($running.Count) { throw 'Close driver test processes before installation.' }
                $mutex=New-Object Threading.Mutex($false,('Local\SaitekFfbRepair-'+$context.Sid))
                try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
                if (-not $held) { throw 'Another FFB installation/repair is running.' }
                if ($Mode -eq 'Apply') {
                    Assert-NativeNoLegacyTransaction
                    # Re-read after taking the lock: do not act on a stale build.
                    $build=Read-NativeInstallInput $ArtifactManifest $ReleaseManifest
                    Invoke-NativeApplyTransaction $context $build
                } else { Invoke-NativeRestoreTransaction $context $BackupId }
            }
        }
    } finally { if ($held) { $mutex.ReleaseMutex() }; if ($null -ne $mutex) { $mutex.Dispose() }; $context.User.Dispose() }
}
