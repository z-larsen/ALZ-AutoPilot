###########################################################################
# ALZWORKLOAD.PSM1
# ATTACH CUSTOM TERRAFORM TO EXISTING DELIVERY INFRASTRUCTURE
###########################################################################

function Test-ALZWorkloadGuid { param([string]$Value) [guid]::TryParse($Value, [ref]([guid]::Empty)) }
function Test-ALZWorkloadNotEmpty { param([string]$Value) return -not [string]::IsNullOrWhiteSpace($Value) }
function Test-ALZWorkloadResourceGroup { param([string]$Value) return $Value -match '^[a-zA-Z0-9_.()-]{1,90}$' -and -not $Value.EndsWith('.') }
function Test-ALZWorkloadRepository { param([string]$Value) return $Value -match '^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}/[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$' }

function Test-ALZWorkloadRelativePath {
    param([string]$Value)
    if ($Value -eq '.') { return $true }
    if ($Value -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_./-]*$') { return $false }
    return @($Value.Split('/') | Where-Object { -not $_ -or $_.StartsWith('.') }).Count -eq 0
}

function Test-ALZWorkloadModulePath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or -not (Test-Path -LiteralPath $Value -PathType Container)) { return $false }
    return @(Get-ChildItem -LiteralPath $Value -File | Where-Object Name -Match '\.tf(\.json)?$').Count -gt 0
}

function Set-ALZDeliveryType {
    param([hashtable]$State)
    Write-ALZSection 'What are you deploying?'
    Write-Host '    1. Platform landing zone  (management groups, policy, networking)' -ForegroundColor White
    Write-Host '    2. New workload / modify existing  (attach to an existing repository; no bootstrap)' -ForegroundColor White
    $typePick = Read-ALZValue -Prompt 'Choose (1/2)' -Default '1' -Validator { param($v) $v -in @('1', '2') }
    $State.answers['deliveryType'] = if ($typePick -eq '2') { 'workload' } else { 'landingzone' }
    Save-ALZState -State $State
    return $State
}

function Invoke-ALZWorkloadInterview {
    param([hashtable]$State, [string]$DataPath)
    $answers = $State.answers
    $previousRepository = $answers.workloadRepository
    $previousRoot = $answers.workloadRoot
    $previousOperation = $answers.workloadOperation
    Write-ALZBanner -Title 'Attach a Terraform workload' -Subtitle 'Reuse an existing GitHub repository and Azure state storage. Bootstrap is skipped.'
    Write-Host '    1. New workload (unused repository folder and state key)' -ForegroundColor White
    Write-Host '    2. Modify existing deployment (existing folder and state)' -ForegroundColor White
    $choice = Read-ALZValue -Prompt 'Operation (1/2)' -Default $(if ($previousOperation -eq 'update') { '2' } else { '1' }) -Validator { param($Value) $Value -in @('1', '2') }
    $answers.workloadOperation = if ($choice -eq '2') { 'update' } else { 'new' }
    $answers.customModulePath = Read-ALZValue -Prompt 'Full path to your custom Terraform configuration' -Default $answers.customModulePath -Validator ${function:Test-ALZWorkloadModulePath} -ValidationMessage 'Select a folder containing .tf or .tf.json files.'
    $answers.deliveryName = Read-ALZValue -Prompt 'Delivery label (does not rename Azure resources)' -Default $(if ($answers.deliveryName) { $answers.deliveryName } else { 'workload' }) -Validator ${function:Test-ALZWorkloadNotEmpty}
    $answers.workloadRepository = Read-ALZValue -Prompt 'Existing GitHub repository (owner/repository)' -Default $answers.workloadRepository -Validator ${function:Test-ALZWorkloadRepository} -ValidationMessage 'Specify the exact owner/repository, not an organization alone.'
    $slug = ($answers.deliveryName.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $slug) { $slug = 'workload' }
    $defaultRoot = if ($answers.workloadRoot) { $answers.workloadRoot } elseif ($answers.workloadOperation -eq 'update') { '.' } else { "workloads/$slug" }
    $answers.workloadRoot = Read-ALZValue -Prompt 'Terraform root relative to the repository' -Default $defaultRoot -Validator ${function:Test-ALZWorkloadRelativePath} -ValidationMessage 'Use a relative forward-slash path without parent traversal or hidden directories.'
    if ($answers.workloadOperation -eq 'new' -and $answers.workloadRoot -eq '.') { throw 'A new workload requires its own repository subfolder; the existing root is protected.' }
    $answers.subscriptions.management = Read-ALZValue -Prompt 'Target workload subscription ID' -Default $answers.subscriptions.management -Validator ${function:Test-ALZWorkloadGuid} -ValidationMessage 'Enter a subscription GUID.'
    $answers.workloadResourceGroup = Read-ALZValue -Prompt 'Target resource group to inspect (not created by this step)' -Default $(if ($answers.workloadResourceGroup) { $answers.workloadResourceGroup } else { "rg-$slug" }) -Validator ${function:Test-ALZWorkloadResourceGroup}
    $attachmentChanged = $previousRepository -ne $answers.workloadRepository -or $previousRoot -cne $answers.workloadRoot -or $previousOperation -ne $answers.workloadOperation
    $resetBackend = $attachmentChanged
    if (-not $resetBackend -and $answers.workloadBackendBinding) {
        $resetBackend = Read-ALZConfirm -Prompt 'Explicitly reselect the saved backend binding (no state migration)?' -Default $false
    }
    if ($previousRepository -ne $answers.workloadRepository) {
        $answers.workloadRepositoryId = ''
        $answers.workloadBranch = ''
    }
    if ($resetBackend) {
        $answers.workloadBackend = $null
        $answers.workloadBackendBinding = ''
        $answers.workloadStateLineage = ''
    }
    $answers.githubOrg = $answers.workloadRepository.Split('/')[0]
    $answers.vcs = 'github'
    $answers.iacType = 'terraform'
    $answers.stateBackend = 'azurerm'
    $answers.workloadAttachmentVersion = 1
    $answers.workloadUsePipeline = Read-ALZConfirm -Prompt 'Prepare PRs and wire the existing ALZ GitHub pipeline?' -Default $false
    if ($answers.workloadUsePipeline) {
        $answers.workloadValidationMode = if (Read-ALZConfirm -Prompt 'Run private-backend state validation on the existing self-hosted runner instead of this computer?' -Default $true) { 'runner' } else { 'local' }
    }
    else { $answers.workloadValidationMode = 'local' }
    Set-ALZPhaseStatus -State $State -Phase 'interview' -Status 'done'
    return $State
}

function Copy-ALZWorkloadModuleFiles {
    param([string]$Source, [string]$Destination, [switch]$AllowOverwrite)
    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ((Get-Item -LiteralPath $sourcePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked source folders are not supported.' }
    if ($sourcePath -eq $destinationPath -or $destinationPath.StartsWith($sourcePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $sourcePath.StartsWith($destinationPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and proposal folders must not overlap.'
    }
    $pendingFolders = [Collections.Generic.Queue[string]]::new()
    $pendingFolders.Enqueue($sourcePath)
    $filesToCopy = @()
    while ($pendingFolders.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pendingFolders.Dequeue() -Force) {
            if ($item.Name -in @('.git', '.github', '.terraform', '.venv', 'node_modules', 'state-backups')) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source paths are not supported: $($item.Name)" }
            if ($item.PSIsContainer) { $pendingFolders.Enqueue($item.FullName); continue }
            if ($item.Name -match '(?i)(\.tfstate($|\.)|\.tfplan($|\.)|^tfplan($|\.)|^\.env($|\.))') { continue }
            $relativePath = [IO.Path]::GetRelativePath($sourcePath, $item.FullName)
            $targetPath = Join-Path $destinationPath $relativePath
            $probePath = $targetPath
            while ($probePath) {
                if ((Test-Path -LiteralPath $probePath) -and ((Get-Item -LiteralPath $probePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked destination paths are not supported.' }
                $probePath = Split-Path $probePath -Parent
            }
            if ((Test-Path -LiteralPath $targetPath) -and -not $AllowOverwrite) { throw "New workload would overwrite an existing file: $relativePath" }
            $filesToCopy += [pscustomobject]@{ Source = $item.FullName; Target = $targetPath }
        }
    }
    foreach ($file in $filesToCopy) {
        $null = New-Item -ItemType Directory -Path (Split-Path $file.Target -Parent) -Force
        Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force -ErrorAction Stop
    }
}

function Invoke-ALZWorkloadContentSwap {
    param([hashtable]$State, [string]$GitHubToken)
    throw 'Direct repository replacement is disabled. Use the workload attachment flow to prepare a reviewed local proposal.'
}

function Get-ALZWorkloadRepositoryContext {
    param([hashtable]$State, [string]$Token)
    $answers = $State.answers
    if (-not (Test-ALZWorkloadRepository $answers.workloadRepository)) { throw 'Select an exact GitHub owner/repository.' }
    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'ALZ-AutoPilot' }
    $baseUri = "https://api.github.com/repos/$($answers.workloadRepository)"
    $repository = Invoke-RestMethod -Uri $baseUri -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
    if ($repository.full_name -ne $answers.workloadRepository -or $repository.archived -or $repository.disabled -or -not $repository.id) { throw 'The selected repository is unavailable, renamed, or archived.' }
    if ($answers.workloadRepositoryId -and "$($repository.id)" -ne "$($answers.workloadRepositoryId)") { throw 'The repository identity changed. Re-select the attachment instead of reusing its saved state binding.' }
    $branch = if ($answers.workloadBranch) { $answers.workloadBranch } else { $repository.default_branch }
    if (-not $branch) { throw 'An existing repository with an initialized branch is required.' }
    $branchInfo = Invoke-RestMethod -Uri "$baseUri/branches/$([uri]::EscapeDataString($branch))" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
    $tree = Invoke-RestMethod -Uri "$baseUri/git/trees/$($branchInfo.commit.sha)?recursive=1" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
    if ($tree.truncated -isnot [bool] -or $tree.truncated -or $null -eq $tree.tree -or -not $branchInfo.commit.sha) { throw 'The repository inventory is incomplete; no greenfield assumption is safe.' }
    $variables = @{}
    $page = 1
    do {
        $variablePage = Invoke-RestMethod -Uri "$baseUri/actions/variables?per_page=100&page=$page" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
        foreach ($variable in $variablePage.variables) { $variables[$variable.name] = $variable.value }
        $page++
    } while (@($variablePage.variables).Count -eq 100)
    return [pscustomobject]@{ Repository = $repository.full_name; Id = "$($repository.id)"; Branch = $branch; Commit = $branchInfo.commit.sha; Files = @($tree.tree | Where-Object type -EQ 'blob' | ForEach-Object path); Variables = $variables }
}

function Read-ALZWorkloadBackend {
    param([hashtable]$State, $Repository)
    $saved = if ($State.answers.workloadBackend) { $State.answers.workloadBackend } else { @{} }
    $defaultKey = if ($State.answers.workloadOperation -eq 'update') { 'terraform.tfstate' } else { "$($State.answers.workloadRoot)/terraform.tfstate" }
    $fields = @(
        @{ Name = 'subscriptionId'; Prompt = 'Existing state storage subscription ID'; Default = $Repository.Variables.AZURE_SUBSCRIPTION_ID; Validate = ${function:Test-ALZWorkloadGuid} },
        @{ Name = 'tenantId'; Prompt = 'Expected Azure tenant ID'; Default = $Repository.Variables.AZURE_TENANT_ID; Validate = ${function:Test-ALZWorkloadGuid} },
        @{ Name = 'resourceGroup'; Prompt = 'Existing state storage resource group'; Default = $Repository.Variables.BACKEND_AZURE_RESOURCE_GROUP_NAME; Validate = ${function:Test-ALZWorkloadResourceGroup} },
        @{ Name = 'storageAccount'; Prompt = 'Existing state storage account'; Default = $Repository.Variables.BACKEND_AZURE_STORAGE_ACCOUNT_NAME; Validate = { param($Value) $Value -match '^[a-z0-9]{3,24}$' } },
        @{ Name = 'container'; Prompt = 'Existing state container'; Default = $Repository.Variables.BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME; Validate = { param($Value) $Value -match '^[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]$' -and $Value -notmatch '--' } },
        @{ Name = 'key'; Prompt = 'Exact state blob key (default Terraform workspace)'; Default = $defaultKey; Validate = { param($Value) $Value -ne '.' -and (Test-ALZWorkloadRelativePath $Value) } }
    )
    $backend = [ordered]@{ workspace = 'default' }
    foreach ($field in $fields) {
        $defaultValue = if ($saved[$field.Name]) { $saved[$field.Name] } else { $field.Default }
        $backend[$field.Name] = Read-ALZValue -Prompt $field.Prompt -Default $defaultValue -Validator $field.Validate
    }
    $newBinding = $backend | ConvertTo-Json -Compress
    if ($State.answers.workloadBackendBinding -and $State.answers.workloadBackendBinding -cne $newBinding) { throw 'The saved backend binding changed. Re-run the interview to explicitly select a different attachment.' }
    $State.answers.workloadBackend = $backend
    $State.answers.workloadBackendBinding = $newBinding
    Save-ALZState -State $State
    return $backend
}

function Invoke-ALZWorkloadAzureRead {
    param([string[]]$Arguments)
    $output = @(& az @Arguments --only-show-errors --output json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Read-only Azure discovery failed. Check subscription access, Storage Blob Data Reader permission, and private endpoint connectivity. Failure is not an empty environment.' }
    try { $document = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate }
    catch { throw 'Azure discovery returned invalid JSON; environment and state status are unknown.' }
    return ,$document
}

function Get-ALZWorkloadSnapshot {
    param([hashtable]$State)
    $answers = $State.answers
    $backend = $answers.workloadBackend
    if (-not $backend -or $backend.workspace -ne 'default') { throw 'An explicit Azure Storage backend using the default Terraform workspace is required.' }
    foreach ($subscriptionId in @($answers.subscriptions.management, $backend.subscriptionId) | Select-Object -Unique) {
        $account = Invoke-ALZWorkloadAzureRead @('account', 'show', '--subscription', $subscriptionId)
        if ($account.id -ne $subscriptionId -or $account.tenantId -ne $backend.tenantId) { throw 'The selected subscription or Azure tenant does not match the attachment.' }
    }
    $storage = Invoke-ALZWorkloadAzureRead @('storage', 'account', 'show', '--name', $backend.storageAccount, '--resource-group', $backend.resourceGroup, '--subscription', $backend.subscriptionId)
    $expectedStorageId = "/subscriptions/$($backend.subscriptionId)/resourceGroups/$($backend.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($backend.storageAccount)"
    if ($storage.id -ne $expectedStorageId) { throw 'The existing storage account does not match the selected backend.' }
    $storageArguments = @('--account-name', $backend.storageAccount, '--auth-mode', 'login', '--subscription', $backend.subscriptionId)
    $container = Invoke-ALZWorkloadAzureRead (@('storage', 'container', 'exists', '--name', $backend.container) + $storageArguments)
    if ($container.exists -isnot [bool] -or -not $container.exists) { throw 'The selected state container must already exist and be readable. No storage will be provisioned.' }
    $blobArguments = @('--container-name', $backend.container, '--name', $backend.key) + $storageArguments
    $blob = Invoke-ALZWorkloadAzureRead (@('storage', 'blob', 'exists') + $blobArguments)
    if ($blob.exists -isnot [bool]) { throw 'State existence could not be determined.' }
    $lineage = ''
    $serial = 0
    $managedCount = 0
    if ($blob.exists) {
        $temporaryState = Join-Path ([IO.Path]::GetTempPath()) ("alz-state-$([guid]::NewGuid().ToString('N')).json")
        try {
            $null = Invoke-ALZWorkloadAzureRead (@('storage', 'blob', 'download', '--file', $temporaryState, '--overwrite', 'true', '--no-progress') + $blobArguments)
            try { $terraformState = Get-Content -LiteralPath $temporaryState -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop }
            catch { throw 'The selected state snapshot could not be decoded. State contents are omitted from this error.' }
            if ($terraformState.version -ne 4 -or -not (Test-ALZWorkloadGuid $terraformState.lineage)) { throw 'The selected blob is not a supported Terraform state snapshot.' }
            $lineage = $terraformState.lineage
            $serial = $terraformState.serial
            foreach ($resource in $terraformState.resources | Where-Object mode -EQ 'managed') {
                if ($resource.instances) { $managedCount += @($resource.instances).Count }
            }
        }
        finally { if (Test-Path -LiteralPath $temporaryState) { Remove-Item -LiteralPath $temporaryState -Force -ErrorAction Stop } }
    }
    $groupExists = Invoke-ALZWorkloadAzureRead @('group', 'exists', '--name', $answers.workloadResourceGroup, '--subscription', $answers.subscriptions.management)
    if ($groupExists -isnot [bool]) { throw 'The Azure resource group inventory is unknown.' }
    $resources = @()
    if ($groupExists) { $resources = Invoke-ALZWorkloadAzureRead @('resource', 'list', '--resource-group', $answers.workloadResourceGroup, '--subscription', $answers.subscriptions.management) }
    return [pscustomobject]@{ StateExists = $blob.exists; ManagedResourceCount = $managedCount; Lineage = $lineage; Serial = $serial; AzureResourceCount = @($resources).Count; ResourceGroupExists = $groupExists }
}

function Get-ALZWorkloadClassification {
    param([ValidateSet('new', 'update')][string]$Operation, [AllowNull()][Nullable[bool]]$StateExists, [int]$ManagedResourceCount, [string]$Lineage, [string]$ExpectedLineage, [bool]$RootExists, [int]$AzureResourceCount = -1, [bool]$ResourceGroupExists)
    if ($null -eq $StateExists -or $AzureResourceCount -lt 0) { throw 'Discovery is incomplete; do not assume greenfield.' }
    if ($Operation -eq 'new' -and ($StateExists -or $RootExists)) { throw 'New workload requires an unused repository folder and state key. Select modify existing for an existing deployment.' }
    if ($Operation -eq 'update' -and (-not $StateExists -or -not $RootExists -or $ManagedResourceCount -lt 1 -or -not (Test-ALZWorkloadGuid $Lineage))) { throw 'An update requires an existing Terraform root and nonempty, readable Terraform state.' }
    if ($ExpectedLineage -and $ExpectedLineage -ne $Lineage) { throw 'Terraform state lineage changed; the selected state does not match this attachment.' }
    return [pscustomobject]@{
        Environment = if ($StateExists -or $ResourceGroupExists -or $AzureResourceCount -gt 0) { 'brownfield' } else { 'greenfield' }
        Operation = $Operation
        ImportReviewRequired = ($Operation -eq 'new' -and ($ResourceGroupExists -or $AzureResourceCount -gt 0))
    }
}

function Copy-ALZWorkloadRepository {
    param($Repository, [string]$Token, [string]$Checkout)
    $oldCount = $env:GIT_CONFIG_COUNT
    $configIndex = if ($oldCount) { [int]$oldCount } else { 0 }
    $keyName = "GIT_CONFIG_KEY_$configIndex"
    $valueName = "GIT_CONFIG_VALUE_$configIndex"
    $oldKey = [Environment]::GetEnvironmentVariable($keyName)
    $oldValue = [Environment]::GetEnvironmentVariable($valueName)
    try {
        $env:GIT_CONFIG_COUNT = "$($configIndex + 1)"
        [Environment]::SetEnvironmentVariable($keyName, 'http.https://github.com/.extraheader')
        $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$Token"))
        [Environment]::SetEnvironmentVariable($valueName, "Authorization: Basic $authorization")
        $null = & git clone --quiet --depth 1 --single-branch --branch $Repository.Branch "https://github.com/$($Repository.Repository).git" $Checkout 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Could not clone the explicitly selected repository. No remote changes were made.' }
    }
    finally {
        $env:GIT_CONFIG_COUNT = $oldCount
        [Environment]::SetEnvironmentVariable($keyName, $oldKey)
        [Environment]::SetEnvironmentVariable($valueName, $oldValue)
    }
    $headCommit = & git -C $Checkout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $headCommit -ne $Repository.Commit) { throw 'The repository changed after discovery. Re-run before preparing an update.' }
}

function New-ALZWorkloadProposal {
    param([hashtable]$State, $Repository, [string]$Token)
    $answers = $State.answers
    if (-not (Test-ALZWorkloadRelativePath $answers.workloadRoot)) { throw 'Unsafe repository-relative root.' }
    $proposalFolder = Join-Path $State.deliveryPath ("workload-proposals/$([guid]::NewGuid().ToString('N'))")
    $checkout = Join-Path $proposalFolder 'repository'
    $sourcePath = (Resolve-Path -LiteralPath $answers.customModulePath).ProviderPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetFullPath($checkout).StartsWith($sourcePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'The proposal folder cannot be inside the custom configuration source.' }
    $null = New-Item -ItemType Directory -Path $proposalFolder -Force
    Copy-ALZWorkloadRepository -Repository $Repository -Token $Token -Checkout $checkout
    $targetRoot = if ($answers.workloadRoot -eq '.') { $checkout } else { Join-Path $checkout $answers.workloadRoot }
    if ($answers.workloadOperation -eq 'new' -and (Test-Path -LiteralPath $targetRoot)) { throw 'The new workload folder already exists in the checkout; choose an unused folder.' }
    Copy-ALZWorkloadModuleFiles -Source $answers.customModulePath -Destination $targetRoot -AllowOverwrite:($answers.workloadOperation -eq 'update')
    $backend = $answers.workloadBackend
    $backendPath = Join-Path $proposalFolder 'backend.tfbackend.json'
    [ordered]@{
        resource_group_name = $backend.resourceGroup
        storage_account_name = $backend.storageAccount
        container_name = $backend.container
        key = $backend.key
        subscription_id = $backend.subscriptionId
        tenant_id = $backend.tenantId
        use_azuread_auth = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $backendPath -Encoding UTF8
    return [pscustomobject]@{ Checkout = $checkout; Root = $targetRoot; BackendConfig = $backendPath; BaseCommit = $Repository.Commit }
}

function Write-ALZWorkloadWorkflow {
        param([hashtable]$State, [string]$Checkout)
        $answers = $State.answers
        $backend = $answers.workloadBackend
        $pipeline = $answers.workloadPipeline
        if (-not (Test-ALZWorkloadRepository $answers.workloadRepository) -or -not (Test-ALZWorkloadRelativePath $answers.workloadRoot)) { throw 'An explicit repository and safe Terraform root are required.' }
        if (-not (Test-ALZWorkloadGuid $answers.subscriptions.management) -or -not (Test-ALZWorkloadGuid $backend.subscriptionId) -or -not (Test-ALZWorkloadGuid $backend.tenantId)) { throw 'Target and backend subscription/tenant IDs must be explicit GUIDs.' }
        if ($backend.workspace -ne 'default' -or $backend.key -eq '.' -or -not (Test-ALZWorkloadRelativePath $backend.key)) { throw 'An explicit state key in the default workspace is required.' }
        foreach ($environment in @($pipeline.planEnvironment, $pipeline.applyEnvironment)) {
                if ($environment -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$') { throw 'Select existing plan and apply environments.' }
        }
        if ($pipeline.planEnvironment -eq $pipeline.applyEnvironment) { throw 'Plan and apply must use separate environments and identities.' }
        $templatesRepository = if ($pipeline.templatesRepository) { $pipeline.templatesRepository } else { "$($answers.workloadRepository)-templates" }
        if (-not (Test-ALZWorkloadRepository $templatesRepository)) { throw 'Select an exact templates repository.' }
        $branch = if ($answers.workloadBranch) { $answers.workloadBranch } else { 'main' }
        if ($branch -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_/-]*$' -or $branch -match '//') { throw 'The selected default branch is not supported for workflow generation.' }
        $version = if ($pipeline.terraformVersion) { $pipeline.terraformVersion } else { '1.14.9' }
        if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Pin a specific Terraform version.' }
        $stateIdentity = "$($backend.subscriptionId)/$($backend.storageAccount)/$($backend.container)/$($backend.key)"
        $identityHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stateIdentity))).ToLowerInvariant().Substring(0, 16)
        $workflowName = "autopilot-$identityHash"
        $configRelativePath = ".github/autopilot/$workflowName.json"
        $workflowRelativePath = ".github/workflows/$workflowName.yml"
        $configPath = Join-Path $Checkout $configRelativePath
        $workflowPath = Join-Path $Checkout $workflowRelativePath
        $null = New-Item -ItemType Directory -Path (Split-Path $configPath -Parent), (Split-Path $workflowPath -Parent) -Force
        $config = [ordered]@{
                schemaVersion = 1
            bindingId = $identityHash
                repository = $answers.workloadRepository
                root = $answers.workloadRoot
                targetSubscriptionId = $answers.subscriptions.management
                targetResourceGroup = $answers.workloadResourceGroup
            allowedSubscriptionIds = if ($pipeline.allowedSubscriptionIds) { @($pipeline.allowedSubscriptionIds) } else { @($answers.subscriptions.management) }
            managedResourceGroups = if ($pipeline.managedResourceGroups) { @($pipeline.managedResourceGroups) } else { @(@{ subscriptionId = $answers.subscriptions.management; name = $answers.workloadResourceGroup }) }
            approvedTemplateHashes = if ($pipeline.approvedTemplateHashes) { @($pipeline.approvedTemplateHashes) } else { @() }
            pipeline = @{ templatesRepository = $templatesRepository; planEnvironment = $pipeline.planEnvironment; applyEnvironment = $pipeline.applyEnvironment }
                backend = $backend
                operation = $answers.workloadOperation
                expectedLineage = $answers.workloadStateLineage
                terraformVersion = $version
        }
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $rootFilter = if ($answers.workloadRoot -eq '.') { '**' } else { "$($answers.workloadRoot)/**" }
        $workflow = @'
name: __NAME__
on:
    pull_request:
        branches: [__BRANCH__]
        paths: [__ROOT_FILTER__, __CONFIG_PATH__, __WORKFLOW_PATH__]
    push:
        branches: [__BRANCH__]
        paths: [__ROOT_FILTER__, __CONFIG_PATH__, __WORKFLOW_PATH__]
    workflow_dispatch:
        inputs:
            action:
                description: Terraform operation
                type: choice
                default: plan
                options: [plan, apply]
            confirmation:
                description: Enter the target subscription ID to authorize an apply
                type: string
                default: ''
            plan_run_id:
                description: Successful reviewed main-branch plan run ID (apply only)
                type: string
                default: ''
            plan_attempt:
                description: Reviewed plan attempt (apply only)
                type: string
                default: '1'
            template_confirmation:
                description: Reviewed nested ARM template hash, if the plan includes one
                type: string
                default: ''
permissions:
    contents: read
concurrency:
    group: autopilot-state-__STATE_HASH__
    cancel-in-progress: false
jobs:
    terraform:
        if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
        permissions:
            contents: read
            id-token: write
            actions: read
        uses: __TEMPLATES_REPOSITORY__/.github/workflows/cd-template.yaml@main
        with:
            autopilot_configuration: '__CONFIG_PATH__'
            autopilot_target_subscription_id: '__TARGET_SUBSCRIPTION__'
            autopilot_plan_environment: '__PLAN_ENVIRONMENT__'
            autopilot_apply_environment: '__APPLY_ENVIRONMENT__'
            terraform_cli_version: '__TERRAFORM_VERSION__'
            autopilot_enable_apply: ${{ github.event_name == 'workflow_dispatch' && inputs.action == 'apply' && github.ref == 'refs/heads/__BRANCH__' }}
            autopilot_confirmation: ${{ inputs.confirmation || '' }}
            autopilot_plan_run_id: ${{ inputs.plan_run_id || '' }}
            autopilot_plan_attempt: ${{ inputs.plan_attempt || '1' }}
            autopilot_template_confirmation: ${{ inputs.template_confirmation || '' }}
'@
        $replacements = [ordered]@{
                '__NAME__' = $workflowName
                '__BRANCH__' = $branch
                '__ROOT_FILTER__' = $rootFilter
                '__CONFIG_PATH__' = $configRelativePath
                '__WORKFLOW_PATH__' = $workflowRelativePath
                '__STATE_HASH__' = $identityHash
                '__TEMPLATES_REPOSITORY__' = $templatesRepository
                '__TARGET_SUBSCRIPTION__' = $answers.subscriptions.management
                '__PLAN_ENVIRONMENT__' = $pipeline.planEnvironment
                '__APPLY_ENVIRONMENT__' = $pipeline.applyEnvironment
                '__TERRAFORM_VERSION__' = $version
        }
        foreach ($entry in $replacements.GetEnumerator()) { $workflow = $workflow.Replace($entry.Key, $entry.Value) }
        $workflow | Set-Content -LiteralPath $workflowPath -Encoding UTF8
        $accessScript = Join-Path (Split-Path $configPath -Parent) 'Initialize-WorkloadAccess.ps1'
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'data/Initialize-WorkloadAccess.ps1') -Destination $accessScript -Force
        $bindingPath = Join-Path (Join-Path $Checkout $answers.workloadRoot) 'autopilot.binding.tf.json'
        $null = New-Item -ItemType Directory -Path (Split-Path $bindingPath -Parent) -Force
        @{ resource = @{ terraform_data = @{ autopilot_binding = @{ input = @{ bindingId = $identityHash; repository = $answers.workloadRepository; root = $answers.workloadRoot } } } } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bindingPath -Encoding UTF8
        return [pscustomobject]@{ Workflow = $workflowPath; Config = $configPath; WorkflowRelativePath = $workflowRelativePath; ConfigurationRelativePath = $configRelativePath; TemplatesRepository = $templatesRepository; StateIdentity = $stateIdentity }
}

    function Write-ALZWorkloadTemplate {
        param([string]$Path)
        Import-Module powershell-yaml -ErrorAction Stop
        $template = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml -Ordered
        if (-not $template.on.workflow_call -or -not $template.jobs) { throw 'The selected file is not an existing reusable ALZ workflow.' }
        $inputs = $template.on.workflow_call.inputs
        $inputs['autopilot_configuration'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_target_subscription_id'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_plan_environment'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_apply_environment'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_runner_labels'] = @{ type = 'string'; default = '["self-hosted","Linux","X64"]' }
        $inputs['autopilot_enable_apply'] = @{ type = 'boolean'; default = $false }
        $inputs['autopilot_confirmation'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_plan_run_id'] = @{ type = 'string'; default = '' }
        $inputs['autopilot_plan_attempt'] = @{ type = 'string'; default = '1' }
        $inputs['autopilot_template_confirmation'] = @{ type = 'string'; default = '' }
        foreach ($jobName in @($template.jobs.Keys)) {
            if ($jobName -like 'autopilot-*') { continue }
            $job = $template.jobs[$jobName]
            $previousCondition = "$($job['if'])"
            if ($previousCondition -like '*inputs.autopilot_configuration*') { continue }
            if ($previousCondition.StartsWith('${{') -and $previousCondition.EndsWith('}}')) { $previousCondition = $previousCondition.Substring(3, $previousCondition.Length - 5).Trim() }
            $job['if'] = if ($previousCondition) { "inputs.autopilot_configuration == '' && ($previousCondition)" } else { "inputs.autopilot_configuration == ''" }
        }
        $dataFolder = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
        $jobs = Get-Content -LiteralPath (Join-Path $dataFolder 'workload-jobs.yml') -Raw | ConvertFrom-Yaml -Ordered
        $scriptContent = (Get-Content -LiteralPath (Join-Path $dataFolder 'workload-pipeline.ps1') -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
        $jobs['autopilot-plan'].steps | Where-Object name -EQ 'Validate, discover state, and plan' | ForEach-Object { $_.run = "& {`n$scriptContent`n} -Stage Plan -Configuration `$env:AUTOPILOT_CONFIGURATION" }
        $jobs['autopilot-apply'].steps | Where-Object name -EQ 'Verify and apply saved plan' | ForEach-Object { $_.run = "& {`n$scriptContent`n} -Stage Apply -Configuration `$env:AUTOPILOT_CONFIGURATION" }
        $jobs['autopilot-apply'].steps | Where-Object name -EQ 'Initialize reviewed workload' | ForEach-Object { $_.run = "& {`n$scriptContent`n} -Stage Initialize -Configuration `$env:AUTOPILOT_CONFIGURATION" }
        foreach ($jobName in $jobs.Keys) { $template.jobs[$jobName] = $jobs[$jobName] }
        $serializedTemplate = ($template | ConvertTo-Yaml -Options DisableAliases).Replace("`r`n", "`n").TrimEnd() + "`n"
        Set-Content -LiteralPath $Path -Value $serializedTemplate -Encoding UTF8 -NoNewline
        return $Path
    }

    function Read-ALZWorkloadPipeline {
        param([hashtable]$State)
        $answers = $State.answers
        $existing = if ($answers.workloadPipeline) { $answers.workloadPipeline } else { @{} }
        $repoLeaf = $answers.workloadRepository.Split('/')[1]
        $pipeline = [ordered]@{
            templatesRepository = Read-ALZValue -Prompt 'Existing ALZ templates repository (owner/repository)' -Default $(if ($existing.templatesRepository) { $existing.templatesRepository } else { "$($answers.workloadRepository)-templates" }) -Validator ${function:Test-ALZWorkloadRepository}
            planEnvironment = Read-ALZValue -Prompt 'Existing plan environment' -Default $(if ($existing.planEnvironment) { $existing.planEnvironment } else { "$repoLeaf-plan" }) -Validator { param($Value) $Value -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$' }
            applyEnvironment = Read-ALZValue -Prompt 'Existing apply environment' -Default $(if ($existing.applyEnvironment) { $existing.applyEnvironment } else { "$repoLeaf-apply" }) -Validator { param($Value) $Value -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$' }
            terraformVersion = '1.14.9'
            runnerLabels = @('self-hosted', 'Linux', 'X64')
            allowedSubscriptionIds = @($answers.subscriptions.management)
            managedResourceGroups = @(@{ subscriptionId = $answers.subscriptions.management; name = $answers.workloadResourceGroup })
        }
        if ($existing.allowedSubscriptionIds) { $pipeline.allowedSubscriptionIds = @($existing.allowedSubscriptionIds) }
        if ($existing.managedResourceGroups) { $pipeline.managedResourceGroups = @($existing.managedResourceGroups) }
        if ($existing.approvedTemplateHashes) { $pipeline['approvedTemplateHashes'] = @($existing.approvedTemplateHashes) }
        $answers.workloadPipeline = $pipeline
        Save-ALZState -State $State
        return $pipeline
    }

    function Test-ALZWorkloadPipelineAccess {
        param([hashtable]$State, [string]$Token)
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'ALZ-AutoPilot' }
        $answers = $State.answers
        $baseUri = "https://api.github.com/repos/$($answers.workloadRepository)"
        $runners = Invoke-RestMethod -Uri "$baseUri/actions/runners?per_page=100" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
        if (@($runners.runners | Where-Object status -EQ 'online').Count -lt 1) { throw 'No existing online runner is available to validate private state. Bootstrap will not be run.' }
        foreach ($environment in @($answers.workloadPipeline.planEnvironment, $answers.workloadPipeline.applyEnvironment)) {
            $encodedEnvironment = [uri]::EscapeDataString($environment)
            $null = Invoke-RestMethod -Uri "$baseUri/environments/$encodedEnvironment" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            $clientVariable = Invoke-RestMethod -Uri "$baseUri/environments/$encodedEnvironment/variables/AZURE_CLIENT_ID" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            if (-not (Test-ALZWorkloadGuid $clientVariable.value)) { throw "The existing environment $environment has no valid OIDC client ID." }
        }
        $backend = $answers.workloadBackend
        foreach ($subscriptionId in @($answers.workloadPipeline.allowedSubscriptionIds) + @($backend.subscriptionId) | Select-Object -Unique) {
            $account = Invoke-ALZWorkloadAzureRead @('account', 'show', '--subscription', $subscriptionId)
            if ($account.id -ne $subscriptionId -or $account.tenantId -ne $backend.tenantId) { throw 'The workload and backend must use the confirmed Azure tenant and subscriptions.' }
        }
        $null = Invoke-ALZWorkloadAzureRead @('storage', 'account', 'show', '--name', $backend.storageAccount, '--resource-group', $backend.resourceGroup, '--subscription', $backend.subscriptionId)
        return $true
    }

    function Get-ALZWorkloadChangedFiles {
        param([string]$Checkout)
        $status = (& git -C $Checkout status --porcelain=v1 --untracked-files=all -z) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the local proposal changes.' }
        $paths = @()
        foreach ($entry in $status.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($entry.Length -lt 4 -or $entry.Substring(0, 2) -notin @('??', ' M', 'M ', ' A', 'A ')) { throw 'A proposal contains deletions, renames, or unsupported Git changes. Review it manually.' }
            $path = $entry.Substring(3)
            if ($path -match '[\r\n\\]' -or $path.StartsWith('/') -or $path.Split('/') -contains '..') { throw 'A proposal contains an unsafe file path.' }
            if ($path -match '(?i)(\.tfstate($|\.)|\.tfplan($|\.)|(^|/)\.terraform/|(^|/)\.env($|\.))') { throw 'State, plans, or environment secrets cannot be published.' }
            $paths += $path
        }
        return $paths
    }

    function Publish-ALZWorkloadPullRequest {
        param([hashtable]$State, $Repository, [string]$Checkout, [string]$Token, [string]$Title, [string]$Body, [string]$PublicationKey = 'workloadPullRequest', [switch]$BranchOnly)
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'ALZ-AutoPilot' }
        $baseUri = "https://api.github.com/repos/$($Repository.Repository)"
        $paths = @(Get-ALZWorkloadChangedFiles -Checkout $Checkout)
        if ($paths.Count -eq 0) { throw 'The proposal has no file changes to publish.' }
        $treeEntries = @()
        $hashInput = @()
        foreach ($path in $paths | Sort-Object) {
            $fullPath = Join-Path $Checkout $path
            if ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked files cannot be published.' }
            $hashInput += "$path`:$((Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash)"
        }
        $contentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashInput -join "`n")))
        $publication = $State.answers[$PublicationKey]
        if ($publication -and ($publication.repository -cne $Repository.Repository -or $publication.contentHash -cne $contentHash)) { throw 'A different proposal was already published for this session. Select a new delivery folder to avoid overwriting an open review.' }
        if (-not $publication) {
            $reference = Invoke-RestMethod -Uri "$baseUri/git/ref/heads/$([uri]::EscapeDataString($Repository.Branch))" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            if ($reference.object.sha -ne $Repository.Commit) { throw 'The base branch changed after discovery. Regenerate the proposal before publication.' }
            $baseCommit = Invoke-RestMethod -Uri "$baseUri/git/commits/$($Repository.Commit)" -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            foreach ($path in $paths) {
                $blobBody = @{ content = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Checkout $path))); encoding = 'base64' } | ConvertTo-Json -Compress
                $blob = Invoke-RestMethod -Uri "$baseUri/git/blobs" -Headers $headers -Method Post -ContentType 'application/json' -Body $blobBody -TimeoutSec 60 -ErrorAction Stop
                $treeEntries += @{ path = $path; mode = '100644'; type = 'blob'; sha = $blob.sha }
            }
            $tree = Invoke-RestMethod -Uri "$baseUri/git/trees" -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ base_tree = $baseCommit.tree.sha; tree = $treeEntries } | ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 60 -ErrorAction Stop
            $commit = Invoke-RestMethod -Uri "$baseUri/git/commits" -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ message = $Title; tree = $tree.sha; parents = @($Repository.Commit) } | ConvertTo-Json -Compress) -TimeoutSec 30 -ErrorAction Stop
            $branch = "autopilot/workload-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
            $null = Invoke-RestMethod -Uri "$baseUri/git/refs" -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ ref = "refs/heads/$branch"; sha = $commit.sha } | ConvertTo-Json -Compress) -TimeoutSec 30 -ErrorAction Stop
            $publication = @{ repository = $Repository.Repository; base = $Repository.Branch; branch = $branch; commit = $commit.sha; contentHash = $contentHash; pullRequestUrl = '' }
            $State.answers[$PublicationKey] = $publication
            Save-ALZState -State $State
        }
        if (-not $BranchOnly -and -not $publication.pullRequestUrl) {
            $pullRequest = Invoke-RestMethod -Uri "$baseUri/pulls" -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ title = $Title; body = $Body; head = $publication.branch; base = $publication.base; draft = $true } | ConvertTo-Json -Compress) -TimeoutSec 30 -ErrorAction Stop
            $publication.pullRequestUrl = $pullRequest.html_url
            $publication.number = $pullRequest.number
            Save-ALZState -State $State
        }
        return [pscustomobject]$publication
    }

    function Protect-ALZWorkloadLegacyTriggers {
        param([string]$Checkout, [string]$Root, [switch]$DisablePlaceholder)
        Import-Module powershell-yaml -ErrorAction Stop
        foreach ($fileName in @('ci.yaml', 'cd.yaml')) {
            $path = Join-Path $Checkout ".github/workflows/$fileName"
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $workflow = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml -Ordered
            if ($DisablePlaceholder) {
                $workflow['on'] = [ordered]@{ workflow_dispatch = @{} }
                $workflow['permissions'] = @{ contents = 'read' }
                $workflow['jobs'] = [ordered]@{
                    placeholder_retired = [ordered]@{
                        'runs-on' = 'ubuntu-latest'
                        steps = @(@{ run = "echo 'The unused ALZ starter is retired in this workload repository. Use the autopilot workload workflow instead.'" })
                    }
                }
            }
            elseif ($Root -ne '.') {
                foreach ($event in @('push', 'pull_request')) {
                    if (-not $workflow.on.Contains($event)) { continue }
                    if ($null -eq $workflow.on[$event]) { $workflow.on[$event] = [ordered]@{} }
                    $trigger = $workflow.on[$event]
                    $excludedPaths = @("$Root/**", '.github/autopilot/**', '.github/workflows/autopilot-*.yml')
                    if ($trigger.paths) { $trigger.paths = @($trigger.paths) + @($excludedPaths | ForEach-Object { "!$_" }) }
                    else { $trigger['paths-ignore'] = @($trigger['paths-ignore']) + $excludedPaths | Where-Object { $_ } | Select-Object -Unique }
                }
            }
            ($workflow | ConvertTo-Yaml -Options DisableAliases).TrimEnd() | Set-Content -LiteralPath $path -Encoding UTF8
        }
    }

function New-ALZWorkloadTemplateProposal {
    param([hashtable]$State, [string]$Token)
    $templateState = @{ answers = @{ workloadRepository = $State.answers.workloadPipeline.templatesRepository; workloadBranch = 'main' } }
    $repository = Get-ALZWorkloadRepositoryContext -State $templateState -Token $Token
    $checkout = Join-Path $State.deliveryPath ("workload-proposals/templates-$([guid]::NewGuid().ToString('N'))/repository")
    $null = New-Item -ItemType Directory -Path (Split-Path $checkout -Parent) -Force
    Copy-ALZWorkloadRepository -Repository $repository -Token $Token -Checkout $checkout
    $workflow = Join-Path $checkout '.github/workflows/cd-template.yaml'
    if (-not (Test-Path -LiteralPath $workflow)) { throw 'The selected templates repository does not contain the official cd-template.yaml workflow.' }
    $null = Write-ALZWorkloadTemplate -Path $workflow
    return [pscustomobject]@{ Checkout = $checkout; Repository = $repository; Workflow = $workflow }
}

function Invoke-ALZWorkloadDelivery {
    param([hashtable]$State, [string]$DataPath)
    $token = $null
    $secureToken = $null
    Set-ALZPhaseStatus -State $State -Phase 'bootstrap' -Status 'skipped'
    Set-ALZPhaseStatus -State $State -Phase 'hcp' -Status 'skipped'
    try {
        $needsInterview = $State.answers.workloadAttachmentVersion -ne 1 -or $State.answers.workloadOperation -notin @('new', 'update') -or $State.phaseStatus.interview -ne 'done'
        if (-not $needsInterview) { $needsInterview = Read-ALZConfirm -Prompt 'Change the saved workload attachment?' -Default $false }
        if ($needsInterview) {
            Set-ALZCurrentPhase -State $State -Phase 'interview'
            $State = Invoke-ALZWorkloadInterview -State $State -DataPath $DataPath
        }
        if (-not (Test-ALZWorkloadModulePath $State.answers.customModulePath) -or -not (Test-ALZWorkloadRelativePath $State.answers.workloadRoot)) { throw 'The saved custom configuration path or repository root is invalid. Re-run the interview.' }
        if ($State.answers.workloadOperation -eq 'new' -and $State.answers.workloadRoot -eq '.') { throw 'New workloads cannot replace the existing repository root.' }
        Set-ALZCurrentPhase -State $State -Phase 'preflight'
        $results = @(Test-ALZTooling) + @(Test-ALZAzureLogin -ExpectedManagementSub $State.answers.subscriptions.management)
        Write-ALZResults $results
        if (@($results | Where-Object Status -EQ 'FAIL').Count -gt 0) { throw 'Resolve the prerequisite failures before attaching to an existing delivery.' }
        $secureToken = Read-Host -Prompt '  GitHub PAT for read-only repository discovery (input hidden)' -AsSecureString
        $token = ConvertTo-ALZPlainText -Secure $secureToken
        $repository = Get-ALZWorkloadRepositoryContext -State $State -Token $token
        $backend = Read-ALZWorkloadBackend -State $State -Repository $repository
        if ($State.answers.workloadUsePipeline) { $null = Read-ALZWorkloadPipeline -State $State }
        $rootPrefix = if ($State.answers.workloadRoot -eq '.') { '' } else { "$($State.answers.workloadRoot)/" }
        $rootFiles = @($repository.Files | Where-Object { $_.StartsWith($rootPrefix, [StringComparison]::Ordinal) })
        $rootExists = if ($State.answers.workloadOperation -eq 'new') { $rootFiles.Count -gt 0 } else { @($rootFiles | Where-Object { $_.Substring($rootPrefix.Length) -match '^[^/]+\.tf(\.json)?$' }).Count -gt 0 }
        $runnerValidation = $State.answers.workloadUsePipeline -and $State.answers.workloadValidationMode -eq 'runner'
        if ($runnerValidation) {
            $null = Test-ALZWorkloadPipelineAccess -State $State -Token $token
            if ($State.answers.workloadOperation -eq 'new' -and $rootExists) { throw 'The new workload folder already exists. Select modify existing.' }
            if ($State.answers.workloadOperation -eq 'update' -and (-not $rootExists -or -not $State.answers.workloadStateLineage)) { throw 'Runner-based updates require the existing root and a previously verified state lineage. Inspect private state before attaching an update.' }
            $classification = [pscustomobject]@{ Operation = $State.answers.workloadOperation; Environment = 'pending runner validation'; ImportReviewRequired = $false }
            $snapshot = [pscustomobject]@{ ManagedResourceCount = 'not inspected'; AzureResourceCount = 'not inspected'; Lineage = $State.answers.workloadStateLineage }
        }
        else {
            $snapshot = Get-ALZWorkloadSnapshot -State $State
            $classification = Get-ALZWorkloadClassification -Operation $State.answers.workloadOperation -StateExists $snapshot.StateExists -ManagedResourceCount $snapshot.ManagedResourceCount -Lineage $snapshot.Lineage -ExpectedLineage $State.answers.workloadStateLineage -RootExists $rootExists -AzureResourceCount $snapshot.AzureResourceCount -ResourceGroupExists $snapshot.ResourceGroupExists
        }
        $State.answers.workloadRepositoryId = $repository.Id
        $State.answers.workloadBranch = $repository.Branch
        $State.answers.workloadStateLineage = $snapshot.Lineage
        $State.answers.workloadClassification = $classification.Environment
        Set-ALZPhaseStatus -State $State -Phase 'preflight' -Status $(if ($runnerValidation) { 'pending' } else { 'done' })
        Write-ALZSection 'Review attachment'
        Write-Host "  Operation: $($classification.Operation); environment: $($classification.Environment)" -ForegroundColor White
        Write-Host "  Repository: $($repository.Repository) [$($repository.Branch)]; root: $($State.answers.workloadRoot)" -ForegroundColor White
        Write-Host "  Tenant: $($backend.tenantId); target subscription: $($State.answers.subscriptions.management)" -ForegroundColor White
        Write-Host "  Target resource group: $($State.answers.workloadResourceGroup)" -ForegroundColor White
        Write-Host "  Backend: $($backend.storageAccount)/$($backend.container)/$($backend.key); workspace: default" -ForegroundColor White
        Write-Host "  State resources: $($snapshot.ManagedResourceCount); resources in target group: $($snapshot.AzureResourceCount)" -ForegroundColor White
        if ($classification.ImportReviewRequired) { Write-ALZStatus -Status WARN -Message 'The target Azure scope already exists. Review ownership and imports before applying any new-state plan.' }
        if (-not (Read-ALZConfirm -Prompt 'Prepare a local proposal only (no commit, push, workflow run, or Azure changes)?' -Default $false)) { return }
        Set-ALZCurrentPhase -State $State -Phase 'config'
        $proposal = New-ALZWorkloadProposal -State $State -Repository $repository -Token $token
        if ($State.answers.workloadUsePipeline) {
            $wiring = Write-ALZWorkloadWorkflow -State $State -Checkout $proposal.Checkout
            Protect-ALZWorkloadLegacyTriggers -Checkout $proposal.Checkout -Root $State.answers.workloadRoot
            $proposal | Add-Member -NotePropertyName Wiring -NotePropertyValue $wiring
            $templateProposal = New-ALZWorkloadTemplateProposal -State $State -Token $token
            $State.answers.workloadTemplateProposal = $templateProposal
        }
        $State.answers.workloadProposal = $proposal
        Set-ALZPhaseStatus -State $State -Phase 'config' -Status 'done'
        Set-ALZPhaseStatus -State $State -Phase 'proof' -Status 'pending'
        Set-ALZPhaseStatus -State $State -Phase 'run' -Status 'pending'
        Set-ALZCurrentPhase -State $State -Phase 'proof'
        Write-ALZStatus -Status OK -Message 'Local proposal prepared; bootstrap was skipped.' -Detail $proposal.Checkout
        Write-ALZStatus -Status WARN -Message 'Review the diff and a Terraform plan before publishing. Existing workflows must use this exact root and backend key; they were not changed or dispatched.'
        Write-Host "  Terraform root: $($proposal.Root)" -ForegroundColor White
        Write-Host "  Backend configuration: $($proposal.BackendConfig)" -ForegroundColor White
        if ($State.answers.workloadUsePipeline -and (Read-ALZConfirm -Prompt 'Commit this proposal to a new GitHub feature branch and create a draft PR (no merge or apply)?' -Default $false)) {
            if (@(Get-ALZWorkloadChangedFiles -Checkout $templateProposal.Checkout).Count -gt 0) {
                $templatePublication = Publish-ALZWorkloadPullRequest -State $State -Repository $templateProposal.Repository -Checkout $templateProposal.Checkout -Token $token -PublicationKey 'templatePullRequest' -Title 'Add opt-in AutoPilot workload planning and reviewed apply' -Body 'Extend the existing reusable CD workflow without changing its path or existing callers. Adds isolated backend/target routing, read-only discovery, no-delete plan validation, and a separate main-branch dispatch to apply a reviewed saved plan. No bootstrap or infrastructure deployment is performed by this PR.'
                Write-ALZStatus -Status OK -Message 'Merge the reusable-template PR first.' -Detail $templatePublication.pullRequestUrl
            }
            $body = "Attach $($State.answers.workloadRoot) to existing ALZ delivery infrastructure. Bootstrap is not rerun. Backend: $($backend.storageAccount)/$($backend.container)/$($backend.key). Target subscription: $($State.answers.subscriptions.management). State checks and a no-delete plan run on the existing runner. Merge the reusable-template PR first. Apply requires a separate confirmed dispatch with a reviewed main-branch plan run ID."
            $publication = Publish-ALZWorkloadPullRequest -State $State -Repository $repository -Checkout $proposal.Checkout -Token $token -Title "Add $($State.answers.deliveryName) workload automation" -Body $body
            Write-ALZStatus -Status OK -Message 'Draft PR created; merge and apply remain pending.' -Detail $publication.pullRequestUrl
        }
    }
    catch {
        Set-ALZPhaseStatus -State $State -Phase $State.currentPhase -Status 'failed'
        Write-ALZStatus -Status FAIL -Message 'Workload attachment stopped. No Terraform apply was run; check any saved PR publication status before retrying.' -Detail $_.Exception.Message
    }
    finally {
        $token = $null
        if ($secureToken) { $secureToken.Dispose() }
    }
}

Export-ModuleMember -Function Set-ALZDeliveryType, Invoke-ALZWorkloadInterview, Invoke-ALZWorkloadContentSwap, Invoke-ALZWorkloadDelivery
