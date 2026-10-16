.PHONY: up down test logs

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
