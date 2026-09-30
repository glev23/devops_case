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

echo
if [[ $failed -eq 0 ]]; then
  printf '\033[32mВсе проверки пройдены\033[0m\n'
else
  printf '\033[31mЕсть непройденные проверки\033[0m\n'
fi
exit $failed
