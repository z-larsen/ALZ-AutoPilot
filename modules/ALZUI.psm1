###########################################################################
# ALZUI.PSM1
# CONSOLE UI HELPERS FOR THE ALZ DELIVERY ORCHESTRATOR
###########################################################################
# Purpose: Consistent, ASCII-safe console output - banners, phase progress,
#          status lines, target-state summary, and error remediation panels.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# All user-facing rendering lives here so the rest of the app stays logic-only:
# 1. Banners and section headers.
# 2. Status lines with [OK]/[!!]/[--]/[>>] markers.
# 3. A phase progress tracker (Planning -> Prereqs -> Bootstrap -> Run).
# 4. Target-state summary and error remediation panels.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

$script:PhaseOrder = @('interview', 'preflight', 'config', 'bootstrap', 'proof', 'hcp', 'run', 'complete')
$script:PhaseLabels = @{
    interview = 'Plan (interview)'
    preflight = 'Prerequisites'
    config    = 'Generate config'
    bootstrap = 'Bootstrap'
    proof     = 'Deploy platform'
    hcp       = 'HCP state migration'
    run       = 'Next steps'
    complete  = 'Complete'
}

function Get-ALZRuleWidth {
    # One frame width everywhere, shrunk to fit a narrow console so rules never wrap.
    $w = 74
    try {
        $cw = $Host.UI.RawUI.WindowSize.Width
        if ($cw -gt 10 -and ($cw - 4) -lt $w) { $w = $cw - 4 }
    }
    catch { }
    return [Math]::Max(40, $w)
}

function Write-ALZBell {
    # Audible nudge so a long unattended apply pulls you back to the console.
    try { [Console]::Beep(880, 180); [Console]::Beep(1175, 220) } catch { Write-Host "`a" -NoNewline }
}

function Format-ALZDuration {
    param([double]$Seconds)
    if (-not $Seconds -or $Seconds -lt 1) { return '' }
    $t = [timespan]::FromSeconds([math]::Round($Seconds))
    if ($t.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [int]$t.TotalHours, $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return ('{0}m{1:00}s' -f [int]$t.TotalMinutes, $t.Seconds) }
    return ('{0}s' -f $t.Seconds)
}

function Write-ALZSplash {
    param([string]$Version)
    $line = '=' * (Get-ALZRuleWidth)
    Write-Host ''
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ''
    # Properly kerned figlet mark (letters smush by one column, as real figlet renders them),
    # with the product name set as spaced caps underneath so the two sit in balance.
    Write-Host '       _    _      _____' -ForegroundColor Cyan
    Write-Host '      / \  | |    |__  /' -ForegroundColor Cyan
    Write-Host '     / _ \ | |      / /' -ForegroundColor Cyan
    Write-Host '    / ___ \| |___  / /_' -ForegroundColor Cyan
    Write-Host '   /_/   \_\_____|/____|' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   A U T O P I L O T' -ForegroundColor White
    Write-Host ''
    Write-Host '   Guided automation for the Azure Landing Zone Accelerator' -ForegroundColor Gray
    if ($Version) { Write-Host "   Version $Version" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  What this does' -ForegroundColor White
    Write-Host '  A guided wrapper around the official ALZ Accelerator. It interviews you for' -ForegroundColor Gray
    Write-Host '  the few real decisions, validates prerequisites, generates the config, runs' -ForegroundColor Gray
    Write-Host '  the bootstrap, and walks you through deploying the platform.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  The journey' -ForegroundColor White
    Write-Host '   1. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Plan       ' -ForegroundColor White -NoNewline; Write-Host 'a short interview; answers saved after every step' -ForegroundColor Gray
    Write-Host '   2. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Prereqs    ' -ForegroundColor White -NoNewline; Write-Host 'live checks: tooling, Azure Owner, providers, GitHub, HCP' -ForegroundColor Gray
    Write-Host '   3. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Confirm    ' -ForegroundColor White -NoNewline; Write-Host 'tenant, subscriptions, topology and cost before anything runs' -ForegroundColor Gray
    Write-Host '   4. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Config     ' -ForegroundColor White -NoNewline; Write-Host 'built from the official config for your chosen topology' -ForegroundColor Gray
    Write-Host '   5. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Bootstrap  ' -ForegroundColor White -NoNewline; Write-Host 'runs the accelerator and translates known errors' -ForegroundColor Gray
    Write-Host '   6. ' -ForegroundColor DarkCyan -NoNewline; Write-Host 'Deploy     ' -ForegroundColor White -NoNewline; Write-Host 'triggers + watches the pipeline, or prints a manual runbook' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Good to know' -ForegroundColor White
    Write-Host '   - Terraform (11 scenarios) or Bicep (3 network types), on GitHub or Azure DevOps' -ForegroundColor Gray
    Write-Host '   - State in Azure Storage, or HCP Terraform with the migration verified' -ForegroundColor Gray
    Write-Host '   - Safe: tokens are entered masked and never written to disk' -ForegroundColor Gray
    Write-Host '   - Resumable: re-run with the same delivery folder to pick up where you left off' -ForegroundColor Gray
    Write-Host '   - Requires PowerShell 7.4+ and an Azure CLI sign-in (az login)' -ForegroundColor Gray
    Write-Host ''
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-ALZBanner {
    param([string]$Title, [string]$Subtitle)
    $line = '=' * (Get-ALZRuleWidth)
    Write-Host ''
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor DarkGray }
    Write-Host "  $line" -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-ALZSection {
    param([string]$Title)
    $w = Get-ALZRuleWidth
    Write-Host ''
    Write-Host "  -- $Title " -ForegroundColor White -NoNewline
    Write-Host ('-' * [Math]::Max(3, $w - $Title.Length - 4)) -ForegroundColor DarkGray
}

function Write-ALZStatus {
    param(
        [ValidateSet('OK', 'FAIL', 'WARN', 'INFO', 'RUN')][string]$Status,
        [string]$Message,
        [string]$Detail
    )
    $map = @{
        OK   = @{ Marker = '[ OK ]'; Color = 'Green' }
        FAIL = @{ Marker = '[FAIL]'; Color = 'Red' }
        WARN = @{ Marker = '[WARN]'; Color = 'Yellow' }
        INFO = @{ Marker = '[ .. ]'; Color = 'Gray' }
        RUN  = @{ Marker = '[ >> ]'; Color = 'Cyan' }
    }
    $m = $map[$Status]
    Write-Host $m.Marker -ForegroundColor $m.Color -NoNewline
    Write-Host " $Message"
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

function Write-ALZProgress {
    param([string]$CurrentPhase, [string[]]$SkipPhases = @())
    $current = if ($CurrentPhase) { $CurrentPhase } else { 'interview' }
    $idx = [Array]::IndexOf($script:PhaseOrder, $current)
    Write-Host ''
    Write-Host '  Progress: ' -ForegroundColor DarkGray -NoNewline
    for ($i = 0; $i -lt $script:PhaseOrder.Length; $i++) {
        $p = $script:PhaseOrder[$i]
        if ($p -eq 'complete') { continue }
        $label = $script:PhaseLabels[$p]
        if ($SkipPhases -contains $p) {
            Write-Host "$label (skipped)" -ForegroundColor DarkGray -NoNewline
        }
        elseif ($i -lt $idx) {
            Write-Host "$label" -ForegroundColor Green -NoNewline
        }
        elseif ($i -eq $idx) {
            Write-Host "$label" -ForegroundColor Cyan -NoNewline
        }
        else {
            Write-Host "$label" -ForegroundColor DarkGray -NoNewline
        }
        if ($i -lt $script:PhaseOrder.Length - 2) { Write-Host ' > ' -ForegroundColor DarkGray -NoNewline }
    }
    Write-Host ''
    Write-Host ''
}

function Write-ALZTargetState {
    param([hashtable]$Answers, $AzureContext, $Scenario, [hashtable]$SubscriptionNames = @{})
    $w = Get-ALZRuleWidth
    $inner = $w - 2
    Write-Host ''
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
    Write-Host '  |' -ForegroundColor DarkCyan -NoNewline
    Write-Host (' CONFIRM BEFORE DEPLOYING'.PadRight($inner)) -ForegroundColor Cyan -NoNewline
    Write-Host '|' -ForegroundColor DarkCyan
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan

    $row = { param($k, $v, $c = 'White') Write-Host ('   {0,-24}' -f $k) -ForegroundColor DarkGray -NoNewline; Write-Host $v -ForegroundColor $c }
    $head = { param($t) Write-Host ''; Write-Host "  $t" -ForegroundColor White; Write-Host ('  ' + ('-' * $inner)) -ForegroundColor DarkGray }

    & $head 'Azure context (where this deploys)'
    if ($AzureContext) {
        & $row 'Tenant' "$($AzureContext.tenantId)" 'Yellow'
        if ($AzureContext.user) { & $row 'Signed in as' $AzureContext.user.name }
        & $row 'Bootstrap subscription' "$($AzureContext.name)"
    }
    else {
        & $row 'Tenant' 'could not read az context' 'Yellow'
    }
    & $row 'Parent mgmt group' $(if ($Answers.parentManagementGroupId) { $Answers.parentManagementGroupId } else { 'Tenant Root Group' })

    & $head 'Platform subscriptions'
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = $Answers.subscriptions[$role]
        if ($id) {
            $nm = if ($SubscriptionNames.ContainsKey($id)) { $SubscriptionNames[$id] } else { '' }
            & $row $role $(if ($nm) { "$nm  ($id)" } else { $id })
        }
        else {
            & $row $role '(not supplied - management group created, no subscription placed)' 'DarkYellow'
        }
    }

    & $head 'Delivery choices'
    & $row 'Delivery name' $Answers.deliveryName
    & $row 'IaC language' $(if ($Answers.iacType -eq 'bicep') { 'Bicep' } else { 'Terraform' })
    & $row 'Version control' $(if ($Answers.vcs -eq 'azuredevops') { "Azure DevOps '$($Answers.adoOrg)/$($Answers.adoProject)'" } else { "GitHub org '$($Answers.githubOrg)'" })
    if ($Answers.iacType -eq 'bicep') {
        & $row 'Topology' "network_type: $($Answers.bicepNetworkType)"
    }
    elseif ($Scenario) {
        & $row 'Topology' $Scenario.name
        & $row 'Accelerator scenario' "#$($Scenario.number)"
    }
    else {
        & $row 'Topology' $Answers.scenario
    }
    & $row 'Region(s)' $(if ($Answers.regionSecondary) { "$($Answers.region), $($Answers.regionSecondary)" } else { $Answers.region })
    & $row 'State backend' $(if ($Answers.stateBackend -eq 'hcp') { "HCP Terraform ($($Answers.hcpOrg)/$($Answers.hcpWorkspace), Local mode)" } else { 'Azure Storage (created by bootstrap)' })
    & $row 'Runners' $(if ($Answers.selfHostedRunners) { 'Self-hosted in a VNet (private networking)' } elseif ($Answers.vcs -eq 'azuredevops') { 'Microsoft-hosted agents' } else { 'GitHub-hosted' })
    & $row 'Apply approvers' ($Answers.applyApprovers -join ', ')
    if ($Scenario -and $null -ne $Scenario.estimatedMonthlyUsd) {
        $cost = if ($Scenario.estimatedMonthlyUsd -eq 0) { 'no fixed infrastructure cost' } else { ('~${0:N0} / month' -f $Scenario.estimatedMonthlyUsd) }
        $note = if ($Scenario.excludesNvaLicence) { ' (excludes the NVA licence)' } else { '' }
        & $row 'Est. fixed cost' "$cost$note" $(if ($Scenario.estimatedMonthlyUsd -gt 1000) { 'Yellow' } else { 'Green' })
    }

    & $head 'Management group hierarchy to be created'
    Write-ALZHierarchy -Answers $Answers -SubscriptionNames $SubscriptionNames

    if ($Scenario -and $null -ne $Scenario.estimatedMonthlyUsd -and $Scenario.estimatedMonthlyUsd -gt 0) {
        Write-Host ''
        Write-Host '   Cost is the accelerator''s own published estimate (westus, USD, fixed' -ForegroundColor DarkGray
        Write-Host '   infrastructure only; consumption is extra). Source:' -ForegroundColor DarkGray
        Write-Host '   https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/' -ForegroundColor DarkCyan
        Write-Host '   For another region or currency, run the accelerator''s Get-ScenarioCostEstimates.ps1.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
}

function Write-ALZHierarchy {
    param([hashtable]$Answers, [hashtable]$SubscriptionNames = @{})
    # Mirrors the official ALZ architecture definition (platform/alz in the ALZ Library).
    $parent = if ($Answers.parentManagementGroupId) { $Answers.parentManagementGroupId } else { 'Tenant Root Group' }
    $subFor = {
        param($role)
        $id = $Answers.subscriptions[$role]
        if (-not $id) { return '' }
        $nm = if ($SubscriptionNames.ContainsKey($id)) { $SubscriptionNames[$id] } else { $id }
        return "  <- $nm"
    }
    $connectivity = & $subFor 'connectivity'
    $identity = & $subFor 'identity'
    $management = & $subFor 'management'
    $security = & $subFor 'security'

    $lines = @(
        @{ t = "   $parent"; c = 'DarkGray' },
        @{ t = '   \- alz  (Azure Landing Zones)'; c = 'Cyan' },
        @{ t = '      +- platform'; c = 'White' },
        @{ t = "      |  +- connectivity$connectivity"; c = $(if ($connectivity) { 'Green' } else { 'DarkGray' }) },
        @{ t = "      |  +- identity$identity"; c = $(if ($identity) { 'Green' } else { 'DarkGray' }) },
        @{ t = "      |  +- management$management"; c = $(if ($management) { 'Green' } else { 'DarkGray' }) },
        @{ t = "      |  \- security$security"; c = $(if ($security) { 'Green' } else { 'DarkGray' }) },
        @{ t = '      +- landingzones'; c = 'White' },
        @{ t = '      |  +- corp'; c = 'DarkGray' },
        @{ t = '      |  +- online'; c = 'DarkGray' },
        @{ t = '      |  \- local'; c = 'DarkGray' },
        @{ t = '      +- sandbox'; c = 'DarkGray' },
        @{ t = '      \- decommissioned'; c = 'DarkGray' }
    )
    foreach ($l in $lines) { Write-Host $l.t -ForegroundColor $l.c }
    Write-Host ''
    Write-Host '   Green = a subscription you supplied will be placed here.' -ForegroundColor DarkGray
    Write-Host '   Grey management groups are still created, just left empty.' -ForegroundColor DarkGray
}

function Write-ALZRemediation {
    param(
        [string]$Title,
        [string]$Remediation,
        [string]$DocUrl
    )
    Write-Host ''
    Write-Host '  +-- How to fix ' -ForegroundColor Yellow -NoNewline
    Write-Host ('-' * [Math]::Max(3, (Get-ALZRuleWidth) - 15)) -ForegroundColor DarkGray
    Write-Host "  | $Title" -ForegroundColor Yellow
    foreach ($line in ($Remediation -split "(.{1,66})(?:\s|$)" | Where-Object { $_.Trim() })) {
        Write-Host "  | $($line.Trim())" -ForegroundColor Gray
    }
    if ($DocUrl) { Write-Host "  | Docs: $DocUrl" -ForegroundColor DarkCyan }
    Write-Host '  +--------------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-ALZResults {
    param($Results)
    foreach ($r in @($Results)) {
        Write-ALZStatus -Status $r.Status -Message $r.Name -Detail $r.Detail
        if ($r.Status -in @('FAIL', 'WARN') -and $r.Remediation) {
            Write-ALZRemediation -Title $r.Name -Remediation $r.Remediation -DocUrl $r.DocUrl
        }
    }
}

function Write-ALZSummary {
    param(
        [hashtable]$State,
        $Platform,
        $Run,
        [string[]]$ResourceGroups = @(),
        $Repo,
        [datetime]$SessionStart,
        [string]$ReportPath
    )
    # Deliberately short. The full detail goes to the HTML report so the console
    # ends with the few things worth reading, plus where to find the rest.
    $a = $State.answers
    $w = Get-ALZRuleWidth
    $inner = $w - 2
    Write-Host ''
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
    Write-Host '  |' -ForegroundColor DarkCyan -NoNewline
    Write-Host (' DELIVERY SUMMARY'.PadRight($inner)) -ForegroundColor Cyan -NoNewline
    Write-Host '|' -ForegroundColor DarkCyan
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
    Write-Host ''

    $row = { param($k, $v, $c = 'White') Write-Host ('   {0,-24}' -f $k) -ForegroundColor DarkGray -NoNewline; Write-Host $v -ForegroundColor $c }

    & $row 'Delivery' $a.deliveryName
    & $row 'Topology' $(if ($a.iacType -eq 'bicep') { "Bicep, network_type: $($a.bicepNetworkType)" } else { $a.scenario })
    if ($Repo) { & $row 'Module repo' $Repo.Repo 'Green' }
    if ($Platform) {
        & $row 'Management groups' $Platform.ManagementGroups 'Green'
        & $row 'Policy assignments' $Platform.PolicyAssignments 'Green'
    }

    if ($Run) {
        $concl = if ($Run.Conclusion) { $Run.Conclusion } else { $Run.State }
        & $row 'Last pipeline run' $concl $(if ($concl -eq 'success') { 'Green' } else { 'Yellow' })
    }

    $done = @($script:PhaseOrder | Where-Object { $_ -ne 'complete' -and $State.phaseStatus.$_ -eq 'done' }).Count
    $failedPhases = @($script:PhaseOrder | Where-Object { $_ -ne 'complete' -and $State.phaseStatus.$_ -eq 'failed' })
    $total = @($script:PhaseOrder | Where-Object { $_ -ne 'complete' }).Count
    & $row 'Phases complete' "$done of $total" $(if ($failedPhases.Count) { 'Yellow' } else { 'Green' })
    if ($failedPhases.Count) {
        & $row 'Failed' (($failedPhases | ForEach-Object { $script:PhaseLabels[$_] }) -join ', ') 'Red'
    }
    if ($SessionStart) { & $row 'Session time' ('{0:hh\:mm\:ss}' -f ((Get-Date) - $SessionStart)) }

    if ($ReportPath) {
        Write-Host ''
        Write-Host '   Full detail, including per-phase timings and everything deployed:' -ForegroundColor DarkGray
        Write-Host "   $ReportPath" -ForegroundColor Cyan
    }

    Write-Host ''
    Write-Host ('  +' + ('-' * $inner) + '+') -ForegroundColor DarkCyan
    Write-Host ''
}

function Read-ALZValue {
    param(
        [string]$Prompt,
        [string]$Default,
        [scriptblock]$Validator,
        [string]$ValidationMessage = 'Invalid value, please try again.'
    )
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        Write-Host "  ? $Prompt$suffix : " -ForegroundColor Cyan -NoNewline
        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default) { $answer = $Default }
        if ($Validator -and -not (& $Validator $answer)) {
            Write-ALZStatus -Status WARN -Message $ValidationMessage
            continue
        }
        return $answer
    }
}

function Read-ALZConfirm {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    Write-Host "  ? $Prompt [$hint] : " -ForegroundColor Cyan -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^(y|yes)$'
}

Export-ModuleMember -Function Write-ALZSplash, Write-ALZBanner, Write-ALZSection, Write-ALZStatus, Write-ALZProgress, Write-ALZTargetState, Write-ALZHierarchy, Write-ALZRemediation, Write-ALZResults, Write-ALZSummary, Write-ALZBell, Format-ALZDuration, Read-ALZValue, Read-ALZConfirm
