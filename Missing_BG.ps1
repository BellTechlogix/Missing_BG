<#
	Missing_BG.ps1
	Created By - Kristopher Roy
	Created On - 10 Mar 2021
	Modified On - 11 Mar 2021

	This Script Requires that SCCM version 2002 minimum is installed and that the collection "Missing BG" is setup. To configure the collection you can use the following query:
		select SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client 
		from SMS_R_System where SMS_R_System.ResourceId in  (select resourceid from SMS_CollectionMemberClientBaselineStatus  
		where SMS_CollectionMemberClientBaselineStatus.boundarygroups is NULL)  and SMS_R_System.Name not in ("Unknown") and SMS_R_System.Client = "1"
	You will also require the ability to directly query the SCCM SQL DB

#>

#Organization that the report is for
$org = "My Org"

#SCCM DB
$DB = "CM_sitecode"

# Site code
$SiteCode = "SMS"

# SMS Provider machine name
$ProviderMachineName = "SCCM.domain.com"

#folder to store completed reports
$rptfolder = "c:\reports\"

#mail recipients for sending report
$recipients = @("BTL SCCM <sccm@belltechlogix.com>")

#from address
$from = "Reports@wherever.com"

#smtpserver
$smtp = "mail.wherever.com"

#Timestamp
$runtime = Get-Date -Format "yyyyMMMdd"

# Customizations
$initParams = @{}

#Connect to SCCM and Import the ConfigurationManager.psd1 module 
if((Get-Module ConfigurationManager) -eq $null) {
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams 
}

# Connect to the site's drive if it is not already present
if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

Function Invoke-SQLQuery {   
    <#
    .SYNOPSIS
        Quickly run a query against a SQL server.
    .DESCRIPTION
        Simple function to run a query against a SQL server.
    .PARAMETER Instance
        Server name and instance (if needed) of the SQL server you want to run the query against.  E.G.  SQLServer\Payroll
    .PARAMETER Database
        Name of the database the query must run against
    .PARAMETER Credential
        Supply alternative credentials
    .PARAMETER MultiSubnetFailover
        Connect to a SQL 2012 AlwaysOn Availability group.  This parameter requires the SQL2012 Native Client to be installed on
        the machine you are running this on.  MultiSubnetFailover will give your script the ability to talk to a AlwaysOn Availability
        cluster, no matter where the primary database is located.
    .PARAMETER Query
        Text of the query you wish to run.  This parameter is optional and if not specified the script will create a text file in 
        your temporary directory called Invoke-SQLQuery-Query.txt.  You can put your query text in this file and when you save and 
        exit the script will execute that query.
    .PARAMETER NoInstance
        By default Invoke-SQLQuery will add a column with the name of the instance where the data was retrieved.  Use this switch to
        suppress that behavior.
    .PARAMETER PrintToStdOut
        If your query is using the PRINT statement, instead of writing that to the verbose stream, this switch will write that output
        to StdOut.
    .PARAMETER Timeout
        Time Invoke-SQLQuery will wait for SQL Server to return data.  Default is 120 seconds.
    .PARAMETER ListDatabases
        Use this switch to get a list of all databases on the Instance you specified.
    .INPUTS
        String              Will accept the query text from pipeline
    .OUTPUTS
        System.Data.DataRow
    .EXAMPLE
        Invoke-SQLQuery -Instance faxdba101 -Database RightFax -Query "Select top 25 * from Documents where fcsfile <> ''"
        
        Runs a query against faxdba101, Rightfax database.
    .EXAMPLE
        Get-Content c:\sql\commonquery.txt | Invoke-SQLQuery -Instance faxdba101,faxdbb101,faxdba401 -Database RightFax
        
        Run a query you have stored in commonquery.txt against faxdba101, faxdbb101 and faxdba401
    .EXAMPLE
        Invoke-SQLQuery -Instance dbprod102 -ListDatabases
        
        Query dbprod102 for all databases on the SQL server
    .NOTES
        Author:             Martin Pugh
        Date:               7/11/2014
          
        Changelog:
            1.0             Initial Release
            1.1             7/11/14  - Changed $Query parameter that if none specified it will open Notepad for editing the query
            1.2             7/17/14  - Added ListDatabases switch so you can see what databases a server has
            1.3             7/18/14  - Added ability to query multiple SQL servers, improved error logging, add several more examples
                                       in help.
            1.4             10/24/14 - Added support for SQL AlwaysOn
            1.5             11/28/14 - Moved into SQL.Automation Module, fixed bug so script will properly detect when no information is returned from the SQL query
            1.51            1/28/15  - Added support for SilentlyContinue, so you can suppress the warnings if you want 
            1.6             3/5/15   - Added NoInstance switch
            1.61            10/14/15 - Added command timeout
            2.0             11/13/15 - Added ability to stream Message traffic (from PRINT command) to verbose stream.  Enhanced error output, you can now Try/Catch
                                       Invoke-SQLQuery.  Updated documentation. 
            2.01            12/23/15 - Fixed piping query into function
        Todo:
            1.              Alternate port support?
    .LINK
        https://github.com/martin9700/Invoke-SQLQuery
    #>
    [CmdletBinding(DefaultParameterSetName="query")]
    Param (
        [string[]]$Instance = $env:COMPUTERNAME,
        
        [Parameter(ParameterSetName="query",Mandatory=$true)]
        [string]$Database,
        
        [Management.Automation.PSCredential]$Credential,
        [switch]$MultiSubnetFailover,
        
        [Parameter(ParameterSetName="query",ValueFromPipeline=$true)]
        [string]$Query,

        [Parameter(ParameterSetName="query")]
        [switch]$NoInstance,

        [Parameter(ParameterSetName="query")]
        [switch]$PrintToStdOut,

        [Parameter(ParameterSetName="query")]
        [int]$Timeout = 120,

        [Parameter(ParameterSetName="list")]
        [switch]$ListDatabases
    )

    Begin {
        If ($ListDatabases)
        {   
            $Database = "Master"
            $Query = "Select Name,state_desc as [State],recovery_model_desc as [Recovery Model] From Sys.Databases"
        }        
        
        $Message = New-Object -TypeName System.Collections.ArrayList

        $ErrorHandlerScript = {
            Param(
                $Sender, 
                $Event
            )

            $Message.Add([PSCustomObject]@{
                Number = $Event.Errors.Number
                Line = $Event.Errors.LineNumber
                Message = $Event.Errors.Message
            }) | Out-Null
        }
    }

    End {
        If ($Input)
        {   
            $Query = $Input -join "`n"
        }
        If (-not $Query)
        {   
            $Path = Join-Path -Path $env:TEMP -ChildPath "Invoke-SQLQuery-Query.txt"
            Start-Process Notepad.exe -ArgumentList $Path -Wait
            $Query = Get-Content $Path
        }

        If ($Credential)
        {   
            $Security = "uid=$($Credential.UserName);pwd=$($Credential.GetNetworkCredential().Password)"
        }
        Else
        {   
            $Security = "Integrated Security=True;"
        }
        
        If ($MultiSubnetFailover)
        {   
            $MSF = "MultiSubnetFailover=yes;"
        }
        
        ForEach ($SQLServer in $Instance)
        {   
            $ConnectionString = "data source=$SQLServer,1433;Initial catalog=$Database;$Security;$MSF"
            $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
            $SqlConnection.ConnectionString = $ConnectionString
            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $Query
            $SqlCommand.CommandTimeout = $Timeout
            $Handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] $ErrorHandlerScript
            $SqlConnection.add_InfoMessage($Handler)
            $SqlConnection.FireInfoMessageEventOnUserErrors = $true
            $DataAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $SqlCommand
            $DataSet = New-Object System.Data.Dataset

            Try {
                $Records = $DataAdapter.Fill($DataSet)
                If ($DataSet.Tables[0])
                {   
                    If (-not $NoInstance)
                    {
                        $DataSet.Tables[0] | Add-Member -MemberType NoteProperty -Name Instance -Value $SQLServer
                    }
                    Write-Output $DataSet.Tables[0]
                }
                Else
                {   
                    Write-Verbose "Query did not return any records"
                }
            }
            Catch {
                $SqlConnection.Close()
                Write-Error $LastError.Exception.Message
                Continue
            }
            $SqlConnection.Close()
        }

        If ($Message)
        {
            ForEach ($Warning in ($Message | Where Number -eq 0))
            {
                If ($PrintToStdOut)
                {
                    Write-Output $Warning.Message
                }
                Else
                {
                    Write-Verbose $Warning.Message -Verbose
                }
            }
            $Errors = @($Message | Where Number -ne 0)
            If ($Errors.Count)
            {
                ForEach ($MsgError in $Errors)
                { 
                    Write-Error "Query Error $($MsgError.Number), Line $($MsgError.Line): $($MsgError.Message)"
                }
            }
        }
    }
}

#Gets your collection ID and then gets all of the machines in the collection

#Verify if Col exists fail if not
$BGCOL = Get-CMCollection -Name "Missing BG"|select CollectionID
If($BGCOL -eq $NULL)
{Write-Host "Collection, Missing BG, Does not exist, ending";exit}

$CMDevices = Get-CMDevice -CollectionId $BGCOL.CollectionID|select Name, HWScan, Subnet,'IP Address'
$CMDevicesCount = $CMDevices.count

$i = 0

#Loop to go through each machine
FOREACH($dev in $cmdevices)
{
    $i++
	#Creates a progress bar
	Write-Progress -Activity ("Gathering Machine Date . . ."+$dev.Name) -Status "Scanned: $i of $($cmdevices.Count)" -PercentComplete ($i/$cmdevices.Count*100)
    $name = $dev.name
    
	#SQL string to grab HW Inventory data
	$string = @"
    DECLARE @Name VARCHAR(25)
    SET @Name = '$name'
    SELECT DISTINCT SYS.Netbios_Name0, SYS.Operating_System_Name_and0,HWSCAN.LastHWScan, SWSCAN.LastScanDate, SWSCAN.LastCollectedFileScanDate 
    FROM v_R_System SYS
    LEFT JOIN v_GS_LastSoftwareScan SWSCAN on SYS.ResourceID = SWSCAN.ResourceID
    LEFT JOIN v_GS_WORKSTATION_STATUS HWSCAN on SYS.ResourceID = HWSCAN.ResourceID
    WHERE SYS.Netbios_Name0 = @Name
"@
    $dev.'Subnet' = [system.string]::Join(", ",(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_R_System -ComputerName $ProviderMachineName -Filter "Name like '$($dev.Name)'" | Select-Object -Property IPSubnets).IPSubnets)
    $dev.'IP Address' = [system.string]::Join(", ",(Get-WmiObject -Namespace "root\SMS\site_$SiteCode" -Class SMS_R_System -ComputerName $ProviderMachineName -Filter "Name like '$($dev.Name)'" | Select-Object -Property IPAddresses).IPAddresses)
    $dev.hwscan = (invoke-SQLQuery -Database $DB -Query $string).LastHWScan
    
	#Nulls the variables inbetween each loop
	$dev = $null
    $name = $null
}


$CMDevices|select Name,HWScan,Subnet,"IP Address"|export-csv $rptFolder$runtime-missingBG.csv -NoTypeInformation

#This Section Builds out the email body
$emailBody = "<h1 style='color: #5e9ca0;'>Missing Boundary Group Report</h1>"
$emailBody = $emailBody + "<h2 style='color: #2e6c80;'>Number of Machines: <span style='color: #000000;'><strong>$CMDevicesCount</strong></span></h2>"

Send-MailMessage -from $from -to $recipients -subject "$ORG - SCCM Missing BG Report" -BodyAsHtml $emailBody -smtpserver $smtp -Attachments "$rptFolder$runtime-MissingBG.csv"

#Cleanup Old Files
$Daysback = '-14'
$CurrentDate = Get-Date
$DateToDelete = $CurrentDate.AddDays($Daysback)
Get-ChildItem $rptFolder | Where-Object { $_.LastWriteTime -lt $DatetoDelete -and $_.Name -like "*MissingBG*"} | Remove-Item