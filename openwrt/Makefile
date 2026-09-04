include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet
PKG_VERSION:=0.4.6
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OPL NetFleet

include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OPL NetFleet minimal enhancement layer
  DEPENDS:=+ucode +yq +mihomo
  PKGARCH:=all
endef

define Package/opl-netfleet/description
  Target-local Nikki discovery, safe profile activation, and one
  procd-supervised scheduler for an OpenWrt + Nikki + Mihomo enhancement layer.
endef

# Refuse package removal while the generated profile is the live Nikki owner.
# The runtime performs the same guarded disable/readback contract; this hook is
# the last package-manager boundary before files can be deleted.
define Package/opl-netfleet/prerm
#!/bin/sh
main=/usr/libexec/opl-netfleet/main.uc
active_profile=$$(uci -q get nikki.config.profile 2>/dev/null) || {
	printf '%s\n' 'opl-netfleet: cannot inspect Nikki profile; refusing removal' >&2
	exit 1
}
is_netfleet_profile() {
	[ "$$1" = "file:OPL-NetFleet.json" ] || [ "$$1" = "file:opl-netfleet/mvp.json" ]
}

[ -x "$$main" ] || {
	! is_netfleet_profile "$$active_profile" && exit 0
	printf '%s\n' 'opl-netfleet: active profile but runtime is unavailable; refusing removal' >&2
	exit 1
}

# Always use the owner implementation: a failed restart can leave UCI naming a
# native Profile while the old Mihomo process still serves NetFleet groups.
if ! ucode "$$main" disable >/dev/null; then
	printf '%s\n' 'opl-netfleet: disable/readback failed; refusing removal' >&2
	exit 1
fi

active_profile=$$(uci -q get nikki.config.profile 2>/dev/null) || exit 1
! is_netfleet_profile "$$active_profile" || {
	printf '%s\n' 'opl-netfleet: NetFleet profile remains active; refusing removal' >&2
	exit 1
}
/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || true
if ! ucode "$$main" package-cleanup >/dev/null; then
	printf '%s\n' 'opl-netfleet: generated artifact cleanup failed; refusing removal' >&2
	exit 1
fi
exit 0
endef

define Build/Compile
endef

define Package/opl-netfleet/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
rm -f "$$upgrade_state"
if [ "$${PKG_UPGRADE:-0}" = 1 ] && [ -x /etc/init.d/opl-netfleet ]; then
	enabled=0
	running=0
	/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && enabled=1
	/etc/init.d/opl-netfleet running >/dev/null 2>&1 && running=1
	printf '%s %s\n' "$$enabled" "$$running" >"$$upgrade_state"
fi
exit 0
endef

define Package/opl-netfleet/install
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/application
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/core
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/adapters
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_DIR) $(1)/etc/opl-netfleet
	$(INSTALL_DIR) $(1)/etc/opl-netfleet/policy-sources
	$(INSTALL_DIR) $(1)/usr/share/opl-netfleet
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/main.uc $(1)/usr/libexec/opl-netfleet/main.uc
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/supervisor.uc $(1)/usr/libexec/opl-netfleet/supervisor.uc
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/output.uc $(1)/usr/libexec/opl-netfleet/output.uc
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/application/*.uc $(1)/usr/libexec/opl-netfleet/application/
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/core/*.uc $(1)/usr/libexec/opl-netfleet/core/
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/adapters/*.uc $(1)/usr/libexec/opl-netfleet/adapters/
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/opl-netfleet $(1)/usr/libexec/rpcd/opl-netfleet
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet $(1)/etc/init.d/opl-netfleet
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy.example.json $(1)/etc/opl-netfleet/policy.example.json
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy-sources/*.json $(1)/etc/opl-netfleet/policy-sources/
	$(INSTALL_DATA) ./files/etc/opl-netfleet/rulesets.lock.json $(1)/etc/opl-netfleet/rulesets.lock.json
	$(INSTALL_DATA) ./files/usr/share/opl-netfleet/build.json $(1)/usr/share/opl-netfleet/build.json
endef

define Package/opl-netfleet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
for path in \
	/etc/opl-netfleet/policy.example.json \
	/etc/opl-netfleet/policy-sources/base-v1.json \
	/etc/opl-netfleet/rulesets.lock.json; do
	[ ! -f "$$path.apk-new" ] || mv -f "$$path.apk-new" "$$path" || exit 1
done
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
stop_netfleet() {
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
	for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		/etc/init.d/opl-netfleet running >/dev/null 2>&1 || return 0
		sleep 1
	done
	return 1
}
if [ "$${PKG_UPGRADE:-0}" != 1 ]; then
	stop_netfleet || exit 1
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	rm -f "$$upgrade_state"
elif [ -s "$$upgrade_state" ]; then
	read -r was_enabled was_running <"$$upgrade_state"
	rm -f "$$upgrade_state"
	[ "$$was_enabled" = 1 ] || /etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	[ "$$was_running" = 1 ] || stop_netfleet || exit 1
fi
exit 0
endef

$(eval $(call BuildPackage,opl-netfleet))
