#!/bin/bash
# Helper script to start Spark Connect Server on the Dataproc master node

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

echo "Starting Spark Connect Server on Dataproc Master (${MASTER_NODE} in ${MASTER_ZONE}) on YARN..."
gcloud compute ssh "${MASTER_NODE}" \
  --zone="${MASTER_ZONE}" \
  --tunnel-through-iap \
  --command="/usr/lib/spark/sbin/start-connect-server.sh --master yarn --deploy-mode client --packages org.apache.spark:spark-connect_2.12:3.5.3"

echo "Waiting for Spark Connect Server to start listening on port 15002..."
TIMEOUT=60
ELAPSED=0
while ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/${MASTER_NODE}/15002" >/dev/null 2>&1; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Spark Connect Server failed to start within ${TIMEOUT} seconds."
    echo "Please check YARN logs on the master node."
    exit 1
  fi
done

echo "===================================================="
echo "Spark Connect Server successfully started and verified!"
echo "You can now connect your PySpark session using:"
echo "  spark = SparkSession.builder.remote(\"sc://${MASTER_NODE}.${MASTER_ZONE}.c.${PROJECT_ID}.internal:15002\").getOrCreate()"
echo "===================================================="
