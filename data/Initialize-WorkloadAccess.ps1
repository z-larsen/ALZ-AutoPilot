[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$Configuration,
    [Parameter(Mandatory)][string]$PlanIdentityResourceId,
    [Parameter(Mandatory)][string]$ApplyIdentityResourceId,
    [switch]$Apply,
    [switch]$AllowSubscriptionScope
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
}
$applyRoles = if ($config.access.applyRoles) { @($config.access.applyRoles) } else {
    @($config.managedResourceGroups | ForEach-Object { @{ role = 'Contributor'; scope = "/subscriptions/$($_.subscriptionId)/resourceGroups/$($_.name)" } })
}
if ($applyRoles.Count -eq 0) { throw 'Explicit managed resource groups or reviewed access.applyRoles entries are required. Subscription deployment rights are never inferred.' }
$allowedRoles = @('Reader', 'Contributor', 'Network Contributor', 'Private DNS Zone Contributor', 'Cost Management Contributor', 'Storage Blob Data Reader', 'Storage Blob Data Contributor', 'Role Based Access Control Administrator')
$scopeProblems = @()
foreach ($entry in $applyRoles) {
    if ($entry.role -notin $allowedRoles -or $entry.scope -notmatch '^/subscriptions/([a-fA-F0-9-]{36})(?:/resourceGroups/([a-zA-Z0-9_.()-]+)(?:/providers/[a-zA-Z0-9_./()-]+)?)?$') { throw 'An apply role or scope is outside the reviewed workload access contract. Owner and management-group grants are not supported.' }
    $subscription = $Matches[1]
    $resourceGroup = $Matches[2]
    if ($subscription -notin $config.allowedSubscriptionIds) { throw 'An apply permission targets an unapproved subscription.' }
    if (-not $resourceGroup) {
        [pscustomobject]@{ Requirement = 'Explicit subscription-wide access approval'; Principal = $identities.apply.principalId; Scope = $entry.scope; Present = [bool]$AllowSubscriptionScope }
        if (-not $AllowSubscriptionScope) { $scopeProblems += 'Subscription-level apply grants require the explicit -AllowSubscriptionScope switch in addition to reviewed access.applyRoles.' }
    }
    else {
        $exists = Invoke-AccessRead az @('group', 'exists', '--name', $resourceGroup, '--subscription', $subscription, '--only-show-errors', '--output', 'json')
        if ($exists -isnot [bool] -or -not $exists) {
            [pscustomobject]@{ Requirement = 'Existing permission scope'; Principal = $identities.apply.principalId; Scope = $entry.scope; Present = $false }
            $scopeProblems += 'A permission resource group is missing or unverified. Pre-provision it through an approved platform process, or separately review exact subscription-level permissions.'
        }
    }
    $requirements += @{ principal = $identities.apply.principalId; role = $entry.role; scope = $entry.scope; subscription = $subscription }
}
$containerScope = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($backend.storageAccount)/blobServices/default/containers/$($backend.container)"
foreach ($identity in $identities.Values) {
    $requirements += @{ principal = $identity.principalId; role = 'Storage Blob Data Contributor'; scope = $containerScope; subscription = $backend.subscriptionId }
}
$pending = @()
foreach ($requirement in $requirements) {
    $assignments = Invoke-AccessRead az @('role', 'assignment', 'list', '--scope', $requirement.scope, '--include-inherited', '--subscription', $requirement.subscription, '--only-show-errors', '--output', 'json')
    $matching = @($assignments | Where-Object { $_.principalId -eq $requirement.principal -and $_.roleDefinitionName -eq $requirement.role })
    $present = @($matching | Where-Object { -not $_.condition }).Count -gt 0
    if (-not $present -and @($matching | Where-Object condition).Count) { $scopeProblems += 'An existing conditional role assignment needs manual review. The helper will not replace it with an unconditional grant.' }
    [pscustomobject]@{ Requirement = $requirement.role; Principal = $requirement.principal; Scope = $requirement.scope; Present = $present }
    if (-not $present) {
        $pending += @{ command = 'az'; arguments = @('role', 'assignment', 'create', '--assignee-object-id', $requirement.principal, '--assignee-principal-type', 'ServicePrincipal', '--role', $requirement.role, '--scope', $requirement.scope, '--subscription', $requirement.subscription, '--only-show-errors', '--output', 'none'); target = $requirement.scope; action = "Grant $($requirement.role) to existing identity $($requirement.principal)" }
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
    if (-not $present) {
        $pending += @{ command = 'az'; arguments = @('identity', 'federated-credential', 'create', '--subscription', $parts[2], '--resource-group', $parts[4], '--identity-name', $parts[-1], '--name', "autopilot-workload-$mode", '--issuer', 'https://token.actions.githubusercontent.com', '--subject', $expectedSubject, '--audiences', 'api://AzureADTokenExchange', '--only-show-errors', '--output', 'none'); target = $identity.id; action = "Add workload $mode OIDC trust for the existing reusable workflow" }
    }
    $encodedEnvironment = [uri]::EscapeDataString($environment)
    $variables = Invoke-AccessRead gh @('api', "repos/$($config.repository)/environments/$encodedEnvironment/variables")
    $existingClient = @($variables.variables | Where-Object name -EQ 'AZURE_CLIENT_ID')
    [pscustomobject]@{ Requirement = 'Environment client ID'; Principal = $identity.clientId; Scope = "$($config.repository)/$environment"; Present = ($existingClient.Count -gt 0) }
    if ($existingClient.Count -gt 0 -and $existingClient[0].value -ne $identity.clientId) { throw 'The environment already points to a different client ID. It will not be overwritten.' }
    if ($existingClient.Count -eq 0) {
        $pending += @{ command = 'gh'; arguments = @('api', '--method', 'POST', "repos/$($config.repository)/environments/$encodedEnvironment/variables", '-f', 'name=AZURE_CLIENT_ID', '-f', "value=$($identity.clientId)"); target = "$($config.repository)/$environment"; action = 'Set the existing identity client ID as AZURE_CLIENT_ID' }
    }
}
foreach ($problem in $scopeProblems | Select-Object -Unique) { Write-Warning $problem }
if ($Apply -and $scopeProblems.Count) { throw 'Access setup is blocked by unapproved, missing or conditional scopes. No access writes were performed.' }
if ($Apply) {
    foreach ($change in $pending) {
        if ($PSCmdlet.ShouldProcess($change.target, $change.action)) {
            $arguments = $change.arguments
            $captured = @(& $change.command @arguments 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'An approved access write failed. Earlier approved writes may have succeeded; rerun read-only discovery before retrying. Command output is withheld.' }
            $captured = $null
        }
    }
}
if (-not $Apply) { Write-Host 'Read-only access review completed. Use -Apply only after approving these exact permission changes.' }