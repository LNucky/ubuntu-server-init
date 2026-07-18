#!/usr/bin/env bash

set -Eeuo pipefail

USERNAME="${1:-}"
PASSWORD="${2:-}"

if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: скрипт должен быть запущен от root."
    exit 1
fi

if [[ -z "$USERNAME" ]]; then
    echo "Укажи имя пользователя."
    echo
    echo "Пример:"
    echo "bash install.sh step 'password'"
    exit 1
fi

if [[ -z "$PASSWORD" ]]; then
    read -rsp "Введите пароль для пользователя ${USERNAME}: " PASSWORD
    echo
fi

if [[ "$USERNAME" == "root" ]]; then
    echo "Ошибка: нельзя использовать root в качестве нового пользователя."
    exit 1
fi

ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
USER_HOME="/home/${USERNAME}"
USER_SSH_DIR="${USER_HOME}/.ssh"
USER_AUTHORIZED_KEYS="${USER_SSH_DIR}/authorized_keys"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config.d/99-server-init.conf"

echo
echo "=========================================="
echo "Настройка нового сервера"
echo "Пользователь: ${USERNAME}"
echo "=========================================="
echo

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "[1/8] Обновление системы"

apt-get update

apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confold"

echo "[2/8] Установка пакетов"

apt-get install -y \
    sudo \
    ufw \
    openssh-server \
    curl \
    ca-certificates

echo "[3/8] Создание пользователя"

if id "$USERNAME" &>/dev/null; then
    echo "Пользователь ${USERNAME} уже существует."
else
    useradd \
        --create-home \
        --shell /bin/bash \
        "$USERNAME"
fi

usermod -aG sudo "$USERNAME"

echo "${USERNAME}:${PASSWORD}" | chpasswd

echo "[4/8] Перенос SSH-ключей"

if [[ ! -s "$ROOT_AUTHORIZED_KEYS" ]]; then
    echo
    echo "Ошибка: файл ${ROOT_AUTHORIZED_KEYS} отсутствует или пуст."
    echo "SSH-настройки не будут изменены."
    echo
    echo "Добавь public SSH key root-пользователю при создании сервера"
    echo "и запусти скрипт повторно."
    exit 1
fi

install \
    -d \
    -m 700 \
    -o "$USERNAME" \
    -g "$USERNAME" \
    "$USER_SSH_DIR"

install \
    -m 600 \
    -o "$USERNAME" \
    -g "$USERNAME" \
    "$ROOT_AUTHORIZED_KEYS" \
    "$USER_AUTHORIZED_KEYS"

if [[ ! -s "$USER_AUTHORIZED_KEYS" ]]; then
    echo "Ошибка: SSH-ключ не был перенесён."
    exit 1
fi

if ! cmp -s "$ROOT_AUTHORIZED_KEYS" "$USER_AUTHORIZED_KEYS"; then
    echo "Ошибка: перенесённый SSH-ключ отличается от исходного."
    exit 1
fi

echo "SSH-ключ успешно перенесён."

echo "[5/8] Проверка sudo"

cat > "/etc/sudoers.d/${USERNAME}" <<EOF
${USERNAME} ALL=(ALL:ALL) ALL
EOF

chmod 440 "/etc/sudoers.d/${USERNAME}"

visudo -cf "/etc/sudoers.d/${USERNAME}"

echo "[6/8] Настройка UFW"

ufw allow OpenSSH
ufw --force enable

echo "[7/8] Настройка SSH"

mkdir -p /etc/ssh/sshd_config.d

cat > "$SSHD_CONFIG_FILE" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF

if ! sshd -t; then
    echo "Ошибка в SSH-конфигурации."
    rm -f "$SSHD_CONFIG_FILE"
    exit 1
fi

echo "[8/8] Перезапуск SSH"

systemctl enable ssh
systemctl restart ssh

echo
echo "=========================================="
echo "Сервер успешно настроен"
echo "=========================================="
echo
echo "Новый пользователь: ${USERNAME}"
echo
echo "Проверь подключение в НОВОМ терминале:"
echo
echo "ssh ${USERNAME}@SERVER_IP"
echo
echo "Текущую root-сессию пока не закрывай,"
echo "пока не убедишься, что новый вход работает."
echo
