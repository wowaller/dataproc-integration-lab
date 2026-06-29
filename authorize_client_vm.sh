#!/bin/bash
# authorize_client_vm.sh
# Configures GCE instance metadata on a standalone VM to authorize it as a Dataproc client.
# This script must be run from a workstation with gcloud permissions to modify the VM.

set -euo pipefail

# Load central configuration
if [ -f config.env ]; then
  source config.env
else
  echo "ERROR: config.env not found. Please run this script from the project root."
  exit 1
fi

echo "===================================================="
echo "Configuring Dataproc Client Authorization Metadata"
echo "Project:      $PROJECT_ID"
echo "Target VM:    $VM_NAME"
echo "Cluster:      $CLUSTER_NAME"
echo "Region:       $REGION"
echo "===================================================="

# 1. Verify the VM exists and resolve its zone
echo "Locating VM '$VM_NAME'..."
VM_ZONE=$(gcloud compute instances list --filter="name=${VM_NAME}" --format="value(zone)" --project="$PROJECT_ID")

if [ -z "$VM_ZONE" ]; then
  echo "ERROR: VM '$VM_NAME' not found in project '$PROJECT_ID'."
  exit 1
fi
echo "Resolved VM Zone: $VM_ZONE"

# 2. Verify the Dataproc cluster exists and get its UUID
echo "Querying cluster '$CLUSTER_NAME' UUID..."
CLUSTER_UUID=$(gcloud dataproc clusters describe "${CLUSTER_NAME}" --region="${REGION}" --project="$PROJECT_ID" --format="value(clusterUuid)" 2>/dev/null)

if [ -z "$CLUSTER_UUID" ]; then
  echo "ERROR: Dataproc cluster '$CLUSTER_NAME' not found in region '$REGION' (project '$PROJECT_ID')."
  exit 1
fi
echo "Resolved Cluster UUID: $CLUSTER_UUID"

# 3. Apply the metadata to the VM
echo "Attaching authorization metadata to VM..."
gcloud compute instances add-metadata "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --metadata="dataproc-cluster-name=${CLUSTER_NAME},dataproc-cluster-uuid=${CLUSTER_UUID},dataproc-role=Master,dataproc-region=${REGION}"

echo "===================================================="
echo "SUCCESS: VM '$VM_NAME' is now authorized for cluster '$CLUSTER_NAME'!"
echo "You can now run Spark/Hadoop jobs from this VM."
echo "===================================================="
