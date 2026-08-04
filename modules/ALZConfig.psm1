###########################################################################
# ALZCONFIG.PSM1
# INTERVIEW AND CONFIG-FILE GENERATION
###########################################################################
# Purpose: Ask only the decisions that matter, validate them inline, and
#          generate inputs.yaml plus the platform config for the chosen
#          topology so the operator never hand-edits scattered files or hits
#          template-token traps.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# 1. Invoke-ALZInterview collects and validates every answer.
# 2. Write-ALZInputsYaml renders the accelerator inputs.yaml.
# 3. Write-ALZStarterTfvars copies the official config for the chosen
#    Terraform scenario; Write-ALZBicepConfig does the same for Bicep.
# The GitHub PAT is never collected here or written to disk - it is read
# masked at bootstrap time and set only as a session env var.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

function Test-ALZRegionName { param([string]$v) return $v -match '^[a-z][a-z0-9]+$' }
function Test-ALZGuid { param([string]$v) [guid]::TryParse($v, [ref]([guid]::Empty)) }
function Test-ALZGuidOrEmpty { param([string]$v) return ([string]::IsNullOrWhiteSpace($v) -or (Test-ALZGuid $v)) }
function Test-ALZGitHubName { param([string]$v) return $v -match '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$' }
function Test-ALZNotEmpty { param([string]$v) return -not [string]::IsNullOrWhiteSpace($v) }
function Test-ALZEmail { param([string]$v) return $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' }

function Invoke-ALZInterview {
    param([hashtable]$State, [string]$DataPath)
    $a = $State.answers

    Write-Host ''
    Write-Host '  Answer a few questions. Press Enter to accept a [default].' -ForegroundColor DarkGray
    Write-Host '  Values are saved after each step, so you can stop and resume anytime.' -ForegroundColor DarkGray

    $a.deliveryName = Read-ALZValue -Prompt 'Delivery / tenant name (used for the output folder)' -Default $(if ($a.deliveryName) { $a.deliveryName } else { 'My Tenant' }) -Validator ${function:Test-ALZNotEmpty}
    $a.region = Read-ALZValue -Prompt 'Primary Azure region (e.g. southcentralus)' -Default $a.region -Validator ${function:Test-ALZRegionName} -ValidationMessage 'Use the lowercase region name, e.g. eastus2 or southcentralus.'
    $a.githubOrg = Read-ALZValue -Prompt 'GitHub organization name' -Default $a.githubOrg -Validator ${function:Test-ALZGitHubName} -ValidationMessage 'Enter a valid GitHub org name (letters, numbers, hyphens).'

    Write-ALZSection 'Platform subscriptions (GUIDs)'
    Write-Host '  Four separate subscriptions are recommended. Management and Connectivity are' -ForegroundColor DarkGray
    Write-Host '  required; Identity and Security are recommended and can be added later (the' -ForegroundColor DarkGray
    Write-Host '  documented SMB pattern starts with just the two required ones).' -ForegroundColor DarkGray
    Write-Host '  Each subscription can fill only one role - do not reuse one for two roles.' -ForegroundColor DarkGray
    do {
        $a.subscriptions.management = Read-ALZValue -Prompt 'Management subscription ID (required)' -Default $a.subscriptions.management -Validator ${function:Test-ALZGuid} -ValidationMessage 'Enter a valid subscription GUID.'
        $a.subscriptions.connectivity = Read-ALZValue -Prompt 'Connectivity subscription ID (required)' -Default $a.subscriptions.connectivity -Validator ${function:Test-ALZGuid} -ValidationMessage 'Enter a valid subscription GUID.'
        $a.subscriptions.identity = Read-ALZValue -Prompt 'Identity subscription ID (recommended, Enter to skip)' -Default $a.subscriptions.identity -Validator ${function:Test-ALZGuidOrEmpty} -ValidationMessage 'Enter a valid GUID or leave blank.'
        $a.subscriptions.security = Read-ALZValue -Prompt 'Security subscription ID (recommended, Enter to skip)' -Default $a.subscriptions.security -Validator ${function:Test-ALZGuidOrEmpty} -ValidationMessage 'Enter a valid GUID or leave blank.'

        # The starter module rejects a subscription ID that appears more than once in
        # subscription_placement, so catch it here instead of 20 minutes into the pipeline.
        $used = @($a.subscriptions.management, $a.subscriptions.connectivity, $a.subscriptions.identity, $a.subscriptions.security) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $dupes = @($used | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($dupes.Count -gt 0) {
            Write-ALZStatus -Status FAIL -Message 'The same subscription is assigned to more than one platform role.' -Detail "Repeated: $($dupes -join ', '). The deployment rejects a subscription used twice. Leave the optional roles blank rather than reusing a subscription."
        }
    } while ($dupes.Count -gt 0)

    Write-ALZSection 'Management group and approvers'
    $a.parentManagementGroupId = Read-ALZValue -Prompt 'Parent management group ID (Enter for Tenant Root Group)' -Default $a.parentManagementGroupId -Validator { param($v) [string]::IsNullOrWhiteSpace($v) -or $v -match '^[A-Za-z0-9._()-]{1,90}$' } -ValidationMessage 'Use letters, numbers, and . _ - ( ) only, or leave blank for Tenant Root Group.'
    $approvers = Read-ALZValue -Prompt 'Apply approvers (comma-separated GitHub usernames)' -Default ($a.applyApprovers -join ',') -Validator {
        param($v)
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        $names = $v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if (-not $names) { return $false }
        return @($names | Where-Object { $_ -notmatch '^[A-Za-z0-9-]{1,39}$' }).Count -eq 0
    } -ValidationMessage 'Each approver must be a valid GitHub username (letters, numbers, hyphens; max 39).'
    $a.applyApprovers = @($approvers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $a.securityContactEmail = Read-ALZValue -Prompt 'Microsoft Defender security contact email' -Default $a.securityContactEmail -Validator ${function:Test-ALZEmail} -ValidationMessage 'Enter a valid email address.'

    Write-ALZSection 'State backend'
    Write-Host '  HCP Terraform (Local mode) stores state in HCP while GitHub Actions runs Terraform.' -ForegroundColor DarkGray
    Write-Host '  Answer No to use the accelerator default: an Azure Storage backend it creates for you.' -ForegroundColor DarkGray
    $useHcp = Read-ALZConfirm -Prompt 'Use HCP Terraform for state? (No = Azure Storage, skips the HCP step)' -Default $($a.stateBackend -eq 'hcp')
    if ($useHcp) {
        $a.stateBackend = 'hcp'
        $a.hcpOrg = Read-ALZValue -Prompt 'HCP organization name' -Default $a.hcpOrg -Validator ${function:Test-ALZNotEmpty}
        $a.hcpWorkspace = Read-ALZValue -Prompt 'HCP workspace name' -Default $(if ($a.hcpWorkspace) { $a.hcpWorkspace } else { 'alz-platform-greenfield' }) -Validator ${function:Test-ALZNotEmpty}
    }
    else {
        $a.stateBackend = 'azurerm'
    }

    Write-ALZSection 'Infrastructure as code language'
    Write-Host '  Terraform offers 11 pre-built topology scenarios. Bicep offers three network types' -ForegroundColor DarkGray
    Write-Host '  and is customized by editing the generated Bicep after bootstrap.' -ForegroundColor DarkGray
    Write-Host '  Either way the bootstrap itself runs on Terraform; this choice is what deploys' -ForegroundColor DarkGray
    Write-Host '  and maintains the platform landing zone afterwards.' -ForegroundColor DarkGray
    Write-Host '    1. Terraform' -ForegroundColor White
    Write-Host '    2. Bicep' -ForegroundColor White
    $iacPick = Read-ALZValue -Prompt 'Choose the IaC language (1/2)' -Default $(if ($a.iacType -eq 'bicep') { '2' } else { '1' }) -Validator { param($v) $v -in @('1', '2') }
    $a.iacType = if ($iacPick -eq '2') { 'bicep' } else { 'terraform' }

    if ($a.iacType -eq 'bicep') {
        Write-ALZSection 'Target topology (your end-state deployment)'
        Write-Host '  Bicep deploys one of three network types. Management groups, policy, and' -ForegroundColor DarkGray
        Write-Host '  management resources deploy in all three.' -ForegroundColor DarkGray
        $netTypes = @(
            @{ key = 'none'; label = 'Management groups, policy and management resources only (no networking)'; cost = 'minimal' },
            @{ key = 'hubNetworking'; label = 'Hub and spoke virtual network'; cost = 'high' },
            @{ key = 'vwanConnectivity'; label = 'Virtual WAN'; cost = 'high' }
        )
        for ($n = 0; $n -lt $netTypes.Count; $n++) {
            Write-Host ('    {0}. {1}' -f ($n + 1), $netTypes[$n].label) -ForegroundColor White
            Write-Host ('        network_type = {0}, cost: {1}' -f $netTypes[$n].key, $netTypes[$n].cost) -ForegroundColor DarkGray
        }
        $curNet = [Array]::IndexOf(($netTypes | ForEach-Object { $_.key }), $a.bicepNetworkType)
        $netPick = Read-ALZValue -Prompt 'Choose the network type (1-3)' -Default $(if ($curNet -ge 0) { ($curNet + 1).ToString() } else { '1' }) -Validator { param($v) $v -match '^[123]$' }
        $a.bicepNetworkType = $netTypes[[int]$netPick - 1].key
        # The Bicep example config always ships two regions; a second is required.
        $a.regionSecondary = Read-ALZValue -Prompt 'Secondary Azure region (Bicep config expects two)' -Default $a.regionSecondary -Validator {
            param($v) (Test-ALZRegionName $v) -and $v -ne $a.region
        } -ValidationMessage 'Use a lowercase region name that differs from the primary region.'
        Write-ALZStatus -Status INFO -Message 'Bicep also requires User Access Administrator at the root (/) scope.' -Detail 'This is a Bicep-only prerequisite. See the accelerator Root Access guidance.'
    }
    else {
        Write-ALZSection 'Target topology (your end-state deployment)'
        Write-Host '  "acc #" is the accelerator''s own scenario number, for cross-referencing the docs.' -ForegroundColor DarkGray
        $catalog = @((Get-Content -Path (Join-Path $DataPath 'scenarios.json') -Raw | ConvertFrom-Json).scenarios)
        $lastGroup = ''
        $i = 1
        foreach ($s in $catalog) {
            if ($s.group -ne $lastGroup) {
                Write-Host ("  {0}:" -f $s.group) -ForegroundColor Cyan
                $lastGroup = $s.group
            }
            Write-Host ('    {0,2}. {1}' -f $i, $s.name) -ForegroundColor White
            Write-Host ('        acc #{0}, cost: {1}, regions: {2}' -f $s.number, $s.costTier, $s.regions) -ForegroundColor DarkGray
            $i++
        }
        $currentIdx = [Array]::IndexOf(($catalog | ForEach-Object { $_.key }), $a.scenario)
        $default = if ($currentIdx -ge 0) { ($currentIdx + 1).ToString() } else { '3' }
        $pick = Read-ALZValue -Prompt "Choose target topology (1-$($catalog.Count))" -Default $default -Validator { param($v) $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $catalog.Count }
        $a.scenario = $catalog[[int]$pick - 1].key

        # Multi-region scenarios need a second location; without it the generated
        # starter_locations list is short and the deployment fails.
        $chosen = $catalog[[int]$pick - 1]
        if ($chosen.regions -eq 'multi') {
            Write-Host '  This scenario deploys to two regions.' -ForegroundColor DarkGray
            $a.regionSecondary = Read-ALZValue -Prompt 'Secondary Azure region' -Default $a.regionSecondary -Validator {
                param($v) (Test-ALZRegionName $v) -and $v -ne $a.region
            } -ValidationMessage 'Use a lowercase region name that differs from the primary region.'
        }
        else {
            $a.regionSecondary = ''
        }
    }

    Write-ALZSection 'Runner and network security'
    Write-Host '  Many governed tenants enforce a policy that disables public network access on' -ForegroundColor DarkGray
    Write-Host '  storage. The Terraform state store is then reachable only over a private endpoint,' -ForegroundColor DarkGray
    Write-Host '  so the pipeline must run on self-hosted runners inside a VNet. Turning this on has' -ForegroundColor DarkGray
    Write-Host '  the accelerator deploy a VNet, private endpoint, container registry, and container-' -ForegroundColor DarkGray
    Write-Host '  based runners, and it needs a second GitHub PAT (Runner Registration) at bootstrap.' -ForegroundColor DarkGray
    $secure = Read-ALZConfirm -Prompt 'Use private networking + self-hosted runners? (recommended for policy-governed tenants)' -Default ([bool]$a.privateNetworking)
    $a.privateNetworking = $secure
    $a.selfHostedRunners = $secure

    Set-ALZPhaseStatus -State $State -Phase 'interview' -Status 'done'
    return $State
}

function Write-ALZInputsYaml {
    param([hashtable]$State, [string]$ConfigFolder)
    $a = $State.answers
    if (-not (Test-Path $ConfigFolder)) { New-Item -ItemType Directory -Path $ConfigFolder -Force | Out-Null }
    $path = Join-Path $ConfigFolder 'inputs.yaml'

    # Defense in depth: strip characters that could break a double-quoted YAML scalar,
    # even though every value is already validated at interview time.
    $san = { param($v) if ($null -eq $v) { '' } else { ($v -replace '["\r\n\\]', '').Trim() } }
    $region = & $san $a.region
    $parentMg = if ($a.parentManagementGroupId) { & $san $a.parentManagementGroupId } else { '' }
    $org = & $san $a.githubOrg
    $subMgmt = & $san $a.subscriptions.management
    $subIdentity = & $san $a.subscriptions.identity
    $subConn = & $san $a.subscriptions.connectivity
    $subSec = & $san $a.subscriptions.security

    # Only emit subscriptions that have a value. A blank entry still reaches the starter
    # module's subscription_placement, where it fails validation twice: it is not a valid
    # UUID, and two blanks count as the same ID specified more than once.
    $subLines = @()
    foreach ($pair in @(@('management', $subMgmt), @('identity', $subIdentity), @('connectivity', $subConn), @('security', $subSec))) {
        if (-not [string]::IsNullOrWhiteSpace($pair[1])) { $subLines += "  $($pair[0]): `"$($pair[1])`"" }
    }
    $subscriptionIds = $subLines -join "`n"
    $approvers = ($a.applyApprovers | ForEach-Object { "`"$(& $san $_)`"" }) -join ', '
    $selfHosted = if ($a.selfHostedRunners) { 'true' } else { 'false' }
    $privateNet = if ($a.privateNetworking) { 'true' } else { 'false' }
    $iac = if ($a.iacType -eq 'bicep') { 'bicep' } else { 'terraform' }
    # When self-hosted runners are enabled the runner-registration PAT (token-2) is supplied
    # via env var at bootstrap time, mirroring the main PAT - it is never written to disk.
    $runnersToken = if ($a.selfHostedRunners) { 'Set via environment variable TF_VAR_github_runners_personal_access_token' } else { '' }

    # A custom ALZ library (custom management groups, archetypes, policy definitions and
    # assignments) lives in <config>\lib. Passing explicit config paths disables the
    # accelerator's auto-discovery, so the folder has to be declared here or it is ignored.
    $libPath = Join-Path $ConfigFolder 'lib'
    $additionalFiles = ''
    if (Test-Path $libPath) {
        $libYaml = ($libPath -replace '\\', '/')
        $additionalFiles = "`nstarter_additional_files: [`"$libYaml`"]"
    }

    $yaml = @"
---
# Generated by the ALZ Delivery Orchestrator. Safe to edit.
# The GitHub PAT is NOT stored here - it is supplied via the
# TF_VAR_github_personal_access_token environment variable at bootstrap time.

bootstrap_location: "$region"

root_parent_management_group_id: "$parentMg"

subscription_ids:
$subscriptionIds

bootstrap_subscription_id: "$subMgmt"

service_name: "alz"
environment_name: "mgmt"
postfix_number: 1

use_self_hosted_runners: $selfHosted
use_private_networking: $privateNet

github_personal_access_token: "Set via environment variable TF_VAR_github_personal_access_token"
github_runners_personal_access_token: "$runnersToken"
github_organization_name: "$org"
apply_approvers: [$approvers]

iac_type: "$iac"
bootstrap_module_name: "alz_github"
starter_module_name: "platform_landing_zone"$additionalFiles
"@
    $yaml | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Set-ALZTfvarsRegion {
    param([string]$TfvarsPath, [string]$Region, [string]$SecondaryRegion, [string]$SecurityContactEmail)
    if (-not (Test-Path $TfvarsPath)) { return $false }
    $content = Get-Content -Path $TfvarsPath -Raw

    if ($content -match 'starter_locations\s*=\s*\[([^\]]*)\]') {
        # Ignore template tokens and the shipped <region-N> placeholders: neither is a real
        # region, so they must not count as an existing list worth preserving.
        $existing = @($matches[1] -split ',' | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\$\{' -and $_ -notmatch '<region-' })
        $wanted = @($Region)
        if ($SecondaryRegion) { $wanted += $SecondaryRegion }
        # Never shrink a multi-region list we cannot fully populate: a scenario swapped in
        # by hand would otherwise be silently reduced to one region and stop deploying.
        if ($wanted.Count -ge $existing.Count -or $existing.Count -le 1) {
            $list = ($wanted | ForEach-Object { "`"$_`"" }) -join ', '
            $content = $content -replace 'starter_locations\s*=\s*\[[^\]]*\]', "starter_locations = [$list]"
        }
    }

    if ($SecurityContactEmail) {
        $content = $content -replace 'replace_me@replace_me\.com', $SecurityContactEmail
    }
    $content | Set-Content -Path $TfvarsPath -Encoding UTF8
    return $true
}

function Set-ALZTfvarsSubscriptionPlacement {
    param([string]$TfvarsPath, $Subscriptions)
    if (-not (Test-Path $TfvarsPath)) { return $false }
    $content = Get-Content -Path $TfvarsPath -Raw
    $i = $content.IndexOf('subscription_placement')
    if ($i -lt 0) { return $false }
    $open = $content.IndexOf('{', $i)
    if ($open -lt 0) { return $false }

    # Walk braces to find the end of the block so nested role objects are handled.
    $depth = 0; $end = -1
    for ($p = $open; $p -lt $content.Length; $p++) {
        if ($content[$p] -eq '{') { $depth++ }
        elseif ($content[$p] -eq '}') { $depth--; if ($depth -eq 0) { $end = $p; break } }
    }
    if ($end -lt 0) { return $false }

    # Only place subscriptions that exist. A role left blank resolves to an empty
    # subscription_id, which fails the module's UUID and uniqueness validation.
    $entries = @()
    foreach ($role in @('identity', 'connectivity', 'management', 'security')) {
        if (-not [string]::IsNullOrWhiteSpace($Subscriptions.$role)) {
            $entries += "    $role = {`n      subscription_id       = `"`$`${subscription_id_$role}`"`n      management_group_name = `"$role`"`n    }"
        }
    }
    $block = "{`n" + ($entries -join "`n") + "`n  }"
    ($content.Substring(0, $open) + $block + $content.Substring($end + 1)) | Set-Content -Path $TfvarsPath -Encoding UTF8
    return $true
}

function Write-ALZBicepConfig {
    param([hashtable]$State, [string]$ConfigFolder, [string]$DataPath)
    $a = $State.answers
    # The state file is on disk and hand-editable, so constrain anything that reaches
    # a file path or generated config rather than trusting it.
    if ($a.bicepNetworkType -notin @('none', 'hubNetworking', 'vwanConnectivity')) {
        throw "Invalid Bicep network type '$($a.bicepNetworkType)'."
    }
    if (-not (Test-ALZRegionName $a.region)) { throw "Invalid region '$($a.region)'." }
    if ($a.regionSecondary -and -not (Test-ALZRegionName $a.regionSecondary)) { throw "Invalid secondary region '$($a.regionSecondary)'." }
    if (-not (Test-Path $ConfigFolder)) { New-Item -ItemType Directory -Path $ConfigFolder -Force | Out-Null }
    $path = Join-Path $ConfigFolder 'platform-landing-zone.yaml'
    $source = Join-Path $DataPath 'scenarios-bicep\platform-landing-zone.yaml'

    if (-not (Test-Path $path)) {
        if (-not (Test-Path $source)) { throw "Bundled Bicep configuration not found: $source" }
        Copy-Item -LiteralPath $source -Destination $path -Force
    }

    # Patch only the values the interview owns so hand edits survive a re-run.
    $content = Get-Content -Path $path -Raw
    $regions = @("`"$($a.region)`"")
    if ($a.regionSecondary) { $regions += "`"$($a.regionSecondary)`"" }
    $content = $content -replace 'starter_locations\s*:\s*\[[^\]]*\]', "starter_locations: [$($regions -join ', ')]"
    $content = $content -replace 'network_type\s*:\s*"[^"]*"', "network_type: `"$($a.bicepNetworkType)`""
    $content | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Write-ALZStarterTfvars {
    param([hashtable]$State, [string]$ConfigFolder, [string]$DataPath)
    $a = $State.answers
    if (-not (Test-Path $ConfigFolder)) { New-Item -ItemType Directory -Path $ConfigFolder -Force | Out-Null }
    $tfvarsPath = Join-Path $ConfigFolder 'platform-landing-zone.tfvars'
    $email = if ($a.securityContactEmail) { $a.securityContactEmail } else { 'security@example.com' }
    # Scenario comes from the on-disk state file and is used to build a path, so keep it
    # to a plain key and require the bundled file to exist.
    if ($a.scenario -notmatch '^[a-z0-9-]+$') { throw "Invalid scenario key '$($a.scenario)'." }
    $source = Join-Path $DataPath "scenarios\$($a.scenario).tfvars"

    if (Test-Path $tfvarsPath) {
        # Re-run: patch the values we own and leave everything else alone, because the
        # tfvars is the file customers are expected to hand-edit.
        Set-ALZTfvarsRegion -TfvarsPath $tfvarsPath -Region $a.region -SecondaryRegion $a.regionSecondary -SecurityContactEmail $email | Out-Null
        Set-ALZTfvarsSubscriptionPlacement -TfvarsPath $tfvarsPath -Subscriptions $a.subscriptions | Out-Null
        return $tfvarsPath
    }

    if (-not (Test-Path $source)) {
        throw "No bundled configuration for scenario '$($a.scenario)'. Expected: $source"
    }
    Copy-Item -LiteralPath $source -Destination $tfvarsPath -Force
    Set-ALZTfvarsRegion -TfvarsPath $tfvarsPath -Region $a.region -SecondaryRegion $a.regionSecondary -SecurityContactEmail $email | Out-Null
    Set-ALZTfvarsSubscriptionPlacement -TfvarsPath $tfvarsPath -Subscriptions $a.subscriptions | Out-Null
    return $tfvarsPath
}

function Test-ALZTfvarsMatchesScenario {
    param([string]$TfvarsPath, [string]$Scenario, [string]$DataPath)
    # A scenario change needs a different base file, but the existing one may hold user
    # edits, so the caller decides whether to replace it.
    if ($Scenario -notmatch '^[a-z0-9-]+$') { return $true }
    $source = Join-Path $DataPath "scenarios\$Scenario.tfvars"
    if (-not (Test-Path $TfvarsPath) -or -not (Test-Path $source)) { return $true }
    $current = Get-Content -Path $TfvarsPath -Raw
    $marker = if ($current -match 'connectivity_type\s*=\s*"([^"]+)"') { $matches[1] } else { $null }
    $expected = if ((Get-Content -Path $source -Raw) -match 'connectivity_type\s*=\s*"([^"]+)"') { $matches[1] } else { $null }
    return ($marker -eq $expected)
}

Export-ModuleMember -Function Invoke-ALZInterview, Write-ALZInputsYaml, Set-ALZTfvarsRegion, Set-ALZTfvarsSubscriptionPlacement, Write-ALZStarterTfvars, Test-ALZTfvarsMatchesScenario, Write-ALZBicepConfig
