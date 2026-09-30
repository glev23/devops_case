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

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "==> Установка Ansible"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ansible >/dev/null
fi

cd ansible
exec ansible-playbook site.yml "$@"
