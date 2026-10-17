#!/usr/bin/env bash
# Best-effort объяснение отката canary локальной LLM. Вызывается из canary.sh после отката.
# Никогда не влияет на код выхода и на сам откат: всегда exit 0, общий таймаут LLM_EXPLAIN_TIMEOUT (по умолчанию 240 с).
# Использование: llm-explain-hook.sh REASON [LOG_FILE]
#   LLM_URL      адрес llama.cpp server (по умолчанию http://127.0.0.1:8090); недоступен -> пропуск
#   LLM_EXPLAIN  0 — отключить
# Результат: llm/out/canary-explain-<время>.md и вывод в консоль.
set -uo pipefail
reason=${1:-unknown}
log=${2:-}
url=${LLM_URL:-http://127.0.0.1:8090}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${LLM_EXPLAIN:-auto}" == 0 ]] && exit 0
if ! curl -sf -m 2 "${url}/health" >/dev/null 2>&1; then
  printf 'llm-explain: LLM недоступна (%s), объяснение пропущено\n' "$url"
  exit 0
fi
ctx="$(mktemp)"
trap 'rm -f -- "$ctx"' EXIT
{
  printf 'ROLLBACK canary: %s\n' "$reason"
  if [[ -n "$log" && -f "$log" ]]; then grep -E "FAIL|PASS|WARN|ROLLBACK|installing|weight|smoke|prometheus" -- "$log" | tail -n 20; fi
  printf -- '--- helm list -n sensor\n'
  timeout 10 helm list -n sensor 2>/dev/null
} >"$ctx"
mkdir -p "${ROOT}/llm/out"
out="${ROOT}/llm/out/canary-explain-$(date +%Y%m%dT%H%M%S).md"
printf 'llm-explain: модель объясняет откат (таймаут %s с, откат уже выполнен)...\n' "${LLM_EXPLAIN_TIMEOUT:-240}"
if timeout "${LLM_EXPLAIN_TIMEOUT:-240}" env LLM_URL="$url" python3 "${ROOT}/llm/llm_gen.py" explain "$ctx" >"$out" 2>"${out}.log"; then
  printf 'llm-explain (черновик от LLM, проверено: русский язык, числа есть в логе) -> %s\n' "$out"
else
  printf 'llm-explain: объяснение не прошло проверку или таймаут, см. %s.log (сохранено как есть)\n' "$out"
fi
sed 's/^/  | /' "$out"
exit 0
