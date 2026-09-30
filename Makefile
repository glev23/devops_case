SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help deploy verify

help: ## Показать доступные команды
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

deploy: ## Развернуть всё решение (идемпотентно): sudo make deploy
	./deploy.sh

verify: ## Проверить работоспособность: make verify
	./scripts/verify.sh
