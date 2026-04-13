include $(TOPDIR)/rules.mk

PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=hexsen929

LUCI_TITLE:=LuCI support for OpenWrt-K online upgrade
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +curl +ca-bundle +ca-certificates
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot only
