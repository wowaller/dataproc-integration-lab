#!/bin/bash
# cleanup_resources.sh
# Safely tears down ONLY the resources created for this lab, leaving pre-existing resources intact.

set -euo pipefail

# Load central configuration
if [ -f config.env ]; then
  source config.env
else
  echo "ERROR: config.env not found. Please run this script from the project root."
  exit 1
fi

echo "===================================================="
echo "Starting Safe Cleanup of Dataproc Client VM Lab"
echo "Project: $PROJECT_ID"
echo "This will delete ONLY the resources created by you:"
echo "  - Standalone VM: $VM_NAME"
echo "  - GCS Bucket:     gs://$BUCKET_NAME"
echo "It will NOT touch cluster-9c32 or the local-lab network."
echo "===================================================="

read -p "Are you sure you want to delete these lab resources? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 1
fi

# 1. Delete VM
# Query the zone of the VM dynamically
VM_ZONE=$(gcloud compute instances list --filter="name=${VM_NAME}" --format="value(zone)" --project="$PROJECT_ID")

if [ -n "$VM_ZONE" ]; then
  echo "Deleting Client VM: $VM_NAME in zone: $VM_ZONE..."
  gcloud compute instances delete "$VM_NAME" --zone="$VM_ZONE" --project="$PROJECT_ID" --quiet
else
  echo "Client VM $VM_NAME already deleted/does not exist."
fi

# 2. Delete GCS Bucket
if gsutil ls -b "gs://$BUCKET_NAME" >/dev/null 2>&1; then
  echo "Deleting GCS bucket: gs://$BUCKET_NAME..."
  gsutil rm -r "gs://$BUCKET_NAME" || true
else
  echo "GCS bucket gs://$BUCKET_NAME already deleted/does not exist."
fi

echo "===================================================="
echo "Safe Cleanup Completed Successfully!"
echo "===================================================="
