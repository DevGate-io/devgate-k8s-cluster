# DevGate Kubernetes — локальный кластер (minikube) и удалённый деплой (k3s).
# Использование из корня репозитория:  make -C k8s <цель>
# Список целей:                        make -C k8s help

SHELL := /bin/bash
.DEFAULT_GOAL := help

K8S_DIR         := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT            := $(abspath $(K8S_DIR)/..)
PROFILE         ?= devgate
MINIKUBE_FLAGS  ?= --driver=docker --cpus=4 --memory=8192
REGISTRY        ?= registry.example.com/devgate
TAG             ?= 1.0.0

# каталог_сервиса:путь_к_jar:образ
SERVICES := \
	devgate-user-service:build/libs/user-service.jar:devgate/user-service:local \
	devgate-audit-service:build/libs/audit-service.jar:devgate/audit-service:local \
	devgate-integration-service:build/libs/integration-service.jar:devgate/integration-service:local \
	devgate-catalog-service:build/libs/catalog-service.jar:devgate/catalog-service:local \
	devgate-scaffolder-service:build/libs/scaffolder-service.jar:devgate/scaffolder-service:local \
	devgate-notification-service:build/libs/notification-service.jar:devgate/notification-service:local

define build-spring-loop
	for s in $(SERVICES); do \
		svc_dir="$${s%%:*}"; rest="$${s#*:}"; jar="$${rest%%:*}"; img="$${rest#*:}"; \
		echo "=== $$svc_dir ==="; \
		(cd $(ROOT)/$$svc_dir && ./gradlew bootJar -x test --quiet); \
		docker build --build-arg JAR_FILE=$$jar -t $$img \
			-f $(K8S_DIR)images/spring-service.Dockerfile $(ROOT)/$$svc_dir; \
	done
endef

.PHONY: help cluster-up cluster-down build build-local push deploy deploy-remote \
	tunnel status logs rabbitmq-ui down clean

help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(K8S_DIR)Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

cluster-up: ## Поднять minikube (профиль devgate)
	minikube --profile $(PROFILE) start $(MINIKUBE_FLAGS)
	kubectl config use-context $(PROFILE)

cluster-down: ## Остановить кластер
	minikube --profile $(PROFILE) stop

build: ## Собрать образы всех сервисов в docker-демон minikube
	@minikube --profile $(PROFILE) status >/dev/null 2>&1 || $(MAKE) --no-print-directory cluster-up
	@eval $$(minikube --profile $(PROFILE) docker-env); \
	$(build-spring-loop); \
	echo "=== devgate-frontend ==="; \
	docker build -t devgate/frontend:local \
		-f $(K8S_DIR)images/frontend.Dockerfile $(ROOT)/devgate-frontend; \
	echo; echo "Готово. Образы в демоне minikube:"; \
	docker images | grep -E 'devgate/|REPOSITORY'

build-local: ## Собрать образы в локальный docker (для пуша в registry)
	@$(build-spring-loop); \
	echo "=== devgate-frontend ==="; \
	docker build -t devgate/frontend:local \
		-f $(K8S_DIR)images/frontend.Dockerfile $(ROOT)/devgate-frontend; \
	echo; echo "Готово. Образы в локальном docker (devgate/*:local) — готовы к tag/push:"; \
	docker images | grep -E 'devgate/|REPOSITORY'

push: build-local ## Собрать и запушить образы в registry (REGISTRY=... TAG=...)
	@for img in user-service audit-service integration-service \
		catalog-service scaffolder-service notification-service frontend; do \
		docker tag devgate/$$img:local $(REGISTRY)/$$img:$(TAG); \
		docker push $(REGISTRY)/$$img:$(TAG); \
	done

deploy: ## Развернуть манифесты в локальном кластере
	@minikube --profile $(PROFILE) status >/dev/null 2>&1 || $(MAKE) --no-print-directory cluster-up
	kubectl config use-context $(PROFILE)
	kubectl apply -f $(K8S_DIR)00-namespace.yaml \
	              -f $(K8S_DIR)10-secrets.yaml \
	              -f $(K8S_DIR)infra \
	              -f $(K8S_DIR)apps \
	              -f $(K8S_DIR)gateway
	@echo; echo ">>> Ждём готовности подов (до 5 минут)..."
	@kubectl -n devgate wait --for=condition=Ready pods --all --timeout=300s || true
	@echo
	kubectl -n devgate get pods,svc
	@echo; echo ">>> Далее: /etc/hosts и 'make -C k8s tunnel' (см. k8s/README.md)"

deploy-remote: ## Деплой на удалённый кластер через kustomize (REGISTRY=... TAG=...)
	kubectl kustomize --load-restrictor LoadRestrictionsNone $(K8S_DIR)overlays/remote | \
	sed 's#REGISTRY_URL#$(REGISTRY)#g; s/\bTAG\b/$(TAG)/g' | kubectl apply -f -

tunnel: ## minikube tunnel для LoadBalancer-шлюза (порт 80)
	minikube --profile $(PROFILE) tunnel

status: ## Статус подов и сервисов
	kubectl -n devgate get pods,svc

logs: ## Логи user-service (нужный сервис — напрямую через kubectl logs)
	kubectl -n devgate logs -f deployment/devgate-user-service

rabbitmq-ui: ## Port-forward RabbitMQ UI → http://localhost:15672
	kubectl -n devgate port-forward svc/rabbitmq 15672:15672

down: ## Удалить приложение из кластера
	kubectl delete namespace devgate

clean: ## Удалить кластер minikube
	minikube --profile $(PROFILE) delete
