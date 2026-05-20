Import-Module AutomateAPI -Force

# ============================================================
# CONFIGURATION
# ============================================================

# Suppress warning noise from AutomateAPI retries.
# Failures are still captured in the final report.
$WarningPreference = 'SilentlyContinue'

# ScreenConnect / Control server, include https://
$ControlServer = "https://scrcon.360smartnet.com/"

# ScreenConnect / Control credentials
$ControlUsername = "rewst_api"
$ControlPassword = "-Tx#U[3<pVVP,=uQ"

# Automate server used by Reinstall-LTService or Restart-LTService, without https://
$AutomateServer = "lt.360smartnet.com"

# Hard-coded Automate installer token, only needed for reinstall scripts
$InstallerToken = "2df3aa5dc5206e83bbb73f714d0d99bc"

# CSV folder and file pattern
# Expected CSV columns: ComputerName, SessionID, LocationID
$CsvFolder = "C:\Temp\AutomateAgentReinstall"
$CsvFilePattern = "AutomateAgentBuild-Online*.csv"

# SessionIDs to exclude from processing.
$ExcludedSessionIDs = @(
     "efb1591b-1326-4f5e-9dbf-566c25baf814"
)

# Result report path
$RunDate = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ResultPath = "C:\Temp\Automate-Reinstall-Results-$RunDate.csv"
$ErrorLogPath = "C:\Temp\AutomateAgentCleanup\Invoke-ControlCommand-Errors-$RunDate.log"

# ============================================================
# VALIDATE CONFIGURATION
# ============================================================

if (-not (Test-Path $CsvFolder)) {
    throw "CSV folder not found: $CsvFolder"
}

if (-not $InstallerToken -or $InstallerToken -eq "YOUR-INSTALLER-TOKEN-HERE" -or $InstallerToken -eq "InstallerTokenHere") {
    throw "InstallerToken is missing. Update `$InstallerToken before running."
}

# Normalize Automate server
$AutomateServer = $AutomateServer `
    -replace "^https://", "" `
    -replace "^http://", "" `
    -replace "/$", ""

# Normalize excluded SessionIDs
$ExcludedSessionIDs = $ExcludedSessionIDs |
    ForEach-Object { $_ -split "," } |
    ForEach-Object { "$_".Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique

# Find the newest Offline-Control-Status CSV
$CsvFile = Get-ChildItem -Path $CsvFolder -Filter $CsvFilePattern |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $CsvFile) {
    throw "No CSV file found matching $CsvFolder\$CsvFilePattern"
}

# Import CSV
$Targets = Import-Csv -Path $CsvFile.FullName

if (-not $Targets -or $Targets.Count -eq 0) {
    throw "CSV file is empty: $($CsvFile.FullName)"
}

# Validate required columns
$RequiredColumns = @("ComputerName", "SessionID", "LocationID")
$CsvColumns = $Targets[0].PSObject.Properties.Name

foreach ($Column in $RequiredColumns) {
    if ($CsvColumns -notcontains $Column) {
        throw "CSV is missing required column : $Column"
    }
}

# ============================================================
# CLEAN AND VALIDATE TARGET ROWS
# ============================================================

$TargetsToRun = foreach ($Target in $Targets) {
    $ComputerName = "$($Target.ComputerName)".Trim()
    $SessionID    = "$($Target.SessionID)".Trim()
    $LocationID   = "$($Target.LocationID)".Trim()

    if (-not $ComputerName -or -not $SessionID -or -not $LocationID) {
        [PSCustomObject]@{
            ComputerName    = $ComputerName
            SessionID       = $SessionID
            LocationID      = $LocationID
            IsValid         = $false
            IsExcluded      = $false
            ValidationError = "Missing ComputerName, SessionID, or LocationID"
        }
        continue
    }

    if ($SessionID -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        [PSCustomObject]@{
            ComputerName    = $ComputerName
            SessionID       = $SessionID
            LocationID      = $LocationID
            IsValid         = $false
            IsExcluded      = $false
            ValidationError = "Invalid SessionID format"
        }
        continue
    }

    if ($LocationID -notmatch '^\d+$') {
        [PSCustomObject]@{
            ComputerName    = $ComputerName
            SessionID       = $SessionID
            LocationID      = $LocationID
            IsValid         = $false
            IsExcluded      = $false
            ValidationError = "Invalid LocationID format"
        }
        continue
    }

    $IsExcluded = $ExcludedSessionIDs -contains $SessionID

    [PSCustomObject]@{
        ComputerName    = $ComputerName
        SessionID       = $SessionID
        LocationID      = [int]$LocationID
        IsValid         = $true
        IsExcluded      = $IsExcluded
        ValidationError = $null
    }
}

$InvalidTargets  = $TargetsToRun | Where-Object { -not $_.IsValid }
$ExcludedTargets = $TargetsToRun | Where-Object { $_.IsValid -and $_.IsExcluded }
$ValidTargets    = $TargetsToRun | Where-Object { $_.IsValid -and -not $_.IsExcluded }

if (-not $ValidTargets -or $ValidTargets.Count -eq 0) {
    $SkippedResults = @()

    $SkippedResults += foreach ($Invalid in $InvalidTargets) {
        [PSCustomObject]@{
            ComputerName = $Invalid.ComputerName
            SessionID    = $Invalid.SessionID
            LocationID   = $Invalid.LocationID
            Status       = "Skipped"
            Error        = $Invalid.ValidationError
            Output       = $null
        }
    }

    $SkippedResults += foreach ($Excluded in $ExcludedTargets) {
        [PSCustomObject]@{
            ComputerName = $Excluded.ComputerName
            SessionID    = $Excluded.SessionID
            LocationID   = $Excluded.LocationID
            Status       = "Excluded"
            Error        = "SessionID listed in `$ExcludedSessionIDs"
            Output       = $null
        }
    }

    $SkippedResults | Export-Csv $ResultPath -NoTypeInformation
    throw "No valid non-excluded target rows found. Report exported to: $ResultPath"
}

# ============================================================
# BUILD SCREENCONNECT CREDENTIAL OBJECT
# ============================================================

if (-not $ControlUsername -or -not $ControlPassword) {
    throw "Control username or password is missing. Update `$ControlUsername and `$ControlPassword in the configuration section."
}

$SecureControlPassword = ConvertTo-SecureString $ControlPassword -AsPlainText -Force

$ControlCredential = New-Object System.Management.Automation.PSCredential (
    $ControlUsername,
    $SecureControlPassword
)

# ============================================================
# CONNECT TO SCREENCONNECT / CONTROL
# ============================================================

try {
    Connect-ControlAPI `
        -Server $ControlServer `
        -Credential $ControlCredential

    Write-Host "Connected to ScreenConnect / Control successfully." -ForegroundColor Green
}
catch {
    throw "Failed to connect to ScreenConnect / Control. $($_.Exception.Message)"
}

# ============================================================
# RUN COMMAND THROUGH SCREENCONNECT
# ============================================================

$Results = foreach ($Target in $ValidTargets) {

    $ComputerName = $Target.ComputerName
    $SessionID    = $Target.SessionID
    $LocationID   = $Target.LocationID

    $ReinstallCommand = @"
#!ps 
#timeout=600000 
#maxlength=10000000 
$ProgressPreference='SilentlyContinue' 
ECHO OFF 
ECHO AUTOMATEAPICOMMAND:7D265A396E16479D9FA0903BA613A013 
echo "DIAGNOSTIC-RESPONSE/1" 
echo "DiagnosticType: ReinstallAutomate" 
echo "ContentType: json" 
echo "" 

$WarningPreference='SilentlyContinue' 

IF([Net.SecurityProtocolType]::Tls) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls } IF([Net.SecurityProtocolType]::Tls11) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls11 } IF([Net.SecurityProtocolType]::Tls12) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 
} 

(new-object Net.WebClient).DownloadString('http://bit.ly/LTPoSh') | iex

Reinstall-LTService -SkipDotNet -Server https://$AutomateServer -LocationID $LocationID -InstallerToken $InstallerToken
"@

    Write-Host ""
    Write-Host "Running command on: $ComputerName | SessionID: $SessionID | LocationID: $LocationID" -ForegroundColor Cyan

    try {
        # Keep working/default Invoke-ControlCommand behavior.
        # Warnings remain visible. Red error stream is redirected to the log file.
        $Result = Invoke-ControlCommand `
            -SessionID $SessionID `
            -PowerShell `
            -Command $ReinstallCommand `
            -TimeOut 600000 `
            -MaxLength 10000000 2>> $ErrorLogPath

        [PSCustomObject]@{
            ComputerName = $ComputerName
            SessionID    = $SessionID
            LocationID   = $LocationID
            Status       = "Success"
            Error        = $null
            Output       = ($Result | Out-String).Trim()
        }
    }
    catch {
        [PSCustomObject]@{
            ComputerName = $ComputerName
            SessionID    = $SessionID
            LocationID   = $LocationID
            Status       = "Failed"
            Error        = $_.Exception.Message
            Output       = $null
        }
    }
}

# ============================================================
# ADD SKIPPED / EXCLUDED ROWS TO FINAL REPORT
# ============================================================

$InvalidResults = foreach ($Invalid in $InvalidTargets) {
    [PSCustomObject]@{
        ComputerName = $Invalid.ComputerName
        SessionID    = $Invalid.SessionID
        LocationID   = $Invalid.LocationID
        Status       = "Skipped"
        Error        = $Invalid.ValidationError
        Output       = $null
    }
}

$ExcludedResults = foreach ($Excluded in $ExcludedTargets) {
    [PSCustomObject]@{
        ComputerName = $Excluded.ComputerName
        SessionID    = $Excluded.SessionID
        LocationID   = $Excluded.LocationID
        Status       = "Excluded"
        Error        = "SessionID listed in `$ExcludedSessionIDs"
        Output       = $null
    }
}

$FinalResults = @($Results) + @($InvalidResults) + @($ExcludedResults)

# ============================================================
# OUTPUT RESULTS
# ============================================================

$FinalResults |
    Sort-Object Status, ComputerName |
    Export-Csv $ResultPath -NoTypeInformation

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTS"
Write-Host "============================================================"
Write-Host "CSV Used: $($CsvFile.FullName)"
Write-Host "Result Report: $ResultPath"
Write-Host "Error Log: $ErrorLogPath"
Write-Host ""

$FinalResults |
    Select-Object ComputerName, SessionID, LocationID, Status, Error |
    Sort-Object Status, ComputerName |
    Format-Table -AutoSize
