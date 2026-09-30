#!/usr/bin/env bash
# Проверка работоспособности развёрнутого решения.
# Запуск от пользователя с kubeconfig (deploy.sh кладёт его в ~/.kube/config):
#   ./scripts/verify.sh
# Код выхода 0 — все проверки пройдены.
set -euo pipefail

CURL_IMAGE="curlimages/curl:8.16.0"
failed=0

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; failed=1; }
section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# Одноразовый под с curl внутри кластера; вывод читается через logs
# (у `kubectl run -i` конец вывода может теряться).
in_cluster() {
  local name="verify-$RANDOM"
  kubectl run "$name" --restart=Never --image="$CURL_IMAGE" --quiet \
    --command -- sh -c "$1" >/dev/null
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=120s >/dev/null || true
  kubectl logs "$name"
  kubectl delete pod "$name" --wait=false >/dev/null
}

section "Кластер"
# grep -c вместо grep -q: с pipefail ранний выход grep -q даёт ложный SIGPIPE
ready=$(kubectl get node -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -cx True || true)
if [[ $ready -ge 1 ]]; then
  ok "узел Ready ($(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'))"
else
  fail "узел не Ready"
fi

not_running=$(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" {print $1"/"$2" "$4}')
if [[ -z "$not_running" ]]; then
  ok "все поды Running ($(kubectl get pods -A --no-headers | wc -l))"
else
  fail "поды не в Running:"
  while IFS= read -r line; do echo "      $line"; done <<< "$not_running"
fi

section "Приложение (внутри кластера)"
trace="verify-$(date +%s)-$RANDOM"
body=$(in_cluster "curl -s -m 5 'http://hello.demo/?trace=$trace'")
if [[ "$body" == "Hello World! from hello-"* ]]; then
  ok "http://hello.demo/ → $body"
else
  fail "http://hello.demo/ вернул: ${body:-<пусто>}"
fi

sleep 2
hits=$(kubectl -n demo logs -l app.kubernetes.io/name=hello --tail=200 | grep "$trace" | grep -c '"status":200' || true)
if [[ $hits -ge 1 ]]; then
  ok "запрос $trace найден в access-логе приложения (JSON, status 200)"
else
  fail "запрос $trace не найден в access-логе приложения"
fi

section "Gateway API (Envoy Gateway)"
# cond <условие> <kubectl get args...> → статус условия (True/False/пусто)
cond() {
  local type=$1; shift
  kubectl get "$@" -o jsonpath='{.status.conditions[?(@.type=="'"$type"'")].status}' 2>/dev/null
}
if [[ $(cond Accepted gatewayclass eg) == True ]]; then
  ok "GatewayClass eg: Accepted"
else
  fail "GatewayClass eg не Accepted"
fi
if [[ $(cond Programmed -n gateway gateway main) == True ]]; then
  ok "Gateway gateway/main: Programmed"
else
  fail "Gateway gateway/main не Programmed"
fi
route_status() {
  kubectl -n demo get httproute hello \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="'"$1"'")].status}' 2>/dev/null
}
if [[ $(route_status Accepted) == True && $(route_status ResolvedRefs) == True ]]; then
  ok "HTTPRoute demo/hello: Accepted, ResolvedRefs"
else
  fail "HTTPRoute demo/hello не принят Gateway"
fi

# Снаружи кластера: NodePort прокси Envoy на основном IP узла.
# Можно переопределить: GATEWAY_URL=http://<IP>:30080 ./scripts/verify.sh
GATEWAY_URL="${GATEWAY_URL:-http://$(hostname -I | awk '{print $1}'):30080}"
gw_trace="verify-gw-$(date +%s)-$RANDOM"
gw_body=$(curl -s -m 5 "$GATEWAY_URL/?trace=$gw_trace" || true)
if [[ "$gw_body" == "Hello World! from hello-"* ]]; then
  ok "curl $GATEWAY_URL/ → $gw_body"
else
  fail "curl $GATEWAY_URL/ вернул: ${gw_body:-<нет ответа>}"
fi

sleep 2
gw_hits=$(kubectl -n demo logs -l app.kubernetes.io/name=hello --tail=200 | grep "$gw_trace" | grep -c '"x_forwarded_for":"[0-9]' || true)
if [[ $gw_hits -ge 1 ]]; then
  ok "запрос через Gateway дошёл до nginx (в логе есть X-Forwarded-For от Envoy)"
else
  fail "запрос $gw_trace через Gateway не найден в логе nginx"
fi

section "Мониторинг (Prometheus)"
PROM_URL="http://kps-prometheus.monitoring:9090/api/v1/query"
# Все PromQL-запросы одним подом; каждый ответ — одна JSON-строка
prom_out=$(in_cluster "
  for q in 'count(up == 0) or vector(0)' 'count(up)' 'sum by (job) (up)' 'sum(nginx_http_requests_total)'; do
    curl -s -m 10 -G '$PROM_URL' --data-urlencode \"query=\$q\"; echo
  done")
prom_parsed=$(python3 - "$prom_out" <<'PY'
import json, sys
lines = [l for l in sys.argv[1].splitlines() if l.startswith('{')]
def vals(i):
    try:
        return json.loads(lines[i])['data']['result']
    except Exception:
        return None
down, total, jobs, reqs = (vals(i) for i in range(4))
print('down', down[0]['value'][1] if down else 'ERR')
print('total', total[0]['value'][1] if total else 'ERR')
print('jobs', ' '.join(sorted(r['metric'].get('job', '?') for r in (jobs or []) if float(r['value'][1]) > 0)))
print('reqs', reqs[0]['value'][1] if reqs else 'ERR')
PY
)
get() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' <<< "$prom_parsed"; }

if [[ $(get total) =~ ^[0-9]+$ ]]; then
  ok "Prometheus отвечает, targets: $(get total)"
else
  fail "Prometheus API не ответил"
fi
if [[ $(get down) == 0 ]]; then
  ok "нет targets в состоянии DOWN (count(up == 0) = 0)"
else
  fail "есть targets в состоянии DOWN: $(get down)"
fi
jobs=" $(get jobs) "
missing=""
for job in apiserver kubelet node-exporter kube-state-metrics coredns kube-controller-manager kube-scheduler kube-etcd kube-proxy hello; do
  [[ $jobs == *" $job "* ]] || missing+=" $job"
done
if [[ -z $missing ]]; then
  ok "targets UP:$jobs"
else
  fail "targets отсутствуют или DOWN:$missing"
fi
reqs=$(get reqs)
if [[ $reqs =~ ^[0-9.]+$ ]] && awk -v r="$reqs" 'BEGIN { exit !(r > 0) }'; then
  ok "PromQL sum(nginx_http_requests_total) = $reqs (метрики приложения)"
else
  fail "метрики nginx не получены (sum(nginx_http_requests_total) = ${reqs:-<пусто>})"
fi

section "Логирование (Fluentd → Loki)"
fluentd_ready=$(kubectl -n logging get ds fluentd -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)
if [[ -n $fluentd_ready && ${fluentd_ready%/*} == "${fluentd_ready#*/}" && ${fluentd_ready%/*} -ge 1 ]]; then
  ok "Fluentd DaemonSet готов ($fluentd_ready)"
else
  fail "Fluentd DaemonSet не готов (${fluentd_ready:-нет})"
fi

# Ищем в Loki тот самый запрос, что прошёл через Gateway ($gw_trace).
# LogQL: поток nginx из namespace demo → строка с меткой → разбор JSON → status 200.
LOKI_URL="http://loki.logging:3100/loki/api/v1/query_range"
LOGQL="{namespace=\"demo\",container=\"nginx\"} |= \"$gw_trace\" | json | status=\"200\""
loki_line=""
for _ in 1 2 3 4 5 6; do
  loki_out=$(in_cluster "curl -s -m 10 -G '$LOKI_URL' --data-urlencode 'since=15m' --data-urlencode 'query=$LOGQL'")
  loki_line=$(python3 -c '
import json, sys
try:
    res = json.loads(sys.argv[1])["data"]["result"]
    print(res[0]["values"][0][1] if res else "")
except Exception:
    print("")
' "$(grep -m1 '^{' <<< "$loki_out" || true)")
  [[ -n $loki_line ]] && break
  sleep 5
done
if [[ -n $loki_line ]]; then
  ok "запрос $gw_trace найден в Loki (LogQL: {namespace=\"demo\",container=\"nginx\"} |= \"…\" | json | status=\"200\")"
  echo "      $loki_line"
else
  fail "запрос $gw_trace не найден в Loki"
fi

echo
if [[ $failed -eq 0 ]]; then
  printf '\033[32mВсе проверки пройдены\033[0m\n'
else
  printf '\033[31mЕсть непройденные проверки\033[0m\n'
fi
exit $failed
