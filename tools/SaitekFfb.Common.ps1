#requires -Version 5.1
# Original shared registry snapshots, safe paths, immutable backups and process guard.
# No payload identities, legacy patch logic or standalone mutation entrypoint.

function Assert-SaitekRegistryPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\') -or $Path.Contains('/') -or
        @($Path.Split('\') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count) {
        throw "Unsafe registry path: $Path"
    }
}

function Get-SaitekRegistryTree([Microsoft.Win32.RegistryKey]$Base, [string]$Path) {
    Assert-SaitekRegistryPath $Path
    $key = $Base.OpenSubKey($Path, $false)
    if ($null -eq $key) { return [pscustomobject]@{ Exists=$false; Values=@(); Children=@() } }
    try {
        $values = @($key.GetValueNames() | Sort-Object | ForEach-Object {
            $name = $_
            $kind = $key.GetValueKind($name).ToString()
            $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($kind -in @('Binary','None')) { $data = [Convert]::ToBase64String([byte[]]$data) }
            elseif ($kind -in @('DWord','QWord')) { $data = $data.ToString([Globalization.CultureInfo]::InvariantCulture) }
            elseif ($kind -eq 'MultiString') { $data = [string[]]$data }
            [pscustomobject]@{ Name=$name; Kind=$kind; Data=$data }
        })
        $children = @($key.GetSubKeyNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{ Name=$_; Tree=(Get-SaitekRegistryTree $Base ($Path + '\' + $_)) }
        })
        [pscustomobject]@{ Exists=$true; Values=$values; Children=$children }
    } finally { $key.Dispose() }
}

function Assert-SaitekTree($Tree, [int]$Depth = 0) {
    if ($Depth -gt 50 -or $null -eq $Tree -or $Tree.Exists -isnot [bool]) { throw 'Malformed registry backup tree.' }
    if (-not $Tree.Exists -and (@($Tree.Values).Count -or @($Tree.Children).Count)) { throw 'Absent registry key has contents.' }
    $valueNames = @{}
    foreach ($entry in @($Tree.Values)) {
        if ($entry.Name -isnot [string] -or $entry.Name.Contains([char]0) -or $valueNames.ContainsKey($entry.Name)) { throw 'Malformed or duplicate registry value name.' }
        $valueNames[$entry.Name] = $true
        switch ($entry.Kind) {
            { $_ -in @('Binary','None') } { [Convert]::FromBase64String($entry.Data) | Out-Null }
            'DWord' { [int]::Parse($entry.Data, [Globalization.CultureInfo]::InvariantCulture) | Out-Null }
            'QWord' { [long]::Parse($entry.Data, [Globalization.CultureInfo]::InvariantCulture) | Out-Null }
            { $_ -in @('String','ExpandString') } { if ($entry.Data -isnot [string]) { throw 'Malformed registry string.' } }
            'MultiString' { foreach ($part in @($entry.Data)) { if ($part -isnot [string]) { throw 'Malformed registry multi-string.' } } }
            default { throw "Unsupported registry value kind: $($entry.Kind)" }
        }
    }
    $childNames = @{}
    foreach ($entry in @($Tree.Children)) {
        if ($entry.Name -isnot [string] -or $entry.Name -match '[\\/\x00]' -or $entry.Name -in @('','.','..') -or $childNames.ContainsKey($entry.Name)) { throw 'Malformed or duplicate registry child name.' }
        $childNames[$entry.Name] = $true
        Assert-SaitekTree $entry.Tree ($Depth + 1)
        if (-not $entry.Tree.Exists) { throw 'Registry child marked absent.' }
    }
}

function Set-SaitekRegistryTree([Microsoft.Win32.RegistryKey]$Base, [string]$Path, $Tree) {
    Assert-SaitekRegistryPath $Path
    Assert-SaitekTree $Tree
    if (-not $Tree.Exists) { $Base.DeleteSubKeyTree($Path, $false); return }
    $key = $Base.CreateSubKey($Path)
    try {
        foreach ($name in $key.GetValueNames()) {
            if (@($Tree.Values | Where-Object { $_.Name -eq $name }).Count -eq 0) { $key.DeleteValue($name, $false) }
        }
        foreach ($entry in @($Tree.Values)) {
            $data = $entry.Data
            switch ($entry.Kind) {
                { $_ -in @('Binary','None') } { $data = [Convert]::FromBase64String($entry.Data) }
                'DWord' { $data = [int]::Parse($entry.Data, [Globalization.CultureInfo]::InvariantCulture) }
                'QWord' { $data = [long]::Parse($entry.Data, [Globalization.CultureInfo]::InvariantCulture) }
                'MultiString' { $data = [string[]]@($entry.Data) }
            }
            $key.SetValue($entry.Name, $data, [Microsoft.Win32.RegistryValueKind]::$($entry.Kind))
        }
        foreach ($name in $key.GetSubKeyNames()) {
            if (@($Tree.Children | Where-Object { $_.Name -eq $name }).Count -eq 0) { $key.DeleteSubKeyTree($name, $false) }
        }
        foreach ($entry in @($Tree.Children)) { Set-SaitekRegistryTree $Base ($Path + '\' + $entry.Name) $entry.Tree }
    } finally { $key.Dispose() }
}

function Test-SaitekTreeEqual($Left, $Right) {
    ($Left | ConvertTo-Json -Depth 100 -Compress) -ceq ($Right | ConvertTo-Json -Depth 100 -Compress)
}

function Set-SaitekTreeValue($Tree, [string]$Name, [string]$Kind, $Data) {
    $Tree.Values = @(@($Tree.Values | Where-Object { $_.Name -ne $Name }) + @([pscustomobject]@{Name=$Name; Kind=$Kind; Data=$Data}) | Sort-Object Name)
}

function Assert-SaitekSafePath([string]$Root, [string]$Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($pathFull -ne $rootFull -and -not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path outside repair storage: $Path" }
    # No junction/symlink redirection anywhere between this path and the volume root.
    $cursor = $pathFull
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point refused: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Write-SaitekNewJson([string]$Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 100
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Get-SaitekBackupDirectory($Context, [string]$Id) {
    if ($Id -notmatch '^[0-9]{8}T[0-9]{9}Z-[a-f0-9]{32}$') { throw 'Invalid backup identifier.' }
    $path = Join-Path $Context.Root "backups\$Id"
    Assert-SaitekSafePath $Context.Root $path
    $path
}

function Get-SaitekMissingParents($Context, [string]$Path) {
    $parts = $Path.Split('\')
    for ($n=1; $n -lt $parts.Count; $n++) {
        $parentPath = $parts[0..($n-1)] -join '\'
        $key = $Context.User.OpenSubKey($parentPath)
        if ($null -eq $key) { $parentPath } else { $key.Dispose() }
    }
}

function Get-SaitekPendingBackupIds($Context) {
    $directory = Join-Path $Context.Root 'backups'
    Assert-SaitekSafePath $Context.Root $directory
    if (Test-Path -LiteralPath $directory) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Directory | Sort-Object Name)) {
            $path = Get-SaitekBackupDirectory $Context $entry.Name
            if ((Test-Path -LiteralPath (Join-Path $path 'manifest.json')) -and
                -not (Test-Path -LiteralPath (Join-Path $path 'restored.json')) -and
                -not (Test-Path -LiteralPath (Join-Path $path 'rolled-back.json'))) { $entry.Name }
        }
    }
}

function Write-SaitekMarker($Context, [string]$Id, [string]$Name) {
    if ($Name -notin @('applied.json','restored.json','rolled-back.json')) { throw 'Invalid transaction marker.' }
    $path = Join-Path (Get-SaitekBackupDirectory $Context $Id) $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-SaitekNewJson $path ([pscustomobject]@{ Utc=[DateTime]::UtcNow.ToString('o'); UserSid=$Context.Sid })
    }
}

function Assert-SaitekApplicationsClosed {
    $running = @(Get-Process | Where-Object { $_.ProcessName -like 'FfbBridge*' -or $_.ProcessName -like 'X-Plane*' -or $_.ProcessName -like '*FfbProbe*' -or $_.ProcessName -like '*DirectInputProbe*' -or $_.ProcessName -eq 'SaitekProbe' })
    if ($running.Count) { throw ('Close these applications before Apply/Restore: ' + (($running | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ', ')) }
}
