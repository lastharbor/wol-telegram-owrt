#!/bin/sh
# Установка luci-app-wol-telegram с GitHub Release (OpenWrt).
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/lastharbor/wol-telegram-owrt/v1.0.0/install-openwrt.sh | sh -s v1.0.0
# или на роутере: sh install-openwrt.sh v1.0.0
set -e

TAG="${1:-v1.0.0}"
REPO="lastharbor/wol-telegram-owrt"

need_cmd() {
	command -v "$1" >/dev/null 2>&1
}

opkg_install_safe() {
	# opkg install может фейлиться на части пакетов из-за conffiles/конфликтов,
	# но для инсталлятора важнее дотянуть зависимости насколько возможно.
	opkg install "$@" >/dev/null 2>&1 || opkg install "$@" || true
}

if need_cmd opkg; then
	echo "opkg: обновляю индексы …"
	opkg update
	echo "opkg: ставлю базовые зависимости …"
	# curl для скачивания .ipk, CA для TLS.
	opkg_install_safe curl ca-bundle
	# python нужен для GitHub API (urllib+ssl).
	opkg_install_safe python3-light python3-urllib python3-openssl
	# pip нужен, чтобы поставить python-telegram-bot вместе с зависимостями (httpx/anyio и т.д.).
	opkg_install_safe python3-pip || opkg_install_safe py3-pip
	# утилиты для WOL
	opkg_install_safe luci-base etherwake
fi

if ! need_cmd python3; then
	echo "Нужен python3 (поставьте python3-light через opkg)." >&2
	exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT INT HUP

python3 - "$TAG" "$REPO" <<'PY' >"$TMP"
import json, ssl, sys, urllib.request

tag, repo = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
req = urllib.request.Request(url, headers={"User-Agent": "wol-telegram-owrt-install"})
ctx = ssl.create_default_context()
with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
    data = json.load(r)
assets = data.get("assets") or []
for a in assets:
    name = a.get("name") or ""
    if name.endswith("_all.ipk") and "luci-app-wol-telegram" in name:
        print(a.get("browser_download_url") or "")
        print(name)
        sys.exit(0)
sys.stderr.write(f"В релизе {tag} нет .ipk luci-app-wol-telegram\n")
sys.exit(1)
PY

URL="$(sed -n '1p' "$TMP")"
NAME="$(sed -n '2p' "$TMP")"
if [ -z "$URL" ] || [ -z "$NAME" ]; then
	echo "Не удалось получить URL артефакта." >&2
	exit 1
fi

# Версия из имени артефакта: luci-app-wol-telegram_1.0.0-1_all.ipk → 1.0.0-1
NEW_VER=""
case "$NAME" in
	luci-app-wol-telegram_*_all.ipk)
		NEW_VER="${NAME#luci-app-wol-telegram_}"
		NEW_VER="${NEW_VER%_all.ipk}"
		;;
esac

INSTALLED_VER=""
if command -v opkg >/dev/null 2>&1; then
	INSTALLED_VER="$(opkg list-installed luci-app-wol-telegram 2>/dev/null | awk '{print $3}')"
fi

if [ -n "$INSTALLED_VER" ] && [ -n "$NEW_VER" ] && [ "$INSTALLED_VER" = "$NEW_VER" ] && [ -z "${FORCE}${WOLTG_FORCE_REINSTALL}" ]; then
	echo "Уже установлена та же версия: $INSTALLED_VER (релиз $TAG). Скачивание и opkg пропущены."
	echo "Переустановка: FORCE=1 curl … | sh -s $TAG   или   WOLTG_FORCE_REINSTALL=1 sh … $TAG"
	exit 0
fi

IPK="/tmp/$NAME"
echo "Скачиваю $NAME …"
curl -fL --connect-timeout 30 --max-time 300 "$URL" -o "$IPK"

if command -v opkg >/dev/null 2>&1; then
	echo "Устанавливаю зависимости opkg …"
	opkg update
	opkg_install_safe luci-base curl ca-bundle etherwake python3-light python3-urllib python3-openssl
	opkg_install_safe python3-pip || opkg_install_safe py3-pip
	echo "Устанавливаю пакет …"
	opkg install --force-reinstall "$IPK" || opkg install "$IPK"
	if command -v pip3 >/dev/null 2>&1; then
		echo "Ставлю pip-зависимость python-telegram-bot …"
		pip3 install --no-cache-dir 'python-telegram-bot>=21,<23' || true
	else
		echo "pip3 не найден — установите python3-pip и затем: pip3 install 'python-telegram-bot>=21,<23'"
	fi
	echo "LuCI: Services → WOL Telegram. Сервис: /etc/init.d/woltelegram restart"
else
	echo "opkg не найден — сохранено: $IPK"
fi
