
function Start-BuildPackerTemplate {

    <# 

    .SYNOPSIS
        Automation Script to select the appropriate template and combination of variables for packer builds. 
        Diego Perez - @darkquassar - 2017
        
    .DESCRIPTION
        This function will abstract another layer of the whole build process by choosing a packer template based on the options specified when calling it.
        Use the parameters to alter the template pathway, for example by choosing a "vmware" platform for a "linux" ostype from an "iso" source. When overloading a particular variable, from the ones found inside "variables.json", make sure to include the "-var" switch plus the variable(s) inside quotations marks like so: "-var install_windowsupdates=True -var install_sysinternals=False".
        
        NOTE: By default, the "variables.json" file points to empty values for "iso_url", "iso_checksum" and "iso_checksum_type". These are overloaded by the current script when selecting a particular platform
    
    .EXAMPLE 1
        Build a Windows 2012 R2 from an ISO for VMWare, using the defaults (ISO file will be downloaded from the internet) and other variables coded in "variables.json"
        
        Build-Template -Platform vmware -OSType windows -OSName Win2012R2 -VMSource iso
        
    .EXAMPLE 2
        Build a Windows 7 VM from an ISO for VMWare specifying the location of the ISO and associated paramaters.

        Build-Template -Platform vmware -OSType windows -OSName Win7 -VMSource iso -Variables '-var iso_url=C:/D13g0/VirtualMachines/ISO/7600.16385.090713-1255_x64fre_enterprise_en-us_EVAL_Eval_Enterprise-GRMCENXEVAL_EN_DVD.iso -var iso_checksum_type=sha256 -var iso_checksum=B202E27008FD2553F226C0F3DE4DD042E4BB7AE93CFC5B255BB23DC228A1B88E -var output_directory=P:/vmware-win7-test -var install_windowsupdates=True -var install_openssh=False -var install_firefox=False -var install_chrome=False'
    
    .EXAMPLE 3
        Build a Windows 2012 R2 from a VMWare VMX (existing VM machine) and install Windows Updates plus FLAREVM tools but no openssh. Specify a different output folder (output_directory) and explicitly select the source folder (source_path).

        Build-Template -Platform vmware -OSType windows -OSName Win2012R2 -VMSource vmx -Variables '-var source_path=./output-vmware-iso/packer-vmware-iso.vmx -var output_directory=P:/vmware-vmx-test -var install_windowsupdates=True -var install_flarevm=True -var install_openssh=False'
        
    .EXAMPLE
        asdf
        
        
    #>

    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateSet("vbox", "vmware", "vagrant")]
        [string]$Platform,
        [Parameter(Mandatory=$false,Position=1)]
        [ValidateSet("linux", "windows")]
        [string]$OSType = "windows",
        [Parameter(Mandatory=$true,Position=2)]
        [ValidateSet("Win2012R2", "Win2016StdCore", "Win10", "Win7", "UbuntuXenial")]
        [string]$OSName,
        [Parameter(Mandatory=$true,Position=3)]
        [ValidateSet("iso", "vmx")]
        [string]$VMSource,
        [Parameter(Mandatory=$false,Position=4)]
        [string]$Variables,
        [Parameter(Mandatory=$false,Position=5)]
        [string]$TemplatesPath = ".\templates",
        [Parameter(Mandatory=$false,Position=6)]
        [System.Collections.Generic.List]$ProvisioningSequence,
        [Parameter(Mandatory=$false,Position=7)]
        [switch]$GenerateJsonOnly
    )

    # Select template based on options
    switch ($OSType)
    {
    
        'linux'         {$ostypex = 'linux'}
        'windows'       {$ostypex = 'windows'}
    
    }
    
    switch ($Platform)
    {
    
        'vbox'          {$vmplatform = $ostypex + '-vbox'}
        'vmware'        {$vmplatform = $ostypex + '-vmware'}
        'vagrant'       {$vmplatform = $ostypex + '-vagrant'}
    
    }
    
    switch ($VMSource)
    {
    
        'iso'           {$vmsourcex = $vmplatform + '-iso.json'}
        'vmx'           {$vmsourcex = $vmplatform + '-vmx.json'}
    
    }

    switch ($OSName)
    {
    
        'Win2016StdCore'    {$DistroScriptsFolder = 'win-server-2016'}
        'Win2012R2'         {$DistroScriptsFolder = 'win-server-2012'}
        'Win10'             {$DistroScriptsFolder = 'win-desktop-10'}
        'Win7'              {$DistroScriptsFolder = 'win-desktop-7'}
        'UbuntuXenial'      {$DistroScriptsFolder = 'ubuntu18'}
    
    }

    $full_template_path = "$TemplatesPath\$vmsourcex"

    # Run some basic checks to make sure everything is in place before deployment
    if(!(Test-Path $full_template_path)) {
        Write-LogFile -Message "Template $full_template_path is missing, please make sure you copy it to the right folder" -MessageType Info -WriteLogToStdOut
    }

    # TODO: 
    # Read template.json
    # buiild provisioners as blocks, place blocks in a pack-provisioners.json file
    # read variables from pack-variables to understand which things to run in the script phase. each phase separated by a restart: initial, choco packages, cleanup
    # generate dynamic template this way, then execute, forget about packer variable shit

    # Read in Template
    Write-LogFile -Message "Reading Template $full_template_path" -MessageType Info -WriteLogToStdOut
    $packer_template = ConvertFrom-Json $(Get-Content -Raw ".\$TemplatesPath\$vmsourcex")

    # Read in the contents of pack-variables.json
    Write-LogFile -Message "Reading Packer Vars file" -MessageType Info -WriteLogToStdOut
    $packer_vars = ConvertFrom-Json $(Get-Content -Raw ".\pack-variables.json")
    $OSType2 = $packer_vars.os.$OSName.guest_os_type.$Platform

    # Read in the contents of pack-provisioners.json
    Write-LogFile -Message "Reading Packer Provisioners file" -MessageType Info -WriteLogToStdOut
    $packer_provisioners = ConvertFrom-Json $(Get-Content -Raw ".\pack-provisioners.json")

    # List files in the "common" script directory, these will be attached as floppy files
    Write-LogFile -Message "Listing scripts in .\scripts\common" -MessageType Info -WriteLogToStdOut
    $common_scripts = (Get-ChildItem .\scripts\common).FullName
    
    # Check if only a JSON file should be generated
    if ($GenerateJsonOnly) {
        
        # 1. Add common scripts and autounattend
        $distro_unattend = (Get-ChildItem ".\scripts\$DistroScriptsFolder\answer_file\").FullName
        $packer_template.builders[0].floppy_files = [System.Collections.ArrayList]$common_scripts
        $packer_template.builders[0].floppy_files.Add($distro_unattend)

        # 2. Generate Provisioners block based on sequence
        # $ProvisioningSequence should be something like: @("show-banner", "prepare", "restart", "process", "cleanup")
        # for loop that selects the blocks and appends them to a psobject
        foreach($block in $ProvisioningSequence) {
            foreach($template_block in ($packer_provisioners | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
                if ($template_block -eq $block) {
                    
                }
            }
        }
        $packer_template.provisioners = $ProvisioningSequenceBlocks
    }
    else {
        # Build template with packer based on chosen options
        # if the user chose to overload any variables provided in variables.json, they will be inserted in the commandline with $(if($Variables){$Variables})
        
        Start-Process -FilePath 'packer.exe' -ArgumentList "build  -var-file=variables.json -var `"os_name=$($osData.os_name)`" -var `"iso_checksum=$($osData.iso_checksum)`" -var `"iso_checksum_type=$($osData.iso_checksum_type)`" -var `"iso_url=$($osData.iso_url)`" -var `"guest_os_type=$($osData.guest_os_type.platform)`" $(if($Variables){$Variables}) .\$($vmsourcex)" -Wait -NoNewWindow
    }
    

}

Function ConvertFrom-JsonV2 {

    <#

    .SYNOPSIS
    Simple helper function to convert to JSON compatible with Powershell V2.0

    #>

    Param ( 
        [Parameter(Mandatory=$True)]
        [Object]$Item
    )

    Add-Type -Assembly System.Web.Extensions
    $ps_js = New-Object System.Web.Script.Serialization.JavascriptSerializer

    #The comma operator is the array construction operator in PowerShell
    Return ,$ps_js.DeserializeObject($item)
}

Function ConvertTo-JsonV2 {

    <#

    .SYNOPSIS
    Simple helper function to convert to JSON compatible with Powershell V2.0

    #>

    Param ( 
        [Parameter(Mandatory=$True)]
        [Object]$Item
    )



    try {
        Add-Type -Assembly System.Web.Extensions
        $ps_js = New-Object System.Web.Script.Serialization.JavascriptSerializer
        $SerializedJSON = $ps_js.Serialize($Item)
    }

    catch [System.Management.Automation.RuntimeException] {
        $SerializedJSON = [LitJson.JsonMapper]::ToJson($Item)
    }
    catch [System.IO.FileNotFoundException] {
        $SerializedJSON = [LitJson.JsonMapper]::ToJson($Item)
    }

    Return $SerializedJSON
}

Function Write-LogFile {

    <#

    .SYNOPSIS
        Function to write message logs from this script in JSON format to a log file. When "LogAsField" is passed it will expect a hashtable of items that will be added to the log as key/value pairs passed as value to the parameter "Dictonary".

    .PARAMETER Message
        The text to be written

    .PARAMETER OutputDir
        The directory where the scan results are stored

    .PARAMETER InitializeLogFile
        When passed, the function will initiate an empty file by opening a handle to it with [System.IO.StreamWriter]

    .PARAMETER LogAsField
        It allows you to pass a dictionary (hashtable) where your keys and values will be converted to a json line. Nested keys are not supported.

    .PARAMETER LogAsIs
        It will log the line as received, without converting it to json.

    .EXAMPLE
        Todo

    #>

    Param (
        [Parameter(Mandatory=$False)]
        [string]$OutputDir,

        [Parameter(Mandatory=$False, Position=0)]
        [string]$Message,

        [Parameter(Mandatory=$False)]
        [Hashtable]$Dictionary,

        [Parameter(Mandatory=$False)]
        [ValidateSet('Memory','Disk')]
        [String[]]$InitializeLogFile = "",

        [Parameter(Mandatory=$False)]
        [ValidateSet('Error','Low','Info','Special','RemoteLog','Rare')]
        [string]$MessageType = "Info",

        [Parameter(Mandatory=$False)]
        [string]$CallingModule = $(if(Get-PSCallStack){$(Get-PSCallStack)[1].FunctionName}else{"NA"}),    
        
        [Parameter(Mandatory=$False)]
        [switch]$CreateRandomName,

        [Parameter(Mandatory=$False)]
        [switch]$LogAsField,

        [Parameter(Mandatory=$False)]
        [switch]$LogAsIs,

        [Parameter(Mandatory=$False)]
        [switch]$WriteLogToStdOut
        
    )

    # We will only proceed if this flag has not been setup somewhere in the script.
    if (!$Global:NoWriteLogFile) {

        if ($InitializeLogFile) {

            if ($CreateRandomName) {
                $Global:strLogFile = [string]([Guid]::newGuid())
            }
            else {
                $strTimeNow = (Get-Date).ToUniversalTime().ToString("yyMMdd-HHmmss")
                $RandomSuffix = Get-Random
                $Global:strLogFile = "$OutputDir\$($env:computername)-packer-vm-producer-$strTimeNow-$RandomSuffix.log"
            }
        }
        
        if ($InitializeLogFile -eq 'Disk') {
            # Initializing the File by opening a File StreamWriter handle to it
            # We need to do this so that the contents of the file are written to memory and only flushed to disk when 
            # we close the handle to the file. The reason is that, otherwise, the Splunk UF service blocks the file while reading it
            # and any other Powershell commands to write to file throw errors. It becomes increasingly harder to maintain if we don't
            # use the StreamWriter .NET handle. At the end of the call to Start-YaraScan the handle is closed and disposed of.
            
            $Global:objDiskFileStream = New-Object -TypeName System.IO.StreamWriter -ArgumentList $strLogFile
            
            Return
        }

        elseif ($InitializeLogFile -eq 'Memory') {
            # Initializing a Memory Stream Writter that will write each line to a memory buffer only flushing to disk at the end
            $Global:MemStream = New-Object -TypeName System.IO.MemoryStream
            $Global:StreamWritter = New-Object -TypeName System.IO.StreamWriter -ArgumentList $MemStream
            $Global:StreamWritter.AutoFlush = 1
            #$Global:objMemoryFileStream = [System.IO.FileStream]::new($Global:strLogFile, [System.IO.FileMode]::OpenOrCreate)

            Return

        }

        # Grabing Time in UTC
        $strTimeNow = (Get-Date).ToUniversalTime().ToString("yy-MM-ddTHH:mm:ssZ")

        if ($LogAsField) {

            if (!$Dictionary) {
                Write-LogFile -Message "Cannot log requested Key/Value since no Dictionary parameter was provided"
                Break
                }
            
            # To keep compatibility with Powershell V2 we can't use the [ordered] accelerator
            $strLogLine = New-Object System.Collections.Specialized.OrderedDictionary
            $strLogLine.Add("timestamp", $strTimeNow)
            $strLogLine.Add("hostname", $($env:COMPUTERNAME))
            
            ForEach ($key in $Dictionary.Keys){

                $strLogLine.Add($key, $Dictionary.Item($key))
            }
        }

        else {

            if ($LogAsIs) {
                $strLogLine = $Message
            }
            else {

                # To keep compatibility with Powershell V2 we can't use the [order] accelerator
                $strLogLine = New-Object System.Collections.Specialized.OrderedDictionary
                $strLogLine.Add("timestamp", $strTimeNow)
                $strLogLine.Add("hostname", $($env:COMPUTERNAME))
                $strLogLine.Add("message", $Message)
            }
        }

        # Converting log line to JSON

        if (!$LogAsIs) {
            if ($PSVersionTable.PSVersion.Major -lt 5) {
                $strLogLine = ConvertTo-JsonV2($strLogLine) -ErrorAction SilentlyContinue
            }
            else {
                $strLogLine = $strLogLine | ConvertTo-Json -Compress
            }
        }



        # Choosing the right StdOut Colors in case we need them
        Switch ($MessageType) {

            "Error" {
                $MessageColor = "Gray"
                $BackgroundColor = "Black"
            }
            "Info" {
                $MessageColor = "Yellow"
                $BackgroundColor = "Black"
            }
            "Low" {
                $MessageColor = "Green"
                $BackgroundColor = "DarkCyan"
            }
            "Special" {
                $MessageColor = "White"
                $BackgroundColor = "Red"
            }
            "RemoteLog" {
                $MessageColor = "DarkGreen"
                $BackgroundColor = "Green"
            }
            "Rare" {
                $MessageColor = "Black"
                $BackgroundColor = "White"
            }
        }

        # Only Log when the writer has been initialized. Otherwise do no nothing. 
        # We implement this check so that we can run modules independently without running into the issue
        # that the LofFile Writter hasn't been initialized
        if ($Global:objDiskFileStream -or $Global:MemStream) {
            # Let's write to Log File on Disk or Memory
            if ($Global:objDiskFileStream) {
                $Global:objDiskFileStream.WriteLine($strLogLine)
            }
            else {
                $Global:StreamWritter.WriteLine($strLogLine)
            }
        }

        # Checking whether we should write to the console too
        # NOTE: In PS 7 Runspaces the concept of a "HOST" doesn't exist, we should avoid using Write-Host
        if ($Host.UI.RawUI -eq "System.Management.Automation.Internal.Host.InternalHostRawUserInterface") {

            if ($Global:LogfileWriteConsole -or $WriteLogToStdOut) {
                Write-Output $strLogLine
            }
        }
        # Running from a .NET PS console v3 to v5
        else {
            if ($Global:LogfileWriteConsole -or $WriteLogToStdOut) {
                Write-Host $strLogLine -ForegroundColor $MessageColor -BackgroundColor $BackgroundColor
            }
        }
    }
}