SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help deploy verify demo release-good release-bad release-reset release-status

help: ## Показать доступные команды
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

deploy: ## Развернуть всё решение (идемпотентно): sudo make deploy
	./deploy.sh

verify: ## Проверить работоспособность: make verify
	./scripts/verify.sh

demo: ## Экскурсия по решению (DEMO_ARGS=--auto — без пауз)
	./scripts/demo.sh $(DEMO_ARGS)

release-good: ## Canary-релиз новой версии v1.1 (проходит анализ, 100%)
	./scripts/release.sh good

release-bad: ## Canary-релиз версии с 500 — автоматический откат
	./scripts/release.sh bad

release-reset: ## Вернуть версию приложения из Git
	./scripts/release.sh reset

release-status: ## Состояние Argo Rollout hello
	./scripts/release.sh status
