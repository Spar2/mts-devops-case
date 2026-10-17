# Прогон terraform apply (libvirt на box, 2026-10-17)

Хост: Debian 13 в контейнере без systemd (`tini` как pid 1), `/dev/kvm`, вложенный KVM (`/sys/module/kvm_intel/parameters/nested=Y`), `sudo` без пароля. Рядом оператор поднимает k3d. Контейнеры `k3d-*`, сеть docker и правила iptables docker/k3d не менялись. Команды `docker stop` / `docker rm` не выполнялись.

Токен GitHub передавался только через окружение: `TF_VAR_github_token="$(gh auth token)"`. В репозиторий, в этот лог и в вывод команд он не записывался. SSH-ключ для проверки сгенерирован в `/tmp/mts-sensor-ssh` (вне репозитория) и после прогона удалён.

## Пересоздание box

Первая попытка на предыдущем экземпляре box: пакеты libvirt/QEMU уже ставились, рядом работал k3d, `available` было около 4 ГиБ. Демоны libvirt тогда не запускались, `terraform apply` не выполнялся. Экземпляр box затем пересоздали: пакеты и демоны пропали, `/home` и worktree (незакоммиченная правка `run_make_up`) сохранились. Оператор связывает пересоздание с нехваткой памяти при загрузке ВМ. Ниже — повторный прогон на новом экземпляре.

На новом экземпляре перед `apply` было `available` 13433 МиБ (из 16002). Порог на время загрузки: если `available` < 2500 МиБ — `virsh destroy mts-sensor`. Минимум за прогон по опросу раз в 10 с — 11471 МиБ. Порог не сработал, домен из-за памяти не останавливался.

## Хост

Пакеты (повторная установка после пересоздания; `apt-get` с `</dev/null` и `-o Dpkg::Options::=--force-confold`):

| Пакет | Версия |
| --- | --- |
| qemu-system-x86 | 1:10.0.13+ds-0+deb13u1 |
| libvirt-daemon / libvirt-clients | 11.3.0-3+deb13u3 |
| cloud-init (схема на хосте) | 25.1.4-1+deb13u1 |
| genisoimage | 9:1.1.11-4 |
| dnsmasq-base | 2.91-1+deb13u2 |

Terraform 1.9.8 (`~/.local/bin`, sha256 с `terraform_1.9.8_SHA256SUMS`, файл архива `terraform_1.9.8_linux_amd64.zip`). Провайдер из lock-файла: `dmacvicar/libvirt` 0.8.3.

`policy-rc.d` не дал systemd запустить сервисы. Демоны запущены вручную: `virtlogd --daemon`, `virtlockd --daemon`, `libvirtd --daemon`. В конфиге демона для этого контейнера (не в репозитории): `auth_unix_ro/rw = "none"`, сокет группы `libvirt`; в `qemu.conf`: `security_driver = "none"`, `user/group = "root"`, `cgroup_controllers = []`. Иначе polkit и cgroup в контейнере без systemd не пускают домен.

Сеть `default` (NAT `192.168.122.0/24`, мост `virbr0`) и пул `default` (`/var/lib/libvirt/images`) подняты через `virsh`. Модуля `vhost_net` в контейнере нет (`modprobe` не удался, `/dev/vhost-net` отсутствует). QEMU взял tap без vhost, этого хватило.

`terraform fmt -check` и `terraform validate` — успех. `cloud-init schema` для `user-data.example.yaml` и `network-config.yaml` — `Valid schema` (предупреждение хоста без datasource, как и раньше).

## Apply

Каталог `infra/terraform`. Переменные: `vm_memory_mib=2048`, `vm_vcpu=2`, `run_make_up=false`. Диск и образ — как в коде (30 ГиБ, qcow2 поверх Ubuntu 24.04 cloud image). Токен и публичный ключ — из окружения, не из файла репозитория.

```bash
cd infra/terraform
export TF_VAR_github_token="$(gh auth token)"
export TF_VAR_ssh_public_key="$(cat /tmp/mts-sensor-ssh/id_ed25519.pub)"
export TF_VAR_vm_memory_mib=2048
export TF_VAR_vm_vcpu=2
export TF_VAR_run_make_up=false
terraform apply -auto-approve -input=false
```

На этом хосте текущая оболочка ещё не была в группе `libvirt`, поэтому `apply` шёл через `sg libvirt`.

Старт `2026-10-17T06:11:28+00:00`. Через ~39 с:

```text
libvirt_volume.base: Creation complete after 13s
libvirt_cloudinit_disk.sensor: Creation complete after 13s
libvirt_volume.root: Creation complete after 0s
libvirt_domain.sensor: Creation complete after 26s
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
vm_ip = "192.168.122.188"
```

`user_data` в плане — `(sensitive value)`. После `apply` `available` 12609 МиБ.

`virsh dominfo mts-sensor`: State running, CPU(s) 2, Max memory 2097152 KiB. В командной строке QEMU: `-accel kvm`, `-m size=2097152k`, `-smp 2`.

DHCP libvirt и `terraform output -raw vm_ip` совпали:

```text
192.168.122.188/24   mts-sensor   52:54:00:26:bb:f4
tf_output=192.168.122.188
```

## Гость

SSH ключом из `/tmp` под `ubuntu@192.168.122.188`.

```text
status: done
extended_status: done
detail: DataSourceNoCloud [seed=/dev/sr0]
errors: []
recoverable_errors: {}
```

`cloud-init status --long` показывает `last_update: Thu, 01 Jan 1970 00:00:52 +0000`, при этом `date -Is` в госте — `2026-10-17T06:14:14+00:00`, а лог runcmd помечен `2026-10-17T06:12:39+00:00`. Ошибок cloud-init нет.

Гость: Ubuntu 24.04.5 LTS, ядро `6.8.0-142-generic`, cloud-init `26.1-0ubuntu1~24.04.1`.

`sudo netplan get` и `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
  version: 2
  ethernets:
    primary:
      match:
        name: "en*"
      dhcp4: true
```

`ip -4 addr show ens3`: `192.168.122.188/24` (имя `ens3` попадает под `en*`). Исходящий HTTPS есть: `curl -fsSI https://github.com` вернул `HTTP/2 200`.

Пользователь `ubuntu` (uid 1000), группы включают `docker` и `sudo`. Пакеты установлены, `docker` — `active`:

```text
git 1:2.43.0-1ubuntu7.3
make 4.3-4.1build2
curl 8.5.0-2ubuntu10.16
docker.io 29.1.3-0ubuntu3~24.04.2
docker-compose-v2 2.40.3+ds1-0ubuntu1~24.04.1
```

Клон `/home/ubuntu/mts-devops-case`: `origin` = `https://github.com/Spar2/mts-devops-case.git`, `HEAD` = `41e0e4f5e1c1` (ветка `main` на GitHub; в ISO был шаблон из worktree, не этот коммит). `/home/ubuntu/.netrc` и `/root/.config/mts/github-token` после runcmd отсутствуют. В `/var/log/mts-k8s-up.log` вхождений токена нет.

```text
=== mts-k8s-up start 2026-10-17T06:12:39+00:00 ===
git version 2.43.0
GNU Make 4.3
Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1
clone https://github.com/Spar2/mts-devops-case.git -> /home/ubuntu/mts-devops-case
Cloning into '/home/ubuntu/mts-devops-case'...
run_make_up=false: skip make up K3D=0
=== mts-k8s-up done 2026-10-17T06:12:40+00:00 ===
```

## Destroy

`terraform destroy -auto-approve` удалил 4 ресурса (`Destroy complete! Resources: 4 destroyed`). Затем удалены `terraform.tfstate` и `terraform.tfstate.backup`. `virsh list --all` пуст, каталог `/var/lib/libvirt/images` пуст (базовый образ, корневой том и ISO cloud-init удалены). Сеть `default` остановлена и убрана из определений (`virbr0` исчез), пул остановлен, демоны `libvirtd` / `virtlogd` / `virtlockd` остановлены. Правила docker/k3d не сбрасывались.

После destroy `available` 13277 МиБ.

## Что не делалось

- `make up` / `make up K3D=0` внутри ВМ. Для этого прогона `run_make_up=false`. Значение по умолчанию (`true`, 8192 МиБ, 4 vCPU) на живой ВМ не проверялось: параллельно ожидался k3d (~4 ГиБ), порог памяти — 2500 МиБ available.
- ВМ 8 ГиБ и OpenStack не запускались. Нативный `make up K3D=0` по-прежнему только в e2e GitHub Actions.
- `k3d-mts-server-0` и `k3d-mts-serverlb` были Up в начале прогона и этими командами не останавливались. К моменту `destroy` в `docker ps` их уже не было; сразу после появился стартующий `k3d-mts-tools` — это не часть прогона.

Повторный `terraform apply` после этого прогона не выполнялся. k3d снова работает, вторая ВМ не создавалась. Итог по IaC — один живой прогон выше: 2048 МиБ, 2 vCPU, `run_make_up=false`, затем `terraform destroy`.
