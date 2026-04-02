#Requires -Version 7.0
<#
.SYNOPSIS
Grant required Microsoft Graph application permissions to the UTCM service principal

.DESCRIPTION
Ensures the Unified Tenant Configuration Management (UTCM) service principal has
the Microsoft-documented permissions required for:
- Creating snapshots
- Creating monitors
- Evaluating drift
Across Conditional Access and all current Intune workloads.

Safe to run multiple times. Only missing permissions are assigned.
#>

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────
# CONSTANTS (fixed Microsoft app IDs)
# ─────────────────────────────────────────────────────────────
$UTCMAppId  = '03b07b79-c5bc-4b5e-9bfa-13acf4a99998'   # Unified Tenant Configuration Management
$GraphAppId = '00000003-0000-0000-c000-000000000000'   # Microsoft Graph

# Required Graph application permissions (authoritative set)
$RequiredGraphAppRoles = @(
    # Conditional Access
    'Policy.Read.All',
    'Policy.Read.ConditionalAccess',

    # Intune – configuration, apps, RBAC
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementApps.Read.All',
    'DeviceManagementRBAC.Read.All',

    # Required for assignments
    'Group.Read.All'
)

# ─────────────────────────────────────────────────────────────
# MODULES + AUTH
# ─────────────────────────────────────────────────────────────
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications

Connect-MgGraph -Scopes @(
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All'
) -NoWelcome

# ─────────────────────────────────────────────────────────────
# LOAD SERVICE PRINCIPALS
# ─────────────────────────────────────────────────────────────
$utcmSp = Get-MgServicePrincipal -Filter "appId eq '$UTCMAppId'" -ErrorAction Stop
if (-not $utcmSp) {
    throw "UTCM service principal not found. Run the SP bootstrap script first."
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '$GraphAppId'" -ErrorAction Stop

# Existing assignments
$existingAssignments = Invoke-MgGraphRequest `
    -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($utcmSp.Id)/appRoleAssignments"

$existingRoleIds = @($existingAssignments.value | ForEach-Object { $_.appRoleId })

# ─────────────────────────────────────────────────────────────
# PROCESS PERMISSIONS
# ─────────────────────────────────────────────────────────────
$results = @()

foreach ($perm in $RequiredGraphAppRoles) {

    $appRole = $graphSp.AppRoles |
        Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains 'Application' } |
        Select-Object -First 1

    if (-not $appRole) {
        $results += [pscustomobject]@{
            Permission = $perm
            Status     = 'Not found in Graph'
        }
        continue
    }

    if ($existingRoleIds -contains $appRole.Id) {
        $results += [pscustomobject]@{
            Permission = $perm
            Status     = 'Already assigned'
        }
        continue
    }

    # Assign missing role
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $utcmSp.Id `
        -BodyParameter @{
            principalId = $utcmSp.Id
            resourceId  = $graphSp.Id
            appRoleId  = $appRole.Id
        } | Out-Null

    $results += [pscustomobject]@{
        Permission = $perm
        Status     = 'Assigned'
    }
}

# ─────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "UTCM Graph Permission Summary" -ForegroundColor Cyan
Write-Host "─────────────────────────────"
$results | Format-Table -AutoSize

