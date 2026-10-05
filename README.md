# R28S FriendlyWrt 25.12 Minimal

为 **NanoPi R28S（Rockchip RK3528）** 构建 **FriendlyWrt 25.12 极简 non-docker TF 卡镜像** 的构建仓库。

本仓库**只包含构建脚本**，不含任何镜像或第三方源码。源码在构建时从 friendlyarm 官方仓库实时拉取。

---

## 产出

| 文件 | 说明 |
|---|---|
| `R28S-FriendlyWrt-25.12-Minimal.img.gz` | 可写入备用 TF 卡的 SD 镜像（交付物） |
| `R28S-FriendlyWrt-25.12-Minimal.img.gz.sha256` | 镜像校验值 |
| `REPORT.md` | 完整构建报告（源码版本、体积对比、包统计、驱动与固件清单、未验证项） |
| `installed-packages.txt` | 装入镜像的包清单 |
| `removed-packages.txt` | 相对官方配置显式剔除的包清单 |
| `firmware-list.txt` | rootfs 内固件清单 |
| `static-check.txt` | 静态检查逐项结果 |

产物位置：**Actions 运行页面的 Artifacts**，以及 **Releases 页面的 `r28s-minimal-25.12`**。

---

## 构建基线（完全跟随官方）

| 组件 | 来源 |
|---|---|
| manifest | `friendlyarm/friendlywrt_manifests` @ `master-v25.12`，`rk3528.xml` |
| rootfs | `friendlyarm/friendlywrt` @ `master-v25.12`（`rockchip` / non-docker） |
| Kernel | `friendlyarm/kernel-rockchip` @ `nanopi6-v6.1.y` |
| U-Boot | `friendlyarm/uboot-rockchip` @ `nanopi5-v2017.09`，`nanopi_zero2_defconfig` |
| 打包 | `friendlyarm/sd-fuse_rk3528` @ `kernel-6.1.y` |
| 板型 | `device/friendlyelec/rk3528/base.mk`，`MODEL=R28S-Zero2-NEO3Plus-Series` |

构建方式与官方 `Actions-FriendlyWrt` 的 workflow 一致（同一套 `build.sh` 流程、同一套
`build-env-on-ubuntu` 环境、同样的 `custome_config.sh` 改写），**唯一差别**是在编译 rootfs 之前
用 `scripts/minimalize-configs.sh` 就地裁剪 `configs/rockchip/`。

---

## 使用方法

### 1. 触发构建

`Actions` → `Build R28S FriendlyWrt 25.12 Minimal` → `Run workflow`，选择模式：

| 模式 | 作用 | 耗时 | 产出 |
|---|---|---|---|
| `dry-run` | 只同步源码 + 生成并静态检查 `.config` | 约 20~35 分钟 | `.config`、静态检查结果、裁剪清单 |
| `full` | 完整编译并产出镜像 | 约 2~4 小时 | 上述全部 + `.img.gz` |

> 建议先跑一次 `dry-run` 确认裁剪结果符合预期，再跑 `full`。

### 2. 下载镜像

构建完成后，在 `Releases` 页面下载 `R28S-FriendlyWrt-25.12-Minimal.img.gz` 与 `.sha256`。

### 3. 校验与写盘

```bash
# 校验（Linux / macOS）
sha256sum -c R28S-FriendlyWrt-25.12-Minimal.img.gz.sha256

# 写入 TF 卡（请务必确认 /dev/sdX 是目标卡，不要写错盘）
gunzip -c R28S-FriendlyWrt-25.12-Minimal.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Windows 下可用 balenaEtcher 或 Rufus 直接写入 `.img.gz`。

---

## 裁剪策略

裁剪**只动 `configs/rockchip/` 下的包选择**，不修改官方构建脚本、内核配置、DTS、U-Boot 与分区参数。

关键机制（已核对官方源码）：

- `scripts/package-metadata.pl:309-318` 把非 hidden 包的 Kconfig 默认值定义为
  `default m if ALL || ALL_NONSHARED || ALL_KMODS` —— 因此 `CONFIG_ALL_KMODS=y` /
  `CONFIG_ALL_NONSHARED=y` 只会让包变成 `=m`（参与编译、**不装入镜像**）。
  **只有显式 `=y` 的包才会进入 rootfs。**
- `scripts/mk-friendlywrt.sh` 会把 `configs/rockchip/` 下所有文件按 `ls` 顺序追加进 `.config`，
  并强制追加 `CONFIG_ALL_KMODS=y`。

因此裁剪做法是：**把不需要的包从 `=y` 改成 `# ... is not set`**（显式关闭优先级高于 default，
既剔除镜像又省编译时间）。凡被保留包真正依赖的项，`make defconfig` 会自动补回，不会造成依赖缺失。

### 保留（不受影响）

- 板载 **Wi-Fi 6（AIC8800）**：`wpad`/`hostapd`/`iw`/`iwinfo`/`wireless-regdb`/`wifi-scripts`/`cfg80211`/`mac80211`
- **Bluetooth 5.3**：由内核侧 AIC8800 驱动承担（官方 rootfs 本就不含 bluez 用户空间栈）
- **双千兆网口**：内核侧驱动 + rootfs 侧 `r8169-firmware`
- **IPv4 / IPv6**、`fw4` / `nftables`、`dnsmasq-full`、`odhcpd`、`dropbear`、LuCI、**APK**、Lua / UCI / UBus
- **PPPoE 拨号**（`luci-proto-ppp` / `kmod-pppoe`）
- MIMI 后续安装所需：`apk`、`lua`、`libuci-lua`、`libubus-lua`、`luci-lua-runtime`、
  `luci-lib-nixio`、`luci-lib-jsonc`、`luci-lib-ip`、`coreutils-timeout`、`rpcd` 等

### 剔除

- 第三方 DNS / 广告过滤：`smartdns`、`adblock`（与 MIMI/Mihomo 的 DNS 接管冲突）
- NAS / 文件共享：`samba4-*`、`wsdd2`、`avahi-*`
- 媒体服务器：`minidlna` 及专用解码库
- 下载器：`aria2`
- 开发 / 调试：`git`、`strace`、`vim-full`
- 压测：`coremark`、`iperf` / `iperf3`
- 监控统计：`collectd` 全家桶、`rrdtool`、`luci-app-statistics`
- FTP：`vsftpd`
- USB Modem / 蜂窝网络栈（QMI / MBIM / USB 串口切换 / PPP 冷门变体）
- 无关无线：Broadcom 驱动、`iwlwifi-ax200/ax210`、`rtl8822be/ce`、`mt76x2`、`mt792x` 固件
- `pciutils` / `pciids`（R28S 无 PCIe 插槽）
- LuCI 界面语言：26 种 → `en` / `zh_Hans` / `zh_Hant`

### 明确不做

- 不打包 MIMI、Mihomo、`geoip.dat` / `geosite.dat`（由 MIMI 独立安装、独立更新规则）
- 不加入 Docker / NAS / 影音 / 开发环境
- 不改主题、不改 LuCI 布局与页面结构
- 不改分区布局、不改 U-Boot / DTS / boot 参数

---

## 重要声明

- 本仓库构建的是**供自行写入备用 TF 卡测试的镜像**，不是生产升级包，也不含任何自动刷机逻辑。
- 构建产物**未经实机验证**。启动链、双网口、Wi-Fi、Bluetooth、IPv6、DHCP/DHCPv6、
  重启与断电恢复等**必须由使用者自行在实机验证**。
- 官方 FriendlyWrt 分区布局：rootfs 1280 MB / userdata 1536 MB / opt 分区，首次启动会自动扩展
  `opt` 分区到卡容量（官方机制，未作改动）。
