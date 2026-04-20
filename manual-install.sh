#!/bin/sh
# Запускать на роутере из каталога luci-app-wol-telegram (или поправьте ROOT)
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

if [ ! -f /etc/config/woltelegram ]; then
	install -m 0600 root/etc/config/woltelegram /etc/config/woltelegram
else
	echo "Сохранён существующий /etc/config/woltelegram"
fi
install -m 0755 root/etc/init.d/woltelegram /etc/init.d/woltelegram
install -m 0755 root/usr/bin/woltelegram /usr/bin/woltelegram
install -d /usr/share/woltelegram
install -m 0644 root/usr/share/woltelegram/woltg_uci.py /usr/share/woltelegram/
install -m 0644 root/usr/share/woltelegram/woltg_state.py /usr/share/woltelegram/
install -m 0644 root/usr/share/woltelegram/woltg_devices.py /usr/share/woltelegram/
install -m 0644 root/usr/share/woltelegram/woltg_sync.py /usr/share/woltelegram/
install -m 0755 root/usr/share/woltelegram/woltg_main.py /usr/share/woltelegram/
install -d /usr/lib/systemd/system
install -m 0644 root/usr/lib/systemd/system/wol-telegram-handler.service /usr/lib/systemd/system/wol-telegram-handler.service
install -m 0644 luasrc/controller/woltelegram.lua /usr/lib/lua/luci/controller/woltelegram.lua
install -m 0644 luasrc/model/cbi/woltelegram.lua /usr/lib/lua/luci/model/cbi/woltelegram.lua

chmod 600 /etc/config/woltelegram

/etc/init.d/rpcd restart 2>/dev/null || true
rm -f /tmp/luci-indexcache 2>/dev/null || true

echo "Установлено. Нужен pip-пакет: pip3 install 'python-telegram-bot>=21,<23'"
echo "Настройте LuCI: Services → WOL Telegram, затем:"
echo "  /etc/init.d/woltelegram enable && /etc/init.d/woltelegram restart"
echo "Синхронизация chat_id: woltelegram sync-chatids"
