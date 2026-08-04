###########################################################################
# START-ALZDELIVERY.PS1
# ALZ AUTOPILOT - GUIDED AUTOMATION FOR THE ALZ ACCELERATOR
###########################################################################
# Purpose: One entry point that interviews for the few real decisions, runs
#          all prerequisite checks with exact fixes, generates the config,
#          orchestrates the real Deploy-Accelerator run, and resumes cleanly
#          after an interruption. Same accelerator, better presentation.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator customer delivery
#
# Description:
# Wraps the official ALZ accelerator without changing what it does:
# 1. Plan - short interview, answers saved after every step.
# 2. Prerequisites - tooling, Azure Owner, resource providers, GitHub, HCP.
# 3. Generate config - writes inputs.yaml (no hand-editing scattered files).
# 4. Bootstrap - runs Deploy-Accelerator and translates known errors.
# 5. Guided next steps - HCP state migration and Phase 3 topology deploy.
#
# ── Parameters ──────────────────────────────────────────────
# DeliveryPath       Root folder for this delivery's config/output/state
# Reset              Start over, ignoring any existing saved state
# SkipPreflight      Jump straight to config/bootstrap (not recommended)
# NoClear            Keep existing console output instead of clearing on start
#
# Prerequisites:
# - PowerShell 7.4+, Azure CLI signed in (az login)
# - A GitHub organization and a fine-grained PAT (entered masked, never stored)
#
# Usage: .\Start-ALZDelivery.ps1 -DeliveryPath "C:\...\ALZ\My Tenant"
###########################################################################

#requires -Version 7.4

[CmdletBinding()]
param(
    [string]$DeliveryPath,
    [switch]$Reset,
    [switch]$SkipPreflight,
    [switch]$NoClear
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dataPath = Join-Path $root 'data'
$modulePath = Join-Path $root 'modules'

Import-Module (Join-Path $modulePath 'ALZUI.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZSecurity.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZState.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZPreflight.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZConfig.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZOrchestrator.psm1') -Force
Import-Module (Join-Path $modulePath 'ALZPipeline.psm1') -Force

if (-not $NoClear) { try { Clear-Host } catch { } }
Write-ALZSplash -Version '1.0.0'

$sessionStart = Get-Date
# Collected through the run and rendered in the closing summary.
$summaryRepo = $null
$summaryRun = $null
$summaryPlatform = $null

# ---- Resolve the delivery path -----------------------------------------
if (-not $DeliveryPath) {
    $DeliveryPath = Read-ALZValue -Prompt 'Delivery folder full path (holds config, output, and saved state)' -Validator { param($v) -not [string]::IsNullOrWhiteSpace($v) }
}
if ($DeliveryPath -match '(^|[\\/])\.\.\.([\\/]|$)') {
    Write-ALZStatus -Status FAIL -Message 'That path contains "...", which is a copied placeholder.' -Detail 'Use the real full path, e.g. "C:\Users\you\...\ALZ DeploymentAccelerator\My Tenant".'
    return
}
# Resolve to an absolute path without requiring it to exist yet.
$DeliveryPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DeliveryPath)
# Cloud-synced folders break the accelerator: fileset() returns inconsistent results
# (empty/partial repo pushes) and files get locked mid-run.
if ($DeliveryPath -match 'OneDrive|Dropbox|Google Drive|Box\b|iCloud') {
    Write-ALZStatus -Status WARN -Message 'The delivery folder is inside a cloud-synced folder (OneDrive/Dropbox/etc.).'
    Write-ALZRemediation -Title 'Cloud-synced path breaks the accelerator' -Remediation 'The accelerator enumerates the module with Terraform fileset(); on a synced folder that returns inconsistent results, so the module and workflows fail to push (empty repos). Use a plain local path such as C:\ALZ\<name> instead.' -DocUrl ''
    if (-not (Read-ALZConfirm -Prompt 'Continue anyway (not recommended)?' -Default $false)) {
        Write-ALZStatus -Status INFO -Message 'Re-run with -DeliveryPath set to a local (non-synced) folder, e.g. C:\ALZ\MyTenant.'
        return
    }
}
$parent = Split-Path $DeliveryPath -Parent
if (-not (Test-Path $parent)) {
    Write-ALZStatus -Status FAIL -Message 'The parent folder does not exist.' -Detail "Parent: $parent. Check the path and try again."
    return
}
if (-not (Test-Path $DeliveryPath)) {
    New-Item -ItemType Directory -Path $DeliveryPath -Force | Out-Null
    Write-ALZStatus -Status INFO -Message "Created delivery folder: $DeliveryPath"
}
else {
    Write-ALZStatus -Status INFO -Message "Using delivery folder: $DeliveryPath"
}

# ---- Load or initialize state ------------------------------------------
$state = $null
if (-not $Reset) { $state = Get-ALZState -DeliveryPath $DeliveryPath }
if ($state) {
    $skip = @(); if ($state.answers.stateBackend -ne 'hcp') { $skip = @('hcp') }
    Write-ALZStatus -Status OK -Message 'Found saved delivery state - resuming.' -Detail "Last updated $($state.updatedUtc)"
    Write-ALZProgress -CurrentPhase $state.currentPhase -SkipPhases $skip
    if (-not (Read-ALZConfirm -Prompt 'Resume this delivery?' -Default $true)) {
        if (Read-ALZConfirm -Prompt 'Start over from scratch (discards saved answers)?' -Default $false) {
            $state = New-ALZState -DeliveryPath $DeliveryPath
            Save-ALZState -State $state
        }
    }
}
else {
    $state = New-ALZState -DeliveryPath $DeliveryPath
    Save-ALZState -State $state
    Write-ALZStatus -Status INFO -Message 'Started a new delivery.'
}
$skip = @(); if ($state.answers.stateBackend -ne 'hcp') { $skip = @('hcp') }

Add-ALZStat -State $state -Name 'sessions'
Save-ALZState -State $state

# ---- Phase: Interview --------------------------------------------------
if (-not (Test-ALZAnswersComplete -State $state) -or $state.phaseStatus.interview -ne 'done') {
    Set-ALZCurrentPhase -State $state -Phase 'interview'
    Write-ALZProgress -CurrentPhase 'interview' -SkipPhases $skip
    $state = Invoke-ALZInterview -State $state -DataPath $dataPath
    Save-ALZState -State $state
}

# Resolve live Azure context and friendly subscription names so the confirmation shows
# where this is really going, not just the GUIDs that were typed in.
function Get-ALZConfirmContext {
    param([hashtable]$State, [string]$DataPath)
    $ctx = $null
    try { $ctx = az account show -o json 2>$null | ConvertFrom-Json } catch { }
    $names = @{}
    try {
        $all = az account list --all -o json 2>$null | ConvertFrom-Json
        foreach ($s in $all) { $names[$s.id] = $s.name }
    }
    catch { }
    $scenario = $null
    if ($State.answers.iacType -ne 'bicep') {
        try {
            $scenario = (Get-Content -Path (Join-Path $DataPath 'scenarios.json') -Raw | ConvertFrom-Json).scenarios |
                Where-Object { $_.key -eq $State.answers.scenario } | Select-Object -First 1
        }
        catch { }
    }
    return @{ Context = $ctx; Names = $names; Scenario = $scenario }
}

$confirm = Get-ALZConfirmContext -State $state -DataPath $dataPath
Write-ALZTargetState -Answers $state.answers -AzureContext $confirm.Context -Scenario $confirm.Scenario -SubscriptionNames $confirm.Names
if (-not (Read-ALZConfirm -Prompt 'Is everything above correct?' -Default $true)) {
    $state = Invoke-ALZInterview -State $state -DataPath $dataPath
    Save-ALZState -State $state
    $confirm = Get-ALZConfirmContext -State $state -DataPath $dataPath
    Write-ALZTargetState -Answers $state.answers -AzureContext $confirm.Context -Scenario $confirm.Scenario -SubscriptionNames $confirm.Names
}

# Recompute skip after the interview and record HCP as explicitly skipped when not used.
$skip = @()
if ($state.answers.stateBackend -ne 'hcp') {
    $skip = @('hcp')
    if ($state.phaseStatus.hcp -ne 'skipped') { Set-ALZPhaseStatus -State $state -Phase 'hcp' -Status 'skipped' }
}
elseif ($state.phaseStatus.hcp -eq 'skipped') {
    Set-ALZPhaseStatus -State $state -Phase 'hcp' -Status 'pending'
}

# ---- Phase: Preflight --------------------------------------------------
$runPreflight = -not $SkipPreflight
if ($runPreflight -and $state.phaseStatus.preflight -eq 'done') {
    $runPreflight = Read-ALZConfirm -Prompt 'Preflight passed on a previous run. Re-run the checks?' -Default $false
}
if ($runPreflight) {
    Set-ALZCurrentPhase -State $state -Phase 'preflight'
    Write-ALZProgress -CurrentPhase 'preflight' -SkipPhases $skip
    Write-ALZSection 'Running prerequisite checks'

    do {
        $results = @()

        Write-ALZStatus -Status RUN -Message 'Checking local tooling (PowerShell 7.4+, Azure CLI, Git)...'
        $r = Test-ALZTooling; Write-ALZResults $r; $results += $r

        Write-ALZStatus -Status RUN -Message 'Checking the ALZ PowerShell module...'
        $r = Test-ALZModuleInstalled; Write-ALZResults $r; $results += $r

        Write-ALZStatus -Status RUN -Message 'Checking Azure sign-in and subscription context...'
        $r = Test-ALZAzureLogin -ExpectedManagementSub $state.answers.subscriptions.management; Write-ALZResults $r; $results += $r

        Write-ALZStatus -Status RUN -Message 'Checking Owner access on the platform subscriptions...'
        $r = Test-ALZSubscriptionAccess -Subscriptions $state.answers.subscriptions; Write-ALZResults $r; $results += $r

        $providers = Get-ALZProviderList -DataPath $dataPath
        Write-ALZStatus -Status RUN -Message "Checking $($providers.Count) resource providers on the current subscription..."
        $r = Test-ALZResourceProviders -Providers $providers; Write-ALZResults $r; $results += $r

        $ghToken = $null
        if (Read-ALZConfirm -Prompt 'Validate the GitHub PAT and org now (recommended)?' -Default $true) {
            $sec = Read-Host -Prompt '  Paste GitHub PAT (input hidden)' -AsSecureString
            $ghToken = ConvertTo-ALZPlainText -Secure $sec
        }
        Write-ALZStatus -Status RUN -Message 'Checking GitHub PAT, org access, and Members permission...'
        $r = Test-ALZGitHubToken -Token $ghToken -Org $state.answers.githubOrg; Write-ALZResults $r; $results += $r
        $ghToken = $null

        if ($state.answers.stateBackend -eq 'hcp') {
            $hcpToken = $null
            if (Read-ALZConfirm -Prompt 'Validate the HCP workspace now (recommended)?' -Default $true) {
                $sec = Read-Host -Prompt '  Paste HCP API token (input hidden)' -AsSecureString
                $hcpToken = ConvertTo-ALZPlainText -Secure $sec
            }
            Write-ALZStatus -Status RUN -Message 'Checking HCP workspace and execution mode...'
            $r = Test-ALZHcpWorkspace -Token $hcpToken -HcpOrg $state.answers.hcpOrg -Workspace $state.answers.hcpWorkspace; Write-ALZResults $r; $results += $r
            $hcpToken = $null
        }

        Write-ALZSection 'Preflight summary'
        $okCount = @($results | Where-Object { $_.Status -eq 'OK' }).Count
        $warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
        $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
        Write-Host "  $okCount passed, $warnCount warnings, $failCount blocking" -ForegroundColor $(if ($failCount) { 'Red' } elseif ($warnCount) { 'Yellow' } else { 'Green' })

        $fails = @($results | Where-Object { $_.Status -eq 'FAIL' })
        $rpWarn = @($results | Where-Object { $_.Name -like 'Resource providers*' -and $_.Status -eq 'WARN' })

        if ($rpWarn.Count -gt 0 -and (Read-ALZConfirm -Prompt 'Register the ALZ resource providers on all subscriptions now?' -Default $true)) {
            Register-ALZResourceProviders -Subscriptions $state.answers.subscriptions -Providers $providers
            Write-ALZStatus -Status OK -Message 'Resource provider registration submitted.'
        }

        if ($fails.Count -eq 0) {
            Set-ALZPhaseStatus -State $state -Phase 'preflight' -Status 'done'
            Write-ALZStatus -Status OK -Message 'Preflight passed.'
            break
        }

        Write-ALZStatus -Status FAIL -Message "$($fails.Count) blocking issue(s) remain."
        if (-not (Read-ALZConfirm -Prompt 'Fix them, then re-run preflight?' -Default $true)) {
            Write-ALZStatus -Status WARN -Message 'Exiting so you can resolve prerequisites. Re-run to resume.'
            return
        }
    } while ($true)
}

# ---- Phase: Generate config --------------------------------------------
Set-ALZCurrentPhase -State $state -Phase 'config'
Write-ALZProgress -CurrentPhase 'config' -SkipPhases $skip
Write-ALZSection 'Generating accelerator config'
$configFolder = Join-Path $DeliveryPath 'config'
$inputsPath = Write-ALZInputsYaml -State $state -ConfigFolder $configFolder
Write-ALZStatus -Status OK -Message 'Wrote inputs.yaml' -Detail $inputsPath

if ($state.answers.iacType -eq 'bicep') {
    $bicepPath = Write-ALZBicepConfig -State $state -ConfigFolder $configFolder -DataPath $dataPath
    Write-ALZStatus -Status OK -Message "Wrote platform-landing-zone.yaml (network_type: $($state.answers.bicepNetworkType))" -Detail $bicepPath
}
else {
    # The platform config is generated from the chosen scenario, then hand-editable. If the
    # scenario changed since it was generated, the existing file is for the old topology.
    $tfvarsExisting = Join-Path $configFolder 'platform-landing-zone.tfvars'
    if ((Test-Path $tfvarsExisting) -and -not (Test-ALZTfvarsMatchesScenario -TfvarsPath $tfvarsExisting -Scenario $state.answers.scenario -DataPath $dataPath)) {
        Write-ALZStatus -Status WARN -Message 'The existing platform config does not match the selected scenario.' -Detail 'It was generated for a different topology. Replacing it discards any manual edits.'
        if (Read-ALZConfirm -Prompt 'Replace it with the selected scenario (discards manual edits)?' -Default $false) {
            Remove-Item -Path $tfvarsExisting -Force
        }
    }
    $tfvarsPath = Write-ALZStarterTfvars -State $state -ConfigFolder $configFolder -DataPath $dataPath
    Write-ALZStatus -Status OK -Message "Wrote platform-landing-zone.tfvars ($($state.answers.scenario))" -Detail $tfvarsPath
}
Set-ALZPhaseStatus -State $state -Phase 'config' -Status 'done'

# ---- Phase: Bootstrap --------------------------------------------------
Write-ALZProgress -CurrentPhase 'bootstrap' -SkipPhases $skip
$runBootstrap = $true
if ($state.phaseStatus.bootstrap -eq 'done') {
    Write-ALZStatus -Status OK -Message 'Bootstrap already completed on a previous run - skipping to stage 2.'
    $runBootstrap = Read-ALZConfirm -Prompt 'Re-run the bootstrap anyway (creates/updates repos + identities)?' -Default $false
}
if ($runBootstrap) {
    if (-not (Read-ALZConfirm -Prompt 'Install/verify the ALZ module and run the bootstrap now?' -Default $true)) {
        Write-ALZStatus -Status INFO -Message 'Stopping before bootstrap. Re-run to resume from here.'
        return
    }
    Set-ALZCurrentPhase -State $state -Phase 'bootstrap'
    Install-ALZModuleIfNeeded

    Write-ALZStatus -Status INFO -Message 'The GitHub PAT is used only for this run and is never written to disk.'
    $sec = Read-Host -Prompt '  Paste GitHub PAT for bootstrap (input hidden)' -AsSecureString

    # Self-hosted runners need a second PAT (token-2, "Runner Registration") to register
    # the in-VNet runners with GitHub. Collected masked, used only for this run.
    $runnersSec = $null
    if ($state.answers.selfHostedRunners) {
        Write-ALZStatus -Status INFO -Message 'Self-hosted runners are enabled - a second PAT (Runner Registration) is required.'
        $runnersSec = Read-Host -Prompt '  Paste GitHub Runner Registration PAT (input hidden)' -AsSecureString
    }

    Write-ALZStatus -Status RUN -Message 'Starting bootstrap (this creates the two repos and Azure identity resources)...'
    $boot = Invoke-ALZBootstrap -State $state -DataPath $dataPath -GitHubToken $sec -GitHubRunnersToken $runnersSec
    Add-ALZStat -State $state -Name 'bootstrapRuns'

    if ($boot.Failed) {
        Set-ALZPhaseStatus -State $state -Phase 'bootstrap' -Status 'failed'
        Write-ALZStatus -Status FAIL -Message 'Bootstrap reported problems.' -Detail "Transcript: $($boot.TranscriptPath)"
        foreach ($t in $boot.MatchedTraps) {
            Write-ALZRemediation -Title $t.title -Remediation $t.remediation -DocUrl $t.docUrl
        }
        Write-ALZStatus -Status INFO -Message 'Fix the above and re-run to resume from bootstrap.'
        return
    }

    Set-ALZPhaseStatus -State $state -Phase 'bootstrap' -Status 'done'
    Write-ALZStatus -Status OK -Message 'Bootstrap complete.'

    # Verify the repos actually received the workflows. A PAT missing "Workflows: Read
    # and write" makes GitHub reject the module push (atomic), leaving empty repos.
    Write-ALZStatus -Status RUN -Message 'Verifying the module repo received its CI/CD workflows...'
    $vtok = ConvertTo-ALZPlainText -Secure $sec
    try {
        $vrepo = Find-ALZModuleRepo -Token $vtok -Org $state.answers.githubOrg
        if (-not $vrepo) {
            Set-ALZPhaseStatus -State $state -Phase 'bootstrap' -Status 'failed'
            Write-ALZStatus -Status FAIL -Message 'The module repo has no CI/CD workflows - the bootstrap push was incomplete.'
            Write-ALZRemediation -Title 'Repos created but the workflows/module were not pushed' -Remediation 'GitHub rejects a push containing .github/workflows files if the PAT lacks the Workflows permission, so the whole module push fails. Fix: (1) add Repository > Workflows: Read and write (and confirm Contents, Administration, Actions, Environments, Secrets, Variables + Organization > Members) to the PAT. (2) If a plain bootstrap re-run still leaves the repos empty, Terraform state thinks the content already exists - delete the two repos in GitHub, then re-run this app and re-run the bootstrap so they are recreated and fully pushed.' -DocUrl 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/'
            $vtok = $null
            return
        }
        Write-ALZStatus -Status OK -Message "Verified: '$($vrepo.Repo)' has the CI/CD workflows."
    }
    finally { $vtok = $null }
}

# ---- Stage 2: deploy the platform (choose CLI or manual) ---------------
Write-ALZProgress -CurrentPhase 'proof' -SkipPhases $skip
Write-ALZBanner -Title 'Bootstrap done - stage 2: deploy the platform' -Subtitle 'MGs, policies, and management resources deploy via the pipeline.'
Write-Host '  Two-stage model:' -ForegroundColor White
Write-Host '  - Bootstrap (done): the two repos, OIDC identities, and Terraform state.' -ForegroundColor DarkGray
Write-Host '  - Next: the "02 Continuous Delivery" workflow runs terraform apply on a' -ForegroundColor DarkGray
Write-Host '    GitHub-hosted runner (OIDC to Azure, no local Terraform) to deploy the' -ForegroundColor DarkGray
Write-Host '    management-group hierarchy, the ALZ policy assignments, and management resources.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    1. Guided in this CLI  - discover the repo, trigger + watch the pipeline, verify' -ForegroundColor White
Write-Host '    2. Manual              - print the step-by-step runbook and do it yourself' -ForegroundColor White
$stage2 = Read-ALZValue -Prompt 'Proceed with stage 2 in the CLI, or print the manual steps? (1/2)' -Default '1' -Validator { param($v) $v -in @('1', '2') }

if ($stage2 -eq '2') {
    Show-ALZManualSteps -State $state -DataPath $dataPath
    Set-ALZCurrentPhase -State $state -Phase 'complete'
    Write-ALZStatus -Status OK -Message 'Manual runbook printed. Re-run anytime to switch to the guided flow or verify.'
    return
}

# ---- Stage 2 (guided in CLI) -------------------------------------------
Set-ALZCurrentPhase -State $state -Phase 'proof'
$sec = Read-Host -Prompt '  Paste GitHub PAT (input hidden)' -AsSecureString
$tok = ConvertTo-ALZPlainText -Secure $sec
try {
    Write-ALZStatus -Status RUN -Message 'Discovering the module repo and its workflows...'
    $repo = Find-ALZModuleRepo -Token $tok -Org $state.answers.githubOrg

    # The accelerator always bootstraps an Azure Storage backend, so HCP is a
    # post-bootstrap migration. Verify it landed instead of taking a yes/no answer.
    if ($state.answers.stateBackend -eq 'hcp' -and $repo) {
        Show-ALZHcpSteps -State $state
        Write-ALZSection 'Verifying the HCP migration'
        $templatesRepo = "$($repo.Repo)-templates"
        $hcpChecks = Test-ALZHcpReadiness -Token $tok -Org $state.answers.githubOrg -ModuleRepo $repo.Repo `
            -TemplatesRepo $templatesRepo -HcpOrg $state.answers.hcpOrg -Workspace $state.answers.hcpWorkspace
        foreach ($c in $hcpChecks) { Write-ALZResults $c }
        $hcpFails = @($hcpChecks | Where-Object { $_.Status -eq 'FAIL' })
        if ($hcpFails.Count -gt 0) {
            Set-ALZPhaseStatus -State $state -Phase 'hcp' -Status 'failed'
            Write-ALZStatus -Status FAIL -Message "$($hcpFails.Count) HCP migration step(s) still outstanding."
            Write-ALZStatus -Status INFO -Message 'Complete the items above, then re-run to continue with the pipeline.'
            Set-ALZCurrentPhase -State $state -Phase 'hcp'
            $tok = $null
            return
        }
        Set-ALZPhaseStatus -State $state -Phase 'hcp' -Status 'done'
        Write-ALZStatus -Status OK -Message 'HCP migration verified - state will be stored in HCP Terraform.'
    }
    if (-not $repo) {
        Write-ALZStatus -Status WARN -Message 'Could not find the module repo/workflows via the API.'
        Write-Host '  Run it manually: GitHub -> module repo -> Actions -> "02 ... Continuous Delivery" -> Run workflow -> approve.' -ForegroundColor DarkCyan
    }
    else {
        Write-ALZStatus -Status OK -Message "Module repo: $($repo.Repo)" -Detail "Workflow: $($repo.CdName)"
        $summaryRepo = $repo
        Write-Host '  The pipeline runs two jobs: plan, then apply behind an approval gate.' -ForegroundColor DarkGray

        $existing = Get-ALZLatestRun -Token $tok -Org $state.answers.githubOrg -Repo $repo.Repo -WorkflowId $repo.CdId
        $watch = $false
        if ($existing -and $existing.status -ne 'completed') {
            Write-ALZStatus -Status INFO -Message "A run is already in progress (#$($existing.run_number)) - watching it." -Detail $existing.html_url
            $watch = $true
        }
        elseif (Read-ALZConfirm -Prompt "Trigger '$($repo.CdName)' now?" -Default $true) {
            if (Start-ALZWorkflow -Token $tok -Org $state.answers.githubOrg -Repo $repo.Repo -WorkflowId $repo.CdId -Ref $repo.DefaultBranch) {
                Write-ALZStatus -Status OK -Message 'Workflow triggered.'
                $watch = $true
            }
            else {
                Write-ALZStatus -Status WARN -Message 'Could not trigger via API (the workflow may not allow manual dispatch).'
                Write-Host "  Push to $($repo.DefaultBranch) or run it from the Actions tab: https://github.com/$($state.answers.githubOrg)/$($repo.Repo)/actions" -ForegroundColor DarkCyan
            }
        }

        if ($watch) {
            Write-Host '  Watching the run. This deploys MGs + policies + management resources.' -ForegroundColor DarkGray
            Add-ALZStat -State $state -Name 'pipelineRuns'
            $result = Wait-ALZPipelineRun -Token $tok -Org $state.answers.githubOrg -Repo $repo.Repo -WorkflowId $repo.CdId
            if ($result.State -eq 'waiting_approval') {
                Write-ALZStatus -Status WARN -Message 'Apply gate reached - your approval is required.' -Detail $result.Url
                $approved = $false
                if (Read-ALZConfirm -Prompt 'Approve the apply from here (needs your reviewer rights)?' -Default $false) {
                    try {
                        $envIds = @($result.Pending | ForEach-Object { $_.environment.id })
                        Set-ALZDeploymentApproval -Token $tok -Org $state.answers.githubOrg -Repo $repo.Repo -RunId $result.Id -EnvIds $envIds
                        Write-ALZStatus -Status OK -Message 'Approval submitted. Continuing to watch...'
                        $approved = $true
                    }
                    catch {
                        Write-ALZStatus -Status WARN -Message 'API approval failed - approve in the browser instead.' -Detail 'This usually means the PAT cannot review deployments, or you are not a required reviewer on the apply environment.'
                    }
                }
                if (-not $approved) {
                    Write-Host "  Approve here: $($result.Url)" -ForegroundColor DarkCyan
                    Write-Host '  Leave this window open - it keeps watching and reports the result.' -ForegroundColor DarkCyan
                }
                # Poll through the gate so a browser approval is picked up without re-running.
                $result = Wait-ALZPipelineRun -Token $tok -Org $state.answers.githubOrg -Repo $repo.Repo -WorkflowId $repo.CdId -ThroughApproval -TimeoutMinutes 60
            }

            if ($result.State -eq 'completed' -and $result.Conclusion -eq 'success') {
                Write-ALZBell
                Write-ALZStatus -Status OK -Message 'Pipeline apply succeeded.'
                Write-ALZStatus -Status RUN -Message 'Verifying the platform (management groups and policy assignments)...'
                $v = Test-ALZPlatformDeployed
                $summaryPlatform = $v
                Write-Host "  Management groups: $($v.ManagementGroups); policy assignments at the ALZ management group: $($v.PolicyAssignments)" -ForegroundColor White
                Set-ALZPhaseStatus -State $state -Phase 'proof' -Status 'done'
            }
            elseif ($result.State -eq 'completed') {
                Write-ALZBell
                Write-ALZStatus -Status FAIL -Message "Pipeline concluded: $($result.Conclusion)" -Detail $result.Url
                Write-Host '  Open the run to see which step failed; re-run the walkthrough after fixing.' -ForegroundColor DarkCyan
            }
            elseif ($result.State -eq 'timeout') {
                Write-ALZStatus -Status INFO -Message 'Still running past the watch window.' -Detail "Re-run this app and choose stage 2 option 1 to resume watching, or check: https://github.com/$($state.answers.githubOrg)/$($repo.Repo)/actions"
            }
            else {
                Write-ALZStatus -Status INFO -Message "Stopped watching while the run was '$($result.State)'." -Detail 'Re-run this app and choose stage 2 option 1 to resume watching.'
            }
            $summaryRun = $result
        }
    }
}
finally { $tok = $null }

# ---- Phase 3: target topology (only if beyond management-only) ---------
Show-ALZRunSteps -State $state -DataPath $dataPath

Set-ALZCurrentPhase -State $state -Phase 'complete'

# ---- Closing summary ----------------------------------------------------
$rgNames = @()
try {
    $rgNames = @(az group list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -like 'rg-alz*' } | ForEach-Object { $_.name } | Sort-Object)
}
catch { }
if (-not $summaryPlatform) {
    try { $summaryPlatform = Test-ALZPlatformDeployed } catch { }
}
Save-ALZState -State $state
Write-ALZSummary -State $state -Platform $summaryPlatform -Run $summaryRun -ResourceGroups $rgNames -Repo $summaryRepo -SessionStart $sessionStart

Write-ALZStatus -Status OK -Message 'Orchestrator finished. State saved for the next session.'
