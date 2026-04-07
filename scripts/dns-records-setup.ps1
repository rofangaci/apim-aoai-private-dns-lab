# DNS Records Setup for APIM Network Lab
# This script creates private DNS A records for both APIM networking modes
# Usage: .\dns-records-setup.ps1

param(
    [string]$ResourceGroup = '<resource-group-name>',
    [string]$ApimInternalName = '<apim-internal-name>',
    [string]$ApimPrivateName = '<apim-private-endpoint-name>',
    [string]$ApimInternalVip = '<apim-internal-private-ip>',
    [string]$ApimPrivateEndpointIp = '<apim-private-endpoint-ip>'
)

if ($ResourceGroup -like '<*' -or $ApimInternalName -like '<*' -or $ApimPrivateName -like '<*' -or $ApimInternalVip -like '<*' -or $ApimPrivateEndpointIp -like '<*') {
    Write-Error "Update all placeholder parameter values before running this script."
}

$ErrorActionPreference = 'Stop'

Write-Output "=== APIM Network Lab: DNS Records Setup ==="
Write-Output "Resource Group: $ResourceGroup"

# ====================
# Internal APIM DNS Records (azure-api.net zone)
# ====================
Write-Output "`n[1/2] Creating DNS A records for Internal APIM in azure-api.net zone..."
$dnsZone = 'azure-api.net'
$endpoints = @(
    $ApimInternalName,
    "$ApimInternalName.portal",
    "$ApimInternalName.developer",
    "$ApimInternalName.management",
    "$ApimInternalName.scm"
)

foreach ($ep in $endpoints) {
    try {
        az network private-dns record-set a add-record `
            -g $ResourceGroup `
            -z $dnsZone `
            -n $ep `
            --ipv4-address $ApimInternalVip `
            --only-show-errors `
            --output none
        Write-Output "  ✓ Created: $ep.azure-api.net -> $ApimInternalVip"
    }
    catch {
        Write-Output "  ✗ Failed to create $ep`: $_"
    }
}

# ====================
# Private Endpoint APIM DNS Records (privatelink.azure-api.net zone)
# ====================
Write-Output "`n[2/2] Creating DNS A records for Private Endpoint APIM in privatelink.azure-api.net zone..."
$dnsZone = 'privatelink.azure-api.net'
$peEndpoint = "$ApimPrivateName.privatelink.azure-api.net"

try {
    az network private-dns record-set a add-record `
        -g $ResourceGroup `
        -z $dnsZone `
        -n $ApimPrivateName `
        --ipv4-address $ApimPrivateEndpointIp `
        --only-show-errors `
        --output none
    Write-Output "  ✓ Created: $peEndpoint -> $ApimPrivateEndpointIp"
}
catch {
    Write-Output "  ✗ Failed to create PE record: $_"
}

# ====================
# Verification
# ====================
Write-Output "`n=== Verification ==="
Write-Output "`nInternal APIM DNS Records (azure-api.net):"
az network private-dns record-set a list `
    -g $ResourceGroup `
    -z 'azure-api.net' `
    --query "[].{name:name, ip:aRecords[0].ipv4Address}" `
    -o table

Write-Output "`nPrivate Endpoint APIM DNS Records (privatelink.azure-api.net):"
az network private-dns record-set a list `
    -g $ResourceGroup `
    -z 'privatelink.azure-api.net' `
    --query "[].{name:name, ip:aRecords[0].ipv4Address}" `
    -o table

Write-Output "`n✅ DNS records setup completed!"
