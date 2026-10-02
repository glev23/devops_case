#!/usr/bin/env bash
# Экскурсия по решению для эксперта и жюри (DEMO-001).
#
#   ./scripts/demo.sh                    # интерактивно: Enter — следующий шаг
#   ./scripts/demo.sh --auto             # без пауз
#   ./scripts/demo.sh --auto --no-release  # без шагов с релизами (~5 мин экономии)
#
# Каждый шаг печатает команду (её можно повторить вручную) и результат.
# Запросы к Prometheus, Loki и Tempo идут через прокси API-сервера Kubernetes
# (kubectl get --raw) — без паролей, port-forward и вспомогательных подов.
# Состояние после сценария не меняется: версия приложения возвращается к Git.
set -euo pipefail

AUTO=0
RELEASES=1
for arg in "$@"; do
  case $arg in
    --auto) AUTO=1 ;;
    --no-release) RELEASES=0 ;;
    *) sed -n '2,11p' "$0"; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
NODE_IP=$(hostname -I | awk '{print $1}')
GW="http://$NODE_IP:30080"
STEP=0

c_h=$'\033[1;36m'; c_d=$'\033[2m'; c_ok=$'\033[32m'; c_0=$'\033[0m'

step() {
  STEP=$((STEP + 1))
  printf '\n%s━━ %s. %s %s\n' "$c_h" "$STEP" "$1" "$c_0"
  [[ -n ${2:-} ]] && printf '%s%s%s\n' "$c_d" "$2" "$c_0"
  return 0
}
cmd() { printf '%s$ %s%s\n' "$c_d" "$*" "$c_0"; }
note() { printf '  %s\n' "$*"; }
pause() {
  if [[ $AUTO == 0 ]]; then
    read -r -p $'\n  [Enter — дальше] ' _ || true
  fi
}

urlencode() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
svc_proxy() { kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"; }

# PromQL → «метки = значение» построчно
promql() {
  cmd "PromQL: $1"
  svc_proxy monitoring kps-prometheus:9090 "/api/v1/query?query=$(urlencode "$1")" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["data"]["result"]:
    labels = ", ".join(k + "=" + v for k, v in r["metric"].items() if k != "__name__") or "—"
    print("    %-55s %.4g" % (labels, float(r["value"][1])))
'
}

# ───────────────────────────────────────────────────────────────────────────
step "Кластер и компоненты" "kubeadm, один узел Ubuntu 24.04; всё поставлено одной командой sudo ./deploy.sh"
cmd "kubectl get nodes -o wide"
kubectl get nodes -o custom-columns='УЗЕЛ:.metadata.name,СТАТУС:.status.conditions[-1].type,ВЕРСИЯ:.status.nodeInfo.kubeletVersion,ОС:.status.nodeInfo.osImage,RUNTIME:.status.nodeInfo.containerRuntimeVersion'
cmd "helm list -A"
helm list -A --kubeconfig "${KUBECONFIG:-$HOME/.kube/config}" 2>/dev/null \
  | awk 'NR == 1 {printf "    %-16s %-22s %s\n", "РЕЛИЗ", "NAMESPACE", "ЧАРТ"; next} {printf "    %-16s %-22s %s\n", $1, $2, $9}'
note "Подов: $(kubectl get pods -A --no-headers | wc -l), не в Running/Completed: $(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | wc -l)"
pause

# ───────────────────────────────────────────────────────────────────────────
step "Gateway API: приложение снаружи кластера" "Envoy Gateway: GatewayClass → Gateway (HTTP :30080, HTTPS :30443) → HTTPRoute → Service"
cmd "kubectl get gatewayclass,gateway,httproute -A"
kubectl get gateway -A -o custom-columns='GATEWAY:.metadata.name,NAMESPACE:.metadata.namespace,КЛАСС:.spec.gatewayClassName,ADDRESS:.status.addresses[0].value'
kubectl get httproute -A -o custom-columns='HTTPROUTE:.metadata.name,NAMESPACE:.metadata.namespace,HOSTNAMES:.spec.hostnames'
cmd "curl -i $GW/"
curl -s -i "$GW/" | tr -d '\r' | grep -E '^HTTP|^x-backend|^Hello' | sed 's/^/    /'
cmd "curl $GW/v2      # маршрут по path + URL rewrite"
note "$(curl -s "$GW/v2")"
cmd "for i in \$(seq 20); do curl -s $GW/canary; done   # веса 80/20"
for _ in $(seq 20); do curl -s "$GW/canary"; done | sed 's/-[a-z0-9]*-[a-z0-9]*$//' | sort | uniq -c | sed 's/^/  /'
cmd "curl -H 'Host: grafana.devops.test' $GW/api/health   # маршрут по hostname"
note "$(curl -s -H 'Host: grafana.devops.test' "$GW/api/health" | tr -d '\n ' )"
ca=$(mktemp)
kubectl -n gateway get secret devops-test-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca"
cmd "curl --cacert ca.crt --resolve hello.devops.test:30443:$NODE_IP https://hello.devops.test:30443/"
note "$(curl -s --cacert "$ca" --resolve "hello.devops.test:30443:$NODE_IP" https://hello.devops.test:30443/)  ← сертификат проверен по CA кластера"
rm -f "$ca"
cmd "for i in \$(seq 15); do curl -s -o /dev/null -w '%{http_code}\\n' $GW/limited; done   # rate limit 5/с"
for _ in $(seq 15); do curl -s -o /dev/null -w '%{http_code}\n' "$GW/limited"; done | sort | uniq -c | sed 's/^/  /'
pause

# ───────────────────────────────────────────────────────────────────────────
step "Мониторинг: Prometheus" "kube-prometheus-stack; метрики кластера, Envoy Gateway и nginx; фоновая нагрузка — loadgen"
promql 'count(up == 1)'
promql 'count(up == 0) or vector(0)'
promql 'route:envoy_upstream_rq:rate5m'
promql 'histogram_quantile(0.95, sum by (le) (rate(envoy_http_downstream_rq_time_bucket{envoy_http_conn_manager_prefix=~"https?-.*"}[5m])))'
note "↑ p95 времени ответа Gateway, мс"
step "SLO доступности 99,9%" "SLI — доля не-5xx по маршрутам приложения; burn-rate алерты по методике Google SRE"
promql 'slo:sli:availability_3d'
promql 'slo:error_budget_remaining:ratio'
promql 'ALERTS{alertstate="firing", alertname!~"Watchdog|InfoInhibitor"}'
note "Сработавшие алерты (служебные Watchdog/InfoInhibitor исключены); пусто — всё в норме."
pause

# ───────────────────────────────────────────────────────────────────────────
step "Логирование и трейсинг: один запрос — лог и трейс" "Fluentd → Loki; Envoy → Tempo; связь по W3C traceparent"
trace_id=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 32 || true)
span_id=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16 || true)
marker="demo-$(date +%s)"
cmd "curl -H 'traceparent: 00-$trace_id-$span_id-01' '$GW/?trace=$marker'"
note "$(curl -s -H "traceparent: 00-$trace_id-$span_id-01" "$GW/?trace=$marker")"
note "${c_d}ждём, пока Fluentd и Tempo примут данные…${c_0}"
sleep 10
logql="{namespace=\"demo\",container=\"nginx\"} |= \"$marker\" | json"
cmd "LogQL: $logql"
svc_proxy logging loki:3100 "/loki/api/v1/query_range?since=10m&query=$(urlencode "$logql")" | python3 -c '
import json, sys
for s in json.load(sys.stdin)["data"]["result"]:
    for _, line in s["values"][:1]:
        d = json.loads(line)
        print("    status=%s uri=%s pod=%s" % (d.get("status"), d.get("uri"), s["stream"].get("pod")))
        print("    traceparent=%s" % d.get("traceparent"))
'
cmd "Tempo: GET /api/v2/traces/$trace_id"
svc_proxy tracing tempo:3200 "/api/v2/traces/$trace_id" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for rs in d["trace"]["resourceSpans"]:
    for ss in rs["scopeSpans"]:
        for sp in ss["spans"]:
            a = {x["key"]: list(x["value"].values())[0] for x in sp.get("attributes", [])}
            ms = (int(sp["endTimeUnixNano"]) - int(sp["startTimeUnixNano"])) / 1e6
            print("    span %-45s %6.2f мс  код=%s" % (sp["name"], ms, a.get("http.status_code", "-")))
'
note "В Grafana: Explore → Loki → строка лога → «Трейс в Tempo»"
pause

# ───────────────────────────────────────────────────────────────────────────
step "GitOps: Argo CD" "кластер сам забирает deploy/* из GitHub (pull-модель, без входящих подключений)"
cmd "kubectl -n argocd get applications"
kubectl -n argocd get applications -o custom-columns='APPLICATION:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,КОММИТ:.status.sync.revision' 2>/dev/null \
  | awk '{ if (NR > 1) $4 = substr($4, 1, 7); printf "    %-12s %-10s %-9s %s\n", $1, $2, $3, $4 }' \
  || note "GitOps выключен (gitops_enabled: false)"
pause

# ───────────────────────────────────────────────────────────────────────────
if [[ $RELEASES == 1 ]]; then
  step "Прогрессивная доставка: хороший релиз" "Argo Rollouts: 10 → 30 → 60 → 100% через веса HTTPRoute, анализ доли 5xx в Prometheus"
  cmd "make release-good"
  ./scripts/release.sh good
  pause

  step "Прогрессивная доставка: плохой релиз (отвечает 500)" "анализ провалится — Rollouts сам вернёт весь трафик на стабильную версию"
  cmd "make release-bad"
  ./scripts/release.sh bad
  cmd "make release-reset"
  ./scripts/release.sh reset
  pause
fi

# ───────────────────────────────────────────────────────────────────────────
step "Итог и ссылки" "для браузера: <IP> grafana.devops.test prometheus.devops.test argocd.devops.test в hosts"
note "Приложение:      $GW/   (HTTPS: https://hello.devops.test:30443/)"
note "Grafana:         http://grafana.devops.test:30080/d/devops-case-gateway   (SLO: /d/devops-case-slo)"
note "Prometheus:      http://prometheus.devops.test:30080   (basic auth)"
note "Argo CD:         http://argocd.devops.test:30080"
note ""
note "Пароли:"
cmd "kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
cmd "kubectl -n monitoring get secret prometheus-basic-auth -o jsonpath='{.data.password}' | base64 -d"
cmd "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
note ""
note "${c_ok}Полная автоматическая проверка: make verify${c_0}"
