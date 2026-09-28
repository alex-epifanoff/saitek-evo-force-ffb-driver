[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$workspacePath = Split-Path -Parent $PSScriptRoot
$vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installationPath = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installationPath) { throw 'MSVC Build Tools are required.' }
Import-Module (Join-Path $installationPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $installationPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$outputPath = Join-Path $workspacePath 'out\tests-hidpid'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$executablePath = Join-Path $outputPath 'HidPidDeviceTests.exe'
$compilerArguments = @('/nologo','/std:c++17','/EHsc','/W4','/WX','/O2','/MT','/utf-8','/DUNICODE','/D_UNICODE','/DSAITEK_PROTOCOL_TESTS',
    (Join-Path $workspacePath 'native\HidPidDevice.cpp'),(Join-Path $PSScriptRoot 'HidPidDeviceTests.cpp'),
    ('/Fo'+($outputPath -replace '\\','/')+'/'),('/Fe'+$executablePath),'/link','hid.lib','/MACHINE:X64')
& cl.exe @compilerArguments
if ($LASTEXITCODE -ne 0) { throw 'HID PID tests did not compile.' }
& $executablePath
if ($LASTEXITCODE -ne 0) { throw 'HID PID tests failed.' }
