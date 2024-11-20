#!/bin/bash

# Enable exit on error
set -e

# Parse arguments
while getopts ":g:n:z:l:v:" opt; do
  case $opt in
    g) RESOURCE_GROUP="$OPTARG" ;;
    n) VM_NAME="$OPTARG" ;;
    z) NEW_AZ="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    v) VAULT_NAME="$OPTARG" ;;
    *) usage ;;
  esac
done

# Function to display script usage message
usage() {
  cat << EOF

Usage:

$0 \\
  -g <resource-group> \\
  -n <vm-name> \\
  -z <new-az> \\
  -l <location> \\
  -v <vault-name>
EOF
  exit 1
}

# Check if all required arguments are provided
if [ -z "$RESOURCE_GROUP" ] || [ -z "$VAULT_NAME" ] || [ -z "$VM_NAME" ] || [ -z "$LOCATION" ] || [ -z "$NEW_AZ" ]; then
  echo "Error: All parameters are required."
  usage
fi

echo "Starting Availability Zone migration script for Azure VMs..."

az account show

# Function to display error messages
error_exit() {
  echo "Error: $1" >&2
  exit 1
}

# Function to clean invalid characters from tags
clean_tags() {
  local tags="$1"
  # Remove invalid characters
  tags=$(echo "$tags" | sed 's/[<>%&\\?\/{},]//g')
  tags=$(echo "$tags" | sed 's/": "/"="/g')
  echo "$tags"
}

# Function to get attributes of the original disk
get_disk_attributes() {
  local disk_name="$1"
  local resource_group="$2"
  
  echo "Getting attributes for disk $disk_name..."

  STORAGE_TYPE=$(az disk show --resource-group "$resource_group" --name "$disk_name" --query "sku.name" -o tsv)
  CACHE_SETTING=$(az disk show --resource-group "$resource_group" --name "$disk_name" --query "diskIOPSReadWrite" -o tsv)
  MAX_SHARES=$(az disk show --resource-group "$resource_group" --name "$disk_name" --query "maxShares" -o tsv)

  if [ -z "$STORAGE_TYPE" ]; then
    error_exit "Could not retrieve the storage type for disk $disk_name."
  fi

  echo "Attributes retrieved for $disk_name: Storage Type: $STORAGE_TYPE, Cache: $CACHE_SETTING, Max Shares: $MAX_SHARES"
}

# Function to wait for the completion of the "Take Snapshot" step
wait_for_snapshot_completion() {
  local job_id="$1"
  local resource_group="$2"
  local vault_name="$3"

  echo "Waiting for the completion of the 'Take Snapshot' step for job $job_id..."

  while true; do
    # Get job details
    TASK_STATUS=$(az backup job show --resource-group "$resource_group" --vault-name "$vault_name" --name "$job_id" \
      --query "properties.extendedInfo.tasksList[?taskId=='Take Snapshot'].status" -o tsv)

    if [ "$TASK_STATUS" == "Completed" ]; then
      echo "The 'Take Snapshot' step has been completed."
      break
    fi

    echo "The 'Take Snapshot' step is still in progress. Waiting..."
    sleep 10
  done
}

# Stop the VM
echo "Stopping VM $VM_NAME..."
az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME \
  || error_exit "Failed to stop the VM."

echo "Waiting for VM $VM_NAME to be fully stopped..."
az vm wait --resource-group $RESOURCE_GROUP --name $VM_NAME --custom "instanceView.statuses[?code=='PowerState/deallocated']" \
  || error_exit "VM $VM_NAME was not fully stopped."

echo "VM $VM_NAME stopped successfully."

# Create additional backup in Vault
echo "Starting on-demand backup of VM in Backup Vault..."
BACKUP_JOB_OUTPUT=$(az backup protection backup-now \
  --resource-group $RESOURCE_GROUP \
  --vault-name $VAULT_NAME \
  --container-name $VM_NAME \
  --item-name $VM_NAME \
  --backup-management-type AzureIaasVM \
  --retain-until "$(date -d '+7 days' +%d-%m-%Y)" -o tsv) \
  || error_exit "Failed to start on-demand backup."

# Debug output
# echo "Output of backup-now command:"
# echo "$BACKUP_JOB_OUTPUT"

# Extract Job ID from output using grep and regex
BACKUP_JOB_ID=$(echo "$BACKUP_JOB_OUTPUT" | grep -Eo "/backupJobs/[a-z0-9\-]+" | awk -F'/' '{print $3}')


# Validate if Job ID was captured correctly
if [ -z "$BACKUP_JOB_ID" ]; then
  error_exit "Failed to capture the Backup Job ID from the output."
fi

echo "On-demand backup requested. Job ID: $BACKUP_JOB_ID"
echo "Waiting for the backup completion..."

# Wait for backup job completion
# az backup job wait --resource-group $RESOURCE_GROUP --vault-name $VAULT_NAME --name $BACKUP_JOB_ID \
#   || error_exit "The backup was not completed successfully."

# Wait only for the completion of the "Take Snapshot" step
wait_for_snapshot_completion "$BACKUP_JOB_ID" "$RESOURCE_GROUP" "$VAULT_NAME"

echo "Backup completed successfully!"

# Get VM information
OS_DISK_NAME=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query "storageProfile.osDisk.name" -o tsv) \
  || error_exit "Failed to get OS disk information."
DATA_DISKS=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query "storageProfile.dataDisks[].name" -o tsv) \
  || error_exit "Failed to get data disks information."
NIC_ID=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query "networkProfile.networkInterfaces[0].id" -o tsv) \
  || error_exit "Failed to get NIC information."

# Create snapshot of OS disk
OS_SNAPSHOT_NAME="${OS_DISK_NAME}-snapshot"
az snapshot create --resource-group $RESOURCE_GROUP --source $OS_DISK_NAME --name $OS_SNAPSHOT_NAME --location $LOCATION \
  || error_exit "Failed to create OS disk snapshot."

echo "Waiting for snapshot creation to complete..."
az snapshot wait --resource-group $RESOURCE_GROUP --name $OS_SNAPSHOT_NAME --created \
  || error_exit "Failed to wait for snapshot creation completion."

# Create snapshots for data disks
for DISK in $DATA_DISKS; do
  SNAPSHOT_NAME="${DISK}-snapshot"
  az snapshot create --resource-group $RESOURCE_GROUP --source $DISK --name $SNAPSHOT_NAME --location $LOCATION \
    || error_exit "Failed to create data disk snapshot: $DISK."

  echo "Waiting for snapshot creation to complete..."
  az snapshot wait --resource-group $RESOURCE_GROUP --name $SNAPSHOT_NAME --created \
    || error_exit "Failed to wait for snapshot creation completion for disk: $DISK."

done

# Get the size (VM size) of the original VM
VM_SIZE=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query "hardwareProfile.vmSize" -o tsv)

# Check if VM size was found
if [ -z "$VM_SIZE" ]; then
  error_exit "Could not determine the VM size for the original VM."
fi

# Capture the tags of the original VM
VM_TAGS=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query "tags" -o json)

# Check if tags were captured
if [ -z "$VM_TAGS" ]; then
  error_exit "Could not capture the tags for the original VM."
fi

# Get attributes of OS disk
get_disk_attributes "$OS_DISK_NAME" "$RESOURCE_GROUP"

# Create a disk from the OS disk snapshot
NEW_OS_DISK_NAME="${OS_DISK_NAME}-az-${NEW_AZ}"
az disk create --resource-group $RESOURCE_GROUP --name $NEW_OS_DISK_NAME --source $OS_SNAPSHOT_NAME --location $LOCATION --zone $NEW_AZ \
  --sku $STORAGE_TYPE \
  || error_exit "Failed to create new OS disk."

az disk wait --resource-group $RESOURCE_GROUP --name $NEW_OS_DISK_NAME --created \
  || error_exit "Failed to wait for OS disk creation completion."

# Create disks for data disk snapshots
NEW_DATA_DISKS=()
for DISK in $DATA_DISKS; do
  SNAPSHOT_NAME="${DISK}-snapshot"
  NEW_DISK_NAME="${DISK}-az-${NEW_AZ}"
  get_disk_attributes "$DISK" "$RESOURCE_GROUP"
  az disk create --resource-group $RESOURCE_GROUP --name $NEW_DISK_NAME --source $SNAPSHOT_NAME --location $LOCATION --zone $NEW_AZ \
    --sku $STORAGE_TYPE \
    || error_exit "Failed to create data disk: $DISK."
  az disk wait --resource-group $RESOURCE_GROUP --name $NEW_DISK_NAME --created \
    || error_exit "Failed to wait for data disk creation completion: $DISK."
  NEW_DATA_DISKS+=($NEW_DISK_NAME)
done

# Get the OS type of the disk
OS_TYPE=$(az disk show --resource-group $RESOURCE_GROUP --name $NEW_OS_DISK_NAME --query "osType" -o tsv)

# Verificar se o tipo de sistema operacional foi encontrado
if [ -z "$OS_TYPE" ]; then
  error_exit "Failed to determine OS type for the new OS disk."
fi
# Clean the tags to remove invalid characters
CLEANED_VM_TAGS=$(clean_tags "$VM_TAGS")


# Delete the original VM
echo "Deleting the original VM..."
az vm delete --resource-group $RESOURCE_GROUP --name $VM_NAME --yes \
  || error_exit "Failed to delete the original VM"


# Recreate the VM in the new availability zone
echo "Recreating the VM in Availability Zone $NEW_AZ..."
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --location $LOCATION \
  --zone $NEW_AZ \
  --attach-os-disk $NEW_OS_DISK_NAME \
  --nics $NIC_ID \
  --os-type $OS_TYPE \
  --size $VM_SIZE \
  --tags $CLEANED_VM_TAGS \
  || error_exit "Failed to recreate the VM in Availability Zone $NEW_AZ."

# Attach the data disks to the new VM
for DISK in "${NEW_DATA_DISKS[@]}"; do
  echo "Attaching data disk: $DISK..."
  az vm disk attach --resource-group $RESOURCE_GROUP --vm-name $VM_NAME --name $DISK \
    || error_exit "Failed to attach data disk: $DISK."
done

echo "The VM has been successfully recreated in Availability Zone $NEW_AZ."


# Clean up old disks and snapshots

# Delete old data disk snapshots, iterating over the disk list
echo "Deleting old data disk snapshots..."
for DISK in "${DATA_DISKS[@]}"; do
  SNAPSHOT_NAME="${DISK}-snapshot"
  az snapshot delete --resource-group $RESOURCE_GROUP --name $SNAPSHOT_NAME || echo "Failed to delete the snapshot for data disk: $DISK."
done

# Delete old data disks, iterating over the disk list
echo "Deleting old data disks..."
for DISK in "${DATA_DISKS[@]}"; do
  az disk delete --resource-group $RESOURCE_GROUP --name $DISK --yes || echo "Failed to delete the data disk: $DISK."
done

# Delete snapshot for the old OS disk
echo "Deleting snapshot for the old OS disk..."
az snapshot delete --resource-group $RESOURCE_GROUP --name $OS_SNAPSHOT_NAME || echo "Failed to delete the snapshot for the OS disk."

# Delete the old OS disk
echo "Deleting the old OS disk..."
az disk delete --resource-group $RESOURCE_GROUP --name $OS_DISK_NAME --yes || echo "Failed to delete the OS disk."

echo "The old disks and snapshots have been successfully deleted."
echo "The VM $VM_NAME has been successfully migrated to Availability Zone $NEW_AZ."
