# TRACE-001 — Распределённый трейсинг: метрики + логи + трейсы

| Поле | Значение |
|---|---|
| ID | `TRACE-001` |
| Статус | `done` |
| Требования | кейс — «Расширенные мониторинг и логирование»; критерий 3 («качество подхода к observability»); architecture.md §6, §7 |
| Решения | D-11 |
| Зависимости | GW-002, LOG-001, GRAF-001 |
| Блокирует | DEMO-001 (шаг «найти трейс запроса») |

## Цель

Добавить третий столп observability. Envoy Gateway создаёт трейс каждого
входящего запроса и отправляет его по OTLP в Grafana Tempo. В Grafana
из строки лога nginx переходим в трейс этого запроса и обратно: по одному
идентификатору видно путь запроса, его время и связанные логи.

## Scope

### Входит

- **Tempo** (Helm, single binary, хранение на emptyDir, приём OTLP gRPC/HTTP);
- **трейсинг Envoy Gateway:** `EnvoyProxy.spec.telemetry.tracing`, провайдер
  OpenTelemetry → Tempo, sampling 100% (демо-нагрузка небольшая);
- **корреляция:** nginx пишет в access-лог `traceparent` / trace id
  (`$http_traceparent`); в datasource Loki — derived field «TraceID» →
  ссылка в Tempo; в datasource Tempo — переход к логам Loki
  (`tracesToLogs`) по времени и меткам;
- datasource Tempo в Grafana (`additionalDataSources`);
- метрики Tempo в Prometheus (ServiceMonitor);
- `verify.sh`: запрос через Gateway с известным `traceparent` → трейс с этим
  ID находится в Tempo API; в строке Loki есть trace id.

### Не входит

- инструментирование самого приложения (nginx статичный — спаны создаёт
  Envoy, этого достаточно для демонстрации пути через Gateway);
- OpenTelemetry Collector — Envoy отправляет напрямую в Tempo (меньше RAM).
  Если понадобятся процессоры/семплинг — Collector добавляется отдельно.

## Технические требования

| Компонент | Версия |
|---|---|
| Tempo | 3.1.0, чарт `grafana-community/tempo` 3.1.0 (single binary). Чарт `grafana/tempo` помечен deprecated и перенесён в grafana-community |

- Ресурсы: ~0,2–0,3 ГБ RAM.
- Идентификатор: `traceparent` (W3C) пробрасывается Envoy до nginx.

## Артефакты

| Артефакт | Назначение |
|---|---|
| `ansible/roles/tracing/`, `helm-values/tempo.yaml` | Установка Tempo |
| `deploy/gateway/envoyproxy.yaml` | Телеметрия трейсинга |
| `deploy/app/base/nginx.conf` | trace id в access-логе |
| `helm-values/kube-prometheus-stack.yaml` | Datasource Tempo, derived fields Loki |
| `scripts/verify.sh` | Проверки |

## Критерии приёмки

- [x] Запрос через Gateway → трейс в Tempo (поиск по trace id через API).
- [x] В Grafana: строка лога nginx → кнопка перехода в трейс → трейс
      открывается; из трейса — переход к логам.
- [x] Повторный `deploy.sh` → `changed=0`; CI `e2e` зелёный.

## Результат закрытия

Закрыта 02.10.2026.

**Как сделано:**
- Tempo 3.1 (single binary): только приёмник OTLP (gRPC :4317, HTTP :4318),
  данные на emptyDir 2 ГиБ (без PVC чарт ничего не монтирует в `/var/tempo`),
  read-only rootfs, `drop: [ALL]`, хранение 48 ч, ServiceMonitor.
- `EnvoyProxy.spec.telemetry.tracing`: провайдер OpenTelemetry → `tempo.tracing:4317`,
  `samplingRate: 100`, тег `k8s.cluster: devops-case`. Envoy продолжает
  входящий `traceparent` или создаёт трейс сам и передаёт заголовок в backend.
- nginx пишет `traceparent` в JSON access-лог.
- Grafana: datasource Tempo (`tracesToLogsV2` → Loki по trace ID, node
  graph), в datasource Loki — derived field `TraceID` по полю `traceparent`
  (кнопка «Трейс в Tempo» у строки лога).

**Артефакты:** `helm-values/tempo.yaml`, роль `ansible/roles/tracing`,
`deploy/gateway/envoyproxy.yaml` (telemetry), `deploy/app/base/nginx.conf`
(traceparent), `helm-values/kube-prometheus-stack.yaml` (datasources),
раздел «Трейсинг» в `scripts/verify.sh`.

| Проверка | Результат |
|---|---|
| Запрос с известным trace ID через Gateway | трейс найден в Tempo (`/api/v2/traces/<id>` → 200), строка с этим ID — в Loki |
| Обычный запрос без `traceparent` | Envoy создал трейс; в логе nginx `traceparent` `00-d634…-01`; в Tempo спаны `ingress` и `router httproute/demo/hello/rule/1 egress` (код 200, 0,48 мс, тег `k8s.cluster`) |
| Grafana | datasource `tempo` — OK |
| Prometheus | target `tempo` — UP |
| GitOps-релиз | изменение `nginx.conf` в коммите → Argo CD применил через ~50 с → Rollouts сам провёл canary 10→30→60→100% с анализом за 2 мин 15 с |
| Повтор `deploy.sh` | `changed=0` |
| GitHub Actions | [run 37008951094](https://github.com/glev23/devops_case/actions/runs/37008951094): все шаги e2e (включая оба сценария релиза) — зелёные; e2e 12 мин 50 с |

**Отклонения от постановки:**
- Вместо устаревшего чарта `grafana/tempo` (Tempo 2.9) — актуальный
  `grafana-community/tempo` с Tempo 3.1.
- OpenTelemetry Collector не ставился (как и планировалось): Envoy отправляет
  спаны напрямую.
