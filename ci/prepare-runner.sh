#!/usr/bin/env bash
# Приводит GitHub-раннер ubuntu-24.04 к состоянию «чистая Ubuntu 24.04».
# Только для CI: на раннере заранее стоят Docker со своим containerd,
# kubectl и Ansible (pipx), которых на чистой системе нет.
set -euo pipefail

echo "==> Удаление Docker и его containerd (конфликтуют с containerd из Ubuntu)"
systemctl stop docker.socket docker containerd 2>/dev/null || true
apt-get purge -y -qq docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin \
  containerd.io moby-engine moby-cli moby-containerd moby-runc moby-buildx moby-compose 2>/dev/null || true
rm -rf /etc/containerd /var/lib/containerd
ip link delete docker0 2>/dev/null || true

echo "==> Удаление предустановленных kubectl/kind (ставятся нашим playbook)"
apt-get purge -y -qq kubectl 2>/dev/null || true
rm -f /usr/local/bin/kubectl /usr/local/bin/kind

echo "==> Свободно: $(free -h | awk '/Mem/ {print $7}') RAM, $(df -h / | awk 'NR==2 {print $4}') диска"
