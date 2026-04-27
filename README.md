# wol-telegram-owrt (luci-app-wol-telegram)

LuCI + UCI + **procd** Telegram-бот для OpenWrt:

- **Wake-on-LAN** (etherwake)
- **Статус** по ping
- Одна “панель” в чате (редактирование одного сообщения) + inline-кнопки

## Установка (из GitHub Release)

После публикации тега (например `v1.0.0`) можно установить одной командой:

```sh
curl -fsSL https://raw.githubusercontent.com/lastharbor/wol-telegram-owrt/v1.0.0/install-openwrt.sh | sh -s v1.0.0
```

Скрипт:

- ставит зависимости через `opkg`
- ставит pip-зависимость `python-telegram-bot` (если доступен `pip3`)
- скачивает `.ipk` из релиза и устанавливает его

## Настройка

1) В LuCI: **Services → WOL Telegram**

- `bot_token` (из @BotFather)
- `allowed_chat_ids` (можно заполнить через `woltelegram sync-chatids`, пока сервис остановлен)

2) Запуск:

```sh
/etc/init.d/woltelegram enable
/etc/init.d/woltelegram restart
```

## Пути (что ставит пакет)

- Entry-point: `/usr/bin/woltelegram`
- Python код: `/usr/share/woltelegram/*.py`
- init/procd: `/etc/init.d/woltelegram`
- UCI config: `/etc/config/woltelegram`

