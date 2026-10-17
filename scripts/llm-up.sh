#!/usr/bin/env bash
# Запускает llama.cpp server (официальный образ, закреплённый тег) с локальной моделью на 127.0.0.1:${LLM_PORT:-8090}.
# Опционально: make up / make k8s-up от него не зависят. Лимит памяти контейнера ${LLM_MEM:-2g}.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${LLM_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-b11681}"
name="${LLM_NAME:-$(grep -v '^#' llm/models.tsv | head -1 | cut -f1)}"
url=$(grep -v '^#' llm/models.tsv | awk -F'\t' -v n="$name" '$1==n{print $2}')
f="llm/models/$(basename "$url")"
[ -f "$f" ] || { echo "llm-up: нет $f — сначала make llm-fetch LLM_NAME=$name" >&2; exit 1; }
docker rm -f mts-llm >/dev/null 2>&1 || true
docker run -d --name mts-llm --memory "${LLM_MEM:-2g}" -p "127.0.0.1:${LLM_PORT:-8090}:8080" \
  -v "$PWD/llm/models:/models:ro" "$IMAGE" \
  -m "/models/$(basename "$f")" -a "$name" -c "${LLM_CTX:-2048}" -np 1 --cache-ram 0 -t "${LLM_THREADS:-4}" --host 0.0.0.0 --port 8080 >/dev/null
for _ in $(seq 120); do
  if curl -sf "http://127.0.0.1:${LLM_PORT:-8090}/health" >/dev/null; then
    echo "llm-up: $name готова: http://127.0.0.1:${LLM_PORT:-8090}/v1 (OpenAI-совместимый API)"; exit 0
  fi
  docker ps -q -f name=mts-llm | grep -q . || { docker logs mts-llm | tail -5; exit 1; }
  sleep 1
done
echo "llm-up: сервер не поднялся за 120 с" >&2; docker logs mts-llm | tail -5; exit 1
