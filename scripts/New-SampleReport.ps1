###########################################################################
# NEW-SAMPLEREPORT.PS1
# GENERATE A DEMO DELIVERY REPORT FOR SCREENSHOTS
###########################################################################
# Purpose: Render a fully populated delivery report using fictional data,
#          so the output can be shown without exposing a real tenant.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# Every value here is invented: Contoso names, throwaway GUIDs, and a
# representative slice of the ALZ policy baseline. Nothing touches Azure.
#
# ── Parameters ──────────────────────────────────────────────
# OutputPath         Where to write the report. Defaults to the repo root.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: .\scripts\New-SampleReport.ps1
###########################################################################

#requires -Version 7.4
[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\ALZReport.psm1') -Force

# Read the version from its single source so the sample never claims a stale build.
$entry = Get-Content (Join-Path $repoRoot 'Start-ALZDelivery.ps1') -Raw
$appVersion = if ($entry -match "(?m)^\`$ALZVersion\s*=\s*'([^']+)'") { $Matches[1] } else { '' }

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("alz-sample-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$state = @{
    deliveryPath = $scratch
    createdUtc   = (Get-Date).AddDays(-11).ToUniversalTime().ToString('o')
    answers      = @{
        deliveryName            = 'Contoso Ltd'
        region                  = 'eastus2'
        regionSecondary         = 'westus3'
        vcs                     = 'github'
        githubOrg               = 'contoso-platform'
        adoOrg                  = ''
        adoProject              = ''
        securityContactEmail    = 'soc@contoso.com'
        subscriptions           = @{
            management   = '8f4a1c2e-5d3b-4e17-9a62-7c081b4d5e93'
            connectivity = 'b21e7f04-9c6a-42d8-8f35-1e7a6b90c4d2'
            identity     = '3c9d8a15-7b24-4f61-a0e8-9d52f3c17b64'
            security     = 'd7e51b93-2f48-4a06-b5c9-6a138e40d275'
        }
        parentManagementGroupId = ''
        applyApprovers          = @('a-rivera', 'j-okafor')
        scenario                = 'multi-region-hub-and-spoke-vnet-with-azure-firewall'
        iacType                 = 'terraform'
        bicepNetworkType        = ''
        stateBackend            = 'azurerm'
        hcpOrg                  = ''
        hcpWorkspace            = ''
        selfHostedRunners       = $true
        privateNetworking       = $true
    }
    phaseStatus  = @{
        interview = 'done'; preflight = 'done'; config = 'done'; bootstrap = 'done'
        proof = 'done'; hcp = 'skipped'; run = 'done'
    }
    stats        = @{ sessions = 4; bootstrapRuns = 2; pipelineRuns = 3 }
    phaseSeconds = @{
        interview = 214; preflight = 96; config = 8; bootstrap = 447; proof = 1893; run = 3
    }
}

# A representative slice of the real ALZ baseline. Names carry the library's
# version suffix, which is the detail that makes them uncopyable from docs.
$mk = {
    param($mg, $names, $enforcement)
    $names | ForEach-Object {
        [pscustomobject]@{
            Name            = $_
            ManagementGroup = $mg
            IsInitiative    = ($_ -like 'Deploy-*' -or $_ -like 'Enforce-*')
            EnforcementMode = $enforcement
        }
    }
}

$assignments = @(
    & $mk 'alz' @(
        'Deploy-MDFC-Config-H224', 'Deploy-MDFC-DefenderSQL-AMA', 'Deploy-AzActivity-Log',
        'Deploy-ASC-SecurityContacts', 'Deploy-Diagnostics-LogAnalytics', 'Enforce-ACSB',
        'Deny-Classic-Resources', 'Deny-UnmanagedDisk', 'Audit-UnusedResourcesCostOptimization',
        'Deploy-MDEndpointsAMA', 'Enforce-Subnet-Private', 'Deploy-Private-DNS-Generic'
    ) 'Default'
    & $mk 'platform' @(
        'Deploy-VM-Backup', 'Deploy-VM-Monitoring', 'Deploy-VMSS-Monitoring',
        'Enable-AUM-CheckUpdates', 'Deploy-MDFC-DefenderSQL', 'Deny-Public-Endpoints'
    ) 'Default'
    & $mk 'connectivity' @('Enable-DDoS-VNET', 'Deploy-Private-DNS-Zones') 'DoNotEnforce'
    & $mk 'identity' @('Deny-Public-IP', 'Deploy-Diagnostics-NIC', 'Deny-MgmtPorts-Internet') 'Default'
    & $mk 'management' @('Deploy-Log-Analytics', 'Audit-ResourceRGLocation') 'Default'
    & $mk 'landingzones' @(
        'Deploy-Diagnostics-AKS', 'Deny-Priv-Esc-AKS', 'Deny-Storage-http',
        'Enforce-TLS-SSL-H224', 'Deploy-SQL-Auditing', 'Deploy-AKS-Policy',
        'Audit-AppGW-WAF', 'Deny-IP-forwarding', 'Deploy-Windows-DomainJoin'
    ) 'Default'
    & $mk 'corp' @('Deny-Public-IP', 'Deploy-Private-DNS-Zones', 'Deny-HybridNetworking') 'Default'
    & $mk 'online' @('Audit-PublicIpAddresses') 'DoNotEnforce'
    & $mk 'sandbox' @('Deny-Resource-Types-Sandbox') 'DoNotEnforce'
    & $mk 'decommissioned' @('Enforce-ALZ-Decomm') 'Default'
    # Assigned above the ALZ hierarchy, so the report marks these pre-existing.
    & $mk '7d3e5a91-6c48-4b02-9e17-2f8a45d6b013' @('Corp-Tag-Enforcement', 'Corp-Region-Restriction') 'Default'
)

$platform = [pscustomobject]@{
    ManagementGroups  = 13
    PolicyAssignments = $assignments.Count
    Assignments       = $assignments
}

$run = [pscustomobject]@{
    Conclusion = 'success'
    Url        = 'https://github.com/contoso-platform/alz-mgmt/actions/runs/12904471158'
}

$repo = [pscustomobject]@{
    Repo   = 'alz-mgmt'
    CdName = '02 Azure Landing Zones Continuous Delivery'
}

$rgs = @(
    'rg-alz-mgmt-state-eastus2-001'
    'rg-alz-mgmt-agents-eastus2-001'
    'rg-alz-mgmt-identity-eastus2-001'
    'rg-alz-mgmt-network-eastus2-001'
    'rg-management-eastus2'
    'rg-connectivity-eastus2'
)

$generated = New-ALZDeliveryReport -State $state -Platform $platform -Run $run `
    -ResourceGroups $rgs -Repo $repo -SessionStart (Get-Date).AddMinutes(-46) -AppVersion $appVersion

if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'sample-delivery-report.html' }

# The report renders its own delivery path, which is the real scratch folder and so
# carries the local username. Swap it for a fictional one before publishing.
$html = Get-Content -LiteralPath $generated -Raw
$html = $html.Replace([System.Net.WebUtility]::HtmlEncode($scratch), 'D:\ALZ\Contoso Ltd')
[System.IO.File]::WriteAllText($OutputPath, $html)
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue

# Fail loudly rather than publishing a sample that leaks the local environment.
foreach ($leak in @($env:USERNAME, 'AppData', 'OneDrive')) {
    if ($leak -and $html -match [regex]::Escape($leak)) {
        throw "Sample report still contains '$leak'. Not writing a publishable file."
    }
}

Write-Host "Sample report written to: $OutputPath" -ForegroundColor Green
Write-Host "  v$appVersion, $($assignments.Count) policy assignments across $(($assignments | Group-Object ManagementGroup).Count) management groups" -ForegroundColor DarkGray
return $OutputPath
