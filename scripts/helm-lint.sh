#!/usr/bin/env bash
# Lint only the Helm charts affected by the files passed as arguments (pre-commit hook).
# For each changed file, walks up the directory tree to find the nearest Chart.yaml.
set -euo pipefail

# Ensure Homebrew binaries (macOS) are on the PATH when running in hook context
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHARTS=""

for FILE in "$@"; do
  DIR=$(dirname "$FILE")
  DIR=${DIR#./}
  while true; do
    if [ -f "${DIR}/Chart.yaml" ]; then
      CHARTS="${CHARTS}${DIR}"$'\n'
      break
    fi
    [ "$DIR" = "." ] && break
    DIR=$(dirname "$DIR")
  done
done

# Deduplicate while preserving order (bash 3 compatible)
UNIQUE_CHARTS=$(printf '%s' "$CHARTS" | sort -u | grep -v '^$' || true)

if [ -z "$UNIQUE_CHARTS" ]; then
  exit 0
fi

ERRORS=0
while IFS= read -r CHART; do
  echo ""
  echo "── helm lint: $CHART"
  if grep -q "^dependencies:" "${CHART}/Chart.yaml" 2>/dev/null; then
    helm dependency update "$CHART" > /dev/null 2>&1 || true
  fi
  helm lint "$CHART" || ERRORS=$((ERRORS + 1))
done <<< "$UNIQUE_CHARTS"

exit $ERRORS
