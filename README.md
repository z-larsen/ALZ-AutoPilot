<!-- markdownlint-disable -->
```
    _     _      _____ 
   / \   | |    |__  / 
  / _ \  | |      / /  
 / ___ \ | |___  / /_  
/_/   \_\|_____|/____| 

    _     _   _  _____   ___   ____   ___  _       ___   _____ 
   / \   | | | ||_   _| / _ \ |  _ \ |_ _|| |     / _ \ |_   _|
  / _ \  | | | |  | |  | | | || |_) | | | | |    | | | |  | |  
 / ___ \ | |_| |  | |  | |_| ||  __/  | | | |___ | |_| |  | |  
/_/   \_\ \___/   |_|   \___/ |_|    |___||_____| \___/   |_|  
```

# ALZ Autopilot

Guided automation for the official [Azure Landing Zones IaC Accelerator](https://azure.github.io/Azure-Landing-Zones/accelerator/). It does not change what the accelerator does - it fixes how the process is *presented*: one entry point, a short interview, all prerequisite checks up front with exact fixes, generated config (no hand-editing scattered files), an automated (or guided-manual) platform deployment, and clean resume after an interrupted run.

Built after a live delivery where the pain was never ALZ itself - it was the scattered tooling (PowerShell wizard + GitHub UI + HCP UI + YAML + tfvars + docs across many pages) and opaque errors that only surfaced mid-apply. Suitable for both internal rehearsals and customer-facing engagements.

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
| **Version control** | GitHub. Azure DevOps and local are not currently supported |

The platform config is generated from the **official** scenario file for your choice, then it is yours to edit. Re-runs patch only the values the interview owns (regions, security contact, subscription placement) so hand edits survive.

## What it fixes

| Pain in the raw accelerator | What this adds |
|---|---|
| Steps spread across a wizard, two web UIs, and several doc pages | One `Start-ALZDelivery.ps1` entry point |
| Errors surface as Terraform stack traces mid-apply | Preflight validates tooling, Azure Owner, resource providers, GitHub PAT/org/Members, and HCP **before** bootstrap |
| A closed terminal means spelunking through `output/` | State saved after every step; re-run resumes automatically |
| Hand-edit `inputs.yaml` and dodge `${starter_location_01}` token traps | Config generated from your answers |
| Cryptic failures (RP timeout, SSO, backend-config, TF_TOKEN, missing Workflows/Members scope) | Known failures matched to plain-language remediation |
| "Bootstrap succeeded" but the repos are empty | Post-bootstrap check verifies the repos actually received the workflows |
| PAT pasted into notes/files | Token entered masked, used in-memory only, never written to disk |
| Manual pipeline click-through + guessing the approval gate | Discovers the repo, triggers + watches the run, detects the apply gate, verifies MGs + policies |
| "Have you done the HCP migration?" answered on trust | Eight live checks against the repos: cloud block, no leftover azurerm backend, `TF_TOKEN_app_terraform_io` secret, no `-backend-config` flags, secret wiring, `secrets: inherit` |

## GitHub plan note

The accelerator ties its approval gate and Azure-auth config to GitHub **environments**, which on a **free org only work on public repos** - so a free org gets **public** repos (fine for a rehearsal; nothing sensitive is exposed). A **Team/Enterprise/EMU** org gets **private** repos with the gate intact. The app works with both and warns you in preflight when the org is free.

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
Plan (interview) -> Prerequisites -> Generate config -> Bootstrap -> [HCP state] -> Deploy platform -> Summary
```

Plan, Prerequisites, Generate config, and Bootstrap are fully automated. The platform deployment can be driven from the CLI (trigger, watch, approve, verify) or printed as a manual runbook so a customer can watch it happen in GitHub. When HCP is selected, the migration steps are printed and then **verified** against the repos before the pipeline runs.

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
  data/
    providers.json          # ALZ-recommended resource providers
    scenarios.json          # Terraform scenario catalog
    traps.json              # known error signatures -> remediation
    scenarios/              # the 11 official Terraform scenario configs
    scenarios-bicep/        # the official Bicep platform config
  samples/
    lib-pci/                # custom library example: regulated MG + PCI/HIPAA
  .alz-delivery-state.json  # created per delivery folder (not here)
```

## Security

- **Secrets never persisted.** The GitHub PAT and HCP token are read with `Read-Host -AsSecureString`, converted to plaintext only in-memory, and never written to `inputs.yaml` or the state file. `inputs.yaml` references the PAT via the `TF_VAR_github_personal_access_token` environment variable, matching the accelerator's own pattern.
- **Unmanaged memory freed.** `ConvertTo-ALZPlainText` frees the `BSTR` (`ZeroFreeBSTR`) immediately after copying, so the plaintext does not linger in unmanaged memory.
- **Env var scoped to the run.** `TF_VAR_github_personal_access_token` is set only for the bootstrap and cleared in a `finally` block.
- **Transcript scrubbing.** The bootstrap transcript is scanned and any token occurrence is redacted (or the file removed) before it is left on disk.
- **Injection defense.** Interview inputs are validated (region, GUIDs, org, management group ID, approver usernames), values are sanitized when written to `inputs.yaml` so a tampered state file cannot inject YAML, and user-supplied values used in API paths are URL-encoded.
- **TLS enforced.** GitHub and HCP API calls use HTTPS with default certificate validation (no `-SkipCertificateCheck`).
- **No dynamic code execution.** No `Invoke-Expression`, no remote code download. Every Azure CLI argument is a validated GUID or an app constant.
- **Requires PowerShell 7.4+** and refuses to run under Windows PowerShell 5.1.

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
