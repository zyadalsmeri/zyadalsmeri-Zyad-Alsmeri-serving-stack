from __future__ import annotations

import json
import os
import time
import uuid

import torch
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from transformers import AutoModelForCausalLM, AutoTokenizer

from schemas import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    Choice,
    HealthResponse,
    ModelCard,
    ModelList,
    ResponseMessage,
    Usage,
)


# ---------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------

MODEL_ID = os.environ.get(
    "MODEL_ID",
    "Qwen/Qwen2.5-0.5B-Instruct"
)

API_KEY = os.environ.get("API_KEY", "")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))


# ---------------------------------------------------------
# App
# ---------------------------------------------------------

app = FastAPI(
    title="serving-stack",
    version="wk2-compose-secure"
)


# ---------------------------------------------------------
# Security
# ---------------------------------------------------------

def require_api_key(
    authorization: str | None = Header(default=None)
):
    if not API_KEY:
        return

    if authorization != f"Bearer {API_KEY}":
        raise HTTPException(
            status_code=401,
            detail="Unauthorized"
        )


# ---------------------------------------------------------
# Model loading
# ---------------------------------------------------------

print(f"Loading {MODEL_ID} on CPU...")

tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float32
)

model.to("cpu")
model.eval()

print("Model ready")


# ---------------------------------------------------------
# Health
# ---------------------------------------------------------

@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        model=MODEL_ID
    )


# ---------------------------------------------------------
# Models
# ---------------------------------------------------------

@app.get("/v1/models", response_model=ModelList)
def list_models(
    authorization: str | None = Header(default=None)
) -> ModelList:
    require_api_key(authorization)

    return ModelList(
        data=[
            ModelCard(
                id=MODEL_ID,
                created=int(time.time()),
                owned_by="aidc"
            )
        ]
    )


# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------

def _build_inputs(req: ChatCompletionRequest):
    input_ids = tokenizer.apply_chat_template(
        [m.model_dump() for m in req.messages],
        add_generation_prompt=True,
        return_tensors="pt",
    )

    return input_ids, input_ids.shape[1]


def _effective_max_tokens(
    req: ChatCompletionRequest
) -> int:
    return min(
        req.max_tokens,
        MAX_TOKENS
    )


def _generate(
    input_ids,
    req: ChatCompletionRequest
):
    effective_max_tokens = _effective_max_tokens(req)

    with torch.no_grad():
        out = model.generate(
            input_ids,
            attention_mask=torch.ones_like(input_ids),
            max_new_tokens=effective_max_tokens,
            do_sample=req.temperature > 0,
            temperature=(
                req.temperature
                if req.temperature > 0
                else None
            ),
            pad_token_id=tokenizer.eos_token_id,
        )

    return out[0][input_ids.shape[1]:]


# ---------------------------------------------------------
# Chat completions
# ---------------------------------------------------------

@app.post(
    "/v1/chat/completions",
    response_model=None
)
def chat_completions(
    req: ChatCompletionRequest,
    authorization: str | None = Header(default=None)
):
    require_api_key(authorization)

    if req.model != MODEL_ID:
        raise HTTPException(
            status_code=400,
            detail={
                "error": {
                    "message": (
                        f"model '{req.model}' not found"
                    ),
                    "type": "invalid_request_error",
                    "code": "model_not_found"
                }
            },
        )

    input_ids, prompt_tokens = _build_inputs(req)

    if req.stream:
        return _stream(
            input_ids,
            prompt_tokens,
            req
        )

    new_tokens = _generate(
        input_ids,
        req
    )

    completion_tokens = int(
        new_tokens.shape[0]
    )

    effective_max_tokens = _effective_max_tokens(req)

    text = tokenizer.decode(
        new_tokens,
        skip_special_tokens=True
    )

    return ChatCompletionResponse(
        id="chatcmpl-" + uuid.uuid4().hex,
        created=int(time.time()),
        model=req.model,
        choices=[
            Choice(
                index=0,
                message=ResponseMessage(
                    role="assistant",
                    content=text
                ),
                finish_reason=(
                    "length"
                    if completion_tokens >= effective_max_tokens
                    else "stop"
                ),
            )
        ],
        usage=Usage(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=(
                prompt_tokens + completion_tokens
            ),
        ),
    )


# ---------------------------------------------------------
# Streaming
# ---------------------------------------------------------

def _stream(
    input_ids,
    prompt_tokens: int,
    req: ChatCompletionRequest
):
    new_tokens = _generate(
        input_ids,
        req
    )

    completion_tokens = int(
        new_tokens.shape[0]
    )

    effective_max_tokens = _effective_max_tokens(req)

    finish_reason = (
        "length"
        if completion_tokens >= effective_max_tokens
        else "stop"
    )

    cid = "chatcmpl-" + uuid.uuid4().hex
    created = int(time.time())

    def chunk(delta: dict, finish=None):
        payload = {
            "id": cid,
            "object": "chat.completion.chunk",
            "created": created,
            "model": req.model,
            "choices": [
                {
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finish
                }
            ],
        }

        return (
            "data: "
            + json.dumps(payload)
            + "\n\n"
        )

    def events():
        yield chunk(
            {
                "role": "assistant",
                "content": ""
            }
        )

        for tok in new_tokens:
            piece = tokenizer.decode(
                [tok],
                skip_special_tokens=True
            )

            if piece:
                yield chunk(
                    {"content": piece}
                )

        yield chunk(
            {},
            finish=finish_reason
        )

        yield "data: [DONE]\n\n"

    return StreamingResponse(
        events(),
        media_type="text/event-stream"
    )