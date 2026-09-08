#!/bin/bash

# ==============================================================================
# 🛡️ VPS SECURITY HARDENING - INTERACTIVE MENU
# ==============================================================================
# Интерактивная версия скрипта безопасности
# VERSION: 1.0.0
# ==============================================================================

set -o pipefail

# ==============================================================================
# 🎨 COLORS & ICONS
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

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
ICON_DISK="💾"
ICON_WARN="⚠️ "
ICON_FIRE="🔥"
ICON_BACK="↩️ "

# ==============================================================================
# 📋 CONFIGURATION
# ==============================================================================
LOG_FILE="/root/security_hardening.log"
BACKUP_DIR="/root/security_backups_$(date +%Y%m%d_%H%M%S)"

# Default values
DEFAULT_HOSTNAME=$(hostname)
DEFAULT_TIMEZONE="Europe/Moscow"
DEFAULT_SWAP_SIZE="2048"
DEFAULT_SSH_PORT="22"

# Stored values (loaded from system or config)
NEW_HOSTNAME=""
NEW_TZ=""
SWAP_SIZE=""
NEW_USER=""
NEW_PASS=""
SSH_PORT=""
SETUP_BANNER=""

# ==============================================================================
# 🧰 HELPERS
# ==============================================================================

# Пауза до нажатия Enter
pause() {
    read -rp "$(echo -e "${DIM}Нажмите Enter для продолжения...${RESET}")"
}

# Разделитель заданной ширины (с цветом, как в оригинале)
sep() {
    local n=${1:-60}
    echo -e "${CYAN}$(printf '─%.0s' $(seq "$n"))${RESET}"
}

# Очистка экрана + заголовок + разделитель
header() {
    clear
    echo -e "${WHITE}${BOLD}$1${RESET}"
    sep "${2:-60}"
    echo
}

# Подтверждение [y/N]
confirm() {
    local msg="${1:-Продолжить}"
    local REPLY
    read -rp "$(echo -e "${YELLOW}${ICON_WARN} ${msg} [y/N]: ${RESET}")"
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Проверка установки пакета/команды
require_pkg() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}❌ $1 не установлен${RESET}"
        echo -e "${DIM}   Установите через меню 8 (Установить пакеты)${RESET}"
        pause
        return 1
    fi
}

# Получение актуального SSH порта из конфига
get_ssh_port() {
    grep -E "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22"
}

# Перезапуск SSH (ssh или sshd)
restart_ssh() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# Безопасное добавление/обновление директивы в sshd_config
ensure_ssh_config() {
    local key="$1"
    local value="$2"
    local file="${3:-/etc/ssh/sshd_config}"
    if grep -q "^${key}[[:space:]]" "$file" 2>/dev/null; then
        sed -i "s/^${key}.*/${key} ${value}/" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

# Проверка синтаксиса sshd + перезапуск
reload_ssh_safe() {
    if sshd -t 2>/dev/null; then
        restart_ssh
        return 0
    else
        echo -e "${RED}   └─ ❌ Ошибка конфигурации SSH! Запустите sshd -t для диагностики${RESET}"
        log_action "ERROR: sshd config test failed - reload aborted"
        return 1
    fi
}

# Управление портами UFW (allow / delete allow)
firewall_port_cmd() {
    local action="$1"
    local port="$2"
    local proto="$3"
    local suffix=""
    case "$proto" in
        tcp|TCP)     suffix="/tcp" ;;
        udp|UDP)     suffix="/udp" ;;
        both|Both|*) suffix="" ;;
    esac
    ufw "$action" "${port}${suffix}" >/dev/null 2>&1
    echo "$suffix"
}

# Стандартный хвост подменю: разделитель, "0) назад", приглашение, чтение выбора
# Принимает макс. номер опции, возвращает выбор в переменную $menu_choice
menu_prompt() {
    local max_opt="$1"
    echo ""
    sep
    echo -e "   ${RED}0)${RESET} ↩️  Назад"
    echo ""
    read -rp "$(echo -e "${WHITE}Выберите опцию [0-$max_opt]:${RESET} ")" menu_choice
}

# Универсальный переключатель сервисов (вкл/выкл)
service_toggle() {
    local title="$1"
    local label_off="$2"
    local label_on="$3"
    local status_cmd="$4"
    local enable_cmd="$5"
    local disable_cmd="$6"

    clear
    echo -e "${WHITE}${BOLD}${title}${RESET}"
    sep
    echo

    if eval "$status_cmd" &>/dev/null; then
        echo -e "${YELLOW}${label_on} сейчас ${GREEN}АКТИВЕН${RESET}"
        read -p "$(echo -e "${RED}Выключить? [y/N]: ${RESET}")" __confirm__
        if [[ "$__confirm__" =~ ^[Yy]$ ]]; then
            eval "$disable_cmd" &>/dev/null || true
            echo -e "${BLUE}   └─ ${GREEN}${label_on} выключен${RESET}"
            log_action "${label_on}: Disabled"
        fi
    else
        echo -e "${YELLOW}${label_on} сейчас ${RED}ОТКЛЮЧЕН${RESET}"
        read -p "$(echo -e "${GREEN}Включить? [y/N]: ${RESET}")" __confirm__
        if [[ "$__confirm__" =~ ^[Yy]$ ]]; then
            eval "$enable_cmd" &>/dev/null || true
            echo -e "${BLUE}   └─ ${GREEN}${label_on} включен${RESET}"
            log_action "${label_on}: Enabled"
        fi
    fi

    echo ""
    pause
}

# ==============================================================================
# 🔄 LOGGING
# ==============================================================================
init_logging() {
    rm -f "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "${BLUE}${ICON_INFO} Лог сессии: ${CYAN}$LOG_FILE${RESET}"
}

log_action() {
    local msg="$1"
    echo -e "${DIM}[$(date '+%H:%M:%S')]${RESET} $msg"
}

# ==============================================================================
# � BACKUP HELPERS
# ==============================================================================
create_backups() {
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${BLUE}${ICON_GEAR} [INIT] Создаю резервные копии...${RESET}"
    
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak" 2>/dev/null && \
        echo -e "${BLUE}   ├─ ${GREEN}SSH конфиг сохранён${RESET}"
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null && \
        echo -e "${BLUE}   ├─ ${GREEN}Sysctl сохранён${RESET}"
    cp /etc/fstab "$BACKUP_DIR/fstab.bak" 2>/dev/null && \
        echo -e "${BLUE}   ├─ ${GREEN}Fstab сохранён${RESET}"
    cp /etc/systemd/resolved.conf "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null && \
        echo -e "${BLUE}   ├─ ${GREEN}DNS конфиг сохранён${RESET}"
    
    echo -e "${BLUE}   └─ ${GREEN}Путь: $BACKUP_DIR${RESET}"
    echo ""
}

# ==============================================================================
# ✅ CHECK ROOT
# ==============================================================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${ICON_ERROR} ${RED}Запустите от имени root!${RESET}"
        echo -e "${BLUE}   Используйте: ${CYAN}sudo bash $0${RESET}"
        exit 1
    fi
}

# ==============================================================================
# 📊 STATUS FUNCTIONS
# ==============================================================================
show_system_status() {
    clear
    echo -e "${WHITE}${BOLD}📊 ПОЛНЫЙ СТАТУС СИСТЕМЫ${RESET}"
    sep 70
    echo ""

    # === SYSTEM INFO ===
    echo -e "${MAGENTA}${BOLD}📌 СИСТЕМНАЯ ИНФОРМАЦИЯ:${RESET}"
    sep 70
    printf "  ${BLUE}%-12s${RESET} %s\n" "Hostname:" "$(hostname)"
    printf "  ${BLUE}%-12s${RESET} %s\n" "Timezone:" "$(timedatectl | grep "Time zone" | awk '{print $3}')"
    printf "  ${BLUE}%-12s${RESET} %s\n" "OS Version:" "$(cat /etc/os-release 2>/dev/null | grep "PRETTY_NAME" | cut -d'=' -f2 | tr -d '"')"
    printf "  ${BLUE}%-12s${RESET} %s\n" "Kernel:" "$(uname -r)"
    printf "  ${BLUE}%-12s${RESET} %s\n" "Uptime:" "$(uptime -p 2>/dev/null || uptime | awk -F, '{print $1}' | awk '{$1=$2=$3=$4=""; print $0}')"
    echo ""

    # === HARDWARE INFO ===
    echo -e "${MAGENTA}${BOLD}🖥️ ЖЕЛЕЗО:${RESET}"
    sep 70
    printf "  ${BLUE}%-12s${RESET} %s\n" "CPU:" "$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | xargs || echo "N/A")"
    printf "  ${BLUE}%-12s${RESET} %s\n" "CPU Cores:" "$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "N/A")"
    printf "  ${BLUE}%-12s${RESET} %s%% загружено\n" "CPU Usage:" "$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")"
    printf "  ${BLUE}%-12s${RESET} %s\n" "RAM Total:" "$(free -h | grep Mem | awk '{print $2}')"
    printf "  ${BLUE}%-12s${RESET} %s\n" "RAM Used:" "$(free -h | grep Mem | awk '{print $3}')"
    printf "  ${BLUE}%-12s${RESET} %s\n" "RAM Free:" "$(free -h | grep Mem | awk '{print $4}')"
    local total_disk=$(df -h / 2>/dev/null | tail -1 | awk '{print $2}')
    local used_disk=$(df -h / 2>/dev/null | tail -1 | awk '{print $3}')
    local disk_percent=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}')
    printf "  ${BLUE}%-12s${RESET} %s / %s (%s)\n" "Disk:" "${used_disk:-N/A}" "${total_disk:-N/A}" "${disk_percent:-N/A}"
    echo ""

    # === NETWORK INTERFACES ===
    echo -e "${MAGENTA}${BOLD}🌐 СЕТЕВЫЕ ИНТЕРФЕЙСЫ:${RESET}"
    sep 70
    if command -v ip &>/dev/null; then
        ip -br addr 2>/dev/null | grep -v "lo:" | grep -v "docker" | grep -v "br-" | grep -v "veth" | while read -r line; do
            local iface=$(echo "$line" | awk '{print $1}')
            local state=$(echo "$line" | awk '{print $2}')
            # Берём только IPv4 адрес (первый)
            local ip_addr=$(echo "$line" | awk '{for(i=3;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {print $i; exit}}' | cut -d'/' -f1)
            local state_icon="${RED}❌ DOWN${RESET}"
            [ "$state" = "UP" ] && state_icon="${GREEN}✅ UP${RESET}"
            [ -z "$ip_addr" ] && ip_addr="N/A"
            printf "  ${BLUE}%-12s${RESET}  ${state_icon}  ${CYAN}%s${RESET}\n" "${iface}:" "${ip_addr}"
        done
    else
        echo -e "  ${YELLOW}⚠️  Команда ip не найдена${RESET}"
    fi
    local public_ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "N/A")
    printf "  ${BLUE}%-12s${RESET} ${CYAN}%s${RESET}\n" "Public IP:" "${public_ip}"
    echo ""

    # === SSH INFO ===
    echo -e "${MAGENTA}${BOLD}🔐 SSH КОНФИГУРАЦИЯ:${RESET}"
    sep 70
    local ssh_port=$(get_ssh_port)
    printf "  ${BLUE}%-12s${RESET} %s\n" "SSH Port:" "${ssh_port:-22}"
    printf "  ${BLUE}%-12s${RESET} %s\n" "Root Login:" "$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not set")"
    printf "  ${BLUE}%-12s${RESET} %s\n" "Password Auth:" "$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not set")"
    echo -e "  ${BLUE}Users:${RESET}"
    local allow_users=$(grep -E "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null | awk '{for(i=2;i<=NF;i++) printf "             - %s\n", $i}')
    if [ -n "$allow_users" ]; then
        echo "$allow_users"
    else
        echo -e "             ${YELLOW}⚠️  (не настроено)${RESET}"
    fi
    echo ""

    # === SWAP & MEMORY ===
    echo -e "${MAGENTA}${BOLD}💾 ПАМЯТЬ И SWAP:${RESET}"
    sep 70
    if swapon --show | grep -q "/swapfile"; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ Активен${RESET}\n" "SWAP:"
        # Получаем размер и используемый объём swap‑файла
        swap_size_raw=$(swapon --show | awk '$1 == "/swapfile" {print $3}')
        swap_used_raw=$(swapon --show | awk '$1 == "/swapfile" {print $4}')
        # Преобразуем из формата IEC (G,M,K) в мегабайты
        size_bytes=$(numfmt --from=iec "$swap_size_raw" 2>/dev/null || echo "0")
        used_bytes=$(numfmt --from=iec "$swap_used_raw" 2>/dev/null || echo "0")
        size_mb=$((size_bytes / 1024 / 1024))
        used_mb=$((used_bytes / 1024 / 1024))
        printf "    ${BLUE}Размер (МБ):${RESET} %s MB\n" "$size_mb"
        printf "    ${BLUE}Использовано (МБ):${RESET} %s MB\n" "$used_mb"
    else
        printf "  ${BLUE}%-12s${RESET} ${YELLOW}⚠️  Не активен${RESET}\n" "SWAP:"
    fi
    echo ""

    # === DOCKER STATUS ===
    echo -e "${MAGENTA}${BOLD}🐳 DOCKER:${RESET}"
    sep 70
    if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ Docker активен${RESET}\n" "Status:"
        printf "  ${BLUE}%-12s${RESET} %s\n" "Версия:" "$(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
        local total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
        local running_containers=$(docker ps -q 2>/dev/null | wc -l)
        printf "  ${BLUE}%-12s${RESET} Всего: ${CYAN}%s${RESET}, Запущено: ${GREEN}%s${RESET}\n" "Контейнеры:" "${total_containers}" "${running_containers}"
        
        # Вывод контейнеров
        echo -e "  ${BLUE}Контейнеры:${RESET}"
        docker ps -a --format "    • {{.Names}} ({{.Status}})" 2>/dev/null || echo "    N/A"
        
        # Сети с подключенными контейнерами
        echo -e "  ${BLUE}Сети:${RESET}"
        docker network ls --format "{{.Name}}" 2>/dev/null | while read -r network; do
            # Получаем контейнеры, подключенные к этой сети
            local containers=$(docker network inspect "$network" 2>/dev/null | grep -oP '"Name":\s*"\K[^"]+' | grep -v "^$network$" | sort -u)
            if [ -n "$containers" ]; then
                printf "    • ${CYAN}%s${RESET}\n" "$network"
                echo "$containers" | while read -r container; do
                    if [ -n "$container" ]; then
                        printf "      └─ %s\n" "$container"
                    fi
                done
            else
                printf "    • ${CYAN}%s${RESET}\n" "$network"
            fi
        done
        
        # Образы
        local images_count=$(docker images -q 2>/dev/null | wc -l)
        printf "  ${BLUE}%-12s${RESET} Всего образов: ${CYAN}%s${RESET}\n" "Образы:" "${images_count}"
        echo -e "  ${BLUE}Образы:${RESET}"
        docker images --format "    • {{.Repository}}:{{.Tag}} ({{.Size}})" 2>/dev/null | head -10 || echo "    N/A"
        local images_more=$((images_count - 10))
        [ "$images_more" -gt 0 ] && echo -e "    ${DIM}... и ещё $images_more образов${RESET}"
        
    elif command -v docker &>/dev/null; then
        printf "  ${BLUE}%-12s${RESET} ${YELLOW}⚠️  Docker установлен, но служба не активна${RESET}\n" "Status:"
    else
        printf "  ${BLUE}%-12s${RESET} ${RED}❌ Docker не установлен${RESET}\n" "Status:"
    fi
    echo ""

    # === OPEN PORTS ===
    echo -e "${MAGENTA}${BOLD}🔓 ОТКРЫТЫЕ ПОРТЫ:${RESET}"
    sep 70
    if command -v ss &>/dev/null; then
        local listening_ports=$(ss -tlnp 2>/dev/null | grep -c LISTEN)
        printf "  ${BLUE}%-12s${RESET} ${CYAN}%s${RESET}\n" "Всего слушают:" "${listening_ports}"
        echo ""
        
        # Внешние порты (доступные из интернета)
        echo -e "  ${MAGENTA}${BOLD}🌐 Внешние (доступны из интернета):${RESET}"
        ss -tlnp 2>/dev/null | grep LISTEN | grep -v "127.0.0.1:" | grep -v "\[::1\]:" | while read -r line; do
            local port=$(echo "$line" | grep -oP ':\K[0-9]+(?=\s)' | head -1)
            local process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' | head -1)
            [ -z "$port" ] && port="?"
            [ -z "$process" ] && process="system"
            printf "    ${GREEN}▶${RESET} Порт ${YELLOW}%-6s${RESET} ${DIM}%s${RESET} ${GREEN}[EXTERNAL]${RESET}\n" "${port}" "${process}"
        done
        echo ""
        
        # Локальные порты (только localhost)
        echo -e "  ${BLUE}🔒 Локальные (только localhost):${RESET}"
        ss -tlnp 2>/dev/null | grep LISTEN | grep -E "127.0.0.1:|\[::1\]:" | while read -r line; do
            local port=$(echo "$line" | grep -oP ':\K[0-9]+(?=\s)' | head -1)
            local process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' | head -1)
            [ -z "$port" ] && port="?"
            [ -z "$process" ] && process="system"
            printf "    ${GREEN}▶${RESET} Порт ${YELLOW}%-6s${RESET} ${DIM}%s${RESET}\n" "${port}" "${process}"
        done
        
    elif command -v netstat &>/dev/null; then
        local listening_ports=$(netstat -tlnp 2>/dev/null | grep -c LISTEN)
        printf "  ${BLUE}%-12s${RESET} ${CYAN}%s${RESET}\n" "Всего слушают:" "${listening_ports}"
        echo ""
        
        # Внешние порты
        echo -e "  ${MAGENTA}${BOLD}🌐 Внешние (доступны из интернета):${RESET}"
        netstat -tlnp 2>/dev/null | grep LISTEN | grep -v "127.0.0.1:" | grep -v "\[::1\]:" | while read -r line; do
            local port=$(echo "$line" | awk '{print $4}' | grep -oP ':\K[0-9]+$')
            local process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2)
            [ -z "$port" ] && port="?"
            [ -z "$process" ] && process="system"
            printf "    ${GREEN}▶${RESET} Порт ${YELLOW}%-6s${RESET} ${DIM}%s${RESET} ${GREEN}[EXTERNAL]${RESET}\n" "${port}" "${process}"
        done
        echo ""
        
        # Локальные порты
        echo -e "  ${BLUE}🔒 Локальные (только localhost):${RESET}"
        netstat -tlnp 2>/dev/null | grep LISTEN | grep -E "127.0.0.1:|\[::1\]:" | while read -r line; do
            local port=$(echo "$line" | awk '{print $4}' | grep -oP ':\K[0-9]+$')
            local process=$(echo "$line" | awk '{print $7}' | cut -d'/' -f2)
            [ -z "$port" ] && port="?"
            [ -z "$process" ] && process="system"
            printf "    ${GREEN}▶${RESET} Порт ${YELLOW}%-6s${RESET} ${DIM}%s${RESET}\n" "${port}" "${process}"
        done
    else
        echo -e "  ${YELLOW}⚠️  Команды ss/netstat не найдены${RESET}"
    fi
    echo ""

    # === SUDO USERS ===
    echo -e "${MAGENTA}${BOLD}👥 ПОЛЬЗОВАТЕЛИ С SUDO:${RESET}"
    sep 70
    
    # Получаем пользователей из группы sudo напрямую из /etc/group
    local sudo_line=$(grep "^sudo:" /etc/group 2>/dev/null)
    local sudo_users_raw=""
    
    if [ -n "$sudo_line" ]; then
        # Формат: sudo:x:27:user1,user2 - берём 4 поле
        sudo_users_raw=$(echo "$sudo_line" | cut -d: -f4)
    fi
    
    # Также проверяем группу wheel
    local wheel_line=$(grep "^wheel:" /etc/group 2>/dev/null)
    if [ -n "$wheel_line" ]; then
        local wheel_users_raw=$(echo "$wheel_line" | cut -d: -f4)
        if [ -n "$sudo_users_raw" ]; then
            sudo_users_raw="$sudo_users_raw,$wheel_users_raw"
        else
            sudo_users_raw="$wheel_users_raw"
        fi
    fi
    
    if [ -n "$sudo_users_raw" ]; then
        # Выводим каждого пользователя
        echo "$sudo_users_raw" | tr ',' '\n' | sort -u | while IFS= read -r __susr__; do
            if [ -n "$__susr__" ]; then
                echo -e "  ${GREEN}▶${RESET} ${CYAN}${__susr__}${RESET}"
            fi
        done
    else
        echo -e "  ${YELLOW}⚠️  Пользователи с sudo не найдены${RESET}"
    fi
    echo ""

    # === FIREWALL ===
    echo -e "${MAGENTA}${BOLD}🔥 FIREWALL (UFW):${RESET}"
    sep 70
    local ufw_status_check=$(ufw status 2>/dev/null | grep -c "Status: active")
    if [ "$ufw_status_check" -ge 1 ]; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ Активен${RESET}\n" "Status:"
        echo -e "  ${DIM}Правила:${RESET}"
        ufw status 2>/dev/null | grep -v "Status:" | head -10 | sed 's/^/     /'
    else
        printf "  ${BLUE}%-12s${RESET} ${RED}❌ Отключен${RESET}\n" "Status:"
    fi
    echo ""

    # === FAIL2BAN ===
    echo -e "${MAGENTA}${BOLD}🛡️ FAIL2BAN:${RESET}"
    sep 70
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ Активен${RESET}\n" "Status:"
        printf "  ${BLUE}%-12s${RESET} %s\n" "Версия:" "$(fail2ban-client -V 2>/dev/null | head -1 || echo "N/A")"
    else
        printf "  ${BLUE}%-12s${RESET} ${RED}❌ Отключен${RESET}\n" "Status:"
    fi
    echo ""

    # === AUDITD ===
    echo -e "${MAGENTA}${BOLD}📋 AUDITD (AUDIT):${RESET}"
    sep 70
    if systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ Активен${RESET}\n" "Status:"
    else
        printf "  ${BLUE}%-12s${RESET} ${RED}❌ Отключен${RESET}\n" "Status:"
    fi
    echo ""

    # === KERNEL PROTECTION ===
    echo -e "${MAGENTA}${BOLD}⚙️ KERNEL PROTECTION:${RESET}"
    sep 70
    printf "  ${BLUE}%-12s${RESET} %s\n" "TCP Congestion:" "$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "N/A")"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        printf "  ${BLUE}%-12s${RESET} ${GREEN}✅ BBR включен${RESET}\n" "BBR:"
    else
        printf "  ${BLUE}%-12s${RESET} ${YELLOW}⚠️  BBR отключен${RESET}\n" "BBR:"
    fi
    printf "  ${BLUE}%-12s${RESET} %s\n" "IP Forwarding:" "$(sysctl net.ipv4.ip_forward 2>/dev/null | awk '{print $3}' || echo "N/A")"
    printf "  ${BLUE}%-12s${RESET} %s\n" "IPv6:" "$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}' || echo "N/A")"
    echo ""

    sep 70
    pause
}

# ==============================================================================
# ⚙️ CONFIGURATION FUNCTIONS
# ==============================================================================
configure_system_basic() {
    clear
    echo -e "${WHITE}${BOLD}⚙️  БАЗОВАЯ НАСТРОЙКА СИСТЕМЫ${RESET}"
    sep 50
    echo ""
    
    # Hostname
    local current_host=$(hostname)
    echo -e "${BLUE}${ICON_GLOBE} ${BOLD}Настройка системы${RESET}"
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Новое имя сервера${RESET} ${DIM}[Enter = ${CYAN}$current_host${RESET}${DIM}]${RESET}: ")" NEW_HOSTNAME
    NEW_HOSTNAME=${NEW_HOSTNAME:-$current_host}
    
    # Timezone
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Таймзона${RESET} ${DIM}[Enter = ${CYAN}$DEFAULT_TIMEZONE${RESET}${DIM}]${RESET}: ")" NEW_TZ
    NEW_TZ=${NEW_TZ:-$DEFAULT_TIMEZONE}
    
    # Swap Size
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Размер SWAP файла${RESET} ${DIM}(в МБ, например ${CYAN}2048${RESET}${DIM})${RESET}: ")" SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-$DEFAULT_SWAP_SIZE}
    
    # SSH Banner
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Установить SSH баннер${RESET} ${DIM}(предупреждение при входе)${RESET} [y/N]: ")" SETUP_BANNER
    
    echo ""
    echo -e "${YELLOW}${ICON_WARN} Применить изменения?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_system_basic
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi
    
    echo ""
    pause
}

apply_system_basic() {
    log_action "Applying system basic settings..."
    
    # Hostname
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    echo -e "${BLUE}   ├─ ${GREEN}Hostname: $NEW_HOSTNAME${RESET}"
    
    # Timezone
    timedatectl set-timezone "$NEW_TZ"
    echo -e "${BLUE}   ├─ ${GREEN}Timezone: $NEW_TZ${RESET}"
    
    # SWAP
    if [ ! -f /swapfile ]; then
        echo -e "${BLUE}${ICON_DISK} Создание SWAP файла (${SWAP_SIZE} МБ)...${RESET}"
        if ! fallocate -l ${SWAP_SIZE}M /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE} status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${BLUE}   ├─ ${GREEN}SWAP создан и активирован${RESET}"
    else
        echo -e "${BLUE}   ├─ ${ICON_INFO} SWAP уже существует${RESET}"
    fi
    
    # Kernel Hardening
    cat <<EOF > /etc/sysctl.d/99-security.conf
# === PERFORMANCE & VPN ===
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
# === SECURITY HARDENING (Network) ===
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
# === SECURITY HARDENING (Kernel) ===
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.pid_max = 65536
# === IPv6 FULL DISABLE ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    if sysctl --system >/dev/null 2>&1; then
        echo -e "${BLUE}   ├─ ${GREEN}Kernel Hardening применён${RESET}"
    else
        echo -e "${BLUE}   ├─ ${RED}Ошибка применения sysctl${RESET}"
        echo -e "${YELLOW}   └─ Восстанавливаю sysctl...${RESET}"
        [ -f "$BACKUP_DIR/sysctl.conf.bak" ] && cp "$BACKUP_DIR/sysctl.conf.bak" /etc/sysctl.conf 2>/dev/null || true
        sysctl -p >/dev/null 2>&1 || true
        log_action "ERROR: sysctl failed - restored"
        echo -e "${RED}⚠️  Sysctl восстановлен! Проверьте конфиг.${RESET}"
        return 1
    fi

    cat <<EOF >> /etc/security/limits.conf

# Security Hardening
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF
    echo -e "${BLUE}   └─ ${GREEN}Limits настроены${RESET}"

    # SSH Banner
    if [[ "$SETUP_BANNER" =~ ^[Yy]$ ]]; then
        cat <<EOF > /etc/issue.net
***************************************************************************
                          NOTICE TO USERS
This is a private system. Unauthorized access is prohibited.
All activities may be monitored and recorded.
***************************************************************************
EOF
        ensure_ssh_config "Banner" "/etc/issue.net"
        echo -e "${BLUE}   ├─ ${GREEN}SSH баннер установлен${RESET}"
        log_action "SSH: Banner configured (basic setup)"
    fi

    # DNS настройка (порт 53) полностью удалена
    log_action "System basic settings applied"
}

# ==============================================================================
# 👥 USER MANAGEMENT FUNCTIONS
# ==============================================================================
user_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}👥 ПОЛЬЗОВАТЕЛИ СИСТЕМЫ - ПОДМЕНЮ${RESET}"
        sep 70
        echo ""

        # Status
        echo -e "${MAGENTA}${BOLD}📊 СТАТУС:${RESET}"
        sep 70
        
        local total_users=$(cut -d: -f1 /etc/passwd | wc -l)
        local sudo_users=$(grep "^sudo:" /etc/group 2>/dev/null | cut -d: -f4)
        local sudo_count=0
        if [ -n "$sudo_users" ]; then
            sudo_count=$(echo "$sudo_users" | tr ',' '\n' | grep -c . 2>/dev/null)
        fi
        local locked_users=$(passwd -S 2>/dev/null | grep -c " L " 2>/dev/null || echo "0")
        local no_pass_users=$(awk -F: '($2 == "" || $2 == "!") {print $1}' /etc/shadow 2>/dev/null | wc -l)
        
        # Root статус
        local root_status=$(passwd -S root 2>/dev/null | awk '{print $2}')
        local root_status_text="❌ Заблокирован"
        [ "$root_status" = "P" ] && root_status_text="✅ Активен"
        [ "$root_status" = "L" ] && root_status_text="⚠️  Заблокирован"
        
        printf "  ${BLUE}%-20s${RESET} %s\n" "Всего пользователей:" "${total_users}"
        printf "  ${BLUE}%-20s${RESET} %s\n" "С sudo правами:" "${sudo_count}"
        printf "  ${BLUE}%-20s${RESET} %s\n" "Заблокированных:" "${locked_users}"
        printf "  ${BLUE}%-20s${RESET} %s\n" "Без пароля:" "${no_pass_users}"
        printf "  ${BLUE}%-20s${RESET} %s\n" "Root:" "${root_status_text}"
        echo ""

        # Активные пользователи
        echo -e "${MAGENTA}${BOLD}👤 АКТИВНЫЕ ПОЛЬЗОВАТЕЛИ:${RESET}"
        sep 70
        
        # Показываем пользователей с оболочкой
        local user_list=$(awk -F: '$3 >= 1000 && $7 != "/usr/sbin/nologin" && $7 != "/bin/false" {print $1}' /etc/passwd 2>/dev/null)
        if [ -n "$user_list" ]; then
            echo "$user_list" | while IFS= read -r uname; do
                local is_sudo=""
                if echo "$sudo_users" | tr ',' '\n' | grep -q "^${uname}$"; then
                    is_sudo=" (sudo)"
                fi
                
                local ustatus=$(passwd -S "$uname" 2>/dev/null | awk '{print $2}')
                local uicon="🟢"
                [ "$ustatus" = "L" ] && uicon="🔒"
                [ "$ustatus" = "NP" ] && uicon="⚠️ "
                
                local last_login=$(last -1 "$uname" 2>/dev/null | head -1 | awk '{for(i=4;i<=NF;i++) printf $i" "; print ""}')
                [ -z "$last_login" ] && last_login="никогда"
                
                if [ -n "$is_sudo" ]; then
                    printf "  ${GREEN}▶${RESET} ${CYAN}%-15s${RESET} %s ${GREEN}%s${RESET} ${DIM}│ Вход: %s${RESET}\n" "$uname" "$uicon" "$is_sudo" "$last_login"
                else
                    printf "  ${GREEN}▶${RESET} ${CYAN}%-15s${RESET} %s ${DIM}│ Вход: %s${RESET}\n" "$uname" "$uicon" "$last_login"
                fi
            done
        else
            echo -e "  ${YELLOW}⚠️  Пользователи не найдены${RESET}"
        fi
        echo ""

        sep 70
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} ➕ Создать нового пользователя"
        echo -e "   ${GREEN}2)${RESET} 🗑️  Удалить пользователя"
        echo -e "   ${GREEN}3)${RESET} 🔑 Сбросить пароль пользователя"
        echo -e "   ${GREEN}4)${RESET} ⚡ Добавить/Удалить sudo права"
        echo -e "   ${GREEN}5)${RESET} 🔒 Заблокировать/Разблокировать пользователя"
        echo -e "   ${GREEN}6)${RESET} 👑 Настройки root пользователя"
        echo -e "   ${GREEN}7)${RESET} 📋 Показать всех пользователей"
        echo -e "   ${GREEN}8)${RESET} 🔍 Информация о пользователе"
        echo -e "   ${GREEN}9)${RESET} 🛡️  Проверка безопасности"
        menu_prompt 9

        case "$menu_choice" in
            1) user_create ;;
            2) user_delete ;;
            3) user_reset_password ;;
            4) user_toggle_sudo ;;
            5) user_toggle_lock ;;
            6) user_root_menu ;;
            7) user_list_all ;;
            8) user_info ;;
            9) user_security_check ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

user_create() {
    clear
    echo -e "${WHITE}${BOLD}➕ СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ${RESET}"
    sep 70
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя${RESET}: ")" new_username
    
    if id "$new_username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь уже существует!${RESET}"
        sleep 2
        return
    fi

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Пароль${RESET}: ")" -s new_password
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Подтвердите пароль${RESET}: ")" -s confirm_password
    echo ""

    if [ "$new_password" != "$confirm_password" ]; then
        echo -e "${RED}   └─ Пароли не совпадают!${RESET}"
        sleep 2
        return
    fi

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Добавить в sudo? [y/N]:${RESET} ")" add_sudo
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Копировать SSH ключи из /root? [y/N]:${RESET} ")" copy_ssh

    echo ""
    echo -e "${YELLOW}${ICON_WARN} Создать пользователя?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        useradd -m -s /bin/bash "$new_username" 2>/dev/null
        echo "$new_username:$new_password" | chpasswd 2>/dev/null
        echo -e "${BLUE}   ├─ ${GREEN}Пользователь создан${RESET}"

        if [[ "$add_sudo" =~ ^[Yy]$ ]]; then
            usermod -aG sudo "$new_username" 2>/dev/null
            echo -e "${BLUE}   ├─ ${GREEN}Добавлен в группу sudo${RESET}"
        fi

        if [[ "$copy_ssh" =~ ^[Yy]$ ]] && [ -d "/root/.ssh" ]; then
            cp -r /root/.ssh /home/"$new_username"/ 2>/dev/null
            chown -R "$new_username":"$new_username" /home/"$new_username"/.ssh 2>/dev/null
            chmod 700 /home/"$new_username"/.ssh 2>/dev/null
            chmod 600 /home/"$new_username"/.ssh/* 2>/dev/null
            echo -e "${BLUE}   ├─ ${GREEN}SSH ключи скопированы${RESET}"
        fi

        if command -v docker &>/dev/null; then
            usermod -aG docker "$new_username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Добавлен в группу docker${RESET}"
        fi

        log_action "User created: $new_username"
    else
        echo -e "${YELLOW}   └─ Отменено${RESET}"
    fi

    echo ""
    pause
}

user_delete() {
    clear
    echo -e "${WHITE}${BOLD}🗑️  УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${RESET}"
    sep 70
    echo ""

    echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Это действие необратимо!${RESET}"
    echo ""
    
    # Показываем пользователей (исключая root и системных)
    echo -e "${BLUE}Доступные для удаления:${RESET}"
    awk -F: '$3 >= 1000 && $1 != "root" && $7 != "/usr/sbin/nologin" {print "  - "$1}' /etc/passwd 2>/dev/null
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя для удаления${RESET}: ")" del_username

    if [ "$del_username" = "root" ]; then
        echo -e "${RED}   └─ Нельзя удалить root!${RESET}"
        sleep 2
        return
    fi

    if ! id "$del_username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь не найден!${RESET}"
        sleep 2
        return
    fi

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Удалить домашнюю директорию? [y/N]:${RESET} ")" remove_home
    echo ""
    echo -e "${RED}⚠️  Вы уверены?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} Введите имя пользователя для подтверждения: ")" confirm_name

    if [ "$confirm_name" = "$del_username" ]; then
        if [[ "$remove_home" =~ ^[Yy]$ ]]; then
            deluser --remove-home "$del_username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Пользователь удалён с домашней директорией${RESET}"
        else
            deluser "$del_username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Пользователь удалён (домашняя директория сохранена)${RESET}"
        fi
        log_action "User deleted: $del_username"
    else
        echo -e "${YELLOW}   └─ Отменено (имя не совпадает)${RESET}"
    fi

    echo ""
    pause
}

user_reset_password() {
    clear
    echo -e "${WHITE}${BOLD}🔑 СБРОС ПАРОЛЯ${RESET}"
    sep 70
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя${RESET}: ")" username

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь не найден!${RESET}"
        sleep 2
        return
    fi

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Новый пароль${RESET}: ")" -s new_pass
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Подтвердите пароль${RESET}: ")" -s confirm_pass
    echo ""

    if [ "$new_pass" = "$confirm_pass" ]; then
        echo "$username:$new_pass" | chpasswd 2>/dev/null
        echo -e "${BLUE}   └─ ${GREEN}Пароль успешно изменён${RESET}"
        log_action "Password reset for: $username"
    else
        echo -e "${RED}   └─ Пароли не совпадают!${RESET}"
    fi

    echo ""
    pause
}

user_toggle_sudo() {
    clear
    echo -e "${WHITE}${BOLD}⚡ SUDO ПРАВА - ДОБАВИТЬ/УДАЛИТЬ${RESET}"
    sep 70
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя${RESET}: ")" username

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь не найден!${RESET}"
        sleep 2
        return
    fi

    local current_groups=$(groups "$username" 2>/dev/null | cut -d: -f2)
    local has_sudo=$(echo "$current_groups" | grep -o "sudo")

    echo -e "${BLUE}Текущие группы:${RESET} $current_groups"
    echo ""

    if [ -n "$has_sudo" ]; then
        echo -e "${YELLOW}Пользователь УЖЕ имеет sudo права${RESET}"
        read -p "$(echo -e "${RED}Удалить sudo права? [y/N]:${RESET} ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            gpasswd -d "$username" sudo 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Sudo права удалены${RESET}"
            log_action "Sudo removed from: $username"
        fi
    else
        echo -e "${GREEN}Пользователь НЕ имеет sudo права${RESET}"
        read -p "$(echo -e "${GREEN}Добавить sudo права? [y/N]:${RESET} ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            usermod -aG sudo "$username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Sudo права добавлены${RESET}"
            log_action "Sudo added to: $username"
        fi
    fi

    echo ""
    pause
}

user_toggle_lock() {
    clear
    echo -e "${WHITE}${BOLD}🔒 БЛОКИРОВКА ПОЛЬЗОВАТЕЛЯ${RESET}"
    sep 70
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя${RESET}: ")" username

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь не найден!${RESET}"
        sleep 2
        return
    fi

    local status=$(passwd -S "$username" 2>/dev/null | awk '{print $2}')
    
    if [ "$status" = "L" ]; then
        echo -e "${YELLOW}Пользователь ЗАБЛОКИРОВАН${RESET}"
        read -p "$(echo -e "${GREEN}Разблокировать? [y/N]:${RESET} ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            passwd -u "$username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Пользователь разблокирован${RESET}"
            log_action "User unlocked: $username"
        fi
    else
        echo -e "${GREEN}Пользователь АКТИВЕН${RESET}"
        read -p "$(echo -e "${RED}Заблокировать? [y/N]:${RESET} ")" confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            passwd -l "$username" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Пользователь заблокирован${RESET}"
            log_action "User locked: $username"
        fi
    fi

    echo ""
    pause
}

user_root_menu() {
    clear
    echo -e "${WHITE}${BOLD}👑 НАСТРОЙКИ ROOT ПОЛЬЗОВАТЕЛЯ${RESET}"
    sep 70
    echo ""

    local root_status=$(passwd -S root 2>/dev/null | awk '{print $2}')
    local root_icon="${RED}❌ Заблокирован${RESET}"
    [ "$root_status" = "P" ] && root_icon="${GREEN}✅ Активен (с паролем)${RESET}"
    [ "$root_status" = "L" ] && root_icon="${YELLOW}⚠️  Заблокирован${RESET}"

    echo -e "${BLUE}Статус root:${RESET} $root_icon"
    echo ""

    # SSH root login статус
    local root_ssh=$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$root_ssh" ] && root_ssh="not set (default: yes)"
    echo -e "${BLUE}SSH root login:${RESET} $root_ssh"
    echo ""

    echo -e "${WHITE}${BOLD}ДЕЙСТВИЯ:${RESET}"
    echo -e "   ${GREEN}1)${RESET} Установить пароль root"
    echo -e "   ${GREEN}2)${RESET} Заблокировать root (без пароля)"
    echo -e "   ${GREEN}3)${RESET} Разблокировать root"
    echo -e "   ${GREEN}4)${RESET} Разрешить SSH вход root"
    echo -e "   ${GREEN}5)${RESET} Запретить SSH вход root"
    menu_prompt 5

    case "$menu_choice" in
        1)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Новый пароль root${RESET}: ")" -s root_pass
            echo ""
            echo "root:$root_pass" | chpasswd 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Пароль установлен${RESET}"
            ;;
        2)
            passwd -l root 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Root заблокирован${RESET}"
            ;;
        3)
            passwd -u root 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Root разблокирован${RESET}"
            ;;
        4)
            ensure_ssh_config "PermitRootLogin" "yes"
            reload_ssh_safe
            echo -e "${BLUE}   └─ ${GREEN}SSH root login разрешён${RESET}"
            ;;
        5)
            ensure_ssh_config "PermitRootLogin" "no"
            reload_ssh_safe
            echo -e "${BLUE}   └─ ${GREEN}SSH root login запрещён${RESET}"
            ;;
        0) return ;;
        *)
            echo -e "${RED}Неверная опция!${RESET}"
            sleep 1
            ;;
    esac

    echo ""
    pause
}

user_list_all() {
    clear
    echo -e "${WHITE}${BOLD}📋 ВСЕ ПОЛЬЗОВАТЕЛИ${RESET}"
    sep 70
    echo ""

    echo -e "${BLUE}Пользователи с оболочкой:${RESET}"
    awk -F: '$7 != "/usr/sbin/nologin" && $7 != "/bin/false" {printf "  %-20s UID: %-6s GID: %-6s\n", $1, $3, $4}' /etc/passwd 2>/dev/null | head -30
    
    local total=$(awk -F: '$7 != "/usr/sbin/nologin" && $7 != "/bin/false"' /etc/passwd 2>/dev/null | wc -l)
    [ "$total" -gt 30 ] && echo -e "  ${DIM}... и ещё $((total - 30)) пользователей${RESET}"
    
    echo ""
    echo -e "${BLUE}Системные (без оболочки):${RESET}"
    awk -F: '$7 == "/usr/sbin/nologin" || $7 == "/bin/false" {printf "  %-20s\n", $1}' /etc/passwd 2>/dev/null | head -10
    
    echo ""
    sep 70
    pause
}

user_info() {
    clear
    echo -e "${WHITE}${BOLD}🔍 ИНФОРМАЦИЯ О ПОЛЬЗОВАТЕЛЕ${RESET}"
    sep 70
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Имя пользователя${RESET}: ")" username

    if ! id "$username" &>/dev/null; then
        echo -e "${RED}   └─ Пользователь не найден!${RESET}"
        sleep 2
        return
    fi

    echo ""
    echo -e "${MAGENTA}${BOLD}Информация о ${CYAN}${username}${RESET}"
    sep 70
    
    id "$username" 2>/dev/null
    echo ""
    
    echo -e "${BLUE}Статус пароля:${RESET}"
    passwd -S "$username" 2>/dev/null
    echo ""
    
    echo -e "${BLUE}Последние входы:${RESET}"
    last "$username" 2>/dev/null | head -5 || echo "  Нет данных"
    echo ""
    
    echo -e "${BLUE}Процессы пользователя:${RESET}"
    ps -u "$username" -o pid,cmd --no-headers 2>/dev/null | head -5 || echo "  Нет активных процессов"
    
    echo ""
    sep 70
    pause
}

user_security_check() {
    clear
    echo -e "${WHITE}${BOLD}🛡️  ПРОВЕРКА БЕЗОПАСНОСТИ ПОЛЬЗОВАТЕЛЕЙ${RESET}"
    sep 70
    echo ""

    echo -e "${MAGENTA}${BOLD}ПОЛЬЗОВАТЕЛИ БЕЗ ПАРОЛЯ:${RESET}"
    local no_pass=$(awk -F: '($2 == "" || $2 == "!") {print "  ⚠️  "$1}' /etc/shadow 2>/dev/null)
    [ -n "$no_pass" ] && echo "$no_pass" || echo -e "  ${GREEN}✅ Нет${RESET}"
    echo ""

    echo -e "${MAGENTA}${BOLD}ПОЛЬЗОВАТЕЛИ С ПУСТЫМ ПАРОЛЕМ:${RESET}"
    local empty_pass=$(awk -F: '($2 == "") {print "  ⚠️  "$1}' /etc/shadow 2>/dev/null)
    [ -n "$empty_pass" ] && echo "$empty_pass" || echo -e "  ${GREEN}✅ Нет${RESET}"
    echo ""

    echo -e "${MAGENTA}${BOLD}ROOT С ПАРОЛЕМ:${RESET}"
    local root_pass=$(passwd -S root 2>/dev/null | awk '{print $2}')
    if [ "$root_pass" = "P" ]; then
        echo -e "  ${RED}❌ Root имеет пароль!${RESET}"
    else
        echo -e "  ${GREEN}✅ Root без пароля${RESET}"
    fi
    echo ""

    echo -e "${MAGENTA}${BOLD}ПОСЛЕДНИЕ НЕУДАЧНЫЕ ВХОДЫ:${RESET}"
    lastb 2>/dev/null | head -5 || echo "  Нет данных"
    
    echo ""
    sep 70
    pause
}

# ==============================================================================
# 🔑 SSH HARDENING FUNCTIONS
# ==============================================================================
ssh_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🔑 SSH - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local ssh_status=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo "inactive")
        local ssh_port=$(get_ssh_port || echo "22")
        echo -e "   Статус: ${GREEN}$ssh_status${RESET} | Порт: ${RED}$ssh_port${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Изменить порт SSH"
        echo -e "   ${GREEN}2)${RESET} Настроить аутентификацию по ключам"
        echo -e "   ${GREEN}3)${RESET} Показать текущую конфигурацию"
        echo -e "   ${GREEN}4)${RESET} Перезапустить SSH"
        echo -e "   ${GREEN}5)${RESET} Тонкая настройка параметров"
        echo -e "   ${GREEN}6)${RESET} Управление пользователями (AllowUsers)"
        echo -e "   ${GREEN}7)${RESET} ℹ️  Информация"
        menu_prompt 7

        case "$menu_choice" in
            1) ssh_change_port ;;
            2) ssh_setup_keys ;;
            3) ssh_show_config ;;
            4) ssh_restart ;;
            5) ssh_advanced_config ;;
            6) ssh_manage_users ;;
            7) ssh_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

ssh_info() {
    clear
    echo -e "${WHITE}${BOLD}🔑 SSH - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Изменить порт SSH${RESET}"
    echo -e "   ${DIM}Меняет стандартный порт 22 на другой (например 2222)${RESET}"
    echo -e "   ${DIM}⚠️  После смены переподключитесь на новом порту!${RESET}"
    echo ""
    echo -e "${CYAN}2. Аутентификация по ключам${RESET}"
    echo -e "   ${DIM}Включает вход по SSH-ключам вместо пароля${RESET}"
    echo -e "   ${DIM}🔒 Режим 'Только ключи' — максимальная защита${RESET}"
    echo ""
    echo -e "${CYAN}3. Показать конфигурацию${RESET}"
    echo -e "   ${DIM}Выводит все активные настройки /etc/ssh/sshd_config${RESET}"
    echo ""
    echo -e "${CYAN}4. Перезапустить SSH${RESET}"
    echo -e "   ${DIM}Применяет изменения конфигурации${RESET}"
    echo -e "   ${DIM}⚠️  Не закрывайте сессию до проверки!${RESET}"
    echo ""
    echo -e "${CYAN}5. Тонкая настройка${RESET}"
    echo -e "   ${DIM}MaxAuthTries — максимум попыток входа (3)${RESET}"
    echo -e "   ${DIM}MaxSessions — максимум сессий (2)${RESET}"
    echo -e "   ${DIM}ClientAliveInterval — проверка активности (300с)${RESET}"
    echo -e "   ${DIM}X11Forwarding — перенаправление X11${RESET}"
    echo -e "   ${DIM}LogLevel — уровень логирования${RESET}"
    echo ""
    echo -e "${CYAN}6. Управление пользователями${RESET}"
    echo -e "   ${DIM}AllowUsers — список разрешённых пользователей${RESET}"
    echo -e "   ${DIM}🔒 Рекомендуется: только ваши пользователи${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}1. Смените порт с 22 на нестандартный${RESET}"
    echo -e "   ${DIM}2. Запретите вход по паролю (только ключи)${RESET}"
    echo -e "   ${DIM}3. Запретите root login${RESET}"
    echo -e "   ${DIM}4. Настройте AllowUsers${RESET}"
    echo ""
    sep
    pause
}

ssh_change_port() {
    clear
    echo -e "${WHITE}${BOLD}🔑 ИЗМЕНИТЬ ПОРТ SSH${RESET}"
    sep
    echo ""

    local current_port=$(get_ssh_port)
    [ -z "$current_port" ] && current_port="22 (по умолчанию)"
    echo -e "${BLUE}Текущий порт: ${RED}$current_port${RESET}"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Новый SSH порт${RESET} ${DIM}(например, ${RED}2222${RESET}${DIM})${RESET}: ")" new_port

    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}   └─ Неверный номер порта!${RESET}"
        sleep 1
        return
    fi

    # Backup
    cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.port_backup.bak" 2>/dev/null || true

    # Проверяем используется ли socket activation
    local use_socket=false
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        use_socket=true
        echo -e "${BLUE}   ├─ ${YELLOW}Обнаружен SSH socket activation${RESET}"
    fi

    # Обновляем порт в sshd_config
    if grep -q "^Port" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i "s/^Port.*/Port $new_port/" /etc/ssh/sshd_config 2>/dev/null
    elif grep -q "^#Port" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i "s/^#Port.*/Port $new_port/" /etc/ssh/sshd_config 2>/dev/null
    else
        echo "Port $new_port" >> /etc/ssh/sshd_config 2>/dev/null
    fi
    echo -e "${BLUE}   ├─ ${GREEN}Порт записан в sshd_config${RESET}"

    # Если используется socket — обновляем порт там тоже
    if [ "$use_socket" = true ]; then
        local socket_file="/lib/systemd/system/ssh.socket"
        local socket_override="/etc/systemd/system/ssh.socket"
        
        # Проверяем где лежит socket файл
        if [ -f "$socket_override" ]; then
            socket_file="$socket_override"
        elif [ ! -f "$socket_file" ]; then
            # Создаём override файл
            mkdir -p /etc/systemd/system/ssh.socket.d 2>/dev/null
            cat > /etc/systemd/system/ssh.socket.d/port.conf << EOF
[Socket]
ListenStream=$new_port
EOF
            socket_file="/etc/systemd/system/ssh.socket.d/port.conf"
            echo -e "${BLUE}   ├─ Создан override файл для socket${RESET}"
        fi
        
        # Обновляем порт в socket
        if grep -q "^ListenStream=" "$socket_file" 2>/dev/null; then
            sed -i "s/^ListenStream=.*/ListenStream=$new_port/" "$socket_file" 2>/dev/null
        else
            echo "ListenStream=$new_port" >> "$socket_file" 2>/dev/null
        fi
        echo -e "${BLUE}   ├─ ${GREEN}Порт обновлён в systemd socket${RESET}"
        
        # Перезагружаем systemd и socket
        systemctl daemon-reload 2>/dev/null
        systemctl restart ssh.socket 2>/dev/null
        echo -e "${BLUE}   ├─ systemd socket перезапущен${RESET}"
    fi

    # Добавляем порт в Firewall
    if command -v ufw &>/dev/null; then
        echo -e "${BLUE}   ├─ Добавляем порт в Firewall...${RESET}"
        ufw allow "$new_port/tcp" 2>/dev/null
        echo -e "${BLUE}   ├─ ${GREEN}Порт $new_port добавлен в UFW${RESET}"
    fi

    # Перезапускаем SSH
    echo -e "${BLUE}   ├─ Перезапускаем SSH...${RESET}"
    reload_ssh_safe
    sleep 3

    # Проверка
    echo ""
    echo -e "${BLUE}Проверка порта:${RESET}"
    if ss -tlnp 2>/dev/null | grep -q ":$new_port"; then
        echo -e "${BLUE}   └─ ${GREEN}✅ SSH слушает порт $new_port${RESET}"
        log_action "SSH: Port changed to $new_port"
        echo ""
        echo -e "${RED}⚠️  ВНИМАНИЕ: Переподключитесь на новом порту!${RESET}"
        echo -e "${DIM}   ssh -p $new_port user@${RESET}$(curl -s ifconfig.me 2>/dev/null || echo "server_ip")"
    else
        echo -e "${BLUE}   └─ ${RED}❌ SSH не слушает порт $new_port${RESET}"
        echo -e "${YELLOW}   └─ Проверьте логи: journalctl -u ssh${RESET}"
        log_action "ERROR: SSH port change failed"
    fi

    echo ""
    pause
}

ssh_setup_keys() {
    clear
    echo -e "${WHITE}${BOLD}🔑 АУТЕНТИФИКАЦИЯ ПО КЛЮЧАМ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Настройки аутентификации:${RESET}"
    local pubkey_auth=$(grep -E "^PubkeyAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not set")
    local password_auth=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not set")
    echo -e "   PubkeyAuthentication: ${CYAN}$pubkey_auth${RESET}"
    echo -e "   PasswordAuthentication: ${CYAN}$password_auth${RESET}"
    echo ""

    echo -e "${YELLOW}Выберите действие:${RESET}"
    echo -e "   ${CYAN}1.${RESET} Включить аутентификацию по ключам"
    echo -e "   ${CYAN}2.${RESET} Отключить аутентификацию по ключам"
    echo -e "   ${CYAN}3.${RESET} Включить парольную аутентификацию"
    echo -e "   ${CYAN}4.${RESET} Отключить парольную аутентификацию"
    echo -e "   ${CYAN}5.${RESET} Только ключи (максимальная защита)"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите опцию [1-5]: ")" choice

    case "$choice" in
        1)
            ensure_ssh_config "PubkeyAuthentication" "yes"
            echo -e "${BLUE}   └─ ${GREEN}Аутентификация по ключам включена${RESET}"
            ;;
        2)
            ensure_ssh_config "PubkeyAuthentication" "no"
            echo -e "${BLUE}   └─ ${GREEN}Аутентификация по ключам отключена${RESET}"
            ;;
        3)
            ensure_ssh_config "PasswordAuthentication" "yes"
            echo -e "${BLUE}   └─ ${GREEN}Парольная аутентификация включена${RESET}"
            ;;
        4)
            ensure_ssh_config "PasswordAuthentication" "no"
            echo -e "${BLUE}   └─ ${GREEN}Парольная аутентификация отключена${RESET}"
            ;;
        5)
            ensure_ssh_config "PubkeyAuthentication" "yes"
            ensure_ssh_config "PasswordAuthentication" "no"
            ensure_ssh_config "ChallengeResponseAuthentication" "no"
            echo -e "${BLUE}   └─ ${GREEN}Только ключи${RESET}"
            echo -e "${RED}⚠️  Убедитесь, что ваш ключ добавлен в ~/.ssh/authorized_keys!${RESET}"
            ;;
    esac

    reload_ssh_safe
    log_action "SSH: Key authentication settings changed"

    echo ""
    pause
}

ssh_setup_banner() {
    clear
    echo -e "${WHITE}${BOLD}🔑 НАСТРОЙКА SSH БАННЕРА${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Баннер - это сообщение, которое видят пользователи при подключении.${RESET}"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Использовать стандартный баннер? [y/N]: ${RESET}")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cat <<EOF > /etc/issue.net
***************************************************************************
                          NOTICE TO USERS
This is a private system. Unauthorized access is prohibited.
All activities may be monitored and recorded.
***************************************************************************
EOF
        ensure_ssh_config "Banner" "/etc/issue.net"
        reload_ssh_safe
        echo -e "${BLUE}   └─ ${GREEN}Баннер установлен${RESET}"
        log_action "SSH: Banner configured"
    else
        read -rp "$(echo -e "${BLUE}   ├─${RESET} Введите путь к файлу баннера: ")" banner_path
        if [ -f "$banner_path" ]; then
            ensure_ssh_config "Banner" "$banner_path"
            reload_ssh_safe
            echo -e "${BLUE}   └─ ${GREEN}Баннер установлен: $banner_path${RESET}"
        else
            echo -e "${RED}   └─ Файл не найден!${RESET}"
        fi
    fi

    echo ""
    pause
}

ssh_show_config() {
    clear
    echo -e "${WHITE}${BOLD}🔑 ТЕКУЩАЯ КОНФИГУРАЦИЯ SSH${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Конфигурация /etc/ssh/sshd_config:${RESET}"
    echo ""
    grep -v "^#" /etc/ssh/sshd_config 2>/dev/null | grep -v "^$" || echo -e "${YELLOW}Не удалось прочитать конфиг${RESET}"
    echo ""
    sep
    pause
}

ssh_restart() {
    clear
    echo -e "${WHITE}${BOLD}🔑 ПЕРЕЗАПУСК SSH${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Проверка конфигурации и перезапуск...${RESET}"
    reload_ssh_safe
    local exit_code=$?
    sleep 2

    if [ $exit_code -eq 0 ] && (systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null); then
        echo -e "${BLUE}   └─ ${GREEN}SSH успешно перезапущен${RESET}"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка перезапуска${RESET}"
    fi

    echo ""
    pause
}

ssh_advanced_config() {
    clear
    echo -e "${WHITE}${BOLD}🔑 ТОНКАЯ НАСТРОЙКА SSH${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ПАРАМЕТРЫ КОНФИГУРАЦИИ:${RESET}"
    echo ""
    echo -e "   ${CYAN}1.${RESET} MaxAuthTries (максимум попыток аутентификации)"
    echo -e "   ${CYAN}2.${RESET} MaxSessions (максимум сессий)"
    echo -e "   ${CYAN}3.${RESET} ClientAliveInterval (интервал проверки активности)"
    echo -e "   ${CYAN}4.${RESET} ClientAliveCountMax (максимум пропущенных проверок)"
    echo -e "   ${CYAN}5.${RESET} X11Forwarding (перенаправление X11)"
    echo -e "   ${CYAN}6.${RESET} AllowTcpForwarding (TCP форвардинг)"
    echo -e "   ${CYAN}7.${RESET} LogLevel (уровень логирования)"
    echo ""
    sep
    echo -e "   ${RED}0)${RESET} ↩️  Назад"
    echo ""

    read -p "$(echo -e "${WHITE}Выберите опцию [0-7]:${RESET} ")" choice

    case "$choice" in
        1)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое значение (например 3): ")" val
            ensure_ssh_config "MaxAuthTries" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        2)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое значение (например 2): ")" val
            ensure_ssh_config "MaxSessions" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        3)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое значение в секундах (например 300): ")" val
            ensure_ssh_config "ClientAliveInterval" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        4)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое значение (например 2): ")" val
            ensure_ssh_config "ClientAliveCountMax" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        5)
            echo -e "${BLUE}   ├─ Доступные значения: yes, no${RESET}"
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите значение: ")" val
            ensure_ssh_config "X11Forwarding" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        6)
            echo -e "${BLUE}   ├─ Доступные значения: yes, no${RESET}"
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите значение: ")" val
            ensure_ssh_config "AllowTcpForwarding" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        7)
            echo -e "${BLUE}   ├─ Доступные уровни: QUIET, FATAL, ERROR, INFO, VERBOSE, DEBUG${RESET}"
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите уровень: ")" val
            ensure_ssh_config "LogLevel" "$val"
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            ;;
        0) return ;;
    esac

    reload_ssh_safe
    log_action "SSH: Advanced config changed"
    echo ""
    pause
}

ssh_manage_users() {
    clear
    echo -e "${WHITE}${BOLD}🔑 УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ (AllowUsers)${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Текущий список разрешённых пользователей:${RESET}"
    echo ""
    grep -E "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null || echo -e "${YELLOW}AllowUsers не настроен${RESET}"
    echo ""

    echo -e "${YELLOW}Выберите действие:${RESET}"
    echo -e "   ${CYAN}1.${RESET} Добавить пользователя"
    echo -e "   ${CYAN}2.${RESET} Удалить пользователя"
    echo -e "   ${CYAN}3.${RESET} Сбросить список (разрешить всем)"
    echo -e "   ${CYAN}0.${RESET} ↩️  Назад"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите опцию [0-3]: ")" choice

    case "$choice" in
        1)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Введите имя пользователя: ")" username
            if [ -z "$username" ]; then
                echo -e "${RED}   └─ Имя не может быть пустым!${RESET}"
                sleep 1
                return
            fi
            if id "$username" &>/dev/null; then
                if grep -q "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null; then
                    current_users=$(grep "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}' || echo "")
                    if [[ ! " $current_users " =~ " $username " ]]; then
                        sed -i "s/^AllowUsers.*/AllowUsers $current_users $username/" /etc/ssh/sshd_config 2>/dev/null
                        echo -e "${BLUE}   └─ ${GREEN}Пользователь $username добавлен${RESET}"
                    else
                        echo -e "${YELLOW}   └─ Пользователь уже в списке${RESET}"
                    fi
                else
                    ensure_ssh_config "AllowUsers" "$username"
                    echo -e "${BLUE}   └─ ${GREEN}Пользователь $username добавлен${RESET}"
                fi
            else
                echo -e "${RED}   └─ Пользователь не существует!${RESET}"
            fi
            reload_ssh_safe
            ;;
        2)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Введите имя пользователя: ")" username
            if [ -z "$username" ]; then
                echo -e "${RED}   └─ Имя не может быть пустым!${RESET}"
                sleep 1
                return
            fi
            if grep -q "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null; then
                current_users=$(grep "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null | awk '{for(i=2;i<=NF;i++) printf "%s ", $i}' || echo "")
                new_users=$(echo "$current_users" | sed "s/[[:<:]]$username[[:>:]]//g" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
                if [ -n "$new_users" ]; then
                    sed -i "s/^AllowUsers.*/AllowUsers $new_users/" /etc/ssh/sshd_config 2>/dev/null
                    echo -e "${BLUE}   └─ ${GREEN}Пользователь $username удалён${RESET}"
                else
                    # Удаляем строку AllowUsers полностью (список пуст)
                    sed -i "/^AllowUsers/d" /etc/ssh/sshd_config 2>/dev/null
                    echo -e "${BLUE}   └─ ${GREEN}Пользователь $username удалён (AllowUsers очищен)${RESET}"
                fi
            else
                echo -e "${YELLOW}   └─ AllowUsers не настроен${RESET}"
            fi
            reload_ssh_safe
            ;;
        3)
            sed -i "/^AllowUsers/d" /etc/ssh/sshd_config 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}AllowUsers удалён (разрешено всем)${RESET}"
            reload_ssh_safe
            ;;
        0) return ;;
        *)
            echo -e "${RED}Неверная опция!${RESET}"
            sleep 1
            ;;
    esac

    log_action "SSH: AllowUsers modified"
    echo ""
    pause
}

# ==============================================================================
# 🔥 FIREWALL FUNCTIONS
# ==============================================================================
firewall_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🔥 FIREWALL (UFW) - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local ufw_status_check=$(ufw status 2>/dev/null | grep -c "Status: active")
        local ufw_status="inactive"
        [ "$ufw_status_check" -ge 1 ] && ufw_status="active"
        local rules_count=$(ufw status numbered 2>/dev/null | grep -c "\[" || echo "0")
        echo -e "   Статус: ${GREEN}$ufw_status${RESET} | Правил: ${CYAN}$rules_count${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Настроить базовый Firewall (порты 22, 80, 443)"
        echo -e "   ${GREEN}2)${RESET} Показать статус и правила"
        echo -e "   ${GREEN}3)${RESET} Открыть порт"
        echo -e "   ${GREEN}4)${RESET} Закрыть порт"
        echo -e "   ${GREEN}5)${RESET} Удалить правило по номеру"
        echo -e "   ${GREEN}6)${RESET} Включить/Выключить Firewall"
        echo -e "   ${GREEN}7)${RESET} Сбросить Firewall"
        echo -e "   ${GREEN}8)${RESET} Логирование UFW"
        echo -e "   ${GREEN}9)${RESET} ℹ️  Информация"
        menu_prompt 9

        case "$menu_choice" in
            1) configure_firewall_basic ;;
            2) firewall_show_status ;;
            3) firewall_open_port ;;
            4) firewall_close_port ;;
            5) firewall_delete_rule ;;
            6) firewall_toggle ;;
            7) firewall_reset ;;
            8) firewall_logging ;;
            9) firewall_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

firewall_info() {
    clear
    echo -e "${WHITE}${BOLD}🔥 FIREWALL - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Базовая настройка${RESET}"
    echo -e "   ${DIM}Открывает порты: SSH (22), HTTP (80), HTTPS (443)${RESET}"
    echo -e "   ${DIM}Включает Firewall с защитой по умолчанию${RESET}"
    echo ""
    echo -e "${CYAN}2. Статус и правила${RESET}"
    echo -e "   ${DIM}Показывает текущий статус UFW${RESET}"
    echo -e "   ${DIM}Все активные правила с номерами${RESET}"
    echo ""
    echo -e "${CYAN}3. Открыть порт${RESET}"
    echo -e "   ${DIM}Открывает указанный порт${RESET}"
    echo -e "   ${DIM}Протоколы: tcp, udp, или оба${RESET}"
    echo ""
    echo -e "${CYAN}4. Закрыть порт${RESET}"
    echo -e "   ${DIM}Закрывает указанный порт${RESET}"
    echo -e "   ${DIM}Удаляет правило из конфигурации${RESET}"
    echo ""
    echo -e "${CYAN}5. Удалить правило по номеру${RESET}"
    echo -e "   ${DIM}Удаляет правило по его номеру в списке${RESET}"
    echo -e "   ${DIM}Используйте после просмотра статуса${RESET}"
    echo ""
    echo -e "${CYAN}6. Включить/Выключить${RESET}"
    echo -e "   ${DIM}Полная активация или остановка Firewall${RESET}"
    echo -e "   ${DIM}⚠️  Не выключайте без необходимости!${RESET}"
    echo ""
    echo -e "${CYAN}7. Сбросить Firewall${RESET}"
    echo -e "   ${DIM}Полный сброс ко всем настройкам по умолчанию${RESET}"
    echo -e "   ${DIM}⚠️  Все правила будут удалены!${RESET}"
    echo ""
    echo -e "${CYAN}8. Логирование${RESET}"
    echo -e "   ${DIM}Уровни: off, low, medium, high, full${RESET}"
    echo -e "   ${DIM}Записывает заблокированные соединения в лог${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}• Включите Firewall сразу после настройки SSH${RESET}"
    echo -e "   ${DIM}• Откройте только необходимые порты${RESET}"
    echo -e "   ${DIM}• Периодически проверяйте список правил${RESET}"
    echo -e "   ${DIM}• Включите логирование для безопасности${RESET}"
    echo ""
    sep
    pause
}

configure_firewall_basic() {
    clear
    echo -e "${WHITE}${BOLD}🔥 НАСТРОЙКА FIREWALL (UFW)${RESET}"
    sep 50
    echo ""

    # Получаем актуальный SSH порт из конфига
    local actual_ssh_port=$(get_ssh_port)
    actual_ssh_port=${actual_ssh_port:-$SSH_PORT}

    echo -e "${BLUE}${ICON_SHIELD} ${BOLD}Настройка Firewall${RESET}"
    echo -e "${BLUE}   ├─ Будут открыты порты:${RESET}"
    echo -e "${BLUE}   │   - SSH: ${RED}${actual_ssh_port}${RESET}"
    echo -e "${BLUE}   │   - HTTP: 80${RESET}"
    echo -e "${BLUE}   │   - HTTPS: 443${RESET}"
    echo ""
    echo -e "${YELLOW}${ICON_WARN} Активировать Firewall?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_firewall
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

apply_firewall() {
    log_action "Configuring firewall"

    # Получаем актуальный SSH порт из конфига
    local actual_ssh_port=$(get_ssh_port)
    actual_ssh_port=${actual_ssh_port:-$SSH_PORT}

    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    ufw allow "${actual_ssh_port}/tcp" >/dev/null 2>&1
    echo -e "${BLUE}   ├─ Порт SSH${RESET} ${RED}(${actual_ssh_port})${RESET} ......... ${GREEN}OPEN${RESET}"

    ufw allow 80/tcp >/dev/null 2>&1
    echo -e "${BLUE}   ├─ Порт HTTP${RESET} ${RED}(80)${RESET} ........... ${GREEN}OPEN${RESET}"

    ufw allow 443/tcp >/dev/null 2>&1
    echo -e "${BLUE}   ├─ Порт HTTPS${RESET} ${RED}(443)${RESET} .......... ${GREEN}OPEN${RESET}"

    if ufw --force enable >/dev/null 2>&1; then
        echo -e "${BLUE}   └─ ${GREEN}Firewall активирован${RESET}"
        log_action "Firewall configured"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка активации Firewall${RESET}"
        echo -e "${YELLOW}   └─ Сбрасываю Firewall...${RESET}"
        ufw --force reset >/dev/null 2>&1
        log_action "ERROR: Firewall failed to enable - reset"
        echo -e "${RED}⚠️  Firewall сброшен! Проверьте конфигурацию.${RESET}"
    fi
}

firewall_show_status() {
    clear
    echo -e "${WHITE}${BOLD}🔥 СТАТУС FIREWALL${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Полный статус UFW:${RESET}"
    echo ""
    ufw status verbose 2>/dev/null || echo -e "${YELLOW}Не удалось получить статус${RESET}"
    echo ""
    echo -e "${BLUE}Нумерованные правила:${RESET}"
    echo ""
    ufw status numbered 2>/dev/null || echo -e "${YELLOW}Не удалось получить правила${RESET}"
    echo ""
    sep
    pause
}

firewall_open_port() {
    clear
    echo -e "${WHITE}${BOLD}🔥 ОТКРЫТЬ ПОРТ${RESET}"
    sep
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Введите номер порта${RESET}: ")" port
    [ -z "$port" ] && { echo -e "${RED}   └─ Порт не может быть пустым!${RESET}"; sleep 1; return; }
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Протокол (tcp/udp/both)${RESET}: ")" protocol
    [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}   └─ Неверный номер порта!${RESET}"; sleep 1; return; }

    local suffix=$(firewall_port_cmd "allow" "$port" "$protocol")
    echo -e "${BLUE}   └─ ${GREEN}Порт $port${suffix} открыт${RESET}"
    log_action "Firewall: Opened port $port ($protocol)"
    echo ""
    pause
}

firewall_close_port() {
    clear
    echo -e "${WHITE}${BOLD}🔥 ЗАКРЫТЬ ПОРТ${RESET}"
    sep
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Введите номер порта${RESET}: ")" port
    [ -z "$port" ] && { echo -e "${RED}   └─ Порт не может быть пустым!${RESET}"; sleep 1; return; }
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Протокол (tcp/udp/both)${RESET}: ")" protocol
    [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}   └─ Неверный номер порта!${RESET}"; sleep 1; return; }

    local suffix=$(firewall_port_cmd "delete allow" "$port" "$protocol")
    echo -e "${BLUE}   └─ ${GREEN}Порт $port${suffix} закрыт${RESET}"
    log_action "Firewall: Closed port $port ($protocol)"
    echo ""
    pause
}

firewall_delete_rule() {
    clear
    echo -e "${WHITE}${BOLD}🔥 УДАЛИТЬ ПРАВИЛО ПО НОМЕРУ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Нумерованные правила:${RESET}"
    echo ""
    ufw status numbered 2>/dev/null || echo -e "${YELLOW}Не удалось получить правила${RESET}"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Введите номер правила для удаления${RESET}: ")" rule_num

    if [ -z "$rule_num" ]; then
        echo -e "${RED}   └─ Номер не может быть пустым!${RESET}"
        sleep 1
        return
    fi

    if [[ ! "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}   └─ Неверный номер!${RESET}"
        sleep 1
        return
    fi

    ufw delete "$rule_num" --force 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${BLUE}   └─ ${GREEN}Правило #$rule_num удалено${RESET}"
        log_action "Firewall: Deleted rule #$rule_num"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка удаления правила${RESET}"
    fi

    echo ""
    pause
}

firewall_toggle() {
    service_toggle \
        "🔥 ВКЛЮЧИТЬ/ВЫКЛЮЧИТЬ FIREWALL" \
        "Firewall" "Firewall" \
        'ufw status 2>/dev/null | grep -q "Status: active"' \
        'ufw --force enable' \
        'ufw --force disable'
}

firewall_reset() {
    clear
    echo -e "${WHITE}${BOLD}🔥 СБРОСИТЬ FIREWALL${RESET}"
    sep
    echo ""

    echo -e "${RED}⚠️  ВНИМАНИЕ!${RESET}"
    echo -e "${DIM}   Все правила будут удалены!${RESET}"
    echo ""
    read -p "$(echo -e "${RED}Вы уверены? [y/N]: ${RESET}")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        ufw --force reset 2>/dev/null
        echo -e "${BLUE}   └─ ${GREEN}Firewall сброшен к настройкам по умолчанию${RESET}"
        log_action "Firewall: Reset"
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

firewall_logging() {
    clear
    echo -e "${WHITE}${BOLD}🔥 ЛОГИРОВАНИЕ UFW${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Уровни логирования:${RESET}"
    echo -e "   ${CYAN}•${RESET} off   - отключено"
    echo -e "   ${CYAN}•${RESET} low   - низкий уровень"
    echo -e "   ${CYAN}•${RESET} medium - средний уровень"
    echo -e "   ${CYAN}•${RESET} high  - высокий уровень"
    echo -e "   ${CYAN}•${RESET} full  - полный"
    echo ""
    echo -e "${BLUE}Текущий уровень:${RESET}"
    ufw logging 2>/dev/null | head -1 || echo -e "${YELLOW}Не удалось получить${RESET}"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Изменить уровень? (off/low/medium/high/full/no): ")" log_level

    case "$log_level" in
        off|low|medium|high|full)
            ufw logging "$log_level" 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Уровень логирования установлен: $log_level${RESET}"
            log_action "Firewall: Logging set to $log_level"
            ;;
        no|*)
            echo -e "${YELLOW}   └─ Изменения отменены${RESET}"
            ;;
    esac

    echo ""
    pause
}

# ==============================================================================
# 🛡️ FAIL2BAN FUNCTIONS
# ==============================================================================
fail2ban_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🛡️ FAIL2BAN - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local f2b_status=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")
        local banned_count=$(fail2ban-client status sshd 2>/dev/null | grep -oP 'Currently banned:\s*\K\d+' || echo "0")
        echo -e "   Статус: ${GREEN}$f2b_status${RESET} | Забанено IP: ${RED}$banned_count${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Настроить базовую конфигурацию (jail.local)"
        echo -e "   ${GREEN}2)${RESET} Посмотреть список заблокированных IP"
        echo -e "   ${GREEN}3)${RESET} Добавить IP в блэклист"
        echo -e "   ${GREEN}4)${RESET} Удалить IP из блэклиста"
        echo -e "   ${GREEN}5)${RESET} Статус банов (за 24 часа)"
        echo -e "   ${GREEN}6)${RESET} Перезапустить Fail2Ban"
        echo -e "   ${GREEN}7)${RESET} Включить/Выключить Fail2Ban"
        echo -e "   ${GREEN}8)${RESET} Тонкая настройка конфигурации"
        echo -e "   ${GREEN}9)${RESET} ℹ️  Информация"
        menu_prompt 9

        case "$menu_choice" in
            1) configure_fail2ban_basic ;;
            2) fail2ban_show_banned ;;
            3) fail2ban_add_ip ;;
            4) fail2ban_remove_ip ;;
            5) fail2ban_show_stats ;;
            6) fail2ban_restart ;;
            7) fail2ban_toggle ;;
            8) fail2ban_advanced_config ;;
            9) fail2ban_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

fail2ban_info() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ FAIL2BAN - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Базовая конфигурация${RESET}"
    echo -e "   ${DIM}Создаёт jail.local с настройками для защиты SSH${RESET}"
    echo -e "   ${DIM}Ban time: 1 час, Max retry: 3${RESET}"
    echo ""
    echo -e "${CYAN}2. Список заблокированных IP${RESET}"
    echo -e "   ${DIM}Показывает все IP, заблокированные Fail2Ban${RESET}"
    echo ""
    echo -e "${CYAN}3. Добавить IP в блэклист${RESET}"
    echo -e "   ${DIM}Ручная блокировка подозрительного IP${RESET}"
    echo -e "   ${DIM}Укажите IP и время блокировки${RESET}"
    echo ""
    echo -e "${CYAN}4. Удалить IP из блэклиста${RESET}"
    echo -e "   ${DIM}Разблокировка IP (если ошибочно заблокирован)${RESET}"
    echo ""
    echo -e "${CYAN}5. Статус банов${RESET}"
    echo -e "   ${DIM}Показывает статистику по всем тюрьмам${RESET}"
    echo -e "   ${DIM}Количество банов за 24 часа${RESET}"
    echo ""
    echo -e "${CYAN}6. Перезапустить Fail2Ban${RESET}"
    echo -e "   ${DIM}Применяет изменения конфигурации${RESET}"
    echo ""
    echo -e "${CYAN}7. Включить/Выключить${RESET}"
    echo -e "   ${DIM}Полная активация или остановка службы${RESET}"
    echo ""
    echo -e "${CYAN}8. Тонкая настройка${RESET}"
    echo -e "   ${DIM}Ban time — время блокировки (1h, 1d)${RESET}"
    echo -e "   ${DIM}Find time — окно обнаружения (10m)${RESET}"
    echo -e "   ${DIM}Max retry — максимум попыток (3)${RESET}"
    echo -e "   ${DIM}Ignore IP — белый список IP${RESET}"
    echo -e "   ${DIM}Mode — режим работы (aggressive)${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}• Включите Fail2Ban сразу после настройки SSH${RESET}"
    echo -e "   ${DIM}• Добавьте свой IP в белый список${RESET}"
    echo -e "   ${DIM}• Проверяйте статистику банов периодически${RESET}"
    echo ""
    sep
    pause
}

configure_fail2ban_basic() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ НАСТРОЙКА FAIL2BAN${RESET}"
    sep 50
    echo ""

    echo -e "${BLUE}${ICON_SHIELD} ${BOLD}Базовая конфигурация${RESET}"
    echo -e "${BLUE}   ├─ Ban time: 1h${RESET}"
    echo -e "${BLUE}   ├─ Max retry: 3${RESET}"
    echo -e "${BLUE}   └─ Protect: SSH (port ${SSH_PORT})${RESET}"
    echo ""
    echo -e "${YELLOW}${ICON_WARN} Настроить Fail2Ban?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_fail2ban
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

apply_fail2ban() {
    log_action "Configuring Fail2Ban"

    local my_ip=$(curl -s ifconfig.me 2>/dev/null || echo "127.0.0.1")

    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime  = 10m
maxretry = 3
ignoreip = 127.0.0.1/8 ::1 $my_ip

[sshd]
enabled = true
port = ${SSH_PORT}
mode = aggressive
backend = systemd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1

    if systemctl is-active --quiet fail2ban; then
        echo -e "${BLUE}   └─ ${GREEN}Fail2Ban активен${RESET}"
        log_action "Fail2Ban configured"
    else
        echo -e "${BLUE}   └─ ${YELLOW}Fail2Ban не запустился${RESET}"
        log_action "WARNING: Fail2Ban failed to start"
    fi
}

fail2ban_show_banned() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ ЗАБАНЕННЫЕ IP АДРЕСА${RESET}"
    sep
    echo ""

    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${RED}Fail2Ban не активен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Список заблокированных IP:${RESET}"
    echo ""
    fail2ban-client get sshd banlist 2>/dev/null || echo -e "${YELLOW}Не удалось получить список${RESET}"
    echo ""
    sep
    pause
}

fail2ban_add_ip() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ ДОБАВИТЬ IP В БЛЭКЛИСТ${RESET}"
    sep
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Введите IP адрес для блокировки${RESET}: ")" ban_ip

    if [[ ! "$ban_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}   └─ Неверный формат IP!${RESET}"
        sleep 1
        return
    fi

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Время блокировки (сек, например 3600)${RESET}: ")" ban_time
    ban_time=${ban_time:-3600}

    local orig_bantime=$(fail2ban-client get sshd bantime 2>/dev/null)
    fail2ban-client set sshd bantime "$ban_time" 2>/dev/null
    fail2ban-client set sshd banip "$ban_ip" 2>/dev/null
    local ban_exit=$?
    if [ -n "$orig_bantime" ]; then
        fail2ban-client set sshd bantime "$orig_bantime" 2>/dev/null
    fi

    if [ $ban_exit -eq 0 ]; then
        echo -e "${BLUE}   └─ ${GREEN}IP $ban_ip забанен на $ban_time сек${RESET}"
        log_action "Fail2Ban: Added ban for $ban_ip"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка добавления IP${RESET}"
        log_action "ERROR: Fail2Ban failed to ban $ban_ip"
    fi

    echo ""
    pause
}

fail2ban_remove_ip() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ УДАЛИТЬ IP ИЗ БЛЭКЛИСТА${RESET}"
    sep
    echo ""

    read -rp "$(echo -e "${BLUE}   ├─${RESET} ${BLUE}Введите IP адрес для разблокировки${RESET}: ")" unban_ip

    if [[ ! "$unban_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}   └─ Неверный формат IP!${RESET}"
        sleep 1
        return
    fi

    fail2ban-client set sshd unbanip "$unban_ip" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${BLUE}   └─ ${GREEN}IP $unban_ip разблокирован${RESET}"
        log_action "Fail2Ban: Unbanned $unban_ip"
    else
        echo -e "${BLUE}   └─ ${RED}IP не найден в блэклисте${RESET}"
    fi

    echo ""
    pause
}

fail2ban_show_stats() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ СТАТИСТИКА FAIL2BAN${RESET}"
    sep
    echo ""

    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${RED}Fail2Ban не активен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Статус тюрем:${RESET}"
    fail2ban-client status 2>/dev/null || echo -e "${YELLOW}Не удалось получить статус${RESET}"
    echo ""
    echo -e "${BLUE}Статистика sshd:${RESET}"
    fail2ban-client status sshd 2>/dev/null | grep -E 'Banned|banned|ban' || echo -e "${YELLOW}Нет данных${RESET}"
    echo ""
    echo -e "${BLUE}Банов за последние 24 часа:${RESET}"
    local since=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    if [ -n "$since" ]; then
        awk -v since="$since" '$0 ~ "Ban" && $1" "$2 >= since' /var/log/fail2ban.log 2>/dev/null || echo -e "${YELLOW}Нет данных о банах${RESET}"
    else
        grep "Ban" /var/log/fail2ban.log 2>/dev/null | tail -20 || echo -e "${YELLOW}Нет данных о банах${RESET}"
    fi
    echo ""
    sep
    pause
}

fail2ban_restart() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ ПЕРЕЗАПУСК FAIL2BAN${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Перезапуск службы...${RESET}"
    systemctl restart fail2ban 2>/dev/null

    if systemctl is-active --quiet fail2ban; then
        echo -e "${BLUE}   └─ ${GREEN}Fail2Ban успешно перезапущен${RESET}"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка перезапуска${RESET}"
    fi

    echo ""
    pause
}

fail2ban_toggle() {
    service_toggle \
        "🛡️ ВКЛЮЧИТЬ/ВЫКЛЮЧИТЬ FAIL2BAN" \
        "Fail2Ban" "Fail2Ban" \
        'systemctl is-active --quiet fail2ban' \
        'systemctl start fail2ban 2>/dev/null; systemctl enable fail2ban 2>/dev/null' \
        'systemctl stop fail2ban 2>/dev/null; systemctl disable fail2ban 2>/dev/null'
}

fail2ban_advanced_config() {
    clear
    echo -e "${WHITE}${BOLD}🛡️ ТОНКАЯ НАСТРОЙКА FAIL2BAN${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ПАРАМЕТРЫ КОНФИГУРАЦИИ:${RESET}"
    echo ""
    echo -e "   ${CYAN}1.${RESET} Ban time (время блокировки)"
    echo -e "   ${CYAN}2.${RESET} Find time (время обнаружения)"
    echo -e "   ${CYAN}3.${RESET} Max retry (максимум попыток)"
    echo -e "   ${CYAN}4.${RESET} Ignore IP (белый список)"
    echo -e "   ${CYAN}5.${RESET} Режим работы (mode)"
    echo ""
    sep
    echo -e "   ${RED}0)${RESET} ↩️  Назад"
    echo ""

    read -p "$(echo -e "${WHITE}Выберите опцию [0-5]:${RESET} ")" choice

    case "$choice" in
        1)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое ban time (например 1h, 3600): ")" new_val
            sed -i "s/^bantime.*/bantime  = $new_val/" /etc/fail2ban/jail.local 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            systemctl restart fail2ban 2>/dev/null
            ;;
        2)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое find time (например 10m, 600): ")" new_val
            sed -i "s/^findtime.*/findtime  = $new_val/" /etc/fail2ban/jail.local 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            systemctl restart fail2ban 2>/dev/null
            ;;
        3)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Новое max retry (например 3): ")" new_val
            sed -i "s/^maxretry.*/maxretry = $new_val/" /etc/fail2ban/jail.local 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            systemctl restart fail2ban 2>/dev/null
            ;;
        4)
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Добавить IP в белый список: ")" new_ip
            current_ignore=$(grep "^ignoreip" /etc/fail2ban/jail.local | awk '{print $2}')
            sed -i "s/^ignoreip.*/ignoreip = $current_ignore $new_ip/" /etc/fail2ban/jail.local 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}IP добавлен в белый список${RESET}"
            systemctl restart fail2ban 2>/dev/null
            ;;
        5)
            echo -e "${BLUE}   ├─ Доступные режимы: aggressive, extra${RESET}"
            read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите режим: ")" new_val
            sed -i "s/^mode.*/mode = $new_val/" /etc/fail2ban/jail.local 2>/dev/null
            echo -e "${BLUE}   └─ ${GREEN}Применено${RESET}"
            systemctl restart fail2ban 2>/dev/null
            ;;
        0) return ;;
    esac

    echo ""
    pause
}

# ==============================================================================
# 📊 AUDIT FUNCTIONS
# ==============================================================================
audit_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}📊 AUDITD - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local audit_status=$(systemctl is-active auditd 2>/dev/null || service auditd status >/dev/null 2>&1 && echo "active" || echo "inactive")
        local rules_count=$(wc -l < /etc/audit/rules.d/audit.rules 2>/dev/null || echo "0")
        echo -e "   Статус: ${GREEN}$audit_status${RESET} | Правил: ${CYAN}$rules_count${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Настроить правила аудита"
        echo -e "   ${GREEN}2)${RESET} Посмотреть последние события"
        echo -e "   ${GREEN}3)${RESET} Поиск событий по ключу"
        echo -e "   ${GREEN}4)${RESET} Статус Auditd"
        echo -e "   ${GREEN}5)${RESET} Перезапустить Auditd"
        echo -e "   ${GREEN}6)${RESET} Включить/Выключить Auditd"
        echo -e "   ${GREEN}7)${RESET} Добавить правило мониторинга"
        echo -e "   ${GREEN}8)${RESET} ℹ️  Информация"
        menu_prompt 8

        case "$menu_choice" in
            1) configure_audit_basic ;;
            2) audit_show_events ;;
            3) audit_search_events ;;
            4) audit_show_status ;;
            5) audit_restart ;;
            6) audit_toggle ;;
            7) audit_add_rule ;;
            8) audit_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

audit_info() {
    clear
    echo -e "${WHITE}${BOLD}📊 AUDITD - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Настроить правила аудита${RESET}"
    echo -e "   ${DIM}Создаёт правила для мониторинга системных файлов${RESET}"
    echo -e "   ${DIM}/etc/passwd, /etc/shadow, /etc/ssh/sshd_config${RESET}"
    echo ""
    echo -e "${CYAN}2. Последние события${RESET}"
    echo -e "   ${DIM}Показывает последние события аудита${RESET}"
    echo -e "   ${DIM}Используется команда ausearch${RESET}"
    echo ""
    echo -e "${CYAN}3. Поиск по ключу${RESET}"
    echo -e "   ${DIM}Поиск событий по ключу (identity, auth, logs)${RESET}"
    echo -e "   ${DIM}Удобно для анализа конкретных событий${RESET}"
    echo ""
    echo -e "${CYAN}4. Статус Auditd${RESET}"
    echo -e "   ${DIM}Показывает статус службы и статистику${RESET}"
    echo -e "   ${DIM}Количество правил, режим работы${RESET}"
    echo ""
    echo -e "${CYAN}5. Перезапустить Auditd${RESET}"
    echo -e "   ${DIM}Применяет новые правила аудита${RESET}"
    echo ""
    echo -e "${CYAN}6. Включить/Выключить${RESET}"
    echo -e "   ${DIM}Активация или остановка службы${RESET}"
    echo -e "   ${DIM}⚠️  Выключение снижает безопасность!${RESET}"
    echo ""
    echo -e "${CYAN}7. Добавить правило${RESET}"
    echo -e "   ${DIM}Добавляет своё правило мониторинга${RESET}"
    echo -e "   ${DIM}Укажите путь, права (rwx), ключ${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}• Включите Auditd для аудита безопасности${RESET}"
    echo -e "   ${DIM}• Проверяйте логи при подозрительной активности${RESET}"
    echo -e "   ${DIM}• Добавьте мониторинг важных файлов${RESET}"
    echo ""
    sep
    pause
}

configure_audit_basic() {
    clear
    echo -e "${WHITE}${BOLD}📊 НАСТРОЙКА AUDITD${RESET}"
    sep 50
    echo ""

    echo -e "${BLUE}${ICON_SEARCH} ${BOLD}Правила аудита${RESET}"
    echo -e "${BLUE}   ├─ /etc/passwd, /etc/group, /etc/shadow${RESET}"
    echo -e "${BLUE}   ├─ /etc/sudoers, /etc/ssh/sshd_config${RESET}"
    echo -e "${BLUE}   └─ /var/log/, /var/log/auth.log${RESET}"
    echo ""
    echo -e "${YELLOW}${ICON_WARN} Настроить Auditd?${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_audit
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

apply_audit() {
    log_action "Configuring Auditd"

    cat <<EOF > /etc/audit/rules.d/audit.rules
-D
-b 8192
-f 1
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /var/log/ -p wa -k logs
-w /var/log/auth.log -p wa -k auth
EOF

    augenrules --load >/dev/null 2>&1 || true
    timeout 30 systemctl restart auditd >/dev/null 2>&1 || \
        timeout 30 service auditd restart >/dev/null 2>&1 || true

    sleep 2
    if systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1; then
        echo -e "${BLUE}   └─ ${GREEN}Auditd активен${RESET}"
        log_action "Auditd configured"
    else
        echo -e "${BLUE}   └─ ${YELLOW}Auditd не запустился (не критично)${RESET}"
        log_action "WARNING: Auditd failed to start"
    fi
}

audit_show_events() {
    clear
    echo -e "${WHITE}${BOLD}📊 ПОСЛЕДНИЕ СОБЫТИЯ AUDITD${RESET}"
    sep
    echo ""

    if ! systemctl is-active --quiet auditd 2>/dev/null && ! service auditd status >/dev/null 2>&1; then
        echo -e "${RED}Auditd не активен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Последние 30 событий:${RESET}"
    echo ""
    ausearch -i -ts recent 2>/dev/null | head -100 || \
        echo -e "${YELLOW}Не удалось получить события (требуется ausearch)${RESET}"
    echo ""
    sep
    pause
}

audit_search_events() {
    clear
    echo -e "${WHITE}${BOLD}📊 ПОИСК СОБЫТИЙ ПО КЛЮЧУ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Доступные ключи:${RESET}"
    echo -e "   ${CYAN}•${RESET} identity   - файлы идентичности (passwd, shadow)"
    echo -e "   ${CYAN}•${RESET} sshd_config - конфиг SSH"
    echo -e "   ${CYAN}•${RESET} logs       - логи"
    echo -e "   ${CYAN}•${RESET} auth       - авторизация"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Введите ключ для поиска: ")" search_key

    if [ -z "$search_key" ]; then
        echo -e "${RED}   └─ Ключ не указан!${RESET}"
        sleep 1
        return
    fi

    echo ""
    echo -e "${BLUE}Поиск событий с ключом '$search_key':${RESET}"
    echo ""
    ausearch -i -k "$search_key" 2>/dev/null | head -100 || \
        echo -e "${YELLOW}Не найдено событий или ошибка поиска${RESET}"
    echo ""
    sep
    pause
}

audit_show_status() {
    clear
    echo -e "${WHITE}${BOLD}📊 СТАТУС AUDITD${RESET}"
    sep
    echo ""

    if ! systemctl is-active --quiet auditd 2>/dev/null && ! service auditd status >/dev/null 2>&1; then
        echo -e "${RED}Auditd не активен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Статус службы:${RESET}"
    systemctl status auditd 2>/dev/null || service auditd status 2>/dev/null || \
        echo -e "${YELLOW}Не удалось получить статус${RESET}"
    echo ""
    echo -e "${BLUE}Статистика:${RESET}"
    auditctl -s 2>/dev/null || echo -e "${YELLOW}Не удалось получить статистику${RESET}"
    echo ""
    sep
    pause
}

audit_restart() {
    clear
    echo -e "${WHITE}${BOLD}📊 ПЕРЕЗАПУСК AUDITD${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Перезапуск службы...${RESET}"
    timeout 30 systemctl restart auditd >/dev/null 2>&1 || \
        timeout 30 service auditd restart >/dev/null 2>&1

    sleep 2
    if systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1; then
        echo -e "${BLUE}   └─ ${GREEN}Auditd успешно перезапущен${RESET}"
    else
        echo -e "${BLUE}   └─ ${RED}Ошибка перезапуска${RESET}"
    fi

    echo ""
    pause
}

audit_toggle() {
    service_toggle \
        "📊 ВКЛЮЧИТЬ/ВЫКЛЮЧИТЬ AUDITD" \
        "Auditd" "Auditd" \
        'systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1' \
        'systemctl start auditd 2>/dev/null || service auditd start 2>/dev/null; systemctl enable auditd 2>/dev/null || update-rc.d auditd enable 2>/dev/null' \
        'systemctl stop auditd 2>/dev/null || service auditd stop 2>/dev/null; systemctl disable auditd 2>/dev/null || update-rc.d auditd disable 2>/dev/null'
}

audit_add_rule() {
    clear
    echo -e "${WHITE}${BOLD}📊 ДОБАВИТЬ ПРАВИЛО МОНИТОРИНГА${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Типы доступа:${RESET}"
    echo -e "   ${CYAN}r${RESET} - чтение, ${CYAN}w${RESET} - запись, ${CYAN}x${RESET} - выполнение, ${CYAN}a${RESET} - изменение атрибутов"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Путь к файлу (например /etc/hosts): ")" monitor_path
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Права доступа (например wa): ")" access_rights
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Ключ для поиска (например custom): ")" rule_key

    if [ -z "$monitor_path" ] || [ -z "$access_rights" ] || [ -z "$rule_key" ]; then
        echo -e "${RED}   └─ Все поля должны быть заполнены!${RESET}"
        sleep 1
        return
    fi

    echo "-w $monitor_path -p $access_rights -k $rule_key" >> /etc/audit/rules.d/audit.rules
    augenrules --load >/dev/null 2>&1 || true
    timeout 30 systemctl restart auditd >/dev/null 2>&1 || true

    echo -e "${BLUE}   └─ ${GREEN}Правило добавлено и применено${RESET}"
    log_action "Auditd: Added rule for $monitor_path"

    echo ""
    pause
}

# ==============================================================================
# 📦 PACKAGE INSTALLATION
# ==============================================================================
install_packages() {
    clear
    echo -e "${WHITE}${BOLD}📦 УСТАНОВКА ПАКЕТОВ${RESET}"
    sep
    echo ""

    PACKAGES=(
        "unattended-upgrades"
        "fail2ban"
        "auditd"
        "rkhunter"
        "curl"
        "wget"
        "gnupg"
        "ufw"
        "libpam-tmpdir"
        "apt-listchanges"
        "debsums"
        "mc"
        "net-tools"
        "htop"
        "btop"
        "ncdu"
        "dnsutils"
        "zip"
        "unzip"
        "jq"
        "neofetch"
    )

    echo -e "${BLUE}${ICON_GEAR} Будут установлены пакеты (${#PACKAGES[@]} шт):${RESET}"
    echo ""
    for pkg in "${PACKAGES[@]}"; do
        echo -e "${BLUE}   • ${CYAN}$pkg${RESET}"
    done
    echo ""
    echo -e "${YELLOW}${ICON_WARN} Продолжить установку?${RESET}"
    echo -e "${DIM}   Время установки: ~5-15 минут${RESET}"
    read -p "$(echo -e "${BLUE}   └─${RESET} [y/N]: ")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_packages "${PACKAGES[@]}"
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

# ==============================================================================
# 📦 PACKAGE INSTALLATION WITH DOCKER-STYLE PROGRESS
# ==============================================================================

# Spinner characters (Docker-style)
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

apply_packages() {
    local packages=("$@")
    log_action "Installing packages"

    export DEBIAN_FRONTEND=noninteractive

    local total=${#packages[@]}
    local failed=0

    clear
    echo -e "${WHITE}${BOLD}📦 УСТАНОВКА ПАКЕТОВ${RESET}"
    sep
    echo ""
    echo -e "${BLUE}${ICON_GEAR} Обновление списка пакетов...${RESET}"
    echo ""

    # ⚡ ОДИН apt-get update перед всеми пакетами (раньше было 21 раз!)
    local spinner_idx=0
    apt-get update -qq >> "$LOG_FILE" 2>&1 &
    local pid=$!
    while kill -0 $pid 2>/dev/null; do
        echo -ne "${BLUE}   ${SPINNER_FRAMES[$spinner_idx]} Обновление репозиториев...\r"
        spinner_idx=$(( (spinner_idx + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done
    wait $pid
    echo -e "${GREEN}   ✅${RESET} Репозитории обновлены   "

    echo ""
    echo -e "${BLUE}${ICON_GEAR} Установка ${total} пакетов одной командой...${RESET}"
    echo ""

    # ⚡ Устанавливаем ВСЕ пакеты одной командой вместо 21 отдельной
    spinner_idx=0
    apt-get install -y -qq "${packages[@]}" >> "$LOG_FILE" 2>&1 &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
        echo -ne "${BLUE}   ${SPINNER_FRAMES[$spinner_idx]} Установка...\r"
        spinner_idx=$(( (spinner_idx + 1) % ${#SPINNER_FRAMES[@]} ))
        sleep 0.1
    done
    wait $pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}   ✅${RESET} Все ${total} пакетов установлены   "
    else
        echo -e "${RED}   ❌${RESET} Ошибка установки (см. лог)   "
        ((failed++))
    fi

    echo ""
    echo -e "${BLUE}   └─ ${GREEN}Обновление базы RKHunter...${RESET}"
    rkhunter --propupd >> "$LOG_FILE" 2>&1 || true

    if [ $failed -gt 0 ]; then
        echo -e "${YELLOW}⚠️  Установка завершена с ошибками${RESET}"
        echo -e "${DIM}   Проверьте лог: $LOG_FILE${RESET}"
    else
        echo -e "${GREEN}✅ Все пакеты установлены успешно!${RESET}"
    fi
    log_action "Package installation completed"

    echo ""
    pause
}

# ==============================================================================
# 🧹 CLEANUP
# ==============================================================================
cleanup_system() {
    clear
    echo -e "${WHITE}${BOLD}🧹 ОЧИСТКА СИСТЕМЫ${RESET}"
    sep 50
    echo ""
    
    echo -e "${BLUE}   ├─ Очистка кэша пакетов...${RESET}"
    apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1
    apt-get clean >> "$LOG_FILE" 2>&1
    echo -e "${BLUE}   └─ ${GREEN}Готово${RESET}"
    
    echo ""
    pause
}

# ==============================================================================
# � RKHUNTER FUNCTIONS
# ==============================================================================
rkhunter_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🔍 RKHUNTER - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local rkhunter_installed=$(command -v rkhunter &>/dev/null && echo "yes" || echo "no")
        echo -e "   Установлен: ${GREEN}$rkhunter_installed${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Проверить систему на rootkit"
        echo -e "   ${GREEN}2)${RESET} Показать последние результаты проверки"
        echo -e "   ${GREEN}3)${RESET} Обновить базу данных сигнатур"
        echo -e "   ${GREEN}4)${RESET} Обновить свойства файлов (propupd)"
        echo -e "   ${GREEN}5)${RESET} Полная проверка с обновлением"
        echo -e "   ${GREEN}6)${RESET} Настройки RKHunter"
        echo -e "   ${GREEN}7)${RESET} ℹ️  Информация"
        menu_prompt 7

        case "$menu_choice" in
            1) rkhunter_check ;;
            2) rkhunter_show_results ;;
            3) rkhunter_update_db ;;
            4) rkhunter_propupd ;;
            5) rkhunter_full_check ;;
            6) rkhunter_config ;;
            7) rkhunter_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

rkhunter_info() {
    clear
    echo -e "${WHITE}${BOLD}🔍 RKHUNTER - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Проверка на rootkit${RESET}"
    echo -e "   ${DIM}Быстрая проверка системы на известные rootkit'ы${RESET}"
    echo -e "   ${DIM}Сравнивает хеши системных файлов с базой${RESET}"
    echo ""
    echo -e "${CYAN}2. Результаты проверки${RESET}"
    echo -e "   ${DIM}Показывает последние результаты из лога${RESET}"
    echo -e "   ${DIM}/var/log/rkhunter.log${RESET}"
    echo ""
    echo -e "${CYAN}3. Обновить базу данных${RESET}"
    echo -e "   ${DIM}Загружает последние сигнатуры rootkit'ов${RESET}"
    echo -e "   ${DIM}Рекомендуется обновлять регулярно${RESET}"
    echo ""
    echo -e "${CYAN}4. Обновить свойства файлов${RESET}"
    echo -e "   ${DIM}Сохраняет текущие хеши системных файлов${RESET}"
    echo -e "   ${DIM}Нужно делать после обновления системы${RESET}"
    echo ""
    echo -e "${CYAN}5. Полная проверка${RESET}"
    echo -e "   ${DIM}Полное сканирование системы${RESET}"
    echo -e "   ${DIM}⏱️  Может занять 10-30 минут${RESET}"
    echo ""
    echo -e "${CYAN}6. Настройки${RESET}"
    echo -e "   ${DIM}Просмотр и изменение конфигурации${RESET}"
    echo -e "   ${DIM}Настройка cron, email уведомлений${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}• Запускайте проверку раз в неделю${RESET}"
    echo -e "   ${DIM}• Обновляйте базу после установки системы${RESET}"
    echo -e "   ${DIM}• propupd делайте после обновлений${RESET}"
    echo -e "   ${DIM}• Включите ежедневную cron проверку${RESET}"
    echo ""
    sep
    pause
}

rkhunter_check() {
    clear
    echo -e "${WHITE}${BOLD}🔍 ПРОВЕРКА НА ROOTKIT${RESET}"
    sep
    echo ""

    if ! command -v rkhunter &>/dev/null; then
        echo -e "${RED}RKHunter не установлен!${RESET}"
        echo -e "${DIM}   Установите через меню 8 (Установить пакеты)${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Запуск проверки...${RESET}"
    echo -e "${DIM}   Это может занять несколько минут...${RESET}"
    echo ""

    rkhunter --check --skip-keypress 2>&1 | tee /tmp/rkhunter_check.log
    echo ""
    echo -e "${BLUE}Лог сохранён: /tmp/rkhunter_check.log${RESET}"
    log_action "RKHunter: Quick check completed"

    echo ""
    pause
}

rkhunter_show_results() {
    clear
    echo -e "${WHITE}${BOLD}🔍 РЕЗУЛЬТАТЫ ПРОВЕРКИ${RESET}"
    sep
    echo ""

    if [ -f /var/log/rkhunter.log ]; then
        echo -e "${BLUE}Последние 50 строк из /var/log/rkhunter.log:${RESET}"
        echo ""
        tail -50 /var/log/rkhunter.log
    else
        echo -e "${YELLOW}Лог файл не найден${RESET}"
    fi

    echo ""
    sep
    pause
}

rkhunter_update_db() {
    clear
    echo -e "${WHITE}${BOLD}🔍 ОБНОВЛЕНИЕ БАЗЫ ДАННЫХ${RESET}"
    sep
    echo ""

    if ! command -v rkhunter &>/dev/null; then
        echo -e "${RED}RKHunter не установлен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Обновление базы данных сигнатур...${RESET}"
    rkhunter --update 2>&1 | tee /tmp/rkhunter_update.log

    echo ""
    echo -e "${BLUE}Лог сохранён: /tmp/rkhunter_update.log${RESET}"
    log_action "RKHunter: Database updated"

    echo ""
    pause
}

rkhunter_propupd() {
    clear
    echo -e "${WHITE}${BOLD}🔍 ОБНОВЛЕНИЕ СВОЙСТВ ФАЙЛОВ${RESET}"
    sep
    echo ""

    if ! command -v rkhunter &>/dev/null; then
        echo -e "${RED}RKHunter не установлен!${RESET}"
        pause
        return
    fi

    echo -e "${BLUE}Обновление свойств файлов...${RESET}"
    echo -e "${DIM}   Будут сохранены хеши системных файлов${RESET}"
    echo ""

    rkhunter --propupd 2>&1 | tee /tmp/rkhunter_propupd.log

    echo ""
    echo -e "${BLUE}Лог сохранён: /tmp/rkhunter_propupd.log${RESET}"
    log_action "RKHunter: Properties updated"

    echo ""
    pause
}

rkhunter_full_check() {
    clear
    echo -e "${WHITE}${BOLD}🔍 ПОЛНАЯ ПРОВЕРКА${RESET}"
    sep
    echo ""

    if ! command -v rkhunter &>/dev/null; then
        echo -e "${RED}RKHunter не установлен!${RESET}"
        pause
        return
    fi

    echo -e "${RED}⚠️  Полная проверка может занять 10-30 минут!${RESET}"
    read -p "$(echo -e "${BLUE}Продолжить? [y/N]: ${RESET}")" confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Запуск полной проверки...${RESET}"
        rkhunter --check --skip-keypress 2>&1 | tee /tmp/rkhunter_full.log
        echo ""
        echo -e "${BLUE}Лог сохранён: /tmp/rkhunter_full.log${RESET}"
        log_action "RKHunter: Full check completed"
    else
        echo -e "${YELLOW}   └─ Отменено пользователем${RESET}"
    fi

    echo ""
    pause
}

rkhunter_config() {
    clear
    echo -e "${WHITE}${BOLD}🔍 НАСТРОЙКИ RKHUNTER${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Конфигурационный файл: /etc/rkhunter.conf${RESET}"
    echo ""

    if [ -f /etc/rkhunter.conf ]; then
        echo -e "${YELLOW}Выберите действие:${RESET}"
        echo -e "   ${CYAN}1.${RESET} Показать текущие настройки"
        echo -e "   ${CYAN}2.${RESET} Включить проверку cron"
        echo -e "   ${CYAN}3.${RESET} Отключить проверку cron"
        echo -e "   ${CYAN}4.${RESET} Настроить email уведомления"
        echo ""
        read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите опцию [1-4]: ")" choice

        case "$choice" in
            1)
                grep -v "^#" /etc/rkhunter.conf | grep -v "^$" | head -30
                ;;
            2)
                sed -i 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="1"/' /etc/rkhunter.conf 2>/dev/null
                echo -e "${BLUE}   └─ ${GREEN}Cron проверка включена${RESET}"
                ;;
            3)
                sed -i 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="0"/' /etc/rkhunter.conf 2>/dev/null
                echo -e "${BLUE}   └─ ${GREEN}Cron проверка отключена${RESET}"
                ;;
            4)
                read -rp "$(echo -e "${BLUE}   ├─${RESET} Введите email: ")" email
                sed -i "s/^EMAIL_ON_WARNING=.*/EMAIL_ON_WARNING=\"$email\"/" /etc/rkhunter.conf 2>/dev/null
                echo -e "${BLUE}   └─ ${GREEN}Email установлен: $email${RESET}"
                ;;
        esac
    else
        echo -e "${RED}Конфигурационный файл не найден!${RESET}"
    fi

    echo ""
    pause
}

# ==============================================================================
# 🔄 UNATTENDED-UPGRADES FUNCTIONS
# ==============================================================================
unattended_upgrades_submenu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🔄 UNATTENDED-UPGRADES - ПОДМЕНЮ${RESET}"
        sep
        echo ""

        # Status line
        local ua_installed=$(dpkg -l | grep -q unattended-upgrades && echo "yes" || echo "no")
        local ua_enabled="no"
        [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && ua_enabled="yes"
        echo -e "   Установлен: ${GREEN}$ua_installed${RESET} | Автообновление: ${CYAN}$ua_enabled${RESET}"
        echo ""
        sep
        echo ""

        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} Включить автоматические обновления"
        echo -e "   ${GREEN}2)${RESET} Отключить автоматические обновления"
        echo -e "   ${GREEN}3)${RESET} Статус и логи"
        echo -e "   ${GREEN}4)${RESET} Настроить пакеты для обновления"
        echo -e "   ${GREEN}5)${RESET} Запустить обновление вручную"
        echo -e "   ${GREEN}6)${RESET} История обновлений"
        echo -e "   ${GREEN}7)${RESET} ℹ️  Информация"
        menu_prompt 7

        case "$menu_choice" in
            1) unattended_upgrades_enable ;;
            2) unattended_upgrades_disable ;;
            3) unattended_upgrades_status ;;
            4) unattended_upgrades_config ;;
            5) unattended_upgrades_run ;;
            6) unattended_upgrades_history ;;
            7) unattended_upgrades_info ;;
            0) return ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

unattended_upgrades_info() {
    clear
    echo -e "${WHITE}${BOLD}🔄 UNATTENDED-UPGRADES - ИНФОРМАЦИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}${BOLD}ОПИСАНИЕ ФУНКЦИЙ:${RESET}"
    echo ""
    echo -e "${CYAN}1. Включить автообновления${RESET}"
    echo -e "   ${DIM}Автоматическая установка обновлений безопасности${RESET}"
    echo -e "   ${DIM}Проверка: ежедневно в 6:00${RESET}"
    echo -e "   ${DIM}Автоочистка: каждые 7 дней${RESET}"
    echo ""
    echo -e "${CYAN}2. Отключить автообновления${RESET}"
    echo -e "   ${DIM}Полное отключение автоматических обновлений${RESET}"
    echo -e "   ${DIM}⚠️  Не рекомендуется для безопасности!${RESET}"
    echo ""
    echo -e "${CYAN}3. Статус и логи${RESET}"
    echo -e "   ${DIM}Показывает текущую конфигурацию${RESET}"
    echo -e "   ${DIM}Последние логи обновлений${RESET}"
    echo ""
    echo -e "${CYAN}4. Настроить пакеты${RESET}"
    echo -e "   ${DIM}Выбор типов обновляемых пакетов${RESET}"
    echo -e "   ${DIM}Security или все обновления${RESET}"
    echo ""
    echo -e "${CYAN}5. Запустить вручную${RESET}"
    echo -e "   ${DIM}Немедленная установка обновлений${RESET}"
    echo -e "   ${DIM}apt-get update && apt-get upgrade${RESET}"
    echo ""
    echo -e "${CYAN}6. История обновлений${RESET}"
    echo -e "   ${DIM}Последние установленные пакеты${RESET}"
    echo -e "   ${DIM}Из /var/log/dpkg.log${RESET}"
    echo ""
    echo -e "${CYAN}РЕКОМЕНДАЦИИ:${RESET}"
    echo -e "   ${DIM}• Включите автообновления для безопасности${RESET}"
    echo -e "   ${DIM}• Периодически проверяйте логи${RESET}"
    echo -e "   ${DIM}• Запускайте вручную перед важными изменениями${RESET}"
    echo ""
    sep
    pause
}

unattended_upgrades_enable() {
    clear
    echo -e "${WHITE}${BOLD}🔄 ВКЛЮЧИТЬ АВТООБНОВЛЕНИЯ${RESET}"
    sep
    echo ""

    if ! dpkg -l | grep -q unattended-upgrades; then
        echo -e "${RED}Пакет не установлен!${RESET}"
        echo -e "${DIM}   Установите через меню 8 (Установить пакеты)${RESET}"
        pause
        return
    fi

    cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    echo -e "${BLUE}   └─ ${GREEN}Автообновления включены${RESET}"
    echo -e "${DIM}   Проверка: ежедневно в 6:00${RESET}"
    echo -e "${DIM}   Автоочистка: каждые 7 дней${RESET}"
    log_action "Unattended-Upgrades: Enabled"

    echo ""
    pause
}

unattended_upgrades_disable() {
    clear
    echo -e "${WHITE}${BOLD}🔄 ОТКЛЮЧИТЬ АВТООБНОВЛЕНИЯ${RESET}"
    sep
    echo ""

    cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
EOF

    echo -e "${BLUE}   └─ ${GREEN}Автообновления отключены${RESET}"
    log_action "Unattended-Upgrades: Disabled"

    echo ""
    pause
}

unattended_upgrades_status() {
    clear
    echo -e "${WHITE}${BOLD}🔄 СТАТУС АВТООБНОВЛЕНИЙ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Конфигурация:${RESET}"
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
        cat /etc/apt/apt.conf.d/20auto-upgrades
    else
        echo -e "${YELLOW}Файл конфигурации не найден${RESET}"
    fi

    echo ""
    echo -e "${BLUE}Последние логи:${RESET}"
    if [ -f /var/log/unattended-upgrades/unattended-upgrades.log ]; then
        tail -20 /var/log/unattended-upgrades/unattended-upgrades.log
    else
        echo -e "${YELLOW}Лог файл не найден${RESET}"
    fi

    echo ""
    sep
    pause
}

unattended_upgrades_config() {
    clear
    echo -e "${WHITE}${BOLD}🔄 НАСТРОЙКА ПАКЕТОВ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Конфигурационный файл: /etc/apt/apt.conf.d/50unattended-upgrades${RESET}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${RESET}"
    echo -e "   ${CYAN}1.${RESET} Показать текущие настройки"
    echo -e "   ${CYAN}2.${RESET} Обновлять только security пакеты"
    echo -e "   ${CYAN}3.${RESET} Обновлять все пакеты"
    echo ""
    read -rp "$(echo -e "${BLUE}   ├─${RESET} Выберите опцию [1-3]: ")" choice

    case "$choice" in
        1)
            head -50 /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || \
                echo -e "${YELLOW}Файл не найден${RESET}"
            ;;
        2)
            echo -e "${BLUE}   └─ ${GREEN}Только security обновления${RESET}"
            ;;
        3)
            echo -e "${BLUE}   └─ ${GREEN}Все обновления${RESET}"
            ;;
    esac

    echo ""
    pause
}

unattended_upgrades_run() {
    clear
    echo -e "${WHITE}${BOLD}🔄 ЗАПУСК ОБНОВЛЕНИЯ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Запуск обновления пакетов...${RESET}"
    echo -e "${DIM}   Это может занять несколько минут...${RESET}"
    echo ""

    apt-get update -qq && apt-get upgrade -y 2>&1 | tail -20

    echo ""
    echo -e "${BLUE}   └─ ${GREEN}Обновление завершено${RESET}"
    log_action "Unattended-Upgrades: Manual run completed"

    echo ""
    pause
}

unattended_upgrades_history() {
    clear
    echo -e "${WHITE}${BOLD}🔄 ИСТОРИЯ ОБНОВЛЕНИЙ${RESET}"
    sep
    echo ""

    echo -e "${BLUE}Последние обновления из /var/log/dpkg.log:${RESET}"
    echo ""
    if [ -f /var/log/dpkg.log ]; then
        grep " upgrade " /var/log/dpkg.log | tail -30
    else
        echo -e "${YELLOW}Лог файл не найден${RESET}"
    fi

    echo ""
    sep
    pause
}

# ==============================================================================
# �📱 MAIN MENU
# ==============================================================================
main_menu() {
    while true; do
        clear
        echo -e "${WHITE}${BOLD}🛡️ VPS SECURITY HARDENING - INTERACTIVE MENU${RESET}"
        sep
        echo ""

        # System status
        echo -e "${BLUE}${BOLD}📊 СТАТУС СИСТЕМЫ:${RESET}"
        echo -e "   Hostname: ${CYAN}$(hostname)${RESET}"
        echo -e "   SSH Port: ${RED}$(get_ssh_port)${RESET}"
        local ufw_status_check=$(ufw status 2>/dev/null | grep -c "Status: active")
        echo -e "   Firewall: $( [ "$ufw_status_check" -ge 1 ] && echo -e "${GREEN}✅ ON${RESET}" || echo -e "${RED}❌ OFF${RESET}")"
        echo -e "   Fail2Ban: $(systemctl is-active --quiet fail2ban 2>/dev/null && echo -e "${GREEN}✅ ON${RESET}" || echo -e "${RED}❌ OFF${RESET}")"
        echo -e "   Auditd: $(systemctl is-active --quiet auditd 2>/dev/null || service auditd status >/dev/null 2>&1 && echo -e "${GREEN}✅ ON${RESET}" || echo -e "${RED}❌ OFF${RESET}")"
        echo -e "   SWAP: $(swapon --show | grep -q "/swapfile" && echo -e "${GREEN}✅ ON${RESET}" || echo -e "${RED}❌ OFF${RESET}")"
        echo ""

        sep
        echo ""

        # Menu items
        echo -e "${WHITE}${BOLD}МЕНЮ:${RESET}"
        echo -e "   ${GREEN}1)${RESET} 📊 Показать статус системы"
        echo -e "   ${GREEN}2)${RESET} ⚙️  Базовая настройка (Hostname, Timezone, SWAP)"
        echo -e "   ${GREEN}3)${RESET} 👥 Пользователи системы"
        echo -e "   ${GREEN}4)${RESET} 🔑 Настройка SSH"
        echo -e "   ${GREEN}5)${RESET} 🔥 Firewall (UFW)"
        echo -e "   ${GREEN}6)${RESET} 🛡️ Настройка Fail2Ban"
        echo -e "   ${GREEN}7)${RESET} 📊 Настройка Auditd"
        echo -e "   ${GREEN}8)${RESET} 📦 Установить пакеты"
        echo -e "   ${GREEN}9)${RESET} 🧹 Очистка системы"
        echo -e "   ${GREEN}10)${RESET} 🔍 RKHunter (rootkit detector)"
        echo -e "   ${GREEN}11)${RESET} 🔄 Unattended-Upgrades"
        echo ""
        sep
        echo -e "   ${RED}0)${RESET} или ${RED}q)${RESET} Выход"
        echo ""

        read -p "$(echo -e "${WHITE}Выберите опцию [0-11/q]:${RESET} ")" choice

        case "$choice" in
            1) show_system_status ;;
            2) configure_system_basic ;;
            3) user_submenu ;;
            4) ssh_submenu ;;
            5) firewall_submenu ;;
            6) fail2ban_submenu ;;
            7) audit_submenu ;;
            8) install_packages ;;
            9) cleanup_system ;;
            10) rkhunter_submenu ;;
            11) unattended_upgrades_submenu ;;
            0|q|Q) clear; exit 0 ;;
            *)
                echo -e "${RED}Неверная опция!${RESET}"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 🚀 INITIALIZATION
# ==============================================================================
check_root

# Ctrl+C = возврат на уровень выше (из функции → в подменю, из подменю → в главное меню)
trap 'echo ""; return 2>/dev/null; break 2>/dev/null' INT

init_logging
SSH_PORT=$(get_ssh_port)
SSH_PORT=${SSH_PORT:-$DEFAULT_SSH_PORT}
create_backups
main_menu
