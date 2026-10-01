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
  # $1 — команда; $2 — namespace (по умолчанию demo: туда пускает NetworkPolicy)
  local name="verify-$RANDOM" ns="${2:-demo}"
  kubectl -n "$ns" run "$name" --restart=Never --image="$CURL_IMAGE" --quiet \
    --labels=app.kubernetes.io/name=verify --command -- sh -c "$1" >/dev/null
  kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=120s >/dev/null || true
  kubectl -n "$ns" logs "$name"
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null
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
hits=$(kubectl -n demo logs -l app.kubernetes.io/name=hello -c nginx --tail=200 | grep "$trace" | grep -c '"status":200' || true)
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
gw_hits=$(kubectl -n demo logs -l app.kubernetes.io/name=hello -c nginx --tail=200 | grep "$gw_trace" | grep -c '"x_forwarded_for":"[0-9]' || true)
if [[ $gw_hits -ge 1 ]]; then
  ok "запрос через Gateway дошёл до nginx (в логе есть X-Forwarded-For от Envoy)"
else
  fail "запрос $gw_trace через Gateway не найден в логе nginx"
fi

section "Gateway API: path, несколько backend, traffic splitting, TLS"
hdr() { curl -s -m 5 -D - -o /dev/null "$GATEWAY_URL$1" | tr -d '\r' | awk -F': ' -v h="$2" 'tolower($1) == tolower(h) {print $2}'; }

v2_body=$(curl -s -m 5 "$GATEWAY_URL/v2" || true)
if [[ $v2_body == "Hello World! from hello-v2-"* && $(hdr /v2 X-Backend) == v2 ]]; then
  ok "/v2 → hello-v2 (URLRewrite /v2 → /, X-Backend: v2): $v2_body"
else
  fail "/v2 вернул: ${v2_body:-<нет ответа>}"
fi
if [[ $(hdr / X-Backend) == v1 ]]; then
  ok "/ → hello v1 (ResponseHeaderModifier: X-Backend: v1)"
else
  fail "/ без заголовка X-Backend: v1"
fi

# Веса 80/20: из 100 запросов к /canary ожидаем ~20 ответов от hello-v2
v1_hits=0; v2_hits=0
for _ in $(seq 100); do
  case $(curl -s -m 5 "$GATEWAY_URL/canary") in
    "Hello World! from hello-v2-"*) v2_hits=$((v2_hits + 1)) ;;
    "Hello World! from hello-"*)    v1_hits=$((v1_hits + 1)) ;;
  esac
done
if (( v1_hits + v2_hits == 100 && v2_hits >= 8 && v2_hits <= 35 )); then
  ok "/canary, веса 80/20: v1=$v1_hits, v2=$v2_hits из 100"
else
  fail "/canary, веса 80/20: v1=$v1_hits, v2=$v2_hits из 100 (ожидалось ~80/20)"
fi

err_code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$GATEWAY_URL/error" || true)
if [[ $err_code == 500 ]]; then
  ok "/error → 500 (для метрик кодов ответа)"
else
  fail "/error вернул $err_code вместо 500"
fi

# HTTPS со строгой проверкой сертификата по CA из кластера (без -k)
gw_ip=${GATEWAY_URL#*://}; gw_ip=${gw_ip%%:*}
ca_file=$(mktemp)
kubectl -n gateway get secret devops-test-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$ca_file"
tls_body=$(curl -s -m 5 --cacert "$ca_file" --resolve "hello.devops.test:30443:$gw_ip" https://hello.devops.test:30443/ || true)
tls_issuer=$(curl -s -m 5 -v --cacert "$ca_file" --resolve "hello.devops.test:30443:$gw_ip" https://hello.devops.test:30443/ 2>&1 \
  | sed -n 's/^\*  *issuer: //p' | head -1)
rm -f "$ca_file"
if [[ $tls_body == "Hello World! from hello-"* ]]; then
  ok "https://hello.devops.test:30443/ → сертификат проверен (issuer: ${tls_issuer:-?})"
else
  fail "HTTPS через Gateway не прошёл проверку: ${tls_body:-<нет ответа>}"
fi

section "Политики трафика Gateway (Envoy Gateway)"
# Политика принята: условие Accepted у предка (Gateway) в status.ancestors
policy_ok() {
  kubectl get "$@" -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null
}
if [[ $(policy_ok -n demo backendtrafficpolicy hello) == True ]]; then
  ok "BackendTrafficPolicy demo/hello: Accepted (таймауты, ретраи на сетевые сбои, circuit breaker, rate limit)"
else
  fail "BackendTrafficPolicy demo/hello не принята"
fi
if [[ $(policy_ok -n gateway clienttrafficpolicy main) == True ]]; then
  ok "ClientTrafficPolicy gateway/main: Accepted (таймауты клиента, лимит соединений, X-Request-Id)"
else
  fail "ClientTrafficPolicy gateway/main не принята"
fi

# Rate limit: 30 запросов подряд к /limited — первые проходят, остальные 429
limited_codes=$(for _ in $(seq 30); do curl -s -o /dev/null -m 5 -w '%{http_code}\n' "$GATEWAY_URL/limited"; done | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')
if [[ $limited_codes == *"200×"* && $limited_codes == *"429×"* ]]; then
  ok "/limited, лимит 5 запросов/с: $limited_codes"
else
  fail "/limited: rate limit не сработал ($limited_codes)"
fi
limited_hdr=$(curl -s -m 5 -D - -o /dev/null "$GATEWAY_URL/limited" | tr -d '\r' | grep -i '^x-ratelimit-limit' || true)
[[ -n $limited_hdr ]] && ok "заголовок ответа: $limited_hdr"

# /error — отдельное правило (#3): его 500 не попадают в основной маршрут (#2)
if [[ $(hdr /error X-Backend) == "" && $(curl -s -m 5 -o /dev/null -w '%{http_code}' "$GATEWAY_URL/error") == 500 ]]; then
  ok "/error обслуживается отдельным правилом маршрута (без X-Backend правила /), 500"
else
  fail "/error попадает в правило / — намеренные 500 испортят SLI"
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

section "Grafana и маршрутизация по hostname"
gw_host() { curl -s -m 10 -H "Host: $1" "${@:3}" "$GATEWAY_URL$2"; }

graf_health=$(gw_host grafana.devops.test /api/health || true)
if [[ $graf_health =~ \"database\":\ *\"ok\" ]]; then
  ok "Host: grafana.devops.test → Grafana (api/health: database ok)"
else
  fail "Grafana через Gateway (Host: grafana.devops.test) не отвечает"
fi

# Prometheus через Gateway закрыт basic auth (SecurityPolicy): без пароля 401, с паролем 200
prom_pw=$(kubectl -n monitoring get secret prometheus-basic-auth -o jsonpath='{.data.password}' | base64 -d)
prom_noauth=$(gw_host prometheus.devops.test /-/ready -o /dev/null -w '%{http_code}' || true)
prom_auth=$(gw_host prometheus.devops.test /-/ready -o /dev/null -w '%{http_code}' -u "admin:$prom_pw" || true)
if [[ $prom_noauth == 401 && $prom_auth == 200 ]]; then
  ok "Host: prometheus.devops.test → Prometheus UI: без пароля 401, с паролем 200 (basic auth)"
else
  fail "Prometheus через Gateway: без пароля ${prom_noauth:-?}, с паролем ${prom_auth:-?} (ожидалось 401/200)"
fi

other=$(gw_host anything.devops.test / || true)
if [[ $other == "Hello World! from hello-"* ]]; then
  ok "любой другой Host → приложение (маршрут по умолчанию)"
else
  fail "маршрут по умолчанию на приложение не сработал: ${other:-<нет ответа>}"
fi

# Источники данных Grafana: Grafana сама обращается к Prometheus и Loki
graf_pw=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
for ds in prometheus loki; do
  ds_status=$(gw_host grafana.devops.test "/api/datasources/uid/$ds/health" -u "admin:$graf_pw" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true)
  if [[ $ds_status == OK ]]; then
    ok "Grafana → datasource $ds: OK"
  else
    fail "Grafana → datasource $ds: ${ds_status:-нет ответа}"
  fi
done

section "Безопасность: NetworkPolicy, PDB"
# Под из чужого namespace (default) не должен достучаться до приложения напрямую
np_out=$(in_cluster "curl -s -m 4 -o /dev/null -w '%{http_code}' http://hello.demo/ || echo blocked" default)
if [[ $np_out == *blocked* || $np_out == 000* ]]; then
  ok "под из namespace default → hello.demo:80 заблокирован NetworkPolicy"
else
  fail "NetworkPolicy не блокирует доступ из default к hello.demo (ответ: $np_out)"
fi
np_in=$(in_cluster "curl -s -m 4 http://hello.demo/" demo)
if [[ $np_in == "Hello World! from hello-"* ]]; then
  ok "под из demo → hello.demo:80 разрешён"
else
  fail "под из demo не получил ответ от hello.demo: ${np_in:-<пусто>}"
fi
pdb_min=$(kubectl -n demo get pdb hello -o jsonpath='{.spec.minAvailable}' 2>/dev/null || true)
pdb_allowed=$(kubectl -n demo get pdb hello -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || true)
if [[ $pdb_min == 1 ]]; then
  ok "PodDisruptionBudget demo/hello: minAvailable=1, сейчас допустимо прерываний: ${pdb_allowed:-?}"
else
  fail "PodDisruptionBudget demo/hello не найден"
fi

section "HTTP-метрики Envoy, алерты, дашборд"
# PodMonitor подхватывается не мгновенно (перезагрузка конфигурации Prometheus) — с повторами
envoy_rq=""
for _ in 1 2 3 4 5 6 7 8; do
  envoy_out=$(in_cluster "curl -s -m 10 -G '$PROM_URL' --data-urlencode 'query=sum by (route) (envoy_cluster_upstream_rq_total{envoy_cluster_name=~\"httproute/demo/.*\"})'")
  envoy_rq=$(python3 -c '
import json, sys
try:
    res = json.loads(sys.argv[1])["data"]["result"]
    print(" ".join("%s=%s" % (r["metric"].get("route", "?"), r["value"][1]) for r in sorted(res, key=lambda r: r["metric"].get("route", ""))))
except Exception:
    print("")
' "$(grep -m1 '^{' <<< "$envoy_out" || true)")
  [[ -n $envoy_rq ]] && break
  sleep 10
done
if [[ -n $envoy_rq ]]; then
  ok "метрики Envoy по маршрутам в Prometheus: $envoy_rq"
else
  fail "метрики Envoy (envoy_cluster_upstream_rq_total) не найдены в Prometheus"
fi

rules_out=$(in_cluster "curl -s -m 10 http://kps-prometheus.monitoring:9090/api/v1/rules")
# Ответ со всеми правилами большой — передаётся через stdin, а не аргументом
rule_groups=$(grep -m1 '^{' <<< "$rules_out" | python3 -c '
import json, sys
try:
    groups = json.load(sys.stdin)["data"]["groups"]
    print(" ".join(sorted(g["name"] for g in groups if g["name"].startswith("devops-case"))))
except Exception:
    print("")
' || true)
if [[ $rule_groups == *devops-case.app*devops-case.gateway*devops-case.logging*devops-case.slo* ]]; then
  ok "правила алертов загружены: $rule_groups"
else
  fail "правила алертов devops-case не загружены (${rule_groups:-нет})"
fi

dash_title=$(gw_host grafana.devops.test /api/dashboards/uid/devops-case-gateway -u "admin:$graf_pw" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["dashboard"]["title"])' 2>/dev/null || true)
if [[ -n $dash_title ]]; then
  ok "дашборд Grafana: «$dash_title» (http://grafana.devops.test:30080/d/devops-case-gateway)"
else
  fail "дашборд devops-case-gateway не найден в Grafana"
fi

section "SLO доступности (99,9%)"
# Recording rules считаются раз в 30 с — после свежей установки нужны повторы
slo_vals=""
for _ in 1 2 3 4 5 6 7 8; do
  slo_out=$(in_cluster "
    for q in 'slo:sli:availability_3d' 'slo:error_budget_remaining:ratio' 'slo:burn_rate:1h' 'slo:sli_error:ratio_rate5m'; do
      curl -s -m 10 -G '$PROM_URL' --data-urlencode \"query=\$q\"; echo
    done")
  slo_vals=$(grep '^{' <<< "$slo_out" | python3 -c '
import json, sys
vals = []
for line in sys.stdin:
    try:
        r = json.loads(line)["data"]["result"]
        vals.append(r[0]["value"][1] if r else "")
    except Exception:
        vals.append("")
print(" ".join(v if v else "-" for v in vals) if all(vals) and len(vals) == 4 else "")
' || true)
  [[ -n $slo_vals ]] && break
  sleep 15
done
if [[ -n $slo_vals ]]; then
  read -r slo_avail slo_budget slo_burn slo_err5m <<< "$slo_vals"
  ok "SLI доступности (3 дня) = $slo_avail при цели 0.999; остаток бюджета ошибок = $slo_budget"
  ok "burn rate (1 ч) = $slo_burn; доля ошибок (5 мин) = $slo_err5m"
else
  fail "recording rules SLO не вернули значения (slo:sli:availability_3d и др.)"
fi
slo_dash=$(gw_host grafana.devops.test /api/dashboards/uid/devops-case-slo -u "admin:$graf_pw"   | python3 -c 'import json,sys; print(json.load(sys.stdin)["dashboard"]["title"])' 2>/dev/null || true)
if [[ -n $slo_dash ]]; then
  ok "дашборд Grafana: «$slo_dash» (http://grafana.devops.test:30080/d/devops-case-slo)"
else
  fail "дашборд devops-case-slo не найден в Grafana"
fi

echo
if [[ $failed -eq 0 ]]; then
  printf '\033[32mВсе проверки пройдены\033[0m\n'
else
  printf '\033[31mЕсть непройденные проверки\033[0m\n'
fi
exit $failed
