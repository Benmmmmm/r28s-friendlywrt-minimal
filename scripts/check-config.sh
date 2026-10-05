#!/bin/bash
# =============================================================================
#  R28S FriendlyWrt 25.12 静态检查（对最终 .config）
# -----------------------------------------------------------------------------
#  用法:  bash check-config.sh <friendlywrt/.config 路径>
#
#  说明
#    这里检查的是 OpenWrt 的 .config（构建配置），不是运行中的系统。
#    因此「DTS / U-Boot / 启动链」这类只存在于内核与 sd-fuse 侧的项目，
#    只能在此处核对相关 Kconfig 开关是否存在，**不能替代实机验证**。
#    按任务书要求：本脚本只做静态检查，不宣称任何实机结论。
# =============================================================================
set -eu

CFG="${1:?用法: bash check-config.sh <friendlywrt/.config>}"
[ -f "${CFG}" ] || { echo "ERROR: 找不到 .config: ${CFG}" >&2; exit 1; }

TOTAL=0
HIT=0

has() {
	# 精确匹配整行
	if grep -qxF "$1" "${CFG}"; then
		printf '  [OK]      %s\n' "$1"
		HIT=$((HIT + 1))
	else
		printf '  [MISSING] %s\n' "$1"
	fi
	TOTAL=$((TOTAL + 1))
}

has_re() {
	if grep -qE "$1" "${CFG}"; then
		printf '  [OK]      %s\n' "$2"
		HIT=$((HIT + 1))
	else
		printf '  [MISSING] %s\n' "$2"
	fi
	TOTAL=$((TOTAL + 1))
}

echo "######################################################################"
echo "#  R28S FriendlyWrt 25.12 静态检查"
echo "#  配置文件: ${CFG}"
echo "######################################################################"

echo ""
echo "== 1. 目标与架构 ====================================================="
has "CONFIG_TARGET_rockchip=y"
has "CONFIG_TARGET_rockchip_armv8=y"
has_re '^CONFIG_TARGET_ARCH_PACKAGES="aarch64[^"]*"' 'CONFIG_TARGET_ARCH_PACKAGES="aarch64*"'
has_re '^CONFIG_TARGET_OPTIMIZATION=.*cortex-a53' 'CONFIG_TARGET_OPTIMIZATION="... cortex-a53 ..."'

echo ""
echo "== 2. OpenWrt 基础系统（procd / ubus / uci / rpcd / netifd / uhttpd）=="
has "CONFIG_PACKAGE_busybox=y"
has "CONFIG_PACKAGE_procd=y"
has "CONFIG_PACKAGE_ubus=y"
has "CONFIG_PACKAGE_uci=y"
has "CONFIG_PACKAGE_rpcd=y"
has "CONFIG_PACKAGE_netifd=y"
has "CONFIG_PACKAGE_uhttpd=y"
has "CONFIG_PACKAGE_logd=y"
has "CONFIG_PACKAGE_dropbear=y"

echo ""
echo "== 3. IPv4 / IPv6 ==================================================="
has "CONFIG_IPV6=y"
has "CONFIG_PACKAGE_odhcpd-ipv6only=y"
has "CONFIG_PACKAGE_odhcp6c=y"
has "CONFIG_PACKAGE_luci-proto-ipv6=y"
has "CONFIG_PACKAGE_kmod-nf-conntrack6=y"

echo ""
echo "== 4. 防火墙 fw4 / nftables ========================================="
has "CONFIG_PACKAGE_firewall4=y"
has "CONFIG_PACKAGE_luci-app-firewall=y"
has "CONFIG_PACKAGE_nftables-json=y"
has "CONFIG_PACKAGE_kmod-nf-tables=y"
has "CONFIG_PACKAGE_kmod-nf-conntrack=y"
has "CONFIG_PACKAGE_kmod-nft-core=y"
has "CONFIG_PACKAGE_kmod-nft-nat=y"

echo ""
echo "== 5. DNS（OpenWrt 原生体系）========================================"
has "CONFIG_PACKAGE_dnsmasq-full=y"
has "CONFIG_PACKAGE_dnsmasq_full_dhcp=y"
has "CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y"
has "CONFIG_PACKAGE_dnsmasq_full_nftset=y"

echo ""
echo "== 6. LuCI =========================================================="
has "CONFIG_PACKAGE_luci=y"
has "CONFIG_PACKAGE_luci-base=y"
has "CONFIG_PACKAGE_luci-mod-admin-full=y"
has "CONFIG_PACKAGE_luci-mod-network=y"
has "CONFIG_PACKAGE_luci-mod-system=y"
has "CONFIG_PACKAGE_luci-mod-status=y"
has "CONFIG_PACKAGE_luci-theme-bootstrap=y"
has "CONFIG_PACKAGE_luci-lua-runtime=y"

echo ""
echo "== 7. APK / Lua / UCI / UBus（MIMI 后续安装前提）====================="
has_re '^CONFIG_PACKAGE_apk[-=]' 'CONFIG_PACKAGE_apk-*'
has_re '^CONFIG_USE_APK=y' 'CONFIG_USE_APK=y'
has "CONFIG_PACKAGE_lua=y"
has "CONFIG_PACKAGE_uci=y"
has "CONFIG_PACKAGE_libuci-lua=y"
has "CONFIG_PACKAGE_libubus-lua=y"
has "CONFIG_PACKAGE_luci-lib-nixio=y"
has "CONFIG_PACKAGE_luci-lib-jsonc=y"
has "CONFIG_PACKAGE_luci-lib-ip=y"
has "CONFIG_PACKAGE_coreutils-timeout=y"
has "CONFIG_PACKAGE_luci-app-package-manager=y"
has "CONFIG_PACKAGE_tar=y"
has "CONFIG_PACKAGE_gzip=y"
has "CONFIG_PACKAGE_file=y"
has_re '^CONFIG_PACKAGE_(curl|wget-ssl)=y' 'CONFIG_PACKAGE_curl=y 或 wget-ssl=y'

echo ""
echo "== 8. Wi-Fi 基础组件（板载 AIC8800，用户空间侧）======================"
has "CONFIG_PACKAGE_wifi-scripts=y"
has "CONFIG_PACKAGE_hostapd-common=y"
has "CONFIG_PACKAGE_wpa-supplicant-openssl=y"
has "CONFIG_PACKAGE_iw=y"
has "CONFIG_PACKAGE_iwinfo=y"
has "CONFIG_PACKAGE_libiwinfo=y"
has "CONFIG_PACKAGE_wireless-regdb=y"
has "CONFIG_PACKAGE_kmod-cfg80211=y"
has_re '^CONFIG_PACKAGE_kmod-mac80211=y' 'CONFIG_PACKAGE_kmod-mac80211=y'

echo ""
echo "== 9. 双网口相关（用户空间侧）======================================="
has "CONFIG_PACKAGE_r8169-firmware=y"
has "CONFIG_PACKAGE_ethtool=y"

echo ""
echo "== 10. MIMI / Mihomo 相关能力 ======================================="
has "CONFIG_PACKAGE_kmod-tun=y"
has "CONFIG_PACKAGE_kmod-wireguard=y"
has "CONFIG_PACKAGE_kmod-nft-tproxy=y"
has "CONFIG_PACKAGE_kmod-ipt-tproxy=y"
has "CONFIG_PACKAGE_kmod-nft-socket=y"
has "CONFIG_PACKAGE_kmod-nft-bridge=y"
has "CONFIG_PACKAGE_kmod-veth=y"
has "CONFIG_PACKAGE_kmod-ifb=y"
has "CONFIG_PACKAGE_nlbwmon=y"
has "CONFIG_PACKAGE_luci-app-nlbwmon=y"

echo ""
echo "== 11. 应已被剔除的组件（不得为 =y）================================"
GONE=(
	smartdns luci-app-smartdns adblock luci-app-adblock
	luci-app-samba4 samba4-server samba4-libs wsdd2 avahi-dbus-daemon
	luci-app-minidlna minidlna
	luci-app-aria2 aria2
	git git-http strace vim-full
	coremark iperf iperf3
	luci-app-statistics rrdtool1
	vsftpd
	comgt umbim uqmi qmi-utils libqmi
	luci-proto-3g luci-proto-qmi
	kmod-brcmfmac kmod-brcmutil brcmfmac-firmware-usb
	iwlwifi-firmware-ax200 iwlwifi-firmware-ax210
	rtl8822be-firmware rtl8822ce-firmware mt76x2-firmware mt792x-firmware
	pciutils pciids
)
GONE_BAD=0
for p in "${GONE[@]}"; do
	if grep -qxF "CONFIG_PACKAGE_${p}=y" "${CFG}"; then
		printf '  [STILL-ON] CONFIG_PACKAGE_%s=y\n' "${p}"
		GONE_BAD=$((GONE_BAD + 1))
	elif grep -qxF "CONFIG_PACKAGE_${p}=m" "${CFG}"; then
		printf '  [ =m ]     CONFIG_PACKAGE_%s=m   (已不装入镜像，仅参与编译)\n' "${p}"
	else
		printf '  [ =n ]     CONFIG_PACKAGE_%s   (未选中)\n' "${p}"
	fi
done

echo ""
echo "== 12. 统计 ========================================================="
N_Y=$(grep -cE '^CONFIG_PACKAGE_[^=]+=y$' "${CFG}" || true)
N_M=$(grep -cE '^CONFIG_PACKAGE_[^=]+=m$' "${CFG}" || true)
N_N=$(grep -cE '^# CONFIG_PACKAGE_[^ ]+ is not set$' "${CFG}" || true)
echo "  装入镜像的包 (=y)        : ${N_Y}"
echo "  仅编译不装入的包 (=m)    : ${N_M}"
echo "  显式关闭的包 (is not set): ${N_N}"
echo "  内核版本相关："
grep -E '^CONFIG_LINUX_[0-9_]+=y$' "${CFG}" | sed 's/^/    /' || true
grep -E '^CONFIG_KERNEL_GIT=.*' "${CFG}" | head -1 | sed 's/^/    /' || true

echo ""
echo "== 13. 检查结论 ====================================================="
echo "  关键项命中: ${HIT} / ${TOTAL}"
if [ "${GONE_BAD}" -ne 0 ]; then
	echo "  ⚠️  有 ${GONE_BAD} 个应剔除项仍为 =y（多为被保留包的真实依赖，属正常回补）"
fi
if [ "${HIT}" -eq "${TOTAL}" ]; then
	echo "  ✅ 全部关键项存在"
else
	echo "  ⚠️  有 $((TOTAL - HIT)) 项缺失，请核对上方 [MISSING] 列表"
fi
echo ""
echo "  提醒：以上为静态检查结果。启动链、双网口、Wi-Fi、Bluetooth、IPv6、"
echo "        DHCP/DHCPv6 的实际可用性必须由用户在实机上验证。"
