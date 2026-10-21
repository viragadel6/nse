from gpu_entrypoint import run_worker


def execute_embedding(operation, payload, volume):
    volume.reload()
    return run_worker(operation, payload)
