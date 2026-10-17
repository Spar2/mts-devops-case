# ВМ libvirt для стенда sensor-gateway

Одна виртуальная машина Ubuntu 24.04 в локальном libvirt (KVM). При первой загрузке cloud-init ставит пакеты, клонирует репозиторий и, если `run_make_up` истинно (значение по умолчанию), от пользователя `ubuntu` запускает `make up K3D=0`. Лог гостя: `/var/log/mts-k8s-up.log`.

Каталог `infra/ansible` — отдельный путь: плейбук для уже существующего хоста. Здесь создаётся сама ВМ.

## Состав

| Файл | Назначение |
| --- | --- |
| `infra/cloud-init/user-data.yaml.tftpl` | Шаблон cloud-config. Его рендерит `templatefile` |
| `infra/cloud-init/user-data.example.yaml` | Пример рендера с плейсхолдерами, для `cloud-init schema` |
| `infra/terraform/` | Провайдер `dmacvicar/libvirt` `~> 0.8.1`, Terraform `>= 1.6` |

## Параметры ВМ

| | |
| --- | --- |
| Домен | `mts-sensor` |
| vCPU | 4 по умолчанию (`vm_vcpu`) |
| RAM | 8 ГиБ по умолчанию (`vm_memory_mib=8192`) |
| Диск | 30 ГиБ, qcow2 поверх базового тома |
| Образ | `https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img` |
| Пул и сеть | `default` |
| Пользователь гостя | `ubuntu` |

URL образа — официальный поток release Ubuntu 24.04 (`releases/24.04/release/`). Имя файла стабильное, содержимое обновляется вместе с point-release.

## Что нужно на хосте

- Linux с KVM, libvirt и URI `qemu:///system`. Пользователь, который запускает Terraform, входит в группу `libvirt`.
- Пул `default` и сеть `default` (NAT, dnsmasq). IP в `output` берётся из DHCP-аренды этой сети.
- Свободная память сверх 8 ГиБ гостя. `make up K3D=0` внутри ВМ рассчитан на 6–8 ГиБ.
- Terraform `>= 1.6`. Ниже — установка 1.9.8 в `~/.local/bin` (linux amd64):

Имя файла в `SHA256SUMS` — `terraform_1.9.8_linux_amd64.zip`. Архив нужно сохранить под ним же: если назвать его иначе, `sha256sum -c --ignore-missing` ничего не проверит и завершится с ошибкой.

```bash
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/terraform_1.9.8_linux_amd64.zip" \
  https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
curl -fsSL -o "$tmp/SHA256SUMS" \
  https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS
(cd "$tmp" && sha256sum -c --ignore-missing SHA256SUMS)
unzip -d "$tmp" "$tmp/terraform_1.9.8_linux_amd64.zip"
install -m 0755 "$tmp/terraform" ~/.local/bin/terraform
```

Схема cloud-init: `sudo apt-get install -y cloud-init`.

## Запуск

Репозиторий приватный. Токен передаётся переменной и попадает в cloud-init только при `apply`. В git его нет.

```bash
cd infra/terraform
terraform init
terraform apply \
  -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var "github_token=$GITHUB_TOKEN"
terraform output vm_ip
```

Тот же токен можно задать через `TF_VAR_github_token`. Файл `terraform.tfvars` с токеном не коммитить. Каталоги `.terraform/` и `terraform.tfstate` локальные. В репозитории остаётся `.terraform.lock.hcl`: провайдер зафиксирован на `0.8.3` при ограничении `~> 0.8.1`.

| Переменная | По умолчанию | Смысл |
| --- | --- | --- |
| `repo_url` | `https://github.com/Spar2/mts-devops-case.git` | Что клонировать |
| `github_token` | пустая строка, `sensitive` | Токен GitHub для HTTPS. Пустая строка — clone без авторизации |
| `ssh_public_key` | пустая строка | Ключ в `~ubuntu/.ssh/authorized_keys`. Пустая строка — ключ не добавляется |
| `libvirt_uri` | `qemu:///system` | Куда подключается провайдер |
| `vm_vcpu` | `4` | Число vCPU |
| `vm_memory_mib` | `8192` | RAM ВМ в МиБ |
| `run_make_up` | `true` | После клона запустить `make up K3D=0`. `false` — только пакеты, пользователь и клон |

`github_token` и `repo_url` без перевода строки. В URL нет одинарной кавычки: он подставляется в одинарные кавычки shell.

Для малой ВМ без k3s в госте: `-var vm_memory_mib=2048 -var vm_vcpu=2 -var run_make_up=false`. По умолчанию `run_make_up=true`, ресурсы — 4 vCPU и 8192 МиБ.

`terraform apply` ждёт DHCP-аренду и после этого показывает IP. При `run_make_up=true` команда `make up K3D=0` к этому моменту ещё выполняется в госте. Дальше:

```bash
ssh ubuntu@$(cd infra/terraform && terraform output -raw vm_ip)
sudo tail -f /var/log/mts-k8s-up.log
```

Гостю нужен исходящий HTTPS: GitHub, `get.k3s.io`, репозитории Helm.

## Первая загрузка

1. Пакеты `git`, `make`, `curl`, `docker.io`, `docker-compose-v2`.
2. Группа `docker` создаётся до пользователя. `ubuntu` — default user облачного образа — входит в неё (`users` и повторный `usermod` в `runcmd`, уже после установки пакета).
3. Клон `repo_url` в `/home/ubuntu/mts-devops-case` от `ubuntu`. Если токен задан, на время clone пишется `/home/ubuntu/.netrc` (`login x-access-token`), затем файл удаляется. В лог токен не попадает.
4. Если `run_make_up` истинно (по умолчанию) — `sudo -u ubuntu make up K3D=0`. stdout и stderr — `/var/log/mts-k8s-up.log`. При `false` в тот же лог пишется `run_make_up=false: skip make up K3D=0`, k3s не запускается.

`runcmd` cloud-init записывает в config-стадии, а выполняет `scripts-user` в final-стадии, после установки пакетов.

## Что проверяется

Локальные проверки ниже читают файлы и не создают ВМ. Живой прогон — следом и в `docs/iac-apply-log.md`.

```bash
terraform fmt -check -recursive infra/terraform
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate
cloud-init schema -c infra/cloud-init/user-data.example.yaml
```

Те же команды и `cloud-init schema --schema-type network-config` выполняет job `iac` в `.github/workflows/ci.yml` (Terraform 1.9.8, cloud-init из архива Ubuntu 24.04, локально проверено 26.1; job зелёный на GitHub, pull request #3). `user-data.yaml.tftpl` в `cloud-init schema` не проходит: это шаблон `templatefile`, не готовый cloud-config.

- `terraform validate` проверяет синтаксис HCL, ссылки между ресурсами и аргументы провайдера `dmacvicar/libvirt` `~> 0.8.1`: один домен, том 30 ГиБ, cloud-init из `user-data.yaml.tftpl`. vCPU, RAM и `run_make_up` — переменные; по умолчанию 4, 8192 и `true`.
- `cloud-init schema` сверяет пример рендера со схемой cloud-config. Пример — ветка `run_make_up=true`: URL репозитория, плейсхолдер `__GITHUB_TOKEN__` и строка-заглушка SSH-ключа. Это вход для схемы, не секрет и не ключ доступа. На хосте без datasource cloud-init пишет предупреждение и при успехе печатает `Valid schema`.

Живой `terraform apply` на box (2026-10-17) записан в `docs/iac-apply-log.md`. Домен `mts-sensor` загрузился при `vm_memory_mib=2048`, `vm_vcpu=2`, `run_make_up=false`: cloud-init `status: done`, netplan из `network-config.yaml` (DHCP, `match: en*`), пользователь `ubuntu`, пакеты, клон, `terraform output vm_ip` совпал с DHCP-арендой. После проверки — `terraform destroy`, state и тома удалены. `make up K3D=0` внутри этой ВМ не выполнялся. Значения по умолчанию (8 ГиБ / 4 vCPU / `run_make_up=true`) на живой ВМ не проверялись. Хост прогона — контейнер Debian 13 без systemd: демоны libvirt запускались вручную, подробности только в логе. Повторный apply после возврата k3d не делался: в логе один прогон.

Рендер с пустым токеном и пустым ключом тоже проходит схему. В git лежит вариант с плейсхолдерами.

## Сеть (netplan) и OpenStack

- `infra/cloud-init/network-config.yaml` — netplan (network-config v2): DHCP на `en*`, рядом закомментирован
  статический вариант. Terraform передаёт его в cloud-init диск. Схема: `cloud-init schema --schema-type network-config -c infra/cloud-init/network-config.yaml`.
  На живой ВМ 2026-10-17 файл стал `/etc/netplan/50-cloud-init.yaml` (`dhcp4: true`, `match: en*`), адрес совпал с DHCP libvirt (`docs/iac-apply-log.md`).
- Целевой стек кейса — OpenStack + Kubernetes. Тот же `user-data` подходит для OpenStack Nova без изменений
  (`openstack server create --image ubuntu-24.04 --flavor <8GB> --user-data user-data.yaml …`): сеть инстанс получает
  из metadata Neutron, поэтому `network-config.yaml` там не нужен. Доступа к OpenStack-облаку у команды не было,
  поэтому этот путь не запускался; проверен локальный эквивалент — `make up K3D=0` на Ubuntu 24.04 в GitHub Actions (job e2e).
