#!/bin/bash

set -euo pipefail

API_BASE="${VE_API_BASE:-https://api.vectorengine.ai}"
API_KEY="${VE_GPT_IMAGE_API_KEY:-}"
MODEL="${VE_IMAGE_MODEL:-gpt-image-2}"
SVG_MODEL="${VE_SVG_MODEL:-gpt-4o}"
SVG_BASE_URL="${VE_SVG_BASE_URL:-}"
SIZE="${VE_IMAGE_SIZE:-1920x1080}"
N="${VE_IMAGE_N:-1}"
QUALITY="${VE_IMAGE_QUALITY:-low}"
FORMAT="${VE_IMAGE_FORMAT:-png}"
OUTPUT_DIR="${VE_IMAGE_OUTPUT_DIR:-.}"
IMAGES=()
MASK=""
SVG_MODE=0
SVG_ONLY=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <prompt>

Modes:
  Text-to-Image (default):  Generate image from text prompt only
  Image-to-Image:           Use -i/--image to provide source image(s) for editing
  SVG Mode (--svg):         Call chat/completions to generate SVG code with <text>
                            elements, then render to PNG via rsvg-convert

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
      --svg              SVG mode: generate SVG code via chat/completions
      --svg-model MODEL  Model for SVG generation (default: same as --model)
      --svg-only         In SVG mode, only save .svg file (skip PNG rendering)
  -h, --help             Show this help message

Environment Variables:
  VE_API_BASE              API base URL (default: https://api.vectorengine.ai)
  VE_GPT_IMAGE_API_KEY     API key (required)
  VE_IMAGE_MODEL           Default model (default: gpt-image-2)
  VE_SVG_MODEL             Model for SVG generation (default: same as VE_IMAGE_MODEL)
  VE_IMAGE_SIZE            Default size (default: 1920x1080)
  VE_IMAGE_N               Default number of images (default: 1)
  VE_IMAGE_QUALITY         Default quality (default: low)
  VE_IMAGE_FORMAT          Default format (default: png)
  VE_IMAGE_OUTPUT_DIR      Default output directory (default: .)

Examples:
  # Text-to-Image
  $(basename "$0") "A cute baby sea otter"
  $(basename "$0") -s 1024x1536 -q high "A sunset over mountains"

  # SVG Mode - generate SVG with editable <text> elements
  $(basename "$0") --svg "A presentation slide about AI agents"
  $(basename "$0") --svg --svg-model doubao-seed-2-0-pro-260215 "Slide: OpenClaw Introduction"

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
        --svg)          SVG_MODE=1; shift ;;
        --svg-model)    SVG_MODEL="$2"; shift 2 ;;
        --svg-base-url) SVG_BASE_URL="$2"; shift 2 ;;
        --svg-only)     SVG_ONLY=1; shift ;;
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

if [[ "$SVG_MODE" -eq 1 ]]; then
    echo "Mode: SVG Generation (chat/completions)"

    SVG_API_BASE="${SVG_BASE_URL:-${API_BASE}}"

    PIXEL_W="${SIZE%x*}"
    PIXEL_H="${SIZE#*x}"

    SVG_W=1792
    SVG_H=1024

    SYSTEM_PROMPT='You are a professional SVG slide designer for PowerPoint compatibility. Generate a standard SVG that survives PowerPoint "Convert to Shape" without any distortion. Absolute rules:

1. Canvas: width="1792" height="1024" viewBox="0 0 1792 1024" — fixed dimensions, viewBox MUST match canvas exactly
2. NO transform: never use transform, matrix, scale, rotate, translate, skew on ANY element. All positions via absolute x/y coordinates only
3. NO nested groups: flat structure only. Use at most ONE level of <g> for background and ONE for text. No <g> inside <g>. After PowerPoint ungroup, every element must retain its original position and proportion
4. All shapes at fixed original scale: every rect, circle, ellipse, line, polygon uses absolute x/y/width/height/rx/ry/cx/cy values. Lock aspect ratio — no proportional scaling tricks
5. NO masks, NO clip-path, NO complex filters (blur, shadow, glow), NO gradient with stop-opacity. Simple linearGradient with solid stop-color (#RRGGBB) is allowed. NO feGaussianBlur, feDropShadow, feColorMatrix
6. Uniform values: border-radius (rx/ry) fixed to 8 or 16, stroke-width fixed to 1 or 2. Paths must be clean with minimal anchor points — no redundant bezier handles
7. Text: pure basic <text x="..." y="..."> only. NO <tspan>, NO dx/dy offsets, NO text-anchor="middle" or "end", NO transform on text, NO letter-spacing/word-spacing. font-size="24px" for all text. font-family="Microsoft YaHei, SimHei". fill="#RRGGBB" only — NO rgba, NO opacity on text
8. Minimal structure: the SVG must be so simple that after importing into PowerPoint and pressing "Convert to Shape" then "Ungroup", every shape, proportion, and position remains exactly the same — zero distortion
9. Layout: title y≈90, subtitle y≈140, body starts y≈220, line spacing 60px. Margins 80px on all sides. Canvas is 1792×1024
10. Return ONLY the SVG code, no explanations, no markdown fences'

    PROMPT_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$PROMPT")
    SYSTEM_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$SYSTEM_PROMPT")

    RESPONSE=$(curl -sS \
        "${SVG_API_BASE}/chat/completions" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{
  \"model\": \"${SVG_MODEL}\",
  \"temperature\": 0.3,
  \"max_tokens\": 8192,
  \"messages\": [
    {\"role\": \"system\", \"content\": ${SYSTEM_JSON}},
    {\"role\": \"user\", \"content\": ${PROMPT_JSON}}
  ]
}")

    python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()),indent=2,ensure_ascii=False))' <<< "$RESPONSE" 2>/dev/null || echo "$RESPONSE"

    CONTENT=$(python3 -c '
import json, sys, re
resp = json.loads(sys.stdin.read())
try:
    content = resp["choices"][0]["message"]["content"]
except (KeyError, IndexError, TypeError):
    print("", end="")
    sys.exit(1)
svg_match = re.search(r"<svg[\s\S]*</svg>", content)
if svg_match:
    print(svg_match.group(0), end="")
else:
    print(content, end="")
' <<< "$RESPONSE" 2>/dev/null)

    if [[ -z "$CONTENT" ]]; then
        echo "Error: no SVG content in response" >&2
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    SVG_FILE="${OUTPUT_DIR}/gpt_image_${TIMESTAMP}_0.svg"
    echo "$CONTENT" > "$SVG_FILE"
    echo "Saved SVG: ${SVG_FILE} ($(wc -c < "$SVG_FILE") bytes)"

    TEXT_COUNT=$(python3 -c '
import sys, re
svg = open(sys.argv[1]).read()
ns = "http://www.w3.org/2000/svg"
count = svg.count("<text ")
print(count)
' "$SVG_FILE" 2>/dev/null || echo "0")
    echo "SVG <text> elements: ${TEXT_COUNT}"

    if [[ "$SVG_ONLY" -eq 0 ]]; then
        if command -v rsvg-convert &>/dev/null; then
            PNG_FILE="${OUTPUT_DIR}/gpt_image_${TIMESTAMP}_0.${FORMAT}"
            if rsvg-convert -w "$PIXEL_W" -h "$PIXEL_H" -o "$PNG_FILE" "$SVG_FILE" 2>/dev/null; then
                echo "Rendered PNG: ${PNG_FILE} ($(wc -c < "$PNG_FILE") bytes)"
            else
                echo "Warning: rsvg-convert failed, PNG not rendered" >&2
            fi
        else
            echo "Warning: rsvg-convert not found, PNG not rendered. Install: brew install librsvg" >&2
        fi
    fi

    echo "Done. SVG mode complete."
    exit 0
fi

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
