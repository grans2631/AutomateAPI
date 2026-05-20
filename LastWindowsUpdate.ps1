# Pull all computer records
$computers = Get-AutomateComputer

# Filter: machines that checked in within the last 7 days AND have not had a Windows update in 30+ days
$filtered = $computers | Where-Object {
    $_.WindowsUpdateDate -and
    $_.RemoteAgentLastContact -and
    ([datetime]$_.RemoteAgentLastContact) -ge (Get-Date).AddDays(-7) -and
    ([datetime]$_.WindowsUpdateDate) -lt (Get-Date).AddDays(-90)
}

# Display selected properties in a clean table
$filtered |
    Select-Object `
        @{Name='Client'; Expression={
            if ($_.ClientName -and $_.ClientName.Name) {
                $_.ClientName.Name
            }
            elseif ($_.ClientName) {
                $_.ClientName
            }
            elseif ($_.Client) {
                $_.Client
            }
            else {
                'Unknown'
            }
        }},
        @{Name='ComputerName'; Expression={ $_.ComputerName }},
        @{Name='OSVersion'; Expression={ $_.OperatingSystemVersion }},
        @{Name='WindowsUpdateDate'; Expression={ $_.WindowsUpdateDate }},
        @{Name='RemoteAgentVersion'; Expression={ $_.RemoteAgentVersion }},
        @{Name='Type'; Expression={ $_.Type }},
        @{Name='RemoteAgentLastContact'; Expression={ $_.RemoteAgentLastContact }} |
    Sort-Object Client, ComputerName |
    Format-Table -AutoSize

$Results = $filtered |
    Select-Object `
        @{Name='Client'; Expression={
            if ($_.ClientName -and $_.ClientName.Name) {
                $_.ClientName.Name
            }
            elseif ($_.ClientName) {
                $_.ClientName
            }
            elseif ($_.Client) {
                $_.Client
            }
            else {
                'Unknown'
            }
        }},
        ComputerName,
        OperatingSystemVersion,
        WindowsUpdateDate,
        RemoteAgentVersion,
        Type,
        RemoteAgentLastContact |
    Sort-Object Client, ComputerName

$Results | Format-Table -AutoSize | Out-String -Width 300 | Write-Output
