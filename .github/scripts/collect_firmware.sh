#!/usr/bin/env bash
#
# 汇总内核模块（.ko）声明的固件到 <root_path>/firmware，并打包为 <root_path>/firmware.tgz。
# modules.yml / cks.yml 两个工作流的「firmware」步骤共用。
# （modules-3rd.yml 的 firmware 步骤不在此列：它是第三方固件的**生产者**，
#   产物落在 syno-modules/thirdparty/firmware，无白名单、不打包 tgz，逻辑并不相同。）
#
# 用法:
#   collect_firmware.sh <root_path> <thirdparty_fw_dir> <repo_fw_dir> \
#                       <repo_fw_subdirs_csv> <whitelist_csv> [<extra_find_root>...]
#
#   root_path            工作区根目录（$GITHUB_WORKSPACE）；firmware/ 与 firmware.tgz 落于此
#   thirdparty_fw_dir    第三方固件目录，内容最先复制进 firmware/；空串 = 跳过
#   repo_fw_dir          仓库自带固件根目录；空串 = 跳过
#   repo_fw_subdirs_csv  repo_fw_dir 下要复制的子目录，逗号分隔；空串 = 跳过
#   whitelist_csv        repo_fw_dir 下「允许缺失」清单文件名，逗号分隔；空串 = 无白名单
#   extra_find_root...   额外扫描 *.ko 的根目录；<root_path>/output 始终会被扫描
#                       （modules.yml 传 syno-modules/release = 官方全平台模块全集）
#
# 固件解析优先级（对每个 modinfo -F firmware 报出的名字 L）：
#   1. linux-firmware 仓库里有             → 复制
#   2. firmware/ 中已存在（第三方/仓库源） → 记 "Used thirdparty"
#   3. 命中白名单                           → 静默放行
#   4. 其余                                 → ::warning ::Missing
set -euo pipefail

if [ $# -lt 5 ]; then
  echo "用法: $(basename "$0") <root_path> <thirdparty_fw_dir> <repo_fw_dir> <repo_fw_subdirs_csv> <whitelist_csv> [<extra_find_root>...]" >&2
  exit 2
fi

ROOT_PATH="${1}"
PARTY3RD_PATH="${2}"
REPO_FW="${3}"
REPO_FW_SUBDIRS="${4}"
WHITELIST_CSV="${5}"
shift 5

FW_DIR="${ROOT_PATH}/firmware"
FW_TGZ="${ROOT_PATH}/firmware.tgz"
OUTPUT_DIR="${ROOT_PATH}/output"
SOURCE="/tmp/linux-firmware"

# 复制目录内容（不含点文件，与原有 `cp -rf "${src}"/*` 语义一致）。
# 用 nullglob 而非裸 glob：目录为空时裸 glob 不展开，cp 会因源不存在而失败。
copy_contents() {
  local src="${1}" dst="${2}" item
  shopt -s nullglob
  for item in "${src}"/*; do
    cp -rf "${item}" "${dst}/"
  done
  shopt -u nullglob
}

mkdir -p "${FW_DIR}"

# ── 1. 预置固件：第三方 → 仓库自带 ───────────────────────────────────────
if [ -n "${PARTY3RD_PATH}" ] && [ -d "${PARTY3RD_PATH}" ]; then
  echo "copy 3rd modules"
  copy_contents "${PARTY3RD_PATH}" "${FW_DIR}"
fi

if [ -n "${REPO_FW}" ] && [ -n "${REPO_FW_SUBDIRS}" ]; then
  IFS=',' read -ra SUBS <<<"${REPO_FW_SUBDIRS}"
  LABEL=""
  for S in "${SUBS[@]}"; do
    LABEL="${LABEL:+${LABEL} + }${S}"
  done
  echo "copy repo firmware (${LABEL}) - Task#188"
  for S in "${SUBS[@]}"; do
    if [ -d "${REPO_FW}/${S}" ]; then
      copy_contents "${REPO_FW}/${S}" "${FW_DIR}"
    fi
  done
fi

# 白名单文件：缺失即告警（配置写错要看得见），但不影响缺失固件的归类
WL_FILES=()
if [ -n "${WHITELIST_CSV}" ]; then
  IFS=',' read -ra WLS <<<"${WHITELIST_CSV}"
  for W in "${WLS[@]}"; do
    if [ -f "${REPO_FW}/${W}" ]; then
      WL_FILES+=("${REPO_FW}/${W}")
    else
      echo "::warning ::白名单文件不存在: ${REPO_FW}/${W}"
    fi
  done
fi

# ── 2. 解包编译产物 ─────────────────────────────────────────────────────
echo "extract all modules"
for F in "${OUTPUT_DIR}"/*.tgz; do
  echo "${F}"
  mkdir -p "${F%.tgz}"
  tar -zxf "${F}" -C "${F%.tgz}" || echo "Failed to extract ${F}"
done

# ── 3. 从 linux-firmware 补齐 ───────────────────────────────────────────
echo "get firmware"
git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git "${SOURCE}"
# intel 固件上移到顶层，便于按 modinfo 报出的相对路径直接命中
# （必须先判目录存在：glob 无匹配时 cp 会中断整个脚本）
if [ -d "${SOURCE}/intel/iwlwifi" ]; then
  cp -rf "${SOURCE}/intel/iwlwifi/"* "${SOURCE}/" 2>/dev/null
fi

FIND_ROOTS=("${OUTPUT_DIR}")
if [ $# -gt 0 ]; then
  FIND_ROOTS+=("$@")
fi

while read -r L; do
  [ -z "${L}" ] && continue
  if [ -e "${SOURCE}/${L}" ]; then
    mkdir -p "$(dirname "${FW_DIR}/${L}")"
    cp -f "${SOURCE}/${L}" "${FW_DIR}/${L}"
  elif [ -e "${FW_DIR}/${L}" ]; then
    echo "Used thirdparty ${L}"
  elif [ "${#WL_FILES[@]}" -gt 0 ] &&
    awk -v L="${L}" '{if($1==L) f=1} END{exit !f}' "${WL_FILES[@]}" 2>/dev/null; then
    : # 白名单内：静默放行，不输出日志
  else
    echo "::warning ::Missing ${L}"
  fi
done <<<"$(find "${FIND_ROOTS[@]}" -name \*.ko -exec /sbin/modinfo -F firmware {} 2>/dev/null \;)"

tar -zcf "${FW_TGZ}" -C "${FW_DIR}" .
