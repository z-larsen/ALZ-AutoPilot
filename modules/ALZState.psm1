###########################################################################
# ALZSTATE.PSM1
# DELIVERY STATE PERSISTENCE AND RESUME
###########################################################################
# Purpose: Persist delivery answers and phase status to a JSON file so a
#          closed terminal or interrupted run can be resumed cleanly.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# Reads and writes .alz-delivery-state.json in the delivery folder:
# 1. Tracks collected answers (region, org, subscriptions, approvers, etc.).
# 2. Tracks per-phase status (pending/done/failed).
# 3. Never stores the GitHub PAT or any secret - those stay session-only.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

$script:StateFileName = '.alz-delivery-state.json'

function Get-ALZStatePath {
    param([string]$DeliveryPath)
    return Join-Path $DeliveryPath $script:StateFileName
}

function New-ALZState {
    param([string]$DeliveryPath)
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{
        version         = '1.0'
        createdUtc      = $now
        updatedUtc      = $now
        deliveryPath    = $DeliveryPath
        currentPhase    = 'interview'
        answers         = [ordered]@{
            deliveryName            = ''
            region                  = ''
            regionSecondary         = ''
            vcs                     = 'github'
            githubOrg               = ''
            adoOrg                  = ''
            adoProject              = ''
            adoCreateProject        = $true
            securityContactEmail    = ''
            subscriptions           = [ordered]@{ management = ''; connectivity = ''; identity = ''; security = '' }
            parentManagementGroupId = ''
            applyApprovers          = @()
            scenario                = 'single-region-virtual-wan-with-azure-firewall'
            iacType                 = 'terraform'
            bicepNetworkType        = 'hubNetworking'
            stateBackend            = 'hcp'
            hcpOrg                  = ''
            hcpWorkspace            = ''
            selfHostedRunners       = $false
            privateNetworking       = $false
        }
        phaseStatus     = [ordered]@{
            interview = 'pending'
            preflight = 'pending'
            config    = 'pending'
            bootstrap = 'pending'
            proof     = 'pending'
            hcp       = 'pending'
            run       = 'pending'
        }
        stats           = [ordered]@{
            sessions      = 0
            bootstrapRuns = 0
            pipelineRuns  = 0
        }
        phaseSeconds    = [ordered]@{}
        phaseStartedUtc = [ordered]@{}
    }
}

function Add-ALZStat {
    param([hashtable]$State, [ValidateSet('sessions', 'bootstrapRuns', 'pipelineRuns')][string]$Name, [int]$By = 1)
    # Older state files predate the stats block.
    if (-not $State.ContainsKey('stats') -or -not $State.stats) {
        $State['stats'] = [ordered]@{ sessions = 0; bootstrapRuns = 0; pipelineRuns = 0 }
    }
    if (-not $State.stats.Contains($Name)) { $State.stats[$Name] = 0 }
    $State.stats[$Name] = [int]$State.stats[$Name] + $By
}

function Get-ALZState {
    param([string]$DeliveryPath)
    $path = Get-ALZStatePath -DeliveryPath $DeliveryPath
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json -AsHashtable
        return $obj
    }
    catch {
        Write-Warning "Could not read state file at $path : $($_.Exception.Message)"
        return $null
    }
}

function Save-ALZState {
    param([hashtable]$State)
    $State.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $path = Get-ALZStatePath -DeliveryPath $State.deliveryPath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
}

function Set-ALZPhaseStatus {
    param(
        [hashtable]$State,
        [string]$Phase,
        [ValidateSet('pending', 'done', 'failed', 'skipped')][string]$Status
    )
    $State.phaseStatus[$Phase] = $Status
    if ($Status -in @('done', 'failed')) { Stop-ALZPhaseTimer -State $State -Phase $Phase }
    Save-ALZState -State $State
}

function Set-ALZCurrentPhase {
    param([hashtable]$State, [string]$Phase)
    $State.currentPhase = $Phase
    Start-ALZPhaseTimer -State $State -Phase $Phase
    Save-ALZState -State $State
}

function Initialize-ALZTiming {
    param([hashtable]$State)
    # Older state files predate timing.
    if (-not $State.ContainsKey('phaseSeconds') -or -not $State.phaseSeconds) { $State['phaseSeconds'] = [ordered]@{} }
    if (-not $State.ContainsKey('phaseStartedUtc') -or -not $State.phaseStartedUtc) { $State['phaseStartedUtc'] = [ordered]@{} }
}

function Start-ALZPhaseTimer {
    param([hashtable]$State, [string]$Phase)
    Initialize-ALZTiming -State $State
    # Keep the original start if the phase is re-entered without completing.
    if (-not $State.phaseStartedUtc[$Phase]) {
        $State.phaseStartedUtc[$Phase] = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Stop-ALZPhaseTimer {
    param([hashtable]$State, [string]$Phase)
    Initialize-ALZTiming -State $State
    $started = $State.phaseStartedUtc[$Phase]
    if (-not $started) { return }
    try {
        $elapsed = ((Get-Date).ToUniversalTime() - [datetime]::Parse($started).ToUniversalTime()).TotalSeconds
        $prior = if ($State.phaseSeconds[$Phase]) { [double]$State.phaseSeconds[$Phase] } else { 0 }
        $State.phaseSeconds[$Phase] = [math]::Round($prior + $elapsed)
    }
    catch { }
    $State.phaseStartedUtc[$Phase] = $null
}

function Test-ALZAnswersComplete {
    param([hashtable]$State)
    $a = $State.answers
    if (-not $a.region -or -not $a.githubOrg -or -not $a.deliveryName) { return $false }
    if (-not $a.subscriptions.management) { return $false }
    if ($a.stateBackend -eq 'hcp' -and (-not $a.hcpOrg -or -not $a.hcpWorkspace)) { return $false }
    return $true
}

Export-ModuleMember -Function Get-ALZStatePath, New-ALZState, Get-ALZState, Save-ALZState, Set-ALZPhaseStatus, Set-ALZCurrentPhase, Test-ALZAnswersComplete, Add-ALZStat, Start-ALZPhaseTimer, Stop-ALZPhaseTimer
