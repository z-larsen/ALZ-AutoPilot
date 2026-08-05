<!-- markdownlint-disable -->
<p align="center">
  <img src="ALZAutoPilot.png" alt="ALZ Autopilot" width="760">
</p>

# ALZ Autopilot

[![Version](https://img.shields.io/badge/version-1.6.2-blue)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.4%2B-5391FE)](https://learn.microsoft.com/powershell/)

Guided automation for the official [Azure Landing Zones IaC Accelerator](https://azure.github.io/Azure-Landing-Zones/accelerator/). It does not change what the accelerator does. It's a guided orchestration layer that reduces process overhead without removing the accelerator's review, approval, and deployment boundaries.

One entry point, a short interview, all prerequisite checks up front with exact fixes, generated config (no hand-editing scattered files), an automated (or guided-manual) platform deployment, and clean resume after an interrupted run.

## The journey

| Phase | What happens |
|---|---|
| **Plan** | A short interview for the few real decisions; answers saved after every step |
| **Prereqs** | Live checks: tooling, Azure Owner, resource providers, GitHub PAT/org/Members, HCP |
| **Config** | Generates `inputs.yaml` plus the platform config for your chosen scenario (no hand-editing, no token traps) |
| **Bootstrap** | Runs `Deploy-Accelerator`, verifies the repos got their workflows, translates known errors |
| **Deploy** | Triggers + watches the `02 Continuous Delivery` pipeline, or prints a step-by-step manual runbook |

## What it supports

| | |
|---|---|
| **IaC** | Terraform and Bicep |
| **Terraform topologies** | All 11 accelerator scenarios: management-only, single/multi region, hub-and-spoke or Virtual WAN, Azure Firewall or NVA, plus the two SMB scenarios |
| **Bicep topologies** | All three network types: `none`, `hubNetworking`, `vwanConnectivity` |
| **State** | Azure Storage (accelerator default) or HCP Terraform, with the HCP migration verified |
| **Runners** | GitHub-hosted, or self-hosted in a VNet with private networking |
| **Regions** | Single and multi-region (a second region is collected when the scenario needs one) |
| **Customization** | A custom ALZ library in `config/lib` is detected and passed through, so custom management groups, archetypes, and policy assignments deploy. See [samples/lib-pci](samples/lib-pci/README.md) |
| **Version control** | GitHub end to end. Azure DevOps through config generation and bootstrap, then a printed runbook for stage 2. Local file system is not supported |

The platform config is generated from the **official** scenario file for your choice, then it is yours to edit. Re-runs patch only the values the interview owns (regions, security contact, subscription placement) so hand edits survive.

## Safety gates

"One command" means one entry point, not unattended deployment. Every gate the accelerator builds in is preserved, and the tool adds one of its own. Nothing reaches Azure without a human saying yes.

| Gate | When | Default |
|---|---|---|
| **Confirm target state** | After the interview, before anything runs. Shows tenant, subscriptions by name, topology, regions, runners, and estimated cost | Prompts |
| **Review configuration** | After config generation, before bootstrap. Offers to open the file, because after bootstrap it lives in the repo and changes go through a pull request | **Stops unless you confirm** |
| **Run the bootstrap** | Before any Azure resource or repo is created | Prompts |
| **Trigger the pipeline** | Manual dispatch of the CD workflow. Runs `terraform plan` first | Prompts |
| **Apply approval** | The accelerator's own GitHub environment gate, created from your `apply_approvers` | **Enforced by GitHub** |

On the apply gate specifically: this tool **cannot** bypass it. The gate is a GitHub deployment environment, enforced server-side. The tool detects the pending approval and waits. It will only submit an approval on your behalf if you explicitly opt in at a prompt that **defaults to No**, and that call fails unless you are a named reviewer. Approving in the browser is the normal path, and the tool keeps watching while you do it.

The accelerator's documented requirement to review the platform configuration before deploying is respected. The tool fills in the values that are usually hand-edited (regions, security contact, subscription placement) so the classic placeholder mistakes cannot happen, and then still stops and asks you to review the file before the bootstrap.

## What it fixes

| Pain in the raw accelerator | What this adds |
|---|---|
| Steps spread across a wizard, two web UIs, and several doc pages | One `Start-ALZDelivery.ps1` entry point |
| Errors surface as Terraform stack traces mid-apply | Preflight validates tooling, Azure Owner, resource providers, GitHub PAT/org/Members, and HCP **before** bootstrap |
| Pointing a greenfield tool at a tenant that is already in use | Preflight detects an existing hierarchy, subscriptions parented elsewhere, and subscriptions that already contain resources |
| A closed terminal means spelunking through `output/` | State saved after every step; re-run resumes automatically |
| Hand-edit `inputs.yaml` and dodge `${starter_location_01}` token traps | Config generated from your answers |
| Cryptic failures (RP timeout, SSO, backend-config, TF_TOKEN, missing Workflows/Members scope) | Known failures matched to plain-language remediation |
| An unformatted config fails `terraform fmt -check` in CI, blocking every future pull request | The generated config is fmt-checked and corrected before the bootstrap |
| "Bootstrap succeeded" but the repos are empty | Post-bootstrap check verifies the repos actually received the workflows |
| PAT pasted into notes/files | Token entered masked, used in-memory only, never written to disk |
| Manual pipeline click-through + guessing the approval gate | Discovers the repo, triggers + watches the run, detects the apply gate, verifies MGs + policies |
| "Have you done the HCP migration?" answered on trust | Eight live checks against the repos: cloud block, no leftover azurerm backend, `TF_TOKEN_app_terraform_io` secret, no `-backend-config` flags, secret wiring, `secrets: inherit` |

## GitHub plan note

The accelerator ties its approval gate and Azure-auth config to GitHub **environments**, which on a **free org only work on public repos** - so a free org gets **public** repos (fine for a rehearsal; nothing sensitive is exposed). A **Team/Enterprise/EMU** org gets **private** repos with the gate intact. The app works with both and warns you in preflight when the org is free.

### Public repos and self-hosted runners

If you take the free org **and** enable self-hosted runners for private networking, the runners execute inside your VNet with private-endpoint access to the Terraform state, on a repo anyone can fork. GitHub advises against that pairing:

> We recommend that you only use self-hosted runners with private repositories. This is because forks of your public repository can potentially run dangerous code on your self-hosted runner machine by creating a pull request that executes the code in a workflow.

Preflight warns when it detects both. Mitigate by setting Settings > Actions > **"Require approval for all external contributors"**, or remove the exposure entirely with a paid org and private repos.

### Moving to private repos later

Repos start public on a free org. To convert them afterwards:

1. **Upgrade the org to Team first.** Private repos are free, but *environments* on private repos are not. Converting while still on Free silently ignores protection rules, and because the federated credential subjects are environment-scoped (`...:environment:alz-mgmt-apply:...`), Azure then rejects the OIDC token and the pipeline fails to authenticate. The symptom is `AADSTS700213`, which looks nothing like a billing problem.
2. **Convert the module repo (`<name>`) to private.** A private caller can still call a public reusable workflow, so nothing breaks yet.
3. **Convert the templates repo (`<name>-templates`) to private.**
4. **Set its Actions access policy immediately**: templates repo > Settings > Actions > **General** > *Access* > "Accessible from repositories in the organization". Without it the caller cannot resolve the reusable workflow, and the error does not look like a permissions problem.
5. **Verify**: run `02 Continuous Delivery` and confirm it plans, reaches the approval gate, and applies.

Simpler alternative: leave the **templates** repo public. A private caller calling a public reusable workflow needs no access policy, and that repo holds workflow logic rather than your tenant identifiers.

## Requirements

- PowerShell 7.4+
- Azure CLI 2.55+ signed in (`az login`)
- A GitHub **organization** and a fine-grained PAT with repo permissions (Actions, Administration, Contents, Environments, Secrets, Variables, **Workflows**) all Read/write, plus Organization **Members** Read/write (see the accelerator [GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/))
- A second PAT (Repository Administration + Organization Self-hosted runners) if you choose self-hosted runners
- Optional: an HCP Terraform workspace in **Local** execution mode (if using HCP for state)
- Bicep only: **User Access Administrator** at the root (`/`) scope, which Terraform does not need

## Usage

```powershell
cd "<path>\ALZAutoPilot"
.\Start-ALZDelivery.ps1 -DeliveryPath "C:\Users\<you>\Documents\ALZ"
```

- `-DeliveryPath` - root folder for this delivery's `config/`, `output/`, and saved state. If omitted, you're prompted. Use a plain local path, not a cloud-synced folder.
- `-Reset` - start over, ignoring saved state.
- `-SkipPreflight` - jump to config/bootstrap (not recommended).
- `-NoClear` - keep existing console output instead of clearing the screen on start.

Re-running the same command resumes from wherever you left off.

## Flow

```
Plan (interview) -> Prerequisites -> Generate config -> Bootstrap -> [HCP state] -> Deploy platform -> Report
```

Plan, Prerequisites, Generate config, and Bootstrap are fully automated. The platform deployment can be driven from the CLI (trigger, watch, approve, verify) or printed as a manual runbook so a customer can watch it happen in GitHub. When HCP is selected, the migration steps are printed and then **verified** against the repos before the pipeline runs. Every run ends with an HTML report in the delivery folder.

## Layout

```
ALZAutoPilot/
  Start-ALZDelivery.ps1     # entry point / orchestrator
  modules/
    ALZUI.psm1              # console output, progress, summary, remediation panels
    ALZState.psm1           # state persistence + resume (never stores secrets)
    ALZSecurity.psm1        # secret handling and input sanitization
    ALZPreflight.psm1       # all prerequisite checks + RP registration
    ALZConfig.psm1          # interview + config generation
    ALZOrchestrator.psm1    # Deploy-Accelerator wrapper + error translation
    ALZPipeline.psm1        # pipeline trigger/watch/verify + HCP readiness checks
    ALZReport.psm1          # HTML delivery report
  data/
    providers.json          # ALZ-recommended resource providers
    scenarios.json          # Terraform scenario catalog
    traps.json              # known error signatures -> remediation
    scenarios/              # the 11 official Terraform scenario configs
    scenarios-bicep/        # the official Bicep platform config
  samples/
    lib-pci/                # custom library example: regulated MG + PCI/HIPAA
  tests/
    Test-ALZConfigConformance.ps1   # offline: generated config vs the accelerator schema
  CHANGELOG.md              # version history
  .alz-delivery-state.json  # created per delivery folder (not here)
```

## Versioning

[Semantic versioning](https://semver.org/): MAJOR for breaking changes, MINOR for new capability, PATCH for fixes and documentation. History is in [CHANGELOG.md](CHANGELOG.md).

The version is defined once, in `$ALZVersion` at the top of `Start-ALZDelivery.ps1`. It appears on the splash screen and in the footer of every delivery report, so a report can always be traced back to the build that produced it. Bump it and add a changelog entry with each change.

## Delivery report

Every run writes `<delivery>\reports\alz-delivery-<timestamp>.html`. The console keeps a short summary and points at it, so the detail lives in a file you can share rather than scrolling past.

One self-contained file with inline CSS and no external references: it opens offline, emails cleanly, and prints for a closeout deck. It contains no credentials, and every value is HTML-encoded.

A published example is in [sample-delivery-report.html](sample-delivery-report.html), rendered entirely from fictional data. Regenerate it with `scripts/New-SampleReport.ps1`.

What is in it:

| Section | Contents |
|---|---|
| Target | Region, topology, version control, state backend, runners, approvers |
| Platform subscriptions | Each role, or "not supplied" where you skipped one |
| Deployed | Module repo, management group and policy counts, resource groups |
| Policy baseline | What the baseline is, counts by type and enforcement, per management group, and the exact assignment names |
| Phases | Status and duration for each phase |
| Session | Run counts, delivery age, folder |

### The policy baseline section

This exists because the most common question after a first deployment is "what did I just deploy, and how would I know what is normal?" It answers that from your tenant rather than from documentation:

- Totals: assignments, initiatives, single policies, enforced vs audit-only.
- A per management group breakdown, with a reminder that assignments inherit downward.
- **The exact assignment names**, collapsed per management group. The ALZ library version-stamps these (`Deploy-MDFC-Config-H224`), so they cannot be guessed or copied from a blog post. A snippet above them shows where the name goes in `policy_assignments_to_modify`.
- Assignments at the tenant root are labelled **pre-existing**, because the accelerator only assigns at `alz` and below. Without that, policies that were already in the tenant get misread as something the accelerator deployed.

Before the pipeline has run there are no assignments yet, so the section says so and tells you to re-run afterwards rather than showing a bare zero.

## Tests

```powershell
.\tests\Test-ALZConfigConformance.ps1
```

Parses `variables.tf` from the accelerator's own bootstrap modules and checks the generated `inputs.yaml` against it, across GitHub and Azure DevOps, Terraform and Bicep: every key emitted is one the module declares, every required variable is present, and the token is a placeholder rather than a credential. It runs entirely offline, with no Azure, GitHub, or Azure DevOps access.

If the accelerator changes its schema in a new version, this fails locally instead of failing partway through someone's bootstrap. It skips cleanly when no bootstrap module has been downloaded yet.

## Customizing for your selections

Two files come out of the config phase, both in `<delivery>\config`:

| File | What it is | Who owns it after bootstrap |
|---|---|---|
| `inputs.yaml` | Bootstrap inputs: org, subscriptions, approvers, runners, state | You, in the delivery folder. Only re-read on a re-bootstrap |
| `platform-landing-zone.tfvars` (or `.yaml` for Bicep) | Your landing zone as configuration | Pushed into the **module repo**. After that, changes go through a pull request |

Values that are normally hand-edited are filled in for you. On a re-run only regions, security contact, and subscription placement are patched, so your own edits survive.

| Your choice | What you customize, and where |
|---|---|
| **Terraform** | IP ranges, naming, DDoS, policy settings: edit the tfvars before bootstrap, or through a PR afterward |
| **Bicep** | `platform-landing-zone.yaml`, plus the generated Bicep in the module repo. Also requires User Access Administrator at the root (`/`) scope |
| **GitHub** | Branch protection, environment reviewers, and repo settings in the GitHub UI |
| **Azure DevOps** | Approvals and checks on the Apply environment, and the service connection, in the Azure DevOps UI |
| **Scenario / network type** | Changing topology later means replacing the platform config with another scenario and letting the pipeline apply the difference |
| **Multi-region** | Extend `starter_locations`. A real multi-entry list is never shrunk on a re-run |
| **HCP Terraform** | The `cloud {}` block, the `TF_TOKEN_app_terraform_io` secret, removing `-backend-config` flags, and `secrets: inherit`. Eight live checks tell you which is still wrong |
| **Self-hosted runners** | Needs a second PAT at bootstrap. Address space and subnet prefixes are bootstrap module variables if the defaults collide |
| **Custom library** | Put custom management groups, archetypes, and policy assignments in `<delivery>\config\lib`. See [samples/lib-pci](samples/lib-pci/README.md) |

If you pick a different Terraform scenario on a re-run, the tool notices the existing platform config no longer matches and asks before replacing it, because replacing discards manual edits.

## Security

- **Secrets never persisted.** The GitHub PAT and HCP token are read with `Read-Host -AsSecureString`, converted to plaintext only in-memory, and never written to `inputs.yaml` or the state file. `inputs.yaml` references the PAT via the `TF_VAR_github_personal_access_token` environment variable, matching the accelerator's own pattern.
- **Unmanaged memory freed.** `ConvertTo-ALZPlainText` frees the `BSTR` (`ZeroFreeBSTR`) immediately after copying, so the plaintext does not linger in unmanaged memory.
- **Env var scoped to the run.** `TF_VAR_github_personal_access_token` is set only for the bootstrap and cleared in a `finally` block.
- **Transcript scrubbing.** The bootstrap transcript is scanned and any token occurrence is redacted (or the file removed) before it is left on disk.
- **Injection defense.** Interview inputs are validated (region, GUIDs, org, management group ID, approver usernames), values are sanitized when written to `inputs.yaml` so a tampered state file cannot inject YAML, and user-supplied values used in API paths are URL-encoded.
- **TLS enforced.** GitHub and HCP API calls use HTTPS with default certificate validation (no `-SkipCertificateCheck`).
- **No dynamic code execution.** No `Invoke-Expression`, no remote code download. Every Azure CLI argument is a validated GUID or an app constant.
- **Requires PowerShell 7.4+** and refuses to run under Windows PowerShell 5.1.

## Known limitations

| Limitation | Detail |
|---|---|
| **Brownfield tenants** | Preflight detects an existing estate: colliding management group names, platform subscriptions already parented elsewhere, and subscriptions that already contain resources. It warns rather than blocks. What it still does not do is adopt an existing hierarchy (`update_existing` is not exposed). In a populated tenant the policy baseline applies to running workloads on the first apply, so follow Microsoft's [audit-only transition guidance](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/align-approach-duplicate-brownfield-audit-only) before pointing this at production |
| **Azure DevOps stage 2** | Config generation and bootstrap are automated. Triggering and watching the pipeline is GitHub-only |
| **Local file system VCS** | Not supported. Use the accelerator directly |
| **`bicep-classic`** | Not exposed. Terraform and Bicep only |

## Scope and roadmap

- **Tier 1 (this)**: orchestration, preflight, config generation, resume, error translation.
- **Tier 2**: live status dashboard and automated remediation for matched errors.
- **Tier 3**: a conversational ALZ delivery agent (interview + narrate) reusable across engagements.

## Sources

This tool is a 1:1 wrapper around the accelerator, so everything it shows comes from the official product rather than being reinvented here:

| What | Where it comes from |
|---|---|
| Platform config files | The accelerator's own scenario examples, bundled unmodified |
| Scenario names and numbers | [Scenarios](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/) |
| Cost estimates | The same page's published table (westus, USD, fixed infrastructure only). For another region or currency use the accelerator's `Get-ScenarioCostEstimates.ps1` |
| Management group hierarchy shown at confirmation | The official `alz` architecture definition in the [ALZ Library](https://github.com/Azure/Azure-Landing-Zones-Library) |
| Resource provider list | [Resource providers FAQ](https://azure.github.io/Azure-Landing-Zones/faq/resource-providers/) |
| PAT scopes and prerequisites | [GitHub prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/github/) and [Platform subscriptions](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/platform-subscriptions/) |
| Error remediation | Entries carrying a doc link restate official guidance. Entries without one are failures seen in live deliveries that the official troubleshooting page does not yet cover |

If the accelerator changes, treat the upstream documentation as the source of truth and refresh the bundled files (see [data/README.md](data/README.md)).

## License and attribution

MIT. See [LICENSE](LICENSE).

The platform configuration files under `data/scenarios/` and `data/scenarios-bicep/` are **unmodified** copies from Microsoft's [alz-terraform-accelerator](https://github.com/Azure/alz-terraform-accelerator) and [alz-bicep-accelerator](https://github.com/Azure/alz-bicep-accelerator), both MIT licensed. They are bundled so a delivery works offline against a known-good version. Attribution and the upstream license are in [NOTICE](NOTICE); for current versions always refer to the upstream repositories.

This is a personal project. It is not produced, endorsed, or supported by Microsoft.

## References

- [Accelerator overview](https://azure.github.io/Azure-Landing-Zones/accelerator/)
- [Phase 1 - Prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)
- [Resource provider recommendations](https://azure.github.io/Azure-Landing-Zones/faq/resource-providers/)
- [Starter Terraform scenarios (cost table)](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/scenarios/)
