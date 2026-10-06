BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    foreach ($moduleName in @('ALZUI', 'ALZSecurity', 'ALZState', 'ALZConfig', 'ALZPreflight', 'ALZOrchestrator', 'ALZPipeline', 'ALZReport', 'ALZWorkload', 'ALZOwnConfig')) {
        Import-Module (Join-Path $repoRoot "modules/$moduleName.psm1") -Force
    }
}

Describe 'Workload attachment safety' -Tag 'Workload' {
    It 'routes operation <Choice> without making an update or migration a bootstrap' -ForEach @(
        @{ Choice = '1'; Type = 'landingzone'; Intent = 'bootstrap' }
        @{ Choice = '2'; Type = 'workload'; Intent = 'new-workload' }
        @{ Choice = '3'; Type = 'workload'; Intent = 'update-workload' }
        @{ Choice = '4'; Type = 'maintenance'; Intent = 'upgrade-review' }
        @{ Choice = '5'; Type = 'maintenance'; Intent = 'migration-review' }
    ) {
        InModuleScope ALZWorkload -Parameters @{ Choice = $Choice; ExpectedType = $Type; ExpectedIntent = $Intent } {
            param($Choice, $ExpectedType, $ExpectedIntent)
            Mock Read-ALZValue { $Choice }
            Mock Save-ALZState {}
            $state = @{ answers = @{} }
            $result = Set-ALZDeliveryType -State $state
            $result.answers.deliveryType | Should -Be $ExpectedType
            $result.answers.deliveryIntent | Should -Be $ExpectedIntent
        }
    }

    It 'never bootstraps or generates placeholder ALZ configuration from workload mode' {
        $definition = (Get-Command Invoke-ALZWorkloadDelivery).Definition
        $definition | Should -Not -Match '\b(Invoke-ALZBootstrap|Write-ALZStarterTfvars|Install-ALZModuleIfNeeded)\b'
    }

    It 'disables the old destructive content-swap API' {
        { Invoke-ALZWorkloadContentSwap -State @{} -GitHubToken 'test-only' } | Should -Throw '*replacement is disabled*'
    }

    It 'recognizes a genuinely unused workload as greenfield' {
        InModuleScope ALZWorkload {
            $result = Get-ALZWorkloadClassification -Operation new -StateExists $false -RootExists $false -ManagedResourceCount 0 -AzureResourceCount 0
            $result.Environment | Should -Be 'greenfield'
            $result.ImportReviewRequired | Should -BeFalse
        }
    }

    It 'requires ownership review for new state in a brownfield target' {
        InModuleScope ALZWorkload {
            $result = Get-ALZWorkloadClassification -Operation new -StateExists $false -RootExists $false -ManagedResourceCount 0 -AzureResourceCount 3
            $result.Environment | Should -Be 'brownfield'
            $result.ImportReviewRequired | Should -BeTrue
        }
    }

    It 'treats an existing empty resource group as brownfield too' {
        InModuleScope ALZWorkload {
            $result = Get-ALZWorkloadClassification -Operation new -StateExists $false -RootExists $false -ManagedResourceCount 0 -AzureResourceCount 0 -ResourceGroupExists $true
            $result.Environment | Should -Be 'brownfield'
            $result.ImportReviewRequired | Should -BeTrue
        }
    }

    It 'recognizes a bound existing deployment without changing state' {
        InModuleScope ALZWorkload {
            $lineage = '11111111-1111-1111-1111-111111111111'
            $result = Get-ALZWorkloadClassification -Operation update -StateExists $true -RootExists $true -ManagedResourceCount 4 -AzureResourceCount 0 -Lineage $lineage -ExpectedLineage $lineage
            $result.Environment | Should -Be 'brownfield'
            $result.ImportReviewRequired | Should -BeFalse
        }
    }

    It 'rejects an occupied <Occupied> for a new workload' -ForEach @(
        @{ Occupied = 'state key'; HasState = $true; HasRoot = $false }
        @{ Occupied = 'repository folder'; HasState = $false; HasRoot = $true }
    ) {
        InModuleScope ALZWorkload -Parameters @{ HasState = $HasState; HasRoot = $HasRoot } {
            param($HasState, $HasRoot)
            { Get-ALZWorkloadClassification -Operation new -StateExists $HasState -RootExists $HasRoot -AzureResourceCount 0 } | Should -Throw '*unused repository folder and state key*'
        }
    }

    It 'blocks an update with <Problem>' -ForEach @(
        @{ Problem = 'missing state'; HasState = $false; HasRoot = $true; ManagedCount = 1 }
        @{ Problem = 'empty state'; HasState = $true; HasRoot = $true; ManagedCount = 0 }
        @{ Problem = 'missing root'; HasState = $true; HasRoot = $false; ManagedCount = 1 }
    ) {
        InModuleScope ALZWorkload -Parameters @{ HasState = $HasState; HasRoot = $HasRoot; ManagedCount = $ManagedCount } {
            param($HasState, $HasRoot, $ManagedCount)
            { Get-ALZWorkloadClassification -Operation update -StateExists $HasState -RootExists $HasRoot -ManagedResourceCount $ManagedCount -AzureResourceCount 0 -Lineage '11111111-1111-1111-1111-111111111111' } | Should -Throw '*existing Terraform root and nonempty*'
        }
    }

    It 'does not turn unknown state or failed discovery into greenfield' {
        InModuleScope ALZWorkload {
            { Get-ALZWorkloadClassification -Operation new -StateExists $null -RootExists $false -AzureResourceCount 0 } | Should -Throw '*incomplete*'
            { Get-ALZWorkloadClassification -Operation new -StateExists $false -RootExists $false -AzureResourceCount -1 } | Should -Throw '*incomplete*'
        }
    }

    It 'rejects a different state lineage on resume' {
        InModuleScope ALZWorkload {
            { Get-ALZWorkloadClassification -Operation update -StateExists $true -RootExists $true -ManagedResourceCount 1 -AzureResourceCount 1 -Lineage '11111111-1111-1111-1111-111111111111' -ExpectedLineage '22222222-2222-2222-2222-222222222222' } | Should -Throw '*lineage changed*'
        }
    }

    It 'rejects unsafe repository roots' {
        InModuleScope ALZWorkload {
            foreach ($root in @('../platform', '/platform', 'C:\platform', 'workloads/../platform', 'workloads/.git', 'workloads/.github', 'workloads/.hidden', 'workloads//hub')) {
                Test-ALZWorkloadRelativePath $root | Should -BeFalse -Because $root
            }
            Test-ALZWorkloadRelativePath '.' | Should -BeTrue
            Test-ALZWorkloadRelativePath 'workloads/finops-hub' | Should -BeTrue
        }
    }

    It 'preserves unrelated files and skips state, plans, git metadata and workflows' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $caseRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
            $source = (New-Item -ItemType Directory -Path "$caseRoot/source" -Force).FullName
            $destination = (New-Item -ItemType Directory -Path "$caseRoot/target" -Force).FullName
            Set-Content "$source/main.tf" 'resource "terraform_data" "new" {}'
            Set-Content "$source/terraform.tfstate.backup" 'private state'
            Set-Content "$source/review.tfplan" 'private plan'
            Set-Content "$destination/platform.tf" 'existing platform'
            foreach ($folder in @('.git', '.github', '.terraform')) {
                $null = New-Item -ItemType Directory -Path (Join-Path $source $folder)
                Set-Content (Join-Path $source "$folder/keep-out.txt") 'not for copying'
            }
            Copy-ALZWorkloadModuleFiles -Source $source -Destination $destination
            Get-Content "$destination/platform.tf" -Raw | Should -Match 'existing platform'
            Test-Path "$destination/main.tf" | Should -BeTrue
            foreach ($excluded in @('.git', '.github', '.terraform', 'terraform.tfstate.backup', 'review.tfplan')) { Test-Path (Join-Path $destination $excluded) | Should -BeFalse }
        }
    }

    It 'allows reviewed file updates but never deletes omitted platform files' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $caseRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
            $source = (New-Item -ItemType Directory -Path "$caseRoot/source" -Force).FullName
            $destination = (New-Item -ItemType Directory -Path "$caseRoot/target" -Force).FullName
            Set-Content "$source/main.tf" 'updated configuration'
            Set-Content "$destination/main.tf" 'original configuration'
            Set-Content "$destination/platform.tf" 'must remain'
            { Copy-ALZWorkloadModuleFiles -Source $source -Destination $destination } | Should -Throw '*overwrite*'
            Get-Content "$destination/main.tf" -Raw | Should -Match 'original configuration'
            Copy-ALZWorkloadModuleFiles -Source $source -Destination $destination -AllowOverwrite
            Get-Content "$destination/main.tf" -Raw | Should -Match 'updated configuration'
            Get-Content "$destination/platform.tf" -Raw | Should -Match 'must remain'
            { Copy-ALZWorkloadModuleFiles -Source $source -Destination "$source/nested" } | Should -Throw '*overlap*'
        }
    }

    It 'pins the exact repository instead of searching the organization' {
        InModuleScope ALZWorkload {
            Mock Invoke-RestMethod {
                param($Uri)
                switch -Regex ($Uri) {
                    '/repos/contoso/platform$' { return [pscustomobject]@{ full_name = 'contoso/platform'; id = 42; default_branch = 'main' } }
                    '/branches/main$' { return [pscustomobject]@{ commit = @{ sha = 'abc123' } } }
                    '/git/trees/abc123\?recursive=1$' { return [pscustomobject]@{ truncated = $false; tree = @(@{ type = 'blob'; path = 'main.tf' }) } }
                    '/actions/variables\?' { return [pscustomobject]@{ variables = @() } }
                    default { throw "Unexpected repository lookup: $Uri" }
                }
            }
            $state = @{ answers = @{ workloadRepository = 'contoso/platform' } }
            $repository = Get-ALZWorkloadRepositoryContext -State $state -Token 'test-only'
            $repository.Repository | Should -Be 'contoso/platform'
            $repository.Id | Should -Be '42'
            $repository.Files | Should -Contain 'main.tf'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -match '/orgs/' -or $Method -ne 'Get' }
            $state.answers.workloadRepositoryId = '99'
            { Get-ALZWorkloadRepositoryContext -State $state -Token 'test-only' } | Should -Throw '*identity changed*'
        }
    }

    It 'blocks an incomplete repository inventory' {
        InModuleScope ALZWorkload {
            Mock Invoke-RestMethod {
                param($Uri)
                if ($Uri -match '/branches/') { return [pscustomobject]@{ commit = @{ sha = 'abc123' } } }
                if ($Uri -match '/git/trees/') { return [pscustomobject]@{ truncated = $true; tree = @() } }
                return [pscustomobject]@{ full_name = 'contoso/platform'; id = 42; default_branch = 'main' }
            }
            { Get-ALZWorkloadRepositoryContext -State @{ answers = @{ workloadRepository = 'contoso/platform' } } -Token 'test-only' } | Should -Throw '*inventory is incomplete*'
        }
    }

    It 'pins backend keys case-sensitively instead of silently switching state' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $state = New-ALZState -DeliveryPath (Join-Path $TestRoot ([guid]::NewGuid().ToString('N')))
            $state.answers.workloadOperation = 'update'
            $repository = [pscustomobject]@{ Variables = @{
                AZURE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
                AZURE_TENANT_ID = '22222222-2222-2222-2222-222222222222'
                BACKEND_AZURE_RESOURCE_GROUP_NAME = 'rg-state'
                BACKEND_AZURE_STORAGE_ACCOUNT_NAME = 'existingstate'
                BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME = 'tfstate'
            } }
            Mock Read-ALZValue { param($Default) $Default }
            $backend = Read-ALZWorkloadBackend -State $state -Repository $repository
            $backend.key | Should -BeExactly 'terraform.tfstate'
            Mock Read-ALZValue { param($Prompt, $Default) if ($Prompt -like 'Exact state blob key*') { 'Terraform.tfstate' } else { $Default } }
            { Read-ALZWorkloadBackend -State $state -Repository $repository } | Should -Throw '*backend binding changed*'
            $state.answers.workloadBackend.key | Should -BeExactly 'terraform.tfstate'
        }
    }

    It 'clears a previous backend binding when a different repository is explicitly selected' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $state = New-ALZState -DeliveryPath (Join-Path $TestRoot ([guid]::NewGuid().ToString('N')))
            $state.answers.workloadOperation = 'new'
            $state.answers.workloadRepository = 'contoso/old'
            $state.answers.workloadRoot = 'workloads/example'
            $state.answers.workloadBackendBinding = 'old binding'
            $state.answers.workloadStateLineage = 'old lineage'
            Mock Read-ALZValue { param($Prompt, $Default) if ($Prompt -like 'Existing GitHub repository*') { 'contoso/new' } else { $Default } }
            Mock Read-ALZConfirm { $false }
            $null = Invoke-ALZWorkloadInterview -State $state
            $state.answers.workloadRepository | Should -Be 'contoso/new'
            $state.answers.workloadBackendBinding | Should -BeNullOrEmpty
            $state.answers.workloadStateLineage | Should -BeNullOrEmpty
        }
    }

    It 'reads only metadata from existing state and removes the temporary download' {
        InModuleScope ALZWorkload {
            $state = @{ answers = @{
                subscriptions = @{ management = '11111111-1111-1111-1111-111111111111' }
                workloadResourceGroup = 'rg-workload'
                workloadBackend = @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; tenantId = '22222222-2222-2222-2222-222222222222'; storageAccount = 'existingstate'; resourceGroup = 'rg-state'; container = 'tfstate'; key = 'custom.tfstate'; workspace = 'default' }
            } }
            Mock Invoke-ALZWorkloadAzureRead {
                param($Arguments)
                switch -Wildcard ($Arguments[0..2] -join ' ') {
                    'account show*' { return @{ id = '11111111-1111-1111-1111-111111111111'; tenantId = '22222222-2222-2222-2222-222222222222' } }
                    'storage account show' { return @{ id = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-state/providers/Microsoft.Storage/storageAccounts/existingstate' } }
                    'storage container exists' { return @{ exists = $true } }
                    'storage blob exists' { return @{ exists = $true } }
                    'storage blob download' {
                        $script:downloadedStatePath = $Arguments[[array]::IndexOf($Arguments, '--file') + 1]
                        @{ version = 4; serial = 7; lineage = '33333333-3333-3333-3333-333333333333'; resources = @(@{ mode = 'managed'; instances = @(@{ attributes = @{ private_value = 'fixture-secret' } }, @{ attributes = @{} }) }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:downloadedStatePath
                        return @{}
                    }
                    'group exists*' { return $true }
                    'resource list*' { return ,@() }
                    default { throw 'Unexpected Azure operation.' }
                }
            }
            $snapshot = Get-ALZWorkloadSnapshot -State $state
            $snapshot.StateExists | Should -BeTrue
            $snapshot.ResourceGroupExists | Should -BeTrue
            $snapshot.AzureResourceCount | Should -Be 0
            $snapshot.ManagedResourceCount | Should -Be 2
            $snapshot.Serial | Should -Be 7
            Test-Path -LiteralPath $script:downloadedStatePath | Should -BeFalse
            $snapshot | ConvertTo-Json | Should -Not -Match 'fixture-secret'
            Should -Invoke Invoke-ALZWorkloadAzureRead -Times 3 -Exactly -ParameterFilter { $Arguments -contains '--auth-mode' -and $Arguments -contains 'login' }
            Mock Invoke-ALZWorkloadAzureRead {
                param($Arguments)
                $script:downloadedStatePath = $Arguments[[array]::IndexOf($Arguments, '--file') + 1]
                Set-Content -LiteralPath $script:downloadedStatePath -Value '{"secret":"fixture-secret"'
                return @{}
            } -ParameterFilter { ($Arguments[0..2] -join ' ') -eq 'storage blob download' }
            $failure = { Get-ALZWorkloadSnapshot -State $state } | Should -Throw '*snapshot could not be decoded*' -PassThru
            $failure.Exception.Message | Should -Not -Match 'fixture-secret'
            Test-Path -LiteralPath $script:downloadedStatePath | Should -BeFalse
        }
    }

    It 'preserves an empty Azure result but blocks native-command and JSON failures' {
        InModuleScope ALZWorkload {
            Mock az { $global:LASTEXITCODE = 0; '[]' }
            $result = Invoke-ALZWorkloadAzureRead -Arguments @('resource', 'list')
            $result | Should -HaveCount 0
            Mock az { $global:LASTEXITCODE = 1; '{"exists":false}' }
            { Invoke-ALZWorkloadAzureRead -Arguments @('storage', 'blob', 'exists') } | Should -Throw '*Failure is not an empty environment*'
            Mock az { $global:LASTEXITCODE = 0; 'malformed sensitive fixture' }
            $failure = { Invoke-ALZWorkloadAzureRead -Arguments @('resource', 'list') } | Should -Throw '*invalid JSON*' -PassThru
            $failure.Exception.Message | Should -Not -Match 'sensitive fixture'
        }
    }

    It 'builds a local proposal with the selected key, without pushing or leaking Git credentials' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $delivery = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
            $source = (New-Item -ItemType Directory -Path "$delivery/source" -Force).FullName
            Set-Content "$source/main.tf" 'resource "terraform_data" "new" {}'
            $state = @{ deliveryPath = $delivery; answers = @{
                customModulePath = $source; workloadOperation = 'new'; workloadRoot = 'workloads/example'
                workloadBackend = @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; tenantId = '22222222-2222-2222-2222-222222222222'; storageAccount = 'existingstate'; resourceGroup = 'rg-state'; container = 'tfstate'; key = 'workloads/example.tfstate' }
            } }
            $script:gitCalls = @()
            Mock git {
                $script:gitCalls += ,@($args)
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'clone') {
                    $checkout = $args[-1]
                    $null = New-Item -ItemType Directory -Path $checkout -Force
                    Set-Content (Join-Path $checkout 'platform.tf') 'existing platform'
                }
                elseif ($args -contains 'rev-parse') { 'abc123' }
                else { throw 'Unexpected git operation.' }
            }
            $oldConfigCount = $env:GIT_CONFIG_COUNT
            $proposal = New-ALZWorkloadProposal -State $state -Repository ([pscustomobject]@{ Repository = 'contoso/platform'; Branch = 'main'; Commit = 'abc123' }) -Token 'test-only-git-token'
            (Get-Content -LiteralPath $proposal.BackendConfig -Raw | ConvertFrom-Json).key | Should -Be 'workloads/example.tfstate'
            [IO.Path]::GetFileName($proposal.BackendConfig) | Should -Be 'backend.tfbackend.json'
            Get-Content (Join-Path $proposal.Checkout 'platform.tf') -Raw | Should -Match 'existing platform'
            Test-Path (Join-Path $proposal.Root 'main.tf') | Should -BeTrue
            $script:gitCalls.Count | Should -Be 2
            ($script:gitCalls | ForEach-Object { $_ -join ' ' }) -join "`n" | Should -Not -Match 'push|commit|test-only-git-token|x-access-token'
            $env:GIT_CONFIG_COUNT | Should -Be $oldConfigCount
        }
    }

    It 'generates an isolated workflow with explicit backend and target subscriptions' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $checkout = (New-Item -ItemType Directory -Path (Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))) -Force).FullName
            $state = @{ answers = @{
                workloadRepository = 'contoso/platform'
                workloadRoot = 'workloads/connectivity'
                workloadBranch = 'main'
                workloadOperation = 'new'
                subscriptions = @{ management = '22222222-2222-2222-2222-222222222222' }
                workloadBackend = @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; tenantId = '33333333-3333-3333-3333-333333333333'; storageAccount = 'existingstate'; resourceGroup = 'rg-state'; container = 'tfstate'; key = 'connectivity/terraform.tfstate'; workspace = 'default' }
                workloadPipeline = @{ planEnvironment = 'platform-plan'; applyEnvironment = 'platform-apply'; runnerLabels = @('self-hosted', 'Linux', 'X64'); terraformVersion = '1.14.9' }
            } }
            $files = Write-ALZWorkloadWorkflow -State $state -Checkout $checkout
            $workflow = Get-Content -LiteralPath $files.Workflow -Raw
            $workflow | Should -Match '22222222-2222-2222-2222-222222222222'
            $workflow | Should -Match 'workflow_dispatch:'
            $workflow | Should -Not -Match 'pull_request_target|terraform destroy|cancel-in-progress: true'
            $config = Get-Content -LiteralPath $files.Config -Raw | ConvertFrom-Json
            $config.backend.subscriptionId | Should -Be '11111111-1111-1111-1111-111111111111'
            $config.backend.key | Should -Be 'connectivity/terraform.tfstate'
            $config.root | Should -Be 'workloads/connectivity'
            $config.targetSubscriptionId | Should -Be '22222222-2222-2222-2222-222222222222'
        }
    }

    It 'preserves custom hooks and workflow files when updating a bound workload' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $checkout = (New-Item -ItemType Directory -Path (Join-Path $TestRoot 'preserve-hooks') -Force).FullName
            $state = @{ answers = @{
                workloadRepository = 'contoso/platform'; workloadRoot = 'workloads/example'; workloadBranch = 'main'; workloadOperation = 'new'
                subscriptions = @{ management = '22222222-2222-2222-2222-222222222222' }
                workloadBackend = @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; tenantId = '33333333-3333-3333-3333-333333333333'; storageAccount = 'existingstate'; resourceGroup = 'rg-state'; container = 'tfstate'; key = 'example/terraform.tfstate'; workspace = 'default' }
                workloadPipeline = @{ planEnvironment = 'platform-plan'; applyEnvironment = 'platform-apply'; terraformVersion = '1.14.9' }
            } }
            $files = Write-ALZWorkloadWorkflow -State $state -Checkout $checkout
            $config = Get-Content -LiteralPath $files.Config -Raw | ConvertFrom-Json -AsHashtable
            $config.initialization = @{ type = 'finops-v14-private'; script = 'scripts/Initialize-FinOpsHub.ps1'; bundle = 'vendor/finops-hub-v14/initialization.json' }
            $config.operatorMetadata = @{ owner = 'platform-team'; approval = 'separate-review' }
            $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $files.Config
            Add-Content -LiteralPath $files.Workflow -Value '# Operator-maintained workflow extensions'
            $helperPath = Join-Path $checkout '.github/autopilot/Initialize-WorkloadAccess.ps1'
            Add-Content -LiteralPath $helperPath -Value '# Operator-maintained access scope'
            $workflowHash = (Get-FileHash $files.Workflow).Hash
            $helperHash = (Get-FileHash $helperPath).Hash
            $state.answers.workloadOperation = 'update'
            $state.answers.workloadStateLineage = '44444444-4444-4444-4444-444444444444'

            $null = Write-ALZWorkloadWorkflow -State $state -Checkout $checkout

            $updated = Get-Content -LiteralPath $files.Config -Raw | ConvertFrom-Json -AsHashtable
            $updated.initialization.type | Should -Be 'finops-v14-private'
            $updated.operatorMetadata.owner | Should -Be 'platform-team'
            $updated.operation | Should -Be 'update'
            $updated.expectedLineage | Should -Be $state.answers.workloadStateLineage
            (Get-FileHash $files.Workflow).Hash | Should -Be $workflowHash
            (Get-FileHash $helperPath).Hash | Should -Be $helperHash
        }
    }

    It 'extends the official reusable template without changing legacy job bodies or OIDC workflow path' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            Import-Module powershell-yaml
            $file = Join-Path $TestRoot 'cd-template.yaml'
            @{
                name = 'Continuous Delivery'
                on = @{ workflow_call = @{ inputs = @{ terraform_cli_version = @{ type = 'string'; default = '1.14.9' } } } }
                jobs = @{ plan = @{ 'runs-on' = 'self-hosted'; steps = @(@{ run = 'terraform plan' }) }; apply = @{ needs = 'plan'; steps = @(@{ run = 'terraform apply tfplan' }) } }
            } | ConvertTo-Yaml | Set-Content -LiteralPath $file
            $null = Write-ALZWorkloadTemplate -Path $file
            $generated = Get-Content -LiteralPath $file -Raw | ConvertFrom-Yaml
            $generated.jobs.plan.steps[0].run | Should -Be 'terraform plan'
            $generated.jobs.plan['if'] | Should -Be "inputs.autopilot_configuration == ''"
            $generated.jobs['autopilot-plan']['if'] | Should -Match '!inputs.autopilot_enable_apply'
            $generated.jobs['autopilot-apply']['if'] | Should -Match "github.event_name == 'workflow_dispatch'"
            $generated.jobs['autopilot-apply'].steps[1].with['run-id'] | Should -Be '${{ inputs.autopilot_plan_run_id }}'
            $generated.on.workflow_call.inputs.autopilot_enable_apply.default | Should -BeFalse
            $null = Write-ALZWorkloadTemplate -Path $file
            $repeated = Get-Content -LiteralPath $file -Raw | ConvertFrom-Yaml
            $repeated.jobs.Count | Should -Be 4
            $repeated.jobs.plan['if'] | Should -Be "inputs.autopilot_configuration == ''"
        }
    }

    It 'identifies a failing Terraform operation without logging sensitive command output' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        Mock terraform {
            $global:LASTEXITCODE = 1
            'Error: Provider dependency changes detected. token=fixture-private-value'
        }
        $failure = { Invoke-WorkloadCommand -Command terraform -Arguments @('-chdir=private-path', 'init', '-backend=false', '-lockfile=readonly') } | Should -Throw '*terraform init failed*provider lock file*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'fixture-private-value|private-path'
        Mock terraform {
            $global:LASTEXITCODE = 1
            'Error: something unexpected with a private-state-value'
        }
        $failure = { Invoke-WorkloadCommand -Command terraform -Arguments @('plan') } | Should -Throw '*terraform plan failed*Unclassified*' -PassThru
        $failure.Exception.Message | Should -Not -Match 'private-state-value'
    }

    It 'requires exact source, artifact and state bindings for initialization retries' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $receipt = @{
            schemaVersion = 1; status = 'Applied'; event = 'workflow_dispatch'
            commit = $env:GITHUB_SHA; repository = $env:GITHUB_REPOSITORY; workflowRef = $env:GITHUB_WORKFLOW_REF
            bindingId = 'bound'; manifestHash = 'manifest'; runId = '123'; runAttempt = '1'
            lineage = '11111111-1111-1111-1111-111111111111'; serial = 4
            initializationScriptHash = 'script'; initializationBundleHash = 'bundle'
        }
        $parameters = @{
            Config = @{ bindingId = 'bound' }
            Snapshot = @{ exists = $true; lineage = $receipt.lineage; serial = 4 }
            Initialization = @{ scriptHash = 'script'; bundleHash = 'bundle' }
            ManifestHash = 'manifest'; SourceRunId = '123'; SourceAttempt = '1'
        }
        { Test-WorkloadInitializationReceipt -Receipt $receipt @parameters } | Should -Not -Throw
        foreach ($property in @('status', 'event', 'commit', 'repository', 'workflowRef', 'bindingId', 'manifestHash', 'runId', 'runAttempt', 'lineage', 'initializationScriptHash', 'initializationBundleHash')) {
            $changed = $receipt.Clone()
            $changed[$property] = 'different'
            { Test-WorkloadInitializationReceipt -Receipt $changed @parameters } | Should -Throw
        }
        $parameters.Snapshot.serial = 5
        { Test-WorkloadInitializationReceipt -Receipt $receipt @parameters } | Should -Throw '*State changed*'
    }

    It 'hashes only the explicit FinOps initialization contract without executing it' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $root = Join-Path $TestDrive 'initializer'
        $null = New-Item -ItemType Directory -Path "$root/scripts", "$root/vendor/finops-hub-v14" -Force
        Set-Content "$root/scripts/Initialize-FinOpsHub.ps1" "throw 'must not run during planning'"
        Set-Content "$root/vendor/finops-hub-v14/initialization.json" '{}'
        $config = @{ initialization = @{ type = 'finops-v14-private'; script = 'scripts/Initialize-FinOpsHub.ps1'; bundle = 'vendor/finops-hub-v14/initialization.json' } }
        $result = Get-WorkloadInitialization -Config $config -Root $root
        $result.scriptHash | Should -Be (Get-FileHash "$root/scripts/Initialize-FinOpsHub.ps1").Hash
        $config.initialization.script = '../unreviewed.ps1'
        { Get-WorkloadInitialization -Config $config -Root $root } | Should -Throw '*Unsupported*'
    }

    It 'retries initialization without planning or applying Terraform' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $workspace = Join-Path $TestDrive 'retry-workspace'
        $null = New-Item -ItemType Directory -Path "$workspace/.github/autopilot", "$workspace/workloads/finops", "$workspace/.autopilot-apply", "$workspace/temp" -Force
        $environment = @{
            GITHUB_WORKSPACE=$workspace; RUNNER_TEMP="$workspace/temp"; GITHUB_SHA='reviewed-commit'
            GITHUB_REPOSITORY='contoso/platform'; GITHUB_REF='refs/heads/main'; GITHUB_RUN_ID='999'; GITHUB_RUN_ATTEMPT='1'
            GITHUB_WORKFLOW_REF='contoso/platform/.github/workflows/workload.yml@refs/heads/main'
            GITHUB_EVENT_NAME='workflow_dispatch'; GITHUB_EVENT_PATH="$workspace/event.json"; GITHUB_STEP_SUMMARY="$workspace/summary.md"
            ARM_SUBSCRIPTION_ID='approved'; ARM_TENANT_ID='tenant'; ARM_CLIENT_ID='apply-client'
            AUTOPILOT_CONFIRMATION='approved'; AUTOPILOT_PLAN_RUN_ID='123'; AUTOPILOT_PLAN_ATTEMPT='1'; AUTOPILOT_TEMPLATE_CONFIRMATION='template'
        }
        $previous = @{}
        foreach ($name in @($environment.Keys) + @('TF_IN_AUTOMATION', 'TF_INPUT', 'TF_WORKSPACE', 'TF_DATA_DIR', 'ARM_RESOURCE_PROVIDER_REGISTRATIONS')) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $config = @{ schemaVersion=1; repository='contoso/platform'; targetSubscriptionId='approved'; root='workloads/finops'; bindingId='bound'; allowedSubscriptionIds=@('approved'); approvedTemplateHashes=@('template'); backend=@{workspace='default'; tenantId='tenant'; subscriptionId='approved'} }
        $config | ConvertTo-Json -Depth 6 | Set-Content "$workspace/.github/autopilot/retry.json"
        @{ repository=@{private=$true; default_branch='main'}; inputs=@{action='initialize'} } | ConvertTo-Json | Set-Content "$workspace/event.json"
        $receipt = @{
            schemaVersion=1; status='Applied'; event='workflow_dispatch'; commit='reviewed-commit'; repository='contoso/platform'
            workflowRef=$environment.GITHUB_WORKFLOW_REF; bindingId='bound'; manifestHash=(Get-FileHash "$workspace/.github/autopilot/retry.json").Hash
            runId='123'; runAttempt='1'; lineage='11111111-1111-1111-1111-111111111111'; serial=4
            initializationScriptHash='script'; initializationBundleHash='bundle'
        }
        $receipt | ConvertTo-Json | Set-Content "$workspace/.autopilot-apply/receipt.json"
        Mock Get-WorkloadInitialization { @{scriptHash='script'; bundleHash='bundle'} }
        Mock Read-WorkloadState { @{exists=$true; lineage='11111111-1111-1111-1111-111111111111'; serial=4} }
        Mock Invoke-WorkloadCommand {
            param($Command)
            if ($Command -eq 'az') { return @{id='approved'; tenantId='tenant'} }
        }
        Mock Invoke-WorkloadInitialization {}
        Push-Location $workspace
        try {
            foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
            Invoke-WorkloadPipeline -Stage Initialize -Configuration '.github/autopilot/retry.json'
            Should -Invoke Invoke-WorkloadInitialization -Times 1 -Exactly
            Should -Invoke Invoke-WorkloadCommand -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'apply' -or $Arguments -contains 'plan' }
            Mock Read-WorkloadState { @{exists=$true; lineage='11111111-1111-1111-1111-111111111111'; serial=5} }
            { Invoke-WorkloadPipeline -Stage Initialize -Configuration '.github/autopilot/retry.json' } | Should -Throw '*State changed*'
            Should -Invoke Invoke-WorkloadInitialization -Times 1 -Exactly
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    It 'blocks deletion, replacement, foreign subscription and governance changes in runner plans' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        foreach ($change in @(
            @{ type = 'azurerm_virtual_network'; change = @{ actions = @('delete') } },
            @{ type = 'azurerm_virtual_network'; change = @{ actions = @('delete', 'create') } },
            @{ type = 'azurerm_management_group'; change = @{ actions = @('create') } },
            @{ type = 'azurerm_resource_group'; change = @{ actions = @('update'); before = @{ id = '/subscriptions/foreign/resourceGroups/example' } } }
        )) {
            $change.mode = 'managed'
            $change.address = 'example.resource'
            { Test-WorkloadPlan -Plan @{ resource_changes = @($change) } -AllowedSubscriptions @('approved') } | Should -Throw
        }
        $safe = @{ mode = 'managed'; address = 'azurerm_resource_group.new'; type = 'azurerm_resource_group'; change = @{ actions = @('create'); after = @{ id = '/subscriptions/approved/resourceGroups/new' } } }
        @(Test-WorkloadPlan -Plan @{ resource_changes = @($safe) } -AllowedSubscriptions @('approved')).Count | Should -Be 1
        $foreignProvider = @{ configuration = @{ provider_config = @{ azurerm = @{ full_name = 'registry.terraform.io/hashicorp/azurerm'; expressions = @{ subscription_id = @{ references = @('var.subscription_id') } } } } }; variables = @{ subscription_id = @{ value = 'foreign' } }; resource_changes = @($safe) }
        { Test-WorkloadPlan -Plan $foreignProvider -AllowedSubscriptions @('approved') } | Should -Throw '*provider targets*'
        $safe.change.after.name = 'existing-platform'
        { Test-WorkloadPlan -Plan @{ resource_changes = @($safe) } -AllowedSubscriptions @('approved') -AllowedResourceGroups @('new') } | Should -Throw '*unapproved resource group*'
        $nested = @{ mode = 'managed'; address = 'azurerm_resource_group_template_deployment.hub'; type = 'azurerm_resource_group_template_deployment'; change = @{ actions = @('create'); after = @{ template_content = '{"resources":[]}' } } }
        { Test-WorkloadPlan -Plan @{ resource_changes = @($nested) } -AllowedSubscriptions @('approved') } | Should -Throw '*pinned template*'
    }

    It 'verifies normalized ARM JSON against the unchanged pinned source' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $templateFolder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'pinned-template')).FullName
        $templatePath = Join-Path $templateFolder 'template.json'
        Set-Content -LiteralPath $templatePath -Value '{ "resources": [], "contentVersion": "1.0.0.0" }'
        $approvedHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $change = @{ mode = 'managed'; address = 'azurerm_resource_group_template_deployment.finops'; type = 'azurerm_resource_group_template_deployment'; change = @{ actions = @('create'); after = @{ template_content = '{"contentVersion":"1.0.0.0","resources":[]}' } } }
        @(Test-WorkloadPlan -Plan @{ resource_changes = @($change) } -AllowedSubscriptions @('approved') -ApprovedTemplateHashes @($approvedHash) -TemplateRoot $templateFolder).Count | Should -Be 1
        $change.change.after.template_content = '{"contentVersion":"2.0.0.0","resources":[]}'
        { Test-WorkloadPlan -Plan @{ resource_changes = @($change) } -AllowedSubscriptions @('approved') -ApprovedTemplateHashes @($approvedHash) -TemplateRoot $templateFolder } | Should -Throw '*pinned template*'
    }

    It 'checks whole-subscription, tenant and resource-group scopes against the approved scope' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $approved = '11111111-1111-1111-1111-111111111111'
        $foreign = '22222222-2222-2222-2222-222222222222'
        $new = { param($type, $after) @{ mode = 'managed'; address = "$type.example"; type = $type; change = @{ actions = @('create'); after = $after } } }
        foreach ($blocked in @(
            (& $new 'azurerm_role_assignment' @{ scope = "/subscriptions/$foreign"; role_definition_name = 'Owner' }),
            (& $new 'azapi_resource' @{ type = 'Microsoft.Authorization/roleAssignments@2022-04-01'; parent_id = "/subscriptions/$foreign" }),
            (& $new 'azurerm_consumption_budget_subscription' @{ subscription_id = $foreign }),
            (& $new 'azurerm_monitor_diagnostic_setting' @{ target_resource_id = "/subscriptions/$foreign/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv" }),
            (& $new 'azurerm_role_assignment' @{ scope = '/' }),
            (& $new 'azapi_resource' @{ type = 'Microsoft.Authorization/roleAssignments@2022-04-01'; parent_id = '/providers/Microsoft.Billing/billingAccounts/1' })
        )) {
            { Test-WorkloadPlan -Plan @{ resource_changes = @($blocked) } -AllowedSubscriptions @($approved) } | Should -Throw '*outside*'
        }
        $reader = & $new 'azurerm_role_assignment' @{ scope = "/subscriptions/$approved"; role_definition_name = 'Cost Management Reader' }
        @(Test-WorkloadPlan -Plan @{ resource_changes = @($reader) } -AllowedSubscriptions @($approved) -AllowedResourceGroups @('rg-workload')).Count | Should -Be 1
        $stateGroup = & $new 'azurerm_role_assignment' @{ scope = "/subscriptions/$approved/resourceGroups/rg-state/providers/Microsoft.Storage/storageAccounts/st" }
        { Test-WorkloadPlan -Plan @{ resource_changes = @($stateGroup) } -AllowedSubscriptions @($approved) -AllowedResourceGroups @('rg-workload') } | Should -Throw '*unapproved resource group*'
        foreach ($policy in @(
            (& $new 'azurerm_resource_group_policy_exemption' @{ resource_group_id = "/subscriptions/$approved/resourceGroups/rg-workload" }),
            (& $new 'azurerm_resource_policy_assignment' @{ resource_id = "/subscriptions/$approved/resourceGroups/rg-workload/providers/Microsoft.Storage/storageAccounts/st" }),
            (& $new 'azapi_resource' @{ type = 'Microsoft.Authorization/policyExemptions@2022-07-01-preview'; parent_id = "/subscriptions/$approved/resourceGroups/rg-workload" })
        )) {
            { Test-WorkloadPlan -Plan @{ resource_changes = @($policy) } -AllowedSubscriptions @($approved) } | Should -Throw '*governance*'
        }
    }

    It 'pins AzAPI and subscription-scope nested deployments to the reviewed template' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $templateFolder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'pinned-azapi')).FullName
        $templatePath = Join-Path $templateFolder 'azuredeploy.json'
        Set-Content -LiteralPath $templatePath -Value '{ "contentVersion": "1.0.0.0", "parameters": { "start": { "type": "string", "defaultValue": "2023-01-01T01:01:00" } }, "resources": [] }'
        $approvedHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $pinned = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $deployment = { param($template, $mode = 'Incremental', $actions = @('create')) @{ mode = 'managed'; address = 'azapi_resource.hub'; type = 'azapi_resource'; change = @{ actions = $actions; after = @{ type = 'Microsoft.Resources/deployments@2025-04-01'; body = @{ properties = @{ mode = $mode; template = $template } } } } } }
        $check = { param($change) Test-WorkloadPlan -Plan @{ resource_changes = @($change) } -AllowedSubscriptions @('approved') -ApprovedTemplateHashes @($approvedHash) -TemplateRoot $templateFolder }
        @(& $check (& $deployment $pinned)).Count | Should -Be 1
        { Test-WorkloadPlan -Plan @{ resource_changes = @(& $deployment $pinned) } -AllowedSubscriptions @('approved') } | Should -Throw '*pinned template*'
        $changed = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $changed.resources = @(@{ type = 'Microsoft.Authorization/roleAssignments'; apiVersion = '2022-04-01'; name = 'escalate' })
        { & $check (& $deployment $changed) } | Should -Throw '*pinned template*'
        { & $check (& $deployment $pinned 'Incremental' @('update')) } | Should -Throw '*pinned template*'
        { & $check (& $deployment $pinned 'Complete') } | Should -Throw '*Complete-mode*'
        $linked = & $deployment $null
        $linked.change.after.body.properties.templateLink = @{ uri = 'https://example.invalid/template.json' }
        { & $check $linked } | Should -Throw '*embed its pinned template*'
        $unknown = & $deployment $null
        { & $check $unknown } | Should -Throw '*pinned template*'
        $subscriptionScope = @{ mode = 'managed'; address = 'azurerm_subscription_template_deployment.x'; type = 'azurerm_subscription_template_deployment'; change = @{ actions = @('create'); after = @{ template_content = '{"resources":[{"type":"Microsoft.Authorization/roleAssignments"}]}' } } }
        { & $check $subscriptionScope } | Should -Throw '*pinned template*'
        $tenantScope = @{ mode = 'managed'; address = 'azurerm_tenant_template_deployment.x'; type = 'azurerm_tenant_template_deployment'; change = @{ actions = @('create'); after = @{ template_content = '{}' } } }
        { & $check $tenantScope } | Should -Throw '*governance*'
    }

    It 'allows only a pristine initialized new state after checking every target group is absent' {
        . (Join-Path $repoRoot 'data/workload-pipeline.ps1')
        $oldRunnerTemp = $env:RUNNER_TEMP
        $env:RUNNER_TEMP = $TestDrive
        $script:stateFixture = @{ version = 4; serial = 0; lineage = '11111111-1111-1111-1111-111111111111'; resources = @(); outputs = @{} }
        $config = @{ operation = 'new'; bindingId = 'test'; managedResourceGroups = @(@{ subscriptionId = 'approved'; name = 'new-rg' }); backend = @{ storageAccount = 'state'; container = 'tfstate'; key = 'new.tfstate'; subscriptionId = 'approved' } }
        Mock Invoke-WorkloadCommand {
            param($Command, $Arguments)
            if (($Arguments[0..2] -join ' ') -eq 'storage blob exists') { return @{ exists = $true } }
            if (($Arguments[0..2] -join ' ') -eq 'storage blob download') {
                $path = $Arguments[[array]::IndexOf($Arguments, '--file') + 1]
                $script:stateFixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
                return @{}
            }
            if (($Arguments[0..1] -join ' ') -eq 'group exists') { return $false }
            throw 'Unexpected command.'
        }
        try {
            (Read-WorkloadState -Config $config).serial | Should -Be 0
            Should -Invoke Invoke-WorkloadCommand -Times 1 -Exactly -ParameterFilter { ($Arguments[0..1] -join ' ') -eq 'group exists' }
            $script:stateFixture.serial = 1
            (Read-WorkloadState -Config $config).serial | Should -Be 1
            Should -Invoke Invoke-WorkloadCommand -Times 2 -Exactly -ParameterFilter { ($Arguments[0..1] -join ' ') -eq 'group exists' }
            $script:stateFixture.serial = 2
            { Read-WorkloadState -Config $config } | Should -Throw '*not owned by this workload*'
            $script:stateFixture.serial = 0
            $script:stateFixture.resources = @(@{ type = 'azurerm_resource_group'; name = 'existing'; mode = 'managed'; instances = @() })
            { Read-WorkloadState -Config $config } | Should -Throw '*not owned by this workload*'
            $script:stateFixture.resources = @()
            Mock Invoke-WorkloadCommand { $true } -ParameterFilter { ($Arguments[0..1] -join ' ') -eq 'group exists' }
            { Read-WorkloadState -Config $config } | Should -Throw '*scope already exists*'
            $config.operation = 'update'
            { Read-WorkloadState -Config $config } | Should -Throw '*not owned by this workload*'
        }
        finally { $env:RUNNER_TEMP = $oldRunnerTemp }
    }

    It 'publishes only a new feature branch and reuses a saved draft PR on retry' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $state = New-ALZState -DeliveryPath (Join-Path $TestRoot ([guid]::NewGuid().ToString('N')))
            $checkout = (New-Item -ItemType Directory -Path (Join-Path $state.deliveryPath 'review') -Force).FullName
            $null = New-Item -ItemType Directory -Path (Join-Path $checkout 'workloads/hub') -Force
            Set-Content -LiteralPath (Join-Path $checkout 'workloads/hub/main.tf') -Value 'resource "terraform_data" "example" {}'
            Mock Get-ALZWorkloadChangedFiles { @('workloads/hub/main.tf') }
            Mock Invoke-RestMethod {
                param($Uri, $Method, $Body)
                switch -Regex ($Uri) {
                    '/git/ref/heads/main$' { @{ object = @{ sha = 'base123' } } }
                    '/git/commits/base123$' { @{ tree = @{ sha = 'basetree' } } }
                    '/git/blobs$' { @{ sha = 'blob123' } }
                    '/git/trees$' { @{ sha = 'tree123' } }
                    '/git/commits$' { @{ sha = 'commit123' } }
                    '/git/refs$' {
                        ($Body | ConvertFrom-Json).ref | Should -Match '^refs/heads/autopilot/workload-'
                        @{}
                    }
                    '/pulls$' {
                        ($Body | ConvertFrom-Json).draft | Should -BeTrue
                        @{ html_url = 'https://github.com/contoso/platform/pull/7'; number = 7 }
                    }
                    default { throw 'Unexpected GitHub write.' }
                }
            }
            $repository = [pscustomobject]@{ Repository = 'contoso/platform'; Branch = 'main'; Commit = 'base123' }
            $first = Publish-ALZWorkloadPullRequest -State $state -Repository $repository -Checkout $checkout -Token 'fixture-token' -Title 'Add workload' -Body 'Review only'
            $second = Publish-ALZWorkloadPullRequest -State $state -Repository $repository -Checkout $checkout -Token 'fixture-token' -Title 'Add workload' -Body 'Review only'
            $first.pullRequestUrl | Should -Be $second.pullRequestUrl
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*/pulls' }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -in @('Patch', 'Put', 'Delete') -or $Uri -match '/dispatches|/merge' }
            Get-Content (Get-ALZStatePath -DeliveryPath $state.deliveryPath) -Raw | Should -Not -Match 'fixture-token'
        }
    }

    It 'excludes a new workload from legacy ALZ push and PR triggers without disabling ALZ updates' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            Import-Module powershell-yaml
            $checkout = (New-Item -ItemType Directory -Path (Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))) -Force).FullName
            $folder = (New-Item -ItemType Directory -Path (Join-Path $checkout '.github/workflows') -Force).FullName
            @{ on = @{ push = @{ branches = @('main') }; pull_request = @{ branches = @('main') }; workflow_dispatch = @{} }; jobs = @{ terraform = @{ uses = 'contoso/platform-templates/.github/workflows/cd-template.yaml@main' } } } | ConvertTo-Yaml | Set-Content (Join-Path $folder 'cd.yaml')
            Protect-ALZWorkloadLegacyTriggers -Checkout $checkout -Root 'workloads/hub'
            $workflow = Get-Content (Join-Path $folder 'cd.yaml') -Raw | ConvertFrom-Yaml
            $workflow.on.push['paths-ignore'] | Should -Contain 'workloads/hub/**'
            $workflow.jobs.terraform.uses | Should -Be 'contoso/platform-templates/.github/workflows/cd-template.yaml@main'
            $workflow.on.Contains('workflow_dispatch') | Should -BeTrue
        }
    }

    It 'keeps access setup read-only unless Apply is explicitly selected' {
        $configPath = Join-Path $TestDrive 'access-review.json'
        $subscription = '11111111-1111-1111-1111-111111111111'
        $tenant = '22222222-2222-2222-2222-222222222222'
        $planIdentity = "/subscriptions/$subscription/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/plan"
        $applyIdentity = "/subscriptions/$subscription/resourceGroups/rg-identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/apply"
        @{
            schemaVersion = 1; repository = 'contoso/platform'; allowedSubscriptionIds = @($subscription)
            managedResourceGroups = @(@{ subscriptionId = $subscription; name = 'rg-workload' })
            backend = @{ subscriptionId = $subscription; tenantId = $tenant; resourceGroup = 'rg-state'; storageAccount = 'existingstate'; container = 'tfstate' }
            pipeline = @{ templatesRepository = 'contoso/platform-templates'; planEnvironment = 'platform-plan'; applyEnvironment = 'platform-apply' }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath
        $script:accessCalls = @()
        Mock az {
            $global:LASTEXITCODE = 0
            $script:accessCalls += 'az ' + ($args -join ' ')
            if (($args[0..1] -join ' ') -eq 'account show') { return '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222"}' }
            if (($args[0..1] -join ' ') -eq 'group exists') { return 'true' }
            if (($args[0..1] -join ' ') -eq 'identity show') {
                $identityId = $args[[array]::IndexOf($args, '--ids') + 1]
                $mode = $identityId.Split('/')[-1]
                return (@{ id = $identityId; tenantId = '22222222-2222-2222-2222-222222222222'; principalId = "$mode-principal"; clientId = "$mode-client" } | ConvertTo-Json -Compress)
            }
            return '[]'
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            $script:accessCalls += 'gh ' + ($args -join ' ')
            if (($args -join ' ') -like '*oidc/customization*') { return '{"use_default":false,"include_claim_keys":["repository","environment","job_workflow_ref"]}' }
            return '{"variables":[]}'
        }
        $review = @(& (Join-Path $repoRoot 'data/Initialize-WorkloadAccess.ps1') -Configuration $configPath -PlanIdentityResourceId $planIdentity -ApplyIdentityResourceId $applyIdentity)
        $review.Count | Should -BeGreaterThan 0
        ($script:accessCalls -join "`n") | Should -Not -Match '\bcreate\b|--method POST|\bregister\b'
        @($review | Where-Object Present -EQ $false).Count | Should -BeGreaterThan 0
        @($review | Where-Object { $_.Requirement -eq 'Contributor' -and $_.Scope -eq "/subscriptions/$subscription/resourceGroups/rg-workload" }).Count | Should -Be 1
        @($review | Where-Object Requirement -EQ 'Role Based Access Control Administrator').Count | Should -Be 0
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
        $config.access = @{ applyRoles = @(@{ role = 'Contributor'; scope = "/subscriptions/$subscription" }) }
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { & (Join-Path $repoRoot 'data/Initialize-WorkloadAccess.ps1') -Configuration $configPath -PlanIdentityResourceId $planIdentity -ApplyIdentityResourceId $applyIdentity -Apply -Confirm:$false } | Should -Throw '*No access writes*'
        ($script:accessCalls -join "`n") | Should -Not -Match '\bcreate\b|--method POST|\bregister\b'
    }

    Context 'Entry point and resume' {
        BeforeEach {
            $state = New-ALZState -DeliveryPath (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            $source = New-Item -ItemType Directory -Path (Join-Path $state.deliveryPath 'source') -Force
            Set-Content (Join-Path $source.FullName 'main.tf') 'resource "terraform_data" "example" {}'
            $state.answers.customModulePath = $source.FullName
            $state.answers.workloadAttachmentVersion = 1
            $state.answers.workloadOperation = 'new'
            $state.answers.workloadRoot = 'workloads/example'
            $state.answers.workloadRepository = 'contoso/platform'
            $state.phaseStatus.interview = 'done'
            Mock Test-ALZTooling -ModuleName ALZWorkload { @() }
            Mock Test-ALZAzureLogin -ModuleName ALZWorkload { @() }
            Mock Test-ALZWorkloadGitHubSecurity -ModuleName ALZWorkload { @() }
            Mock Test-ALZWorkloadPipelineAccess -ModuleName ALZWorkload { $true }
            Mock Write-ALZResults -ModuleName ALZWorkload {}
            Mock Write-ALZStatus -ModuleName ALZWorkload {}
            Mock Read-Host -ModuleName ALZWorkload {
                $testToken = [Security.SecureString]::new()
                foreach ($character in 'test-only-token'.ToCharArray()) { $testToken.AppendChar($character) }
                return $testToken
            }
            Mock Read-ALZConfirm -ModuleName ALZWorkload { param($Prompt) $Prompt -like 'Prepare a local proposal*' }
            Mock Invoke-ALZBootstrap -ModuleName ALZWorkload { throw 'Bootstrap must never run.' }
            Mock Start-ALZWorkflow -ModuleName ALZWorkload { throw 'A workflow must never be dispatched.' }
            Mock Get-ALZWorkloadRepositoryContext -ModuleName ALZWorkload { [pscustomobject]@{ Repository = 'contoso/platform'; Id = '42'; Branch = 'main'; Commit = 'abc123'; Files = @('main.tf'); Variables = @{} } }
            Mock Read-ALZWorkloadBackend -ModuleName ALZWorkload {
                param($State)
                $State.answers.workloadBackend = @{ storageAccount = 'existingstate'; container = 'tfstate'; key = 'workloads/example.tfstate'; workspace = 'default' }
                return $State.answers.workloadBackend
            }
            Mock Get-ALZWorkloadSnapshot -ModuleName ALZWorkload { [pscustomobject]@{ StateExists = $false; ManagedResourceCount = 0; Lineage = ''; Serial = 0; AzureResourceCount = 0; ResourceGroupExists = $false } }
            Mock New-ALZWorkloadProposal -ModuleName ALZWorkload { [pscustomobject]@{ Checkout = 'local-review'; Root = 'local-review/workloads/example'; BackendConfig = 'local-backend'; BaseCommit = 'abc123' } }
        }

        It 'prepares a local proposal while skipping bootstrap and leaving apply pending' {
            Invoke-ALZWorkloadDelivery -State $state
            $state.phaseStatus.bootstrap | Should -Be 'skipped'
            $state.phaseStatus.preflight | Should -Be 'done'
            $state.phaseStatus.config | Should -Be 'done'
            $state.phaseStatus.proof | Should -Be 'pending'
            $state.phaseStatus.run | Should -Be 'pending'
            Should -Invoke New-ALZWorkloadProposal -ModuleName ALZWorkload -Times 1 -Exactly
            Should -Invoke Invoke-ALZBootstrap -ModuleName ALZWorkload -Times 0 -Exactly
            Should -Invoke Start-ALZWorkflow -ModuleName ALZWorkload -Times 0 -Exactly
            Get-Content (Get-ALZStatePath $state.deliveryPath) -Raw | Should -Not -Match 'test-only-token'
        }

        It 'blocks inaccessible state without preparing or bootstrapping anything' {
            Mock Get-ALZWorkloadSnapshot -ModuleName ALZWorkload { throw 'Backend is unreachable.' }
            Invoke-ALZWorkloadDelivery -State $state
            $state.phaseStatus.preflight | Should -Be 'failed'
            $state.phaseStatus.bootstrap | Should -Be 'skipped'
            Should -Invoke New-ALZWorkloadProposal -ModuleName ALZWorkload -Times 0 -Exactly
            Should -Invoke Invoke-ALZBootstrap -ModuleName ALZWorkload -Times 0 -Exactly
        }

        It 'marks private state pending when deferring validation to the existing runner' {
            $state.answers.workloadUsePipeline = $true
            $state.answers.workloadValidationMode = 'runner'
            Mock Read-ALZWorkloadPipeline -ModuleName ALZWorkload { @{} }
            Mock Test-ALZWorkloadPipelineAccess -ModuleName ALZWorkload { $true }
            Mock Get-ALZWorkloadSnapshot -ModuleName ALZWorkload { throw 'Local private-state reads should be deferred.' }
            Mock Write-ALZWorkloadWorkflow -ModuleName ALZWorkload { [pscustomobject]@{ Workflow = 'review-workflow' } }
            Mock Protect-ALZWorkloadLegacyTriggers -ModuleName ALZWorkload {}
            Mock New-ALZWorkloadTemplateProposal -ModuleName ALZWorkload { [pscustomobject]@{ Checkout = 'template-review'; Repository = @{} } }
            Invoke-ALZWorkloadDelivery -State $state
            $state.phaseStatus.preflight | Should -Be 'pending'
            $state.answers.workloadClassification | Should -Be 'pending runner validation'
            Should -Invoke Get-ALZWorkloadSnapshot -ModuleName ALZWorkload -Times 0 -Exactly
            Should -Invoke Invoke-ALZBootstrap -ModuleName ALZWorkload -Times 0 -Exactly
            Should -Invoke Start-ALZWorkflow -ModuleName ALZWorkload -Times 0 -Exactly
        }

        It 're-interviews legacy workload sessions instead of resuming their bootstrap' {
            $state.answers.workloadAttachmentVersion = $null
            $state.phaseStatus.bootstrap = 'failed'
            Mock Invoke-ALZWorkloadInterview -ModuleName ALZWorkload {
                param($State)
                $State.answers.workloadAttachmentVersion = 1
                return $State
            }
            Invoke-ALZWorkloadDelivery -State $state
            Should -Invoke Invoke-ALZWorkloadInterview -ModuleName ALZWorkload -Times 1 -Exactly
            Should -Invoke Invoke-ALZBootstrap -ModuleName ALZWorkload -Times 0 -Exactly
            $state.phaseStatus.bootstrap | Should -Be 'skipped'
        }

        It 'does not regenerate shared workflows when preserving an existing attachment' {
            $state.answers.workloadUsePipeline = $true
            Mock Read-ALZWorkloadPipeline -ModuleName ALZWorkload { @{} }
            Mock Write-ALZWorkloadWorkflow -ModuleName ALZWorkload { [pscustomobject]@{ Workflow = 'review-workflow'; Preserved = $true } }
            Mock Protect-ALZWorkloadLegacyTriggers -ModuleName ALZWorkload { throw 'Must preserve existing triggers' }
            Mock New-ALZWorkloadTemplateProposal -ModuleName ALZWorkload { throw 'Must not regenerate shared workflow' }
            Invoke-ALZWorkloadDelivery -State $state
            $state.phaseStatus.config | Should -Be 'done'
            Should -Invoke New-ALZWorkloadTemplateProposal -ModuleName ALZWorkload -Times 0 -Exactly
            Should -Invoke Protect-ALZWorkloadLegacyTriggers -ModuleName ALZWorkload -Times 0 -Exactly
        }
    }
}

Describe 'GitHub security and runner boundaries' -Tag 'Security' {
    BeforeEach {
        $protection = @{
            required_pull_request_reviews = @{ required_approving_review_count = 1; require_code_owner_reviews = $true }
            required_status_checks = @{ contexts = @('validate') }
            enforce_admins = @{ enabled = $true }
            allow_force_pushes = @{ enabled = $false }
            allow_deletions = @{ enabled = $false }
        }
        $snapshot = @{
            Branch = 'main'
            Repository = @{ private = $true }
            Organization = @{ plan = @{ name = 'enterprise' }; two_factor_requirement_enabled = $true; default_repository_permission = 'none'; members_can_create_public_repositories = $false }
            Protection = $protection
            TemplateProtection = $protection
            Actions = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
            Environment = @{ deployment_branch_policy = @{ custom_branch_policies = $true }; can_admins_bypass = $false; protection_rules = @(@{ type = 'required_reviewers'; reviewers = @(@{ type = 'Team'; reviewer = @{ id = 1 } }); prevent_self_review = $true }) }
            EnvironmentBranches = @{ branch_policies = @(@{ name = 'main'; type = 'branch' }) }
            Unavailable = @()
        }
    }

    It 'recognizes configured Enterprise controls without claiming runner isolation' {
        $findings = @(Get-ALZGitHubSecurityFindings -Snapshot $snapshot -Profile production)
        @($findings | Where-Object Status -EQ 'FAIL').Count | Should -Be 0
        ($findings | Where-Object Name -EQ 'Deployment approval capability').Status | Should -Be 'OK'
    }

    It 'never claims private environment reviewer support on Team' {
        $snapshot.Organization.plan.name = 'team'
        foreach ($profile in @('learning', 'production')) {
            $finding = Get-ALZGitHubSecurityFindings -Snapshot $snapshot -Profile $profile | Where-Object Name -EQ 'Deployment approval capability'
            $finding.Status | Should -Be $(if ($profile -eq 'production') { 'FAIL' } else { 'WARN' })
            $finding.Detail | Should -Match 'Manual dispatch is not independent approval'
        }
    }

    It 'blocks missing <Control> evidence in production' -ForEach @(
        @{ Control = 'Organization'; Finding = 'Organization 2FA' }
        @{ Control = 'Protection'; Finding = 'Workload PR review' }
        @{ Control = 'TemplateProtection'; Finding = 'Reusable workflow PR review' }
        @{ Control = 'Actions'; Finding = 'Workflow token defaults' }
        @{ Control = 'Environment'; Finding = 'Deployment approval capability' }
        @{ Control = 'EnvironmentBranches'; Finding = 'Apply branch restriction' }
    ) {
        $snapshot.Remove($Control)
        $findings = @(Get-ALZGitHubSecurityFindings -Snapshot $snapshot -Profile production)
        ($findings | Where-Object Name -EQ $Finding).Status | Should -Be 'FAIL'
    }

    It 'does not accept a tag or wildcard as the exact apply branch boundary' {
        $snapshot.EnvironmentBranches.branch_policies[0].type = 'tag'
        (Get-ALZGitHubSecurityFindings -Snapshot $snapshot | Where-Object Name -EQ 'Apply branch restriction').Status | Should -Be 'FAIL'
        $snapshot.EnvironmentBranches.branch_policies[0].type = 'branch'
        $snapshot.EnvironmentBranches.branch_policies[0].name = '*'
        (Get-ALZGitHubSecurityFindings -Snapshot $snapshot | Where-Object Name -EQ 'Apply branch restriction').Status | Should -Be 'FAIL'
    }

    It 'reports denied settings without making GitHub writes or exposing credentials' {
        InModuleScope ALZPreflight {
            Mock Invoke-RestMethod { throw 'fixture-token must not be displayed' }
            $findings = @(Test-ALZWorkloadGitHubSecurity -Repository 'contoso/platform' -Branch main -Pipeline @{ templatesRepository = 'contoso/templates'; applyEnvironment = 'apply'; securityProfile = 'production' } -Token 'fixture-token')
            @($findings | Where-Object Name -Like 'Security evidence:*').Count | Should -BeGreaterThan 0
            ($findings | ConvertTo-Json -Depth 6) | Should -Not -Match 'fixture-token'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'Get' }
        }
    }

    It 'rejects overlapping plan and apply runner pools in production' {
        InModuleScope ALZWorkload {
            $pipeline = @{ securityProfile = 'production'; runnerIsolationReviewed = $true; planRunnerLabels = @('self-hosted', 'plan'); applyRunnerLabels = @('self-hosted', 'apply') }
            $runners = @(@{ id = 1; status = 'online'; labels = @(@{name='self-hosted'}, @{name='plan'}, @{name='apply'}) })
            { Test-ALZWorkloadRunnerIsolation -Pipeline $pipeline -Runners $runners } | Should -Throw '*overlap*'
            $pipeline.securityProfile = 'learning'
            { Test-ALZWorkloadRunnerIsolation -Pipeline $pipeline -Runners $runners } | Should -Not -Throw
        }
    }

    It 'requires disjoint available runners and a separate production isolation review' {
        InModuleScope ALZWorkload {
            $pipeline = @{ securityProfile = 'production'; planRunnerLabels = @('self-hosted', 'plan'); applyRunnerLabels = @('self-hosted', 'apply') }
            $runners = @(
                @{ id = 1; status = 'online'; labels = @(@{name='self-hosted'}, @{name='plan'}) }
                @{ id = 2; status = 'online'; labels = @(@{name='self-hosted'}, @{name='apply'}) }
            )
            { Test-ALZWorkloadRunnerIsolation -Pipeline $pipeline -Runners $runners } | Should -Throw '*not been reviewed*'
            $pipeline.runnerIsolationReviewed = $true
            Test-ALZWorkloadRunnerIsolation -Pipeline $pipeline -Runners $runners | Should -BeTrue
            $runners[1].status = 'offline'
            { Test-ALZWorkloadRunnerIsolation -Pipeline $pipeline -Runners $runners } | Should -Throw '*No existing online apply runner*'
        }
    }

    It 'loads an existing attachment at its pinned commit without rewriting the caller' {
        InModuleScope ALZWorkload -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            Import-Module powershell-yaml
            $state = @{ deliveryPath = $TestRoot; answers = @{
                workloadRepository='contoso/platform'; workloadRoot='workloads/example'; workloadBranch='main'; workloadOperation='new'; workloadResourceGroup='rg-example'; workloadValidationMode='runner'
                subscriptions=@{management='22222222-2222-2222-2222-222222222222'}
                workloadBackend=@{subscriptionId='11111111-1111-1111-1111-111111111111';tenantId='33333333-3333-3333-3333-333333333333';storageAccount='state';resourceGroup='rg-state';container='tfstate';key='example/state';workspace='default'}
                workloadPipeline=@{templatesRepository='contoso/templates';planEnvironment='plan';applyEnvironment='apply';securityProfile='learning';planRunnerLabels=@('self-hosted','plan');applyRunnerLabels=@('self-hosted','apply')}
            } }
            $files = Write-ALZWorkloadWorkflow -State $state -Checkout $TestRoot
            $script:savedConfig = [IO.File]::ReadAllText($files.Config)
            $script:savedCaller = [IO.File]::ReadAllText($files.Workflow)
            $before = (Get-FileHash $files.Workflow).Hash
            $state.answers.workloadOperation = 'update'
            $state.answers.workloadStateLineage = '44444444-4444-4444-4444-444444444444'
            Mock Save-ALZState {}
            Mock Read-ALZValue { 'learning' }
            Mock Invoke-RestMethod {
                param($Uri)
                $Uri | Should -Match '\?ref=reviewedcommit$'
                $content = if ($Uri -match '/contents/\.github/autopilot/') { $script:savedConfig } else { $script:savedCaller }
                @{ encoding='base64'; content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content)) }
            }
            $pipeline = Read-ALZWorkloadPipeline -State $state -Repository ([pscustomobject]@{Repository='contoso/platform';Commit='reviewedcommit'}) -Token 'fixture-token'
            $pipeline.templatesRepository | Should -Be 'contoso/templates'
            $pipeline.planRunnerLabels | Should -Contain 'plan'
            $pipeline.applyRunnerLabels | Should -Contain 'apply'
            (Get-FileHash $files.Workflow).Hash | Should -Be $before
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'Get' }
        }
    }
}

Describe 'Advisory official release checks' -Tag 'Versions' {
    It 'reports newer stable releases without changing local versions or files' {
        InModuleScope ALZOrchestrator -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            Set-Content (Join-Path $TestRoot '.alz-version-data.json') '{"bootstrapVersion":"v7.2.1","starterVersion":"v17.4.0"}'
            $before = (Get-FileHash (Join-Path $TestRoot '.alz-version-data.json')).Hash
            Mock Get-Module { [pscustomobject]@{ Version = [version]'7.1.4' } } -ParameterFilter { $ListAvailable -and $Name -eq 'ALZ' }
            Mock Invoke-WebRequest {
                param($Uri)
                if ($Uri -like '*powershellgallery*') { return @{ Content = '<feed><entry><properties><Version>7.1.5</Version></properties></entry></feed>' } }
                $version = if ($Uri -like '*bootstrap*') { 'v7.3.0' } else { 'v17.5.1' }
                return @{ Content = (@{ tag_name = $version; draft = $false; prerelease = $false } | ConvertTo-Json) }
            }
            Mock Install-PSResource { throw 'Unexpected installation' }
            Mock Update-PSResource { throw 'Unexpected upgrade' }
            $results = @(Get-ALZReleaseStatus -DeliveryPath $TestRoot)
            $results.Count | Should -Be 4
            ($results | Where-Object Component -EQ 'Bootstrap').Status | Should -Be 'Newer release available'
            ($results | Where-Object Component -EQ 'ALZ PowerShell').LatestStable | Should -Be '7.1.5'
            (Get-FileHash (Join-Path $TestRoot '.alz-version-data.json')).Hash | Should -Be $before
            Should -Invoke Install-PSResource -Times 0 -Exactly
            Should -Invoke Update-PSResource -Times 0 -Exactly
        }
    }

    It 'treats failed release lookups as unknown, not current or upgrade-required' {
        InModuleScope ALZOrchestrator {
            Mock Invoke-WebRequest { throw 'HTTP 429 fixture' }
            $results = @(Get-ALZReleaseStatus)
            @($results | Where-Object Status -EQ 'Unavailable; versions unchanged').Count | Should -Be 4
            @($results | Where-Object LatestStable).Count | Should -Be 0
        }
    }

    It 'supports offline checks without network calls' {
        InModuleScope ALZOrchestrator {
            Mock Invoke-WebRequest { throw 'Network must not be used' }
            $results = @(Get-ALZReleaseStatus -SkipOnline)
            $results.Count | Should -Be 4
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
    }

    It 'keeps an installed package without automatically upgrading it' {
        InModuleScope ALZOrchestrator {
            Mock Get-InstalledPSResource { [pscustomobject]@{ Version = '7.1.4' } }
            Mock Update-PSResource { throw 'Unexpected upgrade' }
            Mock Install-PSResource { throw 'Unexpected installation' }
            Install-ALZModuleIfNeeded
            Should -Invoke Update-PSResource -Times 0 -Exactly
            Should -Invoke Install-PSResource -Times 0 -Exactly
        }
    }

    It 'does not delete state or version metadata when a pinned bootstrap download is incomplete' {
        InModuleScope ALZOrchestrator -Parameters @{ TestRoot = $TestDrive } {
            param($TestRoot)
            $null = New-Item -ItemType Directory -Path "$TestRoot/config", "$TestRoot/bootstrap" -Force
            Set-Content "$TestRoot/config/inputs.yaml" 'reviewed: true'
            Set-Content "$TestRoot/.alz-version-data.json" '{"bootstrapVersion":"v7.2.1"}'
            Set-Content "$TestRoot/bootstrap/terraform.tfstate" 'state fixture that must remain'
            $state = @{ deliveryPath=$TestRoot; answers=@{vcs='github';iacType='terraform'} }
            { Invoke-ALZBootstrap -State $state } | Should -Throw '*no delivery files were deleted*'
            Get-Content "$TestRoot/bootstrap/terraform.tfstate" | Should -Be 'state fixture that must remain'
            Test-Path "$TestRoot/.alz-version-data.json" | Should -BeTrue
        }
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

Describe 'Own configuration mode' -Tag 'OwnConfig' {
    BeforeAll {
        $script:dataPath = Join-Path $repoRoot 'data'
        $script:mgmt = '11111111-1111-1111-1111-111111111111'
        $script:conn = '22222222-2222-2222-2222-222222222222'
        $script:tenant = '33333333-3333-3333-3333-333333333333'
        function New-TestInputs {
            [ordered]@{
                iac_type                  = 'terraform'
                bootstrap_module_name     = 'alz_github'
                bootstrap_location        = 'westus2'
                github_organization_name  = 'contoso'
                subscription_ids          = @{ management = $script:mgmt; connectivity = $script:conn }
                bootstrap_subscription_id = $script:mgmt
                bootstrap_module_version  = 'v7.3.0'
                starter_module_version    = 'v17.5.1'
                apply_approvers           = @()
                use_self_hosted_runners   = $true
            }
        }
        $script:vwanWithIntent = "connectivity_type = `"virtual_wan`"`nprimary_firewall_enabled = true`nrouting_intents = {}"
        function Invoke-TestOwnConfig {
            param($Inputs = (New-TestInputs), [string]$InputsText = 'bootstrap_location: westus2', [string]$Platform = $script:vwanWithIntent, [string]$Default = $script:tenant, [string]$Management = $script:tenant, [string]$Plan = 'team', $Recorded)
            Test-ALZOwnConfig -Inputs $Inputs -InputsText $InputsText -PlatformConfigText $Platform -DefaultTenantId $Default -ManagementTenantId $Management -GitHubPlan $Plan -RecordedVersions $Recorded
        }
        function New-TestOutput {
            param([string]$Root, [long]$Serial = 5, [string]$Lineage = 'lineage-a', [string[]]$Versions = @('v7.3.0'))
            $output = Join-Path $Root 'output'
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            @{ bootstrapVersion = $Versions[0]; starterVersion = 'v17.5.1' } | ConvertTo-Json | Set-Content (Join-Path $output '.alz-version-data.json')
            foreach ($version in $Versions) {
                $folder = Join-Path $output "bootstrap\$version\alz\github"
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                @{ version = 4; serial = $Serial; lineage = $Lineage; resources = @(@{ type = 'a' }, @{ type = 'b' }) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $folder 'terraform.tfstate')
            }
            return $output
        }
    }

    It 'routes option 6 to the own-configuration delivery' {
        InModuleScope ALZWorkload {
            Mock Read-ALZValue { '6' }
            Mock Save-ALZState {}
            $result = Set-ALZDeliveryType -State @{ answers = @{} }
            $result.answers.deliveryType | Should -Be 'ownconfig'
            $result.answers.deliveryIntent | Should -Be 'own-config'
        }
    }

    It 'never generates configuration, interviews, or uses the prompting bootstrap' {
        $definition = (Get-Command Invoke-ALZOwnConfigDelivery).Definition
        $definition | Should -Not -Match '\b(Write-ALZInputsYaml|Write-ALZStarterTfvars|Invoke-ALZInterview|Invoke-ALZBootstrap)\b'
    }

    It 'accepts a complete, pinned configuration' {
        $results = Invoke-TestOwnConfig
        @($results | Where-Object Status -EQ 'FAIL') | Should -BeNullOrEmpty
        @($results | Where-Object Status -EQ 'WARN') | Should -BeNullOrEmpty
    }

    It 'fails when a token key is stored in inputs.yaml' {
        $inputs = New-TestInputs
        $inputs['github_personal_access_token'] = 'not-a-real-token'
        (Invoke-TestOwnConfig -Inputs $inputs | Where-Object Name -EQ 'Secrets in configuration').Status | Should -Be 'FAIL'
    }

    It 'fails when a token-like value appears in the platform config' {
        $platform = "$script:vwanWithIntent`nnote = `"ghp_$('a' * 36)`""
        (Invoke-TestOwnConfig -Platform $platform | Where-Object Name -EQ 'Secrets in configuration').Status | Should -Be 'FAIL'
    }

    It 'fails on example placeholders but ignores them in comments' {
        (Invoke-TestOwnConfig -InputsText 'bootstrap_location: "<region-1>"' | Where-Object Name -EQ 'Unfilled placeholders').Status | Should -Be 'FAIL'
        Invoke-TestOwnConfig -InputsText "# see <region-1>`nbootstrap_location: westus2" -Platform "/* <region-1> */`n$script:vwanWithIntent" |
            Where-Object Name -EQ 'Unfilled placeholders' | Should -BeNullOrEmpty
    }

    It 'fails approvers on the GitHub Team plan and allows an empty list' {
        $inputs = New-TestInputs
        $inputs['apply_approvers'] = @('octocat')
        (Invoke-TestOwnConfig -Inputs $inputs | Where-Object Name -EQ 'Apply approvers').Status | Should -Be 'FAIL'
        (Invoke-TestOwnConfig -Inputs $inputs -Plan 'enterprise' | Where-Object Name -EQ 'Apply approvers').Status | Should -Be 'OK'
        (Invoke-TestOwnConfig | Where-Object Name -EQ 'Apply approvers').Status | Should -Be 'OK'
    }

    It 'fails when the CLI default is another tenant or the subscription is not visible' {
        (Invoke-TestOwnConfig -Default '44444444-4444-4444-4444-444444444444' | Where-Object Name -EQ 'Azure tenant').Status | Should -Be 'FAIL'
        (Invoke-TestOwnConfig -Management '' | Where-Object Name -EQ 'Azure tenant').Status | Should -Be 'FAIL'
    }

    It 'warns on unpinned versions and fails on a version change against the output folder' {
        $inputs = New-TestInputs
        $inputs.Remove('starter_module_version')
        (Invoke-TestOwnConfig -Inputs $inputs | Where-Object Name -EQ 'Pinned versions').Status | Should -Be 'WARN'
        $recorded = [pscustomobject]@{ bootstrapVersion = 'v7.2.1'; starterVersion = 'v17.5.1' }
        (Invoke-TestOwnConfig -Recorded $recorded | Where-Object Name -EQ 'Version change').Status | Should -Be 'FAIL'
    }

    It 'fails on duplicate or missing platform subscriptions' {
        $inputs = New-TestInputs
        $inputs['subscription_ids'] = @{ management = $script:mgmt; connectivity = $script:mgmt }
        (Invoke-TestOwnConfig -Inputs $inputs | Where-Object Name -EQ 'Subscription IDs').Status | Should -Be 'FAIL'
        $inputs.Remove('subscription_ids')
        @(Invoke-TestOwnConfig -Inputs $inputs | Where-Object { $_.Name -like 'Subscription: *' -and $_.Status -eq 'FAIL' }).Count | Should -Be 2
    }

    It 'warns when a secured Virtual WAN hub has no routing intent' {
        (Invoke-TestOwnConfig -Platform "connectivity_type = `"virtual_wan`"`nprimary_firewall_enabled = true" | Where-Object Name -EQ 'Virtual WAN routing intent').Status | Should -Be 'WARN'
    }

    It 'warns when the private DNS zone regex filter is enabled but not when it is commented out' {
        $on = "private_link_private_dns_zones_regex_filter = {`n  enabled = true`n}"
        (Invoke-TestOwnConfig -Platform $on | Where-Object Name -EQ 'Private DNS zone filter').Status | Should -Be 'WARN'
        @(Invoke-TestOwnConfig -Platform ("# " + ($on -replace "`n", "`n# ")) | Where-Object Name -EQ 'Private DNS zone filter').Count | Should -Be 0
        $trap = (Get-Content (Join-Path $script:dataPath 'traps.json') -Raw | ConvertFrom-Json).traps | Where-Object id -EQ 'private-dns-zone-filter-primary-hub'
        "The Resource 'Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net' under resource group 'rg-dns' was not found." | Should -Match $trap.pattern
    }

    It 'derives the bootstrap state resource group name' {
        Get-ALZOwnConfigStateResourceGroupName -Inputs (New-TestInputs) | Should -Be 'rg-alz-mgmt-state-westus2-001'
        $inputs = New-TestInputs
        $inputs['resource_names'] = @{ resource_group_state = 'rg-{{service_name}}-tfstate-{{postfix_number}}' }
        $inputs['postfix_number'] = 7
        Get-ALZOwnConfigStateResourceGroupName -Inputs $inputs | Should -Be 'rg-alz-tfstate-007'
    }

    It 'reads bootstrap state metadata and flags more than one state as ambiguous' {
        $state = Get-ALZOwnConfigBootstrapState -OutputPath (New-TestOutput -Root (Join-Path $TestDrive 'one')) -Inputs (New-TestInputs)
        $state.Exists | Should -BeTrue
        $state.Serial | Should -Be 5
        $state.Lineage | Should -Be 'lineage-a'
        $state.ResourceCount | Should -Be 2
        (Get-ALZOwnConfigBootstrapState -OutputPath (New-TestOutput -Root (Join-Path $TestDrive 'two') -Versions @('v7.2.1', 'v7.3.0')) -Inputs (New-TestInputs)).Ambiguous | Should -BeTrue
    }

    It 'blocks a second bootstrap when Azure has one but the folder has no state' {
        $layout = Get-ALZOwnConfigLayout -DeliveryPath (Join-Path $TestDrive 'empty-delivery')
        $none = [pscustomobject]@{ Exists = $false; Ambiguous = $false }
        (Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState $none -StateResourceGroupName 'rg-x' -StateResourceGroupExists $true).Status | Should -Be 'FAIL'
        (Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState $none -StateResourceGroupName 'rg-x' -StateResourceGroupExists $false).Status | Should -Be 'OK'
        (Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState $none -StateResourceGroupName 'rg-x' -StateResourceGroupExists $null).Status | Should -Be 'WARN'
        $existing = [pscustomobject]@{ Exists = $true; Ambiguous = $false; Serial = 9; ResourceCount = 3; Lineage = 'l' }
        (Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState $existing -StateResourceGroupName 'rg-x' -StateResourceGroupExists $true).Status | Should -Be 'OK'
    }

    It 'refuses a folder that also holds a guided-bootstrap layout' {
        $delivery = Join-Path $TestDrive 'mixed-delivery'
        New-Item -ItemType Directory -Path (Join-Path $delivery 'bootstrap') -Force | Out-Null
        $layout = Get-ALZOwnConfigLayout -DeliveryPath $delivery
        $results = Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState ([pscustomobject]@{ Exists = $true; Ambiguous = $false }) -StateResourceGroupName 'rg-x' -StateResourceGroupExists $true
        ($results | Where-Object Name -EQ 'Delivery layout').Status | Should -Be 'FAIL'
    }

    It 'summarizes a plan by address and flags blocking and review changes' {
        $plan = [pscustomobject]@{ resource_changes = @(
                [pscustomobject]@{ address = 'module.github.github_repository_file.a'; type = 'github_repository_file'; change = [pscustomobject]@{ actions = @('update') } }
                [pscustomobject]@{ address = 'module.azure.azurerm_public_ip.alz[0]'; type = 'azurerm_public_ip'; action_reason = 'replace_because_cannot_update'; change = [pscustomobject]@{ actions = @('delete', 'create'); replace_paths = @(, @('ip_tags')) } }
                [pscustomobject]@{ address = 'module.azure.azurerm_storage_account.alz'; type = 'azurerm_storage_account'; change = [pscustomobject]@{ actions = @('delete') } }
                [pscustomobject]@{ address = 'module.azure.azurerm_user_assigned_identity.plan'; type = 'azurerm_user_assigned_identity'; change = [pscustomobject]@{ actions = @('create', 'delete'); replace_paths = @(, @('name')) } }
                [pscustomobject]@{ address = 'module.github.github_team.alz'; type = 'github_team'; change = [pscustomobject]@{ actions = @('no-op') } }
            )
        }
        $review = ConvertTo-ALZOwnConfigPlanReview -Plan $plan
        $review.Changes.Count | Should -Be 4
        $review.Counts.update | Should -Be 1
        $review.Counts.replace | Should -Be 2
        $review.Counts.delete | Should -Be 1
        $review.Blocked | Should -BeTrue
        ($review.Findings | Where-Object Id -EQ 'public-ip-platform-ip-tags').Severity | Should -Be 'Block'
        ($review.Findings | Where-Object Id -EQ 'delivery-resource-destroyed').Severity | Should -Be 'Block'
        ($review.Findings | Where-Object Id -EQ 'pipeline-identity-replaced').Severity | Should -Be 'Review'
    }

    It 'flags repository file updates that change only commit metadata' {
        $file = { param($address, $before, $after) [pscustomobject]@{ address = $address; type = 'github_repository_file'; change = [pscustomobject]@{ actions = @('update'); before = $before; after = $after } } }
        $plan = [pscustomobject]@{ resource_changes = @(
                (& $file 'f.meta' ([pscustomobject]@{ content = 'x'; commit_author = 'a'; commit_email = 'a' }) ([pscustomobject]@{ content = 'x'; commit_author = 'b'; commit_email = 'b' }))
                (& $file 'f.content' ([pscustomobject]@{ content = 'x'; commit_author = 'a' }) ([pscustomobject]@{ content = 'y'; commit_author = 'b' }))
            )
        }
        $review = ConvertTo-ALZOwnConfigPlanReview -Plan $plan
        $finding = $review.Findings | Where-Object Id -EQ 'repository-file-metadata-only'
        $finding.Severity | Should -Be 'Review'
        $finding.Address | Should -Be '1 repository file(s)'
        $review.Blocked | Should -BeFalse
        ($review.Changes | Where-Object Address -EQ 'f.content').ChangedAttributes | Should -Be @('commit_author', 'content')
    }

    It 'runs the accelerator plan-only with the guard, then restores the environment' {
        if (-not (Get-Command Deploy-Accelerator -ErrorAction SilentlyContinue)) { function global:Deploy-Accelerator { param($inputConfigFilePaths, $output_folder_path, [switch]$auto_approve, $starter_additional_files) } }
        $delivery = Join-Path $TestDrive 'plan-delivery'
        $output = New-TestOutput -Root $delivery
        New-Item -ItemType Directory -Path (Join-Path $delivery 'config\lib') -Force | Out-Null
        Set-Content (Join-Path $delivery 'config\inputs.yaml') 'iac_type: terraform'
        Set-Content (Join-Path $delivery 'config\platform-landing-zone.tfvars') 'starter_locations = ["westus2"]'
        $script:seen = $null
        Mock Deploy-Accelerator -ModuleName ALZOwnConfig {
            $script:seen = [pscustomobject]@{ Guard = $env:TF_CLI_ARGS_apply; Token = $env:TF_VAR_github_personal_access_token; Parameters = $PesterBoundParameters }
            Set-Content (Join-Path $output_folder_path 'bootstrap\v7.3.0\alz\github\tfplan') 'plan'
            throw 'Terraform apply failed with exit code 1 after 5 attempts.'
        }
        $env:TF_CLI_ARGS_apply = $null
        $secure = ConvertTo-SecureString 'test-only-value' -AsPlainText -Force
        $result = Invoke-ALZOwnConfigPlan -Layout (Get-ALZOwnConfigLayout -DeliveryPath $delivery) -Inputs (New-TestInputs) -VcsToken $secure -DataPath $script:dataPath 6>$null
        $result.Succeeded | Should -BeTrue
        $result.OutputPath | Should -Be $output
        $script:seen.Guard | Should -Be '-alz-autopilot-plan-only-guard'
        $script:seen.Token | Should -Be 'test-only-value'
        $script:seen.Parameters.auto_approve | Should -BeTrue
        $script:seen.Parameters.output_folder_path | Should -Be $output
        @($script:seen.Parameters.starter_additional_files) | Should -Be @((Join-Path $delivery 'config\lib'))
        $env:TF_CLI_ARGS_apply | Should -BeNullOrEmpty
        $env:TF_VAR_github_personal_access_token | Should -BeNullOrEmpty
        Remove-Item $result.TranscriptPath -ErrorAction SilentlyContinue
    }

    It 'fails the plan step if bootstrap state changed during a plan-only run' {
        if (-not (Get-Command Deploy-Accelerator -ErrorAction SilentlyContinue)) { function global:Deploy-Accelerator { param($inputConfigFilePaths, $output_folder_path, [switch]$auto_approve, $starter_additional_files) } }
        $delivery = Join-Path $TestDrive 'changed-delivery'
        New-TestOutput -Root $delivery | Out-Null
        Mock Deploy-Accelerator -ModuleName ALZOwnConfig {
            $folder = Join-Path $output_folder_path 'bootstrap\v7.3.0\alz\github'
            @{ serial = 6; lineage = 'lineage-a'; resources = @() } | ConvertTo-Json | Set-Content (Join-Path $folder 'terraform.tfstate')
            Set-Content (Join-Path $folder 'tfplan') 'plan'
        }
        $result = Invoke-ALZOwnConfigPlan -Layout (Get-ALZOwnConfigLayout -DeliveryPath $delivery) -Inputs (New-TestInputs) -DataPath $script:dataPath 6>$null
        $result.Succeeded | Should -BeFalse
        $result.StateChanged | Should -BeTrue
        Remove-Item $result.TranscriptPath -ErrorAction SilentlyContinue
    }

    It 'discards the plan and applies nothing when state changed after review' {
        $delivery = Join-Path $TestDrive 'stale-delivery'
        $output = New-TestOutput -Root $delivery -Serial 8
        $folder = Join-Path $output 'bootstrap\v7.3.0\alz\github'
        Set-Content (Join-Path $folder 'tfplan') 'plan'
        $planResult = [pscustomobject]@{ PlanPath = (Join-Path $folder 'tfplan'); BootstrapFolder = $folder; OutputPath = $output; StateBefore = [pscustomobject]@{ Exists = $true; Serial = 7; Lineage = 'lineage-a' } }
        { Invoke-ALZOwnConfigApply -PlanResult $planResult -Inputs (New-TestInputs) -ExpectedChanges 1 -DataPath $script:dataPath } | Should -Throw '*changed after the plan*'
        Test-Path (Join-Path $folder 'tfplan') | Should -BeFalse
    }

    It 'the Terraform apply guard blocks saved-plan and retry applies without writing state' -Skip:(-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        $work = Join-Path $TestDrive 'guard'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Set-Content (Join-Path $work 'main.tf') 'resource "terraform_data" "x" { input = "guard" }'
        & terraform "-chdir=$work" init -input=false -no-color *> $null
        & terraform "-chdir=$work" plan -out=tfplan -input=false -no-color *> $null
        $LASTEXITCODE | Should -Be 0
        try {
            $env:TF_CLI_ARGS_apply = '-alz-autopilot-plan-only-guard'
            & terraform "-chdir=$work" apply -auto-approve -input=false tfplan *> $null
            $LASTEXITCODE | Should -Not -Be 0
            & terraform "-chdir=$work" apply -auto-approve -input=false *> $null
            $LASTEXITCODE | Should -Not -Be 0
        }
        finally { $env:TF_CLI_ARGS_apply = $null }
        Test-Path (Join-Path $work 'terraform.tfstate') | Should -BeFalse
    }

    It 'applies the reviewed plan once, verifies the new state, and deletes the plan' -Skip:(-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        $output = Join-Path $TestDrive 'apply-delivery\output'
        $folder = Join-Path $output 'bootstrap\v7.3.0\alz\github'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        @{ bootstrapVersion = 'v7.3.0'; starterVersion = 'v17.5.1' } | ConvertTo-Json | Set-Content (Join-Path $output '.alz-version-data.json')
        Set-Content (Join-Path $folder 'main.tf') 'resource "terraform_data" "x" { input = "apply" }'
        & terraform "-chdir=$folder" init -input=false -no-color *> $null
        & terraform "-chdir=$folder" plan -out=tfplan -input=false -no-color *> $null
        $planResult = [pscustomobject]@{ PlanPath = (Join-Path $folder 'tfplan'); BootstrapFolder = $folder; OutputPath = $output; StateBefore = [pscustomobject]@{ Exists = $false } }
        $env:TF_CLI_ARGS_apply = '-alz-autopilot-plan-only-guard'
        try { $result = Invoke-ALZOwnConfigApply -PlanResult $planResult -Inputs (New-TestInputs) -ExpectedChanges 1 -DataPath $script:dataPath 6>$null }
        finally { $guardAfter = $env:TF_CLI_ARGS_apply; $env:TF_CLI_ARGS_apply = $null }
        $result.Succeeded | Should -BeTrue
        $result.StateAfter.Exists | Should -BeTrue
        $result.StateAfter.ResourceCount | Should -Be 1
        Test-Path (Join-Path $folder 'tfplan') | Should -BeFalse
        Test-Path $result.LogPath | Should -BeTrue
        $guardAfter | Should -Be '-alz-autopilot-plan-only-guard'
        Remove-Item $result.LogPath -ErrorAction SilentlyContinue
    }

    It 'reports a partial apply when state advanced but Terraform returned an error' -Skip:(-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        $output = Join-Path $TestDrive 'partial-delivery\output'
        $folder = Join-Path $output 'bootstrap\v7.3.0\alz\github'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        @{ bootstrapVersion = 'v7.3.0'; starterVersion = 'v17.5.1' } | ConvertTo-Json | Set-Content (Join-Path $output '.alz-version-data.json')
        Set-Content (Join-Path $folder 'main.tf') @'
resource "terraform_data" "ok" { input = "ok" }
resource "terraform_data" "bad" {
  depends_on = [terraform_data.ok]
  provisioner "local-exec" { command = "exit 1" }
}
'@
        & terraform "-chdir=$folder" init -input=false -no-color *> $null
        & terraform "-chdir=$folder" plan -out=tfplan -input=false -no-color *> $null
        $planResult = [pscustomobject]@{ PlanPath = (Join-Path $folder 'tfplan'); BootstrapFolder = $folder; OutputPath = $output; StateBefore = [pscustomobject]@{ Exists = $false } }
        $result = Invoke-ALZOwnConfigApply -PlanResult $planResult -Inputs (New-TestInputs) -ExpectedChanges 2 -DataPath $script:dataPath 6>$null
        $result.Succeeded | Should -BeFalse
        $result.Partial | Should -BeTrue
        $result.ExitCode | Should -Not -Be 0
        $result.StateAfter.Exists | Should -BeTrue
        Test-Path $result.LogPath | Should -BeTrue
        Test-Path (Join-Path $folder 'tfplan') | Should -BeFalse
        Remove-Item $result.LogPath -ErrorAction SilentlyContinue
    }
}