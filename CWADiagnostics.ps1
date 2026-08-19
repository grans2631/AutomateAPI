Import-Module AutomateAPI -Force

# ============================================================
# CONFIGURATION
# ============================================================

# ScreenConnect / Control server, include https://
$ControlServer = "https://sc.ScreenConnect.com/"

# Automate server used by AutomateDiagnostics, without https://
$AutomateServer = "lt.Automate.com"

# CSV folder and file pattern
# Expected CSV columns: ComputerName, SessionID, LocationID
$CsvFolder = "C:\Temp\AutomateAgentCleanup"
$CsvFilePattern = "Offline-Control-Status*.csv"

# Result report path
$RunDate = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ResultPath = "C:\Temp\Automate-Diagnostics-Results-$RunDate.csv"

# ============================================================
# VALIDATE CONFIGURATION
# ============================================================

if (-not (Test-Path $CsvFolder)) {
    throw "CSV folder not found: $CsvFolder"
}

# Normalize Automate server
$AutomateServer = $AutomateServer `
    -replace "^https://", "" `
    -replace "^http://", "" `
    -replace "/$", ""

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
        throw "CSV is missing required column: $Column"
    }
}

# ============================================================
# CLEAN AND VALIDATE TARGET ROWS
# ============================================================

$TargetsToRun = foreach ($Target in $Targets) {
    $ComputerName = "$($Target.ComputerName)".Trim()
    $SessionID    = "$($Target.SessionID)".Trim()
    $LocationID   = "$($Target.LocationID)".Trim()

    if (-not $ComputerName -or -not $SessionID) {
        [PSCustomObject]@{
            ComputerName    = $ComputerName
            SessionID       = $SessionID
            LocationID      = $LocationID
            IsValid         = $false
            ValidationError = "Missing ComputerName or SessionID"
        }
        continue
    }

    if ($SessionID -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        [PSCustomObject]@{
            ComputerName    = $ComputerName
            SessionID       = $SessionID
            LocationID      = $LocationID
            IsValid         = $false
            ValidationError = "Invalid SessionID format"
        }
        continue
    }

    [PSCustomObject]@{
        ComputerName    = $ComputerName
        SessionID       = $SessionID
        LocationID      = $LocationID
        IsValid         = $true
        ValidationError = $null
    }
}

$InvalidTargets = $TargetsToRun | Where-Object { -not $_.IsValid }
$ValidTargets   = $TargetsToRun | Where-Object { $_.IsValid }

if (-not $ValidTargets -or $ValidTargets.Count -eq 0) {
    $InvalidTargets | Export-Csv $ResultPath -NoTypeInformation
    throw "No valid target rows found. Validation report exported to: $ResultPath"
}

# ============================================================
# PROMPT FOR SCREENCONNECT CREDENTIALS
# ============================================================

$ControlCredential = Get-Credential -Message "ScreenConnect Username and Password"

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
# BUILD AUTOMATE DIAGNOSTICS COMMAND
# ============================================================

# Single-quoted here-string is intentional.
# This prevents local PowerShell from expanding variables like $_ before sending the command.

$AutomateDiagnosticsCommand = @'
#!ps
#maxlength=10000000
#timeout=600000
echo "DIAGNOSTIC-RESPONSE/1"
echo "DiagnosticType: Automate"
echo "ContentType: json"
echo ""
$WarningPreference='SilentlyContinue'; IF([Net.SecurityProtocolType]::Tls) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls}; IF([Net.SecurityProtocolType]::Tls11) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls11}; IF([Net.SecurityProtocolType]::Tls12) {[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}; Try { (new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/johnduprey/CWCAutomateDiagnostics/master/AutomateDiagnostics.ps1') | iex; Start-AutomateDiagnostics -ltposh 'http://bit.ly/LTPoSh' -include_lterrors -automate_server 'lt.360smartnet.com' -Verbose} Catch { $_.Exception.Message; Write-Output '!---BEGIN JSON---!'; Write-Output '{"version": "Error loading AutomateDiagnostics"}' }
'@

# ============================================================
# RUN DIAGNOSTICS THROUGH SCREENCONNECT
# ============================================================

$Results = foreach ($Target in $ValidTargets) {

    $ComputerName = $Target.ComputerName
    $SessionID    = $Target.SessionID
    $LocationID   = $Target.LocationID

    Write-Host ""
    Write-Host "Running diagnostics on: $ComputerName | SessionID: $SessionID | LocationID: $LocationID" -ForegroundColor Cyan

    try {
        # Keep working/default Invoke-ControlCommand behavior.
        # Warnings remain visible. Red error stream is redirected to the log file.
        $Result = Invoke-ControlCommand `
            -SessionID $SessionID `
            -PowerShell `
            -Command $AutomateDiagnosticsCommand `
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
# ADD INVALID ROWS TO FINAL REPORT
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

$FinalResults = @($Results) + @($InvalidResults)

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
