PARAM(        
    [Parameter(Mandatory=$true)] $WorkspaceId,            
    [Parameter(Mandatory=$true)] $kustoEngineUrl,    
    $kustoToolsPackage = "microsoft.azure.kusto.tools",
    $kustoConnectionString = "$kustoEngineUrl;Fed=True",
    $nugetPackageLocation = "$($env:USERPROFILE)\.nuget\packages", #global-packages", # local
    $nugetIndex = "https://api.nuget.org/v3/index.json",
    $nugetDownloadUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
)

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

        nuget install $kustoToolsPackage -Source $nugetIndex -OutputDirectory $nugetPackageLocation
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

if(!(Test-Path "$PSScriptRoot\KustoQueries" -PathType Container)) { 
    New-Item -Path $PSScriptRoot -Name "KustoQueries" -ItemType "directory"
}

#Get All the Tables from LA Workspace
$queryAllTables = 'search *| distinct $table| sort by $table asc nulls last'

$resultsAllTables = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $queryAllTables).Results

foreach ($table in $resultsAllTables) {
    $TableName = $table.'$table'
    IF ($TableName -match '_CL$'){
        Write-Output "Custom Log Table : $TableName not supported"
    }
    else {        
        $query = $TableName + ' | getschema | project ColumnName, DataType'

        $output = (Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query).Results

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

