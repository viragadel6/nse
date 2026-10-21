import sys
from pathlib import Path

import modal

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gpu_entrypoint import WorkerFailure, configuration, run_worker
from embedding_entrypoint import execute_embedding
from training_entrypoint import execute_training

config = configuration()
source_root = Path(__file__).resolve().parents[1]
app = modal.App(config["app_name"])
volume = modal.Volume.from_name(config["artifact_volume"], create_if_missing=True)
image = (
    modal.Image.from_registry(config["cuda_image"], add_python="3.11")
    .pip_install("ziglang==" + config["zig_version"], "fastapi==" + config["dependencies"]["fastapi"])
    .add_local_dir(str(source_root), "/opt/runtime", copy=True, ignore=[".zig-cache", "zig-out", "data", "__pycache__"])
    .run_commands("cd /opt/runtime && python -m ziglang build -Doptimize=ReleaseFast -j2")
    .env({"PYTHONPATH": "/opt/runtime/modal", "LD_LIBRARY_PATH": "/usr/local/cuda/lib64:/usr/local/nvidia/lib64"})
)
resources = {"image": image, "cpu": config["cpu"], "memory": config["memory_mb"], "volumes": {config["artifact_mount"]: volume}}


@app.function(gpu="B300", timeout=config["embedding_timeout_seconds"], scaledown_window=config["scaledown_window_seconds"], **resources)
def embedding(operation: str, payload: dict):
    return execute_embedding(operation, payload, volume)


@app.function(gpu="B300", max_containers=1, timeout=config["training_timeout_seconds"], retries=modal.Retries(max_retries=3, initial_delay=2.0, backoff_coefficient=2.0), **resources)
def training(payload: dict):
    return execute_training(payload, volume)


@app.function(max_containers=1, timeout=config["embedding_timeout_seconds"], **resources)
def artifact(operation: str, payload: dict):
    volume.reload()
    try:
        return run_worker(operation, payload, binary=operation == "artifact")
    finally:
        if operation == "register":
            volume.commit()


@app.function(timeout=config["embedding_timeout_seconds"], **resources)
@modal.asgi_app()
def gateway():
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse, Response
    from modal.exception import NotFoundError

    web = FastAPI()

    async def payload(request):
        data = await request.body()
        if len(data) > config["request_bytes"]:
            raise WorkerFailure({"code": "WorkloadExceedsMemoryBudget", "retryable": False})
        import json
        try:
            value = json.loads(data)
        except (json.JSONDecodeError, UnicodeDecodeError) as failure:
            raise WorkerFailure({"code": "MalformedWorkload", "retryable": False}) from failure
        if not isinstance(value, dict):
            raise WorkerFailure({"code": "InvalidWorkloadType", "retryable": False})
        return value

    @web.exception_handler(WorkerFailure)
    async def worker_error(request, failure):
        return JSONResponse({"error": failure.detail}, status_code=503 if failure.detail.get("retryable") else 422)

    @web.exception_handler(Exception)
    async def platform_error(request, failure):
        return JSONResponse({"error": {"code": type(failure).__name__, "message": str(failure), "retryable": True}}, status_code=503)

    @web.get("/health")
    async def health(model_version: int = config["model_version"]):
        return await embedding.remote.aio("health", {"model_version": model_version})

    @web.post("/embed")
    async def single(request: Request):
        return await embedding.remote.aio("single", await payload(request))

    @web.post("/embeddings")
    async def batch(request: Request):
        return await embedding.remote.aio("embed", await payload(request))

    @web.post("/training")
    async def submit(request: Request):
        call = await training.spawn.aio(await payload(request))
        return JSONResponse({"protocol_version": 1, "call_id": call.object_id, "state": "submitted"}, status_code=202)

    @web.get("/training/{call_id}")
    async def status(call_id: str):
        try:
            call = modal.FunctionCall.from_id(call_id)
            result = await call.get.aio(timeout=0)
            return {"protocol_version": 1, "call_id": call_id, "state": "completed" if result["completed"] else "interrupted", "result": result}
        except TimeoutError:
            return {"protocol_version": 1, "call_id": call_id, "state": "running"}
        except NotFoundError:
            return JSONResponse({"error": {"code": "TrainingCallNotFound", "retryable": False}}, status_code=404)

    @web.delete("/training/{call_id}")
    async def cancel(call_id: str):
        call = modal.FunctionCall.from_id(call_id)
        await call.cancel.aio(terminate_containers=False)
        return {"protocol_version": 1, "call_id": call_id, "state": "cancelled"}

    @web.post("/models/refresh")
    async def refresh(request: Request):
        return await artifact.remote.aio("register", await payload(request))

    @web.get("/artifacts/{model_version}")
    async def download(model_version: int):
        data = await artifact.remote.aio("artifact", {"model_version": model_version})
        return Response(data, media_type="application/octet-stream")

    return web
