###########################################################################
# ALZORCHESTRATOR.PSM1
# BOOTSTRAP EXECUTION, ERROR TRANSLATION, AND GUIDED NEXT STEPS
###########################################################################
# Purpose: Wrap the real Deploy-Accelerator run, capture its output, and
#          translate known failures into plain-language fixes. Also render
#          the guided checklists for the HCP migration and day-2 operations.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# 1. Ensures the ALZ PowerShell module is installed/current.
# 2. Runs Deploy-Accelerator against the generated inputs.yaml.
# 3. Transcribes the run and matches failures against data/traps.json.
# 4. Renders the HCP-migration steps and the day-2 operating model.
# The accelerator itself is unchanged - this only orchestrates it.
#
# Prerequisites:
# - PowerShell 7.4+, ALZ module (auto-installed if missing).
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

function Test-ALZModuleInstalled {
    $m = Get-InstalledPSResource -Name ALZ -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) {
        return New-ALZCheckResult 'ALZ PowerShell module' 'OK' "Installed $($m.Version)"
    }
    return New-ALZCheckResult 'ALZ PowerShell module' 'WARN' 'Not installed' 'The orchestrator can install it for you before bootstrap.'
}

function Install-ALZModuleIfNeeded {
    $m = Get-InstalledPSResource -Name ALZ -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $m) {
        Write-Host '  Installing ALZ module...' -ForegroundColor Cyan
        Install-PSResource -Name ALZ -TrustRepository -ErrorAction Stop
    }
    else {
        Write-Host "  ALZ module present ($($m.Version)). Checking for updates..." -ForegroundColor Cyan
        Update-PSResource -Name ALZ -ErrorAction SilentlyContinue
    }
}

function Resolve-ALZError {
    param([string]$Text, [string]$DataPath)
    if (-not $Text) { return @() }
    $traps = (Get-Content -Path (Join-Path $DataPath 'traps.json') -Raw | ConvertFrom-Json).traps
    $matched = @()
    foreach ($t in $traps) {
        if ($Text -match $t.pattern) {
            $matched += $t
        }
    }
    return $matched
}

function Invoke-ALZBootstrap {
    param(
        [hashtable]$State,
        [string]$DataPath,
        [securestring]$VcsToken,
        [securestring]$VcsAgentsToken
    )
    # The two bootstrap modules read their credentials from differently named TF_VAR_
    # environment variables. Everything else about the run is identical.
    $isAdo = ($State.answers.vcs -eq 'azuredevops')
    $tokenVar = if ($isAdo) { 'TF_VAR_azure_devops_personal_access_token' } else { 'TF_VAR_github_personal_access_token' }
    $agentsVar = if ($isAdo) { 'TF_VAR_azure_devops_agents_personal_access_token' } else { 'TF_VAR_github_runners_personal_access_token' }
    $inputsPath = Join-Path $State.deliveryPath 'config\inputs.yaml'
    $platformConfig = if ($State.answers.iacType -eq 'bicep') {
        Join-Path $State.deliveryPath 'config\platform-landing-zone.yaml'
    }
    else {
        Join-Path $State.deliveryPath 'config\platform-landing-zone.tfvars'
    }

    if (-not (Test-Path $inputsPath)) {
        throw "inputs.yaml not found at $inputsPath. Run the config phase first."
    }
    # Explicit inputConfigFilePaths disables the accelerator's folder auto-discovery,
    # so every config file must be listed. The platform config supplies starter_locations.
    $configPaths = @($inputsPath)
    if (Test-Path $platformConfig) { $configPaths += $platformConfig }

    # Self-heal a partial module download. The accelerator records the extracted module
    # versions in .alz-version-data.json and trusts it: if the marker claims a bootstrap
    # version is present but the extracted module is gone (deleted bootstrap/ folder, or an
    # interrupted prior run), it skips re-downloading and then dies with
    # "The config file does not exist at ...\.config\ALZ-Powershell.config.json".
    # Detect that mismatch and clear the marker + module folders so it re-downloads cleanly.
    $versionMarker = Join-Path $State.deliveryPath '.alz-version-data.json'
    if (Test-Path $versionMarker) {
        try {
            $vd = Get-Content -Path $versionMarker -Raw | ConvertFrom-Json
            $bootCfg = Join-Path $State.deliveryPath "bootstrap\$($vd.bootstrapVersion)\.config\ALZ-Powershell.config.json"
            if ($vd.bootstrapVersion -and -not (Test-Path $bootCfg)) {
                Write-ALZStatus -Status WARN -Message 'Partial module download detected - healing before bootstrap' -Detail 'Version marker present but the bootstrap module is missing; clearing marker and stale module folders so the accelerator re-downloads.'
                Remove-Item -Path $versionMarker -Force -ErrorAction SilentlyContinue
                Remove-Item -Path (Join-Path $State.deliveryPath 'bootstrap') -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path (Join-Path $State.deliveryPath 'starter') -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch { }
    }

    # Supply the PAT only as a session env var - never persisted.
    # Copy from the SecureString and free the unmanaged BSTR immediately so the
    # plaintext does not linger in unmanaged memory.
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VcsToken)
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    Set-Item -Path "Env:$tokenVar" -Value $plain

    # Self-hosted runners/agents need a second PAT to register them with the VCS.
    # Same rules as the main token: session env var only, BSTR freed immediately, never on disk.
    $plainRunners = $null
    if ($VcsAgentsToken) {
        $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VcsAgentsToken)
        $plainRunners = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
        Set-Item -Path "Env:$agentsVar" -Value $plainRunners
    }

    # Tell Terraform's azurerm provider to skip auto-registration. We pre-register the
    # ALZ providers the deployment needs; this avoids multi-minute hangs on slow
    # providers like Microsoft.DataMigration that the deployment does not use.
    # 'none' is HashiCorp's recommended setting when managing registration outside Terraform.
    $priorRpReg = $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS
    $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'

    $transcript = Join-Path $env:TEMP "alz-bootstrap-$(Get-Date -Format yyyyMMdd-HHmmss).log"
    $failed = $false
    $transcriptStarted = $false
    try {
        try { Start-Transcript -Path $transcript -Force | Out-Null; $transcriptStarted = $true } catch { }
        Deploy-Accelerator `
            -output_folder_path $State.deliveryPath `
            -inputConfigFilePaths $configPaths
    }
    catch {
        $failed = $true
        Write-ALZStatus -Status FAIL -Message 'Bootstrap threw an error' -Detail $_.Exception.Message
    }
    finally {
        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
        # Clear the tokens from the environment as soon as the run ends.
        Remove-Item -Path "Env:$tokenVar" -ErrorAction SilentlyContinue
        Remove-Item -Path "Env:$agentsVar" -ErrorAction SilentlyContinue
        $env:ARM_RESOURCE_PROVIDER_REGISTRATIONS = $priorRpReg
        # Defense in depth: scrub the tokens from the transcript if they ever leaked into output.
        if ((Test-Path $transcript)) {
            try {
                $c = Get-Content -Path $transcript -Raw
                if ($c) {
                    $changed = $false
                    foreach ($secret in @($plain, $plainRunners)) {
                        if ($secret -and $c.Contains($secret)) { $c = $c.Replace($secret, '***REDACTED***'); $changed = $true }
                    }
                    if ($changed) { $c | Set-Content -Path $transcript -Encoding UTF8 }
                }
            }
            catch { Remove-Item -Path $transcript -Force -ErrorAction SilentlyContinue }
        }
        $plain = $null
        $plainRunners = $null
    }

    $log = if (Test-Path $transcript) { Get-Content -Path $transcript -Raw } else { '' }
    $matchedTraps = Resolve-ALZError -Text $log -DataPath $DataPath

    return [pscustomobject]@{
        Failed         = ($failed -or ($matchedTraps.Count -gt 0))
        TranscriptPath = $transcript
        MatchedTraps   = $matchedTraps
    }
}

function Show-ALZHcpSteps {
    param([hashtable]$State)
    $a = $State.answers
    Write-ALZSection 'Move state to HCP (guided)'
    Write-Host '  These edits happen in the two repos the bootstrap just created.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  1. Confirm the HCP workspace is Execution Mode = Local.' -ForegroundColor White
    Write-Host "     ($($a.hcpOrg)/$($a.hcpWorkspace))" -ForegroundColor DarkGray
    Write-Host '  2. Module repo: replace  backend "azurerm" {}  with:' -ForegroundColor White
    Write-Host '       cloud {' -ForegroundColor Gray
    Write-Host "         organization = `"$($a.hcpOrg)`"" -ForegroundColor Gray
    Write-Host "         workspaces { name = `"$($a.hcpWorkspace)`" }" -ForegroundColor Gray
    Write-Host '       }' -ForegroundColor Gray
    Write-Host '  3. Add repo secret TF_TOKEN_app_terraform_io (HCP API token).' -ForegroundColor White
    Write-Host '  4. Templates repo (ci/cd): declare the secret under secrets:, add it to' -ForegroundColor White
    Write-Host '     job env:, and remove every -backend-config flag from terraform init' -ForegroundColor White
    Write-Host '     (CD plan, CD apply, CI plan). Leave CI validate -backend=false alone.' -ForegroundColor White
    Write-Host '  5. Caller workflows (01/02): add  secrets: inherit.' -ForegroundColor White
    Write-Host '  6. Migrate:  terraform init -migrate-state   (answer yes)' -ForegroundColor White
    Write-Host ''
    Write-Host '  Gate: re-run 02 CD green, run shows in HCP history, no new state in storage.' -ForegroundColor DarkCyan
}

function Show-ALZRunSteps {
    param([hashtable]$State, [string]$DataPath)
    $a = $State.answers
    Write-ALZSection 'What happens from here'

    if ($a.iacType -eq 'bicep') {
        Write-Host "  Deployed: Bicep platform landing zone (network_type: $($a.bicepNetworkType))" -ForegroundColor White
    }
    else {
        $scenario = (Get-Content -Path (Join-Path $DataPath 'scenarios.json') -Raw | ConvertFrom-Json).scenarios |
            Where-Object { $_.key -eq $a.scenario } | Select-Object -First 1
        if ($scenario) {
            Write-Host "  Deployed: $($scenario.name)" -ForegroundColor White
            Write-Host "  connectivity_type = $($scenario.connectivityType)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Deployed: $($a.scenario)" -ForegroundColor White
        }
    }

    Write-Host ''
    Write-Host '  The pipeline is now your operating model. Every future platform change:' -ForegroundColor White
    Write-Host '   1. Edit the platform config in the module repo.' -ForegroundColor Gray
    Write-Host '   2. Open a pull request - the CI workflow runs the plan.' -ForegroundColor Gray
    Write-Host '   3. Merge - the CD workflow plans, waits at the approval gate, then applies.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Customizing further' -ForegroundColor White
    Write-Host '   - Management groups, archetypes, and policy assignments live in lib/ in the' -ForegroundColor Gray
    Write-Host '     module repo. See samples/lib-pci for a worked regulatory-compliance example.' -ForegroundColor Gray
    Write-Host '   - Changing topology later means replacing the platform config with another' -ForegroundColor Gray
    Write-Host '     scenario, then letting the pipeline apply the difference.' -ForegroundColor Gray

    if ($a.iacType -ne 'bicep' -and $scenario -and $scenario.estimatedMonthlyUsd -gt 0) {
        Write-Host ''
        Write-Host ('  This topology carries roughly ${0:N0}/month in fixed infrastructure cost.' -f $scenario.estimatedMonthlyUsd) -ForegroundColor Yellow
        Write-Host '  https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/' -ForegroundColor DarkCyan
    }
}

function Show-ALZManualSteps {
    param([hashtable]$State, [string]$DataPath)
    $a = $State.answers
    $org = $a.githubOrg

    Write-ALZBanner -Title 'Manual runbook - stage 2 onward' -Subtitle 'Do these yourself. Steps reflect the accelerator version you bootstrapped.'

    Write-ALZSection 'A. Deploy the platform (MGs, policies, management resources)'
    if ($a.vcs -eq 'azuredevops') {
        Write-Host "  1. Open https://dev.azure.com/$($a.adoOrg)/$($a.adoProject) and go to Pipelines." -ForegroundColor White
        Write-Host '  2. Select the "02 ... Continuous Delivery" pipeline -> Run pipeline -> branch main.' -ForegroundColor White
        Write-Host '  3. It runs terraform plan first, then pauses on the Apply environment approval check.' -ForegroundColor White
        Write-Host '  4. Review the plan, then approve the run (you were added as an approver).' -ForegroundColor White
        Write-Host '  5. Apply authenticates to Azure via the workload identity federation service connection.' -ForegroundColor White
    }
    else {
        Write-Host "  1. Open https://github.com/$org and pick the module repo - the one holding the" -ForegroundColor White
        Write-Host "     '01 ... Continuous Integration' and '02 ... Continuous Delivery' workflows." -ForegroundColor White
        Write-Host '  2. Actions tab -> select "02 ... Continuous Delivery" -> Run workflow -> branch main.' -ForegroundColor White
        Write-Host '  3. It runs terraform plan first, then pauses on the Apply environment approval gate.' -ForegroundColor White
        Write-Host '  4. Review the plan, then approve the deployment (you were added as an approver).' -ForegroundColor White
        Write-Host '  5. Apply runs on a GitHub-hosted runner and authenticates to Azure via OIDC.' -ForegroundColor White
    }
    Write-Host ''
    Write-Host '  This apply deploys:' -ForegroundColor DarkGray
    Write-Host '   - the full ALZ management-group hierarchy' -ForegroundColor DarkGray
    Write-Host '   - the ALZ policy assignments (Deny / Deploy / Audit set)' -ForegroundColor DarkGray
    Write-Host '   - management resources: Log Analytics, Automation, Defender plans, data collection rules' -ForegroundColor DarkGray
    Write-Host '   - subscription placement (moves your subscriptions into their target MGs)' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Verify (portal Management groups, or):' -ForegroundColor DarkCyan
    Write-Host '   az account management-group list -o table' -ForegroundColor DarkCyan
    Write-Host "   az policy assignment list --scope /providers/Microsoft.Management/managementGroups/alz -o table" -ForegroundColor DarkCyan
    Write-Host '   (repeat per management group: at MG scope Azure rejects --disable-scope-strict-match)' -ForegroundColor DarkGray

    if ($a.stateBackend -eq 'hcp') {
        Write-Host ''
        Show-ALZHcpSteps -State $State
    }

    Write-Host ''
    Show-ALZRunSteps -State $State -DataPath $DataPath

    Write-ALZSection 'C. Day-2 operations'
    Write-Host '  - Change flow: edit the module repo tfvars/lib -> open a PR (01 CI runs plan) ->' -ForegroundColor White
    Write-Host '    merge -> 02 CD runs plan + approved apply.' -ForegroundColor White
    Write-Host '  - Application landing zones: use subscription vending to create workload subscriptions.' -ForegroundColor White

    Write-ALZSection 'References (official)'
    Write-Host '  Phase 3 - Run:       https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/' -ForegroundColor DarkCyan
    if ($a.vcs -eq 'azuredevops') {
        Write-Host '  Azure DevOps prereqs: https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/' -ForegroundColor DarkCyan
    }
    Write-Host '  Terraform scenarios: https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/' -ForegroundColor DarkCyan
    Write-Host '  Configuration files: https://azure.github.io/Azure-Landing-Zones/accelerator/configuration-files/' -ForegroundColor DarkCyan
    Write-Host '  Cleanup FAQ:         https://azure.github.io/Azure-Landing-Zones/accelerator/faq/cleanup/' -ForegroundColor DarkCyan
}

Export-ModuleMember -Function Test-ALZModuleInstalled, Install-ALZModuleIfNeeded, Resolve-ALZError, Invoke-ALZBootstrap, Show-ALZHcpSteps, Show-ALZRunSteps, Show-ALZManualSteps
