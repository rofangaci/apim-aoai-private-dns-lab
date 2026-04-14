#Requires -Version 7.0
<#!
.SYNOPSIS
    Validates APIM + AOAI private lab deployment health and configuration.

.DESCRIPTION
    Performs end-to-end checks for core infrastructure and optional post-deploy
    APIM API configuration steps.

.EXAMPLE
    ./scripts/validate-deployment.ps1 -ResourceGroup rg-apimrepo-rofangaci
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$DeploymentName = 'apim-lab-deploy',

    [string]$ExpectedApiId = 'aoai-4o',

    [string]$ExpectedModelDeploymentName = 'gpt4o-demo'
)

$ErrorActionPreference = 'Stop'
$failureCount = 0
$warningCount = 0

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    $script:failureCount++
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
    $script:warningCount++
}

Write-Host "Validating deployment in resource group: $ResourceGroup" -ForegroundColor Cyan
Write-Host ''

try {
    $deploymentState = az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.provisioningState -o tsv 2>$null
    if ($deploymentState -eq 'Succeeded') {
        Write-Pass "Deployment '$DeploymentName' state is Succeeded"
    }
    elseif ($deploymentState) {
        Write-Warn "Deployment '$DeploymentName' state is $deploymentState"
    }
    else {
        Write-Warn "Deployment '$DeploymentName' not found"
    }
}
catch {
    Write-Warn "Unable to read deployment state: $($_.Exception.Message)"
}

$vnet = az network vnet list -g $ResourceGroup --query "[0].{name:name,id:id}" -o json | ConvertFrom-Json
if (-not $vnet) {
    Write-Fail 'No VNet found in resource group'
}
else {
    Write-Pass "VNet found: $($vnet.name)"

    $subnetNames = az network vnet subnet list -g $ResourceGroup --vnet-name $vnet.name --query "[].name" -o tsv
    foreach ($requiredSubnet in @('snet-apim-int', 'snet-private-endpoints', 'snet-jumpbox')) {
        if ($subnetNames -contains $requiredSubnet) {
            Write-Pass "Subnet exists: $requiredSubnet"
        }
        else {
            Write-Fail "Missing subnet: $requiredSubnet"
        }
    }
}

$requiredZones = @('azure-api.net', 'privatelink.azure-api.net', 'privatelink.openai.azure.com')
foreach ($zone in $requiredZones) {
    $zoneExists = az network private-dns zone show -g $ResourceGroup -n $zone --query name -o tsv 2>$null
    if ($zoneExists) {
        Write-Pass "Private DNS zone exists: $zone"

        if ($vnet) {
            $linkCount = az network private-dns link vnet list -g $ResourceGroup -z $zone --query "[?virtualNetwork.id=='$($vnet.id)'] | length(@)" -o tsv
            if ([int]$linkCount -ge 1) {
                Write-Pass "Private DNS zone linked to VNet: $zone"
            }
            else {
                Write-Fail "Private DNS zone is not linked to VNet: $zone"
            }
        }
    }
    else {
        Write-Fail "Missing private DNS zone: $zone"
    }
}

$apimServices = az apim list -g $ResourceGroup -o json | ConvertFrom-Json
if (-not $apimServices -or $apimServices.Count -lt 2) {
    Write-Fail 'Expected two APIM services (internal + private mode)'
}
else {
    Write-Pass "APIM service count: $($apimServices.Count)"
}

$apimInternal = $apimServices | Where-Object { $_.virtualNetworkType -eq 'Internal' } | Select-Object -First 1
$apimPrivate = $apimServices | Where-Object { $_.virtualNetworkType -eq 'None' } | Select-Object -First 1

if ($apimInternal) {
    Write-Pass "Internal APIM found: $($apimInternal.name)"
    if ($apimInternal.provisioningState -eq 'Succeeded') {
        Write-Pass 'Internal APIM provisioning state is Succeeded'
    }
    else {
        Write-Warn "Internal APIM provisioning state: $($apimInternal.provisioningState)"
    }

    if ($apimInternal.identity.principalId) {
        Write-Pass 'Internal APIM managed identity is enabled'
    }
    else {
        Write-Fail 'Internal APIM managed identity is missing'
    }
}
else {
    Write-Fail 'Internal APIM (virtualNetworkType=Internal) not found'
}

if ($apimPrivate) {
    Write-Pass "Private-mode APIM found: $($apimPrivate.name)"
    if ($apimPrivate.provisioningState -eq 'Succeeded') {
        Write-Pass 'Private-mode APIM provisioning state is Succeeded'
    }
    else {
        Write-Warn "Private-mode APIM provisioning state: $($apimPrivate.provisioningState)"
    }
}
else {
    Write-Fail 'Private-mode APIM (virtualNetworkType=None) not found'
}

$aoai = az cognitiveservices account list -g $ResourceGroup --query "[?kind=='OpenAI'] | [0]" -o json | ConvertFrom-Json
if (-not $aoai) {
    Write-Fail 'Azure OpenAI account not found'
}
else {
    Write-Pass "Azure OpenAI account found: $($aoai.name)"

    if ($aoai.properties.publicNetworkAccess -eq 'Disabled') {
        Write-Pass 'AOAI public network access is Disabled'
    }
    else {
        Write-Warn "AOAI public network access is $($aoai.properties.publicNetworkAccess)"
    }

    $modelDeployments = az cognitiveservices account deployment list -g $ResourceGroup -n $aoai.name --query "[].name" -o tsv
    if ($modelDeployments -contains $ExpectedModelDeploymentName) {
        Write-Pass "AOAI model deployment exists: $ExpectedModelDeploymentName"
    }
    elseif ($modelDeployments) {
        Write-Warn "AOAI deployment exists but not '$ExpectedModelDeploymentName': $($modelDeployments -join ', ')"
    }
    else {
        Write-Fail 'No AOAI model deployment found'
    }
}

$privateEndpointGroupIds = az network private-endpoint list -g $ResourceGroup --query "[].privateLinkServiceConnections[0].groupIds[0]" -o tsv
if ($privateEndpointGroupIds -contains 'Gateway') {
    Write-Pass 'APIM private endpoint (Gateway group) exists'
}
else {
    Write-Fail 'APIM private endpoint (Gateway group) not found'
}

if ($privateEndpointGroupIds -contains 'account') {
    Write-Pass 'AOAI private endpoint (account group) exists'
}
else {
    Write-Fail 'AOAI private endpoint (account group) not found'
}

$jumpboxName = az vm list -g $ResourceGroup --query "[?starts_with(name,'vm-jumpbox')]|[0].name" -o tsv
if ($jumpboxName) {
    Write-Pass "Jumpbox VM found: $jumpboxName"
    $vmPowerState = az vm get-instance-view -g $ResourceGroup -n $jumpboxName --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv
    if ($vmPowerState) {
        Write-Pass "Jumpbox power state: $vmPowerState"
    }
}
else {
    Write-Fail 'Jumpbox VM not found'
}

if ($apimInternal -and $apimInternal.identity.principalId -and $aoai -and $aoai.id) {
    $roleAssignmentCount = az role assignment list --assignee-object-id $apimInternal.identity.principalId --scope $aoai.id --query "[?roleDefinitionName=='Cognitive Services OpenAI User'] | length(@)" -o tsv
    if ([int]$roleAssignmentCount -ge 1) {
        Write-Pass 'RBAC assignment exists: Cognitive Services OpenAI User'
    }
    else {
        Write-Fail 'Missing RBAC assignment: Cognitive Services OpenAI User'
    }
}

if ($apimInternal) {
    $apiExists = az apim api show -g $ResourceGroup --service-name $apimInternal.name --api-id $ExpectedApiId --query name -o tsv 2>$null
    if ($apiExists) {
        Write-Pass "APIM API exists: $ExpectedApiId"

        $subscriptionId = az account show --query id -o tsv
        $policyUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$($apimInternal.name)/apis/$ExpectedApiId/policies/policy?api-version=2022-08-01"
        $policyValue = az rest --method get --uri $policyUri --query properties.value -o tsv 2>$null

        if ($policyValue -match 'authentication-managed-identity') {
            Write-Pass 'APIM API policy contains authentication-managed-identity'
        }
        else {
            Write-Warn 'APIM API policy does not yet contain authentication-managed-identity'
        }
    }
    else {
        Write-Warn "APIM API '$ExpectedApiId' not found yet (run README Step 2)"
    }
}

Write-Host ''
Write-Host "Validation complete. Failures: $failureCount  Warnings: $warningCount" -ForegroundColor Cyan
if ($failureCount -gt 0) {
    exit 1
}

exit 0
