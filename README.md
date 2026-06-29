# Dataproc Client VM Integration Lab

This project demonstrates how to deploy and configure a standalone Google Compute Engine (GCE) virtual machine (VM) as a **fully functional Dataproc Client** using a hybrid execution model.

Once configured, this client VM can:
1.  Submit Spark and PySpark jobs to the Dataproc YARN cluster in **Cluster Mode** (driver runs on the cluster).
2.  Connect interactively to the cluster via **Spark Connect** (driver runs on the cluster, client sends gRPC query plans).
3.  Connect to **HiveServer2** via Beeline for SQL queries.
4.  Read and write data directly from/to Google Cloud Storage (GCS).

---

## Architecture Overview

Traditional YARN Client Mode (where the Spark driver runs locally on the standalone VM) is blocked on standard VMs because Google's custom Spark fork contains an environment validator that requires a Dataproc GCE License.

To bypass this without managing complex GCE licenses, this lab implements a **Hybrid Execution Model**:

*   **Batch Jobs (YARN Cluster Mode)**: The client VM submits the job to YARN. The driver is launched on the Dataproc master node (which has the license), completely bypassing the local validator.
*   **Interactive Sessions (Spark Connect)**: The client VM starts a Spark Connect gRPC server on the Dataproc cluster. The client VM then runs a thin Python client that sends query plans over gRPC (port `15002`). This completely avoids Java serialization mismatches and local environment validation.

```mermaid
graph TD
    subgraph Client VM (Standard VM)
        A[PySpark Connect Client] -- gRPC Port 15002 --> B[Spark Connect Server]
        C[spark-submit --deploy-mode cluster] -- Submit --> D[YARN ResourceManager]
    end
    subgraph Dataproc Cluster (Licensed)
        B -- Runs Driver --> E[YARN ApplicationMaster]
        D -- Allocates --> E
        E -- Coordinates --> F[Spark Executors]
    end
```

---

## Project Structure

*   **`config.env`**: The single source of truth for the lab. Contains project ID, region, zones, cluster name, VM name, and GCS bucket name. Sourced by all orchestration scripts.
*   **`run_lab.sh`**: The main orchestration script. Sources `config.env`, provisions the VM and bucket, copies setup scripts, configures the VM, and runs the verification suite.
*   **`provision_resources.sh`**: Provisions the standalone GCE VM (Debian 12, `n4-standard-4`) and the GCS staging bucket.
*   **`prepare_packages.sh`**: Packages the custom Dataproc Spark binaries from your active cluster and stages them in GCS alongside standard Hadoop/Hive packages.
*   **`scripts/setup_client.sh`**: Runs on the client VM. Extracts the packages, installs Python dependencies (`pandas`, `pyarrow`, `grpcio`), configures environment variables, and deploys the Spark Connect helper scripts.
*   **`scripts/start_spark_connect.sh`**: Helper script on the VM that SSHs into the master node, starts the Spark Connect server on YARN, and polls port `15002` until it is ready.
*   **`scripts/stop_spark_connect.sh`**: Helper script on the VM that stops the Spark Connect server on the cluster.
*   **`scripts/check_spark_connect.sh`**: Standalone health check script that verifies the Spark Connect server's network port and executes a test query.
*   **`scripts/verify_integration.sh`**: The integration test suite. Runs 5 comprehensive tests (GCS read, Hive temporary table write/read, Spark Submit Scala, PySpark YARN Cluster write/read, and Spark Connect).
*   **`cleanup_resources.sh`**: Tears down the VM and GCS bucket.

---

## Getting Started

### 1. Configure the Lab
Edit the [config.env](file:///usr/local/google/home/binggangwo/project/dataproc-integration-lab/config.env) file in the root of the project and set your Google Cloud parameters:
```properties
PROJECT_ID="your-project-id"
CLUSTER_NAME="your-dataproc-cluster-name"
CLUSTER_ZONE="cluster-master-zone"
REGION="cluster-region"
VM_NAME="dataproc-client-vm-v1-hybrid"
VM_ZONE="client-vm-zone"
BUCKET_NAME="dataproc-client-lab-your-project"
```

### 2. Stage the Packages
Before deploying the VM, you must stage the Spark/Hadoop/Hive binaries in your GCS bucket. Run this from your workstation (requires the target Dataproc cluster to be running):
```bash
bash prepare_packages.sh
```

### 3. Run the Orchestration
To provision, configure, and verify the client VM in one command:
```bash
bash run_lab.sh
```
*At the end of the run, you will see a unified test report showing the status of all 5 integration tests.*

---

## Manual Usage & Verification

Once the VM is configured, you can log in and interact with the cluster:

### 1. SSH into the Client VM
```bash
gcloud compute ssh dataproc-client-vm-v1-hybrid --zone=us-central1-f --tunnel-through-iap
```

### 2. Load the Environment
```bash
source /etc/profile.d/dataproc-env.sh
```

### 3. Run a YARN Cluster Mode Job (Scala)
```bash
spark-submit \
  --master yarn \
  --deploy-mode cluster \
  --class org.apache.spark.examples.SparkPi \
  /opt/spark/examples/jars/spark-examples_2.12-3.5.3.jar 10
```

### 4. Interactive Work via Spark Connect (Python)
To start an interactive Python session using the cluster's Spark resources:

1.  **Start the Spark Connect Server on the cluster**:
    ```bash
    ./start_spark_connect.sh
    ```
    *This script will start the server on YARN and wait until port 15002 is active.*

2.  **Launch PySpark Connect**:
    Launch the PySpark shell pointing to the remote server (the start script will print the exact FQDN):
    ```bash
    pyspark --remote "sc://<master-node-fqdn>:15002"
    ```
    *Inside the shell, you can run DataFrame and SQL operations (e.g., `spark.sql("SELECT 1").show()`) which will execute on the YARN cluster.*

3.  **Check Health at any time**:
    You can run the standalone health check to verify the connection:
    ```bash
    ./check_spark_connect.sh
    ```

4.  **Stop the Server when done**:
    To free up YARN resources:
    ```bash
    ./stop_spark_connect.sh
    ```

---

## Cleaning Up
To delete the client VM and the GCS bucket, leaving the Dataproc cluster intact:
```bash
./cleanup_resources.sh
```
