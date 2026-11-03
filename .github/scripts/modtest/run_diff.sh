#!/usr/bin/env bash
#
# 启动日志对比：按 (型号, profile) 配对 artifact 并归一化 diff。
#
# 用法：
#   run_diff.sh <artifact下载目录> <输出目录>
#
# artifact 命名（2026-11 起）：modtest-<source>-<model_slug>-<kernel>
#   source ∈ ainas | RROrg；kernel ∈ official | custom
# 目录层级不写死：按源目录之后的相对路径逐文件配对。
#
# 支持的配对（存在两侧 artifact 才执行，否则跳过）：
#   1) ainas/<kernel>  ↔ RROrg/<kernel>    跨源同内核（原有对比）
#   2) ainas/official  ↔ ainas/custom      同环境内核切换（同源跨内核）
#   3) RROrg/official  ↔ RROrg/custom      第二来源的跨内核对照（可选）
#
# 注意：自定义内核本来就与官方内核启动日志不同，diff 只输出摘要，不据此判失败。

set -euo pipefail

ROOT="${1:?缺少 artifact 目录}"
OUT="${2:?缺少输出目录}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="${SCRIPT_DIR}/../bootlog_diff.py"

mkdir -p "${OUT}"

shopt -s nullglob
declare -A seen=()
pairs=0
has_ainas=0
has_rro=0
dirs=()

for d in "${ROOT}"/modtest-*; do
  [ -d "${d}" ] || continue
  base="${d##*/}"
  stem="${base#modtest-}"
  src="${stem%%-*}"
  kern="${stem##*-}"
  slug="${stem#"${src}"-}"
  slug="${slug%-"${kern}"}"
  case "${src}" in ainas|RROrg) ;; *) continue ;; esac
  case "${kern}" in
    official|custom) ;;
    *)
      echo "[WARN] 跳过无法解析 kernel 的 artifact: ${base}" >&2
      continue
      ;;
  esac
  [ -n "${slug}" ] || continue
  dirs+=("${src}|${slug}|${kern}|${d}")
  [ "${src}" = "ainas" ] && has_ainas=$((has_ainas + 1))
  [ "${src}" = "RROrg" ] && has_rro=$((has_rro + 1))
done

run_pair() {
  local a_dir="$1" a_label="$2" b_dir="$3" b_label="$4" pair="$5" slug="$6"
  while IFS= read -r f; do
    rel="${f#"${a_dir}/"}"
    rf="${b_dir}/${rel}"
    [ -f "${rf}" ] || continue
    profile="$(basename "$(dirname "${f}")")"
    name="$(basename "${f}" .log)"
    prefix="${OUT}/${pair}/${slug}/${profile}/${name}"
    mkdir -p "$(dirname "${prefix}")"
    python3 -I "${DIFF}" "${f}" "${rf}" "${prefix}" "${a_label}" "${b_label}"
    pairs=$((pairs + 1))
  done < <(find "${a_dir}" -type f \( -name 'docker.log' -o -name 'cmd-*.out' \) | sort)
}

for entry in "${dirs[@]}"; do
  IFS='|' read -r src slug kern dir <<<"${entry}"

  # 对手目录列表（src/kern 组合）
  case "${src}/${kern}" in
    ainas/official)  candidates="RROrg/official ainas/custom" ;;
    ainas/custom)    candidates="RROrg/custom ainas/official" ;;
    RROrg/official)  candidates="ainas/official" ;;
    RROrg/custom)    candidates="ainas/custom" ;;
    *)               candidates="" ;;
  esac

  for cand in ${candidates}; do
    csrc="${cand%%/*}"
    ckern="${cand##*/}"
    other="${ROOT}/modtest-${csrc}-${slug}-${ckern}"
    [ -d "${other}" ] || continue

    # 每对只做一次：把两侧 (source,kernel) 排序作为去重键
    id="$(printf '%s\n' "${src}-${kern}" "${csrc}-${ckern}" | sort | paste -sd '_')"
    [ -n "${seen[${id}]:-}" ] && continue
    seen[${id}]=1

    if [ "${src}" = "${csrc}" ]; then
      pair="${src}-${kern}-vs-${ckern}"
      a_label="${kern}" b_label="${ckern}"
    else
      pair="${src}-vs-${csrc}-${kern}"
      a_label="${src}/${kern}" b_label="${csrc}/${kern}"
    fi

    echo "[INFO] 配对 ${pair}: ${slug}"
    run_pair "${dir}" "${a_label}" "${other}" "${b_label}" "${pair}" "${slug}"
  done
done

echo "[INFO] 完成配对 ${pairs} 组，输出目录: ${OUT}"

# 单源、单内核运行没有对照可做，正常跳过。
if [ "${has_ainas}" -eq 0 ] || [ "${has_rro}" -eq 0 ]; then
  echo "[INFO] 单源 artifact（ainas=${has_ainas} RROrg=${has_rro}），跳过双源对比"
  exit 0
fi
[ "${pairs}" -gt 0 ] || { echo "[E] 双源 artifact 存在但没有任何可配对日志" >&2; exit 1; }
