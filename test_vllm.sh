#!/bin/bash

PORT="${PORT:-8000}"
API_URL="http://localhost:${PORT}/v1/chat/completions"
MODEL="Qwen/Qwen3-VL-2B-Instruct"

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -t, --test <name|all>   Which test(s) to run. Can be a single name,
                          a comma-separated list, or 'all' (default).
  -h, --help              Show this help message and exit.

Available tests:
  image-uuid        Standard Image with Caching UUID
  image-no-uuid     Image URL with auto-generated UUID (for later reuse)
  image-cached      Cached Image Request (Skipping Payload)
  multi-image       Multi-Image Input (Requires --limit-mm-per-prompt)
  local-file        Local File Path (Requires --allowed-local-media-path)
  image-embeds      Direct Image Embeddings Input (Requires --enable-mm-embeds)
  video             Video Input
  placeholder       Placeholder Token Test (Shows <image> token replacement)
  two-images        Two Images Test (Shows multiple mm_hash handling)

Examples:
  $0                              # run all tests
  $0 -t image-uuid                # run only the image-uuid test
  $0 -t image-uuid,image-cached   # run two specific tests
  $0 -t all                       # run all tests
EOF
}

# ---------------------------------------------------------------------------
# Helper: print and run a curl command
# ---------------------------------------------------------------------------
CURL_TIMEOUT="${CURL_TIMEOUT:-60}"   # seconds, override with: export CURL_TIMEOUT=120

run_curl() {
  local data="$1"
  echo ">> curl command:"
  echo "   curl -s --max-time $CURL_TIMEOUT -w '\\nHTTP_STATUS:%{http_code}' $API_URL \\"
  echo "     -H 'Content-Type: application/json' \\"
  echo "     -d '$data'"
  echo ""

  local response
  response=$(curl -s --max-time "$CURL_TIMEOUT" \
    -w "\nHTTP_STATUS:%{http_code}" \
    "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$data")
  local curl_exit=$?

  if [[ $curl_exit -ne 0 ]]; then
    echo ">> curl failed (exit $curl_exit). Common causes:"
    echo "   28 = timeout after ${CURL_TIMEOUT}s (server busy/overloaded)"
    echo "   7  = connection refused (server not running)"
    echo "   52 = empty reply (server closed connection)"
    return 1
  fi

  local http_status body
  http_status=$(echo "$response" | grep "HTTP_STATUS:" | tail -1 | cut -d: -f2)
  body=$(echo "$response" | grep -v "HTTP_STATUS:")

  echo ">> HTTP status: $http_status"
  if [[ -z "$body" ]]; then
    echo ">> (empty response body)"
  else
    echo "$body" | jq . 2>/dev/null || echo "$body"
  fi
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
TESTS_TO_RUN="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--test)
      TESTS_TO_RUN="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

ALL_TESTS=(image-uuid image-no-uuid image-cached multi-image local-file image-embeds video placeholder two-images)

# Build a set of test names to run
declare -A RUN_TEST
if [[ "$TESTS_TO_RUN" == "all" ]]; then
  for name in "${ALL_TESTS[@]}"; do RUN_TEST[$name]=1; done
else
  IFS=',' read -ra NAMES <<< "$TESTS_TO_RUN"
  for name in "${NAMES[@]}"; do
    name="${name// /}"   # trim spaces
    # Validate name
    valid=0
    for t in "${ALL_TESTS[@]}"; do [[ "$t" == "$name" ]] && valid=1 && break; done
    if [[ $valid -eq 0 ]]; then
      echo "Unknown test name: '$name'"
      echo "Valid names: ${ALL_TESTS[*]}"
      exit 1
    fi
    RUN_TEST[$name]=1
  done
fi

# ---------------------------------------------------------------------------
# Test functions  (use underscores in function names to avoid bash hyphen issue)
# ---------------------------------------------------------------------------

test_image_uuid() {
  echo "========================================================="
  echo "image-uuid: Standard Image with Caching UUID"
  echo "========================================================="
  # Providing a 'uuid' allows vLLM to cache the processed image features
  # for future requests using the same UUID.
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What is in this image?"},
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg"},
            "uuid": "dog-image-v1"
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_image_no_uuid() {
  echo -e "\n\n========================================================="
  echo "image-no-uuid: Image URL with explicit UUID for later reuse"
  echo "========================================================="
  # Providing a 'uuid' lets you reference this image in future requests
  # without resending the image data (use image-cached test to reuse it).
  # The uuid is your chosen cache key — any unique string works.
  local IMAGE_UUID="poodle-$(date +%s)"
  echo ">> Using uuid: $IMAGE_UUID  (save this to reuse with image-cached)"
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What is in this image?"},
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg"},
            "uuid": "'"$IMAGE_UUID"'"
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_image_cached() {
  echo -e "\n\n========================================================="
  echo "image-cached: Cached Image Request (Skipping Payload)"
  echo "========================================================="
  # If you know the UUID was cached by a previous request, you can pass 'null'
  # to the url/data to save network bandwidth.
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What breed is the dog?"},
          {
            "type": "image_url",
            "image_url": null,
            "uuid": "dog-image-v1"
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_multi_image() {
  echo -e "\n\n========================================================="
  echo "multi-image: Multi-Image Input (Requires --limit-mm-per-prompt)"
  echo "========================================================="
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What are the animals in these two images?"},
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg"}
          },
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/labrador/n02099712_4323.jpg"}
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_local_file() {
  echo -e "\n\n========================================================="
  echo "local-file: Local File Path (Requires --allowed-local-media-path /data/images)"
  echo "========================================================="
  # The server must be started with: --allowed-local-media-path /data/images
  # The file must exist inside the pod at /data/images/test_image.jpg
  local LOCAL_IMAGE_PATH="${LOCAL_IMAGE_PATH:-/data/images/test_image.jpg}"
  echo ">> Using local path: $LOCAL_IMAGE_PATH  (override with: export LOCAL_IMAGE_PATH=/data/images/myfile.jpg)"
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What is in this local file?"},
          {
            "type": "image_url",
            "image_url": {"url": "file://'"$LOCAL_IMAGE_PATH"'", "uuid": "local-image-v1"}
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_image_embeds() {
  echo -e "\n\n========================================================="
  echo "image-embeds: Direct Image Embeddings Input (Requires --enable-mm-embeds)"
  echo "========================================================="
  # WARNING: Passing raw embeddings can crash the server if shaped incorrectly.
  # Only enable for trusted users. The base64 string must represent a serialized torch tensor.
  local DUMMY_TENSOR_B64="AAAA...<your_base64_encoded_torch_tensor>..."
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "Describe this embedded image:"},
          {
            "type": "image_embeds",
            "image_embeds": "'"$DUMMY_TENSOR_B64"'",
            "uuid": "embedded-image-1"
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_video() {
  echo -e "\n\n========================================================="
  echo "video: Video Input"
  echo "========================================================="
  # Ensure a video-capable model (like Qwen2-VL or LLaVA-OneVision) is loaded.
  local data='{
    "model": "llava-hf/llava-onevision-qwen2-0.5b-ov-hf",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What is happening in this video?"},
          {
            "type": "video_url",
            "video_url": {"url": "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4"}
          }
        ]
      }
    ]
  }'
  run_curl "$data"
}

test_placeholder() {
  echo -e "\n\n========================================================="
  echo "placeholder: Placeholder Token Test (Shows <image> token replacement)"
  echo "========================================================="
  echo ">> This test demonstrates how placeholder tokens work:"
  echo ">>   1. Text 'What is in <image>?' gets tokenized"
  echo ">>   2. <image> becomes a placeholder token (e.g., token ID 32000)"
  echo ">>   3. During prefill, the placeholder token is replaced with image embeddings"
  echo ">>   4. Check server logs for [PLACEHOLDER-TOKEN] to see the replacement"
  echo ""
  echo ">> Expected logs on server:"
  echo ">>   [PLACEHOLDER-TOKEN] Found placeholder token: modality=image ..."
  echo ">>   [MM-HASH] Created MMFeature: base_mm_hash=poodle-..."
  echo ">>   [ENCODER-CACHE] Using cached encoder output: mm_hash=poodle-..."
  echo ""
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "Describe what you see in this image in detail."},
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg"},
            "uuid": "placeholder-test-image"
          }
        ]
      }
    ],
    "max_tokens": 100
  }'
  run_curl "$data"
  echo ""
  echo ">> To see placeholder token processing in server logs, look for:"
  echo ">>   [PLACEHOLDER-TOKEN] - Shows where <image> token was found"
  echo ">>   [MM-HASH] - Shows the hash computed from image data"
  echo ">>   [KV-CACHE-PREFILL] - Shows KV cache block hash computation"
  echo ">>   [PREFILL] - Shows the actual model execution"
  echo ">>   [ENCODER-CACHE] - Shows image embeddings being used"
}

test_two_images() {
  echo -e "\n\n========================================================="
  echo "two-images: Two Images Test (Shows multiple mm_hash handling)"
  echo "========================================================="
  echo ">> This test demonstrates how multiple images are processed:"
  echo ">>   1. Each image gets its own mm_hash computed"
  echo ">>   2. Each image gets its own placeholder tokens"
  echo ">>   3. Both mm_hashes are included in KV cache block hashes"
  echo ">>   4. Check server logs for multiple [MM-HASH] and [PLACEHOLDER-TOKEN] entries"
  echo ""
  echo ">> Expected logs on server:"
  echo ">>   [MM-HASH] Created MMFeature: base_mm_hash=poodle-... (image 1)"
  echo ">>   [MM-HASH] Created MMFeature: base_mm_hash=labrador-... (image 2)"
  echo ">>   [PLACEHOLDER-TOKEN] Found placeholder token: item_idx=0 (image 1)"
  echo ">>   [PLACEHOLDER-TOKEN] Found placeholder token: item_idx=1 (image 2)"
  echo ">>   [KV-CACHE-PREFILL] extra_keys=('poodle-...', 'labrador-...')"
  echo ">>   [ENCODER-CACHE] Using cached encoder output for both images"
  echo ""
  local data='{
    "model": "'"$MODEL"'",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "Compare these two dog images. What breeds are they and what are the differences?"},
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/poodle-standard/n02113799_2280.jpg"},
            "uuid": "two-images-poodle"
          },
          {
            "type": "image_url",
            "image_url": {"url": "https://images.dog.ceo/breeds/labrador/n02099712_4323.jpg"},
            "uuid": "two-images-labrador"
          }
        ]
      }
    ],
    "max_tokens": 150
  }'
  run_curl "$data"
  echo ""
  echo ">> To see two-image processing in server logs, look for:"
  echo ">>   [MM-HASH] - Two separate hashes (one per image)"
  echo ">>   [PLACEHOLDER-TOKEN] - Two placeholder token ranges"
  echo ">>   [KV-CACHE-PREFILL] - Block hashes include both mm_hashes in extra_keys"
  echo ">>   [ENCODER-CACHE] - Two separate encoder cache lookups/loads"
  echo ">>   [PREFILL] - Single forward pass with both images' embeddings"
  echo ""
  echo ">> Key insight: Both mm_hashes are combined in block hash extra_keys,"
  echo ">>              ensuring different image combinations produce different KV cache blocks"
}

# ---------------------------------------------------------------------------
# Dispatch map: test name (with hyphens) -> function name (with underscores)
# ---------------------------------------------------------------------------
declare -A DISPATCH
DISPATCH["image-uuid"]=test_image_uuid
DISPATCH["image-no-uuid"]=test_image_no_uuid
DISPATCH["image-cached"]=test_image_cached
DISPATCH["multi-image"]=test_multi_image
DISPATCH["local-file"]=test_local_file
DISPATCH["image-embeds"]=test_image_embeds
DISPATCH["video"]=test_video
DISPATCH["placeholder"]=test_placeholder
DISPATCH["two-images"]=test_two_images

# ---------------------------------------------------------------------------
# Run selected tests in order
# ---------------------------------------------------------------------------
for name in "${ALL_TESTS[@]}"; do
  if [[ "${RUN_TEST[$name]}" == "1" ]]; then
    "${DISPATCH[$name]}"
  fi
done

# Made with Bob
