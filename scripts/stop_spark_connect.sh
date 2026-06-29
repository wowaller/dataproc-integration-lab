#!/bin/bash
# Helper script to stop Spark Connect Server on the Dataproc master node

CLUSTER_NAME=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/dataproc-cluster-name)
if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: Could not resolve cluster name."
  exit 1
fi

MASTER_NODE="${CLUSTER_NAME}-m-0"
MASTER_ZONE=$(gcloud compute instances list --filter="name=${MASTER_NODE}" --format="value(zone)" --limit=1)

echo "Stopping Spark Connect Server on Dataproc Master..."
gcloud compute ssh "${MASTER_NODE}" \
  --zone="${MASTER_ZONE}" \
  --tunnel-through-iap \
  --command="/usr/lib/spark/sbin/stop-connect-server.sh"
echo "Spark Connect Server stopped."
