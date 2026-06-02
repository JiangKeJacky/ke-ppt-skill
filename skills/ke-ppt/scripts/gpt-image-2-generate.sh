#!/bin/bash

set -euo pipefail

API_BASE="${VE_API_BASE:-https://api.vectorengine.ai}"
API_KEY="${VE_GPT_IMAGE_API_KEY:-}"
MODEL="${VE_IMAGE_MODEL:-gpt-image-2}"
SIZE="${VE_IMAGE_SIZE:-1920x1080}"
N="${VE_IMAGE_N:-1}"
QUALITY="${VE_IMAGE_QUALITY:-low}"
FORMAT="${VE_IMAGE_FORMAT:-png}"
OUTPUT_DIR="${VE_IMAGE_OUTPUT_DIR:-.}"
IMAGES=()
MASK=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <prompt>

Modes:
  Text-to-Image (default):  Generate image from text prompt only
  Image-to-Image:           Use -i/--image to provide source image(s) for editing

Options:
  -m, --model MODEL      Model name (default: gpt-image-2)
  -s, --size SIZE        Image size (default: 1920x1080)
                          1024x1024 | 1536x1024 | 1920x1080 | 1024x1532
                          2048x2048 | 2048x1152 | 3840x2160 | 2160x3840 | auto
  -n, --num N            Number of images, 1-10 (default: 1)
  -q, --quality QUALITY  Image quality: low|medium|high|auto (default: low)
  -f, --format FORMAT    Image format: png|jpeg|webp (default: png)
  -i, --image FILE       Source image(s) for edit mode (can be used multiple times)
      --mask FILE        Mask image for edit (transparent areas indicate where to edit)
  -o, --output DIR       Output directory (default: .)
  -k, --key KEY          API key (or set VE_GPT_IMAGE_API_KEY env var)
  -h, --help             Show this help message

Environment Variables:
  VE_API_BASE              API base URL (default: https://api.vectorengine.ai)
  VE_GPT_IMAGE_API_KEY     API key (required)
  VE_IMAGE_MODEL           Default model (default: gpt-image-2)
  VE_IMAGE_SIZE            Default size (default: 1920x1080)
  VE_IMAGE_N               Default number of images (default: 1)
  VE_IMAGE_QUALITY         Default quality (default: low)
  VE_IMAGE_FORMAT          Default format (default: png)
  VE_IMAGE_OUTPUT_DIR      Default output directory (default: .)

Examples:
  # Text-to-Image
  $(basename "$0") "A cute baby sea otter"
  $(basename "$0") -s 1024x1536 -q high "A sunset over mountains"

  # Image-to-Image (single image)
  $(basename "$0") -i photo.png "Add a rainbow in the sky"

  # Image-to-Image (multiple images)
  $(basename "$0") -i scene1.png -i scene2.png "Merge them into one image"

  # Image-to-Image with mask
  $(basename "$0") -i photo.png --mask mask.png "Replace the background with ocean"
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)     MODEL="$2"; shift 2 ;;
        -s|--size)      SIZE="$2"; shift 2 ;;
        -n|--num)       N="$2"; shift 2 ;;
        -q|--quality)   QUALITY="$2"; shift 2 ;;
        -f|--format)    FORMAT="$2"; shift 2 ;;
        -i|--image)     IMAGES+=("$2"); shift 2 ;;
        --mask)         MASK="$2"; shift 2 ;;
        -o|--output)    OUTPUT_DIR="$2"; shift 2 ;;
        -k|--key)       API_KEY="$2"; shift 2 ;;
        -h|--help)      usage ;;
        --)             shift; break ;;
        -*)             echo "Unknown option: $1" >&2; exit 1 ;;
        *)              break ;;
    esac
done

PROMPT="$*"

if [[ -z "$PROMPT" ]]; then
    echo "Error: prompt is required" >&2
    usage
fi

if [[ -z "$API_KEY" ]]; then
    echo "Error: API key is required (set VE_GPT_IMAGE_API_KEY or use -k)" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

if [[ ${#IMAGES[@]} -gt 0 ]]; then
    echo "Mode: Image-to-Image (edits)"
    echo "Input image(s): ${IMAGES[*]}"

    CURL_ARGS=(
        -sS
        "${API_BASE}/v1/images/edits"
        -H "Authorization: Bearer ${API_KEY}"
        -H "Accept: application/json"
    )

    for IMG in "${IMAGES[@]}"; do
        if [[ ! -f "$IMG" ]]; then
            echo "Error: image file not found: $IMG" >&2
            exit 1
        fi
        CURL_ARGS+=(-F "image=@${IMG}")
    done

    CURL_ARGS+=(
        -F "prompt=${PROMPT}"
        -F "model=${MODEL}"
        -F "n=${N}"
        -F "size=${SIZE}"
        -F "quality=${QUALITY}"
    )

    if [[ -n "$MASK" ]]; then
        if [[ ! -f "$MASK" ]]; then
            echo "Error: mask file not found: $MASK" >&2
            exit 1
        fi
        CURL_ARGS+=(-F "mask=@${MASK}")
    fi

    RESPONSE=$(curl "${CURL_ARGS[@]}")
else
    echo "Mode: Text-to-Image (generations)"

    PROMPT_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROMPT")

    RESPONSE=$(curl -sS \
        "${API_BASE}/v1/images/generations" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"model\":\"${MODEL}\",\"prompt\":${PROMPT_JSON},\"n\":${N},\"size\":\"${SIZE}\",\"quality\":\"${QUALITY}\",\"format\":\"${FORMAT}\"}")
fi

python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()),indent=2,ensure_ascii=False))' <<< "$RESPONSE" 2>/dev/null || echo "$RESPONSE"

HAS_B64=$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()).get("data",{}); print("yes" if (isinstance(d,dict) and "b64_json" in d) or (isinstance(d,list) and any(isinstance(i,dict) and "b64_json" in i for i in d)) else "no")' <<< "$RESPONSE" 2>/dev/null || echo "no")

if [[ "$HAS_B64" == "yes" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    python3 -c '
import base64, json, sys

data = json.loads(sys.stdin.read()).get("data", {})
items = data if isinstance(data, list) else [data]
output_dir, timestamp, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
count = 0
for index, item in enumerate(items):
    if not isinstance(item, dict) or not item.get("b64_json"):
        continue
    filename = f"{output_dir}/gpt_image_{timestamp}_{index}.{fmt}"
    print(f"Decoding base64 image -> {filename}")
    with open(filename, "wb") as f:
        f.write(base64.b64decode(item["b64_json"]))
    count += 1
print(f"Done. {count} image(s) saved to {output_dir}/")
' "$OUTPUT_DIR" "$TIMESTAMP" "$FORMAT" <<< "$RESPONSE"
else
    URLS=$(python3 -c 'import json,sys; [print(d.get("url","")) for d in json.loads(sys.stdin.read()).get("data",[])]' <<< "$RESPONSE" 2>/dev/null)

    if [[ -n "$URLS" ]]; then
        INDEX=0
        while IFS= read -r URL; do
            if [[ -n "$URL" ]]; then
                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                FILENAME="${OUTPUT_DIR}/gpt_image_${TIMESTAMP}_${INDEX}.${FORMAT}"
                echo "Downloading image ${INDEX} -> ${FILENAME}"
                curl -sS -o "$FILENAME" "$URL"
                INDEX=$((INDEX + 1))
            fi
        done <<< "$URLS"
        echo "Done. ${INDEX} image(s) saved to ${OUTPUT_DIR}/"
    else
        echo "No image data found in response." >&2
        exit 1
    fi
fi
