$citrixServer = "CitrixServer"  # Server where Citrix cmdlets are running, typically the Citrix Director server
$profileServer = "ProfileServer" # FSLogix server that holds the volumes with the profiles

$volumeTypes = "profile","office"
$profileVolumes = "C:\*\*","D:\*\*","E:\*\*","F:\*\*","G:\*\*"
$officeVolumes = "H:\*\*","I:\*\*","J:\*\*","K:\*\*","L:\*\*"

# Setup Logging
$LOGGINGFILEPATH = ".\RedistributeProfiles-$(Get-Date -Format "yyyyMMddhhmmss").log"
. .\LogHelper.ps1

# Get all logged in users from Citrix

Write-LogEntry "Connecting to Citrix server [$citrixServer]"
$session = New-PSSession -ComputerName $citrixserver

Write-LogEntry "Get logged in Citrix Broker Users"
$citrixUsers = Invoke-Command -Session $session -ScriptBlock{
    Import-Module citrix.broker.commands
    Get-BrokerUser -MaxRecordCount 99999
}

Write-LogEntry "Disconnecting from Citrix server [$citrixServer]"
if ($session) { $session | Remove-PSSession }

Write-LogEntry "Found [$($citrixUsers.Count)] logged in users"

$volumeTypes | ForEach-Object{

    Write-LogEntry "Found volume type [$_]"

    # Get all folders from users that are not logged in

    $volumes = (Get-Variable -Name ("{0}Volumes" -f $_)).Value
    Write-LogEntry "Found volumes $($volumes | Out-String)"
    
    if ($profileServer -ne $env:COMPUTERNAME){
        Write-LogEntry "Connecting to profile server [$profileServer]"
        $session = New-PSSession -ComputerName $profileserver

        Write-LogEntry "Get folders from users that are not logged into Citrix"
        $excludedFolders = Invoke-Command -Session $session -ArgumentList ($volumes, $citrixUsers.Name) -ScriptBlock{
            param([array]$volumes,[array]$users)
            (Get-ChildItem -Path $volumes).Name | Where-Object { "GEMEENTEWWK\$($_.Split("_")[0])" -in $users }
        }
    
        Write-LogEntry "Disconnecting from profile server [$profileServer]"
        if ($session) { $session | Remove-PSSession }
    }
    else{
        Write-LogEntry "Get folders from users that are not logged into Citrix"
        $excludedFolders = (Get-ChildItem -Path $volumes).Name | Where-Object { "GEMEENTEWWK\$($_.Split("_")[0])" -in $citrixUsers.Name }
    }

    Write-LogEntry "Found [$($excludedFolders.Count)] folders to exclude"

    # Distribute volumes
    .\DistributeFolders.ps1 -Volumes $volumes -ComputerName $profileserver -ExcludedFolders $excludedFolders -LogFile $LOGGINGFILEPATH

}