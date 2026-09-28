[CmdletBinding()]
param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$workspacePath = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $workspacePath 'out\driver'
$sourcePath = Join-Path $workspacePath 'native\SaitekFfbDriver.cpp'
$transportPath = Join-Path $workspacePath 'native\HidPidDevice.cpp'
$testPath = Join-Path $workspacePath 'native\tests\DriverTests.cpp'
$exportsPath = Join-Path $workspacePath 'native\SaitekFfbDriver.def'
$protocolTestRunner = Join-Path $workspacePath 'tests\Run-HidPidTests.ps1'
$sourceFiles = @($sourcePath, $transportPath, (Join-Path $workspacePath 'native\HidPidDevice.h'),
    $exportsPath, $testPath, (Join-Path $workspacePath 'tests\HidPidDeviceTests.cpp'), $protocolTestRunner, $PSCommandPath)
$initialHashes = @($sourceFiles | ForEach-Object {
    [ordered]@{ Path = $_; Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash }
})
$manifestPath = Join-Path $outputDirectory 'build-manifest.json'
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
$vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswherePath)) { throw 'Visual Studio vswhere.exe was not found.' }
$installationPath = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installationPath) { throw 'Visual Studio C++ x64 Build Tools are required.' }
Import-Module -Name (Join-Path $installationPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $installationPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$compilerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Get-Command cl.exe -CommandType Application).Source).FileVersion
$sdkVersion = $env:WindowsSDKVersion.TrimEnd('\')
if ($compilerVersion -notmatch '^\d+(\.\d+){2,3}$' -or $sdkVersion -notmatch '^\d+(\.\d+){2,3}$') {
    throw 'Compiler/Windows SDK identity could not be constrained to numeric versions.'
}
# Relative command identity deliberately contains no machine/user/toolchain paths.
$buildIdentity = [ordered]@{
    Compiler = 'MSVC cl.exe ' + $compilerVersion + ' x64'
    WindowsSdk = $sdkVersion
    Command = 'cl.exe /nologo /std:c++17 /EHsc /W4 /WX /O2 /MT /utf-8 /DUNICODE /D_UNICODE /LD native/SaitekFfbDriver.cpp native/HidPidDevice.cpp /Foout/driver/ /Feout/driver/SaitekFfbDriver.dll /Fdout/driver/SaitekFfbDriver.pdb /link dxguid.lib ole32.lib hid.lib /MACHINE:X64 /WX /DEF:native/SaitekFfbDriver.def /IMPLIB:out/driver/SaitekFfbDriver.lib'
}
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$libraryPath = Join-Path $outputDirectory 'SaitekFfbDriver.dll'
$commonArguments = @('/nologo', '/std:c++17', '/EHsc', '/W4', '/WX', '/O2', '/MT', '/utf-8', '/DUNICODE', '/D_UNICODE')
$objectDirectoryPrefix = '/Fo' + ($outputDirectory -replace '\\', '/') + '/'
$driverArguments = $commonArguments + @('/LD', $sourcePath, $transportPath, $objectDirectoryPrefix,
    ('/Fe' + $libraryPath), ('/Fd' + (Join-Path $outputDirectory 'SaitekFfbDriver.pdb')),
    '/link', 'dxguid.lib', 'ole32.lib', 'hid.lib', '/MACHINE:X64', '/WX', ('/DEF:' + $exportsPath),
    ('/IMPLIB:' + (Join-Path $outputDirectory 'SaitekFfbDriver.lib')))
& cl.exe @driverArguments
if ($LASTEXITCODE -ne 0) { throw "Native driver build failed: exit $LASTEXITCODE" }
if (-not $SkipTests) {
    $testExecutablePath = Join-Path $outputDirectory 'DriverTests.exe'
    $testArguments = $commonArguments + @($testPath, $transportPath, $objectDirectoryPrefix,
        ('/Fe' + $testExecutablePath), ('/Fd' + (Join-Path $outputDirectory 'DriverTests.pdb')),
        '/link', 'dxguid.lib', 'ole32.lib', 'hid.lib', '/MACHINE:X64',
        ('/IMPLIB:' + (Join-Path $outputDirectory 'DriverTests.lib')))
    & cl.exe @testArguments
    if ($LASTEXITCODE -ne 0) { throw "COM contract test build failed: exit $LASTEXITCODE" }
    & $testExecutablePath
    if ($LASTEXITCODE -ne 0) { throw "COM contract tests failed: exit $LASTEXITCODE" }
    & $protocolTestRunner
    if ($LASTEXITCODE -ne 0) { throw "HID PID protocol tests failed: exit $LASTEXITCODE" }
}
foreach ($sourceHash in $initialHashes) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourceHash.Path).Hash -ne $sourceHash.Sha256) {
        throw "Source changed during build; rebuild before installation: $($sourceHash.Path)"
    }
}
$manifest = [ordered]@{
    SchemaVersion = 1
    Clsid = '{1DB0C28F-6D99-416E-8D05-73DE59E6E170}'
    Architecture = 'x64'
    BinaryPath = $libraryPath
    BinarySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $libraryPath).Hash
    SourceHashes = $initialHashes
    OfflineComTestsPassed = -not $SkipTests
    OfflineProtocolTestsPassed = -not $SkipTests
    HardwareValidated = $false
    Build = $buildIdentity
    RegistryMetadata = [ordered]@{
        DeviceFlags = 0 # DIFFDEVICEATTRIBUTES.dwFlags is reserved; effect capabilities are in each effect's attributes.
        FFSamplePeriod = 1000
        FFMinTimeResolution = 1000
        Effects = @(
            [ordered]@{ Name='Constant Force'; Guid='{13541C20-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x26; Type=0x8601; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Square Wave'; Guid='{13541C22-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x30; Type=0x8603; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Sine Wave'; Guid='{13541C23-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x31; Type=0x8603; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Triangle Wave'; Guid='{13541C24-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x32; Type=0x8603; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Sawtooth Up'; Guid='{13541C25-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x33; Type=0x8603; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Sawtooth Down'; Guid='{13541C26-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x34; Type=0x8603; StaticParams=0x3E5; DynamicParams=0x144; Coords=0x20 }
            [ordered]@{ Name='Spring'; Guid='{13541C27-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x40; Type=0xF804; StaticParams=0x325; DynamicParams=0x104; Coords=0x20 }
            [ordered]@{ Name='Damper'; Guid='{13541C28-8E33-11D0-9AD0-00A0C9A06E35}'; Id=0x41; Type=0xF804; StaticParams=0x325; DynamicParams=0x104; Coords=0x20 }
        )
    }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Output $libraryPath
