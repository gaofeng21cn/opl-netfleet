include $(TOPDIR)/rules.mk
PKG_NAME:=opl-netfleet-plugin-device-identity
PKG_VERSION:=0.2.3
PKG_RELEASE:=
PKG_LICENSE:=Apache-2.0
include $(INCLUDE_DIR)/package.mk

define Package/opl-netfleet-plugin-device-identity
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetFleet local device address source
  DEPENDS:=+opl-netfleet-kernel +netfleet-plugin-api-v1 +ucode +ucode-mod-fs +ucode-mod-digest +ip-full +conntrack +coreutils-timeout
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/neighbor.c ./src/atomic-replace.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror \
		$(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/neighbor $(PKG_BUILD_DIR)/neighbor.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) -Wall -Wextra -Werror \
		$(TARGET_LDFLAGS) -o $(PKG_BUILD_DIR)/atomic-replace $(PKG_BUILD_DIR)/atomic-replace.c
endef

define Package/opl-netfleet-plugin-device-identity/install
	$(INSTALL_DIR) $(1)/usr/libexec/opl-netfleet/plugins/device-identity/resources
	$(INSTALL_BIN) ./files/control $(1)/usr/libexec/opl-netfleet/plugins/device-identity/control
	$(INSTALL_DATA) ./files/manifest.json $(1)/usr/libexec/opl-netfleet/plugins/device-identity/manifest.json
	$(INSTALL_DATA) ./files/resources/identity.uc $(1)/usr/libexec/opl-netfleet/plugins/device-identity/resources/identity.uc
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/atomic-replace $(1)/usr/libexec/opl-netfleet/plugins/device-identity/resources/atomic-replace
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/neighbor $(1)/usr/libexec/opl-netfleet/plugins/device-identity/resources/neighbor
endef

define Package/opl-netfleet-plugin-device-identity/preinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /usr/libexec/opl-netfleet-plugin-package device-identity preinst
endef

define Package/opl-netfleet-plugin-device-identity/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /usr/libexec/opl-netfleet-plugin-package device-identity postinst
endef

define Package/opl-netfleet-plugin-device-identity/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /usr/libexec/opl-netfleet-plugin-package device-identity prerm
endef

define Package/opl-netfleet-plugin-device-identity/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /usr/libexec/opl-netfleet-plugin-package device-identity postrm
endef

$(eval $(call BuildPackage,opl-netfleet-plugin-device-identity))
