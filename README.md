# APIM to Azure OpenAI (Private) Lab

## Purpose

Demonstrate private networking and DNS design for Azure API Management (APIM) connecting to Azure OpenAI (AOAI), and validate end-to-end request flow where all traffic stays on private paths inside a VNet.

The lab covers two APIM connectivity modes side by side:

| Mode | How clients reach APIM | DNS zone used |
|---|---|---|
| Internal VNet injection | Private VIP inside the VNet | `azure-api.net` |
| Private endpoint | Private endpoint NIC/IP | `privatelink.azure-api.net` |

AOAI is always accessed through a private endpoint (`privatelink.openai.azure.com`), so APIM-to-AOAI traffic never leaves the VNet.

## Architecture

```
Jumpbox VM (snet-jumpbox)
    │
    │  private DNS: <apim>.azure-api.net → APIM private VIP
    ▼
APIM internal gateway (snet-apim-int)
    │  managed identity token injected by inbound policy
    │
    │  private DNS: <aoai>.privatelink.openai.azure.com → PE NIC IP
    ▼
AOAI private endpoint (snet-private-endpoints)
    │
    ▼
Azure OpenAI (gpt-4o deployment)
```

## What the Bicep deploys

`infra/apim-network-lab.bicep` creates everything in a single deployment:

| Resource | Details |
|---|---|
| VNet | Parameterized CIDR (default `10.10.0.0/24`), 3 parameterized subnets |
| NSG | Required inbound rules for APIM Developer SKU (ports 3443, 6390) |
| Private DNS zones | `azure-api.net`, `privatelink.azure-api.net`, `privatelink.openai.azure.com` |
| DNS VNet links | One per zone |
| APIM internal | Developer SKU, VNet-injected into `snet-apim-int`, system-assigned identity |
| APIM private endpoint mode | Developer SKU, accessed via private endpoint |
| Private endpoint (APIM PE mode) | NIC in `snet-private-endpoints`, DNS auto-registered |
| DNS A records | Gateway, portal, developer, management, scm for internal APIM |
| Azure OpenAI | Public access disabled, custom domain |
| AOAI model deployment | gpt-4o `2024-11-20` |
| AOAI private endpoint | NIC in `snet-private-endpoints`, DNS auto-registered |
| Role assignment | APIM managed identity → `Cognitive Services OpenAI User` on AOAI |
| Jumpbox VM | Ubuntu 22.04, `Standard_B2s`, no public IP |

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Contributor role on the target subscription
- A resource group already created

If you are starting from a new environment (for example Cloud Shell), clone the repo first:

```powershell
git clone https://github.com/rofangaci/apim-aoai-private-dns-lab.git
Set-Location .\apim-aoai-private-dns-lab
```

Supported deployment regions for this template are enforced by the Bicep `location` parameter (`@allowed`).
Default region is `centralus`.

Allowed values:
`australiaeast`, `brazilsouth`, `canadacentral`, `canadaeast`, `centralus`, `eastus`, `eastus2`, `francecentral`, `germanywestcentral`, `italynorth`, `japaneast`, `jioindiacentral`, `jioindiawest`, `koreacentral`, `northcentralus`, `norwayeast`, `polandcentral`, `southafricanorth`, `southcentralus`, `southeastasia`, `southindia`, `spaincentral`, `swedencentral`, `switzerlandnorth`, `switzerlandwest`, `uaenorth`, `uksouth`, `westeurope`, `westus`, `westus3`.

```powershell
az group create --name <resource-group> --location centralus
```

## Step 1 — Deploy infrastructure

All networking, APIM, AOAI, and the jumpbox are deployed in one command.

```powershell
az deployment group create `
  --resource-group <resource-group> `
  --name apim-lab-deploy `
  --template-file infra/apim-network-lab.bicep `
  --parameters `
  location=<region> `
      apimInternalName=<apim-internal-name> `
      apimPrivateName=<apim-private-name> `
      publisherEmail=<your-email> `
      publisherName=<your-name> `
      aoaiName=<aoai-account-name> `
      jumpboxAdminUsername=<vm-username> `
      jumpboxAdminPassword=<vm-password>
```

Optional network parameters (defaults shown):

- `vnetAddressPrefix=10.10.0.0/24`
- `apimSubnetAddressPrefix=10.10.0.0/26`
- `privateEndpointSubnetAddressPrefix=10.10.0.64/26`
- `jumpboxSubnetAddressPrefix=10.10.0.128/26`

If you omit `location`, deployment uses `centralus`.

> **Note:** APIM Developer SKU provisioning takes 30–45 minutes. Check status with:
> ```powershell
> az apim show -g <resource-group> -n <apim-internal-name> --query provisioningState -o tsv
> ```

Save the deployment outputs — you will need them in the next steps:

```powershell
az deployment group show -g <resource-group> -n apim-lab-deploy --query properties.outputs
```

Key outputs: `apimInternalPrivateIp`, `aoaiEndpoint`, `jumpboxPrivateIp`, `apimInternalGatewayUrl`.

## Step 2 — Import the AOAI OpenAPI spec into APIM

Once APIM provisioning state is `Succeeded`:

```powershell
$rg       = '<resource-group>'
$apim     = '<apim-internal-name>'
$aoai     = '<aoai-account-name>'
$apiId    = 'aoai-4o'
$spec     = 'https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json'
$endpoint = az cognitiveservices account show -g $rg -n $aoai --query properties.endpoint -o tsv

az apim api import -g $rg --service-name $apim --api-id $apiId `
  --display-name 'AOAI GPT-4o API' --path aoai4o `
  --specification-format OpenApiJson --specification-url $spec `
  --service-url ($endpoint + 'openai') --protocols https --subscription-required false
```

## Step 3 — Apply managed identity policy

Apply the inbound policy so APIM acquires an Entra token and forwards it to AOAI (no API key required):

```powershell
$subId = az account show --query id -o tsv
$uri   = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apim/apis/$apiId/policies/policy?api-version=2022-08-01"

az rest --method put --uri $uri `
  --body "@apim-op-policy.json" `
  --headers 'Content-Type=application/json'
```

The policy in `apim-op-policy.json` uses `authentication-managed-identity` to obtain a token for `https://cognitiveservices.azure.com` — no secrets are stored or transmitted.

## Step 4 — Run deployment validation script

Run the validator to confirm infrastructure, DNS, APIM, AOAI, private endpoints, RBAC, and optional API/policy post-configuration checks.

```powershell
.\scripts\validate-deployment.ps1 -ResourceGroup <resource-group>
```

Optional parameters:

- `-DeploymentName apim-lab-deploy`
- `-ExpectedApiId aoai-4o`
- `-ExpectedModelDeploymentName gpt4o-demo`
- `-SkipDeploymentRecordCheck`

Behavior:

- Script prints `PASS`, `WARN`, and `FAIL` checks.
- If `-DeploymentName` is missing/failed, the validator auto-falls back to the latest `Succeeded` deployment record when available.
- Exit code `0` when no failures are found.
- Exit code `1` when one or more failures are found.

## Step 5 — Validate from the jumpbox

### Option A: Use the test script (recommended)

```powershell
.\scripts\test-apim-chat.ps1 `
  -ResourceGroup <resource-group> `
  -ApimHost '<apim-internal-name>.azure-api.net' `
  -Message "reply with exactly: APIM_PRIVATE_PATH_OK"
```

You can omit `-Message` and the script will prompt you interactively.

If your VM name is not `vm-jumpbox`, add:

```powershell
  -JumpboxName <your-jumpbox-vm-name>
```

If the provided jumpbox name is not found, the script automatically falls back to the first VM name matching `vm-jumpbox*` in the resource group.

This script handles shell escaping automatically and prints a concise summary (`HTTP Status`, `Message`, `Tokens`).

Use `-ShowRawResponse` if you also want full headers and raw JSON body.

### Option B: SSH into the jumpbox and run curlsample

Get the jumpbox public IP (if present) or use Bastion:

```powershell
az vm show -d -g <resource-group> -n vm-jumpbox --query publicIps -o tsv
```

SSH to the jumpbox:

```bash
ssh azureuser@<jumpbox-public-ip>
export APIM_HOST=<apim-internal-name>.azure-api.net
export DEPLOYMENT_NAME=gpt4o-demo
./curlsample
```

Expected response from either option: HTTP 200 OK with a chat completion containing `APIM_PRIVATE_PATH_OK`.

## Step 6 — Run the end-to-end demo script

Run the end-to-end demo script:

```powershell
.\scripts\demo-apim-to-aoai-flow.ps1 `
  -Subscription <subscription-name-or-id> `
  -ResourceGroup <resource-group> `
  -ApimName <apim-internal-name> `
  -AoaiName <aoai-account-name> `
  -JumpboxName vm-jumpbox `
  -DeploymentName apim-lab-deploy
```

`-JumpboxPrivateIp`, `-ApimPrivateVip`, and `-AoaiPrivateEndpointIp` are optional overrides.
If omitted, the script auto-resolves values from deployment outputs and resource queries.
If `-DeploymentName` is missing/failed, the script falls back to the latest `Succeeded` deployment for output lookup.

## Step 7 — Test individual APIM operations (optional)

```powershell
.\test-apim-operations.ps1 `
  -Subscription <subscription-name-or-id> `
  -ResourceGroup <resource-group> `
  -ApimName <apim-internal-name> `
  -DeploymentId gpt4o-demo `
  -VmName vm-jumpbox
```

This opens an interactive menu to invoke individual AOAI operations (chat completions, embeddings, etc.) through the APIM gateway.

## Repo file reference

| File | Purpose |
|---|---|
| `infra/apim-network-lab.bicep` | Full infrastructure — VNet, DNS, APIM, AOAI, jumpbox |
| `apim-op-policy.json` | Managed identity inbound policy for the `aoai-4o` API |
| `apim-policy.json` | Alternative API-key-based policy (reference only) |
| `deploy-body.json` | AOAI gpt-4o model deployment payload (reference only) |
| `scripts/demo-apim-to-aoai-flow.ps1` | End-to-end demo with network topology output |
| `scripts/validate-deployment.ps1` | End-to-end deployment validation script with pass/fail summary |
| `scripts/dns-records-setup.ps1` | Standalone DNS A record setup (not needed when using Bicep) |
| `test-apim-operations.ps1` | Interactive operation tester via jumpbox |
| `curlsample` | Minimal curl test — run on jumpbox |

## Troubleshooting

**APIM stuck in `Updating` state**  
Developer SKU internal mode takes up to 45 min. Do not rerun the deployment — wait and poll `provisioningState`.

**401 / 403 from AOAI**  
- Confirm the APIM system-assigned identity exists: `az apim show -g <rg> -n <apim> --query identity`
- Confirm the role assignment landed: `az role assignment list --scope <aoai-resource-id>`

**DNS not resolving from jumpbox**  
- Confirm the private DNS zones are linked to the VNet: `az network private-dns link vnet list -g <rg> -z azure-api.net`
- Confirm A records exist: `az network private-dns record-set a list -g <rg> -z azure-api.net`

**curl returns connection refused**  
- Confirm the jumpbox subnet can reach `snet-apim-int` (no NSG blocking port 443)
- Confirm APIM provisioning state is `Succeeded`
