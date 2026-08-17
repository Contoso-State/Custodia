<#
.SYNOPSIS
    Creates the Custodia custom connector in a Power Platform environment, fully configured
    for on-behalf-of (OBO) delegated auth against Microsoft Graph.

.DESCRIPTION
    Automates the "custom connector" step that would otherwise be done by hand in the maker
    portal's Security tab. Uses paconn (the Power Platform custom-connector CLI documented at
    https://learn.microsoft.com/connectors/custom-connectors/paconn-cli) to create a connector
    from:

      - connector/apiDefinition.swagger.json  (the 25 allowed eDiscovery operations)
      - connector/apiProperties.json          (OAuth 2.0 / Microsoft Entra ID / OBO settings)
      - agent/brand/custodia-avatar.png       (connector icon)

    The generated apiProperties.json matches exactly what the portal's Security tab would
    produce for "OAuth 2.0, identity provider Microsoft Entra ID, Enable on-behalf-of login =
    true" — including "IsOnbehalfofLoginSupported": true and the fixed redirect URL
    https://global.consent.azure-apim.net/redirect that scripts/1-setup-app-registration.ps1
    already registered on the app. There is nothing to copy back and forth between the two
    portals.

    Requires Python 3.8+ (to install and run paconn) and a Power Platform environment you
    are a maker in. Installs paconn with pip if it is not already present.

.PARAMETER EnvironmentId
    The Power Platform environment GUID to create the connector in. Find it in
    https://make.powerapps.com under Settings > Session details, or via
    `pac org who` if you have the Power Platform CLI.

.PARAMETER TenantId
    Your Entra tenant ID. Defaults to the value recorded by
    scripts/1-setup-app-registration.ps1 in custodia-app.local.json.

.PARAMETER ClientId
    The app registration's client (application) ID. Defaults to the value recorded in
    custodia-app.local.json.

.PARAMETER ClientSecret
    The app registration's client secret. Not stored anywhere by this script or by
    scripts/1-setup-app-registration.ps1 — you must supply it (paste it, or pipe it in).

.PARAMETER ConnectorName
    Display name for the custom connector.

.EXAMPLE
    ./3-create-custom-connector.ps1 -EnvironmentId '<ENVIRONMENT-GUID>' -ClientSecret $secret
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $EnvironmentId,
    [string]                       $TenantId,
    [string]                       $ClientId,
    [Security.SecureString]        $ClientSecret,
    [string]                       $ConnectorName = 'Custodia eDiscovery'
)

$ErrorActionPreference = 'Stop'

$repoRoot        = Resolve-Path (Join-Path $PSScriptRoot '..')
$swaggerPath     = Join-Path $repoRoot 'connector\apiDefinition.swagger.json'
$propsTemplate   = Join-Path $repoRoot 'connector\apiProperties.json'
$iconPath        = Join-Path $repoRoot 'agent\brand\custodia-avatar.png'
$localConfigPath = Join-Path $repoRoot 'custodia-app.local.json'

foreach ($required in @($swaggerPath, $propsTemplate)) {
    if (-not (Test-Path $required)) { throw "Required file not found: $required" }
}

# --- Fill in TenantId / ClientId from custodia-app.local.json if not passed --------------
if ((-not $TenantId -or -not $ClientId) -and (Test-Path $localConfigPath)) {
    $local = Get-Content $localConfigPath -Raw | ConvertFrom-Json
    if (-not $TenantId) { $TenantId = $local.tenantId }
    if (-not $ClientId) { $ClientId = $local.clientId }
}

if (-not $TenantId -or -not $ClientId) {
    throw 'TenantId and ClientId are required. Run scripts/1-setup-app-registration.ps1 first, or pass them explicitly.'
}

if (-not $ClientSecret) {
    $ClientSecret = Read-Host -AsSecureString -Prompt 'Client secret for the Custodia app registration'
}
$plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
)
if ([string]::IsNullOrWhiteSpace($plainSecret)) {
    throw 'A client secret is required to create the connector.'
}

# --- Ensure paconn is available -----------------------------------------------------------
function Assert-Paconn {
    if (Get-Command paconn -ErrorAction SilentlyContinue) { return }

    if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
        -not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw @'
Python was not found on PATH, and paconn (the Power Platform connector CLI) needs it.

Install Python, then re-run this script:
  winget install -e --id Python.Python.3.12

If you just installed it, close and reopen this terminal window first.
'@
    }

    Write-Host 'Installing paconn (Power Platform custom connector CLI) ...' -ForegroundColor Cyan
    & pip install --user --quiet paconn
    if ($LASTEXITCODE -ne 0) {
        throw 'pip install paconn failed. See https://learn.microsoft.com/connectors/custom-connectors/paconn-cli for manual install steps.'
    }

    if (-not (Get-Command paconn -ErrorAction SilentlyContinue)) {
        throw 'paconn installed but is not on PATH yet. Close and reopen this terminal window, then re-run this script.'
    }
}

Assert-Paconn

# --- Build a temp apiProperties.json with the real client ID / tenant ID substituted ------
$propsJson = Get-Content $propsTemplate -Raw
$propsJson = $propsJson.Replace('<APP-ID>', $ClientId).Replace('<TENANT-ID>', $TenantId)

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "custodia-connector-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null
$tempPropsPath = Join-Path $tempDir 'apiProperties.json'
Set-Content -Path $tempPropsPath -Value $propsJson -Encoding utf8

try {
    Write-Host ''
    Write-Host "Signing in to Power Platform (a browser or device-code prompt will appear) ..." -ForegroundColor Cyan
    & paconn login
    if ($LASTEXITCODE -ne 0) { throw 'paconn login failed.' }

    Write-Host ''
    Write-Host "Creating connector '$ConnectorName' in environment $EnvironmentId ..." -ForegroundColor Cyan

    $createArgs = @(
        'create',
        '--env', $EnvironmentId,
        '--api-def', $swaggerPath,
        '--api-prop', $tempPropsPath,
        '--secret', $plainSecret
    )
    if (Test-Path $iconPath) { $createArgs += @('--icon', $iconPath) }

    $output = & paconn @createArgs 2>&1
    $output | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        throw "paconn create failed. Full output above. You can still create the connector by hand — see README.md 'Custom connector' section."
    }

    # paconn prints the new connector ID; capture it for the local record.
    $connectorId = ($output | Select-String -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
        Select-Object -First 1).Matches.Value
}
finally {
    # Never leave the plaintext secret or the filled-in tenant/client IDs sitting on disk.
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    Remove-Variable plainSecret -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Green
Write-Host ' Custom connector created' -ForegroundColor Green
Write-Host '=========================================================' -ForegroundColor Green
Write-Host "Environment ID: $EnvironmentId"
if ($connectorId) { Write-Host "Connector ID:   $connectorId" }
Write-Host ''
Write-Host 'Next: create the Custodia agent in Copilot Studio, add this connector as an' -ForegroundColor Cyan
Write-Host 'action, and make sure each user authenticates with their OWN credentials (do not' -ForegroundColor Cyan
Write-Host 'use maker-provided credentials) — see README.md "3. Copilot Studio agent".' -ForegroundColor Cyan

if (Test-Path $localConfigPath) {
    $local = Get-Content $localConfigPath -Raw | ConvertFrom-Json
    $local | Add-Member -NotePropertyName environmentId -NotePropertyValue $EnvironmentId -Force
    if ($connectorId) {
        $local | Add-Member -NotePropertyName connectorId -NotePropertyValue $connectorId -Force
    }
    $local | ConvertTo-Json -Depth 5 | Set-Content -Path $localConfigPath -Encoding utf8
}

return [pscustomobject]@{
    EnvironmentId = $EnvironmentId
    ConnectorId   = $connectorId
}
