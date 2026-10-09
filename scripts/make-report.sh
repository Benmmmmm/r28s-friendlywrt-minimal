#!/bin/bash
# =============================================================================
#  生成 R28S FriendlyWrt 25.12 Minimal 构建报告
# -----------------------------------------------------------------------------
#  用法:  bash make-report.sh <BUILD_ROOT> <DIST_DIR>
#
#  产出（全部写入 DIST_DIR）：
#    R28S-FriendlyWrt-25.12-Minimal.img.gz          最终镜像（gzip 压缩）
#    R28S-FriendlyWrt-25.12-Minimal.img.gz.sha256   校验值
#    REPORT.md                                      完整报告
#    installed-packages.txt                         装入镜像的包清单
#    removed-packages.txt                           显式剔除的包清单
#    firmware-list.txt                              rootfs 内的固件清单
#    static-check.txt                               静态检查结果
#    minimal-.config                                本次使用的构建配置
# =============================================================================
set -eu

# 出错时精确报出失败行（set -e 静默退出时，这是唯一的定位线索）
trap 'echo "ERROR: make-report.sh 第 ${LINENO} 行失败 (退出码 $?): ${BASH_COMMAND}" >&2' ERR

BUILD_ROOT="${1:?用法: make-report.sh <BUILD_ROOT> <DIST_DIR>}"
DIST="${2:?用法: make-report.sh <BUILD_ROOT> <DIST_DIR>}"
PROJECT="${BUILD_ROOT}/project"

IMG_NAME="${IMG_NAME:-R28S-FriendlyWrt-25.12-Minimal.img}"
DIST_DIRNAME="${DIST_DIRNAME:-friendlywrt25}"
OFFICIAL_ASSET="${OFFICIAL_ASSET:-R28S-Zero2-NEO3Plus-Series-FriendlyWrt-25.12.img.gz}"

mkdir -p "${DIST}"

# ---- 定位产物 ---------------------------------------------------------------
# 注意：project/out 是符号链接（-> scripts/sd-fuse/out）。`-f`/`ls` 会自动跟随，
# 但 `find` 默认不跟随，需用 `find -L` 或 readlink -f 解析（曾因此误报找不到产物）。
IMG_SRC="${PROJECT}/out/${IMG_NAME}"
if [ ! -f "${IMG_SRC}" ]; then
	echo "WARN: 未找到 ${IMG_SRC}，改为搜索 out/*.img" >&2
	IMG_SRC="$(find -L "${PROJECT}/out" -maxdepth 1 -name '*.img' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2)" || true
fi
[ -n "${IMG_SRC}" ] && [ -f "${IMG_SRC}" ] || { echo "ERROR: 找不到最终 .img" >&2; exit 1; }
echo "最终镜像: ${IMG_SRC}"

# ---- 体积统计 ---------------------------------------------------------------
IMG_BYTES=$(stat -c %s "${IMG_SRC}")
IMG_HUMAN=$(numfmt --to=iec --suffix=B "${IMG_BYTES}" 2>/dev/null || echo "${IMG_BYTES}B")

SDFUSE_OUT="${PROJECT}/scripts/sd-fuse/${DIST_DIRNAME}"
part_size() {
	local f="$1"
	if [ -f "${f}" ]; then
		local b; b=$(stat -c %s "${f}")
		# 必须以 \n 结尾：调用方用 `read -r a b < <(part_size ...)` 读取，
		# 无换行时 read 在 EOF 返回 1，配合 set -e 会静默中止整个脚本（run#2/#4 的真凶）。
		printf '%s\t%s\n' "$(numfmt --to=iec --suffix=B "${b}" 2>/dev/null || echo ${b}B)" "${b}"
	else
		printf -- '-\t-\n'
	fi
}

ROOTFS_DIR="$(ls -d "${PROJECT}"/friendlywrt/build_dir/target-*/root-* 2>/dev/null | head -1 || true)"
ROOTFS_DU="-"
[ -n "${ROOTFS_DIR}" ] && ROOTFS_DU=$(du -sh "${ROOTFS_DIR}" 2>/dev/null | cut -f1 || echo "-")

KERNEL_IMG="${PROJECT}/out/resource.img"
[ -f "${KERNEL_IMG}" ] || KERNEL_IMG="${SDFUSE_OUT}/boot.img"

# ---- 收集镜像并压缩 ---------------------------------------------------------
# 官方 sd-fuse（mk-sd-image.sh）收尾时已在 out/ 内生成同名 .img.gz。
# 直接复用它，避免把 3.5GB 裸镜像再复制+压缩一遍（既慢又易触发 runner 资源上限）。
GZ_PATH="${DIST}/${IMG_NAME}.gz"
OFFICIAL_GZ="${PROJECT}/out/${IMG_NAME}.gz"

if [ -f "${OFFICIAL_GZ}" ]; then
	echo "复用官方已生成的压缩包: ${OFFICIAL_GZ}"
	cp -f "${OFFICIAL_GZ}" "${GZ_PATH}"
else
	echo "官方 .gz 缺失，自行压缩…"
	cp -f "${IMG_SRC}" "${DIST}/${IMG_NAME}"
	IMG_LINE=$(sha256sum "${DIST}/${IMG_NAME}" | awk '{print $1}')
	# -1 = 最低压缩级别：内存占用小、速度快，镜像最终仍会 gzip，体积差异可接受
	if ! gzip -1 -f "${DIST}/${IMG_NAME}" ; then
		echo "ERROR: gzip 压缩失败（镜像 ${IMG_HUMAN}），已保留未压缩 .img" >&2
		exit 1
	fi
fi

GZ_BYTES=$(stat -c %s "${GZ_PATH}")
GZ_HUMAN=$(numfmt --to=iec --suffix=B "${GZ_BYTES}" 2>/dev/null || echo "${GZ_BYTES}B")
GZ_SHA=$(sha256sum "${GZ_PATH}" | awk '{print $1}')
echo "${GZ_SHA}  $(basename "${GZ_PATH}")" > "${DIST}/${IMG_NAME}.gz.sha256"

# 未压缩镜像的 sha256（3.58GB，耗时较长；失败不影响主流程）
IMG_LINE="-"
IMG_LINE=$(sha256sum "${IMG_SRC}" 2>/dev/null | awk '{print $1}') \
	|| { IMG_LINE="-"; echo "WARN: 计算未压缩镜像 sha256 失败（不影响交付物）"; }

# ---- 官方基线 ---------------------------------------------------------------
OFFICIAL_TAG="-"
OFFICIAL_BYTES=0
cat > /tmp/get_official.py <<'PY'
import json, os, sys, urllib.request
proxy = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY")
opener = (urllib.request.build_opener(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
          if proxy else urllib.request.build_opener())
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/friendlyarm/Actions-FriendlyWrt/releases/latest",
        headers={"User-Agent": "curl/8.4", "Accept": "application/vnd.github+json"})
    with opener.open(req, timeout=45) as r:
        d = json.load(r)
    target = sys.argv[1]
    size = next((a["size"] for a in d.get("assets", []) if a["name"] == target), 0)
    print(f'{d.get("tag_name","-")}\t{size}')
except Exception as exc:  # 网络失败不影响主流程
    print(f"-\t0")
PY
OFFICIAL_LINE=$(python3 /tmp/get_official.py "${OFFICIAL_ASSET}" 2>/dev/null || printf -- '-\t0')
OFFICIAL_TAG=$(printf '%s' "${OFFICIAL_LINE}" | cut -f1)
OFFICIAL_BYTES=$(printf '%s' "${OFFICIAL_LINE}" | cut -f2)
[ "${OFFICIAL_BYTES}" = "0" ] && OFFICIAL_BYTES=207564300   # 兜底：FriendlyWrt-2026-08-07 实测值

if [ "${OFFICIAL_BYTES}" -gt 0 ] 2>/dev/null; then
	DIFF_BYTES=$((GZ_BYTES - OFFICIAL_BYTES))
	DIFF_HUMAN=$(numfmt --to=iec --suffix=B "${DIFF_BYTES}" 2>/dev/null || echo "${DIFF_BYTES}B")
	PCT=$(awk -v a="${GZ_BYTES}" -v b="${OFFICIAL_BYTES}" 'BEGIN{printf "%.1f%%", (a-b)*100.0/b}')
	OFFICIAL_HUMAN=$(numfmt --to=iec --suffix=B "${OFFICIAL_BYTES}" 2>/dev/null || echo "${OFFICIAL_BYTES}B")
else
	DIFF_HUMAN="-" ; PCT="-" ; OFFICIAL_HUMAN="-"
fi

# ---- 包清单 -----------------------------------------------------------------
MANIFEST=$(find "${PROJECT}/friendlywrt/bin/targets" -name '*.manifest' 2>/dev/null | head -1 || true)
if [ -n "${MANIFEST}" ] && [ -f "${MANIFEST}" ]; then
	cp -f "${MANIFEST}" "${DIST}/$(basename "${MANIFEST}")"
	cp -f "${MANIFEST}" "${DIST}/installed-packages.txt"
	N_INSTALLED=$(wc -l < "${MANIFEST}")
else
	N_INSTALLED="-"
fi

# APK 数据库（OpenWrt 25.12+）
APK_DB=$(find "${PROJECT}/friendlywrt/build_dir" -path '*/usr/lib/apk/db/installed' 2>/dev/null | head -1 || true)
if [ -n "${APK_DB}" ]; then
	awk -F: '/^P:/{p=$2} /^V:/{print p"\t"$2}' "${APK_DB}" | sort > "${DIST}/apk-installed.txt"
	echo "APK 包数量: $(wc -l < "${DIST}/apk-installed.txt")"
fi

CFG="${PROJECT}/friendlywrt/.config"
if [ -f "${CFG}" ]; then
	cp -f "${CFG}" "${DIST}/minimal-.config"
	N_Y=$(grep -cE '^CONFIG_PACKAGE_[^=]+=y$' "${CFG}" || true)
	N_M=$(grep -cE '^CONFIG_PACKAGE_[^=]+=m$' "${CFG}" || true)
	N_N=$(grep -cE '^# CONFIG_PACKAGE_[^ ]+ is not set$' "${CFG}" || true)
else
	N_Y="-"; N_M="-"; N_N="-"
fi

[ -f /tmp/r28s-removed.txt ] && cp -f /tmp/r28s-removed.txt "${DIST}/removed-packages.txt" || true
[ -f "${BUILD_ROOT}/static-check.txt" ] && cp -f "${BUILD_ROOT}/static-check.txt" "${DIST}/static-check.txt" || true

# ---- 固件清单 ---------------------------------------------------------------
: > "${DIST}/firmware-list.txt"
if [ -n "${ROOTFS_DIR}" ] && [ -d "${ROOTFS_DIR}/lib/firmware" ]; then
	(cd "${ROOTFS_DIR}/lib/firmware" && find . -type f -printf '%s\t%p\n' 2>/dev/null \
		| sort -rn | awk '{printf "%8.1f KB  %s\n", $1/1024, $2}') > "${DIST}/firmware-list.txt" || true
fi
N_FW=$(wc -l < "${DIST}/firmware-list.txt")

# ---- 内核 / U-Boot / DTS ----------------------------------------------------
kver() {
	local mk="$1"
	if [ -f "${mk}" ]; then
		awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} /^EXTRAVERSION =/{e=$2}
			END{printf "%s.%s.%s%s", v, p, s, e}' "${mk}"
	else
		echo "-"
	fi
}
KVER=$(kver "${PROJECT}/kernel/Makefile")
UBOOTVER=$(kver "${PROJECT}/u-boot/Makefile")

DTS_LIST=$(ls "${PROJECT}/kernel/arch/arm64/boot/dts/rockchip/" 2>/dev/null | grep -iE 'rk3528|r28s|zero2|neo3' | tr '\n' ' ' || true)
[ -n "${DTS_LIST}" ] || DTS_LIST="(未在内核 DTS 目录找到 rk3528 文件，见下方说明)"

OPENWRT_VER=$(grep -m1 '^CONFIG_VERSION_NUMBER=' "${CFG}" 2>/dev/null | cut -d'"' -f2 || echo "-")

# ---- 写出报告 ---------------------------------------------------------------
NOW=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
DURATION="-"
if [ -n "${RUN_STARTED_AT:-}" ]; then
	START_EPOCH=$(date -u -d "${RUN_STARTED_AT}" +%s 2>/dev/null || echo "")
	if [ -n "${START_EPOCH}" ]; then
		DURATION="$(( ($(date -u +%s) - START_EPOCH) / 60 )) 分钟"
	fi
fi

{
	echo "# R28S FriendlyWrt 25.12 Minimal — 构建报告"
	echo ""
	echo "> 本报告由 Actions 自动生成。**所有结论均为编译与静态检查结果，实机测试由用户执行。**"
	echo ""
	echo "## 一、构建标识"
	echo ""
	echo "| 项目 | 值 |"
	echo "|---|---|"
	echo "| 生成时间 | ${NOW} |"
	echo "| 构建耗时 | ${DURATION} |"
	echo "| 目标板 | NanoPi R28S（RK3528A，4×Cortex-A53，1GB LPDDR4） |"
	echo "| 输出镜像 | \`$(basename "${GZ_PATH}")\` |"
	echo "| 镜像 SHA256 | \`${GZ_SHA}\` |"
	echo ""
	echo "## 二、源码与版本"
	echo ""
	if [ -f "${DIST}/source-versions.md" ]; then
		tail -n +2 "${DIST}/source-versions.md"
	elif [ -f "${BUILD_ROOT}/source-versions.md" ]; then
		tail -n +2 "${BUILD_ROOT}/source-versions.md"
	else
		echo "(源码版本文件缺失)"
	fi
	echo ""
	echo "| 项目 | 值 |"
	echo "|---|---|"
	echo "| manifest | \`rk3528.xml\` @ \`master-v25.12\` |"
	echo "| OpenWrt 版本 | ${OPENWRT_VER} |"
	echo "| Kernel 版本 | ${KVER} |"
	echo "| U-Boot 版本 | ${UBOOTVER}（nanopi_zero2_defconfig） |"
	echo "| 打包工具 | sd-fuse_rk3528（kernel-6.1.y） |"
	echo ""
	echo "## 三、体积统计"
	echo ""
	echo "| 项目 | 大小 | 说明 |"
	echo "|---|---|---|"
	printf '| 最终 SD 镜像 .img | %s | 未压缩，板级分区镜像 |\n' "${IMG_HUMAN}"
	printf '| **最终 .img.gz** | **%s** | **交付物** |\n' "${GZ_HUMAN}"
	if [ -n "${ROOTFS_DIR}" ]; then
		printf '| rootfs 目录（内容） | %s | 实际文件占用，不含分区空余 |\n' "${ROOTFS_DU}"
	fi
	if [ -f "${KERNEL_IMG}" ]; then
		printf '| 内核 image | %s | %s |\n' "$(numfmt --to=iec --suffix=B "$(stat -c %s "${KERNEL_IMG}")" 2>/dev/null)" "$(basename "${KERNEL_IMG}")"
	fi
	for pf in boot.img rootfs.img opt.img; do
		if [ -f "${SDFUSE_OUT}/${pf}" ]; then
			read -r human bytes < <(part_size "${SDFUSE_OUT}/${pf}") || true
			printf '| 分区 %s | %s | sd-fuse 产出 |\n' "${pf}" "${human}"
		fi
	done
	echo ""
	echo "## 四、与官方镜像的体积对比"
	echo ""
	echo "| 项目 | 大小 |"
	echo "|---|---|"
	echo "| 官方 \`${OFFICIAL_ASSET}\`（release ${OFFICIAL_TAG}） | ${OFFICIAL_HUMAN} |"
	echo "| 本次 Minimal | ${GZ_HUMAN} |"
	echo "| **差异** | **${DIFF_HUMAN}（${PCT}）** |"
	echo ""
	echo "> 注：官方数字为该 release 中同名资产的字节数；官方 \`images-*.tgz\`（升级包）"
	echo "> 与 TF 卡 \`.img.gz\` 不是同一种产物，不可直接互相比较。"
	echo ""
	echo "## 五、包统计"
	echo ""
	echo "| 指标 | 数量 |"
	echo "|---|---|"
	printf '| 装入镜像的包（=y） | %s |\n' "${N_Y}"
	printf '| 仅编译不装入（=m） | %s |\n' "${N_M}"
	printf '| 显式关闭（is not set） | %s |\n' "${N_N}"
	printf '| manifest 中已安装包数 | %s |\n' "${N_INSTALLED}"
	echo ""
	echo "- 完整已安装清单：\`installed-packages.txt\`"
	echo "- 显式剔除清单：\`removed-packages.txt\`"
	echo ""
	echo "## 六、无线 / 蓝牙 / 网口驱动"
	echo ""
	echo "- **Wi-Fi 6**：板载 **AIC8800**（\`device/friendlyelec/rk3528/aic8800\` 将 \`aic8800_fdrv\` 写入 \`/etc/modules.d/10-aic8800\`）。"
	echo "  驱动与固件由内核与官方 rootfs 提供；用户空间保留 \`wpad\`/\`hostapd\`/\`iw\`/\`iwinfo\`/\`wireless-regdb\`/\`wifi-scripts\`。"
	echo "- **Bluetooth 5.3**：随 AIC8800 方案，由内核侧驱动承担；官方 rootfs 本就不含 bluez 用户空间栈，本次未添加、也未删除任何蓝牙组件。"
	echo "- **双千兆网口**：驱动位于内核侧；rootfs 侧保留 \`r8169-firmware\`（RTL8125 系列固件）。"
	echo "- 已剔除的无关无线固件：iwlwifi-ax200 / iwlwifi-ax210 / rtl8822be / rtl8822ce / mt76x2 / mt792x、"
	echo "  Broadcom 驱动（kmod-brcmfmac / kmod-brcmutil / brcmfmac-firmware-usb）。"
	echo ""
	echo "### rootfs 内固件清单（共 ${N_FW} 个文件）"
	echo ""
	echo '```'
	echo "(完整内容见 firmware-list.txt)"
	head -40 "${DIST}/firmware-list.txt" 2>/dev/null || echo "(无)"
	echo '```'
	echo ""
	echo "## 七、Device Tree（DTS）"
	echo ""
	echo '```'
	echo "内核 DTS 目录内匹配 rk3528/r28s/zero2/neo3 的文件："
	echo "${DTS_LIST}"
	echo '```'
	echo ""
	echo "> 说明：R28S 的 DTB 由内核源码编入 \`resource.img\`（\`TARGET_KERNEL_DTB=resource.img\`），"
	echo "> 不经过 friendlywrt 的 \`target/linux/rockchip/image/armv8.mk\`（该文件里没有任何"
	echo "> friendlyarm R28S 设备定义，rootfs 侧本就与板型无关）。本次构建未修改 DTS、U-Boot、"
	echo "> boot 参数与分区布局。"
	echo ""
	echo "## 八、静态检查"
	echo ""
	echo "完整性检查结果见 \`static-check.txt\`（也附在本页 Actions 摘要的折叠区）。"
	echo ""
	if [ -f "${DIST}/static-check.txt" ]; then
		grep -E '关键项命中|全部关键项存在|应剔除项仍为' "${DIST}/static-check.txt" | sed 's/^/  /' || true
	fi
	echo ""
	echo "## 九、未验证项目（必须由用户在实机确认）"
	echo ""
	echo "本次**未**进行任何实机测试。以下项目全部待用户自行验证："
	echo ""
	echo "- 启动链（R28S 能否从 TF 卡启动）"
	echo "- LuCI 登录与各页面、SSH（\`ssh root@192.168.2.1\`）"
	echo "- LAN / WAN / bridge / VLAN、IPv4 / IPv6 / DHCP / DHCPv6 / DNS"
	echo "- nftables / fw4、双栈策略路由"
	echo "- Wi-Fi 2.4G / 5G 接入、客户端连接与重连、重启后自动恢复"
	echo "- Bluetooth 硬件初始化"
	echo "- reboot、断电重启后的一致性"
	echo "- 后续 MIMI / Mihomo 的独立安装与运行"
	echo ""
	echo "---"
	echo ""
	echo "## 附：本次构建对官方配置的改动摘要"
	echo ""
	echo "改动仅限 \`configs/rockchip/\` 下的包选择（见 \`removed-packages.txt\`），"
	echo "未修改官方构建脚本、内核配置、DTS、U-Boot 或分区参数。"
	echo ""
} > "${DIST}/REPORT.md"

echo "报告已生成: ${DIST}/REPORT.md"
echo "镜像 SHA256: ${GZ_SHA}"
echo "镜像大小  : ${GZ_HUMAN}"
