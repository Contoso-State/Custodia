<#
.SYNOPSIS
    Reference flow: create an eDiscovery case, create a search, run a statistics estimate,
    and read the result back.

.DESCRIPTION
    This script mirrors exactly what the GwinnIQ agent is allowed to do. It stops at
    estimate + read. It never exports, purges, deletes, holds, populates a review set, or
    applies review tags.

    Authentication is DELEGATED: it signs in the interactive user with Microsoft.Graph
    PowerShell and requests only eDiscovery.ReadWrite.All and User.Read. The script cannot
    exceed the signed-in reviewer's own Purview eDiscovery role.

    Defaults are read from scripts/foia-case-template.json.

.PARAMETER RequestNumber
    The FOIA intake tracking number, for example 00142.

.PARAMETER ShortSubject
    Short kebab-case subject for the case name, for example budget-emails.

.PARAMETER Keywords
    KQL keyword expression, for example '"budget" OR "appropriation"'.

.PARAMETER RangeStart
    Start of the requested date range (yyyy-MM-dd).

.PARAMETER RangeEnd
    End of the requested date range (yyyy-MM-dd).

.PARAMETER DataSourceScopes
    One of: none, allTenantMailboxes, allTenantSites, allCaseCustodians,
    allCaseNoncustodialDataSources.

.PARAMETER WhatIfOnly
    Print the case name, query, and scope that would be created, then exit without writing.

.EXAMPLE
    ./2-create-foia-case.ps1 -RequestNumber 00142 -ShortSubject budget-emails `
        -Keywords '"budget" OR "appropriation"' -RangeStart 2026-01-01 -RangeEnd 2026-06-30 `
        -WhatIfOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RequestNumber,
    [Parameter(Mandatory)][string] $ShortSubject,
    [Parameter(Mandatory)][string] $Keywords,
    [Parameter(Mandatory)][string] $RangeStart,
    [Parameter(Mandatory)][string] $RangeEnd,

    [ValidateSet('none', 'allTenantMailboxes', 'allTenantSites',
                 'allCaseCustodians', 'allCaseNoncustodialDataSources')]
    [string] $DataSourceScopes,

    [string] $StatisticsOptions,
    [int]    $PollSeconds       = 15,
    [int]    $PollTimeoutMinutes = 30,
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$GraphBase = 'https://graph.microsoft.com/v1.0'

# --- Load template defaults -------------------------------------------------------------
$templatePath = Join-Path $PSScriptRoot 'foia-case-template.json'
if (-not (Test-Path $templatePath)) {
    throw "Case template not found at $templatePath"
}
$template = Get-Content $templatePath -Raw | ConvertFrom-Json

if (-not $DataSourceScopes)  { $DataSourceScopes  = $template.defaults.dataSourceScopes }
if (-not $StatisticsOptions) { $StatisticsOptions = $template.defaults.statisticsOptions }

# --- Build the case name and query from the template ------------------------------------
$year = (Get-Date).Year

$caseName = $template.naming.casePattern `
    -replace '\{year\}',          $year `
    -replace '\{requestNumber\}', $RequestNumber `
    -replace '\{shortSubject\}',  $ShortSubject

$searchName = $template.naming.searchPattern `
    -replace '\{caseName\}',  $caseName `
    -replace '\{iteration\}', '01'

$contentQuery = $template.queryDefaults.kqlTemplate `
    -replace '\{keywords\}',   [regex]::Escape($Keywords).Replace('\', '') `
    -replace '\{rangeStart\}', $RangeStart `
    -replace '\{rangeEnd\}',   $RangeEnd

$description = $template.defaults.descriptionTemplate `
    -replace '\{requestNumber\}', $RequestNumber `
    -replace '\{receivedDate\}',  (Get-Date -Format 'yyyy-MM-dd') `
    -replace '\{dueDate\}',       '(set by intake)' `
    -replace '\{rangeStart\}',    $RangeStart `
    -replace '\{rangeEnd\}',      $RangeEnd

# --- Restate before acting (same contract as the agent) ---------------------------------
Write-Host ''
Write-Host 'About to create the following:' -ForegroundColor Cyan
Write-Host "  Case name:     $caseName"
Write-Host "  Description:   $description"
Write-Host "  Search name:   $searchName"
Write-Host "  Content query: $contentQuery"
Write-Host "  Scope:         $DataSourceScopes"
Write-Host "  Statistics:    $StatisticsOptions"
Write-Host ''

if ($DataSourceScopes -in @('allTenantMailboxes', 'allTenantSites')) {
    Write-Warning "'$DataSourceScopes' searches the entire tenant. Confirm this is intended."
}

if ($WhatIfOnly) {
    Write-Host 'WhatIfOnly specified. Nothing was created.' -ForegroundColor Yellow
    return
}

$answer = Read-Host 'Type CREATE to proceed'
if ($answer -cne 'CREATE') {
    Write-Host 'Aborted. Nothing was created.' -ForegroundColor Yellow
    return
}

# --- Delegated sign-in ------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication

Write-Host 'Signing in (delegated) ...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'eDiscovery.ReadWrite.All', 'User.Read' -NoWelcome

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body
    )

    $params = @{
        Method      = $Method
        Uri         = $Uri
        OutputType  = 'HttpResponseMessage'
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }

    $response = Invoke-MgGraphRequest @params
    $content  = $response.Content.ReadAsStringAsync().Result

    if (-not $response.IsSuccessStatusCode) {
        throw "Graph $Method $Uri failed with $([int]$response.StatusCode): $content"
    }

    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Location   = $response.Headers.Location.AbsoluteUri
        Body       = if ([string]::IsNullOrWhiteSpace($content)) { $null }
                     else { $content | ConvertFrom-Json }
    }
}

try {
    # --- 1. Create the case -------------------------------------------------------------
    Write-Host 'Creating case ...' -ForegroundColor Cyan
    $caseResult = Invoke-Graph -Method POST `
        -Uri "$GraphBase/security/cases/ediscoveryCases" `
        -Body @{ displayName = $caseName; description = $description }

    $caseId = $caseResult.Body.id
    Write-Host "  Case ID: $caseId" -ForegroundColor Green

    # --- 2. Create the search -----------------------------------------------------------
    Write-Host 'Creating search ...' -ForegroundColor Cyan
    $searchResult = Invoke-Graph -Method POST `
        -Uri "$GraphBase/security/cases/ediscoveryCases/$caseId/searches" `
        -Body @{
            displayName      = $searchName
            description      = "Search for $caseName"
            contentQuery     = $contentQuery
            dataSourceScopes = $DataSourceScopes
        }

    $searchId = $searchResult.Body.id
    Write-Host "  Search ID: $searchId" -ForegroundColor Green

    # --- 3. Start the estimate (asynchronous, returns 202) ------------------------------
    Write-Host 'Starting statistics estimate ...' -ForegroundColor Cyan
    $estimate = Invoke-Graph -Method POST `
        -Uri "$GraphBase/security/cases/ediscoveryCases/$caseId/searches/$searchId/estimateStatistics" `
        -Body @{ statisticsOptions = $StatisticsOptions }

    Write-Host "  Accepted ($($estimate.StatusCode)). Operation: $($estimate.Location)"

    # --- 4. Poll case operations until nothing is pending --------------------------------
    Write-Host 'Polling operations ...' -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes($PollTimeoutMinutes)
    $pending  = @('notStarted', 'running')

    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Estimate did not complete within $PollTimeoutMinutes minutes."
        }

        $ops = Invoke-Graph -Method GET `
            -Uri "$GraphBase/security/cases/ediscoveryCases/$caseId/operations"

        $running = @($ops.Body.value | Where-Object { $_.status -in $pending })
        if ($running.Count -eq 0) { break }

        $statuses = ($running | ForEach-Object { "$($_.action)=$($_.status)" }) -join ', '
        Write-Host "  Still running: $statuses" -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSeconds
    }

    # --- 5. Read the estimate -----------------------------------------------------------
    Write-Host 'Reading estimate ...' -ForegroundColor Cyan
    $stats = Invoke-Graph -Method GET `
        -Uri "$GraphBase/security/cases/ediscoveryCases/$caseId/searches/$searchId/lastEstimateStatisticsOperation"

    $s = $stats.Body

    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Green
    Write-Host ' Estimate complete' -ForegroundColor Green
    Write-Host '=========================================================' -ForegroundColor Green
    Write-Host "  Case:               $caseName ($caseId)"
    Write-Host "  Search:             $searchName ($searchId)"
    Write-Host "  Status:             $($s.status)"
    Write-Host "  Indexed items:      $($s.indexedItemCount)"
    Write-Host "  Indexed size:       $($s.indexedItemsSize) bytes"
    Write-Host "  Unindexed items:    $($s.unindexedItemCount)"
    Write-Host "  Unindexed size:     $($s.unindexedItemsSize) bytes"
    Write-Host "  Mailboxes with hits:$($s.mailboxCount)"
    Write-Host "  Sites with hits:    $($s.siteCount)"
    Write-Host ''
    Write-Host 'This script stops here by design. Export, purge, holds, review sets, and' -ForegroundColor Yellow
    Write-Host 'tagging are out of scope and must be done by a reviewer in the Purview portal.' -ForegroundColor Yellow
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
