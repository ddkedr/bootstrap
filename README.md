# bootstrap

Интерактивная первичная настройка новой машины на Ubuntu или Debian:
hostname, обновление, пользователь с sudo, SSH-ключи из GitHub, sshd
hardening, ufw, fail2ban, автообновления безопасности, Docker, journald,
swap, timezone. В начале выбирается профиль: `cloud` для VPS с публичным
адресом (защитные шаги по умолчанию включены) или `local` для VM/CT за NAT
(по умолчанию выключены); любой шаг можно подтвердить или пропустить.

Запуск из консоли свежей машины под root, одной строкой:

```bash
apt-get update -qq && apt-get install -y -qq curl && curl -fsSL https://raw.githubusercontent.com/ddkedr/bootstrap/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh
```

Минимальные образы CT и VM идут без `curl`, поэтому он ставится первым;
если он уже есть, первые две команды ничего не меняют.

На уже работающем сервере, из сессии пользователя с sudo, та же строка с
`sudo` (на свежей машине `sudo` может быть не установлен, его ставит сам
скрипт):

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq curl && curl -fsSL https://raw.githubusercontent.com/ddkedr/bootstrap/main/bootstrap.sh -o bootstrap.sh && sudo bash bootstrap.sh
```

Скрипт скачивается на диск, а не течёт в `bash` из curl: его можно
посмотреть перед запуском и прогнать повторно, он рассчитан на это
(существующего пользователя не пересоздаёт, ключи не дублирует).

Это серверная половина схемы SSH-ключей; ноутбучная половина, команда
`keymaster`, и вся документация живут в приватном репозитории `keymaster`.
В конце bootstrap печатает готовую строку `keymaster server-add` для
ноутбука.
