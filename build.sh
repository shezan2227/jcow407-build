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
# LuCI here is the ucode build: /www/cgi-bin/luci is a ucode script, so uhttpd
# NEEDS uhttpd-mod-ucode. Without it every LuCI request returns 403.
CONFIG_PACKAGE_uhttpd-mod-ucode=y
CONFIG_PACKAGE_uhttpd-mod-cgi=y

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
CONFIG_PACKAGE_kmod-8021q=y
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

# ---------------------------------------------------------------------------
# Persistent configuration.
#
# This image boots as squashfs with an overlayfs-on-tmpfs, so EVERY uci/LuCI
# change is lost on reboot. There is a persistent UBIFS volume on the NAND
# ("config_data", /dev/ubi0_0) - it currently holds the stock Jio/TR-069 files.
# We mount it early and bind-mount our own subdirectory over /etc/config (and
# /etc/dropbear), so configuration survives reboots and the SSH host key stays
# stable. Stock files in that volume are left untouched.
# ---------------------------------------------------------------------------
mkdir -p files/etc/init.d
cat > files/etc/init.d/xpon-persist <<'INITEOF'
#!/bin/sh /etc/rc.common

START=09
STOP=89

XCFG=/mnt/xponcfg
STORE="$XCFG/openwrt"

wait_for_ubi() {
	local i=0
	while [ $i -lt 30 ]; do
		[ -e /dev/ubi0_0 ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

start() {
	mkdir -p "$XCFG"
	wait_for_ubi || {
		logger -t xpon-persist "no /dev/ubi0_0, config will NOT persist"
		return 0
	}
	grep -q " $XCFG " /proc/mounts || mount -t ubifs /dev/ubi0_0 "$XCFG" || {
		logger -t xpon-persist "ubifs mount failed, config will NOT persist"
		return 0
	}

	mkdir -p "$STORE/config" "$STORE/dropbear" "$STORE/modules.d"

	# First boot: seed the persistent store from the read-only image defaults.
	if [ ! -f "$STORE/config/network" ]; then
		cp -af /etc/config/. "$STORE/config/" 2>/dev/null
		logger -t xpon-persist "seeded persistent config from image defaults"
	fi
	if [ ! -f "$STORE/dropbear/dropbear_ed25519_host_key" ] &&
	   [ -f /etc/dropbear/dropbear_ed25519_host_key ]; then
		cp -af /etc/dropbear/. "$STORE/dropbear/" 2>/dev/null
	fi
	if [ ! -f "$STORE/modules.d/90-econet-eth" ] && [ -f /etc/modules.d/90-econet-eth ]; then
		cp -af /etc/modules.d/. "$STORE/modules.d/" 2>/dev/null
	fi

	if mount --bind "$STORE/config" /etc/config; then
		logger -t xpon-persist "/etc/config is persistent (ubifs $STORE/config)"
	fi
	mount --bind "$STORE/dropbear" /etc/dropbear 2>/dev/null
	mount --bind "$STORE/modules.d" /etc/modules.d 2>/dev/null
	sync
}

stop() {
	sync
	umount /etc/config 2>/dev/null
	umount /etc/dropbear 2>/dev/null
	umount /etc/modules.d 2>/dev/null
}
INITEOF
chmod +x files/etc/init.d/xpon-persist

# Generic GPON ONT defaults + editable VLAN/PPPoE WAN.
cat > files/etc/uci-defaults/99-xpon-setup <<'XEOF'
#!/bin/sh
# 1) /etc/modules.d/91-econet-xpon autoloads the driver with NO identity, then
#    /etc/init.d/econet-xpon rmmod+insmods it WITH the identity. The second
#    registration collides on /proc entries and oopses on every boot, so let the
#    init script be the only thing that loads the module.
rm -f /etc/modules.d/91-econet-xpon

# 2) Generic ONT: identity left EMPTY so any ISP's serial number / PLOAM
#    password / WAN MAC can be entered in LuCI -> Services -> ECONET xPON.
#    Nothing Jio/ISP specific is hardcoded.
uci -q delete econet-xpon.identity
uci set econet-xpon.identity=econet-xpon
uci set econet-xpon.identity.gpon_sn=''
uci set econet-xpon.identity.gpon_pw=''
uci set econet-xpon.identity.wan_mac=''
uci commit econet-xpon

# 3) Editable 802.1q VLAN device on the GPON WAN netdev, with PPPoE on top.
#    The VID, device and PPPoE credentials all stay editable in LuCI.
uci -q delete network.vlanwan
uci set network.vlanwan=device
uci set network.vlanwan.name='ponwan0.1015'
uci set network.vlanwan.type='8021q'
uci set network.vlanwan.ifname='ponwan0'
uci set network.vlanwan.vid='1015'

uci -q delete network.wan
uci set network.wan=interface
uci set network.wan.device='ponwan0.1015'
uci set network.wan.proto='pppoe'

uci -q delete network.wan6
uci set network.wan6=interface
uci set network.wan6.device='ponwan0.1015'
uci set network.wan6.proto='dhcpv6'

uci commit network
exit 0
XEOF
chmod +x files/etc/uci-defaults/99-xpon-setup

# LuCI web UI repair.
cat > files/etc/uci-defaults/98-luci-fix <<'LEOF'
#!/bin/sh
# The stock uhttpd config ships a Lua handler prefix for the old Lua LuCI:
#   list lua_prefix '/cgi-bin/luci=/usr/lib/lua/luci/sgi/uhttpd.lua'
# This image has the ucode LuCI and no uhttpd Lua module, so that prefix
# pointed /cgi-bin/luci at a file that does not exist and every single LuCI
# request came back 403 Forbidden (the web UI was unusable). Drop it - uhttpd
# then serves /www/cgi-bin/luci (the ucode dispatcher) itself.
uci -q delete uhttpd.main.lua_prefix
uci commit uhttpd

# Leftover placeholder login section with an invalid hash ("$p$root").
uci -q delete rpcd.@login[0]
uci commit rpcd

exit 0
LEOF
chmod +x files/etc/uci-defaults/98-luci-fix

make defconfig
make "-j$(nproc)" V=s 2>&1 | tee build.log

# Normalise output names so the .trx is easy to find:
#   openwrt-snapshot-<date>-econet-<rest>  ->  openwrt-econet-<rest>
cd ./bin/targets/econet/en7528 || exit 1
ls | sed -n -e 's/openwrt-snapshot-\(.*\)-econet-\(.*\)/mv openwrt-snapshot-\1-econet-\2 openwrt-econet-\2/p' | sh
ls -la
