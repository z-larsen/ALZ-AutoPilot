#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:requiredPesterVersion = [version]'5.7.1'
$script:NewTestState = $null
$script:NewBicepFixture = $null
$global:ALZBicepTestsRepoRoot = $null
$global:ALZBicepTestsInitialModulePaths = @{}
$global:ALZBicepTestsBundledTemplate = $null

BeforeAll {
    $global:ALZBicepTestsRepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $global:ALZBicepTestsInitialModulePaths = @{}
    $loadedPester = Get-Module -Name Pester
    if (-not $loadedPester -or $loadedPester.Version -lt $script:requiredPesterVersion) {
        Import-Module Pester -MinimumVersion $script:requiredPesterVersion -ErrorAction Stop
    }

    foreach ($name in @('ALZState', 'ALZConfig')) {
        $global:ALZBicepTestsInitialModulePaths[$name] = @(Get-Module -Name $name -All | ForEach-Object Path)
    }

    Import-Module (Join-Path $global:ALZBicepTestsRepoRoot 'modules/ALZState.psm1') -Force
    Import-Module (Join-Path $global:ALZBicepTestsRepoRoot 'modules/ALZConfig.psm1') -Force
    $global:ALZBicepTestsBundledTemplate = Join-Path $global:ALZBicepTestsRepoRoot 'data/scenarios-bicep/platform-landing-zone.yaml'
    $global:ALZBicepTestsBundledTemplate = Join-Path $global:ALZBicepTestsRepoRoot 'data/scenarios-bicep/platform-landing-zone.yaml'
    $script:NewTestState = {
        param(
            [string]$PrimaryRegion = 'eastus2',
            [string]$SecondaryRegion = 'westus3',
            [string]$NetworkType = 'hubNetworking'
        )

        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $state.answers.region = $PrimaryRegion
        $state.answers.regionSecondary = $SecondaryRegion
        $state.answers.bicepNetworkType = $NetworkType
        return $state
    }

    $script:NewBicepFixture = {
        param([switch]$WithoutTemplate)

        $dataPath = Join-Path $TestDrive ("data-" + [guid]::NewGuid().ToString('N'))
        $scenarioPath = Join-Path $dataPath 'scenarios-bicep'
        New-Item -ItemType Directory -Path $scenarioPath -Force | Out-Null

        if (-not $WithoutTemplate) {
            Copy-Item -LiteralPath $global:ALZBicepTestsBundledTemplate -Destination (Join-Path $scenarioPath 'platform-landing-zone.yaml') -Force
        }

        return $dataPath
    }
}

Describe 'Write-ALZBicepConfig' {
    AfterAll {
        foreach ($name in @('ALZState', 'ALZConfig')) {
            @(Get-Module -Name $name -All) | Remove-Module -Force -ErrorAction SilentlyContinue
            foreach ($path in @($global:ALZBicepTestsInitialModulePaths[$name])) {
                if ($path) { Import-Module $path -Force }
            }
        }
    }

    It 'generates <NetworkType> with primary and secondary regions' -ForEach @(
        @{ NetworkType = 'none' }
        @{ NetworkType = 'hubNetworking' }
        @{ NetworkType = 'vwanConnectivity' }
    ) {
        $state = & $script:NewTestState -NetworkType $NetworkType
        $dataPath = & $script:NewBicepFixture
        $configFolder = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N'))

        $path = Write-ALZBicepConfig -State $state -ConfigFolder $configFolder -DataPath $dataPath
        $content = Get-Content -LiteralPath $path -Raw

        $path | Should -Be (Join-Path $configFolder 'platform-landing-zone.yaml')
        $content | Should -Match ([regex]::Escape('starter_locations: ["eastus2", "westus3"]'))
        $content | Should -Match ('network_type:\s*"' + [regex]::Escape($NetworkType) + '"')
        $content | Should -Not -Match '<region-1>|<region-2>'
    }

    It 'preserves unrelated manual edits and placeholders on rerun' {
        $dataPath = & $script:NewBicepFixture
        $configFolder = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N'))
        $path = Write-ALZBicepConfig -State (& $script:NewTestState -NetworkType 'hubNetworking') -ConfigFolder $configFolder -DataPath $dataPath

        $manualContent = Get-Content -LiteralPath $path -Raw
        $manualContent = $manualContent -replace 'management_group_id_prefix\s*:\s*"[^"]*"', 'management_group_id_prefix: "<id-prefix>"'
        $manualContent += "`ncustom_placeholder: ""<keep-me>""" + [Environment]::NewLine
        $manualContent | Set-Content -LiteralPath $path -Encoding UTF8

        $rerunState = & $script:NewTestState -PrimaryRegion 'centralus' -SecondaryRegion 'westus' -NetworkType 'vwanConnectivity'
        $rerunPath = Write-ALZBicepConfig -State $rerunState -ConfigFolder $configFolder -DataPath $dataPath
        $rerunContent = Get-Content -LiteralPath $rerunPath -Raw

        $rerunContent | Should -Match ([regex]::Escape('starter_locations: ["centralus", "westus"]'))
        $rerunContent | Should -Match 'network_type:\s*"vwanConnectivity"'
        $rerunContent | Should -Match ([regex]::Escape('management_group_id_prefix: "<id-prefix>"'))
        $rerunContent | Should -Match ([regex]::Escape('custom_placeholder: "<keep-me>"'))
        $rerunContent | Should -Match ([regex]::Escape('# The naming pattern is <id-prefix><id><id-postfix> and <name-prefix><name><name-postfix>'))
    }

    It 'rejects invalid network types' {
        $state = & $script:NewTestState -NetworkType 'mesh'
        $dataPath = & $script:NewBicepFixture
        $configFolder = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N'))

        { Write-ALZBicepConfig -State $state -ConfigFolder $configFolder -DataPath $dataPath } |
            Should -Throw "Invalid Bicep network type 'mesh'."
    }

    It 'rejects invalid region values' -ForEach @(
        @{
            Name = 'primary'
            PrimaryRegion = 'east-us2'
            SecondaryRegion = 'westus3'
            Message = "Invalid region 'east-us2'."
        }
        @{
            Name = 'secondary'
            PrimaryRegion = 'eastus2'
            SecondaryRegion = 'west us'
            Message = "Invalid secondary region 'west us'."
        }
    ) {
        $state = & $script:NewTestState -PrimaryRegion $PrimaryRegion -SecondaryRegion $SecondaryRegion
        $dataPath = & $script:NewBicepFixture
        $configFolder = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N'))

        { Write-ALZBicepConfig -State $state -ConfigFolder $configFolder -DataPath $dataPath } |
            Should -Throw $Message
    }

    It 'throws when the bundled template is missing in an isolated fixture' {
        $state = & $script:NewTestState
        $dataPath = & $script:NewBicepFixture -WithoutTemplate
        $configFolder = Join-Path $TestDrive ("cfg-" + [guid]::NewGuid().ToString('N'))

        { Write-ALZBicepConfig -State $state -ConfigFolder $configFolder -DataPath $dataPath } |
            Should -Throw 'Bundled Bicep configuration not found:*platform-landing-zone.yaml'
    }
}
