#Requires -Version 7.0
<#
.SYNOPSIS
    Standalone UTCM drift report — discovers all active monitors and reports drift for each.

.DESCRIPTION
    No config file or monitors.index.json required. The script connects to UTCM,
    discovers every active configurationMonitor in the tenant, queries
    configurationDrifts for each, and produces:

      .\out\drifts.all.json              — full drift export for all monitors
      .\out\drifts.summary_<date>.csv    — one row per monitor with drift count
      .\out\drift-check\drift-check_<MonitorId>.ps1
                                         — standalone re-runnable script per monitor

    Results are also printed to the console as a formatted report.

.PERMISSIONS
    ConfigurationMonitoring.ReadWrite.All

.NOTES
    - GET calls to monitors and drifts APIs consume no quota.
    - Drift records older than 30 days post-resolution are deleted by UTCM automatically.
    - Paging is handled on both monitors and drifts queries.
    - Resource type is extracted from the monitor's embedded baseline JSON.
    - monitoringResults must be queried per-monitor:
        /configurationMonitors/{id}/monitoringResults
      The top-level /configurationMonitors/monitoringResults collection does not exist
      in the UTCM API — it returns 400 (treats the segment as a GUID).
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$BaseV1   = 'https://graph.microsoft.com/v1.0/admin/configurationManagement'
$BaseBeta = 'https://graph.microsoft.com/beta/admin/configurationManagement'

$outRoot  = Join-Path $PSScriptRoot 'out'
$driftDir = Join-Path $outRoot 'drift-check'
New-Item -ItemType Directory -Path $outRoot  -Force | Out-Null
New-Item -ItemType Directory -Path $driftDir -Force | Out-Null

# ---------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host ("  " + ("─" * 64)) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * 64)) -ForegroundColor Cyan
    Write-Host ""
}
function Write-Pass   { param([string]$Msg) Write-Host "  ✔  $Msg" -ForegroundColor Green  }
function Write-Warn   { param([string]$Msg) Write-Host "  ⚠  $Msg" -ForegroundColor Yellow }
function Write-Detail { param([string]$Msg) Write-Host "     $Msg" -ForegroundColor Gray   }
function Write-Info   { param([string]$Msg) Write-Host "  ℹ  $Msg" -ForegroundColor White  }

function Invoke-GraphPaged {
    param([string]$Uri)
    $results = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        if ($response.value) { $results.AddRange($response.value) }
        $nextUri = $response.'@odata.nextLink'
    } while ($nextUri)
    return @($results)
}

function Get-ResourceTypesFromBaseline {
    param($Baseline)
    $types = @()
    if (-not $Baseline) { return $types }
    try {
        if ($Baseline.resources) {
            foreach ($r in @($Baseline.resources)) {
                if ($r.resourceType) { $types += $r.resourceType }
            }
        }
    } catch { }
    return $types
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   UTCM Drift Report — All Monitors | move2modern.co.uk  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Standalone — no config file or index required." -ForegroundColor DarkGray
    Write-Host "  Discovers all active monitors directly from UTCM." -ForegroundColor DarkGray
    Write-Host ""

    # ── CONNECT ──────────────────────────────────────────────
    Write-Banner "AUTHENTICATION"

    $tenant = Read-Host "  Enter tenant ID or domain"
    if (-not $tenant) { throw "Tenant is required." }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Connect-MgGraph -TenantId $tenant -Scopes @(
        'ConfigurationMonitoring.ReadWrite.All'
    ) -NoWelcome

    $orgName = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/organization").value[0].displayName
    Write-Pass "Connected: $orgName ($tenant)"

    # ── LOAD ALL MONITORS ────────────────────────────────────
    Write-Banner "DISCOVERING MONITORS"

    $monitorUri  = "$BaseV1/configurationMonitors?`$select=id,displayName,description,status,monitorRunFrequencyInHours,baseline"
    $allMonitors = @(Invoke-GraphPaged -Uri $monitorUri)

    if (-not $allMonitors -or $allMonitors.Count -eq 0) {
        Write-Warn "No monitors found in this tenant."
        Write-Info "Run New-UTCMMonitorSetup.ps1 first to create monitors."
        return
    }

    Write-Pass "Found $($allMonitors.Count) monitor(s)"

    # ── PROCESS EACH MONITOR ─────────────────────────────────
    Write-Banner "QUERYING MONITOR RESULTS AND DRIFTS"

    $reportRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $fullResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    $index = 0
    foreach ($monitor in $allMonitors) {

        $index++
        $monId   = $monitor.id
        $monName = $monitor.displayName

        Write-Host "  [$index/$($allMonitors.Count)] $monName" -ForegroundColor White
        Write-Detail "Monitor ID : $monId"

        # Extract resource types from embedded baseline
        $resourceTypes = Get-ResourceTypesFromBaseline -Baseline $monitor.baseline
        $rtDisplay     = if ($resourceTypes.Count -gt 0) { $resourceTypes -join ', ' } else { '(unknown)' }
        Write-Detail "Resource   : $rtDisplay"

        # ── Last run result ───────────────────────────────────
        # NOTE: Must be queried per monitor — no top-level collection exists.
        # /configurationMonitors/monitoringResults returns 400 (segment treated as GUID).
        $lastRun       = $null
        $lastRunStatus = 'no runs yet'
        $lastRunDrifts = 0
        $lastRunTime   = 'n/a'

        try {
            $runUri     = "$BaseBeta/configurationMonitors/$monId/monitoringResults"
            $runResults = @(Invoke-GraphPaged -Uri $runUri)
            if ($runResults.Count -gt 0) {
                $lastRun       = $runResults | Sort-Object startDateTime -Descending | Select-Object -First 1
                $lastRunStatus = $lastRun.status
                $lastRunDrifts = $lastRun.driftsCount
                $lastRunTime   = $lastRun.startDateTime
            }
        } catch {
            $lastRunStatus = "query error: $($_.Exception.Message)"
        }

        Write-Detail "Last run   : $lastRunTime | $lastRunStatus | $lastRunDrifts drift(s) reported by run"

        # ── Active drifts — paged ─────────────────────────────
        $drifts     = @()
        $driftCount = 0
        $driftError = $null

        try {
            $driftUri = "$BaseBeta/configurationDrifts?`$filter=monitorId eq '$monId'"
            $drifts   = @(Invoke-GraphPaged -Uri $driftUri)
            $driftCount = $drifts.Count
        } catch {
            $driftError = $_.Exception.Message
            Write-Warn "Drift query failed: $driftError"
        }

        if ($driftError) {
            Write-Warn "Active drifts  : query error"
        } elseif ($driftCount -eq 0) {
            Write-Pass "Active drifts  : none — all resources match baseline"
        } else {
            Write-Warn "Active drifts  : $driftCount"
            foreach ($d in $drifts) {
                Write-Detail "  Resource : $($d.baselineResourceDisplayName)"
                Write-Detail "  Status   : $($d.status)"
                Write-Detail "  Detected : $($d.firstReportedDateTime)"
                Write-Host ""
            }
        }

        # ── Generate standalone drift-check script ────────────
        $safeId      = $monId -replace '[^a-zA-Z0-9]', ''
        $driftScript = Join-Path $driftDir "drift-check_$safeId.ps1"

        $rtCommentBlock = if ($resourceTypes.Count -gt 0) {
            ($resourceTypes | ForEach-Object { "#   $_" }) -join "`n"
        } else {
            "#   (resource types not determined)"
        }

        $scriptContent = @"
#Requires -Version 7.0
<#
.SYNOPSIS
    Drift Check — $monName
.DESCRIPTION
    Queries UTCM configurationDrifts for monitor: $monName
    Monitor ID : $monId
    Resource(s):
$rtCommentBlock
    Generated by Get-UTCMDriftReport.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
#>

`$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Connect-MgGraph -Scopes @('ConfigurationMonitoring.ReadWrite.All') -NoWelcome

`$base      = 'https://graph.microsoft.com/beta/admin/configurationManagement'
`$monitorId = '$monId'

# Page through all drifts for this monitor
`$drifts  = [System.Collections.Generic.List[object]]::new()
`$nextUri = "`$base/configurationDrifts?`$filter=monitorId eq '`$monitorId'"
do {
    `$resp = Invoke-MgGraphRequest -Method GET -Uri `$nextUri
    if (`$resp.value) { `$drifts.AddRange(`$resp.value) }
    `$nextUri = `$resp.'@odata.nextLink'
} while (`$nextUri)

Write-Host ""
Write-Host "Monitor  : $monName" -ForegroundColor Cyan
Write-Host "ID       : $monId"   -ForegroundColor DarkGray
Write-Host ""

if (`$drifts.Count -eq 0) {
    Write-Host "  ✔  No active drift — all resources match baseline." -ForegroundColor Green
} else {
    Write-Host "  ⚠  `$(`$drifts.Count) active drift event(s):" -ForegroundColor Yellow
    Write-Host ""
    `$drifts | ForEach-Object {
        Write-Host "  Resource  : `$(`$_.baselineResourceDisplayName)" -ForegroundColor White
        Write-Host "  Status    : `$(`$_.status)"                       -ForegroundColor Gray
        Write-Host "  Detected  : `$(`$_.firstReportedDateTime)"        -ForegroundColor Gray
        if (`$_.driftedProperties) {
            Write-Host "  Properties drifted:" -ForegroundColor Gray
            `$_.driftedProperties | ForEach-Object {
                Write-Host "    `$(`$_.propertyName)" -ForegroundColor DarkGray
                Write-Host "      Expected : `$(`$_.desiredValue)"  -ForegroundColor DarkGray
                Write-Host "      Current  : `$(`$_.currentValue)"  -ForegroundColor Red
            }
        }
        Write-Host ""
    }
}
"@

        Set-Content -Path $driftScript -Value $scriptContent -Encoding utf8
        Write-Detail "Drift check script: $driftScript"

        # ── Collect for report ────────────────────────────────
        $reportRows.Add([PSCustomObject]@{
            MonitorId         = $monId
            MonitorName       = $monName
            ResourceTypes     = $rtDisplay
            LastRunTime       = $lastRunTime
            LastRunStatus     = $lastRunStatus
            LastRunDriftCount = $lastRunDrifts
            ActiveDriftCount  = $driftCount
            DriftQueryError   = $driftError
            DriftScriptPath   = $driftScript
        })

        $fullResults.Add([PSCustomObject]@{
            MonitorId     = $monId
            MonitorName   = $monName
            ResourceTypes = $resourceTypes
            LastRun       = $lastRun
            Drifts        = $drifts
        })

        Write-Host ""
    }

    # ── CONSOLE SUMMARY TABLE ────────────────────────────────
    Write-Banner "DRIFT SUMMARY"

    $colW = @{ Mon = 32; RT = 42 }

    Write-Host ("  {0,-$($colW.Mon)} {1,-$($colW.RT)} {2}" -f "Monitor", "Resource Type(s)", "Drifts") -ForegroundColor White
    Write-Host ("  {0,-$($colW.Mon)} {1,-$($colW.RT)} {2}" -f ("─" * $colW.Mon), ("─" * $colW.RT), "──────") -ForegroundColor DarkGray

    foreach ($row in $reportRows) {
        $driftDisplay = if ($row.DriftQueryError)            { "ERROR" }
                        elseif ($row.ActiveDriftCount -eq 0) { "✔ None" }
                        else                                 { "⚠ $($row.ActiveDriftCount)" }

        $color = if ($row.DriftQueryError)            { 'Red'    }
                 elseif ($row.ActiveDriftCount -eq 0) { 'Green'  }
                 else                                 { 'Yellow' }

        $monTrunc = if ($row.MonitorName.Length   -gt $colW.Mon) { $row.MonitorName.Substring(0, $colW.Mon - 1)  + '…' } else { $row.MonitorName }
        $rtTrunc  = if ($row.ResourceTypes.Length -gt $colW.RT)  { $row.ResourceTypes.Substring(0, $colW.RT - 1) + '…' } else { $row.ResourceTypes }

        Write-Host ("  {0,-$($colW.Mon)} {1,-$($colW.RT)} {2}" -f $monTrunc, $rtTrunc, $driftDisplay) -ForegroundColor $color
    }

    Write-Host ""

    $totalDrift   = ($reportRows | Measure-Object ActiveDriftCount -Sum).Sum
    $cleanCount   = @($reportRows | Where-Object { $_.ActiveDriftCount -eq 0 -and -not $_.DriftQueryError }).Count
    $driftedCount = @($reportRows | Where-Object { $_.ActiveDriftCount -gt 0 }).Count
    $errorCount   = @($reportRows | Where-Object { $_.DriftQueryError }).Count

    Write-Host "  Monitors checked     : $($allMonitors.Count)" -ForegroundColor White
    Write-Host "  Clean (no drift)     : $cleanCount"           -ForegroundColor Green
    Write-Host "  Drifted              : $driftedCount"         -ForegroundColor $(if ($driftedCount -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "  Query errors         : $errorCount"           -ForegroundColor $(if ($errorCount   -eq 0) { 'Green' } else { 'Red'    })
    Write-Host "  Total active drifts  : $totalDrift"           -ForegroundColor $(if ($totalDrift   -eq 0) { 'Green' } else { 'Yellow' })

    # ── WRITE OUTPUTS ────────────────────────────────────────
    Write-Banner "WRITING OUTPUTS"

    $jsonPath = Join-Path $outRoot 'drifts.all.json'
    $fullResults | ConvertTo-Json -Depth 80 | Set-Content -Path $jsonPath -Encoding utf8
    Write-Detail "Full export  : $jsonPath"

    $csvPath = Join-Path $outRoot ('drifts.summary_{0}.csv' -f (Get-Date -Format 'yyyyMMdd HHmm'))
    $reportRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
    Write-Detail "Summary CSV  : $csvPath"

    Write-Detail "Drift scripts: $driftDir"

    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                  Drift report complete                   ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "  ── Script terminated with an error ──" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $($_ | Out-String)" -ForegroundColor DarkGray
} finally {
    Write-Host ""
    Read-Host "  Press Enter to close"
}
