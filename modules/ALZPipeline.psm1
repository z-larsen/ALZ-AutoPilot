###########################################################################
# ALZPIPELINE.PSM1
# GITHUB ACTIONS PIPELINE DISCOVERY, TRIGGER, WATCH, AND VERIFY
###########################################################################
# Purpose: Drive the post-bootstrap platform deployment - find the module
#          repo and its Continuous Delivery workflow, trigger or watch the
#          run, detect the apply approval gate, and verify what landed.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# The bootstrap only builds the CI/CD plumbing. The management-group
# hierarchy, ALZ policy assignments, and management resources are deployed
# by the "02 Continuous Delivery" GitHub Actions workflow. These helpers
# let the orchestrator walk the user through that stage.
#
# Prerequisites:
# - PowerShell 7.4+, a GitHub PAT with Actions access, Azure CLI signed in.
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

function Get-ALZGitHubHeaders {
    param([string]$Token)
    return @{ Authorization = "Bearer $Token"; 'User-Agent' = 'ALZ-Orchestrator'; Accept = 'application/vnd.github+json' }
}

function ConvertTo-ALZUriSegment {
    param([string]$Value)
    return [uri]::EscapeDataString("$Value")
}

function Find-ALZModuleRepo {
    param([string]$Token, [string]$Org)
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org
    try {
        $repos = Invoke-RestMethod -Uri "https://api.github.com/orgs/$o/repos?per_page=100" -Headers $h -Method Get -ErrorAction Stop
    }
    catch { return $null }
    foreach ($repo in $repos) {
        try {
            $r = ConvertTo-ALZUriSegment $repo.name
            $wf = Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/workflows" -Headers $h -Method Get -ErrorAction Stop
            $cd = $wf.workflows | Where-Object { $_.name -match 'Continuous Delivery' } | Select-Object -First 1
            $ci = $wf.workflows | Where-Object { $_.name -match 'Continuous Integration' } | Select-Object -First 1
            if ($cd) {
                return [pscustomobject]@{
                    Repo          = $repo.name
                    DefaultBranch = $repo.default_branch
                    CdId          = $cd.id
                    CdName        = $cd.name
                    CiId          = if ($ci) { $ci.id } else { $null }
                    CiName        = if ($ci) { $ci.name } else { $null }
                }
            }
        }
        catch { continue }
    }
    return $null
}

function Get-ALZLatestRun {
    param([string]$Token, [string]$Org, [string]$Repo, [long]$WorkflowId)
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    try {
        $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/workflows/$WorkflowId/runs?per_page=1" -Headers $h -Method Get -ErrorAction Stop
        return $runs.workflow_runs | Select-Object -First 1
    }
    catch { return $null }
}

function Start-ALZWorkflow {
    param([string]$Token, [string]$Org, [string]$Repo, [long]$WorkflowId, [string]$Ref = 'main')
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    $body = @{ ref = $Ref } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/workflows/$WorkflowId/dispatches" -Headers $h -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ALZPendingApproval {
    param([string]$Token, [string]$Org, [string]$Repo, [long]$RunId)
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    try {
        $pd = Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/runs/$RunId/pending_deployments" -Headers $h -Method Get -ErrorAction Stop
        return @($pd | Where-Object { $_.current_user_can_approve })
    }
    catch { return @() }
}

function Set-ALZDeploymentApproval {
    param([string]$Token, [string]$Org, [string]$Repo, [long]$RunId, [int[]]$EnvIds, [string]$Comment = 'Approved via ALZ Orchestrator')
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    $body = @{ environment_ids = $EnvIds; state = 'approved'; comment = $Comment } | ConvertTo-Json
    Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/runs/$RunId/pending_deployments" -Headers $h -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
}

function Wait-ALZPipelineRun {
    param(
        [string]$Token, [string]$Org, [string]$Repo, [long]$WorkflowId,
        [int]$TimeoutMinutes = 30,
        [switch]$ThroughApproval
    )
    $start = Get-Date
    $deadline = $start.AddMinutes($TimeoutMinutes)
    $lastStatus = ''
    $lastBeat = $start
    $approvalNoticeShown = $false
    Start-Sleep -Seconds 5
    while ((Get-Date) -lt $deadline) {
        $run = Get-ALZLatestRun -Token $Token -Org $Org -Repo $Repo -WorkflowId $WorkflowId
        if (-not $run) { Start-Sleep -Seconds 10; continue }
        if ($run.status -ne $lastStatus) {
            Write-Host "    run #$($run.run_number): $($run.status)" -ForegroundColor Cyan
            $lastStatus = $run.status
            $lastBeat = Get-Date
        }
        if ($run.status -eq 'completed') {
            return [pscustomobject]@{ State = 'completed'; Conclusion = $run.conclusion; Url = $run.html_url; Id = $run.id }
        }
        $pending = Get-ALZPendingApproval -Token $Token -Org $Org -Repo $Repo -RunId $run.id
        if ($pending -and $pending.Count -gt 0) {
            # Without -ThroughApproval, hand control back so the caller can offer to approve.
            if (-not $ThroughApproval) {
                return [pscustomobject]@{ State = 'waiting_approval'; Url = $run.html_url; Id = $run.id; Pending = $pending }
            }
            if (-not $approvalNoticeShown) {
                Write-Host '    waiting for the apply approval (approve in the browser - this keeps watching)...' -ForegroundColor Yellow
                $approvalNoticeShown = $true
                $lastBeat = Get-Date
            }
        }
        # Heartbeat so a long apply does not look like a frozen console.
        if (((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
            Write-Host "    still $($run.status)... $([int]((Get-Date) - $start).TotalMinutes)m elapsed" -ForegroundColor DarkGray
            $lastBeat = Get-Date
        }
        Start-Sleep -Seconds 15
    }
    return [pscustomobject]@{ State = 'timeout' }
}

function Get-ALZRepoFile {
    param([string]$Token, [string]$Org, [string]$Repo, [string]$Path)
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    # Encode each segment so a crafted file name cannot reshape the request path.
    $p = ($Path -split '/' | Where-Object { $_ -and $_ -ne '.' -and $_ -ne '..' } |
        ForEach-Object { ConvertTo-ALZUriSegment $_ }) -join '/'
    try {
        $item = Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/contents/$p" -Headers $h -Method Get -ErrorAction Stop
        if ($item.content) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($item.content)) }
        return $null
    }
    catch { return $null }
}

function Get-ALZRepoFileNames {
    param([string]$Token, [string]$Org, [string]$Repo, [string]$Path = '')
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    $p = ($Path -split '/' | Where-Object { $_ -and $_ -ne '.' -and $_ -ne '..' } |
        ForEach-Object { ConvertTo-ALZUriSegment $_ }) -join '/'
    try {
        $items = Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/contents/$p" -Headers $h -Method Get -ErrorAction Stop
        return @($items | Where-Object { $_.type -eq 'file' } | ForEach-Object { $_.name })
    }
    catch { return @() }
}

function Test-ALZRepoSecretExists {
    param([string]$Token, [string]$Org, [string]$Repo, [string]$Name)
    $h = Get-ALZGitHubHeaders $Token
    $o = ConvertTo-ALZUriSegment $Org; $r = ConvertTo-ALZUriSegment $Repo
    try {
        # Returns metadata only; secret values are never readable through the API.
        Invoke-RestMethod -Uri "https://api.github.com/repos/$o/$r/actions/secrets/$Name" -Headers $h -Method Get -ErrorAction Stop | Out-Null
        return $true
    }
    catch { return $false }
}

function Test-ALZHcpReadiness {
    param(
        [string]$Token, [string]$Org, [string]$ModuleRepo, [string]$TemplatesRepo,
        [string]$HcpOrg, [string]$Workspace
    )
    $results = @()
    $add = { param($name, $status, $detail, $fix) $script:null = $null; return [pscustomobject]@{ Name = $name; Status = $status; Detail = $detail; Remediation = $fix; DocUrl = '' } }

    # 1. Backend swapped to the HCP cloud block in the module repo.
    $tfFiles = @(Get-ALZRepoFileNames -Token $Token -Org $Org -Repo $ModuleRepo | Where-Object { $_ -like '*.tf' })
    $cloudFound = $false; $azurermFound = $false; $where = ''
    foreach ($f in $tfFiles) {
        $c = Get-ALZRepoFile -Token $Token -Org $Org -Repo $ModuleRepo -Path $f
        if (-not $c) { continue }
        if ($c -match '(?m)^\s*cloud\s*\{') { $cloudFound = $true; $where = $f }
        if ($c -match '(?m)^\s*backend\s+"azurerm"') { $azurermFound = $true; if (-not $where) { $where = $f } }
    }
    if ($cloudFound -and -not $azurermFound) {
        $results += & $add 'HCP backend block' 'OK' "cloud block present in $where" ''
    }
    elseif ($cloudFound -and $azurermFound) {
        $results += & $add 'HCP backend block' 'FAIL' 'Both a cloud block and an azurerm backend are present' 'Remove the backend "azurerm" block. A cloud block and an azurerm backend cannot coexist.'
    }
    else {
        $results += & $add 'HCP backend block' 'FAIL' 'No cloud block found in the module repo' "Replace backend `"azurerm`" {} with: cloud { organization = `"$HcpOrg`" workspaces { name = `"$Workspace`" } }"
    }

    # 2. HCP API token available to the workflows.
    if (Test-ALZRepoSecretExists -Token $Token -Org $Org -Repo $ModuleRepo -Name 'TF_TOKEN_app_terraform_io') {
        $results += & $add 'TF_TOKEN_app_terraform_io secret' 'OK' 'Present on the module repo' ''
    }
    else {
        $results += & $add 'TF_TOKEN_app_terraform_io secret' 'FAIL' 'Not found on the module repo' 'Add a repository secret named TF_TOKEN_app_terraform_io containing an HCP Terraform API token.'
    }

    # 3. No -backend-config left in the reusable templates (it conflicts with the cloud block).
    foreach ($wf in @('cd-template.yaml', 'ci-template.yaml')) {
        $c = Get-ALZRepoFile -Token $Token -Org $Org -Repo $TemplatesRepo -Path ".github/workflows/$wf"
        if (-not $c) {
            $results += & $add "Template $wf" 'WARN' 'Could not read the workflow' 'Check the templates repo name and the PAT Contents permission.'
            continue
        }
        # -backend=false on validate is expected and must stay.
        $bad = @([regex]::Matches($c, '-backend-config')).Count
        if ($bad -eq 0) {
            $results += & $add "Template $wf" 'OK' 'No -backend-config flags remain' ''
        }
        else {
            $results += & $add "Template $wf" 'FAIL' "$bad -backend-config flag(s) still present" 'Remove every -backend-config flag from terraform init in the plan and apply steps. Leave the CI validate step''s -backend=false alone.'
        }
        if ($c -notmatch 'TF_TOKEN_app_terraform_io') {
            $results += & $add "Template $wf secret wiring" 'FAIL' 'TF_TOKEN_app_terraform_io is not referenced' 'Declare the secret under secrets: and add it to the job env: so Terraform can authenticate to HCP.'
        }
        else {
            $results += & $add "Template $wf secret wiring" 'OK' 'Secret is declared and used' ''
        }
    }

    # 4. Caller workflows must forward secrets to the reusable workflow. The accelerator
    # names these ci.yaml/cd.yaml; the 01/02 numbering is only the display name.
    $callers = @(Get-ALZRepoFileNames -Token $Token -Org $Org -Repo $ModuleRepo -Path '.github/workflows' |
        Where-Object { $_ -match '\.(yaml|yml)$' })
    if ($callers.Count -eq 0) {
        $results += & $add 'Caller workflows' 'WARN' 'No workflows found in the module repo' 'Confirm the module repo contains its CI and CD workflows.'
    }
    foreach ($wf in $callers) {
        $c = Get-ALZRepoFile -Token $Token -Org $Org -Repo $ModuleRepo -Path ".github/workflows/$wf"
        if ($c -and $c -match 'secrets:\s*inherit') {
            $results += & $add "Caller $wf" 'OK' 'secrets: inherit present' ''
        }
        else {
            $results += & $add "Caller $wf" 'FAIL' 'secrets: inherit missing' 'Add "secrets: inherit" to the job that calls the reusable workflow, otherwise the HCP token never reaches it.'
        }
    }

    return $results
}

function Test-ALZPlatformDeployed {
    param([string]$RootMgName = 'alz')
    # Count in PowerShell rather than with az --query "length(@)": on Windows the
    # az.cmd wrapper mangles the @ and () through cmd.exe and returns garbage.
    $mgCount = 0
    $mgNames = @()
    try {
        $mgs = az account management-group list -o json 2>$null | ConvertFrom-Json
        $mgCount = @($mgs).Count
        $mgNames = @($mgs | ForEach-Object { $_.name } | Where-Object { $_ })
    }
    catch { }

    # Assignments must be counted one management group at a time. At management group
    # scope the service rejects atScopeAndBelow(), which is what --disable-scope-strict-match
    # sends, and returns UnsupportedFilter; atScope() per group is the supported form.
    $seen = @{}
    foreach ($name in $mgNames) {
        try {
            $pa = az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/$name" -o json 2>$null | ConvertFrom-Json
            foreach ($p in @($pa)) {
                if (-not $p.id -or $seen.ContainsKey($p.id)) { continue }
                $seen[$p.id] = [pscustomobject]@{
                    Name            = $p.name
                    DisplayName     = $p.displayName
                    ManagementGroup = ($p.scope -split '/')[-1]
                    IsInitiative    = ([string]$p.policyDefinitionId -like '*policySetDefinitions*')
                    EnforcementMode = $(if ($p.enforcementMode) { $p.enforcementMode } else { 'Default' })
                }
            }
        }
        catch { }
    }
    $assignments = @($seen.Values)
    return [pscustomobject]@{
        ManagementGroups  = $mgCount
        PolicyAssignments = $assignments.Count
        Assignments       = $assignments
    }
}

Export-ModuleMember -Function Find-ALZModuleRepo, Get-ALZLatestRun, Start-ALZWorkflow, Get-ALZPendingApproval, Set-ALZDeploymentApproval, Wait-ALZPipelineRun, Test-ALZPlatformDeployed, Get-ALZRepoFile, Get-ALZRepoFileNames, Test-ALZRepoSecretExists, Test-ALZHcpReadiness
