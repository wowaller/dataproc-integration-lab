#!/bin/bash
# run_lab.sh
# Main orchestration script to provision, configure, and verify the Dataproc Client VM integration.
# Utilizes a high-speed internal mirroring strategy to copy pre-installed Spark/Hadoop/Hive from the master node.

set -euo pipefail

# Load central configuration
if [ -f config.env ]; then
  source config.env
else
  echo "ERROR: config.env not found. Please run this script from the project root."
  exit 1
fi

echo "===================================================="
echo "🚀 STARTING DATAPROC INTEGRATION LAB ORCHESTRATION"
echo "Existing Cluster: $CLUSTER_NAME (in $CLUSTER_ZONE)"
echo "VM Name:          $VM_NAME"
echo "===================================================="

# 1. Provision Infrastructure (VM & Bucket)
echo "Step 1: Provisioning GCP Resources (VM & Bucket)..."
chmod +x provision_resources.sh
./provision_resources.sh

# Read the zone where the VM was actually created
VM_ZONE=$(cat /tmp/dataproc_client_vm_zone.txt)
echo "Resolved Standalone VM Zone: $VM_ZONE"

# 2. Wait for ssh availability on Dataproc master and VM
echo "Step 2: Waiting for VM and Cluster SSH availability..."
sleep 10  # Give VMs a few seconds to initialize sshd fully

# 3. Copy configuration scripts to the Client VM
echo "Step 3: Copying setup and verification scripts to Client VM..."
gcloud compute scp \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  scripts/setup_client.sh scripts/verify_integration.sh "${VM_NAME}:/tmp/"

# 4. Execute setup script on the Client VM
echo "Step 4: Running setup script on Client VM (unpacking payload & applying configs)..."
MASTER_FQDN="${CLUSTER_NAME}-m-0.${CLUSTER_ZONE}.c.${PROJECT_ID}.internal"
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  --command="chmod +x /tmp/setup_client.sh /tmp/verify_integration.sh && /tmp/setup_client.sh ${BUCKET_NAME} ${CLUSTER_NAME} ${MASTER_FQDN} ${PROJECT_ID} ${CLUSTER_ZONE}"

# 5. Execute verification tests on the Client VM
echo "Step 5: Running integration verification tests on Client VM..."
gcloud compute ssh "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$VM_ZONE" \
  --tunnel-through-iap \
  --command="chmod +x /tmp/verify_integration.sh && /tmp/verify_integration.sh"

echo "===================================================="
echo "🎉 LAB ORCHESTRATION COMPLETED SUCCESSFULLY!"
echo "===================================================="
echo "Your standalone VM is fully configured and verified."
echo "You can manually SSH into the VM to play around:"
echo "  gcloud compute ssh $VM_NAME --zone=$VM_ZONE --tunnel-through-iap"
echo "To clean up all resources, run:"
echo "  ./cleanup_resources.sh"
echo "===================================================="
