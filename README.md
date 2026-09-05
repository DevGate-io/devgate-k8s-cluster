# DevGate в Kubernetes (локальный кластер)

Локальное развёртывание всего проекта DevGate в Kubernetes через **minikube** (docker-драйвер).

> Все команды ниже используют отдельный профиль minikube **devgate**, поэтому другие
> кластеры на машине не затрагиваются.

## Что разворачивается

| Компонент | k8s-ресурсы | Порт |
|---|---|---|
| Postgres 16 (один инстанс, 6 БД через init-скрипт) | StatefulSet + PVC | 5432 (ClusterIP) |
| RabbitMQ 4 + Management UI | Deployment + PVC | 5672 / 15672 (ClusterIP) |
| devgate-user-service | Deployment + Service | 8081 |
| devgate-audit-service | Deployment + Service | 8082 |
| devgate-integration-service | Deployment + Service | 8083 |
| devgate-catalog-service | Deployment + Service | 8084 |
| devgate-scaffolder-service | Deployment + Service | 8085 |
| devgate-notification-service | Deployment + Service | 8086 |
| devgate-frontend (Next.js) | Deployment + Service | 3000 |
| gateway (Nginx, тот же конфиг, что в docker/) | Deployment + LoadBalancer | 80 |

Service-имена совпадают с именами контейнеров из docker-compose (`devgate-user-service` и т.д.),
поэтому nginx-конфиг шлюза перенесён почти без изменений. Отличия: `resolver` указывает на
CoreDNS, а апстримы заданы FQDN (`devgate-user-service.devgate.svc.cluster.local`) — резолвер
nginx не применяет search-домены из /etc/resolv.conf, с короткими именами будет 502.
Маршрутизация по путям и хостам — как в `docker/gateway/nginx.conf`.

Структура:

```
k8s/
├── 00-namespace.yaml          # namespace devgate
├── 10-secrets.yaml            # пароли, JWT, ключ шифрования интеграций (dev-значения)
├── infra/                     # postgres.yaml, rabbitmq.yaml
├── apps/                      # манифесты 6 бэкенд-сервисов + frontend.yaml
├── gateway/                   # nginx-configmap.yaml, gateway.yaml (LoadBalancer :80)
├── overlays/remote/           # kustomize-оверлей для деплоя на удалённый кластер
├── images/                    # Dockerfile'ы
└── Makefile                   # цели сборки/деплоя (make -C k8s help)
```

## Требования

- Docker, minikube, kubectl, make
- ~10 ГБ свободного диска (образы) и 8 ГБ RAM для кластера
- Первая сборка фронтенда долгая (pnpm install в контейнере)

## Быстрый старт

```bash
# 1. Поднять кластер (профиль devgate, docker-драйвер)
make -C k8s cluster-up

# 2. Собрать образы всех сервисов (jars через gradle + docker build в демоне minikube)
make -C k8s build

# 3. Развернуть манифесты
make -C k8s deploy
```

`make -C k8s deploy` (и `build`) сам поднимет minikube, если он не запущен.
Полный список целей: `make -C k8s help`.

## Доступ из браузера

1. Добавьте в `/etc/hosts` (запросы ходят на 127.0.0.1 через `minikube tunnel`):

```
127.0.0.1 api.devgate.gateway.local api.devgate.users.local api.devgate.audit.local api.devgate.integrations.local api.devgate.catalog.local api.devgate.scaffolder.local api.devgate.notifications.local app.devgate.local
```

2. В отдельном терминале запустите туннель (нужен для LoadBalancer-сервиса шлюза;
   спросит пароль sudo, т.к. порт 80 привилегированный — оставьте процесс запущенным):

```bash
minikube --profile devgate tunnel   # или: make -C k8s tunnel
```

3. Проверка:

```bash
curl -H 'Host: api.devgate.users.local' http://127.0.0.1/health   # healthy
curl http://api.devgate.gateway.local/users                        # шлюз → user-service
```

Фронтенд: http://app.devgate.local

Альтернатива туннелю (без sudo, но с рандомным портом):
`minikube --profile devgate service gateway -n devgate`.

## Управление

```bash
kubectl -n devgate get pods                    # статус всех подов
kubectl -n devgate logs -f deployment/devgate-user-service
kubectl -n devgate port-forward svc/rabbitmq 15672:15672   # RabbitMQ UI: http://localhost:15672 (guest/guest)
kubectl -n devgate port-forward svc/postgres 5432:5432     # psql: psql -h localhost -U postgres
```

RabbitMQ UI недоступен снаружи напрямую — используйте port-forward.

## Обновление образов

```bash
make -C k8s build                                              # пересборка всех образов
kubectl -n devgate rollout restart deployment/devgate-user-service   # или нужный сервис
```

## Frontend в режиме разработки (альтернатива)

Вместо развёртывания Next.js в кластере можно держать его локально с HMR
(`pnpm dev` в `devgate-frontend/src`), а весь бэкенд — в кластере. Тогда применяйте
только манифесты бэкенда и шлюза (frontend.yaml не обязателен).

## Развертывание на удалённых машинах

Деплой на свои VPS/серверы: кластер — **k3s** (лёгкий, ставится одной командой,
из коробки есть local-path storage и service-lb/klipper для LoadBalancer),
приложение — те же манифесты через kustomize-оверлей `overlays/remote`.

### 1. Кластер k3s на сервере

Один узел (Ubuntu/Debian, от root):

```bash
# --disable traefik: порты 80/443 освобождаются под наш nginx-шлюз
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
kubectl get nodes
```

Несколько узлов (server = control plane + worker, agent = только worker):

```bash
# На server-ноде
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
sudo cat /var/lib/rancher/k3s/server/node-token   # токен для агентов

# На каждой agent-ноде
curl -sfL https://get.k3s.io | K3S_URL=https://<SERVER_IP>:6443 K3S_TOKEN=<TOKEN> sh -s - --disable traefik
```

### 2. Доступ к кластеру с рабочей машины

```bash
mkdir -p ~/.kube
scp user@server:/etc/rancher/k3s/k3s.yaml ~/.kube/devgate-remote.yaml
# В файле замените server: https://127.0.0.1:6443 → https://<SERVER_IP>:6443
export KUBECONFIG=~/.kube/devgate-remote.yaml
kubectl get nodes
```

### 3. Образы в registry

Удалённый кластер не видит docker-демон вашей машины и образы minikube, поэтому
образы нужно собрать локально и запушить в registry (Docker Hub, ghcr.io, GitLab,
или self-hosted). Сборка и пуш:

```bash
# Сборка в локальный docker и пуш в registry
make -C k8s push REGISTRY=registry.example.com/devgate TAG=1.0.0
```

Фронтенд: `NEXT_PUBLIC_API_URL` для браузера запекается на этапе сборки образа,
поэтому для удалённого кластера пересоберите его с реальным адресом API:

```bash
docker build -t devgate/frontend:local \
  --build-arg NEXT_PUBLIC_API_URL=https://api.devgate.example.com \
  -f k8s/images/frontend.Dockerfile devgate-frontend
```

### 4. Применение через оверлей

1. Замените dev-значения в `10-secrets.yaml` (см. «Безопасность»).
2. Примените (REGISTRY/TAG подставляются автоматически):

```bash
make -C k8s deploy-remote REGISTRY=registry.example.com/devgate TAG=1.0.0
# то же вручную:
# kubectl kustomize --load-restrictor LoadRestrictionsNone k8s/overlays/remote | kubectl apply -f -
```

Оверлей переписывает `image` во всех Deployment'ах на `<registry>/...:<tag>`.
Для приватного registry создайте docker-секрет и раскомментируйте
`imagePullSecrets`-патч в kustomization.yaml (Postgres/RabbitMQ публичные — им
pull-секрет не нужен).

### 5. DNS и сеть

- Заведите A-записи доменов на IP сервера: `api.devgate.example.com` (шлюз) и
  `app.devgate.example.com` (фронтенд) — либо один хост с путями.
- В `k8s/gateway/nginx-configmap.yaml` замените dev-имена (`*.devgate.*.local`)
  на реальные домены, а `PUBLIC_GATEWAY_URL` у integration-service — на публичный
  URL шлюза.
- LoadBalancer-сервис шлюза получит IP ноды автоматически (klipper в k3s).
- Файрвол: откройте 80/443 (веб) и 6443 (k8s API, только для себя);
  между нодами k3s дополнительно нужен 8472/udp (flannel vxlan).
- RabbitMQ UI и Postgres наружу не выставляйте — только `kubectl port-forward`.

### 6. Безопасность (обязательно для не-локального кластера)

- Замените все значения в `10-secrets.yaml` (пароль БД, `JWT_SECRET_BASE64`,
  `INTEGRATION_CREDENTIALS_KEY`).
- У user-service выставите `JWT_COOKIE_SECURE=true` (env в `apps/backend/user-service.yaml`),
  если API отдаётся по HTTPS.
- Ограничьте доступ к API-порту 6443 (фаервол/security group).

### 7. HTTPS (кратко)

- **Вариант A**: вернуть Traefik в k3s (убрать `--disable traefik`), выпустить
  сертификаты через cert-manager (Let's Encrypt) и направить IngressRoute на наш
  nginx-шлюз по ClusterIP.
- **Вариант B**: поставить nginx-ingress + cert-manager, Ingress на 443 → `gateway:80`.
- **Вариант C**: внешний терминатор TLS (Cloudflare, LB провайдера) → порт 80 сервера.

## Очистка

```bash
kubectl delete namespace devgate      # удалить приложение
minikube --profile devgate delete     # удалить сам кластер
```

## FAQ

- **Поды в CrashLoopBackOff после первого деплоя** — обычно не хватает памяти.
  Поднимите minikube с `--memory=8192` или уменьшите `resources.limits` в манифестах.
- **502 от шлюза** — апстрим-сервис ещё не Ready (`kubectl -n devgate get pods`); nginx
  резолвит имена в момент запроса и не падает.
- **Секреты** — в `10-secrets.yaml` лежат dev-значения (пароль postgres, JWT-секрет
  из локального .env). Для чего-то, кроме локальной разработки, замените их и не
  коммитьте реальные значения.
- **ImagePullBackOff на удалённом кластере** — либо образ не запушен в registry
  (`kubectl -n devgate describe pod ...` покажет реальную причину), либо registry
  приватный и не настроен `imagePullSecrets`.
- **502/connection refused на удалённом кластере** — проверьте, что порт 80 открыт
  в фаерволе и что шлюз получил External-IP: `kubectl -n devgate get svc gateway`.
- **ERR_PNPM_LOCKFILE_CONFIG_MISMATCH при сборке фронтенда** — версия pnpm в образе
  не совпадает с той, которой сгенерирован lockfile. Обновите `PNPM_VERSION` в
  `k8s/images/frontend.Dockerfile` до локальной (`pnpm --version` в
  `devgate-frontend/src`) и пересоберите.
