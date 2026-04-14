#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive script to test different APIM Azure OpenAI operations from jumpbox

.DESCRIPTION
    Presents a menu of operations and makes curl calls to the selected operation
    through APIM internal gateway with managed identity authentication

.EXAMPLE
    .\test-apim-operations.ps1
#>

param(
    [Parameter(Mandatory)]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApimName,

    [Parameter(Mandatory)]
    [string]$DeploymentId,

    [Parameter(Mandatory)]
    [string]$VmName,

    [string]$ApiPath = 'aoai4o',

    [string]$ApiVersion = '2024-10-21'
)

$ErrorActionPreference = 'Stop'

# Alias locals to match rest of script
$subscription  = $Subscription
$resourceGroup = $ResourceGroup
$apimName      = $ApimName
$apiPath       = $ApiPath
$deploymentId  = $DeploymentId
$apiVersion    = $ApiVersion
$vmName        = $VmName

# Set subscription
Write-Host "`n[INFO] Setting subscription context..." -ForegroundColor Cyan
az account set --subscription $subscription --only-show-errors | Out-Null

# Operations menu
$operations = @(
    @{
        Index = 1
        Name = "ChatCompletions_Create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/chat/completions"
        Description = "Chat Completions - Text generation"
        Payload = @{
            messages = @(
                @{
                    role = "user"
                    content = "reply with exactly: CHAT_COMPLETIONS_OK"
                }
            )
            max_completion_tokens = 20
            temperature = 0
        }
    }
    @{
        Index = 2
        Name = "Completions_Create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/completions"
        Description = "Completions - Legacy text generation"
        Payload = @{
            prompt = "reply with exactly: COMPLETIONS_OK"
            max_tokens = 20
            temperature = 0
        }
    }
    @{
        Index = 3
        Name = "embeddings_create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/embeddings"
        Description = "Embeddings - Text embeddings (requires text-embedding model)"
        Payload = @{
            input = "test embedding"
        }
    }
    @{
        Index = 4
        Name = "ImageGenerations_Create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/images/generations"
        Description = "Image Generations - DALL-E image generation (requires DALL-E deployment)"
        Payload = @{
            prompt = "a test image"
            n = 1
            size = "256x256"
        }
    }
    @{
        Index = 5
        Name = "Transcriptions_Create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/audio/transcriptions"
        Description = "Transcriptions - Speech to text (requires audio file)"
        Payload = @{
            model = "whisper-1"
        }
    }
    @{
        Index = 6
        Name = "Translations_Create"
        Method = "POST"
        Path = "/deployments/{deployment-id}/audio/translations"
        Description = "Translations - Audio translation (requires audio file)"
        Payload = @{
            model = "whisper-1"
        }
    }
)

# Display menu
Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║       Available APIM Azure OpenAI Operations                 ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

foreach ($op in $operations) {
    Write-Host "`n[$($op.Index)] $($op.Name)" -ForegroundColor Yellow
    Write-Host "    $($op.Description)"
    Write-Host "    Method: $($op.Method)  Path: $($op.Path)"
}

Write-Host "`n[0] Exit" -ForegroundColor Yellow

# Get user selection
$selection = Read-Host "`nSelect operation (0-6)"

if ($selection -eq "0") {
    Write-Host "Exiting..." -ForegroundColor Green
    exit 0
}

$selectedOp = $operations | Where-Object { $_.Index -eq [int]$selection }
if (-not $selectedOp) {
    Write-Host "Invalid selection" -ForegroundColor Red
    exit 1
}

# Build URL
$url = "https://$apimName.azure-api.net/$apiPath$($selectedOp.Path)?api-version=$apiVersion"
$url = $url -replace '{deployment-id}', $deploymentId

Write-Host "`n╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║ Executing Test Request" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`nOperation: $($selectedOp.Name)" -ForegroundColor Green
Write-Host "URL: $url" -ForegroundColor Green
Write-Host "Method: $($selectedOp.Method)" -ForegroundColor Green

# Convert payload to JSON
$payloadJson = $selectedOp.Payload | ConvertTo-Json -Compress

Write-Host "`nPayload:`n$payloadJson`n" -ForegroundColor White

# Create script for jumpbox
$jumpboxScript = @"
cat > /tmp/payload.json <<'PAYLOAD'
$payloadJson
PAYLOAD

echo '=== Making API Call ==='
curl -k -sS -o /tmp/resp.json -w 'HTTP_CODE:%{http_code}\n' -X $($selectedOp.Method) '$url' \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/payload.json

echo ''
echo '=== Response ==='
cat /tmp/resp.json
"@

# Execute on jumpbox
Write-Host "Executing on jumpbox ($vmName)..." -ForegroundColor Cyan

$result = az vm run-command invoke `
    -g $resourceGroup `
    -n $vmName `
    --command-id RunShellScript `
    --scripts $jumpboxScript `
    --query 'value[0].message' `
    -o tsv 2>&1

Write-Host $result -ForegroundColor White

Write-Host "`n[SUCCESS] Request completed`n" -ForegroundColor Green
