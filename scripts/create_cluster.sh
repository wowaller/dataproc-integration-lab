#!/bin/bash
# scripts/create_cluster.sh
# Reconstructed Dataproc cluster creation script with external MySQL Hive metastore.

set -euo pipefail

PROJECT_ID="jms-au-495809"
CLUSTER_NAME="jmsau"
REGION="australia-southeast2"
ZONE="australia-southeast2-a"
SUBNET="jmsau-subnet-bgd-pro"
STAGING_BUCKET="dataproc-stagingdir-au"
WAREHOUSE_BUCKET="bigdata-pro"
DEFAULT_FS_BUCKET="bigdata-pro"

# MySQL Metastore Configuration
DB_IP="10.79.109.28"
DB_USER="hive"
DB_PASS="Shyf_2020"
DB_NAME="hive" # Change this if the target database name is different (e.g. metastore)

echo "===================================================="
echo "Creating Dataproc cluster: ${CLUSTER_NAME}"
echo "Project:                   ${PROJECT_ID}"
echo "Region:                    ${REGION}"
echo "Subnet:                    ${SUBNET}"
echo "Staging Bucket:            gs://${STAGING_BUCKET}"
echo "Warehouse Bucket:          gs://${WAREHOUSE_BUCKET}"
echo "Default FS Bucket:         gs://${DEFAULT_FS_BUCKET}"
echo "External Metastore:        ${DB_IP} (User: ${DB_USER})"
echo "===================================================="

gcloud dataproc clusters create "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --zone="${ZONE}" \
    --subnet="${SUBNET}" \
    --no-address \
    --bucket="${STAGING_BUCKET}" \
    --temp-bucket="${STAGING_BUCKET}" \
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
hive:datanucleus.schema.autoCreateAll=true,\
hive:hive.metastore.warehouse.dir=gs://${WAREHOUSE_BUCKET}/user/hive/warehouse,\
core:fs.defaultFS=gs://${DEFAULT_FS_BUCKET}"

echo "===================================================="
echo "Cluster creation command submitted."
echo "===================================================="
