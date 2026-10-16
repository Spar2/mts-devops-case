.PHONY: up down test logs k8s-up k8s-images k8s-deploy k8s-canary k8s-rollback-demo k8s-down lint

# Быстрое демо (по умолчанию для жюри): Docker Compose, ~1 минута, до 2 ГБ RAM.
up:
	@test -f .env || cp .env.example .env
	docker compose up --build -d
	@echo "Стенд: http://127.0.0.1:8080  логин demo"

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

test:
	cd services/api && python -m pip install -r requirements.txt && python -m pytest
	cd apps/web && npm ci && npm run build

lint:
	ruff check services/api
	helm lint deploy/helm/sensor-gateway

# Полный контур: k3s + ingress-nginx + SOPS-секрет + kube-prometheus-stack + Helm-релиз.
# Нужен sudo (k3s ставится в систему), ~10 минут, ориентир 6-8 ГБ RAM.
TAG ?= $(shell git rev-parse --short=7 HEAD)
PREFIX ?= ghcr.io/spar2/mts-devops-case
K3D ?= 0
ifeq ($(K3D),1)
export KUBECONFIG ?= $(HOME)/.kube/config
IMPORT_CMD = k3d image import -c mts
else
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
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

k8s-down:
	-helm uninstall sensor-canary -n sensor
	-helm uninstall sensor -n sensor
	-helm uninstall mon -n monitoring
	@echo "k3s целиком удаляется: sudo /usr/local/bin/k3s-uninstall.sh"
