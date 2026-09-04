include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netfleet
PKG_VERSION:=0.4.6
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=OPL NetFleet

include $(INCLUDE_DIR)/package.mk

NETFLEET_VIEW_VERSION:=v$(subst .,_,$(PKG_VERSION))

define Package/luci-app-netfleet
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=OPL NetFleet status and recovery interface
  DEPENDS:=+luci-base +opl-netfleet
  PKGARCH:=all
endef

define Package/luci-app-netfleet/description
  Native LuCI status, configuration, and recovery interface for OPL NetFleet.
endef

define Build/Compile
endef

define Package/luci-app-netfleet/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/netfleet
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/netfleet
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./htdocs/luci-static/resources/netfleet/api.js $(1)/www/luci-static/resources/netfleet/api.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/netfleet/config.js $(1)/www/luci-static/resources/netfleet/config.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/netfleet/native.css $(1)/www/luci-static/resources/netfleet/native.css
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/netfleet/overview.js $(1)/www/luci-static/resources/view/netfleet/overview-$(NETFLEET_VIEW_VERSION).js
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-netfleet.json $(1)/usr/share/luci/menu.d/luci-app-netfleet.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-netfleet.json $(1)/usr/share/rpcd/acl.d/luci-app-netfleet.json
endef

define Package/luci-app-netfleet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	changed=0
	rpcd_timeout=$$(uci -q get 'rpcd.@rpcd[0].timeout' 2>/dev/null || true)
	case "$$rpcd_timeout" in
		''|*[!0-9]*) uci set 'rpcd.@rpcd[0].timeout=300' || exit 1; changed=1 ;;
		*) [ "$$rpcd_timeout" -ge 300 ] || { uci set 'rpcd.@rpcd[0].timeout=300' || exit 1; changed=1; } ;;
	esac
	uhttpd_timeout=$$(uci -q get 'uhttpd.main.script_timeout' 2>/dev/null || true)
	case "$$uhttpd_timeout" in
		''|*[!0-9]*) uci set 'uhttpd.main.script_timeout=300' || exit 1; changed=1 ;;
		*) [ "$$uhttpd_timeout" -ge 300 ] || { uci set 'uhttpd.main.script_timeout=300' || exit 1; changed=1; } ;;
	esac
	if [ "$$changed" = 1 ]; then
		uci commit rpcd && uci commit uhttpd || {
			printf '%s\n' 'luci-app-netfleet: cannot configure RPC execution timeout' >&2
			exit 1
		}
	fi
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd restart 2>/dev/null
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-netfleet))
