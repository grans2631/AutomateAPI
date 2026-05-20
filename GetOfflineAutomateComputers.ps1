Import-Module AutomateAPI -Force

# ============================================================
# STATIC INPUTS / CONFIGURATION
# ============================================================

$Date = Get-Date -Format "yyyy-MM-dd-HHmmss"

# Automate API settings
# Use Automate user that does NOT require MFA.
$AutomateServer   = "lt.360smartnet.com"
$AutomateClientID = "d0a6cb5a-621b-4f2c-837b-a9ab1e32e1c5"
$AutomateUsername = "PowerTools_API"
$AutomatePassword = 'h$4n"X!7Hu555n'

# ScreenConnect / Control settings
$ControlServer   = "https://scrcon.360smartnet.com/"
$ControlUsername = "rewst_api"
$ControlPassword = "-Tx#U[3<pVVP,=uQ"

# Export settings
$ExportFolder = "C:\Temp\AutomateAgentCleanup"
$ExportPath   = "$ExportFolder\Offline-Control-Status-$Date.csv"

# Add computer names to exclude here
$ExcludedComputerNames = @(
    "DESKTOP-OA524BV"
)

# Add ScreenConnect SessionIDs to exclude here
$ExcludedSessionIDs = @(
    "efb1591b-1326-4f5e-9dbf-566c25baf814"
)

# ============================================================
# NORMALIZE VALUES
# ============================================================

$AutomateServer = $AutomateServer `
    -replace "^https://", "" `
    -replace "^http://", "" `
    -replace "/cwa/api/v1/?$", "" `
    -replace "/$", ""

$ControlServer = $ControlServer.TrimEnd("/")

# Convert plain text passwords to SecureString for PSCredential
$AutomatePasswordSecure = ConvertTo-SecureString $AutomatePassword -AsPlainText -Force
$AutomateCredential = New-Object System.Management.Automation.PSCredential (
    $AutomateUsername,
    $AutomatePasswordSecure
)

$ControlPasswordSecure = ConvertTo-SecureString $ControlPassword -AsPlainText -Force
$ControlCredential = New-Object System.Management.Automation.PSCredential (
    $ControlUsername,
    $ControlPasswordSecure
)

# Normalize exclusions
$ExcludedComputerNames = $ExcludedComputerNames |
    ForEach-Object { "$_".Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique

$ExcludedSessionIDs = $ExcludedSessionIDs |
    ForEach-Object { $_ -split "," } |
    ForEach-Object { "$_".Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique

# ============================================================
# VALIDATE / PREP
# ============================================================

if (-not (Test-Path $ExportFolder)) {
    New-Item -Path $ExportFolder -ItemType Directory -Force | Out-Null
}

if (-not $AutomateServer) {
    throw "AutomateServer is missing."
}

if (-not $AutomateClientID) {
    throw "AutomateClientID is missing."
}

if (-not $AutomateUsername -or -not $AutomatePassword) {
    throw "Automate username or password is missing."
}

if (-not $ControlServer) {
    throw "ControlServer is missing."
}

if (-not $ControlUsername -or -not $ControlPassword) {
    throw "Control username or password is missing."
}

# ============================================================
# CONNECT TO AUTOMATE API
# ============================================================

Write-Host ""
Write-Host "Connecting to Automate API..." -ForegroundColor Cyan

try {
    $AutomateConnected = Connect-AutomateAPI `
        -Server $AutomateServer `
        -Credential $AutomateCredential `
        -ClientID $AutomateClientID `
        -Force `
        -Quiet

    if (-not $AutomateConnected) {
        throw "Connect-AutomateAPI did not return a successful connection."
    }

    Write-Host "Connected to Automate API successfully." -ForegroundColor Green
}
catch {
    throw "Failed to connect to Automate API. $($_.Exception.Message)"
}

# ============================================================
# CONNECT TO SCREENCONNECT / CONTROL
# ============================================================

Write-Host ""
Write-Host "Connecting to ScreenConnect / Control..." -ForegroundColor Cyan

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
# GET OFFLINE WINDOWS MACHINES WITH CONTROL SESSION INFO
# ============================================================

Write-Host ""
Write-Host "Collecting offline Windows Automate machines and matching Control status..." -ForegroundColor Cyan

$Results = Get-AutomateComputer -Online $False |
    Where-Object {
        # Keep only Windows machines
        $_.OperatingSystem -match "Windows" -or
        $_.OS -match "Windows" -or
        $_.OperatingSystemName -match "Windows"
    } |
    Where-Object {
        # Exclude by Automate computer name
        $ExcludedComputerNames -notcontains $_.ComputerName
    } |
    Select-Object *,
        @{Name='AutomateLocationID';Expression={$_.Location.Id}} |
    Compare-AutomateControlStatus |
    Where-Object {
        # Exclude by ScreenConnect SessionID
        $ExcludedSessionIDs -notcontains $_.SessionID
    } |
    Select-Object `
        ComputerName,
        SessionID,
        @{Name='LocationID';Expression={$_.AutomateLocationID}} |
    Sort-Object ComputerName

# ============================================================
# EXPORT RESULTS
# ============================================================

$Results |
    Export-Csv $ExportPath -NoTypeInformation

Write-Host ""
Write-Host "Export complete:" -ForegroundColor Green
Write-Host $ExportPath

Write-Host ""
$Results | Format-Table -AutoSize
