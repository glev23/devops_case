# ROLLOUT-001 — Автоматический canary-релиз с анализом метрик и откатом

| Поле | Значение |
|---|---|
| ID | `ROLLOUT-001` |
| Статус | `done` |
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

- [x] `make release-good`: веса 10 → 30 → 60 → 100, анализ успешен,
      все ответы — новая версия.
- [x] `make release-bad`: на первом шаге анализ проваливается, Rollout
      `Degraded`, вес canary → 0, ответы — только стабильная версия.
- [x] На дашборде видны изменение долей трафика, всплеск 5xx и аннотации.
- [x] Повторный `deploy.sh` → `changed=0`; Argo CD не воюет с Rollouts.
- [x] CI `e2e` зелёный, включая сценарий отката.

## Результат закрытия

Закрыта 02.10.2026.

**Как сделано:**
- **Rollout из общей базы.** `deploy/app/rollout.yaml` — патч Kustomize со
  `allowKindChange`, превращающий Deployment `hello` из `base` в
  `argoproj.io/v1alpha1 Rollout`; группа API задаётся вторым патчем
  (`allowKindChange` меняет только kind). Цель патча — по метке
  (`labelSelector`), а не по имени: имя сравнивается с исходным из `base`, и
  под фильтр попадал `hello-v2`.
- **Маршрутизация:** правило `/` (`#2`) — `hello: 100`, `hello-canary: 0`;
  веса во время релиза ведёт плагин Gateway API.
- **Анализ:** `AnalysisTemplate gateway-error-rate` — доля 5xx правила `#2`
  (Envoy) за 1 мин < 2%, каждые 15 с после 30 с задержки, `failureLimit: 1`;
  фоновый — с первого шага.
- **Шаги:** 10% → 45 с → 30% → 45 с → 60% → 45 с → 100%.
- **Метрики:** PodMonitor вместо ServiceMonitor (canary-поды не выпадают из
  мониторинга), метки `app.kubernetes.io/version` и
  `rollouts-pod-template-hash` на метриках nginx; панель «доля трафика по
  версиям» и аннотации релизов в Grafana.
- **Argo CD + Rollouts:** для `demo` `selfHeal: false` (релизы для
  демонстрации запускаются командой); `ignoreDifferences` — веса правила `/`
  и селекторы Service `hello`/`hello-canary`; `deploy.sh` явно синхронизирует
  приложение, если оно `OutOfSync`.
- **Команды:** `make release-good | release-bad | release-reset | release-status`
  (`scripts/release.sh`).
- Плагин Gateway API и CLI `kubectl-argo-rollouts` загружаются с проверкой
  SHA-256.

| Проверка | Результат |
|---|---|
| Плохой релиз `v1.2-bad` (стенд) | 12:12:49 — 10% на canary, в выборке ~10% ошибок; 12:13:30 — анализ `Failed`, Rollout `Degraded`, веса 100/0, ошибок 0 — **автооткат за ~40 с** |
| Хороший релиз `v1.1` (стенд) | 10% → 30% → 60% → 100% за 2 мин 20 с; доля новой версии в выборке 2 → 6 → 12 → 20 из 20; анализ `Successful`, ошибок 0 |
| После `reset` | Rollout `Healthy` v1; Application `demo` — `Synced/Healthy`; `verify.sh` — все проверки |
| Метрики по версиям | `nginx_http_requests_total` разделён по `v1`, `v1.1`, `v1.2-bad` |
| Повтор `deploy.sh` | `changed=0` (VM и CI) |
| GitHub Actions | [run 36994620268](https://github.com/glev23/devops_case/actions/runs/36994620268): e2e 11 мин 37 с; плохой релиз в CI: откат в 10:26:21 (анализ Failed, веса 100/0); хороший: после ожидания чистого окна анализа — 100%, анализ Successful |

**Отклонения и находки:**
- **`RespectIgnoreDifferences` убран.** С игнорируемыми весами он подставлял
  живой список `backendRefs` целиком, и Argo CD не добавлял `hello-canary` в
  маршрут (`httproute unchanged`) — плагин падал с «backendRef was not
  found». Без опции `ignoreDifferences` влияет только на сравнение.
- **Ложный `changed` на Application в CI** (два случая): модуль `k8s`
  сравнивал объект целиком, а Argo CD постоянно обновляет `status`; затем
  `group: ""` в `ignoreDifferences` для Service — Argo CD не сохраняет пустое
  поле. Теперь сравнивается только `spec`, `group` для core-ресурсов не
  указывается. Для диагностики во втором прогоне CI включён `--diff`.
- **Окно анализа и подряд идущие релизы:** хороший релиз сразу после
  откатанного плохого проваливал анализ — ошибки плохого ещё были в окне 1 мин
  (CI). `release.sh` перед стартом ждёт, пока доля 5xx за минуту не станет
  < 0,5% (тот же запрос, что в анализе).
- **Автосинхронизация откатывала релиз:** явная синхронизация из `deploy.sh`
  передавала `revision: main`, и Argo CD считал ветку «новой ревизией» по
  сравнению с SHA последней синхронизации — и синхронизировал заново прямо
  во время релиза. Теперь передаётся разрешённый SHA.
- Флаг исполнения `release.sh` не попал в Git (на VM его выставлял скрипт
  синхронизации) — исправлено.
- Анализ считает долю 5xx по правилу целиком (stable + canary): Envoy
  учитывает взвешенные backend одного правила одним upstream-кластером.
  Плохая версия на 10% трафика даёт ~10% 5xx — порог 2% это надёжно ловит.
