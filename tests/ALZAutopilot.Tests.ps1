BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    foreach ($moduleName in @('ALZUI', 'ALZSecurity', 'ALZState', 'ALZConfig', 'ALZPreflight', 'ALZOrchestrator', 'ALZPipeline', 'ALZReport', 'ALZWorkload')) {
        Import-Module (Join-Path $repoRoot "modules/$moduleName.psm1") -Force
    }
}

Describe 'Workload attachment safety' -Tag 'Workload' {
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
            backend = @{ subscriptionId = $subscription; tenantId = $tenant; resourceGroup = 'rg-state'; storageAccount = 'existingstate'; container = 'tfstate' }
            pipeline = @{ templatesRepository = 'contoso/platform-templates'; planEnvironment = 'platform-plan'; applyEnvironment = 'platform-apply' }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath
        $script:accessCalls = @()
        Mock az {
            $global:LASTEXITCODE = 0
            $script:accessCalls += 'az ' + ($args -join ' ')
            if (($args[0..1] -join ' ') -eq 'account show') { return '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222"}' }
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