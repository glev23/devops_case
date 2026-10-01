# TRACE-001 — Распределённый трейсинг: метрики + логи + трейсы

| Поле | Значение |
|---|---|
| ID | `TRACE-001` |
| Статус | `planned` |
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
| Tempo | чарт `grafana/tempo` 1.24.4 (Tempo 2.9.0) ⚠️ последний релиз Tempo — v3.1.0, чарт отстаёт; сверить актуальный способ установки single binary |

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

- [ ] Запрос через Gateway → трейс в Tempo (поиск по trace id через API).
- [ ] В Grafana: строка лога nginx → кнопка перехода в трейс → трейс
      открывается; из трейса — переход к логам.
- [ ] Повторный `deploy.sh` → `changed=0`; CI `e2e` зелёный.

## Результат закрытия

Заполняется после выполнения.
