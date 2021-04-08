PARAM(        
    [Parameter(Mandatory=$true)] $LogAnalyticsWorkspaceId,            
    [Parameter(Mandatory=$true)] $ADXClusterURL,
    [Parameter(Mandatory=$true)] $ADXDBName,
    $ADXEngineUrl = "$ADXClusterURL/$ADXDBName",
    $kustoToolsPackage = "microsoft.azure.kusto.tools",
    $kustoConnectionString = "$ADXEngineUrl;Fed=True",
    $nugetPackageLocation = "$($env:USERPROFILE)\.nuget\packages", #global-packages", # local
    $nugetIndex = "https://api.nuget.org/v3/index.json",
    $nugetDownloadUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
)


Function CheckModules($module) {
    $installedModule = Get-InstalledModule -Name $module -ErrorAction SilentlyContinue
    if ($null -eq $installedModule) {
        Write-Warning "The $module PowerShell module is not found"
        #check for Admin Privleges
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

        if (-not ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
            #Not an Admin, install to current user
            Write-Warning -Message "Can not install the $module module. You are not running as Administrator"
            Write-Warning -Message "Installing $module module to current user Scope"
            Install-Module -Name $module -Scope CurrentUser -Force
            Import-Module -Name $module -Force
        }
        else {
            #Admin, install to all users
            Write-Warning -Message "Installing the $module module to all users"
            Install-Module -Name $module -Force
            Import-Module -Name $module -Force
        }
    }
    #Install-Module will obtain the module from the gallery and install it on your local machine, making it available for use.
    #Import-Module will bring the module and its functions into your current powershell session, if the module is installed.  
}
Function InvokeKustoCLI($adxCommandsFile) {
    $kustoToolsDir = "$env:USERPROFILE\.nuget\packages\$kustoToolsPackage\"
    $currentDir = Get-Location
    Set-Location $scriptDir

    if (!(test-path $kustoToolsDir))
    {

        if(!(test-path nuget))
        {
            (new-object net.webclient).downloadFile($nugetDownloadUrl, "$pwd\nuget.exe")
        }

        &.\nuget.exe install $kustoToolsPackage -Source $nugetIndex -OutputDirectory $nugetPackageLocation
    }

    $kustoExe = $kustoToolsDir + @(get-childitem -recurse -path $kustoToolsDir -Name kusto.cli.exe)[-1]
    
    if (!(test-path $kustoExe))
    {
        Write-Warning "unable to find kusto client tool $kustoExe. exiting"
        return
    }
    
    invoke-expression "$kustoExe `"$kustoConnectionString`" -script:$adxCommandsFile"

    set-location $currentDir
}

Write-Host "ADXEngineUrl:$ADXEngineUrl"
CheckModules("Az.Resources")
CheckModules("Az.OperationalInsights")

Write-Host "`r`nIf not logged in to Azure already, you will now be asked to log in to your Azure environment. `nFor this script to work correctly, you need to provide credentials `nAzure Log Analytics Workspace Read Permissions `nAzure Data Explorer Database User Permission. `nThis will allow the script to read all the Tables from Log Analytics Workspace `nand create tables in Azure Data Explorer.`r`n" -BackgroundColor Blue

Read-Host -Prompt "Press enter to continue or CTRL+C to quit the script"

$context = Get-AzContext

if(!$context){
    Connect-AzAccount
    $context = Get-AzContext
}

$SubscriptionId = $context.Subscription.Id

if(!(Test-Path "$PSScriptRoot\KustoQueries" -PathType Container)) { 
    New-Item -Path $PSScriptRoot -Name "KustoQueries" -ItemType "directory"
}

#Get All the Tables from LA Workspace
$queryAllTables = 'search *| distinct $table| sort by $table asc nulls last'

$resultsAllTables = (Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $queryAllTables).Results

foreach ($table in $resultsAllTables) {
    $TableName = $table.'$table'
    IF ($TableName -match '_CL$'){
        Write-Output "Custom Log Table : $TableName not supported"
    }
    else {        
        $query = $TableName + ' | getschema | project ColumnName, DataType'

        $output = (Invoke-AzOperationalInsightsQuery -WorkspaceId $LogAnalyticsWorkspaceId -Query $query).Results

        $TableExpandFunction = $TableName + 'Expand'
        $TableRaw = $TableName + 'Raw'
        $RawMapping = $TableRaw + 'Mapping'

        $FirstCommand = @()
        $ThirdCommand = @()

        foreach ($record in $output) {
            if ($record.DataType -eq 'System.DateTime') {
                $dataType = 'datetime'
                $ThirdCommand += $record.ColumnName + " = todatetime(events." + $record.ColumnName + "),"
            } else {
                $dataType = 'string'
                $ThirdCommand += $record.ColumnName + " = tostring(events." + $record.ColumnName + "),"
            }
            $FirstCommand += $record.ColumnName + ":" + "$dataType" + ","    
        }

        $schema = ($FirstCommand -join '') -replace ',$'
        $function = ($ThirdCommand -join '') -replace ',$'

        $CreateRawTable = @'
.create table {0} (Records:dynamic)
'@ -f $TableRaw

        $CreateRawMapping = @'
.create table {0} ingestion json mapping '{1}' '[{{"column":"Records","Properties":{{"path":"$.records"}}}}]'
'@ -f $TableRaw, $RawMapping

        $CreateRetention = @'
.alter-merge table {0} policy retention softdelete = 0d
'@ -f $TableRaw

        $CreateTable = @'
.create table {0} ({1})
'@ -f $TableName, $schema

        $CreateFunction = @'
.create-or-alter function {0} {{{1} | mv-expand events = Records | project {2} }}
'@ -f $TableExpandFunction, $TableRaw, $function

        $CreatePolicyUpdate = @'
.alter table {0} policy update @'[{{"Source": "{1}", "Query": "{2}()", "IsEnabled": "True", "IsTransactional": true}}]'
'@ -f $TableName, $TableRaw, $TableExpandFunction

        $scriptDir = "$PSScriptRoot\KustoQueries"
        New-Item "$scriptDir\adxCommands.txt"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRawTable"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRawMapping"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreateRetention"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreateTable"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreateFunction"
        Add-Content "$scriptDir\adxCommands.txt" "`n$CreatePolicyUpdate"

        InvokeKustoCLI -AdxCommandsFile "$scriptDir\adxCommands.txt"

        Remove-Item $scriptDir\adxCommands.txt -Force -ErrorAction Ignore        
    }
}
Write-Host "Successfully created all the tables in ADX Cluster Database"
Write-Host "Please create Ingestion Pipeline"