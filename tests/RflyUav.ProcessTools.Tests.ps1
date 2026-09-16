$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\RflyUav.ProcessTools.psm1'
Import-Module $modulePath -Force

Describe 'Rfly UAV process tools' {
    It 'matches only PX4 processes under configured source roots' {
        Test-RflyWslProcessMatch `
            -ExecutablePath '/mnt/d/AI_work/px4-h743-weact-custom/build/px4_sitl_default/bin/px4' `
            -WorkingDirectory '/mnt/d/AI_work/px4-h743-weact-custom/build/px4_sitl_default/instance_1' `
            -CommandLine '../bin/px4 -i 1' `
            -Px4Roots @('/mnt/d/AI_work/px4-h743-weact-custom') | Should Be $true

        Test-RflyWslProcessMatch `
            -ExecutablePath '/home/user/other-px4/build/px4_sitl_default/bin/px4' `
            -WorkingDirectory '/home/user/other-px4/build/px4_sitl_default/instance_1' `
            -CommandLine '../bin/px4 -i 1' `
            -Px4Roots @('/mnt/d/AI_work/px4-h743-weact-custom') | Should Be $false
    }

    It 'matches the project helper without matching unrelated bash commands' {
        $helper = '/mnt/d/AI_work/RflyParametricUAV/scripts/sitl_multiple_run_rfly_custom.sh'
        Test-RflyWslProcessMatch -CommandLine "bash $helper root 1 1 iris" -HelperPaths @($helper) | Should Be $true
        Test-RflyWslProcessMatch -CommandLine 'bash /tmp/unrelated.sh' -HelperPaths @($helper) | Should Be $false
    }

    It 'discovers profiles from JSON without a hard-coded aircraft list' {
        $configDirectory = Join-Path $TestDrive 'configs'
        New-Item -ItemType Directory -Path $configDirectory | Out-Null
        '{"profile_id":"zulu","variant":"quad_x","px4":{"sitl_frame":"iris"},"actuators":[{},{}]}' |
            Set-Content -LiteralPath (Join-Path $configDirectory 'zulu.json') -Encoding UTF8
        '{"profile_id":"alpha","variant":"quad_x_tailpusher","px4":{"sitl_frame":"tailpusher"},"actuators":[{},{},{}]}' |
            Set-Content -LiteralPath (Join-Path $configDirectory 'alpha.json') -Encoding UTF8
        'not-json' | Set-Content -LiteralPath (Join-Path $configDirectory 'invalid.json') -Encoding UTF8

        $catalog = @(Get-RflyProfileCatalog -ConfigDirectory $configDirectory)
        $catalog.Count | Should Be 2
        $catalog[0].ProfileId | Should Be 'alpha'
        $catalog[0].ActuatorCount | Should Be 3
    }

    It 'maps menu numbers and supports a no-op exit selection' {
        $catalog = @(
            [pscustomobject]@{ ProfileId = 'first' },
            [pscustomobject]@{ ProfileId = 'second' }
        )
        (Resolve-RflyMenuSelection -Catalog $catalog -Selection '2').ProfileId | Should Be 'second'
        Resolve-RflyMenuSelection -Catalog $catalog -Selection '0' | Should BeNullOrEmpty
        { Resolve-RflyMenuSelection -Catalog $catalog -Selection '3' } | Should Throw
    }

    It 'treats an empty cleanup inventory as inactive' {
        $inventory = [pscustomobject]@{ Windows = @(); Wsl = @() }
        Test-RflyInventoryActive -Inventory $inventory | Should Be $false
    }
}
