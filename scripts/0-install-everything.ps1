<#
.SYNOPSIS
    Start here. Sets up Custodia end to end with as little manual work as possible.

.DESCRIPTION
    This is the one script a non-technical admin should run. It walks through the whole
    installable part of Custodia in plain language, asking only for the handful of things
    that must come from a human (your tenant ID, and whether to also auto-create the custom
    connector):

      1. Checks for the Azure CLI (and, if you choose automatic connector creation, Python)
         and offers to install anything missing with winget.
      2. Signs you in to Azure / Microsoft Entra ID.
      3. Runs scripts/1-setup-app-registration.ps1 — creates the Entra app registration,
         delegated Graph permissions, admin consent, exposed API scope, and the Power
         Platform redirect URI.
      4. Optionally runs scripts/3-create-custom-connector.ps1 — creates the Power Platform
         custom connector itself, fully wired for on-behalf-of auth. No portal clicking.
      5. Runs scripts/4-test-setup.ps1 and writes a plain-language SETUP-SUMMARY.md so you
         have a record of what happened and exactly what is left to do by hand.

    What this script CANNOT automate, on purpose:
      - Creating the Custodia agent inside Copilot Studio and pasting in agent/instructions.md.
        Copilot Studio does not expose this as an API a script can safely drive end to end.
      - Assigning the Purview eDiscovery Manager role to your reviewers. That is a per-person,
        per-tenant decision your Purview admin makes deliberately — see README.md "4. Grant a
        reviewer access".
      - Publishing the agent to Teams / Microsoft 365 Copilot, and sharing it with reviewers.

    You will still need to do those three things by hand, in Copilot Studio and the Purview
    portal. Everything else, this script does for you.

    Run it from an elevated PowerShell prompt if possible, as an account with rights to:
      - Create app registrations and grant admin consent in Microsoft Entra ID
        (Application Administrator / Cloud Application Administrator, plus Privileged Role
        Administrator or Global Administrator for consent).
      - Create connectors in the target Power Platform environment (maker access).

.PARAMETER TenantId
    Your Microsoft Entra tenant ID. If omitted, you will be prompted for it.

.PARAMETER EnvironmentId
    Power Platform environment GUID to create the custom connector in. Only needed if you
    choose automatic connector creation; if omitted, you will be prompted for it.

.PARAMETER SkipConnector
    Skip automatic custom-connector creation and just do the app registration. Use this if
    you would rather create the connector by hand following README.md.

.EXAMPLE
    ./0-install-everything.ps1
#>

[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $EnvironmentId,
    [switch] $SkipConnector
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

function Write-Banner {
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Magenta
    Write-Host " $Text" -ForegroundColor Magenta
    Write-Host ('=' * 70) -ForegroundColor Magenta
}

function Confirm-YesNo {
    param([string] $Prompt, [bool] $DefaultYes = $true)
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer.Trim().ToLowerInvariant() -in @('y', 'yes')
}

Write-Banner 'Custodia setup'
Write-Host @'
This will set up the Microsoft Entra app registration and (optionally) the Power Platform
custom connector that Custodia needs. It will NOT touch Copilot Studio or assign anyone a
Purview role — those two steps are quick, deliberate, human decisions, done at the end.

You can stop at any time with Ctrl+C. Nothing here is destructive: it creates new resources,
it does not delete or modify anything that already exists in your tenant.
'@

# --- Step 0: prerequisites -----------------------------------------------------------------
Write-Banner 'Step 1 of 4 — Checking prerequisites'

$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host 'Azure CLI (az) is not installed.' -ForegroundColor Yellow
    if ($hasWinget -and (Confirm-YesNo 'Install it now with winget?')) {
        winget install -e --id Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
        Write-Host ''
        Write-Host 'Azure CLI was installed. Close this window, reopen a new PowerShell window,' -ForegroundColor Yellow
        Write-Host 'and run this script again so the updated PATH takes effect.' -ForegroundColor Yellow
        return
    } else {
        throw 'Install the Azure CLI (https://aka.ms/installazurecliwindows) and re-run this script.'
    }
}
Write-Host '  Azure CLI: found' -ForegroundColor Green

if (-not $SkipConnector) {
    $hasPython = [bool](Get-Command python -ErrorAction SilentlyContinue) -or [bool](Get-Command py -ErrorAction SilentlyContinue)
    if (-not $hasPython) {
        Write-Host 'Python is not installed (needed for automatic connector creation).' -ForegroundColor Yellow
        if ($hasWinget -and (Confirm-YesNo 'Install it now with winget?')) {
            winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
            Write-Host ''
            Write-Host 'Python was installed. Close this window, reopen a new PowerShell window,' -ForegroundColor Yellow
            Write-Host 'and run this script again so the updated PATH takes effect.' -ForegroundColor Yellow
            return
        } else {
            Write-Host 'Continuing without automatic connector creation. You will create it by hand instead.' -ForegroundColor Yellow
            $SkipConnector = $true
        }
    } else {
        Write-Host '  Python: found' -ForegroundColor Green
    }
}

# --- Step 1: gather the few inputs that must come from a human ----------------------------
Write-Banner 'Step 2 of 4 — A couple of questions'

if (-not $TenantId) {
    $TenantId = Read-Host 'Your Microsoft Entra tenant ID (GUID or contoso.onmicrosoft.com)'
}
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    throw 'A tenant ID is required.'
}

if (-not $SkipConnector -and -not $EnvironmentId) {
    Write-Host ''
    Write-Host 'The Power Platform environment ID is on https://make.powerapps.com under' -ForegroundColor DarkGray
    Write-Host 'Settings (gear icon) > Session details > Environment ID.' -ForegroundColor DarkGray
    $EnvironmentId = Read-Host 'Power Platform environment ID (leave blank to skip automatic connector creation)'
    if ([string]::IsNullOrWhiteSpace($EnvironmentId)) { $SkipConnector = $true }
}

# --- Step 2: app registration ---------------------------------------------------------------
Write-Banner 'Step 3 of 4 — Microsoft Entra app registration'

$appResult = & (Join-Path $PSScriptRoot '1-setup-app-registration.ps1') -TenantId $TenantId
if (-not $appResult) {
    throw 'App registration step did not return a result. Check the output above for errors.'
}

# --- Step 3: custom connector (optional) -----------------------------------------------------
$connectorResult = $null
if (-not $SkipConnector) {
    Write-Banner 'Step 4 of 4 — Power Platform custom connector'

    if (-not $appResult.ClientSecret) {
        Write-Host 'No client secret is available in this session (the app registration already' -ForegroundColor Yellow
        Write-Host 'existed). You will be prompted to paste one in.' -ForegroundColor Yellow
        $connectorResult = & (Join-Path $PSScriptRoot '3-create-custom-connector.ps1') `
            -EnvironmentId $EnvironmentId -TenantId $appResult.TenantId -ClientId $appResult.ClientId
    } else {
        $secureSecret = ConvertTo-SecureString -String $appResult.ClientSecret -AsPlainText -Force
        $connectorResult = & (Join-Path $PSScriptRoot '3-create-custom-connector.ps1') `
            -EnvironmentId $EnvironmentId -TenantId $appResult.TenantId -ClientId $appResult.ClientId `
            -ClientSecret $secureSecret
    }
} else {
    Write-Banner 'Step 4 of 4 — Custom connector (skipped)'
    Write-Host 'Create it by hand from connector/apiDefinition.swagger.json — see README.md "2. Custom connector".' -ForegroundColor Yellow
}

# --- Validate + write a plain-language summary ----------------------------------------------
Write-Banner 'Checking everything'
& (Join-Path $PSScriptRoot '4-test-setup.ps1')

$summaryPath = Join-Path $repoRoot 'SETUP-SUMMARY.md'
$connectorLine = if ($connectorResult -and $connectorResult.ConnectorId) {
    "- [x] Custom connector created automatically (ID: $($connectorResult.ConnectorId), environment: $($connectorResult.EnvironmentId))"
} else {
    '- [ ] Custom connector — not created automatically. Follow README.md "2. Custom connector".'
}

@"
# Custodia setup summary

Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by scripts/0-install-everything.ps1.
This file is local only (git-ignored) — it is your record of what happened, not something to
commit or share outside your organization.

## Done automatically

- [x] Microsoft Entra app registration (tenant $($appResult.TenantId), client $($appResult.ClientId))
- [x] Delegated Graph permissions: eDiscovery.ReadWrite.All, User.Read — no application permissions
- [x] Tenant-wide admin consent
- [x] Exposed API scope access_as_user, pre-authorized for Power Platform connectors
- [x] Power Platform OAuth redirect URI registered
$connectorLine

## Left for you to do by hand

1. **Create the Custodia agent in Copilot Studio.**
   - New agent, named Custodia. Use agent/brand/custodia-avatar.png as the icon.
   - Paste agent/instructions.md into the agent's Instructions.
   - Add the custom connector as an action (all operations — the connector definition is
     the safety boundary, not per-tool toggles).
   - Authentication: each user signs in with THEIR OWN credentials. Do not use
     maker-provided / shared credentials — this is what makes on-behalf-of meaningful.
   - Upload agent/evaluations/*.csv under Evaluate and run them.
   - Publish to Microsoft 365 Copilot / Teams.

2. **Assign the Purview eDiscovery Manager role** to each reviewer who should use Custodia.
   Purview portal > Roles & scopes > Role groups. Do this deliberately, per person — see
   README.md "4. Grant a reviewer access" for why role choice matters and what happens if
   you get it wrong.

3. **Test before pointing it at a real request.** Follow README.md "How to test": a
   non-production case with synthetic data first, then verify a low-privilege reviewer
   cannot see another reviewer's cases through the agent.

Full detail for all three steps is in README.md.
"@ | Set-Content -Path $summaryPath -Encoding utf8

Write-Banner 'Done'
Write-Host "A plain-language summary was written to SETUP-SUMMARY.md — open it next." -ForegroundColor Green
