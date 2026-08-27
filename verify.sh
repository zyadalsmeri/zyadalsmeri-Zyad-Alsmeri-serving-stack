#!/usr/bin/env bash
# Green-check verifier for W2D5 — Docker Compose + Secure /v1
#
# Checks:
# 1. compose.yaml and .env exist
# 2. cpu-v2 image can be pulled fresh from Docker Hub
# 3. Docker Compose starts the service
# 4. Compose healthcheck reaches "healthy"
# 5. /health returns 200 without API key
# 6. /v1/models returns 401 without API key
# 7. /v1/models returns 200 with the correct Bearer API key
# 8. /v1/chat/completions returns a real authenticated completion
#
# Final line:
# GREEN CHECK: PASS
# or
# GREEN CHECK: FAIL (<reason>)

set -u

TIMEOUT="${TIMEOUT:-420}"
TMP_RESPONSE=""

cleanup() {
  docker compose down >/dev/null 2>&1 || true

  if [ -n "${TMP_RESPONSE:-}" ] && [ -f "$TMP_RESPONSE" ]; then
    rm -f "$TMP_RESPONSE"
  fi
}

fail() {
  echo "GREEN CHECK: FAIL ($1)"
  cleanup
  exit 1
}


# ---------------------------------------------------------
# 1. Required files
# ---------------------------------------------------------

[ -f ".env" ] || fail ".env is missing"
[ -f "compose.yaml" ] || fail "compose.yaml is missing"


# ---------------------------------------------------------
# 2. Load .env for verifier requests
# ---------------------------------------------------------

set -a
source .env
set +a

[ -n "${IMAGE:-}" ] || fail "IMAGE is missing from .env"
[ -n "${MODEL_ID:-}" ] || fail "MODEL_ID is missing from .env"
[ -n "${HOST_PORT:-}" ] || fail "HOST_PORT is missing from .env"
[ -n "${API_KEY:-}" ] || fail "API_KEY is missing or empty in .env"
[ -n "${MAX_TOKENS:-}" ] || fail "MAX_TOKENS is missing from .env"

TMP_RESPONSE="$(mktemp)"

trap cleanup EXIT INT TERM


# ---------------------------------------------------------
# 3. Start clean
# ---------------------------------------------------------

echo "stopping existing Compose stack ..."
docker compose down >/dev/null 2>&1 || true


# ---------------------------------------------------------
# 4. Fresh pull checkpoint
# ---------------------------------------------------------

echo "removing local image: $IMAGE ..."
docker image rm "$IMAGE" >/dev/null 2>&1 || true

echo "pulling $IMAGE ..."

if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  fail "docker pull failed"
fi


# ---------------------------------------------------------
# 5. Start with Docker Compose
# ---------------------------------------------------------

echo "starting service with Docker Compose ..."

if ! docker compose up -d >/dev/null 2>&1; then
  fail "docker compose up failed"
fi


# ---------------------------------------------------------
# 6. Wait for Compose healthcheck
# ---------------------------------------------------------

echo "waiting for Compose healthcheck (up to ${TIMEOUT}s) ..."

deadline=$(( $(date +%s) + TIMEOUT ))
healthy=0

while [ "$(date +%s)" -lt "$deadline" ]; do

  CID="$(docker compose ps -q serving 2>/dev/null || true)"

  if [ -z "$CID" ]; then
    fail "serving container was not created"
  fi

  RUNNING="$(docker inspect \
    --format '{{.State.Running}}' \
    "$CID" 2>/dev/null || true)"

  if [ "$RUNNING" != "true" ]; then
    echo "--- container logs ---"
    docker compose logs --tail 30 serving 2>&1 || true
    fail "serving container stopped"
  fi

  HEALTH="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$CID" 2>/dev/null || true)"

  if [ "$HEALTH" = "healthy" ]; then
    healthy=1
    break
  fi

  sleep 3
done

[ "$healthy" -eq 1 ] || fail "service did not become healthy within ${TIMEOUT}s"


# ---------------------------------------------------------
# 7. /health must be open
# ---------------------------------------------------------

echo "checking /health without API key ..."

CODE="$(curl -s \
  -o /dev/null \
  -w "%{http_code}" \
  "http://localhost:${HOST_PORT}/health")"

[ "$CODE" = "200" ] || fail "/health returned $CODE instead of 200"


# ---------------------------------------------------------
# 8. /v1/models must reject missing API key
# ---------------------------------------------------------

echo "checking /v1/models without API key ..."

CODE="$(curl -s \
  -o /dev/null \
  -w "%{http_code}" \
  "http://localhost:${HOST_PORT}/v1/models")"

[ "$CODE" = "401" ] || fail "/v1/models without key returned $CODE instead of 401"


# ---------------------------------------------------------
# 9. /v1/models must accept correct API key
# ---------------------------------------------------------

echo "checking /v1/models with API key ..."

CODE="$(curl -s \
  -o /dev/null \
  -w "%{http_code}" \
  -H "Authorization: Bearer ${API_KEY}" \
  "http://localhost:${HOST_PORT}/v1/models")"

[ "$CODE" = "200" ] || fail "/v1/models with key returned $CODE instead of 200"


# ---------------------------------------------------------
# 10. Real authenticated completion
# ---------------------------------------------------------

echo "checking authenticated chat completion ..."

CODE="$(curl -sS \
  -o "$TMP_RESPONSE" \
  -w "%{http_code}" \
  "http://localhost:${HOST_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_KEY}" \
  -d "{
    \"model\":\"${MODEL_ID}\",
    \"messages\":[
      {
        \"role\":\"user\",
        \"content\":\"Say hi.\"
      }
    ],
    \"max_tokens\":16
  }")"

[ "$CODE" = "200" ] || fail "/v1/chat/completions returned $CODE instead of 200"

grep -q '"chat.completion"' "$TMP_RESPONSE" \
  || fail "completion response has no chat.completion object"

grep -q '"content"' "$TMP_RESPONSE" \
  || fail "completion response has no content field"

grep -q '"usage"' "$TMP_RESPONSE" \
  || fail "completion response has no usage field"


# ---------------------------------------------------------
# Result
# ---------------------------------------------------------

echo
echo "image: $IMAGE"
echo "compose: healthy"
echo "health without key: 200"
echo "models without key: 401"
echo "models with key: 200"
echo "authenticated completion: ok"

trap - EXIT INT TERM
cleanup

echo "GREEN CHECK: PASS"
exit 0