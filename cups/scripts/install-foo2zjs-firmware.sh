#!/usr/bin/env bash
# foo2zjs / foo2xqx 系列 HP host-based 打印机固件安装脚本。
#
# 覆盖型号（均为"GDI / host-based"打印机，每次上电需主机上传固件）：
#   foo2zjs:  HP LaserJet 1000, 1005, 1018
#   foo2xqx:  HP LaserJet P1005, P1006/P1008, P1505
#
# 注意：HP LaserJet 1020 的固件由 install-hp-laserjet1020.sh 独立处理（从
# GitHub Releases 下载 sihp1020.dl + 派生 A4-default PPD），本脚本跳过。
#
# 固件来源：从公共镜像站下载 .tar.gz（含 .img 原始固件），用 arm2hpdl 工具
# 转换为 CUPS 可用的 .dl 格式。arm2hpdl 是 foo2zjs 项目的单文件 C 工具，
# 构建期从 GitHub 克隆编译。
#
# 安装路径：/lib/firmware/hp/（Debian foo2zjs 包所有 udev 脚本 hpljXXXX 的
# FWDIR 硬编码路径；merged-usr 下与 /usr/lib/firmware/hp/ 等价）。
#
# 本脚本必须在 cleanup-build.sh 之前运行——编译 arm2hpdl 需要 gcc。

set -eo pipefail

# ────────────────────────────────────────────────────────────────────
# 配置
# ────────────────────────────────────────────────────────────────────
FW_INSTALL_DIR="/lib/firmware/hp"

# 公共固件下载源（按优先级排列，首个成功即停止）
FIRMWARE_SOURCES=(
    "https://www.quirinux.org/printers"
    "https://mirrors.edge.kernel.org/pub/software/drivers/foo2zjs/firmware"
    "http://foo2zjs.rkkda.com/firmware"
)

# foo2zjs 系列固件（ZjStream 协议）
FOO2ZJS_MODELS=(sihp1000 sihp1005 sihp1018)

# foo2xqx 系列固件（XQX 协议）
FOO2XQX_MODELS=(sihpP1005 sihpP1006 sihpP1505)

# ────────────────────────────────────────────────────────────────────
# 编译 arm2hpdl 转换工具
# ────────────────────────────────────────────────────────────────────
echo "[foo2zjs-firmware] compiling arm2hpdl converter..."

ARM2HPDL=""
TMPDIR_BUILD="$(mktemp -d /tmp/foo2zjs-build.XXXXXX)"
trap 'rm -rf "${TMPDIR_BUILD}"' EXIT

wget -q "https://raw.githubusercontent.com/koenkooi/foo2zjs/master/arm2hpdl.c" \
    -O "${TMPDIR_BUILD}/arm2hpdl.c"
gcc -o "${TMPDIR_BUILD}/arm2hpdl" "${TMPDIR_BUILD}/arm2hpdl.c"
ARM2HPDL="${TMPDIR_BUILD}/arm2hpdl"
echo "[foo2zjs-firmware] arm2hpdl compiled: ${ARM2HPDL}"

mkdir -p "${FW_INSTALL_DIR}"

# ────────────────────────────────────────────────────────────────────
# 通用下载 & 转换函数
# ────────────────────────────────────────────────────────────────────
download_and_convert() {
    local fw_name="$1"
    local target_path="${FW_INSTALL_DIR}/${fw_name}.dl"

    # 跳过已存在的固件（sihp1020 由 install-hp-laserjet1020.sh 安装）
    if [ -s "${target_path}" ]; then
        echo "[foo2zjs-firmware] ${fw_name}.dl already exists, skipping"
        return 0
    fi

    local tarball="${TMPDIR_BUILD}/${fw_name}.tar.gz"
    local downloaded=false

    for src in "${FIRMWARE_SOURCES[@]}"; do
        if wget -q --no-check-certificate "${src}/${fw_name}.tar.gz" -O "${tarball}" 2>/dev/null; then
            downloaded=true
            break
        fi
    done

    if ! $downloaded || [ ! -s "${tarball}" ]; then
        echo "[foo2zjs-firmware] WARNING: ${fw_name}.tar.gz download failed from all sources"
        return 1
    fi

    # 解压并转换
    tar xzf "${tarball}" -C "${TMPDIR_BUILD}" 2>/dev/null

    if [ -f "${TMPDIR_BUILD}/${fw_name}.img" ]; then
        "${ARM2HPDL}" "${TMPDIR_BUILD}/${fw_name}.img" > "${target_path}" 2>/dev/null
        rm -f "${TMPDIR_BUILD}/${fw_name}.img"
    elif [ -f "${TMPDIR_BUILD}/${fw_name}.dl" ]; then
        cp "${TMPDIR_BUILD}/${fw_name}.dl" "${target_path}"
        rm -f "${TMPDIR_BUILD}/${fw_name}.dl"
    else
        echo "[foo2zjs-firmware] WARNING: ${fw_name}.tar.gz contains neither .img nor .dl"
        rm -f "${tarball}"
        return 1
    fi

    rm -f "${tarball}"

    if [ -s "${target_path}" ]; then
        echo "[foo2zjs-firmware] installed ${fw_name}.dl ($(wc -c < "${target_path}") bytes)"
        return 0
    else
        echo "[foo2zjs-firmware] WARNING: ${fw_name}.dl is empty after conversion"
        rm -f "${target_path}"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# 下载 foo2zjs 系列固件
# ────────────────────────────────────────────────────────────────────
echo "[foo2zjs-firmware] === foo2zjs firmware (ZjStream) ==="
ZJS_OK=0
ZJS_FAIL=0
for fw in "${FOO2ZJS_MODELS[@]}"; do
    if download_and_convert "$fw"; then
        ZJS_OK=$((ZJS_OK + 1))
    else
        ZJS_FAIL=$((ZJS_FAIL + 1))
    fi
done

# ────────────────────────────────────────────────────────────────────
# 下载 foo2xqx 系列固件
# ────────────────────────────────────────────────────────────────────
echo "[foo2zjs-firmware] === foo2xqx firmware (XQX) ==="
XQX_OK=0
XQX_FAIL=0
for fw in "${FOO2XQX_MODELS[@]}"; do
    if download_and_convert "$fw"; then
        XQX_OK=$((XQX_OK + 1))
    else
        XQX_FAIL=$((XQX_FAIL + 1))
    fi
done

# ────────────────────────────────────────────────────────────────────
# 兼容符号链接
# ────────────────────────────────────────────────────────────────────
# P1007 使用与 P1005 相同的固件；P1008 使用与 P1006 相同的固件
if [ -f "${FW_INSTALL_DIR}/sihpP1005.dl" ] && [ ! -e "${FW_INSTALL_DIR}/sihpP1007.dl" ]; then
    ln -sf sihpP1005.dl "${FW_INSTALL_DIR}/sihpP1007.dl"
    echo "[foo2zjs-firmware] symlink: sihpP1007.dl → sihpP1005.dl"
fi
if [ -f "${FW_INSTALL_DIR}/sihpP1006.dl" ] && [ ! -e "${FW_INSTALL_DIR}/sihpP1008.dl" ]; then
    ln -sf sihpP1006.dl "${FW_INSTALL_DIR}/sihpP1008.dl"
    echo "[foo2zjs-firmware] symlink: sihpP1008.dl → sihpP1006.dl"
fi

# ────────────────────────────────────────────────────────────────────
# 权限修正 & 汇总
# ────────────────────────────────────────────────────────────────────
chmod 644 "${FW_INSTALL_DIR}"/sihp*.dl 2>/dev/null || true

TOTAL_OK=$((ZJS_OK + XQX_OK))
TOTAL_FAIL=$((ZJS_FAIL + XQX_FAIL))

echo "[foo2zjs-firmware] === summary ==="
echo "[foo2zjs-firmware] installed: ${TOTAL_OK}, failed: ${TOTAL_FAIL}"
ls -la "${FW_INSTALL_DIR}"/sihp*.dl 2>/dev/null || true

if [ "${TOTAL_OK}" -eq 0 ]; then
    echo "[foo2zjs-firmware] FATAL: no firmware files were installed"
    exit 1
fi
