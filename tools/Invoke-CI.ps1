#requires -Version 5.1
<#
.SYNOPSIS
Run offline checks and optionally assemble a clean, traceable alpha release.
.DESCRIPTION
No device is opened and no production registration is changed. Installer
fixture suites retain their production DirectInput fingerprint precondition.
#>
[CmdletBinding()]
param([string]$Version='0.1.0-alpha.2',[switch]$Package)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -cne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this script in native x64 Windows PowerShell 5.1.'
}
if ($Version.Length -gt 101 -or $Version -cnotmatch '^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.(0|[1-9][0-9]*)\z') {
    throw 'Version must be X.Y.Z-alpha.N, optionally prefixed with v.'
}
$Version=$Version -creplace '^v',''
$workspace=Split-Path -Parent $PSScriptRoot
$shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$results=[Collections.Generic.List[object]]::new()
$summaryDirectory=Join-Path $workspace 'out/ci'
[IO.Directory]::CreateDirectory($summaryDirectory) | Out-Null
$summaryPath=Join-Path $summaryDirectory 'verification-summary.json'
if (Test-Path -LiteralPath $summaryPath) { Remove-Item -LiteralPath $summaryPath }
function Invoke-Check([string]$Name,[string]$RelativePath,[string[]]$ScriptArguments=@()) {
    Write-Host "Running $Name"
    & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $workspace $RelativePath) @ScriptArguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
    $results.Add([ordered]@{Name=$Name;Status='PASS'})
}
$commit=& git -C $workspace rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[a-f0-9]{40}$') { throw 'A committed Git checkout is required.' }
Invoke-Check 'Native build, COM and HID PID protocol tests' 'tools/Build-Driver.ps1'
Invoke-Check 'Owner tools fixtures' 'tests/Owner-Tools.Tests.ps1'
Invoke-Check 'Release package fixtures and exported-source rebuild' 'tests/Release-Package.Tests.ps1' @('-RebuildExport')
$requiredFingerprint='B0F10001FCCD05E9863D84588BE9B9F8389656D95177287DD4C6CF3BE4BF1DFE'
$actualFingerprint=(Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32/dinput8.dll') -Algorithm SHA256).Hash
$fingerprintMatches=$actualFingerprint -ceq $requiredFingerprint
foreach ($suite in @(
    @{Name='Native installer registry fixtures';Path='tests/Install-SaitekFfbDriver.Tests.ps1'},
    @{Name='Release installer registry fixtures';Path='tests/Release-Installer.Tests.ps1'}
)) {
    if ($fingerprintMatches) { Invoke-Check $suite.Name $suite.Path }
    else {
        Write-Host "SKIP: $($suite.Name) requires the reviewed DirectInput binary. Production guards remain enabled."
        $results.Add([ordered]@{Name=$suite.Name;Status='SKIP';Reason='Runner DirectInput fingerprint differs from the reviewed production fingerprint.'})
    }
}
if ($Package) { Invoke-Check 'Release assembly' 'tools/Build-Release.ps1' @('-Version',$Version) }
$summary=[ordered]@{
    SchemaVersion=1;Version=$Version;GitCommit=$commit;Result='PASS';
    DirectInputFingerprintMatched=$fingerprintMatches;HardwareTested=$false;
    Checks=@($results.ToArray())
}
[IO.File]::WriteAllText($summaryPath,($summary | ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
if ($Package) {
    $releaseDirectory=Join-Path $workspace ('out/release/'+$Version)
    $releaseSummary=Join-Path $releaseDirectory 'verification-summary.json'
    [IO.File]::Copy($summaryPath,$releaseSummary,$false)
    $line=(Get-FileHash -LiteralPath $releaseSummary -Algorithm SHA256).Hash+'  verification-summary.json'+"`n"
    [IO.File]::AppendAllText((Join-Path $releaseDirectory 'SHA256SUMS.txt'),$line,[Text.UTF8Encoding]::new($false))
}
if ($env:GITHUB_STEP_SUMMARY) {
    $lines=@('## Offline verification',"Commit: ``$commit``",'', '| Check | Result |','| --- | --- |')
    foreach ($result in $results) { $lines+='| '+$result.Name+' | '+$result.Status+' |' }
    $lines+=@('','No hardware test was performed. SKIP means the installer suite requires a different, explicitly pinned DirectInput binary; it is not a passing test.')
    [IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY,($lines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
}
Write-Host "Offline verification complete for $Version ($commit)."
