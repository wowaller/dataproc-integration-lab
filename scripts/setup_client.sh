#!/bin/bash
# scripts/setup_client.sh
# Configures the standalone VM as a standard Apache Spark/Hadoop/Hive client.
# Downloads clean, standard Apache packages from the GCS bucket (offline-ready)
# and applies the cluster-specific configurations.

set -euo pipefail

# 1. Parse Arguments
BUCKET_NAME=$1
CLUSTER_NAME=$2
MASTER_HOST=$3
PROJECT_ID=$4
REGION=${5:-"us-central1"}

if [ -z "$BUCKET_NAME" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$MASTER_HOST" ] || [ -z "$PROJECT_ID" ]; then
    echo "Usage: $0 <bucket_name> <cluster_name> <master_host> <project_id> [region]"
    exit 1
fi

HADOOP_VERSION="3.3.6"
SPARK_VERSION="3.5.3"
HIVE_VERSION="3.1.3"
GCS_CONNECTOR_VERSION="3.1.13"
ICEBERG_VERSION="1.6.1"

echo "===================================================="
echo "Starting Standalone Client VM Configuration (Standard Apache)"
echo "Target GCS Bucket: gs://$BUCKET_NAME"
echo "===================================================="

# 1. Install Java 17 and JQ
echo "Installing OpenJDK 17 and JQ..."
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk-headless jq

# 2. Create local directories
echo "Creating required directories..."
sudo mkdir -p /opt
sudo mkdir -p /hadoop/tmp /hadoop/spark/tmp /hadoop/spark/work
sudo mkdir -p /usr/lib/delta/lib /usr/lib/iceberg/lib
sudo chmod 1777 /hadoop/tmp /hadoop/spark/tmp /hadoop/spark/work

# 3. Download packages from GCS (internal network transfer)
echo "Downloading Dataproc client packages from GCS..."
sudo gsutil cp "gs://${BUCKET_NAME}/packages/hadoop-${HADOOP_VERSION}.tar.gz" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/dataproc-spark.tar.gz" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/apache-hive-${HIVE_VERSION}-bin.tar.gz" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/delta-spark-3.2.1_2.12_3.5.3-with-dependencies.jar" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/packages/delta-storage-3.2.1_2.12_3.5.3.jar" /tmp/

echo "Downloading Hive auxiliary jars from GCS..."
sudo gsutil cp "gs://${BUCKET_NAME}/hive-aux/delta-hive-assembly-3.2.1_2.12_3.5.3.jar" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/hive-aux/iceberg-hive-runtime.jar" /tmp/
sudo gsutil cp "gs://${BUCKET_NAME}/hive-aux/libfb303-0.9.3.jar" /tmp/

# 4. Extract packages to /opt/
echo "Extracting packages to /opt/..."
sudo tar -xzf "/tmp/hadoop-${HADOOP_VERSION}.tar.gz" -C /opt/
sudo tar -xzf "/tmp/dataproc-spark.tar.gz" -C /opt/
sudo tar -xzf "/tmp/apache-hive-${HIVE_VERSION}-bin.tar.gz" -C /opt/

# Create symlinks for clean paths
echo "Creating symlinks..."
sudo ln -sfn "/opt/hadoop-${HADOOP_VERSION}" /opt/hadoop
sudo ln -sfn "/opt/apache-hive-${HIVE_VERSION}-bin" /opt/hive

# 5. Deploy GCS Connector and Iceberg Runtime
echo "Cleaning up any old GCS connector jar versions..."
sudo rm -f /opt/hadoop/share/hadoop/common/lib/gcs-connector-hadoop3-*.jar
sudo rm -f /opt/spark/jars/gcs-connector-hadoop3-*.jar

echo "Deploying GCS Connector to Spark and Hadoop..."
sudo cp "/tmp/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar" /opt/hadoop/share/hadoop/common/lib/
sudo cp "/tmp/gcs-connector-${GCS_CONNECTOR_VERSION}-shaded.jar" /opt/spark/jars/

echo "Deploying Iceberg Spark Runtime..."
sudo cp "/tmp/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar" /opt/spark/jars/

echo "Deploying Hive Auxiliary Jars to /usr/lib..."
sudo cp "/tmp/delta-spark-3.2.1_2.12_3.5.3-with-dependencies.jar" /usr/lib/delta/lib/
sudo cp "/tmp/delta-storage-3.2.1_2.12_3.5.3.jar" /usr/lib/delta/lib/
sudo cp "/tmp/delta-spark-3.2.1_2.12_3.5.3-with-dependencies.jar" /opt/spark/jars/
sudo cp "/tmp/delta-storage-3.2.1_2.12_3.5.3.jar" /opt/spark/jars/
sudo cp "/tmp/delta-hive-assembly-3.2.1_2.12_3.5.3.jar" /usr/lib/delta/lib/
sudo cp "/tmp/iceberg-hive-runtime.jar" /usr/lib/iceberg/lib/
sudo cp "/tmp/libfb303-0.9.3.jar" /usr/lib/iceberg/lib/

# 6. Download and extract cluster-specific configurations
echo "Downloading and deploying cluster configurations..."
sudo gsutil cp "gs://${BUCKET_NAME}/configs/dataproc-configs.tar.gz" /tmp/
# Extract configurations directly to / (recreates /etc/hadoop/conf, /etc/spark/conf, /etc/hive/conf)
sudo tar -xzf /tmp/dataproc-configs.tar.gz -C /

# 7. Setup Environment Variables
echo "Setting up environment variables in /etc/profile.d/dataproc-env.sh..."
sudo tee /etc/profile.d/dataproc-env.sh > /dev/null << EOF
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export HADOOP_HOME=/opt/hadoop
export SPARK_HOME=/opt/spark
export HIVE_HOME=/opt/hive
export HADOOP_CONF_DIR=/etc/hadoop/conf
export SPARK_CONF_DIR=/etc/spark/conf
export HIVE_CONF_DIR=/etc/hive/conf
export PATH=\$PATH:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin:\$SPARK_HOME/bin:\$HIVE_HOME/bin

# Dataproc Lab Integration Variables
export DATAPROC_BUCKET="${BUCKET_NAME}"
export DATAPROC_CLUSTER_NAME="${CLUSTER_NAME}"
export DATAPROC_MASTER_HOST="${MASTER_HOST}"
export DATAPROC_PROJECT_ID="${PROJECT_ID}"
export DATAPROC_REGION="${REGION}"
EOF
sudo chmod +x /etc/profile.d/dataproc-env.sh

# 8. Configure Spark Client Mode Port Binding & Driver Hostname
echo "Appending Spark Client Mode network configurations..."
# Get VM's internal IP to ensure cross-zone resolution works for YARN workers
VM_IP=$(hostname -I | awk '{print $1}')
sudo tee -a /etc/spark/conf/spark-defaults.conf > /dev/null << EOF

# Spark Client Mode Ports and Hostname configuration for Firewall traversal
spark.driver.port 30000
spark.blockManager.port 30001
spark.driver.host ${VM_IP}
EOF

# 9. Disable Dataproc Spark Plugin & Listener in the copied configs
# Since we are using standard Spark, these plugins do not exist and will cause errors if active.
echo "Disabling Dataproc-specific Spark plugins and listeners in configurations..."
if [ -f /etc/spark/conf/spark-defaults.conf ]; then
  sudo sed -i 's/^spark.plugins.defaultList=/# spark.plugins.defaultList=/g' /etc/spark/conf/spark-defaults.conf
  sudo sed -i 's/^spark.dataproc.listeners=/# spark.dataproc.listeners=/g' /etc/spark/conf/spark-defaults.conf
fi

# 10. Hive Beeline Log4j Classpath Conflict Fix
echo "Applying Beeline/Hive class path fixes..."
# Standard Hive 3.1.3 has a log4j conflict that blocks Beeline, we rename the duplicate jar
if ls /opt/hive/lib/log4j-slf4j-impl-*.jar >/dev/null 2>&1; then
  sudo mv /opt/hive/lib/log4j-slf4j-impl-*.jar /opt/hive/lib/log4j-slf4j-impl-*.jar.bak || true
fi

# 11. Install Spark Connect Client Dependencies
echo "Installing Spark Connect Python client dependencies..."
sudo apt-get install -y python3-pip
pip3 install pandas pyarrow grpcio grpcio-status --break-system-packages

# 12. Create Spark Connect Helper Scripts in the home directory
echo "Creating Spark Connect helper scripts in home directory..."
USER_HOME=$(eval echo "~${SUDO_USER:-$USER}")

cat << 'EOF' > "${USER_HOME}/start_spark_connect.sh"
#!/bin/bash
# Helper script to start Spark Connect Server on the Dataproc master node

source /etc/profile.d/dataproc-env.sh

if [ -z "$DATAPROC_CLUSTER_NAME" ] || [ -z "$DATAPROC_MASTER_HOST" ]; then
  echo "ERROR: Dataproc environment variables are not set. Run: source /etc/profile.d/dataproc-env.sh"
  exit 1
fi

MASTER_NODE="${DATAPROC_CLUSTER_NAME}-m-0"
MASTER_ZONE=$(gcloud compute instances list --filter="name=${MASTER_NODE}" --format="value(zone)" --limit=1)

if [ -z "$MASTER_ZONE" ]; then
  echo "ERROR: Could not resolve zone for master node ${MASTER_NODE} via gcloud."
  exit 1
fi

echo "Starting Spark Connect Server on Dataproc Master (${MASTER_NODE} in ${MASTER_ZONE}) on YARN..."
gcloud compute ssh "${MASTER_NODE}" \
  --zone="${MASTER_ZONE}" \
  --tunnel-through-iap \
  --command="/usr/lib/spark/sbin/start-connect-server.sh --master yarn --deploy-mode client --packages org.apache.spark:spark-connect_2.12:3.5.3"

echo "Waiting for Spark Connect Server to start listening on port 15002..."
TIMEOUT=60
ELAPSED=0
while ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/${DATAPROC_MASTER_HOST}/15002" >/dev/null 2>&1; do
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
echo "  spark = SparkSession.builder.remote(\"sc://${DATAPROC_MASTER_HOST}:15002\").getOrCreate()"
echo "===================================================="
EOF
chmod +x "${USER_HOME}/start_spark_connect.sh"
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${USER_HOME}/start_spark_connect.sh"

cat << 'EOF' > "${USER_HOME}/stop_spark_connect.sh"
#!/bin/bash
# Helper script to stop Spark Connect Server on the Dataproc master node

source /etc/profile.d/dataproc-env.sh

if [ -z "$DATAPROC_CLUSTER_NAME" ]; then
  echo "ERROR: Dataproc environment variables are not set. Run: source /etc/profile.d/dataproc-env.sh"
  exit 1
fi

MASTER_NODE="${DATAPROC_CLUSTER_NAME}-m-0"
MASTER_ZONE=$(gcloud compute instances list --filter="name=${MASTER_NODE}" --format="value(zone)" --limit=1)

echo "Stopping Spark Connect Server on Dataproc Master..."
gcloud compute ssh "${MASTER_NODE}" \
  --zone="${MASTER_ZONE}" \
  --tunnel-through-iap \
  --command="/usr/lib/spark/sbin/stop-connect-server.sh"
echo "Spark Connect Server stopped."
EOF
chmod +x "${USER_HOME}/stop_spark_connect.sh"
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${USER_HOME}/stop_spark_connect.sh"

cat << 'EOF' > "${USER_HOME}/check_spark_connect.sh"
#!/bin/bash
# Standalone Health Check for Spark Connect Server

source /etc/profile.d/dataproc-env.sh

if [ -z "$DATAPROC_MASTER_HOST" ] || [ -z "$DATAPROC_CLUSTER_NAME" ]; then
  echo "ERROR: Dataproc environment variables are not set. Run: source /etc/profile.d/dataproc-env.sh"
  exit 1
fi

CONNECTION_URI="sc://${DATAPROC_MASTER_HOST}:15002"

echo "===================================================="
echo "DATAPROC SPARK CONNECT HEALTH CHECK"
echo "Target Server: ${CONNECTION_URI}"
echo "===================================================="

# Tier 1: Network Port Check
echo -n "Checking network port 15002... "
if timeout 2 bash -c "cat < /dev/null > /dev/tcp/${DATAPROC_MASTER_HOST}/15002" >/dev/null 2>&1; then
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
    # Run a simple query
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
EOF
chmod +x "${USER_HOME}/check_spark_connect.sh"
chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${USER_HOME}/check_spark_connect.sh"

# 13. Cleanup temporary downloads on VM
echo "Cleaning up temporary files..."
sudo rm -f /tmp/hadoop-*.tar.gz /tmp/dataproc-spark.tar.gz /tmp/apache-hive-*.tar.gz /tmp/gcs-connector-*.jar /tmp/iceberg-*.jar /tmp/delta-*.jar /tmp/libfb303-*.jar /tmp/dataproc-configs.tar.gz

echo "===================================================="
echo "Standalone Client VM Setup Completed (Standard Apache)!"
echo "Please run: 'source /etc/profile.d/dataproc-env.sh' to load environment."
echo "===================================================="
