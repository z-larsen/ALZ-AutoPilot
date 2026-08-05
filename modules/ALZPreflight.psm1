###########################################################################
# ALZPREFLIGHT.PSM1
# PREREQUISITE VALIDATION FOR THE ALZ DELIVERY ORCHESTRATOR
###########################################################################
# Purpose: Validate every prerequisite up front and fail fast with the exact
#          fix, instead of a Terraform stack trace mid-apply.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# Each check returns a structured result (Name/Status/Detail/Remediation/DocUrl):
# 1. Tooling - pwsh 7.4+, Azure CLI 2.55+, Git.
# 2. Azure login and subscription context.
# 3. Owner on each platform subscription.
# 4. Resource provider registration (with an opt-in bulk register).
# 5. GitHub PAT validity and organization access (live API).
# 6. HCP workspace existence and Local execution mode (live API).
#
# Prerequisites:
# - PowerShell 7.4+, Azure CLI signed in (az login).
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

function New-ALZCheckResult {
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Remediation, [string]$DocUrl)
    [pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
        DocUrl      = $DocUrl
    }
}

function Get-ALZSemver {
    param([string]$Text)
    if ($Text -match '(\d+)\.(\d+)\.(\d+)') {
        return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
    }
    return $null
}

function Test-ALZTooling {
    $results = @()

    $psVer = $PSVersionTable.PSVersion
    if ($psVer -ge [version]'7.4.0') {
        $results += New-ALZCheckResult 'PowerShell 7.4+' 'OK' "Found $psVer"
    }
    else {
        $results += New-ALZCheckResult 'PowerShell 7.4+' 'FAIL' "Found $psVer" 'Install PowerShell 7.4 or newer and run from a pwsh terminal.' 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell'
    }

    $az = Get-Command az -ErrorAction SilentlyContinue
    if ($az) {
        try {
            $azJson = az version --output json 2>$null | ConvertFrom-Json
            $azVer = Get-ALZSemver ($azJson.'azure-cli')
            if ($azVer -and $azVer -ge [version]'2.55.0') {
                $results += New-ALZCheckResult 'Azure CLI 2.55+' 'OK' "Found $azVer"
            }
            else {
                $results += New-ALZCheckResult 'Azure CLI 2.55+' 'FAIL' "Found $azVer" 'Upgrade Azure CLI to 2.55.0 or newer (az upgrade).' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
            }
        }
        catch {
            $results += New-ALZCheckResult 'Azure CLI 2.55+' 'WARN' 'Installed, version could not be parsed'
        }
    }
    else {
        $results += New-ALZCheckResult 'Azure CLI 2.55+' 'FAIL' 'az not found on PATH' 'Install Azure CLI and reopen the terminal.' 'https://learn.microsoft.com/cli/azure/install-azure-cli'
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $results += New-ALZCheckResult 'Git' 'OK' ((git --version) -replace 'git version ', '')
    }
    else {
        $results += New-ALZCheckResult 'Git' 'FAIL' 'git not found on PATH' 'Install Git and reopen the terminal.' 'https://git-scm.com/downloads'
    }

    return $results
}

function Test-ALZAzureLogin {
    param([string]$ExpectedManagementSub)
    try {
        $acct = az account show --output json 2>$null | ConvertFrom-Json
        if (-not $acct) { throw 'not logged in' }
        if ($ExpectedManagementSub -and $acct.id -ne $ExpectedManagementSub) {
            return New-ALZCheckResult 'Azure login' 'WARN' "Signed in as $($acct.user.name) on '$($acct.name)'" "Active subscription is not the Management sub. Run: az account set --subscription $ExpectedManagementSub"
        }
        return New-ALZCheckResult 'Azure login' 'OK' "Signed in as $($acct.user.name) on '$($acct.name)'"
    }
    catch {
        return New-ALZCheckResult 'Azure login' 'FAIL' 'No active Azure CLI session' 'Run az login, then az account set --subscription <management-id>.' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/'
    }
}

function Test-ALZSubscriptionAccess {
    param([hashtable]$Subscriptions)
    $results = @()
    $signedInId = az ad signed-in-user show --query id -o tsv 2>$null
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $subId = $Subscriptions[$role]
        if (-not $subId) {
            if ($role -in @('management', 'connectivity')) {
                $results += New-ALZCheckResult "Subscription: $role" 'FAIL' 'Not set' "The $role subscription is required. Set its ID in the interview."
            }
            continue
        }
        $found = az account list --query "[?id=='$subId'] | [0].name" -o tsv 2>$null
        if (-not $found) {
            $results += New-ALZCheckResult "Subscription: $role" 'FAIL' "$subId not visible to this account" 'Confirm the subscription ID and that this account has access to it.'
            continue
        }
        $owner = $null
        if ($signedInId) {
            $owner = az role assignment list --assignee $signedInId --scope "/subscriptions/$subId" --include-inherited --query "[?roleDefinitionName=='Owner'] | [0].roleDefinitionName" -o tsv 2>$null
        }
        if ($owner) {
            $results += New-ALZCheckResult "Subscription: $role" 'OK' "$found - Owner confirmed"
        }
        else {
            $results += New-ALZCheckResult "Subscription: $role" 'WARN' "$found - Owner not confirmed for this user" 'Owner may be granted via a group (not detectable here). If not, assign Owner on this subscription before bootstrap.' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/'
        }
    }
    return $results
}

function Get-ALZProviderList {
    param([string]$DataPath)
    $providers = Get-Content -Path (Join-Path $DataPath 'providers.json') -Raw | ConvertFrom-Json
    return $providers.required
}

function Test-ALZResourceProviders {
    param([string[]]$Providers)
    $notReg = @()
    foreach ($p in $Providers) {
        $state = az provider show --namespace $p --query registrationState -o tsv 2>$null
        if ($state -ne 'Registered') { $notReg += "$p ($state)" }
    }
    if ($notReg.Count -eq 0) {
        return New-ALZCheckResult 'Resource providers (current sub)' 'OK' "All $($Providers.Count) ALZ providers registered"
    }
    return New-ALZCheckResult 'Resource providers (current sub)' 'WARN' "$($notReg.Count) not registered: $($notReg -join ', ')" 'Run the bulk register step to pre-register the ALZ-recommended list on all subscriptions.' 'https://azure.github.io/Azure-Landing-Zones/faq/resource-providers/'
}

function Register-ALZResourceProviders {
    param([hashtable]$Subscriptions, [string[]]$Providers)
    $originalSub = az account show --query id -o tsv 2>$null
    try {
        foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
            $subId = $Subscriptions[$role]
            if (-not $subId) { continue }
            Write-Host "  Registering providers on $role ($subId)..." -ForegroundColor Cyan
            az account set --subscription $subId 2>$null
            foreach ($p in $Providers) {
                Write-Host "    $p" -ForegroundColor DarkGray
                # Fire-and-forget (no --wait): registration completes in the background.
                # Terraform is told to skip registration at bootstrap, so we never block here.
                az provider register --namespace $p 2>$null | Out-Null
            }
        }
    }
    finally {
        # Always put the caller back on the subscription they started on.
        if ($originalSub) { az account set --subscription $originalSub 2>$null }
    }
}

function Test-ALZGitHubToken {
    param([string]$Token, [string]$Org, [bool]$SelfHostedRunners)
    if (-not $Token) {
        return New-ALZCheckResult 'GitHub PAT' 'WARN' 'No token provided this session' 'The PAT is only needed for bootstrap. You will be prompted (masked) before the bootstrap runs.'
    }
    $headers = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'ALZ-Orchestrator'; Accept = 'application/vnd.github+json' }
    try {
        $user = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get -ErrorAction Stop
        $results = @(New-ALZCheckResult 'GitHub PAT' 'OK' "Authenticated as $($user.login)")
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        return New-ALZCheckResult 'GitHub PAT' 'FAIL' "Token rejected (HTTP $code)" 'Regenerate a fine-grained PAT with Resource owner = your org, All repositories, Read/write on the required repository permissions, and Organization > Members: Read and write.' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
    }
    try {
        $orgInfo = Invoke-RestMethod -Uri "https://api.github.com/orgs/$Org" -Headers $headers -Method Get -ErrorAction Stop
        $planName = if ($orgInfo.plan) { $orgInfo.plan.name } else { 'unknown' }
        if ($planName -eq 'free') {
            $results += New-ALZCheckResult "GitHub org: $Org" 'WARN' "Reachable (free plan)" 'A free org makes the accelerator repos public. Fine for a rehearsal; use a paid/EMU org for anything real.' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
            # A free org forces public repos, and self-hosted runners then execute inside the
            # VNet that reaches the state storage. GitHub advises against that pairing because
            # a fork pull request can run code on the runner.
            if ($SelfHostedRunners) {
                $results += New-ALZCheckResult 'Public repos + self-hosted runners' 'WARN' 'A free org makes the repos public, and self-hosted runners run inside your VNet' 'GitHub recommends self-hosted runners only on private repositories, because a fork pull request can run code on the runner, which here has private-endpoint access to the Terraform state. Mitigate by setting Settings > Actions > "Require approval for all external contributors", or remove the exposure with a paid org and private repos, or by not using self-hosted runners.' 'https://docs.github.com/en/actions/reference/security/secure-use'
            }
        }
        else {
            $results += New-ALZCheckResult "GitHub org: $Org" 'OK' "Reachable (plan: $planName)"
        }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        $rem = if ($code -eq 403) { 'The org likely enforces SAML SSO. Authorize the token for the org on github.com/settings/tokens, or use a dedicated free org for rehearsals.' } else { "Confirm the org name is correct and the token's Resource owner is this org." }
        $results += New-ALZCheckResult "GitHub org: $Org" 'FAIL' "Org not accessible (HTTP $code)" $rem 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
    }
    # The accelerator reads org members and manages the approver team, which needs Organization > Members.
    try {
        Invoke-RestMethod -Uri "https://api.github.com/orgs/$Org/members?per_page=1" -Headers $headers -Method Get -ErrorAction Stop | Out-Null
        $results += New-ALZCheckResult 'GitHub org Members permission' 'OK' 'Token can read organization members'
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        $results += New-ALZCheckResult 'GitHub org Members permission' 'FAIL' "Cannot read org members (HTTP $code)" 'Add Organization permissions > Members: Read and write to the fine-grained PAT. The accelerator fails at apply without it (data github_organization).' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
    }
    return $results
}

function Test-ALZAdoToken {
    param([string]$Token, [string]$Org, [string]$Project, [bool]$CreateProject)
    $doc = 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/'
    if (-not $Token) {
        return New-ALZCheckResult 'Azure DevOps PAT' 'WARN' 'No token provided this session' 'The PAT is only needed for bootstrap. You will be prompted (masked) before the bootstrap runs.' $doc
    }
    # This check is advisory: it never returns FAIL. The Azure DevOps path has not been
    # exercised end to end, so a quirk here must not block a run the bootstrap would accept.
    $headers = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token")))" }
    $orgUri = "https://dev.azure.com/$([uri]::EscapeDataString($Org))/_apis/projects?api-version=7.1&`$top=200"
    try {
        $projects = Invoke-RestMethod -Uri $orgUri -Headers $headers -Method Get -ErrorAction Stop
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        $rem = if ($code -eq 401 -or $code -eq 203) {
            'The PAT was rejected. Create one scoped to this organization with Full access (or at minimum Code, Project and Team, Build, Release, Service Connections, Variable Groups, Agent Pools, Environment: Read & manage).'
        }
        else { "Confirm the organization name is '$Org' and that the PAT is scoped to it." }
        return New-ALZCheckResult "Azure DevOps org: $Org" 'WARN' "Could not verify (HTTP $code)" "$rem The bootstrap validates this too, so this is advisory only." $doc
    }
    $results = @(New-ALZCheckResult "Azure DevOps org: $Org" 'OK' "Reachable, $($projects.count) project(s) visible")
    $found = @($projects.value | Where-Object { $_.name -eq $Project }).Count -gt 0
    if ($found -and $CreateProject) {
        $results += New-ALZCheckResult "Azure DevOps project: $Project" 'WARN' 'Project already exists but you chose to create it' "Re-run the interview and answer No to creating the project, or pick a different project name." $doc
    }
    elseif ($found) {
        $results += New-ALZCheckResult "Azure DevOps project: $Project" 'OK' 'Exists and is visible to this token'
    }
    elseif ($CreateProject) {
        $results += New-ALZCheckResult "Azure DevOps project: $Project" 'OK' 'Does not exist yet, the bootstrap will create it'
    }
    else {
        $results += New-ALZCheckResult "Azure DevOps project: $Project" 'WARN' 'Not found, and you chose not to create it' "Either create the project first, or re-run the interview and answer Yes to creating it." $doc
    }
    return $results
}

# The management group names the accelerator creates. A collision means the target
# tenant already has a hierarchy, which the accelerator does not adopt by default.
$script:ALZManagementGroupNames = @('alz', 'platform', 'connectivity', 'identity', 'management', 'security', 'landingzones', 'corp', 'online', 'local', 'sandbox', 'decommissioned')

# Resource groups Azure creates on its own. Their presence says nothing about whether
# a subscription is in use, so they must not trigger a brownfield warning.
$script:ALZIgnorableResourceGroups = @('NetworkWatcherRG', 'Default-ActivityLogAlerts', 'LogAnalyticsDefaultResources', 'DefaultResourceGroup-*', 'cloud-shell-storage-*', 'microsoft-network', 'AzureBackupRG_*', 'databricks-rg-*')

function Test-ALZExistingEstate {
    param([hashtable]$Subscriptions, [string]$ParentManagementGroupId)
    $doc = 'https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/align-approach-duplicate-brownfield-audit-only'
    $root = $ParentManagementGroupId
    if ([string]::IsNullOrWhiteSpace($root)) {
        try { $root = (az account show -o json 2>$null | ConvertFrom-Json).tenantId } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        return @(New-ALZCheckResult 'Existing estate' 'WARN' 'Could not resolve the root management group' 'Sign in with az login and re-run, or the brownfield checks are skipped.' $doc)
    }

    # One descendants call returns every management group and placed subscription
    # beneath the root, each with its parent.
    try {
        $url = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$([uri]::EscapeDataString($root))/descendants?api-version=2021-04-01"
        $resp = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
        $entities = @($resp.value)
    }
    catch {
        return @(New-ALZCheckResult 'Existing estate' 'WARN' 'Could not read the management group hierarchy' 'Advisory check only. Confirm manually whether the tenant already has an ALZ hierarchy.' $doc)
    }

    $results = @()
    $existingMgs = @($entities | Where-Object { $_.type -eq 'Microsoft.Management/managementGroups' } | ForEach-Object { $_.name })
    $collisions = @($existingMgs | Where-Object { $_ -in $script:ALZManagementGroupNames })

    if ($collisions.Count -eq 0) {
        $results += New-ALZCheckResult 'Existing management groups' 'OK' "None of the ALZ management group names exist yet ($($existingMgs.Count) other group(s) present)"
    }
    elseif ($collisions.Count -ge 10) {
        $results += New-ALZCheckResult 'Existing management groups' 'OK' "An ALZ hierarchy is already present ($($collisions.Count) of the expected groups)" 'This looks like a re-run against an existing deployment rather than a new tenant.'
    }
    else {
        $results += New-ALZCheckResult 'Existing management groups' 'WARN' "$($collisions.Count) ALZ management group name(s) already exist: $($collisions -join ', ')" "The accelerator does not adopt existing management groups by default (update_existing defaults to false, and this app does not expose it). Either remove them, deploy under a different parent management group, or plan the transition deliberately." $doc
    }

    # A subscription already sitting under a management group is being moved, not placed.
    # That changes which policies apply to whatever is running in it.
    $placed = @($entities | Where-Object { $_.type -eq 'Microsoft.Management/managementGroups/subscriptions' })
    $moving = @()
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = $Subscriptions.$role
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $entry = $placed | Where-Object { $_.name -eq $id } | Select-Object -First 1
        if (-not $entry) { continue }
        $parent = ($entry.properties.parent.id -replace '.*/', '')
        if ($parent -and $parent -ne $root -and $parent -notin $script:ALZManagementGroupNames) {
            $moving += "$role -> currently under '$parent'"
        }
    }
    if ($moving.Count -gt 0) {
        $results += New-ALZCheckResult 'Subscription placement' 'WARN' "$($moving.Count) platform subscription(s) already sit under another management group" "Subscription placement will move them: $($moving -join '; '). They will pick up the ALZ policy assignments and lose any that applied only at their current parent." $doc
    }
    else {
        $results += New-ALZCheckResult 'Subscription placement' 'OK' 'No platform subscription sits under an unrelated management group'
    }
    return $results
}

function Test-ALZSubscriptionContent {
    param([hashtable]$Subscriptions)
    $doc = 'https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/align-approach-duplicate-brownfield-audit-only'
    $populated = @()
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = $Subscriptions.$role
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        try {
            $groups = @(az group list --subscription $id -o json 2>$null | ConvertFrom-Json)
        }
        catch { continue }
        $real = @($groups | Where-Object {
                $name = $_.name
                -not ($script:ALZIgnorableResourceGroups | Where-Object { $name -like $_ })
            })
        if ($real.Count -gt 0) {
            $sample = ($real | Select-Object -First 4 | ForEach-Object { $_.name }) -join ', '
            if ($real.Count -gt 4) { $sample += ", +$($real.Count - 4) more" }
            $populated += "$role ($($real.Count)): $sample"
        }
    }
    if ($populated.Count -eq 0) {
        return @(New-ALZCheckResult 'Subscription contents' 'OK' 'Platform subscriptions are empty (greenfield)')
    }
    return @(New-ALZCheckResult 'Subscription contents' 'WARN' "$($populated.Count) platform subscription(s) already contain resources" "$($populated -join ' | '). On the first apply the ALZ policy baseline applies to whatever is running: DeployIfNotExists assignments start remediating existing resources and any Deny starts blocking deployments. After a previous ALZ run its own resource groups appear here too, which is expected. For a tenant in real use, follow Microsoft's audit-only transition guidance before deploying." $doc)
}

function Test-ALZHcpWorkspace {
    param([string]$Token, [string]$HcpOrg, [string]$Workspace)
    if (-not $Token) {
        return New-ALZCheckResult 'HCP workspace' 'WARN' 'No HCP token provided this session' 'The HCP token is needed for the state-migration step. You will be prompted (masked) before that phase.'
    }
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/vnd.api+json' }
    try {
        $uri = "https://app.terraform.io/api/v2/organizations/$([uri]::EscapeDataString($HcpOrg))/workspaces/$([uri]::EscapeDataString($Workspace))"
        $ws = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        $mode = $ws.data.attributes.'execution-mode'
        if ($mode -eq 'local') {
            return New-ALZCheckResult 'HCP workspace' 'OK' "$HcpOrg/$Workspace - execution mode Local"
        }
        return New-ALZCheckResult 'HCP workspace' 'FAIL' "$HcpOrg/$Workspace - execution mode is '$mode'" 'Set Execution Mode = Local (Workspace > Settings > General). Remote mode breaks the plan/apply handoff.' 'https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings#execution-mode'
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        $rem = if ($code -eq 404) { "Workspace '$Workspace' not found in org '$HcpOrg'. Create it (Local execution mode) or fix the names." } else { 'Check the HCP API token and org/workspace names.' }
        return New-ALZCheckResult 'HCP workspace' 'FAIL' "Lookup failed (HTTP $code)" $rem 'https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings#execution-mode'
    }
}

Export-ModuleMember -Function New-ALZCheckResult, Test-ALZTooling, Test-ALZAzureLogin, Test-ALZSubscriptionAccess, Get-ALZProviderList, Test-ALZResourceProviders, Register-ALZResourceProviders, Test-ALZGitHubToken, Test-ALZAdoToken, Test-ALZExistingEstate, Test-ALZSubscriptionContent, Test-ALZHcpWorkspace
