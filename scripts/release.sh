#!/usr/bin/env bash
# Демонстрационный canary-релиз приложения hello через Argo Rollouts (ROLLOUT-001).
#
#   ./scripts/release.sh good     # новая версия v1.1 — проходит анализ, доходит до 100%
#   ./scripts/release.sh bad      # версия v1.2-bad отвечает 500 — анализ проваливается, автооткат
#   ./scripts/release.sh reset    # вернуть версию из Git (v1)
#   ./scripts/release.sh status   # состояние Rollout
#
# Версии отличаются только конфигом nginx (ConfigMap hello-release-<версия>),
# образ тот же. Во время релиза каждые 5 с печатаются фаза, шаг, веса в
# HTTPRoute, статус анализа и выборка ответов через Gateway.
# Код выхода 0 — релиз закончился ожидаемо (good → Healthy, bad → откат).
set -euo pipefail

NS=demo
ROLLOUT=hello
TIMEOUT=${RELEASE_TIMEOUT:-600}
GATEWAY_URL="${GATEWAY_URL:-http://$(hostname -I | awk '{print $1}'):30080}"

c_ok=$'\033[32m'; c_bad=$'\033[31m'; c_dim=$'\033[2m'; c_b=$'\033[1m'; c_0=$'\033[0m'
say() { printf '%s\n' "$*"; }
cmd() { printf '%s$ %s%s\n' "$c_dim" "$*" "$c_0"; }

rollout_jsonpath() { kubectl -n "$NS" get rollout "$ROLLOUT" -o jsonpath="$1"; }

# ConfigMap из Git (сгенерирован Kustomize) запоминается при первом релизе
base_config() {
  local base
  base=$(rollout_jsonpath '{.metadata.annotations.devops-case/base-config}')
  if [[ -z $base ]]; then
    base=$(rollout_jsonpath '{.spec.template.spec.volumes[0].configMap.name}')
    kubectl -n "$NS" annotate rollout "$ROLLOUT" "devops-case/base-config=$base" >/dev/null
  fi
  printf '%s' "$base"
}

grafana_annotation() {
  local text=$1 tag=$2 pw
  pw=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d) || return 0
  curl -s -m 5 -o /dev/null -u "admin:$pw" -H "Host: grafana.devops.test" -H 'Content-Type: application/json' \
    -X POST "$GATEWAY_URL/api/annotations" \
    -d "{\"tags\":[\"release\",\"$tag\"],\"text\":\"$text\"}" || true
}

# Выборка ответов через Gateway: сколько от стабильной версии, новой, ошибок
sample_traffic() {
  local stable=0 new=0 errors=0 body code
  for _ in $(seq 20); do
    body=$(curl -s -m 3 -w '\n%{http_code}' "$GATEWAY_URL/" || printf '\n000')
    code=${body##*$'\n'}; body=${body%$'\n'*}
    if [[ $code != 200 ]]; then errors=$((errors + 1))
    elif [[ $body == "Hello World! v1."* ]]; then new=$((new + 1))
    else stable=$((stable + 1)); fi
  done
  printf 'ответы: стабильная=%s новая=%s ошибки=%s' "$stable" "$new" "$errors"
}

watch_release() {
  local expect=$1 start=$SECONDS seen_progress=0 phase step weights analysis
  say ""
  say "${c_b}Ход релиза (каждые 5 с):${c_0}"
  while (( SECONDS - start < TIMEOUT )); do
    phase=$(rollout_jsonpath '{.status.phase}')
    step=$(rollout_jsonpath '{.status.currentStepIndex}')
    weights=$(kubectl -n "$NS" get httproute hello -o jsonpath='{.spec.rules[2].backendRefs[*].weight}')
    analysis=$(kubectl -n "$NS" get analysisrun -l "rollouts-pod-template-hash" --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null || true)
    printf '  %s  фаза=%-11s шаг=%-2s веса stable/canary=%-7s анализ=%-12s %s\n' \
      "$(date +%T)" "$phase" "${step:--}" "${weights// //}" "${analysis:--}" "$(sample_traffic)"
    [[ $phase != Healthy ]] && seen_progress=1
    if [[ $phase == Degraded ]]; then
      say ""
      if [[ $expect == aborted ]]; then
        say "${c_ok}✔ Анализ провалился — релиз автоматически откатан, весь трафик на стабильной версии.${c_0}"
        grafana_annotation "Релиз $VERSION откатан автоматически: анализ 5xx провален" rollback
        return 0
      fi
      say "${c_bad}✘ Релиз откатан, хотя ожидался успех.${c_0}"; return 1
    fi
    if [[ $phase == Healthy && $seen_progress == 1 ]]; then
      say ""
      if [[ $expect == healthy ]]; then
        say "${c_ok}✔ Релиз прошёл все шаги и анализ — новая версия получает 100% трафика.${c_0}"
        grafana_annotation "Релиз $VERSION завершён: 100% трафика" success
        return 0
      fi
      say "${c_bad}✘ Релиз дошёл до 100%, хотя ожидался откат.${c_0}"; return 1
    fi
    sleep 5
  done
  say "${c_bad}✘ Релиз не завершился за ${TIMEOUT} с.${c_0}"; return 1
}

release() {
  local base new_conf
  VERSION=$1
  base=$(base_config)
  new_conf=$(kubectl -n "$NS" get configmap "$base" -o jsonpath='{.data.nginx\.conf}')
  # $hostname — переменная nginx, а не shell: строки берутся буквально
  # shellcheck disable=SC2016
  local stable_line='return 200 "Hello World! from $hostname\n";'
  # shellcheck disable=SC2016
  local good_line='return 200 "Hello World! v1.1 from $hostname\n";'
  local bad_line='return 500 "Internal Server Error (release v1.2-bad)\n";'
  local target_line
  case $VERSION in
    v1.1)     target_line=$good_line ;;
    v1.2-bad) target_line=$bad_line ;;
  esac
  new_conf=${new_conf//"$stable_line"/"$target_line"}
  if [[ $new_conf != *"$target_line"* ]]; then
    say "${c_bad}✘ Не удалось подготовить конфиг версии $VERSION (строка ответа в nginx.conf не найдена)${c_0}"
    exit 1
  fi
  say "${c_b}Релиз $VERSION приложения hello (canary через Gateway API, анализ в Prometheus)${c_0}"
  cmd "kubectl -n $NS create configmap hello-release-$VERSION --from-file=nginx.conf"
  kubectl -n "$NS" create configmap "hello-release-$VERSION" --from-literal=nginx.conf="$new_conf" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - devops-case/release-config=true -o yaml \
    | kubectl apply -f - >/dev/null
  cmd "kubectl -n $NS patch rollout $ROLLOUT  # конфиг и метка версии в шаблоне пода"
  kubectl -n "$NS" patch rollout "$ROLLOUT" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",\"value\":\"hello-release-$VERSION\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/metadata/labels/app.kubernetes.io~1version\",\"value\":\"$VERSION\"}
  ]" >/dev/null
  grafana_annotation "Старт релиза $VERSION" start
  say "Наблюдать отдельно: kubectl argo rollouts get rollout $ROLLOUT -n $NS --watch"
}

reset() {
  local base
  base=$(base_config)
  say "${c_b}Возврат к версии из Git (v1, ConfigMap $base)${c_0}"
  kubectl -n "$NS" patch rollout "$ROLLOUT" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",\"value\":\"$base\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/metadata/labels/app.kubernetes.io~1version\",\"value\":\"v1\"}
  ]" >/dev/null
  # После отката — снять признак abort; после успешного релиза — без шагов canary
  kubectl argo rollouts retry rollout "$ROLLOUT" -n "$NS" >/dev/null 2>&1 || true
  kubectl argo rollouts promote "$ROLLOUT" -n "$NS" --full >/dev/null 2>&1 || true
  kubectl argo rollouts status "$ROLLOUT" -n "$NS" --timeout 300s >/dev/null
  kubectl -n "$NS" delete configmap -l devops-case/release-config=true --ignore-not-found >/dev/null
  grafana_annotation "Возврат к версии из Git (v1)" reset
  say "${c_ok}✔ Версия из Git восстановлена, Rollout Healthy.${c_0}"
}

case ${1:-} in
  good)   release v1.1;     watch_release healthy ;;
  bad)    release v1.2-bad; watch_release aborted ;;
  reset)  reset ;;
  status) kubectl argo rollouts get rollout "$ROLLOUT" -n "$NS" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
