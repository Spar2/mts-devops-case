#!/usr/bin/env bash
# Скачивает GGUF-веса локальной LLM с Hugging Face (без токена) и проверяет sha256.
# Использование: scripts/llm-fetch.sh [имя из llm/models.tsv]   (по умолчанию LLM_NAME или первая строка)
set -euo pipefail
cd "$(dirname "$0")/.."
name="${1:-${LLM_NAME:-}}"
line=$(grep -v '^#' llm/models.tsv | awk -F'\t' -v n="$name" 'n=="" || $1==n' | head -1)
[ -n "$line" ] || { echo "llm-fetch: модель '$name' не найдена в llm/models.tsv" >&2; exit 1; }
IFS=$'\t' read -r n url sha bytes <<<"$line"
mkdir -p llm/models
f="llm/models/$(basename "$url")"
if [ -f "$f" ] && echo "$sha  $f" | sha256sum -c --quiet - 2>/dev/null; then
  echo "llm-fetch: $f уже скачан, sha256 совпадает"; exit 0
fi
echo "llm-fetch: $n ($((bytes / 1024 / 1024)) МиБ) <- $url"
curl -fL --retry 3 -o "$f.part" "$url"
echo "$sha  $f.part" | sha256sum -c - || { rm -f "$f.part"; echo "llm-fetch: sha256 не совпал" >&2; exit 1; }
mv "$f.part" "$f"
echo "llm-fetch: OK $f"
