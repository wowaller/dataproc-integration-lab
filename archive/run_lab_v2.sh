#!/bin/bash
# run_lab_v2.sh
# Orchestrator for Dataproc Client VM V2 (Single Payload Mirror Mode).
# Provisions a new test VM (dataproc-client-vm-v2) and configures it.

set -euo pipefail

# Configuration
PROJECT_ID=$(gcloud config get-value project)
export VM_NAME="dataproc-client-vm-v2" # Exported so provision_resources.sh uses it
BUCKET_NAME="dataproc-client-lab-${PROJECT_ID}"

export CLUSTER_NAME="jmsau-test"
CLUSTER_ZONE="us-central1-b"

echo "===================================================="
echo "🚀 STARTING DATAPROC INTEGRATION LAB V2 (MIRROR MODE)"
echo "Target Cluster:   $CLUSTER_NAME"
echo "New Test VM Name: $VM_NAME"
echo "===================================================="

# 1. Provision Infrastructure (VM & Bucket)
echo "Step 1: Provisioning GCP Resources (VM & Bucket)..."
chmod +x provision_resources.sh
./provision_resources.sh

# Read the zone where the VM was actually created
VM_ZONE=$(cat /tmp/dataproc_client_vm_zone.txt)
echo "Resolved Standalone VM Zone: $VM_ZONE"

# 2. Wait for ssh availability on VM
echo "Step 2: Waiting for VM SSH availability..."
sleep 10  # Give VM a few seconds to initialize sshd fully

# 3. Copy configuration scripts to the Client VM
echo "Step 3: Copying setup_v2 and verification scripts to Client VM..."
gcloud compute scp \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  scripts/setup_client_v2.sh scripts/verify_client.sh "${VM_NAME}:/tmp/"

# 4. Execute setup script on the Client VM
echo "Step 4: Running setup_v2 script on Client VM (extracting mirror payload)..."
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  --command="chmod +x /tmp/setup_client_v2.sh /tmp/verify_client.sh && /tmp/setup_client_v2.sh ${BUCKET_NAME}"

# 5. Execute verification tests on the Client VM
echo "Step 5: Running integration verification tests on Client VM..."
MASTER_FQDN="${CLUSTER_NAME}-m-0.${CLUSTER_ZONE}.c.${PROJECT_ID}.internal"
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  --command="chmod +x /tmp/verify_client.sh && /tmp/verify_client.sh ${MASTER_FQDN}"

echo "===================================================="
echo "🎉 LAB ORCHESTRATION V2 COMPLETED SUCCESSFULLY!"
echo "===================================================="
echo "Your standalone VM is fully configured and verified."
echo "You can manually SSH into the VM to test:"
echo "  gcloud compute ssh $VM_NAME --zone=$VM_ZONE --tunnel-through-iap"
echo "To clean up all resources (including the v2 VM), run:"
echo "  VM_NAME=$VM_NAME ./cleanup_resources.sh"
echo "===================================================="
