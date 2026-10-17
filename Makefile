.PHONY: ghcr-secret k8s-deploy-ghcr up down demo demo-down test logs status k8s-up k8s-images k8s-deploy k8s-canary k8s-canary-fail k8s-rollback-demo k8s-alert-demo k8s-netpol-check k8s-rotate-demo k8s-down lint lint-ruff lint-tools lint-helm lint-manifests lint-dockerfiles lint-shellcheck

# Полное решение за 3 команды (git clone, cd, make up): k3d-кластер (k3s v1.31.4 в Docker) + ingress-nginx +
# SOPS-секрет + kube-prometheus-stack + Helm-релиз + smoke. Нужен только Docker; ~5 минут, 8 ГБ RAM.
# Нативный k3s на хосте (ВМ, OpenStack-инстанс): make up K3D=0 (нужен sudo).
up: k8s-up status

# Быстрое демо без Kubernetes: Docker Compose, ~1 минута, до 2 ГБ RAM.
demo:
	@test -f .env || cp .env.example .env
	docker compose up --build -d
	@echo "Стенд: http://127.0.0.1:8080  логин demo, пароль из .env"

demo-down:
	@if [ -f .env ]; then docker compose down; else echo "demo-down: .env нет, Compose-стенд не запускался"; fi

down: k8s-down demo-down

logs:
	docker compose logs -f --tail=100

test:
	cd services/api && python3 -m pip install -r requirements.txt && python3 -m pytest
	cd apps/web && npm ci && npm run build

# Локальный повтор CI (jobs lint, helm, manifests, dockerfiles, shellcheck и ruff из job llm).
# Бинарь нужной версии берётся из PATH. Иначе: ruff/hadolint/shellcheck — docker-образ
# с тем же тегом; helm и kubeconform — ~/.local/bin со сверкой sha256 (scripts/lint-manifests.sh).
RUFF_IMAGE ?= ghcr.io/astral-sh/ruff:0.8.4
HADOLINT_IMAGE ?= hadolint/hadolint:v2.12.0
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.10.0

lint: lint-ruff lint-helm lint-manifests lint-dockerfiles lint-shellcheck

# ruff 0.8.4: services/api (job lint) и каталог llm (job llm).
lint-ruff:
	@set -eu; \
	run() { \
	  if command -v ruff >/dev/null 2>&1 && ruff version 2>/dev/null | head -n 1 | grep -q '^ruff 0.8.4$$'; then \
	    ruff check "$$1"; \
	  else \
	    docker run --rm -v "$(CURDIR):/io" -w /io "$(RUFF_IMAGE)" check "$$1"; \
	  fi; \
	}; \
	printf '%s\n' 'ruff check services/api'; \
	run services/api; \
	printf '%s\n' 'ruff check llm'; \
	run llm

# Поставить helm v3.16.3 и kubeconform 0.6.7, если в PATH ещё нет этой версии.
lint-tools:
	./scripts/lint-manifests.sh --ensure-tools

# Helm v3.16.3: lint и template чарта (job helm). stdout template скрыт, ошибки видны.
lint-helm: lint-tools
	@export PATH="$${HOME}/.local/bin:$${PATH}"; \
	helm lint deploy/helm/sensor-gateway; \
	helm template sensor deploy/helm/sensor-gateway --namespace sensor >/dev/null

# kubeconform 0.6.7: stable, canary и манифесты мониторинга (job manifests).
lint-manifests: lint-tools
	./scripts/lint-manifests.sh

# hadolint 2.12.0, --failure-threshold error (job dockerfiles, hadolint-action@v3.1.0).
lint-dockerfiles:
	@set -eu; \
	run() { \
	  printf '%s\n' "hadolint $$1"; \
	  if command -v hadolint >/dev/null 2>&1 && hadolint --version 2>/dev/null | grep -q 'Haskell Dockerfile Linter 2.12.0$$'; then \
	    hadolint --failure-threshold error "$$1"; \
	  else \
	    docker run --rm --entrypoint /bin/hadolint -v "$(CURDIR):/io" -w /io "$(HADOLINT_IMAGE)" --failure-threshold error "$$1"; \
	  fi; \
	}; \
	run services/api/Dockerfile; \
	run apps/web/Dockerfile

# shellcheck 0.10.0 для scripts/*.sh (job shellcheck).
lint-shellcheck:
	@set -eu; \
	printf '%s\n' 'shellcheck scripts/*.sh'; \
	if command -v shellcheck >/dev/null 2>&1 && shellcheck --version 2>/dev/null | grep -q '^version: 0.10.0$$'; then \
	  shellcheck scripts/*.sh; \
	else \
	  docker run --rm -v "$(CURDIR):/mnt" -w /mnt "$(SHELLCHECK_IMAGE)" scripts/*.sh; \
	fi

# Полный контур: k3s + ingress-nginx + SOPS-секрет + kube-prometheus-stack + Helm-релиз.
TAG ?= $(shell git rev-parse --short=7 HEAD)
PREFIX ?= ghcr.io/spar2/mts-devops-case
K3D ?= 1
ifeq ($(K3D),1)
export INGRESS_PORT ?= 8081
export KUBECONFIG ?= $(HOME)/.kube/config
IMPORT_CMD = k3d image import -c mts
else
export KUBECONFIG ?= $(HOME)/.kube/config
export INGRESS_PORT ?= 80
IMPORT_CMD = docker save $(PREFIX)/sensor-gateway:$(TAG) $(PREFIX)/sensor-web:$(TAG) | sudo k3s ctr images import -
endif
export K3D

# Образы собираются до kube-prometheus-stack: ниже пик RAM на ВМ 8 ГБ.
k8s-up:
	./scripts/k3s-install.sh
	./scripts/secrets-init.sh
	./scripts/secrets-apply.sh
	$(MAKE) k8s-images
	./scripts/monitoring-install.sh
	$(MAKE) k8s-deploy

# Образы собираются локально и импортируются в containerd k3s: не нужен доступ к приватному GHCR.
# Чтобы брать образы из GHCR (их пушит CI), выполнить: make k8s-deploy TAG=<sha> после docker login/pull secret.
k8s-images:
	docker build -t $(PREFIX)/sensor-gateway:$(TAG) services/api
	docker build -t $(PREFIX)/sensor-web:$(TAG) apps/web
ifeq ($(K3D),1)
	$(IMPORT_CMD) $(PREFIX)/sensor-gateway:$(TAG) $(PREFIX)/sensor-web:$(TAG)
else
	$(IMPORT_CMD)
endif

# Опционально: брать образы, которые пушит CI, из приватного GHCR.
# GHCR_USER=<login> GHCR_TOKEN=<PAT с read:packages> make ghcr-secret
# затем make k8s-deploy-ghcr TAG=<короткий sha коммита из main>.
ghcr-secret:
	@test -n "$$GHCR_USER" -a -n "$$GHCR_TOKEN" || { echo "нужны GHCR_USER и GHCR_TOKEN (read:packages)"; exit 1; }
	kubectl create namespace sensor --dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n sensor create secret docker-registry ghcr --docker-server=ghcr.io \
	  --docker-username="$$GHCR_USER" --docker-password="$$GHCR_TOKEN" --dry-run=client -o yaml | kubectl apply -f -

k8s-deploy-ghcr:
	HELM_ARGS="--set imagePullSecrets[0].name=ghcr" ./scripts/deploy.sh $(TAG)

k8s-deploy:
	./scripts/deploy.sh $(TAG)

# Метрический гейт canary читает Prometheus по PROM_URL (по умолчанию port-forward на 9090).
k8s-canary:
	./scripts/prom-forward.sh
	./scripts/canary.sh $(TAG)

k8s-rollback-demo:
	./scripts/rollback-demo.sh

# Пароль в лог не пишется. Команда чтения — всегда; само значение только при
# SHOW_SECRETS=1 и не в CI (GitHub Actions задаёт CI=true, make up вызывает status).
status:
	@echo
	@echo "Приложение: http://sensor.localtest.me:$(INGRESS_PORT)  логин demo"
	@if [ "$${CI:-}" = "true" ]; then \
	  echo "Пароль в лог не печатается (CI=true)."; \
	  echo "  kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo"; \
	elif [ "$${SHOW_SECRETS:-}" = "1" ]; then \
	  printf '%s' "Пароль: "; \
	  kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo; \
	else \
	  echo "Пароль не печатается. Напечатать значение: SHOW_SECRETS=1 make status"; \
	  echo "  kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo"; \
	fi
	@echo "Grafana:    http://grafana.localtest.me:$(INGRESS_PORT)  логин admin (дашборд sensor-gateway)"
	@if [ "$${CI:-}" = "true" ]; then \
	  echo "Пароль в лог не печатается (CI=true)."; \
	  echo "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"; \
	elif [ "$${SHOW_SECRETS:-}" = "1" ]; then \
	  printf '%s' "Пароль: "; \
	  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo; \
	else \
	  echo "Пароль не печатается. Напечатать значение: SHOW_SECRETS=1 make status"; \
	  echo "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"; \
	fi
	@echo "Демо: make k8s-canary | make k8s-canary-fail | make k8s-rollback-demo | make k8s-rotate-demo | make k8s-alert-demo"

k8s-canary-fail:
	./scripts/canary-fail-demo.sh $(TAG)

k8s-netpol-check:
	./scripts/netpol-check.sh $(TAG)

k8s-alert-demo:
	./scripts/alert-demo.sh

k8s-rotate-demo:
	./scripts/secrets-rotate-check.sh

ifeq ($(K3D),1)
k8s-down:
	-k3d cluster delete mts
else
k8s-down:
	-helm uninstall sensor-canary -n sensor
	-helm uninstall sensor -n sensor
	-helm uninstall mon -n monitoring
	@echo "k3s целиком удаляется: sudo /usr/local/bin/k3s-uninstall.sh"
endif

# --- Локальная LLM (опционально, make up / make k8s-up от неё не зависят), см. README «Использование LLM» ---
.PHONY: llm-fetch llm-up llm-down llm-gen llm-explain llm-notes llm-test
LLM_NAME ?= ternary-bonsai-2-4b
export LLM_NAME
LLM_PY ?= python3
DESC ?= Critical alert when service_probe_latency_seconds is above 1 second for 2 minutes

llm-fetch:
	./scripts/llm-fetch.sh $(LLM_NAME)

llm-up: llm-fetch
	./scripts/llm-up.sh

llm-down:
	docker rm -f mts-llm

# Описание → PrometheusRule → проверка (YAML, структура, release=mon, белый список метрик llm/metrics_whitelist.yaml, promtool check rules); при ошибке один раунд исправления.
llm-gen:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py rule "$(DESC)"

# Объяснение провала canary/отката по логу (по умолчанию пример из docs/cd-demo-log.md). Числа из 3+ цифр сверяются по границам токена, не по подстроке.
LOG ?= llm/examples/canary-fail.log
llm-explain:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py explain $(LOG)

RANGE ?= HEAD~5..HEAD
llm-notes:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py notes --range $(RANGE)

# Тесты валидатора и цикла исправления без модели (фейковый OpenAI-сервер).
llm-test:
	$(LLM_PY) -m pytest -q llm
