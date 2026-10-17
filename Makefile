.PHONY: up down demo demo-down test logs status k8s-up k8s-images k8s-deploy k8s-canary k8s-canary-fail k8s-rollback-demo k8s-alert-demo k8s-netpol-check k8s-rotate-demo k8s-down lint

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
	docker compose down

down: k8s-down demo-down

logs:
	docker compose logs -f --tail=100

test:
	cd services/api && python -m pip install -r requirements.txt && python -m pytest
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
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
export INGRESS_PORT ?= 80
IMPORT_CMD = docker save $(PREFIX)/sensor-gateway:$(TAG) $(PREFIX)/sensor-web:$(TAG) | sudo k3s ctr images import -
endif
export K3D

k8s-up:
	./scripts/k3s-install.sh
	./scripts/secrets-init.sh
	./scripts/secrets-apply.sh
	./scripts/monitoring-install.sh
	$(MAKE) k8s-images k8s-deploy

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

k8s-deploy:
	./scripts/deploy.sh $(TAG)

# Метрический гейт canary читает Prometheus по PROM_URL (по умолчанию port-forward на 9090).
k8s-canary:
	@pgrep -f "port-forward svc/mon-kube-prometheus-stack-prometheus" >/dev/null || \
	  (kubectl -n monitoring port-forward svc/mon-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &) ; sleep 2
	./scripts/canary.sh $(TAG)

k8s-rollback-demo:
	./scripts/rollback-demo.sh

status:
	@echo
	@echo "Приложение: http://sensor.localtest.me:$(INGRESS_PORT)  логин demo, пароль:"
	@kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo
	@echo "Grafana:    http://grafana.localtest.me:$(INGRESS_PORT)  (admin/admin, дашборд sensor-gateway)"
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
