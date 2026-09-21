<!-- markdownlint-disable -->
<p align="center">
  <img src="ALZAutoPilot.png" alt="ALZ Autopilot" width="760">
</p>

# How to use ALZ Autopilot

Use ALZ Autopilot to prepare and review Azure landing zone deliveries. For a new platform, it guides the official [Azure Landing Zones IaC Accelerator](https://azure.github.io/Azure-Landing-Zones/accelerator/). For workloads, it prepares changes in existing GitHub repositories without running bootstrap again.

AutoPilot is a companion, not a prerequisite. Your repositories, Terraform configuration, remote state, and pipelines remain usable without the app. This guide describes version 1.11.0. See [the changelog](CHANGELOG.md) for changes from earlier versions.

A pull request (PR) proposes a repository change for review. A Terraform plan previews infrastructure changes. An apply executes a reviewed plan. Treat code review and deployment approval as separate decisions.

## Choose your scenario

Choose the operation based on resource ownership and Terraform state, not just whether an Azure resource is new.

| What you need to do | Where to start |
|---|---|
| Create delivery infrastructure and a new platform landing zone | [1. Bootstrap a new platform](#1-bootstrap-a-new-platform) |
| Deploy a separate workload with its own Terraform root and state | [2. Attach a new workload](#2-attach-a-new-workload) |
| Add or change resources managed by an existing workload | [3. Update an attached workload](#3-update-an-attached-workload) |
| Assess a newer official module or provider version | [4. Review module upgrades](#4-review-module-upgrades) |
| Import existing resources, move state, or change ownership | [5. Review a migration or import](#5-review-a-migration-or-import) |
| Change an already deployed platform, such as a policy or network setting | [Update an existing platform](#update-an-existing-platform) |
| Diagnose access or continue an interrupted session | [Check connectivity](#check-connectivity) or [Resume a delivery](#resume-a-delivery) |

**Example:** Adding a storage account to an existing application is usually an update to that application's Terraform root. It does not require a new state file or another bootstrap.

## Before you start

Install PowerShell 7.4 or later, Azure CLI 2.55 or later, and Git. Use `pwsh`, not Windows PowerShell 5.1. Sign in to Azure and verify access to the intended tenant and subscriptions before starting a deployment operation.

Select a delivery folder outside OneDrive, Dropbox, or other synchronization services. The parent directory must already exist. The app can be in a synced folder; its delivery folder must not be. Cloud synchronization can cause file locks and inconsistent Terraform file enumeration.

Keep these three locations distinct:

| Location | Purpose |
|---|---|
| Local delivery folder | Stores the app's answers, progress, proposals, and reports. |
| GitHub repository and Terraform root | Stores the desired infrastructure configuration and workflow. |
| Remote Terraform state | Records which deployed resources Terraform manages. It can contain secrets. |

Do not use a new state key to adopt existing resources. Do not commit state, saved plans, credentials, or local delivery output to a source repository.

### Check access for the selected operation

For **platform bootstrap**, follow the official [GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/) and [platform subscription prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/). Bootstrap needs permissions to create delivery resources, repositories, identities, and role assignments. The GitHub bootstrap token needs the documented repository permissions, including Workflows, and organization Members permissions. Self-hosted runner registration needs additional permissions. Bicep platform delivery also has root-scope access requirements; review them before proceeding.

For **workload attachment**, use an existing private GitHub repository, reusable-workflow repository, Linux x64 runners, separate plan and apply identities/environments, and an Azure Storage backend. Configure both environments' client IDs before pipeline discovery. Use the minimum token permissions needed to inspect the repositories and settings; publishing a draft PR separately requires repository write permissions. A failed settings read is not a reason to grant unrestricted access.

The app reads prompted tokens through a hidden terminal prompt. Never put a token in a command, issue, PR, delivery note, or chat message. Treat Terraform state and tool logs as sensitive even when AutoPilot redacts known token values.

## Start the app

Open PowerShell in the ALZ Autopilot repository and run:

```powershell
.\Start-ALZDelivery.ps1 -DeliveryPath "$HOME\Documents\ALZ-Platform" -NoClear
```

Use a separate delivery folder for each new proposal or review. To continue the same proposal, reuse its delivery folder and saved answers.

| Parameter | Purpose |
|---|---|
| `-DeliveryPath` | Select the local delivery folder. The app prompts if you omit it. |
| `-NoClear` | Keep previous console output visible. |
| `-SkipUpdateCheck` | Skip online release notices. Other operations can still require network access. |
| `-ConnectivityOnly` | Check public endpoints and exit without creating a delivery or installing tools. |
| `-ConnectivityTimeoutSeconds` | Set the connectivity-probe timeout from 1 to 60 seconds; the default is 10. |
| `-Reset` | Ignore saved app answers. This does not migrate, restore, or reset Terraform state. Do not use it as deployment recovery. |
| `-SkipPreflight` | Skip platform preflight. Not recommended for deployment; it does not make an environment safe. |

The startup release notice compares installed or cached versions with official stable releases. It does not install updates or prove which modules are deployed. An unavailable feed is reported as unknown. If bootstrap needs an ALZ PowerShell package that is not installed, the app asks for approval and an exact stable version.

## 1. Bootstrap a new platform

Use this scenario when you need the delivery infrastructure and platform configuration for a new landing zone. For an existing platform, use its repository instead of bootstrapping a second copy.

**Prepare:** Confirm the target subscriptions, parent management group, repository owner, network design, access permissions, approval model, and cost estimate. An existing tenant requires a separate [transition review](#brownfield-tenants).

1. Start the app with a new delivery folder and select **1. Bootstrap a new platform landing zone**.
2. Enter the platform subscriptions, regions, version control system, infrastructure language, topology, state preference, and runner choices. Review the [supported networking choices](README.md#platform-networking-choices).
3. Review the target summary and prerequisite results. Resource-provider registration is a separate Azure write; approve it only when required and authorized.
4. Review the generated bootstrap inputs and platform configuration. Check address ranges, subscription placement, policy changes, service tiers, and custom library content. Configuration generation is not deployment approval.
5. Approve bootstrap only after the configuration review. The official accelerator creates the delivery repositories, identities, state storage, and optional runner/network resources. Bootstrap does not deploy the platform landing zone itself.
6. Review the generated pipeline and actual deployment approval controls. Choose the guided GitHub pipeline path or the manual handoff. Review its Terraform plan before permitting apply.
7. Verify the platform deployment and review the delivery report. Check resource placement, effective policies, private connectivity, and ongoing cost.

**Expected result:** Delivery infrastructure and reviewed platform configuration, followed by an approved platform deployment. The report distinguishes observed Azure inventory from verified deployment results.

**Without AutoPilot:** Follow the official [bootstrap](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/) and [run](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/) procedures, then maintain the generated repositories through PRs.

### Choose a platform variation

The numbers below are the upstream Terraform scenario numbers, not the five operation choices in AutoPilot's startup menu. Select the matching scenario label during the platform interview. The bundled [scenario catalog](data/scenarios.json) lists all 11 options.

| Variation | How to use it |
|---|---|
| Management-only, scenario 5 | Select the management-only scenario. The extra networking questions are skipped. Monitoring, security services, and optional bootstrap infrastructure can still incur charges. |
| Hub-and-spoke with Azure Firewall, scenarios 6 and 1 | Select the single-region or multi-region variant, respectively. Review firewall tiers, gateway choices, address ranges, and routes. |
| Virtual WAN with Azure Firewall, scenarios 7 and 2 | Select the single-region or multi-region variant, respectively. Review virtual hub locations, gateway capacity, and routing. |
| Hub-and-spoke with an NVA, scenarios 8 and 3 | Select the single-region or multi-region variant, respectively. Plan the network virtual appliance (NVA), licensing, deployment, and next-hop routing separately. |
| Virtual WAN with an NVA, scenarios 9 and 4 | Select the single-region or multi-region variant, respectively. Confirm appliance compatibility with the selected Virtual WAN design. |
| Small or medium business, scenarios 10 and 11 | Select the single-region hub-and-spoke or Virtual WAN option, respectively. Review the scenario's fixed firewall design and required subscriptions. Published baseline estimates are not spending caps or quotes for your settings. |
| Multiple regions | Select a multi-region scenario and supply the requested regions. Review the resulting address ranges, service availability, and per-region cost. |
| Custom policy library | Select the existing `lib` folder, or place it in the delivery's `config/lib` folder before configuration generation. Review the selected path and contents. See the [custom library example](samples/lib-pci/README.md). |
| Bicep | Select Bicep during the platform interview. Configuration generation is available, but end-to-end delivery is preview in this wrapper. The extra Terraform networking interview does not apply. |
| Azure DevOps | Select Azure DevOps for platform configuration and bootstrap, then follow the printed manual pipeline handoff. Workload attachment is GitHub-only. |

Gateway creation does not configure circuits, VPN sites, Border Gateway Protocol (BGP), or connection routing. Review those dependencies separately from the scenario selection.

## 2. Attach a new workload

Use this scenario for a separate workload that will own an unused Terraform root and state key. For example, create a storage lab alongside an existing platform without creating another runner or backend stack.

**Prepare:** Have the Terraform source ready. This path accepts your configuration; it does not generate arbitrary resource designs. Confirm the existing repository, templates repository, target subscription, backend, environments, and runner labels.

```powershell
.\Start-ALZDelivery.ps1 -DeliveryPath "$HOME\Documents\ALZ-StorageLab" -NoClear
```

1. Select **2. Attach a new workload** and provide the full path to the Terraform source folder.
2. Enter the exact repository, such as `contoso/platform-workloads`, and an unused root, such as `workloads/storage-lab`. Select the target subscription and resource group to inspect. Existing groups or resources require an ownership review; they are not assumed to be unowned.
3. Enter the existing state account, resource group, container, tenant, and subscription. Choose a unique state blob key, such as `workloads/storage-lab/terraform.tfstate`. The backend subscription can differ from the deployment subscription.
4. Choose whether to prepare pipeline PRs. For a private backend that your computer cannot reach, choose validation on the existing runner. Deferred validation remains pending until the runner inspects the state.
5. Select the existing templates repository, plan/apply environments, [security profile](#security-profiles-and-approvals), and [runner selectors](#runner-isolation). Resolve blocking preflight results without changing policy or broadening access as a workaround.
6. Approve the local proposal, inspect its diff, and then separately authorize draft PR publication. The app adds workload files without replacing the platform root. It creates a companion templates PR only when that proposal has changes.
7. Complete the [workload review and apply procedure](#review-and-apply-a-workload). No workload apply is dispatched by this interview.

**Expected result:** A local proposal and, if authorized, draft PRs tied to one repository, root, and backend key. Bootstrap remains skipped.

**Without AutoPilot:** Add the root, explicit backend configuration, workflow, and scoped identities through normal PRs. Reuse the established pipeline contract and review the same plan and access boundaries.

### Plan the permissions before apply

Use the generated [access helper](data/Initialize-WorkloadAccess.ps1) in its default read-only mode to inspect required permissions. Its default apply proposal is Contributor on the named existing resource groups, not the entire subscription. RBAC Administrator requires an explicit manifest entry.

A resource-group grant cannot create a resource group that does not exist. If Terraform creates the group, review the exact subscription-level permissions separately. Such entries require both `access.applyRoles` in the manifest and `-AllowSubscriptionScope` when invoking the helper. `-Apply` and confirmation are still required for any write. A design using pre-created groups needs a separately reviewed attachment and ownership approach; do not bypass the new-workload scope checks.

## 3. Update an attached workload

Use this scenario to add or modify resources within an existing attachment. Keep its repository, Terraform root, backend key, and state lineage. A lineage is the identifier Terraform uses to distinguish one state history from another.

**Prepare:** Start from the current repository revision, edit only the intended Terraform configuration, and obtain the expected lineage from a verified prior run or authorized state inspection. Do not use another workload's lineage or a new empty state.

```powershell
.\Start-ALZDelivery.ps1 -DeliveryPath "$HOME\Documents\ALZ-StorageLab-Update" -NoClear
```

1. Select **3. Update an attached workload**. Use a new proposal folder so you do not reuse the publication metadata of an older PR.
2. Provide the updated Terraform source and the exact existing repository, root, target scope, and backend binding.
3. Review the attachment discovered at the selected repository commit. The app reads its manifest and caller workflow rather than replacing their settings with wizard defaults. For runner-based validation, provide the expected state lineage when prompted.
4. Complete the security and runner checks. Missing attachment metadata, changed ownership, or an unsupported caller contract stops the operation for manual review.
5. Approve and inspect the local proposal. Existing initialization hooks, unknown manifest fields, the caller workflow, access helper, and reusable template are preserved. Only the attachment operation and verified lineage metadata are updated.
6. Publish the draft PR if authorized, then follow the workload plan-review and apply procedure.

**Expected result:** A reviewed change against the original state, without another bootstrap or implicit workflow upgrade. Deletion, replacement, import, and management-group changes remain blocked by the workload plan guard. Nested ARM deployments allow first creation only; updates require a separate procedure.

**Without AutoPilot:** Create a branch in the existing repository, edit the same Terraform root, and open a PR. Use the existing workflow and state. This is also the preferred path when your established custom workflow is outside the app's supported attachment contract.

## 4. Review module upgrades

Use this scenario to assess a dependency upgrade independently from an infrastructure feature change. The startup notice is useful context, not an instruction to upgrade.

1. Start a separate review session and select **4. Review official module upgrades**.
2. Select the existing local Terraform root. The app displays cached module information when available. It does not run Terraform initialization or edit version pins.
3. Verify module source/version constraints in the repository. A local module cache can be stale. The Terraform provider lock file locks providers, not Terraform module versions.
4. Read the release notes and upgrade guidance for the specific dependency. Distinguish the ALZ PowerShell package, bootstrap modules, starter packages, ALZ Terraform modules, providers, and Terraform CLI.
5. Prepare a dedicated feature branch and change a small dependency set. Keep the backend, resource addresses, workflow contract, and custom hooks unchanged unless their migration is explicitly included in the review.
6. Validate, generate a fresh plan, and review policy changes, replacements, permissions, and cost. Rehearse in a test environment before approving production deployment.

**Expected result:** A read-only inventory and an upgrade handoff. AutoPilot does not prepare an upgrade PR, update dependency pins, or deploy the upgrade. The startup check cannot certify deployed-module currency.

**Without AutoPilot:** Follow the same repository inspection, upstream release review, dedicated PR, plan, and approval process. A new starter release does not require rerunning bootstrap.

## 5. Review a migration or import

Use this scenario when resources already exist but are not owned by the intended state, when moving a backend, or when changing resource ownership or addresses.

1. Start a separate review session and select **5. Review a migration or import**.
2. Identify the current and intended owners of each resource, including repository, root, backend, lineage, and Terraform address.
3. Prepare secure state backups and confirm state-locking behavior. State and saved plans can contain credentials; keep them outside Git and shared document storage.
4. Write an explicit migration procedure using the supported Terraform import, moved-block, or state-migration mechanism for the case. Include recovery steps and dependencies.
5. Review expected creates, updates, replacements, and deletions before authorizing execution. A workload no-delete guard is not a migration engine.
6. Execute the separately approved procedure, verify ownership and state, and review a post-migration plan before normal operation resumes.

**Expected result:** Guidance only. The app does not run import commands, move resources or state, delete files, create a replacement backend, or bootstrap another environment.

**Without AutoPilot:** Use your team's change-control process and the relevant [Terraform state](https://developer.hashicorp.com/terraform/language/state) and [import](https://developer.hashicorp.com/terraform/language/import) guidance.

## Update an existing platform

Platform maintenance is different from a workload update. Management groups, subscription placement, and platform policy changes belong to the existing platform repository and its pipeline, not the workload attachment pipeline.

1. Open the existing platform repository and create a branch from its current default branch.
2. Change the relevant platform configuration or custom library. For a module upgrade, use the separate upgrade review above.
3. Review the diff and plan, including inherited policy effects, subscription moves, network changes, and service costs.
4. Merge and deploy through the platform's established approval process. Verify effective settings after deployment.

Resume the original AutoPilot delivery only when you need its supported guided pipeline handoff or report. Do not rerun bootstrap to overwrite protected repository content or bypass a required PR. Changing network topology can require a migration, not just selecting another scenario file.

## Review and apply a workload

This procedure applies to the generated workload pipeline. The platform accelerator's pipeline has its own configuration and approval flow.

1. Inspect the workload and any companion templates PR. Confirm the exact root, target scopes, backend key, identity permissions, and runner routing. Review cost and policy compatibility as well as the Terraform actions.
2. Resolve review comments and require the applicable validation checks. If a companion templates change is approved, merge it before the workload PR. Merging a workload PR starts a plan, not an apply.
3. Review a fresh successful plan from the default branch after all required merges. Do not apply a PR plan or a plan from another commit. Inspect nested ARM templates separately because Terraform does not show every child-resource change.
4. In GitHub, open **Actions**, select the workload workflow, and select **Run workflow** on the default branch. Enter the reviewed values below. Dispatch only after deployment approval and readiness checks are complete.
5. Satisfy any configured environment approval. Monitor the run and verify resource placement, authentication, private DNS, application behavior, and cost after deployment.

| Workflow input | Value for an apply |
|---|---|
| `action` | `apply` |
| `confirmation` | The target subscription ID from the reviewed manifest. |
| `plan_run_id` | The successful, reviewed default-branch plan run ID. |
| `plan_attempt` | The attempt number of that plan run, commonly `1`. |
| `template_confirmation` | The reviewed nested ARM template hash when the manifest requires one. Otherwise leave it empty. |

The workflow binds the saved plan to its source revision, configuration, workload, and provider lock. Plans expire after one day. If the plan is stale, expired, or no longer matches state, generate and review a new plan; do not bypass the check. Planning can lock or initialize backend state, but it does not authorize resource deployment.

### Recover workload initialization

Some reviewed workload recipes have an `initialize` action, such as the private FinOps recipe. It is not added to every generic caller automatically.

If Terraform succeeded but initialization failed, use `action=initialize` only when the caller supports it. Set `plan_run_id` and `plan_attempt` to the **original successful Terraform apply run** and attempt, not the earlier plan run. Use the same subscription and template confirmations.

The retry requires the successful-apply receipt, exact source and artifact hashes, and unchanged state lineage and serial. It does not replan or reapply Terraform. Apply receipts expire after seven days. If Terraform failed, state changed, or the receipt expired, stop for a reviewed recovery procedure instead of resetting state or rerunning bootstrap.

## Security profiles and approvals

Workload pipeline preflight defaults to **production**. Missing or unverifiable controls stop the proposal. The explicit **learning** profile reports security gaps as warnings without claiming independent approval; it still requires a private workload repository and working identity and runner access.

| GitHub plan | Private-repository deployment controls |
|---|---|
| Team | Environments, secrets, and branch restrictions are available. Required deployment reviewers are not available. A manual dispatch is not independent approval. |
| Enterprise | Required deployment reviewers are available. Verify that reviewers, prevention of self-review, and bypass restrictions are actually configured. |

See [GitHub's environment feature availability](https://docs.github.com/en/actions/reference/deployments-and-environments). Code Security and Secret Protection are separate products. Do not make repositories public to obtain an approval feature.

Preflight reads organization, repository, branch-protection, workflow-token, and apply-environment settings. It does not change them. If an API is denied, inspect the control through an authorized process; do not assume it is enabled. Equivalent rulesets need separate review when classic branch-protection APIs do not describe them. A point-in-time check does not replace GitHub or Azure enforcement.

### Runner isolation

New callers use separate plan and apply label selectors. The defaults are `self-hosted,Linux,X64,alz-plan` and `self-hosted,Linux,X64,alz-apply`. Select labels that exist on the intended runners; the app does not create or relabel runners.

Production preflight requires online matches, disjoint runner IDs, different Azure client IDs, and a recorded platform-owner isolation review. That review must cover clean disposable hosts, restricted runner access, network boundaries, and the absence of a shared privileged host identity. Labels and the `runnerIsolationReviewed` acknowledgment do not prove isolation. Existing callers retain their routing during an ordinary update.

Do not run untrusted PR code on persistent privileged runners, even in a private repository. See [GitHub's self-hosted runner guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners).

## Check connectivity

Use this diagnostic before starting a delivery or when working behind a proxy:

```powershell
.\Start-ALZDelivery.ps1 -ConnectivityOnly
```

The check uses unauthenticated metadata GET requests and download HEAD requests. It does not create delivery files, install tools, register providers, or deploy resources. It reports DNS, TLS, proxy-authentication, timeout, and HTTP failures without displaying proxy credentials or response bodies.

Passing this check does not prove Azure authorization, complete downloads, private-state access, or connectivity from Git, Terraform, or the runner. Do not disable TLS verification or enable public storage access to bypass a failure. Review the [upstream prerequisites and proxy guidance](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/).

## Resume a delivery

Run the same command with the original delivery folder and select **Resume this delivery?**. The app reads its saved answers and phase status. Legacy sessions keep their existing delivery type; reopening one does not select a new operation.

Review what completed before approving another action. A previous success does not prove the environment has not changed. Recheck prerequisites when access, policies, versions, or infrastructure have changed. Use a new proposal folder for a different operation or change request, while retaining the original backend for an existing deployment.

The local session file is not Terraform state. Do not delete it, delete bootstrap folders, or use `-Reset` as a way to recover an interrupted apply. If pinned bootstrap files are missing, restore the reviewed release through a separate recovery procedure; the app stops rather than deleting delivery files.

## Use HCP Terraform

HCP Terraform is an optional **platform** workflow. Workload attachment currently supports the Azure Storage backend only.

Select HCP during the platform interview to check an existing workspace in **Local** execution mode. The official accelerator first creates an Azure Storage backend. The app then prints the migration procedure and verifies the repository configuration, token-secret metadata, reusable workflow wiring, and caller secret forwarding. Verification does not move state.

Complete a separately reviewed migration with secure backups and the correct source/destination binding. Follow the printed runbook and [HashiCorp's migration guidance](https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization). Do not run state migration from an arbitrary checkout or assume passing configuration checks proves the state has moved.

## Brownfield tenants

A brownfield tenant already contains resources, management groups, or policies. Existing-resource discovery provides evidence, not permission to adopt or move those resources.

Before a platform transition, inventory ownership and state, review inherited policy, identify subscription placement changes, and agree on a phased migration. The upstream modules have adoption and policy-enforcement options, but they need a version-specific design and plan review. Selecting an option is not a substitute for importing resources into the correct state when that is required.

Policy effects differ: Deny can block later creates or updates; Modify can change supported properties on writes; DeployIfNotExists can deploy related resources after applicable create/update evaluations. Existing noncompliance can require a remediation task. An audit-oriented rollout is not a global switch, and `DoNotEnforce` on one assignment does not disable other assignments or inherited tenant policy.

Do not remove governance controls or move subscriptions to avoid a deployment failure. See Microsoft's [existing-environment transition guidance](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/align-approach-duplicate-brownfield-audit-only) and [policy remediation guidance](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources).

## Troubleshoot safely

| Symptom | What to check |
|---|---|
| Release lookup is unavailable | The feed, proxy, or rate limit might be unavailable. Keep pinned versions. Use `-SkipUpdateCheck` only to skip the advisory lookup. |
| Production preflight stops on GitHub Team | Private required deployment reviewers are unavailable on that plan. Use learning mode only for an intentionally nonproduction proposal, or establish an approved production deployment boundary. |
| No runner matches, or plan/apply runners overlap | Review labels and actual runner IDs. Provision isolation through a separate platform change; do not rerun bootstrap from workload mode. |
| No matching attachment manifest or lineage | Verify the repository, root, backend, and prior run. Do not invent a lineage or use an empty state to continue. |
| Private-state access returns 403 | Check the identity, data role, DNS, network path, and policy. Access failure is not evidence that the state is empty. |
| OIDC sign-in reports no matching federated identity | Compare the configured issuer, audience, repository/environment, and reusable-workflow subject with the actual run. Do not expose tokens or switch to a stored client secret as a shortcut. |
| Bootstrap files are missing | Recover the pinned package while preserving metadata and state. Automatic folder deletion is not supported. |
| Bootstrap repositories are empty | Check token permissions, especially Workflows, and whether the delivery folder is cloud-synced. Do not delete the environment before determining what succeeded. |
| A protected branch rejects a write | Use a PR. Do not disable protection or rerun bootstrap to replace repository contents. |
| Terraform proposes deletion, replacement, or import | Stop for a separate migration or lifecycle review. The workload guard intentionally blocks these actions. |

## Continue without AutoPilot

Keep the repository URL, Terraform root, backend binding, pipeline name, identity scopes, approval requirements, and recovery procedure in the deployment repository. An authorized engineer can then:

1. Create a branch and update the configuration in the existing root.
2. Open a PR and inspect validation and plan results.
3. Complete code review and merge through the repository's controls.
4. Review the new default-branch plan and authorize the deployment through the established workflow.
5. Verify the result and retain the original remote state and audit history.

AutoPilot's local session file is not required for this process. Continue using the same state, identities, and deployment controls rather than recreating them.

## References

- [ALZ accelerator overview](https://azure.github.io/Azure-Landing-Zones/accelerator/)
- [ALZ accelerator prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [GitHub prerequisites for the accelerator](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/)
- [ALZ bootstrap](https://azure.github.io/Azure-Landing-Zones/accelerator/2_bootstrap/)
- [Run the platform pipeline](https://azure.github.io/Azure-Landing-Zones/accelerator/3_run/)
- [GitHub deployment environment controls](https://docs.github.com/en/actions/reference/deployments-and-environments)
- [Azure authentication with GitHub OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Terraform remote state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/get-started/store-state-in-azure-storage)
