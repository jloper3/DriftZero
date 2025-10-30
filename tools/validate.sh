#!/usr/bin/env bash
set -euo pipefail
echo "🔍 Validating OpenAPI and JSON Schemas..."
yamllint api/dz-control-plane.yaml
for f in schemas/*.json; do
  jq empty "$f"
done
echo "✅ All good."
