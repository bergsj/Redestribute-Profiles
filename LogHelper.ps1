   <#
   .SYNOPSIS
    Simple log helper to write nicely to logfile
   .DESCRIPTION
    Simple log helper to write nicely to logfile.
   .NOTES
    Globally scoped variables can be used:
    - LOGGINGFILEPATH to configure LogPath
    - NOLOGGING to block logging
    - OVERRIDELOGGINGFILEPATH to override global LOGGINGFILEPATH

    ##  28-08-2017  v1.0.0: SVB: Initial script
    ##  10-11-2017  v1.0.1: SVB: Added variable DEBUG option, Renamed LOGGINGFILEPATH
    ##  16-11-2017  v1.0.2: SVB: Added variable OverrideLoggingFilePath to override global LOGGINGFILEPATH
    ##  20-04-2018  v1.0.3: SVB: Added variable LOGDEBUG
    ##  19-03-2019  v1.0.4: SVB: Added calling script
    ##  09-07-2019  v2.0.0: SVB: Added switch NoLogging to disable logging (for usage on GUI scripts)
   .EXAMPLE
    $LOGGINGFILEPATH = "c:\test\script.log"
    Write-LogEntry "Welcome to the world!" -Level Error
   #>

   function Write-LogEntry {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("LogContent")]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Error", "Warn", "Info", "Debug")]
        [string]$Level = "Info",
        
        [Parameter(Mandatory = $false)]
        [switch]$NoClobber
    )

    Begin {
        # Set VerbosePreference to Continue so that verbose messages are displayed.
        #$VerbosePreference = 'Continue'
        # Set LOGDEBUG to $true so that debug messages are displayed.
        $LOGDEBUG = $true
    }
    Process {
        
        if ($Global:NOLOGGING) { return }

        if ([string]::IsNullOrEmpty($LOGGINGFILEPATH) -and [string]::IsNullOrEmpty($OVERRIDELOGGINGFILEPATH)) { Write-Error "Global parameter 'LOGGINGFILEPATH' not set." }

        if ($LOGGINGFILEPATH) {
            # If the file already exists and NoClobber was specified, do not write to the log.
            if ((Test-Path $LOGGINGFILEPATH) -AND $NoClobber) {
                Write-Error "Log file $LOGGINGFILEPATH already exists, and you specified NoClobber. Either delete the file or specify a different name."
                Return
            }
            # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path.
            elseif (!(Test-Path $LOGGINGFILEPATH)) {
                Write-Verbose "Creating $LOGGINGFILEPATH."
                New-Item $LOGGINGFILEPATH -Force -ItemType File | Out-Null
            }
        }

        # Format Date for our Log File
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if (-not [string]::IsNullOrEmpty($OVERRIDELOGGINGFILEPATH)) { 
            $filepath = $OVERRIDELOGGINGFILEPATH
        }
        else {
            $filepath = $LOGGINGFILEPATH
        }

        $callstack = Get-PSCallStack
        $scriptname = $callstack[1].Location.Split(":")[0].Trim("ps1").Trim(".")

        # Write message to error, warning, or verbose pipeline and specify $LevelText
        switch ($Level) {
            'Error' {
                Write-Error $Message
                "$FormattedDate   ERROR [$scriptname] $Message" | Out-File -FilePath $filepath -Append
            }
            'Warn' {
                Write-Warning $Message
                "$FormattedDate WARNING [$scriptname] $Message" | Out-File -FilePath $filepath -Append
            }
            'Info' {
                #if ($ToScreen) { Write-Verbose $Message }
                "$FormattedDate    INFO [$scriptname] $Message" | Out-File -FilePath $filepath -Append
            }
            'Debug' {
                if ($LOGDEBUG) { "$FormattedDate   DEBUG [$scriptname] $Message" | Out-File -FilePath $filepath -Append }
            }
        }

    }
    End {
    }
}