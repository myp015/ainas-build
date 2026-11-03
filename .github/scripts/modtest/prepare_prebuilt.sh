#!/usr/bin/env bash
#
# 预装成品模式：下载已安装的 OVA，还原为可直接启动的 rr.img + data.qcow2，
# 并把"我们自己编译的模块包"注入引导盘 p3（供 guest 内逐个 insmod）。
#
# 用法：
#   prepare_prebuilt.sh <source> <model> <modules_key> <kver> \
#       <ova_release_tag> <ova_asset_glob> <modules_release_tag> \
#       <run_module_test> <module_limit>
#
# 前置：
#   - 工作目录为仓库根（$PWD），需已有 .2in1（ainas-2in1 检出）；
#   - GH_TOKEN 环境变量（访问 myp015/ainas-2in1 与 myp015/syno-modules）；
#   - 依赖 qemu-utils（qemu-img）、kmod（modinfo）。
#
# 产物（工作目录下）：
#   rr/rr.img            启动盘（已安装 DSM，raw）
#   rr/data.qcow2        数据盘（qcow2）
#   rr/docker-compose.yaml  预装启动用 compose（源为 2in1 模板，已含 /storage/alpine/rr.img）
#   rr.img 的 p3/modtest/  模块测试清单与 guest 脚本（run_module_test=true 时）
#
# 说明：
#   - OVA 内磁盘命名不固定（ovftool 可能重命名），因此按 qemu-img 的虚机大小
#     区分：小盘=启动盘（2.5G），大盘=数据盘（12G）；
#   - 成品 OVA 由正式 ova.yml 构建时已裁剪 p3，这里显式放入本次测试的模块包，
#     保证 ainas/RROrg 两源测的是同一份模块包。

set -euo pipefail

SOURCE="${1:?缺少 source}"
MODEL="${2:?缺少 model}"
MODULES_KEY="${3:?缺少 modules_key}"
KVER="${4:?缺少 kver}"
OVA_RELEASE_TAG="${5:?缺少 ova_release_tag}"
OVA_ASSET_GLOB="${6:?缺少 ova_asset_glob}"
MODULES_RELEASE_TAG="${7:?缺少 modules_release_tag}"
RUN_MODULE_TEST="${8:-false}"
MODULE_LIMIT="${9:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$PWD"
OVA_DIR="${WORKDIR}/.prebuilt-ova"
RR_DIR="${WORKDIR}/rr"

[ -f "${WORKDIR}/.2in1/docker/vm-docker-compose.yaml" ] || {
  echo "[E] 缺少 compose 模板: ${WORKDIR}/.2in1/docker/vm-docker-compose.yaml" >&2; exit 1; }

cleanup() {
  sudo umount /mnt/p3 2>/dev/null || true
  for L in $(losetup -j "${RR_DIR}/rr.img" 2>/dev/null | cut -d: -f1); do
    sudo losetup --detach "$L" 2>/dev/null || true
  done
}
trap cleanup EXIT

echo "[INFO] 预装 OVA: source=${SOURCE} model=${MODEL} release=${OVA_RELEASE_TAG} pattern=${OVA_ASSET_GLOB}"

echo "[INFO] 安装依赖 qemu-utils（qemu-img）"
command -v qemu-img >/dev/null || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq qemu-utils >/dev/null
}

rm -rf "${OVA_DIR}"
mkdir -p "${OVA_DIR}/dl" "${OVA_DIR}/unpacked" "${RR_DIR}"

# ── 1. 下载成品 OVA（按 型号_DSM主版本_* 严格匹配，避免选错版本）────────
export GH_REPO="myp015/ainas-2in1"
gh release download "${OVA_RELEASE_TAG}" --pattern "${OVA_ASSET_GLOB}" --dir "${OVA_DIR}/dl"

FILES=("${OVA_DIR}/dl/"*.ova.gz)
if [ "${#FILES[@]}" -ne 1 ] || [ ! -f "${FILES[0]}" ]; then
  echo "[E] Release ${OVA_RELEASE_TAG} 中未按 ${OVA_ASSET_GLOB} 匹配到唯一 .ova.gz" >&2
  echo "[E] 现有资产:" >&2
  gh release view "${OVA_RELEASE_TAG}" --json assets --jq '.assets[].name' >&2 || true
  exit 1
fi
OVA_GZ="${FILES[0]}"
echo "[INFO] 已下载 $(basename "${OVA_GZ}")（$(du -h "${OVA_GZ}" | cut -f1)）"

# ── 2. 解包（gzip 流式解压 + tar，避免中间文件翻倍占盘）────────────────
echo "[INFO] 解包 OVA（gzip -> tar，直接落盘）"
gzip -dc "${OVA_GZ}" | tar -xf - -C "${OVA_DIR}/unpacked" -v
rm -f "${OVA_GZ}"

# ── 3. 按虚机容量区分启动盘/数据盘，并转换为 qemu 格式 ─────────────────
VMDK_OUT="${OVA_DIR}/vmdk-paths.txt"
python3 -I - "${OVA_DIR}/unpacked" "${VMDK_OUT}" <<'PY'
import glob, os, re, subprocess, sys

root, out_path = sys.argv[1], sys.argv[2]
# split vmdk 的分片文件（*-s001.vmdk 等）不是独立磁盘，跳过
files = [f for f in glob.glob(os.path.join(root, "**", "*.vmdk"), recursive=True)
         if not re.search(r"-s\d+\.vmdk$", f)]
if not files:
    raise SystemExit("[E] OVA 内未找到 .vmdk 磁盘文件")

infos = []
for f in files:
    res = subprocess.run(["qemu-img", "info", f],
                         capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise SystemExit("[E] qemu-img info 失败: %s\n%s" % (f, res.stderr.strip()))
    # 人读格式在所有版本一致：virtual size: 8 MiB (8388608 bytes)
    m = re.search(r"virtual size:\s+.*?\((\d+) bytes\)", res.stdout)
    if not m:
        raise SystemExit("[E] 无法解析 virtual size: %s\n%s" % (f, res.stdout.strip()))
    infos.append((f, int(m.group(1))))

infos.sort(key=lambda x: x[1])
print("[INFO] OVA 内磁盘: %s" % ", ".join(
    "%s=%.1fG" % (os.path.basename(f), s / 1024**3) for f, s in infos))

if len(infos) < 2:
    raise SystemExit("[E] 预装 OVA 应是双盘（启动盘+数据盘），实际只有 %d 个 vmdk" % len(infos))
if infos[0][1] == infos[-1][1]:
    raise SystemExit("[E] 无法按容量区分启动盘/数据盘（同为 %.1fG）" % (infos[0][1] / 1024**3))
with open(out_path, "w", encoding="utf-8") as f:
    f.write(infos[0][0] + "\n" + infos[-1][0] + "\n")
PY
mapfile -t VMDK_LINES < "${VMDK_OUT}"
[ "${#VMDK_LINES[@]}" -eq 2 ] || { echo "[E] vmdk 解析结果不完整" >&2; exit 1; }
BOOT_VMDK="${VMDK_LINES[0]}"
DATA_VMDK="${VMDK_LINES[1]}"
echo "[INFO] 启动盘=${BOOT_VMDK}"
echo "[INFO] 数据盘=${DATA_VMDK}"

echo "[INFO] 转换启动盘 -> rr/rr.img（raw）"
qemu-img convert -p -O raw "${BOOT_VMDK}" "${RR_DIR}/rr.img"
echo "[INFO] 转换数据盘 -> rr/data.qcow2（qcow2）"
qemu-img convert -p -O qcow2 "${DATA_VMDK}" "${RR_DIR}/data.qcow2"

rm -rf "${OVA_DIR}"
ls -lh "${RR_DIR}/rr.img" "${RR_DIR}/data.qcow2"

# ── 4. 生成启动用 compose（模板已含 /storage/alpine/rr.img）────────────
cp -f "${WORKDIR}/.2in1/docker/vm-docker-compose.yaml" "${RR_DIR}/docker-compose.yaml"

# ── 5. 注入我们自己编译的模块包到引导盘 p3 ─────────────────────────────
if [ "${RUN_MODULE_TEST}" = "true" ]; then
  echo "[INFO] 下载模块包: ${MODULES_RELEASE_TAG}（只取 ${MODULES_KEY}.tgz）"
  MODPKG_DIR="${WORKDIR}/.modules-pkg"
  rm -rf "${MODPKG_DIR}"
  mkdir -p "${MODPKG_DIR}"
  GH_REPO="myp015/syno-modules" gh release download "${MODULES_RELEASE_TAG}" \
    --pattern "modules-*.zip" --dir "${MODPKG_DIR}"
  MODZIP="$(find "${MODPKG_DIR}" -maxdepth 1 -name 'modules-*.zip' | head -n1)"
  [ -n "${MODZIP}" ] || { echo "[E] 未下载到 modules-*.zip" >&2; exit 1; }
  # zip -j 平铺，tgz 在压缩包根目录
  unzip -o -j "${MODZIP}" "${MODULES_KEY}.tgz" -d "${MODPKG_DIR}" >/dev/null
  MOD_TGZ="${MODPKG_DIR}/${MODULES_KEY}.tgz"
  [ -f "${MOD_TGZ}" ] || {
    echo "[E] modules zip 中缺少 ${MODULES_KEY}.tgz" >&2; exit 1; }
  echo "[INFO] 模块包大小: $(du -h "${MOD_TGZ}" | cut -f1)"

  DISK_LOOP=$(sudo losetup -f)
  sudo losetup -P "${DISK_LOOP}" "${RR_DIR}/rr.img"
  for _ in $(seq 1 40); do [ -b "${DISK_LOOP}p3" ] && break; sleep 0.25; done
  [ -b "${DISK_LOOP}p3" ] || {
    echo "[E] 预装 rr.img 分区未就绪: ${DISK_LOOP}p3" >&2; exit 1; }
  sudo mkdir -p /mnt/p3
  sudo mount "${DISK_LOOP}p3" /mnt/p3
  df -h /mnt/p3

  sudo mkdir -p /mnt/p3/modules /mnt/p3/modtest
  sudo cp -f "${MOD_TGZ}" "/mnt/p3/modules/${MODULES_KEY}.tgz"
  sudo cp -f "${SCRIPT_DIR}/guest/run-module-tests.sh" /mnt/p3/modtest/
  sudo bash "${WORKDIR}/.github/scripts/make_module_list.sh" \
    "/mnt/p3/modules/${MODULES_KEY}.tgz" "${KVER}" "/mnt/p3/modtest" "${MODULE_LIMIT:-0}"
  sudo sync

  sudo umount /mnt/p3
  sudo losetup --detach "${DISK_LOOP}"
  rm -f "${MOD_TGZ}"
fi

echo "[INFO] 预装镜像准备完成: rr/rr.img + rr/data.qcow2"
