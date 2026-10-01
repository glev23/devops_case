# GRAF-001 — Grafana: метрики и логи в одном окне, доступ через Gateway

| Поле | Значение |
|---|---|
| ID | `GRAF-001` |
| Статус | `done` |
| Требования | кейс — «Расширенные мониторинг и логирование: dashboards, централизованный поиск логов»; «Расширенные возможности Gateway API: маршрутизация по hostname»; architecture.md §5–§7 |
| Решения | D-03, D-05, D-06 |
| Зависимости | MON-001, LOG-001, GW-001 |
| Блокирует | MON-002 (свой дашборд), DOCS-002 |

## Цель

Эксперт открывает Grafana через тот же Gateway, что и приложение, и видит
там дашборды кластера (из MON-001), а в Explore — логи из Loki. Prometheus
UI тоже доступен через Gateway. Маршрутизация по hostname демонстрирует
расширенные возможности Gateway API.

## Scope

### Входит

- datasource Loki в Grafana (`additionalDataSources` kube-prometheus-stack);
- `HTTPRoute` по hostname на Gateway `main`: `grafana.devops.test` →
  Grafana, `prometheus.devops.test` → Prometheus; маршрут приложения без
  hostnames остаётся маршрутом по умолчанию;
- метка `gateway-access: "true"` на namespace `monitoring`;
- `grafana.ini`: `domain`/`root_url` под адрес Gateway, отключены
  телеметрия и проверка обновлений;
- раздел «Grafana и маршрутизация по hostname» в `scripts/verify.sh`.

### Не входит

- свой дашборд HTTP-метрик Envoy (MON-002);
- TLS и аутентификация перед Prometheus (GW-002, SEC-001).

## Артефакты

| Артефакт | Назначение |
|---|---|
| `helm-values/kube-prometheus-stack.yaml` | `grafana.ini`, `additionalDataSources` |
| `deploy/monitoring/httproutes.yaml`, `kustomization.yaml` | Маршруты Grafana и Prometheus |
| `ansible/roles/monitoring/tasks/main.yml` | Метка namespace, применение маршрутов |
| `scripts/verify.sh` | Проверки |

## Критерии приёмки

- [x] `Host: grafana.devops.test` → Grafana, `Host: prometheus.devops.test` →
      Prometheus, любой другой Host → приложение.
- [x] Health-check datasource в Grafana: `prometheus` — OK, `loki` — OK.
- [x] Доступно с ПК команды (вне VM).
- [x] Повторный `deploy.sh` → `changed=0`.
- [x] CI `e2e` зелёный.

## Проверка

```bash
make verify
curl -s -H "Host: grafana.devops.test" http://<IP узла>:30080/api/health
curl -s -H "Host: prometheus.devops.test" http://<IP узла>:30080/-/ready
```

В браузере — добавить в hosts (`/etc/hosts` или
`C:\Windows\System32\drivers\etc\hosts`) строку
`<IP узла> grafana.devops.test prometheus.devops.test` и открыть
`http://grafana.devops.test:30080` (логин `admin`, пароль —
`kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d`).

## Результат закрытия

Закрыта 01.10.2026.

| Проверка | Результат |
|---|---|
| `deploy.sh` на VM | `changed=3` (метка namespace, values чарта, маршруты), повтор — `changed=0` |
| `verify.sh` на VM | 20/20, включая datasource prometheus/loki — OK |
| С Windows-ПК | `api/health` → `database: ok`, `/login` → 200; Prometheus `/-/ready` → `Prometheus Server is Ready.`; без Host → `Hello World!` |
| GitHub Actions | [run 36849470455](https://github.com/glev23/devops_case/actions/runs/36849470455): lint, secrets, e2e — зелёные; e2e 5 мин 57 с |

**Отклонения от постановки:** нет. Маршрутизация по hostname — часть GW-002,
в GW-002 остаются path, несколько backend с весами и TLS.

**Ограничение:** Prometheus UI доступен через Gateway без аутентификации
(у Grafana — логин). Защита — кандидат в SEC-001 (basic auth через
`SecurityPolicy` Envoy Gateway).
