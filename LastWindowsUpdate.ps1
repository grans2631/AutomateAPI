function Get-AutomateClientName {
    param($Computer)

    if ($Computer.ClientName -and
        $Computer.ClientName.PSObject.Properties['Name'] -and
        $Computer.ClientName.Name) {

        return $Computer.ClientName.Name
    }

    if ($Computer.Client -and
        $Computer.Client.PSObject.Properties['Name'] -and
        $Computer.Client.Name) {

        return $Computer.Client.Name
    }

    if ($Computer.ClientName -match 'Name=([^;}]+)') {
        return $Matches[1].Trim()
    }

    if ($Computer.Client -match 'Name=([^;}]+)') {
        return $Matches[1].Trim()
    }

    return 'Unknown'
}


# Pull all computer records
$computers = Get-AutomateComputer


# Machines checked in within the last 7 days
# AND Windows Update older than 90 days
$filtered = $computers | Where-Object {

    $_.WindowsUpdateDate -and
    $_.RemoteAgentLastContact -and

    ([datetime]$_.RemoteAgentLastContact) -ge (Get-Date).AddDays(-7) -and

    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-90)
}


# Build clean results
$Results = $filtered |
    Select-Object `
        @{Name='Client'; Expression={
            Get-AutomateClientName -Computer $_
        }},
        ComputerName,
        @{Name='OSVersion'; Expression={
            $_.OperatingSystemVersion
        }},
        WindowsUpdateDate,
        RemoteAgentVersion,
        Type,
        RemoteAgentLastContact |
    Sort-Object Client, ComputerName


# Display
$Results |
    Format-Table -AutoSize |
    Out-String -Width 300 |
    Write-Output
