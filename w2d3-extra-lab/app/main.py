import json
import os

from fastapi import FastAPI, HTTPException

app = FastAPI(title="model-registry")

REGISTRY_PATH = os.environ.get(
    "REGISTRY_PATH",
    "registry.json"
)

with open(REGISTRY_PATH) as f:
    REGISTRY = json.load(f)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/registry")
def list_models():
    return {
        "models": list(REGISTRY.keys())
    }


@app.get("/registry/{name}")
def get_model(name: str):
    if name not in REGISTRY:
        raise HTTPException(
            status_code=404,
            detail=f"no such model: {name}"
        )

    return REGISTRY[name]