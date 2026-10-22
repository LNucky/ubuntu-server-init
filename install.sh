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
    while true; do
        read -rsp "Введите пароль для пользователя ${USERNAME}: " PASSWORD
        echo
        read -rsp "Повторите пароль: " PASSWORD_CONFIRM
        echo

        if [[ -z "$PASSWORD" ]]; then
            echo "Пароль не может быть пустым."
            echo
            continue
        fi

        if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
            break
        fi

        echo "Пароли не совпадают. Попробуйте ещё раз."
        echo
    done

    unset PASSWORD_CONFIRM
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

detect_server_ip() {
    local ip=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ ip _ <<< "${SSH_CONNECTION}"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    if [[ -z "$ip" ]]; then
        ip="SERVER_IP"
    fi

    echo "$ip"
}

echo
echo "=========================================="
echo "Настройка нового сервера"
echo "Пользователь: ${USERNAME}"
echo "=========================================="
echo

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "[1/9] Обновление системы"

apt-get update

apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confold"

echo "[2/9] Установка пакетов"

apt-get install -y \
    sudo \
    ufw \
    openssh-server \
    curl \
    ca-certificates \
    gnupg

echo "[3/9] Создание пользователя"

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

echo "[4/9] Перенос SSH-ключей"

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

echo "[5/9] Проверка sudo"

cat > "/etc/sudoers.d/${USERNAME}" <<EOF
${USERNAME} ALL=(ALL:ALL) ALL
EOF

chmod 440 "/etc/sudoers.d/${USERNAME}"

visudo -cf "/etc/sudoers.d/${USERNAME}"

echo "[6/9] Настройка UFW"

ufw allow OpenSSH
ufw --force enable

echo "[7/9] Установка Docker"

apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | tee /etc/apt/keyrings/docker.asc > /dev/null

chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

if dpkg-query -W -f='${Status}' docker.io containerd runc 2>/dev/null \
    | grep -q "install ok installed"; then
    echo "Удаление Docker из репозитория Ubuntu (конфликтует с docker-ce)..."

    systemctl stop docker.service docker.socket containerd 2>/dev/null || true
    systemctl disable docker.socket 2>/dev/null || true

    apt-get remove -y \
        docker.io \
        docker-doc \
        docker-compose \
        docker-compose-v2 \
        podman-docker \
        containerd \
        runc
fi

apt-get update

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl daemon-reload
systemctl enable containerd docker
systemctl start containerd
systemctl start docker

for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! docker info >/dev/null 2>&1; then
    echo
    echo "Ошибка: Docker daemon не запустился."
    systemctl status docker --no-pager || true
    exit 1
fi

usermod -aG docker "$USERNAME"

docker run --rm hello-world
docker compose version

echo "[8/9] Настройка SSH"

mkdir -p /etc/ssh/sshd_config.d

cat > "$SSHD_CONFIG_FILE" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM yes
EOF

# На свежей системе каталог ещё не создан: systemd делает это только
# при старте ssh, а sshd -t проверяет его сразу и из-за этого падает.
install -d -m 0755 /run/sshd

if ! sshd -t; then
    echo "Ошибка в SSH-конфигурации."
    rm -f "$SSHD_CONFIG_FILE"
    exit 1
fi

echo "[9/9] Перезапуск SSH"

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
echo "ssh ${USERNAME}@$(detect_server_ip)"
echo
echo "После входа проверь Docker:"
echo
echo "docker run hello-world && docker compose version"
echo
echo "Текущую root-сессию пока не закрывай,"
echo "пока не убедишься, что новый вход работает."
echo
