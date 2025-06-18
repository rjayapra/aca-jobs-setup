RESOURCE_GROUP="aca-workshop-rg"
LOCATION="canadacentral"
ACR_NAME="academoregistry"

senderImageName="sbsender"
processorImageName="sbprocessor"
receiverImageName="sbreceiver"

images=($senderImageName $processorImageName $receiverImageName)
filenames=(sbsender.py sbprocessor.py sbreceiver.py)
tag="v1"

# Use a for loop to build the docker images using the array index
for index in ${!images[@]}; do
    # Build the docker image for linux/amd64
    docker build --platform linux/amd64 -t ${images[$index]}:$tag -f Dockerfile --build-arg FILENAME=${filenames[$index]} .
done

az acr login --name $ACR_NAME -g $RESOURCE_GROUP

# Retrieve ACR login server. Each container image needs to be tagged with the loginServer name of the registry. 
loginServer=$(az acr show --name $ACR_NAME -g $RESOURCE_GROUP --query loginServer --output tsv)

# Use a for loop to tag and push the local docker images to the Azure Container Registry
for index in ${!images[@]}; do
  # Tag the local sender image with the loginServer of ACR
  docker tag ${images[$index],,}:$tag $loginServer/${images[$index],,}:$tag

  # Push the container image to ACR
  docker push $loginServer/${images[$index],,}:$tag
done