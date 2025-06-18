#!/bin/bash

# Variables
RESOURCE_GROUP="aca-workshop-rg"
LOCATION="canadacentral"
VNET_NAME="acavnet"
SUBNET_NAME="acaSubnet"
ACA_ENV_NAME="acaenv"
ACA_NAME="demoapp"
LOG_ANALYTICS_WS="aca-law"
DAPR_APP_ID="dapr-app"
ACR_NAME="academoregistry"
CONTAINER_IMAGE="academoregistry.azurecr.io/demoapp:latest"
WORKLOAD_PROFILE_NAME_CONSUMPTION="Consumption"
WORKLOAD_PROFILE_NAME_DEDICATED="D4"
PE_SUBNET_NAME="PESubnet"
SERVICEBUS_NAME="aca-asb"
RESOURCES_SNET_NAME="acaResourcesSubnet"

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create VNet and subnet
az network vnet create \
  --resource-group $RESOURCE_GROUP \
  --name $VNET_NAME \
  --address-prefixes 10.0.0.0/20 \
  --subnet-name $SUBNET_NAME \
  --subnet-prefix 10.0.0.0/24

# Create a dedicated subnet for private endpoints
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $PE_SUBNET_NAME \
  --address-prefixes "10.0.1.0/28"
# Create a subnet for resources that need to access the ACA environment
az network vnet subnet create \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $RESOURCES_SNET_NAME \
  --address-prefixes "10.0.2.0/27"

# Delegate subnet to ACA
az network vnet subnet update \
  --name $SUBNET_NAME \
  --vnet-name $VNET_NAME \
  --resource-group $RESOURCE_GROUP \
  --delegations "Microsoft.App/environments"

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

# Create ACA environment with VNet and Log Analytics and system assigned managed identity
az containerapp env create \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --logs-workspace-id $WORKSPACE_ID \
  --logs-workspace-key $WORKSPACE_KEY \
  --infrastructure-subnet-resource-id $(az network vnet subnet show \
      --resource-group $RESOURCE_GROUP \
      --vnet-name $VNET_NAME \
      --name $SUBNET_NAME \
      --query id -o tsv) \
  --enable-workload-profiles \
  --internal-only \
  --tags "createdBy=script" "environment=dev"

# Enable system assigned managed identity for the Container App environment
az containerapp env identity assign \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --system-assigned


managedIdentity=$(az containerapp env show \
  --name $ACA_ENV_NAME \
  --resource-group $RESOURCE_GROUP \
  --query identity.principalId -o tsv)

# Create container registry (if not already created)
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Premium \
  --location $LOCATION 

ACR_ID=$(az acr show \
      --resource-group $RESOURCE_GROUP \
      --name $ACR_NAME \
      --query id -o tsv)

# Create private endpoint for the container registry
az network private-endpoint create \
  --resource-group $RESOURCE_GROUP \
  --name acrPrivateEndpoint \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
    --private-connection-resource-id $ACR_ID \
  --group-id registry \
  --connection-name acrPrivateConnection \
    --location $LOCATION    

# Ensure the ACR is accessible via private endpoint
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name privatelink.azurecr.io 

# Create a DNS zone group for the private endpoint
az network private-endpoint dns-zone-group create \
  --resource-group $RESOURCE_GROUP \
  --endpoint-name acrPrivateEndpoint \
  --name acrDnsZoneGroup \
  --private-dns-zone privatelink.azurecr.io \
  --zone-name privatelink.azurecr.io



#Assign ACRPull permission to the ACA environment's managed identity
az role assignment create \
  --assignee $(az containerapp env show \
      --name $ACA_ENV_NAME \
      --resource-group $RESOURCE_GROUP \
      --query identity.principalId -o tsv) \
  --role AcrPull \
  --scope $ACR_ID


# Service Bus namespace (if not already created)
az servicebus namespace create \
  --resource-group $RESOURCE_GROUP \
  --name $SERVICEBUS_NAME \
  --location $LOCATION \
  --sku Premium \
  --tags "createdBy=script" "environment=dev"   

# Create a Service Bus Queue
az servicebus queue create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $SERVICEBUS_NAME \
  --name "demoqueue" \
  --max-size-in-megabytes 1024 \
  --enable-partitioning true 

az servicebus queue create \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $SERVICEBUS_NAME \
  --name "demorcvqueue" \
  --max-size-in-megabytes 1024 \
  --enable-partitioning true 

SERVICE_BUS_CONNECTION_STRING=$(az servicebus namespace authorization-rule keys list \
  --resource-group $RESOURCE_GROUP \
  --namespace-name $SERVICEBUS_NAME \
  --name RootManageSharedAccessKey \
  --query primaryConnectionString -o tsv)

# Create private endpoint for the Service Bus namespace
az network private-endpoint create \
  --name sbPrivateEndpoint \
  --resource-group $RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --subnet $PE_SUBNET_NAME \
  --private-connection-resource-id $(az servicebus namespace show \
      --resource-group $RESOURCE_GROUP \
      --name $SERVICEBUS_NAME --query id -o tsv) \
    --group-id namespace \
    --connection-name sbPrivateConnection \
    --location $LOCATION

# Create a DNS zone for the Service Bus private endpoint
az network private-dns zone create \
    --resource-group $RESOURCE_GROUP \
    --name privatelink.servicebus.windows.net

# Create a DNS zone group for the Service Bus private endpoint
az network private-endpoint dns-zone-group create \
    --resource-group $RESOURCE_GROUP \
    --endpoint-name sbPrivateEndpoint \
    --name sbDnsZoneGroup \
    --private-dns-zone privatelink.servicebus.windows.net \
    --zone-name privatelink.servicebus.windows.net

# Create user managed identity for the Container App
IDENTITY_NAME="acaIdentity"
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP  

# Get the identity's principal ID
PRINCIPAL_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

#Assign RBAC for service bus Sender and receiver roles to the identity
az role assignment create \
  --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Service Bus Data Sender" \
  --scope $(az servicebus namespace show \
      --resource-group $RESOURCE_GROUP \
      --name $SERVICEBUS_NAME \
        --query id -o tsv)

az role assignment create \
  --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Service Bus Data Receiver" \
    --scope $(az servicebus namespace show \
        --resource-group $RESOURCE_GROUP \
        --name $SERVICEBUS_NAME \
            --query id -o tsv)



# Create a workload profile (if not already created)
az containerapp env workload-profile add \
 --workload-profile-name $WORKLOAD_PROFILE_NAME_CONSUMPTION \
 --resource-group $RESOURCE_GROUP \
 --name $ACA_ENV_NAME \
 --workload-profile-type Consumption \
 --min-nodes 0 \
 --max-nodes 2

clientId=$(az identity show \
        --name $IDENTITY_NAME \
        --resource-group $RESOURCE_GROUP \
        --query clientId \
        --output tsv)

# Create a Container App Job (example: Cron job)
              
az containerapp job create \
    --name "aca-job-sender" \
    --resource-group $RESOURCE_GROUP \
    --environment $ACA_ENV_NAME \
    --trigger-type "Event" \
    --replica-timeout 1800  \
    --replica-retry-limit 1 \
    --replica-completion-count 1 \
    --parallelism 1 \
    --image "academoregistry.azurecr.io/sbsender:v1" \
    --cpu "0.25" --memory "0.5Gi" \
    --registry-identity 'system-environment' \
    --registry-server $ACR_NAME.azurecr.io \
    --mi-user-assigned $IDENTITY_NAME \
    --min-executions "0" \
    --max-executions "10" \
    --scale-rule-name "azure-servicebus-queue-rule" \
    --scale-rule-type "azure-servicebus" \
    --scale-rule-metadata "namespace=$SERVICEBUS_NAME" "queueName=demoqueue" "messageCount='5'" \
    --scale-rule-auth "connection=connection-string-secret" \
    --secrets "connection-string-secret=$SERVICE_BUS_CONNECTION_STRING" \
    --env-vars \
              AZURE_CLIENT_ID=$clientId \
              FULLY_QUALIFIED_NAMESPACE="${SERVICEBUS_NAME}.servicebus.windows.net" \
              INPUT_QUEUE_NAME="demoqueue" \
              MIN_NUMBER="1" \
              MAX_NUMBER="10" \
              MESSAGE_COUNT="100" \
              SEND_TYPE="list" 1>/dev/null

az containerapp job create \
          --name "aca-job-processor" \
            --resource-group $RESOURCE_GROUP \
            --environment $ACA_ENV_NAME \
            --trigger-type "Schedule" \
            --replica-timeout 1800  \
            --replica-retry-limit 1 \
            --replica-completion-count 1 \
            --parallelism 1 \
            --cron-expression "*/5 * * * *" \
            --image "academoregistry.azurecr.io/sbprocessor:v1" \
            --cpu "0.25" --memory "0.5Gi" \
            --registry-identity 'system-environment' \
            --registry-server $ACR_NAME.azurecr.io \
            --mi-user-assigned $IDENTITY_NAME \
            --env-vars \
                AZURE_CLIENT_ID=$clientId \
                FULLY_QUALIFIED_NAMESPACE="${SERVICEBUS_NAME}.servicebus.windows.net" \
                INPUT_QUEUE_NAME="demoqueue" \
                OUTPUT_QUEUE_NAME="demorcvqueue" \
                MAX_MESSAGE_COUNT="20" \
                MAX_WAIT_TIME="5"                 

az containerapp job create \
    --name "aca-job-receive" \
    --resource-group $RESOURCE_GROUP \
    --environment $ACA_ENV_NAME \
    --trigger-type "Event" \
    --replica-timeout 1800  \
    --replica-retry-limit 1 \
    --replica-completion-count 1 \
    --parallelism 1 \
    --image "academoregistry.azurecr.io/sbreceiver:v1" \
    --cpu "0.25" --memory "0.5Gi" \
    --registry-identity 'system-environment' \
    --registry-server $ACR_NAME.azurecr.io \
    --mi-user-assigned $IDENTITY_NAME \
    --min-executions "0" \
    --max-executions "10" \
    --scale-rule-name "azure-servicebus-queue-rule" \
    --scale-rule-type "azure-servicebus" \
    --scale-rule-metadata "namespace=$SERVICEBUS_NAME" "queueName=demorcvqueue" "messageCount='5'" \
    --scale-rule-auth "connection=connection-string-secret" \
    --secrets "connection-string-secret=$SERVICE_BUS_CONNECTION_STRING" \
    --env-vars \
              AZURE_CLIENT_ID=$clientId \
              FULLY_QUALIFIED_NAMESPACE="${SERVICEBUS_NAME}.servicebus.windows.net" \
              OUTPUT_QUEUE_NAME="demorcvqueue" \
              MAX_MESSAGE_COUNT="20" \
              MAX_WAIT_TIME="5" 
 

#Assign the user managed identity to the sender job
az containerapp job identity assign \
    --name "aca-sender-job" \
    --resource-group $RESOURCE_GROUP \
    --user-assigned "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$IDENTITY_NAME"  


echo "Azure Container Apps environment and resources created successfully."