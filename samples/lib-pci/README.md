<!-- markdownlint-disable -->
# Sample: regulated management group with PCI DSS and HIPAA

A worked example of the two most common ALZ customization requests:

1. **Add a management group** for workloads with a compliance obligation.
2. **Assign regulatory compliance policies** (PCI DSS, HITRUST/HIPAA) to it.

Neither is done in the portal. Both are code in a custom ALZ library, applied by the same pipeline that deployed your landing zone.

## What this sample contains

```
lib-pci/
├── policy_assignments/
│   ├── Assign-PCI-DSS-v4.alz_policy_assignment.json
│   └── Assign-HITRUST-HIPAA.alz_policy_assignment.json
├── archetype_definitions/
│   └── corp_regulated.alz_archetype_definition.yaml
└── architecture_definitions/
    └── corp-regulated-mg.snippet.yaml        (a snippet, not a loadable asset)
```

The three pieces connect like this: an **assignment** says which policy to apply, an **archetype** groups assignments under a name, and the **architecture** attaches an archetype to a management group.

## Key point about regulatory compliance initiatives

PCI DSS and HITRUST/HIPAA already exist as **built-in Azure policy initiatives**. You do not author them, you assign them. That means no policy definition or policy set definition files are needed here, only assignment files.

These initiatives are almost entirely **Audit** and **AuditIfNotExists**. They report compliance in the Microsoft Defender for Cloud regulatory compliance dashboard; they do not block deployments. If you want enforcement, that is a separate set of deny policies.

Initiative IDs used here (verified against Azure):

| Initiative | Policy set definition ID |
|---|---|
| PCI DSS v4 | `c676748e-3af9-4e22-bc28-50feed564afb` |
| PCI DSS v4.0.1 | `a06d5deb-24aa-4991-9d58-fa7563154e31` |
| PCI v3.2.1:2018 | `496eeda9-8f2f-4d5e-8dfd-204f0a92ed41` |
| HITRUST/HIPAA | `a169a624-5599-4385-a696-c8d643089fab` |
| HITRUST CSF v11.3 | `e0d47b75-5d99-442a-9d60-07f2595ab095` |

Confirm the current list for your tenant with:

```powershell
az policy set-definition list --query "[?policyType=='BuiltIn']" -o json |
  ConvertFrom-Json | Where-Object { $_.displayName -match 'PCI|HIPAA|HITRUST' } |
  Select-Object displayName, id
```

## How to use it

### 1. Copy the assets into your delivery library

```powershell
$lib = "C:\Users\<you>\Documents\ALZ\config\lib"
Copy-Item ".\samples\lib-pci\policy_assignments\*"    "$lib\policy_assignments\"    -Force
Copy-Item ".\samples\lib-pci\archetype_definitions\*" "$lib\archetype_definitions\" -Force
```

ALZ Autopilot detects `config/lib` and passes it to the accelerator automatically via `starter_additional_files`. Nothing else to wire up.

### 2. Add the management group

Open `config/lib/alz_custom.alz_architecture_definition.yaml` and add the entry from `architecture_definitions/corp-regulated-mg.snippet.yaml` to the existing `management_groups` list.

**Do not replace that file.** The architecture definition describes the entire hierarchy, so deleting the other entries would remove those management groups.

Listing two archetypes (`corp` and `corp_regulated`) is intentional: the management group keeps the standard corp policies and adds the compliance initiatives on top. Multiple archetypes per management group is a supported pattern.

### 3. Deploy

If you have not bootstrapped yet, just run ALZ Autopilot normally: the library is picked up during bootstrap.

If your landing zone is already deployed, commit the library change to the module repo and let the pipeline apply it:

```powershell
git add lib/ && git commit -m "Add regulated management group with PCI and HIPAA" && git push
```

The `02 Continuous Delivery` workflow runs plan, waits at the approval gate, then applies. Expect to see the new management group created and two policy assignments added.

## Verifying

```powershell
az account management-group list --query "[?name=='corp-regulated']" -o table
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/corp-regulated" -o table
```

Compliance results take time to populate. Check the Defender for Cloud regulatory compliance dashboard after the first evaluation cycle rather than expecting instant results.

## Adapting this

- **Different framework**: swap the `policyDefinitionId` for another built-in initiative (NIST SP 800-53, ISO 27001, CIS, FedRAMP). The file structure does not change.
- **No separate management group**: if every workload is in scope, skip step 2 and add `corp_regulated` to an existing management group's archetype list instead.
- **Audit before enforcing**: set `enforcementMode` to `DoNotEnforce` on any assignment you want to evaluate without acting on it. That matters for deny policies, less so for these audit-based initiatives.

## Reference

- [Creating a Policy Assignment](https://azure.github.io/Azure-Landing-Zones/terraform/custom-policy/policy-assignment/)
- [Custom Policies overview](https://azure.github.io/Azure-Landing-Zones/terraform/custom-policy/)
- [Using a custom library](https://azure.github.io/Azure-Landing-Zones/terraform/howtos/customlibrary/)
- [Archetypes](https://azure.github.io/Azure-Landing-Zones-Library/assets/archetypes/)
- [Customize Management Group Names and IDs](https://azure.github.io/Azure-Landing-Zones/accelerator/starter-terraform/options/management-groups/)
- [Built-in policy initiatives](https://learn.microsoft.com/azure/governance/policy/samples/built-in-policy-sets)
