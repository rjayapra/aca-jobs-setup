#!/bin/bash
# This script sets up Azure Container Apps (ACA) environment in the VAC-Production subscription. 
#  Not recommended to run this script in production without proper testing and validation and should not be used in automation
#  Recommend to use Bicep or Terraform for production deployments.

# Prerequisite: 
# Ensure you have the Azure CLI installed and logged in to the correct subscription
# az login
# az account set --subscription "VAC-Production"
# Ensure you have the necessary permissions to create resources in the specified resource group and subscription.
# Ensure you have the Azure CLI version 2.20.0 or later installed


# Subscription: VAC-Production
# Resource Group : VACPC-CSTAPP-RG
# Vnet: VACPC-CST-VNet : IP Address range (10.0.4.0/22)
# 
# Container App Subnet (10.1.4.0/23)
# PE subnet (10.1.6.64/27)
# Resources subnet (10.1.6.0/26)
# DNS Zone - for prod (existing or new)
# 
# Subnets : 
# VACPC-CST-App
# VACPC-CST-Resources
# VACPC-CST-PE 

# Service bus and PE exists in VACPC-CommonInfrasubnet
# ACR exists in VACPC-SHRTAPP-RG , no PE enabled

# Resources to be created:
# ACA 
# Log analytics Workspace
# AI Search
# Open AI
# Document intelligence 

# Variables
RESOURCE_GROUP="VACPC-CSTAPP-RG"
LOCATION="canadacentral"
VNET_RG="VACPC-CSTAPP-RG"
VNET_NAME="VACPCVNET-01"
ACA_SUBNET_NAME="VACPC-CST-App-SNet"
RESOURCES_SUBNET_NAME="VACPC-CST-Resources-SNet"
PE_SUBNET_NAME="VACPC-CST-PE-SNet"

# DNS Zone Resources
DNS_ZONE_SUBSCRIPTION="1a9d07dd-d0e5-4f75-94a8-d6224f36ce7c"
DNS_ZONE_RG="VACCC-PrivateDNSZones-RG"
DNS_ZONE_VNET_NAME="VACPCVNET-01"
ACA_DNS_ZONE_NAME="privatelink.azurecontainerapps.io"
COGSERVICE_DNS_ZONE_NAME="privatelink.cognitiveservices.azure.com"
SEARCH_DNS_ZONE_NAME="privatelink.search.windows.net"
OPENAI_DNS_ZONE_NAME="privatelink.openai.azure.com"


ACA_ENV_NAME="VACPC-ACA-Env"
ACA_NAME="cst-app"
WORKLOAD_PROFILE_NAME="Consumption"
IDENTITY_NAME="cst-identity"

LOG_ANALYTICS_WS="VACPC-ACA-LAW"
CONTAINER_IMAGE="shrstcr.azurecr.io/shrst-cst-azure-dev:d6fb73a5"

ACR_NAME="shrstcr.azurecr.io"
ACR_ID="/subscriptions/94f984d5-8890-48b3-bf6a-fba4ae2cd092/resourceGroups/VACPC-SHRTAPP-RG/providers/Microsoft.ContainerRegistry/registries/shrstcr"

VNET_ADDRESS_PREFIX="10.0.4.0/22"
ACA_SUBNET_ADDRESS_PREFIX="10.0.4.0/23"
RESOURCES_SUBNET_ADDRESS_PREFIX="10.0.6.0/26"
PE_SUBNET_ADDRESS_PREFIX="10.0.6.64/27"

# Create Resource Group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create Virtual Network
az network vnet create \
  --resource-group $VNET_RG \
  --name $VNET_NAME \
  --address-prefix $VNET_ADDRESS_PREFIX \
  --subnet-name $ACA_SUBNET_NAME \
  --subnet-prefix $ACA_SUBNET_ADDRESS_PREFIX  
# Create additional subnets
az network vnet subnet create \
  --resource-group $VNET_RG \
  --vnet-name $VNET_NAME \
  --name $RESOURCES_SUBNET_NAME \
  --address-prefix $RESOURCES_SUBNET_ADDRESS_PREFIX 
az network vnet subnet create \
  --resource-group $VNET_RG \
  --vnet-name $VNET_NAME \
  --name $PE_SUBNET_NAME \
  --address-prefix $PE_SUBNET_ADDRESS_PREFIX

# Delegate subnets for ACA
az network vnet subnet update \
  --resource-group $VNET_RG \
  --vnet-name $VNET_NAME \
  --name $ACA_SUBNET_NAME \
  --delegations "Microsoft.App/managedEnvironments"


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

# Create private endpoint for Log Analytics workspace
az network private-endpoint create \
  --name "${LOG_ANALYTICS_WS}-PE" \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $(az monitor log-analytics workspace show \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WS \
  --query id -o tsv) \
  --group-id "workspace" \
  --connection-name "${LOG_ANALYTICS_WS}-PE-connection" \
  --location $LOCATION


# Get the subnet ID for the ACA environment
SUBNETID=$(az network vnet subnet show \
  --resource-group $VNET_RG \
  --vnet-name $VNET_NAME \
  --name $ACA_SUBNET_NAME \
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

# Get the ACA environment ID
ACA_ENV_ID=$(az containerapp env show \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Assign system-assigned managed identity to the ACA environment
az containerapp env identity assign \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --system-assigned

# Get the ACA environment's managed identity principal ID
ACA_ENV_MI_PRINCIPAL_ID=$(az containerapp env show \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --query identity.principalId -o tsv)

# Assign the Log Analytics Contributor role to the ACA environment's managed identity
az role assignment create \
  --assignee $ACA_ENV_MI_PRINCIPAL_ID \
  --role "Log Analytics Contributor" \
  --scope $(az monitor log-analytics workspace show \
  --resource-group $RESOURCE_GROUP \
  --workspace-name $LOG_ANALYTICS_WS \
  --query id -o tsv)

# Create a workload profile (if not already created)
az containerapp env workload-profile add \
 --workload-profile-name Consumption \
 --resource-group $RESOURCE_GROUP \
 --name $ACA_ENV_NAME \
 --workload-profile-type Consumption \
 --min-nodes 1 \
 --max-nodes 5

# Assign AcrPull role to the identity
az role assignment create \
  --assignee-object-id $ACA_ENV_MI_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPull" \
  --scope $ACR_ID


# Variables
PRIVATE_DNS_ZONE="privatelink.azurecontainerapps.io"
ACA_PRIVATE_ENDPOINT_NAME="VACPC-ACA-PE"
PE_VNET_ID=$(az network vnet show --resource-group $VNET_RG --name $VNET_NAME --query id -o tsv)
PE_SUBNET_ID=$(az network vnet subnet show --resource-group $VNET_RG --vnet-name $VNET_NAME --name $PE_SUBNET_NAME --query id -o tsv)

# Create Private Endpoint
az network private-endpoint create \
  --name $ACA_PRIVATE_ENDPOINT_NAME \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $ACA_ENV_ID \
  --group-id "managedEnvironments" \
  --connection-name "${ACA_PRIVATE_ENDPOINT_NAME}-connection" \
  --location $LOCATION

# Use existing private DNS zone which is in different subscription
# Use the existing DNS zone group for the private endpoint
# Link the private DNS zone which is in different subscription and resource group to the VNet

# Create managed identity for the Container App
az identity create \
    --name $IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION  

clientId=$(az identity show \
    --name $IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP \
    --query clientId -o tsv)

SERVICEBUS_NAME="VACPC-ServiceBus"
# Create a Container App Job event type
az containerapp job create \
    --name "aca-cst-job" \
    --resource-group $RESOURCE_GROUP \
    --environment $ACA_ENV_NAME \
    --trigger-type "Event" \
    --replica-timeout 7200 \
    --replica-retry-limit 1 \
    --replica-completion-count 1 \
    --parallelism 1 \
    --image "shrstcr.azurecr.io/shrst-cst-production:0d33ac00" \
    --cpu "2.0" --memory "4.0Gi" \
    --registry-identity 'system-environment' \
    --registry-server $ACR_NAME.azurecr.io \
    --mi-user-assigned $IDENTITY_NAME \
    --min-executions "0" \
    --max-executions "5" \
    --scale-rule-name "azure-servicebus-queue-rule" \
    --scale-rule-type "azure-servicebus" \
    --scale-rule-metadata "namespace=$SERVICEBUS_NAME" "queueName=shrst-cst-worker" "messageCount=1" "activationMessageCount=1" "activationQueueLength=1"\
    --scale-rule-identity $IDENTITY_NAME \
    --env-vars \
              AZURE_CLIENT_ID=$clientId \
              ENV_NAME="PROD" \
    --log-analytics-workspace-id $WORKSPACE_ID \
    --log-analytics-workspace-key $WORKSPACE_KEY \
    --tags "environment=production" "createdBy=script"


echo "Azure Container Apps environment and resources created successfully."


# Create Search Service
SEARCH_NAME="vacpc-cst-search"
SEARCH_PRIVATE_ENDPOINT_NAME="vacpc-cst-search-pe"
#create search service
az search service create \
  --name $SEARCH_NAME \
  --resource-group  $RESOURCE_GROUP \
  --location $LOCATION \
  --sku "standard" \
  --public-network-access Disabled \
  --tags "environment=production" "createdBy=script"

# Update the search service to use the managed identity
az search service update \
  --name $SEARCH_NAME \
  --resource-group $RESOURCE_GROUP \
  --identity-type SystemAssigned



#Create a private endpoint for the search service
az network private-endpoint create \
  --name $SEARCH_PRIVATE_ENDPOINT_NAME \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
  --group-id searchService \
  --connection-name vacpc-cst-search-connection \
  --location $LOCATION

# Use existing private DNS zone for the search service
# Create a private DNS zone for the search service
az network private-dns zone create \
  --resource-group $DNS_ZONE_RG \
  --name $SEARCH_DNS_ZONE_NAME  

# Link the private DNS zone to the VNet
# Create a DNS zone group for the private endpoint

### Create OpenAI service
OPENAI_NAME="vacpc-cst-openai"
OPENAI_PRIVATE_ENDPOINT_NAME="vacpc-cst-openai-pe"
OPENAI_LOCATION="canadaeast"

#Create open ai service with name vacpc-cst-openai
az cognitiveservices account create \
  --name $OPENAI_NAME \
  --resource-group $RESOURCE_GROUP \
  --kind OpenAI \
  --sku S0 \
  --location $OPENAI_LOCATION \
  --custom-domain "vacpccstopenai" \
  --tags "environment=production" "createdBy=script" \
  --assign-identity \
  --yes

# Create a private endpoint for the OpenAI service
az network private-endpoint create \
  --name $OPENAI_PRIVATE_ENDPOINT_NAME \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $(az cognitiveservices account show --name $OPENAI_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
  --group-id account \
  --connection-name vacpc-cst-openai-connection \
  --location $LOCATION

# Create a model deployment for the OpenAI service from foundry portal


### Create Document Intelligence service
DOCUMENT_INTELLIGENCE_NAME="vacpc-cst-doc-int"
DOCUMENT_INTELLIGENCE_LOCATION="canadacentral"
DOCUMENT_INTELLIGENCE_PRIVATE_ENDPOINT_NAME="vacpc-cst-doc-int-pe"

# Create Document Intelligence service
az cognitiveservices account create \
  --name $DOCUMENT_INTELLIGENCE_NAME \
  --resource-group $RESOURCE_GROUP \
  --kind "FormRecognizer" \
  --sku "S0" \
  --location $DOCUMENT_INTELLIGENCE_LOCATION \
  --tags "environment=production" "createdBy=script" \
  --custom-domain "vacpccstdocint" \
  --assign-identity \
  --yes

# Create a private endpoint for the Document Intelligence service
az network private-endpoint create \
  --name $DOCUMENT_INTELLIGENCE_PRIVATE_ENDPOINT_NAME \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $(az cognitiveservices account show --name $DOCUMENT_INTELLIGENCE_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) \
  --group-id account \
  --connection-name vacpc-cst-doc-int-connection  


# Get the principal ID of the managed identity of ACA
PRINCIPAL_ID=$(az containerapp env show --name $ACA_ENV_NAME --resource-group $RESOURCE_GROUP --query identity.principalId -o tsv)
# Get the principal ID of the managed identity
SEARCH_PRINCIPAL_ID=$(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query identity.principalId -o tsv)
# Get the principal ID of the OpenAI service managed identity
OPENAI_PRINCIPAL_ID=$(az cognitiveservices account show --name $OPENAI_NAME --resource-group $RESOURCE_GROUP --query identity.principalId -o tsv)
# Get the principal ID of the Document Intelligence service managed identity
DOCUMENT_INTELLIGENCE_PRINCIPAL_ID=$(az cognitiveservices account show --name $DOCUMENT_INTELLIGENCE_NAME --resource-group $RESOURCE_GROUP --query identity.principalId -o tsv)

# Assign the Search Service Contributor role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Service Contributor" \
    --scope $(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Assign the Search Index Data Contributor role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Index Data Contributor" \
    --scope $(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)


# Assign the Cognitive services OpenAI User role to the identity
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Cognitive Services OpenAI User" \
    --scope $(az cognitiveservices account show --name $OPENAI_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)


# Assign Cognitive services User role to the managed identity of ACA on Document Intelligence service
az role assignment create \
    --assignee-object-id $PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Cognitive Services User" \
    --scope $(az cognitiveservices account show --name $DOCUMENT_INTELLIGENCE_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Assign the Search Service Contributor role to the managed identity of the OpenAI service
az role assignment create \
    --assignee-object-id $OPENAI_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Service Contributor" \
    --scope $(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

# Assign the Search Index Data Contributor role to the managed identity of the OpenAI service
az role assignment create \
    --assignee-object-id $OPENAI_PRINCIPAL_ID \
    --assignee-principal-type ServicePrincipal \
    --role "Search Index Data Contributor" \
    --scope $(az search service show --name $SEARCH_NAME --resource-group $RESOURCE_GROUP --query id -o tsv)

