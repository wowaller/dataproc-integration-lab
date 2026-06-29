#!/bin/bash
# Comprehensive Dataproc Integration Verification Script

# Load environment
source /etc/profile.d/dataproc-env.sh

# Check that environment variables are loaded
if [ -z "${DATAPROC_BUCKET:-}" ] || [ -z "${DATAPROC_MASTER_HOST:-}" ] || [ -z "${DATAPROC_CLUSTER_NAME:-}" ] || [ -z "${DATAPROC_PROJECT_ID:-}" ]; then
  echo "ERROR: Dataproc environment variables are not loaded."
  echo "Please run: source /etc/profile.d/dataproc-env.sh"
  exit 1
fi

BUCKET_NAME="${DATAPROC_BUCKET}"
CLUSTER_NAME="${DATAPROC_CLUSTER_NAME}"
PROJECT_ID="${DATAPROC_PROJECT_ID}"
MASTER_HOST="${DATAPROC_MASTER_HOST}"
MASTER_NODE="${CLUSTER_NAME}-m-0"

echo "===================================================="
echo "STARTING INTEGRATION VERIFICATION TESTS"
echo "Project:        ${PROJECT_ID}"
echo "Client VM:      $(hostname)"
echo "Target Cluster: ${CLUSTER_NAME} (Master: ${MASTER_HOST})"
echo "Staging Bucket: gs://${BUCKET_NAME}"
echo "===================================================="
echo ""

# Helper to print test headers
print_header() {
  echo "----------------------------------------------------"
  echo "TEST: $1"
  echo "----------------------------------------------------"
}

# Track test statuses
HADOOP_STATUS="FAIL"
HIVE_STATUS="FAIL"
SPARK_SCALA_STATUS="FAIL"
PYSPARK_STATUS="FAIL"
SPARK_CONNECT_STATUS="FAIL"

# ====================================================
# TEST 1: Hadoop FS GCS Check
# ====================================================
print_header "1. Hadoop FS GCS Connectivity"
echo "Running: hadoop fs -ls gs://${BUCKET_NAME}/"
if amusement_output=$(hadoop fs -ls "gs://${BUCKET_NAME}/" 2>&1); then
  echo "$amusement_output" | head -n 5
  echo "... (truncated)"
  echo "SUCCESS: Hadoop FS GCS check passed!"
  HADOOP_STATUS="PASS"
else
  echo "ERROR: Hadoop FS GCS check failed:"
  echo "$amusement_output"
fi
echo ""

# ====================================================
# TEST 2: Hive / Beeline Check
# ====================================================
print_header "2. Hive Beeline Query (Write & Read via Temporary Table)"
echo "Connecting to HiveServer2 and running temporary table operations..."
HIVE_SQL="
DROP TABLE IF EXISTS default.verify_hive_table;
CREATE TEMPORARY TABLE default.verify_hive_table (id INT, name STRING);
INSERT INTO default.verify_hive_table VALUES (1, 'Alice'), (2, 'Bob');
SELECT COUNT(*) as cnt FROM default.verify_hive_table;
"

if hive_output=$(beeline -u "jdbc:hive2://${MASTER_HOST}:10000" -n hive -p hive -e "$HIVE_SQL" 2>&1); then
  echo "$hive_output" | grep -A 4 -i "cnt"
  echo "SUCCESS: Hive temporary table write and read verified successfully!"
  HIVE_STATUS="PASS"
else
  echo "ERROR: Hive Beeline query failed:"
  echo "$hive_output"
fi
echo ""

# ====================================================
# TEST 3: Spark Submit (YARN Cluster Mode - Scala)
# ====================================================
print_header "3. Spark Submit (Scala YARN Cluster Mode)"
echo "Submitting Spark Pi job..."
if spark_output=$(spark-submit \
  --master yarn \
  --deploy-mode cluster \
  --class org.apache.spark.examples.SparkPi \
  /opt/spark/examples/jars/spark-examples_2.12-3.5.3.jar 5 2>&1); then
  
  APP_ID=$(echo "$spark_output" | grep -oE 'application_[0-9]+_[0-9]+' | head -n 1)
  echo "SUCCESS: Spark job submitted successfully (YARN App ID: ${APP_ID})!"
  echo "Fetching job result from YARN logs..."
  sleep 5
  yarn logs -applicationId "$APP_ID" 2>/dev/null | grep -i "Pi is roughly" || echo "Job completed. (Run 'yarn logs -applicationId ${APP_ID}' to see Pi output)."
  SPARK_SCALA_STATUS="PASS"
else
  echo "ERROR: Spark submit failed:"
  echo "$spark_output" | tail -n 20
fi
echo ""

# ====================================================
# TEST 4: PySpark Submit (YARN Cluster Mode - Python)
# ====================================================
print_header "4. PySpark Submit (Python YARN Cluster Mode)"
echo "Creating temp PySpark script..."
cat << 'EOF' > /tmp/verify_pyspark.py
import sys
from pyspark.sql import SparkSession

if len(sys.argv) < 2:
    print("ERROR: Missing bucket name argument")
    sys.exit(1)

bucket = sys.argv[1]
write_path = f"gs://{bucket}/pyspark_test_table"

spark = SparkSession.builder.appName("Verify-PySpark-Write-Read").getOrCreate()

print("=== PYSPARK TEST: Writing data to GCS ===")
data = [(1, "Spark"), (2, "Connect"), (3, "Yarn")]
df = spark.createDataFrame(data, ["id", "word"])
df.write.mode("overwrite").parquet(write_path)

print("=== PYSPARK TEST: Reading data back from GCS ===")
df_read = spark.read.parquet(write_path)
count = df_read.count()
print(f"=== PYSPARK TEST: READ COUNT = {count} ===")

if count == 3:
    print("=== PYSPARK TEST: SUCCESS ===")
else:
    print("=== PYSPARK TEST: FAILURE ===")
    sys.exit(2)

spark.stop()
EOF

echo "Submitting PySpark job..."
if pyspark_output=$(spark-submit \
  --master yarn \
  --deploy-mode cluster \
  /tmp/verify_pyspark.py "${BUCKET_NAME}" 2>&1); then
  
  PY_APP_ID=$(echo "$pyspark_output" | grep -oE 'application_[0-9]+_[0-9]+' | head -n 1)
  echo "SUCCESS: PySpark job submitted successfully (YARN App ID: ${PY_APP_ID})!"
  
  echo "Fetching job result from YARN logs..."
  sleep 5
  YARN_LOGS=$(yarn logs -applicationId "$PY_APP_ID" 2>/dev/null)
  
  if echo "$YARN_LOGS" | grep -q "=== PYSPARK TEST: SUCCESS ==="; then
    echo "SUCCESS: PySpark successfully wrote and read data!"
    
    echo "Verifying physical files in GCS..."
    if hadoop fs -ls "gs://${BUCKET_NAME}/pyspark_test_table" >/dev/null 2>&1; then
      echo "SUCCESS: Parquet files found in GCS under gs://${BUCKET_NAME}/pyspark_test_table!"
      PYSPARK_STATUS="PASS"
    else
      echo "ERROR: PySpark reported success, but no files were found in GCS!"
    fi
  else
    echo "ERROR: PySpark job failed execution. Logs:"
    echo "$YARN_LOGS" | grep -A 5 -i "PYSPARK TEST"
  fi
  
  # Clean up GCS files (Disabled to allow manual inspection)
  # hadoop fs -rm -r "gs://${BUCKET_NAME}/pyspark_test_table" >/dev/null 2>&1
else
  echo "ERROR: PySpark submit failed:"
  echo "$pyspark_output" | tail -n 20
fi
rm -f /tmp/verify_pyspark.py
echo ""

# ====================================================
# TEST 5: Spark Connect Check
# ====================================================
print_header "5. Spark Connect Query"
CONNECTION_URI="sc://${MASTER_HOST}:15002"

echo "Checking if Spark Connect Server is listening..."
if ! timeout 1 bash -c "cat < /dev/null > /dev/tcp/${MASTER_NODE}/15002" >/dev/null 2>&1; then
  echo "SKIP: Spark Connect Server is not running on port 15002."
  echo "      To run this test, please start the server first using: ./start_spark_connect.sh"
  SPARK_CONNECT_STATUS="SKIP (Server Offline)"
else
  echo "Server active. Running test query..."
  CONNECT_OUTPUT=$(python3 -c "
import sys
import glob

sys.path.insert(0, '/opt/spark/python')
py4j_zip = glob.glob('/opt/spark/python/lib/py4j-*-src.zip')
if py4j_zip:
    sys.path.insert(0, py4j_zip[0])

from pyspark.sql import SparkSession

try:
    spark = SparkSession.builder.remote('${CONNECTION_URI}').getOrCreate()
    # Read the parquet dataset written to GCS in Test 4
    df = spark.read.parquet('gs://${BUCKET_NAME}/pyspark_test_table')
    df.show()
    count = df.count()
    print(f'=== CONNECT TEST: COUNT = {count} ===')
    if count == 3:
        sys.exit(0)
    else:
        print('ERROR: Count mismatch')
        sys.exit(4)
except Exception as e:
    print('EXCEPTION:', str(e).replace('\n', ' '))
    sys.exit(3)
" 2>&1)

  if [ $? -eq 0 ]; then
    echo "$CONNECT_OUTPUT"
    echo "SUCCESS: Spark Connect successfully read the parquet dataset from GCS!"
    SPARK_CONNECT_STATUS="PASS"
  else
    echo "ERROR: Spark Connect query failed:"
    echo "$CONNECT_OUTPUT"
  fi
fi
echo ""

# ====================================================
# FINAL REPORT
# ====================================================
echo "===================================================="
echo "DATAPROC INTEGRATION TEST REPORT"
echo "===================================================="
echo "1. Hadoop GCS Read:       [ ${HADOOP_STATUS} ]"
echo "2. Hive Beeline Query:     [ ${HIVE_STATUS} ]"
echo "3. Spark Submit (Scala):   [ ${SPARK_SCALA_STATUS} ]"
echo "4. PySpark Submit (Py):    [ ${PYSPARK_STATUS} ]"
echo "5. Spark Connect (gRPC):   [ ${SPARK_CONNECT_STATUS} ]"
echo "===================================================="
if [ "${PYSPARK_STATUS}" = "PASS" ]; then
  echo "NOTE: PySpark test data was preserved in GCS. To clean it up manually, run:"
  echo "  hadoop fs -rm -r gs://${BUCKET_NAME}/pyspark_test_table"
  echo "===================================================="
fi
