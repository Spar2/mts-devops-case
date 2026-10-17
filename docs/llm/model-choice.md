# Выбор локальной LLM: замеры

Стенд замеров (box): 8 vCPU x86_64 с AVX2, 16 ГБ RAM (свободно ~11 ГБ при запущенном k3d), без GPU.
Рантайм для всех моделей одинаковый: официальный образ `ghcr.io/ggml-org/llama.cpp:server-b11681`
(upstream llama.cpp, без форков), `-t 6`, `--memory 2g`, temperature 0, seed 42. Дата: 2026-10-17.

Задачи (одинаковые для всех, `llm/llm_gen.py`, промпты в `llm/prompts/`):
1. `rule0`: «critical, если service_probe_latency_seconds > 1 с в течение 2 мин» → PrometheusRule.
2. `rule1`: «warning, если rate 5xx в http_requests_total за 5m > 0.1/с в течение 5m».
3. `rule2`: «critical, если process_resident_memory_bytes > 400MB в течение 10m».
4. `explain`: объяснить провал canary и откат по логу `llm/examples/canary-fail.log` (выдержка из `docs/cd-demo-log.md`).

«Валидно» = прошёл YAML + структура + `release: mon` + `promtool check rules` (Prometheus v2.54.1), допускался один
раунд исправления по ошибкам валидатора. «Смысл» — ручная проверка выражения человеком.

| Модель (HF) | Формат | Файл | Лицензия | Генерация, ток/с | Prompt, ток/с | Память (docker stats) | Валидно rule0/1/2 | Смысл правил (вручную) | explain (вручную) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [prism-ml/Ternary-Bonsai-2-4B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf) | Q2_0 (тернарные) | 1.21 ГБ | Apache-2.0 | 14.5 | 34 | 1.00 ГиБ | ✔/✔/✔ (с 1-й попытки) | rule2 верно; rule0 `rate()` по gauge, rule1 `path=".*"` — ловятся новым линтом | верно, конкретно, «stable не задет» (тогда на английском; после русского промпта — на русском, см. README) |
| [prism-ml/Ternary-Bonsai-2-2B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf) | Q2_0 | 0.55 ГБ | Apache-2.0 | 38.0 | 90 | 0.71 ГиБ | ✔/✘/✔ | rule0, rule2 верно | в целом верно, придумал имя релиза |
| [prism-ml/Bonsai-8B-gguf](https://huggingface.co/prism-ml/Bonsai-8B-gguf) | Q1_0 (1-бит) | 1.16 ГБ | Apache-2.0 | 16.9 | 26 | 1.10 ГиБ | ✘/✘/✘ | — | верно |
| [prism-ml/Bonsai-4B-gguf](https://huggingface.co/prism-ml/Bonsai-4B-gguf) | Q1_0 | 0.57 ГБ | Apache-2.0 | 29.1 | 43 | 1.49 ГиБ | ✔/✘/✘ | — | верно, на английском, путает PASS/FAIL |
| [prism-ml/Bonsai-1.7B-gguf](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) | Q1_0 | 0.25 ГБ | Apache-2.0 | 64.5 | 103 | 1.0 ГиБ | ✔/✘/✘ | — | — |
| [Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF) | Q4_K_M | 1.12 ГБ | Apache-2.0 | 34.0 | 312 | 1.69 ГиБ | ✔/✘/✔ | rule0, rule2 верно | **ошибка**: «stable traffic was affected» |
| [Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF) | Q4_K_M | 0.49 ГБ | Apache-2.0 | 79.5 | 350 | 0.56 ГиБ | ✔/✘/✘ | — | поверхностно |

Память в `docker stats` включает часть page cache от mmap весов и плавает; точный замер выбранной модели в рабочем
режиме (`scripts/llm-up.sh`: `-c 2048 -np 1 --cache-ram 0`): пиковый RSS процесса **1.66 ГБ** = 0.47 ГБ анонимной памяти
(KV-кэш, буферы) + 1.19 ГБ отображённых весов (страницы файла, вытесняемые ядром). С настройками сервера по умолчанию
(`-c 4096`, кэш промптов) было 2.19 ГБ — поэтому они переопределены.
Сырые прогоны: `docs/llm/examples/runs.jsonl` (выбранная модель), дополнительно первый проход без цикла исправления:
все Bonsai-1.7B/4B/8B и Ternary-2-2B завалили ≥2 из 3 правил (чаще всего `metadata.name` с `_`, незакрытый ```yaml).

## Не включены

- **SmolLM2-1.7B-Instruct** (Apache-2.0) скачана, но снята после первого прохода из-за нехватки времени, не замерена.
- **Gemma 3 270M/1B, Llama 3.2 1B** — gated-репозитории на HF (нужны принятие лицензии и токен) — противоречит
  требованию «жюри скачивает без токена»; лицензии не OSI.
- **BitNet b1.58 2B4T** — для эффективного CPU-инференса нужен отдельный рантайм bitnet.cpp; не замерялась.
- **Bonsai через форк PrismML-Eng/llama.cpp** не понадобился: форматы Q1_0 и Q2_0 работают в upstream-образе b11681
  (проверено запуском всех пяти Bonsai выше), сборка форка на Ubuntu не нужна.

## Решение

**Ternary-Bonsai-2-4B Q2_0** — по умолчанию (`LLM_NAME=ternary-bonsai-2-4b`): единственная модель, давшая 3/3 правила,
прошедших YAML+promtool с первой попытки, и лучшее объяснение отката без фактических ошибок; Apache-2.0, без токена,
стандартный llama.cpp. Цена — 14.5 ток/с (правило ~16–26 с, объяснение ~50 с) и пик RSS 1.66 ГБ, чуть выше цели 1.5 ГБ.
Синтаксически валидные, но неверные по смыслу выражения (rule0, rule1) показали, что promtool недостаточно, —
в валидатор добавлены проверки `rate()` по gauge и regex в `=`-матчере; модели не доверяем без проверки и ревью.

**Ternary-Bonsai-2-2B Q2_0** — запасной лёгкий вариант для машин с 8 ГБ (`make llm-up LLM_NAME=ternary-bonsai-2-2b`):
0.55 ГБ, 38 ток/с, ~0.7 ГиБ, 2/3 правил.
