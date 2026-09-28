#requires -Version 5.1
# Offline packaging fixtures. No device, installer transaction, app or network.
[CmdletBinding()]
param([switch]$RebuildExport)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../tools/Build-Release.ps1')
$workspace=Split-Path -Parent $PSScriptRoot
$script:packageChecks=0
function Check-Package([bool]$Condition,[string]$Message) { $script:packageChecks++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Reject-Package([scriptblock]$Body,[string]$Message) { $failed=$false; try { & $Body | Out-Null } catch { $failed=$true }; Check-Package $failed $Message }
function Save-PackageText([string]$Path,[string]$Text) { [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null; [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
$testId=[Guid]::NewGuid().ToString('N')
$testRoot=Assert-ReleasePath $workspace (Join-Path $workspace ('out/package-tests-'+$testId))
$fixture=Join-Path $testRoot 'fixture source with spaces'
$junction=$null
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $originalBuild=Read-ReleaseBuild $workspace
    $spec=Get-Content -LiteralPath (Join-Path $workspace 'release/release-spec.json') -Raw | ConvertFrom-Json
    # Public exports must exercise the actual reviewed inputs, including LICENSE
    # and CI definitions; missing files cannot be replaced by placeholders.
    foreach ($entry in @($spec.Source)) {
        $inputPath=Join-Path $workspace $entry.Source; $destination=Join-Path $fixture $entry.Path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        if (-not [IO.File]::Exists($inputPath)) { throw "Required source fixture input missing: $($entry.Source)" }
        [IO.File]::Copy($inputPath,$destination,$false)
    }
    foreach ($excluded in @('native/SaitekProbe.cpp','native/HidTrace.cpp','native/HidTrace.h','tools/Build-Probe.ps1','tools/Repair-SaitekFfb.ps1','tests/Repair-SaitekFfb.Tests.ps1','docs/probe.md','docs/repair.md','thirdparty/vendor.dll','.claude/private.json','.business/private.json')) { Save-PackageText (Join-Path $fixture $excluded) 'Excluded sentinel; never distribute.' }
    & git -C $fixture init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize disposable source fixture.' }
    & git -C $fixture config core.autocrlf false
    & git -C $fixture add --all
    & git -C $fixture -c user.name='Package Test Fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'Disposable packaging fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit disposable source fixture.' }
    $fixtureBuild=($originalBuild | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    $fixtureBuild.BinaryPath=Join-Path $fixture 'out/driver/SaitekFfbDriver.dll'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fixtureBuild.BinaryPath)) | Out-Null
    [IO.File]::Copy($originalBuild.BinaryPath,$fixtureBuild.BinaryPath,$false)
    foreach ($source in $fixtureBuild.SourceHashes) { $relative=$source.Path.Substring($workspace.TrimEnd('\').Length+1); $source.Path=Join-Path $fixture $relative; $source.Sha256=Get-ReleaseHash $source.Path }
    $fixtureManifest=Join-Path $fixture 'out/driver/build-manifest.json'
    # Extra private development metadata must never propagate into the export.
    $fixtureBuild.Build | Add-Member NoteProperty PrivatePath 'C:\Users\SyntheticOwner\private'
    $fixtureBuild.RegistryMetadata | Add-Member NoteProperty PrivateSid 'S-1-5-21-111111111-222222222-333333333-1001'
    Write-ReleaseJson $fixtureManifest $fixtureBuild
    $release=Invoke-ReleaseBuild $fixture '0.1.0-alpha.2'
    Check-Package ([IO.File]::Exists($release.BinaryZip) -and [IO.File]::Exists($release.SourceZip)) 'both archives created'
    $manifest=Get-Content -LiteralPath $release.Manifest -Raw | ConvertFrom-Json
    Check-Package ($manifest.Files.Count -eq $spec.Binary.Count -and $manifest.SourceIdentity.Dirty -eq $false) 'complete binary inventory and clean source identity'
    Check-Package ($manifest.OfflineComTestsPassed -eq $true -and $manifest.OfflineProtocolTestsPassed -eq $true -and $manifest.Channel -ceq 'experimental-alpha' -and $manifest.Version -ceq '0.1.0-alpha.2') 'actual offline build evidence and experimental alpha version/channel'
    $manifestText=Get-Content -LiteralPath $release.Manifest -Raw
    Check-Package ($manifestText -notmatch '[A-Za-z]:\\|S-1-5-21|SyntheticOwner|SourceHashes|PrivatePath|PrivateSid') 'manifest contains no development paths, identities or extra metadata'
    $relocated=Join-Path $testRoot 'relocated package with spaces'; [IO.Directory]::CreateDirectory($relocated) | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($release.BinaryZip,$relocated)
    $binaryRoot=Join-Path $relocated 'SaitekNativeFfb-0.1.0-alpha.2-win-x64'
    Check-Package (@(Get-ChildItem -LiteralPath $binaryRoot -File -Recurse).Count -eq ($spec.Binary.Count+1)) 'ZIP has only allowlisted binary files and manifest'
    foreach ($file in $manifest.Files) {
        $path=Join-Path $binaryRoot $file.Path
        Check-Package ([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -eq $file.Length -and (Get-ReleaseHash $path) -ceq $file.Sha256) ('relocated inventory: '+$file.Path)
    }
    Check-Package ((Get-ReleaseHash (Join-Path $binaryRoot 'release-manifest.json')) -ceq (Get-ReleaseHash $release.Manifest)) 'external manifest matches archived manifest'
    $sourceDestination=Join-Path $testRoot 'exported source with spaces'; [IO.Directory]::CreateDirectory($sourceDestination) | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($release.SourceZip,$sourceDestination)
    $sourceRoot=Join-Path $sourceDestination 'SaitekNativeFfb-0.1.0-alpha.2-source'
    Check-Package (@(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force).Count -eq ($spec.Source.Count+1)) 'source ZIP exact allowlist plus identity'
    $licenseHash=Get-ReleaseHash (Join-Path $workspace 'LICENSE')
    Check-Package ((Get-ReleaseHash (Join-Path $binaryRoot 'LICENSE')) -ceq $licenseHash -and (Get-ReleaseHash (Join-Path $sourceRoot 'LICENSE')) -ceq $licenseHash) 'both archives preserve selected LICENSE bytes exactly'
    Check-Package ((Get-ReleaseHash (Join-Path $sourceRoot 'release/import-origin.json')) -ceq (Get-ReleaseHash (Join-Path $workspace 'release/import-origin.json')) -and
        -not [IO.File]::Exists((Join-Path $binaryRoot 'release/import-origin.json')) -and -not [IO.File]::Exists((Join-Path $binaryRoot 'import-origin.json'))) 'historical import evidence preserved only in source export'
    $sourceIdentity=Get-Content -LiteralPath (Join-Path $sourceRoot 'source-identity.json') -Raw | ConvertFrom-Json
    $exportedInventory=@($spec.Source | ForEach-Object { [ordered]@{Path=$_.Path;Sha256=(Get-ReleaseHash (Join-Path $sourceRoot $_.Path))} })
    Check-Package ((Get-ReleaseInventoryHash $exportedInventory) -ceq $manifest.SourceIdentity.InventorySha256 -and $sourceIdentity.SourceIdentity.InventorySha256 -ceq $manifest.SourceIdentity.InventorySha256) 'exported sources independently reproduce canonical identity'
    & git -C $sourceRoot init --quiet
    & git -C $sourceRoot config core.autocrlf false
    & git -C $sourceRoot add --all
    & git -C $sourceRoot -c user.name='Package Test Fixture' -c user.email='fixture@example.invalid' commit --quiet -m 'Initialize exported source fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize exported source Git fixture.' }
    Save-PackageText (Join-Path $sourceRoot 'out/driver/generated-test-output.txt') 'Generated output must remain ignored.'
    $ignored=& git -C $sourceRoot check-ignore -- out/driver/generated-test-output.txt
    Check-Package ($LASTEXITCODE -eq 0 -and $ignored -ceq 'out/driver/generated-test-output.txt') 'source .gitignore excludes generated build output'
    $exportStatus=@(& git -C $sourceRoot status --porcelain --untracked-files=all)
    Check-Package ($LASTEXITCODE -eq 0 -and $exportStatus.Count -eq 0) 'initialized source export stays clean after generated output'
    foreach ($sum in @(Get-Content -LiteralPath $release.Checksums)) {
        Check-Package ($sum -cmatch '^([A-F0-9]{64})  ([A-Za-z0-9.-]+)$') 'checksum format is relative'
        Check-Package ((Get-ReleaseHash (Join-Path $release.Directory $Matches[2])) -ceq $Matches[1]) 'external checksum identifies completed artifact'
    }
    Reject-Package { Invoke-ReleaseBuild $fixture '0.1.0-alpha.2' } 'existing release refuses overwrite'
    Check-Package ((Get-ReleaseHash $release.Manifest) -ceq (Get-ReleaseHash (Join-Path $binaryRoot 'release-manifest.json'))) 'collision preserves prior release'
    foreach ($badVersion in @('../escape','C:/escape','1.0.0','1.0.0-alpha.1/evil','01.0.0-alpha.2','0.1.0-alpha.02','0.1.0-beta.1',"0.1.0-alpha.2`n")) { Reject-Package { Invoke-ReleaseBuild $fixture $badVersion } 'unsafe/non-alpha version refused' }
    $savedBuild=[IO.File]::ReadAllText($fixtureManifest)
    foreach ($mutation in @('com','protocol','source','duplicate','binary','command','compiler','sdk','metadata','name','architecture')) {
        $bad=$savedBuild | ConvertFrom-Json
        switch ($mutation) {
            com { $bad.OfflineComTestsPassed=$false }
            protocol { $bad.OfflineProtocolTestsPassed='true' }
            source { $bad.SourceHashes[0].Sha256='0'*64 }
            duplicate { $bad.SourceHashes[1]=$bad.SourceHashes[0] }
            binary { $bad.BinarySha256='0'*64 }
            command { $bad.Build.Command+=' /unsafe' }
            compiler { $bad.Build.Compiler='C:\Users\owner\cl.exe' }
            sdk { $bad.Build.WindowsSdk='unknown' }
            metadata { $bad.RegistryMetadata.Effects[0].Coords=0 }
            name { $bad.RegistryMetadata.Effects[0].Name='unexpected' }
            architecture { $bad.Architecture='x86' }
        }
        Write-ReleaseJson $fixtureManifest $bad
        Reject-Package { Read-ReleaseBuild $fixture } ('changed build evidence: '+$mutation)
    }
    [IO.File]::WriteAllText($fixtureManifest,$savedBuild,[Text.UTF8Encoding]::new($false))
    $nativePath=Join-Path $fixture 'native/HidPidDevice.cpp'; $savedNative=[IO.File]::ReadAllBytes($nativePath)
    [IO.File]::AppendAllText($nativePath,"`n// changed fixture source")
    Reject-Package { Read-ReleaseBuild $fixture } 'changed source bytes invalidate prior passing build'
    [IO.File]::WriteAllBytes($nativePath,$savedNative)
    $readme=Join-Path $fixture 'README.md'; $readmeBytes=[IO.File]::ReadAllBytes($readme)
    [IO.File]::AppendAllText($readme,"`nDirty source")
    Reject-Package { Invoke-ReleaseBuild $fixture '0.1.0-alpha.3' } 'dirty reviewed source refused'
    [IO.File]::WriteAllBytes($readme,$readmeBytes)
    $specPath=Join-Path $fixture 'release/release-spec.json'; $savedSpec=[IO.File]::ReadAllText($specPath)
    foreach ($mutation in @('escape','absolute','duplicate','excluded','broadout','missing','omitted','hidden','binaryignore','binarylicense','sourcelicense','renamedlicense','binaryorigin','unreviewedworkflow','binaryworkflow')) {
        $bad=$savedSpec | ConvertFrom-Json
        switch ($mutation) {
            escape { $bad.Binary[1].Path='../escape.cmd' }
            absolute { $bad.Binary[1].Source='C:/outside.cmd' }
            duplicate { $bad.Binary[1].Path=$bad.Binary[2].Path }
            excluded { $bad.Binary+= [pscustomobject]@{Source='native/HidTrace.cpp';Path='native/HidTrace.cpp'} }
            broadout { $bad.Binary+= [pscustomobject]@{Source='out/private.md';Path='private.md'} }
            missing { $bad.Binary[1].Source='missing.cmd' }
            omitted { $bad.Binary=@($bad.Binary | Where-Object Path -ne 'Start.cmd') }
            hidden { $bad.Source+= [pscustomobject]@{Source='.private';Path='.private'} }
            binaryignore { $bad.Binary+= [pscustomobject]@{Source='.gitignore';Path='.gitignore'} }
            binarylicense { $bad.Binary=@($bad.Binary | Where-Object Path -ne 'LICENSE') }
            sourcelicense { $bad.Source=@($bad.Source | Where-Object Path -ne 'LICENSE') }
            renamedlicense { ($bad.Binary | Where-Object Path -eq 'LICENSE').Path='licenses/LICENSE' }
            binaryorigin { $bad.Binary+= [pscustomobject]@{Source='release/import-origin.json';Path='import-origin.json'} }
            unreviewedworkflow { $bad.Source+= [pscustomobject]@{Source='.github/workflows/unreviewed.yml';Path='.github/workflows/unreviewed.yml'} }
            binaryworkflow { $bad.Binary+= [pscustomobject]@{Source='.github/workflows/ci.yml';Path='.github/workflows/ci.yml'} }
        }
        Write-ReleaseJson $specPath $bad
        Reject-Package { Read-ReleaseSpec $fixture } ('unsafe or incomplete allowlist: '+$mutation)
    }
    [IO.File]::WriteAllText($specPath,$savedSpec,[Text.UTF8Encoding]::new($false))
    $licensePath=Join-Path $fixture 'LICENSE';$licenseBytes=[IO.File]::ReadAllBytes($licensePath);[IO.File]::Delete($licensePath)
    Reject-Package { Read-ReleaseSpec $fixture } 'missing selected LICENSE refuses packaging'
    [IO.File]::WriteAllBytes($licensePath,$licenseBytes)
    $missingPath=Join-Path $fixture 'tools/Start-SaitekFfbSetup.ps1'; $missingBytes=[IO.File]::ReadAllBytes($missingPath); [IO.File]::Delete($missingPath)
    Reject-Package { Read-ReleaseSpec $fixture } 'missing required owner file refused'
    [IO.File]::WriteAllBytes($missingPath,$missingBytes)
    $dllBytes=[IO.File]::ReadAllBytes($fixtureBuild.BinaryPath); [IO.File]::AppendAllText($fixtureBuild.BinaryPath,'corrupt')
    Reject-Package { Read-ReleaseBuild $fixture } 'modified runtime DLL refused'
    [IO.File]::WriteAllBytes($fixtureBuild.BinaryPath,$dllBytes)
    Reject-Package { Assert-ReleasePath $fixture (Join-Path $testRoot 'outside') } 'absolute staging path escape refused'
    Reject-Package { Remove-ReleaseStagingDirectory $fixture $fixture } 'cleanup cannot target workspace root'
    Reject-Package { Remove-ReleaseStagingDirectory $fixture (Join-Path $fixture 'out/release') } 'cleanup cannot target release parent'
    $outside=Join-Path $testRoot 'outside sentinel'; Save-PackageText (Join-Path $outside 'keep.txt') 'preserved'
    $junction=Join-Path $fixture 'out/linked'; New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Reject-Package { Assert-ReleasePath $fixture (Join-Path $junction 'keep.txt') } 'junction traversal refused'
    [IO.Directory]::Delete($junction); $junction=$null
    $unsafeStage=Join-Path $fixture ('out/release/.staging-'+[Guid]::NewGuid().ToString('N')); [IO.Directory]::CreateDirectory($unsafeStage) | Out-Null
    $junction=Join-Path $unsafeStage 'linked'; New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Reject-Package { Remove-ReleaseStagingDirectory $fixture $unsafeStage } 'cleanup refuses nested junction before recursion'
    Check-Package ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -ceq 'preserved') 'outside sentinel preserved'
    [IO.Directory]::Delete($junction); $junction=$null; Remove-ReleaseStagingDirectory $fixture $unsafeStage
    $baseChecks=$script:packageChecks
    if ($RebuildExport) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sourceRoot 'tools/Build-Driver.ps1')
        Check-Package ($LASTEXITCODE -eq 0) 'export independently compiles and passes native suites'
        $rebuilt=Read-ReleaseBuild $sourceRoot
        Check-Package ($rebuilt.OfflineComTestsPassed -and $rebuilt.OfflineProtocolTestsPassed) 'fresh source export build evidence verified'
    }
    $rebuildChecks=$script:packageChecks-$baseChecks
    Write-Output "PASS $baseChecks base release-package checks; $rebuildChecks optional exported-source rebuild checks; offline fixtures only."
} finally {
    # Never recursively delete a live junction, even after an assertion failure.
    if ($junction -and [IO.Directory]::Exists($junction)) { $null=Assert-ReleasePath $testRoot ([IO.Path]::GetDirectoryName($junction)); [IO.Directory]::Delete($junction) }
    $null=Assert-ReleasePath $workspace $testRoot
    if ([IO.Path]::GetFileName($testRoot) -cne ('package-tests-'+$testId)) { throw 'Unsafe package-test cleanup target.' }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
