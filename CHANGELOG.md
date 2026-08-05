<!-- markdownlint-disable -->
# Changelog

All notable changes to ALZ Autopilot.

Versioning follows [semantic versioning](https://semver.org/): **MAJOR** for breaking changes, **MINOR** for new capability, **PATCH** for fixes and documentation.

The version is defined once, in `$ALZVersion` at the top of `Start-ALZDelivery.ps1`. It appears on the splash screen and in the footer of every delivery report, so an artifact can always be traced back to the build that produced it.

## 1.6.3

- README now embeds **screenshots** of the delivery report instead of linking the raw HTML, because GitHub does not render committed HTML inline and the file downloaded rather than displayed. The generator remains for regenerating them.

## 1.6.2

- The sample report is now published in the repo, and the generator scrubs its own scratch path (which carried the local username) before writing. It refuses to produce a file that still contains the username, `AppData`, or `OneDrive`.

## 1.6.1

- Added `scripts/New-SampleReport.ps1`, which renders a fully populated delivery report from fictional data (Contoso names, throwaway GUIDs, a representative slice of the ALZ baseline) for screenshots and documentation. It reads the version from its single source rather than hardcoding one.

## 1.6.0

- Preflight warns when a **free GitHub org is combined with self-hosted runners**. That pairing puts VNet-resident runners, which have private-endpoint access to the Terraform state, on a repository anyone can fork. GitHub advises against it, and the tool previously steered users into it without comment.
- Documented **moving to private repos later**: Team is required because environments do not work on private repos under GitHub Free, converting on Free strips the `environment:` claim and breaks Azure OIDC with `AADSTS700213`, and two private repos require an Actions access policy on the called workflow's repository.

## 1.5.0

- **Brownfield detection in preflight.** A single management group descendants call reports colliding ALZ group names, platform subscriptions already parented elsewhere, and subscriptions that already contain resources. A full set of ALZ groups is treated as a re-run rather than a collision, so re-running against an existing deployment stays quiet.
- These checks warn and never block, because deploying into a populated tenant is legitimate, it just needs care.

## 1.4.1

- Delivery report lists the **exact policy assignment names** per management group, with a snippet showing where a name goes in `policy_assignments_to_modify`. The ALZ library version-stamps these names, so they cannot be guessed or copied from documentation.
- Assignments at the tenant root are labelled **pre-existing**, because the accelerator only assigns at `alz` and below. Without that they were misread as something the accelerator deployed.
- Fixed report filenames colliding when two reports were generated inside the same second.

## 1.4.0

- **Policy baseline section** in the delivery report: totals, initiatives versus single policies, enforced versus audit-only, and a per management group breakdown. Written to answer "what did I just deploy, and how would I know what is normal?" from the tenant rather than from documentation.
- Before the pipeline has run the section says nothing is assigned yet and points at the re-run, instead of showing a bare zero.

## 1.3.0

- **HTML delivery report** written to `<delivery>\reports\`. One self-contained file with no external references, so it opens offline, emails cleanly, and prints for a closeout deck. The console summary shrank to the few lines worth reading plus the report path.
- **`terraform fmt` check** on the generated config. The accelerator's CI runs `terraform fmt -check` and fails the build on unformatted files, which blocks every future pull request. Formatting is whitespace-only, so it is corrected rather than just reported.

## 1.2.1

- Fixed platform verification always reporting **zero policy assignments**. It used `--disable-scope-strict-match`, which Azure rejects at management group scope with `UnsupportedFilter`, and the error was swallowed. It now enumerates each management group with the supported `atScope()` filter and deduplicates by assignment ID.
- The same broken command was printed in the manual runbook.

## 1.2.0

- **Azure DevOps support** through config generation and bootstrap. Approver validation follows the target system, sign-in addresses for Azure DevOps and usernames for GitHub, because the two bootstrap modules expect different formats. Stage 2 prints a runbook, because triggering and watching the pipeline is implemented against the GitHub API.
- **Offline conformance test** (`tests/Test-ALZConfigConformance.ps1`). Parses `variables.tf` from the accelerator's own bootstrap modules and checks the generated `inputs.yaml` against both schemas, across Terraform and Bicep. Requires no Azure, GitHub, or Azure DevOps access, so an accelerator schema change fails locally instead of partway through a customer's bootstrap.

## 1.1.0

- **Configuration review gate.** After config generation and before the bootstrap, the run stops and offers to open the platform config. It defaults to No, because after the bootstrap that file lives in the module repo and every later change goes through a pull request.
- Documented the full set of safety gates. "One command" means one entry point, not unattended deployment.

## 1.0.1

- Splash screen and next-step guidance rewritten to describe the operating model rather than stale switch instructions.

## 1.0.0

Initial public release.

- Guided interview, resumable state, and generated config for all 11 official Terraform scenarios plus the three Bicep network types.
- Live prerequisite checks with plain-language remediation for known failures.
- `Deploy-Accelerator` wrapper with error translation, secret handling that never touches disk, and post-bootstrap verification that the repos received their workflows.
- Pipeline trigger, watch, approval detection, and outcome verification.
- HCP Terraform state migration verified with eight live checks.
- Custom ALZ library pass-through, with a worked PCI DSS and HITRUST example.
