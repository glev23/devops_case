#!/usr/bin/env bash
# Удаляет кластер Kubernetes с узла, чтобы переустановить решение с нуля:
#   sudo ./destroy.sh          # с подтверждением
#   sudo ./destroy.sh --yes    # без вопроса
# После этого: sudo ./deploy.sh
set -euo pipefail

cd "$(dirname "$0")"
export HOME="${HOME:-/root}"

if [[ $EUID -ne 0 ]]; then
  echo "Запустите через sudo: sudo ./destroy.sh" >&2
  exit 1
fi

if [[ ${1:-} != --yes ]]; then
  read -r -p "Удалить кластер Kubernetes и все данные решения на этом узле? [y/N] " answer
  [[ $answer =~ ^[YyДд]$ ]] || { echo "Отменено."; exit 1; }
fi

if ! command -v /usr/bin/ansible-playbook >/dev/null 2>&1; then
  echo "Ansible не установлен — кластер, вероятно, не разворачивался (deploy.sh ставит Ansible)." >&2
  exit 1
fi

cd ansible
exec /usr/bin/ansible-playbook destroy.yml "${@:2}"
