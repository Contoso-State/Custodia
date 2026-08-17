<#
.SYNOPSIS
    Checks that the automated Custodia setup actually worked, in plain language.

.DESCRIPTION
    Run this after scripts/1-setup-app-registration.ps1 (and, if you used it,
    scripts/3-create-custom-connector.ps1) to get a simple PASS / WARN / FAIL checklist
    instead of having to dig through the Entra and Power Platform portals by hand.

    This script only reads state — it never creates, changes, or deletes anything.

.EXAMPLE
    ./4-test-setup.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$repoRoot        = Resolve-Path (Join-Path $PSScriptRoot '..')
$localConfigPath = Join-Path $repoRoot 'custodia-app.local.json'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string] $Check, [ValidateSet('PASS', 'WARN', 'FAIL')][string] $Status, [string] $Detail)
    $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
}

Write-Host ''
Write-Host 'Checking your Custodia setup ...' -ForegroundColor Cyan
Write-Host ''

# --- 1. Local config file -----------------------------------------------------------------
if (-not (Test-Path $localConfigPath)) {
    Add-Result 'App registration recorded locally' 'FAIL' 'custodia-app.local.json not found. Run scripts/1-setup-app-registration.ps1 first.'
    $results | Format-Table -AutoSize
    return
}

$local = Get-Content $localConfigPath -Raw | ConvertFrom-Json
Add-Result 'App registration recorded locally' 'PASS' "Tenant $($local.tenantId), client $($local.clientId)"

# --- 2. Azure CLI + sign-in ----------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Add-Result 'Azure CLI available' 'FAIL' 'Install it: winget install -e --id Microsoft.AzureCLI'
    $results | Format-Table -AutoSize
    return
}
Add-Result 'Azure CLI available' 'PASS' ''

$account = & az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $account) {
    Add-Result 'Signed in to Azure' 'FAIL' "Run: az login --tenant $($local.tenantId)"
    $results | Format-Table -AutoSize
    return
}
Add-Result 'Signed in to Azure' 'PASS' "As $($account.user.name)"

# --- 3. App registration still exists -------------------------------------------------------
$app = & az ad app show --id $local.clientId --only-show-errors 2>$null | ConvertFrom-Json
if (-not $app) {
    Add-Result 'App registration exists' 'FAIL' "Client ID $($local.clientId) was not found in this tenant."
} else {
    Add-Result 'App registration exists' 'PASS' $app.displayName
}

# --- 4. Delegated Graph permissions requested (not application/app-only) -------------------
if ($app) {
    $graphResource = @($app.requiredResourceAccess) | Where-Object { $_.resourceAppId -eq '00000003-0000-0000-c000-000000000000' }
    $delegated = @($graphResource.resourceAccess) | Where-Object { $_.type -eq 'Scope' }
    $appOnly   = @($graphResource.resourceAccess) | Where-Object { $_.type -eq 'Role' }

    $wantedScopeIds = @('acb8f680-0834-4146-b69e-4ab1b39745ad', 'e1fe6dd8-ba31-4d61-89e7-88639da4683d')
    $haveScopeIds   = @($delegated.id)
    $missing        = @($wantedScopeIds | Where-Object { $_ -notin $haveScopeIds })

    if ($missing.Count -eq 0) {
        Add-Result 'Delegated Graph permissions present' 'PASS' 'eDiscovery.ReadWrite.All + User.Read'
    } else {
        Add-Result 'Delegated Graph permissions present' 'FAIL' "Missing $($missing.Count) expected scope(s). Re-run scripts/1-setup-app-registration.ps1 -Force."
    }

    if ($appOnly.Count -gt 0) {
        Add-Result 'No application (app-only) permissions' 'FAIL' "$($appOnly.Count) app-only permission(s) found — remove them. This breaks the delegated-only safety guarantee."
    } else {
        Add-Result 'No application (app-only) permissions' 'PASS' ''
    }
}

# --- 5. Admin consent granted ---------------------------------------------------------------
$sp = & az ad sp show --id $local.clientId --only-show-errors 2>$null | ConvertFrom-Json
if ($sp) {
    $grants = & az ad app permission list-grants --id $local.clientId --only-show-errors 2>$null | ConvertFrom-Json
    $graphGrant = @($grants) | Where-Object { $_.resourceId -eq $sp.appId -or $_.consentType } | Select-Object -First 1
    if ($graphGrant -and $graphGrant.scope -match 'eDiscovery') {
        Add-Result 'Tenant-wide admin consent granted' 'PASS' $graphGrant.scope
    } else {
        Add-Result 'Tenant-wide admin consent granted' 'WARN' 'Could not confirm from list-grants. Verify in Entra admin center > API permissions.'
    }
} else {
    Add-Result 'Tenant-wide admin consent granted' 'WARN' 'Service principal not found; cannot check consent.'
}

# --- 6. Exposed API scope + redirect URI ----------------------------------------------------
if ($app) {
    $hasScope = @($app.api.oauth2PermissionScopes) | Where-Object { $_.value -eq 'access_as_user' }
    if ($hasScope) {
        Add-Result 'Exposed API scope access_as_user' 'PASS' ''
    } else {
        Add-Result 'Exposed API scope access_as_user' 'FAIL' 'Not found. Re-run scripts/1-setup-app-registration.ps1 -Force.'
    }

    $hasRedirect = @($app.web.redirectUris) -contains 'https://global.consent.azure-apim.net/redirect'
    if ($hasRedirect) {
        Add-Result 'Power Platform redirect URI registered' 'PASS' ''
    } else {
        Add-Result 'Power Platform redirect URI registered' 'FAIL' 'Not found. Re-run scripts/1-setup-app-registration.ps1 -Force.'
    }
}

# --- 7. Custom connector (only if script 3 was used) ----------------------------------------
if ($local.connectorId -and $local.environmentId) {
    Add-Result 'Custom connector created by automation' 'PASS' "Connector $($local.connectorId) in environment $($local.environmentId)"
} else {
    Add-Result 'Custom connector created by automation' 'WARN' 'Not recorded — either create it with scripts/3-create-custom-connector.ps1, or you created it by hand in the portal (that is fine too).'
}

# --- Summary ---------------------------------------------------------------------------------
Write-Host ''
$results | Format-Table -AutoSize

$fails = @($results | Where-Object Status -eq 'FAIL')
$warns = @($results | Where-Object Status -eq 'WARN')

Write-Host ''
if ($fails.Count -gt 0) {
    Write-Host "$($fails.Count) check(s) FAILED. Fix those before pointing reviewers at Custodia." -ForegroundColor Red
} elseif ($warns.Count -gt 0) {
    Write-Host "All required checks passed. $($warns.Count) item(s) need a manual look (see WARN rows above)." -ForegroundColor Yellow
} else {
    Write-Host 'All automated checks passed.' -ForegroundColor Green
}
Write-Host ''
Write-Host 'This script cannot check Copilot Studio itself (agent instructions, connector' -ForegroundColor DarkGray
Write-Host 'action wiring, per-user authentication, or the Purview eDiscovery role assignment).' -ForegroundColor DarkGray
Write-Host 'Verify those by hand, then run the "How to test" section of README.md.' -ForegroundColor DarkGray
