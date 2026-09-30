#!/usr/bin/env bash
# Единая точка входа: разворачивает всё решение на чистой Ubuntu 24.04.
# Идемпотентно: повторный запуск приводит систему к тому же состоянию.
#
#   sudo ./deploy.sh              # всё решение
#   sudo ./deploy.sh --tags cni   # доп. аргументы передаются в ansible-playbook
set -euo pipefail

cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "Запустите через sudo: sudo ./deploy.sh" >&2
  exit 1
fi

# Всегда Ansible из репозитория Ubuntu 24.04 (ansible-core 2.16 + коллекции
# kubernetes.core, community.general, ansible.posix), а не случайный из PATH:
# так набор модулей и их версии одинаковы на любой машине.
if ! dpkg-query -W -f='${Status}' ansible 2>/dev/null | grep -q "install ok installed"; then
  echo "==> Установка Ansible из репозитория Ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ansible >/dev/null
fi

cd ansible
exec /usr/bin/ansible-playbook site.yml "$@"
