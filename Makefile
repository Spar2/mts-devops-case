.PHONY: ghcr-secret k8s-deploy-ghcr up down demo demo-down test logs status k8s-up k8s-images k8s-deploy k8s-canary k8s-canary-fail k8s-rollback-demo k8s-alert-demo k8s-netpol-check k8s-rotate-demo k8s-down lint

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

lint:
	ruff check services/api
	helm lint deploy/helm/sensor-gateway

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

status:
	@echo
	@echo "Приложение: http://sensor.localtest.me:$(INGRESS_PORT)  логин demo, пароль:"
	@kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo
	@echo "Grafana:    http://grafana.localtest.me:$(INGRESS_PORT)  логин admin, пароль (дашборд sensor-gateway):"
	@kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
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

# Описание → PrometheusRule → проверка (YAML, структура, release=mon, promtool check rules); при ошибке один раунд исправления.
llm-gen:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py rule "$(DESC)"

# Объяснение провала canary/отката по логу (по умолчанию пример из docs/cd-demo-log.md) с проверкой на выдуманные числа.
LOG ?= llm/examples/canary-fail.log
llm-explain:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py explain $(LOG)

RANGE ?= HEAD~5..HEAD
llm-notes:
	LLM_MODEL=$(LLM_NAME) $(LLM_PY) llm/llm_gen.py notes --range $(RANGE)

# Тесты валидатора и цикла исправления без модели (фейковый OpenAI-сервер).
llm-test:
	$(LLM_PY) -m pytest -q llm
