#!/usr/bin/env bash
#
# 双源启动日志对比：把 ainas 与 RROrg 的 modtest artifact 按 (型号, profile) 配对。
#
# 用法：
#   run_diff.sh <artifact下载目录> <输出目录>
#
# 期望目录结构（actions/download-artifact pattern=modtest-*）：
#   <root>/modtest-ainas-<slug>/.../<profile>/docker.log
#   <root>/modtest-RROrg-<slug>/.../<profile>/docker.log
# 目录层级不写死：按源目录之后的相对路径逐文件配对。

set -euo pipefail

ROOT="${1:?缺少 artifact 目录}"
OUT="${2:?缺少输出目录}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF="${SCRIPT_DIR}/../bootlog_diff.py"

mkdir -p "${OUT}"

shopt -s nullglob
pairs=0
found_ainas=0
found_rro=0
for rr_dir in "${ROOT}"/modtest-RROrg-*; do
  found_rro=1
done
for ainas_dir in "${ROOT}"/modtest-ainas-*; do
  found_ainas=1
  slug="${ainas_dir##*modtest-ainas-}"
  rr_dir="${ROOT}/modtest-RROrg-${slug}"
  if [ ! -d "${rr_dir}" ]; then
    echo "[WARN] 缺少 RROrg 对照: ${slug}" >&2
    continue
  fi

  while IFS= read -r f; do
    rel="${f#"${ainas_dir}/"}"
    rf="${rr_dir}/${rel}"
    [ -f "${rf}" ] || continue
    profile="$(basename "$(dirname "${f}")")"
    name="$(basename "${f}" .log)"
    prefix="${OUT}/${slug}/${profile}/${name}"
    mkdir -p "$(dirname "${prefix}")"
    python3 -I "${DIFF}" "${f}" "${rf}" "${prefix}"
    pairs=$((pairs + 1))
  done < <(find "${ainas_dir}" -type f \( -name 'docker.log' -o -name 'cmd-*.out' \) | sort)
done

echo "[INFO] 完成配对 ${pairs} 组，输出目录: ${OUT}"

# 单源运行（rr_source=ainas 或 RROrg）没有对照可做，正常跳过。
if [ "${found_ainas}" -eq 0 ] || [ "${found_rro}" -eq 0 ]; then
  echo "[INFO] 单源 artifact（ainas=${found_ainas} RROrg=${found_rro}），跳过双源对比"
  exit 0
fi
[ "${pairs}" -gt 0 ] || { echo "[E] 双源 artifact 存在但没有任何可配对日志" >&2; exit 1; }
