#!/usr/bin/env bash
set -euo pipefail

NAIVE="registry:naive"
MULTI="registry:multistage"
TARGET_MB=300
MIN_SAVINGS=20
NAME="registry-green-check"
PORT=8000

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

fail() {
  echo "GREEN CHECK: FAIL ($1)"
  cleanup
  exit 1
}

cleanup

echo "checking images..."

docker image inspect "$NAIVE" >/dev/null 2>&1 \
  || fail "registry:naive missing"

docker image inspect "$MULTI" >/dev/null 2>&1 \
  || fail "registry:multistage missing"

naive_size=$(docker images "$NAIVE" --format "{{.Size}}")
multi_size=$(docker images "$MULTI" --format "{{.Size}}")

result=$(python - "$naive_size" "$multi_size" <<'PYEOF'
import sys

def mb(value):
    value = value.strip()

    if value.endswith("GB"):
        return float(value[:-2]) * 1024

    if value.endswith("MB"):
        return float(value[:-2])

    if value.endswith("kB"):
        return float(value[:-2]) / 1024

    if value.endswith("B"):
        return float(value[:-1]) / (1024 * 1024)

    raise ValueError(value)

naive = mb(sys.argv[1])
multi = mb(sys.argv[2])

savings = ((naive - multi) / naive) * 100

print(f"{naive}|{multi}|{savings}")
PYEOF
)

IFS='|' read naive_mb multi_mb savings <<< "$result"

echo "naive:       ${naive_mb} MB"
echo "multistage:  ${multi_mb} MB"
echo "savings:     ${savings}%"
echo "target:      <= ${TARGET_MB} MB"
echo "minimum:     >= ${MIN_SAVINGS}% savings"

set +e

python - "$multi_mb" "$savings" "$TARGET_MB" "$MIN_SAVINGS" <<'PYEOF'
import sys

multi = float(sys.argv[1])
savings = float(sys.argv[2])
target = float(sys.argv[3])
minimum = float(sys.argv[4])

if multi > target:
    sys.exit(1)

if savings < minimum:
    sys.exit(2)

sys.exit(0)
PYEOF

status=$?

set -e

case $status in
  1)
    fail "multi-stage image is over ${TARGET_MB} MB"
    ;;
  2)
    fail "savings are below ${MIN_SAVINGS}%"
    ;;
esac

echo "starting container..."

docker run -d \
  --name "$NAME" \
  -p "${PORT}:8000" \
  "$MULTI" >/dev/null \
  || fail "container failed to start"

echo "waiting for /health..."

code="000"

for i in {1..30}; do
  code=$(curl -s \
    -o /dev/null \
    -w "%{http_code}" \
    "http://localhost:${PORT}/health" \
    2>/dev/null || true)

  if [ "$code" = "200" ]; then
    break
  fi

  if [ -z "$(docker ps -q -f name="$NAME")" ]; then
    echo "--- container logs ---"
    docker logs "$NAME" 2>&1 || true
    fail "container exited before /health"
  fi

  sleep 2
done

[ "$code" = "200" ] \
  || fail "/health failed"

echo "checking /registry..."

registry_response=$(curl -fsS \
  "http://localhost:${PORT}/registry") \
  || fail "/registry failed"

echo "$registry_response" \
  | grep -q '"models"' \
  || fail "/registry has no models field"

echo "$registry_response" \
  | grep -q 'Qwen2.5-0.5B-Instruct' \
  || fail "expected model missing"

echo "checking model lookup..."

model_response=$(curl -fsS \
  "http://localhost:${PORT}/registry/Qwen2.5-0.5B-Instruct") \
  || fail "model lookup failed"

echo "$model_response" \
  | grep -q '"approved"' \
  || fail "model lookup returned unexpected data"

echo "checking unknown model returns 404..."

unknown_code=$(curl -s \
  -o /dev/null \
  -w "%{http_code}" \
  "http://localhost:${PORT}/registry/not-a-real-model")

[ "$unknown_code" = "404" ] \
  || fail "unknown model did not return 404"

echo "health: ok"
echo "registry: ok"
echo "model lookup: ok"
echo "404 check: ok"

cleanup

echo "GREEN CHECK: PASS"
exit 0