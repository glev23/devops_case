# CLUSTER-001 — Кластер kubeadm на Ubuntu 24.04 кодом из репозитория

| Поле | Значение |
|---|---|
| ID | `CLUSTER-001` |
| Статус | `done` |
| Требования | кейс, пп. 1, 6, 7; architecture.md §2, §3, §8, §9 |
| Решения | D-01, D-02, D-02b, D-07 |
| Зависимости | DOCS-001 |
| Блокирует | APP-001, MON-001 и всё, что работает в кластере |

## Цель

На чистой Ubuntu 24.04 одной командой из репозитория поднимается
одноузловой кластер Kubernetes через kubeadm с containerd и Calico.
Повторный запуск ничего не ломает и ничего не меняет.

Задача закладывает каркас автоматизации (Makefile + Ansible), на который
следующие задачи добавляют свои шаги. Так к AUTO-001 не придётся
переписывать всё заново.

## Scope

### Входит

- каркас репозитория: `Makefile`, `ansible/`, `.gitignore`, `.editorconfig`;
- bootstrap Ansible на узле (если его нет) — первый шаг `make deploy`;
- роль `node`: пакеты, отключение swap, модули ядра `overlay` и
  `br_netfilter`, sysctl, containerd с `SystemdCgroup = true`;
- роль `kubeadm`: репозиторий pkgs.k8s.io для v1.36, `kubelet`/`kubeadm`/
  `kubectl` закреплённой версии с `apt-mark hold`, `kubeadm init` с
  конфигом из шаблона — только если кластера ещё нет;
  kubeconfig для пользователя; снятие taint control-plane;
- роль `cni`: Calico v3.32.2 через манифест tigera-operator и ресурс
  `Installation` с pod CIDR `10.244.0.0/16`;
- ожидание `Ready` узла и всех подов `kube-system` / `calico-system`;
- установка Helm закреплённой версии (понадобится с GW-001);
- все версии — в `ansible/group_vars/all.yml`.

### Не входит

- приложение, Gateway, мониторинг, логи (APP-001, GW-001, MON-001, LOG-001);
- `make verify` целиком (AUTO-001) — здесь только проверки кластера;
- многоузловой кластер, HA control plane;
- настройки конкретно нашего стенда (MTU для WireGuard) — это не часть
  решения (architecture.md §2).

## Технические требования

| Компонент | Версия | Источник |
|---|---|---|
| Kubernetes | v1.36.5 | dl.k8s.io/release/stable-1.36.txt, 30.09.2026 |
| containerd | из репозитория Ubuntu 24.04 (`containerd`) | ⚠️ версия фиксируется по факту установки |
| Calico | v3.32.2 | github.com/projectcalico/calico/releases, поддерживает k8s 1.34–1.36 |
| Helm | ⚠️ последний стабильный 3.x, фиксируется при реализации | get.helm.sh |

- `kubeadm init` идёт через файл конфигурации (`ClusterConfiguration`,
  `KubeletConfiguration` с `cgroupDriver: systemd`), а не через флаги.
- Адрес API — основной IPv4 узла (`ansible_default_ipv4.address`).
- Команда работает под `sudo` на самом узле (`connection: local`).

## Артефакты

| Артефакт | Назначение |
|---|---|
| `Makefile` | `deploy`, `cluster`, `lint`, `help` |
| `scripts/bootstrap.sh` | Установка Ansible на чистую Ubuntu |
| `ansible/site.yml` | Корневой playbook |
| `ansible/group_vars/all.yml` | Все версии и параметры |
| `ansible/roles/{node,kubeadm,cni,helm}/` | Роли |

## Критерии приёмки

- [x] На VM, откатанной к снимку чистой Ubuntu, `sudo ./deploy.sh` поднимает
      кластер без ручных действий.
- [x] `kubectl get nodes` → узел `Ready`, версия `v1.36.5`.
- [x] Все поды `kube-system`, `tigera-operator` и `calico-system` в `Running`.
- [x] Под из тестового образа получает IP из `10.244.0.0/16` и резолвит
      `kubernetes.default` через CoreDNS.
- [x] Повторный `sudo ./deploy.sh` завершается с `changed=0`.
- [x] Кластер переживает перезагрузку узла со сменой IP по DHCP
      (добавлено по ходу задачи).
- [x] В репозитории нет секретов; версии не `latest`.

## Проверка

```bash
sudo ./deploy.sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default
sudo ./deploy.sh   # повторно: PLAY RECAP ... changed=0
```

## Результат закрытия

Закрыта 30.09.2026.

**Артефакты:** `deploy.sh`, `Makefile`, `ansible/{ansible.cfg,inventory.ini,site.yml}`,
`ansible/group_vars/all.yml`, роли `node`, `kubeadm`, `cni`, `helm`,
`.gitignore`, `.gitattributes`.

**Фактические проверки** (VM `k8s`, откат к чистой Ubuntu 24.04.5):

| Проверка | Результат |
|---|---|
| Первый прогон с нуля | `ok=38 changed=23 failed=0`, 824 с (время в основном уходит на загрузку пакетов и образов) |
| Повторный прогон | `ok=32 changed=0 failed=0` |
| `kubectl get nodes` | `k8s Ready control-plane v1.36.5`, INTERNAL-IP `10.200.0.10`, `containerd://2.2.1` |
| Поды | 14/14 `Running`; `tigerastatus` calico/apiserver/ippools — `Available` |
| Под busybox | IP `10.244.77.x`, `kubernetes.default` → `10.96.0.1` через `10.96.0.10` |
| Перезагрузка VM | IP `172.24.181.165` → `172.24.176.19`, узел `Ready`, 14/14 `Running` |
| Ресурсы после установки | RAM ~1,7 ГБ из 7,8; диск 5,5 ГБ из 48 |

**Зафиксированные версии:** Kubernetes 1.36.5 (пакеты `1.36.5-1.1`, hold),
containerd 2.2.1 (Ubuntu), Calico v3.32.2, Helm v3.22.0, kubeadm API
`v1beta4`.

**Отклонения от постановки:**
- Точка входа — `./deploy.sh`, а не `make deploy`: в чистом образе Ubuntu
  нет `make`. `make deploy` оставлен как обёртка.
- Добавлен стабильный адрес узла `10.200.0.10` на dummy-интерфейсе: без него
  кластер ломался после перезагрузки с новым IP по DHCP (architecture.md,
  «История решений»).
- Calico `Installation` создаётся один раз: после установки оператор
  владеет его `spec`, и повторное применение давало `changed=1` или
  конфликт server-side apply.
- Особенности стенда (не часть решения): MTU 1400 и DNS 1.1.1.1/8.8.8.8 в
  VM из-за WireGuard и нестабильного DNS-прокси Hyper-V.

**Follow-up:** APP-001 и MON-001 разблокированы; в AUTO-001 — `make verify`
с проверкой кластера.
