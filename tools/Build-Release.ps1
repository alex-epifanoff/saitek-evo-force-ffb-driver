#requires -Version 5.1
<#
.SYNOPSIS
Assemble an unsigned experimental-alpha runtime package from a clean, tested checkout.
.DESCRIPTION
Only exact files in release/release-spec.json are exported. The source identity
hash is SHA256 of ordinally sorted "relative/path SHA256\n" records encoded as
UTF-8 without BOM, including the final LF. source-identity.json in the source ZIP
records that inventory but does not hash itself. Git must identify a clean source
checkout. Build evidence is verified against the current sources, never inferred.
Output version directories must not already exist. Hashes establish integrity,
not publisher authentication, licensing clearance or physical-device acceptance.
#>
[CmdletBinding()]
param([string]$Version='0.1.0-alpha.2')
$ErrorActionPreference='Stop'

function Assert-ReleasePath([string]$Root,[string]$Path) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Release path must stay beneath its declared root.' }
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release paths cannot traverse reparse points.' }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    $full
}
function Assert-ReleaseRelativePath([string]$Path) {
    if ($Path -cin @('.gitignore','.gitattributes','.github/workflows/ci.yml','.github/workflows/release.yml','.github/dependabot.yml',
        '.github/ISSUE_TEMPLATE/bug_report.yml','.github/ISSUE_TEMPLATE/config.yml')) { return }
    if ($Path -cnotmatch '^[A-Za-z0-9_-][A-Za-z0-9._/-]*$' -or $Path.Contains('//')) { throw 'Release inventory requires ordinary relative slash paths.' }
    foreach ($part in $Path.Split('/')) {
        if ($part -eq '.' -or $part -eq '..' -or $part.EndsWith('.') -or $part -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)') { throw 'Unsafe release path segment.' }
    }
}
function Get-ReleaseHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Write-ReleaseJson([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 16)+"`n",[Text.UTF8Encoding]::new($false))
}
function Get-ReleaseInventoryHash($Inventory) {
    $lines=[string[]]@($Inventory | ForEach-Object { $_.Path+' '+$_.Sha256 })
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")+"`n"))).Replace('-','') }
    finally { $sha.Dispose() }
}
function Read-ReleaseSpec([string]$Workspace) {
    $path=Assert-ReleasePath $Workspace (Join-Path $Workspace 'release/release-spec.json')
    $spec=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($spec.SchemaVersion -ne 1 -or $spec.Product -cne 'SaitekNativeFfb') { throw 'Unsupported release specification.' }
    foreach ($kind in @('Binary','Source')) {
        $seen=@{}; $inputs=@{}
        if (@($spec.$kind).Count -eq 0) { throw 'Empty release allowlist.' }
        foreach ($entry in @($spec.$kind)) {
            Assert-ReleaseRelativePath $entry.Source; Assert-ReleaseRelativePath $entry.Path
            if ($seen.ContainsKey($entry.Path) -or $inputs.ContainsKey($entry.Source)) { throw 'Duplicate release inventory path.' }
            $seen[$entry.Path]=$true; $inputs[$entry.Source]=$true
            foreach ($candidate in @($entry.Source,$entry.Path)) {
                if ($candidate -match '(^|/)(\.claude|\.business|\.git|thirdparty|third-party|vendor|captures)(/|$)|SaitekProbe|HidTrace|Build-Probe|Repair-SaitekFfb|(^|/)(probe|repair)\.md$|(^|/)(release-manifest|build-manifest|source-identity)\.json$') { throw 'Excluded/private payload in release specification.' }
            }
            $isDriver=$kind -ceq 'Binary' -and $entry.Source -ceq 'out/driver/SaitekFfbDriver.dll' -and $entry.Path -ceq 'bin/SaitekFfbDriver.dll'
            $isSourceConfig=$kind -ceq 'Source' -and $entry.Source -ceq $entry.Path -and $entry.Path -cin @('.gitignore','.gitattributes',
                '.github/workflows/ci.yml','.github/workflows/release.yml','.github/dependabot.yml','.github/ISSUE_TEMPLATE/bug_report.yml','.github/ISSUE_TEMPLATE/config.yml')
            $isLicense=$entry.Source -ceq 'LICENSE' -and $entry.Path -ceq 'LICENSE'
            if ($kind -cne 'Source' -and ($entry.Source -ceq 'release/import-origin.json' -or $entry.Path -match '(^|/)import-origin\.json$')) { throw 'Historical import evidence belongs only in the source export.' }
            if (-not $isDriver -and -not $isSourceConfig -and -not $isLicense -and ($entry.Source -match '^out/' -or $entry.Path -match '^out/' -or $entry.Source -notmatch '\.(ps1|cpp|h|def|md|json|cmd)$' -or $entry.Path -notmatch '\.(ps1|cpp|h|def|md|json|cmd)$')) { throw 'Only allowlisted original source/text files, LICENSE and the fixed runtime DLL can ship.' }
            if ($kind -ceq 'Source' -and $entry.Path -cne $entry.Source) { throw 'Source archive must retain project-relative paths.' }
            $inputPath=Assert-ReleasePath $Workspace (Join-Path $Workspace $entry.Source)
            if (-not [IO.File]::Exists($inputPath)) { throw "Required release input missing: $($entry.Source)" }
        }
        $required=@('Start.cmd','README.md','LICENSE','CHANGELOG.md','tools/Install-SaitekFfbDriver.ps1','tools/SaitekFfb.Common.ps1','tools/Start-SaitekFfbSetup.ps1','tools/Start-SaitekFfbBridge.ps1','tools/Get-SaitekFfbSupport.ps1','tools/New-SaitekFfbShortcut.ps1')
        $required+=@('docs/community-alpha.md','docs/bridge-launcher.md','docs/flying.md','docs/native-install.md','docs/native-driver.md','docs/protocol.md')
        if ($kind -ceq 'Binary') { $required+=@('bin/SaitekFfbDriver.dll','PROVENANCE.md','RELEASE-STATUS.md','THIRD-PARTY-NOTICES.md') }
        else { $required+=@('.gitignore','.gitattributes','.github/workflows/ci.yml','.github/workflows/release.yml','.github/dependabot.yml','.github/ISSUE_TEMPLATE/bug_report.yml','.github/ISSUE_TEMPLATE/config.yml',
            'CONTRIBUTING.md','docs/build-release.md','tools/Invoke-CI.ps1','release/import-origin.json','native/SaitekFfbDriver.cpp','native/HidPidDevice.cpp','native/HidPidDevice.h','native/SaitekFfbDriver.def','native/tests/DriverTests.cpp','tests/HidPidDeviceTests.cpp','tests/Run-HidPidTests.ps1','tools/Build-Driver.ps1','tools/Build-Release.ps1','release/release-spec.json','release/PROVENANCE.md','release/RELEASE-STATUS.md','release/THIRD-PARTY-NOTICES.md') }
        foreach ($requiredPath in $required) { if (-not $seen.ContainsKey($requiredPath)) { throw "Required release payload omitted: $requiredPath" } }
    }
    # Every original binary-package input must also be present in the source export.
    foreach ($entry in @($spec.Binary | Where-Object Source -ne 'out/driver/SaitekFfbDriver.dll')) {
        if (@($spec.Source | Where-Object Source -ceq $entry.Source).Count -ne 1) { throw 'Source export omits a binary-package source.' }
    }
    $spec
}
function Read-ReleaseBuild([string]$Workspace) {
    $path=Assert-ReleasePath $Workspace (Join-Path $Workspace 'out/driver/build-manifest.json')
    $build=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($build.SchemaVersion -ne 1 -or $build.Architecture -cne 'x64' -or $build.Clsid -cne '{1DB0C28F-6D99-416E-8D05-73DE59E6E170}' -or
        $build.OfflineComTestsPassed -isnot [bool] -or -not $build.OfflineComTestsPassed -or
        $build.OfflineProtocolTestsPassed -isnot [bool] -or -not $build.OfflineProtocolTestsPassed) { throw 'A current x64 build with both offline suites passed is required.' }
    $binary=Assert-ReleasePath $Workspace (Join-Path $Workspace 'out/driver/SaitekFfbDriver.dll')
    if ([IO.Path]::GetFullPath($build.BinaryPath) -ine $binary -or $build.BinarySha256 -cnotmatch '^[A-F0-9]{64}$' -or (Get-ReleaseHash $binary) -cne $build.BinarySha256) { throw 'Build DLL identity mismatch.' }
    $bytes=[IO.File]::ReadAllBytes($binary)
    if ($bytes.Length -lt 256 -or $bytes.Length -gt 16777216) { throw 'Invalid native DLL size.' }
    $pe=[BitConverter]::ToInt32($bytes,0x3c)
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a -or $pe -lt 64 -or $pe -gt ($bytes.Length-24) -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664 -or ([BitConverter]::ToUInt16($bytes,$pe+22) -band 0x2000) -eq 0) { throw 'Runtime must be an AMD64 PE DLL.' }
    $required=@('native/SaitekFfbDriver.cpp','native/HidPidDevice.cpp','native/HidPidDevice.h','native/SaitekFfbDriver.def','native/tests/DriverTests.cpp','tests/HidPidDeviceTests.cpp','tests/Run-HidPidTests.ps1','tools/Build-Driver.ps1')
    $expected=@{}; foreach ($relative in $required) { $expected[(Assert-ReleasePath $Workspace (Join-Path $Workspace $relative))]=$true }
    if (@($build.SourceHashes).Count -ne $required.Count) { throw 'Incomplete source build evidence.' }
    $seen=@{}
    foreach ($source in @($build.SourceHashes)) {
        $full=Assert-ReleasePath $Workspace $source.Path
        if (-not $expected.ContainsKey($full) -or $seen.ContainsKey($full) -or $source.Sha256 -cnotmatch '^[A-F0-9]{64}$' -or (Get-ReleaseHash $full) -cne $source.Sha256) { throw 'Stale, changed, duplicate or unexpected build source. Rebuild with tests.' }
        $seen[$full]=$true
    }
    if ($build.Build.Compiler -cnotmatch '^MSVC cl\.exe \d+(\.\d+){2,3} x64$' -or $build.Build.WindowsSdk -cnotmatch '^\d+(\.\d+){2,3}$') { throw 'Missing or invalid compiler/SDK provenance. Rebuild with current Build-Driver.' }
    $command='cl.exe /nologo /std:c++17 /EHsc /W4 /WX /O2 /MT /utf-8 /DUNICODE /D_UNICODE /LD native/SaitekFfbDriver.cpp native/HidPidDevice.cpp /Foout/driver/ /Feout/driver/SaitekFfbDriver.dll /Fdout/driver/SaitekFfbDriver.pdb /link dxguid.lib ole32.lib hid.lib /MACHINE:X64 /WX /DEF:native/SaitekFfbDriver.def /IMPLIB:out/driver/SaitekFfbDriver.lib'
    if ($build.Build.Command -cne $command) { throw 'Unrecognized build command identity.' }
    $metadata=$build.RegistryMetadata
    if ($metadata.DeviceFlags -ne 0 -or $metadata.FFSamplePeriod -ne 1000 -or $metadata.FFMinTimeResolution -ne 1000 -or @($metadata.Effects).Count -ne 8) { throw 'Invalid runtime metadata.' }
    $rows=@(@('13541C20','Constant Force',38,34305,997,324),@('13541C22','Square Wave',48,34307,997,324),@('13541C23','Sine Wave',49,34307,997,324),@('13541C24','Triangle Wave',50,34307,997,324),@('13541C25','Sawtooth Up',51,34307,997,324),@('13541C26','Sawtooth Down',52,34307,997,324),@('13541C27','Spring',64,63492,805,260),@('13541C28','Damper',65,63492,805,260))
    foreach ($row in $rows) {
        $matches=@($metadata.Effects | Where-Object Guid -ceq ('{'+$row[0]+'-8E33-11D0-9AD0-00A0C9A06E35}'))
        if ($matches.Count -ne 1) { throw 'Invalid effect metadata GUID.' }
        $effect=$matches[0]
        if ($effect.Name -cne $row[1] -or $effect.Id -ne $row[2] -or $effect.Type -ne $row[3] -or $effect.StaticParams -ne $row[4] -or $effect.DynamicParams -ne $row[5] -or $effect.Coords -ne 32) { throw 'Invalid effect capability metadata.' }
    }
    $build
}
function Get-ReleaseSourceIdentity([string]$Workspace,$Inventory) {
    $gitRoot=& git -C $Workspace rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($gitRoot).TrimEnd('\','/') -ine [IO.Path]::GetFullPath($Workspace).TrimEnd('\','/')) { throw 'Release assembly requires its own Git source checkout.' }
    $commit=& git -C $Workspace rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$') { throw 'Cannot identify release Git commit.' }
    $status=@(& git -C $Workspace status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Release source checkout is dirty; commit reviewed inputs and rebuild first.' }
    foreach ($entry in $Inventory) {
        & git -C $Workspace ls-files --error-unmatch -- $entry.Path 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Release source input is not tracked by the source commit.' }
    }
    [ordered]@{GitCommit=$commit;Dirty=$false;InventorySha256=(Get-ReleaseInventoryHash $Inventory)}
}
function Copy-ReleaseFiles([string]$Workspace,[string]$Destination,$Entries) {
    $inventory=@()
    foreach ($entry in $Entries) {
        $inputPath=Assert-ReleasePath $Workspace (Join-Path $Workspace $entry.Source)
        $outputPath=Assert-ReleasePath $Destination (Join-Path $Destination $entry.Path)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
        [IO.File]::Copy($inputPath,$outputPath,$false)
        $inventory+= [ordered]@{Path=$entry.Path;Length=[long](Get-Item -LiteralPath $outputPath).Length;Sha256=(Get-ReleaseHash $outputPath)}
    }
    $inventory
}
function Remove-ReleaseStagingDirectory([string]$Workspace,[string]$Stage) {
    $full=Assert-ReleasePath $Workspace $Stage
    $parent=[IO.Path]::GetFullPath((Join-Path $Workspace 'out/release'))
    if ([IO.Path]::GetDirectoryName($full) -ine $parent -or [IO.Path]::GetFileName($full) -cnotmatch '^\.staging-[a-f0-9]{32}$') { throw 'Unsafe release cleanup target.' }
    if (-not (Test-Path -LiteralPath $full)) { return }
    # Refuse unexpected links anywhere in the disposable tree before recursion.
    $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($full)
    while ($pending.Count -gt 0) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $attributes=[IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe link in release cleanup tree.' }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($entry) }
        }
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}
function Invoke-ReleaseBuild([string]$Workspace,[string]$ReleaseVersion) {
    if ($ReleaseVersion.Length -gt 100 -or $ReleaseVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.(0|[1-9][0-9]*)\z') { throw 'Only a numeric X.Y.Z-alpha.N experimental version is accepted.' }
    $Workspace=[IO.Path]::GetFullPath($Workspace)
    $spec=Read-ReleaseSpec $Workspace
    $build=Read-ReleaseBuild $Workspace
    $buildHash=Get-ReleaseHash (Join-Path $Workspace 'out/driver/build-manifest.json')
    $inventory=@($spec.Source | ForEach-Object { $path=Join-Path $Workspace $_.Source; [ordered]@{Path=$_.Path;Length=[long](Get-Item -LiteralPath $path).Length;Sha256=(Get-ReleaseHash $path)} })
    $identity=Get-ReleaseSourceIdentity $Workspace $inventory
    $output=Assert-ReleasePath $Workspace (Join-Path $Workspace ('out/release/'+$ReleaseVersion))
    if (Test-Path -LiteralPath $output) { throw 'Release output already exists; choose a new version or archive the existing result explicitly.' }
    $stage=Assert-ReleasePath $Workspace (Join-Path $Workspace ('out/release/.staging-'+[Guid]::NewGuid().ToString('N')))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $binaryName='SaitekNativeFfb-'+$ReleaseVersion+'-win-x64'; $sourceName='SaitekNativeFfb-'+$ReleaseVersion+'-source'
        $payload=Join-Path $stage 'payload'; $binaryRoot=Join-Path $payload $binaryName; $sourceRoot=Join-Path $payload $sourceName
        $binaryInventory=@(Copy-ReleaseFiles $Workspace $binaryRoot $spec.Binary)
        $sourceInventory=@(Copy-ReleaseFiles $Workspace $sourceRoot $spec.Source)
        if ((Get-ReleaseInventoryHash $sourceInventory) -cne $identity.InventorySha256 -or (Get-ReleaseHash (Join-Path $binaryRoot 'bin/SaitekFfbDriver.dll')) -cne $build.BinarySha256) { throw 'Inputs changed while staging; rebuild and retry.' }
        $sourceHashes=@{}; foreach ($file in $sourceInventory) { $sourceHashes[$file.Path]=$file.Sha256 }
        $binaryHashes=@{}; foreach ($file in $binaryInventory) { $binaryHashes[$file.Path]=$file.Sha256 }
        foreach ($entry in @($spec.Binary | Where-Object Source -ne 'out/driver/SaitekFfbDriver.dll')) {
            if ($binaryHashes[$entry.Path] -cne $sourceHashes[$entry.Source]) { throw 'Binary/source payload changed between staging copies.' }
        }
        Write-ReleaseJson (Join-Path $sourceRoot 'source-identity.json') ([ordered]@{SchemaVersion=1;SourceIdentity=$identity;Files=$sourceInventory})
        $publicBuild=[ordered]@{Compiler=$build.Build.Compiler;WindowsSdk=$build.Build.WindowsSdk;Command=$build.Build.Command}
        $publicEffects=@($build.RegistryMetadata.Effects | ForEach-Object { [ordered]@{Name=$_.Name;Guid=$_.Guid;Id=[int]$_.Id;Type=[int]$_.Type;StaticParams=[int]$_.StaticParams;DynamicParams=[int]$_.DynamicParams;Coords=[int]$_.Coords} })
        $publicMetadata=[ordered]@{DeviceFlags=0;FFSamplePeriod=1000;FFMinTimeResolution=1000;Effects=$publicEffects}
        $manifest=[ordered]@{SchemaVersion=1;Product='SaitekNativeFfb';Version=$ReleaseVersion;Channel='experimental-alpha';Architecture='x64';Clsid=$build.Clsid;BinaryPath='bin/SaitekFfbDriver.dll';BinarySha256=$build.BinarySha256;OfflineComTestsPassed=$true;OfflineProtocolTestsPassed=$true;RegistryMetadata=$publicMetadata;SourceIdentity=$identity;Build=$publicBuild;Files=$binaryInventory}
        Write-ReleaseJson (Join-Path $binaryRoot 'release-manifest.json') $manifest
        # The fresh evidence and clean commit must still identify the staged inputs.
        $null=Read-ReleaseBuild $Workspace
        $finalInventory=@($spec.Source | ForEach-Object { [ordered]@{Path=$_.Path;Sha256=(Get-ReleaseHash (Join-Path $Workspace $_.Source))} })
        $finalIdentity=Get-ReleaseSourceIdentity $Workspace $finalInventory
        if ($finalIdentity.GitCommit -cne $identity.GitCommit -or $finalIdentity.InventorySha256 -cne $identity.InventorySha256 -or (Get-ReleaseHash (Join-Path $Workspace 'out/driver/build-manifest.json')) -cne $buildHash) { throw 'Source/build evidence changed during assembly.' }
        $artifacts=Join-Path $stage 'artifacts'; [IO.Directory]::CreateDirectory($artifacts) | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($name in @($binaryName,$sourceName)) {
            [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $payload $name),(Join-Path $artifacts ($name+'.zip')),[IO.Compression.CompressionLevel]::Optimal,$true)
        }
        [IO.File]::Copy((Join-Path $binaryRoot 'release-manifest.json'),(Join-Path $artifacts 'release-manifest.json'),$false)
        $checksums=@(($binaryName+'.zip'),($sourceName+'.zip'),'release-manifest.json') | ForEach-Object { (Get-ReleaseHash (Join-Path $artifacts $_))+'  '+$_ }
        [IO.File]::WriteAllText((Join-Path $artifacts 'SHA256SUMS.txt'),($checksums -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
        $null=Assert-ReleasePath $Workspace $output; $null=Assert-ReleasePath $Workspace $artifacts
        [IO.Directory]::Move($artifacts,$output)
        [pscustomobject]@{Version=$ReleaseVersion;Directory=$output;BinaryZip=(Join-Path $output ($binaryName+'.zip'));SourceZip=(Join-Path $output ($sourceName+'.zip'));Manifest=(Join-Path $output 'release-manifest.json');Checksums=(Join-Path $output 'SHA256SUMS.txt')}
    } finally {
        Remove-ReleaseStagingDirectory $Workspace $stage
    }
}
if ($MyInvocation.InvocationName -ne '.') { Invoke-ReleaseBuild (Split-Path -Parent $PSScriptRoot) $Version }
