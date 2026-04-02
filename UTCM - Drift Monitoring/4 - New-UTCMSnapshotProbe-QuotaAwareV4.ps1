# =====================================================================
# New-UTCMSnapshotProbe-QuotaAwareV4.ps1
#
# Fixes 409 Conflict "Snapshot Job with displayName already exists" by ensuring
# per-RT unique displayName values (includes index).
#
# Safeguards:
# 1) PRE-FLIGHT (STRICT): Skip snapshot if no policies of that type exist.
#    If the pre-flight query fails, SKIP (quota-safe).
# 2) IDEMPOTENT: Reuse recent snapshot jobs (<=RecentDays) per resource type.
# 3) QUOTA-AWARE: Do not attempt new jobs when visible snapshot job limit reached.
# 4) POST-FLIGHT: If snapshot succeeds but baseline contains 0 resources, flag it
#    as emptyBaseline (useful for reporting why monitor creation will fail).
# =====================================================================

#Requires -Version 7.2
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------
# PREREQ CHECK
# ---------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "" 
    Write-Host "  Microsoft.Graph.Authentication module not found." -ForegroundColor Red
    Write-Host "  Install it with:" -ForegroundColor Yellow
    Write-Host "    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host "" 
    Read-Host "Press Enter to close"
    exit
}

# ---------------------------------------------------------------
# RESOURCE TYPES
# ---------------------------------------------------------------
$ResourceTypes = [ordered]@{
    "microsoft.entra.conditionalaccesspolicy"                          = "Entra: Conditional Access"
    "microsoft.intune.devicecompliancepolicywindows10"                 = "Intune: Compliance - Windows"
    "microsoft.intune.devicecompliancepolicyandroid"                   = "Intune: Compliance - Android"
    "microsoft.intune.devicecompliancepolicyandroidworkprofile"        = "Intune: Compliance - Android Work Profile"
    "microsoft.intune.devicecompliancepolicyandroiddeviceowner"        = "Intune: Compliance - Android Device Owner"
    "microsoft.intune.devicecompliancepolicyios"                       = "Intune: Compliance - iOS"
    "microsoft.intune.devicecompliancepolicymacos"                     = "Intune: Compliance - macOS"
    "microsoft.intune.antiviruspolicywindows10settingcatalog"          = "Intune: Endpoint Security - Antivirus"
    "microsoft.intune.applicationcontrolpolicywindows10"               = "Intune: App Control for Business"
    "microsoft.intune.accountprotectionpolicy"                         = "Intune: Account Protection"
    "microsoft.intune.accountprotectionlocalusergroupmembershippolicy" = "Intune: Account Protection - Local Groups"
    "microsoft.intune.appprotectionpolicyandroid"                      = "Intune: App Protection - Android"
    "microsoft.intune.appprotectionpolicyios"                          = "Intune: App Protection - iOS"
    "microsoft.intune.appconfigurationpolicy"                          = "Intune: App Configuration"
    "microsoft.intune.deviceandappmanagementassignmentfilter"          = "Intune: Assignment Filter"
    "microsoft.intune.devicecategory"                                  = "Intune: Device Category"
}

# ---------------------------------------------------------------
# ENDPOINTS
# ---------------------------------------------------------------
$GraphV1   = "https://graph.microsoft.com/v1.0"
$GraphBeta = "https://graph.microsoft.com/beta"
$UTCMBase  = "https://graph.microsoft.com/beta/admin/configurationManagement"

# ---------------------------------------------------------------
# PRE-FLIGHT MAP (ROBUST)
# ---------------------------------------------------------------
$PreflightMap = @{
    "microsoft.entra.conditionalaccesspolicy" = "$GraphV1/identity/conditionalAccess/policies?`$select=id&`$top=1"

    "microsoft.intune.devicecompliancepolicywindows10"          = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.windows10CompliancePolicy')&`$select=id&`$top=1"
    "microsoft.intune.devicecompliancepolicyandroid"            = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.androidCompliancePolicy')&`$select=id&`$top=1"
    "microsoft.intune.devicecompliancepolicyandroidworkprofile" = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.androidWorkProfileCompliancePolicy')&`$select=id&`$top=1"
    "microsoft.intune.devicecompliancepolicyandroiddeviceowner" = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.androidDeviceOwnerCompliancePolicy')&`$select=id&`$top=1"
    "microsoft.intune.devicecompliancepolicyios"                = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.iosCompliancePolicy')&`$select=id&`$top=1"
    "microsoft.intune.devicecompliancepolicymacos"              = "$GraphV1/deviceManagement/deviceCompliancePolicies?`$filter=isof('microsoft.graph.macOSCompliancePolicy')&`$select=id&`$top=1"

    "microsoft.intune.antiviruspolicywindows10settingcatalog"   = "$GraphBeta/deviceManagement/configurationPolicies?`$filter=templateReference/templateFamily eq 'endpointSecurityAntivirus'&`$select=id&`$top=1"
    "microsoft.intune.applicationcontrolpolicywindows10"        = "$GraphBeta/deviceManagement/configurationPolicies?`$filter=templateReference/templateFamily eq 'endpointSecurityApplicationControl'&`$select=id&`$top=1"
    "microsoft.intune.accountprotectionpolicy"                  = "$GraphBeta/deviceManagement/configurationPolicies?`$filter=templateReference/templateFamily eq 'endpointSecurityAccountProtection'&`$select=id&`$top=1"
    "microsoft.intune.accountprotectionlocalusergroupmembershippolicy" = "$GraphBeta/deviceManagement/configurationPolicies?`$filter=templateReference/templateFamily eq 'endpointSecurityAccountProtection'&`$select=id&`$top=1"

    "microsoft.intune.appprotectionpolicyandroid"               = "$GraphV1/deviceAppManagement/androidManagedAppProtections?`$select=id&`$top=1"
    "microsoft.intune.appprotectionpolicyios"                   = "$GraphV1/deviceAppManagement/iosManagedAppProtections?`$select=id&`$top=1"
    "microsoft.intune.appconfigurationpolicy"                   = "$GraphV1/deviceAppManagement/mobileAppConfigurations?`$select=id&`$top=1"
    "microsoft.intune.deviceandappmanagementassignmentfilter"   = "$GraphV1/deviceManagement/assignmentFilters?`$select=id&`$top=1"
    "microsoft.intune.devicecategory"                           = "$GraphV1/deviceManagement/deviceCategories?`$select=id&`$top=1"
}

# ---------------------------------------------------------------
# SETTINGS
# ---------------------------------------------------------------
$MaxVisibleSnapshotJobs = 12
$RecentDays             = 7
$PollInterval           = 5
$PollTimeout            = 120

# ---------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------
function Write-Banner {
    param([string]$Text)
    Write-Host "" 
    Write-Host ("  " + ("─" * 54)) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ("─" * 54)) -ForegroundColor Cyan
    Write-Host "" 
}

function Invoke-GraphPaged {
    param([string]$Uri)
    $items = @()
    $next = $Uri
    do {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($resp.value) { $items += $resp.value }
        $next = $resp.'@odata.nextLink'
    } while ($next)
    return $items
}

function Try-ParseDate {
    param([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
    try { return [datetime]$DateString } catch { return $null }
}

function Test-PoliciesExist {
    param([string]$ResourceType)

    if (-not $PreflightMap.ContainsKey($ResourceType)) {
        return $false
    }

    try {
        $r = Invoke-MgGraphRequest -Method GET -Uri $PreflightMap[$ResourceType]
        return ($r.value.Count -gt 0)
    } catch {
        Write-Host "              Pre-flight failed — SKIPPING (quota-safe)" -ForegroundColor Yellow
        Write-Host "              $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function New-UniqueSnapshotDisplayName {
    # displayName must be user-friendly; service appears to enforce uniqueness.
    # Keep within 8-32 chars and allow letters/numbers/spaces only.
    param(
        [int]$Index,
        [string]$Stamp
    )

    $name = "Probe $Index $Stamp"  # e.g. Probe 2 04022324
    $name = ($name -replace '[^a-zA-Z0-9 ]','').Trim()
    if ($name.Length -lt 8) { $name = ($name + ' Baseline').Trim() }
    if ($name.Length -gt 32) { $name = $name.Substring(0,32).Trim() }
    return $name
}

# ---------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------
try {
    Write-Host "" 
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  UTCM Snapshot Probe (Quota Aware V4) | move2modern   ║" -ForegroundColor Cyan
    Write-Host "  ║  STRICT pre-flight + idempotent + quota guard         ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "" 

    $confirm = Read-Host "  Proceed? (Y/N)"
    if ($confirm -notmatch '^[Yy]') { Write-Host "  Cancelled." -ForegroundColor Yellow; exit }

    Write-Banner "Authentication"

    $tenant = Read-Host "  Enter tenant ID or domain"
    if ([string]::IsNullOrWhiteSpace($tenant)) { throw "Tenant is required." }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Connect-MgGraph -TenantId $tenant -Scopes @(
        "ConfigurationMonitoring.ReadWrite.All",
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementApps.Read.All",
        "Policy.Read.All"
    ) -NoWelcome -ErrorAction Stop

    $ctx     = Get-MgContext
    $orgName = (Invoke-MgGraphRequest -Method GET -Uri "$GraphV1/organization").value[0].displayName
    Write-Host "  Connected: $orgName ($($ctx.TenantId))" -ForegroundColor Green

    Write-Banner "Checking existing snapshot jobs"

    $jobsUri = "$UTCMBase/configurationSnapshotJobs?`$select=id,displayName,status,resources,resourceLocation,createdDateTime,completedDateTime"
    $existingJobs = @(Invoke-GraphPaged -Uri $jobsUri)

    Write-Host "  Snapshot jobs currently visible: $($existingJobs.Count)" -ForegroundColor Gray

    $recentCutoff = (Get-Date).AddDays(-1 * $RecentDays)
    $latestByRT = @{}

    foreach ($j in $existingJobs) {
        $created = Try-ParseDate $j.createdDateTime
        if (-not ($created -and $created -ge $recentCutoff)) { continue }
        if ($j.status -notin @('succeeded','partiallySuccessful','running','inProgress','notStarted')) { continue }
        foreach ($rt in @($j.resources)) {
            if (-not $latestByRT.ContainsKey($rt)) { $latestByRT[$rt] = $j }
        }
    }

    Write-Banner "Probing resource types"

    $results = @()
    $i = 0

    foreach ($kvp in $ResourceTypes.GetEnumerator()) {
        $i++
        $rt = $kvp.Key
        $label = $kvp.Value

        Write-Host "  [$i/$($ResourceTypes.Count)] $label" -ForegroundColor White
        Write-Host "              $rt" -ForegroundColor DarkGray

        $row = [pscustomobject]@{
            Index        = $i
            ResourceType = $rt
            Name         = $label
            Status       = 'skipped'
            JobId        = $null
            SnapshotUrl  = $null
            Note         = $null
        }

        # Gate 1: reuse recent job
        if ($latestByRT.ContainsKey($rt)) {
            $row.Status = 'exists'
            $row.JobId = $latestByRT[$rt].id
            $row.SnapshotUrl = $latestByRT[$rt].resourceLocation
            $row.Note = 'Recent snapshot job exists (reused)'
            Write-Host "              ↩️  Exists (reused)" -ForegroundColor Gray
            $results += $row
            Write-Host "" 
            continue
        }

        # Gate 2: job slot limit
        if ($existingJobs.Count -ge $MaxVisibleSnapshotJobs) {
            $row.Status = 'quotaBlocked'
            $row.Note = "Snapshot job limit reached ($MaxVisibleSnapshotJobs visible)."
            Write-Host "              ⛔ Skipped — snapshot job limit reached" -ForegroundColor Yellow
            $results += $row
            Write-Host "" 
            continue
        }

        # Gate 3: strict pre-flight
        Write-Host "              Pre-flight: checking tenant for existing policies..." -ForegroundColor DarkGray
        if (-not (Test-PoliciesExist -ResourceType $rt)) {
            $row.Status = 'emptyTenant'
            $row.Note = 'No policies found OR pre-flight failed (strict mode)'
            Write-Host "              🔍 No policies found — skipped" -ForegroundColor Yellow
            $results += $row
            Write-Host "" 
            continue
        }

        # Create snapshot job (unique displayName per RT)
        $stamp = (Get-Date).ToString('MMddHHmm')
        $displayName = New-UniqueSnapshotDisplayName -Index $i -Stamp $stamp

        $body = @{
            displayName = $displayName
            description = "UTCM snapshot probe $i/$($ResourceTypes.Count): $rt | move2modern"
            resources   = @($rt)
        } | ConvertTo-Json -Depth 3

        try {
            $job = Invoke-MgGraphRequest -Method POST -Uri "$UTCMBase/configurationSnapshots/createSnapshot" -Body $body -ContentType 'application/json'
            $row.JobId = $job.id
            $row.Status = ($job.status ?? 'notStarted')
            Write-Host "              ✅ Job created: $($job.id) | displayName: $displayName" -ForegroundColor Green
            $existingJobs += $job
        } catch {
            # Handle 409 conflict (displayName collision) by retrying once with a different name
            $msg = $_.Exception.Message
            if ($msg -match '409' -or $msg -match 'Conflict') {
                $displayName2 = New-UniqueSnapshotDisplayName -Index $i -Stamp ((Get-Date).ToString('MMddHHmm') + '9')
                $body2 = @{
                    displayName = $displayName2
                    description = "UTCM snapshot probe retry $i/$($ResourceTypes.Count): $rt | move2modern"
                    resources   = @($rt)
                } | ConvertTo-Json -Depth 3

                try {
                    $job = Invoke-MgGraphRequest -Method POST -Uri "$UTCMBase/configurationSnapshots/createSnapshot" -Body $body2 -ContentType 'application/json'
                    $row.JobId = $job.id
                    $row.Status = ($job.status ?? 'notStarted')
                    $row.Note = 'Retried after 409 displayName conflict'
                    Write-Host "              ✅ Job created (retry): $($job.id) | displayName: $displayName2" -ForegroundColor Green
                    $existingJobs += $job
                } catch {
                    $row.Status = 'skipped'
                    $row.Note = "CreateSnapshot failed after retry: $($_.Exception.Message)"
                    Write-Host "              ⚠️  CreateSnapshot failed after retry" -ForegroundColor Yellow
                }
            } else {
                $row.Status = 'skipped'
                $row.Note = "CreateSnapshot failed: $msg"
                Write-Host "              ⚠️  CreateSnapshot failed" -ForegroundColor Yellow
            }
            $results += $row
            Write-Host "" 
            continue
        }

        # Poll
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($row.Status -notin @('succeeded','partiallySuccessful','failed') -and $sw.Elapsed.TotalSeconds -lt $PollTimeout) {
            Start-Sleep -Seconds $PollInterval
            $st = Invoke-MgGraphRequest -Method GET -Uri "$UTCMBase/configurationSnapshotJobs/$($row.JobId)"
            $row.Status = ($st.status ?? $row.Status)
            if ($st.resourceLocation) { $row.SnapshotUrl = $st.resourceLocation }
            Write-Host "              Polling... $($row.Status) ($([int]$sw.Elapsed.TotalSeconds)s)" -ForegroundColor DarkGray
        }

        # Post-flight: mark emptyBaseline if baseline has no resources
        if ($row.Status -in @('succeeded','partiallySuccessful') -and $row.SnapshotUrl) {
            try {
                $snap = Invoke-MgGraphRequest -Method GET -Uri $row.SnapshotUrl
                if (-not $snap.resources -or @($snap.resources).Count -eq 0) {
                    $row.Note = 'Snapshot baseline empty (0 resources) — monitor likely to fail'
                    Write-Host "              ⚠️  Baseline empty (0 resources)" -ForegroundColor Yellow
                }
            } catch {
                # ignore post-flight inspection errors
            }
        }

        $results += $row
        Write-Host "" 
    }

    Write-Banner "Summary"
    $exists = @($results | Where-Object { $_.Status -eq 'exists' })
    $createdOK = @($results | Where-Object { $_.Status -in @('succeeded','partiallySuccessful') })
    $empty = @($results | Where-Object { $_.Status -eq 'emptyTenant' })
    $blocked = @($results | Where-Object { $_.Status -eq 'quotaBlocked' })
    $errs = @($results | Where-Object { $_.Status -eq 'skipped' })

    Write-Host "  Total RTs          : $($ResourceTypes.Count)" -ForegroundColor White
    Write-Host "  Reused snapshots   : $($exists.Count)" -ForegroundColor Gray
    Write-Host "  Created succeeded  : $($createdOK.Count)" -ForegroundColor Green
    Write-Host "  Skipped (empty)    : $($empty.Count)" -ForegroundColor Yellow
    Write-Host "  Quota blocked      : $($blocked.Count)" -ForegroundColor Yellow
    Write-Host "  Create errors      : $($errs.Count)" -ForegroundColor Yellow

    $csvPath = Join-Path $PSScriptRoot ("UTCMSnapshotProbe_QuotaAwareV4_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "" 
    Write-Host "  Results exported to: $csvPath" -ForegroundColor DarkGray

} catch {
    Write-Host "" 
    Write-Host "  ── Script terminated with an error ──" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
} finally {
    Write-Host "" 
    Read-Host "  Press Enter to close"
}
