include $(TOPDIR)/rules.mk

PKG_NAME:=opl-netfleet-https-compat
PKG_VERSION:=0.5.3
PKG_RELEASE:=1
PKG_LICENSE:=MIT GPL-2.0-or-later LGPL-2.1-only
HAPROXY_VERSION:=3.2.21
PKG_SOURCE:=haproxy-$(HAPROXY_VERSION).tar.gz
PKG_SOURCE_URL:=https://www.haproxy.org/download/3.2/src/
PKG_HASH:=0cb8818a26c5f888e0cb1c40f1b3acb9fb952527d1733f769ce688fedd680339
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet-https-compat
  USERID:=netfleet-compat:netfleet-compat
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetFleet optional HTTPS compatibility engine
  DEPENDS:=+opl-netfleet-plugin-https-compat +opl-netfleet-plugin-mihomo +ucode +ucode-mod-fs +ucode-mod-digest +ucode-mod-socket +ucode-mod-uloop +libopenssl +libpthread +libatomic +openssl-util +ca-bundle +coreutils-timeout
  EXTRA_DEPENDS:=opl-netfleet-plugin-https-compat (>=0.9.1), opl-netfleet-plugin-mihomo (>=0.8.6)
endef

define Package/opl-netfleet-https-compat/description
 Optional transparent HTTPS protocol conversion. Disabled until devices and
 target policies are configured and independently verified.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xzf $(DL_DIR)/$(PKG_SOURCE)
	$(CP) ./src/*.c $(PKG_BUILD_DIR)/
	$(Build/Patch)
endef

MAKE_FLAGS += TARGET=linux-musl CC="$(TARGET_CC)" LD="$(TARGET_CC)" \
	CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" \
	SSL_INC="$(STAGING_DIR)/usr/include" SSL_LIB="$(STAGING_DIR)/usr/lib" \
	USE_OPENSSL=1 USE_THREAD=1 USE_LUA= USE_PCRE= USE_PCRE2= \
	USE_ZLIB= USE_SLZ= USE_SYSTEMD= USE_QUIC= USE_PROMEX=

define Build/Compile
	$(call Build/Compile/Default)
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror $(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/port-range $(PKG_BUILD_DIR)/port-range.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror $(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/launcher $(PKG_BUILD_DIR)/launcher.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror $(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/tls-probe $(PKG_BUILD_DIR)/tls-probe.c -lssl -lcrypto
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror $(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/atomic-replace $(PKG_BUILD_DIR)/atomic-replace.c
endef

define Package/opl-netfleet-https-compat/install
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet-compat $(1)/etc/init.d
	$(INSTALL_DATA) ./files/usr/libexec/opl-netfleet-compat/*.uc ./files/usr/libexec/opl-netfleet-compat/extension.json $(1)/usr/libexec/opl-netfleet-compat/
	$(INSTALL_BIN) ./files/etc/init.d/opl-netfleet-compat $(1)/etc/init.d/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/launcher $(PKG_BUILD_DIR)/tls-probe $(PKG_BUILD_DIR)/atomic-replace $(1)/usr/libexec/opl-netfleet-compat/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/port-range $(1)/usr/libexec/opl-netfleet-compat/port-range
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/haproxy $(1)/usr/libexec/opl-netfleet-compat/haproxy
	$(INSTALL_DIR) $(1)/usr/share/licenses/opl-netfleet-https-compat
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(PKG_BUILD_DIR)/doc/gpl.txt $(PKG_BUILD_DIR)/doc/lgpl.txt $(1)/usr/share/licenses/opl-netfleet-https-compat/
	chmod 0644 $(1)/usr/libexec/opl-netfleet-compat/*.uc $(1)/usr/libexec/opl-netfleet-compat/extension.json
	chmod 0755 $(1)/usr/libexec/opl-netfleet-compat $(1)/etc/init.d/opl-netfleet-compat
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
