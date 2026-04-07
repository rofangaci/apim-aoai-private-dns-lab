# APIM to Azure OpenAI (Private) Lab

## Purpose
Demonstrate networking and DNS design for Azure API Management (APIM) private access patterns to Azure OpenAI (AOAI), and validate end-to-end request flow over private paths.

## DNS and networking focus
This lab compares DNS behavior for both APIM connectivity modes:

1. APIM internal VNet mode
- APIM gateway is reachable only from inside the VNet (or connected networks).
- Clients resolve APIM hostnames through private DNS context linked to the VNet.
- Default APIM internal hostname resolution is handled with the `azure-api.net` private DNS zone in this lab setup.

2. APIM private endpoint mode
- Clients access APIM through a private endpoint NIC/IP.
- Name resolution uses `privatelink.azure-api.net` so APIM gateway FQDN resolves to the private endpoint IP.
- DNS zone link and A-record mapping are required for successful private routing.

AOAI private endpoint resolution:
- APIM backend resolution to AOAI uses `privatelink.openai.azure.com` so AOAI endpoint names resolve to private IPs.
- This keeps APIM-to-AOAI traffic on private networking.

## What this repo contains
- Infrastructure as code for the network and APIM lab deployment
- APIM policy and deployment payload samples
- Validation and operation test scripts
- End-to-end demo scripts for APIM to AOAI flow

## Deployment code
- `infra/apim-network-lab.bicep`
- `deploy.json`
- `deploy-body.json`
- `apim-policy.json`
- `apim-op-policy.json`
- `scripts/dns-records-setup.ps1`
- `scripts/demo-apim-to-aoai-flow.ps1`
- `test-apim-operations.ps1`

## Lab result
The lab validated DNS and private routing for both APIM modes (internal VNet and private endpoint) and demonstrated successful APIM-to-AOAI request flow with APIM operating as the controlled private gateway.
