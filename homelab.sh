#!/bin/bash

# ============================================================
#  homelab.sh -- Docker Homelab Manager
#  Version: 3.0
#  Author: havzerone
#  License: MIT
#  GitHub: https://github.com/mrhavzerone/homelab-manager
#
#  Usage:
#    homelab              -- interactive menu
#    homelab --backup     -- silent backup (for cron)
#    homelab --status     -- print container status and exit
#    homelab --list       -- list backups and exit
#    homelab --help       -- show this help
# ============================================================

set -euo pipefail
export COMPOSE_HTTP_TIMEOUT=300

# ============================================================
#  CONFIG
# ============================================================
CONFIG_FILE="$HOME/.homelab_manager.conf"

DEFAULT_SOURCE_DIR="/home/$(logname 2>/dev/null || echo $USER)/homelab"
DEFAULT_BACKUP_DIR="/mnt/backup/data_backups"
DEFAULT_TARGET_DIR="/home/$(logname 2>/dev/null || echo $USER)"
DEFAULT_KEEP_COUNT=10
DEFAULT_NETWORK_NAME="homelab_network"
LOG_FILE="/var/log/homelab_manager.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
#  LOAD / SAVE CONFIG
# ============================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    SOURCE_DIR="${SOURCE_DIR:-$DEFAULT_SOURCE_DIR}"
    BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
    TARGET_DIR="${TARGET_DIR:-$DEFAULT_TARGET_DIR}"
    KEEP_COUNT="${KEEP_COUNT:-$DEFAULT_KEEP_COUNT}"
    NETWORK_NAME="${NETWORK_NAME:-$DEFAULT_NETWORK_NAME}"
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
# homelab_manager config ($(date '+%Y-%m-%d %H:%M'))
SOURCE_DIR="$SOURCE_DIR"
BACKUP_DIR="$BACKUP_DIR"
TARGET_DIR="$TARGET_DIR"
KEEP_COUNT="$KEEP_COUNT"
NETWORK_NAME="$NETWORK_NAME"
EOF
}

# ============================================================
#  HELPERS
# ============================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | sudo tee -a "$LOG_FILE" > /dev/null 2>&1 || true
    echo "$msg"
}

log_only() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | sudo tee -a "$LOG_FILE" > /dev/null 2>&1 || true
}

check_deps() {
    local missing=()
    command -v docker   &>/dev/null || missing+=("docker")
    command -v tar      &>/dev/null || missing+=("tar")
    command -v whiptail &>/dev/null || {
        sudo apt-get install -y whiptail > /dev/null 2>&1 || true
    }
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Не знайдено: ${missing[*]}${NC}"
        echo "Встановiть їх i запустiть знову."
        exit 1
    fi
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif docker-compose version >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

list_mounted_disks() {
    echo -e "\n${BOLD}${BLUE}  Пiдключенi диски:${NC}"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL 2>/dev/null | grep -v "loop" | sed 's/^/  /'
    echo -e "\n${BOLD}  Дисковий простiр:${NC}"
    df -h 2>/dev/null | grep -v "tmpfs\|udev\|loop" | sed 's/^/  /'
    echo ""
}

pick_path_readline() {
    local prompt="$1"
    local current="$2"
    local chosen
    echo ""
    echo -e "${BOLD}${CYAN}  $prompt${NC}"
    echo -e "${YELLOW}  Tab -- автодоповнення, Enter -- пiдтвердити${NC}"
    echo -e "  Поточний: ${GREEN}$current${NC}"
    echo -ne "  Новий шлях: "
    bind 'set show-all-if-ambiguous on' 2>/dev/null || true
    bind 'set completion-ignore-case on' 2>/dev/null || true
    IFS= read -r -e -i "$current" chosen
    echo "${chosen:-$current}"
}

choose_path() {
    local title="$1"
    local prompt="$2"
    local current="$3"
    local OPTIONS=()
    OPTIONS+=("$DEFAULT_SOURCE_DIR" "Homelab (основна папка)")
    OPTIONS+=("$DEFAULT_TARGET_DIR" "Домашня директорiя")
    OPTIONS+=("/mnt/backup/data_backups" "Основний бекап-диск")
    OPTIONS+=("/mnt/backup" "/mnt/backup")

    while IFS= read -r mp; do
        local skip=0
        for o in "${OPTIONS[@]}"; do
            [ "$o" = "$mp" ] && skip=1 && break
        done
        [ $skip -eq 1 ] && continue
        OPTIONS+=("$mp" "Зовнiшнiй диск / роздiл")
    done < <(lsblk -o MOUNTPOINT --noheadings 2>/dev/null | grep -E '^/(mnt|media)/' | sort -u)

    OPTIONS+=("__manual__" "Ввести шлях вручну (з Tab-доповненням)")

    local CHOICE
    CHOICE=$(whiptail --title "$title" \
        --menu "$prompt\n\nПоточний: $current" \
        22 70 12 \
        "${OPTIONS[@]}" \
        3>&1 1>&2 2>&3) || { echo "$current"; return; }

    if [ "$CHOICE" = "__manual__" ]; then
        # Виводимо на stderr щоб не забруднити stdout який йде в змінну
        clear >&2
        list_mounted_disks >&2
        pick_path_readline "$title" "$current"
    else
        echo "$CHOICE"
    fi
}

# ============================================================
#  BACKUP CORE (використовується i меню, i cron)
# ============================================================
run_backup() {
    local silent="${1:-false}"
    local DOCKER_COMPOSE DATE FILENAME
    DOCKER_COMPOSE=$(detect_compose)
    DATE=$(date +%Y-%m-%d_%H-%M)
    FILENAME="homelab_backup_$DATE.tar.gz"

    [ "$silent" = "false" ] && echo -e "\n${BOLD}${BLUE}========================================${NC}"
    [ "$silent" = "false" ] && echo -e "${BOLD}  БЕКАП HOMELAB${NC}"
    [ "$silent" = "false" ] && echo -e "${BOLD}${BLUE}========================================${NC}\n"
    [ "$silent" = "false" ] && echo -e "  ${CYAN}Джерело:${NC} $SOURCE_DIR"
    [ "$silent" = "false" ] && echo -e "  ${CYAN}Цiль:${NC}    $BACKUP_DIR/$FILENAME\n"

    log_only "=== ПОЧАТОК БЕКАПУ ==="
    mkdir -p "$BACKUP_DIR"

    # 1. Зупинка
    log_only "Зупинка контейнерiв..."
    for d in "$SOURCE_DIR"/*/; do
        [ -f "${d}docker-compose.yml" ] || continue
        local svc; svc=$(basename "$d")
        [ "$silent" = "false" ] && echo -e "  ${CYAN}> Зупиняю:${NC} $svc"
        (cd "$d" && sudo $DOCKER_COMPOSE stop) >> "$LOG_FILE" 2>&1 || true
    done

    # 2. Архiв
    log_only "Створення архiву $FILENAME..."
    local parent folder
    parent=$(dirname "$SOURCE_DIR")
    folder=$(basename "$SOURCE_DIR")

    if sudo tar -czf "$BACKUP_DIR/$FILENAME" -C "$parent" "$folder" 2>>"$LOG_FILE"; then
        local SIZE; SIZE=$(du -sh "$BACKUP_DIR/$FILENAME" | cut -f1)
        [ "$silent" = "false" ] && echo -e "  ${GREEN}OK Архiв створено ($SIZE)${NC}"
        log_only "Архiв: $FILENAME ($SIZE)"
    else
        log "ПОМИЛКА: не вдалося створити архiв!"
        # Пiднiмаємо контейнери навiть при помилцi
        for d in "$SOURCE_DIR"/*/; do
            [ -f "${d}docker-compose.yml" ] || continue
            (cd "$d" && sudo $DOCKER_COMPOSE up -d) >> "$LOG_FILE" 2>&1 || true
        done
        return 1
    fi

    # 3. Запуск
    log_only "Запуск контейнерiв..."
    for d in "$SOURCE_DIR"/*/; do
        [ -f "${d}docker-compose.yml" ] || continue
        local svc; svc=$(basename "$d")
        [ "$silent" = "false" ] && echo -e "  ${CYAN}> Запускаю:${NC} $svc"
        (cd "$d" && sudo $DOCKER_COMPOSE up -d) >> "$LOG_FILE" 2>&1 || true
    done

    # 4. Ротацiя
    local ALL_BACKUPS
    mapfile -t ALL_BACKUPS < <(ls -t "$BACKUP_DIR"/homelab_backup_*.tar.gz 2>/dev/null)
    local TOTAL=${#ALL_BACKUPS[@]}
    if [ "$TOTAL" -gt "$KEEP_COUNT" ]; then
        local TO_DELETE=("${ALL_BACKUPS[@]:$KEEP_COUNT}")
        for f in "${TO_DELETE[@]}"; do
            [ "$silent" = "false" ] && echo -e "  ${RED}> Видалено:${NC} $(basename "$f")"
            sudo rm -f "$f"
            log_only "Ротацiя: видалено $(basename "$f")"
        done
    else
        [ "$silent" = "false" ] && echo -e "  ${GREEN}OK Ротацiя не потрiбна ($TOTAL з $KEEP_COUNT)${NC}"
    fi

    log_only "=== БЕКАП ЗАВЕРШЕНО ==="
    [ "$silent" = "false" ] && echo -e "\n${BOLD}${GREEN}========================================${NC}"
    [ "$silent" = "false" ] && echo -e "${BOLD}${GREEN}  БЕКАП ЗАВЕРШЕНО УСПIШНО!${NC}"
    [ "$silent" = "false" ] && echo -e "${BOLD}${GREEN}========================================${NC}\n"
    return 0
}

# ============================================================
#  BACKUP (з меню -- показує пiдтвердження i паузу)
# ============================================================
do_backup() {
    local DATE FILENAME
    DATE=$(date +%Y-%m-%d_%H-%M)
    FILENAME="homelab_backup_$DATE.tar.gz"

    whiptail --title "Пiдтвердження бекапу" \
        --yesno "Параметри:\n\n  Джерело:  $SOURCE_DIR\n  Архiв:    $BACKUP_DIR/$FILENAME\n  Лiмiт:    $KEEP_COUNT бекапiв\n\n  Контейнери будуть тимчасово зупиненi.\n  Продовжити?" \
        15 68 || return

    clear
    run_backup false
    echo -e "Натиснiть Enter для повернення..."
    read -r
}

# ============================================================
#  RESTORE
# ============================================================
do_restore() {
    local DOCKER_COMPOSE
    DOCKER_COMPOSE=$(detect_compose)

    if ! command -v docker &>/dev/null; then
        whiptail --title "Docker не знайдено" \
            --yesno "Docker не встановлено.\nВстановити зараз?" 8 42 || return
        sudo apt update && sudo apt install -y docker.io docker-compose
        sudo systemctl enable --now docker
        DOCKER_COMPOSE=$(detect_compose)
    fi

    local BACKUPS=()
    while IFS= read -r file; do
        local fname size mdate
        fname=$(basename "$file")
        size=$(du -sh "$file" 2>/dev/null | cut -f1)
        mdate=$(stat -c '%y' "$file" 2>/dev/null | cut -d'.' -f1)
        BACKUPS+=("$fname" "  $size  |  $mdate")
    done < <(ls -t "$BACKUP_DIR"/homelab_backup_*.tar.gz 2>/dev/null)

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        whiptail --title "Бекапiв не знайдено" \
            --msgbox "Папка порожня:\n$BACKUP_DIR\n\nЗмiнiть шлях у Налаштуваннях." 10 58
        return
    fi

    local SELECTED
    SELECTED=$(whiptail --title "Вибiр бекапу" \
        --menu "Папка: $BACKUP_DIR\n\nПерший -- найновiший. Стрiлки -- навiгацiя:" \
        24 76 14 \
        "${BACKUPS[@]}" \
        3>&1 1>&2 2>&3) || return

    local BACKUP_FILE="$BACKUP_DIR/$SELECTED"

    whiptail --title "УВАГА -- НЕЗВОРОТНА ДIЯ" \
        --yesno "ПОВНЕ вiдновлення:\n\n  Бекап:  $SELECTED\n  Цiль:   $TARGET_DIR/homelab\n\n  Поточна папка homelab БУДЕ ВИДАЛЕНА!\n  Всi контейнери зупиняться!\n\n  Ви впевненi?" \
        15 68 || return

    clear
    log_only "=== ПОЧАТОК ВIДНОВЛЕННЯ: $SELECTED ==="

    echo -e "\n${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}  ВIДНОВЛЕННЯ HOMELAB${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}"
    echo -e "  ${CYAN}Бекап:${NC} $SELECTED\n"

    echo -e "${YELLOW}[1/5] Зупинка контейнерiв...${NC}"
    if [ -d "$TARGET_DIR/homelab" ]; then
        for d in "$TARGET_DIR/homelab"/*/; do
            [ -f "${d}docker-compose.yml" ] || continue
            (cd "$d" && sudo $DOCKER_COMPOSE down --remove-orphans) >> "$LOG_FILE" 2>&1 || true
        done
    fi
    sudo docker stop $(sudo docker ps -q) >> "$LOG_FILE" 2>&1 || true
    sudo docker rm $(sudo docker ps -aq) >> "$LOG_FILE" 2>&1 || true
    echo -e "  ${GREEN}OK${NC}"

    echo -e "\n${YELLOW}[2/5] Розпакування...${NC}"
    sudo rm -rf "$TARGET_DIR/homelab"
    if sudo tar -xzf "$BACKUP_FILE" -C "$TARGET_DIR" 2>>"$LOG_FILE"; then
        echo -e "  ${GREEN}OK Розпаковано${NC}"
        log_only "Розпаковано: $SELECTED"
    else
        echo -e "  ${RED}ПОМИЛКА розпакування!${NC}"
        log_only "ПОМИЛКА: $SELECTED"
        echo -e "\nНатиснiть Enter..."; read -r
        return
    fi

    echo -e "\n${YELLOW}[3/5] Права доступу...${NC}"
    local OWNER; OWNER=$(basename "$TARGET_DIR")
    sudo chown -R "$OWNER:$OWNER" "$TARGET_DIR/homelab"
    sudo chown -R 33:33 "$TARGET_DIR/homelab/wp_"*/wp_data 2>/dev/null || true
    echo -e "  ${GREEN}OK${NC}"

    echo -e "\n${YELLOW}[4/5] Docker мережа (чекаємо 10 сек)...${NC}"
    sleep 10
    if ! docker network ls | grep -q "$NETWORK_NAME"; then
        docker network create "$NETWORK_NAME" >> "$LOG_FILE" 2>&1 || true
        echo -e "  ${GREEN}OK Мережу $NETWORK_NAME створено${NC}"
    else
        echo -e "  ${GREEN}OK Мережа iснує${NC}"
    fi

    echo -e "\n${YELLOW}[5/5] Запуск сервiсiв...${NC}"
    for d in "$TARGET_DIR/homelab"/*/; do
        [ -f "${d}docker-compose.yml" ] || continue
        local svc; svc=$(basename "$d")
        echo -e "  ${CYAN}> Запускаю:${NC} $svc"
        if [ -f "${d}Dockerfile" ]; then
            echo -e "    ${YELLOW}> Збiрка образу...${NC}"
            (cd "$d" && sudo docker build -t oxiwis-image .) >> "$LOG_FILE" 2>&1 || true
        fi
        (cd "$d" && sudo $DOCKER_COMPOSE up -d) >> "$LOG_FILE" 2>&1 || true
    done
    log_only "=== ВIДНОВЛЕННЯ ЗАВЕРШЕНО ==="

    echo -e "\n${BOLD}${GREEN}========================================${NC}"
    echo -e "${BOLD}${GREEN}  ВIДНОВЛЕННЯ ЗАВЕРШЕНО!${NC}"
    echo -e "${BOLD}${GREEN}========================================${NC}\n"
    echo -e "Натиснiть Enter для повернення..."; read -r
}

# ============================================================
#  LIST BACKUPS
# ============================================================
do_list() {
    clear
    echo -e "\n${BOLD}${BLUE}================================================${NC}"
    echo -e "${BOLD}  СПИСОК БЕКАПIВ${NC}"
    echo -e "${BOLD}${BLUE}================================================${NC}"
    echo -e "  ${CYAN}Папка:${NC} $BACKUP_DIR\n"

    local COUNT=0
    while IFS= read -r file; do
        local fname size mdate
        fname=$(basename "$file")
        size=$(du -sh "$file" 2>/dev/null | cut -f1)
        mdate=$(stat -c '%y' "$file" 2>/dev/null | cut -d'.' -f1)
        COUNT=$((COUNT + 1))
        if [ $COUNT -eq 1 ]; then
            echo -e "  ${GREEN}* [$COUNT] $fname${NC}"
            echo -e "      ${GREEN}$size  |  $mdate  <- найновiший${NC}"
        else
            echo -e "  ${CYAN}  [$COUNT] $fname${NC}"
            echo -e "      ${CYAN}$size  |  $mdate${NC}"
        fi
    done < <(ls -t "$BACKUP_DIR"/homelab_backup_*.tar.gz 2>/dev/null)

    echo -e "\n${BOLD}${BLUE}================================================${NC}"
    if [ $COUNT -eq 0 ]; then
        echo -e "  ${RED}Бекапiв не знайдено в $BACKUP_DIR${NC}"
    else
        local FOLDER_SIZE; FOLDER_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        echo -e "  ${BOLD}Всього: $COUNT  |  Лiмiт: $KEEP_COUNT  |  Папка: $FOLDER_SIZE${NC}"
    fi
    echo -e "${BOLD}${BLUE}================================================${NC}"
}

# ============================================================
#  STATUS
# ============================================================
do_status() {
    echo -e "\n${BOLD}${BLUE}================================================${NC}"
    echo -e "${BOLD}  СТАТУС DOCKER КОНТЕЙНЕРIВ  [$(date '+%H:%M:%S')]${NC}"
    echo -e "${BOLD}${BLUE}================================================${NC}\n"

    local output
    output=$(sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
    echo "$output" | while IFS= read -r line; do
        if echo "$line" | grep -q "Up"; then
            echo -e "  ${GREEN}$line${NC}"
        elif echo "$line" | grep -q "NAME"; then
            echo -e "  ${BOLD}$line${NC}"
        else
            echo -e "  ${RED}$line${NC}"
        fi
    done

    local STOPPED
    STOPPED=$(sudo docker ps -a --filter "status=exited" --format "{{.Names}}" 2>/dev/null)
    if [ -n "$STOPPED" ]; then
        echo -e "\n  ${RED}Зупиненi контейнери:${NC}"
        echo "$STOPPED" | sed 's/^/    /'
    fi

    echo -e "\n${BOLD}${BLUE}================================================${NC}"
}

# ============================================================
#  SETTINGS
# ============================================================
do_settings() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail --title "Налаштування -- Homelab Manager" \
            --menu "Поточнi параметри:\n\n  Джерело:      $SOURCE_DIR\n  Бекапи:       $BACKUP_DIR\n  Розпакування: $TARGET_DIR\n  Мережа:       $NETWORK_NAME\n  Зберiгати:    $KEEP_COUNT бекапiв\n" \
            24 74 7 \
            "1" "Змiнити джерело бекапу (SOURCE_DIR)" \
            "2" "Змiнити папку для збереження бекапiв" \
            "3" "Змiнити цiль вiдновлення (TARGET_DIR)" \
            "4" "Змiнити назву Docker мережi" \
            "5" "Кiлькiсть бекапiв (зараз: $KEEP_COUNT)" \
            "6" "Показати пiдключенi диски" \
            "7" "Назад" \
            3>&1 1>&2 2>&3) || break

        case "$CHOICE" in
            1)
                local NEW; NEW=$(choose_path "Джерело бекапу" "Звiдки робити бекап:" "$SOURCE_DIR")
                if [ -d "$NEW" ]; then
                    SOURCE_DIR="$NEW"; save_config
                    whiptail --title "Збережено" --msgbox "SOURCE_DIR:\n$SOURCE_DIR" 8 62
                else
                    whiptail --title "Помилка" --msgbox "Шлях не iснує:\n$NEW" 8 52
                fi
                ;;
            2)
                local NEW; NEW=$(choose_path "Папка для бекапiв" "Куди зберiгати архiви:" "$BACKUP_DIR")
                BACKUP_DIR="$NEW"; save_config
                whiptail --title "Збережено" --msgbox "BACKUP_DIR:\n$BACKUP_DIR\n\n(Буде створена автоматично)" 10 64
                ;;
            3)
                local NEW; NEW=$(choose_path "Цiль вiдновлення" "Куди розпаковувати:" "$TARGET_DIR")
                if [ -d "$NEW" ]; then
                    TARGET_DIR="$NEW"; save_config
                    whiptail --title "Збережено" --msgbox "TARGET_DIR:\n$TARGET_DIR" 8 62
                else
                    whiptail --title "Помилка" --msgbox "Шлях не iснує:\n$NEW" 8 52
                fi
                ;;
            4)
                local NEW_NET
                NEW_NET=$(whiptail --title "Docker мережа" \
                    --inputbox "Назва Docker мережi:\n\nПоточне: $NETWORK_NAME" \
                    9 52 "$NETWORK_NAME" 3>&1 1>&2 2>&3) || continue
                if [ -n "$NEW_NET" ]; then
                    NETWORK_NAME="$NEW_NET"; save_config
                    whiptail --title "Збережено" --msgbox "NETWORK_NAME: $NETWORK_NAME" 7 48
                fi
                ;;
            5)
                local NEW_COUNT
                NEW_COUNT=$(whiptail --title "Кiлькiсть бекапiв" \
                    --inputbox "Скiльки бекапiв зберiгати?\n\nПоточне: $KEEP_COUNT" \
                    9 50 "$KEEP_COUNT" 3>&1 1>&2 2>&3) || continue
                if [[ "$NEW_COUNT" =~ ^[0-9]+$ ]] && [ "$NEW_COUNT" -gt 0 ]; then
                    KEEP_COUNT="$NEW_COUNT"; save_config
                    whiptail --title "Збережено" --msgbox "Зберiгатиметься $KEEP_COUNT бекапiв." 7 46
                else
                    whiptail --title "Помилка" --msgbox "Введiть цiле число > 0." 7 38
                fi
                ;;
            6)
                clear; list_mounted_disks
                echo -e "Натиснiть Enter..."; read -r
                ;;
            7) break ;;
        esac
    done
}

# ============================================================
#  HELP
# ============================================================
show_help() {
    echo ""
    echo -e "${BOLD}homelab -- Docker Homelab Manager v3.0${NC}"
    echo ""
    echo "  Використання:"
    echo "    homelab              -- iнтерактивне меню"
    echo "    homelab --backup     -- тихий бекап (для cron)"
    echo "    homelab --status     -- статус контейнерiв"
    echo "    homelab --list       -- список бекапiв"
    echo "    homelab --help       -- ця довiдка"
    echo ""
    echo "  Cron (бекап щоночi о 3:00):"
    echo "    0 3 * * * /usr/local/bin/homelab --backup >> /var/log/homelab_manager.log 2>&1"
    echo ""
    echo "  Конфiг: ~/.homelab_manager.conf"
    echo "  Лог:    /var/log/homelab_manager.log"
    echo ""
}

# ============================================================
#  MAIN MENU
# ============================================================
main_menu() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail --title "Homelab Manager v3.0  [$HOSTNAME]" \
            --menu "\n  Джерело:  $SOURCE_DIR\n  Бекапи:   $BACKUP_DIR\n  Лiмiт:    $KEEP_COUNT бекапiв\n" \
            22 68 7 \
            "1" "Створити бекап" \
            "2" "Вiдновити з бекапу (вибiр зi списку)" \
            "3" "Переглянути всi бекапи" \
            "4" "Статус Docker контейнерiв" \
            "5" "Налаштування" \
            "6" "Переглянути лог" \
            "7" "Вихiд" \
            3>&1 1>&2 2>&3) || break

        case "$CHOICE" in
            1) do_backup   ;;
            2) do_restore  ;;
            3) do_list; echo -e "\nНатиснiть Enter..."; read -r ;;
            4) do_status; echo -e "Натиснiть Enter..."; read -r ;;
            5) do_settings ;;
            6)
                clear
                echo -e "${BOLD}Останнi 50 рядкiв логу:${NC}\n"
                sudo tail -50 "$LOG_FILE" 2>/dev/null || echo "Лог порожнiй."
                echo -e "\nНатиснiть Enter..."; read -r
                ;;
            7) break ;;
        esac
    done
    clear
    echo -e "${GREEN}До побачення!${NC}"
}

# ============================================================
#  ENTRY POINT
# ============================================================
load_config

case "${1:-}" in
    --backup)
        # Тихий режим для cron -- без меню, без пауз
        log_only "=== CRON BACKUP STARTED ==="
        run_backup true
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 0 ]; then
            log_only "=== CRON BACKUP OK ==="
        else
            log_only "=== CRON BACKUP FAILED ==="
        fi
        exit $EXIT_CODE
        ;;
    --status)
        do_status
        exit 0
        ;;
    --list)
        do_list
        exit 0
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    "")
        check_deps
        main_menu
        ;;
    *)
        echo "Невiдомий параметр: $1"
        show_help
        exit 1
        ;;
esac
