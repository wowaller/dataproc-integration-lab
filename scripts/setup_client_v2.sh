#!/bin/bash
# scripts/setup_client_v2.sh
# Configures the standalone VM by extracting the single-payload Dataproc mirror archive.
# Recreates the exact filesystem layout and configurations of the Dataproc master.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <bucket-name>"
    exit 1
fi

BUCKET_NAME="$1"
PAYLOAD_NAME="dataproc-client-payload.tar.gz"

echo "===================================================="
echo "Starting Standalone Client VM Configuration (V2 - Mirror)"
echo "Target GCS Bucket: gs://$BUCKET_NAME"
echo "===================================================="

# 1. Install Java 17 and JQ
echo "Installing OpenJDK 17 and JQ..."
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk-headless jq

# 2. Create local scratch directories
echo "Creating required directories..."
sudo mkdir -p /hadoop/tmp /hadoop/spark/tmp /hadoop/spark/work
sudo chmod 1777 /hadoop/tmp /hadoop/spark/tmp /hadoop/spark/work

# 3. Download the single-payload mirror from GCS
echo "Downloading Dataproc mirror payload from GCS..."
sudo gsutil cp "gs://${BUCKET_NAME}/payload/${PAYLOAD_NAME}" /tmp/

# 4. Extract the payload to root (recreates /usr/lib/ and /etc/ paths)
echo "Extracting mirror payload to /..."
sudo tar -xzf "/tmp/${PAYLOAD_NAME}" -C /

# 5. Setup Environment Variables in /etc/profile.d/
echo "Setting up environment variables in /etc/profile.d/dataproc-env.sh..."
sudo tee /etc/profile.d/dataproc-env.sh > /dev/null << 'EOF'
# Dataproc Environment Variables
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export HADOOP_HOME=/usr/lib/hadoop
export HADOOP_CONF_DIR=/etc/hadoop/conf
export SPARK_HOME=/usr/lib/spark
export SPARK_CONF_DIR=/etc/spark/conf
export HIVE_HOME=/usr/lib/hive
export HIVE_CONF_DIR=/etc/hive/conf

# Update PATH
export PATH=$SPARK_HOME/bin:$HADOOP_HOME/bin:$HIVE_HOME/bin:$PATH
EOF
sudo chmod +x /etc/profile.d/dataproc-env.sh

# 6. Configure Spark Client Mode Port Binding & Driver Hostname
echo "Appending Spark Client Mode network configurations..."
VM_IP=$(hostname -I | awk '{print $1}')
sudo tee -a /etc/spark/conf/spark-defaults.conf > /dev/null << EOF

# Spark Client Mode Ports and Hostname configuration for Firewall traversal
spark.driver.port 30000
spark.blockManager.port 30001
spark.driver.host ${VM_IP}
EOF

# 7. Disable Dataproc Spark Plugin & Listener in the copied configs
# Since we are not running inside the Dataproc agent, these plugins will cause errors if active.
echo "Disabling Dataproc-specific Spark plugins and listeners in configurations..."
sudo sed -i 's/spark.jars.packages/#spark.jars.packages/g' /etc/spark/conf/spark-defaults.conf
sudo sed -i 's/spark.jars.excludes/#spark.jars.excludes/g' /etc/spark/conf/spark-defaults.conf
sudo sed -i 's/spark.plugins/#spark.plugins/g' /etc/spark/conf/spark-defaults.conf
sudo sed -i 's/spark.sql.queryExecutionListeners/#spark.sql.queryExecutionListeners/g' /etc/spark/conf/spark-defaults.conf
sudo sed -i 's/spark.extraListeners/#spark.extraListeners/g' /etc/spark/conf/spark-defaults.conf

# 8. Apply Beeline/Hive class path fixes
# Remove any pre-configured Hadoop classpath overrides in Hive env to prevent jar version conflicts
if [ -f /etc/hive/conf/hive-env.sh ]; then
    echo "Applying Beeline/Hive class path fixes..."
    sudo sed -i 's/export HADOOP_CLASSPATH=/#export HADOOP_CLASSPATH=/g' /etc/hive/conf/hive-env.sh
fi

# 9. Cleanup temporary files
echo "Cleaning up temporary files..."
sudo rm -f "/tmp/${PAYLOAD_NAME}"

echo "===================================================="
echo "Standalone Client VM Setup Completed (V2 - Mirror)!"
echo "Please run: 'source /etc/profile.d/dataproc-env.sh' to load environment."
echo "===================================================="
