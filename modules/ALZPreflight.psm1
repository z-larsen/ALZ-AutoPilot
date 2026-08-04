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
    param([string]$Token, [string]$Org)
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

Export-ModuleMember -Function New-ALZCheckResult, Test-ALZTooling, Test-ALZAzureLogin, Test-ALZSubscriptionAccess, Get-ALZProviderList, Test-ALZResourceProviders, Register-ALZResourceProviders, Test-ALZGitHubToken, Test-ALZHcpWorkspace
