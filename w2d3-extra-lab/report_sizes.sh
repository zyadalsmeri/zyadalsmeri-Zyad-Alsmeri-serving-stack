#!/usr/bin/env bash
set -euo pipefail

TARGET_MB=300

echo "building naive single-stage image..."
docker build \
  -f Dockerfile.naive \
  -t registry:naive . > /dev/null

echo "building multi-stage image..."
docker build \
  -t registry:multistage . > /dev/null

naive_size=$(
  docker images registry:naive \
    --format "{{.Size}}"
)

multi_size=$(
  docker images registry:multistage \
    --format "{{.Size}}"
)

python - "$naive_size" "$multi_size" "$TARGET_MB" << 'PYEOF'
import json
import sys


def parse_size_to_mb(size_str):
    size_str = size_str.strip()

    if size_str.endswith("GB"):
        return float(size_str[:-2]) * 1024

    if size_str.endswith("MB"):
        return float(size_str[:-2])

    if size_str.endswith("kB"):
        return float(size_str[:-2]) / 1024

    if size_str.endswith("B"):
        return float(size_str[:-1]) / (1024 * 1024)

    raise ValueError(
        f"unrecognized size format: {size_str}"
    )


naive_str = sys.argv[1]
multi_str = sys.argv[2]
target_mb = float(sys.argv[3])

naive_mb = parse_size_to_mb(naive_str)
multi_mb = parse_size_to_mb(multi_str)

savings_mb = naive_mb - multi_mb

savings_pct = (
    (savings_mb / naive_mb) * 100
    if naive_mb > 0
    else 0
)

fits = multi_mb <= target_mb

print(f"naive single-stage: {naive_str}")
print(f"multi-stage:        {multi_str}")
print(
    f"savings:            "
    f"{savings_mb:.1f} MB "
    f"({savings_pct:.1f}%)"
)
print(f"target:             {target_mb:.0f} MB")
print("multi-stage fits target:", fits)

with open("size_report.json", "w") as f:
    json.dump(
        {
            "naive_mb": round(naive_mb, 1),
            "multistage_mb": round(multi_mb, 1),
            "savings_mb": round(savings_mb, 1),
            "savings_pct": round(savings_pct, 1),
            "target_mb": target_mb,
            "fits_target": fits
        },
        f,
        indent=2
    )

sys.exit(0 if fits else 1)
PYEOF