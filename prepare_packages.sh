#!/bin/bash
# prepare_packages.sh
# Downloads standard Apache Spark, Hadoop, Hive, and GCS Connector packages,
# and uploads them to the GCS staging bucket for offline VM deployment.

set -euo pipefail

# Configuration
PROJECT_ID=$(gcloud config get-value project)
BUCKET_NAME="dataproc-client-lab-${PROJECT_ID}"

# Component Versions (matched to Dataproc cluster-9c32)
HADOOP_VERSION="3.3.6"
HIVE_VERSION="3.1.3"
GCS_CONNECTOR_VERSION="3.1.13"
ICEBERG_VERSION="1.6.1"
DELTA_VERSION="3.2.1"

# Download URLs (only Hadoop, Hive, and GCS Connector are standard)
HADOOP_URL="https://dlcdn.apache.org/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz"
HIVE_URL="https://mirrors.huaweicloud.com/apache/hive/hive-${HIVE_VERSION}/apache-hive-${HIVE_VERSION}-bin.tar.gz"
GCS_CONNECTOR_URL="https://repo1.maven.org/maven2/com/google/cloud/bigdataoss/gcs-connector/${GCS_CONNECTOR_VERSION}/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar"
ICEBERG_URL="https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/${ICEBERG_VERSION}/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar"

# Local temp directory for downloads
TEMP_DIR="./tmp_packages"
mkdir -p "$TEMP_DIR"

echo "===================================================="
echo "Starting Staging of Dataproc Client Packages"
echo "Project:      $PROJECT_ID"
echo "Target GCS:   gs://$BUCKET_NAME/packages/"
echo "===================================================="

# Helper function to download if not already present locally OR in GCS
download_file() {
  local url="$1"
  local dest="$2"
  local gcs_path="$3" # e.g. gs://bucket/packages/filename
  
  if [ -f "$dest" ]; then
    echo "File $(basename "$dest") already exists locally, skipping download."
  elif gsutil ls "$gcs_path" >/dev/null 2>&1; then
    echo "File $(basename "$dest") already exists in GCS ($gcs_path), skipping download."
  else
    echo "Downloading $url..."
    curl -L -o "$dest" "$url"
  fi
}

# 1. Download Standard Packages (checking GCS first)
download_file "$HADOOP_URL" "$TEMP_DIR/hadoop-${HADOOP_VERSION}.tar.gz" "gs://${BUCKET_NAME}/packages/hadoop-${HADOOP_VERSION}.tar.gz"
download_file "$HIVE_URL" "$TEMP_DIR/apache-hive-${HIVE_VERSION}-bin.tar.gz" "gs://${BUCKET_NAME}/packages/apache-hive-${HIVE_VERSION}-bin.tar.gz"
download_file "$GCS_CONNECTOR_URL" "$TEMP_DIR/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar" "gs://${BUCKET_NAME}/packages/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar"
download_file "$ICEBERG_URL" "$TEMP_DIR/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" "gs://${BUCKET_NAME}/packages/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar"

# Download standard Hive auxiliary jars
ICEBERG_HIVE_URL="https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-hive-runtime/${ICEBERG_VERSION}/iceberg-hive-runtime-${ICEBERG_VERSION}.jar"
LIBFB303_URL="https://repo1.maven.org/maven2/org/apache/thrift/libfb303/0.9.3/libfb303-0.9.3.jar"
download_file "$ICEBERG_HIVE_URL" "$TEMP_DIR/iceberg-hive-runtime.jar" "gs://${BUCKET_NAME}/hive-aux/iceberg-hive-runtime.jar"
download_file "$LIBFB303_URL" "$TEMP_DIR/libfb303-0.9.3.jar" "gs://${BUCKET_NAME}/hive-aux/libfb303-0.9.3.jar"

# 2. Verify staging bucket exists
if ! gsutil ls -b "gs://$BUCKET_NAME" >/dev/null 2>&1; then
  echo "Staging bucket gs://$BUCKET_NAME does not exist. Creating it..."
  # We use us-central1 as default region
  gsutil mb -p "$PROJECT_ID" -c standard -l "us-central1" "gs://$BUCKET_NAME"
fi

# 3. Stage the Custom Dataproc Spark Package from cluster if not already in GCS
CLUSTER_NAME="jmsau-test"
CLUSTER_ZONE="us-central1-b"
echo "Checking for staged Dataproc Spark Package in GCS..."
if ! gsutil ls "gs://$BUCKET_NAME/packages/dataproc-spark.tar.gz" >/dev/null 2>&1; then
  echo "Dataproc Spark Package not found in GCS. Attempting to copy from active cluster..."
  if gcloud compute instances describe "${CLUSTER_NAME}-m-0" --zone="$CLUSTER_ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute ssh "${CLUSTER_NAME}-m-0" \
      --project="$PROJECT_ID" \
      --zone="$CLUSTER_ZONE" \
      --tunnel-through-iap \
      --command="echo '=== Packaging Spark on Master ===' && sudo tar -czf /tmp/dataproc-spark.tar.gz -C /usr/lib spark && gsutil cp /tmp/dataproc-spark.tar.gz gs://${BUCKET_NAME}/packages/dataproc-spark.tar.gz && sudo rm -f /tmp/dataproc-spark.tar.gz"
    echo "Dataproc Spark Package successfully copied to GCS."
  else
    echo "WARNING: Cluster '${CLUSTER_NAME}' is not running. Could not copy Dataproc Spark Package. If this is a fresh setup, please ensure the cluster is running and re-run this script."
  fi
else
  echo "Dataproc Spark Package is already staged in GCS."
fi

# 3b. Stage the Custom Delta Jars from cluster if not already in GCS
echo "Checking for staged Delta Jars in GCS..."
if ! gsutil ls "gs://$BUCKET_NAME/packages/delta-spark-3.2.1_2.12_3.5.3-with-dependencies.jar" >/dev/null 2>&1 || \
   ! gsutil ls "gs://$BUCKET_NAME/packages/delta-storage-3.2.1_2.12_3.5.3.jar" >/dev/null 2>&1; then
  echo "Delta Jars not found in GCS. Attempting to copy from active cluster..."
  if gcloud compute instances describe "${CLUSTER_NAME}-m-0" --zone="$CLUSTER_ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute ssh "${CLUSTER_NAME}-m-0" \
      --project="$PROJECT_ID" \
      --zone="$CLUSTER_ZONE" \
      --tunnel-through-iap \
      --command="gsutil cp /usr/lib/delta/lib/delta-spark-3.2.1_2.12_3.5.3-with-dependencies.jar gs://${BUCKET_NAME}/packages/ && gsutil cp /usr/lib/delta/lib/delta-storage-3.2.1_2.12_3.5.3.jar gs://${BUCKET_NAME}/packages/"
    echo "Delta Jars successfully copied to GCS."
  else
    echo "WARNING: Cluster '${CLUSTER_NAME}' is not running. Could not copy Delta Jars. If this is a fresh setup, please ensure the cluster is running and re-run this script."
  fi
else
  echo "Delta Jars are already staged in GCS."
fi

# 3c. Stage the Custom Delta Hive Assembly from cluster if not already in GCS
echo "Checking for staged Delta Hive Assembly in GCS..."
if ! gsutil ls "gs://$BUCKET_NAME/hive-aux/delta-hive-assembly-3.2.1_2.12_3.5.3.jar" >/dev/null 2>&1; then
  echo "Delta Hive Assembly not found in GCS. Attempting to copy from active cluster..."
  if gcloud compute instances describe "${CLUSTER_NAME}-m-0" --zone="$CLUSTER_ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute ssh "${CLUSTER_NAME}-m-0" \
      --project="$PROJECT_ID" \
      --zone="$CLUSTER_ZONE" \
      --tunnel-through-iap \
      --command="gsutil cp /usr/lib/delta/lib/delta-hive-assembly-3.2.1_2.12_3.5.3.jar gs://${BUCKET_NAME}/hive-aux/"
    echo "Delta Hive Assembly successfully copied to GCS."
  else
    echo "WARNING: Cluster '${CLUSTER_NAME}' is not running. Could not copy Delta Hive Assembly. If this is a fresh setup, please ensure the cluster is running and re-run this script."
  fi
else
  echo "Delta Hive Assembly is already staged in GCS."
fi

# 3d. Stage the Cluster Configurations if not already in GCS
echo "Checking for staged Dataproc configurations in GCS..."
if ! gsutil ls "gs://$BUCKET_NAME/configs/dataproc-configs.tar.gz" >/dev/null 2>&1; then
  echo "Dataproc configurations not found in GCS. Attempting to copy from active cluster..."
  if gcloud compute instances describe "${CLUSTER_NAME}-m-0" --zone="$CLUSTER_ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud compute ssh "${CLUSTER_NAME}-m-0" \
      --project="$PROJECT_ID" \
      --zone="$CLUSTER_ZONE" \
      --tunnel-through-iap \
      --command="sudo tar -chzf /tmp/dataproc-configs.tar.gz -C / etc/hadoop/conf etc/spark/conf etc/hive/conf && gsutil cp /tmp/dataproc-configs.tar.gz gs://${BUCKET_NAME}/configs/dataproc-configs.tar.gz && sudo rm -f /tmp/dataproc-configs.tar.gz"
    echo "Dataproc configurations successfully copied to GCS."
  else
    echo "WARNING: Cluster '${CLUSTER_NAME}' is not running. Could not copy Dataproc configurations. If this is a fresh setup, please ensure the cluster is running and re-run this script."
  fi
else
  echo "Dataproc configurations are already staged in GCS."
fi

# 4. Upload standard packages to GCS (only if any were downloaded)
if [ "$(ls -A "$TEMP_DIR" 2>/dev/null)" ]; then
  echo "Uploading standard packages to gs://$BUCKET_NAME/packages/..."
  gsutil -m cp "$TEMP_DIR"/* "gs://$BUCKET_NAME/packages/"
fi

# Copy standard Hive aux jars to /hive-aux/ directory in GCS (only if downloaded)
if [ -f "$TEMP_DIR/iceberg-hive-runtime.jar" ]; then
  echo "Uploading standard Iceberg Hive runtime jar to gs://$BUCKET_NAME/hive-aux/..."
  gsutil cp "$TEMP_DIR/iceberg-hive-runtime.jar" "gs://$BUCKET_NAME/hive-aux/"
fi
if [ -f "$TEMP_DIR/libfb303-0.9.3.jar" ]; then
  echo "Uploading standard libfb303 jar to gs://$BUCKET_NAME/hive-aux/..."
  gsutil cp "$TEMP_DIR/libfb303-0.9.3.jar" "gs://$BUCKET_NAME/hive-aux/"
fi

# 5. Cleanup local temp files
echo "Cleaning up local temporary downloads..."
rm -rf "$TEMP_DIR"

echo "===================================================="
echo "Package Staging Completed Successfully!"
echo "All packages and Hive auxiliary jars are staged in GCS."
echo "===================================================="
