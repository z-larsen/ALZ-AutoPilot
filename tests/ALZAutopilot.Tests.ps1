BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    foreach ($moduleName in @('ALZUI', 'ALZState', 'ALZConfig', 'ALZPreflight', 'ALZOrchestrator', 'ALZPipeline', 'ALZReport')) {
        Import-Module (Join-Path $repoRoot "modules/$moduleName.psm1") -Force
    }
}

Describe 'Delivery handoff reports' {
    BeforeEach {
        Mock Test-ALZPlatformDeployed -ModuleName ALZReport {
            [pscustomobject]@{ ManagementGroups = 2; PolicyAssignments = 0; Assignments = @() }
        }
        Mock Write-ALZSummary -ModuleName ALZReport {}
        Mock Write-ALZStatus -ModuleName ALZReport {}
        Mock Read-ALZConfirm -ModuleName ALZReport { $false }
    }

    It 'writes an in-progress report for <Vcs> without marking deployment complete' -ForEach @(
        @{ Vcs = 'github' }
        @{ Vcs = 'azuredevops' }
    ) {
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive $Vcs)
        $state.answers.vcs = $Vcs
        $state.answers.deliveryName = 'Contoso rehearsal'
        $state.phaseStatus.bootstrap = 'done'
        $state.currentPhase = 'proof'

        Complete-ALZDelivery -State $state -SessionStart (Get-Date) -AppVersion 'test'

        $report = Get-ChildItem (Join-Path $state.deliveryPath 'reports') -Filter '*.html'
        $report.Count | Should -Be 1
        $html = Get-Content $report.FullName -Raw
        $html | Should -Match 'In progress'
        $html | Should -Match 'Observed Azure inventory'
        $state.phaseStatus.proof | Should -Be 'pending'
        (Get-ALZState -DeliveryPath $state.deliveryPath).currentPhase | Should -Be 'proof'
        Should -Invoke Test-ALZPlatformDeployed -ModuleName ALZReport -Times 1 -Exactly
    }

    It 'writes a report even when the Azure inventory call fails' {
        Mock Test-ALZPlatformDeployed -ModuleName ALZReport { throw 'Unavailable' }
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive 'offline')

        Complete-ALZDelivery -State $state -SessionStart (Get-Date)

        Get-ChildItem (Join-Path $state.deliveryPath 'reports') -Filter '*.html' | Should -HaveCount 1
        $state.phaseStatus.proof | Should -Be 'pending'
    }

    It 'does not mark a delivery complete while later phases are still pending' {
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive 'pending-hcp')
        $state.phaseStatus.proof = 'done'
        $state.currentPhase = 'hcp'

        Complete-ALZDelivery -State $state -SessionStart (Get-Date)

        (Get-ALZState -DeliveryPath $state.deliveryPath).currentPhase | Should -Be 'hcp'
    }

    It 'marks completion only when all phases are done or skipped' {
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive 'finished')
        foreach ($phase in @($state.phaseStatus.Keys)) { $state.phaseStatus[$phase] = 'done' }
        $state.phaseStatus.hcp = 'skipped'

        Complete-ALZDelivery -State $state -SessionStart (Get-Date)

        (Get-ALZState -DeliveryPath $state.deliveryPath).currentPhase | Should -Be 'complete'
    }
}

Describe 'Library selection and resume' {
    It 'includes a selected library path with spaces in generated inputs' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.customLibraryPath = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'custom assets/lib') -Force).FullName
        $path = Write-ALZInputsYaml -State $state -ConfigFolder (Join-Path $TestDrive 'config')
        $body = Get-Content $path -Raw
        $body | Should -Match 'starter_additional_files: \[".*custom assets/lib"\]'
    }

    It 'detects a library added after configuration generation' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $folder = Join-Path $TestDrive 'late-config'
        Get-ALZCustomLibraryPath -State $state -ConfigFolder $folder | Should -BeNullOrEmpty
        New-Item -ItemType Directory -Path (Join-Path $folder 'lib') -Force | Out-Null
        Get-ALZCustomLibraryPath -State $state -ConfigFolder $folder | Should -Not -BeNullOrEmpty
    }

    It 'rejects a missing explicit library instead of silently skipping it' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.customLibraryPath = Join-Path $TestDrive 'missing/lib'
        { Write-ALZInputsYaml -State $state -ConfigFolder $TestDrive } | Should -Throw '*does not exist*'
    }

    It 'resumes Azure DevOps answers without requiring a GitHub organization' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.vcs = 'azuredevops'
        $state.answers.adoOrg = 'contoso'
        $state.answers.adoProject = 'ALZ'
        $state.answers.region = 'eastus2'
        $state.answers.deliveryName = 'Rehearsal'
        $state.answers.subscriptions.management = '11111111-1111-1111-1111-111111111111'
        $state.answers.stateBackend = 'azurerm'
        Test-ALZAnswersComplete -State $state | Should -BeTrue
        $state.answers.adoProject = ''
        Test-ALZAnswersComplete -State $state | Should -BeFalse
    }
}

Describe 'Platform network configuration' {
    BeforeAll {
        $script:dataPath = Join-Path $repoRoot 'data'
    }

    It 'populates gateway, firewall, and DDoS choices for <Scenario>' -ForEach @(
        @{ Scenario = 'single-region-hub-and-spoke-vnet-with-azure-firewall' }
        @{ Scenario = 'multi-region-hub-and-spoke-vnet-with-azure-firewall' }
        @{ Scenario = 'single-region-virtual-wan-with-azure-firewall' }
        @{ Scenario = 'multi-region-virtual-wan-with-azure-firewall' }
        @{ Scenario = 'single-region-hub-and-spoke-vnet-with-nva' }
        @{ Scenario = 'multi-region-hub-and-spoke-vnet-with-nva' }
        @{ Scenario = 'single-region-virtual-wan-with-nva' }
        @{ Scenario = 'multi-region-virtual-wan-with-nva' }
        @{ Scenario = 'smb-single-region-hub-and-spoke-vnet-with-azure-firewall' }
        @{ Scenario = 'smb-single-region-virtual-wan-with-azure-firewall' }
    ) {
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive $Scenario)
        $state.answers.scenario = $Scenario
        $state.answers.region = 'eastus2'
        $state.answers.regionSecondary = if ($Scenario -like 'multi-*') { 'westus3' } else { '' }
        $networking = Get-ALZNetworkDefaults -Scenario $Scenario -DataPath $dataPath
        $networking.ddosProtectionPlanEnabled = $false
        foreach ($regionKey in $networking.regions.Keys) {
            $networking.regions[$regionKey].vpnGatewayEnabled = $false
            $networking.regions[$regionKey].expressRouteGatewayEnabled = $false
            if ($Scenario -like '*-with-azure-firewall') { $networking.regions[$regionKey].firewallSku = 'Standard' }
        }
        $state.answers.networking = $networking

        $path = Write-ALZStarterTfvars -State $state -ConfigFolder $state.deliveryPath -DataPath $dataPath

        $body = Get-Content $path -Raw
        $body | Should -Match 'ddos_protection_plan_enabled\s*= false'
        foreach ($regionKey in $networking.regions.Keys) {
            $body | Should -Match "${regionKey}_virtual_network_gateway_vpn_enabled\s*= false"
            $body | Should -Match "${regionKey}_virtual_network_gateway_express_route_enabled\s*= false"
            if ($Scenario -like '*-with-azure-firewall') { $body | Should -Match "${regionKey}_firewall_sku_tier\s*= `"Standard`"" }
        }
        [regex]::Matches($body, 'Enable-DDoS-VNET').Count | Should -Be 2
        $body | Should -Not -Match '(?m)^    ddos_protection_plan_id\s*= "\$\$\{ddos_protection_plan_id\}"'
        $body | Should -Match '\$\$\{starter_location_01\}'
        if (Get-Command terraform -ErrorAction SilentlyContinue) {
            $format = Repair-ALZTfvarsFormat -ConfigFolder $state.deliveryPath
            $format.Checked | Should -BeTrue
            $format.Clean | Should -BeTrue
        }
    }

    It 'creates and attaches a NAT gateway for each selected hub region' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.region = 'eastus2'
        $state.answers.regionSecondary = 'westus3'
        $state.answers.scenario = 'multi-region-hub-and-spoke-vnet-with-azure-firewall'
        $state.answers.networking = Get-ALZNetworkDefaults -Scenario $state.answers.scenario -DataPath $dataPath
        foreach ($region in $state.answers.networking.regions.Values) { $region.natGatewayEnabled = $true }

        $path = Write-ALZStarterTfvars -State $state -ConfigFolder (Join-Path $TestDrive 'nat') -DataPath $dataPath
        $body = Get-Content $path -Raw
        [regex]::Matches($body, 'nat_gateway = true').Count | Should -Be 4
        [regex]::Matches($body, 'firewall_subnet_nat_gateway =').Count | Should -Be 2
        [regex]::Matches($body, 'sku\s*= "StandardV2"').Count | Should -Be 4
        $body | Should -Match 'nat-hub-primary-\$\$\{starter_location_01\}'
        $body | Should -Match 'nat-hub-secondary-\$\$\{starter_location_02\}'
        if (Get-Command terraform -ErrorAction SilentlyContinue) {
            (Repair-ALZTfvarsFormat -ConfigFolder (Split-Path $path)).Clean | Should -BeTrue
        }
    }

    It 'restores DDoS policy defaults when enabling the plan in an SMB scenario' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.region = 'eastus2'
        $state.answers.scenario = 'smb-single-region-hub-and-spoke-vnet-with-azure-firewall'
        $state.answers.networking = Get-ALZNetworkDefaults -Scenario $state.answers.scenario -DataPath $dataPath
        $state.answers.networking.ddosProtectionPlanEnabled = $true
        $path = Write-ALZStarterTfvars -State $state -ConfigFolder (Join-Path $TestDrive 'ddos') -DataPath $dataPath
        $body = Get-Content $path -Raw
        $body | Should -Match 'ddos_protection_plan_enabled\s*= true'
        $body | Should -Not -Match 'Enable-DDoS-VNET'
        $body | Should -Match '(?m)^    ddos_protection_plan_id\s*='
    }

    It 'rejects NAT on a Virtual WAN hub instead of silently ignoring it' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.scenario = 'single-region-virtual-wan-with-azure-firewall'
        $state.answers.networking = Get-ALZNetworkDefaults -Scenario $state.answers.scenario -DataPath $dataPath
        $state.answers.networking.regions.primary.natGatewayEnabled = $true
        { Write-ALZStarterTfvars -State $state -ConfigFolder (Join-Path $TestDrive 'invalid-nat') -DataPath $dataPath } | Should -Throw '*NAT generation requires*'
    }

    It 'preserves an existing edited configuration unless regeneration is explicit' {
        $state = New-ALZState -DeliveryPath $TestDrive
        $state.answers.region = 'eastus2'
        $state.answers.scenario = 'single-region-hub-and-spoke-vnet-with-azure-firewall'
        $state.answers.networking = Get-ALZNetworkDefaults -Scenario $state.answers.scenario -DataPath $dataPath
        $folder = Join-Path $TestDrive 'preserved'
        $path = Write-ALZStarterTfvars -State $state -ConfigFolder $folder -DataPath $dataPath
        $state.answers.networking.regions.primary.vpnGatewayEnabled = $false
        $null = Write-ALZStarterTfvars -State $state -ConfigFolder $folder -DataPath $dataPath
        Get-Content $path -Raw | Should -Match 'primary_virtual_network_gateway_vpn_enabled\s*= true'
        $null = Write-ALZStarterTfvars -State $state -ConfigFolder $folder -DataPath $dataPath -Regenerate
        Get-Content $path -Raw | Should -Match 'primary_virtual_network_gateway_vpn_enabled\s*= false'
    }

    It 'retains generated networking status after state is saved and loaded' {
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive 'network-resume')
        $state.answers.region = 'eastus2'
        $state.answers.scenario = 'single-region-hub-and-spoke-vnet-with-azure-firewall'
        $state.answers.networking = Get-ALZNetworkDefaults -Scenario $state.answers.scenario -DataPath $dataPath
        $null = Write-ALZStarterTfvars -State $state -ConfigFolder (Join-Path $state.deliveryPath 'config') -DataPath $dataPath
        Save-ALZState -State $state

        $restored = Get-ALZState -DeliveryPath $state.deliveryPath
        $report = New-ALZDeliveryReport -State $restored -SessionStart (Get-Date) -DataPath $dataPath

        Get-Content $report -Raw | Should -Not -Match 'Requested choices have not been generated'
    }
}

Describe 'Bootstrap connectivity' {
    BeforeEach {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '<feed><entry><properties><Version>7.1.5</Version></properties></entry></feed>' }
        }
    }

    It 'checks downloads and Azure endpoints without requiring Azure CLI or credentials' {
        $results = @(Test-ALZConnectivity -Vcs github -StateBackend azurerm -TimeoutSeconds 3)
        @($results | Where-Object Status -EQ 'FAIL') | Should -HaveCount 0
        Should -Invoke Invoke-WebRequest -ModuleName ALZPreflight -Times 1 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -eq 'releases.hashicorp.com' -and $Method -eq 'Head'
        }
        Should -Invoke Invoke-WebRequest -ModuleName ALZPreflight -Times 1 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -eq 'management.azure.com' -and $Method -eq 'Get'
        }
        Should -Invoke Invoke-WebRequest -ModuleName ALZPreflight -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://cdn.powershellgallery.com/packages/alz.7.1.5.nupkg' -and $Method -eq 'Head'
        }
    }

    It 'includes Azure DevOps and HCP endpoints when selected' {
        $null = Test-ALZConnectivity -Vcs azuredevops -StateBackend hcp
        Should -Invoke Invoke-WebRequest -ModuleName ALZPreflight -Times 1 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -eq 'dev.azure.com'
        }
        Should -Invoke Invoke-WebRequest -ModuleName ALZPreflight -Times 1 -Exactly -ParameterFilter {
            ([uri]$Uri).Host -eq 'app.terraform.io'
        }
    }

    It 'accepts an expected unauthenticated Azure response but rejects denied downloads' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 401; Headers = @{} }
        } -ParameterFilter { ([uri]$Uri).Host -eq 'management.azure.com' }
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 403; Headers = @{} }
        } -ParameterFilter { ([uri]$Uri).Host -eq 'releases.hashicorp.com' }

        $results = @(Test-ALZConnectivity)
        ($results | Where-Object Detail -Match 'management.azure.com').Status | Should -Be 'OK'
        ($results | Where-Object Detail -Match 'releases.hashicorp.com').Status | Should -Be 'FAIL'
    }

    It 'reports proxy authentication without exposing the response body' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 407; Headers = @{}; Content = 'private-proxy-user:private-proxy-password' }
        }
        $results = @(Test-ALZConnectivity)
        @($results | Where-Object Status -EQ 'FAIL').Count | Should -BeGreaterThan 0
        ($results | ConvertTo-Json) | Should -Match 'Proxy authentication'
        ($results | ConvertTo-Json) | Should -Not -Match 'private-proxy'
    }

    It 'classifies <Failure> without including raw exception text' -ForEach @(
        @{ Failure = 'TLS'; ExceptionType = 'System.Security.Authentication.AuthenticationException'; Expected = 'certificate|TLS' }
        @{ Failure = 'timeout'; ExceptionType = 'System.TimeoutException'; Expected = 'timed out' }
    ) {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            throw (New-Object -TypeName $ExceptionType -ArgumentList 'private-proxy-user:private-proxy-password')
        }
        $results = @(Test-ALZConnectivity)
        @($results | Where-Object Status -EQ 'FAIL').Count | Should -BeGreaterThan 0
        ($results | ConvertTo-Json) | Should -Match $Expected
        ($results | ConvertTo-Json) | Should -Not -Match 'private-proxy'
    }

    It 'classifies DNS failures' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            throw [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::HostNotFound)
        }
        $results = @(Test-ALZConnectivity)
        ($results | ConvertTo-Json) | Should -Match 'DNS resolution failed'
    }

    It 'rejects an HTML block page returned instead of download metadata' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/html' } }
        } -ParameterFilter { ([uri]$Uri).Host -eq 'releases.hashicorp.com' }
        $results = @(Test-ALZConnectivity)
        ($results | Where-Object Detail -Match 'releases.hashicorp.com').Status | Should -Be 'FAIL'
    }

    It 'does not treat an unsupported HEAD probe as confirmed download access' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 405; Headers = @{} }
        }
        $results = @(Test-ALZConnectivity)
        @($results | Where-Object Status -EQ 'OK') | Should -HaveCount 0
        ($results | ConvertTo-Json) | Should -Match 'unverified'
    }

    It 'fails a rejected GET instead of treating it as an unsupported HEAD probe' {
        Mock Invoke-WebRequest -ModuleName ALZPreflight {
            [pscustomobject]@{ StatusCode = 405; Headers = @{} }
        } -ParameterFilter { ([uri]$Uri).Host -eq 'management.azure.com' }
        $results = @(Test-ALZConnectivity)
        ($results | Where-Object Detail -Match 'management.azure.com').Status | Should -Be 'FAIL'
    }

    It 'does not expose proxy environment variable values' {
        $previousProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
        try {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://private-user:private-password@proxy.invalid:8080')
            $results = @(Test-ALZConnectivity)
            ($results | ConvertTo-Json) | Should -Match 'Proxy configuration'
            ($results | ConvertTo-Json) | Should -Not -Match 'private-user|private-password|proxy.invalid'
        }
        finally { [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $previousProxy) }
    }

    It 'connectivity-only exits without a delivery folder or interview' {
        Mock Import-Module {}
        Mock Test-ALZConnectivity { New-ALZCheckResult 'HTTPS' 'OK' 'Reachable' }
        Mock Write-ALZSection {}
        Mock Write-ALZResults {}
        Mock Read-ALZValue { throw 'Unexpected interview' }
        $folder = Join-Path $TestDrive 'not-created'

        & (Join-Path $repoRoot 'Start-ALZDelivery.ps1') -ConnectivityOnly -DeliveryPath $folder

        Test-Path $folder | Should -BeFalse
        Should -Invoke Test-ALZConnectivity -Times 1 -Exactly -ParameterFilter { $Vcs -eq 'all' -and $StateBackend -eq 'hcp' }
        Should -Invoke Read-ALZValue -Times 0 -Exactly
    }

    It 'connectivity-only fails without creating delivery files when a probe fails' {
        Mock Import-Module {}
        Mock Test-ALZConnectivity { New-ALZCheckResult 'HTTPS' 'FAIL' 'Blocked' }
        Mock Write-ALZSection {}
        Mock Write-ALZResults {}
        $folder = Join-Path $TestDrive 'blocked-not-created'

        { & (Join-Path $repoRoot 'Start-ALZDelivery.ps1') -ConnectivityOnly -DeliveryPath $folder } | Should -Throw '*Connectivity checks failed*'
        Test-Path $folder | Should -BeFalse
    }

    It 'stops normal preflight before tool checks or deployment when connectivity fails' {
        function az { '{}' }
        Mock Import-Module {}
        Mock Test-ALZConnectivity { New-ALZCheckResult 'HTTPS' 'FAIL' 'Blocked' }
        Mock Test-ALZTooling { throw 'Unexpected tool check' }
        Mock Register-ALZResourceProviders { throw 'Unexpected provider registration' }
        Mock Install-ALZModuleIfNeeded { throw 'Unexpected installation' }
        Mock Invoke-ALZBootstrap { throw 'Unexpected bootstrap' }
        Mock Read-ALZConfirm { $false }
        Mock Read-ALZConfirm { $true } -ParameterFilter { $Prompt -in @('Resume this delivery?', 'Is everything above correct?') }
        Mock Read-ALZValue { throw 'Unexpected interview' }
        $state = New-ALZState -DeliveryPath (Join-Path $TestDrive 'blocked-normal-run')
        $state.answers.deliveryName = 'Connectivity regression'
        $state.answers.region = 'eastus2'
        $state.answers.githubOrg = 'contoso'
        $state.answers.stateBackend = 'azurerm'
        $state.answers.scenario = 'management-only'
        $state.answers.subscriptions.management = '11111111-1111-1111-1111-111111111111'
        $state.phaseStatus.interview = 'done'
        Save-ALZState -State $state

        & (Join-Path $repoRoot 'Start-ALZDelivery.ps1') -DeliveryPath $state.deliveryPath -NoClear 6>$null

        (Get-ALZState -DeliveryPath $state.deliveryPath).phaseStatus.preflight | Should -Be 'failed'
        Should -Invoke Test-ALZTooling -Times 0 -Exactly
        Should -Invoke Register-ALZResourceProviders -Times 0 -Exactly
        Should -Invoke Install-ALZModuleIfNeeded -Times 0 -Exactly
        Should -Invoke Invoke-ALZBootstrap -Times 0 -Exactly
        Test-Path (Join-Path $state.deliveryPath 'config') | Should -BeFalse
    }
}

Describe 'Required schema conformance' {
    It 'fails when a required bootstrap schema is missing' {
        & (Join-Path $repoRoot 'tests/Test-ALZConfigConformance.ps1') -ModulesRoot (Join-Path $TestDrive 'missing-schema') -RequireSchema -Quiet
        $LASTEXITCODE | Should -Be 1
    }
}