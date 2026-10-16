# Секреты стенда: SOPS и age

`DEMO_PASSWORD` для sensor-gateway не лежит в git открытым текстом. В кластер он попадает как Secret `sensor-secrets` в namespace `sensor`, ключ `DEMO_PASSWORD`. Helm-чарт берёт этот Secret через `existingSecret` (по умолчанию то же имя `sensor-secrets`). API не стартует, если пароль короче 12 символов.

Версии зафиксированы: sops **3.9.2**, age **1.2.1**. `scripts/secrets-init.sh` скачивает их с GitHub Releases в `~/.local/bin`, проверяет SHA-256 и пропускает загрузку, если эти версии уже стоят.

## Как это устроено

Приватный ключ age лежит в `~/.config/sops/age/keys.txt`. Если задан `XDG_CONFIG_HOME`, и sops 3.9.2, и скрипты смотрят `$XDG_CONFIG_HOME/sops/age/keys.txt`. Это путь по умолчанию у sops, отдельная переменная не нужна. Можно переопределить его через `SOPS_AGE_KEY_FILE` или положить сам ключ в `SOPS_AGE_KEY`.

`.sops.yaml` в корне репозитория. До первого запуска в поле `age` стоит плейсхолдер `AGE_PUBLIC_KEY`. `secrets-init.sh` подставляет туда публичный ключ из `keys.txt`. Пока там плейсхолдер, `sops` шифровать откажется: это не ключ age.

Правило `path_regex` берёт только `deploy/secrets/*.enc.yaml`. `encrypted_regex: ^(data|stringData)$` шифрует значения внутри `data` и `stringData`. Имя Secret, namespace и ключ `DEMO_PASSWORD` в файле читаются без расшифровки. Значение пароля выглядит как `ENC[AES256_GCM,...]`.

`secrets-init.sh` собирает Secret и шифрует его в `deploy/secrets/sensor-secrets.enc.yaml`:

- `metadata.name: sensor-secrets`
- `metadata.namespace: sensor`
- `stringData.DEMO_PASSWORD` — из переменной `DEMO_PASSWORD`, если она задана и не короче 12 символов, иначе 24 символа из `openssl rand -base64 18`

Повторный init не создаёт новый ключ, если `keys.txt` уже есть, и не перезаписывает уже существующий `sensor-secrets.enc.yaml`. Если публичный ключ из `keys.txt` не числится получателем этого файла, скрипт пишет об этом в stderr. Перешифровать файл на другой ключ он сам не станет.

`scripts/secrets-apply.sh` создаёт namespace `sensor`, если его нет, и выполняет:

```bash
sops -d deploy/secrets/sensor-secrets.enc.yaml | kubectl apply -f -
```

`scripts/secrets-rotate.sh` меняет пароль, применяет Secret и перезапускает API. Метка `app.kubernetes.io/component=api` есть и у стабильного релиза, и у канарейки, поэтому рестарт задевает оба Deployment, если оба выкатаны.

Команды sops ищут `.sops.yaml` от текущего каталога вверх. Скрипты сами переходят в корень репозитория. Вручную тоже запускайте их оттуда.

## Что в git, а чего нет

В git:

- `.sops.yaml` — публичный ключ age, не секрет
- `deploy/secrets/sensor-secrets.enc.yaml` — шифротекст, появляется после `secrets-init.sh`
- этот README, `.gitignore` и `scripts/secrets-*.sh`

Не в git и не добавлять:

- `~/.config/sops/age/keys.txt` — приватный ключ age. В репозитории его нет и не должно появиться
- `keys.txt`, если файл случайно положили в `deploy/secrets/` — его закрывает `deploy/secrets/.gitignore`
- `*.dec.yaml` — расшифрованные копии, тот же `.gitignore`
- `.env` со стендом Compose

Публичный ключ из `.sops.yaml` пароль не открывает. Без приватного ключа `sops -d` не работает.

## Первый запуск

Нужны `curl`, `openssl`, `kubectl` и доступ к кластеру. sops и age скрипт поставит сам.

```bash
# необязательно: свой пароль, не короче 12 символов
export DEMO_PASSWORD='stand-password-12'
./scripts/secrets-init.sh
./scripts/secrets-apply.sh
```

Init один раз печатает пароль. В git его после этого нет. Посмотреть снова:

```bash
sops -d deploy/secrets/sensor-secrets.enc.yaml
```

Закоммитить `.sops.yaml` и `deploy/secrets/sensor-secrets.enc.yaml`. Перед `git add` проверить `git status`: `keys.txt` и `*.dec.yaml` в индекс не должны попасть.

На другую машину `keys.txt` копируют мимо git (scp, менеджер паролей) в `~/.config/sops/age/keys.txt` и ставят `chmod 600`. Каталог `~/.config/sops/age` — `chmod 700`. Дальше `./scripts/secrets-init.sh` поставит бинарники и не будет генерировать второй ключ, потому что файл уже на месте. Затем `./scripts/secrets-apply.sh`.

## Ротация DEMO_PASSWORD

Ключ age при этом не меняется.

```bash
./scripts/secrets-rotate.sh
```

Скрипт по шагам:

1. Генерирует 24 символа через `openssl rand -base64 18`.
2. Записывает их в `stringData.DEMO_PASSWORD` командой `sops set`: файл расшифровывается, меняется одно значение, файл шифруется снова.
3. Печатает новый пароль.
4. Применяет Secret так же, как `secrets-apply.sh`.
5. Выполняет `kubectl -n sensor rollout restart deploy -l app.kubernetes.io/component=api`.
6. Ждёт `kubectl -n sensor rollout status` с тем же селектором, таймаут 180 секунд.

После рестарта старые cookie `dts_session` не подходят: сессии API лежат в памяти процесса. Обновлённый `sensor-secrets.enc.yaml` нужно закоммитить. Приватный ключ — нет.

Свой пароль, если не нужен случайный (значение для `sops set` — JSON-строка):

```bash
export PATH="$HOME/.local/bin:$PATH"
sops set deploy/secrets/sensor-secrets.enc.yaml '["stringData"]["DEMO_PASSWORD"]' '"новый-пароль-12"'
./scripts/secrets-apply.sh
kubectl -n sensor rollout restart deploy -l app.kubernetes.io/component=api
kubectl -n sensor rollout status deploy -l app.kubernetes.io/component=api --timeout=180s
```

Кавычку и обратный слэш внутри пароля экранируют как в JSON (`\"`, `\\`). Короче 12 символов в Secret класть нельзя: под API не станет Ready.

## Ротация ключа age

Делается, если ключ утёк или доступ к нему надо забрать. Пока файл не перешифрован, старый приватный ключ не удалять: без него `sops updatekeys` текущий шифротекст не откроет.

Пока в `.sops.yaml` указан получатель, которого ещё нет в `keys.txt`, `secrets-init.sh` не запускать. Он перезапишет строку `age` публичными ключами только из текущего `keys.txt` и сотрёт ручную правку.

Команды из корня репозитория. `sops` и `age-keygen` уже лежат в `~/.local/bin` после init.

1. Снять копию текущего ключа вне репозитория: `cp ~/.config/sops/age/keys.txt ~/age-keys.old` и убрать её в менеджер паролей. `chmod 600 ~/age-keys.old`.
2. Новый ключ писать в другой файл, не поверх старого: `age-keygen -o ~/age-keys.new`. В терминале будет публичный ключ `age1...`. `chmod 600 ~/age-keys.new`.
3. На время перехода sops должен видеть оба приватных ключа. Старый открывает файл, новый шифрует на нового получателя:

```bash
cat ~/age-keys.old ~/age-keys.new > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

4. В `.sops.yaml` в одной строке `age` перечислить оба публичных ключа через запятую, без пробела: `age: age1новый,age1старый`. Это одна группа: расшифровать может любой из двух ключей, а не обязательно оба сразу.
5. Перешифровать: `sops updatekeys -y deploy/secrets/sensor-secrets.enc.yaml`. Флаг `-y` у sops 3.9.2 сразу отвечает «да». Без него sops спрашивает `Is this okay? (y/n):`.
6. Убрать старый публичный ключ из `.sops.yaml`, оставить только новый.
7. Ещё раз `sops updatekeys -y deploy/secrets/sensor-secrets.enc.yaml`, чтобы старый получатель ушёл из метаданных файла.
8. Оставить в рабочем файле только новый ключ: `cp ~/age-keys.new ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt`.
9. Проверка. С новым `keys.txt` команда `sops -d deploy/secrets/sensor-secrets.enc.yaml` показывает Secret. Если подставить только старый ключ, расшифровка должна завершиться ошибкой.
10. Новый `keys.txt` передать тем, кто выкатывает стенд, тем же каналом, что и в первый раз, не через git. Старые копии удалить с машин и из менеджера паролей. Закоммитить `.sops.yaml` и `sensor-secrets.enc.yaml`.

`secrets-init.sh` после этого можно запустить снова. Новый ключ он не создаст, в `.sops.yaml` запишет публичные ключи из текущего `keys.txt`, существующий enc-файл не перезапишет. Если ключ в файле и ключ на диске разъехались, скрипт только предупредит. Перешифровка — это `sops updatekeys`.

## Проверка

```bash
sops -d deploy/secrets/sensor-secrets.enc.yaml | kubectl apply --dry-run=client -f -
kubectl -n sensor get secret sensor-secrets -o jsonpath='{.data.DEMO_PASSWORD}' | base64 -d; echo
```

Без ключа age в `sensor-secrets.enc.yaml` видно `metadata.name: sensor-secrets`. Строка `DEMO_PASSWORD` при этом остаётся `ENC[...]`, не паролем.
