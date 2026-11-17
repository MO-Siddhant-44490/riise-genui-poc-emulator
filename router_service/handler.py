"""GenUI router service (POC).

The app sends {"system": "...", "message": "...", "model": "..."} and gets {"text": "..."} back.
Bedrock is called with the Lambda's execution role, so no AWS key ever exists in the app.
Access is gated by a shared token in the x-genui-token header (env GENUI_TOKEN); the Function URL
itself is public. Good enough for an internal test build; a real release would verify the RIISE JWT.
"""
import hmac
import json
import os

import boto3

_REGION = os.environ.get("GENUI_REGION", "ap-south-1")
_DEFAULT_MODEL = os.environ.get("GENUI_MODEL", "qwen.qwen3-32b-v1:0")
_ALLOWED_MODELS = set(filter(None, os.environ.get("GENUI_ALLOWED_MODELS", _DEFAULT_MODEL).split(",")))
_TOKEN = os.environ.get("GENUI_TOKEN", "")
_MAX_CHARS = 200000  # the routing prompt is ~24k chars today and grows with the catalog

_bedrock = boto3.client("bedrock-runtime", region_name=_REGION)


def _reply(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not _TOKEN or not hmac.compare_digest(headers.get("x-genui-token", ""), _TOKEN):
        return _reply(401, {"error": "unauthorised"})
    try:
        body = json.loads(event.get("body") or "{}")
    except ValueError:
        return _reply(400, {"error": "bad json"})
    system = str(body.get("system", ""))[:_MAX_CHARS]
    message = str(body.get("message", ""))[:4000]
    model = str(body.get("model") or _DEFAULT_MODEL)
    if not message:
        return _reply(400, {"error": "message required"})
    if model not in _ALLOWED_MODELS:
        return _reply(400, {"error": "model not allowed"})
    res = _bedrock.converse(
        modelId=model,
        system=[{"text": system}] if system else [],
        messages=[{"role": "user", "content": [{"text": message}]}],
        inferenceConfig={"maxTokens": int(os.environ.get("GENUI_MAX_TOKENS", "700"))},
    )
    text = "".join(c.get("text", "") for c in res["output"]["message"]["content"])
    usage = res.get("usage", {})
    return _reply(200, {"text": text, "model": model, "usage": {"in": usage.get("inputTokens"), "out": usage.get("outputTokens")}, "ms": res.get("metrics", {}).get("latencyMs")})
