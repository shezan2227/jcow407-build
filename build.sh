#!/bin/sh
# Build OpenWrt EN7528 GPON firmware for the JioFiber JCOW407.
# Source tree: AKoo7/openwrt-econet-gpon (branch h660gm-a-gpon-o5) which adds the
# native xPON/GPON MAC + optical PHY driver (package/kernel/econet-xpon) and the
# LuCI identity page (package/luci/luci-app-econet-xpon).
set -e

git clone --depth 1 --single-branch --branch h660gm-a-gpon-o5 \
  https://github.com/AKoo7/openwrt-econet-gpon.git openwrt
cd openwrt || exit 1

./scripts/feeds update -a
./scripts/feeds install -a

cat > .config <<'EOF'
CONFIG_TARGET_econet=y
CONFIG_TARGET_econet_en7528=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_econet_en7528_DEVICE_jio_jcow407=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
CONFIG_IMAGEOPT=y

# --- GPON / fiber WAN stack (the whole point) ---
CONFIG_PACKAGE_kmod-econet-xpon=y
CONFIG_PACKAGE_luci-app-econet-xpon=y
CONFIG_PACKAGE_luci=y

# --- WAN PPPoE over the PON netdev ---
CONFIG_PACKAGE_ppp=y
CONFIG_PACKAGE_ppp-mod-pppoe=y
CONFIG_PACKAGE_luci-proto-ppp=y

# --- basics (kept from the previous working build) ---
CONFIG_PACKAGE_ca-bundle=y
CONFIG_PACKAGE_openssl-util=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_kmod-usb-core=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_wpad-basic-mbedtls=y
EOF

# Seed an editable tr069 interface (unmanaged / proto=none) so it shows up in
# LuCI -> Network -> Interfaces and can be edited. NOT tied to any Jio ACS.
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-tr069 <<'UCIEOF'
#!/bin/sh
uci -q delete network.tr069
uci set network.tr069=interface
uci set network.tr069.proto='none'
uci commit network
exit 0
UCIEOF
chmod +x files/etc/uci-defaults/99-tr069

make defconfig
make "-j$(nproc)" V=s 2>&1 | tee build.log

# Normalise output names so the .trx is easy to find:
#   openwrt-snapshot-<date>-econet-<rest>  ->  openwrt-econet-<rest>
cd ./bin/targets/econet/en7528 || exit 1
ls | sed -n -e 's/openwrt-snapshot-\(.*\)-econet-\(.*\)/mv openwrt-snapshot-\1-econet-\2 openwrt-econet-\2/p' | sh
ls -la
