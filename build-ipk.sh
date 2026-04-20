#!/bin/sh
# Собрать .ipk на самом OpenWrt (без SDK): нужны tar и пакет ar (opkg install ar).
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

PKG=luci-app-wol-telegram
VER=1.0
REL=51
ARCH=all

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/stage"
ST="$WORKDIR/stage"

# data tree (без coreutils install — только mkdir/cp/chmod)
mkdir -p "$ST/usr/lib/lua/luci/controller"
cp -f "$ROOT/luasrc/controller/woltelegram.lua" "$ST/usr/lib/lua/luci/controller/"
chmod 0644 "$ST/usr/lib/lua/luci/controller/woltelegram.lua"
mkdir -p "$ST/usr/lib/lua/luci/model/cbi"
cp -f "$ROOT/luasrc/model/cbi/woltelegram.lua" "$ST/usr/lib/lua/luci/model/cbi/"
chmod 0644 "$ST/usr/lib/lua/luci/model/cbi/woltelegram.lua"
mkdir -p "$ST/usr/bin"
cp -f "$ROOT/root/usr/bin/woltelegram" "$ST/usr/bin/"
chmod 0755 "$ST/usr/bin/woltelegram"
mkdir -p "$ST/usr/share/woltelegram"
cp -f "$ROOT/root/usr/share/woltelegram/woltg_uci.py" "$ST/usr/share/woltelegram/"
cp -f "$ROOT/root/usr/share/woltelegram/woltg_state.py" "$ST/usr/share/woltelegram/"
cp -f "$ROOT/root/usr/share/woltelegram/woltg_devices.py" "$ST/usr/share/woltelegram/"
cp -f "$ROOT/root/usr/share/woltelegram/woltg_sync.py" "$ST/usr/share/woltelegram/"
cp -f "$ROOT/root/usr/share/woltelegram/woltg_main.py" "$ST/usr/share/woltelegram/"
chmod 0644 "$ST/usr/share/woltelegram/woltg_uci.py" "$ST/usr/share/woltelegram/woltg_state.py" "$ST/usr/share/woltelegram/woltg_devices.py" "$ST/usr/share/woltelegram/woltg_sync.py"
chmod 0755 "$ST/usr/share/woltelegram/woltg_main.py"
mkdir -p "$ST/etc/init.d"
cp -f "$ROOT/root/etc/init.d/woltelegram" "$ST/etc/init.d/"
chmod 0755 "$ST/etc/init.d/woltelegram"
mkdir -p "$ST/usr/lib/systemd/system"
cp -f "$ROOT/root/usr/lib/systemd/system/wol-telegram-handler.service" "$ST/usr/lib/systemd/system/"
chmod 0644 "$ST/usr/lib/systemd/system/wol-telegram-handler.service"
mkdir -p "$ST/etc/config"
cp -f "$ROOT/root/etc/config/woltelegram" "$ST/etc/config/woltelegram"
chmod 0600 "$ST/etc/config/woltelegram"

mkdir -p "$WORKDIR/control"
# Installed-Size в control для OpenWrt/opkg — в байтах (см. SDK: du -sb), не KiB из du -sk.
INST_BYTES=$(du -sb "$ST" | awk '{print $1}')
cat >"$WORKDIR/control/control" <<EOF
Package: $PKG
Version: $VER-$REL
Depends: luci-base, etherwake, curl, python3-light
Source: local
SourceName: $PKG
License: GPL-2.0-or-later
Section: luci
Priority: optional
SourceDateEpoch: $(date +%s)
Maintainer: local
Architecture: $ARCH
Installed-Size: $INST_BYTES
Description: LuCI Telegram: WOL и ping
 LuCI + UCI + procd: бот Wake-on-LAN и статус по ping в Telegram.
 pip на роутере: python-telegram-bot (см. README). Удаление: opkg remove.
EOF

cat >"$WORKDIR/control/postinst" <<'EOS'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/woltelegram 2>/dev/null || true
rm -f /usr/bin/wol-telegram-bot.sh /usr/bin/wol-telegram-handler.py /usr/bin/wol-telegram-sync-chatids.sh 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache 2>/dev/null || true
exit 0
EOS

cat >"$WORKDIR/control/prerm" <<'EOS'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/woltelegram stop >/dev/null 2>&1 || true
/etc/init.d/woltelegram disable >/dev/null 2>&1 || true
exit 0
EOS

cat >"$WORKDIR/control/postrm" <<'EOS'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
rm -f /var/run/wol-telegram.offset /var/run/wol-telegram.offset.py 2>/dev/null || true
rm -f /var/run/wol-telegram-dash-autorefresh.tsv 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache 2>/dev/null || true
exit 0
EOS

chmod 0755 "$WORKDIR/control/postinst" "$WORKDIR/control/prerm" "$WORKDIR/control/postrm"

( cd "$ST" && tar -czf "$WORKDIR/data.tar.gz" . )
( cd "$WORKDIR/control" && tar -czf "$WORKDIR/control.tar.gz" . )
printf '2.0\n' >"$WORKDIR/debian-binary"

# Формат OpenWrt ipk: gzip(tar(debian-binary, data.tar.gz, control.tar.gz)) — не GNU ar
mkdir -p "$WORKDIR/bundle"
cp -f "$WORKDIR/debian-binary" "$WORKDIR/data.tar.gz" "$WORKDIR/control.tar.gz" "$WORKDIR/bundle/"

mkdir -p "$ROOT/bin"
OUT="$ROOT/bin/${PKG}_${VER}-${REL}_${ARCH}.ipk"
rm -f "$OUT"
( cd "$WORKDIR/bundle" && tar -cf - debian-binary data.tar.gz control.tar.gz | gzip -n -9 >"$OUT" )

echo "Собрано: $OUT"
ls -la "$OUT"
file "$OUT"

# Индекс opkg: Size (байты .ipk) и Description — для LuCI/«менеджер пакетов» при src/gz на каталог с .ipk
IPK_BASE=$(basename "$OUT")
IPK_SIZE=$(wc -c <"$OUT")
IPK_SHA=$(sha256sum "$OUT" | awk '{print $1}')
{
	echo "Package: $PKG"
	echo "Version: $VER-$REL"
	echo "Depends: luci-base, etherwake, curl, python3-light"
	echo "License: GPL-2.0-or-later"
	echo "Section: luci"
	echo "Priority: optional"
	echo "Source: local"
	echo "SourceName: $PKG"
	echo "Architecture: $ARCH"
	echo "Installed-Size: $INST_BYTES"
	echo "Filename: $IPK_BASE"
	echo "Size: $IPK_SIZE"
	echo "SHA256sum: $IPK_SHA"
	echo "Description: LuCI Telegram: WOL и ping"
	echo " LuCI + UCI + procd: бот Wake-on-LAN и статус по ping в Telegram."
	echo " pip на роутере: python-telegram-bot (см. README)."
} >"$ROOT/bin/Packages"
gzip -9 -n -c "$ROOT/bin/Packages" >"$ROOT/bin/Packages.gz"
echo "Индекс opkg: $ROOT/bin/Packages (+ .gz)"
