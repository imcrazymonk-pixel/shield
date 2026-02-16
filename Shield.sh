#!/bin/bash

# ==============================================================================
# РАЗДЕЛ 1: ВИЗУАЛЬНОЕ ОФОРМЛЕНИЕ И ПЕРЕМЕННЫЕ
# ==============================================================================

# --- Цветовая палитра ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Иконки для интерфейса ---
ICON_ROCKET="🚀"
ICON_GEAR="⚙️ "
ICON_USER="👤"
ICON_KEY="🔑"
ICON_SHIELD="🛡️ "
ICON_SEARCH="🔎"
ICON_CHECK="✅"
ICON_ERROR="❌"
ICON_INFO="ℹ️ "
ICON_GLOBE="🌍"
ICON_LOCK="🔒"
ICON_DOCKER="🐳"
ICON_DISK="💾"

# ==============================================================================
# РАЗДЕЛ 2: НАСТРОЙКА ЛОГИРОВАНИЯ
# ==============================================================================

LOG_FILE="/root/vps_install.log"
# Удаляем старый лог, если он существует, для чистого старта
rm -f "$LOG_FILE"

# Перенаправляем стандартный вывод (stdout) и ошибки (stderr)
# одновременно на экран и в лог-файл
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${ICON_INFO} Лог установки записывается в файл: ${BOLD}$LOG_FILE${RESET}"

# ==============================================================================
# РАЗДЕЛ 3: ОБРАБОТКА ОШИБОК И ФУНКЦИЯ ОТКАТА (ROLLBACK)
# ==============================================================================

# Функция выполняется, если скрипт завершился с ошибкой.
# Она пытается вернуть систему в исходное состояние.
rollback() {
    # Отключаем перехват ошибок, чтобы не зациклить функцию
    trap - ERR SIGINT SIGTERM
    local exit_code=$?
    local line_no=$1
    
    echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${ICON_ERROR} ${BOLD}КРИТИЧЕСКАЯ ОШИБКА (Строка $line_no, Код выхода: $exit_code)${RESET}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    
    # --- 3.1. Вывод последних строк лога ---
    if [ ! -z "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}📜 ПОСЛЕДНИЕ ЗАПИСИ ИЗ ЛОГА ($LOG_FILE):${RESET}"
        echo -e "${CYAN}----------------------------------------${RESET}"
        tail -n 15 "$LOG_FILE"
        echo -e "${CYAN}----------------------------------------${RESET}"
    else
        echo -e "${YELLOW}📜 Лог файл не найден или не задан.${RESET}"
    fi

    echo -e "${YELLOW}🔄 [ROLLBACK] Начинаю процедуру аварийного отката изменений...${RESET}"

    # --- 3.2. Очистка Docker и файлов проекта ---
    # Если была создана папка проекта — останавливаем контейнеры и удаляем папку
    if [ -d "/root/myserver" ]; then
        echo -e "   ├─ Остановка контейнеров и удаление рабочих файлов..."
        if command -v docker &> /dev/null; then
            cd /root/myserver && docker compose down >/dev/null 2>&1
        fi
        rm -rf /root/myserver
    fi

    # --- 3.3. Удаление SWAP файла ---
    # Если файл подкачки прописан в fstab — отключаем и удаляем
    if grep -q "/swapfile" /etc/fstab; then
        echo -e "   ├─ Удаление SWAP файла..."
        swapoff /swapfile >/dev/null 2>&1
        sed -i '/\/swapfile/d' /etc/fstab
        rm -f /swapfile
    fi

    # --- 3.4. Удаление конфигов безопасности ---
    # Удаляем созданные конфигурации Fail2Ban и Auditd
    if [ -f /etc/fail2ban/jail.local ]; then
        rm -f /etc/fail2ban/jail.local
        echo -e "   ├─ Настройки Fail2Ban удалены."
    fi
    if [ -f /etc/audit/rules.d/audit.rules ]; then
        rm -f /etc/audit/rules.d/audit.rules
        echo -e "   ├─ Правила Auditd удалены."
    fi

    # --- 3.5. Восстановление системных конфигов ---
    # Восстанавливаем SSH конфиг из бэкапа
    if [ -f /etc/ssh/sshd_config.bak ]; then
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        echo -e "   ├─ Оригинальный конфиг SSH восстановлен."
        systemctl restart ssh >/dev/null 2>&1
    fi
    
    # Восстанавливаем sysctl (ядро) из бэкапа
    if [ -f /etc/sysctl.conf.bak ]; then
        cp /etc/sysctl.conf.bak /etc/sysctl.conf
        echo -e "   ├─ Настройки ядра (sysctl) восстановлены."
        sysctl -p >/dev/null 2>&1
    fi

    # Удаляем файл харденинга сети
    if [ -f /etc/sysctl.d/99-vpn-hardening.conf ]; then
        rm /etc/sysctl.d/99-vpn-hardening.conf
        echo -e "   ├─ Файл hardening ядра удален."
        sysctl --system >/dev/null 2>&1
    fi
    
    # Восстанавливаем настройки DNS (resolved.conf)
    if [ -f /etc/systemd/resolved.conf.orig ]; then
        mv /etc/systemd/resolved.conf.orig /etc/systemd/resolved.conf
        echo -e "   ├─ Настройки DNS восстановлены."
        systemctl restart systemd-resolved >/dev/null 2>&1
    fi

    # --- 3.6. Сброс сети ---
    ufw disable >/dev/null 2>&1
    echo -e "   ├─ Firewall (UFW) аварийно отключен."
    echo -e "${RED}⚠️  Скрипт завершен аварийно. Полный лог: $LOG_FILE${RESET}"
    exit 1
}

# Назначаем ловушку (trap): при любой ошибке вызывать функцию rollback
trap 'rollback $LINENO' ERR SIGINT SIGTERM

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${ICON_ERROR} ${RED}Запустите этот скрипт от имени root!${RESET}"
  exit
fi

# ==============================================================================
# РАЗДЕЛ 4: ИНИЦИАЛИЗАЦИЯ
# ==============================================================================

echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${ICON_ROCKET}  ${BOLD}ULTIMATE VPS SETUP (Defender + Docker Stack)${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# Установка curl, если отсутствует (необходимо для определения IP)
if ! command -v curl &> /dev/null; then
    apt-get update -qq && apt-get install -y curl -qq >/dev/null 2>&1
fi
# Определение внешнего IP-адреса сервера
MY_IP=$(curl -s ifconfig.me)

echo -e "${ICON_GEAR} [INIT] Создаю резервные копии конфигов (Backup)..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null
cp /etc/sysctl.conf /etc/sysctl.conf.bak 2>/dev/null
echo -e "   └─ ${GREEN}Backups созданы (SSH, Sysctl)${RESET}"
echo ""

# ==============================================================================
# РАЗДЕЛ 5: СБОР ДАННЫХ ОТ ПОЛЬЗОВАТЕЛЯ
# ==============================================================================

# 5.1 Настройка имени хоста
echo -e "${ICON_GLOBE} ${BOLD}Настройка системы${RESET}"
current_host=$(hostname)
read -p "   ├─ Новое имя сервера [Enter = $current_host]: " NEW_HOSTNAME
NEW_HOSTNAME=${NEW_HOSTNAME:-$current_host}

# 5.2 Настройка часового пояса
read -p "   ├─ Таймзона [Enter = Europe/Moscow]: " NEW_TZ
NEW_TZ=${NEW_TZ:-Europe/Moscow}
echo ""

# 5.3 Создание нового пользователя (безопасность)
echo -e "${ICON_USER} ${BOLD}Настройка пользователя${RESET}"
read -p "   ├─ Имя нового sudo-пользователя: " NEW_USER
read -s -p "   ├─ Пароль для $NEW_USER: " NEW_PASS
echo ""
echo -e "   └─ ${GREEN}Пароль принят${RESET}"
echo ""

# 5.4 Настройка порта SSH
echo -e "${ICON_KEY} ${BOLD}Безопасность SSH${RESET}"
read -p "   ├─ Новый SSH порт (например, 2222): " SSH_PORT
echo ""

# ==============================================================================
# РАЗДЕЛ 6: НАСТРОЙКА СИСТЕМЫ И ЯДРА (HARDENING)
# ==============================================================================
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "📦 ${BOLD}ЭТАП 1: БАЗОВАЯ НАСТРОЙКА И ЯДРО...${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# --- 6.1. Базовые настройки (Hostname, Timezone, Hosts) ---
hostnamectl set-hostname "$NEW_HOSTNAME"
timedatectl set-timezone "$NEW_TZ"
# Обновляем /etc/hosts для корректного разрешения имени
sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
echo -e "${ICON_CHECK} Система: Hostname, Timezone, /etc/hosts обновлены"

# --- 6.2. Тюнинг ядра и сетевая безопасность (Sysctl) ---
echo -e "${ICON_LOCK} Настройка ядра (Sysctl Hardening)..."

# Создаем файл конфигурации с параметрами безопасности и производительности
cat <<EOF > /etc/sysctl.d/99-vpn-hardening.conf
# === ПРОИЗВОДИТЕЛЬНОСТЬ И VPN ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
# === СЕТЕВАЯ БЕЗОПАСНОСТЬ ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# === БЕЗОПАСНОСТЬ ЯДРА ===
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_fifos = 2
fs.protected_regular = 2
dev.tty.ldisc_autoload = 0
kernel.modules_disabled = 0 
kernel.sysrq = 0
net.ipv6.conf.all.disable_ipv6 = 0
EOF

# Применяем параметры sysctl
sysctl --system >/dev/null 2>&1 || true

# Увеличиваем лимиты открытых файлов (важно для нагруженных серверов)
cat <<EOF >> /etc/security/limits.conf
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF
echo -e "${ICON_CHECK} Sysctl: BBR, Forwarding + защита ядра применены"

# --- 6.3. Настройка SWAP (Файл подкачки) ---
if [ ! -f /swapfile ]; then
    echo -e "${ICON_DISK} Создаю SWAP файл (2GB)..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${ICON_CHECK} SWAP создан и активирован"
else
    echo -e "${ICON_INFO} SWAP уже существует, пропускаю."
fi

# ==============================================================================
# РАЗДЕЛ 7: УСТАНОВКА ПО И СТЕКА (DOCKER + APPS)
# ==============================================================================
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "🐳 ${BOLD}ЭТАП 2: УСТАНОВКА ПО И СТЕКА (AdGuard/3X-UI)...${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# --- 7.1. Обновление системы и зависимостей ---
echo -e "${ICON_GEAR} Подготовка системы..."
export DEBIAN_FRONTEND=noninteractive

# Обновление списков пакетов
echo -ne "   ├─ Обновление списков пакетов...\r"
# Используем '|| true', чтобы скрипт не падал при некритичных предупреждениях apt
if apt-get update >> "$LOG_FILE" 2>&1; then
    echo -e "   ├─ [${GREEN}OK${RESET}] Обновление списков пакетов        "
else
    echo -e "   ├─ [${YELLOW}WARN${RESET}] Ошибки обновления (см. лог)     "
fi

# Обновление установленных программ
echo -ne "   ├─ Обновление установленных программ...\r"
if apt-get dist-upgrade -y >> "$LOG_FILE" 2>&1; then
    echo -e "   ├─ [${GREEN}OK${RESET}] Обновление установленных программ "
else
     echo -e "   ├─ [${YELLOW}WARN${RESET}] Ошибки обновления (см. лог)     "
fi

# Список пакетов для установки
PACKAGES=(
    unattended-upgrades
    fail2ban
    auditd
    rkhunter
    git
    curl
    wget
    gnupg
    ufw
    libpam-tmpdir
    apt-listchanges
    debsums
    mc
    net-tools
    htop
    btop
    ncdu
    dnsutils
    zip
    unzip
    jq
    neofetch
)
TOTAL=${#PACKAGES[@]}
CURRENT=0

# Функция ожидания освобождения блокировок APT
# Предотвращает ошибки, если apt занят другим процессом
wait_for_apt() {
    command -v fuser >/dev/null 2>&1 || return 0
    
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        echo -ne "   ⏳ Жду освобождения apt...\r"
        sleep 2
    done
    return 0 
}

# Цикл установки пакетов
for pkg in "${PACKAGES[@]}"; do
    ((++CURRENT))
    PERCENT=$((CURRENT * 100 / TOTAL))
    
    echo -ne "   ├─ [${PERCENT}%] Установка: ${BLUE}${pkg}${RESET}...\r"
    
    wait_for_apt
    
    # Устанавливаем пакет. В случае ошибки вызываем rollback.
    if apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
        echo -e "   ├─ [${GREEN}OK${RESET}] Установка: ${BOLD}${pkg}${RESET}           "
    else
        echo -e "\n${RED}[ERROR] Не удалось установить пакет: $pkg${RESET}"
        rollback $LINENO
    fi
done

# Обновление базы данных rkhunter (Rootkit Hunter)
rkhunter --propupd >> "$LOG_FILE" 2>&1 || true

# --- 7.2. Исправление для порта 53 (AdGuard) ---
echo -e "${ICON_GEAR} Освобождение порта 53 для AdGuard..."
# Отключаем DNSStubListener, чтобы systemd-resolved не занимал порт 53
sed -r -i.orig 's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
sh -c 'rm /etc/resolv.conf && ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf'
systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1 || true
echo -e "${ICON_CHECK} Порт 53 освобожден."

# --- 7.3. Установка Docker ---
if ! command -v docker &> /dev/null; then
    echo -ne "   ├─ Установка ${BLUE}Docker Engine${RESET} (Подождите)...\r"
    curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
    echo -e "   ├─ [${GREEN}OK${RESET}] Установка ${BLUE}Docker Engine${RESET} завершена!     "
else
    echo -e "${ICON_INFO} Docker уже установлен"
fi

# --- 7.4. Создание структуры директорий проекта ---
echo -e "${ICON_DISK} Создание структуры папок..."
BASE_DIR="/root/myserver"
mkdir -p $BASE_DIR/xui/db
mkdir -p $BASE_DIR/xui/log
mkdir -p $BASE_DIR/adguard/work
mkdir -p $BASE_DIR/adguard/conf
mkdir -p $BASE_DIR/bot

# --- 7.5. Генерация файлов для бота ---
# Создаем Dockerfile
cat > $BASE_DIR/bot/Dockerfile <<EOF
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "main.py"]
EOF

# Создаем заглушку main.py
cat > $BASE_DIR/bot/main.py <<EOF
import time
print("Bot container is running! Replace these files with your code.")
while True:
    time.sleep(60)
EOF
# Создаем пустой requirements.txt
touch $BASE_DIR/bot/requirements.txt

# --- 7.6. Генерация Docker Compose файла ---
cat > $BASE_DIR/docker-compose.yml <<EOF
services:
  # --- VPN (3X-UI) ---
  xui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: xui
    restart: always
    network_mode: host
    volumes:
      - ./xui/db:/etc/x-ui
      - ./xui/log:/var/log/x-ui
    environment:
      - XRAY_VMESS_AEAD_FORCED=false

  # --- AdGuard Home ---
  adguard:
    image: adguard/adguardhome
    container_name: adguard
    restart: always
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf

  # --- Telegram Bot ---
  mybot:
    build: ./bot
    container_name: telegram_bot
    restart: always
EOF

# --- 7.7. Запуск контейнеров ---
echo -e "${ICON_ROCKET} Запуск контейнеров..."
cd $BASE_DIR
# Запускаем сборку и старт в фоновом режиме
if docker compose up -d --build >> "$LOG_FILE" 2>&1; then
    echo -e "${ICON_CHECK} Контейнеры запущены."
else
    echo -e "\n${RED}[ERROR] Ошибка запуска Docker Compose${RESET}"
    exit 1
fi

# ==============================================================================
# РАЗДЕЛ 8: ФИНАЛЬНАЯ ЗАЩИТА (SSH, AUDIT, FIREWALL)
# ==============================================================================
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "🛡️ ${BOLD}ЭТАП 3: ФИНАЛЬНАЯ ЗАЩИТА (SSH + UFW)...${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# --- 8.1. Настройка Auditd (системный аудит) ---
cat <<EOF > /etc/audit/rules.d/audit.rules
-D
-b 8192
--backlog_wait_time 60000
-f 1
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
EOF
systemctl enable auditd &>/dev/null
service auditd restart 2>/dev/null || systemctl restart auditd

# --- 8.2. Очистка системы и создание пользователя ---
# Удаление Postfix (почтовый сервер часто не нужен и уязвим)
if systemctl is-active --quiet postfix; then systemctl stop postfix; fi
apt-get purge postfix -y -qq >/dev/null 2>&1

# Удаление остатков удаленных пакетов
dpkg --list | grep '^rc' | awk '{ print $2 }' | xargs -r apt-get -y purge >/dev/null 2>&1
apt-get autoremove -y -qq >/dev/null 2>&1

# Ограничение прав доступа к компиляторам (для безопасности)
chmod 700 /usr/bin/as 2>/dev/null || true
chmod 700 /usr/bin/gcc* 2>/dev/null || true
chmod 700 /usr/bin/make 2>/dev/null || true

# Создание/Обновление пользователя
if id "$NEW_USER" &>/dev/null; then
    echo "$NEW_USER:$NEW_PASS" | chpasswd
else
    useradd -m -s /bin/bash -G sudo "$NEW_USER"
    echo "$NEW_USER:$NEW_PASS" | chpasswd
    usermod -aG docker "$NEW_USER"
    echo -e "${ICON_CHECK} Пользователь ${BOLD}$NEW_USER${RESET} создан (+docker group)"
fi

# --- 8.3. Конфигурация SSH ---
# Меняем порт и отключаем root-login
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config

# Если SSH работает через socket (особенность некоторых Ubuntu), отключаем его
if systemctl is-active --quiet ssh.socket; then
    systemctl stop ssh.socket
    systemctl disable ssh.socket
fi

echo -e "   ├─ Принудительное включение службы SSH..."
systemctl unmask ssh 2>/dev/null || true
systemctl enable ssh
systemctl restart ssh

if systemctl is-active --quiet ssh; then
    echo -e "   └─ ${GREEN}SSH Service успешно запущен${RESET}"
else
    echo -e "   └─ ${RED}ОШИБКА: SSH Service не стартовал! Проверьте конфиг: sshd -t${RESET}"
fi

# Установка баннера при входе
echo "***************************************************************************" > /etc/issue.net
echo "                          NOTICE TO USERS" >> /etc/issue.net
echo "This is a private system. Unauthorized access is prohibited." >> /etc/issue.net
echo "All activities may be monitored and recorded." >> /etc/issue.net
echo "***************************************************************************" >> /etc/issue.net
cp /etc/issue.net /etc/issue

# Функция для безопасного изменения параметров SSH
set_ssh_param() {
    local param=$1
    local value=$2
    local config="/etc/ssh/sshd_config"
    if grep -q "^#\?${param}" "$config"; then
        sed -i "s|^#\?${param}.*|${param} ${value}|" "$config"
    else
        echo "${param} ${value}" >> "$config"
    fi
}
# Применение Hardening настроек для SSH
set_ssh_param "AllowTcpForwarding" "yes"
set_ssh_param "X11Forwarding" "no"
set_ssh_param "AllowAgentForwarding" "no"
set_ssh_param "MaxAuthTries" "3"
set_ssh_param "MaxSessions" "2"
set_ssh_param "TCPKeepAlive" "no"
set_ssh_param "UseDNS" "no"
set_ssh_param "LogLevel" "VERBOSE"
set_ssh_param "Banner" "/etc/issue.net"
set_ssh_param "ClientAliveCountMax" "2"
set_ssh_param "Compression" "no"

# --- 8.4. Настройка Fail2Ban (Защита от подбора паролей) ---
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 10m
findtime  = 10m
maxretry = 3
ignoreip = 127.0.0.1/8 ::1 $MY_IP

[sshd]
enabled = true
port = $SSH_PORT
mode = aggressive
backend = systemd
EOF
systemctl enable fail2ban &>/dev/null
systemctl restart fail2ban

# --- 8.5. Настройка Firewall (UFW) ---
echo -e "${ICON_SHIELD} Настраиваю UFW (SSH + App Ports)..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null # Блокируем входящие
ufw default allow outgoing &>/dev/null # Разрешаем исходящие

# Разрешаем новый порт SSH
ufw allow "$SSH_PORT/tcp" &>/dev/null
echo -e "   ├─ Порт SSH ($SSH_PORT) ......... ${GREEN}OPEN${RESET}"

# Открываем порты для приложений
# VPN (Reality/VLESS)
ufw allow 443/tcp &>/dev/null
echo -e "   ├─ Порт VPN (443) ........... ${GREEN}OPEN${RESET}"
# Панель 3X-UI
ufw allow 2053/tcp &>/dev/null
echo -e "   ├─ Порт 3X-UI (2053) ........ ${GREEN}OPEN${RESET}"
# Подписка 3X-UI
ufw allow 2096/tcp &>/dev/null
echo -e "   ├─ Порт 3X-UI SUB (2096) .... ${GREEN}OPEN${RESET}"
# Панель AdGuard
ufw allow 3000/tcp &>/dev/null
echo -e "   ├─ Порт AdGuard (3000) ...... ${GREEN}OPEN${RESET}"
# DNS (Порт 53 обязателен для работы AdGuard)
ufw allow 53/tcp &>/dev/null
ufw allow 53/udp &>/dev/null
echo -e "   ├─ Порт DNS (53 TCP/UDP) .... ${GREEN}OPEN${RESET}"

# Активация UFW
ufw --force enable &>/dev/null
echo -e "${ICON_CHECK} Firewall активирован"

systemctl restart ssh

# ==============================================================================
# РАЗДЕЛ 9: ДИАГНОСТИКА И ИТОГОВЫЙ ОТЧЕТ
# ==============================================================================
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${ICON_DOC} ${BOLD}ФИНАЛЬНЫЙ ЧЕКАП${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}Жду 5 секунд для стабилизации контейнеров...${RESET}"
sleep 5

# Универсальная функция проверки с выводом статуса
check_item() {
    local desc=$1
    local cmd=$2
    if eval "$cmd"; then
        echo -e " [ ${GREEN}OK${RESET} ] $desc"
    else
        echo -e " [${RED}FAIL${RESET}] $desc"
    fi
}

echo -e "\n${BOLD}1. ПОЛЬЗОВАТЕЛЬ И ДОСТУП${RESET}"
check_item "Пользователь '$NEW_USER'" "id '$NEW_USER' &>/dev/null"
check_item "Права Sudo" "groups '$NEW_USER' | grep -q 'sudo'"
check_item "Права Docker" "groups '$NEW_USER' | grep -q 'docker'"
check_item "Root вход отключен (SSH config)" "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config"

echo -e "\n${BOLD}2. СИСТЕМА И ЯДРО${RESET}"
check_item "Hostname установлен ($NEW_HOSTNAME)" "[[ $(hostname) == '$NEW_HOSTNAME' ]]"
check_item "SWAP" "swapon --show | grep -q 'swapfile'"
check_item "BBR" "sysctl net.ipv4.tcp_congestion_control | grep -q 'bbr'"
check_item "IP Forwarding" "sysctl net.ipv4.ip_forward | grep -q '1'"

echo -e "\n${BOLD}3. БЕЗОПАСНОСТЬ (СЕРВИСЫ)${RESET}"
check_item "SSH слушает порт $SSH_PORT" "ss -tuln | grep -q ':$SSH_PORT '"
check_item "Fail2Ban" "systemctl is-active --quiet fail2ban"
check_item "Auditd" "systemctl is-active --quiet auditd"
check_item "Firewall (UFW)" "ufw status | grep -q 'Status: active'"

echo -e "\n${BOLD}4. DOCKER И КОНТЕЙНЕРЫ${RESET}"
check_item "Docker Engine" "systemctl is-active --quiet docker"
check_item "Контейнер 3X-UI (VPN)" "docker ps --format '{{.Names}}' | grep -q 'xui'"
check_item "Контейнер AdGuard" "docker ps --format '{{.Names}}' | grep -q 'adguard'"
check_item "Контейнер Telegram Bot" "docker ps --format '{{.Names}}' | grep -q 'telegram_bot'"

echo -e "\n${BOLD}5. ДОСТУПНОСТЬ ПОРТОВ (СЛУШАЮТ ЛИ ПРОГРАММЫ?)${RESET}"
# Используем ss чтобы убедиться что софт реально захватил порты
check_item "Порт 2053 (3X-UI Панель)" "ss -tuln | grep -q ':2053 '"
check_item "Порт 2096 (3X-UI Подписка)" "ss -tuln | grep -q ':2096 '"
check_item "Порт 443 (3X-UI VPN)" "ss -tuln | grep -q ':443 '"
check_item "Порт 3000 (AdGuard Web)" "ss -tuln | grep -q ':3000 '"
check_item "Порт 53 (DNS TCP)" "ss -tuln | grep -q ':53 '"


# ==============================================================================
# РАЗДЕЛ 10: СВОДКА И ЗАВЕРШЕНИЕ
# ==============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "✨  ${BOLD}УСТАНОВКА ПОЛНОСТЬЮ ЗАВЕРШЕНА!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo -e "💻 ${BOLD}СИСТЕМА:${RESET}"
echo -e "   ├─ Host:        ${CYAN}$NEW_HOSTNAME${RESET} ($NEW_TZ)"
echo -e "   ├─ IP Address:  ${CYAN}$MY_IP${RESET}"
echo -e "   ├─ Kernel:      ${GREEN}BBR Enabled, IP Forwarding ON${RESET}"
echo -e "   ├─ Docker:      ${GREEN}Installed & Active${RESET} ${ICON_DOCKER}"
echo -e "   └─ Fail2Ban:    ${GREEN}ACTIVE (Whitelist: $MY_IP)${RESET}"


echo -e "\n👤 ${BOLD}ДОСТУП:${RESET}"
echo -e "   ├─ User:        ${YELLOW}$NEW_USER${RESET} (sudo, docker)"
echo -e "   ├─ Port:        ${YELLOW}$SSH_PORT${RESET}"
echo -e "   └─ Command:     ${BOLD}ssh $NEW_USER@$MY_IP -p $SSH_PORT${RESET}"

echo -e "\n📦 ${BOLD}ДОСТУП К ПРИЛОЖЕНИЯМ:${RESET}"
echo -e "   ├─ 3X-UI Панель: ${BLUE}http://$MY_IP:2053${RESET} (Login: admin/admin)"
echo -e "   ├─ AdGuard Home: ${BLUE}http://$MY_IP:3000${RESET} (Setup: используйте порт 3000 или 80 для web)"
echo -e "   └─ Бот файлы:    ${CYAN}/root/myserver/bot${RESET}"

echo -e "\n🔎 ${BOLD}ПРОВЕРКА (Кликабельно):${RESET}"
echo -e "   👉 ${CYAN}SSH ($SSH_PORT):${RESET}   https://check-host.net/check-tcp?host=$MY_IP:$SSH_PORT"
echo -e "   👉 ${CYAN}3X-UI Panel:${RESET}   https://check-host.net/check-tcp?host=$MY_IP:2053"
echo -e "   👉 ${CYAN}AdGuard Web:${RESET}   https://check-host.net/check-tcp?host=$MY_IP:3000"

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "⚠️  ${BOLD}ВАЖНО:${RESET} Не закрывайте это окно!"
echo -e "    Откройте ${BOLD}НОВЫЙ${RESET} терминал и проверьте вход."
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# Добавление neofetch в автозагрузку терминала root, если его там нет
if grep -q "neofetch" /root/.bashrc; then
    :
else
    echo "neofetch" >> /root/.bashrc
fi

echo ""
read -p "🔄 Желаете перезагрузить сервер прямо сейчас для применения обновлений ядра? (y/n): " REBOOT_NOW
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
    echo -e "${ICON_INFO} Перезагрузка..."
    reboot
else
    echo -e "${ICON_INFO} Ок, перезагрузите сервер вручную позже командой: reboot"
fi