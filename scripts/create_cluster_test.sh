#!/bin/bash
# scripts/create_cluster_test.sh
# Test Dataproc cluster creation script adapted for us-central1 environment.

set -euo pipefail

# Dynamically resolve the active GCP project
PROJECT_ID=$(gcloud config get-value project 2>/dev/null || echo "")
if [ -z "$PROJECT_ID" ]; then
    echo "Error: No active gcloud project found. Please run 'gcloud config set project <PROJECT_ID>' first."
    exit 1
fi

CLUSTER_NAME="jmsau-test"
REGION="us-central1"
ZONE="us-central1-b"
SUBNET="local-lab-us"
BUCKET="dataproc-client-lab-${PROJECT_ID}"

# MySQL Metastore Configuration (using the provided IP/credentials)
DB_IP="10.13.160.3"
DB_USER="admin"
DB_PASS="wowaller6275"
DB_NAME="hive" 

echo "===================================================="
echo "Creating TEST Dataproc cluster: ${CLUSTER_NAME}"
echo "Project:                        ${PROJECT_ID}"
echo "Region:                         ${REGION}"
echo "Zone:                           ${ZONE}"
echo "Subnet:                         ${SUBNET}"
echo "Staging Bucket:                 gs://${BUCKET}"
echo "External Metastore:             ${DB_IP} (User: ${DB_USER})"
echo "===================================================="

# Ensure the staging bucket exists
if ! gsutil ls -b "gs://${BUCKET}" >/dev/null 2>&1; then
    echo "Creating staging bucket gs://${BUCKET}..."
    gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${BUCKET}"
fi

gcloud dataproc clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --zone="${ZONE}" \
    --subnet="${SUBNET}" \
    --no-address \
    --bucket="${BUCKET}" \
    --enable-component-gateway \
    --num-masters 3 \
    --master-machine-type n4-standard-16 \
    --master-boot-disk-type hyperdisk-balanced \
    --master-boot-disk-size 500 \
    --num-workers 2 \
    --worker-machine-type n4-standard-32 \
    --worker-boot-disk-type hyperdisk-balanced \
    --worker-boot-disk-size 500 \
    --image-version 2.3-rocky9 \
    --optional-components ICEBERG,DELTA,FLINK,JUPYTER,ZOOKEEPER \
    --scopes 'https://www.googleapis.com/auth/cloud-platform' \
    --tags bigdata \
    --properties "spark:spark.dataproc.engine=lightningEngine,\
spark:spark.dataproc.lightningEngine.runtime=default,\
hive:javax.jdo.option.ConnectionURL=jdbc:mysql://${DB_IP}/${DB_NAME}?createDatabaseIfNotExist=true,\
hive:javax.jdo.option.ConnectionDriverName=com.mysql.cj.jdbc.Driver,\
hive:javax.jdo.option.ConnectionUserName=${DB_USER},\
hive:javax.jdo.option.ConnectionPassword=${DB_PASS},\
hive:hive.metastore.schema.verification=false,\
hive:datanucleus.schema.autoCreateAll=true"

echo "===================================================="
echo "Test Cluster '${CLUSTER_NAME}' creation command submitted."
echo "===================================================="
