# Native installer tests: only disposable HKCU Software and workspace test files.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../tools/Install-SaitekFfbDriver.ps1')
$script:nativeChecks=0
function Check([bool]$Condition,[string]$Message) { $script:nativeChecks++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Reject([scriptblock]$Body,[string]$Message) { $rejected=$false; try { & $Body | Out-Null } catch {$rejected=$true}; Check $rejected $Message }
$testId=[Guid]::NewGuid().ToString('N')
$testRegistryRoot="Software\SaitekNativeFfbTests\$testId"
$testFileRoot=Join-Path $script:NativeWorkspace "out\installer-tests-$testId"
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry64')
$context=[pscustomobject]@{User=$base;UserOemPath="$testRegistryRoot\Device\OEMForceFeedback";ClassPath="$testRegistryRoot\Classes\$script:NativeClsid";Root=(Join-Path $testFileRoot 'store');Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
try {
    Assert-SaitekSafePath $script:NativeWorkspace $testFileRoot
    [IO.Directory]::CreateDirectory($testFileRoot) | Out-Null
    $build=Read-NativeBuild (Join-Path $script:NativeWorkspace 'out\driver\build-manifest.json')
    Check ($build.RegistryMetadata.DeviceFlags -eq 0) 'reserved device flags zero'
    # Typed original state, including values not used by the native installer.
    $key=$base.CreateSubKey($context.UserOemPath)
    $key.SetValue('CLSID','original','String');$key.SetValue('Expand','%TEMP%\literal','ExpandString')
    $key.SetValue('Data',[byte[]]@(0,1,255),'Binary');$key.SetValue('Multi',[string[]]@('one','two'),'MultiString')
    $key.SetValue('DWord',[int]-1,'DWord');$key.SetValue('QWord',[long]::MaxValue,'QWord');$key.Dispose()
    # Real legacy installations preserve this mixed-case GUID spelling. Windows
    # key identity ignores case, but opening it with uppercase does not rename it.
    $key=$base.CreateSubKey($context.UserOemPath+'\Effects\{B3873612-BCB7-11d0-A156-524153480000}')
    $key.SetValue('','Axis Barrier','String');$key.SetValue('Attributes',[byte[]](0..19),'Binary');$key.Dispose()
    $original=Get-SaitekRegistryTree $base $context.UserOemPath
    $nameVariant=($original|ConvertTo-Json -Depth 100)|ConvertFrom-Json
    $nameVariant.Values[0].Name=$nameVariant.Values[0].Name.ToLowerInvariant()
    $nameVariant.Children[0].Name=$nameVariant.Children[0].Name.ToLowerInvariant()
    $nameVariant.Children[0].Tree.Children[0].Name=$nameVariant.Children[0].Tree.Children[0].Name.ToUpperInvariant()
    Check (Test-NativeRegistryTreeEqual $original $nameVariant) 'registry name casing does not change identity'
    $textValue=@($nameVariant.Values|Where-Object Name -eq 'CLSID')[0];$textValue.Data='ORIGINAL'
    Check (-not (Test-NativeRegistryTreeEqual $original $nameVariant)) 'string value contents remain case-sensitive'
    $textValue.Data='original';$textValue.Kind='ExpandString'
    Check (-not (Test-NativeRegistryTreeEqual $original $nameVariant)) 'value kinds remain exact'
    $parent=$base.CreateSubKey("$testRegistryRoot\Device");$parent.SetValue('CalibrationSentinel','unchanged','String');$parent.Dispose()
    $result=Invoke-NativeApplyTransaction $context $build
    Check ($result.Status -eq 'Applied') 'apply transaction succeeds'
    $applied=Get-SaitekRegistryTree $base $context.UserOemPath
    Check (@($applied.Children[0].Tree.Children).Count -eq 16) 'eight supported entries plus eight inherited-effect masks'
    foreach ($guid in @(Get-NativeMaskedEffects)) {
        $effect=@($applied.Children[0].Tree.Children|Where-Object Name -eq $guid)[0]
        $binary=[Convert]::FromBase64String(@($effect.Tree.Values|Where-Object Name -eq 'Attributes')[0].Data)
        Check ($binary.Length -eq 20 -and [BitConverter]::ToUInt32($binary,0) -eq [uint32]::MaxValue -and [BitConverter]::ToUInt32($binary,16) -eq 0) 'unsupported inherited GUID has unmapped ID and zero coordinate mask'
    }
    $savedMaskHash=$script:NativeMaskDInputHash
    try {$script:NativeMaskDInputHash='0'*64;Reject {Assert-NativeEffectMaskCompatibility} 'untested DirectInput reader is refused'}
    finally {$script:NativeMaskDInputHash=$savedMaskHash}
    $attrs=@($applied.Values|Where-Object Name -eq 'Attributes')[0]
    Check ([BitConverter]::ToUInt32([Convert]::FromBase64String($attrs.Data),0) -eq 0) 'written reserved flags zero'
    $key=$base.OpenSubKey("$testRegistryRoot\Device");try {Check ($key.GetValue('CalibrationSentinel') -eq 'unchanged') 'parent and calibration untouched'} finally {$key.Dispose()}
    $manifestPath=Join-Path $result.BackupDirectory 'manifest.json';$immutable=[IO.File]::ReadAllText($manifestPath)
    $again=Invoke-NativeApplyTransaction $context $build
    Check ($again.Status -eq 'AlreadyApplied' -and $again.BackupId -eq $result.BackupId -and [IO.File]::ReadAllText($manifestPath) -ceq $immutable) 'repeat apply preserves original backup'
    foreach ($variant in @('sid','path','hash','registry','parent')) {
        $m=$immutable|ConvertFrom-Json
        switch ($variant) {
            sid {$m.UserSid='S-1-0-0'}
            path {$m.BinaryPath=Join-Path $testFileRoot 'outside.dll'}
            hash {$m.BinaryHash='..\bad'}
            registry {$m.Registry[0].Path='Software\Unrelated'}
            parent {$m.Registry[0].MissingParents=@('Software\Unrelated')}
        }
        [IO.File]::WriteAllText($manifestPath,($m|ConvertTo-Json -Depth 100))
        Reject {Read-NativeBackup $context $result.BackupId} "tampered backup rejected: $variant"
        [IO.File]::WriteAllText($manifestPath,$immutable)
    }
    $savedMaskHash=$script:NativeMaskDInputHash
    try {$script:NativeMaskDInputHash='0'*64;$restored=Invoke-NativeRestoreTransaction $context $result.BackupId}
    finally {$script:NativeMaskDInputHash=$savedMaskHash}
    Check ($restored.Status -eq 'Restored') 'restore remains available when Windows reader identity differs'
    Check ($restored.Status -eq 'Restored' -and (Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath))) 'typed original OEM tree restored'
    Check (-not (Get-SaitekRegistryTree $base $context.ClassPath).Exists -and -not (Test-Path -LiteralPath $result.BinaryPath)) 'original class absence and staged file restored'
    Check ((Invoke-NativeRestoreTransaction $context $result.BackupId).Status -eq 'AlreadyRestored') 'repeat restore idempotent'
    # Interrupted/failed apply must restore exact snapshots, without overwriting
    # the successful first transaction. Fault injection only affects test paths.
    $script:nativeOriginalSetter=(Get-Command Set-SaitekRegistryTree).ScriptBlock
    $script:nativeFaultPath=$context.ClassPath;$script:nativeFaultArmed=$true
    function Set-SaitekRegistryTree($Base,[string]$Path,$Tree) {
        if ($script:nativeFaultArmed -and $Path -eq $script:nativeFaultPath) {$script:nativeFaultArmed=$false;throw 'Injected test write failure'}
        & $script:nativeOriginalSetter $Base $Path $Tree
    }
    Reject {Invoke-NativeApplyTransaction $context $build} 'partial apply fails visibly'
    Set-Item -LiteralPath Function:\Set-SaitekRegistryTree -Value $script:nativeOriginalSetter
    Check ((Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath)) -and -not (Get-SaitekRegistryTree $base $context.ClassPath).Exists) 'automatic rollback after first target changed'
    Check (@(Get-SaitekPendingBackupIds $context).Count -eq 0) 'rolled-back transaction is not active'
    $result=Invoke-NativeApplyTransaction $context $build
    # Restore must work after a rebuild/source removal and preserve a tampered
    # stage file rather than deleting bytes it no longer recognizes.
    [IO.File]::WriteAllText($result.BinaryPath,'modified test artifact')
    $restored=Invoke-NativeRestoreTransaction $context $result.BackupId
    Check ($restored.Status -eq 'Restored' -and $restored.ModifiedBinaryRetained -and (Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath))) 'restore independent current DLL; modified file retained'
    Remove-Item -LiteralPath $result.BinaryPath -Force
    $modified=($build|ConvertTo-Json -Depth 10)|ConvertFrom-Json
    $testBuildPath=Join-Path $testFileRoot 'build.json'
    foreach ($variant in @('test','source','class','binary','metadata')) {
        $modified=($build|ConvertTo-Json -Depth 10)|ConvertFrom-Json
        switch ($variant) {
            test {$modified.OfflineProtocolTestsPassed=$false}
            source {$modified.SourceHashes[0].Sha256=('0'*64)}
            class {$modified.Clsid='{00000000-0000-0000-0000-000000000000}'}
            binary {$modified.BinarySha256=('0'*64)}
            metadata {$modified.RegistryMetadata.DeviceFlags=65280}
        }
        [IO.File]::WriteAllText($testBuildPath,($modified|ConvertTo-Json -Depth 10))
        Reject {Read-NativeBuild $testBuildPath} "tampered build rejected: $variant"
    }
    $production=New-NativeContext
    try {
        $prodOem=Get-SaitekRegistryTree $production.User $production.UserOemPath
        $prodClass=Get-SaitekRegistryTree $production.User $production.ClassPath
        $storageExisted=Test-Path -LiteralPath $production.Root
        & (Join-Path $script:NativeWorkspace 'tools\Install-SaitekFfbDriver.ps1') -Mode Apply -ArtifactManifest (Join-Path $script:NativeWorkspace 'out\driver\build-manifest.json') -WhatIf
        Check ((Test-SaitekTreeEqual $prodOem (Get-SaitekRegistryTree $production.User $production.UserOemPath)) -and
            (Test-SaitekTreeEqual $prodClass (Get-SaitekRegistryTree $production.User $production.ClassPath)) -and
            $storageExisted -eq (Test-Path -LiteralPath $production.Root)) 'public WhatIf leaves production registry and storage unchanged'
    } finally {$production.User.Dispose()}
    Write-Output "PASS $script:nativeChecks isolated native installer checks; no production mutations."
} finally {
    if ($testRegistryRoot -notmatch '^Software\\SaitekNativeFfbTests\\[a-f0-9]{32}$') {throw 'Unsafe test registry cleanup path'}
    $base.DeleteSubKeyTree($testRegistryRoot,$false);$base.Dispose()
    Assert-SaitekSafePath $script:NativeWorkspace $testFileRoot
    if ([IO.Path]::GetFileName($testFileRoot) -cne "installer-tests-$testId") {throw 'Unsafe test file cleanup path'}
    if (Test-Path -LiteralPath $testFileRoot) {Remove-Item -LiteralPath $testFileRoot -Recurse -Force}
}
