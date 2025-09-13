#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DIR="$ROOT_DIR/images"

COUNT=2
PROMPT="nano banana, studio photo, simple background, 1:1"
MODEL_OWNER="stability-ai"
MODEL_NAME="sdxl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:-2}"; shift 2;;
    --prompt) PROMPT="${2:-$PROMPT}"; shift 2;;
    --model) MODEL_NAME="${2:-$MODEL_NAME}"; shift 2;;
    --owner) MODEL_OWNER="${2:-$MODEL_OWNER}"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--count N] [--prompt "text"] [--owner stability-ai] [--model sdxl]

Requires REPLICATE_API_TOKEN in environment.
Downloads output images to ./images/nano-banana-#.png
EOF
      exit 0;;
    *) echo -e "${YELLOW}Ignoring unknown option:${NC} $1"; shift;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl is required${NC}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}jq is required${NC}" >&2; exit 1; }

if [[ -z "${REPLICATE_API_TOKEN:-}" ]]; then
  echo -e "${RED}REPLICATE_API_TOKEN is not set${NC}" >&2
  exit 1
fi

mkdir -p "$IMG_DIR"

auth_header=("-H" "Authorization: Bearer $REPLICATE_API_TOKEN")

echo "Fetching latest model version for $MODEL_OWNER/$MODEL_NAME..."
MODEL_JSON=$(curl -fsS "https://api.replicate.com/v1/models/$MODEL_OWNER/$MODEL_NAME" "${auth_header[@]}") || {
  echo -e "${YELLOW}Model lookup failed for $MODEL_OWNER/$MODEL_NAME; trying black-forest-labs/flux-1.1-pro${NC}"
  MODEL_OWNER="black-forest-labs"; MODEL_NAME="flux-1.1-pro"
  MODEL_JSON=$(curl -fsS "https://api.replicate.com/v1/models/$MODEL_OWNER/$MODEL_NAME" "${auth_header[@]}")
}

VERSION_ID=$(echo "$MODEL_JSON" | jq -r '.latest_version.id')
if [[ -z "$VERSION_ID" || "$VERSION_ID" == "null" ]]; then
  echo -e "${RED}Could not determine latest version id${NC}" >&2
  exit 1
fi
echo -e "${GREEN}Using version:${NC} $VERSION_ID ($MODEL_OWNER/$MODEL_NAME)"

for i in $(seq 1 "$COUNT"); do
  echo "Creating prediction $i..."
  PRED=$(curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    "${auth_header[@]}" \
    -d "{\"version\": \"$VERSION_ID\", \"input\": {\"prompt\": \"$PROMPT\"}}" \
    https://api.replicate.com/v1/predictions)
  ID=$(echo "$PRED" | jq -r '.id')
  [[ "$ID" != "null" && -n "$ID" ]] || { echo -e "${RED}Failed to create prediction${NC}" >&2; echo "$PRED"; exit 1; }

  echo -n "Waiting for completion ($ID)"
  STATUS=""
  for _ in $(seq 1 120); do
    OUT=$(curl -fsS "https://api.replicate.com/v1/predictions/$ID" "${auth_header[@]}") || true
    STATUS=$(echo "$OUT" | jq -r '.status')
    if [[ "$STATUS" == "succeeded" ]]; then
      echo " done"
      break
    elif [[ "$STATUS" == "failed" || "$STATUS" == "canceled" ]]; then
      echo " error: $STATUS"; echo "$OUT"; exit 1
    fi
    echo -n "."; sleep 1
  done

  URL=$(echo "$OUT" | jq -r '.output[0]')
  if [[ -z "$URL" || "$URL" == "null" ]]; then
    echo -e "${RED}No output URL found${NC}" >&2; echo "$OUT"; exit 1
  fi

  OUTFILE="$IMG_DIR/nano-banana-$i.png"
  echo "Downloading to $OUTFILE"
  curl -fsS -o "$OUTFILE" "$URL" "${auth_header[@]}"
done

echo -e "${GREEN}Done.${NC} Images saved under $IMG_DIR"

