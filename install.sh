#!/bin/bash

# ============================================================
#  install.sh -- Homelab Manager Bootstrap Installer
#  Version: 1.0
#  Usage on fresh Ubuntu machine:
#    curl -fsSL https://raw.githubusercontent.com/mrhavzerone/homelab-manager/main/install.sh | bash
#  Or locally:
#    bash install.sh
# ============================================================

set -eo pipefail

HOMELAB_BIN="/usr/local/bin/homelab"
HOMELAB_SCRIPT_URL="https://raw.githubusercontent.com/mrhavzerone/homelab-manager/main/homelab.sh"
LOG_FILE="/var/log/homelab_manager.log"
CONFIG_FILE="$HOME/.homelab_manager.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
#  HELPERS
# ============================================================
step() { echo -e "\n${BOLD}${BLUE}[ $1 ]${NC} $2"; }
ok()   { echo -e "  ${GREEN}OK${NC} $1"; }
warn() { echo -e "  ${YELLOW}!!${NC} $1"; }
fail() { echo -e "  ${RED}ПОМИЛКА${NC} $1"; exit 1; }
ask()  { echo -ne "${CYAN}  $1${NC} "; }

# ============================================================
#  HEADER
# ============================================================
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║     Homelab Manager -- Bootstrap Installer   ║"
echo "  ║     Version 1.0                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Цей скрипт:"
echo -e "  ${CYAN}1.${NC} Перевiрить та встановить залежностi"
echo -e "  ${CYAN}2.${NC} Налаштує параметри пiд твою систему"
echo -e "  ${CYAN}3.${NC} Встановить homelab як системну команду"
echo -e "  ${CYAN}4.${NC} Налаштує автобекап (cron)"
echo -e "  ${CYAN}5.${NC} Вiдновить бекап (опцiонально)"
echo ""
echo -e "  ${YELLOW}Потрiбнi права sudo.${NC}"
echo ""
ask "Продовжити? [Enter]"
read -r

# ============================================================
#  STEP 1: SYSTEM CHECK
# ============================================================
step "1/6" "Перевiрка системи"

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "?")
ARCH=$(uname -m)
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
DISK_FREE=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')

echo -e "  ОС:         $OS $VER ($ARCH)"
echo -e "  RAM:        ${RAM_MB} MB"
echo -e "  Вiльно (/): ${DISK_FREE} GB"

[ "$RAM_MB" -lt 512 ] && warn "Мало RAM. Деякi сервiси можуть не запуститись."
[ "$DISK_FREE" -lt 5 ] && warn "Мало мiсця на диску."

ok "Перевiрка завершена"

# ============================================================
#  STEP 2: INSTALL DEPENDENCIES
# ============================================================
step "2/6" "Встановлення залежностей"

sudo apt-get update -qq

install_if_missing() {
    local pkg="$1"
    if ! command -v "$pkg" &>/dev/null && ! dpkg -l "$pkg" &>/dev/null; then
        echo -e "  ${YELLOW}Встановлюю $pkg...${NC}"
        sudo apt-get install -y "$pkg" -qq
        ok "$pkg встановлено"
    else
        ok "$pkg вже є"
    fi
}

install_if_missing curl
install_if_missing whiptail
install_if_missing rsync
install_if_missing tar

# Docker
if ! command -v docker &>/dev/null; then
    echo -e "  ${YELLOW}Встановлюю Docker...${NC}"
    curl -fsSL https://get.docker.com | sudo bash -s > /dev/null 2>&1
    sudo systemctl enable --now docker > /dev/null 2>&1
    ok "Docker встановлено"
else
    ok "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

# Docker Compose
if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
    echo -e "  ${YELLOW}Встановлюю Docker Compose plugin...${NC}"
    sudo apt-get install -y docker-compose-plugin -qq
    ok "Docker Compose встановлено"
else
    ok "Docker Compose є"
fi

# Додаємо поточного юзера до групи docker
if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    warn "Додано $USER до групи docker. Змiни пiсля перелогiнення."
fi

# ============================================================
#  STEP 3: CONFIGURATION WIZARD
# ============================================================
step "3/6" "Налаштування параметрiв"

echo ""

# Iм'я користувача
CURRENT_USER="${SUDO_USER:-${USER:-$(whoami)}}"
ask "Iм'я користувача сервера [$CURRENT_USER]: "
read -r INPUT_USER
HOMELAB_USER="${INPUT_USER:-$CURRENT_USER}"
HOMELAB_USER="${HOMELAB_USER:-$(whoami)}"
HOMELAB_HOME="/home/$HOMELAB_USER"

if [ ! -d "$HOMELAB_HOME" ]; then
    warn "Директорiя $HOMELAB_HOME не iснує. Буде створена при вiдновленнi."
fi

# Папка homelab
DEFAULT_SOURCE="$HOMELAB_HOME/homelab"
ask "Папка з сервiсами [$DEFAULT_SOURCE]: "
read -r INPUT_SOURCE
SOURCE_DIR="${INPUT_SOURCE:-$DEFAULT_SOURCE}"

# Папка бекапiв
DEFAULT_BACKUP="/mnt/backup/data_backups"
ask "Папка для бекапiв [$DEFAULT_BACKUP]: "
read -r INPUT_BACKUP
BACKUP_DIR="${INPUT_BACKUP:-$DEFAULT_BACKUP}"

# Кiлькiсть бекапiв
ask "Скiльки бекапiв зберiгати [10]: "
read -r INPUT_KEEP
KEEP_COUNT="${INPUT_KEEP:-10}"

# Docker мережа
ask "Назва Docker мережi [homelab_network]: "
read -r INPUT_NET
NETWORK_NAME="${INPUT_NET:-homelab_network}"

echo ""
echo -e "  ${BOLD}Пiдсумок налаштувань:${NC}"
echo -e "  Користувач:  ${GREEN}$HOMELAB_USER${NC}"
echo -e "  Homelab:     ${GREEN}$SOURCE_DIR${NC}"
echo -e "  Бекапи:      ${GREEN}$BACKUP_DIR${NC}"
echo -e "  Лiмiт:       ${GREEN}$KEEP_COUNT бекапiв${NC}"
echo -e "  Мережа:      ${GREEN}$NETWORK_NAME${NC}"
echo ""
ask "Все вiрно? [Enter = так, Ctrl+C = скасувати]: "
read -r

# Зберiгаємо конфiг
sudo mkdir -p "$(dirname "$LOG_FILE")"
sudo touch "$LOG_FILE"
sudo chmod 666 "$LOG_FILE"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true

cat > "$CONFIG_FILE" << EOF
# homelab_manager config ($(date '+%Y-%m-%d %H:%M'))
# Generated by install.sh
SOURCE_DIR="$SOURCE_DIR"
BACKUP_DIR="$BACKUP_DIR"
TARGET_DIR="$HOMELAB_HOME"
KEEP_COUNT="$KEEP_COUNT"
NETWORK_NAME="$NETWORK_NAME"
HOMELAB_USER="$HOMELAB_USER"
EOF

ok "Конфiг збережено: $CONFIG_FILE"

# ============================================================
#  STEP 4: INSTALL HOMELAB COMMAND
# ============================================================
step "4/6" "Встановлення команди homelab"

# Спочатку шукаємо локально (якщо install.sh i homelab.sh поруч)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/homelab.sh" ]; then
    echo -e "  ${CYAN}Знайдено локальний homelab.sh${NC}"
    sudo cp "$SCRIPT_DIR/homelab.sh" "$HOMELAB_BIN"
    ok "Скопiйовано з $SCRIPT_DIR/homelab.sh"
elif command -v curl &>/dev/null; then
    echo -e "  ${CYAN}Завантажую з GitHub...${NC}"
    if sudo curl -fsSL "$HOMELAB_SCRIPT_URL" -o "$HOMELAB_BIN" 2>/dev/null; then
        ok "Завантажено з GitHub"
    else
        warn "Не вдалося завантажити. Помiстiть homelab.sh поруч з install.sh i запустiть знову."
        fail "homelab.sh не знайдено"
    fi
else
    fail "curl не знайдено i локальний homelab.sh вiдсутнiй"
fi

sudo chmod +x "$HOMELAB_BIN"
ok "homelab встановлено як системну команду"

# Перевiрка синтаксису
bash -n "$HOMELAB_BIN" || fail "Помилка синтаксису в homelab.sh"

# ============================================================
#  STEP 5: CRON
# ============================================================
step "5/6" "Налаштування автобекапу"

echo ""
ask "Налаштувати автоматичний бекап о 3:00 щоночi? [Y/n]: "
read -r CRON_ANSWER

if [[ "${CRON_ANSWER,,}" != "n" ]]; then
    ask "О котрiй годинi робити бекап? [3]: "
    read -r CRON_HOUR
    CRON_HOUR="${CRON_HOUR:-3}"

    CRON_LINE="0 $CRON_HOUR * * * $HOMELAB_BIN --backup >> $LOG_FILE 2>&1"

    # Видаляємо старi записи homelab з crontab
    (crontab -l 2>/dev/null | grep -v "homelab" | grep -v "backup.sh" || true) | crontab -

    # Додаємо новий
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

    ok "Cron налаштовано: щодня о ${CRON_HOUR}:00"
    echo -e "  ${CYAN}$CRON_LINE${NC}"
else
    ok "Cron пропущено"
fi

# ============================================================
#  STEP 6: RESTORE (optional)
# ============================================================
step "6/6" "Вiдновлення бекапу"

echo ""
echo -e "  Варiанти:"
echo -e "  ${CYAN}1${NC} Вiдновити з локального диску/флешки"
echo -e "  ${CYAN}2${NC} Завантажити бекап по SSH з iншого сервера"
echo -e "  ${CYAN}3${NC} Пропустити (запустити homelab вручну пiзнiше)"
echo ""
ask "Вибiр [1/2/3]: "
read -r RESTORE_CHOICE

case "$RESTORE_CHOICE" in
    1)
        echo ""
        echo -e "  ${YELLOW}Доступнi диски:${NC}"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL | grep -v loop | sed 's/^/  /'
        echo ""
        ask "Шлях до папки з бекапами [$BACKUP_DIR]: "
        read -r INPUT_RESTORE_PATH
        RESTORE_PATH="${INPUT_RESTORE_PATH:-$BACKUP_DIR}"

        if [ ! -d "$RESTORE_PATH" ]; then
            warn "Папка не знайдена: $RESTORE_PATH"
            warn "Запусти homelab вручну: homelab"
        else
            # Знаходимо найновiший бекап
            LATEST=$(ls -t "$RESTORE_PATH"/homelab_backup_*.tar.gz 2>/dev/null | head -1)
            if [ -z "$LATEST" ]; then
                warn "Бекапiв не знайдено в $RESTORE_PATH"
            else
                echo ""
                echo -e "  ${BOLD}Доступнi бекапи:${NC}"
                COUNT=0
                while IFS= read -r f; do
                    COUNT=$((COUNT+1))
                    SIZE=$(du -sh "$f" | cut -f1)
                    DATE=$(stat -c '%y' "$f" | cut -d'.' -f1)
                    echo -e "  ${CYAN}[$COUNT]${NC} $(basename "$f")  |  $SIZE  |  $DATE"
                done < <(ls -t "$RESTORE_PATH"/homelab_backup_*.tar.gz 2>/dev/null)

                echo ""
                ask "Який вiдновити? [1 = найновiший]: "
                read -r RESTORE_NUM
                RESTORE_NUM="${RESTORE_NUM:-1}"

                SELECTED=$(ls -t "$RESTORE_PATH"/homelab_backup_*.tar.gz 2>/dev/null | sed -n "${RESTORE_NUM}p")

                if [ -z "$SELECTED" ]; then
                    warn "Не знайдено бекап #$RESTORE_NUM"
                else
                    echo -e "\n  ${YELLOW}Вiдновлення з: $(basename "$SELECTED")${NC}"
                    ask "Пiдтвердити? [y/N]: "
                    read -r CONFIRM
                    if [[ "${CONFIRM,,}" == "y" ]]; then
                        echo -e "  ${YELLOW}Розпаковую...${NC}"
                        sudo mkdir -p "$HOMELAB_HOME"
                        sudo tar -xzf "$SELECTED" -C "$HOMELAB_HOME" && ok "Розпаковано" || fail "Помилка розпакування"
                        sudo chown -R "$HOMELAB_USER:$HOMELAB_USER" "$HOMELAB_HOME/homelab"
                        sudo chown -R 33:33 "$HOMELAB_HOME/homelab/wp_"*/wp_data 2>/dev/null || true

                        # Мережа
                        docker network ls | grep -q "$NETWORK_NAME" || \
                            docker network create "$NETWORK_NAME" > /dev/null 2>&1 || true

                        # Запуск
                        echo -e "  ${YELLOW}Запуск сервiсiв...${NC}"
                        for d in "$HOMELAB_HOME/homelab"/*/; do
                            [ -f "${d}docker-compose.yml" ] || continue
                            svc=$(basename "$d")
                            echo -e "    ${CYAN}> $svc${NC}"
                            (cd "$d" && sudo docker compose up -d) >> "$LOG_FILE" 2>&1 || true
                        done
                        ok "Сервiси запущено"
                    fi
                fi
            fi
        fi
        ;;

    2)
        echo ""
        ask "SSH адреса старого сервера (user@host): "
        read -r SSH_HOST
        ask "Шлях до бекапiв на старому серверi [$BACKUP_DIR]: "
        read -r SSH_REMOTE_PATH
        SSH_REMOTE_PATH="${SSH_REMOTE_PATH:-$BACKUP_DIR}"

        echo -e "\n  ${YELLOW}Отримую список бекапiв з $SSH_HOST...${NC}"

        # Отримуємо список
        REMOTE_FILES=$(ssh "$SSH_HOST" "ls -t $SSH_REMOTE_PATH/homelab_backup_*.tar.gz 2>/dev/null" 2>/dev/null || true)

        if [ -z "$REMOTE_FILES" ]; then
            warn "Бекапiв не знайдено на $SSH_HOST:$SSH_REMOTE_PATH"
        else
            echo -e "  ${BOLD}Доступнi бекапи на $SSH_HOST:${NC}"
            COUNT=0
            while IFS= read -r f; do
                COUNT=$((COUNT+1))
                echo -e "  ${CYAN}[$COUNT]${NC} $(basename "$f")"
            done <<< "$REMOTE_FILES"

            echo ""
            ask "Який завантажити? [1 = найновiший]: "
            read -r SSH_NUM
            SSH_NUM="${SSH_NUM:-1}"

            SSH_SELECTED=$(echo "$REMOTE_FILES" | sed -n "${SSH_NUM}p")

            if [ -z "$SSH_SELECTED" ]; then
                warn "Не знайдено бекап #$SSH_NUM"
            else
                mkdir -p "$BACKUP_DIR"
                LOCAL_FILE="$BACKUP_DIR/$(basename "$SSH_SELECTED")"

                echo -e "  ${YELLOW}Завантажую $(basename "$SSH_SELECTED")...${NC}"
                echo -e "  ${CYAN}(rsync покаже прогрес)${NC}"
                rsync -avzP "$SSH_HOST:$SSH_SELECTED" "$LOCAL_FILE" || fail "Помилка rsync"
                ok "Завантажено: $LOCAL_FILE"

                ask "Вiдновити зараз? [y/N]: "
                read -r SSH_RESTORE
                if [[ "${SSH_RESTORE,,}" == "y" ]]; then
                    echo -e "  ${YELLOW}Розпаковую...${NC}"
                    sudo mkdir -p "$HOMELAB_HOME"
                    sudo tar -xzf "$LOCAL_FILE" -C "$HOMELAB_HOME" && ok "Розпаковано" || fail "Помилка розпакування"
                    sudo chown -R "$HOMELAB_USER:$HOMELAB_USER" "$HOMELAB_HOME/homelab"
                    sudo chown -R 33:33 "$HOMELAB_HOME/homelab/wp_"*/wp_data 2>/dev/null || true

                    docker network ls | grep -q "$NETWORK_NAME" || \
                        docker network create "$NETWORK_NAME" > /dev/null 2>&1 || true

                    echo -e "  ${YELLOW}Запуск сервiсiв...${NC}"
                    for d in "$HOMELAB_HOME/homelab"/*/; do
                        [ -f "${d}docker-compose.yml" ] || continue
                        svc=$(basename "$d")
                        echo -e "    ${CYAN}> $svc${NC}"
                        (cd "$d" && sudo docker compose up -d) >> "$LOG_FILE" 2>&1 || true
                    done
                    ok "Сервiси запущено"
                fi
            fi
        fi
        ;;

    *)
        ok "Пропущено. Запусти: homelab"
        ;;
esac

# ============================================================
#  DONE
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ВСТАНОВЛЕННЯ ЗАВЕРШЕНО!              ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Команди:${NC}"
echo -e "  ${CYAN}homelab${NC}           -- iнтерактивне меню"
echo -e "  ${CYAN}homelab --backup${NC}  -- запустити бекап зараз"
echo -e "  ${CYAN}homelab --status${NC}  -- статус контейнерiв"
echo -e "  ${CYAN}homelab --list${NC}    -- список бекапiв"
echo -e "  ${CYAN}homelab --help${NC}    -- довiдка"
echo ""
echo -e "  ${BOLD}Файли:${NC}"
echo -e "  Конфiг: ${CYAN}$CONFIG_FILE${NC}"
echo -e "  Лог:    ${CYAN}$LOG_FILE${NC}"
echo -e "  Cron:   ${CYAN}crontab -l${NC}"
echo ""

# Показуємо статус якщо вiдновлювали
if [[ "$RESTORE_CHOICE" == "1" || "$RESTORE_CHOICE" == "2" ]]; then
    echo -e "  ${BOLD}Статус контейнерiв:${NC}"
    sudo docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || true
    echo ""
fi
