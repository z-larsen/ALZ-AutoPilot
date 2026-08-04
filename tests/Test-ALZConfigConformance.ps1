###########################################################################
# TEST-ALZCONFIGCONFORMANCE.PS1
# OFFLINE SCHEMA CONFORMANCE TEST FOR GENERATED INPUTS.YAML
###########################################################################
# Purpose: Prove the generated inputs.yaml matches the accelerator's own
#          bootstrap module schema, without touching Azure, GitHub, or
#          Azure DevOps.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# The accelerator's bootstrap modules declare their inputs in variables.tf.
# This test parses those files and checks the generated config against them:
# 1. Every key emitted is a variable the module actually declares.
# 2. Every variable the module requires is emitted.
# It runs across the full matrix of GitHub/Azure DevOps and Terraform/Bicep,
# so a schema drift in a new accelerator version fails here instead of
# failing partway through someone's bootstrap.
#
# ── Parameters ──────────────────────────────────────────────
# ModulesRoot        Folder holding the extracted bootstrap modules
# Quiet              Print only the summary line
#
# Prerequisites:
# - PowerShell 7.4+
# - A bootstrap module already downloaded by a previous run. If none is
#   found the test skips rather than fails, so it is safe to run anywhere.
#
# Usage: .\tests\Test-ALZConfigConformance.ps1
###########################################################################

#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ModulesRoot,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\ALZState.psm1') -Force
Import-Module (Join-Path $repoRoot 'modules\ALZConfig.psm1') -Force

# Inputs the ALZ PowerShell module consumes itself. They are legitimate keys in
# inputs.yaml but are not Terraform variables of the bootstrap module, so they
# would otherwise look like undeclared keys.
$toolLevelKeys = @('bootstrap_module_name', 'starter_additional_files')

# Required variables the accelerator supplies on our behalf, so the generated
# config is not expected to carry them.
$acceleratorSuppliedKeys = @('module_folder_path')

$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Write-Result {
    param([string]$Status, [string]$Message, [string]$Detail)
    if ($Quiet -and $Status -eq 'PASS') { return }
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}" -f $Status, $Message) -ForegroundColor $color
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

# Pull variable names out of a Terraform variables.tf, flagging which are required.
# A variable is required when it declares no default.
function Get-ALZTfVariable {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    $map = @{}
    foreach ($m in [regex]::Matches($text, '(?ms)^variable\s+"([^"]+)"\s*\{(.*?)^\}')) {
        $map[$m.Groups[1].Value] = ($m.Groups[2].Value -notmatch '(?m)^\s*default\s*=')
    }
    return $map
}

# Only column-zero keys are top-level; indented lines are nested values such as
# the entries under subscription_ids.
function Get-YamlTopLevelKey {
    param([string]$Path)
    $keys = @()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:') { $keys += $Matches[1] }
    }
    return $keys
}

function Resolve-ModulesRoot {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ALZ'),
        (Join-Path $HOME 'Documents\ALZ'),
        $repoRoot
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($c in $candidates) {
        $hit = Get-ChildItem -LiteralPath $c -Recurse -Directory -Filter 'alz' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'github\variables.tf') } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

Write-Host ''
Write-Host '  ALZ config conformance (offline)' -ForegroundColor Cyan
Write-Host '  Generated inputs.yaml vs the accelerator bootstrap module schema' -ForegroundColor DarkGray
Write-Host ''

$alzModuleRoot = Resolve-ModulesRoot -Explicit $ModulesRoot
if (-not $alzModuleRoot) {
    Write-Result 'SKIP' 'No extracted bootstrap module found.' 'Run a bootstrap once, or pass -ModulesRoot pointing at the folder containing github\variables.tf.'
    Write-Host ''
    Write-Host '  Skipped: nothing to validate against.' -ForegroundColor Yellow
    exit 0
}
Write-Result 'INFO' "Bootstrap module: $alzModuleRoot"

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("alz-conformance-" + [guid]::NewGuid().ToString('N'))
try {
    foreach ($vcs in @('github', 'azuredevops')) {
        $varsFile = Join-Path $alzModuleRoot "$vcs\variables.tf"
        if (-not (Test-Path -LiteralPath $varsFile)) {
            Write-Result 'SKIP' "$vcs - variables.tf not present in this module version"
            continue
        }
        $declared = Get-ALZTfVariable -Path $varsFile
        $required = @($declared.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key })
        Write-Result 'INFO' ("{0} - {1} variables declared, {2} required" -f $vcs, $declared.Count, $required.Count)

        foreach ($iac in @('terraform', 'bicep')) {
            foreach ($selfHosted in @($false, $true)) {
                $label = "$vcs / $iac / self-hosted=$selfHosted"
                $state = New-ALZState -DeliveryPath $scratch
                $a = $state.answers
                $a.deliveryName = 'Conformance'
                $a.region = 'eastus2'
                $a.regionSecondary = 'westus3'
                $a.vcs = $vcs
                $a.githubOrg = 'contoso'
                $a.adoOrg = 'contoso'
                $a.adoProject = 'ALZ'
                $a.adoCreateProject = $true
                $a.securityContactEmail = 'soc@contoso.com'
                $a.subscriptions.management = [guid]::NewGuid().ToString()
                $a.subscriptions.connectivity = [guid]::NewGuid().ToString()
                $a.subscriptions.identity = [guid]::NewGuid().ToString()
                $a.subscriptions.security = [guid]::NewGuid().ToString()
                $a.applyApprovers = @(if ($vcs -eq 'azuredevops') { 'jane@contoso.com' } else { 'jane-doe' })
                $a.iacType = $iac
                $a.selfHostedRunners = $selfHosted
                $a.privateNetworking = $selfHosted

                $configFolder = Join-Path $scratch ("cfg-" + [guid]::NewGuid().ToString('N'))
                $yamlPath = Write-ALZInputsYaml -State $state -ConfigFolder $configFolder
                $keys = Get-YamlTopLevelKey -Path $yamlPath

                # 1. Nothing emitted that the module does not declare.
                $checks++
                $undeclared = @($keys | Where-Object { $_ -notin $toolLevelKeys -and -not $declared.ContainsKey($_) })
                if ($undeclared.Count -gt 0) {
                    $failures.Add("$label - undeclared key(s): $($undeclared -join ', ')")
                    Write-Result 'FAIL' "$label - emits key(s) the module does not declare" ($undeclared -join ', ')
                }
                else {
                    Write-Result 'PASS' "$label - all $($keys.Count) keys are declared by the module"
                }

                # 2. Nothing required is missing.
                $checks++
                $missing = @($required | Where-Object { $_ -notin $acceleratorSuppliedKeys -and $_ -notin $keys })
                if ($missing.Count -gt 0) {
                    $failures.Add("$label - missing required variable(s): $($missing -join ', ')")
                    Write-Result 'FAIL' "$label - missing required variable(s)" ($missing -join ', ')
                }
                else {
                    Write-Result 'PASS' "$label - every required variable is present"
                }

                # 3. The token placeholder is present and no credential was written.
                $checks++
                $body = Get-Content -LiteralPath $yamlPath -Raw
                $tokenKey = if ($vcs -eq 'azuredevops') { 'azure_devops_personal_access_token' } else { 'github_personal_access_token' }
                if ($body -notmatch [regex]::Escape($tokenKey) -or $body -notmatch 'Set via environment variable') {
                    $failures.Add("$label - token placeholder missing for $tokenKey")
                    Write-Result 'FAIL' "$label - token placeholder missing" $tokenKey
                }
                else {
                    Write-Result 'PASS' "$label - token is a placeholder, not a credential"
                }
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("  {0} of {1} checks failed" -f $failures.Count, $checks) -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "   - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  A failure here usually means the accelerator changed its schema.' -ForegroundColor Yellow
    Write-Host '  Compare the module variables.tf against Write-ALZInputsYaml.' -ForegroundColor Yellow
    exit 1
}

Write-Host ("  All {0} checks passed" -f $checks) -ForegroundColor Green
Write-Host ''
exit 0
