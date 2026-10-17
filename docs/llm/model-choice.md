# Выбор локальной LLM: замеры

Стенд замеров (box): 8 vCPU x86_64 с AVX2, 16 ГБ RAM (свободно ~11 ГБ при запущенном k3d), без GPU.
Рантайм для всех моделей одинаковый: официальный образ `ghcr.io/ggml-org/llama.cpp:server-b11681`
(upstream llama.cpp, без форков), `-t 6`, `--memory 2g`, temperature 0, seed 42. Дата: 2026-10-17.

Таблица ниже (колонки «Генерация», «Prompt», «Память» и отметки ✔/✘) — прежний замер на английских задачах, `-t 6`. Колонка «Валидно» у Ternary-Bonsai-2-4B к нему не относится: это русский повтор 2026-10-17 (`-t 4`). Остальные модели на русских фразах не запускались. `make llm-gen` без `DESC` берёт из Makefile английскую фразу `Critical alert when service_probe_latency_seconds is above 1 second for 2 minutes`, не rule0 ниже. Точные английские строки и секунды выбранной модели — в абзаце про `runs.jsonl`.

Русские фразы — только повтор Ternary-Bonsai-2-4B (`llm/llm_gen.py`, промпты в `llm/prompts/`):
1. `rule0`: «critical, если service_probe_latency_seconds > 1 с в течение 2 мин» → PrometheusRule.
2. `rule1`: «warning, если rate 5xx в http_requests_total за 5m > 0.1/с в течение 5m».
3. `rule2`: «critical, если process_resident_memory_bytes > 400MB в течение 10m».
4. `explain`: объяснить провал canary и откат по логу `llm/examples/canary-fail.log` (выдержка из `docs/cd-demo-log.md`).

Фразы выше — текст этого повтора, не задач остальных строк таблицы. На повтор 2026-10-17 список в `llm/llm_gen.py` был `up`, `service_up`, `service_probe_latency_seconds`, `http_requests_total` без меток: `/metrics` писался вручную, `process_resident_memory_bytes` и метки `status`/`path` сервис не отдавал. Сейчас API пишет метрики через `prometheus_client` 0.26.0 (`http_requests_total` и `http_request_duration_seconds` с `method`, `path`, `status`, `service_up` по проверке готовности, измеренный `service_probe_latency_seconds`, process collector). Имена и метки, которые валидатор принимает, — `llm/metrics_whitelist.yaml`: ряды API, включая `http_request_duration_seconds_bucket`/`_sum`/`_count` и метки `method`, `path`, `status` у счётчика и гистограммы, `up`, `nginx_ingress_controller_requests`, kube-state-metrics из `deploy/monitoring/prometheusrule.yaml`. Строка для модели собирается из этого файла (`KNOWN_METRICS` в `llm/llm_gen.py`). `process_resident_memory_bytes` в списке нет.

«Валидно» = прошёл YAML + структура + `release: mon` + `promtool check rules` (Prometheus v2.54.1), допускался один
раунд исправления по ошибкам валидатора. «Смысл» — ручная проверка выражения человеком.
Белый список в эти прогоны не входил. rule1 с `status` у `http_requests_total` список больше не отвергает из-за метки: `status` у счётчика есть. `histogram_quantile` по `http_request_duration_seconds_bucket` валиден, по самому `http_requests_total` — нет. rule2 с `process_resident_memory_bytes` список по-прежнему отвергает: ряд в белый список не входит.

| Модель (HF) | Формат | Файл | Лицензия | Генерация, ток/с | Prompt, ток/с | Память (docker stats) | Валидно rule0/1/2 | Смысл правил (вручную) | explain (вручную) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [prism-ml/Ternary-Bonsai-2-4B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf) | Q2_0 (тернарные) | 1.21 ГБ | Apache-2.0 | 14.5 | 34 | 1.00 ГиБ | ✘ / ✔ с 1-й / ✔ со 2-й | повтор 2026-10-17: rule0 `sum(...[2m])` — promtool (range vector); rule1 `rate` + `status=~"5.."` прошёл; rule2 со 2-й — gauge > 400000000 | explain: проверки скрипта пройдены, 66.67 с, attempts 1 |
| [prism-ml/Ternary-Bonsai-2-2B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf) | Q2_0 | 0.55 ГБ | Apache-2.0 | 38.0 | 90 | 0.71 ГиБ | ✔/✘/✔ | rule0, rule2 верно | в целом верно, придумал имя релиза |
| [prism-ml/Bonsai-8B-gguf](https://huggingface.co/prism-ml/Bonsai-8B-gguf) | Q1_0 (1-бит) | 1.16 ГБ | Apache-2.0 | 16.9 | 26 | 1.10 ГиБ | ✘/✘/✘ | — | верно |
| [prism-ml/Bonsai-4B-gguf](https://huggingface.co/prism-ml/Bonsai-4B-gguf) | Q1_0 | 0.57 ГБ | Apache-2.0 | 29.1 | 43 | 1.49 ГиБ | ✔/✘/✘ | — | верно, на английском, путает PASS/FAIL |
| [prism-ml/Bonsai-1.7B-gguf](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) | Q1_0 | 0.25 ГБ | Apache-2.0 | 64.5 | 103 | 1.0 ГиБ | ✔/✘/✘ | — | — |
| [Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF) | Q4_K_M | 1.12 ГБ | Apache-2.0 | 34.0 | 312 | 1.69 ГиБ | ✔/✘/✔ | rule0, rule2 верно | **ошибка**: «stable traffic was affected» |
| [Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF) | Q4_K_M | 0.49 ГБ | Apache-2.0 | 79.5 | 350 | 0.56 ГиБ | ✔/✘/✘ | — | поверхностно |

Память в `docker stats` включает часть page cache от mmap весов и плавает; точный замер выбранной модели в рабочем
режиме (`scripts/llm-up.sh`: `-c 2048 -np 1 --cache-ram 0`): пиковый RSS процесса **1.66 ГБ** (прежний замер, в повторе 2026-10-17 не снимался) = 0.47 ГБ анонимной памяти
(KV-кэш, буферы) + 1.19 ГБ отображённых весов (страницы файла, вытесняемые ядром). С настройками сервера по умолчанию
(`-c 4096`, кэш промптов) было 2.19 ГБ — поэтому они переопределены.
Колонки «Генерация», «Prompt» и «Память» — прежний замер (`-t 6`); в повторном прогоне 2026-10-17 их не снимали. Колонка «Валидно» у Ternary-Bonsai-2-4B — этот повтор.

В `docs/llm/examples/runs.jsonl` два прогона.

Ранний, метки `2026-10-17T04:36:52+0300` … `04:40:03+0300`: задачи на английском, не фразы rule0/1/2 выше. Четыре записи `task=rule` выбранной модели: 5xx valid 17.86 с (attempts 1), memory valid 15.71 с и 25.91 с (attempts 1), задержка invalid 46.01 с (attempts 2, promtool: range vector). Explain той же модели `04:38:57+0300`, 52.5 с, valid. Строка explain qwen — `04:58:01+0300`.

Повтор, метки `2026-10-17T07:25:15+0000` … `07:28:24+0000`: `make llm-up` без `LLM_THREADS` (в контейнере `-t 4`, `--memory 2g`), затем `make llm-gen` ровно с тремя фразами выше и `make llm-explain`. С первой попытки valid одна из трёх. rule0: 51.11 с, attempts 2, valid false (в поле `errors` ещё первая загрузка `prom/prometheus:v2.54.1`, затем promtool: range vector в `sum`). rule1: 16.88 с, attempts 1, valid true. rule2: 104.27 с, attempts 2, valid true (первая попытка — `rate()` по gauge, вторая — сравнение с 400000000). explain: 66.67 с, attempts 1, valid true, `cyrillic_share` 0.6.

Первый проход без цикла исправления (прежняя таблица, не повтор):
все Bonsai-1.7B/4B/8B и Ternary-2-2B завалили ≥2 из 3 правил (чаще всего `metadata.name` с `_`, незакрытый ```yaml).

## Не включены

- **SmolLM2-1.7B-Instruct** (Apache-2.0) скачана, но снята после первого прохода из-за нехватки времени, не замерена.
- **Gemma 3 270M/1B, Llama 3.2 1B** — gated-репозитории на HF (нужны принятие лицензии и токен) — противоречит
  требованию «жюри скачивает без токена»; лицензии не OSI.
- **BitNet b1.58 2B4T** — для эффективного CPU-инференса нужен отдельный рантайм bitnet.cpp; не замерялась.
- **Bonsai через форк PrismML-Eng/llama.cpp** не понадобился: форматы Q1_0 и Q2_0 работают в upstream-образе b11681
  (проверено запуском всех пяти Bonsai выше), сборка форка на Ubuntu не нужна.

## Решение

**Ternary-Bonsai-2-4B Q2_0** — по умолчанию (`LLM_NAME=ternary-bonsai-2-4b`). Повтор трёх фраз выше 2026-10-17 (`-t 4`): с первой попытки valid одна из трёх (только rule1, 16.88 с). rule0 не прошёл и со второй попытки (51.11 с), rule2 прошёл со второй (104.27 с), explain — 66.67 с, valid с первой. 14.5 ток/с и пик RSS 1.66 ГБ — прежний замер на `-t 6`, здесь не повторялись. Остальные модели в этот день заново не запускались. Apache-2.0, без токена, стандартный llama.cpp.
На старом проходе синтаксически валидные, но неверные по смыслу выражения (rule0, rule1) показали, что promtool недостаточно, —
в валидатор добавлены проверки `rate()` по gauge и regex в `=`-матчере; позже — белый список метрик и меток (`llm/metrics_whitelist.yaml`) и запрет `histogram_quantile` не по ряду `*_bucket`. Модели не доверяем без проверки и ревью.

**Ternary-Bonsai-2-2B Q2_0** — запасной лёгкий вариант для машин с 8 ГБ (`make llm-up LLM_NAME=ternary-bonsai-2-2b`):
0.55 ГБ, 38 ток/с, ~0.7 ГиБ, 2/3 правил.
