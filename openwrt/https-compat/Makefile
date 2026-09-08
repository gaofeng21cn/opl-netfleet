include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet-https-compat
PKG_VERSION:=0.3.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet-https-compat
  USERID:=netfleet-compat:netfleet-compat
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetFleet optional HTTPS compatibility engine
  DEPENDS:=@aarch64 +opl-netfleet-plugin-https-compat +opl-netfleet-plugin-mihomo +python3 +libc +libstdcpp +libgcc +libopenssl +ca-bundle +coreutils-timeout
  EXTRA_DEPENDS:=python3 (~3.13), opl-netfleet-plugin-https-compat (>=0.8.3)
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
	chmod 0644 $(1)/usr/libexec/opl-netfleet-compat/*.py $(1)/usr/libexec/opl-netfleet-compat/extension.json
	chmod 0755 $(1)/usr/libexec/opl-netfleet-compat $(1)/usr/lib/opl-netfleet-compat
	chmod 0755 $(1)/etc/init.d/opl-netfleet-compat $(1)/usr/libexec/opl-netfleet-compat/mitmdump
endef

define Package/opl-netfleet-https-compat/preinst
#!/bin/sh
if [ -z "$$IPKG_INSTROOT" ] && [ -x /etc/init.d/opl-netfleet-compat ]; then
 /usr/libexec/opl-netfleet-plugin-package https-compat preinst
fi
exit 0
endef

define Package/opl-netfleet-https-compat/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
 /usr/libexec/opl-netfleet-plugin-package https-compat prerm
 /etc/init.d/opl-netfleet-compat disable
}
exit 0
endef

define Package/opl-netfleet-https-compat/postinst
#!/bin/sh
if [ -z "$$IPKG_INSTROOT" ]; then
 # Reproducible packages can retain a stale timestamp-and-size Python cache.
 find /usr/libexec/opl-netfleet-compat /usr/lib/opl-netfleet-compat/vendor -type f -name '*.py[co]' -exec rm -f {} + || exit 1
 /usr/libexec/opl-netfleet-plugin-package https-compat postinst
fi
exit 0
endef

define Package/opl-netfleet-https-compat/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /usr/libexec/opl-netfleet-plugin-package https-compat postrm
exit 0
endef

$(eval $(call BuildPackage,opl-netfleet-https-compat))
