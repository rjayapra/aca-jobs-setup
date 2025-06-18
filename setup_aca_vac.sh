#!/bin/bash

# Variables
RESOURCE_GROUP="VACDC-SHRTAPP-RG"
LOCATION="canadacentral"
VNET_RG="VACDCVNET-RG"
VNET_NAME="VACDCVNET-DEV01"
SUBNET_NAME="VACDC-ACA-SNET"
ACA_ENV_NAME="VACDC-ACA-Env"
ACA_NAME="cst-app"
LOG_ANALYTICS_WS="VACDC-ACA-LogAnalytics"
CONTAINER_IMAGE="devshrst.azurecr.io/shrst-cst-azure-dev:d6fb73a5"
WORKLOAD_PROFILE_NAME_CONSUMPTION="wp-consumption"
WORKLOAD_PROFILE_NAME_DEDICATED="wp-dedicated"
IDENTITY_NAME="cst-identity"
ACR_NAME="devshrst.azurecr.io"

# Create Log Analytics workspace
az monitor log-analytics workspace create \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WS \
  --location $LOCATION

# Get workspace customer ID and key
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WS \
  --query customerId -o tsv)

WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WS \
  --query primarySharedKey -o tsv)

SUBNETID=$(az network vnet subnet show \
      --resource-group $VNET_RG \
      --vnet-name $VNET_NAME \
      --name $SUBNET_NAME \
      --query id -o tsv)

# Create ACA environment with VNet and Log Analytics
az containerapp env create \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --logs-workspace-id $WORKSPACE_ID \
  --logs-workspace-key $WORKSPACE_KEY \
  --infrastructure-subnet-resource-id $SUBNETID \
  --enable-workload-profiles \
  --internal-only 

# Get ACA environment ID
ACA_ENV_ID=$(az containerapp env show \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Variables
PRIVATE_DNS_ZONE="privatelink.azurecontainerapps.io"
PRIVATE_ENDPOINT_NAME="VACDC-ACA-PE"
VNET_ID=$(az network vnet show --resource-group $VNET_RG --name $VNET_NAME --query id -o tsv)
SUBNET_ID=$(az network vnet subnet show --resource-group $VNET_RG --vnet-name $VNET_NAME --name $SUBNET_NAME --query id -o tsv)

# Create Private DNS Zone
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name $PRIVATE_DNS_ZONE

# Link DNS zone to VNet
az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name $PRIVATE_DNS_ZONE \
  --name "acaDnsLink" \
  --virtual-network $VNET_ID \
  --registration-enabled false



# Create Private Endpoint
az network private-endpoint create \
  --name $PRIVATE_ENDPOINT_NAME \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $SUBNET_NAME \
  --private-connection-resource-id $ACA_ENV_ID \
  --group-id "containerappEnvironment" \
  --connection-name "acaPrivateConnection" \
  --location $LOCATION

# Create DNS zone group for the private endpoint
az network private-endpoint dns-zone-group create \
  --resource-group $RESOURCE_GROUP \
  --endpoint-name $PRIVATE_ENDPOINT_NAME \
  --name "acaDnsZoneGroup" \
  --private-dns-zone $PRIVATE_DNS_ZONE \
  --zone-name $PRIVATE_DNS_ZONE



# Create a workload profile (if not already created)
az containerapp env workload-profile add \
 --workload-profile-name Consumption \
 --resource-group $RESOURCE_GROUP \
 --name $ACA_ENV_NAME \
 --workload-profile-type Consumption \
 --min-nodes 1 \
 --max-nodes 1


az identity create \
--name $IDENTITY_NAME \
--resource-group $RESOURCE_GROUP

# Get the identity's principal ID
PRINCIPAL_ID=$(az identity show \
--name $IDENTITY_NAME \
--resource-group $RESOURCE_GROUP \
--query principalId -o tsv)

# Get the ACR resource ID
ACR_ID=$(az acr show \
--name $ACR_NAME \
--resource-group $RESOURCE_GROUP \
--query id -o tsv)

# Assign AcrPull role to the identity
az role assignment create \
--assignee-object-id $PRINCIPAL_ID \
--assignee-principal-type ServicePrincipal \
--role "AcrPull" \
--scope $ACR_ID



# Create the Container App with Dapr and private ingress
az containerapp create \
    --name $ACA_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $ACA_ENV_NAME \
    --image $CONTAINER_IMAGE \
    --ingress external \
    --target-port 80 \
    --user-assigned "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$IDENTITY_NAME"


# Create a Container App Job (example: Cron job)
az containerapp job create \
    --name $JOBS_NAME \
    --resource-group $RESOURCE_GROUP \
    --environment $ACA_ENV_NAME \
    --trigger-type "Schedule" \
    --replica-timeout 1800 \
    --replica-retry-limit 3 \
    --replica-completion-count 1 \
    --cron-expression "0 */6 * * *" \
    --image $CONTAINER_IMAGE \
    --workload-profile-name $WORKLOAD_PROFILE_NAME_CONSUMPTION

echo "Azure Container Apps environment and resources created successfully."


#create search service
az search service create \
  --name vacdc-cst-search \
  --resource-group  VACDC-SHRTAPP-RG \
  --location canadacentral \
  --sku standard \
  --partition-count 1 \
  --replica-count 1
# Use the user-assigned managed identity for the search service
az search service update \
  --name vacdc-cst-search \
  --resource-group VACDC-SHRTAPP-RG \
  --set identity.type=UserAssigned \
  --set identity.userAssignedIdentities="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$IDENTITY_NAME"


# Create a private endpoint for the search service
az network private-endpoint create \
  --name vacdc-cst-search-pe \
  --resource-group VACDC-SHRTAPP-RG \
  --vnet-name VACDCVNET-DEV01 \
  --subnet VACDC-ACA-SNET \
  --private-connection-resource-id $(az search service show --name vacdc-cst-search --resource-group VACDC-SHRTAPP-RG --query id -o tsv) \
  --group-id searchService \
  --connection-name vacdc-cst-search-connection
# Create a private DNS zone for the search service
az network private-dns zone create \
  --resource-group VACDC-SHRTAPP-RG \
  --name privatelink.search.windows.net
# Link the private DNS zone to the VNet
az network private-dns link vnet create \   
  --resource-group VACDC-SHRTAPP-RG \
  --zone-name privatelink.search.windows.net \
  --name vacdc-cst-search-dns-link \
  --virtual-network VACDCVNET-DEV01 \
  --registration-enabled false
# Create a DNS zone group for the private endpoint
az network private-endpoint dns-zone-group create \
  --resource-group VACDC-SHRTAPP-RG \
  --endpoint-name vacdc-cst-search-pe \
  --name vacdc-cst-search-dns-zone-group \
  --private-dns-zone privatelink.search.windows.net \
  --zone-name privatelink.search.windows.net

# Assign the Search Service Contributor role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Service Contributor" \
    --scope $(az search service show --name vacdc-cst-search --resource-group VACDC-SHRTAPP-RG --query id -o tsv)
# Assign the Search Index Data Contributor role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Index Data Contributor" \
    --scope $(az search service show --name vacdc-cst-search --resource-group VACDC-SHRTAPP-RG --query id -o tsv)

# Assign the Search Query Key role to the identity
az role assignment create \ 
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Query Key" \
    --scope $(az search service show --name vacdc-cst-search --resource-group VACDC-SHRTAPP-RG --query id -o tsv)
# Assign the Search Index Data Reader role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Index Data Reader" \
    --scope $(az search service show --name vacdc-cst-search --resource-group VACDC-SHRTAPP-RG --query id -o tsv)
