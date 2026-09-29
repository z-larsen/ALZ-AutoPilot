###########################################################################
# ALZOWNCONFIG.PSM1
# DEPLOY FROM AN EXISTING ACCELERATOR CONFIGURATION
###########################################################################
# Purpose: Run the official accelerator with configuration you already own
#          and adopt its existing bootstrap state, with no interview and no
#          generated files.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator customer delivery
#
# Description:
# Uses the folder layout created by New-AcceleratorFolderStructure:
#   <delivery>\config\inputs.yaml, platform-landing-zone.tfvars|.yaml, lib\
#   <delivery>\output\  (downloaded modules, bootstrap state, version marker)
# 1. Reviews the configuration and existing state before anything runs.
# 2. Runs Deploy-Accelerator in plan-only mode. TF_CLI_ARGS_apply carries an
#    undefined flag, so every apply it attempts (including its automatic
#    retries) fails at argument parsing before state is touched.
# 3. Summarizes the saved plan without reading values, then applies exactly
#    that plan once, and verifies the state actually advanced.
#
# Prerequisites:
# - PowerShell 7.4+, the ALZ and powershell-yaml modules, Azure CLI signed in
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

$script:PlanOnlyGuardFlag = '-alz-autopilot-plan-only-guard'
$script:TokenKeys = @('github_personal_access_token', 'github_runners_personal_access_token', 'azure_devops_personal_access_token', 'azure_devops_agents_personal_access_token')
$script:TokenValuePattern = '\b(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
$script:PlaceholderPattern = '<[A-Za-z][A-Za-z0-9_.-]*>|replace_me'
$script:BootstrapDoc = 'https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/'
# Replacing these breaks the delivery itself: state storage, repositories, or the pipeline identities.
$script:CriticalTypes = @('azurerm_storage_account', 'azurerm_storage_container', 'github_repository', 'azuredevops_git_repository')
$script:IdentityTypes = @('azurerm_user_assigned_identity', 'azurerm_federated_identity_credential')

function Get-ALZOwnConfigLayout {
    param([string]$DeliveryPath)
    $config = Join-Path $DeliveryPath 'config'
    $platform = @('platform-landing-zone.tfvars', 'platform-landing-zone.yaml') |
        ForEach-Object { Join-Path $config $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    $lib = Join-Path $config 'lib'
    [pscustomobject]@{
        DeliveryPath       = $DeliveryPath
        ConfigFolder       = $config
        InputsPath         = Join-Path $config 'inputs.yaml'
        PlatformConfigPath = $platform
        LibPath            = if (Test-Path -LiteralPath $lib -PathType Container) { $lib } else { $null }
        OutputPath         = Join-Path $DeliveryPath 'output'
        # The guided bootstrap writes modules to <delivery>\bootstrap; mixing both layouts risks a second state.
        GeneratedLayout    = Test-Path -LiteralPath (Join-Path $DeliveryPath 'bootstrap') -PathType Container
    }
}

function Read-ALZOwnConfigInputs {
    param([string]$Path)
    if (-not (Get-Module powershell-yaml -ListAvailable)) {
        throw 'The powershell-yaml module is required to read inputs.yaml. Install it with: Install-PSResource powershell-yaml'
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
    if ($parsed -isnot [System.Collections.IDictionary]) { throw 'inputs.yaml must be a YAML mapping of accelerator inputs.' }
    return $parsed
}

function Remove-ALZOwnConfigComment {
    param([string]$Text, [ValidateSet('yaml', 'hcl')][string]$Kind)
    if (-not $Text) { return '' }
    if ($Kind -eq 'hcl') { $Text = [regex]::Replace($Text, '(?s)/\*.*?\*/', '') }
    $lines = foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(#|//)') { continue }
        $line -replace '\s+#.*$', ''
    }
    return ($lines -join "`n")
}

function Get-ALZOwnConfigVcs {
    param([System.Collections.IDictionary]$Inputs)
    if ($Inputs['bootstrap_module_name'] -eq 'alz_azuredevops') { return 'azuredevops' }
    return 'github'
}

function Get-ALZOwnConfigSubscription {
    param([System.Collections.IDictionary]$Inputs, [string]$Role)
    $subscriptions = $Inputs['subscription_ids']
    if ($subscriptions -is [System.Collections.IDictionary]) { return [string]$subscriptions[$Role] }
    return ''
}

function Test-ALZOwnConfigGuid {
    param([string]$Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$parsed)
}

function Test-ALZOwnConfig {
    param(
        [System.Collections.IDictionary]$Inputs,
        [string]$InputsText,
        [string]$PlatformConfigText,
        [string]$DefaultTenantId,
        [string]$ManagementTenantId,
        [string]$GitHubPlan,
        $RecordedVersions
    )
    $results = @()
    $inputsBody = Remove-ALZOwnConfigComment -Text $InputsText -Kind yaml
    $platformBody = Remove-ALZOwnConfigComment -Text $PlatformConfigText -Kind hcl

    $storedTokens = @($script:TokenKeys | Where-Object { $Inputs.Contains($_) -and -not [string]::IsNullOrWhiteSpace([string]$Inputs[$_]) })
    if ($storedTokens.Count -gt 0 -or $inputsBody -match $script:TokenValuePattern -or $platformBody -match $script:TokenValuePattern) {
        $results += New-ALZCheckResult 'Secrets in configuration' 'FAIL' 'A token key or token-like value is present in the configuration files' "Remove the value and the key ($($storedTokens -join ', ')). Supply tokens only as environment variables for the run; AutoPilot prompts for them masked. Rotate any token that was saved to disk or committed." $script:BootstrapDoc
    }
    else {
        $results += New-ALZCheckResult 'Secrets in configuration' 'OK' 'No tokens are stored in the configuration files'
    }

    $placeholders = @([regex]::Matches("$inputsBody`n$platformBody", $script:PlaceholderPattern) | ForEach-Object Value | Sort-Object -Unique)
    if ($placeholders.Count -gt 0) {
        $results += New-ALZCheckResult 'Unfilled placeholders' 'FAIL' "Example values remain: $($placeholders -join ', ')" 'Replace every example placeholder with the real value, or remove the setting, before bootstrap.' $script:BootstrapDoc
    }

    if ($Inputs['iac_type'] -notin @('terraform', 'bicep')) {
        $results += New-ALZCheckResult 'IaC type' 'FAIL' "iac_type '$($Inputs['iac_type'])' is not supported by this mode" "Use 'terraform' or 'bicep'."
    }
    if ($Inputs['bootstrap_module_name'] -notin @('alz_github', 'alz_azuredevops')) {
        $results += New-ALZCheckResult 'Bootstrap module' 'FAIL' "bootstrap_module_name '$($Inputs['bootstrap_module_name'])' is not supported by this mode" "Use 'alz_github' or 'alz_azuredevops'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Inputs['bootstrap_location'])) {
        $results += New-ALZCheckResult 'Bootstrap region' 'FAIL' 'bootstrap_location is not set' 'Set bootstrap_location to the Azure region for the bootstrap resources.'
    }
    if ((Get-ALZOwnConfigVcs -Inputs $Inputs) -eq 'github' -and [string]::IsNullOrWhiteSpace([string]$Inputs['github_organization_name'])) {
        $results += New-ALZCheckResult 'GitHub organization' 'FAIL' 'github_organization_name is not set' 'Set github_organization_name to the organization that will hold the repositories.'
    }

    $ids = @()
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = Get-ALZOwnConfigSubscription -Inputs $Inputs -Role $role
        if ([string]::IsNullOrWhiteSpace($id)) {
            if ($role -in @('management', 'connectivity')) {
                $results += New-ALZCheckResult "Subscription: $role" 'FAIL' 'Not set' "subscription_ids.$role is required."
            }
            continue
        }
        if (-not (Test-ALZOwnConfigGuid -Value $id)) {
            $results += New-ALZCheckResult "Subscription: $role" 'FAIL' "'$id' is not a subscription ID" 'Use the subscription GUID, not its name.'
            continue
        }
        $ids += $id.ToLowerInvariant()
    }
    if (@($ids | Group-Object | Where-Object Count -GT 1).Count -gt 0) {
        $results += New-ALZCheckResult 'Subscription IDs' 'FAIL' 'The same subscription is listed for more than one role' 'Omit identity and security when they share another subscription; blank or repeated IDs fail subscription placement.'
    }
    elseif ($ids.Count -ge 2) {
        $results += New-ALZCheckResult 'Subscription IDs' 'OK' "$($ids.Count) distinct platform subscription(s)"
    }

    $bootstrapSub = [string]$Inputs['bootstrap_subscription_id']
    if ([string]::IsNullOrWhiteSpace($bootstrapSub)) {
        $results += New-ALZCheckResult 'Bootstrap subscription' 'WARN' 'bootstrap_subscription_id is empty, so the Azure CLI default subscription is used' 'Set bootstrap_subscription_id explicitly so a different CLI default cannot redirect the bootstrap.'
    }
    elseif (-not (Test-ALZOwnConfigGuid -Value $bootstrapSub)) {
        $results += New-ALZCheckResult 'Bootstrap subscription' 'FAIL' "'$bootstrapSub' is not a subscription ID" 'Use the subscription GUID.'
    }

    if ([string]::IsNullOrWhiteSpace($ManagementTenantId)) {
        $results += New-ALZCheckResult 'Azure tenant' 'FAIL' 'The management subscription is not visible to the signed-in Azure CLI account' 'Sign in to the tenant that owns the platform subscriptions (az login --tenant <tenant-id>), then re-run.'
    }
    elseif ($DefaultTenantId -and $DefaultTenantId -ne $ManagementTenantId) {
        $results += New-ALZCheckResult 'Azure tenant' 'FAIL' "The Azure CLI default is tenant $DefaultTenantId, but the platform subscriptions are in $ManagementTenantId" 'Run az account set --subscription <management-subscription-id> and confirm the tenant before bootstrap. Terraform and the accelerator use the CLI default login.'
    }
    else {
        $results += New-ALZCheckResult 'Azure tenant' 'OK' "Azure CLI default matches the platform tenant ($ManagementTenantId)"
    }

    $unpinned = @('bootstrap_module_version', 'starter_module_version' | Where-Object { [string]::IsNullOrWhiteSpace([string]$Inputs[$_]) })
    if ($unpinned.Count -gt 0) {
        $results += New-ALZCheckResult 'Pinned versions' 'WARN' "Not pinned: $($unpinned -join ', ')" 'Pin bootstrap_module_version and starter_module_version so a redeploy uses the same code. Unpinned runs use the recorded version when one exists, otherwise the latest release.'
    }
    else {
        $results += New-ALZCheckResult 'Pinned versions' 'OK' "Bootstrap $($Inputs['bootstrap_module_version']), starter $($Inputs['starter_module_version'])"
    }
    if ($Inputs['terraform_version'] -eq 'latest') {
        $results += New-ALZCheckResult 'Terraform version' 'WARN' "terraform_version is 'latest'" 'Pin an exact Terraform version for repeatable bootstrap runs.'
    }
    if ($RecordedVersions) {
        foreach ($pair in @(@('bootstrap_module_version', 'bootstrapVersion'), @('starter_module_version', 'starterVersion'))) {
            $wanted = [string]$Inputs[$pair[0]]
            $recorded = [string]$RecordedVersions.($pair[1])
            if ($wanted -and $recorded -and $wanted -ne $recorded) {
                $results += New-ALZCheckResult 'Version change' 'FAIL' "$($pair[0]) is $wanted but this output folder was built with $recorded" 'A version change downloads a new module folder and can start a new, empty bootstrap state. Handle it as a reviewed upgrade (AutoPilot option 4), not as a routine run.'
            }
        }
    }

    $approvers = @($Inputs['apply_approvers'] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ((Get-ALZOwnConfigVcs -Inputs $Inputs) -eq 'github' -and $approvers.Count -gt 0 -and $GitHubPlan -eq 'team') {
        $results += New-ALZCheckResult 'Apply approvers' 'FAIL' 'apply_approvers is set, but the GitHub organization is on the Team plan' 'Required reviewers on private-repository environments need GitHub Enterprise; the bootstrap fails with HTTP 422 creating the apply environment. Set apply_approvers: [] and gate changes with pull-request plan review, or move the organization to Enterprise. Do not make the repositories public to get the feature.' 'https://docs.github.com/en/actions/reference/deployments-and-environments#required-reviewers'
    }
    elseif ($approvers.Count -eq 0) {
        $results += New-ALZCheckResult 'Apply approvers' 'OK' 'None: the pipeline applies after its plan, so pull-request plan review is the gate'
    }
    else {
        $results += New-ALZCheckResult 'Apply approvers' 'OK' "$($approvers -join ', ') (GitHub plan: $(if ($GitHubPlan) { $GitHubPlan } else { 'unknown' }))"
    }

    if ($platformBody -match 'connectivity_type\s*=\s*"virtual_wan"' -and $platformBody -match 'firewall_enabled\s*=\s*true' -and $platformBody -notmatch 'routing_intents\s*=') {
        $results += New-ALZCheckResult 'Virtual WAN routing intent' 'WARN' 'A secured hub firewall is enabled, but no routing_intents are configured' 'Without routing intent, spoke and internet traffic does not pass through the hub firewall. Add routing_intents to the virtual hub if inspection is intended.' 'https://learn.microsoft.com/azure/virtual-wan/how-to-routing-policies'
    }
    if ($platformBody -match '(?s)private_link_private_dns_zones_regex_filter\s*=\s*\{[^}]*enabled\s*=\s*true') {
        $results += New-ALZCheckResult 'Private DNS zone filter' 'WARN' 'private_link_private_dns_zones_regex_filter is enabled' 'The filter keeps only zones whose names contain the region, so global zones such as privatelink.blob.core.windows.net and privatelink.vaultcore.azure.net are not created. Leave it off for the primary hub (the module default) and use it only on secondary hubs, or the DNS policy role assignments fail with ResourceNotFound.' 'https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-virtual-wan#private-dns-zones'
    }
    return $results
}

function Get-ALZOwnConfigRecordedVersions {
    param([string]$OutputPath)
    $marker = Join-Path $OutputPath '.alz-version-data.json'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    try { return Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "The version marker $marker is unreadable. Stop for recovery; no delivery files were changed." }
}

function Get-ALZOwnConfigBootstrapFolder {
    param([string]$OutputPath, [System.Collections.IDictionary]$Inputs)
    $recorded = Get-ALZOwnConfigRecordedVersions -OutputPath $OutputPath
    if (-not $recorded -or -not $recorded.bootstrapVersion) { return $null }
    return Join-Path $OutputPath "bootstrap\$($recorded.bootstrapVersion)\alz\$(Get-ALZOwnConfigVcs -Inputs $Inputs)"
}

function Get-ALZOwnConfigBootstrapState {
    param([string]$OutputPath, [System.Collections.IDictionary]$Inputs)
    $vcs = Get-ALZOwnConfigVcs -Inputs $Inputs
    $folders = @(Get-ChildItem -LiteralPath (Join-Path $OutputPath 'bootstrap') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "alz\$vcs" } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'terraform.tfstate') -PathType Leaf })
    if ($folders.Count -gt 1) {
        return [pscustomobject]@{ Exists = $false; Ambiguous = $true; Folder = $null; Folders = $folders }
    }
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Exists = $false; Ambiguous = $false; Folder = $null; Folders = @() }
    }
    $statePath = Join-Path $folders[0] 'terraform.tfstate'
    # Only metadata is read; resource attributes stay untouched and are never printed.
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 100
    [pscustomobject]@{
        Exists        = $true
        Ambiguous     = $false
        Folder        = $folders[0]
        Folders       = $folders
        StatePath     = $statePath
        Serial        = [long]$state.serial
        Lineage       = [string]$state.lineage
        ResourceCount = @($state.resources).Count
        LastWriteUtc  = (Get-Item -LiteralPath $statePath).LastWriteTimeUtc
    }
}

function Get-ALZOwnConfigStateResourceGroupName {
    param([System.Collections.IDictionary]$Inputs)
    $template = 'rg-{{service_name}}-{{environment_name}}-state-{{azure_location}}-{{postfix_number}}'
    $overrides = $Inputs['resource_names']
    if ($overrides -is [System.Collections.IDictionary] -and $overrides['resource_group_state']) { $template = [string]$overrides['resource_group_state'] }
    $postfix = if ($Inputs['postfix_number']) { [int]$Inputs['postfix_number'] } else { 1 }
    $name = $template.
        Replace('{{service_name}}', $(if ($Inputs['service_name']) { [string]$Inputs['service_name'] } else { 'alz' })).
        Replace('{{environment_name}}', $(if ($Inputs['environment_name']) { [string]$Inputs['environment_name'] } else { 'mgmt' })).
        Replace('{{azure_location}}', [string]$Inputs['bootstrap_location']).
        Replace('{{postfix_number}}', ('{0:000}' -f $postfix))
    if ($name -match '\{\{') { return $null }
    return $name
}

function Test-ALZOwnConfigAdoption {
    param($Layout, $BootstrapState, [string]$StateResourceGroupName, $StateResourceGroupExists)
    $results = @()
    if ($Layout.GeneratedLayout) {
        $results += New-ALZCheckResult 'Delivery layout' 'FAIL' "$($Layout.DeliveryPath) also contains a guided-bootstrap 'bootstrap' folder" 'Use a folder created by New-AcceleratorFolderStructure (config and output subfolders) for this mode. Mixing layouts can start a second bootstrap state.'
    }
    if ($BootstrapState.Ambiguous) {
        $results += New-ALZCheckResult 'Bootstrap state' 'FAIL' "More than one bootstrap state exists: $($BootstrapState.Folders -join '; ')" 'Identify the authoritative state before continuing. Treat a module version change as a reviewed upgrade.'
    }
    elseif ($BootstrapState.Exists) {
        $results += New-ALZCheckResult 'Bootstrap state' 'OK' "Adopting existing state: serial $($BootstrapState.Serial), $($BootstrapState.ResourceCount) resources, lineage $($BootstrapState.Lineage)"
    }
    elseif ($StateResourceGroupExists -eq $true) {
        $results += New-ALZCheckResult 'Bootstrap state' 'FAIL' "'$StateResourceGroupName' already exists in Azure, but $($Layout.OutputPath) has no bootstrap state" 'A bootstrap from here would try to create a second copy of existing delivery resources. Restore the original output folder from backup, or run this mode from the folder that holds the state.' $script:BootstrapDoc
    }
    elseif ($null -eq $StateResourceGroupExists) {
        $results += New-ALZCheckResult 'Bootstrap state' 'WARN' 'No local bootstrap state; could not confirm that the bootstrap does not already exist in Azure' "Confirm that the bootstrap state resource group ($StateResourceGroupName) does not exist before approving a plan."
    }
    else {
        $results += New-ALZCheckResult 'Bootstrap state' 'OK' "New bootstrap: no local state and no '$StateResourceGroupName' in Azure"
    }
    return $results
}

function Get-ALZOwnConfigGitHubPlan {
    param([string]$Token, [string]$Org)
    try {
        $headers = @{ Authorization = "Bearer $Token"; 'User-Agent' = 'ALZ-Orchestrator'; Accept = 'application/vnd.github+json' }
        return (Invoke-RestMethod -Uri "https://api.github.com/orgs/$([uri]::EscapeDataString($Org))" -Headers $headers -Method Get -ErrorAction Stop).plan.name
    }
    catch { return $null }
}

function Set-ALZOwnConfigTokenEnvironment {
    param([System.Collections.IDictionary]$Inputs, [securestring]$VcsToken, [securestring]$VcsAgentsToken)
    $isAdo = (Get-ALZOwnConfigVcs -Inputs $Inputs) -eq 'azuredevops'
    $names = [pscustomobject]@{
        Token  = if ($isAdo) { 'TF_VAR_azure_devops_personal_access_token' } else { 'TF_VAR_github_personal_access_token' }
        Agents = if ($isAdo) { 'TF_VAR_azure_devops_agents_personal_access_token' } else { 'TF_VAR_github_runners_personal_access_token' }
        Values = @()
    }
    foreach ($pair in @(@($names.Token, $VcsToken), @($names.Agents, $VcsAgentsToken))) {
        if (-not $pair[1]) { continue }
        $plain = ConvertTo-ALZPlainText -Secure $pair[1]
        Set-Item -Path "Env:$($pair[0])" -Value $plain
        $names.Values += $plain
    }
    return $names
}

function Clear-ALZOwnConfigTokenEnvironment {
    param($TokenEnvironment, [string]$TranscriptPath)
    Remove-Item -Path "Env:$($TokenEnvironment.Token)", "Env:$($TokenEnvironment.Agents)" -ErrorAction SilentlyContinue
    if ($TranscriptPath -and (Test-Path -LiteralPath $TranscriptPath)) {
        try {
            $content = Get-Content -LiteralPath $TranscriptPath -Raw
            $changed = $false
            foreach ($secret in @($TokenEnvironment.Values)) {
                if ($secret -and $content.Contains($secret)) { $content = $content.Replace($secret, '***REDACTED***'); $changed = $true }
            }
            if ($changed) { Set-Content -LiteralPath $TranscriptPath -Value $content -Encoding UTF8 }
        }
        catch {
            Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
            Write-Warning 'The session transcript could not be scrubbed, so it was deleted.'
        }
    }
    $TokenEnvironment.Values = @()
}

function Invoke-ALZOwnConfigPlan {
    param($Layout, [System.Collections.IDictionary]$Inputs, [securestring]$VcsToken, [securestring]$VcsAgentsToken, [string]$DataPath)
    $configPaths = @($Layout.InputsPath)
    if ($Layout.PlatformConfigPath) { $configPaths += $Layout.PlatformConfigPath }
    $params = @{ inputConfigFilePaths = $configPaths; output_folder_path = $Layout.OutputPath; auto_approve = $true }
    if ($Layout.LibPath -and -not $Inputs.Contains('starter_additional_files')) { $params['starter_additional_files'] = @($Layout.LibPath) }

    $before = Get-ALZOwnConfigBootstrapState -OutputPath $Layout.OutputPath -Inputs $Inputs
    $started = (Get-Date).ToUniversalTime()
    $priorGuard = $env:TF_CLI_ARGS_apply
    $priorRegistrations = $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS
    $transcript = Join-Path $env:TEMP "alz-ownconfig-plan-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $tokens = $null
    $thrown = $null
    $transcriptStarted = $false
    try {
        $tokens = Set-ALZOwnConfigTokenEnvironment -Inputs $Inputs -VcsToken $VcsToken -VcsAgentsToken $VcsAgentsToken
        $env:TF_CLI_ARGS_apply = $script:PlanOnlyGuardFlag
        $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'
        try { Start-Transcript -Path $transcript -Force | Out-Null; $transcriptStarted = $true }
        catch { Write-Verbose "Transcript unavailable; known-error matching will use the returned error only: $($_.Exception.Message)" }
        Deploy-Accelerator @params
    }
    catch { $thrown = $_.Exception.Message }
    finally {
        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Transcript was already stopped: $($_.Exception.Message)" } }
        $env:TF_CLI_ARGS_apply = $priorGuard
        $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = $priorRegistrations
        if ($tokens) { Clear-ALZOwnConfigTokenEnvironment -TokenEnvironment $tokens -TranscriptPath $transcript }
    }

    $log = if (Test-Path -LiteralPath $transcript) { Get-Content -LiteralPath $transcript -Raw } else { '' }
    $folder = Get-ALZOwnConfigBootstrapFolder -OutputPath $Layout.OutputPath -Inputs $Inputs
    $planPath = if ($folder) { Join-Path $folder 'tfplan' } else { $null }
    $after = Get-ALZOwnConfigBootstrapState -OutputPath $Layout.OutputPath -Inputs $Inputs
    $stateChanged = ($before.Exists -ne $after.Exists) -or ($before.Exists -and ($before.Serial -ne $after.Serial -or $before.Lineage -ne $after.Lineage))
    $freshPlan = $planPath -and (Test-Path -LiteralPath $planPath) -and (Get-Item -LiteralPath $planPath).LastWriteTimeUtc -ge $started.AddSeconds(-2)
    # PowerShell 7 transcripts omit native stderr, so the accelerator's apply error is the observable proof.
    $guardHeld = ($log -match [regex]::Escape($script:PlanOnlyGuardFlag)) -or ($thrown -match 'Terraform apply failed')
    $message = if ($stateChanged) { 'Bootstrap state changed during a plan-only run. Stop and review the state before doing anything else.' }
    elseif ($thrown -match 'plan failed') { $thrown }
    elseif (-not $freshPlan) { if ($thrown) { $thrown } else { 'The accelerator finished without producing a new plan file.' } }
    elseif (-not $guardHeld) { 'A plan was produced, but the plan-only guard was not observed in the accelerator output.' }
    else { 'Plan produced; the plan-only guard blocked every apply attempt.' }

    return [pscustomobject]@{
        Succeeded       = [bool]($freshPlan -and $guardHeld -and -not $stateChanged)
        StateChanged    = [bool]$stateChanged
        PlanPath        = $planPath
        BootstrapFolder = $folder
        OutputPath      = $Layout.OutputPath
        StateBefore     = $before
        Message         = $message
        TranscriptPath  = $transcript
        MatchedTraps    = @(Resolve-ALZError -Text $log -DataPath $DataPath)
    }
}

function Get-ALZOwnConfigPlanJson {
    param([string]$BootstrapFolder)
    $raw = & terraform "-chdir=$BootstrapFolder" show -json tfplan 2>$null
    if ($LASTEXITCODE -ne 0) { throw "terraform show could not read the saved plan in $BootstrapFolder (exit $LASTEXITCODE)." }
    return ($raw -join "`n") | ConvertFrom-Json -Depth 100
}

function ConvertTo-ALZOwnConfigPlanReview {
    param($Plan)
    # Reads addresses, actions and replacement attribute names only; never attribute values.
    $changes = foreach ($rc in @($Plan.resource_changes)) {
        $actions = @($rc.change.actions)
        if ($actions.Count -eq 1 -and $actions[0] -in @('no-op', 'read')) { continue }
        $kind = if ($actions -contains 'delete' -and $actions -contains 'create') { 'replace' }
        elseif ($actions -contains 'delete') { 'delete' }
        elseif ($actions -contains 'create') { 'create' }
        else { 'update' }
        # Values are compared in memory to name the changed attributes; they are never returned or printed.
        $changedAttributes = @()
        if ($kind -eq 'update' -and $rc.change.before -and $rc.change.after) {
            $names = @(@($rc.change.before.PSObject.Properties.Name) + @($rc.change.after.PSObject.Properties.Name) | Sort-Object -Unique)
            $changedAttributes = @($names | Where-Object {
                    ($rc.change.before.$_ | ConvertTo-Json -Compress -Depth 20) -ne ($rc.change.after.$_ | ConvertTo-Json -Compress -Depth 20) -or
                    ($rc.change.after_unknown -and $rc.change.after_unknown.$_ -eq $true)
                })
        }
        [pscustomobject]@{
            Address           = [string]$rc.address
            Type              = [string]$rc.type
            Kind              = $kind
            Reason            = [string]$rc.action_reason
            ReplacePaths      = @(@($rc.change.replace_paths) | Where-Object { $_ } | ForEach-Object { [string](@($_)[0]) } | Sort-Object -Unique)
            ChangedAttributes = $changedAttributes
        }
    }
    $changes = @($changes)
    $destructive = @($changes | Where-Object Kind -In @('delete', 'replace'))
    $findings = @()
    foreach ($c in $destructive) {
        if ($c.ReplacePaths -contains 'ip_tags') {
            $findings += [pscustomobject]@{ Id = 'public-ip-platform-ip-tags'; Severity = 'Block'; Address = $c.Address
                Title = 'Public IP would be replaced because Azure added an IP tag'
                Remediation = 'The platform stamps an IP tag (for example FirstPartyUsage=/Unprivileged) on new public IPs in some subscriptions, and ip_tags cannot change in place. Add lifecycle { ignore_changes = [ip_tags] } to that public IP in the downloaded bootstrap module, or declare the same tag, then re-run. Re-apply the patch after any bootstrap version change.' }
        }
        elseif ($c.Type -in $script:CriticalTypes) {
            $findings += [pscustomobject]@{ Id = 'delivery-resource-destroyed'; Severity = 'Block'; Address = $c.Address
                Title = "Delivery resource would be $($c.Kind)d"
                Remediation = 'Deleting or replacing state storage or the delivery repositories loses state or history. Find the cause (configuration drift, a renamed input, or a version change) before any apply.' }
        }
        elseif ($c.Type -in $script:IdentityTypes) {
            $findings += [pscustomobject]@{ Id = 'pipeline-identity-replaced'; Severity = 'Review'; Address = $c.Address
                Title = "Pipeline identity would be $($c.Kind)d"
                Remediation = 'A replaced identity gets a new client ID; pipelines and role assignments that reference the old one stop working until updated.' }
        }
    }
    $metadataOnly = @($changes | Where-Object {
            $_.Type -eq 'github_repository_file' -and $_.Kind -eq 'update' -and $_.ChangedAttributes.Count -gt 0 -and
            @($_.ChangedAttributes | Where-Object { $_ -notin @('commit_author', 'commit_email', 'commit_message', 'commit_sha') }).Count -eq 0
        })
    if ($metadataOnly.Count -gt 0) {
        $findings += [pscustomobject]@{ Id = 'repository-file-metadata-only'; Severity = 'Review'; Address = "$($metadataOnly.Count) repository file(s)"
            Title = 'Repository file updates change only commit metadata'
            Remediation = 'These updates change the commit author or email, not file content. A default branch that requires pull requests rejects them (HTTP 409), so the apply reports errors even though nothing else is affected; state can still record the new values. The commit author comes from the first apply approver, so avoid changing apply_approvers after the first bootstrap.' }
    }
    [pscustomobject]@{
        Changes     = $changes
        Counts      = [ordered]@{
            create  = @($changes | Where-Object Kind -EQ 'create').Count
            update  = @($changes | Where-Object Kind -EQ 'update').Count
            delete  = @($changes | Where-Object Kind -EQ 'delete').Count
            replace = @($changes | Where-Object Kind -EQ 'replace').Count
        }
        Destructive = $destructive
        Findings    = $findings
        Blocked     = @($findings | Where-Object Severity -EQ 'Block').Count -gt 0
    }
}

function Write-ALZOwnConfigPlanReview {
    param($Review)
    Write-ALZSection 'Plan review (addresses and actions only; no values are shown)'
    $c = $Review.Counts
    Write-Host ("  Create {0}   Update {1}   Delete {2}   Replace {3}" -f $c.create, $c.update, $c.delete, $c.replace) -ForegroundColor White
    foreach ($group in ($Review.Changes | Group-Object Type, Kind | Sort-Object Name)) {
        Write-Host ('   {0,-8} x{1,-4} {2}' -f $group.Group[0].Kind, $group.Count, $group.Group[0].Type) -ForegroundColor Gray
    }
    if ($Review.Destructive.Count -gt 0) {
        Write-Host ''
        Write-Host '  Destructive changes:' -ForegroundColor Yellow
        foreach ($d in $Review.Destructive) {
            $why = if ($d.ReplacePaths.Count) { " (forced by: $($d.ReplacePaths -join ', '))" } else { '' }
            Write-Host "   - $($d.Kind): $($d.Address)$why" -ForegroundColor Yellow
        }
    }
    foreach ($f in $Review.Findings) {
        Write-ALZStatus -Status $(if ($f.Severity -eq 'Block') { 'FAIL' } else { 'WARN' }) -Message $f.Title -Detail $f.Address
        Write-ALZRemediation -Title $f.Title -Remediation $f.Remediation -DocUrl ''
    }
}

function Invoke-ALZOwnConfigApply {
    param($PlanResult, [System.Collections.IDictionary]$Inputs, [securestring]$VcsToken, [securestring]$VcsAgentsToken, [int]$ExpectedChanges, [string]$DataPath)
    $planPath = $PlanResult.PlanPath
    if (-not $planPath -or -not (Test-Path -LiteralPath $planPath)) { throw 'The reviewed plan file is missing. Nothing was applied.' }
    $folder = $PlanResult.BootstrapFolder
    $current = Get-ALZOwnConfigBootstrapState -OutputPath $PlanResult.OutputPath -Inputs $Inputs
    $before = $PlanResult.StateBefore
    if ($before.Exists -and (-not $current.Exists -or $current.Serial -ne $before.Serial -or $current.Lineage -ne $before.Lineage)) {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        throw 'Bootstrap state changed after the plan was reviewed. The plan was discarded; nothing was applied.'
    }

    $prior = @{ Guard = $env:TF_CLI_ARGS_apply; Registrations = $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS; Subscription = $env:ARM_SUBSCRIPTION_ID }
    $tokens = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    $exitCode = -1
    $logPath = Join-Path $env:TEMP "alz-ownconfig-apply-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $ErrorActionPreference = 'Continue'
    try {
        $tokens = Set-ALZOwnConfigTokenEnvironment -Inputs $Inputs -VcsToken $VcsToken -VcsAgentsToken $VcsAgentsToken
        Remove-Item Env:TF_CLI_ARGS_apply -ErrorAction SilentlyContinue
        $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'
        if (-not $env:ARM_SUBSCRIPTION_ID) {
            $env:ARM_SUBSCRIPTION_ID = if ($Inputs['bootstrap_subscription_id']) { [string]$Inputs['bootstrap_subscription_id'] } else { az account show --query id -o tsv 2>$null }
        }
        # One attempt only: a failed apply is reviewed, never retried with a fresh unreviewed plan.
        & terraform "-chdir=$folder" apply -input=false tfplan 2>&1 | ForEach-Object { $text = "$_"; $lines.Add($text); Write-Host $text }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:TF_CLI_ARGS_apply = $prior.Guard
        $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = $prior.Registrations
        $env:ARM_SUBSCRIPTION_ID = $prior.Subscription
        Set-Content -LiteralPath $logPath -Value $lines -Encoding UTF8
        if ($tokens) { Clear-ALZOwnConfigTokenEnvironment -TokenEnvironment $tokens -TranscriptPath $logPath }
        # A saved plan holds input variables, including tokens; never keep it after use.
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
    }

    $after = Get-ALZOwnConfigBootstrapState -OutputPath $PlanResult.OutputPath -Inputs $Inputs
    $advanced = $after.Exists -and (-not $before.Exists -or ($after.Lineage -eq $before.Lineage -and $after.Serial -gt $before.Serial))
    $verified = $exitCode -eq 0 -and ($advanced -or $ExpectedChanges -eq 0)
    [pscustomobject]@{
        Succeeded    = [bool]$verified
        Partial      = [bool]($exitCode -ne 0 -and $advanced)
        ExitCode     = $exitCode
        StateBefore  = $before
        StateAfter   = $after
        LogPath      = $logPath
        MatchedTraps = @(Resolve-ALZError -Text ($lines -join "`n") -DataPath $DataPath)
    }
}

function Remove-ALZOwnConfigPlanFile {
    param([string]$PlanPath)
    if ($PlanPath -and (Test-Path -LiteralPath $PlanPath)) { Remove-Item -LiteralPath $PlanPath -Force -ErrorAction SilentlyContinue }
}

function Write-ALZOwnConfigTarget {
    param([System.Collections.IDictionary]$Inputs, $Layout, $AzureContext, [hashtable]$SubscriptionNames, $RecordedVersions, $BootstrapState)
    Write-ALZSection 'Configuration to deploy (used exactly as written)'
    $row = { param($k, $v, $c = 'White') Write-Host ('   {0,-24}' -f $k) -ForegroundColor DarkGray -NoNewline; Write-Host $v -ForegroundColor $c }
    & $row 'Tenant (CLI default)' $(if ($AzureContext) { $AzureContext.tenantId } else { 'unknown' }) 'Yellow'
    if ($AzureContext) { & $row 'Signed in as' $AzureContext.user.name }
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = Get-ALZOwnConfigSubscription -Inputs $Inputs -Role $role
        if ($id) { & $row "Subscription: $role" $(if ($SubscriptionNames.ContainsKey($id)) { "$($SubscriptionNames[$id])  ($id)" } else { $id }) }
    }
    & $row 'Bootstrap subscription' $(if ($Inputs['bootstrap_subscription_id']) { $Inputs['bootstrap_subscription_id'] } else { 'Azure CLI default' })
    & $row 'Region' $Inputs['bootstrap_location']
    & $row 'Version control' $(if ((Get-ALZOwnConfigVcs -Inputs $Inputs) -eq 'azuredevops') { "Azure DevOps '$($Inputs['azure_devops_organization_name'])'" } else { "GitHub org '$($Inputs['github_organization_name'])'" })
    & $row 'Apply approvers' $(if (@($Inputs['apply_approvers']).Count) { @($Inputs['apply_approvers']) -join ', ' } else { 'none (pull-request review is the gate)' })
    & $row 'Bootstrap / starter' "$(if ($Inputs['bootstrap_module_version']) { $Inputs['bootstrap_module_version'] } else { 'unpinned' }) / $(if ($Inputs['starter_module_version']) { $Inputs['starter_module_version'] } else { 'unpinned' })"
    if ($RecordedVersions) { & $row 'Output folder built with' "$($RecordedVersions.bootstrapVersion) / $($RecordedVersions.starterVersion)" }
    & $row 'Platform config' $(if ($Layout.PlatformConfigPath) { $Layout.PlatformConfigPath } else { 'missing' })
    & $row 'Custom library' $(if ($Layout.LibPath) { $Layout.LibPath } elseif ($Inputs.Contains('starter_additional_files')) { 'declared in inputs.yaml' } else { 'none' })
    & $row 'Output folder' $Layout.OutputPath
    & $row 'Bootstrap state' $(if ($BootstrapState.Exists) { "existing: serial $($BootstrapState.Serial), $($BootstrapState.ResourceCount) resources" } elseif ($BootstrapState.Ambiguous) { 'AMBIGUOUS (more than one)' } else { 'none yet' }) $(if ($BootstrapState.Exists) { 'Green' } else { 'White' })
}

function Invoke-ALZOwnConfigPipeline {
    param([hashtable]$State, [System.Collections.IDictionary]$Inputs, [securestring]$VcsToken)
    Write-ALZSection 'Stage 2: platform pipeline'
    if ((Get-ALZOwnConfigVcs -Inputs $Inputs) -eq 'azuredevops') {
        Write-ALZStatus -Status INFO -Message 'Run the "02 Continuous Delivery" pipeline in Azure DevOps and review its plan before approving the apply.'
        return $null
    }
    $org = [string]$Inputs['github_organization_name']
    if (@($Inputs['apply_approvers']).Count -eq 0) {
        Write-ALZStatus -Status WARN -Message 'No required reviewers: the CD workflow plans and then applies without pausing.' -Detail 'Review the plan on a pull request before merging changes to the default branch.'
    }
    if (-not (Read-ALZConfirm -Prompt 'Trigger the platform CD workflow now?' -Default $false)) {
        Write-Host "  When ready: https://github.com/$org -> module repo -> Actions -> '02 ... Continuous Delivery' -> Run workflow." -ForegroundColor DarkCyan
        return $null
    }
    $tok = ConvertTo-ALZPlainText -Secure $VcsToken
    try {
        $repo = Find-ALZModuleRepo -Token $tok -Org $org
        if (-not $repo) {
            Write-ALZStatus -Status WARN -Message 'Could not find the module repository and its CD workflow.'
            return $null
        }
        if (-not (Start-ALZWorkflow -Token $tok -Org $org -Repo $repo.Repo -WorkflowId $repo.CdId -Ref $repo.DefaultBranch)) {
            Write-ALZStatus -Status WARN -Message 'Could not trigger the workflow through the API.' -Detail "https://github.com/$org/$($repo.Repo)/actions"
            return $null
        }
        Add-ALZStat -State $State -Name 'pipelineRuns'
        Write-ALZStatus -Status OK -Message "Triggered '$($repo.CdName)'. Watching the run..."
        $result = Wait-ALZPipelineRun -Token $tok -Org $org -Repo $repo.Repo -WorkflowId $repo.CdId -ThroughApproval -TimeoutMinutes 120
        if ($result.State -eq 'completed' -and $result.Conclusion -eq 'success') {
            Set-ALZPhaseStatus -State $State -Phase 'proof' -Status 'done'
            Write-ALZStatus -Status OK -Message 'Platform pipeline succeeded.' -Detail $result.Url
        }
        else {
            Write-ALZStatus -Status WARN -Message "Pipeline state: $($result.State) $($result.Conclusion)" -Detail $result.Url
        }
        return $result
    }
    finally { $tok = $null }
}

function Invoke-ALZOwnConfigDelivery {
    param([hashtable]$State, [string]$DataPath)
    Write-ALZBanner -Title 'Deploy from your own accelerator configuration' -Subtitle 'inputs.yaml, the platform config and lib are used exactly as written. Nothing is generated.'
    foreach ($phase in @('interview', 'config', 'hcp')) { if ($State.phaseStatus[$phase] -ne 'skipped') { Set-ALZPhaseStatus -State $State -Phase $phase -Status 'skipped' } }

    $layout = Get-ALZOwnConfigLayout -DeliveryPath $State.deliveryPath
    if (-not (Test-Path -LiteralPath $layout.InputsPath) -or -not $layout.PlatformConfigPath) {
        Write-ALZStatus -Status FAIL -Message 'No accelerator configuration found in this folder.' -Detail "Expected $($layout.InputsPath) and config\platform-landing-zone.tfvars (or .yaml)."
        Write-ALZRemediation -Title 'Create or copy the configuration first' -Remediation 'Run New-AcceleratorFolderStructure -iacType terraform -versionControl github -scenarioNumber <n> -targetFolderPath <this folder>, edit config\inputs.yaml and the platform config, then re-run and choose option 6.' -DocUrl 'https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/'
        return
    }
    $inputs = Read-ALZOwnConfigInputs -Path $layout.InputsPath
    $isAdo = (Get-ALZOwnConfigVcs -Inputs $inputs) -eq 'azuredevops'

    Set-ALZCurrentPhase -State $State -Phase 'preflight'
    $context = $null
    # A missing context is reported by the tenant check below rather than failing here.
    try { $context = az account show -o json 2>$null | ConvertFrom-Json } catch { $context = $null }
    $managementSub = Get-ALZOwnConfigSubscription -Inputs $inputs -Role 'management'
    $managementTenant = if ($managementSub) { az account show --subscription $managementSub --query tenantId -o tsv 2>$null } else { $null }
    $names = @{}
    try { foreach ($s in @(az account list --all -o json 2>$null | ConvertFrom-Json)) { $names[$s.id] = $s.name } }
    catch { Write-Verbose 'Subscription names unavailable; IDs are shown instead.' }
    $recorded = Get-ALZOwnConfigRecordedVersions -OutputPath $layout.OutputPath
    $bootState = Get-ALZOwnConfigBootstrapState -OutputPath $layout.OutputPath -Inputs $inputs
    $rgName = Get-ALZOwnConfigStateResourceGroupName -Inputs $inputs
    $bootstrapSub = if ($inputs['bootstrap_subscription_id']) { [string]$inputs['bootstrap_subscription_id'] } elseif ($context) { $context.id } else { '' }
    $rgExists = $null
    if ($rgName -and $bootstrapSub) {
        $exists = az group exists --name $rgName --subscription $bootstrapSub 2>$null
        if ($LASTEXITCODE -eq 0) { $rgExists = $exists -eq 'true' }
    }

    $State.answers.deliveryName = "Own configuration ($(Split-Path $State.deliveryPath -Leaf))"
    $State.answers.vcs = if ($isAdo) { 'azuredevops' } else { 'github' }
    $State.answers.githubOrg = [string]$inputs['github_organization_name']
    $State.answers.region = [string]$inputs['bootstrap_location']
    $State.answers.iacType = [string]$inputs['iac_type']
    $State.answers.stateBackend = 'azurerm'
    $State.answers.selfHostedRunners = [bool]$inputs['use_self_hosted_runners']
    $State.answers.privateNetworking = [bool]$inputs['use_private_networking']
    $State.answers.applyApprovers = @($inputs['apply_approvers'] | Where-Object { $_ })
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) { $State.answers.subscriptions[$role] = Get-ALZOwnConfigSubscription -Inputs $inputs -Role $role }
    Save-ALZState -State $State

    Write-ALZOwnConfigTarget -Inputs $inputs -Layout $layout -AzureContext $context -SubscriptionNames $names -RecordedVersions $recorded -BootstrapState $bootState

    Write-ALZSection 'Tokens for this session'
    Write-ALZStatus -Status INFO -Message 'Tokens are held in memory for this session only and are never written to disk.'
    $vcsLabel = if ($isAdo) { 'Azure DevOps' } else { 'GitHub' }
    $token = Read-Host -Prompt "  Paste $vcsLabel PAT for bootstrap (input hidden)" -AsSecureString
    $agentsToken = $null
    if ($inputs['use_self_hosted_runners']) {
        $agentsToken = Read-Host -Prompt "  Paste $(if ($isAdo) { 'Azure DevOps Agent Pools' } else { 'GitHub Runner Registration' }) PAT (input hidden)" -AsSecureString
    }

    Write-ALZSection 'Checks before anything runs'
    $plan = $null
    $results = @()
    $results += Test-ALZTooling
    $results += Test-ALZModuleInstalled
    if (-not $isAdo) {
        $plainToken = ConvertTo-ALZPlainText -Secure $token
        try {
            $plan = Get-ALZOwnConfigGitHubPlan -Token $plainToken -Org $inputs['github_organization_name']
            $results += Test-ALZGitHubToken -Token $plainToken -Org $inputs['github_organization_name'] -SelfHostedRunners ([bool]$inputs['use_self_hosted_runners'])
        }
        finally { $plainToken = $null }
    }
    $results += Test-ALZOwnConfig -Inputs $inputs -InputsText (Get-Content -LiteralPath $layout.InputsPath -Raw) -PlatformConfigText (Get-Content -LiteralPath $layout.PlatformConfigPath -Raw) `
        -DefaultTenantId $(if ($context) { $context.tenantId } else { '' }) -ManagementTenantId $managementTenant -GitHubPlan $plan -RecordedVersions $recorded
    $results += Test-ALZOwnConfigAdoption -Layout $layout -BootstrapState $bootState -StateResourceGroupName $rgName -StateResourceGroupExists $rgExists
    Write-ALZResults $results
    $fails = @($results | Where-Object Status -EQ 'FAIL')
    if ($fails.Count -gt 0) {
        Set-ALZPhaseStatus -State $State -Phase 'preflight' -Status 'failed'
        Write-ALZStatus -Status FAIL -Message "$($fails.Count) blocking issue(s). Nothing was run." -Detail 'Fix the configuration or environment, then re-run and choose option 6.'
        return
    }
    Set-ALZPhaseStatus -State $State -Phase 'preflight' -Status 'done'

    Write-ALZSection 'Plan (nothing is applied in this step)'
    Write-Host '  The accelerator runs with an apply guard: it downloads or reuses the pinned modules, writes' -ForegroundColor DarkGray
    Write-Host '  the bootstrap inputs and saves a Terraform plan. Its apply attempts, including its automatic' -ForegroundColor DarkGray
    Write-Host "  retries, then fail with 'flag provided but not defined: $($script:PlanOnlyGuardFlag)'. That is expected." -ForegroundColor DarkGray
    if (-not (Read-ALZConfirm -Prompt 'Run the accelerator in plan-only mode now?' -Default $true)) {
        Write-ALZStatus -Status INFO -Message 'Stopped before planning. Re-run to continue.'
        return
    }
    Install-ALZModuleIfNeeded
    Set-ALZCurrentPhase -State $State -Phase 'bootstrap'
    Add-ALZStat -State $State -Name 'bootstrapRuns'
    $planResult = Invoke-ALZOwnConfigPlan -Layout $layout -Inputs $inputs -VcsToken $token -VcsAgentsToken $agentsToken -DataPath $DataPath
    if (-not $planResult.Succeeded) {
        Remove-ALZOwnConfigPlanFile -PlanPath $planResult.PlanPath
        Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'failed'
        Write-ALZStatus -Status FAIL -Message $planResult.Message -Detail "Transcript: $($planResult.TranscriptPath)"
        foreach ($t in $planResult.MatchedTraps) { Write-ALZRemediation -Title $t.title -Remediation $t.remediation -DocUrl $t.docUrl }
        return
    }
    Write-ALZStatus -Status OK -Message $planResult.Message

    $review = ConvertTo-ALZOwnConfigPlanReview -Plan (Get-ALZOwnConfigPlanJson -BootstrapFolder $planResult.BootstrapFolder)
    Write-ALZOwnConfigPlanReview -Review $review
    if ($review.Changes.Count -eq 0) {
        Remove-ALZOwnConfigPlanFile -PlanPath $planResult.PlanPath
        Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'done'
        Write-ALZStatus -Status OK -Message 'The bootstrap already matches this configuration. Nothing to apply.'
    }
    else {
        if ($review.Blocked) {
            Remove-ALZOwnConfigPlanFile -PlanPath $planResult.PlanPath
            Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'failed'
            Write-ALZStatus -Status FAIL -Message 'The plan contains a blocking change. It was discarded; nothing was applied.'
            return
        }
        $approved = if ($review.Destructive.Count -gt 0) {
            $count = "$($review.Destructive.Count)"
            (Read-ALZValue -Prompt "Type $count to approve the $count destructive change(s), or press Enter to stop" -Default '') -eq $count
        }
        else { Read-ALZConfirm -Prompt 'Apply exactly this reviewed plan now?' -Default $false }
        if (-not $approved) {
            Remove-ALZOwnConfigPlanFile -PlanPath $planResult.PlanPath
            Write-ALZStatus -Status INFO -Message 'Not approved. The plan was discarded; nothing was applied.'
            return
        }
        $apply = Invoke-ALZOwnConfigApply -PlanResult $planResult -Inputs $inputs -VcsToken $token -VcsAgentsToken $agentsToken -ExpectedChanges $review.Changes.Count -DataPath $DataPath
        if (-not $apply.Succeeded) {
            Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'failed'
            if ($apply.Partial) {
                Write-ALZStatus -Status FAIL -Message "Apply reported errors after changing state (serial $($apply.StateBefore.Serial) -> $($apply.StateAfter.Serial)). It is not retried automatically." -Detail "Log: $($apply.LogPath)"
                Write-ALZStatus -Status INFO -Message 'Review the errors, then re-run option 6. The new plan shows exactly what is still outstanding.'
            }
            else {
                Write-ALZStatus -Status FAIL -Message "Apply did not complete (exit $($apply.ExitCode)). It is not retried automatically." -Detail "Log: $($apply.LogPath)"
            }
            foreach ($t in $apply.MatchedTraps) { Write-ALZRemediation -Title $t.title -Remediation $t.remediation -DocUrl $t.docUrl }
            return
        }
        Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'done'
        Write-ALZStatus -Status OK -Message "Bootstrap applied and verified: state serial $($apply.StateBefore.Serial) -> $($apply.StateAfter.Serial), $($apply.StateAfter.ResourceCount) resources."
    }

    $run = Invoke-ALZOwnConfigPipeline -State $State -Inputs $inputs -VcsToken $token
    $token = $null
    $agentsToken = $null
    Write-ALZSection 'Next steps'
    Write-Host '  - Back up the output folder securely; its bootstrap state contains the runner token.' -ForegroundColor Gray
    Write-Host '  - Make platform changes on a branch; review the CI plan on the pull request before merging.' -ForegroundColor Gray
    Write-Host '  - Keep config\ under version control without secrets; it is what a redeploy needs.' -ForegroundColor Gray
    if ($run) { Write-Host "  - Pipeline run: $($run.Url)" -ForegroundColor Gray }
    Write-ALZStatus -Status INFO -Message 'Session finished. State saved.'
}

Export-ModuleMember -Function Get-ALZOwnConfigLayout, Read-ALZOwnConfigInputs, Test-ALZOwnConfig, Get-ALZOwnConfigRecordedVersions, Get-ALZOwnConfigBootstrapFolder, Get-ALZOwnConfigBootstrapState, Get-ALZOwnConfigStateResourceGroupName, Test-ALZOwnConfigAdoption, Invoke-ALZOwnConfigPlan, Get-ALZOwnConfigPlanJson, ConvertTo-ALZOwnConfigPlanReview, Write-ALZOwnConfigPlanReview, Invoke-ALZOwnConfigApply, Invoke-ALZOwnConfigDelivery
