Import-Module AutomateAPI

Connect-AutomateAPI

$DaysBack = 30
$Cutoff = (Get-Date).Date.AddDays(-$DaysBack)
$Today = (Get-Date).Date
$Date = Get-Date -Format "yyyy-MM-dd-HHmmss"

$ExportFolder = "C:\Temp\AutomatePatchReports"
$ExportPath = Join-Path $ExportFolder "WindowsOnly-PatchInventory-Or-NotPatched-OlderThan-$DaysBack-Days-$Date.csv"

New-Item -ItemType Directory -Path $ExportFolder -Force | Out-Null

$PatchInventoryFieldHints = @(
    'PatchInventory',
    'PatchInventoryDate',
    'LastPatchInventory',
    'LastPatchInventoryDate',
    'LastPatchScan',
    'LastPatchScanDate',
    'PatchScanDate',
    'LastHotfixUpdate',
    'LastHotfixInventory',
    'LastUpdateInventory',
    'LastInventory',
    'InventoryDate'
)

$LastPatchedFieldHints = @(
    'LastPatched',
    'LastPatchedDate',
    'LastPatchDate',
    'LastPatchInstall',
    'LastPatchInstalled',
    'LastPatchInstalledDate',
    'LastHotfixInstall',
    'LastHotfixInstalled',
    'LastHotfixInstalledDate',
    'LastWindowsUpdate',
    'LastUpdateInstall',
    'LastUpdateInstalled',
    'LastUpdateInstalledDate'
)

$WindowsOSFieldHints = @(
    'OS',
    'OperatingSystem',
    'OperatingSystemName',
    'OSName',
    'OSDescription',
    'OSType',
    'Platform'
)

function Convert-AutomateDate {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $StringValue = ($Value | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($StringValue)) {
        return $null
    }

    switch -Regex ($StringValue) {
        '^(Today)$' {
            return (Get-Date).Date
        }

        '^(Yesterday)$' {
            return (Get-Date).Date.AddDays(-1)
        }

        '^(Never|None|N/A|Unknown|No|False)$' {
            return $null
        }

        '^0+$' {
            return $null
        }

        '^1/1/0001' {
            return $null
        }

        '^1/1/1900' {
            return $null
        }
    }

    try {
        return ([datetime]$StringValue).Date
    }
    catch {
        return $null
    }
}

function Get-DateCandidatesFromObject {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$FieldHints,

        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    $Properties = $Object.PSObject.Properties

    $CandidateProperties = foreach ($Property in $Properties) {
        $Name = $Property.Name
        $Value = $Property.Value

        $HintMatch = $false

        foreach ($Hint in $FieldHints) {
            if ($Name -like "*$Hint*") {
                $HintMatch = $true
                break
            }
        }

        $DynamicMatch = $false

        if ($Mode -eq 'Inventory') {
            if ($Name -match 'patch|hotfix|update|inventory|scan') {
                $DynamicMatch = $true
            }
        }

        if ($Mode -eq 'LastPatched') {
            if ($Name -match 'patch|hotfix|update|install|installed') {
                $DynamicMatch = $true
            }
        }

        if ($HintMatch -or $DynamicMatch) {
            [PSCustomObject]@{
                Field = $Name
                Raw   = $Value
                Date  = Convert-AutomateDate -Value $Value
            }
        }
    }

    $CandidateProperties |
        Where-Object {
            $_.Raw -or $_.Date
        }
}

function Get-NewestValidDateResult {
    param(
        [Parameter(Mandatory = $false)]
        $Candidates
    )

    $ValidCandidates = @($Candidates | Where-Object { $_.Date })

    if ($ValidCandidates.Count -eq 0) {
        return [PSCustomObject]@{
            NewestDate      = $null
            NewestField     = $null
            NewestRawValue  = $null
            AllFieldsFound  = (($Candidates | Select-Object -ExpandProperty Field -Unique) -join '; ')
            AllRawValues    = (($Candidates | ForEach-Object { "$($_.Field)=$($_.Raw)" }) -join '; ')
        }
    }

    $Newest = $ValidCandidates | Sort-Object Date -Descending | Select-Object -First 1

    return [PSCustomObject]@{
        NewestDate      = $Newest.Date
        NewestField     = $Newest.Field
        NewestRawValue  = $Newest.Raw
        AllFieldsFound  = (($Candidates | Select-Object -ExpandProperty Field -Unique) -join '; ')
        AllRawValues    = (($Candidates | ForEach-Object { "$($_.Field)=$($_.Raw)" }) -join '; ')
    }
}

function Get-FirstMatchingPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string[]]$FieldHints
    )

    foreach ($Property in $Object.PSObject.Properties) {
        foreach ($Hint in $FieldHints) {
            if ($Property.Name -like "*$Hint*") {
                if ($Property.Value) {
                    return [PSCustomObject]@{
                        Field = $Property.Name
                        Value = ($Property.Value | Out-String).Trim()
                    }
                }
            }
        }
    }

    return [PSCustomObject]@{
        Field = $null
        Value = $null
    }
}

function Test-IsWindowsDevice {
    param(
        [Parameter(Mandatory = $true)]
        $Computer
    )

    $OSResult = Get-FirstMatchingPropertyValue -Object $Computer -FieldHints $WindowsOSFieldHints
    $OSValue = $OSResult.Value

    if ([string]::IsNullOrWhiteSpace($OSValue)) {
        return $false
    }

    if ($OSValue -match 'Windows|Win32NT|Microsoft') {
        return $true
    }

    return $false
}

$AllComputers = Get-AutomateComputer -Online $True

$WindowsComputers = $AllComputers | Where-Object {
    Test-IsWindowsDevice -Computer $_
}

$Results = foreach ($Computer in $WindowsComputers) {

    $OSResult = Get-FirstMatchingPropertyValue -Object $Computer -FieldHints $WindowsOSFieldHints

    $InventoryCandidates = Get-DateCandidatesFromObject `
        -Object $Computer `
        -FieldHints $PatchInventoryFieldHints `
        -Mode 'Inventory'

    $LastPatchedCandidates = Get-DateCandidatesFromObject `
        -Object $Computer `
        -FieldHints $LastPatchedFieldHints `
        -Mode 'LastPatched'

    $InventoryResult = Get-NewestValidDateResult -Candidates $InventoryCandidates
    $LastPatchedResult = Get-NewestValidDateResult -Candidates $LastPatchedCandidates

    $InventoryMissing = -not $InventoryResult.NewestDate
    $LastPatchedMissing = -not $LastPatchedResult.NewestDate

    $InventoryOlderThanCutoff = $InventoryMissing -or ($InventoryResult.NewestDate -lt $Cutoff)
    $LastPatchedOlderThanCutoff = $LastPatchedMissing -or ($LastPatchedResult.NewestDate -lt $Cutoff)

    if ($InventoryOlderThanCutoff -or $LastPatchedOlderThanCutoff) {

        [PSCustomObject]@{
            ClientName                    = $Computer.ClientName
            LocationName                  = $Computer.LocationName
            ComputerName                  = $Computer.ComputerName
            ComputerID                    = $Computer.ComputerID
            Online                        = $Computer.Online

            OSFieldUsed                   = $OSResult.Field
            OSValue                       = $OSResult.Value

            PatchInventoryDate            = $InventoryResult.NewestDate
            PatchInventoryAgeDays         = if ($InventoryResult.NewestDate) {
                                                [math]::Round(($Today - $InventoryResult.NewestDate).TotalDays, 1)
                                            } else {
                                                'Missing/Never'
                                            }
            PatchInventoryFieldUsed       = $InventoryResult.NewestField
            PatchInventoryRawValue        = $InventoryResult.NewestRawValue
            PatchInventoryOlderThan30     = $InventoryOlderThanCutoff

            LastPatchedDate               = $LastPatchedResult.NewestDate
            LastPatchedAgeDays            = if ($LastPatchedResult.NewestDate) {
                                                [math]::Round(($Today - $LastPatchedResult.NewestDate).TotalDays, 1)
                                            } else {
                                                'Missing/Never'
                                            }
            LastPatchedFieldUsed          = $LastPatchedResult.NewestField
            LastPatchedRawValue           = $LastPatchedResult.NewestRawValue
            NotPatchedIn30Days            = $LastPatchedOlderThanCutoff

            PatchInventoryFieldsFound     = $InventoryResult.AllFieldsFound
            PatchInventoryAllRawValues    = $InventoryResult.AllRawValues
            LastPatchedFieldsFound        = $LastPatchedResult.AllFieldsFound
            LastPatchedAllRawValues       = $LastPatchedResult.AllRawValues

            RemoteAgentLastContact        = $Computer.RemoteAgentLastContact
        }
    }
}

$Results |
    Sort-Object ClientName, LocationName, ComputerName |
    Export-Csv $ExportPath -NoTypeInformation

$Results |
    Sort-Object ClientName, LocationName, ComputerName |
    Select-Object `
        ClientName,
        LocationName,
        ComputerName,
        OSValue,
        PatchInventoryDate,
        PatchInventoryAgeDays,
        PatchInventoryOlderThan30,
        LastPatchedDate,
        LastPatchedAgeDays,
        NotPatchedIn30Days |
    Format-Table -AutoSize

Write-Output ""
Write-Output "Exported to: $ExportPath"
Write-Output ""
Write-Output "Cutoff date used: $Cutoff"
Write-Output "Today values are treated as: $Today"
Write-Output "Total online computers checked: $($AllComputers.Count)"
Write-Output "Windows online computers checked: $($WindowsComputers.Count)"
Write-Output "Matching stale/missing patch records exported: $($Results.Count)"
