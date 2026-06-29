#!/bin/bash
# prepare_packages_v2.sh
# Packages the entire Spark/Hadoop/Hive/Iceberg/Delta environment and configurations
# directly from the active Dataproc master node, and stages it in GCS as a single payload.

set -euo pipefail

PROJECT_ID=$(gcloud config get-value project)
BUCKET_NAME="dataproc-client-lab-${PROJECT_ID}"
CLUSTER_NAME="jmsau-test"
CLUSTER_ZONE="us-central1-b"

PAYLOAD_NAME="dataproc-client-payload.tar.gz"

echo "===================================================="
echo "Starting Mirror Staging (V2 - Single Payload)"
echo "Project:      $PROJECT_ID"
echo "Target GCS:   gs://$BUCKET_NAME/payload/$PAYLOAD_NAME"
echo "Source:       $CLUSTER_NAME-m-0"
echo "===================================================="

# 1. Verify staging bucket exists
if ! gsutil ls -b "gs://$BUCKET_NAME" >/dev/null 2>&1; then
  echo "Staging bucket gs://$BUCKET_NAME does not exist. Creating it..."
  gsutil mb -p "$PROJECT_ID" -c standard -l "us-central1" "gs://$BUCKET_NAME"
fi

# 2. Package and stage the entire client payload from master
echo "Checking if staged payload already exists in GCS..."
if ! gsutil ls "gs://$BUCKET_NAME/payload/$PAYLOAD_NAME" >/dev/null 2>&1; then
  echo "Payload not found in GCS. Attempting to package from active cluster..."
  
  echo "SSHing into master node to package /usr/lib and /etc configurations..."
  gcloud compute ssh "${CLUSTER_NAME}-m-0" \
    --project="$PROJECT_ID" \
    --zone="$CLUSTER_ZONE" \
    --tunnel-through-iap \
    --command="echo '=== Packaging directories on Master ===' && \
      (sudo tar -chzf /tmp/$PAYLOAD_NAME --ignore-failed-read \
        -C / \
        usr/lib/hadoop \
        usr/lib/hadoop-hdfs \
        usr/lib/hadoop-yarn \
        usr/lib/hadoop-mapreduce \
        usr/lib/spark \
        usr/lib/hive \
        usr/lib/iceberg \
        usr/lib/delta \
        usr/local/share/google/dataproc \
        etc/hadoop/conf \
        etc/spark/conf \
        etc/hive/conf || [ \$? -eq 1 ]) && \
      echo '=== Uploading payload to GCS ===' && \
      gsutil cp /tmp/$PAYLOAD_NAME gs://$BUCKET_NAME/payload/$PAYLOAD_NAME && \
      echo '=== Cleaning up Master ===' && \
      sudo rm -f /tmp/$PAYLOAD_NAME"
  echo "Payload successfully packaged and staged in GCS."
else
  echo "Payload $PAYLOAD_NAME is already staged in GCS."
fi

echo "===================================================="
echo "Mirror Staging Completed Successfully!"
echo "===================================================="
