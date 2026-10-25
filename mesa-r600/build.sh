#!/bin/bash
#
# 在 ubuntu:18.04 容器内构建 Mesa 21.3.9 的 r600 VA 驱动。
#
# 为什么必须用 Ubuntu 18.04：
#   Emby 容器是 glibc 2.27 + libva 2.22（VA API 1.22），原版
#   /lib/dri/libgallium_drv_video.so 的最高 GLIBC 符号版本正好是 2.27。
#   构建产物必须同样落在 GLIBC_2.27 以内，并由 2.22 的 VA 头生成
#   __vaDriverInit_1_22 入口。18.04 是原生满足这两个约束的最后一个 LTS。
#
# 为什么 -Dllvm=disabled：
#   Mesa 21.3.9 的 r600 允许关闭 LLVM（25.x 才强制要求），VAAPI 编解码
#   路径不使用 LLVM，产物因此不需要 libLLVM，容器里也无需额外部署。
#
# 输入：mesa-r600/patches/（r600 VCE 版本回调修复）、mesa-r600/libva/（头）
# 输出：mesa-r600/out/libgallium_drv_video.so

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
MESA_VERSION=21.3.9
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-${MESA_VERSION}/mesa-mesa-${MESA_VERSION}.tar.gz"
BUILD_ROOT=/build
OUT_DIR="${REPO_DIR}/mesa-r600/out"

export DEBIAN_FRONTEND=noninteractive

echo "== [1/6] apt 源（bionic 已 EOL，必要时切 old-releases）=="
# EOL 后 Release 文件会过期，禁用 Valid-Until 校验
APT_OPTS="-o Acquire::Check-Valid-Until=false"
if ! apt-get ${APT_OPTS} update -qq; then
    echo "archive.ubuntu.com 不可用，切换到 old-releases.ubuntu.com"
    sed -i \
        -e 's|http://archive.ubuntu.com|http://old-releases.ubuntu.com|g' \
        -e 's|http://security.ubuntu.com|http://old-releases.ubuntu.com|g' \
        -e 's|https://archive.ubuntu.com|http://old-releases.ubuntu.com|g' \
        -e 's|https://security.ubuntu.com|http://old-releases.ubuntu.com|g' \
        /etc/apt/sources.list
    apt-get ${APT_OPTS} update -qq
fi

echo "== [2/6] 安装构建依赖 =="
apt-get ${APT_OPTS} install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config bison flex ninja-build \
    python3 python3-pip python3-setuptools python3-wheel python3-mako \
    libdrm-dev zlib1g-dev libzstd-dev libexpat1-dev libudev-dev libelf-dev

echo "== [3/6] meson / ninja =="
# PyPI 上支持 python3.6 的最后一个 meson 是 0.61.5（0.63 起要求 >=3.7）
python3 -m pip install --no-cache-dir --upgrade 'pip<22'
python3 -m pip install --no-cache-dir 'meson==0.61.5'
meson --version
ninja --version

echo "== [4/6] 下载并解压 Mesa ${MESA_VERSION} =="
mkdir -p "${BUILD_ROOT}"
curl -fsSL --retry 3 --max-time 900 -o "${BUILD_ROOT}/mesa.tar.gz" "${MESA_URL}"
tar xzf "${BUILD_ROOT}/mesa.tar.gz" -C "${BUILD_ROOT}"
MESA_SRC="${BUILD_ROOT}/mesa-mesa-${MESA_VERSION}"

# 来源校验：确认解压出来的确实是 21.3.9
grep -qx "${MESA_VERSION}" "${MESA_SRC}/VERSION"

echo "== [5/6] 应用 r600 VCE 修复补丁 + 安装 VA 头 =="
(cd "${MESA_SRC}" && patch -p1 --batch --forward < "${REPO_DIR}/mesa-r600/patches/0001-r600-vce-version-callbacks.patch")

install -d /usr/local/include
cp -r "${REPO_DIR}/mesa-r600/libva/include/va" /usr/local/include/
install -D -m 0644 "${REPO_DIR}/mesa-r600/libva/libva.pc" /usr/local/lib/pkgconfig/libva.pc
pkg-config --modversion libva | grep -qx '1.22.0'

echo "== [6/6] 配置并编译 =="
meson setup "${BUILD_ROOT}/mesa-build" "${MESA_SRC}" \
    --buildtype=release \
    --strip \
    -Dgallium-drivers=r600 \
    -Ddri-drivers= \
    -Dvulkan-drivers= \
    -Dplatforms= \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dllvm=disabled \
    -Dgallium-va=enabled \
    -Dbuild-tests=false \
    -Dvalgrind=disabled \
    -Dosmesa=false \
    -Dzstd=disabled \
    -Dc_link_args='-Wl,-rpath,$ORIGIN'
ninja -C "${BUILD_ROOT}/mesa-build"

SO="${BUILD_ROOT}/mesa-build/src/gallium/targets/va/libgallium_drv_video.so"
test -f "${SO}"

install -d "${OUT_DIR}"
install -m 0755 "${SO}" "${OUT_DIR}/libgallium_drv_video.so"

# expat 无法通过 meson 选项关闭：xmlconfig（pipe-loader 依赖）无条件使用它，
# 而 Emby 容器里没有 libexpat.so.1。产物已带 RPATH=$ORIGIN，把 18.04 的
# libexpat.so.1 一并放到同目录即可被加载，部署时两个文件须一起拷贝。
EXPAT_SO=$(ldconfig -p | awk '/libexpat\.so\.1 .*x86-64/{print $NF; exit}')
test -f "${EXPAT_SO}"
install -m 0755 "${EXPAT_SO}" "${OUT_DIR}/libexpat.so.1"

ls -l "${OUT_DIR}/"

echo "== 构建完成 =="
