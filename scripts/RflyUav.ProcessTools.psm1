function Test-RflyWslProcessMatch {
    [CmdletBinding()]
    param(
        [string]$ExecutablePath,
        [string]$WorkingDirectory,
        [string]$CommandLine,
        [string[]]$Px4Roots = @(),
        [string[]]$HelperPaths = @()
    )

    foreach ($rootValue in @($Px4Roots)) {
        $root = ([string]$rootValue).TrimEnd('/')
        if (-not $root) {
            continue
        }
        $px4Binary = "$root/build/px4_sitl_default/bin/px4"
        $instancePrefix = "$root/build/px4_sitl_default/instance_"
        if ($ExecutablePath -eq $px4Binary -or
                (($ExecutablePath -like '*/px4') -and $WorkingDirectory.StartsWith($instancePrefix, [StringComparison]::Ordinal))) {
            return $true
        }
    }

    foreach ($helperValue in @($HelperPaths)) {
        $helper = [string]$helperValue
        if ($helper -and $CommandLine.Contains($helper)) {
            return $true
        }
    }
    return $false
}

function Get-RflyProfileCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigDirectory)

    $catalog = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ConfigDirectory -Filter '*.json' -File | Sort-Object Name)) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not $profile.profile_id -or -not $profile.variant -or -not $profile.px4.sitl_frame) {
            continue
        }
        $catalog += [pscustomobject]@{
            Path = $file.FullName
            FileName = $file.Name
            ProfileId = [string]$profile.profile_id
            Variant = [string]$profile.variant
            SitlFrame = [string]$profile.px4.sitl_frame
            ActuatorCount = @($profile.actuators).Count
        }
    }
    return $catalog
}

function Resolve-RflyMenuSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Catalog,
        [Parameter(Mandatory = $true)][string]$Selection
    )

    $number = 0
    if (-not [int]::TryParse($Selection, [ref]$number)) {
        throw "Selection must be a number between 0 and $($Catalog.Count)."
    }
    if ($number -eq 0) {
        return $null
    }
    if ($number -lt 1 -or $number -gt $Catalog.Count) {
        throw "Selection must be a number between 0 and $($Catalog.Count)."
    }
    return $Catalog[$number - 1]
}

function Test-RflyInventoryActive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Inventory)

    return (@($Inventory.Windows).Count -gt 0 -or @($Inventory.Wsl).Count -gt 0)
}

Export-ModuleMember -Function Test-RflyWslProcessMatch, Get-RflyProfileCatalog, Resolve-RflyMenuSelection, Test-RflyInventoryActive
