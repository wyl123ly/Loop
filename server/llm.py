"""DeepSeek 客户端：流式对话、非流式补全、计费估算。"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import AsyncIterator

import httpx


class LLMError(RuntimeError):
    def __init__(self, message: str, status: int = 0):
        super().__init__(message)
        self.status = status


# 每 1M token 的美元单价（非高峰）
PRICES: dict[str, tuple[float, float]] = {
    "deepseek-flash": (0.15, 0.60),
    "deepseek-v4-pro": (0.66, 1.98),
}
DEFAULT_PRICE = (0.15, 0.60)


def is_peak(ts: datetime | None = None) -> bool:
    """UTC 01:00-04:00 与 06:00-10:00 为高峰，单价翻倍。"""
    hour = (ts or datetime.now(timezone.utc)).hour
    return 1 <= hour < 4 or 6 <= hour < 10


def estimate_cost(model: str, tokens_in: int, tokens_out: int, ts: datetime | None = None) -> float:
    price_in, price_out = PRICES.get(model, DEFAULT_PRICE)
    multiplier = 2.0 if is_peak(ts) else 1.0
    cost = (tokens_in * price_in + tokens_out * price_out) / 1_000_000 * multiplier
    return round(cost, 6)


def _explain(status: int, detail: str) -> str:
    if status == 401:
        return "API Key 无效或已过期，请到设置里检查。"
    if status == 402:
        return "DeepSeek 账户余额不足，请充值后再试。"
    if status == 429:
        return "请求太频繁（限流），稍等几秒再试。"
    if status >= 500:
        return f"DeepSeek 服务暂时不可用（{status}），稍后重试。"
    return f"请求失败（{status}）：{detail[:200]}"


def _headers(cfg: dict) -> dict:
    return {
        "Authorization": f"Bearer {cfg.get('api_key', '')}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }


def _url(cfg: dict) -> str:
    return cfg.get("base_url", "https://api.deepseek.com").rstrip("/") + "/chat/completions"


async def stream_chat(
    cfg: dict,
    messages: list[dict],
    tools: list[dict] | None = None,
    temperature: float = 0.7,
) -> AsyncIterator[dict]:
    if not cfg.get("api_key"):
        raise LLMError("还没有配置 DeepSeek API Key，点左下角「设置」填入。", 401)

    body = {
        "model": cfg.get("model", "deepseek-flash"),
        "messages": messages,
        "stream": True,
        "temperature": temperature,
        "stream_options": {"include_usage": True},
    }
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"

    timeout = httpx.Timeout(180.0, connect=20.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream("POST", _url(cfg), json=body, headers=_headers(cfg)) as resp:
            if resp.status_code != 200:
                raw = (await resp.aread()).decode("utf-8", "ignore")
                raise LLMError(_explain(resp.status_code, raw), resp.status_code)
            async for line in resp.aiter_lines():
                if not line or not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    yield json.loads(data)
                except json.JSONDecodeError:
                    continue


async def complete(
    cfg: dict,
    messages: list[dict],
    temperature: float = 0.4,
    max_tokens: int | None = None,
) -> tuple[str, dict]:
    if not cfg.get("api_key"):
        raise LLMError("还没有配置 DeepSeek API Key。", 401)
    body = {
        "model": cfg.get("model", "deepseek-flash"),
        "messages": messages,
        "stream": False,
        "temperature": temperature,
    }
    if max_tokens:
        body["max_tokens"] = max_tokens
    timeout = httpx.Timeout(180.0, connect=20.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        resp = await client.post(_url(cfg), json=body, headers=_headers(cfg))
        if resp.status_code != 200:
            raise LLMError(_explain(resp.status_code, resp.text), resp.status_code)
        data = resp.json()
    choice = (data.get("choices") or [{}])[0]
    content = ((choice.get("message") or {}).get("content") or "").strip()
    return content, data.get("usage") or {}


def extract_json(text: str):
    """从模型输出里抠出第一个 JSON 对象/数组（容忍 ```json 包裹）。"""
    text = (text or "").strip()
    if text.startswith("```"):
        text = text.split("```", 2)[1] if text.count("```") >= 2 else text
        if text.lstrip().startswith("json"):
            text = text.lstrip()[4:]
    text = text.strip()
    for opener, closer in (("[", "]"), ("{", "}")):
        start = text.find(opener)
        end = text.rfind(closer)
        if start != -1 and end > start:
            try:
                return json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                continue
    return None
