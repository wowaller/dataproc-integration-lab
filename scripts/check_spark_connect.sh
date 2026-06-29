#!/bin/bash
# Standalone Health Check for Spark Connect Server

# Get cluster name from VM metadata
CLUSTER_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/dataproc-cluster-name)
if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: Could not resolve cluster name from VM metadata."
  exit 1
fi

# Find the master node name and its zone
MASTER_NODE="${CLUSTER_NAME}-m-0"
MASTER_ZONE=$(gcloud compute instances list --filter="name=${MASTER_NODE}" --format="value(zone)" --limit=1)

if [ -z "$MASTER_ZONE" ]; then
  echo "ERROR: Could not resolve zone for master node ${MASTER_NODE} via gcloud."
  exit 1
fi

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
CONNECTION_URI="sc://${MASTER_NODE}.${MASTER_ZONE}.c.${PROJECT_ID}.internal:15002"

echo "===================================================="
echo "DATAPROC SPARK CONNECT HEALTH CHECK"
echo "Target Server: ${CONNECTION_URI}"
echo "===================================================="

# Tier 1: Network Port Check
echo -n "Checking network port 15002... "
if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${MASTER_NODE}/15002" >/dev/null 2>&1; then
  echo "PORT OPEN (OK)"
else
  echo "CONNECTION REFUSED (FAIL)"
  echo "----------------------------------------------------"
  echo "CRITICAL: Spark Connect Server is not listening on port 15002."
  echo "Please start the server first by running: ./start_spark_connect.sh"
  echo "===================================================="
  exit 1
fi

# Tier 2: End-to-End Query Execution Check
echo -n "Executing end-to-end test query... "
TEST_RESULT=$(python3 -c "
import sys
import glob

# Add Spark python libraries to path
sys.path.insert(0, '/opt/spark/python')
py4j_zip = glob.glob('/opt/spark/python/lib/py4j-*-src.zip')
if py4j_zip:
    sys.path.insert(0, py4j_zip[0])

from pyspark.sql import SparkSession

try:
    spark = SparkSession.builder.remote('${CONNECTION_URI}').getOrCreate()
    # Run a simple query with a 5-second timeout
    res = spark.sql('SELECT 1 as val').collect()
    if len(res) > 0 and res[0]['val'] == 1:
        print('OK')
        sys.exit(0)
    else:
        print('INVALID_RESULT')
        sys.exit(2)
except Exception as e:
    print('EXCEPTION:', str(e).replace('\n', ' '))
    sys.exit(3)
" 2>&1)

if [ "$TEST_RESULT" = "OK" ]; then
  echo "QUERY SUCCESSFUL (OK)"
  echo "----------------------------------------------------"
  echo "SUCCESS: Spark Connect Server is healthy and ready!"
  echo "===================================================="
  exit 0
else
  echo "QUERY FAILED (FAIL)"
  echo "----------------------------------------------------"
  echo "ERROR: Spark Connect Server is listening, but failing to execute queries."
  echo "Details: ${TEST_RESULT}"
  echo "Please check the YARN ResourceManager UI or run 'yarn logs' for details."
  echo "===================================================="
  exit 2
fi
