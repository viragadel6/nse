from gpu_entrypoint import run_worker


def execute_training(payload, volume):
    volume.reload()
    try:
        return run_worker("train", payload)
    finally:
        volume.commit()
