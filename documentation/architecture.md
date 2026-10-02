# Архитектура решения — Kubernetes, Gateway API, мониторинг, логирование

> Здесь фиксируется, как требования [кейса](./кейс.md) реализуются
> технически. Пока решение не принято, оно живёт в разделе
> «Открытые решения». При изменениях ничего не удаляем: правим текст и
> записываем существенное в «Историю решений» внизу.

**Статус:** 🟢 стек выбран (ревизия 3, 30.09.2026). Все решения D-01…D-08
приняты. Точные версии компонентов фиксируются в задачах реализации после
сверки с официальными матрицами совместимости и до этого помечены ⚠️.

---

## 1. Обзор и схема

```
                ┌──────────────── Kubernetes (kubeadm, 1 узел, containerd, Calico) ────────────────┐
                │                                                                                  │
 Пользователь ──┼─► NodePort :30080 ─► Envoy (прокси) ◄── Envoy Gateway (контроллер)               │
  curl          │                        │   GatewayClass → Gateway → HTTPRoute                    │
                │                        ▼                                                         │
                │                 Service hello ─► Deployment nginx (Hello World!)                 │
                │                                             │ access-лог JSON в stdout           │
                │     метрики Envoy, nginx-exporter           ▼                                    │
                │               │                  Fluentd (DaemonSet) ─► Loki                     │
                │               ▼                                           │                      │
                │  kube-prometheus-stack: Prometheus ◄── node-exporter,      │                      │
                │                         kube-state-metrics, kubelet/cAdvisor                     │
                │                              │                            │                      │
                │                              └────────► Grafana ◄─────────┘                      │
                │                                (метрики + логи в одном окне)                     │
                └──────────────────────────────────────────────────────────────────────────────────┘
                  Ubuntu 24.04 · make deploy → Ansible → kubeadm + Helm + Kustomize · make verify
```

Для паспорта эта схема перерисовывается картинкой после выбора стека.
Кейс требует показать путь `Пользователь → Gateway API → приложение`, а
также мониторинг и логирование.

---

## 2. Окружение

| Параметр | Значение | Источник требования |
|---|---|---|
| ОС узлов | Ubuntu 24.04 LTS | кейс, п. 6 |
| Где крутится стенд | VM на ПК команды: Multipass поверх Hyper-V, образ Ubuntu 24.04, 4 vCPU / 8 ГБ / 50 ГБ, хранилище `D:\Multipass`, имя `k8s` (D-01) | кейс, п. 1: стенд организаторы не дают |
| Ресурсы стенда | 4 vCPU / 8 ГБ RAM / 50 ГБ диск; фактическое потребление стека фиксируется в QA-001 | — |
| Доступ извне | не требуется: эксперт проверяет у себя по инструкции | кейс, «Условие задачи» |

Рабочая машина команды — Windows 10, поэтому Ubuntu 24.04 поднимается как
отдельная VM. Эксперт повторяет решение на своей Ubuntu 24.04, поэтому
автоматизация стартует с **чистой Ubuntu 24.04**, а Multipass — только наш
способ получить такую машину, в инструкцию он не входит. Снимок «чистая
ОС» используется для прогона с нуля (QA-001).

**Особенность нашего стенда (не часть решения).** Интернет с ПК идёт через
WireGuard в режиме full-tunnel. Чтобы не включался kill-switch, который
блокирует Default Switch, `AllowedIPs` задан как `0.0.0.0/1, 128.0.0.0/1`
вместо `0.0.0.0/0`. MTU туннеля меньше 1500, поэтому крупные пакеты из VM
терялись: TLS к pkgs.k8s.io и реестрам зависал. В VM MTU `eth0` закреплён на
1400 через `/etc/netplan/90-wireguard-mtu.yaml`. Там же DNS `1.1.1.1, 8.8.8.8` вместо
DNS-прокси Default Switch: тот отвечал через раз. IP VM (Default Switch)
меняется после перезапуска, актуальный адрес показывает `multipass info k8s`.
Снимки: `clean-ubuntu-v2` (чистая Ubuntu 24.04.5 + эти сетевые настройки) и
снимок с полным стеком. NTP (UDP 123) через Hyper-V NAT и WireGuard не
проходит, время VM не синхронизируется — горит алерт
`NodeClockNotSynchronising`; на обычной Ubuntu и в CI этого нет.

---

## 3. Kubernetes-кластер

| Параметр | Значение |
|---|---|
| Способ создания | kubeadm (D-02) — приоритет по критерию 1 |
| Версия Kubernetes | **v1.36.5** — пересечение поддержки Calico 3.32 (тестирован на 1.34–1.36) и Envoy Gateway 1.9 (1.33–1.36). Самая новая 1.37.1 пока вне матрицы Calico. Сверено 30.09.2026 по docs.tigera.io и gateway.envoyproxy.io/news/releases/matrix |
| Container runtime | containerd (D-02) |
| CNI | Calico **v3.32.2** (D-02b): NetworkPolicy, MTU определяется автоматически по интерфейсу узла; pod CIDR `10.244.0.0/16` задаётся явно, чтобы не пересечься с сетью узла |
| Количество узлов | один: control plane с отключённым taint для обычных подов (D-02) |
| Адрес узла | стабильный `10.200.0.10/32` на dummy-интерфейсе `k8s0` (systemd-networkd): его используют API server (`advertiseAddress`, `controlPlaneEndpoint`), kubelet (`node-ip`) и Calico. Внешний доступ — по любому IP узла, NodePort слушает на всех адресах. Отключается через `node_stable_ip: ""` |
| Доступ к Service типа LoadBalancer | не используется: прокси Envoy публикуется через NodePort (D-03) |

Требования кейса к README: версия Kubernetes, способ создания кластера, ОС
тестирования, список всех дополнительных компонентов со способом установки.

---

## 4. Демонстрационное приложение

| Требование кейса (п. 2) | Как закрывается |
|---|---|
| Принимает HTTP | nginx, официальный публичный образ (D-04) |
| Однозначно проверяемый ответ | `Hello World! from $hostname` (`text/plain`): имя пода показывает балансировку и traffic splitting |
| Access-логи, доступные для сбора | access-лог nginx в **JSON** в stdout, error-лог в stderr; Fluentd читает `/var/log/containers/*.log` |
| Публичный image или материалы сборки | официальный публичный образ + конфиг через ConfigMap; своя сборка не нужна |

Собственное приложение не пишем: кейс прямо говорит, что это не даёт баллов.
Метрики самого nginx отдаёт sidecar `nginx-prometheus-exporter` через
`stub_status` (MON-001).

---

## 5. Gateway API

| Параметр | Значение |
|---|---|
| Реализация и версия | Envoy Gateway **v1.9.x** (D-03; последний патч фиксируется в GW-001), Envoy Proxy 1.39, Gateway API v1.6.1 |
| Версия CRD Gateway API | та, что поставляется Helm-чартом Envoy Gateway (совместимость гарантирует проект) |
| Ресурсы (минимум) | `GatewayClass`, `Gateway`, `HTTPRoute` → `Service` приложения |
| Как трафик попадает на Gateway | Service прокси Envoy типа **NodePort** с фиксированными портами `30080` (HTTP) и `30443` (HTTPS, GW-002) через ресурс `EnvoyProxy` |
| Проверка | `curl http://<IP узла>:30080/` → `Hello World! from <pod>` (точная команда — в GW-001) |

Маршрутизация по hostname (GRAF-001): `grafana.devops.test` → Grafana,
`prometheus.devops.test` → Prometheus UI, любой другой Host → приложение
(маршрут без `hostnames`). Проверка — `curl -H "Host: …"`, без внешнего DNS;
домен `.test` зарезервирован RFC 2606.

Расширенные возможности (GW-002, сделано): `/v2` → `hello-v2` с
`URLRewrite`; `/canary` → веса 80/20 между `hello` и `hello-v2`;
`ResponseHeaderModifier` (`X-Backend`, `X-Route`); `/error` → 500; HTTPS-
listener `:443` → NodePort 30443, сертификат `*.devops.test` от cert-manager
v1.21.2 через собственную цепочку CA (`selfsigned` → `devops-ca` →
`devops-test-tls`), проверка клиентом по `ca.crt` без `-k`. Маршруты
подключены к обоим listener. Подробности — tasks/gw-002.md.

Политики трафика (GW-003): `BackendTrafficPolicy demo/hello` — таймауты
(запрос 5 с, подключение 2 с), ретраи только на сетевые сбои, circuit
breaker, local rate limit 5 запросов/с на `/limited` → 429;
`ClientTrafficPolicy gateway/main` — таймауты клиента, лимит соединений,
отклонение заголовков с `_`, сохранение `X-Request-Id`. `/error` вынесен в
отдельное правило (`#3`), чтобы намеренные 500 не портили SLI.

Прогрессивная доставка (ROLLOUT-001): Argo Rollouts v1.10.0 + плагин
Gateway API v0.17.0. `hello` — Rollout: canary 10 → 30 → 60 → 100% через
веса правила `/` (`hello` / `hello-canary`), фоновый анализ доли 5xx в
Prometheus (< 2%), при провале — автоматический откат. `make release-good`,
`make release-bad`, `make release-reset`.

Исходный план GW-002: маршруты по path, два backend `v1`/`v2`
с весами 80/20, маршрут, отвечающий 500 (для графика кодов), TLS-listener с
сертификатом от cert-manager (self-signed `ClusterIssuer`, ключи не попадают
в репозиторий). MetalLB вместо NodePort — только если останется время.

---

## 6. Мониторинг

| Параметр | Значение |
|---|---|
| Способ развёртывания Prometheus | Helm-чарт **kube-prometheus-stack 91.8.2** (D-05; Prometheus Operator v0.94.1): Prometheus, Alertmanager, node-exporter, kube-state-metrics, Grafana 13.2.3. Values — `helm-values/kube-prometheus-stack.yaml` |
| Обязательный минимум | хотя бы один target в состоянии `UP` + PromQL-запрос, который возвращает данные |
| Targets | 14 jobs, все `UP`: apiserver, kubelet/cAdvisor, node-exporter, kube-state-metrics, coredns, kube-controller-manager, kube-scheduler, kube-etcd, kube-proxy, компоненты стека, **hello** (nginx-exporter 1.5.3, ServiceMonitor). Метрики control plane kubeadm привязаны к адресу узла `10.200.0.10` (по умолчанию — `127.0.0.1`, и targets были бы DOWN). Envoy — MON-002 |
| HTTP-метрики Gateway (MON-002) | PodMonitor прокси Envoy (`/stats/prometheus`), метка `route` из правила HTTPRoute; ServiceMonitor контроллера Envoy Gateway |
| Алерты (MON-002) | `PrometheusRule devops-case`: приложение (targets, реплики), Gateway (5xx > 10%, p95 > 500 мс, прокси), Fluentd, Loki; recording rules по маршрутам |
| Дашборд (MON-002) | «DevOps case / Gateway и приложение» — JSON в `deploy/monitoring/dashboards/`, ConfigMap с `grafana_dashboard: "1"` |
| Фоновая нагрузка | `demo/loadgen`: ~4 запроса/с через Gateway, графики живые сразу после установки |
| Трейсинг (TRACE-001) | Envoy Gateway → OTLP → Grafana Tempo 3.1 (`tracing/tempo`), sampling 100%; `traceparent` в логе nginx; в Grafana лог ↔ трейс (derived field Loki, `tracesToLogsV2` Tempo) |
| SLO (SLO-001) | SLI — доля не-5xx по правилам `/canary`, `/v2`, `/` (Envoy); SLO 99,9%, бюджет 0,1% за 3 дня; burn-rate алерты 14,4× (1 ч + 5 мин) и 6× (6 ч + 30 мин); дашборд «SLO доступности» |
| Хранение | emptyDir, retention 3 дня / 4 ГБ: в кластере нет StorageClass |
| Grafana | пароль admin случайный, создаётся один раз в Secret `monitoring/grafana-admin`; пароль чарта по умолчанию не работает |
| Проверка | `/targets` в Prometheus + конкретные PromQL-запросы с ожидаемым результатом (MON-001) |

Плюсом по кейсу считаются HTTP-метрики (количество запросов, коды ответов,
latency), CPU/RAM и дашборды. CPU/RAM и дашборды кластера приходят вместе с
чартом. HTTP-метрики берём из Envoy. Свой дашборд лежит в репозитории как JSON
и подгружается в Grafana через ConfigMap (MON-002). Там же — свои правила
алертов (`PrometheusRule`).

---

## 7. Логирование

| Параметр | Значение |
|---|---|
| Коллектор | **Fluentd** (D-06) — именно Fluentd, не Fluent Bit: кейс называет Fluentd или Filebeat |
| Способ запуска | DaemonSet `logging/fluentd`, образ `grafana/fluent-plugin-loki:3.7.8` (Fluentd 1.19.0 + `out_loki`): читает `/var/log/containers/*.log` (CRI), метки `namespace`/`pod`/`container`/`stream` берёт из имени файла, JSON nginx разбирает в поля, буфер — на диске узла (`/var/log/fluentd`) |
| Хранилище / точка назначения | **Loki 3.6.11** (чарт `grafana/loki` 7.3.0), single binary, файловая система на emptyDir, retention 72 ч; `http://loki.logging:3100`. Просмотр — Grafana (GRAF-001) и LogQL API |
| Какие логи | все контейнеры кластера (централизованное хранение); access-лог nginx — разобранный JSON, error-лог — stderr |
| Проверка | `verify.sh`: запрос `?trace=<uuid>` через Gateway → LogQL `{namespace="demo",container="nginx"} \|= "<uuid>" \| json \| status="200"` |

Проверку с уникальной меткой заложить сразу: кейс требует показать, что
*именно этот* запрос появился в логах, а не просто что логи есть.

---

## 8. Автоматизация развёртывания

| Требование кейса (п. 7) | Как закрывается |
|---|---|
| Без ручного создания Kubernetes-ресурсов | весь кластерный стек ставится кодом из репозитория |
| Повторный запуск не ломает систему | Ansible (идемпотентные модули; `kubeadm init` — только если нет `/etc/kubernetes/admin.conf`), `helm upgrade --install`, `kubectl apply -k`. Доказательство — `changed=0` при повторном прогоне (D-07) |
| Минимум понятных команд | цель: `make deploy` (или `./deploy.sh`) + `make verify` |
| Версии зафиксированы | все версии чартов, образов и CRD прописаны явно, `latest` не используется |

**Доставка манифестов (CD-001).** `deploy.sh` ставит платформу (Helm-чарты,
секреты), а каталоги `deploy/gateway`, `deploy/monitoring`, `deploy/logging`,
`deploy/app` доставляет Argo CD: по `Application` на каталог, источник —
этот репозиторий (`gitops_repo_url`, `gitops_revision`, по умолчанию `main`),
`automated` + `prune` + `selfHeal`. Push в `main` → кластер обновляется сам
примерно за минуту, без входящих подключений. В CI — синхронизация с SHA
проверяемого коммита. Запасной режим `gitops_enabled: false` — применение из
локальной копии.

Применение наших манифестов без GitOps — общая роль `kustomize`: `kubectl diff`
(серверный dry-run) → `kubectl apply` только при различиях; так признак
изменения в Ansible честный (SEC-001).

Инструменты (D-07): **Makefile** — точка входа; **Ansible** — подготовка
узла, kubeadm, установка чартов; **Helm** — сторонние компоненты с
закреплёнными версиями чартов; **Kustomize** — наши ресурсы (приложение,
Gateway, маршруты, мониторы). Если Ansible не установлен, `make deploy`
ставит его первым шагом. Playbook запускается на самом узле
(`connection: local`); inventory для удалённого узла — опционально.

Переустановка: `sudo ./destroy.sh` (`ansible/destroy.yml`) удаляет кластер
и состояние решения, оставляя пакеты и образы. Удалённый узел: хост в
`ansible/inventory.ini` — файлы копируются в `/opt/devops-case` (AUTO-001).

Что покрывает одна команда `make deploy`:

1. подготовка узла Ubuntu 24.04 (пакеты, sysctl, swap, runtime);
2. создание кластера (`kubeadm init` / join, CNI);
3. установка платформы (Gateway-контроллер, Prometheus, логирование);
4. деплой приложения и маршрутов;
5. проверка (smoke: curl, PromQL, поиск в логах).

---

## 9. Структура репозитория

```
README.md              — инструкция для эксперта (DOCS-002)
Makefile               — deploy, verify, destroy, lint
ansible/               — playbook и роли: node (ОС, containerd), kubeadm, cni, platform
  group_vars/all.yml   — все версии в одном месте
deploy/                — Kustomize: наши ресурсы
  app/  gateway/  monitoring/  logging/
helm-values/           — values для сторонних чартов
scripts/               — verify.sh (smoke: curl, PromQL, поиск в Loki)
.github/workflows/     — CI (CI-001)
documentation/         — эта документация
```

Раскладка уточняется в AUTO-001, изменения фиксируются в «Истории решений».

---

## 10. Безопасность и надёжность

Сводка реализованных мер (для README и паспорта):

| Область | Меры |
|---|---|
| Секреты | в репозитории нет паролей, ключей, токенов; пароли Grafana и Prometheus генерируются при установке (24 символа) и живут только в Secret; ключи TLS выпускает cert-manager в кластере; gitleaks по всей истории git в CI |
| Доступ | Grafana — логин; Prometheus через Gateway — basic auth (`SecurityPolicy`); маршруты к Gateway — только из namespace с меткой `gateway-access` |
| Сеть | NetworkPolicy в `demo`: default deny ingress, к nginx — только прокси Envoy и `demo`, к экспортеру — только `monitoring`; метрики control plane — на внутреннем адресе узла |
| Транспорт | HTTPS на Gateway, собственная цепочка CA, клиент проверяет сертификат |
| Контейнеры | non-root (nginx 101, loadgen 101), read-only rootfs, `drop: [ALL]`, seccomp `RuntimeDefault`, без токена ServiceAccount, requests/limits, liveness/readiness probes |
| Входящий трафик | таймауты, лимит соединений, rate limit → 429, отклонение заголовков с `_`, `X-Forwarded-For` клиента не доверяется (GW-003) |
| Доступность | 2 реплики + PodDisruptionBudget `minAvailable: 1`; ретраи на сетевые сбои, circuit breaker |
| Цепочка поставки | закреплённые версии всех образов, чартов и пакетов (`apt-mark hold`); официальные публичные образы |

Не сделано (ограничения): Fluentd работает от root (файлы логов узла);
basic auth Envoy поддерживает только `{SHA}`; mTLS между сервисами нет;
исходящий трафик подов не ограничен.

---

## 11. CI/CD (по желанию)

GitHub Actions (D-08), `.github/workflows/ci.yml`, на каждый push в `main` и
pull request:

| Job | Что делает |
|---|---|
| `lint` | yamllint `--strict`, ansible-lint (профиль `production`), shellcheck, `kubectl kustomize` + kubeconform для `deploy/*` |
| `secrets` | gitleaks по всей истории git (критерий 4) |
| `e2e` | GitHub-раннер `ubuntu-24.04` приводится к чистой Ubuntu (`ci/prepare-runner.sh`), затем **тот же `sudo ./deploy.sh`, что у эксперта**: kubeadm с нуля → повторный запуск (job падает, если `changed` ≠ 0) → `scripts/verify.sh` |

**CD.** Две части: `e2e` разворачивает каждый коммит в эфемерное окружение и
проверяет его; доставку в работающий кластер выполняет Argo CD по
pull-модели (CD-001) — кластер сам забирает изменения из Git, поэтому стенд
за NAT и VPN не нужен ни публичный адрес, ни self-hosted runner.

---

## 12. Известные ограничения

Этот раздел попадает в README как «известные ограничения решения»
(обязательный пункт кейса). Пополняется по ходу работы.

- Один узел: нет отказоустойчивости ни control plane, ни рабочих узлов.
- Первая установка занимает около 14 минут на VM 4 vCPU / 8 ГБ; основное
  время уходит на загрузку пакетов и образов и зависит от канала.
- Нужен доступ в интернет к pkgs.k8s.io, registry.k8s.io, docker.io,
  github.com, get.helm.sh; офлайн-установка не поддерживается.
- Пул IP подов Calico задаётся при первой установке; смена `pod_cidr` на
  существующем кластере не поддерживается, нужна переустановка.
- Трейсы Tempo — на emptyDir, хранение 48 ч; sampling 100% подходит для
  демонстрационной нагрузки, для продакшена нужна выборка.
- Окно бюджета ошибок SLO — 3 дня (retention Prometheus), а не классические
  30 дней: для 30 дней нужно постоянное хранилище.
- Метрики Prometheus и логи Loki хранятся в emptyDir: при пересоздании пода
  история теряется (нет StorageClass; для продакшена нужен PV).
- Fluentd работает от root (uid 0) — файлы логов контейнеров принадлежат root;
  capabilities сброшены, повышение привилегий запрещено.
- Для браузера нужны записи в hosts: `<IP> grafana.devops.test
  prometheus.devops.test`; в Firefox с DNS-over-HTTPS — исключение для
  `devops.test`.
- Basic auth Envoy поддерживает только хэш `{SHA}` — компенсируется
  случайным паролем из 24 символов.
- Настройки kubeadm (включая адреса метрик control plane) применяются только
  при создании кластера; на уже созданном кластере их изменение не
  применяется повторным `deploy.sh`.

---

## Открытые решения

Все решения приняты (ревизия 3). Таблица остаётся реестром: новое решение
добавляется сюда со статусом ⚠️, после выбора переносится в разделы выше и в
«Историю решений».

| ID | Вопрос | Кандидаты | Что влияет на выбор | Статус |
|---|---|---|---|---|
| D-01 | Где крутится стенд Ubuntu 24.04 | VM на рабочей машине (Hyper-V / VirtualBox / VMware), облачная VM, WSL2 | критерий 1 (kubeadm нужен полноценный systemd и сеть), ресурсы рабочей машины, повторяемость у эксперта | ✅ Multipass + Hyper-V на ПК |
| D-02 | Способ создания кластера, runtime, число узлов | kubeadm (приоритет), kind, minikube, k3d; runtime — containerd | критерий 1 прямо даёт баллы за kubeadm; сложность автоматизации bootstrap | ✅ kubeadm, containerd, один узел |
| D-02b | CNI | Calico, Cilium, Flannel | NetworkPolicy для SEC-001; Cilium может закрыть и D-03 | ✅ Calico |
| D-03 | Реализация Gateway API и способ вывода трафика | Envoy Gateway, NGINX Gateway Fabric, Istio, Cilium, Traefik, Kong, kgateway; MetalLB / NodePort | зрелость поддержки Gateway API, TLS и traffic splitting из коробки, метрики для Prometheus, связь с выбором CNI | ✅ Envoy Gateway + NodePort |
| D-04 | Демонстрационное приложение | Nginx, Angie, Apache httpd | формат access-логов, наличие exporter для метрик | ✅ nginx |
| D-05 | Способ развёртывания Prometheus | kube-prometheus-stack (Helm), Prometheus Operator, чистый Prometheus (Helm/манифесты) | ServiceMonitor, готовые метрики кластера и Grafana против объёма и ресурсов | ✅ kube-prometheus-stack |
| D-06 | Коллектор логов и хранилище | Fluentd / Fluent Bit + Fluentd / Filebeat; Loki, Elasticsearch/OpenSearch, файл/stdout | кейс разрешает только Fluentd или Filebeat; ресурсы хранилища; удобство поиска для эксперта | ✅ Fluentd → Loki → Grafana |
| D-07 | Инструмент автоматизации | Makefile + shell, Ansible, Helmfile, Terraform, Kustomize | идемпотентность, число команд у эксперта, покрытие bootstrap узла | ✅ Makefile + Ansible + Helm + Kustomize |
| D-08 | CI/CD | GitHub Actions, GitLab CI, без CI | где будет лежать репозиторий, время до дедлайна | ✅ GitHub Actions |
| D-09 | CD в кластер | push через self-hosted runner, GitOps (Argo CD, Flux) | стенд за NAT/VPN, безопасность публичного репозитория, UI для демонстрации | ✅ Argo CD (pull), план — CD-001 |
| D-10 | Прогрессивная доставка | Argo Rollouts + плагин Gateway API, Flagger, ручные веса | работа с Gateway API, анализ по Prometheus, сочетание с Argo CD | ✅ Argo Rollouts, план — ROLLOUT-001 |
| D-11 | Трейсинг | Tempo, Jaeger; через OTel Collector или напрямую | одна Grafana для всего, RAM | ✅ Tempo, OTLP напрямую от Envoy, план — TRACE-001 |
| D-12 | SLO | Sloth, Pyrra, правила вручную | прозрачность для эксперта, без лишних компонентов | ✅ правила вручную, план — SLO-001 |

---

## История решений

**[01.10.2026] Второй пакет дополнительных возможностей (D-09…D-12).** База готова за первый день, до
дедлайна 3,5 дня — запланированы дополнительные возможности, усиливающие
критерии 1, 3 и 5. Отбор: каждая возможность воспроизводится
у эксперта той же командой, проверяется в `verify.sh` и CI, укладывается в
8 ГБ RAM (сейчас занято ~3,5–4 ГБ, добавится ~1–1,5 ГБ).
- **D-09 Argo CD:** pull-модель снимает причину, по которой CD на стенд был
  отклонён в CI-001 (нет входящих подключений). Режим без GitOps
  (`gitops_enabled: false`) сохраняется.
- **D-10 Argo Rollouts:** canary поверх тех же весов Gateway API, анализ по
  Prometheus, естественно сочетается с Argo CD. Flagger тоже умеет Gateway
  API, но с Argo CD в одной экосистеме проще разрешить конфликт владения
  весами (`ignoreDifferences`).
- **D-11 Tempo, OTLP напрямую:** без OTel Collector — меньше RAM; Grafana
  уже есть.
- **D-12 SLO правилами вручную:** эксперт видит все формулы, нет лишнего
  компонента.
- Отклонено: многоузловой кластер (риск для воспроизводимости, CI не
  проверит), уведомления в Telegram (нужен токен, эксперт не проверит).

**[30.09.2026] CI: полный kubeadm на GitHub-раннере вместо kind.** Раннер
`ubuntu-24.04` — это полноценная VM с sudo, поэтому `e2e` гоняет весь
`deploy.sh` с нуля. Это автоматически подтверждает сразу три критерия:
воспроизводимость, идемпотентность и работу на Ubuntu 24.04. kind проверил
бы только Kubernetes-слой. Раннер перед запуском очищается от Docker и его
containerd: он конфликтует с пакетом `containerd` из Ubuntu. Заодно
`deploy.sh` теперь всегда берёт Ansible из репозитория Ubuntu (детерминированный
набор коллекций), а репозиторий Kubernetes подключается через
`deb822_repository` (файл перезаписывается, а не дописывается).

**[30.09.2026] Стабильный адрес узла.** На первом прогоне CLUSTER-001
кластер переставал работать после перезагрузки VM: Default Switch выдал
новый IP по DHCP, а kubeadm вшивает адрес узла в сертификаты API-сервера и
kubeconfig. Та же ситуация возможна у эксперта на любой VM с DHCP. Решение:
адрес `10.200.0.10/32` на dummy-интерфейсе, к нему привязаны kubeadm,
kubelet и Calico. Отвергнуто: статический IP в netplan (подсеть Default
Switch меняется после перезагрузки Windows) и перевыпуск сертификатов при
смене IP (хрупко). Диапазон `10.200.0.0/24` не пересекается с подами
(`10.244.0.0/16`) и сервисами (`10.96.0.0/12`).

**[30.09.2026] Ревизия 3 — выбран весь стек; критерий выбора — максимум баллов.**
- **D-02b Calico.** NetworkPolicy открывает бонус по безопасности
  (критерий 4). Flannel её не поддерживает, Cilium без роли Gateway избыточен.
- **D-03 Envoy Gateway + NodePort.** Реализация создана специально под
  Gateway API: веса, TLS, host/path задаются стандартными полями `HTTPRoute`.
  Метрики Envoy по маршрутам закрывают бонус «HTTP-метрики, коды, latency».
  NGINX Gateway Fabric отвергнут из-за более бедных метрик, Istio избыточен,
  у Cilium один компонент отвечает и за сеть, и за вход — выше риск. NodePort
  вместо MetalLB: подсеть эксперта неизвестна, а воспроизводимость стоит
  25 баллов.
- **D-05 kube-prometheus-stack.** Одним чартом: Operator, node-exporter
  (CPU/RAM), kube-state-metrics, Grafana с дашбордами, Alertmanager.
- **D-06 Fluentd → Loki.** Filebeat не умеет писать в Loki, а
  Elasticsearch/OpenSearch (JVM, 2+ ГБ) тесно на 8 ГБ рядом с Prometheus.
  Loki лёгкий и даёт одно окно Grafana для метрик и логов. Fluent Bit не
  берём: кейс называет Fluentd.
- **D-07 Makefile + Ansible + Helm + Kustomize.** Ansible покрывает подготовку
  ОС и kubeadm, идемпотентность видна по `changed=0` на повторном прогоне.
  Эксперту достаточно `make deploy`.
- **D-08 GitHub Actions.** Линты, валидация, поиск секретов, smoke в kind
  (уточнено 30.09: вместо kind — полный kubeadm на раннере, см. ниже).
- **Стенд.** Для работы через WireGuard `AllowedIPs` заменён на
  `0.0.0.0/1, 128.0.0.0/1` (без kill-switch), в VM выставлен MTU 1400 (§2).

**[30.09.2026] Ревизия 2 — стенд, кластер, приложение.**
- **D-01.** Стенд — VM на ПК команды (Multipass + Hyper-V), а не рабочая VM
  в Yandex Cloud. Ресурсов там хватало (12 vCPU, ~20 ГБ свободной RAM), но на
  ней крутятся 37 рабочих контейнеров. kubeadm потребовал бы включить CRI в
  общем containerd с его перезапуском, выключить swap и менять iptables
  рядом с Docker. Порты 80/443 заняты, вложенная виртуализация недоступна.
  WSL2 отвергнут, потому что это не «чистая Ubuntu» с обычной сетью.
- **D-02.** kubeadm на одном узле с containerd: полные баллы по критерию 1 и
  самый короткий путь повторения у эксперта. kind оставлен для CI.
- **D-04.** nginx из официального образа. Ответ — текст
  `Hello World! from $hostname`, без HTML: проверяется одной командой `curl`,
  а имя пода показывает балансировку. Access-лог — в JSON в stdout.

**[30.09.2026] Ревизия 1 — каркас архитектуры.** Разделы выстроены по
обязательным пунктам кейса и требованиям к README. Стек не выбран. Открытые
решения D-01…D-08 вынесены в таблицу, чтобы разобрать их вместе.
