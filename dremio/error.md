# Troubleshooting & Reproduction Guide: Argo Workflows Hanging During Dremio Arrow Flight Queries

## 1. Executive Summary & Overview
When running Python-based data pipelines inside Argo Workflows that interact with Dremio via Apache Arrow Flight or high-throughput database drivers, workflows can occasionally hang indefinitely right after successful authentication and query result retrieval. 

This document outlines the root cause of this specific failure mode (lingering gRPC connections, thread management, and output buffering) and provides a structured prompt for LLMs/Codex to deploy a minimal reproduction environment in a Kubernetes cluster where Argo Workflows and ArgoCD are already active.

---

## 2. Root Cause Analysis
1. **Unclosed gRPC Sockets & Arrow Flight Threads:** Dremio's Arrow Flight client library builds on gRPC, spawning background worker and keep-alive threads. If a Python script finishes processing query data but fails to explicitly invoke `client.close()`, Python's interpreter hangs on exit waiting for these lingering non-daemon threads or open TCP sockets to time out.
2. **Container Output Buffering:** By default, Python buffers `stdout` and `stderr` streams when running in containerized environments. If a job finishes executing core queries but the container process lingers without flushing output streams or signaling an exit code, the Argo `wait` container remains stuck in a `Running` state.
3. **Stream and Reader Leakage:** Failing to consume or cleanly close `FlightStreamReader` handles can leave network connections blocked awaiting server-side acknowledgment packets.

---

## 3. Recommended Code Pattern: Safe Context Manager
To eliminate hanging connections, encapsulate the Dremio Flight client inside a safe context manager that ensures deterministic cleanup:

```python
from contextlib import contextmanager
import pyarrow.flight as flight
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@contextmanager
def dremio_flight_client(host: str, port: int, token: str):
    client = None
    try:
        endpoint = f"grpc+tls://{host}:{port}"
        logger.info(f"Connecting to Dremio Flight endpoint: {host}:{port}")
        client = flight.FlightClient(endpoint)
        headers = [(b"authorization", f"Bearer {token}".encode("utf-8"))]
        yield client, headers
    except Exception as e:
        logger.error(f"Error during Dremio Flight operation: {e}")
        raise
    finally:
        if client is not None:
            logger.info("Closing Dremio Arrow Flight client connections...")
            try:
                client.close()
                logger.info("Dremio Flight client closed successfully.")
            except Exception as close_err:
                logger.warning(f"Error while closing flight client: {close_err}")
```

---

## 4. Codex Prompt to Recreate the Error Environment

Copy and paste the prompt below into Codex or your preferred coding assistant to generate a test deployment for reproducing this issue in your existing Kubernetes cluster.

```text
Act as a Senior Kubernetes and Data Platform Engineer. I have a Kubernetes cluster with Argo Workflows and ArgoCD already installed and configured. I want to deploy a lightweight Dremio instance (or mock/standalone test container) and a corresponding Argo Workflow to reproduce and debug a scenario where a Python workflow step hangs right after authenticating and fetching query results from Dremio via Apache Arrow Flight.

Please generate a single Kubernetes manifest or a set of clean yaml manifests containing:
1. A lightweight Dremio deployment (or community-edition/mock database container suitable for testing flight/JDBC connections) exposed internally within a test namespace (e.g., dremio-test).
2. A ConfigMap containing a Python script that intentionally replicates the hanging behavior by opening an Arrow Flight client, fetching data, but omitting explicit client cleanup and running without unbuffered output (`PYTHONUNBUFFERED=1`).
3. A corrected version of the Python script using a robust context manager (`try...finally` with `client.close()`) to show how to fix the hang.
4. An Argo Workflow custom resource definition (YAML) template that runs the script using the correct environment variables (`PYTHONUNBUFFERED=1`) and proper resource lifecycle handling.

Keep the setup simple, self-contained, and clear so I can apply it via kubectl to test the behavior immediately.
