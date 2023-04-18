<#
.SYNOPSIS
    Script to evenly distribute folders on volumes based on size
.DESCRIPTION
    This script will calculate the total and freespace of the volumes provided and will then calculate which folders to move in order to distribute them evenly across the volumes
.NOTES
    Author: Sjoerd van den Berg
.PARAMETER Volumes
    This parameter should provide the volumes (minimum of 2) to work with. This should be provided in the form of driveletters.
.PARAMETER ComputerName
    This optional parameter can provide a remote computer that holds the volumes.
.PARAMETER ExcludedFolders
    This optional parameter can provide folders that are excluded and should not be moved.
.EXAMPLE
    DistributeFolders.ps1 -Volumes "E:,F:"
.EXAMPLE    
    DistributeFolders.ps1 -Volumes "E:,F:" -ComputerName "FileServer"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string[]]
    $Volumes,
    [Parameter()]
    [string]
    $ComputerName,
    [Parameter()]
    [string[]]
    $ExcludedFolders,
    [Parameter()]
    [string]
    $LogFile
)

Start-Transcript -Path "$LogFile.pstransscript"

$LOGGINGFILEPATH = $LogFile

. .\LogHelper.ps1

if (([array]$Volumes).Count -eq 1){
    Write-LogEntry "Expecting at least 2 volumes" -Level Error
    Exit
}

Write-LogEntry "Volumes to measure: $volumes"
if ($ExcludedFolders){ Write-LogEntry "Folders to exclude [$($ExcludedFolders -join ",")]" }

if ($ComputerName -ne $env:COMPUTERNAME){
    Write-LogEntry "Connecting to computer: $ComputerName"
    #TODO: Provide Credentials
    $psSession = New-PSSession -ComputerName $ComputerName
    if ($psSession.State -eq "Opened") { 
        Write-LogEntry "Connected to computer: $ComputerName"
    }
    else{
        Write-LogEntry "Failed to connect to computer: $ComputerName" -Level Error
    }
}

# Get the total size and free space of each volume
$volumesInfo = @()
foreach ($volume in $volumes) {
    $drive = Split-Path $volume -Qualifier
    if ($psSession){
        $disk = Invoke-Command -Session $psSession -ArgumentList $drive -ScriptBlock { 
            Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$args'" }
        $filesize = Invoke-Command -Session $psSession -ArgumentList $drive -ScriptBlock{ 
            Get-ChildItem -Path $args -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum }

        #TODO; ugly way of supporting sub level. We need to have the subpath of the drive as a target to move the folders to
        # Only supports 1 folder in the root!
        if ($volume -match "\\*\\"){
            $subPath = Invoke-Command -Session $psSession -ArgumentList $drive -ScriptBlock{ 
            (Get-ChildItem -Path $args -Depth 0 -Directory).FullName }
        }
    }
    else{
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
        $filesize = Get-ChildItem -Path $drive -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum
        
        #TODO; ugly way of supporting sub level. We need to have the subpath of the drive as a target to move the folders to
        # Only supports 1 folder in the root!
        if ($volume -match "\\*\\"){
            $subPath = (Get-ChildItem -Path $drive -Depth 0 -Directory).FullName
        }        
    }
    
    $volumesInfo += [pscustomobject]@{
        Volume = $disk.DeviceID #TODO: rename Volume to Disk or Drive
        Path = $volume
        FreeSpace = [math]::Round($disk.FreeSpace, 2)
        FileSize = $filesize
        DistributionType = [string]::Empty
        DistributionSize = [string]::Empty
        SubPath = $subPath
    }
}

# Calculate the total size of all files in all volumes
$totalFileSize = $volumesInfo | Measure-Object -Sum FileSize | Select-Object -ExpandProperty Sum
Write-LogEntry "Total FileSize = $totalFileSize"

# Calculate the ideal size for each volume based on the average free space
$idealVolumeSize = [math]::Round($totalFileSize / $volumesInfo.Count,2)
Write-LogEntry "Ideal Volume Size = $idealVolumeSize"

# Distribute the filesize evenly amongst the volumes
foreach ($volumeInfo in $volumesInfo) {
   
    if ($volumeInfo.FileSize -ge $idealVolumeSize) {
        $distributionSize = $($volumeInfo.FileSize - $idealVolumeSize)
        Write-LogEntry "[Volume $($volumeInfo.Volume)] Move $distributionSize [$($volumeInfo.FileSize/1GB) - $($idealVolumeSize/1GB)] of data TO another volume"
        $volumeInfo.DistributionType = "Out"
        $volumeInfo.DistributionSize = $distributionSize
    }
    else{
        $distributionSize = $($idealVolumeSize - $volumeInfo.FileSize)
        Write-LogEntry "[Volume $($volumeInfo.Volume)] Move $distributionSize [$($idealVolumeSize/1GB) - $($volumeInfo.FileSize/1GB)] of data FROM another volume"
        $volumeInfo.DistributionType = "In"
        $volumeInfo.DistributionSize = $distributionSize
    }
}
Write-LogEntry "VolumeInfo:"
Write-LogEntry ($volumesInfo | Out-String)

foreach ($volumeInfoOut in ($volumesInfo | Where-Object DistributionType -eq "Out")) {

    Write-LogEntry "Size to move out of volume [$($volumeInfoOut.Volume)]: $($volumeInfoOut.DistributionSize)"   

    if ($psSession){
        $allOutFolders = Invoke-Command -Session $psSession -ArgumentList $volumeInfoOut.Path -ScriptBlock {
            Get-ChildItem -Path $args -Directory | Select-Object FullName, Name, @{Name = 'Size'; Expression = {
                [int64](Get-ChildItem -Path $_.FullName -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum)}} `
            | Sort-Object Size -Descending
        }
    }
    else{
        $allOutFolders = Get-ChildItem -Path $volumeInfoOut.Path -Directory | Select-Object FullName, Name, @{Name = 'Size'; Expression = {
                            [int64](Get-ChildItem -Path $_.FullName -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum)}} `
                        | Sort-Object Size -Descending
    }
    if ($null -eq $allOutFolders) { 
        Write-LogEntry "No folders detected, skipping" -Level Warn
        continue 
    }

    Write-LogEntry "All folders on volume [$($volumeInfoOut.Volume)]:"
    Write-LogEntry ($allOutFolders.FullName -join ";")

    $remainingDistributionSizeOut = $volumeInfoOut.DistributionSize
    $foldersToMove = @()


    foreach ($folder in $allOutFolders){
        if (($folder.Size -le $remainingDistributionSizeOut) -and ($folder.Name -notin $ExcludedFolders)){
            $foldersToMove += $folder
            $remainingDistributionSizeOut -= $folder.Size
        }
    }

    if ($foldersToMove.Count -eq 0) {
        Write-LogEntry "No folders to move, skipping" -Level Warn
        continue 
    }
    
    Write-LogEntry "All folders to move out off volume [$($volumeInfoOut.Volume)]:"
    Write-LogEntry ($foldersToMove.FullName -join ";")
    
    $foldersToMove | Add-Member -MemberType NoteProperty -Name "Moved" -Value $false
    
    foreach ($volumeInfoIn in ($volumesInfo | Where-Object DistributionType -eq "In")) {
        
        $remainingDistributionSizeIn = $volumeInfoIn.DistributionSize

        foreach ($folder in ($foldersToMove | Where-Object Moved -eq $false)){
            
            if ($folder.Size -le $remainingDistributionSizeIn){
                

                Write-LogEntry "Moving folder [$($folder.FullName)] to [$($volumeInfoIn.SubPath)]"
                Write-Host "Moving folder [$($folder.FullName)] to [$($volumeInfoIn.SubPath)]" -ForegroundColor Cyan
                if ($psSession){
                    $log = Invoke-Command -Session $psSession -ArgumentList $folder.FullName,$volumeInfoIn.SubPath -ScriptBlock {

                        $originalFolder = $args[0]
                        $targetFolder = (Join-Path $args[1] (Split-Path $originalFolder -Leaf))
                        $targetFolderRoot = $args[1]
                        
                        $arguments = ("`"{0}`" `"{1}`" /COPYALL /R:0 /W:0 /NP /V" -f $originalFolder, $targetFolder)
                        Write-Output ("Starting process: [{0}]" -f ("{0}\System32\robocopy.exe {1}" -f $env:SystemRoot, $arguments))
                        $s = Start-Process -FilePath ("{0}\System32\robocopy.exe" -f $env:SystemRoot) -ArgumentList $arguments -PassThru -Wait
                        if ($s -eq $null -or $s.ExitCode -gt 7){
	                        Write-Error ("Robocopy returned error [{0}]. Please check log!" -f $s.ExitCode)
	                        Exit
                        }
                        Write-Output "Calculating folder sizes"
                        $originalSize = (Get-ChildItem -Path $originalFolder -Recurse | Measure-Object -Sum -Property Length).Sum
                        $targetSize = (Get-ChildItem -Path $targetFolder -Recurse | Measure-Object -Sum -Property Length).Sum
                        if ($originalSize -eq $targetSize){
                            Write-Output "Original [$originalFolder / $originalSize] and target [$targetFolder / $targetSize] folder are same size, removing original folder."
                            Remove-Item -Path $originalFolder -Recurse -Force
                        }                                               
                    }
                    Write-LogEntry ($log | Out-String)
                }
                else{

                    $originalFolder = $folder.FullName
                    $targetFolder = (Join-Path  $volumeInfoIn.SubPath (Split-Path $originalFolder -Leaf))
                    $targetFolderRoot =  $volumeInfoIn.SubPath

                    $arguments = ("`"{0}`" `"{1}`" /COPYALL /R:0 /W:0 /NP /V /LOG+:$LOGGINGFILEPATH" -f $originalFolder, $targetFolder)
                    Write-LogEntry ("Starting process: [{0}]" -f ("{0}\System32\robocopy.exe {1}" -f $env:SystemRoot, $arguments))
                    $s = Start-Process -FilePath ("{0}\System32\robocopy.exe" -f $env:SystemRoot) -ArgumentList $arguments -PassThru -Wait
                    if ($s -eq $null -or $s.ExitCode -gt 7){
	                    Write-Error ("Robocopy returned error [{0}]. Please check log!" -f $s.ExitCode)
	                    Exit
                    }
                    Write-LogEntry "Calculating folder sizes"
                    $originalSize = (Get-ChildItem -Path $originalFolder -Recurse | Measure-Object -Sum -Property Length).Sum
                    $targetSize = (Get-ChildItem -Path $targetFolder -Recurse | Measure-Object -Sum -Property Length).Sum
                    if ($originalSize -eq $targetSize){
                        Write-LogEntry "Original [$originalFolder / $originalSize] and target [$targetFolder / $targetSize] folder are same size, removing original folder."
                        Remove-Item -Path $originalFolder -Recurse -Force
                    }

                }

                $remainingDistributionSizeIn -= $folder.Size
                $folder.Moved = $true
                Write-LogEntry "remainingDistributionSizeIn = $($remainingDistributionSizeIn)"


            }

        }

    }

}

# Get the total size and free space of each volume
$volumeInfo = foreach ($volume in $volumes) {
    $drive = Split-Path $volume -Qualifier
    if ($psSession){
        $disk = Invoke-Command -Session $psSession -ArgumentList $drive -ScriptBlock { 
            Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$args'" }
        $filesize = Invoke-Command -Session $psSession -ArgumentList $drive -ScriptBlock{ 
            Get-ChildItem -Path $args -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum }
    }
    else{
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'"
        $filesize = Get-ChildItem -Path $drive -Recurse -File | Measure-Object -Sum Length | Select-Object -ExpandProperty Sum
    }
    [pscustomobject]@{
        Volume = $disk.DeviceID
        FreeSpace = [math]::Round($disk.FreeSpace, 2)
        FileSize = $filesize
    }
}

Write-LogEntry ($volumeInfo | Out-String)

if ($psSession){ 
    Write-LogEntry "Disconnecting from [$ComputerName]"
    $psSession | Remove-PSSession 
}

Stop-Transcript