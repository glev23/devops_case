# ROLLOUT-001 — Автоматический canary-релиз с анализом метрик и откатом

| Поле | Значение |
|---|---|
| ID | `ROLLOUT-001` |
| Статус | `ready` |
| Требования | кейс — «Расширенные возможности Gateway API: traffic splitting», «CI/CD: развёртывание»; критерии 1, 3, 5; architecture.md §5, §8 |
| Решения | D-03, D-05, D-10 |
| Зависимости | CD-001, SLO-001, GW-003 |
| Блокирует | DEMO-001 |

## Цель

Главная демонстрация решения: новая версия приложения выкатывается
**постепенно** — доля трафика на неё растёт шагами через веса Gateway API,
а Prometheus на каждом шаге проверяет долю ошибок. Хорошая версия доходит
до 100%, плохая **автоматически откатывается** без участия человека. Всё
видно на дашборде: веса, коды ответов, момент отката.

## Архитектура

- **Argo Rollouts** + плагин **Gateway API** (`rollouts-plugin-trafficrouter-gatewayapi`):
  контроллер меняет `weight` у `backendRefs` в `HTTPRoute`.
- `Rollout hello` управляет основным приложением (v1). Варианты:
  `workloadRef` на существующий `Deployment hello` или перевод на
  `Rollout` с тем же шаблоном — выбрать при реализации (селектор
  `Deployment` неизменяем, учесть переход на уже работающем кластере).
- Два Service: `hello` (stable) и `hello-canary`; правило `/` в
  `HTTPRoute demo/hello` содержит оба backend, веса ведёт плагин.
- **Шаги:** 10% → пауза/анализ → 30% → анализ → 60% → анализ → 100%.
- **AnalysisTemplate (Prometheus):** доля 5xx правила `/` (SLI из SLO-001)
  за 1 мин < 2%; нужен трафик — его даёт `loadgen`.
- **Версии для демонстрации:** различаются конфигом nginx (ответ
  `Hello World! … version=<v>`). «Плохая» версия отдаёт 500 на `/`
  (полностью или для доли запросов через `split_clients`).
- **Argo CD:** `ignoreDifferences` для `weight` в `HTTPRoute` (их меняет
  Rollouts) и для полей, которые меняет демонстрация; для приложения
  `selfHeal` выключен или исключение — иначе Argo CD откатит ручной
  запуск релиза. Решение зафиксировать в «Истории решений».
- **Команды:** `make release-good`, `make release-bad`, `make release-reset`
  (`scripts/release.sh`) — меняют версию приложения и показывают ход
  релиза (`kubectl argo rollouts get rollout hello --watch` или
  собственный вывод весов и результатов анализа).
- Аннотации в Grafana на старт/успех/откат релиза (через API Grafana).

## Scope

### Входит

- Helm-чарт Argo Rollouts с плагином Gateway API, RBAC плагина на HTTPRoute;
- `Rollout`, `AnalysisTemplate`, Service `hello-canary`, изменения HTTPRoute;
- `scripts/release.sh`, цели `make`;
- панель на дашборде: веса stable/canary во времени (метрики Rollouts или
  envoy по backend), аннотации релизов;
- метрики контроллера Rollouts в Prometheus;
- `verify.sh`: `Rollout` Healthy, AnalysisTemplate на месте; e2e-сценарий
  «плохой релиз откатывается» — в CI отдельным шагом (`release-bad` →
  ожидание `Degraded/Aborted` → `release-reset`).

### Не входит

- blue-green; header-based canary (можно как бонус, если плагин позволяет);
- автоматический релиз по новому образу.

## Технические требования

| Компонент | Версия |
|---|---|
| Argo Rollouts | v1.10.0 (чарт `argo/argo-rollouts` 2.43.2) |
| Gateway API plugin | v0.17.0 ⚠️ сверить совместимость с Rollouts 1.10 и Gateway API v1.6 |

- Анализ не должен ложно срабатывать от фонового `/error` — поэтому GW-003
  выделяет `/error` в отдельное правило.
- Ретраи Gateway не должны маскировать 5xx (GW-003: ретраи только на
  сетевые сбои).
- Время полного релиза для демонстрации — 3–5 минут.

## Артефакты

| Артефакт | Назначение |
|---|---|
| `ansible/roles/rollouts/`, `helm-values/argo-rollouts.yaml` | Установка |
| `deploy/app/rollout.yaml`, `analysis.yaml`, `service-canary.yaml` | Ресурсы релиза |
| `deploy/app/httproute.yaml` | Backend canary в правиле `/` |
| `scripts/release.sh`, `Makefile` | Запуск релизов |
| `.github/workflows/ci.yml` | Шаг «плохой релиз откатывается» |

## Критерии приёмки

- [ ] `make release-good`: веса 10 → 30 → 60 → 100, анализ успешен,
      все ответы — новая версия.
- [ ] `make release-bad`: на первом шаге анализ проваливается, Rollout
      `Degraded`, вес canary → 0, ответы — только стабильная версия.
- [ ] На дашборде видны изменение долей трафика, всплеск 5xx и аннотации.
- [ ] Повторный `deploy.sh` → `changed=0`; Argo CD не воюет с Rollouts.
- [ ] CI `e2e` зелёный, включая сценарий отката.

## Результат закрытия

Заполняется после выполнения.
