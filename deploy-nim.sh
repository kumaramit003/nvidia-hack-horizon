#!/usr/bin/env bash
set -euo pipefail

: "${NGC_API_KEY:?Set NGC_API_KEY first: export NGC_API_KEY=<your-key>}"

export LOCAL_NIM_CACHE="${LOCAL_NIM_CACHE:-$HOME/.cache/nim}"
mkdir -p "$LOCAL_NIM_CACHE"
chmod -R a+w "$LOCAL_NIM_CACHE"

echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin

docker rm -f nvidia-nim 2>/dev/null || true

docker run -d \
  --name nvidia-nim \
  --restart unless-stopped \
  --gpus all \
  --ipc host \
  --shm-size=32GB \
  -e NGC_API_KEY \
  -v "$LOCAL_NIM_CACHE:/opt/nim/.cache" \
  -p 8000:8000 \
  nvcr.io/nim/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:latest

echo "NIM running at http://localhost:8000/v1"
echo "Logs: docker logs -f nvidia-nim"
echo "Stop: docker stop nvidia-nim"
