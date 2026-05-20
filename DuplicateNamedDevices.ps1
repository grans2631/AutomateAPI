# ============================================================
# Automate Duplicate / Similar Computer Name Report
# All-clients, non-interactive credential version
# ============================================================

Import-Module AutomateAPI -ErrorAction Stop

# ============================================================
# CONFIGURATION
# ============================================================

$AutomateServer = "https://lt.360smartnet.com"

# Fill these in before running.
$AutomateUsername = "PowerTools_API"
$AutomatePasswordPlainText = 'h$4n"X!7Hu555n'

# Set this to $false if you only want exact/normalized duplicates.
$RunFuzzySimilarNameCheck = $true

# Fuzzy matching distance:
# 1 = very strict
# 2 = recommended
# 3 = looser / more false positives
$MaxDistance = 2

# Prevents runaway fuzzy comparison on large environments.
# Names with length differences greater than this are skipped.
$MaxNameLengthDifference = 2

# Optional: compare fuzzy names only within the same client.
# Recommended for large Automate environments to reduce false positives and speed up the script.
# Set to $false if you want fuzzy matching across all clients.
$FuzzyMatchOnlyWithinSameClient = $true

# Export location.
$Date = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ExportFolder = "C:\Temp\AutomateDuplicateNameReports"

$ExactExportPath      = Join-Path $ExportFolder "Automate-ExactDuplicateNames-AllClients-$Date.csv"
$NormalizedExportPath = Join-Path $ExportFolder "Automate-NormalizedDuplicateNames-AllClients-$Date.csv"
$SimilarExportPath    = Join-Path $ExportFolder "Automate-SimilarComputerNames-AllClients-$Date.csv"

New-Item -ItemType Directory -Path $ExportFolder -Force | Out-Null

# ============================================================
# CREDENTIAL / API CONNECTION
# ============================================================

$SecurePassword = ConvertTo-SecureString $AutomatePasswordPlainText -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($AutomateUsername, $SecurePassword)

Write-Output "Connecting to Automate API..."
Write-Output "Server: $AutomateServer"
Write-Output "Scope: All clients"
Write-Output ""

try {
    Connect-AutomateAPI -Server $AutomateServer -Credential $Credential -ErrorAction Stop
}
catch {
    Write-Warning "Connect-AutomateAPI -Server/-Credential failed. Trying -Username/-Password style..."

    try {
        Connect-AutomateAPI -Server $AutomateServer -Username $AutomateUsername -Password $AutomatePasswordPlainText -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to connect to Automate API."
        Write-Error "Your installed AutomateAPI module may use different parameters."
        Write-Error "Run this to confirm syntax: Get-Command Connect-AutomateAPI -Syntax"
        Write-Error $_.Exception.Message
        return
    }
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Normalize-ComputerName {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    # Uppercase and remove common separators/noise.
    return ($Name.ToUpper().Trim() -replace '[\s\-_\.]', '')
}

function Get-ClientIdFromComputer {
    param(
        [Parameter(Mandatory = $true)]
        $Computer
    )

    if ($Computer.PSObject.Properties.Name -contains 'ClientID') {
        return $Computer.ClientID
    }

    if ($Computer.PSObject.Properties.Name -contains 'ClientId') {
        return $Computer.ClientId
    }

    if ($Computer.PSObject.Properties.Name -contains 'Client') {
        if ($Computer.Client -and $Computer.Client.PSObject.Properties.Name -contains 'Id') {
            return $Computer.Client.Id
        }
    }

    return $null
}

function Get-LevenshteinDistance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$String1,

        [Parameter(Mandatory = $true)]
        [string]$String2
    )

    if ($String1 -eq $String2) {
        return 0
    }

    if ([string]::IsNullOrEmpty($String1)) {
        return $String2.Length
    }

    if ([string]::IsNullOrEmpty($String2)) {
        return $String1.Length
    }

    $Len1 = $String1.Length
    $Len2 = $String2.Length

    $Matrix = New-Object 'int[,]' ($Len1 + 1), ($Len2 + 1)

    for ($i = 0; $i -le $Len1; $i++) {
        $Matrix[$i, 0] = $i
    }

    for ($j = 0; $j -le $Len2; $j++) {
        $Matrix[0, $j] = $j
    }

    for ($i = 1; $i -le $Len1; $i++) {
        for ($j = 1; $j -le $Len2; $j++) {

            if ($String1[($i - 1)] -eq $String2[($j - 1)]) {
                $Cost = 0
            }
            else {
                $Cost = 1
            }

            # Parentheses around calculated indexes are required in PowerShell.
            $Deletion     = $Matrix[($i - 1), $j] + 1
            $Insertion    = $Matrix[$i, ($j - 1)] + 1
            $Substitution = $Matrix[($i - 1), ($j - 1)] + $Cost

            $Matrix[$i, $j] = [Math]::Min(
                [Math]::Min($Deletion, $Insertion),
                $Substitution
            )
        }
    }

    return $Matrix[$Len1, $Len2]
}

# ============================================================
# PULL COMPUTERS FOR ALL CLIENTS
# ============================================================

Write-Output "Getting all computers from Automate..."

try {
    $ComputersRaw = Get-AutomateComputer -ErrorAction Stop
}
catch {
    Write-Error "Failed to retrieve computers from Automate."
    Write-Error $_.Exception.Message
    return
}

$Computers = @(
    $ComputersRaw |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.ComputerName)
        } |
        ForEach-Object {
            [PSCustomObject]@{
                ClientName             = $_.ClientName
                LocationName           = $_.LocationName
                ComputerName           = $_.ComputerName
                ComputerID             = $_.ComputerID
                ClientID               = Get-ClientIdFromComputer -Computer $_
                Online                 = $_.Online
                RemoteAgentLastContact = $_.RemoteAgentLastContact
                NormalizedName         = Normalize-ComputerName -Name $_.ComputerName
            }
        }
)

Write-Output "Total computers returned: $($Computers.Count)"
Write-Output ""

if ($Computers.Count -eq 0) {
    Write-Warning "No computers were returned from Automate."
    return
}

# ============================================================
# EXACT DUPLICATE COMPUTER NAMES
# ============================================================

Write-Output "Checking exact duplicate computer names across all clients..."

$ExactDuplicates = @(
    $Computers |
        Group-Object ComputerName |
        Where-Object {
            $_.Count -gt 1 -and
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } |
        ForEach-Object {
            $DuplicateGroup = $_.Name
            $GroupCount = $_.Count

            $_.Group | ForEach-Object {
                [PSCustomObject]@{
                    DuplicateType          = "ExactComputerName"
                    DuplicateGroup         = $DuplicateGroup
                    GroupCount             = $GroupCount
                    ClientName             = $_.ClientName
                    ClientID               = $_.ClientID
                    LocationName           = $_.LocationName
                    ComputerName           = $_.ComputerName
                    NormalizedName         = $_.NormalizedName
                    ComputerID             = $_.ComputerID
                    Online                 = $_.Online
                    RemoteAgentLastContact = $_.RemoteAgentLastContact
                }
            }
        }
)

$ExactDuplicates |
    Sort-Object DuplicateGroup, ClientName, LocationName, ComputerName |
    Export-Csv $ExactExportPath -NoTypeInformation

# ============================================================
# NORMALIZED DUPLICATE COMPUTER NAMES
# Example: PC-123, PC_123, PC.123, pc123
# ============================================================

Write-Output "Checking normalized duplicate computer names across all clients..."

$NormalizedDuplicates = @(
    $Computers |
        Group-Object NormalizedName |
        Where-Object {
            $_.Count -gt 1 -and
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } |
        ForEach-Object {
            $DuplicateGroup = $_.Name
            $GroupCount = $_.Count

            $_.Group | ForEach-Object {
                [PSCustomObject]@{
                    DuplicateType          = "NormalizedComputerName"
                    DuplicateGroup         = $DuplicateGroup
                    GroupCount             = $GroupCount
                    ClientName             = $_.ClientName
                    ClientID               = $_.ClientID
                    LocationName           = $_.LocationName
                    ComputerName           = $_.ComputerName
                    NormalizedName         = $_.NormalizedName
                    ComputerID             = $_.ComputerID
                    Online                 = $_.Online
                    RemoteAgentLastContact = $_.RemoteAgentLastContact
                }
            }
        }
)

$NormalizedDuplicates |
    Sort-Object DuplicateGroup, ClientName, LocationName, ComputerName |
    Export-Csv $NormalizedExportPath -NoTypeInformation

# ============================================================
# FUZZY / VERY SIMILAR COMPUTER NAMES
# ============================================================

$SimilarResults = New-Object System.Collections.Generic.List[object]

if ($RunFuzzySimilarNameCheck) {

    Write-Output "Checking very similar computer names..."
    Write-Output "Max distance: $MaxDistance"
    Write-Output "Fuzzy match only within same client: $FuzzyMatchOnlyWithinSameClient"
    Write-Output "This may take a while on large environments."
    Write-Output ""

    $ComputerArray = @(
        $Computers |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.NormalizedName)
            } |
            Sort-Object ClientName, NormalizedName
    )

    for ($i = 0; $i -lt $ComputerArray.Count; $i++) {
        $A = $ComputerArray[$i]

        for ($j = ($i + 1); $j -lt $ComputerArray.Count; $j++) {
            $B = $ComputerArray[$j]

            if ($FuzzyMatchOnlyWithinSameClient) {
                if ($A.ClientID -and $B.ClientID) {
                    if ($A.ClientID -ne $B.ClientID) {
                        continue
                    }
                }
                elseif ($A.ClientName -ne $B.ClientName) {
                    continue
                }
            }

            # Skip exact normalized matches because they are already captured.
            if ($A.NormalizedName -eq $B.NormalizedName) {
                continue
            }

            # Skip names with very different lengths.
            if ([Math]::Abs($A.NormalizedName.Length - $B.NormalizedName.Length) -gt $MaxNameLengthDifference) {
                continue
            }

            # Quick prefix filter to avoid comparing unrelated names.
            $PrefixLength = [Math]::Min(3, [Math]::Min($A.NormalizedName.Length, $B.NormalizedName.Length))

            if ($PrefixLength -gt 0) {
                if ($A.NormalizedName.Substring(0, $PrefixLength) -ne $B.NormalizedName.Substring(0, $PrefixLength)) {
                    continue
                }
            }

            try {
                $Distance = Get-LevenshteinDistance -String1 $A.NormalizedName -String2 $B.NormalizedName
            }
            catch {
                # Avoid repeated red error spam.
                Write-Warning "Skipping comparison: $($A.ComputerName) vs $($B.ComputerName). Error: $($_.Exception.Message)"
                continue
            }

            if ($Distance -le $MaxDistance) {
                $SimilarResults.Add([PSCustomObject]@{
                    MatchType               = "VerySimilarName"
                    SimilarityDistance      = $Distance

                    ComputerNameA           = $A.ComputerName
                    NormalizedNameA         = $A.NormalizedName
                    ClientNameA             = $A.ClientName
                    ClientIDA               = $A.ClientID
                    LocationNameA           = $A.LocationName
                    ComputerIDA             = $A.ComputerID
                    OnlineA                 = $A.Online
                    RemoteAgentLastContactA = $A.RemoteAgentLastContact

                    ComputerNameB           = $B.ComputerName
                    NormalizedNameB         = $B.NormalizedName
                    ClientNameB             = $B.ClientName
                    ClientIDB               = $B.ClientID
                    LocationNameB           = $B.LocationName
                    ComputerIDB             = $B.ComputerID
                    OnlineB                 = $B.Online
                    RemoteAgentLastContactB = $B.RemoteAgentLastContact
                })
            }
        }
    }

    $SimilarResults |
        Sort-Object SimilarityDistance, ClientNameA, ComputerNameA, ComputerNameB |
        Export-Csv $SimilarExportPath -NoTypeInformation
}
else {
    Write-Output "Fuzzy similar name check skipped."
}

# ============================================================
# SUMMARY / PREVIEW
# ============================================================

Write-Output ""
Write-Output "===== Summary ====="
Write-Output "Scope checked: All clients"
Write-Output "Total Automate computers checked: $($Computers.Count)"
Write-Output "Exact duplicate rows exported: $($ExactDuplicates.Count)"
Write-Output "Normalized duplicate rows exported: $($NormalizedDuplicates.Count)"
Write-Output "Very similar name pairs exported: $($SimilarResults.Count)"
Write-Output ""
Write-Output "Exact duplicate report:"
Write-Output $ExactExportPath
Write-Output ""
Write-Output "Normalized duplicate report:"
Write-Output $NormalizedExportPath
Write-Output ""
Write-Output "Very similar computer name report:"
Write-Output $SimilarExportPath

Write-Output ""
Write-Output "===== Exact Duplicate Preview ====="

$ExactDuplicates |
    Sort-Object DuplicateGroup, ClientName, LocationName, ComputerName |
    Select-Object DuplicateGroup, GroupCount, ClientName, ClientID, LocationName, ComputerName, ComputerID, Online, RemoteAgentLastContact |
    Format-Table -AutoSize

Write-Output ""
Write-Output "===== Normalized Duplicate Preview ====="

$NormalizedDuplicates |
    Sort-Object DuplicateGroup, ClientName, LocationName, ComputerName |
    Select-Object DuplicateGroup, GroupCount, ClientName, ClientID, LocationName, ComputerName, ComputerID, Online, RemoteAgentLastContact |
    Format-Table -AutoSize

if ($RunFuzzySimilarNameCheck) {
    Write-Output ""
    Write-Output "===== Very Similar Name Preview ====="

    $SimilarResults |
        Sort-Object SimilarityDistance, ClientNameA, ComputerNameA, ComputerNameB |
        Select-Object SimilarityDistance, ComputerNameA, ComputerIDA, ClientNameA, ComputerNameB, ComputerIDB, ClientNameB |
        Format-Table -AutoSize
}
