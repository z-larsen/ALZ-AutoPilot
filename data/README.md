<!-- markdownlint-disable -->
# Bundled platform configuration files

These files are **unmodified** copies from Microsoft's Azure Landing Zones accelerators, redistributed under the MIT License. They are not authored by this project.

| Folder | Upstream source |
|---|---|
| `scenarios/` | [Azure/alz-terraform-accelerator](https://github.com/Azure/alz-terraform-accelerator) &rarr; `templates/platform_landing_zone/examples/` |
| `scenarios-bicep/` | [Azure/alz-bicep-accelerator](https://github.com/Azure/alz-bicep-accelerator) &rarr; `examples/platform-landing-zone.yaml` |

Terraform files are renamed to the scenario key the app uses, so the mapping is explicit:

| Scenario key | Upstream path |
|---|---|
| `management-only` | `management-only/management.tfvars` |
| `single-region-hub-and-spoke-vnet-with-azure-firewall` | `full-single-region/hub-and-spoke-vnet.tfvars` |
| `single-region-virtual-wan-with-azure-firewall` | `full-single-region/virtual-wan.tfvars` |
| `single-region-hub-and-spoke-vnet-with-nva` | `full-single-region-nva/hub-and-spoke-vnet.tfvars` |
| `single-region-virtual-wan-with-nva` | `full-single-region-nva/virtual-wan.tfvars` |
| `multi-region-hub-and-spoke-vnet-with-azure-firewall` | `full-multi-region/hub-and-spoke-vnet.tfvars` |
| `multi-region-virtual-wan-with-azure-firewall` | `full-multi-region/virtual-wan.tfvars` |
| `multi-region-hub-and-spoke-vnet-with-nva` | `full-multi-region-nva/hub-and-spoke-vnet.tfvars` |
| `multi-region-virtual-wan-with-nva` | `full-multi-region-nva/virtual-wan.tfvars` |
| `smb-single-region-hub-and-spoke-vnet-with-azure-firewall` | `smb-single-region/hub-and-spoke-vnet.tfvars` |
| `smb-single-region-virtual-wan-with-azure-firewall` | `smb-single-region/virtual-wan.tfvars` |

They are bundled rather than downloaded so a delivery works offline, behind a restrictive proxy, and against a known-good version instead of whatever upstream happens to be that day.

**Refreshing them**: re-download from the upstream paths above and drop them in with the same names. Always check the upstream repositories for the current versions before a customer engagement.

See [../NOTICE](../NOTICE) for the attribution and license text.
