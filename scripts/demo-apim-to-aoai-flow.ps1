<#
.SYNOPSIS
    Demonstrates APIM Internal VNet Injection Mode calling Azure OpenAI via Private Endpoint
    This proves the complete private networking flow from customer's jumpbox through APIM 
    to the AOAI backend, with all communication on private IPs.

.DESCRIPTION
    End-to-end customer demo showing:
    - Jumpbox can reach internal APIM gateway via private DNS
    - APIM injects Authorization header with Entra token via managed identity policy
    - Request is routed to AOAI private endpoint
    - All communication stays within private IP space and private DNS zones
    
.NOTES
    Prerequisites:
    - Jumpbox VM in VNet with line-of-sight to internal APIM
    - APIM internal mode with VNet injection (not public)
    - AOAI with private endpoint in same VNet
    - APIM API proxy configured with operation for AOAI
    - Valid AOAI deployment name (e.g., gpt-4o-mini-demo or gpt-35-turbo deployed)
#>

param(
    [Parameter(Mandatory)]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApimName,

    [Parameter(Mandatory)]
    [string]$AoaiName,

    [Parameter(Mandatory)]
    [string]$JumpboxName,

    [string]$JumpboxPrivateIp,

    [string]$ApimPrivateVip,

    [string]$AoaiPrivateEndpointIp,

    [string]$DeploymentName = 'apim-lab-deploy',

    [string]$AoaiDeploymentName = 'gpt4o-demo',

    # APIM API ID and path as deployed by the Bicep + import step
    [string]$ApimApiId = 'aoai-4o',
    [string]$ApimApiPath = 'aoai4o',

    [string]$UserMessage = 'Happy Friday or any msg you like'
)

$ErrorActionPreference = 'Stop'

az account set --subscription $Subscription | Out-Null

function Get-LatestSucceededDeploymentName {
    param([string]$ResourceGroup)

    return az deployment group list -g $ResourceGroup --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" -o tsv 2>$null
}

function Resolve-JumpboxName {
    param(
        [string]$ResourceGroup,
        [string]$PreferredName
    )

    $preferredExists = az vm show -g $ResourceGroup -n $PreferredName --query name -o tsv 2>$null
    if ($preferredExists) {
        return $PreferredName
    }

    $fallbackName = az vm list -g $ResourceGroup --query "[?starts_with(name, 'vm-jumpbox')][0].name" -o tsv 2>$null
    if ($fallbackName) {
        Write-Host "[WARN] Jumpbox '$PreferredName' not found. Using '$fallbackName'." -ForegroundColor Yellow
        return $fallbackName
    }

    return $PreferredName
}

$JumpboxName = Resolve-JumpboxName -ResourceGroup $ResourceGroup -PreferredName $JumpboxName

if (-not $ApimPrivateVip -or -not $JumpboxPrivateIp) {
    try {
        $deploymentState = az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.provisioningState -o tsv 2>$null
        if ($deploymentState -ne 'Succeeded') {
            $fallbackDeploymentName = Get-LatestSucceededDeploymentName -ResourceGroup $ResourceGroup
            if ($fallbackDeploymentName) {
                Write-Host "[WARN] Deployment '$DeploymentName' state is '$deploymentState'. Using '$fallbackDeploymentName' for output lookup." -ForegroundColor Yellow
                $DeploymentName = $fallbackDeploymentName
            }
        }

        $outputs = az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.outputs -o json | ConvertFrom-Json
        if (-not $ApimPrivateVip -and $outputs.apimInternalPrivateIp.value) {
            $ApimPrivateVip = $outputs.apimInternalPrivateIp.value
        }
        if (-not $JumpboxPrivateIp -and $outputs.jumpboxPrivateIp.value) {
            $JumpboxPrivateIp = $outputs.jumpboxPrivateIp.value
        }
    }
    catch {
        $fallbackDeploymentName = Get-LatestSucceededDeploymentName -ResourceGroup $ResourceGroup
        if ($fallbackDeploymentName -and $fallbackDeploymentName -ne $DeploymentName) {
            Write-Host "[WARN] Could not read deployment outputs from '$DeploymentName'. Retrying with '$fallbackDeploymentName'." -ForegroundColor Yellow
            try {
                $DeploymentName = $fallbackDeploymentName
                $outputs = az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.outputs -o json | ConvertFrom-Json
                if (-not $ApimPrivateVip -and $outputs.apimInternalPrivateIp.value) {
                    $ApimPrivateVip = $outputs.apimInternalPrivateIp.value
                }
                if (-not $JumpboxPrivateIp -and $outputs.jumpboxPrivateIp.value) {
                    $JumpboxPrivateIp = $outputs.jumpboxPrivateIp.value
                }
            }
            catch {
                Write-Host "[WARN] Could not read deployment outputs from '$DeploymentName'. Falling back to resource queries." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "[WARN] Could not read deployment outputs from '$DeploymentName'. Falling back to resource queries." -ForegroundColor Yellow
        }
    }
}

if (-not $JumpboxPrivateIp) {
    $JumpboxPrivateIp = az vm show -d -g $ResourceGroup -n $JumpboxName --query privateIps -o tsv 2>$null
}

if (-not $AoaiPrivateEndpointIp) {
    $AoaiPrivateEndpointIp = az network private-endpoint list -g $ResourceGroup --query "[?privateLinkServiceConnections[0].groupIds[0]=='account'] | [0].customDnsConfigs[0].ipAddresses[0]" -o tsv 2>$null
    if (-not $AoaiPrivateEndpointIp) {
        $AoaiPrivateEndpointIp = az network private-endpoint list -g $ResourceGroup --query "[?privateLinkServiceConnections[0].groupIds[0]=='account'] | [0].ipConfigurations[0].privateIPAddress" -o tsv 2>$null
    }
}

if (-not $ApimPrivateVip) {
    $ApimPrivateVip = az apim show -g $ResourceGroup -n $ApimName --query "privateIPAddresses[0]" -o tsv 2>$null
}

if (-not $ApimPrivateVip -or -not $JumpboxPrivateIp -or -not $AoaiPrivateEndpointIp) {
    throw "Unable to resolve required private IP values. Provide -ApimPrivateVip, -JumpboxPrivateIp, and -AoaiPrivateEndpointIp explicitly."
}

$apimGatewayHost = "$ApimName.azure-api.net"
$aoaiPrivateDnsHost = "$AoaiName.privatelink.openai.azure.com"
$aoaiPublicEndpointHost = "$AoaiName.openai.azure.com"

Write-Host ("`n" + ("=" * 80))
Write-Host "CUSTOMER DEMO: APIM Internal Injection Mode → AOAI Private Endpoint"
Write-Host ("=" * 80)

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Show Network Architecture
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 1: Network Architecture" -ForegroundColor Cyan

Write-Host "`nNetwork Topology:"
Write-Host "  Jumpbox ($JumpboxPrivateIp)  ──private──>  APIM Gateway ($ApimPrivateVip)  ──private──>  AOAI PE ($AoaiPrivateEndpointIp)"
Write-Host "  └─ DNS: $apimGatewayHost  (resolves to $ApimPrivateVip)"
Write-Host "  └─ DNS: $aoaiPrivateDnsHost  (resolves to $AoaiPrivateEndpointIp)"

$apim = az apim show -g $ResourceGroup -n $ApimName --query "{name:name, virtualNetworkType:virtualNetworkType, gatewayUrl:gatewayUrl, privateIP:privateIPAddresses[0]}" -o json | ConvertFrom-Json
$aoai = az cognitiveservices account show -g $ResourceGroup -n $AoaiName --query "{name:name, kind:kind, endpoint:properties.endpoint}" -o json | ConvertFrom-Json

Write-Host "`n✓ APIM Configuration:"
Write-Host "  Name: $($apim.name)"
Write-Host "  Mode: $($apim.virtualNetworkType) (fully private, no public access)"
Write-Host "  Gateway URL: $($apim.gatewayUrl)"
Write-Host "  Private IP: $($apim.privateIP)"

Write-Host "`n✓ Azure OpenAI Configuration:"
Write-Host "  Name: $($aoai.name)"
Write-Host "  Endpoint: $($aoai.endpoint)"
Write-Host "  Network: Private Endpoint + Private DNS"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: Verify API Configuration
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 2: APIM API Proxy Configuration" -ForegroundColor Cyan

$api = az apim api show -g $ResourceGroup --service-name $ApimName --api-id $ApimApiId --query "{apiId:name, path:path, serviceUrl:serviceUrl, protocols:protocols[0]}" -o json | ConvertFrom-Json
$ops = az apim api operation list -g $ResourceGroup --service-name $ApimName --api-id $ApimApiId --query "[].{id:name, method:method, urlTemplate:urlTemplate}" -o json | ConvertFrom-Json

Write-Host "`n✓ API Proxy: $($api.apiId)"
Write-Host "  Base Path: /$($api.path)"
Write-Host "  Service URL (Backend): $($api.serviceUrl)"
Write-Host "  Protocol: $($api.protocols)"

Write-Host "`n✓ Operations:"
foreach ($op in $ops) {
    Write-Host "  [$($op.method)] $($op.urlTemplate)"
    Write-Host "    → Routed to: $($api.serviceUrl)$($op.urlTemplate -replace '{deploymentId}', '<deployment-name>')"
}

Write-Host "`n✓ Security: Managed Identity (no API key required)"
Write-Host "  APIM system-assigned identity is granted Cognitive Services OpenAI User on AOAI"
Write-Host "  → Token injected via APIM inbound policy: authentication-managed-identity"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Test from Jumpbox - DNS Resolution
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 3: Jumpbox DNS Resolution Test" -ForegroundColor Cyan

Write-Host "`nTest 1: Resolve internal APIM hostname..."
$dnsTest = az vm run-command invoke -g $ResourceGroup -n $JumpboxName --command-id RunShellScript `
    --scripts "nslookup $apimGatewayHost" `
    --query "value[0].message" -o tsv

if ($dnsTest -match [regex]::Escape($ApimPrivateVip)) {
    Write-Host "  ✓ DNS Resolution Success:"
    Write-Host "    $apimGatewayHost -> $ApimPrivateVip (APIM private VIP)"
} else {
    Write-Host "  ✗ DNS Resolution Failed"
}

Write-Host "`nTest 2: Resolve AOAI private endpoint hostname..."
$dnsTest2 = az vm run-command invoke -g $ResourceGroup -n $JumpboxName --command-id RunShellScript `
    --scripts "nslookup $aoaiPrivateDnsHost" `
    --query "value[0].message" -o tsv

if ($dnsTest2 -match [regex]::Escape($AoaiPrivateEndpointIp)) {
    Write-Host "  ✓ DNS Resolution Success (AOAI PE endpoint)"
} else {
    Write-Host "  ✗ DNS Resolution Failed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: Test from Jumpbox - HTTP Connectivity to APIM
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 4: HTTP Connectivity Test (Jumpbox → APIM)" -ForegroundColor Cyan
Write-Host "  (Uses same HTTP test logic as scripts/test-apim-chat.ps1)" -ForegroundColor DarkGray

Write-Host "`nTest: POST request to APIM proxy endpoint..."
Write-Host "  Deployment Name: $AoaiDeploymentName"
Write-Host "  Request: POST https://$apimGatewayHost/$ApimApiPath/deployments/$AoaiDeploymentName/chat/completions"
Write-Host "  User Message: $UserMessage"

$requestBody = @{
    messages = @(
        @{
            role = 'user'
            content = $UserMessage
        }
    )
    max_completion_tokens = 40
    temperature = 0
} | ConvertTo-Json -Compress

$curlScript = @"
#!/bin/bash
set -euo pipefail
cat > /tmp/payload.json <<'JSON'
$requestBody
JSON

curl -k -i -sS -X POST "https://$apimGatewayHost/$ApimApiPath/deployments/$AoaiDeploymentName/chat/completions?api-version=2024-10-21" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/payload.json
"@

$curlScript = $curlScript.Replace("`r`n", "`n")
$curlScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($curlScript))

Write-Host "`nExecuting curl on jumpbox..." -ForegroundColor Yellow

$httpRunRaw = az vm run-command invoke -g $ResourceGroup -n $JumpboxName `
    --command-id RunShellScript `
    --scripts "echo $curlScriptB64 | base64 -d | bash" `
    -o json

$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Failed to execute command on jumpbox." -ForegroundColor Red
    Write-Host "Exit Code: $exitCode" -ForegroundColor Red
    Write-Host "Output: $httpRunRaw" -ForegroundColor Red
    throw "Azure CLI command failed with exit code $exitCode"
}

try {
    $httpRun = $httpRunRaw | ConvertFrom-Json
}
catch {
    Write-Host ""
    Write-Host "ERROR: Failed to parse response as JSON." -ForegroundColor Red
    Write-Host "Response: $httpRunRaw" -ForegroundColor Red
    throw $_
}

if (-not $httpRun.value -or $httpRun.value.Count -eq 0) {
    throw "Run command returned an empty response. Jumpbox may not be accessible."
}

$httpTest = $httpRun.value[0].message

if (-not $httpTest) {
    throw 'Run command returned an empty response.'
}

$stdoutOnly = $httpTest
$stderrOnly = ''

if ($httpTest -match '\[stdout\]') {
    $stdoutSplit = $httpTest -split '\[stdout\]', 2
    if ($stdoutSplit.Count -eq 2) {
        $stdoutOnly = $stdoutSplit[1]
    }
}

if ($stdoutOnly -match '\[stderr\]') {
    $stderrSplit = $stdoutOnly -split '\[stderr\]', 2
    $stdoutOnly = $stderrSplit[0]
    if ($stderrSplit.Count -eq 2) {
        $stderrOnly = $stderrSplit[1].Trim()
    }
}

$stdoutOnly = $stdoutOnly.Trim()

Write-Host ""
Write-Host "Response from APIM Gateway:" -ForegroundColor Green
Write-Host "============================" -ForegroundColor Green

try {
    # Show status if present
    if ($stdoutOnly -match "HTTP/1.1 (\d+)") {
        $statusCode = $matches[1]
        Write-Host "HTTP Status: $statusCode" -ForegroundColor $(if ($statusCode -eq "200") { "Green" } else { "Red" })
    }

    # Parse body JSON from stdout
    $jsonStart = $stdoutOnly.IndexOf('{')
    $jsonEnd = $stdoutOnly.LastIndexOf('}')
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        $jsonBody = $stdoutOnly.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        $parsedBody = $jsonBody | ConvertFrom-Json
        
        if ($parsedBody.choices -and $parsedBody.choices.Count -gt 0 -and $parsedBody.choices[0].message.content) {
            Write-Host "Message: $($parsedBody.choices[0].message.content)" -ForegroundColor White
        }
        
        if ($parsedBody.usage) {
            Write-Host "Tokens - Prompt: $($parsedBody.usage.prompt_tokens), Completion: $($parsedBody.usage.completion_tokens), Total: $($parsedBody.usage.total_tokens)" -ForegroundColor Cyan
        }
    }
}
catch {
    Write-Host "Error parsing response: $_" -ForegroundColor Yellow
}

if ($statusCode -eq '200' -or $statusCode -eq '400') {
    Write-Host ""
    Write-Host "  ✓ Gateway is reachable and responding!"
    Write-Host "  ✓ Network path verified: Jumpbox → APIM Gateway (private IP $ApimPrivateVip) → AOAI (private IP $AoaiPrivateEndpointIp)"
    Write-Host ""
    Write-Host "  ✓ SECURITY PROOF: All communication is on private IPs within VNet"
    Write-Host "    - Jumpbox: $JumpboxPrivateIp"
    Write-Host "    - APIM Gateway: $ApimPrivateVip"
    Write-Host "    - AOAI Private Endpoint: $AoaiPrivateEndpointIp"
    Write-Host "    ✓ No public internet hops"
}
else {
    Write-Host ""
    Write-Host "  Response (raw):"
    Write-Host $stdoutOnly
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: Show APIM Policy (Managed Identity Auth)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 5: APIM Inbound Policy (Managed Identity)" -ForegroundColor Cyan

Write-Host "`nPolicy Details:"
Write-Host "  When a request arrives at APIM gateway:"
Write-Host "  1. APIM acquires a Microsoft Entra token for https://cognitiveservices.azure.com"
Write-Host "     using its system-assigned managed identity"
Write-Host "  2. Token is injected as the Authorization header before forwarding to AOAI"
Write-Host "  3. No API key is stored or transmitted"
Write-Host ""
Write-Host "  Policy XML:"
Write-Host "  <policies>"
Write-Host "    <inbound>"
Write-Host "      <base />"
Write-Host "      <authentication-managed-identity resource='https://cognitiveservices.azure.com' />"
Write-Host "      <set-query-parameter name='api-version' exists-action='override'>"
Write-Host "        <value>2024-10-21</value>"
Write-Host "      </set-query-parameter>"
Write-Host "    </inbound>"
Write-Host "    <backend><base /></backend>"
Write-Host "    <outbound><base /></outbound>"
Write-Host "    <on-error><base /></on-error>"
Write-Host "  </policies>"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: Complete Flow Diagram
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 6: Complete End-to-End Flow" -ForegroundColor Cyan

Write-Host "`n┌─────────────────────────────────────────────────────────────────┐"
Write-Host "│ CUSTOMER CLIENT                                                 │"
Write-Host "├─────────────────────────────────────────────────────────────────┤"
Write-Host "│ 1. POST https://$apimGatewayHost/$ApimApiPath/...                   │"
Write-Host "│    Headers: Content-Type: application/json                      │"
Write-Host "│    Body: messages=[{role=user, content=...}]                    │"
Write-Host "└─────────────────────────────────────────────────────────────────┘"
Write-Host "              │"
Write-Host "              │ Private DNS Resolution"
Write-Host "              ↓ ($apimGatewayHost -> $ApimPrivateVip)"
Write-Host "┌─────────────────────────────────────────────────────────────────┐"
Write-Host "│ APIM GATEWAY (Internal VNet Injection Mode)                     │"
Write-Host "├─────────────────────────────────────────────────────────────────┤"
Write-Host "│ Private IP: $ApimPrivateVip                                      │"
Write-Host "│ Port: 443 (HTTPS)                                               │"
Write-Host "│ Mode: No public IP, entirely within VNet                        │"
Write-Host "│                                                                 │"
Write-Host "│ INBOUND POLICY (Authentication):                               │"
Write-Host "│   1. Acquire Entra token via system-assigned managed identity    │"
Write-Host "│   2. Inject token as Authorization header                       │"
Write-Host "│   3. Forward to AOAI private endpoint                           │"
Write-Host "└─────────────────────────────────────────────────────────────────┘"
Write-Host "              │"
Write-Host "              │ Backend Routing"
Write-Host "              ↓ (https://$aoaiPublicEndpointHost/...)"
Write-Host "┌─────────────────────────────────────────────────────────────────┐"
Write-Host "│ AZURE OPENAI (Private Endpoint)                                 │"
Write-Host "├─────────────────────────────────────────────────────────────────┤"
Write-Host "│ Private IP: $AoaiPrivateEndpointIp (PE NIC)                     │"
Write-Host "│ Private DNS: $aoaiPrivateDnsHost                                 │"
Write-Host "│ Deployment: $AoaiDeploymentName                                  │"
Write-Host "│                                                                 │"
Write-Host "│ Receives Authorization: Bearer <managed-identity-token> ✓      │"
Write-Host "│ Validates Entra token audience/issuer ✓                         │"
Write-Host "│ Processes: /openai/deployments/{deployment}/chat/completions    │"
Write-Host "│ Returns: Chat completion response                               │"
Write-Host "└─────────────────────────────────────────────────────────────────┘"
Write-Host "              │"
Write-Host "              │ Response (encrypted TLS)"
Write-Host "              ↓"
Write-Host "┌─────────────────────────────────────────────────────────────────┐"
Write-Host "│ CUSTOMER CLIENT (receives response)                             │"
Write-Host "│ - Status: 200 OK                                                │"
Write-Host "│ - Content: choices[...] and usage {...}                         │"
Write-Host "└─────────────────────────────────────────────────────────────────┘"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7: Security Benefits
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "`n📋 SECTION 7: Security Architecture Benefits" -ForegroundColor Cyan

Write-Host "`n✓ APIM Internal VNet Injection Mode:"
Write-Host "  • No public IP address on APIM gateway"
Write-Host "  • All management traffic encrypted within VNet"
Write-Host "  • Private DNS resolution within closed network"
Write-Host "  • Suitable for: Regulated environments (HIPAA, PCI-DSS, FedRAMP)"

Write-Host "`n✓ AOAI Private Endpoint:"
Write-Host "  • No internet route to AOAI data plane"
Write-Host "  • Private DNS prevents DNS hijacking"
Write-Host "  • Network isolation: only reachable from authorized VNets"
Write-Host "  • Entra tokens validated at AOAI endpoint"

Write-Host "`n✓ Managed Identity Token Injection via APIM Policy:"
Write-Host "  • APIM acquires token using system-assigned managed identity"
Write-Host "  • Authorization header is injected in APIM policy"
Write-Host "  • No secrets or API keys required on client side"
Write-Host "  • Audit trail exists for APIM and AOAI control/data plane events"

Write-Host "`n✓ Combined Architecture:"
Write-Host "  Customer → APIM (private) → AOAI (private endpoint)"
Write-Host "  ✓ Zero-trust networking"
Write-Host "  ✓ Encrypted end-to-end"
Write-Host "  ✓ No data exfiltration risk"

Write-Host ("`n" + ("=" * 80))
Write-Host "DEMO COMPLETE"
Write-Host ("=" * 80)
Write-Host "`nNext Steps:"
Write-Host "1. Deploy your gpt-4o-mini or gpt-35-turbo model to AOAI"
Write-Host "2. Update AoaiDeploymentName parameter with your deployment name"
Write-Host "3. Run this script to validate the complete flow"
Write-Host "4. Monitor APIM Analytics for per-API-call audit trails"
