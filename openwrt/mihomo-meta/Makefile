include $(TOPDIR)/rules.mk

# Reuse Nikki's package identity and alternatives; the core is upstream-built.
core_field = $(shell python3 -c 'import json; print(json.load(open("$(CURDIR)/source.json"))["$(1)"])')
PKG_NAME:=mihomo-meta
PKG_VERSION:=$(call core_field,version)
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_SOURCE:=$(call core_field,filename)
PKG_SOURCE_URL:=$(dir $(call core_field,url))
PKG_HASH:=$(call core_field,sha256)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/mihomo-meta
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Mihomo proxy core (official prebuilt)
  URL:=https://github.com/MetaCubeX/mihomo
  DEPENDS:=@aarch64 +ca-bundle +ip-full +kmod-inet-diag +kmod-tun
  PROVIDES:=mihomo
  CONFLICTS:=mihomo-alpha
  ALTERNATIVES:=300:/usr/bin/mihomo:/usr/libexec/mihomo
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) >$(PKG_BUILD_DIR)/mihomo
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/mihomo-meta/install
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/usr/share/mihomo-meta
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mihomo $(1)/usr/libexec/mihomo
	$(INSTALL_DATA) ./source.json $(1)/usr/share/mihomo-meta/source.json
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/mihomo-meta/LICENSE
endef

$(eval $(call BuildPackage,mihomo-meta))
