[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Configuration,
    [Parameter(Mandatory)][string]$PlanIdentityResourceId,
    [Parameter(Mandatory)][string]$ApplyIdentityResourceId,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Invoke-AccessRead {
    param([string]$Command, [string[]]$Arguments)
    $result = @(& $Command @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$Command access discovery failed. Resolve authentication or permissions before changing access." }
    return ,(($result -join "`n") | ConvertFrom-Json -AsHashtable -Depth 30 -NoEnumerate)
}

$config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json -AsHashtable -Depth 30
if ($config.schemaVersion -ne 1 -or $config.repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') { throw 'Invalid workload manifest.' }
$backend = $config.backend
$pipeline = $config.pipeline
foreach ($subscription in @($config.allowedSubscriptionIds) + @($backend.subscriptionId) | Select-Object -Unique) {
    $account = Invoke-AccessRead az @('account', 'show', '--subscription', $subscription, '--only-show-errors', '--output', 'json')
    if ($account.id -ne $subscription -or $account.tenantId -ne $backend.tenantId) { throw 'Subscription and tenant do not match the reviewed manifest.' }
}
$identities = @{}
foreach ($entry in @(@{ mode = 'plan'; id = $PlanIdentityResourceId }, @{ mode = 'apply'; id = $ApplyIdentityResourceId })) {
    if ($entry.id -notmatch '^/subscriptions/([a-fA-F0-9-]{36})/resourceGroups/([^/]+)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/([^/]+)$') { throw 'Use the existing user-assigned identity resource IDs from bootstrap.' }
    $identity = Invoke-AccessRead az @('identity', 'show', '--ids', $entry.id, '--only-show-errors', '--output', 'json')
    if ($identity.tenantId -ne $backend.tenantId) { throw 'Deployment identity belongs to a different tenant.' }
    $identities[$entry.mode] = $identity
}
if ($identities.plan.principalId -eq $identities.apply.principalId) { throw 'Plan and apply must use different existing identities.' }

$requirements = @()
foreach ($subscription in $config.allowedSubscriptionIds) {
    $scope = "/subscriptions/$subscription"
    $requirements += @{ principal = $identities.plan.principalId; role = 'Reader'; scope = $scope; subscription = $subscription }
    $requirements += @{ principal = $identities.apply.principalId; role = 'Contributor'; scope = $scope; subscription = $subscription }
    $requirements += @{ principal = $identities.apply.principalId; role = 'Role Based Access Control Administrator'; scope = $scope; subscription = $subscription }
}
$containerScope = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($backend.storageAccount)/blobServices/default/containers/$($backend.container)"
foreach ($identity in $identities.Values) {
    $requirements += @{ principal = $identity.principalId; role = 'Storage Blob Data Contributor'; scope = $containerScope; subscription = $backend.subscriptionId }
}
foreach ($requirement in $requirements) {
    $assignments = Invoke-AccessRead az @('role', 'assignment', 'list', '--scope', $requirement.scope, '--include-inherited', '--subscription', $requirement.subscription, '--only-show-errors', '--output', 'json')
    $present = @($assignments | Where-Object { $_.principalId -eq $requirement.principal -and $_.roleDefinitionName -eq $requirement.role }).Count -gt 0
    [pscustomobject]@{ Requirement = $requirement.role; Principal = $requirement.principal; Scope = $requirement.scope; Present = $present }
    if (-not $present -and $Apply -and $PSCmdlet.ShouldProcess($requirement.scope, "Grant $($requirement.role) to existing identity $($requirement.principal)")) {
        $null = & az role assignment create --assignee-object-id $requirement.principal --assignee-principal-type ServicePrincipal --role $requirement.role --scope $requirement.scope --subscription $requirement.subscription --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw 'Role assignment failed; do not run the workload apply.' }
    }
}

$oidc = Invoke-AccessRead gh @('api', "repos/$($config.repository)/actions/oidc/customization/sub")
if ($oidc.use_default -or ($oidc.include_claim_keys -join ',') -cne 'repository,environment,job_workflow_ref' -or ($oidc.use_immutable_subject -and -not $oidc.sub_claim_prefix)) { throw 'OIDC subject customization does not match the official ALZ contract. Review it manually; it will not be overwritten.' }
$prefix = if ($oidc.sub_claim_prefix) { $oidc.sub_claim_prefix } else { "repo:$($config.repository)" }
foreach ($mode in @('plan', 'apply')) {
    $identity = $identities[$mode]
    $parts = $identity.id.Split('/')
    $environment = if ($mode -eq 'plan') { $pipeline.planEnvironment } else { $pipeline.applyEnvironment }
    $expectedSubject = "${prefix}:environment:${environment}:job_workflow_ref:$($pipeline.templatesRepository)/.github/workflows/cd-template.yaml@refs/heads/main"
    $credentials = Invoke-AccessRead az @('identity', 'federated-credential', 'list', '--subscription', $parts[2], '--resource-group', $parts[4], '--identity-name', $parts[-1], '--only-show-errors', '--output', 'json')
    $present = @($credentials | Where-Object { $_.subject -ceq $expectedSubject -and $_.issuer -eq 'https://token.actions.githubusercontent.com' -and $_.audiences -contains 'api://AzureADTokenExchange' }).Count -gt 0
    [pscustomobject]@{ Requirement = 'OIDC trust'; Principal = $identity.principalId; Scope = $expectedSubject; Present = $present }
    if (-not $present -and $Apply -and $PSCmdlet.ShouldProcess($identity.id, "Add workload $mode OIDC trust for the existing reusable workflow")) {
        $null = & az identity federated-credential create --subscription $parts[2] --resource-group $parts[4] --identity-name $parts[-1] --name "autopilot-workload-$mode" --issuer 'https://token.actions.githubusercontent.com' --subject $expectedSubject --audiences 'api://AzureADTokenExchange' --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw 'Federated credential creation failed.' }
    }
    $encodedEnvironment = [uri]::EscapeDataString($environment)
    $variables = Invoke-AccessRead gh @('api', "repos/$($config.repository)/environments/$encodedEnvironment/variables")
    $existingClient = @($variables.variables | Where-Object name -EQ 'AZURE_CLIENT_ID')
    [pscustomobject]@{ Requirement = 'Environment client ID'; Principal = $identity.clientId; Scope = "$($config.repository)/$environment"; Present = ($existingClient.Count -gt 0) }
    if ($existingClient.Count -gt 0 -and $existingClient[0].value -ne $identity.clientId) { throw 'The environment already points to a different client ID. It will not be overwritten.' }
    if ($existingClient.Count -eq 0 -and $Apply -and $PSCmdlet.ShouldProcess("$($config.repository)/$environment", 'Set the existing identity client ID as AZURE_CLIENT_ID')) {
        $null = & gh api --method POST "repos/$($config.repository)/environments/$encodedEnvironment/variables" -f 'name=AZURE_CLIENT_ID' -f "value=$($identity.clientId)"
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure the environment client ID.' }
    }
}
if (-not $Apply) { Write-Host 'Read-only access review completed. Use -Apply only after approving these exact permission changes.' }