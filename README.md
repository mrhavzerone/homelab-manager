# 🏠 Homelab Manager

> Інструмент для керування Docker-сервісами на домашньому сервері.  
> Бекап, відновлення, моніторинг — все в одному місці.

## ✨ Можливості

- 📦 **Бекап** всіх Docker Compose сервісів одною командою
- 🛠️ **Відновлення** з вибором конкретного бекапу зі списку
- 🖥️ **Інтерактивне меню** на базі `whiptail` (працює в будь-якому терміналі)
- ⚙️ **Налаштування шляхів** через меню — з Tab-доповненням і автовизначенням дисків
- 🔄 **Автобекап через cron** з тихим режимом (`--backup`)
- 🔢 **Ротація бекапів** — зберігає N останніх, решту видаляє
- 🚀 **Bootstrap-встановлення** на чисту машину — один рядок
- 📡 **Відновлення по SSH** з іншого сервера через rsync

---

## 🚀 Встановлення

### На чистій машині (Ubuntu/Debian)

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homelab-manager/main/install.sh | bash
```

### Локально (якщо файли вже є)

```bash
git clone https://github.com/YOUR_USERNAME/homelab-manager
cd homelab-manager
bash install.sh
```

---

## 📖 Використання

```bash
homelab              # інтерактивне меню
homelab --backup     # тихий бекап (для cron)
homelab --status     # статус контейнерів
homelab --list       # список бекапів
homelab --help       # довідка
```

### Cron (встановлюється автоматично через install.sh)

```
0 3 * * * /usr/local/bin/homelab --backup >> /var/log/homelab_manager.log 2>&1
```

---

## 📁 Структура

```
homelab-manager/
├── homelab.sh       # основний скрипт (меню, бекап, відновлення)
├── install.sh       # bootstrap-інсталятор для чистої машини
├── README.md        # ця документація
└── .github/
    └── workflows/
        └── validate.yml   # автоперевірка синтаксису при push
```

---

## ⚙️ Конфігурація

Зберігається в `~/.homelab_manager.conf`:

```bash
SOURCE_DIR="/home/user/homelab"      # звідки бекапити
BACKUP_DIR="/mnt/backup/data_backups" # куди зберігати
TARGET_DIR="/home/user"              # куди розпаковувати
KEEP_COUNT=10                        # скільки бекапів зберігати
NETWORK_NAME="homelab_network"       # назва Docker мережі
```

---

## 🔄 Сценарій переїзду на новий сервер

**На старому сервері:**
```bash
homelab --backup
```

**На новому сервері (чиста Ubuntu):**
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/homelab-manager/main/install.sh | bash
# install.sh сам запропонує відновити по SSH або з диску
```

---

## 📋 Вимоги

| Компонент | Версія |
|-----------|--------|
| OS | Ubuntu 20.04+ / Debian 11+ |
| Docker | 20.10+ |
| Docker Compose | V2 (plugin) |
| Bash | 4.0+ |

Встановлюються автоматично через `install.sh`: `curl`, `whiptail`, `rsync`, `tar`

---

## 🗺️ Плани (TODO)

- [ ] Telegram сповіщення після бекапу
- [ ] Healthcheck після відновлення
- [ ] Інкрементальні бекапи через rsync
- [ ] Веб-дашборд (статичний HTML)
- [ ] Git-версіонування docker-compose файлів
- [ ] Перевірка цілісності архівів

---

## 📄 Ліцензія

MIT — використовуй, змінюй, ділись.

---

> Зроблено для тих, хто хоче мати власний сервер і не боятися його переносити.
