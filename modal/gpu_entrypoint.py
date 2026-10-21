import json
import os
import subprocess
from pathlib import Path


class WorkerFailure(RuntimeError):
    def __init__(self, detail):
        self.detail = detail
        super().__init__(json.dumps(detail, separators=(",", ":")))


def configuration():
    with Path(__file__).with_name("modal_config.json").open("r", encoding="utf-8") as source:
        value = json.load(source)
    if value["protocol_version"] != 1 or value["gpu"] != "B300" or value["gpu_count"] != 1:
        raise RuntimeError("IncompatibleDeploymentConfiguration")
    return value


def run_worker(operation, payload, binary=False):
    config = configuration()
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(encoded) > config["request_bytes"]:
        raise WorkerFailure({"code": "WorkloadExceedsMemoryBudget", "retryable": False})
    timeout = config["training_timeout_seconds"] if operation == "train" else config["embedding_timeout_seconds"]
    environment = os.environ.copy()
    environment["LD_LIBRARY_PATH"] = "/usr/local/cuda/lib64:/usr/local/nvidia/lib64:" + environment.get("LD_LIBRARY_PATH", "")
    try:
        result = subprocess.run(
            [config["worker"], operation, config["artifact_mount"]],
            input=encoded,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout + 60,
            env=environment,
            check=False,
        )
    except subprocess.TimeoutExpired as failure:
        raise WorkerFailure({"code": "GpuWorkerDeadlineExceeded", "retryable": True}) from failure
    except OSError as failure:
        raise WorkerFailure({"code": "GpuWorkerLaunchFailed", "message": str(failure), "retryable": True}) from failure
    if result.returncode != 0:
        lines = result.stderr.decode("utf-8", errors="replace").splitlines()
        detail = {"code": "GpuWorkerFailed", "exit_code": result.returncode, "retryable": False}
        for line in reversed(lines):
            try:
                decoded = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(decoded, dict) and "error" in decoded:
                detail = decoded["error"]
                break
        raise WorkerFailure(detail)
    if binary:
        return result.stdout
    try:
        return json.loads(result.stdout)
    except (json.JSONDecodeError, UnicodeDecodeError) as failure:
        raise WorkerFailure({"code": "InvalidGpuWorkerResponse", "retryable": False}) from failure
