Import-Module AutomateAPI -Force

# ============================================================
# CONFIGURATION
# ============================================================

$ControlServer = "https://Screenconnect.com"

$AutomateClientID = "ClientID"

# Computer name to search for in both Automate and ScreenConnect
$ComputerName = Read-Host -Prompt "Enter computer name to search"

# ============================================================
# AUTOMATE SERVER + API ENDPOINT TEST
# ============================================================

$AutomateServer = Read-Host -Prompt "Enter Automate server host only, example lt.360smartnet.com"

$AutomateServer = $AutomateServer `
    -replace "^https://", "" `
    -replace "^http://", "" `
    -replace "/cwa/api/v1/?$", "" `
    -replace "/$", ""

$AutomateApiTokenUrl = "https://$AutomateServer/cwa/api/v1/apitoken"

Write-Host ""
Write-Host "Testing Automate API endpoint:" -ForegroundColor Cyan
Write-Host $AutomateApiTokenUrl

try {
    $TestHeaders = @{
        "clientid"     = $AutomateClientID
        "Content-Type" = "application/json"
    }

    $TestBody = @{
        username = "endpoint-test"
        password = "endpoint-test"
    } | ConvertTo-Json

    Invoke-WebRequest `
        -Uri $AutomateApiTokenUrl `
        -Method POST `
        -Headers $TestHeaders `
        -Body $TestBody `
        -UseBasicParsing `
        -ErrorAction Stop | Out-Null

    Write-Host "Automate API endpoint responded successfully." -ForegroundColor Green
}
catch {
    $StatusCode = $null

    if ($_.Exception.Response) {
        $StatusCode = $_.Exception.Response.StatusCode.value__
    }

    if ($StatusCode -eq 401 -or $StatusCode -eq 400 -or $StatusCode -eq 403) {
        Write-Host "Automate API endpoint exists. Authentication test failed as expected with status $StatusCode." -ForegroundColor Green
    }
    elseif ($StatusCode -eq 404) {
        Write-Host ""
        Write-Host "Automate API endpoint was not found." -ForegroundColor Red
        Write-Host "Tested URL: $AutomateApiTokenUrl"
        throw
    }
    else {
        Write-Host ""
        Write-Host "Unexpected response while testing Automate API endpoint." -ForegroundColor Red
        Write-Host "Status code: $StatusCode"
        Write-Host "Error: $($_.Exception.Message)"
        throw
    }
}

# ============================================================
# PROMPT FOR AUTOMATE CREDENTIALS + MFA
# ============================================================

Write-Host ""
Write-Host "Enter your ConnectWise Automate API credentials." -ForegroundColor Cyan
$AutomateCredential = Get-Credential -Message "Automate API Username and Password"

Write-Host ""
$AutomateMFAToken = Read-Host -Prompt "Enter Automate MFA / 2FA code"

# ============================================================
# CONNECT TO AUTOMATE API
# ============================================================

Write-Host ""
Write-Host "Connecting to Automate API..." -ForegroundColor Cyan

try {
    Connect-AutomateAPI `
        -Server $AutomateServer `
        -Credential $AutomateCredential `
        -TwoFactorToken $AutomateMFAToken `
        -ClientID $AutomateClientID `
        -Force

    Write-Host "Connected to Automate API successfully." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Failed to connect to Automate API." -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

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
    throw
}

# ============================================================
# FIND COMPUTER IN AUTOMATE
# ============================================================

Write-Host ""
Write-Host "Searching Automate for computer: $ComputerName" -ForegroundColor Cyan

$AutomateMatches = @()

try {
    $AutomateMatches = @(Get-AutomateComputer -ComputerName $ComputerName)
}
catch {
    Write-Warning "Automate computer lookup failed. $($_.Exception.Message)"
}

$AutomateResult = $null

if (-not $AutomateMatches -or $AutomateMatches.Count -eq 0) {
    Write-Warning "No Automate computer found for $ComputerName."
}
elseif ($AutomateMatches.Count -gt 1) {
    Write-Host ""
    Write-Host "Multiple Automate computers matched. Showing results:" -ForegroundColor Yellow

    $AutomateMatches |
        Select-Object `
            @{n='AutomateComputerName';e={$_.ComputerName}},
            @{n='AutomateAgentID';e={$_.ComputerID}},
            @{n='Client';e={$_.Client.Name}},
            @{n='Location';e={$_.Location.Name}},
            @{n='LocationID';e={$_.Location.Id}} |
        Format-Table -AutoSize

    $AutomateResult = $AutomateMatches | Where-Object {
        $_.ComputerName -eq $ComputerName
    } | Select-Object -First 1

    if (-not $AutomateResult) {
        $AutomateResult = $AutomateMatches | Select-Object -First 1
    }
}
else {
    $AutomateResult = $AutomateMatches[0]
}

# ============================================================
# FIND COMPUTER IN SCREENCONNECT
# ============================================================

Write-Host ""
Write-Host "Searching ScreenConnect for computer: $ComputerName" -ForegroundColor Cyan

$ControlSessions = @()
$ScreenConnectMatches = @()

try {
    # Some AutomateAPI versions use Get-ControlSession.
    # Other examples/reference paths mention Get-ControlSessions.
    # Try both.
    try {
        $ControlSessions = @(Get-ControlSession)
    }
    catch {
        Write-Warning "Get-ControlSession failed. Trying Get-ControlSessions. $($_.Exception.Message)"
        $ControlSessions = @(Get-ControlSessions)
    }

    if (-not $ControlSessions -or $ControlSessions.Count -eq 0) {
        throw "No ScreenConnect sessions returned."
    }

    Write-Host "Total ScreenConnect sessions returned: $($ControlSessions.Count)" -ForegroundColor DarkCyan

    # Write raw debug file so we can inspect the actual object shape.
    $DebugPath = Join-Path $env:TEMP "ScreenConnectSessions_Debug.json"

    $ControlSessions |
        ConvertTo-Json -Depth 25 |
        Out-File -FilePath $DebugPath -Encoding UTF8

    Write-Host "Raw ScreenConnect session dump written to: $DebugPath" -ForegroundColor Yellow

    # Search the entire JSON object for the computer name.
    # This catches nested fields like GuestInfo.MachineName, Name, Host, CustomProperties, etc.
    $ScreenConnectMatches = @(
        foreach ($Session in $ControlSessions) {
            $SessionJson = $Session | ConvertTo-Json -Depth 25 -Compress

            if ($SessionJson -match [regex]::Escape($ComputerName)) {
                $Session
            }
        }
    )

    if (-not $ScreenConnectMatches -or $ScreenConnectMatches.Count -eq 0) {
        Write-Warning "No ScreenConnect session object contained the exact name $ComputerName."

        Write-Host ""
        Write-Host "Showing first 3 raw session objects to help identify available fields:" -ForegroundColor Yellow

        $ControlSessions |
            Select-Object -First 3 |
            Format-List *
    }
}
catch {
    Write-Warning "ScreenConnect lookup failed. $($_.Exception.Message)"
}

# ============================================================
# NORMALIZE SCREENCONNECT MATCH OUTPUT
# ============================================================

function Get-SessionIdFromObject {
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    if ($Session.SessionID) {
        return $Session.SessionID
    }

    if ($Session.SessionId) {
        return $Session.SessionId
    }

    if ($Session.Id) {
        return $Session.Id
    }

    if ($Session.SessionID.Guid) {
        return $Session.SessionID.Guid
    }

    if ($Session.SessionId.Guid) {
        return $Session.SessionId.Guid
    }

    return $null
}

function Get-ComputerNameFromControlObject {
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    $PossibleNames = @(
        $Session.Name
        $Session.GuestMachineName
        $Session.GuestName
        $Session.GuestInfo.MachineName
        $Session.GuestInfo.Name
        $Session.Host
        $Session.CustomProperty1
        $Session.CustomProperty2
        $Session.CustomProperty3
        $Session.CustomProperty4
        $Session.CustomProperty5
        $Session.CustomProperty6
        $Session.CustomProperty7
        $Session.CustomProperty8
    )

    $BestName = $PossibleNames |
        Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 } |
        Select-Object -First 1

    if ($BestName) {
        return $BestName.ToString()
    }

    return $null
}

$ScreenConnectResultRows = @()

foreach ($SCMatch in $ScreenConnectMatches) {
    $ScreenConnectResultRows += [PSCustomObject]@{
        ScreenConnectComputerName = Get-ComputerNameFromControlObject -Session $SCMatch
        ScreenConnectSessionID    = Get-SessionIdFromObject -Session $SCMatch
        RawScreenConnectObject    = $SCMatch
    }
}

# ============================================================
# FINAL OUTPUT
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "MATCH RESULTS"
Write-Host "============================================================"

if ($AutomateResult) {
    $AutomateComputerName = $AutomateResult.ComputerName
    $AutomateAgentID      = $AutomateResult.ComputerID
    $AutomateClient       = $AutomateResult.Client.Name
    $AutomateLocation     = $AutomateResult.Location.Name
    $AutomateLocationID   = $AutomateResult.Location.Id
}
else {
    $AutomateComputerName = $null
    $AutomateAgentID      = $null
    $AutomateClient       = $null
    $AutomateLocation     = $null
    $AutomateLocationID   = $null
}

if ($ScreenConnectResultRows.Count -eq 0) {
    [PSCustomObject]@{
        SearchName                  = $ComputerName
        AutomateComputerName         = $AutomateComputerName
        AutomateAgentID              = $AutomateAgentID
        AutomateClient               = $AutomateClient
        AutomateLocation             = $AutomateLocation
        AutomateLocationID           = $AutomateLocationID
        ScreenConnectComputerName    = $null
        ScreenConnectSessionID       = $null
        MatchStatus                  = "Automate found: $([bool]$AutomateResult); ScreenConnect found: False"
    } | Format-List *
}
else {
    foreach ($SCRow in $ScreenConnectResultRows) {
        [PSCustomObject]@{
            SearchName                  = $ComputerName
            AutomateComputerName         = $AutomateComputerName
            AutomateAgentID              = $AutomateAgentID
            AutomateClient               = $AutomateClient
            AutomateLocation             = $AutomateLocation
            AutomateLocationID           = $AutomateLocationID
            ScreenConnectComputerName    = $SCRow.ScreenConnectComputerName
            ScreenConnectSessionID       = $SCRow.ScreenConnectSessionID
            MatchStatus                  = "Automate found: $([bool]$AutomateResult); ScreenConnect found: True"
        } | Format-List *
    }
}

Write-Host ""
Write-Host "If ScreenConnectComputerName is blank but ScreenConnectSessionID is present, inspect this file:" -ForegroundColor Yellow
Write-Host "$env:TEMP\ScreenConnectSessions_Debug.json"
