---
# Main Sync C++
---
## English

`main-sync` is a single C++ binary for bidirectional file synchronization between a local Linux machine and a remote Linux server over SSHFS.

### Features

- one interactive application; no Python runtime and no separate shell menu;
- Russian and English UI;
- configurable server host, SSH port, user, remote home and SSH key;
- Ed25519 key generation and `ssh-copy-id` setup;
- any number of synchronized folders and individual files;
- multi-selection such as `1 2 4`, or `a` for all;
- user-systemd daemon;
- separate online/offline polling intervals;
- lightweight metadata checks plus periodic SHA-256 verification;
- local logging;
- PostgreSQL backup using remote `pg_dump`;
- dump retention;
- lock protection against simultaneous manual and daemon syncs.

### Synchronization rules

1. A file present on only one side is copied to the missing side.
2. If sizes differ, the **larger file is treated as the newer copy**.
3. Equal sizes are compared using SHA-256.
4. If hashes differ, newer `mtime` wins.
5. Equal size + equal mtime + different hashes becomes a conflict.
6. Files are never automatically deleted.

> Important: under the “larger file wins” rule, a genuinely newer edit that made a file smaller can be overwritten by an older larger copy. This behavior is intentionally preserved from the current project logic.

### Start

```bash
main-sync
```

Other commands:

```bash
main-sync --sync
main-sync --dry-run
main-sync --status
main-sync --daemon
main-sync --pg-backup
main-sync --install-service
main-sync --config
```

### Paths

- source: `~/main/i/backubserver/main-sync.cpp`
- binary: `~/main/i/backubserver/main-sync`
- command: `~/.local/bin/main-sync`
- configuration: `~/.config/main-sync/config.ini`
- log: `~/.local/state/main-sync/main-sync.log`
- SSHFS mount: `~/.cache/main-sync-remote`
- systemd unit: `~/.config/systemd/user/main-sync.service`

### PostgreSQL

`pg_dump` must be installed on the remote server. The program supports running it as the SSH account or as `postgres` using non-interactive `sudo -n`. Database passwords are not stored in `config.ini`.

## Русский

`main-sync` — один C++-бинарник для двусторонней синхронизации файлов между локальным Linux-компьютером и удалённым Linux-сервером через SSHFS.

### Возможности

- одно интерактивное меню без Python и без отдельного `.sh`-меню;
- русский и английский интерфейс;
- сервер, SSH-порт, пользователь, remote home и путь к ключу настраиваются из меню;
- генерация Ed25519-ключа и установка ключа через `ssh-copy-id`;
- любое количество синхронизируемых папок и отдельных файлов;
- выбор нескольких пунктов через пробел, например `1 2 4`, либо `a` для всех;
- user-systemd daemon;
- отдельные интервалы проверки для online/offline сервера;
- лёгкая проверка metadata и периодическая полная проверка SHA-256;
- локальный журнал;
- PostgreSQL backup через удалённый `pg_dump`;
- ограничение количества `.dump`-копий;
- блокировка от одновременного ручного и daemon-sync.

### Логика синхронизации

1. Файл существует только с одной стороны — он копируется на отсутствующую сторону.
2. Если размеры отличаются, **больший файл считается новой копией**.
3. Если размеры одинаковые, сравнивается SHA-256.
4. Если SHA-256 различается, побеждает более новый `mtime`.
5. При одинаковом размере, одинаковом времени, но разном SHA-256 файл отмечается как conflict.
6. Автоматического удаления файлов нет.

> Важно: правило «больший файл = новая копия» означает, что новая редакция файла, ставшая меньше старой, может быть заменена старой большей копией. Это сознательно сохранено по текущей логике проекта.

### Запуск

```bash
main-sync
```

Другие команды:

```bash
main-sync --sync
main-sync --dry-run
main-sync --status
main-sync --daemon
main-sync --pg-backup
main-sync --install-service
main-sync --config
```

### Файлы

- исходник: `~/main/i/backubserver/main-sync.cpp`
- бинарник: `~/main/i/backubserver/main-sync`
- команда: `~/.local/bin/main-sync`
- конфиг: `~/.config/main-sync/config.ini`
- лог: `~/.local/state/main-sync/main-sync.log`
- mount: `~/.cache/main-sync-remote`
- systemd: `~/.config/systemd/user/main-sync.service`

### Конфиг

Конфиг создаётся программой автоматически. Его можно менять через меню или вручную.

Пример:

```ini
language=ru
host=84.39.243.205
port=61950
user=localhost
remote_home=/home/localhost
identity_file=~/.ssh/main_sync_ed25519
online_seconds=1
offline_seconds=5
full_verify_seconds=60
postgres_enabled=false
postgres_interval=3600
postgres_retention=10
postgres_root=~/PostgreSQL-backups
root=main/i|~/main/i|~/main/i|true
file=.bashrc|~/.bashrc|~/.bashrc|true
```

Символ `|` зарезервирован как разделитель и не должен использоваться в имени или пути.

### PostgreSQL

На удалённом сервере должен быть установлен `pg_dump`.

Программа поддерживает два режима:

- `ssh` — `pg_dump` запускается от SSH-пользователя;
- `sudo_postgres` — `sudo -n -u postgres pg_dump ...`.

Во втором случае сервер должен разрешать нужную команду без интерактивного sudo-пароля. PostgreSQL-пароли в `config.ini` не сохраняются.

Дампы сначала пишутся как `.part`, а после успешного завершения переименовываются в `.dump`.

### Systemd

Установить/обновить unit можно из меню или:

```bash
main-sync --install-service
systemctl --user restart main-sync.service
```

Для запуска user-service ещё до интерактивного входа можно включить linger:

```bash
sudo loginctl enable-linger "$USER"
```

---


