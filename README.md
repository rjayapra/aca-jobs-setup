# ACA Setup Guide

This README provides instructions for setting up Azure Container Apps (ACA) using `setup_aca.sh` and for building and pushing container images using `build_push.sh`.

## Prerequisites

- Azure CLI installed and logged in
- Docker installed and running
- Access to an Azure subscription

## Architecture 
The following diagram shows the architecture and network topology of the sample:

![architecture](image.png)

Microsoft.App/jobs: this samples deploys the following jobs:
Sender job: this is a manually triggered job that sends a configurable amount of messages to the parameters queue in the Azure Service Bus namespace. The payload of each message contains a random positive integer number comprised in a configurable range.
Processor job: this is a scheduled job that reads the messages from the parameters queue in the Azure Service Bus namespace, calculates the Fibonacci number for the actual parameter, and writes the result in the results queue in the same namespace.
Receiver job: this is an event-driven job which execution is triggered by each message in the results queue. The job reads the result and logs it.

The following diagram shows message flow ;

![message flow](image-1.png)

Here are the steps of the message flow:

A job administrator starts the sender job using the az containerapp job start Azure CLI command.
The sender job writes a list of messages to the parameters queue, each containing a random positive integer within a pre-defined range.
The processor job reads the messages from the parameters queue
The processor job calculates the Fibonacci number for the actual integer and writes the result in the results queue in the same namespace.
The receiver job reads the messages from the results queue.
The receiver job writes the results to the standard output that is logged to the Azure Log Analytics workspace.

## 1. Setting Up Azure Container Apps

The `setup_aca.sh` script automates the creation and configuration of Azure resources required for ACA.

### Usage

```bash
./setup_aca.sh
```

**What it does:**
- Creates a resource group
- Sets up an Azure Container Registry (ACR)
- Deploys an Azure Container App environment
- Deploys Service bus with 2 queues

> **Note:** Review the script for configurable variables (e.g., resource group name, location).


## 2. Building and Pushing Container Images

The `build_push.sh` script builds your Docker image and pushes it to the Azure Container Registry.

### Usage

```bash
./build_push.sh <image-name> <acr-name>
```

- `<image-name>`: Name/tag for your Docker image (e.g., `myapp:latest`)
- `<acr-name>`: Name of your Azure Container Registry

**What it does:**
- Builds the Docker image from your local Dockerfile
- Logs in to ACR
- Tags and pushes the image to your ACR

## Example Workflow

1. Run `setup_aca.sh` to provision Azure resources.
2. Build and push your image:

    ```bash
    ./build_push.sh myapp:latest myacrname
    ```

3. Deploy your image to ACA using the Azure CLI or portal.

## Troubleshooting

- Ensure you have the necessary permissions in your Azure subscription.
- Verify Docker is running before building images.
- Check Azure CLI is authenticated (`az login`).

## References

- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)
- [Azure CLI Documentation](https://learn.microsoft.com/cli/azure/)
