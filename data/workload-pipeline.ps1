param(
    [ValidateSet('Plan', 'Apply')][string]$Stage,
    [string]$Configuration
)

function Invoke-WorkloadCommand {
    param([string]$Command, [string[]]$Arguments, [switch]$Json)
    $operation = if ($Command -eq 'terraform') {
        @($Arguments | Where-Object { $_ -in @('init', 'validate', 'plan', 'show', 'apply') }) | Select-Object -First 1
    } else { 'read' }
    Write-Host "${Stage}: $Command $operation"
    $captured = @(& $Command @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $diagnostics = [ordered]@{
            'checksums|checksum mismatch|Required plugins are not installed' = 'Provider package verification failed.'
            'Inconsistent dependency lock file|Provider dependency changes detected' = 'The provider lock file does not match the configuration or runner platform.'
            'Failed to install provider|Failed to query available provider|Could not retrieve the list of available versions' = 'Provider download or version resolution failed.'
            'Backend initialization required|Backend configuration changed' = 'Terraform backend initialization is required or differs from the configured backend.'
            'AuthorizationFailed|AuthorizationPermissionMismatch|AuthorizationFailure|403 Forbidden' = 'Authorization or private-backend access was denied.'
            'Error acquiring the state lock' = 'The Terraform state lock could not be acquired.'
            'Invalid character|Invalid expression|Invalid function argument|Unsupported argument|Invalid value for' = 'Terraform rejected a configuration argument or expression.'
        }
        $category = 'Unclassified command failure.'
        $outputText = $captured -join "`n"
        foreach ($diagnostic in $diagnostics.GetEnumerator()) {
            if ($outputText -match $diagnostic.Key) { $category = $diagnostic.Value; break }
        }
        throw "$Command $operation failed during $Stage (exit $exitCode). $category Raw output is withheld because plans and state can contain secrets."
    }
    if ($Json) {
        try { return ,(($captured -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate -ErrorAction Stop) }
        catch { throw "$Command returned invalid JSON. No environment or state assumption can be made." }
    }
}

function Test-WorkloadPlan {
    param([System.Collections.IDictionary]$Plan, [string[]]$AllowedSubscriptions, [string[]]$AllowedResourceGroups = @(), [string[]]$ApprovedTemplateHashes = @(), [string]$TemplateRoot)
    if ($Plan.errored -or $Plan.complete -eq $false) { throw 'An errored or incomplete Terraform plan cannot be applied.' }
    if ($Plan.configuration.provider_config) {
        foreach ($provider in $Plan.configuration.provider_config.Values) {
            if ($provider.full_name -notmatch '/(azurerm|azapi)$') { continue }
            $expression = $provider.expressions.subscription_id
            if (-not $expression) { continue }
            $subscription = $expression.constant_value
            if (-not $subscription) {
                $references = @($expression.references | Where-Object { $_ -match '^var\.[a-zA-Z0-9_]+$' } | Select-Object -Unique)
                if ($references.Count -eq 1) { $subscription = $Plan.variables[$references[0].Substring(4)].value }
            }
            if (-not $subscription -or $subscription -notin $AllowedSubscriptions) { throw 'An Azure provider targets an unapproved or unresolved subscription.' }
        }
    }
    $changes = @($Plan.resource_changes | Where-Object { $_.mode -eq 'managed' -and ($_.change.actions -join ',') -ne 'no-op' })
    foreach ($change in $changes) {
        if ($change.change.actions -contains 'delete' -or $change.change.importing) { throw "Deletion, replacement, or import requires a separate reviewed migration: $($change.address)" }
        foreach ($resourceId in @($change.change.before.id, $change.change.after.id, $change.change.after.parent_id, $change.change.after.scope, $change.change.after.subscription_id)) {
            if ($resourceId -match '^/subscriptions/([^/]+)/' -and $Matches[1] -notin $AllowedSubscriptions) { throw "A resource is outside the approved subscriptions: $($change.address)" }
            if ($resourceId -match '^/providers/Microsoft.Management/managementGroups/') { throw "Management-group changes are outside this workload: $($change.address)" }
        }
        if ($change.type -match 'management_group|subscription_policy|management_group_policy' -or ($change.type -eq 'azapi_resource' -and $change.change.after.type -like 'Microsoft.Management/*')) { throw "Platform governance changes are outside this workload: $($change.address)" }
        $groupName = if ($change.type -eq 'azurerm_resource_group') { $change.change.after.name } else { $change.change.after.resource_group_name }
        if ($AllowedResourceGroups.Count -gt 0 -and $groupName -and $groupName -notin $AllowedResourceGroups) { throw "A resource targets an unapproved resource group: $($change.address)" }
        if ($change.type -eq 'azurerm_resource_group_template_deployment') {
            $templateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($change.change.after.template_content)"))).ToLowerInvariant()
            $verifiedTemplate = $templateHash -in $ApprovedTemplateHashes
            if (-not $verifiedTemplate -and $TemplateRoot -and $ApprovedTemplateHashes.Count -gt 0) {
                $plannedTemplate = [Text.Json.Nodes.JsonNode]::Parse([string]$change.change.after.template_content)
                foreach ($file in Get-ChildItem -LiteralPath $TemplateRoot -Filter '*.json' -Recurse -File) {
                    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -notin $ApprovedTemplateHashes) { continue }
                    $approvedTemplate = [Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($file.FullName))
                    if ([Text.Json.Nodes.JsonNode]::DeepEquals($plannedTemplate, $approvedTemplate)) { $verifiedTemplate = $true; break }
                }
            }
            if (-not $verifiedTemplate -or ($change.change.actions -join ',') -ne 'create') { throw 'A nested ARM deployment requires a pinned template and a separate review for updates.' }
        }
    }
    return @($changes | ForEach-Object { [pscustomobject]@{ Address = $_.address; Actions = $_.change.actions -join ',' } })
}

function Assert-WorkloadNewScope {
    param([System.Collections.IDictionary]$Config)
    if (@($Config.managedResourceGroups).Count -lt 1) { throw 'Explicit resource-group scopes are required for a new workload.' }
    foreach ($scope in $Config.managedResourceGroups) {
        $exists = Invoke-WorkloadCommand -Command az -Arguments @('group', 'exists', '--subscription', $scope.subscriptionId, '--name', $scope.name, '--output', 'json', '--only-show-errors') -Json
        if ($exists -isnot [bool] -or $exists) { throw 'The new workload scope already exists or cannot be inspected. Review ownership/imports before proceeding.' }
    }
}

function Read-WorkloadState {
    param([System.Collections.IDictionary]$Config)
    $backend = $Config.backend
    $storageArgs = @('--account-name', $backend.storageAccount, '--container-name', $backend.container, '--name', $backend.key, '--auth-mode', 'login', '--subscription', $backend.subscriptionId, '--only-show-errors', '--output', 'json')
    $existence = Invoke-WorkloadCommand -Command az -Arguments (@('storage', 'blob', 'exists') + $storageArgs) -Json
    if ($existence.exists -isnot [bool]) { throw 'State existence is unknown.' }
    if (-not $existence.exists) {
        if ($Config.operation -ne 'new') { throw 'An existing workload requires its original state. Missing state is not greenfield.' }
        Assert-WorkloadNewScope -Config $Config
        return @{ exists = $false; lineage = ''; serial = 0 }
    }
    $tempState = Join-Path $env:RUNNER_TEMP ("state-$([guid]::NewGuid().ToString('N')).json")
    try {
        $null = Invoke-WorkloadCommand -Command az -Arguments (@('storage', 'blob', 'download', '--file', $tempState, '--overwrite', 'true', '--no-progress') + $storageArgs) -Json
        try { $state = Get-Content -LiteralPath $tempState -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop }
        catch { throw 'Terraform state could not be decoded. State content is omitted.' }
        $stateLineage = [guid]::Empty
        if ($state.version -ne 4 -or -not [guid]::TryParse([string]$state.lineage, [ref]$stateLineage) -or -not $state.Contains('resources') -or -not $state.Contains('outputs') -or $state.serial -isnot [long] -and $state.serial -isnot [int]) { throw 'Unsupported or incomplete Terraform state.' }
        if ($Config.expectedLineage -and $state.lineage -cne $Config.expectedLineage) { throw 'Terraform state lineage does not match the attached deployment.' }
        Write-Host "State metadata: serial $($state.serial), resource entries $(@($state.resources).Count), outputs $($state.outputs.Count)."
        if ($Config.operation -eq 'new' -and $state.serial -in @(0, 1) -and @($state.resources).Count -eq 0 -and $state.outputs.Count -eq 0) {
            Assert-WorkloadNewScope -Config $Config
            return @{ exists = $true; lineage = $state.lineage; serial = $state.serial }
        }
        $binding = @($state.resources | Where-Object { $_.type -eq 'terraform_data' -and $_.name -eq 'autopilot_binding' })
        if ($binding.Count -gt 0) {
            $storedBinding = $binding[0].instances[0].attributes.input.value.bindingId
            if ($storedBinding -cne $Config.bindingId) { throw 'The backend contains a different workload binding.' }
        }
        elseif ($Config.operation -eq 'new' -or -not $Config.expectedLineage) { throw 'Existing state is not owned by this workload. An explicit lineage-bound update is required.' }
        return @{ exists = $true; lineage = $state.lineage; serial = $state.serial }
    }
    finally { if (Test-Path -LiteralPath $tempState) { Remove-Item -LiteralPath $tempState -Force } }
}

function Invoke-WorkloadPipeline {
    param([ValidateSet('Plan', 'Apply')][string]$Stage, [string]$Configuration)
    $ErrorActionPreference = 'Stop'
    if ($Configuration -notmatch '^\.github/autopilot/[a-z0-9-]+\.json$') { throw 'Invalid workload configuration path.' }
    $config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable -Depth 30
    if ($config.schemaVersion -ne 1 -or $config.repository -cne $env:GITHUB_REPOSITORY) { throw 'The workload manifest is not bound to this repository.' }
    $eventPayload = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    if ($eventPayload.repository.private -ne $true) { throw 'This workflow stores sensitive plan artifacts and requires a private repository.' }
    if ($config.targetSubscriptionId -ne $env:ARM_SUBSCRIPTION_ID -or $config.backend.tenantId -ne $env:ARM_TENANT_ID) { throw 'Workflow identity and workload subscription/tenant do not match.' }
    if ($config.backend.workspace -ne 'default' -or $config.root -match '(^|/)\.\.(/|$)|[\\:]') { throw 'Unsafe Terraform root or workspace.' }
    $workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath((Join-Path $workspace $config.root))
    if ($root -ne $workspace -and -not $root.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { throw 'Terraform root escapes the checkout.' }
    $env:TF_IN_AUTOMATION = 'true'
    $env:TF_INPUT = 'false'
    $env:TF_WORKSPACE = 'default'
    $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'
    $env:TF_DATA_DIR = Join-Path $env:RUNNER_TEMP ("tfdata-$Stage-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT")
    $artifact = Join-Path $workspace '.autopilot-plan'
    $backendFile = Join-Path $env:RUNNER_TEMP ("backend-$Stage-$env:GITHUB_RUN_ID.json")
    $backend = $config.backend
    @{
        resource_group_name = $backend.resourceGroup
        storage_account_name = $backend.storageAccount
        container_name = $backend.container
        key = $backend.key
        subscription_id = $backend.subscriptionId
        tenant_id = $backend.tenantId
        client_id = $env:ARM_CLIENT_ID
        use_oidc = $true
        use_azuread_auth = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $backendFile -Encoding UTF8
    try {
        $planFile = Join-Path $artifact 'tfplan'
        $receiptFile = Join-Path $artifact 'receipt.json'
        $lockFile = Join-Path $root '.terraform.lock.hcl'
        $artifactLock = Join-Path $artifact 'terraform.lock.hcl'
        $manifestHash = (Get-FileHash -LiteralPath $Configuration -Algorithm SHA256).Hash
        if ($Stage -eq 'Apply') {
            $receipt = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
            if ($receipt.commit -ne $env:GITHUB_SHA -or $receipt.repository -cne $env:GITHUB_REPOSITORY -or $receipt.manifestHash -cne $manifestHash -or $receipt.planHash -cne (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash) { throw 'The saved plan is not bound to this source revision.' }
            if ($receipt.lockHash) {
                if ($receipt.lockHash -cne (Get-FileHash -LiteralPath $artifactLock -Algorithm SHA256).Hash) { throw 'The saved provider lock file changed.' }
                Copy-Item -LiteralPath $artifactLock -Destination $lockFile -Force
            }
        }
        foreach ($subscriptionId in @($config.allowedSubscriptionIds) + @($backend.subscriptionId) | Select-Object -Unique) {
            $account = Invoke-WorkloadCommand -Command az -Arguments @('account', 'show', '--subscription', $subscriptionId, '--output', 'json', '--only-show-errors') -Json
            if ($account.tenantId -ne $backend.tenantId -or $account.id -ne $subscriptionId) { throw 'A selected subscription is in the wrong tenant or inaccessible.' }
        }
        $lockArguments = if (Test-Path -LiteralPath $lockFile) { @('-lockfile=readonly') } else { @() }
        Invoke-WorkloadCommand -Command terraform -Arguments (@("-chdir=$root", 'init', '-backend=false', '-input=false', '-no-color') + $lockArguments)
        Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'validate', '-no-color')
        $snapshot = Read-WorkloadState -Config $config
        Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'init', '-reconfigure', '-input=false', '-no-color', "-backend-config=$backendFile")
        if ($Stage -eq 'Plan') {
            if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force }
            $null = New-Item -ItemType Directory -Path $artifact
            Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'plan', '-input=false', '-no-color', '-lock-timeout=5m', "-out=$planFile")
            $plan = Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'show', '-json', $planFile) -Json
            $changes = @(Test-WorkloadPlan -Plan $plan -AllowedSubscriptions $config.allowedSubscriptionIds -AllowedResourceGroups $config.managedResourceGroups.name -ApprovedTemplateHashes $config.approvedTemplateHashes -TemplateRoot $root)
            $lockHash = ''
            if (Test-Path -LiteralPath $lockFile) {
                Copy-Item -LiteralPath $lockFile -Destination $artifactLock
                $lockHash = (Get-FileHash -LiteralPath $artifactLock -Algorithm SHA256).Hash
            }
            @{
                commit = $env:GITHUB_SHA
                repository = $env:GITHUB_REPOSITORY
                event = $env:GITHUB_EVENT_NAME
                workflowRef = $env:GITHUB_WORKFLOW_REF
                runId = $env:GITHUB_RUN_ID
                runAttempt = $env:GITHUB_RUN_ATTEMPT
                bindingId = $config.bindingId
                manifestHash = $manifestHash
                planHash = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash
                lockHash = $lockHash
                lineage = $snapshot.lineage
                serial = $snapshot.serial
                nestedTemplateHashes = @($config.approvedTemplateHashes)
            } | ConvertTo-Json | Set-Content -LiteralPath $receiptFile -Encoding UTF8
            $changes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifact 'changes.json') -Encoding UTF8
            @("## Terraform workload plan", "Root: $($config.root)", "Target subscription: $($config.targetSubscriptionId)", "State: $($backend.storageAccount)/$($backend.container)/$($backend.key)", "Plan run: $env:GITHUB_RUN_ID, attempt: $env:GITHUB_RUN_ATTEMPT", "Changes: $($changes.Count). No deletions, replacements, imports, or management-group changes allowed.") | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
            foreach ($change in $changes) { "- $($change.Actions): $($change.Address)" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
            if (@($config.approvedTemplateHashes).Count -gt 0) { 'Nested ARM resources are not individually represented by the Terraform plan. Review the pinned template and ARM what-if before entering its hash in the apply confirmation.' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
        }
        else {
            if ($env:GITHUB_EVENT_NAME -ne 'workflow_dispatch' -or $env:AUTOPILOT_CONFIRMATION -ne $config.targetSubscriptionId) { throw 'Apply requires an explicit dispatch and matching subscription confirmation.' }
            $receipt = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
            if ($receipt.event -notin @('push', 'workflow_dispatch') -or $receipt.workflowRef -cne $env:GITHUB_WORKFLOW_REF -or "$($receipt.runId)" -ne $env:AUTOPILOT_PLAN_RUN_ID -or "$($receipt.runAttempt)" -ne $env:AUTOPILOT_PLAN_ATTEMPT) { throw 'Apply requires a reviewed plan from this workflow on its default branch, not a PR plan.' }
            if ($receipt.commit -ne $env:GITHUB_SHA -or $receipt.repository -cne $env:GITHUB_REPOSITORY -or $receipt.bindingId -cne $config.bindingId -or $receipt.manifestHash -cne $manifestHash -or $receipt.planHash -cne (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash) { throw 'The reviewed plan is not bound to this commit, configuration, or state.' }
            if (@($config.approvedTemplateHashes).Count -gt 0 -and $env:AUTOPILOT_TEMPLATE_CONFIRMATION -cne ($config.approvedTemplateHashes -join ',')) { throw 'The nested ARM template requires explicit hash confirmation after review.' }
            $plan = Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'show', '-json', $planFile) -Json
            $null = Test-WorkloadPlan -Plan $plan -AllowedSubscriptions $config.allowedSubscriptionIds -AllowedResourceGroups $config.managedResourceGroups.name -ApprovedTemplateHashes $config.approvedTemplateHashes -TemplateRoot $root
            Invoke-WorkloadCommand -Command terraform -Arguments @("-chdir=$root", 'apply', '-input=false', '-no-color', '-lock-timeout=5m', '-auto-approve', $planFile)
            'Applied the reviewed saved plan.' | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
        }
    }
    finally {
        if (Test-Path -LiteralPath $backendFile) { Remove-Item -LiteralPath $backendFile -Force }
        if (Test-Path -LiteralPath $env:TF_DATA_DIR) { Remove-Item -LiteralPath $env:TF_DATA_DIR -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-WorkloadPipeline -Stage $Stage -Configuration $Configuration }