import hashlib
import json
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Literal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

app = FastAPI(title="GNN Serving Dispatcher")

# ---------- Configuration ----------
SMALL_ENDPOINT_NAME = os.environ.get("SMALL_ENDPOINT_NAME", "")
LARGE_ENDPOINT_NAME = os.environ.get("LARGE_ENDPOINT_NAME", "")
SECRET_ARN = os.environ.get("SECRET_ARN", "")
ASYNC_IO_BUCKET = os.environ.get("ASYNC_IO_BUCKET", "")
TELEMETRY_TABLE_NAME = os.environ.get("TELEMETRY_TABLE_NAME", "")
ENV_NAME = os.environ.get("ENV_NAME", "prod")

# ---------- Cached Secrets ----------
_api_keys_cache: dict | None = None
_api_keys_cache_time: float = 0.0
CACHE_TTL_SECONDS = 60
SKIP_TIMEBOX_SECONDS = 120  # in-flight prior only blocks duplicates within 2 min


def _get_api_keys() -> dict:
    global _api_keys_cache, _api_keys_cache_time
    now = time.time()
    if _api_keys_cache is not None and (now - _api_keys_cache_time) < CACHE_TTL_SECONDS:
        return _api_keys_cache
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=SECRET_ARN)
    _api_keys_cache = json.loads(resp["SecretString"])
    _api_keys_cache_time = now
    return _api_keys_cache


def _authenticate(api_key: str, requested_tier: str | None = None) -> tuple[str, str]:
    """Validate api_key against the secret and (optionally) enforce a tier match.

    Returns ``(tier, user_id)`` where ``user_id`` is the sha256 of the raw key —
    a stable, anonymous customer identifier we never have to store separately.
    Pass ``requested_tier=None`` from routes that don't take a tier (e.g.
    ``/approve``); the tier check is skipped in that case.

    The ``all`` tier is treated as authorized for any requested tier.
    """
    key_hash = hashlib.sha256(api_key.encode()).hexdigest()
    api_keys = _get_api_keys()
    entry = api_keys.get(key_hash)
    if entry is None:
        raise HTTPException(status_code=401, detail="Invalid API key")
    entry_tier = entry["tier"]
    if requested_tier is not None and entry_tier != requested_tier and entry_tier != "all":
        raise HTTPException(
            status_code=403,
            detail=f"Key is for tier '{entry_tier}', not '{requested_tier}'",
        )
    return entry_tier, key_hash


def _authenticate_admin(api_key: str) -> str:
    """Require the caller's key to map to the ``all`` tier. Returns user_id."""
    tier, user_id = _authenticate(api_key)
    if tier != "all":
        raise HTTPException(status_code=403, detail="Admin endpoints require the 'all' tier key")
    return user_id


def _s3_key_from_uri(uri: str, bucket: str) -> str:
    prefix = f"s3://{bucket}/"
    return uri[len(prefix):]


# ---------- Endpoint describe cache ----------
# Cached value is (model_version, status, last_modified_iso, current_instances,
# desired_instances). ``last_modified`` is a UTC-ISO string so callers can
# return it directly in JSON without an extra serialize step. Any of the
# latter four may be ``None`` on failure or when SageMaker omits the field.
# Shorter TTL than the API-key cache: instance counts flip on scale-from-zero
# transitions and the admin UI needs near-live cold/warm visibility.
ENDPOINT_DESCRIBE_TTL_SECONDS = 10
_endpoint_describe_cache: dict[
    str, tuple[float, tuple[str, str | None, str | None, int | None, int | None]]
] = {}


def _describe_endpoint(
    tier: str,
) -> tuple[str, str | None, str | None, int | None, int | None]:
    """Resolve the currently-serving endpoint metadata for a tier by walking
    SageMaker DescribeEndpoint -> DescribeEndpointConfig -> DescribeModel.

    Returns ``(model_version, status, last_modified, current_instances,
    desired_instances)`` where:
    - ``model_version`` is the git SHA encoded in the primary container image
      tag (or ``"unknown"`` on any failure).
    - ``status`` is the ``EndpointStatus`` (e.g. ``"InService"``) or ``None``
      on failure.
    - ``last_modified`` is the ``LastModifiedTime`` as an ISO-8601 UTC string,
      or ``None`` on failure.
    - ``current_instances`` / ``desired_instances`` come from the top-level
      ``ProductionVariants[0]`` of DescribeEndpoint (live capacity, distinct
      from the EndpointConfig variants). Either is ``None`` if SageMaker
      omits the field or on failure.

    Cached per-tier with ``ENDPOINT_DESCRIBE_TTL_SECONDS``. Failures are
    cached briefly so we don't hammer SageMaker if it's down.
    """
    now = time.time()
    cached = _endpoint_describe_cache.get(tier)
    if cached is not None and (now - cached[0]) < ENDPOINT_DESCRIBE_TTL_SECONDS:
        return cached[1]

    endpoint_map = {"small": SMALL_ENDPOINT_NAME, "large": LARGE_ENDPOINT_NAME}
    endpoint_name = endpoint_map.get(tier, "")
    if not endpoint_name:
        result: tuple[str, str | None, str | None, int | None, int | None] = (
            "unknown",
            None,
            None,
            None,
            None,
        )
        _endpoint_describe_cache[tier] = (now, result)
        return result

    version = "unknown"
    status: str | None = None
    last_modified_iso: str | None = None
    current_instances: int | None = None
    desired_instances: int | None = None
    try:
        sm = boto3.client("sagemaker")
        ep = sm.describe_endpoint(EndpointName=endpoint_name)
        status = ep.get("EndpointStatus")
        last_modified = ep.get("LastModifiedTime")
        if isinstance(last_modified, datetime):
            if last_modified.tzinfo is None:
                last_modified = last_modified.replace(tzinfo=timezone.utc)
            else:
                last_modified = last_modified.astimezone(timezone.utc)
            last_modified_iso = last_modified.isoformat()
        pv = ep.get("ProductionVariants") or []
        if pv:
            current_instances = pv[0].get("CurrentInstanceCount")
            desired_instances = pv[0].get("DesiredInstanceCount")
        cfg = sm.describe_endpoint_config(EndpointConfigName=ep["EndpointConfigName"])
        variants = cfg.get("ProductionVariants", [])
        if not variants:
            raise RuntimeError("no production variants")
        model_name = variants[0]["ModelName"]
        model = sm.describe_model(ModelName=model_name)
        primary = model.get("PrimaryContainer") or {}
        image = primary.get("Image")
        if image:
            # Image looks like ".../repo:tag" — the tag is the git SHA we want.
            tag = image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else image
            version = tag
        else:
            version = primary.get("ModelPackageName") or model_name
    except (BotoCoreError, ClientError, KeyError, RuntimeError) as exc:
        print(f"_describe_endpoint({tier}) failed: {exc}")
        version = "unknown"

    result = (version, status, last_modified_iso, current_instances, desired_instances)
    _endpoint_describe_cache[tier] = (now, result)
    return result


def _get_model_version(tier: str) -> str:
    """Backwards-compatible accessor that returns just the model version.

    Thin wrapper over ``_describe_endpoint`` so existing callers continue to
    work without change. New code that also needs status/last_modified should
    call ``_describe_endpoint`` directly.
    """
    return _describe_endpoint(tier)[0]


# ---------- Telemetry helpers ----------
def _hash_payload(payload: dict) -> str:
    """Canonical JSON sha256 — same payload always yields the same hash."""
    canon = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canon).hexdigest()


def _telemetry_table():
    return boto3.resource("dynamodb").Table(TELEMETRY_TABLE_NAME)


def _is_within_skip_timebox(created_at_str, now_utc) -> bool:
    """Return True iff created_at_str is a parseable timestamp within SKIP_TIMEBOX_SECONDS of now_utc.

    Fail-open on missing or unparseable values: returning False means the prior
    row is treated as stale, so the new submit proceeds. False-skip is the bug
    we are fixing; fail-closed would re-introduce it.
    """
    if not created_at_str:
        return False
    try:
        s = created_at_str
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        ts = datetime.fromisoformat(s)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError) as exc:
        print(f"_is_within_skip_timebox parse error: {exc!r} created_at={created_at_str!r}")
        return False
    return (now_utc - ts).total_seconds() < SKIP_TIMEBOX_SECONDS


def _handle_prior_rows(table, user_id: str, input_sha256: str) -> Literal["proceed", "skip"]:
    """Inspect prior rows with the same {user_id, input_sha256}.

    - If any prior row has ``inference_status == "running"``, return ``"skip"``
      so the caller writes a synthetic skipped row instead of double-invoking.
    - Otherwise, flip any prior rows that completed with ``verdict="pending"``
      to ``"rejected"`` (the user's submission of a duplicate is implicit
      regen-style rejection of those completed-but-not-yet-judged outputs).
      The conditional update guards against races.

    The GSI is KEYS_ONLY (DynamoDB won't let us widen an existing GSI's
    projection in-place), so for each prior key returned by the Query we do a
    per-row GetItem to read ``verdict`` and ``inference_status``. The
    duplicate-submit hot path is rare so the N+1 cost is acceptable.

    Defensive: rows missing ``inference_status`` (legacy rows from before this
    field existed, e.g. PR #3 era) are treated as ``inference_status="completed"``
    for backwards compatibility — they're eligible for the verdict flip but
    don't block as "running". Rows that vanish between Query and GetItem
    (e.g. deleted by a TTL or admin) are ignored.
    """
    gsi1pk = f"{user_id}#{input_sha256}"
    resp = table.query(
        IndexName="byUserAndInput",
        KeyConditionExpression=Key("gsi1pk").eq(gsi1pk),
    )
    key_items = resp.get("Items", [])

    # GSI is KEYS_ONLY — fetch full rows for each prior to read verdict/status.
    priors: list[dict] = []
    for key_item in key_items:
        prior_id = key_item.get("inference_id")
        if not prior_id:
            continue
        full = table.get_item(Key={"inference_id": prior_id}).get("Item")
        if full is None:
            # Row vanished between Query and GetItem — treat as not present.
            continue
        priors.append(full)

    # First pass: are any priors still in-flight? If so, skip outright.
    now_utc = datetime.now(timezone.utc)
    for item in priors:
        if item.get("inference_status") != "running":
            continue
        if _is_within_skip_timebox(item.get("created_at"), now_utc):
            return "skip"
        # stale running row -> fall through; reconciler is out of scope.

    # Second pass: flip completed+pending priors to rejected. Legacy rows
    # without inference_status are treated as completed (see docstring).
    for item in priors:
        status = item.get("inference_status", "completed")
        if status != "completed":
            continue
        if item.get("verdict") != "pending":
            continue
        try:
            table.update_item(
                Key={"inference_id": item["inference_id"]},
                UpdateExpression="SET verdict = :r",
                ConditionExpression=(
                    "verdict = :p AND "
                    "(attribute_not_exists(inference_status) OR inference_status = :c)"
                ),
                ExpressionAttributeValues={
                    ":r": "rejected",
                    ":p": "pending",
                    ":c": "completed",
                },
            )
        except ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    return "proceed"


# ---------- Request/Response Models ----------
class PredictRequest(BaseModel):
    tier: str = Field(..., pattern="^(small|large)$")
    payload: dict


class PredictAccepted(BaseModel):
    inference_id: str
    output_location: str
    input_sha256: str
    skipped: bool = False


class PredictStatus(BaseModel):
    inference_id: str
    status: str
    result: dict | None = None
    error: str | None = None
    verdict: str | None = None


class ApproveResponse(BaseModel):
    verdict: str


# ---------- Routes ----------
@app.get("/healthz")
def healthz() -> dict:
    return {
        "status": "ok",
        "env": ENV_NAME,
        "sha": os.environ.get("GIT_SHA", "unknown"),
    }


@app.post("/v1/predict", response_model=PredictAccepted, status_code=202)
async def predict(body: PredictRequest, x_api_key: str = Header(...)):
    tier, user_id = _authenticate(x_api_key, body.tier)

    endpoint_map = {"small": SMALL_ENDPOINT_NAME, "large": LARGE_ENDPOINT_NAME}
    endpoint_name = endpoint_map.get(body.tier, "")
    if not endpoint_name:
        raise HTTPException(
            status_code=503,
            detail=f"No endpoint configured for tier: {body.tier}",
        )

    # Hash the payload BEFORE writing the new row, then decide whether this
    # submission is a duplicate-while-running (skip) or a fresh attempt that
    # rejects any prior completed-but-pending outputs.
    input_sha256 = _hash_payload(body.payload)
    table = _telemetry_table()
    decision = _handle_prior_rows(table, user_id, input_sha256)

    # Resolve the model version once per request. Used in both branches.
    model_version = _get_model_version(body.tier)
    now_iso = datetime.now(timezone.utc).isoformat()

    if decision == "skip":
        # Synthesize a row but DO NOT invoke SageMaker. The original in-flight
        # row will surface its result on its own card; this card is purely a
        # marker that the duplicate submission was deliberately ignored.
        inference_id = str(uuid.uuid4())
        table.put_item(
            Item={
                "inference_id": inference_id,
                "user_id": user_id,
                "tier": tier if tier != "all" else body.tier,
                "input_sha256": input_sha256,
                "gsi1pk": f"{user_id}#{input_sha256}",
                "output_s3_uri": "",
                "verdict": "skipped",
                "inference_status": "skipped",
                "model_version": model_version,
                "created_at": now_iso,
            }
        )
        return PredictAccepted(
            inference_id=inference_id,
            output_location="",
            input_sha256=input_sha256,
            skipped=True,
        )

    inference_id = str(uuid.uuid4())
    s3_input_key = f"input/{inference_id}.json"
    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=ASYNC_IO_BUCKET,
        Key=s3_input_key,
        Body=json.dumps(body.payload),
        ContentType="application/json",
    )

    sm_client = boto3.client("sagemaker-runtime")
    input_location = f"s3://{ASYNC_IO_BUCKET}/{s3_input_key}"
    try:
        sm_resp = sm_client.invoke_endpoint_async(
            EndpointName=endpoint_name,
            InputLocation=input_location,
            ContentType="application/json",
            InferenceId=inference_id,
        )
    except (BotoCoreError, ClientError) as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    output_uri = sm_resp["OutputLocation"]
    failure_uri = sm_resp.get("FailureLocation", f"s3://{ASYNC_IO_BUCKET}/failure/{inference_id}.out")
    output_key = _s3_key_from_uri(output_uri, ASYNC_IO_BUCKET)
    failure_key = _s3_key_from_uri(failure_uri, ASYNC_IO_BUCKET)
    s3_client.put_object(
        Bucket=ASYNC_IO_BUCKET,
        Key=f"meta/{inference_id}.json",
        Body=json.dumps({"output_key": output_key, "failure_key": failure_key}),
        ContentType="application/json",
    )

    table.put_item(
        Item={
            "inference_id": inference_id,
            "user_id": user_id,
            "tier": tier if tier != "all" else body.tier,
            "input_sha256": input_sha256,
            "gsi1pk": f"{user_id}#{input_sha256}",
            "output_s3_uri": output_uri,
            "verdict": "pending",
            "inference_status": "running",
            "model_version": model_version,
            "created_at": now_iso,
        }
    )

    return PredictAccepted(
        inference_id=inference_id,
        output_location=output_uri,
        input_sha256=input_sha256,
        skipped=False,
    )


def _get_telemetry_item(inference_id: str) -> dict | None:
    if not TELEMETRY_TABLE_NAME:
        return None
    try:
        resp = _telemetry_table().get_item(Key={"inference_id": inference_id})
    except ClientError:
        return None
    return resp.get("Item")


def _mark_inference_status(inference_id: str, new_status: str, expected_status: str) -> None:
    """Conditional-update inference_status. Idempotent — swallows
    ConditionalCheckFailedException so a status route called many times never
    re-flips a row that's already past the expected state."""
    try:
        _telemetry_table().update_item(
            Key={"inference_id": inference_id},
            UpdateExpression="SET inference_status = :n",
            ConditionExpression="inference_status = :e",
            ExpressionAttributeValues={":n": new_status, ":e": expected_status},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise


@app.get("/v1/predict/{inference_id}", response_model=PredictStatus)
async def predict_status(inference_id: str):
    s3_client = boto3.client("s3")
    item = _get_telemetry_item(inference_id)
    verdict = item.get("verdict") if item else None
    inference_status = item.get("inference_status") if item else None

    # Skipped rows are a terminal local-only state — they never had a SageMaker
    # invoke, so there's no S3 meta to look up. Surface as status="skipped"
    # with verdict="skipped" so the UI can render the appropriate badge.
    if inference_status == "skipped":
        return PredictStatus(
            inference_id=inference_id,
            status="skipped",
            verdict=verdict or "skipped",
        )

    try:
        meta_obj = s3_client.get_object(Bucket=ASYNC_IO_BUCKET, Key=f"meta/{inference_id}.json")
        meta = json.loads(meta_obj["Body"].read())
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("NoSuchKey", "404"):
            return PredictStatus(
                inference_id=inference_id,
                status="error",
                error="Metadata not found — inference_id unknown or meta file missing",
                verdict=verdict,
            )
        raise HTTPException(status_code=502, detail=str(e)) from e

    output_key = meta["output_key"]
    failure_key = meta["failure_key"]

    try:
        s3_client.head_object(Bucket=ASYNC_IO_BUCKET, Key=output_key)
        obj = s3_client.get_object(Bucket=ASYNC_IO_BUCKET, Key=output_key)
        result = json.loads(obj["Body"].read())
        # Mark DDB row as completed (idempotent; only flips running -> completed).
        _mark_inference_status(inference_id, "completed", "running")
        return PredictStatus(
            inference_id=inference_id, status="completed", result=result, verdict=verdict,
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "404":
            raise HTTPException(status_code=502, detail=str(e)) from e

    try:
        s3_client.head_object(Bucket=ASYNC_IO_BUCKET, Key=failure_key)
        obj = s3_client.get_object(Bucket=ASYNC_IO_BUCKET, Key=failure_key)
        error_body = obj["Body"].read().decode()
        # Failed inferences never get a verdict per spec — surface None.
        _mark_inference_status(inference_id, "failed", "running")
        return PredictStatus(
            inference_id=inference_id, status="failed", error=error_body, verdict=None,
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "404":
            raise HTTPException(status_code=502, detail=str(e)) from e

    return PredictStatus(inference_id=inference_id, status="pending", verdict=verdict)


@app.post("/v1/predict/{inference_id}/approve", response_model=ApproveResponse)
async def approve(inference_id: str, x_api_key: str = Header(...)):
    _, caller_user_id = _authenticate(x_api_key)  # tier-agnostic auth
    table = _telemetry_table()

    resp = table.get_item(Key={"inference_id": inference_id})
    item = resp.get("Item")
    if item is None:
        raise HTTPException(status_code=404, detail="inference_id not found")
    if item.get("user_id") != caller_user_id:
        raise HTTPException(status_code=403, detail="not your inference_id")

    try:
        table.update_item(
            Key={"inference_id": inference_id},
            UpdateExpression="SET verdict = :a",
            ConditionExpression="verdict = :p",
            ExpressionAttributeValues={":a": "approved", ":p": "pending"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Verdict already moved past pending — re-fetch and report the
            # current state in a 409 so the client can resync. Skipped rows
            # (verdict="skipped") naturally land here too.
            current = table.get_item(Key={"inference_id": inference_id}).get("Item", {})
            return JSONResponse(
                status_code=409,
                content={"verdict": current.get("verdict", "unknown")},
            )
        raise

    return ApproveResponse(verdict="approved")


# ---------- Admin metrics ----------
_VERDICT_KEYS = ("pending", "approved", "rejected", "skipped")
_STATUS_KEYS = ("running", "completed", "failed", "skipped", "abandoned")
# Render-only split: ``unannotated`` = ``inference_status="completed" AND
# verdict="pending"``. We surface it as an extra counts key alongside the
# existing pending/running counters; no DDB schema change.
_DERIVED_KEYS = ("unannotated",)


@app.get("/v1/admin/metrics")
async def admin_metrics(x_api_key: str = Header(...)):
    _authenticate_admin(x_api_key)

    table = _telemetry_table()
    # We use Table.scan (resource) with manual LastEvaluatedKey pagination so
    # items are already deserialized into native Python types — simpler than
    # the low-level paginator + TypeDeserializer dance.
    buckets: dict[tuple[str, str], dict[str, int]] = {}

    total_inferences = 0
    approved_count = 0
    rejected_count = 0
    distinct_users: set[str] = set()

    scan_kwargs: dict = {}
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            model_version = item.get("model_version") or "unknown"
            tier = item.get("tier") or "unknown"
            key = (model_version, tier)
            counts = buckets.setdefault(
                key,
                {k: 0 for k in (*_VERDICT_KEYS, *_STATUS_KEYS, *_DERIVED_KEYS)},
            )
            verdict = item.get("verdict")
            status = item.get("inference_status")
            # Increment verdict + status counters. "skipped" appears in both
            # _VERDICT_KEYS and _STATUS_KEYS as a single dict key; a skipped row
            # has verdict==status=="skipped" so we'd otherwise double-count.
            # The set() de-dupes that case.
            for k in {verdict, status}:
                if k in counts:
                    counts[k] += 1
            # Derived render-only "unannotated" bucket: completed-but-pending.
            # Counted in addition to (not instead of) pending + completed so
            # admin can read both legacy and new shapes.
            if status == "completed" and verdict == "pending":
                counts["unannotated"] += 1

            total_inferences += 1
            if verdict == "approved":
                approved_count += 1
            elif verdict == "rejected":
                rejected_count += 1
            user_id = item.get("user_id")
            if user_id:
                distinct_users.add(user_id)
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    out = [
        {"model_version": mv, "tier": t, "counts": counts}
        for (mv, t), counts in sorted(buckets.items())
    ]

    decided = approved_count + rejected_count
    aggregates = {
        "acceptance_rate": (approved_count / decided) if decided > 0 else None,
        "total_inferences": total_inferences,
        "active_users": len(distinct_users),
    }

    # Per-tier endpoint health. Each describe is wrapped defensively so a
    # single-tier failure can't break the whole metrics response.
    endpoint_map = {"small": SMALL_ENDPOINT_NAME, "large": LARGE_ENDPOINT_NAME}
    now_utc = datetime.now(timezone.utc)
    endpoints: list[dict] = []
    for tier_name, endpoint_name in endpoint_map.items():
        try:
            (
                _,
                status,
                last_modified_iso,
                current_instances,
                desired_instances,
            ) = _describe_endpoint(tier_name)
        except (BotoCoreError, ClientError, KeyError, RuntimeError) as exc:
            print(f"admin_metrics describe_endpoint({tier_name}) failed: {exc}")
            status = None
            last_modified_iso = None
            current_instances = None
            desired_instances = None

        age_seconds: float | None = None
        if last_modified_iso:
            try:
                lm = datetime.fromisoformat(last_modified_iso)
                if lm.tzinfo is None:
                    lm = lm.replace(tzinfo=timezone.utc)
                age_seconds = (now_utc - lm).total_seconds()
            except (ValueError, TypeError):
                age_seconds = None

        # In-flight count: sum running rows across every model_version on this
        # tier. Lets the admin UI flip the pill to "warming" the moment a job
        # is submitted, instead of waiting 1-3 min for the SageMaker
        # auto-scaler's CurrentInstanceCount/DesiredInstanceCount to react.
        # Reuses the scan results above — no extra DDB query.
        in_flight = sum(
            c["running"] for (_mv, t), c in buckets.items() if t == tier_name
        )

        endpoints.append(
            {
                "tier": tier_name,
                "endpoint_name": endpoint_name,
                "status": status or "Unknown",
                "last_modified": last_modified_iso,
                "age_seconds": age_seconds,
                "current_instances": current_instances,
                "desired_instances": desired_instances,
                "in_flight": in_flight,
            }
        )

    return {
        "buckets": out,
        "aggregates": aggregates,
        "endpoints": endpoints,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "env": ENV_NAME,
    }


@app.post("/v1/admin/cleanup-abandoned")
async def admin_cleanup_abandoned(x_api_key: str = Header(...)):
    """Sweep stale `inference_status="running"` rows older than the timebox
    and conditionally flip them to `"abandoned"`. Triggered by the admin UI's
    Cleanup button. Pagination + ProjectionExpression mirror admin_metrics."""
    _authenticate_admin(x_api_key)
    table = _telemetry_table()
    now_utc = datetime.now(timezone.utc)
    scanned = 0
    flipped = 0
    skipped_recent = 0  # rows still inside the timebox — left alone

    scan_kwargs: dict = {
        "ProjectionExpression": "inference_id, inference_status, created_at",
    }
    while True:
        resp = table.scan(**scan_kwargs)
        for item in resp.get("Items", []):
            scanned += 1
            if item.get("inference_status") != "running":
                continue
            if _is_within_skip_timebox(item.get("created_at"), now_utc):
                skipped_recent += 1
                continue
            try:
                table.update_item(
                    Key={"inference_id": item["inference_id"]},
                    UpdateExpression="SET inference_status = :a",
                    ConditionExpression="inference_status = :r",
                    ExpressionAttributeValues={":a": "abandoned", ":r": "running"},
                )
                flipped += 1
            except ClientError as e:
                if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    print(f"cleanup_abandoned update error for {item['inference_id']}: {e}")
                # ConditionalCheckFailed = a poll won the race; that's fine.
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    return {
        "scanned": scanned,
        "flipped": flipped,
        "skipped_recent": skipped_recent,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "env": ENV_NAME,
    }


app.mount("/", StaticFiles(directory="app/static", html=True), name="static")
