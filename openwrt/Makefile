include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet
PKG_VERSION:=0.8.10
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=OPL NetFleet

include $(INCLUDE_DIR)/package.mk

NETFLEET_PLUGINS:=$(shell python3 ./plugin-packages.py ids)
ifeq ($(strip $(NETFLEET_PLUGINS)),)
  $(error NetFleet default plugin composition is invalid)
endif

define Package/opl-netfleet-kernel
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OPL NetFleet microkernel
  LICENSE:=Apache-2.0
  PROVIDES:=netfleet-plugin-api-v1
  REPLACES:=opl-netfleet
  DEPENDS:=+ucode +ucode-mod-fs +flock +coreutils-timeout
  PKGARCH:=all
endef

define Package/opl-netfleet-kernel/install
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/kernel $(1)/usr/libexec/opl-netfleet/adapters $(1)/usr/libexec/rpcd $(1)/usr/share/opl-netfleet $(1)/etc/opl-netfleet
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/main.uc $(1)/usr/libexec/opl-netfleet/main.uc
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/supervisor.uc $(1)/usr/libexec/opl-netfleet/supervisor.uc
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/kernel/*.uc $(1)/usr/libexec/opl-netfleet/kernel/
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet/adapters/*.uc $(1)/usr/libexec/opl-netfleet/adapters/
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet-plugin-package $(1)/usr/libexec/opl-netfleet-plugin-package
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/opl-netfleet.plugins $(1)/usr/libexec/rpcd/opl-netfleet.plugins
	$(INSTALL_DATA) ./files/usr/share/opl-netfleet/LICENSE.Apache-2.0 $(1)/usr/share/opl-netfleet/LICENSE.Apache-2.0
endef

define Package/opl-netfleet-kernel/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
main=/usr/libexec/opl-netfleet/main.uc
maintenance=/var/run/opl-netfleet-plugin-maintenance
if [ -f /usr/libexec/opl-netfleet/kernel/host.uc ]; then
	umask 077
	mkdir -p "$$maintenance" /var/lock/opl-netfleet-code || exit 1
	plugins=
	for path in /usr/libexec/opl-netfleet/plugins/*/manifest.json; do
		[ -f "$$path" ] || continue
		id=$${path%/manifest.json}; id=$${id##*/}
		case "$$id" in ""|*[!a-z0-9-]*) exit 1 ;; esac
		plugins="$$plugins $$id"
	done
	printf '%s\n' "$$plugins" >"$$maintenance/.kernel-plugins" || exit 1
	if [ -n "$$plugins" ]; then
		while ! ucode "$$main" plugin-package-drain $$plugins; do sleep 2; done
	fi
	exec 8>/var/lock/opl-netfleet-code/.kernel.lock
	flock 8 || exit 1
	printf '%s\n' replacing >"$$maintenance/.kernel" || exit 1
	exit 0
fi
legacy=/usr/libexec/opl-netfleet/application/native_gateway.uc
[ -f "$$legacy" ] && [ ! -f /usr/libexec/opl-netfleet/kernel/host.uc ] || exit 0
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
if [ ! -s "$$upgrade_state" ]; then
	backend=nikki-mihomo
	[ ! -f /etc/opl-netfleet/backend.json ] || backend=$$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind')
	case "$$backend" in nikki-mihomo|native-mihomo) ;; *) exit 1 ;; esac
	enabled=0; running=0; core_enabled=0; core_running=0
	/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && enabled=1
	/etc/init.d/opl-netfleet running >/dev/null 2>&1 && running=1
	if [ "$$backend" = native-mihomo ]; then
		/etc/init.d/opl-netfleet-core enabled >/dev/null 2>&1 && core_enabled=1
		/etc/init.d/opl-netfleet-core running >/dev/null 2>&1 && core_running=1
	fi
	umask 077
	printf '%s %s %s %s %s\n' "$$backend" "$$enabled" "$$running" "$$core_enabled" "$$core_running" >"$$upgrade_state" || exit 1
fi
read -r backend enabled running core_enabled core_running <"$$upgrade_state"
case "$$backend:$$enabled:$$running:$$core_enabled:$$core_running" in
	nikki-mihomo:[01]:[01]:0:0|native-mihomo:[01]:[01]:[01]:[01]) ;;
	*) exit 1 ;;
esac
# APK may continue after a failed hook. Keep the old files installed until the
# old runtime confirms cleanup, using only the 0.6 migration entrypoint here.
while :; do
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || { sleep 1; continue; }
	/etc/init.d/opl-netfleet running >/dev/null 2>&1 && { sleep 1; continue; }
	if [ "$$backend" = native-mihomo ]; then
		/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || { sleep 1; continue; }
		core_status=$$(ucode "$$legacy" status) || { sleep 1; continue; }
		[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.core_running')" = false ] || { sleep 1; continue; }
		[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.clean')" = true ] || { sleep 1; continue; }
	fi
	break
done
umask 077
printf '%s\n' 0.6 >/tmp/opl-netfleet-microkernel-migration
exit 0
endef

define Package/opl-netfleet-kernel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
maintenance=/var/run/opl-netfleet-plugin-maintenance
if [ -f "$$maintenance/.kernel-plugins" ]; then
	plugins=$$(cat "$$maintenance/.kernel-plugins")
	rm -f "$$maintenance/.kernel" || exit 1
	[ -z "$$plugins" ] || ucode /usr/libexec/opl-netfleet/main.uc plugin-package-resume $$plugins || exit 1
	rm -f "$$maintenance/.kernel-plugins" || exit 1
fi
exit 0
endef

define Package/opl-netfleet
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OPL NetFleet default network platform
  DEPENDS:=+opl-netfleet-kernel $(foreach plugin,$(NETFLEET_PLUGINS),+opl-netfleet-plugin-$(plugin))
  EXTRA_DEPENDS:=opl-netfleet-kernel (>=0.8.1)$(if $(CONFIG_USE_APK),$(comma) !opl-netfleet-https-compat (<0.1.8))
  $(if $(CONFIG_USE_APK),,CONFLICTS:=opl-netfleet-https-compat (<0.1.8))
  PKGARCH:=all
endef

define Package/opl-netfleet/description
  Target-local subscriptions, safe Mihomo profile activation, transparent
  proxying, and one procd-supervised scheduler. Supports Nikki migration.
endef

# Refuse package removal while the generated profile is the live Nikki owner.
# The runtime performs the same guarded disable/readback contract; this hook is
# the last package-manager boundary before files can be deleted.
define Package/opl-netfleet/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
main=/usr/libexec/opl-netfleet/main.uc
backend=nikki-mihomo
if [ -e /etc/opl-netfleet/backend.json ]; then
	backend=$$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || exit 1
fi
if [ "$$backend" = native-mihomo ]; then
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || exit 1
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	uci set netfleet.config.enabled=0 && uci commit netfleet || exit 1
	/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1 || exit 1
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
	for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		core_status=$$(ucode "$$main" native-gateway-status) || exit 1
		core_running=$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.core_running')
		core_clean=$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.clean')
		[ "$$core_running" != false ] || [ "$$core_clean" != true ] || exit 0
		sleep 1
	done
	printf '%s\n' 'opl-netfleet: native core cleanup unconfirmed; refusing removal' >&2
	exit 1
fi
[ "$$backend" = nikki-mihomo ] || exit 1
if [ ! -e /etc/config/nikki ] && [ ! -e /etc/init.d/nikki ]; then
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || true
	exit 0
fi
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
main=/usr/libexec/opl-netfleet/main.uc
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
[ "$${PKG_UPGRADE:-0}" = 1 ] || exit 0
if [ -f /tmp/opl-netfleet-microkernel-migration ] && [ -s "$$upgrade_state" ]; then
	read -r backend enabled running core_enabled core_running <"$$upgrade_state"
	case "$$backend:$$enabled:$$running:$$core_enabled:$$core_running" in
		nikki-mihomo:[01]:[01]:0:0|native-mihomo:[01]:[01]:[01]:[01]) exit 0 ;;
		*) exit 1 ;;
	esac
fi
[ ! -e "$$upgrade_state" ] || {
	printf '%s\n' 'opl-netfleet: previous package state restoration is incomplete' >&2
	exit 1
}
backend=nikki-mihomo
if [ -e /etc/opl-netfleet/backend.json ]; then
	backend=$$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || exit 1
fi
case "$$backend" in nikki-mihomo|native-mihomo) ;; *) exit 1 ;; esac
enabled=0
running=0
core_enabled=0
core_running=0
/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && enabled=1
/etc/init.d/opl-netfleet running >/dev/null 2>&1 && running=1
if [ "$$backend" = native-mihomo ]; then
	/etc/init.d/opl-netfleet-core enabled >/dev/null 2>&1 && core_enabled=1
	/etc/init.d/opl-netfleet-core running >/dev/null 2>&1 && core_running=1
fi
umask 077
printf '%s %s %s %s %s\n' "$$backend" "$$enabled" "$$running" "$$core_enabled" "$$core_running" >"$$upgrade_state" || exit 1
/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || exit 1
if [ "$$backend" = native-mihomo ]; then
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
fi
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	if ! /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
		if [ "$$backend" != native-mihomo ]; then
			exit 0
		fi
		core_status=$$(ucode "$$main" native-gateway-status) || exit 1
		stopped=$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.core_running')
		clean=$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.clean')
		[ "$$stopped" != false ] || [ "$$clean" != true ] || exit 0
	fi
	sleep 1
done
printf '%s\n' 'opl-netfleet: old processes did not stop before upgrade' >&2
exit 1
endef

define Package/opl-netfleet/install
	$(INSTALL_DIR) $(1)/usr/share/opl-netfleet
	$(INSTALL_DATA) ./files/usr/share/opl-netfleet/build.json $(1)/usr/share/opl-netfleet/build.json
	$(INSTALL_DATA) ./files/usr/share/opl-netfleet/system.json $(1)/usr/share/opl-netfleet/system.json
endef

define Package/opl-netfleet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
main=/usr/libexec/opl-netfleet/main.uc
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
	/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
	/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1 || exit 1
	rm -f "$$upgrade_state"
elif [ -s "$$upgrade_state" ]; then
	read -r backend was_enabled was_running core_enabled core_running <"$$upgrade_state"
	case "$$backend:$$was_enabled:$$was_running:$$core_enabled:$$core_running" in
		nikki-mihomo:[01]:[01]:0:0|native-mihomo:[01]:[01]:[01]:[01]) ;;
		*) exit 1 ;;
	esac
	if [ "$$backend" = native-mihomo ]; then
		if [ "$$core_enabled" = 1 ]; then
			/etc/init.d/opl-netfleet-core enable >/dev/null 2>&1 || exit 1
		else
			/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1 || exit 1
		fi
		if [ "$$core_running" = 1 ]; then
			NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/opl-netfleet-core restart >/dev/null 2>&1 || exit 1
			core_status=$$(ucode "$$main" native-gateway-status) || exit 1
			[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.ready')" = true ] || exit 1
		else
			/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
			core_status=$$(ucode "$$main" native-gateway-status) || exit 1
			[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.core_running')" = false ] || exit 1
			[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.clean')" = true ] || exit 1
		fi
	else
		/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
		/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1 || exit 1
	fi
	if [ "$$was_enabled" = 1 ]; then
		/etc/init.d/opl-netfleet enable >/dev/null 2>&1 || exit 1
	else
		/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	fi
	if [ "$$was_running" = 1 ]; then
		NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/opl-netfleet restart >/dev/null 2>&1 || exit 1
		/etc/init.d/opl-netfleet running >/dev/null 2>&1 || exit 1
	else
		stop_netfleet || exit 1
	fi
	rm -f "$$upgrade_state"
	rm -f /tmp/opl-netfleet-microkernel-migration
else
	printf '%s\n' 'opl-netfleet: package upgrade state is missing' >&2
	exit 1
fi
exit 0
endef

define PluginFiles/platform-openwrt
	$(INSTALL_DIR) $(1)/usr/share/opl-netfleet
	$(INSTALL_DATA) ./files/etc/config/netfleet $(1)/usr/share/opl-netfleet/netfleet.config
endef

define PluginFiles/mihomo
	$(INSTALL_DIR) $(1)/usr/share/opl-netfleet/nikki $(1)/etc/init.d
	$(INSTALL_DATA) ./files/usr/share/opl-netfleet/nikki/* $(1)/usr/share/opl-netfleet/nikki/
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet-core $(1)/etc/init.d/opl-netfleet-core
endef

define PluginFiles/configuration
	$(INSTALL_DIR) $(1)/etc/opl-netfleet/policy-sources
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy.example.json $(1)/etc/opl-netfleet/policy.example.json
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy-sources/*.json $(1)/etc/opl-netfleet/policy-sources/
	$(INSTALL_DATA) ./files/etc/opl-netfleet/rulesets.lock.json $(1)/etc/opl-netfleet/rulesets.lock.json
endef

define PluginFiles/components
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet-update-recovery $(1)/etc/init.d/opl-netfleet-update-recovery
endef

define PluginFiles/maintenance
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet-transfer $(1)/usr/libexec/opl-netfleet-transfer
endef

define PluginFiles/status
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/opl-netfleet $(1)/usr/libexec/rpcd/opl-netfleet
endef

define PluginFiles/scheduler
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet $(1)/etc/init.d/opl-netfleet
endef

define NetFleetServicePlugin
define Package/opl-netfleet-plugin-$(1)
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OPL NetFleet $(1) service plugin
  LICENSE:=$(if $(filter mihomo,$(1)),GPL-3.0-only,Apache-2.0)
  VERSION:=$(shell python3 ./plugin-packages.py version $(1))-r$(PKG_RELEASE)
  REPLACES:=opl-netfleet
  DEPENDS:=+opl-netfleet-kernel $(shell python3 ./plugin-packages.py dependencies $(1))
  EXTRA_DEPENDS:=$(if $(filter product-ui,$(1)),opl-netfleet-kernel (>=0.8.8)$(comma) luci-app-netfleet (>=0.8.4),$(if $(filter maintenance,$(1)),opl-netfleet-kernel (>=0.8.1)))
  PKGARCH:=all
endef

define Package/opl-netfleet-plugin-$(1)/install
	$$(INSTALL_DIR) $$(1)/usr/libexec/opl-netfleet/plugins/$(1)
	$$(CP) ./files/usr/libexec/opl-netfleet/plugins/$(1)/. $$(1)/usr/libexec/opl-netfleet/plugins/$(1)/
	python3 ./plugin_payload.py project ./files/usr/libexec/opl-netfleet/plugins/$(1) $$(1)/www
$(call PluginFiles/$(1),$$(1))
endef

define Package/opl-netfleet-plugin-$(1)/preinst
#!/bin/sh
[ -n "$$$${IPKG_INSTROOT}" ] && exit 0
exec /usr/libexec/opl-netfleet-plugin-package $(1) preinst
endef

define Package/opl-netfleet-plugin-$(1)/prerm
#!/bin/sh
[ -n "$$$${IPKG_INSTROOT}" ] && exit 0
exec /usr/libexec/opl-netfleet-plugin-package $(1) prerm
endef

define Package/opl-netfleet-plugin-$(1)/postinst
#!/bin/sh
[ -n "$$$${IPKG_INSTROOT}" ] && exit 0
exec /usr/libexec/opl-netfleet-plugin-package $(1) postinst
endef

define Package/opl-netfleet-plugin-$(1)/postrm
#!/bin/sh
[ -n "$$$${IPKG_INSTROOT}" ] && exit 0
exec /usr/libexec/opl-netfleet-plugin-package $(1) postrm
endef
endef

$(foreach plugin,$(NETFLEET_PLUGINS),$(eval $(call NetFleetServicePlugin,$(plugin))))

define Package/opl-netfleet-plugin-configuration/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
for path in \
	/etc/opl-netfleet/policy.example.json \
	/etc/opl-netfleet/policy-sources/base-v1.json \
	/etc/opl-netfleet/rulesets.lock.json; do
	[ ! -f "$$path.apk-new" ] || mv -f "$$path.apk-new" "$$path" || exit 1
done
exec /usr/libexec/opl-netfleet-plugin-package configuration postinst
endef

define Package/opl-netfleet-plugin-mihomo/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/opl-netfleet-plugin-package mihomo postrm || exit 1
[ "$${PKG_UPGRADE:-0}" != 1 ] && [ "$${1:-}" != upgrade ] || exit 0
rm -f /var/run/opl-netfleet-mihomo-handoff/state.json || exit 1
[ ! -d /var/run/opl-netfleet-mihomo-handoff ] || rmdir /var/run/opl-netfleet-mihomo-handoff
endef

$(eval $(call BuildPackage,opl-netfleet-kernel))
$(foreach plugin,$(NETFLEET_PLUGINS),$(eval $(call BuildPackage,opl-netfleet-plugin-$(plugin))))
$(eval $(call BuildPackage,opl-netfleet))
