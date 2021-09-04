<#
.SYNOPSIS
Powershell script module for interacting with a remote SAS server

.DESCRIPTION
This module provides Powershell functions for connecting to SAS server,
sending commands that are executed by the server, receiving SAS Log files
and List ouptut, and disconnecting from the SAS server. 

.NOTES
Functions provided by this module: 
- Connect-SAS      Open a connection to SAS server and start a session (can be only one) 
- Send-SASprogram  Send SAS Programs .sas file current session and create log and lst files
- Disconnect-SAS   Disconnect from SAS Server and close session
#>


#########################################################################################

# variable to keep track of the SAS session within the module
# this is Script scope which means that it is 'private' to this 
# module and cannot be accessed directly from outside.

# Note that there can only be one sas session open at a time (per user space)

$script:session = $null        # connection to SAS server object

#########################################################################################


function Connect-SAS {
<#
.SYNOPSIS
Establish a connection to the SAS server and start a session.

.DESCRIPTION
Return a SAS IOM workspace session object using the server name and
credentials that are supplied as parameters. Credentials will be
prompted for if they are not supplied in full.
When finished with the Workspace object, disconnect by calling the 
Disconnect-SAS function.

.INPUTS

None. You cannot pipe objects to Connect-SAS

.OUTPUTS

Workspace object - See SAS Integration Technologies documentation:

https://support.sas.com/rnd/itech/doc9/dev_guide/dist-obj/comdoc/autoca.html

.EXAMPLE 

Connect to SAs runing locally on developer workstation

PS> Connect-SAS -Local

<do stuff>

PS> Disconnect-SAS

.EXAMPLE 

Connect to SAS Academics EU server using Alice username (interactive password prompt)

PS> Connect-SAS -Credential alice
Password for user alice: ******

<do stuff>

PS> Disconnect-SAS


.EXAMPLE 

Connect to production SAS server, prompt user for all credentials

PS> Connect-SAS -server sasprod.company.com -credential (Get-Credentials)
PowerShell credential request
Enter your credentials.
User: bob
Password for user stuart: ****

<do stuff>

PS> Disconnect-SAS

.EXAMPLE

Connect to corporate SAS server using credentials supplied in variable

PS> $password = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
PS> $Cred = New-Object System.Management.Automation.PSCredential ("carol", $password)
PS> Connect-SAS -server sas.company.com -credential $Cred

<do stuff>

PS> Disconnect-SAS

.NOTES

For details on managing credentials in PowerShell see the following article:
https://docs.microsoft.com/en-us/powershell/scripting/learn/deep-dives/add-credentials-to-powershell-functions?view=powershell-7.1

#>

param (
  # (optional) name of the SAS server as text string e.g. sas9.server.com
  # Default value is EU SAS for Academics server odaws01-euw1.oda.sas.com
  [String]$server = "odaws01-euw1.oda.sas.com", 

  # (optional) a PSCredential object containing credentials for remote server
  # Can be full PSCredential object (username and password) or only username as
  # a string, in which case the password is prompted interactively.
  # If not supplied then username and password are prompted interactively.
  [ValidateNotNull()]
  [System.Management.Automation.PSCredential]
  [System.Management.Automation.Credential()]$credential = [System.Management.Automation.PSCredential]::Empty,

  # (optional) Connect to installation of SAS on local machine. No credentials required.
  [Parameter(mandatory=$False)]
  [Switch]$Local
) #param  

  # if we are connecting locally then setup the lite config
  if ($Local -eq $True) {
    #
    # this is a local connection, so dont need servername, credentials, etc. for COM protocol 
    #
    $server          = "127.0.0.1"
    $username        = ""
    $password        = ""
    $port            = 0
    $protocol        = 0   # 0 = COM protocol
    $ClassIdentifier = ""
  }
  else {
    #
    # this is a remote connection, so will need servername, credentials, etc. for IOM protocol 
    #

    # check if any form of credential passed in, if not prompt interactively
    if($credential -eq [System.Management.Automation.PSCredential]::Empty) {
      $credential = Get-Credential
    }

    # extract the username - this is done to make it compatible with local config
    $username = $credential.UserName

    # convert secure password to text string so that it can be passed to SAS Server
    # this is a bit of a code smell, would be nice to find a cleaner way to type cast!
    $BSTR     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
    $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    # define the remote port/protocol/etc
    $port     = 8591
    $protocol = 2     # 2 = IOM protocol
    $ClassIdentifier = "440196d4-90f0-11d0-9f41-00a024bb830c"
  }

#
# Use SAS Object Manager to create a ServerDef object that you use to connect to a 
# SAS Workspace. Connect to local or remote using protocol and params defined above
#
$objFactory = New-Object -ComObject SASObjectManager.ObjectFactoryMulti2
$objServerDef = New-Object -ComObject SASObjectManager.ServerDef 
$objServerDef.MachineDNSName  = $server
$objServerDef.Port            = $port
$objServerDef.Protocol        = $protocol
$objServerDef.ClassIdentifier = $ClassIdentifier

#
# With an instance of an ObjectFactory class and the ServerDef class, we can now 
# establish a connection to the server, which is returned to the caller
#
$script:session = $objFactory.CreateObjectByServer(
                  "SASApp",               # server name
                  $true,                  # Wait for connection before returning
                  $objServerDef,          # server definition for Workspace
                  $UserName,              # user ID
                  $password               # password
                  )

} #function sas-connect


#########################################################################################


function Read-SASLog {
  <#
  .SYNOPSIS
  Private module function to read the SAS log (return value)
  #>
  $log = ""
  $in = ""
  do {
    $in = $script:session.LanguageService.FlushLog(1000)
    if ($in.Length -gt 0) {$log += ("<log>" + $in + "</log>")}
  } while ($in.Length -gt 0)
  Return $log
}


#########################################################################################

function Read-SASList {
  <#
  .SYNOPSIS
  Private function to read the SAS LST (return value)#>
  $list = ""
  $in = ""
  do {
   $in = $script:session.LanguageService.FlushList(1000)
   if ($in.length -gt 0) { $list += $in}
  } while ($in.Length -gt 0)
  Return $list
}


#########################################################################################

function Write-SAS {
  <#
  .SYNOPSIS
  Write SAS code to server and return response object. Supports pipelines

  .DESCRIPTION
  Send SAS code to the SAS Server (using the session established with Connect-SAS)
  The (sas LOG and LST) responses are returned as a sas hash table object 
  This function supports pipeline input and output.

  .PARAMETER method
  (optional) defines the method used to create the output. Default is listorlog
  - listorlog  : output LST results if there are any, if not output the LOG
  - logandlist : output both, first the LOG then the LST are output
  - log        : only the log is output
  - list       : only the LST is output  
  #>
  param(
    [String]$method = "listorlog"
  )
  begin {
      # make sure the SAS session exists. If not, error and stop!
    if ($script:session -eq $null) {
      Write-Error -Message "No SAS session. Use Connect-SAS to start session." -ErrorAction Stop
    }
  }
  process {
    Write-Debug "Processing: $_"
    # submit the sas code
    $script:session.LanguageService.Submit($_)

    # read the log and lst responses from SAS server
    $log = Read-SASLog
    $list = Read-SASList

    # write ourput depending on the METHOD parameter
    switch ($method) 
    {
      listorlog
      {
        if ($list.length -gt 0) {
          Write-Output $list
        }
        else {
          if ($log.length -gt 0) { Write-Output $log }
        }
      }
      listandlog
      {
        if ($list.length -ne 0) {Write-Output $list}
        if ($log.length -ne 0) {Write-Output $log}
      }
      log
      {
        if ($log.length -ne 0) {Write-Output $log}
      }
      list
      {
        if ($list.length -ne 0) {Write-Output $list}
      }
    }
  }
}


#########################################################################################

function Send-SASprogram {
  <#
  .SYNOPSIS 
  Send a sas program file to SAS server write response to LOG and LST files 

  .DESCRIPTION
  Sends a SAS program file to a SAS server. This uses a SAS workspace object created using
  the Connect-SAS function. The SAS Log and List files that are returned from the SAS server
  are written to files with the same path/name as the program file, except with .log and .lst
  extensions.
  #>

  param(
    # (mandatory) File is the path and filename (inclusing extension) of the SAS program to run 
    [ValidateNotNull()]
    [string]$file
  )

  # make sure the SAS session exists. If not, error and stop!
  if ($script:session -eq $null) {
    Write-Error -Message "No SAS session. Use Connect-SAS to start session." -ErrorAction Stop
  }

  # make sure the SAS program file exists. If not, error and stop!
  if (!(Test-Path -path $file)) {
    write-error -message "SAS Program does not exist." -ErrorAction Stop
  }

  # create the output file name - log and lst file
  $logfilename = (get-item $file).DirectoryName+"/"+(get-item $file).BaseName+".log"
  $lstfilename = (get-item $file).DirectoryName+"/"+(get-item $file).BaseName+".lst"

  # create new output files - this will delete files if they already exist
  # this is done before the program is sent to the SAS server to make sure that
  # the log/lst files can be written to before we execute the SAS program
  New-Item $logfilename -ItemType file -Force
  New-Item $lstfilename -ItemType file -Force

  # write the sas program file one line at a time to SAS server
  Get-Content -Path $file | ForEach-Object {
    $script:session.LanguageService.Submit($_)
  }

  # flush the SAS log file
  $log = ""
  do {
    $log = $script:session.LanguageService.FlushLog(1000)
    Add-Content $logfilename -Value $log
  } while ($log.Length -gt 0)

  # flush the output  
  $list = ""
  do {
   $list = $script:session.LanguageService.FlushList(1000)
   Add-Content $lstfilename -Value $list
  } while ($list.Length -gt 0)

}


#########################################################################################


function Invoke-iSAS {
  <#
  .SYNOPSIS
  Invoke interactive SAS read-eval-print loop. Use EXIT to return to Powershell

  .DESCRIPTION
  This command invokes interactive SAS, where user commands read from the console
  are sent to the curent SAS session (established using the SAS-Connect function).
  The SAS Log and List output are displayer on the console.
  This allows the user to interact with SAS similar to NODMS mode on Unix.
  To return to Powershell, enter the command EXIT (not case sensitive)
  #>
  param (
    # (optional) String used as SAS user prompt. Default SAS
    [String]$prompt = "SAS",
    #     (optional) defines the method used to create the output. Default is listorlog
    #   - listorlog  : output LST results if there are any, if not output the LOG
    #   - logandlist : output both, first the LOG then the LST are output
    #   - log        : only the log is output
    #   - list       : only the LST is output  
    [String]$method = "listorlog"
  )
  # Start the REPL. Use BREAK statements to exit loop.
  while($true) {
    # READ input from user
    $in = Read-Host $prompt 

    # check if user wants to exit loop
    if ($in.Trim() -eq "EXIT") {Break}

    # EVAL the input by sending it to the SAS Server
    # the Write-Method will output the List/Log using method param
    $in | Write-SAS -method $method

  } until($True)

  # post-REPL code here:
  write-output "NOTE: Return to Powershell. SAS Session remains open. Use Disconnect-SAS to end."
}



#########################################################################################


function Disconnect-SAS {
  <#
  .SYNOPSIS
  Disconnect the connection to the SAS Workspace and end the session.
  #>

  if ($script:session -eq $null) {
    Write-Error -Message "Cannot disconnect - No SAS session" -ErrorAction Stop
  }
  $script:session.LanguageService.Close()
  $script:session = $null
}


# Define the things that this Script Module exports:
#########################################################################################

Export-ModuleMember -Function `
  Connect-SAS,                
  Send-SASprogram,            
  Write-SAS,                  
  Disconnect-SAS,             
  Invoke-iSAS

