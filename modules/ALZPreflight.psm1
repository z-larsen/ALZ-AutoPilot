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

function Test-ALZConnectivity {
    param(
        [ValidateSet('github', 'azuredevops', 'all')][string]$Vcs = 'github',
        [ValidateSet('terraform', 'bicep')][string]$IacType = 'terraform',
        [ValidateSet('azurerm', 'hcp')][string]$StateBackend = 'azurerm',
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    $doc = 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/'
    $proxyNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') |
        Where-Object { [Environment]::GetEnvironmentVariable($_) } | Select-Object -Unique
    if ($proxyNames) {
        New-ALZCheckResult 'Proxy configuration' 'WARN' "Proxy environment variables are set: $($proxyNames -join ', '). Values are not displayed." 'The accelerator does not explicitly support corporate proxies. Use an approved execution environment or work with your network team. Passing these PowerShell probes does not validate Git, Azure CLI, Terraform, or runner proxy settings.' $doc
    }
    $endpoints = @(
        @{ Name = 'Microsoft Entra sign-in'; Uri = 'https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration'; Method = 'Get'; ContentType = 'json' }
        @{ Name = 'Azure Resource Manager'; Uri = 'https://management.azure.com/tenants?api-version=2022-12-01'; Method = 'Get'; AllowUnauthorized = $true }
        @{ Name = 'Microsoft Graph'; Uri = 'https://graph.microsoft.com/v1.0/organization'; Method = 'Get'; AllowUnauthorized = $true }
        @{ Name = 'PowerShell Gallery feed'; Uri = 'https://www.powershellgallery.com/api/v2/FindPackagesById()?id=%27ALZ%27&$filter=IsLatestVersion'; Method = 'Get'; ContentType = 'xml'; PackageFeed = $true }
        @{ Name = 'GitHub API'; Uri = 'https://api.github.com/repos/Azure/ALZ-PowerShell-Module/releases/latest'; ContentType = 'json' }
        @{ Name = 'GitHub source'; Uri = 'https://raw.githubusercontent.com/Azure/ALZ-PowerShell-Module/main/README.md'; ContentType = 'text/plain' }
        @{ Name = 'GitHub archive download'; Uri = 'https://github.com/Azure/ALZ-PowerShell-Module/archive/refs/heads/main.zip'; ContentType = 'zip' }
        @{ Name = 'Bootstrap sample release download'; Uri = 'https://github.com/Azure/accelerator-bootstrap-modules/releases/download/v7.2.1/bootstrap_modules.zip'; ContentType = 'octet-stream|zip' }
        @{ Name = 'Terraform downloads'; Uri = 'https://releases.hashicorp.com/terraform/index.json'; ContentType = 'json' }
        @{ Name = 'Terraform Registry'; Uri = 'https://registry.terraform.io/.well-known/terraform.json'; ContentType = 'json' }
    )
    if ($Vcs -in @('azuredevops', 'all')) {
        $endpoints += @{ Name = 'Azure DevOps'; Uri = 'https://dev.azure.com/'; AllowNotFound = $true }
    }
    if ($StateBackend -eq 'hcp') {
        $endpoints += @{ Name = 'HCP Terraform'; Uri = 'https://app.terraform.io/.well-known/terraform.json'; ContentType = 'json' }
    }
    if ($IacType -eq 'bicep') {
        $endpoints += @{ Name = 'Bicep release metadata'; Uri = 'https://api.github.com/repos/Azure/bicep/releases/latest'; ContentType = 'json' }
    }

    $pending = [System.Collections.Generic.Queue[hashtable]]::new()
    foreach ($endpoint in $endpoints) { $pending.Enqueue($endpoint) }
    while ($pending.Count -gt 0) {
        $endpoint = $pending.Dequeue()
        $hostName = ([uri]$endpoint.Uri).Host
        $method = if ($endpoint.Method) { $endpoint.Method } else { 'Head' }
        try {
            $response = Invoke-WebRequest -Uri $endpoint.Uri -Method $method -SkipHttpErrorCheck -MaximumRedirection 5 -ConnectionTimeoutSeconds $TimeoutSeconds -OperationTimeoutSeconds $TimeoutSeconds -UserAgent 'ALZ-Autopilot-Preflight' -ErrorAction Stop
            $statusCode = [int]$response.StatusCode
            if ($statusCode -eq 407) {
                New-ALZCheckResult $endpoint.Name 'FAIL' "$hostName - Proxy authentication required (HTTP 407)." 'Have your network team configure approved proxy authentication for this process, or use a supported execution environment. Do not paste proxy credentials into delivery files.' $doc
            }
            elseif ($statusCode -eq 401 -and $endpoint.AllowUnauthorized) {
                New-ALZCheckResult $endpoint.Name 'OK' "$hostName - HTTPS reachable (HTTP 401 is expected without credentials). Access permissions are checked separately."
            }
            elseif ($statusCode -eq 404 -and $endpoint.AllowNotFound) {
                New-ALZCheckResult $endpoint.Name 'OK' "$hostName - HTTPS reachable (HTTP 404 is expected at the service root). Organization access is unverified."
            }
            elseif ($statusCode -ge 200 -and $statusCode -lt 300) {
                $contentType = [string]($response.Headers['Content-Type'] -join ';')
                if ($endpoint.ContentType -and $contentType -and $contentType -notmatch $endpoint.ContentType) {
                    New-ALZCheckResult $endpoint.Name 'FAIL' "$hostName - Unexpected response type; the request may have reached a proxy sign-in or block page." 'Ask your network team to allow the service and its download redirects. A successful HTTP status alone does not confirm download access.' $doc
                }
                else {
                    if ($endpoint.PackageFeed) {
                        $feed = [System.Xml.XmlDocument]::new()
                        $feed.XmlResolver = $null
                        $feed.LoadXml($response.Content)
                        $versionNode = $feed.SelectSingleNode("//*[local-name()='Version']")
                        if (-not $versionNode -or $versionNode.InnerText -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
                            New-ALZCheckResult $endpoint.Name 'FAIL' "$hostName - The feed did not return a valid ALZ package version." 'Check PowerShell Gallery availability and whether the proxy rewrote the metadata response.' $doc
                            continue
                        }
                        $pending.Enqueue(@{ Name = 'ALZ module download'; Uri = "https://cdn.powershellgallery.com/packages/alz.$($versionNode.InnerText).nupkg"; ContentType = 'octet-stream|zip' })
                    }
                    New-ALZCheckResult $endpoint.Name 'OK' "$hostName - HTTPS $method succeeded (HTTP $statusCode)."
                }
            }
            elseif ($method -eq 'Head' -and $statusCode -in @(405, 501)) {
                New-ALZCheckResult $endpoint.Name 'WARN' "$hostName - HEAD probe is not supported (HTTP $statusCode); download access is unverified." 'Check the download from the same shell. No installer or archive was downloaded by this probe.' $doc
            }
            else {
                New-ALZCheckResult $endpoint.Name 'FAIL' "$hostName - Request rejected (HTTP $statusCode)." 'Check outbound HTTPS, proxy allowlists, service availability, and download redirects with your network team. For HTTP 429, retry after the service rate limit clears.' $doc
            }
        }
        catch {
            $failure = $_.Exception
            $category = 'Connection failed'
            while ($failure) {
                if ($failure -is [System.Security.Authentication.AuthenticationException]) {
                    $category = 'TLS certificate or handshake failed'
                    break
                }
                if ($failure -is [System.TimeoutException] -or $failure -is [System.OperationCanceledException]) {
                    $category = 'Request timed out'
                    break
                }
                if ($failure -is [System.Net.Sockets.SocketException] -and $failure.SocketErrorCode -in @('HostNotFound', 'NoData', 'TryAgain')) {
                    $category = 'DNS resolution failed'
                    break
                }
                if ($failure -is [System.Net.Http.HttpRequestException] -and $failure.StatusCode -eq 407) {
                    $category = 'Proxy authentication required'
                    break
                }
                if ($failure -is [System.Net.Http.HttpRequestException] -and $failure.HttpRequestError -eq 'ProxyTunnelError') {
                    $category = 'Proxy HTTPS tunnel failed'
                    break
                }
                $failure = $failure.InnerException
            }
            $remediation = switch -Regex ($category) {
                'TLS' { 'Confirm the certificate chain and TLS inspection policy with your network team. Use approved trust stores for each tool; do not disable certificate verification.' }
                'Proxy' { 'Check approved proxy authentication and HTTPS CONNECT access with your network team. Do not place credentials in delivery files.' }
                'DNS' { 'Check DNS resolution, VPN connectivity, and the configured proxy from this execution environment.' }
                'timed out' { 'Check outbound TCP 443, the proxy, and service availability. Retry after resolving the connection issue.' }
                default { 'Check DNS, outbound TCP 443, proxy authentication, certificate trust, and redirect access in this execution environment.' }
            }
            New-ALZCheckResult $endpoint.Name 'FAIL' "$hostName - $category." $remediation $doc
        }
    }
    New-ALZCheckResult 'Connectivity scope' 'INFO' 'Unauthenticated PowerShell metadata GETs and download HEAD probes only; no tools were installed and no Azure resources were changed.' 'These checks do not verify complete downloads, organization permissions, sovereign cloud endpoints, private state storage, or connectivity from deployed runners. Git, Azure CLI, and Terraform can use different proxy settings and certificate stores.' $doc
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

function Get-ALZGitHubSecurityFindings {
    param([System.Collections.IDictionary]$Snapshot, [ValidateSet('learning', 'production')][string]$Profile = 'production')
    $riskStatus = if ($Profile -eq 'production') { 'FAIL' } else { 'WARN' }
    $plan = [string]$Snapshot.Organization.plan.name
    $environmentDoc = 'https://docs.github.com/en/actions/reference/deployments-and-environments'
    $secureDoc = 'https://docs.github.com/en/actions/reference/security/secure-use'
    if ($Snapshot.Repository.private -ne $true) { New-ALZCheckResult 'Private workload repository' 'FAIL' 'Private repository access is absent or unverified.' 'Keep workload code and sensitive plan artifacts in a private repository.' $secureDoc }
    else { New-ALZCheckResult 'Private workload repository' 'OK' 'Repository is private. This does not prevent authorized readers from cloning it.' }
    if ($Snapshot.Organization.two_factor_requirement_enabled -ne $true) { New-ALZCheckResult 'Organization 2FA' $riskStatus 'Organization-wide 2FA is disabled or could not be verified.' 'Review account recovery and collaborators before enforcing secure 2FA. AutoPilot does not change this setting.' $secureDoc }
    else { New-ALZCheckResult 'Organization 2FA' 'OK' 'Organization requires 2FA.' }
    if ($Snapshot.Organization.default_repository_permission -ne 'none' -or $Snapshot.Organization.members_can_create_public_repositories -ne $false) { New-ALZCheckResult 'Organization access' $riskStatus 'Least-privilege base access or public repository creation restrictions are absent or unverified.' 'Review base permission None and explicit team grants; restrict public repository creation.' $secureDoc }
    foreach ($entry in @(@{ Name = 'Workload'; Protection = $Snapshot.Protection }, @{ Name = 'Reusable workflow'; Protection = $Snapshot.TemplateProtection })) {
        $protection = $entry.Protection
        if ($protection.required_pull_request_reviews.required_approving_review_count -lt 1 -or $protection.enforce_admins.enabled -ne $true) { New-ALZCheckResult "$($entry.Name) PR review" $riskStatus 'Independent PR review and administrator enforcement are absent or unverified.' 'Require PR review and enforce protections. If rulesets enforce this instead, inspect them separately; this check does not certify ruleset equivalence.' $secureDoc }
        if ($protection.required_pull_request_reviews.require_code_owner_reviews -ne $true) { New-ALZCheckResult "$($entry.Name) code ownership" $riskStatus 'Code-owner review is absent or unverified.' 'Protect workflows, access configuration and CODEOWNERS with required owner review.' $secureDoc }
        if (@($protection.required_status_checks.contexts).Where({ $_ }).Count + @($protection.required_status_checks.checks).Where({ $_ }).Count -lt 1) { New-ALZCheckResult "$($entry.Name) required checks" $riskStatus 'Required status checks are absent or unverified.' 'Require the actual applicable validation checks; do not select path-filtered checks that never run for some PRs.' $secureDoc }
        if ($protection.allow_force_pushes.enabled -ne $false -or $protection.allow_deletions.enabled -ne $false) { New-ALZCheckResult "$($entry.Name) history protection" $riskStatus 'Force-push and deletion protection are absent or unverified.' 'Protect the default branch against force pushes and deletion.' $secureDoc }
    }
    if ($Snapshot.Actions.default_workflow_permissions -ne 'read' -or $Snapshot.Actions.can_approve_pull_request_reviews -ne $false) { New-ALZCheckResult 'Workflow token defaults' $riskStatus 'Read-only defaults and disabled automated approvals are absent or unverified.' 'Use read-only defaults and keep workflow PR approvals disabled. Individual jobs can request extra permissions; review workflow code.' $secureDoc }
    $policy = $Snapshot.Environment.deployment_branch_policy
    $rules = @($Snapshot.EnvironmentBranches.branch_policies)
    if ($policy.custom_branch_policies -ne $true -or $rules.Count -ne 1 -or $rules[0].name -cne $Snapshot.Branch -or $rules[0].type -cne 'branch') { New-ALZCheckResult 'Apply branch restriction' $riskStatus 'An exact default-branch-only apply environment could not be verified.' 'Configure a selected branch rule for the default branch on the apply environment. Do not apply that restriction to PR-plan environments.' $environmentDoc }
    else { New-ALZCheckResult 'Apply branch restriction' 'OK' 'The apply environment allows only the selected default branch.' }
    $reviewRules = @($Snapshot.Environment.protection_rules | Where-Object type -EQ 'required_reviewers')
    if ($plan -in @('free', 'team', 'pro')) {
        New-ALZCheckResult 'Deployment approval capability' $riskStatus "GitHub $plan does not support required deployment reviewers for private repositories. Manual dispatch is not independent approval." 'Use an Enterprise private-environment gate or a separately governed deployment system. Learning mode may prepare a proposal, but does not claim independent approval.' $environmentDoc
    }
    elseif ($plan -notin @('enterprise', 'business') -or $reviewRules.Count -ne 1 -or @($reviewRules[0].reviewers).Count -lt 1 -or $reviewRules[0].prevent_self_review -ne $true -or $Snapshot.Environment.can_admins_bypass -ne $false) {
        New-ALZCheckResult 'Deployment approval capability' $riskStatus 'Plan capability, independent environment reviewers, self-review prevention or no-bypass enforcement is unverified.' 'Verify the actual apply environment rules. Do not infer approval protection merely because an environment exists.' $environmentDoc
    }
    else { New-ALZCheckResult 'Deployment approval capability' 'OK' 'Required environment reviewers, prevention of self-review and disabled administrator bypass are configured.' }
    foreach ($name in $Snapshot.Unavailable) { New-ALZCheckResult "Security evidence: $name" $riskStatus 'The read-only API request was denied or returned incomplete data.' 'Inspect this setting manually. Do not expand token permissions automatically or treat missing evidence as a pass.' }
}

function Test-ALZWorkloadGitHubSecurity {
    param([string]$Repository, [string]$Branch, [System.Collections.IDictionary]$Pipeline, [string]$Token)
    if ($Repository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' -or $Pipeline.templatesRepository -notmatch '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$') { throw 'Select explicit workload and templates repositories for security review.' }
    $profile = if ($Pipeline.securityProfile) { $Pipeline.securityProfile } else { 'production' }
    $headers = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'ALZ-AutoPilot'; Accept = 'application/vnd.github+json' }
    $snapshot = @{ Branch = $Branch; Unavailable = @() }
    $environment = [uri]::EscapeDataString($Pipeline.applyEnvironment)
    $branchName = [uri]::EscapeDataString($Branch)
    $requests = [ordered]@{
        Organization = "orgs/$($Repository.Split('/')[0])"
        Repository = "repos/$Repository"
        Protection = "repos/$Repository/branches/$branchName/protection"
        Templates = "repos/$($Pipeline.templatesRepository)"
        Actions = "repos/$Repository/actions/permissions/workflow"
        Environment = "repos/$Repository/environments/$environment"
        EnvironmentBranches = "repos/$Repository/environments/$environment/deployment-branch-policies?per_page=100"
    }
    foreach ($request in $requests.GetEnumerator()) {
        try { $snapshot[$request.Key] = Invoke-RestMethod -Uri "https://api.github.com/$($request.Value)" -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop }
        catch { $snapshot.Unavailable += $request.Key }
    }
    if ($snapshot.Templates.default_branch) {
        try { $snapshot.TemplateProtection = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Pipeline.templatesRepository)/branches/$([uri]::EscapeDataString($snapshot.Templates.default_branch))/protection" -Method Get -Headers $headers -TimeoutSec 15 -ErrorAction Stop }
        catch { $snapshot.Unavailable += 'TemplateProtection' }
    }
    else { $snapshot.Unavailable += 'TemplateProtection' }
    Get-ALZGitHubSecurityFindings -Snapshot $snapshot -Profile $profile
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
            $results += New-ALZCheckResult "GitHub org: $Org" 'WARN' "Reachable (free plan)" 'The accelerator may create public repositories for a free organization. Do not publish customer configuration, state, plans or secrets. Use private repositories on a suitable paid plan for sensitive deployments.' 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
            # A free org forces public repos, and self-hosted runners then execute inside the
            # VNet that reaches the state storage. GitHub advises against that pairing because
            # a fork pull request can run code on the runner.
            if ($SelfHostedRunners) {
                $results += New-ALZCheckResult 'Public repos + self-hosted runners' 'WARN' 'Public repository code can execute inside a runner network with sensitive access.' 'Do not run untrusted PR code on persistent privileged runners. Use private repositories and isolated clean execution pools; external-contributor approval alone is not isolation.' 'https://docs.github.com/en/actions/reference/security/secure-use'
            }
        }
        else {
            $results += New-ALZCheckResult "GitHub org: $Org" 'OK' "Reachable (plan: $planName)"
        }
        if ($planName -eq 'team') { $results += New-ALZCheckResult 'Private deployment approval' 'WARN' 'GitHub Team supports private environments, but not required deployment reviewers on private repositories.' 'Do not treat an environment or manual workflow dispatch as an independent approval gate. Enterprise is required for that private-repository feature.' 'https://docs.github.com/en/actions/reference/deployments-and-environments#required-reviewers' }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        $rem = "Confirm the organization, token resource owner, approval and required permissions. HTTP $code does not establish whether SSO is the cause; do not widen permissions automatically."
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
        $results += New-ALZCheckResult 'Existing management groups' 'WARN' "$($collisions.Count) ALZ management group name(s) already exist: $($collisions -join ', ')" "The accelerator does not adopt existing management groups by default (update_existing defaults to false). To adopt them, set update_existing = true in the platform config at the review gate. Otherwise deploy under a different parent management group, or remove them. See the 'Brownfield tenants' section of HOW-TO-USE.md." $doc
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
    return @(New-ALZCheckResult 'Subscription contents' 'WARN' "$($populated.Count) platform subscription(s) already contain resources" "$($populated -join ' | '). On the first apply the ALZ policy baseline starts evaluating what is already running: Deny assignments block new create and update operations while existing resources keep running, and DeployIfNotExists assignments mark existing resources non-compliant without changing them until a remediation task is triggered. After a previous ALZ run its own resource groups appear here too, which is expected. To land the baseline audit-only first, see the 'Brownfield tenants' section of HOW-TO-USE.md." $doc)
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

Export-ModuleMember -Function New-ALZCheckResult, Test-ALZConnectivity, Test-ALZTooling, Test-ALZAzureLogin, Test-ALZSubscriptionAccess, Get-ALZProviderList, Test-ALZResourceProviders, Register-ALZResourceProviders, Get-ALZGitHubSecurityFindings, Test-ALZWorkloadGitHubSecurity, Test-ALZGitHubToken, Test-ALZAdoToken, Test-ALZExistingEstate, Test-ALZSubscriptionContent, Test-ALZHcpWorkspace
