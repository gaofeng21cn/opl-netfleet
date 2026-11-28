include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet
PKG_VERSION:=0.9.36
PKG_RELEASE:=
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=OPL NetFleet

include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OPL NetFleet thin shell and Release Bundle runtime
  PROVIDES:=netfleet-plugin-api-v1
  REPLACES:=opl-netfleet-kernel opl-netfleet-plugin-activation opl-netfleet-plugin-compilation opl-netfleet-plugin-components opl-netfleet-plugin-configuration opl-netfleet-plugin-dashboard opl-netfleet-plugin-events opl-netfleet-plugin-maintenance opl-netfleet-plugin-mihomo opl-netfleet-plugin-models opl-netfleet-plugin-network opl-netfleet-plugin-platform opl-netfleet-plugin-platform-openwrt opl-netfleet-plugin-platform-storage opl-netfleet-plugin-product-ui opl-netfleet-plugin-recovery opl-netfleet-plugin-refresh opl-netfleet-plugin-scheduler opl-netfleet-plugin-selection opl-netfleet-plugin-selection-algorithm opl-netfleet-plugin-setup opl-netfleet-plugin-site-sync opl-netfleet-plugin-status opl-netfleet-plugin-subscriptions
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-socket +ucode-mod-digest +yq +curl +ca-bundle +flock +coreutils-timeout +unzip +ip-full +nftables-json +kmod-nft-socket +kmod-nft-tproxy +usign
  PKGARCH:=all
endef

define Package/opl-netfleet/description
  OPL NetFleet thin OpenWrt runtime shell delivering signed pure-source
  Release Bundles with atomic current symlink switching and instant rollback.
endef

define Build/Compile
endef

define Package/opl-netfleet/install
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/opl-netfleet/policy-sources $(1)/etc/opl-netfleet/extensions
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet $(1)/etc/init.d/opl-netfleet
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet-core $(1)/etc/init.d/opl-netfleet-core
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet-update-recovery $(1)/etc/init.d/opl-netfleet-update-recovery
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy.example.json $(1)/etc/opl-netfleet/policy.example.json
	$(INSTALL_DATA) ./files/etc/opl-netfleet/policy-sources/*.json $(1)/etc/opl-netfleet/policy-sources/
	$(INSTALL_DATA) ./files/etc/opl-netfleet/rulesets.lock.json $(1)/etc/opl-netfleet/rulesets.lock.json

	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/plugins $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/main.uc $(1)/usr/libexec/opl-netfleet/main.uc
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet/supervisor.uc $(1)/usr/libexec/opl-netfleet/supervisor.uc
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet-plugin-package $(1)/usr/libexec/opl-netfleet-plugin-package
	$(INSTALL_BIN) ./files/usr/libexec/opl-netfleet-transfer $(1)/usr/libexec/opl-netfleet-transfer
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/opl-netfleet $(1)/usr/libexec/rpcd/opl-netfleet
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/opl-netfleet.plugins $(1)/usr/libexec/rpcd/opl-netfleet.plugins

	test -f ./bundle-stage/share/build.json && test -f ./bundle.pub && test -f ./shell.json
	$(INSTALL_DIR) $(1)/usr/share/opl-netfleet/releases/$(PKG_VERSION) $(1)/usr/share/opl-netfleet/keys
	$(CP) ./bundle-stage/. $(1)/usr/share/opl-netfleet/releases/$(PKG_VERSION)/
	$(INSTALL_DATA) ./shell.json $(1)/usr/share/opl-netfleet/shell.json
	$(INSTALL_DATA) ./bundle.pub $(1)/usr/share/opl-netfleet/keys/release-bundle.pub
endef

define Package/opl-netfleet/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
main=/usr/libexec/opl-netfleet/main.uc
upgrade_state=/tmp/opl-netfleet-package-upgrade-state
run_step() {
	label="$$1"; shift
	out=$$("$$@" 2>&1) && return 0
	rc=$$?
	printf 'opl-netfleet preinst: %s failed (exit %s): %s\n' "$$label" "$$rc" "$$out" >&2
	return "$$rc"
}
stop_netfleet() {
	if [ -x /etc/init.d/opl-netfleet ] && /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
		run_step "opl-netfleet stop" /etc/init.d/opl-netfleet stop || return 1
	elif [ -x /etc/init.d/opl-netfleet ]; then
		/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || true
	fi
}
stop_core() {
	[ -x /etc/init.d/opl-netfleet-core ] || return 0
	if /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
		run_step "opl-netfleet-core stop" /etc/init.d/opl-netfleet-core stop || return 1
	else
		/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || return 1
	fi
}
is_upgrade=0
[ "$${PKG_UPGRADE:-0}" != 1 ] || is_upgrade=1
[ "$${1:-}" != upgrade ] || is_upgrade=1
[ "$$is_upgrade" = 1 ] || exit 0
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
enabled=0; running=0; core_enabled=0; core_running=0
if [ -x /etc/init.d/opl-netfleet ]; then
	/etc/init.d/opl-netfleet enabled >/dev/null 2>&1 && enabled=1 || true
	/etc/init.d/opl-netfleet running >/dev/null 2>&1 && running=1 || true
fi
if [ "$$backend" = native-mihomo ] && [ -x /etc/init.d/opl-netfleet-core ]; then
	/etc/init.d/opl-netfleet-core enabled >/dev/null 2>&1 && core_enabled=1 || true
	/etc/init.d/opl-netfleet-core running >/dev/null 2>&1 && core_running=1 || true
fi
umask 077
printf '%s %s %s %s %s\n' "$$backend" "$$enabled" "$$running" "$$core_enabled" "$$core_running" >"$$upgrade_state" || exit 1
stop_netfleet || exit 1
if [ "$$backend" = native-mihomo ]; then
	stop_core || exit 1
fi
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	if [ ! -x /etc/init.d/opl-netfleet ] || ! /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
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

define Package/opl-netfleet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
run_step() {
	label="$$1"; shift
	out=$$("$$@" 2>&1) && return 0
	rc=$$?
	printf 'opl-netfleet postinst: %s failed (exit %s): %s\n' "$$label" "$$rc" "$$out" >&2
	return "$$rc"
}
for path in \
	/etc/opl-netfleet/policy.example.json \
	/etc/opl-netfleet/policy-sources/base-v1.json \
	/etc/opl-netfleet/rulesets.lock.json; do
	[ ! -f "$$path.apk-new" ] || mv -f "$$path.apk-new" "$$path" || exit 1
done
bundle_root=$${NETFLEET_BUNDLE_ROOT:-/usr/share/opl-netfleet}
pkg_ver='$(PKG_VERSION)'
if [ -d "$$bundle_root/releases/$$pkg_ver/runtime" ]; then
	mkdir -p "$$bundle_root/releases" /usr/libexec/opl-netfleet/plugins /etc/opl-netfleet/extensions || exit 1
	ucode -e '
		import * as fs from "fs";
		const root = ARGV[0], ver = ARGV[1];
		function swap(link_path, target) {
			const parent = fs.dirname(link_path);
			const tmp = parent + "/." + fs.basename(link_path) + ".next";
			fs.unlink(tmp);
			if (!fs.symlink(target, tmp) || !fs.rename(tmp, link_path)) { fs.unlink(tmp); die("symlink_failed:" + link_path); }
		}
		function ver_ge(a, b) {
			if (b == null) return true;
			const pa = split(a, "."), pb = split(b, ".");
			if (length(pa) != 3 || length(pb) != 3) return true;
			for (let i = 0; i < 3; i++) {
				if (int(pa[i]) != int(pb[i])) return int(pa[i]) > int(pb[i]);
			}
			return true;
		}
		const cur = fs.readlink(root + "/current");
		let cur_ver = null;
		try { cur_ver = json(fs.readfile(root + "/current/share/build.json")).version; } catch (e) {}
		if (cur == null || fs.stat(root + "/current/runtime") == null || ver_ge(ver, cur_ver)) {
			if (cur != null && cur != ("releases/" + ver) && fs.stat(root + "/" + cur + "/share/build.json") != null)
				swap(root + "/previous", cur);
			swap(root + "/current", "releases/" + ver);
		}
		for (let name in ["system.json", "build.json", "nikki", "netfleet.config", "LICENSE.Apache-2.0"]) {
			const p = root + "/" + name;
			const st = fs.lstat(p);
			if (st != null && st.type != "link") {
				if (st.type == "directory") system("rm -rf " + p);
				else fs.unlink(p);
			}
			swap(p, "current/share/" + name);
		}
	' "$$bundle_root" "$$pkg_ver" || exit 1
fi
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
stop_core() {
	[ -x /etc/init.d/opl-netfleet-core ] || return 0
	if /etc/init.d/opl-netfleet-core running >/dev/null 2>&1; then
		run_step "opl-netfleet-core stop" /etc/init.d/opl-netfleet-core stop || return 1
	else
		/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || return 1
	fi
}
is_upgrade=0
[ "$${PKG_UPGRADE:-0}" != 1 ] || is_upgrade=1
[ ! -s "$$upgrade_state" ] || is_upgrade=1
if [ "$$is_upgrade" != 1 ]; then
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
			core_ready=0
			for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
				if core_status=$$(ucode "$$main" native-gateway-status 2>/dev/null) && [ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.ready' 2>/dev/null || true)" = true ]; then
					core_ready=1
					break
				fi
				sleep 1
			done
			[ "$$core_ready" = 1 ] || exit 1
		else
			/etc/init.d/opl-netfleet-core stop >/dev/null 2>&1 || exit 1
			core_status=$$(ucode "$$main" native-gateway-status) || exit 1
			[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.core_running')" = false ] || exit 1
			[ "$$(printf '%s' "$$core_status" | jsonfilter -e '@.result.clean')" = true ] || exit 1
		fi
	else
		stop_core || exit 1
		/etc/init.d/opl-netfleet-core disable >/dev/null 2>&1 || exit 1
	fi
	if [ "$$was_enabled" = 1 ]; then
		/etc/init.d/opl-netfleet enable >/dev/null 2>&1 || exit 1
	else
		/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	fi
	if [ "$$was_running" = 1 ]; then
		NETFLEET_PACKAGE_RESTORE=1 /etc/init.d/opl-netfleet restart >/dev/null 2>&1 || exit 1
		netfleet_running=0
		for attempt in 1 2 3 4 5 6 7 8 9 10; do
			if /etc/init.d/opl-netfleet running >/dev/null 2>&1; then
				netfleet_running=1
				break
			fi
			sleep 1
		done
		[ "$$netfleet_running" = 1 ] || exit 1
	else
		stop_netfleet || exit 1
	fi
	rm -f "$$upgrade_state"
else
	printf '%s\n' 'opl-netfleet: package upgrade state is missing' >&2
	exit 1
fi
if [ -x /etc/init.d/rpcd ]; then
	old_rpcd=$$(pidof rpcd 2>/dev/null || true)
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		cur_rpcd=$$(pidof rpcd 2>/dev/null || true)
		if [ -n "$$cur_rpcd" ] && [ "$$cur_rpcd" != "$$old_rpcd" ] && ubus -v list opl-netfleet >/dev/null 2>&1; then
			break
		fi
		sleep 1
	done
fi
exit 0
endef

define Package/opl-netfleet/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" != 1 ] && [ "$${1:-}" != upgrade ] || exit 0
main=/usr/libexec/opl-netfleet/main.uc
backend=nikki-mihomo
if [ -e /etc/opl-netfleet/backend.json ]; then
	backend=$$(jsonfilter -i /etc/opl-netfleet/backend.json -e '@.kind') || exit 1
fi
if [ "$$backend" = native-mihomo ]; then
	/etc/init.d/opl-netfleet stop >/dev/null 2>&1 || exit 1
	/etc/init.d/opl-netfleet disable >/dev/null 2>&1 || exit 1
	if uci -q get netfleet.config >/dev/null 2>&1; then
		uci set netfleet.config.enabled=0 && uci commit netfleet || exit 1
	fi
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

define Package/opl-netfleet/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" != 1 ] && [ "$${1:-}" != upgrade ] || exit 0
rm -f /usr/share/opl-netfleet/current /usr/share/opl-netfleet/previous \
	/usr/share/opl-netfleet/system.json /usr/share/opl-netfleet/build.json \
	/usr/share/opl-netfleet/nikki /usr/share/opl-netfleet/netfleet.config \
	/usr/share/opl-netfleet/LICENSE.Apache-2.0
rm -rf /usr/share/opl-netfleet/releases /var/run/opl-netfleet-plugin-maintenance \
	/var/lock/opl-netfleet-code /tmp/opl-netfleet-plugin-inspection
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,opl-netfleet))
