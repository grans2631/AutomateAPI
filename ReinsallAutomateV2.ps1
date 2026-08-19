Install-Module AutomateAPI -Repository PSGallery

Import-Module AutomateAPI

Connect-AutomateAPI
#remember to use your CWA USERNAME AND PASSWORD

Connect-ControlAPI
#remember to create a user in ScreenConnect (no MFA)

Import-Module AutomateAPI -Force

# ============================================================
# CONFIGURATION
# ============================================================

# ScreenConnect / Control server, include https://
$ControlServer = "https://sc.ScreenConnect.com/"

# Automate server used by Reinstall-LTService, without https://
$AutomateServer = "lt.Automate.com"

# LocationID to use for reinstall.
# Since we are no longer looking up the Automate computer, this must be provided manually.
$LocationID = 471

# Hard-coded Automate installer token
$InstallerToken = "InstallerToken"

# Add one or more ScreenConnect SessionIDs here.
# Example:
# $SessionIDs = @(
#     "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
#     "ffffffff-1111-2222-3333-444444444444"
# )

$SessionIDs = @(
    "1401c788-6d12-46fb-b7ef-b25899d7f9db",
    "5708d4a8-e2fb-4163-9aff-9469770142a5",
    "62620c17-fc85-4345-8ab5-161dd49b4ac3",
    "47fce7d7-b3e2-4e2d-ab28-d7f63684d522",
    "cd90bc91-e574-4383-ba15-c5b53376dfa3",
    "d8b62dab-984a-4332-9c5c-73c3816aa461",
    "5de2b9dc-d4f5-438a-a788-fb7ec15cfc52",
    "5de2b9dc-d4f5-438a-a788-fb7ec15cfc52",
    "985f3598-0825-44d8-8c81-a92d89a79070",
    "6fd69ca4-d6c4-4d05-bb47-f495d5e7dc5d",
    "a31e2fd9-4bdb-4410-8033-098d416453bb"

)

# ============================================================
# VALIDATE CONFIGURATION
# ============================================================

if (-not $SessionIDs -or $SessionIDs.Count -eq 0) {
    throw "No SessionIDs were provided. Add one or more ScreenConnect SessionIDs to the `$SessionIDs array."
}

if (-not $LocationID) {
    throw "LocationID is required because this version no longer looks up the Automate computer."
}

if (-not $InstallerToken -or $InstallerToken -eq "YOUR-INSTALLER-TOKEN-HERE") {
    throw "InstallerToken is missing. Update `$InstallerToken before running."
}

# Normalize Automate server
$AutomateServer = $AutomateServer `
    -replace "^https://", "" `
    -replace "^http://", "" `
    -replace "/$", ""

# ============================================================
# PROMPT FOR SCREENCONNECT CREDENTIALS
# ============================================================

Write-Host ""
Write-Host "Enter your ScreenConnect / Control credentials." -ForegroundColor Cyan
$ControlCredential = Get-Credential -Message "ScreenConnect Username and Password"

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
    Write-Host ""
    Write-Host "Failed to connect to ScreenConnect / Control." -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Check the following:" -ForegroundColor Yellow
    Write-Host "1. Control server is correct: $ControlServer"
    Write-Host "2. The account is a local/internal ScreenConnect account."
    Write-Host "3. The account does not require MFA/SSO."
    Write-Host "4. The account has permission to access sessions and run commands."
    throw
}

# ============================================================
# BUILD REINSTALL COMMAND
# ============================================================

$ReinstallCommand = @"
echo "DIAGNOSTIC-RESPONSE/1"
echo "DiagnosticType: ReinstallAutomate"
echo "ContentType: json"
echo ""

`$WarningPreference='SilentlyContinue'

IF([Net.SecurityProtocolType]::Tls) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls
}

IF([Net.SecurityProtocolType]::Tls11) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls11
}

IF([Net.SecurityProtocolType]::Tls12) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

(new-object Net.WebClient).DownloadString('http://bit.ly/LTPoSh') | iex

Reinstall-LTService -SkipDotNet -Server https://$AutomateServer -LocationID $LocationID -InstallerToken $InstallerToken
"@

# ============================================================
# CONFIRM DETAILS BEFORE RUNNING
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "REINSTALL TARGETS"
Write-Host "============================================================"
Write-Host "Automate Server: https://$AutomateServer"
Write-Host "LocationID: $LocationID"
Write-Host "SessionID Count: $($SessionIDs.Count)"
Write-Host "============================================================"

Write-Host ""
Write-Host "ScreenConnect SessionIDs:" -ForegroundColor Cyan
$SessionIDs | ForEach-Object {
    Write-Host " - $_"
}

Write-Host ""
Write-Host "Command that will be sent to each ScreenConnect session:" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------"
Write-Host $ReinstallCommand
Write-Host "------------------------------------------------------------"

$Confirm = Read-Host -Prompt "Type YES to run the reinstall command against all listed SessionIDs"

if ($Confirm -ne "YES") {
    Write-Host "Cancelled. No command was run." -ForegroundColor Yellow
    return
}

# ============================================================
# RUN COMMAND THROUGH SCREENCONNECT
# ============================================================

$Results = foreach ($SessionID in $SessionIDs) {
    Write-Host ""
    Write-Host "Running Automate reinstall command against SessionID: $SessionID" -ForegroundColor Cyan

    try {
        $Result = Invoke-ControlCommand `
            -SessionID $SessionID `
            -PowerShell `
            -Command $ReinstallCommand `
            -TimeOut 600000 `
            -MaxLength 10000000

        [PSCustomObject]@{
            SessionID = $SessionID
            Status    = "Success"
            Output    = ($Result | Out-String).Trim()
            Error     = $null
        }
    }
    catch {
        [PSCustomObject]@{
            SessionID = $SessionID
            Status    = "Failed"
            Output    = $null
            Error     = $_.Exception.Message
        }
    }
}

# ============================================================
# OUTPUT RESULTS
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTS"
Write-Host "============================================================"

$Results | Format-Table SessionID, Status, Error -AutoSize

Write-Host ""
Write-Host "Detailed output:"
$Results | Format-List *
