###########################################################################
# ALZREPORT.PSM1
# HTML DELIVERY REPORT
###########################################################################
# Purpose: Write the delivery summary to a self-contained HTML file so the
#          detail lives in a shareable artifact instead of scrolling past
#          in the console.
# Author: Zac Larsen
# Date: Created for the ALZ Accelerator orchestrator app
#
# Description:
# 1. New-ALZDeliveryReport renders the full run detail and returns the path.
# 2. The output is one file with inline CSS and no external references, so
#    it opens offline, emails cleanly, and prints for a closeout deck.
# Every value is HTML-encoded on the way in: delivery name and org names are
# free text from the interview and must not be able to inject markup.
# The report contains no secrets, because state never holds any.
#
# Prerequisites:
# - PowerShell 7.4+
#
# Usage: Imported by Start-ALZDelivery.ps1 via Import-Module.
###########################################################################

$script:ReportPhaseOrder = @('interview', 'preflight', 'config', 'bootstrap', 'proof', 'hcp', 'run')
$script:ReportPhaseLabels = @{
    interview = 'Plan (interview)'
    preflight = 'Prerequisites'
    config    = 'Generate config'
    bootstrap = 'Bootstrap'
    proof     = 'Deploy platform'
    hcp       = 'HCP state migration'
    run       = 'Next steps'
}

function ConvertTo-ALZHtml {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-ALZDeliveryReport {
    param(
        [hashtable]$State,
        $Platform,
        $Run,
        [string[]]$ResourceGroups = @(),
        $Repo,
        [datetime]$SessionStart,
        [string]$DataPath
    )
    $a = $State.answers
    $e = { param($v) ConvertTo-ALZHtml $v }

    $reportDir = Join-Path $State.deliveryPath 'reports'
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $reportDir "alz-delivery-$stamp.html"

    $failed = @($script:ReportPhaseOrder | Where-Object { $State.phaseStatus.$_ -eq 'failed' }).Count
    $pending = @($script:ReportPhaseOrder | Where-Object { $State.phaseStatus.$_ -eq 'pending' }).Count
    if ($failed -gt 0) { $overall = 'Attention needed'; $overallClass = 'bad' }
    elseif ($pending -gt 0) { $overall = 'In progress'; $overallClass = 'warn' }
    else { $overall = 'Complete'; $overallClass = 'good' }

    # --- Target -----------------------------------------------------------
    $scenarioText = if ($a.iacType -eq 'bicep') { "network_type: $($a.bicepNetworkType)" } else { $a.scenario }
    $vcsText = if ($a.vcs -eq 'azuredevops') { "Azure DevOps: $($a.adoOrg)/$($a.adoProject)" } else { "GitHub org: $($a.githubOrg)" }
    $runnerText = if ($a.selfHostedRunners) { 'Self-hosted in a VNet (private networking)' }
    elseif ($a.vcs -eq 'azuredevops') { 'Microsoft-hosted agents' } else { 'GitHub-hosted' }
    $stateText = if ($a.stateBackend -eq 'hcp') { "HCP Terraform ($($a.hcpOrg)/$($a.hcpWorkspace))" } else { 'Azure Storage (accelerator default)' }

    $targetRows = @()
    $addRow = {
        param($k, $v)
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return }
        $script:tmpRows += "<tr><th>$(& $e $k)</th><td>$(& $e $v)</td></tr>"
    }
    $script:tmpRows = @()
    & $addRow 'Delivery' $a.deliveryName
    & $addRow 'Primary region' $a.region
    & $addRow 'Secondary region' $a.regionSecondary
    & $addRow 'IaC language' $(if ($a.iacType) { $a.iacType } else { 'terraform' })
    & $addRow 'Topology' $scenarioText
    & $addRow 'Version control' $vcsText
    & $addRow 'State backend' $stateText
    & $addRow 'Runners' $runnerText
    & $addRow 'Parent management group' $(if ($a.parentManagementGroupId) { $a.parentManagementGroupId } else { 'Tenant Root Group' })
    & $addRow 'Security contact' $a.securityContactEmail
    & $addRow 'Apply approvers' ($a.applyApprovers -join ', ')
    $targetRows = $script:tmpRows -join "`n"

    # --- Subscriptions ----------------------------------------------------
    $subRows = @()
    foreach ($role in @('management', 'connectivity', 'identity', 'security')) {
        $id = $a.subscriptions.$role
        $val = if ([string]::IsNullOrWhiteSpace($id)) { '<span class="muted">not supplied</span>' } else { "<code>$(& $e $id)</code>" }
        $subRows += "<tr><th>$(& $e $role)</th><td>$val</td></tr>"
    }
    $subRows = $subRows -join "`n"

    # --- Deployed ---------------------------------------------------------
    $deployed = @()
    if ($Repo) {
        $repoOwner = if ($a.vcs -eq 'azuredevops') { "$($a.adoOrg)/$($a.adoProject)" } else { $a.githubOrg }
        $deployed += "<tr><th>Module repo</th><td>$(& $e "$repoOwner/$($Repo.Repo)")</td></tr>"
        if ($Repo.CdName) { $deployed += "<tr><th>CD workflow</th><td>$(& $e $Repo.CdName)</td></tr>" }
    }
    if ($Platform) {
        $deployed += "<tr><th>Management groups</th><td><span class='metric'>$(& $e $Platform.ManagementGroups)</span></td></tr>"
        $deployed += "<tr><th>Policy assignments</th><td><span class='metric'>$(& $e $Platform.PolicyAssignments)</span></td></tr>"
    }
    if ($ResourceGroups.Count -gt 0) {
        $rgList = ($ResourceGroups | ForEach-Object { "<li><code>$(& $e $_)</code></li>" }) -join ''
        $deployed += "<tr><th>Resource groups ($($ResourceGroups.Count))</th><td><ul class='tight'>$rgList</ul></td></tr>"
    }
    $deployedRows = if ($deployed.Count) { $deployed -join "`n" } else { "<tr><td colspan='2' class='muted'>Nothing recorded for this session.</td></tr>" }

    # --- Pipeline ---------------------------------------------------------
    $runSection = ''
    if ($Run) {
        $concl = if ($Run.Conclusion) { $Run.Conclusion } else { $Run.State }
        $cls = if ($concl -eq 'success') { 'good' } elseif ($concl -in @('failure', 'cancelled', 'timed_out')) { 'bad' } else { 'warn' }
        $linkCell = if ($Run.Url) { "<a href='$(& $e $Run.Url)'>$(& $e $Run.Url)</a>" } else { '<span class="muted">n/a</span>' }
        $runSection = @"
<h2>Last pipeline run</h2>
<table>
<tr><th>Result</th><td><span class="pill $cls">$(& $e $concl)</span></td></tr>
<tr><th>Run</th><td>$linkCell</td></tr>
</table>
"@
    }

    # --- Phases -----------------------------------------------------------
    $phaseRows = @()
    foreach ($p in $script:ReportPhaseOrder) {
        $st = $State.phaseStatus.$p
        $cls = switch ($st) { 'done' { 'good' } 'failed' { 'bad' } 'skipped' { 'muted-pill' } default { 'warn' } }
        $took = ''
        if ($State.phaseSeconds -and $State.phaseSeconds[$p]) {
            $secs = [double]$State.phaseSeconds[$p]
            $took = if ($secs -ge 60) { '{0:n0}m {1:n0}s' -f [math]::Floor($secs / 60), ($secs % 60) } else { '{0:n0}s' -f $secs }
        }
        $phaseRows += "<tr><td>$(& $e $script:ReportPhaseLabels[$p])</td><td><span class='pill $cls'>$(& $e $st)</span></td><td class='num'>$(& $e $took)</td></tr>"
    }
    $phaseRows = $phaseRows -join "`n"

    # --- Stats ------------------------------------------------------------
    $statRows = @()
    if ($SessionStart) { $statRows += "<tr><th>This session</th><td>$('{0:hh\:mm\:ss}' -f ((Get-Date) - $SessionStart))</td></tr>" }
    if ($State.stats) {
        $statRows += "<tr><th>Sessions</th><td>$(& $e $State.stats.sessions)</td></tr>"
        $statRows += "<tr><th>Bootstrap runs</th><td>$(& $e $State.stats.bootstrapRuns)</td></tr>"
        $statRows += "<tr><th>Pipeline runs watched</th><td>$(& $e $State.stats.pipelineRuns)</td></tr>"
    }
    if ($State.createdUtc) {
        $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($State.createdUtc).ToUniversalTime()
        $statRows += "<tr><th>Delivery age</th><td>$('{0}d {1}h' -f [int]$age.TotalDays, $age.Hours)</td></tr>"
    }
    $statRows += "<tr><th>Delivery folder</th><td><code>$(& $e $State.deliveryPath)</code></td></tr>"
    $statRows = $statRows -join "`n"

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $docLink = if ($a.vcs -eq 'azuredevops') { 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/' } else { 'https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ALZ delivery report - $(& $e $a.deliveryName)</title>
<style>
  :root { --line:#e2e6ea; --ink:#1b1f23; --dim:#6a737d; --accent:#0b5cab; }
  * { box-sizing:border-box; }
  body { margin:0; padding:32px; font:15px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif; color:var(--ink); background:#f6f8fa; }
  .wrap { max-width:900px; margin:0 auto; background:#fff; border:1px solid var(--line); border-radius:10px; padding:32px 36px; }
  h1 { margin:0 0 4px; font-size:22px; }
  h2 { margin:32px 0 10px; font-size:15px; text-transform:uppercase; letter-spacing:.06em; color:var(--dim); border-bottom:1px solid var(--line); padding-bottom:6px; }
  .sub { color:var(--dim); font-size:13px; margin-bottom:18px; }
  table { width:100%; border-collapse:collapse; }
  th,td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); vertical-align:top; font-size:14px; }
  th { width:230px; color:var(--dim); font-weight:600; }
  td.num { text-align:right; width:90px; color:var(--dim); }
  code { background:#f0f2f4; padding:1px 5px; border-radius:4px; font:13px ui-monospace,Consolas,monospace; }
  .pill { display:inline-block; padding:1px 9px; border-radius:11px; font-size:12px; font-weight:600; }
  .good { background:#e4f5e9; color:#136c31; }
  .warn { background:#fdf3d8; color:#8a6100; }
  .bad { background:#fbe6e6; color:#a01414; }
  .muted-pill { background:#eef0f2; color:#6a737d; }
  .muted { color:var(--dim); }
  .metric { font-size:17px; font-weight:600; color:var(--accent); }
  ul.tight { margin:0; padding-left:18px; }
  ul.tight li { margin:1px 0; }
  a { color:var(--accent); }
  .banner { display:flex; justify-content:space-between; align-items:center; gap:16px; }
  footer { margin-top:28px; padding-top:14px; border-top:1px solid var(--line); font-size:12px; color:var(--dim); }
  @media print { body { background:#fff; padding:0; } .wrap { border:0; } }
</style>
</head>
<body>
<div class="wrap">
  <div class="banner">
    <div>
      <h1>Azure Landing Zone delivery</h1>
      <div class="sub">$(& $e $a.deliveryName) &middot; generated $generated</div>
    </div>
    <span class="pill $overallClass">$(& $e $overall)</span>
  </div>

  <h2>Target</h2>
  <table>
$targetRows
  </table>

  <h2>Platform subscriptions</h2>
  <table>
$subRows
  </table>

  <h2>Deployed</h2>
  <table>
$deployedRows
  </table>

$runSection

  <h2>Phases</h2>
  <table>
$phaseRows
  </table>

  <h2>Session</h2>
  <table>
$statRows
  </table>

  <footer>
    Generated by ALZ Autopilot, a guided orchestration layer over the
    <a href="https://azure.github.io/Azure-Landing-Zones/accelerator/">Azure Landing Zones IaC Accelerator</a>.
    Prerequisites reference: <a href="$docLink">$(& $e $docLink)</a>.
    This report contains no credentials.
  </footer>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $path -Encoding UTF8
    return $path
}

Export-ModuleMember -Function New-ALZDeliveryReport
