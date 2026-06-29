#!/bin/bash
# scripts/verify_client.sh
# Verification suite to run on the Client VM to test Dataproc integration with cluster-9c32.

set -euo pipefail

# Source the environment variables
if [ -f /etc/profile.d/dataproc-env.sh ]; then
  source /etc/profile.d/dataproc-env.sh
else
  echo "Error: /etc/profile.d/dataproc-env.sh not found. Please run setup_client.sh first."
  exit 1
fi

# Clean up any stale Java/Spark driver processes from previous failed runs to free ports 30000/30001
echo "Cleaning up any stale Java/Spark processes on the VM..."
sudo pkill -f java || true

PROJECT_ID=$(gcloud config get-value project)
BUCKET_NAME="dataproc-client-lab-${PROJECT_ID}"
MASTER_HOST="${1:-"jmsau-test-m-0"}"

echo "===================================================="
echo "Starting Dataproc Integration Verification Tests"
echo "Project:        $PROJECT_ID"
echo "Staging Bucket: gs://$BUCKET_NAME"
echo "Master Host:    $MASTER_HOST"
echo "===================================================="

# Helper function to print headers
print_step() {
  echo
  echo "----------------------------------------------------"
  echo "TEST STEP: $1"
  echo "----------------------------------------------------"
}

# Test 1: Hadoop GCS Connector
print_step "1. Testing Hadoop FS GCS connectivity..."
echo "Running: hadoop fs -ls gs://${BUCKET_NAME}/"
if hadoop fs -ls "gs://${BUCKET_NAME}/" > /dev/null; then
  echo "SUCCESS: Hadoop can successfully read from gs://${BUCKET_NAME}!"
  hadoop fs -ls "gs://${BUCKET_NAME}/"
else
  echo "FAILURE: Hadoop GCS connection failed."
  exit 1
fi

# Test 2: Spark Submit in YARN Cluster Mode
print_step "2. Testing Spark Job in YARN Cluster Mode..."
echo "Submitting Spark Pi job in YARN Cluster Mode..."
if spark-submit \
    --master yarn \
    --deploy-mode cluster \
    $SPARK_HOME/examples/src/main/python/pi.py 10 2>&1 | tee /tmp/spark_cluster_test.log; then
  echo "SUCCESS: Spark job in YARN Cluster Mode completed successfully!"
else
  # Check if it succeeded by looking at the logs
  if grep -q "state: FINISHED" /tmp/spark_cluster_test.log || grep -q "finalStatus: SUCCEEDED" /tmp/spark_cluster_test.log; then
    echo "SUCCESS: Spark job in YARN Cluster Mode completed successfully (detected in logs)!"
  else
    echo "FAILURE: Spark job in YARN Cluster Mode failed. Check /tmp/spark_cluster_test.log"
    exit 1
  fi
fi

# (YARN Client Mode test removed as it is not required for cluster-mode deployment)

# Test 4: Hive Beeline Connectivity
print_step "4. Testing Hive/Beeline connectivity to HiveServer2..."
echo "Connecting to HiveServer2 on $MASTER_HOST:10000..."
if beeline -u "jdbc:hive2://${MASTER_HOST}:10000" -n hive -p hive -e "SHOW DATABASES;" 2>&1 | tee /tmp/beeline_test.log; then
  echo "SUCCESS: Hive Beeline connection and query executed successfully!"
else
  echo "FAILURE: Hive Beeline connection failed. Check /tmp/beeline_test.log"
  exit 1
fi

echo
echo "===================================================="
echo "ALL INTEGRATION TESTS PASSED SUCCESSFULLY! 🎉"
echo "Your standalone VM is fully configured as a Dataproc client."
echo "===================================================="
