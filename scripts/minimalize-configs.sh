#!/bin/bash
# =============================================================================
#  R28S FriendlyWrt 25.12 极简配置裁剪脚本（稳妥尺度）
# -----------------------------------------------------------------------------
#  作用
#    在 `repo sync` 之后、`./build.sh friendlywrt` 之前，就地修改官方
#    `configs/rockchip/` 下的配置，把与 NanoPi R28S 硬件无关、或与
#    MIMI / Mihomo 冲突的组件从镜像里剔除。
#
#  已核对的官方机制（决定了本脚本的裁剪策略）
#    1) scripts/package-metadata.pl:309-318
#       非 hidden 包的 Kconfig 默认值被定义为
#           default m if ALL || ALL_NONSHARED || ALL_KMODS
#       —— 也就是说 CONFIG_ALL_KMODS=y / CONFIG_ALL_NONSHARED=y 只会让包变成
#       `=m`（参与编译、**不装入镜像**）。
#       **只有显式 `=y` 的包才会进入 rootfs。**
#       因此：本脚本不尝试关闭 ALL_KMODS（官方 mk-friendlywrt.sh 还会强制追加
#       `CONFIG_ALL_KMODS=y`），也不动 ALL_NONSHARED —— 它们不影响镜像体积。
#    2) scripts/mk-friendlywrt.sh
#       会把 configs/<TARGET_FRIENDLYWRT_CONFIG>/ 下 **所有文件**按 `ls` 顺序
#       追加进 .config，然后 `echo CONFIG_ALL_KMODS=y >> .config`。
#       → 推论 A：裁剪后目录里不得残留任何备份文件（会二次注入配置）。
#       → 推论 B：把不需要的包写成 `# CONFIG_PACKAGE_x is not set`
#                （显式关闭优先级高于 default，既剔除镜像又省编译时间）。
#    3) 凡被保留下来的包真正依赖的项，`make defconfig` 会自动补回，
#       不会造成依赖缺失；漏掉的只是一点空间。
#
#  边界（不做的事）
#    * 不改主题（luci-theme-*）、不改 LuCI 布局与页面结构
#    * 不改分区参数、不改 U-Boot / DTS / 启动链
#    * 不删任何被保留包依赖的公共库（libuci / libubox / liblua / libcurl 等）
#    * 不删 PPPoE 相关（luci-proto-ppp / kmod-pppoe 属 WAN 拨号能力）
#
#  用法
#    bash minimalize-configs.sh [configs/rockchip 目录]      # 默认 configs/rockchip
# =============================================================================
set -eu

CFG_DIR="${1:-configs/rockchip}"
if [ ! -d "${CFG_DIR}" ]; then
	echo "ERROR: 找不到配置目录 ${CFG_DIR}" >&2
	exit 1
fi
cd "${CFG_DIR}"

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

for f in 01-nanopi 02-luci_lang 03-custom 04-utils 05-wifi; do
	[ -f "${f}" ] || { echo "ERROR: 缺少配置文件 ${f}" >&2; exit 1; }
	cp -f "${f}" "${TMPD}/${f}.orig"
done

echo "==================== 裁剪前（行数） ===================="
wc -l 01-nanopi 02-luci_lang 03-custom 04-utils 05-wifi

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
# 把 CONFIG_PACKAGE_<pkg>=y 显式关闭（=y → `# ... is not set`）
exclude_pkg() {
	local pkg
	for pkg in "$@"; do
		sed -i -E "s|^CONFIG_PACKAGE_${pkg}=y\$|# CONFIG_PACKAGE_${pkg} is not set|" 01-nanopi
	done
}

# 删除某个前缀开头的配置项（用于子选项，例如 CONFIG_ARIA2_*、CONFIG_SAMBA4_*）
drop_prefix() {
	local key
	for key in "$@"; do
		sed -i -E "/^${key}/d" 01-nanopi
	done
}

# 在 02/04/05 里把 CONFIG_PACKAGE_<pkg>=y 显式关闭
exclude_pkg_in() {
	local file="$1"; shift
	local pkg
	for pkg in "$@"; do
		sed -i -E "s|^CONFIG_PACKAGE_${pkg}=y\$|# CONFIG_PACKAGE_${pkg} is not set|" "${file}"
	done
}

# =============================================================================
#  A. 第三方 DNS 与广告过滤 —— 与 MIMI/Mihomo 的 DNS 接管直接冲突
#     smartdns 会自建上游并抢占 53 端口；adblock 依赖 dnsmasq 额外钩子。
#     MIMI 需要的是「OpenWrt 原生 dnsmasq（dnsmasq-full）+ odhcpd」，故这两组必须剔除。
# =============================================================================
exclude_pkg smartdns luci-app-smartdns adblock luci-app-adblock

# =============================================================================
#  B. NAS / 文件共享（任务书第十八条：删 NAS / Samba）
#     Samba4 + WSD 发现 + Avahi(mDNS) 是一整套，Avahi 还会额外拉起 dbus。
# =============================================================================
exclude_pkg luci-app-samba4 samba4-server samba4-libs wsdd2 \
	avahi-dbus-daemon libavahi-client libavahi-dbus-support
drop_prefix "CONFIG_SAMBA4_"

# =============================================================================
#  C. 媒体服务器（任务书：删媒体服务器 / Jellyfin 一类）
#     minidlna 及其专用解码库；libexif / libjpeg-turbo 可能被其它保留包引用，不动。
# =============================================================================
exclude_pkg luci-app-minidlna minidlna libffmpeg-audio-dec \
	libflac libogg libvorbis libid3tag

# =============================================================================
#  D. 下载器（任务书：删下载器）
# =============================================================================
exclude_pkg luci-app-aria2 aria2 aria2-openssl
drop_prefix "CONFIG_ARIA2_"

# =============================================================================
#  E. 开发环境 / 编辑器 / 调试器（任务书：删开发环境）
#     git 体积可观；vim-full 由 vim-runtime 支撑，一并剔除（BusyBox 自带 vi 仍可用）。
#     注：gcc/g++/make/python/perl/php/node 等官方 non-docker 配置本就不含，
#        它们属于 SDK/IB，官方 CI 已用 custome_config.sh 关闭 CONFIG_SDK / CONFIG_IB。
# =============================================================================
exclude_pkg git git-http strace vim-full vim-runtime

# =============================================================================
#  F. 基准测试 / 压测工具 —— 非路由与 MIMI 所需
# =============================================================================
exclude_pkg coremark iperf iperf3 libiperf3
drop_prefix "CONFIG_COREMARK_"

# =============================================================================
#  G. 监控统计与 RRD（任务书：不需要的数据库）
#     collectd 全家桶（十余个子包）与已保留的 nlbwmon 功能重复。
#     用前缀删除以便一次命中 collectd 与 collectd-mod-*。
# =============================================================================
drop_prefix "CONFIG_PACKAGE_collectd"
exclude_pkg luci-app-statistics rrdtool1 librrd1

# =============================================================================
#  H. FTP 服务（任务书：不需要 FTP）—— SSH 由 dropbear 提供，不受影响
# =============================================================================
exclude_pkg vsftpd

# =============================================================================
#  I. USB Modem / 蜂窝网络栈（任务书：删不属于 R28S 的 USB Modem 驱动）
#     ⚠️ 绝对不能删 luci-proto-ppp / kmod-pppoe —— 那是 PPPoE 宽带拨号（WAN 能力）。
#     这里清掉的是：QMI/MBIM 模组、USB 串口切换，以及 PPP 的冷门变体
#     （PPPoA / PPPoL2TP / PPTP / L2TP / RADIUS）。
# =============================================================================
exclude_pkg comgt umbim uqmi qmi-utils libqmi libmbim libqrtr-glib wwan \
	usb-modeswitch-official \
	kmod-usb-net-qmi-wwan kmod-usb-net-cdc-mbim kmod-usb-wdm \
	luci-proto-3g luci-proto-qmi \
	kmod-mppe kmod-pppoa kmod-pppol2tp kmod-pptp kmod-l2tp \
	kmod-atm linux-atm \
	ppp-mod-pppoa ppp-mod-pppol2tp ppp-mod-pptp ppp-mod-radius ppp-mod-passwordfd
drop_prefix "CONFIG_LIBQMI_"

# =============================================================================
#  J. 非板载无线内核模块（Broadcom）
#     R28S 板载无线为 AIC8800（device/friendlyelec/rk3528/aic8800），非 Broadcom。
# =============================================================================
exclude_pkg kmod-brcmfmac kmod-brcmutil brcmfmac-firmware-usb

# =============================================================================
#  K. 04-utils：无 PCIe 插槽，pciutils / pciids 无用
# =============================================================================
: > 04-utils
cat > 04-utils <<'UTILS_EOF'
# R28S Minimal: 无 PCIe 插槽，移除 pciutils / pciids（官方默认开启）
UTILS_EOF

# =============================================================================
#  L. 05-wifi：板载无线为 AIC8800，剔除全部外置无线网卡固件
#     （iwlwifi-ax200 / iwlwifi-ax210 / rtl8822be / rtl8822ce / mt76x2 / mt792x）
# =============================================================================
cat > 05-wifi <<'WIFI_EOF'
# R28S Minimal: 板载无线为 AIC8800，无需外置无线网卡固件（官方默认全开）
# 已移除: iwlwifi-firmware-ax200, iwlwifi-firmware-ax210, rtl8822be-firmware,
#         rtl8822ce-firmware, mt76x2-firmware, mt792x-firmware
WIFI_EOF

# =============================================================================
#  M. 02-luci_lang：官方 26 种 → 仅 en / zh_Hans / zh_Hant
# =============================================================================
cat > 02-luci_lang <<'LANG_EOF'
# R28S Minimal: 仅保留 en / 简体中文 / 繁体中文（官方默认 26 种界面语言）
CONFIG_LUCI_LANG_en=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_LUCI_LANG_zh_Hant=y
LANG_EOF

# =============================================================================
#  裁剪后统计
# =============================================================================
echo "==================== 裁剪后（行数） ===================="
wc -l 01-nanopi 02-luci_lang 03-custom 04-utils 05-wifi

# =============================================================================
#  断言 1：MIMI / Mihomo 与基础路由所必需的组件必须仍为 =y
#         任一缺失即中止（宁可不出镜像，也不交付缺依赖的固件）。
# =============================================================================
echo "==================== 断言 1：必需项仍为 =y ===================="
REQUIRED=(
	"CONFIG_PACKAGE_dnsmasq-full=y"
	"CONFIG_PACKAGE_dnsmasq_full_dhcpv6=y"
	"CONFIG_PACKAGE_dnsmasq_full_nftset=y"
	"CONFIG_PACKAGE_lua=y"
	"CONFIG_PACKAGE_libuci-lua=y"
	"CONFIG_PACKAGE_libubus-lua=y"
	"CONFIG_PACKAGE_luci-lua-runtime=y"
	"CONFIG_PACKAGE_luci-lib-nixio=y"
	"CONFIG_PACKAGE_luci-lib-jsonc=y"
	"CONFIG_PACKAGE_luci-lib-ip=y"
	"CONFIG_PACKAGE_coreutils-timeout=y"
	"CONFIG_PACKAGE_rpcd=y"
	"CONFIG_PACKAGE_uhttpd=y"
	"CONFIG_PACKAGE_luci-app-package-manager=y"
	"CONFIG_PACKAGE_luci-app-firewall=y"
	"CONFIG_PACKAGE_luci-app-nlbwmon=y"
	"CONFIG_PACKAGE_nlbwmon=y"
	"CONFIG_PACKAGE_luci-proto-ipv6=y"
	"CONFIG_PACKAGE_luci-proto-ppp=y"
	"CONFIG_PACKAGE_kmod-tun=y"
	"CONFIG_PACKAGE_kmod-wireguard=y"
	"CONFIG_PACKAGE_kmod-nft-tproxy=y"
	"CONFIG_PACKAGE_kmod-ipt-tproxy=y"
	"CONFIG_PACKAGE_kmod-nft-socket=y"
	"CONFIG_PACKAGE_kmod-nft-bridge=y"
	"CONFIG_PACKAGE_luci-theme-bootstrap=y"
	"CONFIG_PACKAGE_wireless-regdb=y"
	"CONFIG_PACKAGE_hostapd-common=y"
	"CONFIG_PACKAGE_wpa-supplicant-openssl=y"
	"CONFIG_PACKAGE_iw=y"
	"CONFIG_PACKAGE_wifi-scripts=y"
	"CONFIG_PACKAGE_luci-mod-admin-full=y"
	"CONFIG_PACKAGE_luci-mod-network=y"
	"CONFIG_PACKAGE_luci-mod-system=y"
)
FAIL=0
for key in "${REQUIRED[@]}"; do
	if grep -qx "${key}" 01-nanopi; then
		echo "  OK   ${key}"
	else
		echo "  MISS ${key}" >&2
		FAIL=1
	fi
done
[ "${FAIL}" -eq 0 ] || { echo "" >&2; echo "ERROR: 有必需组件在裁剪后被移除，已中止。" >&2; exit 1; }

# =============================================================================
#  断言 2：被剔除的组件在 01-nanopi 里不能再残留 =y
# =============================================================================
echo "==================== 断言 2：剔除项已无残留 =y ===================="
MUST_BE_GONE=(
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
	kmod-brcmfmac kmod-brcmutil
)
for pkg in "${MUST_BE_GONE[@]}"; do
	if grep -qx "CONFIG_PACKAGE_${pkg}=y" 01-nanopi; then
		echo "  STILL-ON ${pkg}" >&2
		FAIL=1
	fi
done
[ "${FAIL}" -eq 0 ] && echo "  OK   全部剔除项均已关闭"
[ "${FAIL}" -eq 0 ] || { echo "ERROR: 仍有剔除项残留 =y，已中止。" >&2; exit 1; }

# =============================================================================
#  输出删除清单（供报告使用；写到 /tmp，绝不留在 configs 目录）
# =============================================================================
{
	echo ""
	echo "==================== 删除清单（按配置来源分类） ===================="
	for f in 01-nanopi 02-luci_lang 04-utils 05-wifi; do
		echo ""
		echo "--- ${f} ---"
		diff "${TMPD}/${f}.orig" "${f}" 2>/dev/null | grep '^<' | sed 's/^< /  - /' || true
	done
} | tee "${TMPD}/removed.txt"
cp -f "${TMPD}/removed.txt" /tmp/r28s-removed.txt

echo ""
echo "OK: 裁剪完成，断言全部通过。"
