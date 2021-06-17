## UPDATE : I have successfully released end-to-end automation script (V2.0) to integrate Azure Data Explorer without being going to Azure Portal. Please download tool from Azure Sentinel Official GitHub Repo - https://github.com/Azure/Azure-Sentinel/tree/master/Tools/AzureDataExplorer

## Azure Log Analytics Log Management using Azure Data Explorer  
Azure Data Explorer is a fast and highly scalable data exploration service for log and telemetry data. 
To use Azure Data Explorer, you first create a cluster, and create one or more databases in that cluster. 
Then you ingest (load) data into a database so that you can run queries against it.

## Prerequisites
1.	**Create an Azure Data Explorer Cluster in the same region as your Log Analytics Workspace**  
	https://docs.microsoft.com/en-us/azure/data-explorer/create-cluster-database-portal

2. Create Database

## Running PowerShell Script

PowerShell prompts you to enter the following parameters

1. Azure Log Analytics Workspace Id
2. ADX Cluster URI  
   Ex: `https://<<ADXClusterName>>.<<region>>.kusto.windows.net`
3. Database Name

## Export data to Azure Data Explorer using Data Export  
The following steps were automated using PowerShell Script

1. Create target tables in ADX – raw records (json) and final tables  

2. Create table mapping – how JSON input is mapped to table fields  

3. Create update policy and attach it to raw records table – function that transforms the data  

4. Create data connection between EventHub and raw data table in ADX – ingestion setup  

5. Modify retention for target table – default is 100 years  

## Create a data export rule for a given workspace 

Run the following command  
Use the following command to create a data export rule to a storage account using CLI.  
```
$storageAccountResourceId = '/subscriptions/subscription-id/resourceGroups/resource-group-name/providers/Microsoft.Storage/storageAccounts/storage-account-name'
az monitor log-analytics workspace data-export create --resource-group resourceGroupName --workspace-name workspaceName --name ruleName --tables SecurityEvent Heartbeat --destination $storageAccountResourceId
```  
Use the following command to create a data export rule to an event hub using CLI. A separate event hub is created for each table.  
```
$eventHubsNamespacesResourceId = '/subscriptions/subscription-id/resourceGroups/resource-group-name/providers/Microsoft.EventHub/namespaces/namespaces-name'
az monitor log-analytics workspace data-export create --resource-group resourceGroupName --workspace-name workspaceName --name ruleName --tables SecurityEvent Heartbeat --destination $eventHubsNamespacesResourceId
```


