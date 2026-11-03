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
for ainas_dir in "${ROOT}"/modtest-ainas-*; do
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
[ "${pairs}" -gt 0 ] || { echo "[E] 没有任何可配对日志" >&2; exit 1; }
