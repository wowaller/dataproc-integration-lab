#!/bin/bash
# provision_resources.sh
# Provisions the GCS bucket and the standalone Client VM (letting GCP auto-select the zone) in the existing local-lab network.

set -euo pipefail

# Load central configuration
if [ -f config.env ]; then
  source config.env
else
  echo "ERROR: config.env not found. Please run this script from the project root."
  exit 1
fi

NETWORK_NAME="local-lab"
SUBNET_NAME="local-lab-us"

echo "===================================================="
echo "Starting Provisioning of Dataproc Integration VM"
echo "Project:      $PROJECT_ID"
echo "Region:       $REGION"
echo "VPC Subnet:   $SUBNET_NAME"
echo "VM Type:      n4-standard-4"
echo "Target Cluster: $CLUSTER_NAME"
echo "===================================================="

# 1. Enable APIs
echo "Enabling necessary APIs (compute, dataproc)..."
gcloud services enable \
  compute.googleapis.com \
  dataproc.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID"

# 2. Create Cloud Storage Bucket
if ! gsutil ls -b "gs://$BUCKET_NAME" >/dev/null 2>&1; then
  echo "Creating Cloud Storage bucket: gs://$BUCKET_NAME..."
  gsutil mb -p "$PROJECT_ID" -c standard -l "$REGION" "gs://$BUCKET_NAME"
else
  echo "Storage bucket gs://$BUCKET_NAME already exists."
fi

# Check if the VM already exists and get its zone
VM_ZONE=${VM_ZONE:-""}
EXISTING_ZONE=$(gcloud compute instances list --filter="name=${VM_NAME}" --format="value(zone)")

if [ -z "$EXISTING_ZONE" ]; then
  echo "Creating Standalone Client VM: $VM_NAME (n4-standard-4, Debian 12)..."
  # Resolve zone argument if specified
  ZONE_ARG=""
  if [ -n "$VM_ZONE" ]; then
    ZONE_ARG="--zone=$VM_ZONE"
  fi
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --subnet="$SUBNET_NAME" \
    $ZONE_ARG \
    --machine-type=n4-standard-4 \
    --image-project=debian-cloud \
    --image-family=debian-12 \
    --boot-disk-size=50 \
    --scopes=cloud-platform \
    --metadata="startup-script=apt-get update && apt-get install -y git gnupg curl"
    
  # Query the zone of the newly created VM
  VM_ZONE=$(gcloud compute instances list --filter="name=${VM_NAME}" --format="value(zone)")
else
  echo "Standalone Client VM $VM_NAME already exists in zone: $EXISTING_ZONE."
  VM_ZONE="$EXISTING_ZONE"
fi

# Apply the Dataproc authorization metadata using the new standalone script
chmod +x authorize_client_vm.sh
VM_NAME="$VM_NAME" CLUSTER_NAME="$CLUSTER_NAME" REGION="$REGION" ./authorize_client_vm.sh

# Write the zone to a temp file for run_lab.sh
echo "$VM_ZONE" > /tmp/dataproc_client_vm_zone.txt

echo "===================================================="
echo "Provisioning Completed Successfully!"
echo "Your standalone Client VM: $VM_NAME is in zone: $VM_ZONE"
echo "===================================================="
