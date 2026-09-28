#requires -Version 5.1
# Launch only the inspected Bridge/runtime pair. Settings affect this process only.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$BridgeDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-SaitekBridgeFileVersion([string]$Path) {
    [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion
}
function Get-SaitekBridgeHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Get-SaitekBridgeIdentity([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\ffb-bridge' }
    $Directory=[IO.Path]::GetFullPath($Directory)
    $exe=Join-Path $Directory 'FfbBridge.Desktop.exe'
    $dll=Join-Path $Directory 'FfbBridge.Desktop.dll'
    $config=Join-Path $Directory 'FfbBridge.Desktop.runtimeconfig.json'
    $core=Join-Path $Directory 'System.Private.CoreLib.dll'
    foreach ($path in @($exe,$dll,$config,$core)) {
        if (-not [IO.File]::Exists($path)) { throw 'Expected Bridge installation files are missing. Install the supported official Bridge separately or select its folder.' }
    }
    $appVersion=Get-SaitekBridgeFileVersion $exe
    $assemblyVersion=Get-SaitekBridgeFileVersion $dll
    if ($appVersion -cne '1.5.3.0' -or $assemblyVersion -cne '1.5.3.0') {
        throw 'This launcher requires exactly Bridge 1.5.3.0. Review an updated application before changing this guard.'
    }
    $runtime=[IO.File]::ReadAllText($config) | ConvertFrom-Json
    if ($runtime -isnot [pscustomobject] -or $runtime.runtimeOptions -isnot [pscustomobject] -or
        $runtime.runtimeOptions.tfm -isnot [string] -or $runtime.runtimeOptions.includedFrameworks -isnot [array]) { throw 'The bundled runtime config has invalid identity types.' }
    foreach ($framework in $runtime.runtimeOptions.includedFrameworks) {
        if ($framework -isnot [pscustomobject] -or $framework.name -isnot [string] -or $framework.version -isnot [string]) { throw 'The bundled framework identity has invalid types.' }
    }
    $frameworks=@($runtime.runtimeOptions.includedFrameworks | Where-Object {$_.name -ceq 'Microsoft.NETCore.App'})
    if ($runtime.runtimeOptions.tfm -cne 'net10.0' -or $frameworks.Count -ne 1 -or $frameworks[0].version -cne '10.0.12') {
        throw 'The bundled runtime differs from inspected .NET 10.0.12. Review its worker-retention setting before using this workaround.'
    }
    if ((Get-SaitekBridgeHash $core) -cne '1125ACC8106C43FC8BAD2D203C4C4485DF6182D292846C2FFF415C1040C54678') {
        throw 'The bundled CoreLib differs from the statically inspected runtime. Recheck ThreadsToKeepAlive before using this workaround.'
    }
    [pscustomobject]@{Directory=$Directory;Executable=$exe;ApplicationVersion=$appVersion}
}
function Get-SaitekBridgeProcesses { @(Get-Process -Name 'FfbBridge*' -ErrorAction SilentlyContinue) }
function Start-SaitekBridgeProcess($StartInfo) { [Diagnostics.Process]::Start($StartInfo) }
function Invoke-SaitekBridgeLaunch {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$Directory)
    $identity=Get-SaitekBridgeIdentity $Directory
    $startInfo=New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName=$identity.Executable
    $startInfo.WorkingDirectory=$identity.Directory
    $startInfo.UseShellExecute=$false
    $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Normal
    $startInfo.EnvironmentVariables['DOTNET_ThreadPool_ThreadsToKeepAlive']='-1'
    $startInfo.EnvironmentVariables['DOTNET_ThreadPool_UseWindowsThreadPool']='0'
    # Serialize the check/start pair; never stop or replace an existing process.
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,('Local\SaitekFfbBridgeLauncher-'+$sid))
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another Bridge launcher is already checking or starting the application.' }
        if (@(Get-SaitekBridgeProcesses).Count) { throw 'Bridge is already running. Fully exit it normally, including its tray icon, before using this launcher; no duplicate was started.' }
        if ($PSCmdlet.ShouldProcess($identity.Executable,'Start interactive Bridge with process-only worker retention (does not Arm)')) {
            $process=Start-SaitekBridgeProcess $startInfo
            if ($null -eq $process) { throw 'Windows did not return a Bridge process.' }
            try { [pscustomobject]@{ProcessId=$process.Id;ApplicationVersion=$identity.ApplicationVersion;BundledRuntime='10.0.12';ThreadsToKeepAlive=-1;UseWindowsThreadPool=$false} }
            finally { $process.Dispose() }
        }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
if ($MyInvocation.InvocationName -ne '.') { Invoke-SaitekBridgeLaunch -Directory $BridgeDirectory -WhatIf:$WhatIfPreference }
