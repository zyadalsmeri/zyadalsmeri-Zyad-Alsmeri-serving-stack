from __future__ import annotations

from typing import List, Literal, Optional, Union

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    max_tokens: int = Field(default=256, ge=1)
    temperature: float = Field(default=0.7, ge=0.0, le=2.0)
    stream: bool = False
    tools: Optional[List[dict]] = None
    tool_choice: Optional[Union[str, dict]] = None


class ResponseMessage(BaseModel):
    role: Literal["assistant"] = "assistant"
    content: str


class Choice(BaseModel):
    index: int = 0
    message: ResponseMessage
    finish_reason: Literal["stop", "length"] = "stop"


class Usage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0


class ChatCompletionResponse(BaseModel):
    id: str
    object: Literal["chat.completion"] = "chat.completion"
    created: int
    model: str
    choices: List[Choice]
    usage: Usage


class ModelCard(BaseModel):
    id: str
    object: Literal["model"] = "model"
    created: int
    owned_by: str = "aidc"


class ModelList(BaseModel):
    object: Literal["list"] = "list"
    data: List[ModelCard]


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    model: str