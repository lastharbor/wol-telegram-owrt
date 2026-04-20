#
# OpenWrt: luci-app-wol-telegram (в дерево package/ или feed)
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wol-telegram
PKG_VERSION:=1.0
PKG_RELEASE:=46

PKG_MAINTAINER:=local
PKG_LICENSE:=GPL-2.0-or-later

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-wol-telegram
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=Telegram WOL + status (/wol /status)
	DEPENDS:=+luci-base +etherwake +curl +python3-light
	PKGARCH:=all
endef

define Package/luci-app-wol-telegram/description
	LuCI и UCI для Telegram-бота: Wake-on-LAN и статус по ping.
	Обработчик: Python (python-telegram-bot), opkg не ставит pip-пакет — установите вручную: pip3 install 'python-telegram-bot>=21,<23'.
	Удаление пакета (opkg remove) снимает init, LuCI и конфиг, см. prerm/postrm.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./luasrc ./root $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/luci-app-wol-telegram/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/controller/woltelegram.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/luasrc/model/cbi/woltelegram.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/woltelegram $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/share/woltelegram
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/woltelegram/woltg_uci.py $(1)/usr/share/woltelegram/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/woltelegram/woltg_state.py $(1)/usr/share/woltelegram/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/woltelegram/woltg_devices.py $(1)/usr/share/woltelegram/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/woltelegram/woltg_sync.py $(1)/usr/share/woltelegram/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/share/woltelegram/woltg_main.py $(1)/usr/share/woltelegram/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/woltelegram $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/usr/lib/systemd/system
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/lib/systemd/system/wol-telegram-handler.service $(1)/usr/lib/systemd/system/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/root/etc/config/woltelegram $(1)/etc/config/woltelegram
endef

define Package/luci-app-wol-telegram/postinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0
chmod 600 /etc/config/woltelegram 2>/dev/null || true
uci -q get woltelegram.main.log_max_preset >/dev/null 2>&1 || uci set woltelegram.main.log_max_preset=256
uci -q get woltelegram.main.log_max_kb >/dev/null 2>&1 || uci set woltelegram.main.log_max_kb=256
uci commit woltelegram 2>/dev/null || true
rm -f /usr/bin/wol-telegram-bot.sh /usr/bin/wol-telegram-handler.py /usr/bin/wol-telegram-sync-chatids.sh 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache 2>/dev/null || true
exit 0
endef

define Package/luci-app-wol-telegram/prerm
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0
/etc/init.d/woltelegram stop >/dev/null 2>&1 || true
/etc/init.d/woltelegram disable >/dev/null 2>&1 || true
exit 0
endef

define Package/luci-app-wol-telegram/postrm
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0
rm -f /var/run/wol-telegram.offset /var/run/wol-telegram.offset.py 2>/dev/null || true
rm -f /var/run/wol-telegram-dash-autorefresh.tsv 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-wol-telegram))
