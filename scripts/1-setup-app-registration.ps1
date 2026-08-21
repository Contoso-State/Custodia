<#
.SYNOPSIS
    One-time setup of the Entra app registration that backs the Custodia Copilot Studio
    custom connector.

.DESCRIPTION
    Creates a single-tenant Entra application configured for on-behalf-of (OBO) delegated
    access to the Microsoft Graph eDiscovery API, then:

      1. Adds DELEGATED Microsoft Graph permissions: eDiscovery.ReadWrite.All and User.Read.
      2. Grants tenant-wide admin consent for those delegated permissions.
      3. Exposes an API with an 'access_as_user' scope consentable by admins and users.
      4. Pre-authorizes the Azure API Connections service principal
         (fe053c5f-3692-4f14-aef2-ee34fc081cae) for that scope, which is what lets the
         Power Platform custom connector perform OBO.
      5. Registers the well-known Power Platform OAuth redirect URI
         (https://global.consent.azure-apim.net/redirect) so nobody has to copy a
         connector-generated redirect URL back into this app registration by hand.
      6. Creates a client secret and prints it once.

    No application (app-only) permissions are requested. The agent must never be able to
    exceed the signed-in reviewer's own Purview eDiscovery role.

    Requires the Azure CLI and an account with permission to create app registrations and
    grant admin consent (Application Administrator / Cloud Application Administrator, plus
    Privileged Role Administrator or Global Administrator for consent).

    Safe to re-run: if custodia-app.local.json already records a completed setup, the script
    reports the existing values and makes no changes unless -Force is passed.

.PARAMETER DisplayName
    Display name for the app registration.

.PARAMETER TenantId
    The tenant to create the app in. Use your own tenant ID; the default is a placeholder.

.PARAMETER SecretYears
    Lifetime of the generated client secret, in years.

.PARAMETER Force
    Re-run the full setup even if custodia-app.local.json already records a completed run.
    Reuses the existing app registration by display name rather than creating a duplicate.

.PARAMETER RotateSecret
    Only meaningful with -Force. Also issues a brand-new client secret for an existing app.
    Do this only if you are prepared to update the custom connector with the new value.

.EXAMPLE
    ./1-setup-app-registration.ps1 -TenantId '<TENANT-ID>'
#>

[CmdletBinding()]
param(
    [string] $DisplayName = 'Custodia eDiscovery Connector',
    [string] $TenantId    = '<TENANT-ID>',
    [int]    $SecretYears = 1,

    # Re-run even if custodia-app.local.json already records a completed setup. A client
    # secret is NOT rotated unless -RotateSecret is also passed, because that would silently
    # break an already-configured custom connector.
    [switch] $Force,

    # Only meaningful with -Force: also issue a brand-new client secret. Do this only if you
    # are prepared to re-paste the new secret into the custom connector's Security tab (or
    # re-run scripts/3-create-custom-connector.ps1).
    [switch] $RotateSecret
)

$ErrorActionPreference = 'Stop'

$localConfigPath = Join-Path $PSScriptRoot '..' 'custodia-app.local.json'

if ((Test-Path $localConfigPath) -and -not $Force) {
    $existing = Get-Content $localConfigPath -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host 'A Custodia app registration already appears to be set up:' -ForegroundColor Yellow
    Write-Host "  Tenant ID: $($existing.tenantId)"
    Write-Host "  Client ID: $($existing.clientId)"
    Write-Host ''
    Write-Host 'Nothing was changed. Re-run with -Force if you really want to redo this step' -ForegroundColor Yellow
    Write-Host '(the client secret is only rotated if you also pass -RotateSecret).' -ForegroundColor Yellow
    return [pscustomobject]@{
        TenantId     = $existing.tenantId
        ClientId     = $existing.clientId
        ObjectId     = $existing.objectId
        ClientSecret = $null
        AlreadySetUp = $true
    }
}

# --- Well-known identifiers -------------------------------------------------------------
$graphAppId = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph

# Delegated permission (oauth2PermissionScope) IDs on Microsoft Graph.
$scopeIds = @{
    'eDiscovery.ReadWrite.All' = 'acb8f680-0834-4146-b69e-4ab1b39745ad'
    'User.Read'                = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
}

# First-party service principal used by Power Platform / Logic Apps custom connectors.
# Pre-authorizing it on our exposed scope is what enables on-behalf-of login.
$apiConnectionsAppId = 'fe053c5f-3692-4f14-aef2-ee34fc081cae'

function Assert-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw @'
Azure CLI (az) was not found on PATH.

Install it, then re-run this script:
  winget install -e --id Microsoft.AzureCLI
(or see https://aka.ms/installazurecliwindows)

If you just installed it, close and reopen this terminal window first - PATH changes
do not apply to windows that were already open.
'@
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Args)

    $raw = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Args -join ' ') failed:`n$raw"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

Assert-AzCli

if ($TenantId -eq '<TENANT-ID>') {
    throw 'Pass -TenantId with your real tenant ID. The default is a placeholder.'
}

Write-Host "Signing in to tenant $TenantId ..." -ForegroundColor Cyan
& az login --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }

# --- 1. Create (or reuse) the app registration ------------------------------------------
Write-Host "Looking for an existing app registration named '$DisplayName' ..." -ForegroundColor Cyan

$existingApps = Invoke-AzJson @(
    'ad', 'app', 'list',
    '--display-name', $DisplayName,
    '--only-show-errors'
)
$existingApp = @($existingApps) | Select-Object -First 1

$isNewApp = $false
if ($existingApp) {
    $appId    = $existingApp.appId
    $appObjId = $existingApp.id
    Write-Host "  Found existing app. Reusing it (nothing is duplicated)." -ForegroundColor DarkGray
} else {
    Write-Host "Creating app registration '$DisplayName' ..." -ForegroundColor Cyan
    $app = Invoke-AzJson @(
        'ad', 'app', 'create',
        '--display-name', $DisplayName,
        '--sign-in-audience', 'AzureADMyOrg',
        '--only-show-errors'
    )
    $appId    = $app.appId
    $appObjId = $app.id
    $isNewApp = $true
}
Write-Host "  App ID:        $appId"
Write-Host "  Object ID:     $appObjId"

# --- 2. Add DELEGATED Graph permissions -------------------------------------------------
Write-Host 'Adding delegated Microsoft Graph permissions ...' -ForegroundColor Cyan

foreach ($name in $scopeIds.Keys) {
    Write-Host "  + $name (delegated)"
    & az ad app permission add `
        --id $appId `
        --api $graphAppId `
        --api-permissions "$($scopeIds[$name])=Scope" `
        --only-show-errors 2>&1 | Out-Null
}

# The service principal must exist before consent can be granted.
Write-Host 'Ensuring service principal exists ...' -ForegroundColor Cyan
$existingSp = & az ad sp show --id $appId --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existingSp) {
    Invoke-AzJson @('ad', 'sp', 'create', '--id', $appId, '--only-show-errors') | Out-Null
}

Write-Host 'Waiting for directory replication ...' -ForegroundColor DarkGray
Start-Sleep -Seconds 20

# --- 3. Grant admin consent for the delegated scopes ------------------------------------
Write-Host 'Granting tenant-wide admin consent for the delegated scopes ...' -ForegroundColor Cyan

& az ad app permission admin-consent --id $appId --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warning @'
Admin consent could not be granted automatically. Grant it manually:
  Entra admin center > App registrations > (this app) > API permissions
  > "Grant admin consent for <your tenant>".
'@
}

# --- 4. Expose an API with access_as_user, pre-authorized for Azure API Connections ------
Write-Host 'Exposing API scope access_as_user ...' -ForegroundColor Cyan

$scopeGuid = [guid]::NewGuid().ToString()

$apiPayload = @{
    identifierUris = @("api://$appId")
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(
            @{
                id                      = $scopeGuid
                value                   = 'access_as_user'
                type                    = 'User'   # Admins and users
                isEnabled               = $true
                adminConsentDisplayName = 'Access Custodia eDiscovery as the signed-in user'
                adminConsentDescription = 'Allows the connector to call the Microsoft Graph eDiscovery API on behalf of the signed-in reviewer, limited to that reviewer''s own Purview permissions.'
                userConsentDisplayName  = 'Access eDiscovery on your behalf'
                userConsentDescription  = 'Allows Custodia to read and create eDiscovery cases and searches on your behalf. It cannot exceed your own Purview eDiscovery permissions.'
            }
        )
        preAuthorizedApplications = @(
            @{
                appId                 = $apiConnectionsAppId
                delegatedPermissionIds = @($scopeGuid)
            }
        )
    }
}

$apiPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "custodia-api-$([guid]::NewGuid()).json"
$apiPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $apiPayloadPath -Encoding utf8

try {
    & az rest `
        --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$appObjId" `
        --headers 'Content-Type=application/json' `
        --body "@$apiPayloadPath" `
        --only-show-errors 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to configure the exposed API scope. Configure "Expose an API" manually in the portal.'
    }
}
finally {
    Remove-Item $apiPayloadPath -ErrorAction SilentlyContinue
}

Write-Host "  Scope:         api://$appId/access_as_user"
Write-Host "  Pre-authorized: Azure API Connections ($apiConnectionsAppId)"

# --- 5. Register the well-known Power Platform / Copilot Studio OAuth redirect URI -------
# Every AAD-authenticated custom connector on the global Power Platform cloud redirects back
# through this same fixed endpoint. Pre-registering it here means nobody has to copy a
# connector-generated redirect URL back into this app registration by hand.
Write-Host 'Registering the Power Platform OAuth redirect URI ...' -ForegroundColor Cyan

$wellKnownRedirectUri = 'https://global.consent.azure-apim.net/redirect'

$currentApp = Invoke-AzJson @('ad', 'app', 'show', '--id', $appId, '--only-show-errors')
$currentRedirectUris = @()
if ($currentApp.web -and $currentApp.web.redirectUris) {
    $currentRedirectUris = @($currentApp.web.redirectUris)
}

if ($currentRedirectUris -notcontains $wellKnownRedirectUri) {
    $webPayload = @{
        web = @{
            redirectUris = @($currentRedirectUris + $wellKnownRedirectUri)
        }
    }
    $webPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) "custodia-web-$([guid]::NewGuid()).json"
    $webPayload | ConvertTo-Json -Depth 10 | Set-Content -Path $webPayloadPath -Encoding utf8
    try {
        & az rest `
            --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$appObjId" `
            --headers 'Content-Type=application/json' `
            --body "@$webPayloadPath" `
            --only-show-errors 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not add the redirect URI automatically. Add it manually: Authentication > Add a platform > Web > $wellKnownRedirectUri"
        } else {
            Write-Host "  Redirect URI:  $wellKnownRedirectUri"
        }
    }
    finally {
        Remove-Item $webPayloadPath -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  Redirect URI already present: $wellKnownRedirectUri" -ForegroundColor DarkGray
}

# --- 6. Create a client secret -----------------------------------------------------------
$cred = $null
if ($isNewApp -or $RotateSecret) {
    Write-Host 'Creating client secret ...' -ForegroundColor Cyan
    $cred = Invoke-AzJson @(
        'ad', 'app', 'credential', 'reset',
        '--id', $appId,
        '--years', "$SecretYears",
        '--display-name', 'custodia-connector',
        '--only-show-errors'
    )
} else {
    Write-Host ''
    Write-Warning @'
Reusing an existing app registration: no new client secret was created (the old one cannot
be read back, and rotating it would break an already-configured custom connector). If you
still have the original secret, reuse it. Otherwise re-run with -Force -RotateSecret and
update the custom connector's Security tab (or re-run scripts/3-create-custom-connector.ps1)
with the new value.
'@
}

# --- Summary ----------------------------------------------------------------------------
Write-Host ''
Write-Host '=========================================================' -ForegroundColor Green
Write-Host ' Custodia app registration complete' -ForegroundColor Green
Write-Host '=========================================================' -ForegroundColor Green
Write-Host ''
Write-Host "Tenant ID:     $TenantId"
Write-Host "Client ID:     $appId"
if ($cred) {
    Write-Host "Client secret: $($cred.password)"
    Write-Host ''
    Write-Host 'The client secret is shown only once. Store it in a secure secret store now.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host '  1. Run scripts/3-create-custom-connector.ps1 to create the Power Platform custom'
Write-Host '     connector automatically (recommended), or create it by hand from'
Write-Host '     connector/apiDefinition.swagger.json using the Security tab settings below.'
Write-Host '  2. Security tab (only needed if creating the connector by hand):'
Write-Host '       OAuth 2.0, identity provider Microsoft Entra ID.'
Write-Host "       Client ID:            $appId"
Write-Host '       Client secret:        (the value above)'
Write-Host "       Tenant ID:            $TenantId"
Write-Host '       Resource URL:         https://graph.microsoft.com'
Write-Host '       Enable on-behalf-of login: true'
Write-Host '       Scope:                eDiscovery.ReadWrite.All User.Read offline_access'
Write-Host '       (offline_access gets you a refresh token, so a granted tool stays granted'
Write-Host '       instead of re-prompting once its access token expires.)'
Write-Host '     The redirect URI is already registered on this app - nothing to copy back.'
Write-Host ''
Write-Host 'Confirm in the portal that NO application (app-only) Graph permissions are present.' -ForegroundColor Yellow

# Write a local, git-ignored record of the non-secret identifiers for convenience.
$localConfig = [ordered]@{
    tenantId    = $TenantId
    clientId    = $appId
    objectId    = $appObjId
    scope       = "api://$appId/access_as_user"
    graphScopes = @('eDiscovery.ReadWrite.All', 'User.Read')
    createdUtc  = (Get-Date).ToUniversalTime().ToString('o')
}
$localConfig | ConvertTo-Json -Depth 5 |
    Set-Content -Path $localConfigPath -Encoding utf8

Write-Host ''
Write-Host 'Non-secret identifiers written to custodia-app.local.json (git-ignored).' -ForegroundColor DarkGray

# Structured result for scripts/0-install-everything.ps1 to consume. Write-Host output above
# goes to the host stream, not the pipeline, so it does not interfere with this return value.
return [pscustomobject]@{
    TenantId     = $TenantId
    ClientId     = $appId
    ObjectId     = $appObjId
    ClientSecret = $(if ($cred) { $cred.password } else { $null })
    AlreadySetUp = $false
}
