[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('validate', 'test', 'build', 'deploy', 'run', 'stop', 'status', 'cleanup', 'select')]
    [string]$Command,

    [string]$Profile = 'configs\quad_x.json',
    [string]$Settings = 'settings.local.json',
    [string]$RunId,
    [int]$ReadyTimeoutSeconds = 120,
    [switch]$AllowClassIdConflict,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$processToolsPath = Join-Path $script:ProjectRoot 'scripts\RflyUav.ProcessTools.psm1'
Import-Module $processToolsPath -Force

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Convert-WindowsPathToWsl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Cannot convert path to WSL form: $fullPath"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $tail = $Matches[2].Replace('\', '/')
    return "/mnt/$drive/$tail"
}

function Quote-BashString {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains("'")) {
        throw "A single quote is not supported in a WSL launcher argument: $Value"
    }
    return "'$Value'"
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file does not exist: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Quote-MatlabString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-Settings {
    $settingsPath = Resolve-ProjectPath $Settings
    $value = Read-JsonFile $settingsPath
    foreach ($required in @('matlab_exe', 'rfly_root', 'wsl_exe', 'wsl_distro', 'px4_sources')) {
        if (-not $value.PSObject.Properties.Name.Contains($required)) {
            throw "Missing setting '$required' in $settingsPath"
        }
    }
    return $value
}

function Invoke-MatlabBatch {
    param(
        [Parameter(Mandatory = $true)][psobject]$LocalSettings,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not (Test-Path -LiteralPath $LocalSettings.matlab_exe -PathType Leaf)) {
        throw "MATLAB executable does not exist: $($LocalSettings.matlab_exe)"
    }
    & $LocalSettings.matlab_exe -batch $Code
    if ($LASTEXITCODE -ne 0) {
        throw "MATLAB batch failed with exit code $LASTEXITCODE."
    }
}

function Invoke-ProfileValidation {
    param([psobject]$LocalSettings, [string]$ProfilePath)
    $sourcePath = Join-Path $script:ProjectRoot 'src'
    $code = "addpath($(Quote-MatlabString $sourcePath)); rfly_validate_profile_file($(Quote-MatlabString $ProfilePath));"
    Invoke-MatlabBatch -LocalSettings $LocalSettings -Code $code
}

function Get-BuildCacheKey {
    param([string]$ProfilePath)
    $inputs = @(
        $ProfilePath,
        (Join-Path $script:ProjectRoot 'model\ParametricUAV_Max.slx'),
        (Join-Path $script:ProjectRoot 'model\ParametricUAV_Max_init.m'),
        (Join-Path $script:ProjectRoot 'model\GenerateModelDLLFile.p')
    )
    $inputs += Get-ChildItem -LiteralPath (Join-Path $script:ProjectRoot 'src') -Filter '*.m' |
        Sort-Object FullName | ForEach-Object FullName
    $hashLines = foreach ($inputPath in $inputs) {
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "Build input does not exist: $inputPath"
        }
        (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($hashLines -join "`n"))
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-BuildArtifact {
    param([psobject]$LocalSettings, [string]$ProfilePath)
    $profileData = Read-JsonFile $ProfilePath
    if (-not $profileData.profile_id) {
        throw "Profile does not define profile_id: $ProfilePath"
    }
    $cacheKey = Get-BuildCacheKey $ProfilePath
    $cacheDirectory = Join-Path $script:ProjectRoot ("artifacts\cache\" + $cacheKey)
    $dllPath = Join-Path $cacheDirectory ($profileData.profile_id + '.dll')
    $xmlPath = Join-Path $cacheDirectory ($profileData.profile_id + '.xml')
    $manifestPath = Join-Path $cacheDirectory 'manifest.json'
    $cacheHit = (Test-Path -LiteralPath $dllPath -PathType Leaf) -and
        (Test-Path -LiteralPath $xmlPath -PathType Leaf) -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf)

    if (-not $cacheHit) {
        New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        $sourcePath = Join-Path $script:ProjectRoot 'src'
        $code = "addpath($(Quote-MatlabString $sourcePath)); rfly_build_model($(Quote-MatlabString $ProfilePath),$(Quote-MatlabString $cacheDirectory));"
        Invoke-MatlabBatch -LocalSettings $LocalSettings -Code $code
    }

    if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
        throw "Cached DLL is missing after build: $dllPath"
    }
    [pscustomobject]@{
        CacheKey = $cacheKey
        CacheHit = $cacheHit
        CacheDirectory = $cacheDirectory
        Dll = $dllPath
        Xml = $xmlPath
        Manifest = $manifestPath
        Profile = $profileData
    }
}

function Get-XmlClassId {
    param([string]$Path)
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($null -ne $xml.vehicle.ClassID) {
            return [int]$xml.vehicle.ClassID
        }
    } catch {
        return $null
    }
    return $null
}

function Install-BuildArtifact {
    param([psobject]$LocalSettings, [psobject]$Artifact)
    $rflyRoot = [IO.Path]::GetFullPath([string]$LocalSettings.rfly_root)
    $modelDirectory = Join-Path $rflyRoot 'CopterSim\external\model'
    $visualDirectory = Join-Path $rflyRoot 'RflySim3D\RflySim3D\Plugins\Rfly3DSimPlugin\Content\XML'
    if (-not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
        throw "RflySim deployment directory does not exist: $modelDirectory"
    }

    $classId = [int]$Artifact.Profile.visual.class_id
    $targetDll = Join-Path $modelDirectory ([IO.Path]::GetFileName($Artifact.Dll))
    if (Test-Path -LiteralPath $targetDll -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $Artifact.Dll -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $targetDll -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            $cacheRoot = Join-Path $script:ProjectRoot 'artifacts\cache'
            $knownPrevious = Get-ChildItem -LiteralPath $cacheRoot -Filter ([IO.Path]::GetFileName($targetDll)) -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $targetHash } |
                Select-Object -First 1
            if (-not $knownPrevious) {
                throw "Deployment target has different content not found in this project's cache; refusing to overwrite: $targetDll"
            }
            Write-Host "Updating project-managed DLL. Recoverable previous copy: $($knownPrevious.FullName)"
        }
    }
    $installMode = [string]$Artifact.Profile.visual.install_mode
    $targetXml = $null
    $installGeneratedXml = $false
    switch ($installMode) {
        'builtin' {
            Write-Host "Using built-in RflySim3D ClassID $classId; no visual XML was installed."
        }
        'reuse_existing' {
            if (-not (Test-Path -LiteralPath $visualDirectory -PathType Container)) {
                throw "RflySim3D XML directory does not exist: $visualDirectory"
            }
            $targetXml = Join-Path $visualDirectory ([string]$Artifact.Profile.visual.existing_xml_name)
            if (-not (Test-Path -LiteralPath $targetXml -PathType Leaf)) {
                throw "Configured existing visual XML does not exist: $targetXml"
            }
            $existingClassId = Get-XmlClassId $targetXml
            if ($existingClassId -ne $classId) {
                throw "Existing visual XML ClassID $existingClassId does not match configured ClassID $classId`: $targetXml"
            }
            Write-Host "Reusing existing visual XML: $targetXml"
        }
        'generated' {
            if (-not (Test-Path -LiteralPath $visualDirectory -PathType Container)) {
                throw "RflySim3D XML directory does not exist: $visualDirectory"
            }
            $targetXml = Join-Path $visualDirectory ([IO.Path]::GetFileName($Artifact.Xml))
            $conflicts = Get-ChildItem -LiteralPath $visualDirectory -Filter '*.xml' |
                Where-Object { (Get-XmlClassId $_.FullName) -eq $classId -and $_.FullName -ne $targetXml }
            if ($conflicts -and -not $AllowClassIdConflict) {
                $names = ($conflicts.FullName -join [Environment]::NewLine)
                throw "Visual ClassID $classId already exists. Generated XML was not installed. Conflicting files:`n$names"
            }
            if (Test-Path -LiteralPath $targetXml -PathType Leaf) {
                $sourceHash = (Get-FileHash -LiteralPath $Artifact.Xml -Algorithm SHA256).Hash
                $targetHash = (Get-FileHash -LiteralPath $targetXml -Algorithm SHA256).Hash
                if ($sourceHash -ne $targetHash) {
                    throw "Visual XML already exists with different content; refusing to overwrite: $targetXml"
                }
            }
            $installGeneratedXml = $true
        }
        default {
            throw "Unsupported visual.install_mode: $installMode"
        }
    }
    Copy-Item -LiteralPath $Artifact.Dll -Destination $targetDll -Force
    if ($installGeneratedXml) {
        Copy-Item -LiteralPath $Artifact.Xml -Destination $targetXml -Force
    }
    [pscustomobject]@{ Dll = $targetDll; VisualMode = $installMode; Xml = $targetXml }
}

function Get-ScopedSimulationProcesses {
    $names = @('CopterSim', 'RflySim3D', 'QGroundControl')
    return Get-Process -Name $names -ErrorAction SilentlyContinue
}

function Get-RunRecords {
    $runsRoot = Join-Path $script:ProjectRoot 'logs\runs'
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
        return @()
    }
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $runsRoot -Filter 'run.json' -Recurse -File)) {
        try {
            $records += [pscustomobject]@{
                Path = $file.FullName
                Data = Read-JsonFile $file.FullName
            }
        } catch {
            Write-Warning "Ignoring unreadable run record: $($file.FullName)"
        }
    }
    return $records
}

function Get-ConfiguredWslProcessScope {
    param([Parameter(Mandatory = $true)][psobject]$LocalSettings)

    $roots = @()
    $helpers = @()
    foreach ($sourceProperty in @($LocalSettings.px4_sources.PSObject.Properties)) {
        $source = $sourceProperty.Value
        if ($source.wsl_path) {
            $roots += ([string]$source.wsl_path).TrimEnd('/')
        }
        if ($source.helper_wsl) {
            $helpers += [string]$source.helper_wsl
        }
    }
    return [pscustomobject]@{
        Roots = @($roots | Sort-Object -Unique)
        Helpers = @($helpers | Sort-Object -Unique)
    }
}

function Get-WslSimulationProcesses {
    param([Parameter(Mandatory = $true)][psobject]$LocalSettings)

    $scope = Get-ConfiguredWslProcessScope -LocalSettings $LocalSettings
    $rootLiterals = @($scope.Roots | ForEach-Object { Quote-BashString $_ }) -join ' '
    $helperLiterals = @($scope.Helpers | ForEach-Object { Quote-BashString $_ }) -join ' '
    $template = @'
roots=(__ROOTS__)
helpers=(__HELPERS__)
for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    if [[ "$pid" == "$$" || "$pid" == "$PPID" ]]; then
        continue
    fi
    exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
    cwd=$(readlink -f "$proc/cwd" 2>/dev/null || true)
    cmd=$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)
    kind=""
    for root in "${roots[@]}"; do
        if [[ "$exe" == "$root/build/px4_sitl_default/bin/px4" ]] || \
                [[ "$exe" == */px4 && "$cwd" == "$root/build/px4_sitl_default/instance_"* ]]; then
            kind="px4"
            break
        fi
    done
    if [[ -z "$kind" ]]; then
        for helper in "${helpers[@]}"; do
            if [[ -n "$helper" && "$cmd" == *"$helper"* ]]; then
                kind="launcher"
                break
            fi
        done
    fi
    if [[ -n "$kind" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$kind" "$exe" "$cwd" "$cmd"
    fi
done
'@
    $bashCode = $template.Replace('__ROOTS__', $rootLiterals).Replace('__HELPERS__', $helperLiterals)
    $encodedBashCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bashCode))
    $wslLaunchCode = "printf '%s' '$encodedBashCode' | base64 -d | bash"
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $LocalSettings.wsl_exe -d ([string]$LocalSettings.wsl_distro) -- bash -lc $wslLaunchCode 2>&1)
        $wslExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($wslExitCode -ne 0) {
        $detail = (@($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
        throw "Could not inspect WSL processes in $($LocalSettings.wsl_distro).`n$detail"
    }

    $processes = @()
    foreach ($line in $output) {
        $parts = ([string]$line) -split "`t", 5
        $processId = 0
        if ($parts.Count -ne 5 -or -not [int]::TryParse($parts[0], [ref]$processId)) {
            continue
        }
        $processes += [pscustomobject]@{
            Id = $processId
            Kind = $parts[1]
            ExecutablePath = $parts[2]
            WorkingDirectory = $parts[3]
            CommandLine = $parts[4]
        }
    }
    return $processes
}

function Get-WindowsSimulationProcesses {
    param([object[]]$RunRecords)

    $runIdsByPid = @{}
    foreach ($recordEntry in @($RunRecords)) {
        $record = $recordEntry.Data
        $pids = @($record.pids)
        for ($index = 0; $index -lt $pids.Count; $index++) {
            $processId = [int]$pids[$index]
            if (-not $runIdsByPid.ContainsKey($processId)) {
                $runIdsByPid[$processId] = @()
            }
            $runIdsByPid[$processId] += [string]$record.run_id
        }
    }

    $byPid = @{}
    foreach ($process in @(Get-ScopedSimulationProcesses)) {
        $byPid[[int]$process.Id] = $process
    }
    foreach ($recordEntry in @($RunRecords)) {
        $record = $recordEntry.Data
        $pids = @($record.pids)
        $names = @($record.process_names)
        for ($index = 0; $index -lt $pids.Count; $index++) {
            if ($index -ge $names.Count -or [string]$names[$index] -ne 'wsl') {
                continue
            }
            $process = Get-Process -Id ([int]$pids[$index]) -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -eq 'wsl') {
                $byPid[[int]$process.Id] = $process
            }
        }
    }

    $items = @()
    foreach ($processId in @($byPid.Keys | Sort-Object)) {
        $process = $byPid[$processId]
        $path = $null
        try { $path = $process.Path } catch { }
        $runIds = @()
        if ($runIdsByPid.ContainsKey([int]$processId)) {
            $runIds = @($runIdsByPid[[int]$processId] | Sort-Object -Unique)
        }
        $items += [pscustomobject]@{
            Id = [int]$processId
            ProcessName = [string]$process.ProcessName
            Path = $path
            RunIds = $runIds
        }
    }
    return $items
}

function Get-SimulationInventory {
    param([Parameter(Mandatory = $true)][psobject]$LocalSettings)

    $records = @(Get-RunRecords)
    return [pscustomobject]@{
        Windows = @(Get-WindowsSimulationProcesses -RunRecords $records)
        Wsl = @(Get-WslSimulationProcesses -LocalSettings $LocalSettings)
        RunRecords = $records
    }
}

function Show-SimulationInventory {
    param([Parameter(Mandatory = $true)][psobject]$Inventory)

    if (-not (Test-RflyInventoryActive -Inventory $Inventory)) {
        Write-Host 'No project-related simulation processes are running.'
        return
    }
    Write-Host 'Project-related simulation processes:'
    foreach ($item in @($Inventory.Windows)) {
        $runText = if (@($item.RunIds).Count -gt 0) { @($item.RunIds) -join ',' } else { '-' }
        $pathText = if ($item.Path) { $item.Path } else { '-' }
        Write-Host ("  Windows {0} PID={1} Path={2} RunId={3}" -f $item.ProcessName, $item.Id, $pathText, $runText)
    }
    foreach ($item in @($Inventory.Wsl)) {
        Write-Host ("  WSL {0} PID={1} Exe={2} Cwd={3}" -f $item.Kind, $item.Id, $item.ExecutablePath, $item.WorkingDirectory)
    }
}

function Stop-WindowsInventoryItems {
    param([object[]]$Items)

    $live = @()
    foreach ($item in @($Items)) {
        $process = Get-Process -Id ([int]$item.Id) -ErrorAction SilentlyContinue
        if (-not $process -or $process.ProcessName -ne [string]$item.ProcessName) {
            continue
        }
        try { [void]$process.CloseMainWindow() } catch { }
        $live += $item
    }
    if ($live.Count -gt 0) {
        Start-Sleep -Seconds 2
    }
    foreach ($item in $live) {
        $process = Get-Process -Id ([int]$item.Id) -ErrorAction SilentlyContinue
        if ($process -and $process.ProcessName -eq [string]$item.ProcessName) {
            Stop-Process -Id $process.Id -Force
        }
    }
    if ($live.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
    foreach ($item in $live) {
        $process = Get-Process -Id ([int]$item.Id) -ErrorAction SilentlyContinue
        if (-not $process -or $process.ProcessName -ne [string]$item.ProcessName) {
            continue
        }
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & taskkill.exe /PID ([string]$process.Id) /T /F 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $previousErrorPreference
        }
    }
}

function Send-WslSignal {
    param(
        [Parameter(Mandatory = $true)][psobject]$LocalSettings,
        [Parameter(Mandatory = $true)][ValidateSet('TERM', 'KILL')][string]$Signal,
        [int[]]$ProcessIds
    )

    $safeIds = @($ProcessIds | Where-Object { $_ -gt 1 } | Sort-Object -Unique)
    if ($safeIds.Count -eq 0) {
        return
    }
    $bashCode = 'for pid in ' + ($safeIds -join ' ') + '; do ' +
        'if kill -0 "$pid" 2>/dev/null; then kill -' + $Signal + ' -- "$pid" 2>/dev/null || true; fi; done'
    $encodedBashCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bashCode))
    $wslLaunchCode = "printf '%s' '$encodedBashCode' | base64 -d | bash"
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $LocalSettings.wsl_exe -d ([string]$LocalSettings.wsl_distro) -- bash -lc $wslLaunchCode 2>$null | Out-Null
        $wslExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($wslExitCode -ne 0) {
        throw "Could not send SIG$Signal to scoped WSL processes."
    }
}

function Stop-WslInventoryItems {
    param(
        [Parameter(Mandatory = $true)][psobject]$LocalSettings,
        [object[]]$Items
    )

    $targetIds = @($Items | ForEach-Object { [int]$_.Id })
    if ($targetIds.Count -eq 0) {
        return
    }
    $current = @(Get-WslSimulationProcesses -LocalSettings $LocalSettings | Where-Object { $targetIds -contains [int]$_.Id })
    $px4Ids = @($current | Where-Object Kind -eq 'px4' | ForEach-Object { [int]$_.Id })
    $launcherIds = @($current | Where-Object Kind -eq 'launcher' | ForEach-Object { [int]$_.Id })
    Send-WslSignal -LocalSettings $LocalSettings -Signal TERM -ProcessIds $px4Ids
    Send-WslSignal -LocalSettings $LocalSettings -Signal TERM -ProcessIds $launcherIds
    Start-Sleep -Seconds 2
    $remaining = @(Get-WslSimulationProcesses -LocalSettings $LocalSettings | Where-Object { $targetIds -contains [int]$_.Id })
    Send-WslSignal -LocalSettings $LocalSettings -Signal KILL -ProcessIds @($remaining | ForEach-Object { [int]$_.Id })
}

function Update-StoppedRunRecords {
    param(
        [Parameter(Mandatory = $true)][psobject]$Inventory,
        [Parameter(Mandatory = $true)][string]$StopMode
    )

    $runIds = @($Inventory.Windows | ForEach-Object { @($_.RunIds) } | Sort-Object -Unique)
    if ($runIds.Count -eq 0) {
        return
    }
    foreach ($entry in @($Inventory.RunRecords)) {
        if ($runIds -notcontains [string]$entry.Data.run_id) {
            continue
        }
        $entry.Data | Add-Member -NotePropertyName stopped_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $entry.Data | Add-Member -NotePropertyName stop_mode -NotePropertyValue $StopMode -Force
        $entry.Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $entry.Path -Encoding UTF8
    }
}

function Invoke-SimulationCleanup {
    param(
        [Parameter(Mandatory = $true)][psobject]$LocalSettings,
        [switch]$SkipConfirmation
    )

    $inventory = Get-SimulationInventory -LocalSettings $LocalSettings
    Show-SimulationInventory -Inventory $inventory
    if (-not (Test-RflyInventoryActive -Inventory $inventory)) {
        return
    }
    if (-not $SkipConfirmation) {
        $answer = Read-Host 'Close all listed processes? [y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host 'Cleanup cancelled; no process was stopped.'
            return
        }
    }

    Stop-WindowsInventoryItems -Items @($inventory.Windows | Where-Object ProcessName -eq 'CopterSim')
    Stop-WslInventoryItems -LocalSettings $LocalSettings -Items @($inventory.Wsl)
    Stop-WindowsInventoryItems -Items @($inventory.Windows | Where-Object { $_.ProcessName -in @('RflySim3D', 'QGroundControl') })
    Stop-WindowsInventoryItems -Items @($inventory.Windows | Where-Object ProcessName -eq 'wsl')

    $remaining = Get-SimulationInventory -LocalSettings $LocalSettings
    if (Test-RflyInventoryActive -Inventory $remaining) {
        Show-SimulationInventory -Inventory $remaining
        throw 'Some project-related simulation processes could not be stopped.'
    }
    Update-StoppedRunRecords -Inventory $inventory -StopMode 'cleanup'
    Write-Host 'Cleanup complete. PX4 instances and related applications are stopped.'
}

function Start-Simulation {
    param([psobject]$LocalSettings, [psobject]$Artifact, [psobject]$Deployment)
    $existing = Get-SimulationInventory -LocalSettings $LocalSettings
    if (Test-RflyInventoryActive -Inventory $existing) {
        Show-SimulationInventory -Inventory $existing
        throw 'Existing simulation processes were found before GUI startup. Run .\cleanup-sim.cmd first.'
    }
    $runStartedAt = Get-Date

    $profileData = $Artifact.Profile
    $sourceKey = [string]$profileData.px4.source_key
    $source = $LocalSettings.px4_sources.$sourceKey
    if ($null -eq $source) {
        throw "settings.local.json does not define px4_sources.$sourceKey"
    }
    $px4Binary = Join-Path ([string]$source.windows_path) 'build\px4_sitl_default\bin\px4'
    if (-not (Test-Path -LiteralPath $px4Binary -PathType Leaf)) {
        throw "PX4 SITL binary does not exist: $px4Binary"
    }

    $runIdValue = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $profileData.profile_id
    $runDirectory = Join-Path $script:ProjectRoot ("logs\runs\" + $runIdValue)
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $rflyRoot = [string]$LocalSettings.rfly_root
    $qgc = Join-Path $rflyRoot 'QGroundControl\QGroundControl.exe'
    $rfly3d = Join-Path $rflyRoot 'RflySim3D\RflySim3D.exe'
    $copterSim = Join-Path $rflyRoot 'CopterSim\CopterSim.exe'
    foreach ($required in @($qgc, $rfly3d, $copterSim, [string]$LocalSettings.wsl_exe)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Runtime executable does not exist: $required"
        }
    }

    Start-Process -FilePath $qgc -ArgumentList '-noComPix' | Out-Null
    Start-Process -FilePath $rfly3d | Out-Null
    Start-Sleep -Seconds 5
    $vehicleId = [int]$profileData.simulation.vehicle_id
    $classId = [int]$profileData.visual.class_id
    $dllName = [string]$profileData.profile_id
    $map = [string]$profileData.simulation.map
    $udpMode = [string]$profileData.simulation.udp_mode
    $copterArgs = @('1', "$vehicleId", "$classId", $dllName, '2', $map, '0', '0', '0', '0', '1', $udpMode)
    Start-Process -FilePath $copterSim -ArgumentList $copterArgs -WorkingDirectory (Split-Path $copterSim) | Out-Null

    $frame = [string]$profileData.px4.sitl_frame
    $px4Wsl = [string]$source.wsl_path
    $launcherPath = Join-Path $runDirectory 'px4-launch.sh'
    if ([string]$source.launch_style -eq 'helper') {
        $helper = [string]$source.helper_wsl
        $launcherLines = @(
            '#!/usr/bin/env bash',
            'set -e',
            ('exec ' + (Quote-BashString $helper) + ' ' + (Quote-BashString $px4Wsl) + ' 1 ' + (Quote-BashString "$vehicleId") + ' ' + (Quote-BashString $frame))
        )
    } else {
        $launcherLines = @(
            '#!/usr/bin/env bash',
            'set -e',
            ('cd ' + (Quote-BashString $px4Wsl)),
            'source ./BkFile/EnvOri.sh',
            ('source ./Tools/sitl_multiple_run_rfly.sh 1 ' + (Quote-BashString "$vehicleId") + ' ' + (Quote-BashString $frame)),
            'wait'
        )
    }
    $launcherText = ($launcherLines -join "`n") + "`n"
    [IO.File]::WriteAllText($launcherPath, $launcherText, [Text.UTF8Encoding]::new($false))
    $launcherWslPath = Convert-WindowsPathToWsl $launcherPath
    $stdoutPath = Join-Path $runDirectory 'px4.stdout.log'
    $stderrPath = Join-Path $runDirectory 'px4.stderr.log'
    $px4InstanceLog = Join-Path ([string]$source.windows_path) ("build\px4_sitl_default\instance_$vehicleId\out.log")
    $wslArgs = @('-d', [string]$LocalSettings.wsl_distro, '--', 'bash', $launcherWslPath)
    $wslProcess = Start-Process -FilePath $LocalSettings.wsl_exe -ArgumentList $wslArgs -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
    $managedProcesses = @(Get-ScopedSimulationProcesses)
    $managedProcesses += $wslProcess
    $managedProcesses = @($managedProcesses | Sort-Object Id -Unique)

    $record = [ordered]@{
        run_id = $runIdValue
        profile_id = [string]$profileData.profile_id
        started_at = (Get-Date).ToUniversalTime().ToString('o')
        pids = @($managedProcesses | ForEach-Object { [int]$_.Id })
        process_names = @($managedProcesses | ForEach-Object { $_.ProcessName })
        stdout = $stdoutPath
        stderr = $stderrPath
        px4_instance_log = $px4InstanceLog
        launcher_script = $launcherPath
        deployment = $Deployment
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'run.json') -Encoding UTF8

    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($wslProcess.HasExited) {
            throw "PX4 launcher exited before readiness. Inspect $stdoutPath and $stderrPath"
        }
        foreach ($readyLog in @($stdoutPath, $px4InstanceLog)) {
            if ((Test-Path -LiteralPath $readyLog -PathType Leaf) -and
                    (Get-Item -LiteralPath $readyLog).LastWriteTime -ge $runStartedAt -and
                    (Select-String -LiteralPath $readyLog -SimpleMatch 'Ready for takeoff!' -Quiet)) {
                $readinessEvidence = Join-Path $runDirectory 'readiness.log'
                Copy-Item -LiteralPath $readyLog -Destination $readinessEvidence -Force
                $record['ready_at'] = (Get-Date).ToUniversalTime().ToString('o')
                $record['readiness_source'] = $readyLog
                $record['readiness_log'] = $readinessEvidence
                $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirectory 'run.json') -Encoding UTF8
                Write-Host "Ready for takeoff! RunId=$runIdValue Log=$readyLog Evidence=$readinessEvidence"
                return
            }
        }
        Start-Sleep -Seconds 2
        $wslProcess.Refresh()
    }
    throw "Timed out waiting for 'Ready for takeoff!'. Run remains active. RunId=$runIdValue"
}

function Invoke-RunProfile {
    param(
        [Parameter(Mandatory = $true)][psobject]$LocalSettings,
        [Parameter(Mandatory = $true)][string]$SelectedProfilePath
    )

    $existing = Get-SimulationInventory -LocalSettings $LocalSettings
    if (Test-RflyInventoryActive -Inventory $existing) {
        Show-SimulationInventory -Inventory $existing
        throw 'Existing simulation processes were found before validation, build, deployment, or GUI startup. Run .\cleanup-sim.cmd first.'
    }

    Invoke-ProfileValidation -LocalSettings $LocalSettings -ProfilePath $SelectedProfilePath
    $artifact = Get-BuildArtifact -LocalSettings $LocalSettings -ProfilePath $SelectedProfilePath
    $deployment = Install-BuildArtifact -LocalSettings $LocalSettings -Artifact $artifact
    Start-Simulation -LocalSettings $LocalSettings -Artifact $artifact -Deployment $deployment
}

function Invoke-ProfileSelector {
    param([Parameter(Mandatory = $true)][psobject]$LocalSettings)

    $catalog = @(Get-RflyProfileCatalog -ConfigDirectory (Join-Path $script:ProjectRoot 'configs'))
    if ($catalog.Count -eq 0) {
        throw 'No selectable JSON profiles were found in the configs directory.'
    }

    Write-Host 'Available aircraft profiles:'
    for ($index = 0; $index -lt $catalog.Count; $index++) {
        $entry = $catalog[$index]
        Write-Host ("  [{0}] {1}  variant={2}  frame={3}  actuators={4}" -f `
            ($index + 1), $entry.ProfileId, $entry.Variant, $entry.SitlFrame, $entry.ActuatorCount)
    }
    Write-Host '  [0] Exit'

    $selected = $null
    while ($null -eq $selected) {
        $selection = Read-Host 'Select aircraft'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            Write-Host 'No selection was provided; no simulation was started.'
            return
        }
        if ($selection -eq '0') {
            Write-Host 'No simulation was started.'
            return
        }
        try {
            $selected = Resolve-RflyMenuSelection -Catalog $catalog -Selection $selection
        } catch {
            Write-Warning $_.Exception.Message
        }
    }

    $inventory = Get-SimulationInventory -LocalSettings $LocalSettings
    if (Test-RflyInventoryActive -Inventory $inventory) {
        Show-SimulationInventory -Inventory $inventory
        $answer = Read-Host 'A simulation is running. Clean it up and start the selected aircraft? [y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host 'Switch cancelled; the existing simulation was left running.'
            return
        }
        Invoke-SimulationCleanup -LocalSettings $LocalSettings -SkipConfirmation
    }

    Write-Host ("Starting profile '{0}' from {1}" -f $selected.ProfileId, $selected.Path)
    Invoke-RunProfile -LocalSettings $LocalSettings -SelectedProfilePath $selected.Path
}

function Stop-RecordedRun {
    if (-not $RunId) {
        throw 'stop requires -RunId.'
    }
    $runPath = Resolve-ProjectPath ("logs\runs\" + $RunId + '\run.json')
    $record = Read-JsonFile $runPath
    $pids = @($record.pids)
    $names = @($record.process_names)
    for ($index = 0; $index -lt $pids.Count; $index++) {
        $processId = [int]$pids[$index]
        $expectedName = if ($index -lt $names.Count) { [string]$names[$index] } else { $null }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($process -and $expectedName -and $process.ProcessName -eq $expectedName) {
            Stop-Process -Id $process.Id
        }
    }
    $record | Add-Member -NotePropertyName stopped_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $record | Add-Member -NotePropertyName stop_mode -NotePropertyValue 'run_id' -Force
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runPath -Encoding UTF8
    Write-Host "Stopped recorded processes for $RunId."
}

$profilePath = Resolve-ProjectPath $Profile
$localSettings = Get-Settings
switch ($Command) {
    'validate' {
        Invoke-ProfileValidation -LocalSettings $localSettings -ProfilePath $profilePath
    }
    'test' {
        $sourcePath = Join-Path $script:ProjectRoot 'src'
        $testsPath = Join-Path $script:ProjectRoot 'tests'
        $code = "addpath($(Quote-MatlabString $sourcePath)); results=runtests($(Quote-MatlabString $testsPath)); assertSuccess(results); disp(table(results));"
        Invoke-MatlabBatch -LocalSettings $localSettings -Code $code
    }
    'build' {
        Invoke-ProfileValidation -LocalSettings $localSettings -ProfilePath $profilePath
        $artifact = Get-BuildArtifact -LocalSettings $localSettings -ProfilePath $profilePath
        $artifact | Format-List
    }
    'deploy' {
        Invoke-ProfileValidation -LocalSettings $localSettings -ProfilePath $profilePath
        $artifact = Get-BuildArtifact -LocalSettings $localSettings -ProfilePath $profilePath
        Install-BuildArtifact -LocalSettings $localSettings -Artifact $artifact | Format-List
    }
    'run' {
        Invoke-RunProfile -LocalSettings $localSettings -SelectedProfilePath $profilePath
    }
    'stop' {
        Stop-RecordedRun
    }
    'status' {
        $runsRoot = Join-Path $script:ProjectRoot 'logs\runs'
        if (Test-Path -LiteralPath $runsRoot) {
            Get-ChildItem -LiteralPath $runsRoot -Filter 'run.json' -Recurse | ForEach-Object {
                $record = Read-JsonFile $_.FullName
                $alive = 0
                $pids = @($record.pids)
                $names = @($record.process_names)
                for ($index = 0; $index -lt $pids.Count; $index++) {
                    $process = Get-Process -Id ([int]$pids[$index]) -ErrorAction SilentlyContinue
                    if ($process -and $index -lt $names.Count -and $process.ProcessName -eq [string]$names[$index]) {
                        $alive++
                    }
                }
                [pscustomobject]@{
                    RunId = $record.run_id
                    Profile = $record.profile_id
                    AliveProcesses = $alive
                    StartedAt = $record.started_at
                    StoppedAt = $record.stopped_at
                }
            } | Format-Table -AutoSize
        }
        $inventory = Get-SimulationInventory -LocalSettings $localSettings
        Show-SimulationInventory -Inventory $inventory
    }
    'cleanup' {
        Invoke-SimulationCleanup -LocalSettings $localSettings -SkipConfirmation:$Force
    }
    'select' {
        Invoke-ProfileSelector -LocalSettings $localSettings
    }
}
