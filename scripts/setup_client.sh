#!/bin/bash
# scripts/setup_client.sh
# Configures the standalone VM as a standard Apache Spark/Hadoop/Hive client.
# Downloads clean, standard Apache packages from the GCS bucket (offline-ready)
# and applies the cluster-specific configurations.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <bucket-name>"
    exit 1
fi

BUCKET_NAME="$1"

HADOOP_VERSION="3.3.6"
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
sudo tee /etc/profile.d/dataproc-env.sh > /dev/null << 'EOF'
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export HADOOP_HOME=/opt/hadoop
export SPARK_HOME=/opt/spark
export HIVE_HOME=/opt/hive
export HADOOP_CONF_DIR=/etc/hadoop/conf
export SPARK_CONF_DIR=/etc/spark/conf
export HIVE_CONF_DIR=/etc/hive/conf
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$SPARK_HOME/bin:$HIVE_HOME/bin
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

# 11. Cleanup temporary downloads on VM
echo "Cleaning up temporary files..."
sudo rm -f /tmp/hadoop-*.tar.gz /tmp/dataproc-spark.tar.gz /tmp/apache-hive-*.tar.gz /tmp/gcs-connector-*.jar /tmp/iceberg-*.jar /tmp/delta-*.jar /tmp/libfb303-*.jar /tmp/dataproc-configs.tar.gz

echo "===================================================="
echo "Standalone Client VM Setup Completed (Standard Apache)!"
echo "Please run: 'source /etc/profile.d/dataproc-env.sh' to load environment."
echo "===================================================="
