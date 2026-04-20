# wol-telegram-owrt (luci-app-wol-telegram)

[![build](https://github.com/lastharbor/wol-telegram-owrt/actions/workflows/build.yml/badge.svg)](https://github.com/lastharbor/wol-telegram-owrt/actions/workflows/build.yml)

LuCI + UCI + **procd** для Telegram-бота на **OpenWrt**: Wake-on-LAN и статус по **ping**, одно якорное сообщение в чате, inline-кнопки.  
Репозиторий: **https://github.com/lastharbor/wol-telegram-owrt**

> **Расширение / проект: AI Generated** — код и документация созданы и доработаны с участием ИИ (LLM). Перед продакшеном сделайте ревью и проверку на своём роутере.

---

## Бэкенд: только Python

| Назначение | Путь |
|------------|------|
| Точка входа (CLI / procd) | `/usr/bin/woltelegram` → вызывает модули из `/usr/share/woltelegram/` |
| Long-poll бот (python-telegram-bot) | `woltg_main.py` |
| UCI | `woltg_uci.py` |
| Состояние панели / TSV в `/var/run` | `woltg_state.py` |
| Устройства, WOL, ping | `woltg_devices.py` |
| `getUpdates` → merge `allowed_chat_ids` | `woltg_sync.py` (`woltelegram sync-chatids`) |

**Не бот:** только `root/etc/init.d/woltelegram` (OpenWrt **/etc/rc.common** + **procd**) и вспомогательные **`build-ipk.sh`**, **`install-openwrt.sh`**, **`manual-install.sh`** для сборки/установки. Отдельных `wol-telegram-*.sh` обработчиков в `/usr/bin` пакет не ставит (postinst удаляет устаревшие файлы).

Зависимость на роутере (pip, не в ipk):

```sh
pip3 install 'python-telegram-bot>=21,<23'
```

opkg: `luci-base`, `etherwake`, `curl`, `python3-light` (см. `Makefile`).

---

## Быстрая установка с GitHub (после Release)

После публикации тега (например **`v1.0.0`**) в [Releases](https://github.com/lastharbor/wol-telegram-owrt/releases) появится `.ipk` и сработает установщик по **raw**:

```sh
curl -fsSL https://raw.githubusercontent.com/lastharbor/wol-telegram-owrt/v1.0.0/install-openwrt.sh | sh -s v1.0.0
```

Скрипт скачивает артефакт `luci-app-wol-telegram_*_all.ipk` из релиза с этим тегом, ставит зависимости через `opkg` и устанавливает пакет. Тег в URL и аргумент `sh -s` должны совпадать с созданным **GitHub Release**.

**Безопасность:** просмотрите `install-openwrt.sh` перед `| sh` (или скачайте файл и запустите `sh install-openwrt.sh v1.0.0`).

---

## Локальная сборка `.ipk` (на OpenWrt или Linux с `tar`/`gzip`)

```sh
./build-ipk.sh
# артефакт: bin/luci-app-wol-telegram_1.0-<PKG_RELEASE>_all.ipk
```

`PKG_RELEASE` задаётся в **`Makefile`**; для согласованности при релизе обновите и строку **`REL=`** в **`build-ipk.sh`** (или выровняйте скриптом перед тегом).

Установка на роутере:

```sh
opkg install luci-base curl etherwake python3-light
opkg install /path/to/luci-app-wol-telegram_*_all.ipk
pip3 install 'python-telegram-bot>=21,<23'
```

Удаление:

```sh
opkg remove luci-app-wol-telegram
```

---

## GitHub Actions

| Workflow | Когда | Что делает |
|----------|--------|------------|
| **build** | push / PR в `main` | Сборка `.ipk`, артефакт в Actions |
| **release** | push тега `v*` (например `v1.0.0`) | Сборка `.ipk` и **GitHub Release** с прикреплённым пакетом |

Создать **Release V1** после первого залива кода:

```sh
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

Нужен **`GITHUB_TOKEN`** с правом `contents: write` (для форков — настройки репозитория / разрешения Actions).

---

## Сборка в дереве OpenWrt SDK

Положите каталог в `package/luci-app-wol-telegram/`, затем:

```sh
make menuconfig   # LuCI → Applications → luci-app-wol-telegram
make package/luci-app-wol-telegram/compile
```

---

## Ручная установка без opkg

```sh
chmod +x manual-install.sh
./manual-install.sh
```

Или см. таблицу файлов в `manual-install.sh`.

---

## Настройка и ограничения

1. Токен в [@BotFather](https://t.me/BotFather) → LuCI.  
2. `chat_id`: LuCI «Показать чаты» / «В UCI из Telegram» (пока **остановлен** procd-бот, иначе конфликт `getUpdates`), либо `woltelegram sync-chatids`.  
3. Устройства и **имя в ответах** — в разделе «Устройства»; для ping задайте IP или используйте DHCP.  
4. WOL — Ethernet и поддержка в BIOS/ОС.

---

## Публикация в GitHub (для владельца репозитория)

HTTPS без сохранённого токена здесь не сработает. Варианты:

```sh
cd luci-app-wol-telegram
git remote set-url origin git@github.com:lastharbor/wol-telegram-owrt.git
git push -u origin main
git push origin v1.0.0   # после: git tag -a v1.0.0 -m "Release v1.0.0"
```

После первого `git push` создайте аннотированный тег и отправьте его (в репозитории уже подготовлен сценарий под **`v1.0.0`**):

```sh
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

Запустится workflow **release** и прикрепит `luci-app-wol-telegram_*_all.ipk` к GitHub Release.

---

## Лицензия

См. `Makefile`: **GPL-2.0-or-later** (метаданные пакета OpenWrt).
