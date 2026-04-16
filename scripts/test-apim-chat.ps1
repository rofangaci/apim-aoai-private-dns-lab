#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Test APIM chat completions from the jumpbox with proper escaping handling.

.DESCRIPTION
    Sends a chat completion request to APIM from the jumpbox VM using Azure VM Run Command.
    Handles all shell escaping automatically via base64 encoding.

.EXAMPLE
    .\test-apim-chat.ps1 -ResourceGroup rg-apim-netlab-eus2-01 -ApimHost apimintlab14452.azure-api.net -Message "Hello, how are you?"

.EXAMPLE
    .\test-apim-chat.ps1 -ResourceGroup rg-apim-netlab-eus2-01 -ApimHost apimintlab14452.azure-api.net -Message "reply with exactly: APIM_PRIVATE_PATH_OK"
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApimHost,

    [string]$Message,

    [string]$JumpboxName = 'vm-jumpbox',
    [string]$Deployment = 'gpt4o-demo',
    [string]$ApiVersion = '2024-10-21',
    [int]$MaxTokens = 100,
    [decimal]$Temperature = 0,
    [switch]$ShowRawResponse
)

$ErrorActionPreference = 'Stop'

# Avoid Azure CLI cp1252 encoding warnings when model text contains Unicode.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if (-not $Message) {
    $Message = Read-Host 'Enter message to send to AOAI through APIM'
}

if (-not $Message) {
    throw 'Message cannot be empty. Provide -Message or enter a value when prompted.'
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

Write-Host "Testing APIM chat completion from jumpbox..." -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroup"
Write-Host "  Jumpbox: $JumpboxName"
Write-Host "  APIM Host: $ApimHost"
Write-Host "  Message: $Message"
Write-Host ""

# Build a JSON payload in PowerShell to avoid shell escaping issues.
$payload = @{
    messages = @(
        @{
            role = 'user'
            content = $Message
        }
    )
    max_completion_tokens = $MaxTokens
    temperature = [double]$Temperature
} | ConvertTo-Json -Compress

# Create bash script that will run on the jumpbox.
$bashScript = @"
#!/bin/bash
set -euo pipefail
APIM_HOST="$ApimHost"
DEPLOYMENT="$Deployment"
API_VERSION="$ApiVersion"

cat > /tmp/apim-chat-payload.json <<'JSON'
$payload
JSON

curl -k -i -sS -X POST "https://$`{APIM_HOST`}/aoai4o/deployments/$`{DEPLOYMENT`}/chat/completions?api-version=$`{API_VERSION`}" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/apim-chat-payload.json
"@

# Ensure proper line endings for Linux
$bashScript = $bashScript.Replace("`r`n", "`n")

# Encode to base64 to avoid shell escaping issues
$bytes = [System.Text.Encoding]::UTF8.GetBytes($bashScript)
$b64 = [Convert]::ToBase64String($bytes)

# Execute on jumpbox
Write-Host "Executing curl on jumpbox..." -ForegroundColor Yellow

$runCommandRaw = az vm run-command invoke `
    -g $ResourceGroup `
    -n $JumpboxName `
    --command-id RunShellScript `
    --scripts "echo $b64 | base64 -d | bash" `
    -o json

$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Failed to execute command on jumpbox." -ForegroundColor Red
    Write-Host "Exit Code: $exitCode" -ForegroundColor Red
    Write-Host "Output: $runCommandRaw" -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  - Jumpbox name is incorrect (expected: '$JumpboxName')" -ForegroundColor Yellow
    Write-Host "  - Jumpbox is not running or not accessible" -ForegroundColor Yellow
    Write-Host "  - Resource group name is incorrect" -ForegroundColor Yellow
    throw "Azure CLI command failed with exit code $exitCode"
}

try {
    $runCommand = $runCommandRaw | ConvertFrom-Json
}
catch {
    Write-Host ""
    Write-Host "ERROR: Failed to parse response as JSON." -ForegroundColor Red
    Write-Host "Response: $runCommandRaw" -ForegroundColor Red
    throw $_
}

if (-not $runCommand.value -or $runCommand.value.Count -eq 0) {
    throw "Run command returned an empty response. Jumpbox may not be accessible."
}

$result = $runCommand.value[0].message

if (-not $result) {
    throw 'Run command returned an empty response.'
}

$stdoutOnly = $result
$stderrOnly = ''

if ($result -match '\[stdout\]') {
    $stdoutSplit = $result -split '\[stdout\]', 2
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
Write-Host "Response from APIM:" -ForegroundColor Green
Write-Host "===================" -ForegroundColor Green

try {
    # Show status if present.
    if ($stdoutOnly -match "HTTP/1.1 (\d+)") {
        $statusCode = $matches[1]
        Write-Host "HTTP Status: $statusCode" -ForegroundColor $(if ($statusCode -eq "200") { "Green" } else { "Red" })
    }

    # Parse body JSON from stdout.
    $jsonStart = $stdoutOnly.IndexOf('{')
    $jsonEnd = $stdoutOnly.LastIndexOf('}')
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        $jsonBody = $stdoutOnly.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        $parsed = $jsonBody | ConvertFrom-Json
        
        if ($parsed.choices -and $parsed.choices.Count -gt 0 -and $parsed.choices[0].message.content) {
            Write-Host "Message: $($parsed.choices[0].message.content)" -ForegroundColor White
        }
        
        if ($parsed.usage) {
            Write-Host "Tokens - Prompt: $($parsed.usage.prompt_tokens), Completion: $($parsed.usage.completion_tokens), Total: $($parsed.usage.total_tokens)" -ForegroundColor Cyan
        }
    }
}
catch {
    Write-Host "Error parsing response: $_" -ForegroundColor Yellow
}

if ($ShowRawResponse) {
    Write-Host ""
    Write-Host "─ Raw Response ─" -ForegroundColor DarkGray
    
    # Extract HTTP headers and body
    $blankLineIdx = $stdoutOnly.IndexOf("`n`n")
    if ($blankLineIdx -eq -1) { $blankLineIdx = $stdoutOnly.IndexOf("`r`n`r`n") }
    
    if ($blankLineIdx -gt 0) {
        $headers = $stdoutOnly.Substring(0, $blankLineIdx)
        $body = $stdoutOnly.Substring($blankLineIdx).Trim()
        
        # Show headers
        Write-Host ""
        Write-Host "HTTP Headers:" -ForegroundColor Magenta
        Write-Host $headers -ForegroundColor DarkGray
        
        # Show body with pretty-printed JSON
        Write-Host ""
        Write-Host "Response Body (JSON):" -ForegroundColor Magenta
        try {
            $parsedJson = $body | ConvertFrom-Json
            $prettyJson = $parsedJson | ConvertTo-Json -Depth 10
            Write-Host $prettyJson -ForegroundColor DarkGray
        }
        catch {
            Write-Host $body -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host $stdoutOnly -ForegroundColor DarkGray
    }
}

if ($stderrOnly) {
    Write-Host ""
    Write-Host "stderr:" -ForegroundColor Yellow
    Write-Host $stderrOnly -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Test completed." -ForegroundColor Green

if ($stdoutOnly -notmatch 'HTTP/1.1 200') {
    exit 1
}
