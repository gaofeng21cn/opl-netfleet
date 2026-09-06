include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet-https-compat
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet-https-compat
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetFleet optional HTTPS compatibility engine
  DEPENDS:=@aarch64 +opl-netfleet +python3 +libstdcpp +libgcc +libopenssl +ca-bundle +coreutils-timeout
  EXTRA_DEPENDS:=python3 (~3.13)
endef

define Package/opl-netfleet-https-compat/description
 Optional transparent HTTPS protocol conversion. Disabled until devices and
 target policies are configured and independently verified.
endef

define Build/Prepare
	test "$(ARCH_PACKAGES)" = aarch64_generic
	test -f "$(NETFLEET_COMPAT_RUNTIME)/vendor/mitmproxy-12.2.3.dist-info/METADATA"
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/vendor
	$(CP) $(NETFLEET_COMPAT_RUNTIME)/vendor/. $(PKG_BUILD_DIR)/vendor/
endef

define Build/Compile
endef

define Package/opl-netfleet-https-compat/install
	$(INSTALL_DIR) $(1)/usr/lib/opl-netfleet-compat/vendor
	$(CP) $(PKG_BUILD_DIR)/vendor/. $(1)/usr/lib/opl-netfleet-compat/vendor/
	$(CP) ./files/. $(1)/
	chmod 0755 $(1)/etc/init.d/opl-netfleet-compat $(1)/usr/libexec/opl-netfleet-compat/mitmdump
endef

define Package/opl-netfleet-https-compat/preinst
#!/bin/sh
if [ -z "$$IPKG_INSTROOT" ] && [ -x /etc/init.d/opl-netfleet-compat ]; then
 /usr/bin/python3 /usr/libexec/opl-netfleet-compat/control.py drain >/dev/null || exit 1
 /etc/init.d/opl-netfleet-compat stop || exit 1
fi
exit 0
endef

define Package/opl-netfleet-https-compat/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
 /usr/bin/python3 /usr/libexec/opl-netfleet-compat/control.py remove >/dev/null || exit 1
 /etc/init.d/opl-netfleet-compat stop
 /etc/init.d/opl-netfleet-compat disable
}
exit 0
endef

$(eval $(call BuildPackage,opl-netfleet-https-compat))
