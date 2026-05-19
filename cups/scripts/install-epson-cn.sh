#!/usr/bin/env bash
# Epson 国行私有驱动：仅 amd64 best-effort 安装。
#
# `epson-inkjet-printer-201601w` 与 `epson-printer-utility` 是 Epson 中国区
# 发布的**闭源专有** .deb 包（无源码，无 arm64/armhf 二进制），覆盖 L380/L455
# 等国行早期喷墨机型。对应功能大部分可以被 Debian 自带的 `printer-driver-escpr`
# 覆盖，但原厂 PPD 在墨水检测、尺寸预设等细节上更完整。
#
# ⚠️ 原下载源 download-center.epson.com.cn 的 UUID 会定期轮换导致 URL 失效，
# 因此把 .deb 镜像到本仓库的 GitHub Releases（cups-driver tag）。
# 此处采用 **fail-fast**：下载 / dpkg 任一步失败则脚本立刻中断，
# 避免发布镜像里缺少国行驱动却静默成功。arm64/armhf 在脚本入口直接退出，
# 不受影响。
# 升级方法：把新版 .deb 上传到 https://github.com/hanxi/cups-web/releases 的
# cups-driver tag，更新下方 DEB 变量即可。

set -eo pipefail

# 仅 amd64 安装；其他架构静默退出（exit 0，不影响整个 build）
ARCH="$(dpkg --print-architecture)"
if [ "${ARCH}" != "amd64" ]; then
    echo "[epson-cn] skip: arch=${ARCH} (only amd64 supported)"
    exit 0
fi

# ────────────────────────────────────────────────────────────────────
# 配置
# ────────────────────────────────────────────────────────────────────
EPSON_PROP_DRIVER_DEB="epson-inkjet-printer-201601w_1.0.1-1_amd64.deb"
EPSON_PROP_UTILITY_DEB="epson-printer-utility_1.2.2-1_amd64.deb"
EPSON_PROP_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

EPSON_DRV_URL="https://github.com/hanxi/cups-web/releases/download/cups-driver/${EPSON_PROP_DRIVER_DEB}"
EPSON_UTIL_URL="https://github.com/hanxi/cups-web/releases/download/cups-driver/${EPSON_PROP_UTILITY_DEB}"

# ────────────────────────────────────────────────────────────────────
# 下载 & dpkg
# ────────────────────────────────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/epson-cn.XXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

cd "${BUILD_DIR}"

echo "[epson-cn] downloading ${EPSON_DRV_URL}"
wget --tries=3 --timeout=60 --retry-connrefused \
     --user-agent="${EPSON_PROP_UA}" \
     -O "${EPSON_PROP_DRIVER_DEB}" "${EPSON_DRV_URL}"

echo "[epson-cn] downloading ${EPSON_UTIL_URL}"
wget --tries=3 --timeout=60 --retry-connrefused \
     --user-agent="${EPSON_PROP_UA}" \
     -O "${EPSON_PROP_UTILITY_DEB}" "${EPSON_UTIL_URL}"

# dpkg -i 失败时用 apt-get -f install 兜底处理依赖
dpkg -i ./*.deb || apt-get install -y -f --no-install-recommends

echo "[epson-cn] installed Epson CN proprietary driver + utility"
rm -rf /var/lib/apt/lists/*
