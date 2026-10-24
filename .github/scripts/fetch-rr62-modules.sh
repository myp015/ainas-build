#!/usr/bin/env bash
#
# 提取 RR 24.4.0 的 DSM 6.2 modules（"直接复制成品"，不为 6.2 另建编译链）。
#
# DSM 6.2 不在本仓库的编译矩阵内（matrix/build.json 只到 7.0+），而 RR 24.4.0 是
# 最后一个支持 6.2 的 loader 版本。RR 24.4.0 没有独立的 modules release
# （rr-modules 仓库已下线），成品在 updateall-24.4.0.zip 的 modules.tgz 里
# （update-*.zip 不含 modules）。
#
# 用法:
#   fetch-rr62-modules.sh <输出目录> [平台...]
#
# 不指定平台则取全部 8 个；输出文件名统一为 <platform>-6.2-<kver>.tgz，
# 与本仓库模块命名规则 <platform>-<kpre>-<kver>.tgz 及 menu.sh 的
# PKVER="${KPRE:+${KPRE}-}${KVER}" 严格一致（RR 原包里 6.2 的 kpre 为空，
# 文件名是 <platform>-<kver>.tgz，故此处需补 6.2-）。
#
# 用途（维护用，**不参与发布链**）:
#   6.2 的 modules 成品已入库在 myp015/syno-modules 的 6.24-25556/ 目录，
#   modules.yml 直接从那拷贝（见「Copy DSM 6.2 modules」步骤）。本脚本只用于
#   **重新生成该目录**（换 RR 基准版本、补平台时跑一次），或验证目录内容仍与
#   RR 24.4.0 的 updateall 逐字节一致。
#
#   例（把 8 个平台重新导到 syno-modules 克隆目录）:
#     RR62_UPDATEALL_ZIP=/www/tmp/updateall-24.4.0.zip \
#       fetch-rr62-modules.sh /path/to/syno-modules/6.24-25556
#
# 6.2 的 kver 只有 4.4.59 / 3.10.105，而 7.x 用 4.4.180 / 4.4.302，
# 所以这些包只服务 6.2，不会与 7.x 串味。
#
set -euo pipefail

OUT_DIR="${1:?用法: fetch-rr62-modules.sh <输出目录> [平台...]}"
shift

RR_VER="24.4.0"
RR_SHA256="64c002878be14f3e95ee3ca3589bf1399b33bde3378a99444b73865469f64884"
URL="https://github.com/RROrg/rr/releases/download/${RR_VER}/updateall-${RR_VER}.zip"

ALL_PLATFORMS=(apollolake broadwell broadwellnk broadwellntbap denverton geminilake purley v1000)
if [ "$#" -eq 0 ]; then
  PLATFORMS=("${ALL_PLATFORMS[@]}")
else
  PLATFORMS=("$@")
fi

# 平台 -> 6.2 内核版本（取自 RR 24.4.0 model-configs 的 kver；同一平台内所有 6.2 型号一致）
kver_of() {
  case "${1}" in
    broadwell) echo "3.10.105" ;;
    apollolake | broadwellnk | broadwellntbap | denverton | geminilake | purley | v1000) echo "4.4.59" ;;
    *)
      echo "ERROR: 未知平台 ${1}（6.2 只支持 ${ALL_PLATFORMS[*]}）" >&2
      return 1
      ;;
  esac
}

SRC_NAMES=()
DST_NAMES=()
for P in "${PLATFORMS[@]}"; do
  KVER="$(kver_of "${P}")"
  SRC_NAMES+=("${P}-${KVER}.tgz")
  DST_NAMES+=("${P}-6.2-${KVER}.tgz")
done

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

# RR62_UPDATEALL_ZIP 可指向本地已下载的 updateall（离线复跑 / 测试用）；sha256 仍然强校验。
if [ -n "${RR62_UPDATEALL_ZIP:-}" ]; then
  echo "使用本地 ${RR62_UPDATEALL_ZIP}"
  cp -f "${RR62_UPDATEALL_ZIP}" "${TMPD}/updateall.zip"
else
  echo "下载 ${URL}"
  curl -fL --retry 3 --retry-delay 5 -o "${TMPD}/updateall.zip" "${URL}"
fi
echo "${RR_SHA256}  ${TMPD}/updateall.zip" | sha256sum -c -

ARGS=()
for S in "${SRC_NAMES[@]}"; do
  ARGS+=("./${S}")
done

mkdir -p "${TMPD}/m" "${OUT_DIR}"
unzip -p "${TMPD}/updateall.zip" modules.tgz | tar -xzf - -C "${TMPD}/m" "${ARGS[@]}"

for I in "${!PLATFORMS[@]}"; do
  SRC="${TMPD}/m/${SRC_NAMES[${I}]}"
  DST="${OUT_DIR}/${DST_NAMES[${I}]}"
  # fail fast：缺文件、坏归档、空归档任何一个都不许静默跳过 ——
  # 否则 6.2 loader 会在运行时报 "modules 不存在"，而发布/构建链全绿。
  [ -s "${SRC}" ] || {
    echo "ERROR: ${SRC_NAMES[${I}]} 未从 updateall 取到" >&2
    exit 1
  }
  tar -tzf "${SRC}" >/dev/null 2>&1 || {
    echo "ERROR: ${SRC_NAMES[${I}]} 不是有效 tgz" >&2
    exit 1
  }
  [ "$(tar -tzf "${SRC}" | wc -l)" -gt 0 ] || {
    echo "ERROR: ${SRC_NAMES[${I}]} 为空归档" >&2
    exit 1
  }
  cp -f "${SRC}" "${DST}"
  echo "6.2 modules: $(basename "${DST}") ($(stat -c%s "${DST}") 字节)"
done
