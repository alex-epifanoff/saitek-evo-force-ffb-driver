#requires -Version 5.1
# Offline package validation and disposable HKCU transaction tests. No DLL is
# loaded, no device is opened, and no production Apply/Restore is invoked.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../tools/Install-SaitekFfbDriver.ps1')
$script:releaseChecks=0
function Check-Release([bool]$Condition,[string]$Message) {
    $script:releaseChecks++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Reject-Release([scriptblock]$Body,[string]$Message) {
    $rejected=$false
    try { & $Body | Out-Null } catch { $rejected=$true }
    Check-Release $rejected $Message
}
function Write-ReleaseFixture($Manifest) {
    [IO.File]::WriteAllText($releasePath,($Manifest | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
}
$workspace=$script:NativeWorkspace
$testId=[Guid]::NewGuid().ToString('N')
$testRoot=Join-Path $workspace "out\release-installer-tests-$testId"
$registryRoot="Software\SaitekReleaseInstallerTests\$testId"
$base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry64')
$context=[pscustomobject]@{User=$base;UserOemPath="$registryRoot\Device\OEMForceFeedback";ClassPath="$registryRoot\Classes\$script:NativeClsid";
    Root=(Join-Path $testRoot 'store');Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
$junction=$null
$originalSetter=$null
try {
    Assert-SaitekSafePath $workspace $testRoot
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $sourceBuild=Read-NativeBuild (Join-Path $workspace 'out\driver\build-manifest.json')
    $originalPackage=Join-Path $testRoot 'original package'
    $package=Join-Path $testRoot 'relocated package with spaces'
    [IO.Directory]::CreateDirectory((Join-Path $originalPackage 'bin')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $originalPackage 'tools')) | Out-Null
    [IO.File]::Copy($sourceBuild.BinaryPath,(Join-Path $originalPackage 'bin\SaitekFfbDriver.dll'))
    foreach ($name in @('Install-SaitekFfbDriver.ps1','SaitekFfb.Common.ps1')) {
        [IO.File]::Copy((Join-Path $workspace "tools\$name"),(Join-Path $originalPackage "tools\$name"))
    }
    # Listed script text is hashed as bytes, never executed by validation.
    [IO.File]::WriteAllText((Join-Path $originalPackage 'must-not-execute.ps1'),"throw 'Payload scripts must not execute'")
    [IO.File]::WriteAllText((Join-Path $originalPackage 'README.md'),'Disposable original-driver release fixture.')
    $filePaths=@('bin/SaitekFfbDriver.dll','tools/Install-SaitekFfbDriver.ps1','tools/SaitekFfb.Common.ps1','must-not-execute.ps1','README.md')
    $fixture=[pscustomobject]@{
        SchemaVersion=1;Product='SaitekNativeFfb';Version='0.1.0-alpha.2';Channel='experimental-alpha';Architecture='x64';Clsid=$script:NativeClsid
        BinaryPath='bin/SaitekFfbDriver.dll';BinarySha256=$sourceBuild.BinarySha256;OfflineComTestsPassed=$true;OfflineProtocolTestsPassed=$true
        RegistryMetadata=(Get-NativeExpectedMetadata);SourceIdentity=[pscustomobject]@{GitCommit=$null;Dirty=$true;InventorySha256=('A'*64)}
        Build=[pscustomobject]@{Compiler='Existing MSVC fixture';WindowsSdk='Existing Windows SDK fixture';Command='tools/Build-Driver.ps1'}
        Files=@($filePaths | ForEach-Object { $file=Join-Path $originalPackage $_; [pscustomobject]@{Path=$_;Length=(Get-Item -LiteralPath $file).Length;Sha256=(Get-NativeHash $file)} })
    }
    $releasePath=Join-Path $originalPackage 'release-manifest.json'
    Write-ReleaseFixture $fixture
    # A move is allowed only between these two verified disposable directories.
    Assert-SaitekSafePath $testRoot $originalPackage
    Assert-SaitekSafePath $testRoot $package
    Move-Item -LiteralPath $originalPackage -Destination $package
    $releasePath=Join-Path $package 'release-manifest.json'
    $pristine=[IO.File]::ReadAllText($releasePath)
    Check-Release (-not (Test-Path -LiteralPath $originalPackage) -and -not (Test-Path -LiteralPath (Join-Path $package 'native'))) 'package relocated without sources'
    $build=Read-NativeRelease $releasePath
    Check-Release ($build.BinaryPath -eq (Join-Path $package 'bin\SaitekFfbDriver.dll') -and $build.BinarySha256 -ceq $sourceBuild.BinarySha256) 'release adapter resolves relocated DLL'
    $legacy=$pristine | ConvertFrom-Json
    $legacy.Version='0.1.0-alpha.1';$legacy.Channel='private-alpha'
    Write-ReleaseFixture $legacy
    $legacyBuild=Read-NativeRelease $releasePath
    Check-Release ($legacyBuild.BinarySha256 -ceq $sourceBuild.BinarySha256) 'previous private alpha remains readable'
    Write-ReleaseFixture ($pristine | ConvertFrom-Json)
    # Run the copied installer in a clean process whose workspace is the package.
    # Only Common is present alongside it; no legacy repair or source build exists.
    $runner=Join-Path $testRoot 'validate-copied.ps1'
    [IO.File]::WriteAllText($runner,@'
param([string]$Package)
$ErrorActionPreference='Stop'
. (Join-Path $Package 'tools\Install-SaitekFfbDriver.ps1')
$build=Read-NativeRelease (Join-Path $Package 'release-manifest.json')
if ($script:NativeWorkspace -ne $Package -or -not $build.BinaryPath.StartsWith($Package+'\')) { throw 'Relocation was not honored.' }
if (Get-Command Assert-SaitekBinary -ErrorAction SilentlyContinue) { throw 'Legacy code was imported.' }
'PASS standalone source-free package validation'
'@)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Package $package
    Check-Release ($LASTEXITCODE -eq 0) 'copied installer works in a clean source-free process'
    $key=$base.CreateSubKey($context.UserOemPath)
    $key.SetValue('','original default','String');$key.SetValue('Expand','%TEMP%\literal','ExpandString')
    $key.SetValue('None',[byte[]]@(1,0,255),'None');$key.SetValue('Binary',[byte[]]@(2,4,6),'Binary')
    $key.SetValue('Multi',[string[]]@('one','two'),'MultiString');$key.SetValue('EmptyMulti',[string[]]@(),'MultiString')
    $key.SetValue('DWord',[int]-1,'DWord');$key.SetValue('QWord',[long]::MinValue,'QWord')
    $child=$key.CreateSubKey('EmptyChild');$child.Dispose();$key.Dispose()
    $key=$base.CreateSubKey("$registryRoot\Device\Sibling");$key.SetValue('Sentinel','unchanged','String');$key.Dispose()
    $original=Get-SaitekRegistryTree $base $context.UserOemPath
    $sibling=Get-SaitekRegistryTree $base "$registryRoot\Device\Sibling"
    foreach ($variant in @('schema','schema-type','product','version','version-leading-zero','channel','architecture','clsid','com-false','protocol-false','boolean-string',
        'binary-path','binary-hash','flags','period','effect-name','effect-guid','effect-coords','effect-type','effect-extra','metadata-extra',
        'source-dirty','source-hash','build-type','duplicate','duplicate-case','traversal','rooted','unc','drive','backslash','empty-component','dot-component',
        'trailing-dot','device-name','ads','length','length-type','hash','missing','no-files','self-reference','no-dll','extra-field')) {
        $m=$pristine | ConvertFrom-Json
        switch ($variant) {
            schema {$m.SchemaVersion=2}
            schema-type {$m.SchemaVersion='1'}
            product {$m.Product='OtherProduct'}
            version {$m.Version='../0.1.0'}
            version-leading-zero {$m.Version='01.1.0'}
            channel {$m.Channel='stable'}
            architecture {$m.Architecture='x86'}
            clsid {$m.Clsid='{00000000-0000-0000-0000-000000000000}'}
            com-false {$m.OfflineComTestsPassed=$false}
            protocol-false {$m.OfflineProtocolTestsPassed=$false}
            boolean-string {$m.OfflineComTestsPassed='true'}
            binary-path {$m.BinaryPath='other.dll'}
            binary-hash {$m.BinarySha256='0'*64}
            flags {$m.RegistryMetadata.DeviceFlags=1}
            period {$m.RegistryMetadata.FFSamplePeriod=1001}
            effect-name {$m.RegistryMetadata.Effects[0].Name='Different'}
            effect-guid {$m.RegistryMetadata.Effects[0].Guid=$m.RegistryMetadata.Effects[1].Guid}
            effect-coords {$m.RegistryMetadata.Effects[0].Coords=0}
            effect-type {$m.RegistryMetadata.Effects[0].Id='38'}
            effect-extra {$m.RegistryMetadata.Effects+=@($m.RegistryMetadata.Effects[0])}
            metadata-extra {$m.RegistryMetadata | Add-Member NoteProperty Unreviewed 1}
            source-dirty {$m.SourceIdentity.Dirty='true'}
            source-hash {$m.SourceIdentity.InventorySha256='not-a-hash'}
            build-type {$m.Build.Compiler=7}
            duplicate {$m.Files+=@($m.Files[0])}
            duplicate-case {$entry=($m.Files[0]|ConvertTo-Json)|ConvertFrom-Json;$entry.Path=$entry.Path.ToUpperInvariant();$m.Files+=@($entry)}
            traversal {$m.Files[0].Path='../escape.dll'}
            rooted {$m.Files[0].Path='/escape.dll'}
            unc {$m.Files[0].Path='//server/share/file'}
            drive {$m.Files[0].Path='C:/escape.dll'}
            backslash {$m.Files[0].Path='bin\SaitekFfbDriver.dll'}
            empty-component {$m.Files[0].Path='bin//SaitekFfbDriver.dll'}
            dot-component {$m.Files[0].Path='bin/./SaitekFfbDriver.dll'}
            trailing-dot {$m.Files[0].Path='bin./SaitekFfbDriver.dll'}
            device-name {$m.Files[0].Path='bin/CON.dll'}
            ads {$m.Files[0].Path='bin/SaitekFfbDriver.dll:stream'}
            length {$m.Files[0].Length++}
            length-type {$m.Files[0].Length=[string]$m.Files[0].Length}
            hash {$m.Files[0].Sha256='0'*64}
            missing {$m.Files[0].Path='bin/missing.dll'}
            no-files {$m.Files=@()}
            self-reference {$m.Files[0].Path='release-manifest.json'}
            no-dll {$m.Files=@($m.Files | Where-Object Path -ne 'bin/SaitekFfbDriver.dll')}
            extra-field {$m | Add-Member NoteProperty UnknownPolicy 'allow'}
        }
        Write-ReleaseFixture $m
        Reject-Release {Read-NativeRelease $releasePath} "invalid release refused: $variant"
    }
    # PowerShell comparison operators filter collections. Every schema string
    # must refuse even singleton/repeated arrays of otherwise valid values.
    foreach ($field in @('Manifest.Product','Manifest.Version','Manifest.Channel','Manifest.Architecture','Manifest.Clsid','Manifest.BinaryPath','Manifest.BinarySha256',
        'Effect.Guid','Effect.Name','SourceIdentity.GitCommit','SourceIdentity.InventorySha256','Build.Compiler','Build.WindowsSdk','Build.Command','File.Path','File.Sha256')) {
        foreach ($shape in @('singleton','repeated','empty')) {
            $m=$pristine | ConvertFrom-Json
            $parts=$field.Split('.')
            switch ($parts[0]) {
                Manifest {$target=$m}
                Effect {$target=$m.RegistryMetadata.Effects[0]}
                SourceIdentity {$target=$m.SourceIdentity}
                Build {$target=$m.Build}
                File {$target=$m.Files[0]}
            }
            $property=$parts[1];$value=$target.$property
            if ($null -eq $value) {$value='A'*40}
            switch ($shape) {
                singleton {$target.$property=@($value)}
                repeated {$target.$property=@($value,$value)}
                empty {$target.$property=@()}
            }
            Write-ReleaseFixture $m
            Reject-Release {Read-NativeRelease $releasePath} "schema string rejects $shape array: $field"
        }
    }
    foreach ($shape in @('null','string','array','missing-property')) {
        $m=$pristine | ConvertFrom-Json
        switch ($shape) {
            null {$m.RegistryMetadata.Effects[0]=$null}
            string {$m.RegistryMetadata.Effects[0]='invalid object'}
            array {$m.RegistryMetadata.Effects[0]=@($m.RegistryMetadata.Effects[0])}
            missing-property {$m.RegistryMetadata.Effects[0].PSObject.Properties.Remove('Guid')}
        }
        Write-ReleaseFixture $m
        Reject-Release {Read-NativeRelease $releasePath} "effect entry requires a complete object: $shape"
    }
    Write-ReleaseFixture ($pristine|ConvertFrom-Json)
    $binary=Join-Path $package 'bin\SaitekFfbDriver.dll'
    $bytes=[IO.File]::ReadAllBytes($binary)
    $badBytes=[byte[]]$bytes.Clone();$badBytes[100]=$badBytes[100] -bxor 1
    [IO.File]::WriteAllBytes($binary,$badBytes)
    Reject-Release {Read-NativeRelease $releasePath} 'same-length payload corruption refused'
    # Even a self-consistent hash/length cannot turn an x86 PE into an x64 DLL.
    $badBytes=[byte[]]$bytes.Clone();$pe=[BitConverter]::ToInt32($badBytes,0x3c);$badBytes[$pe+4]=0x4c;$badBytes[$pe+5]=0x01
    [IO.File]::WriteAllBytes($binary,$badBytes)
    $m=$pristine|ConvertFrom-Json;$m.BinarySha256=Get-NativeHash $binary;$m.Files[0].Sha256=$m.BinarySha256
    Write-ReleaseFixture $m
    Reject-Release {Read-NativeRelease $releasePath} 'self-consistent wrong PE architecture refused'
    [IO.File]::WriteAllBytes($binary,$bytes)
    Write-ReleaseFixture ($pristine|ConvertFrom-Json)
    $unlisted=Join-Path $package 'unlisted.txt';[IO.File]::WriteAllText($unlisted,'unlisted')
    Reject-Release {Read-NativeRelease $releasePath} 'unlisted package file refused'
    Remove-Item -LiteralPath $unlisted -Force
    $external=Join-Path $testRoot 'outside package';[IO.Directory]::CreateDirectory($external)|Out-Null
    [IO.File]::WriteAllText((Join-Path $external 'outside.txt'),'outside')
    $junction=Join-Path $package 'escape'
    New-Item -ItemType Junction -Path $junction -Target $external | Out-Null
    $m=$pristine|ConvertFrom-Json
    $m.Files+=@([pscustomobject]@{Path='escape/outside.txt';Length=7;Sha256=(Get-NativeHash (Join-Path $external 'outside.txt'))})
    Write-ReleaseFixture $m
    Reject-Release {Read-NativeRelease $releasePath} 'listed reparse escape refused'
    Write-ReleaseFixture ($pristine|ConvertFrom-Json)
    Reject-Release {Read-NativeRelease $releasePath} 'unlisted reparse directory refused before traversal'
    # Non-recursive .NET deletion removes only the verified junction itself.
    if ([IO.Path]::GetFullPath($junction) -ne (Join-Path $package 'escape') -or
        ((Get-Item -LiteralPath $junction -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Unsafe junction cleanup' }
    [IO.Directory]::Delete($junction);$junction=$null
    Check-Release ([IO.File]::Exists((Join-Path $external 'outside.txt'))) 'reparse refusal and cleanup preserve target'
    $savedMask=$script:NativeMaskDInputHash
    try {
        $script:NativeMaskDInputHash='0'*64
        Reject-Release {Read-NativeRelease $releasePath} 'unknown DirectInput release validation refuses'
        Reject-Release {Invoke-NativeApplyTransaction $context $build} 'unknown DirectInput transaction refuses before staging'
    } finally {$script:NativeMaskDInputHash=$savedMask}
    Check-Release (-not (Test-Path -LiteralPath $context.Root) -and (Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath))) 'all refusal cases leave transaction storage and registry untouched'
    $result=Invoke-NativeApplyTransaction $context $build
    $savedBackup=Read-NativeBackup $context $result.BackupId
    Check-Release ($result.Status -eq 'Applied' -and $savedBackup.Schema -eq 1 -and $savedBackup.BinaryHash -ceq $build.BinarySha256) 'release reuses schema1 native transaction identity'
    Check-Release ((Invoke-NativeApplyTransaction $context $build).Status -eq 'AlreadyApplied') 'release reapply is idempotent'
    # Distinct PE identity fixture is used only for conflict/upgrade transactions;
    # these tests never load it or claim it has executed offline runtime tests.
    $otherBinary=Join-Path $testRoot 'other-identity.dll'
    [IO.File]::WriteAllBytes($otherBinary,[byte[]]($bytes+@(0)))
    $otherBuild=[pscustomobject]@{BinaryPath=$otherBinary;BinarySha256=(Get-NativeHash $otherBinary);RegistryMetadata=(Get-NativeExpectedMetadata)}
    Reject-Release {Invoke-NativeApplyTransaction $context $otherBuild} 'active different build refuses upgrade'
    Remove-Item -LiteralPath $releasePath -Force
    Remove-Item -LiteralPath $binary -Force
    try {
        $script:NativeMaskDInputHash='0'*64
        $restored=Invoke-NativeRestoreTransaction $context $result.BackupId
    } finally {$script:NativeMaskDInputHash=$savedMask}
    Check-Release ($restored.Status -eq 'Restored' -and (Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath))) 'restore succeeds after package DLL/manifest removal and changed fingerprint'
    Check-Release (-not (Get-SaitekRegistryTree $base $context.ClassPath).Exists -and -not (Test-Path -LiteralPath $result.BinaryPath)) 'original class absence and staged DLL absence restored'
    Check-Release (Test-SaitekTreeEqual $sibling (Get-SaitekRegistryTree $base "$registryRoot\Device\Sibling")) 'unrelated sibling survives apply/restore'
    $upgrade=Invoke-NativeApplyTransaction $context $otherBuild
    Check-Release ($upgrade.Status -eq 'Applied' -and $upgrade.BackupId -ne $result.BackupId) 'restore then apply permits distinct identity'
    Invoke-NativeRestoreTransaction $context $upgrade.BackupId | Out-Null
    [IO.File]::WriteAllBytes($binary,$bytes);Write-ReleaseFixture ($pristine|ConvertFrom-Json)
    # An interrupted transaction with an incomplete automatic rollback keeps its
    # original durable backup and refuses another Apply until explicit recovery.
    $originalSetter=(Get-Command Set-SaitekRegistryTree).ScriptBlock
    $script:releaseFaultPath=$context.ClassPath
    $script:releaseRecoveryFault=$false
    function Set-SaitekRegistryTree($Base,[string]$Path,$Tree) {
        if ($Path -eq $script:releaseFaultPath) {$script:releaseRecoveryFault=$true;throw 'Injected interrupted write fixture'}
        if ($script:releaseRecoveryFault) {throw 'Injected unavailable recovery fixture'}
        & $originalSetter $Base $Path $Tree
    }
    Reject-Release {Invoke-NativeApplyTransaction $context $build} 'interrupted apply surfaces incomplete recovery'
    Set-Item -LiteralPath Function:\Set-SaitekRegistryTree -Value $originalSetter
    $originalSetter=$null
    $pending=@(Get-SaitekPendingBackupIds $context)
    Check-Release ($pending.Count -eq 1) 'interrupted transaction retains sole active backup'
    Check-Release (-not (Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath))) 'interruption fixture retains changed first target for explicit recovery'
    Reject-Release {Invoke-NativeApplyTransaction $context $build} 'interrupted transaction blocks reapply'
    Invoke-NativeRestoreTransaction $context $pending[0] | Out-Null
    Check-Release ((Test-SaitekTreeEqual $original (Get-SaitekRegistryTree $base $context.UserOemPath)) -and -not (Get-SaitekRegistryTree $base $context.ClassPath).Exists) 'explicit recovery restores original typed state after interruption'
    Check-Release (@(Get-SaitekPendingBackupIds $context).Count -eq 0) 'recovery clears active transaction'
    # Public entrypoint previews must be nonmutating, even from the relocated kit.
    $production=New-NativeContext
    try {
        $prodOem=Get-SaitekRegistryTree $production.User $production.UserOemPath
        $prodClass=Get-SaitekRegistryTree $production.User $production.ClassPath
        $prodStorage=Test-Path -LiteralPath $production.Root
        & (Join-Path $package 'tools\Install-SaitekFfbDriver.ps1') -Mode Apply -ReleaseManifest $releasePath -WhatIf
        Check-Release ((Test-SaitekTreeEqual $prodOem (Get-SaitekRegistryTree $production.User $production.UserOemPath)) -and
            (Test-SaitekTreeEqual $prodClass (Get-SaitekRegistryTree $production.User $production.ClassPath)) -and
            $prodStorage -eq (Test-Path -LiteralPath $production.Root)) 'relocated public WhatIf preserves production state'
        Reject-Release { & (Join-Path $package 'tools\Install-SaitekFfbDriver.ps1') -Mode Apply -ReleaseManifest $releasePath -ArtifactManifest 'unused' -WhatIf } 'mutually exclusive manifest inputs refused'
    } finally {$production.User.Dispose()}
    Write-Output "PASS $script:releaseChecks release installer checks; source-free relocation and isolated transactions only."
} finally {
    if ($null -ne $originalSetter) {Set-Item -LiteralPath Function:\Set-SaitekRegistryTree -Value $originalSetter}
    if ($null -ne $junction -and [IO.Directory]::Exists($junction)) {
        if (-not [IO.Path]::GetFullPath($junction).StartsWith([IO.Path]::GetFullPath($testRoot)+'\',[StringComparison]::OrdinalIgnoreCase) -or
            ((Get-Item -LiteralPath $junction -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {throw 'Unsafe junction cleanup'}
        [IO.Directory]::Delete($junction)
    }
    if ($registryRoot -cnotmatch '^Software\\SaitekReleaseInstallerTests\\[a-f0-9]{32}$') {throw 'Unsafe test registry cleanup'}
    $base.DeleteSubKeyTree($registryRoot,$false);$base.Dispose()
    Assert-SaitekSafePath $workspace $testRoot
    if ([IO.Path]::GetFileName($testRoot) -cne "release-installer-tests-$testId") {throw 'Unsafe test file cleanup'}
    if (Test-Path -LiteralPath $testRoot) {Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
