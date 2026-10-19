#!/usr/bin/env bash
#
# 把构建产物发布到指定 Release。rr.yml / ova.yml / 2in1.yml 的 build job 共用。
#
# 用法:
#   release_publish.sh <release_tag> <release_notes> <asset>...
#
# 依赖环境变量:
#   GH_TOKEN   gh 的凭据（调用方从 secrets.AiNas 导出）
#   GH_REPO    目标仓库，如 myp015/ainas-2in1
#   RELEASE_TITLE  Release 标题（可选，默认等于 release_tag）
#
# 行为:
#   - 资产文件不存在则跳过；一个都不剩则失败
#   - 单个资产 >= 2GB（GitHub 硬上限）时按 1900MB 分卷，命名 <文件>.part.NNN
#   - 上传前确认 Release 存在，被删或 API 不一致时重建
#     （ensure-release job 已串行创建过一次，但 matrix job 仍会撞上 release not found）
#   - 上传失败且属于可重试错误（404/409/422/429/5xx/限流）时退避重试 5 次
set -euo pipefail

MAX_ASSET_BYTES=2147483648 # GitHub 单文件上限 2GB
SPLIT_SIZE="1900M"
MAX_ATTEMPTS=5

if [ $# -lt 3 ]; then
  echo "用法: $(basename "$0") <release_tag> <release_notes> <asset>..." >&2
  exit 2
fi
RELEASE_TAG="${1}"
RELEASE_NOTES="${2}"
shift 2

# Release 标题可与 tag 不同（如 tag 为 rr-<版本>、标题为 rr_<版本>）。
# 调用方可 export RELEASE_TITLE 覆盖；未指定时沿用 tag，保持既有行为。
RELEASE_TITLE="${RELEASE_TITLE:-${RELEASE_TAG}}"

ensure_release() {
  local out rc
  if gh release view "${RELEASE_TAG}" >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] Release ${RELEASE_TAG} 不存在，重建..."
  set +e
  out=$(gh release create "${RELEASE_TAG}" \
    --title "${RELEASE_TITLE}" \
    --notes "${RELEASE_NOTES}" \
    --latest=false 2>&1)
  rc=$?
  set -e
  if [ "${rc}" -ne 0 ]; then
    echo "${out}"
    # 并发创建 / 短暂 5xx 都算成功，只要随后能查到
    # 正则与各 ensure-release job 保持一致（含并发创建时的 Validation Failed）
    echo "${out}" | grep -qiE 'already exists|already_exists|Validation Failed|HTTP 429|HTTP 502|HTTP 503|HTTP 504|rate limit|secondary rate' || return "${rc}"
  fi
  gh release view "${RELEASE_TAG}" >/dev/null 2>&1
}

# ── 组装资产（超限的分卷）─────────────────────────────────────────────
ASSETS=()
for f in "$@"; do
  if [ ! -f "${f}" ]; then
    echo "[WARN] 资产不存在，跳过: ${f}" >&2
    continue
  fi
  size=$(stat -c%s "${f}")
  if [ "${size}" -ge "${MAX_ASSET_BYTES}" ]; then
    echo "[INFO] ${f##*/} 大小 ${size} 超过 2GB 上限，按 ${SPLIT_SIZE} 分卷"
    rm -f "${f}.part."*
    split -b "${SPLIT_SIZE}" -d -a 3 "${f}" "${f}.part."
    for p in "${f}.part."*; do
      echo "  -> ${p##*/} ($(stat -c%s "${p}") 字节)"
      ASSETS+=("${p}")
    done
  else
    ASSETS+=("${f}")
  fi
done

if [ ${#ASSETS[@]} -eq 0 ]; then
  echo "[E] 没有可上传的资产" >&2
  exit 1
fi

# ── 上传（带 Release 自愈与退避重试）──────────────────────────────────
for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  if ! ensure_release; then
    echo "[E] Release ${RELEASE_TAG} 不可用，放弃上传" >&2
    exit 1
  fi
  echo "[INFO] 上传制品尝试 ${attempt}/${MAX_ATTEMPTS} -> ${RELEASE_TAG}: ${ASSETS[*]}"
  set +e
  out=$(gh release upload "${RELEASE_TAG}" "${ASSETS[@]}" --clobber 2>&1)
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "[INFO] 上传完成: ${RELEASE_TAG}"
    exit 0
  fi
  echo "${out}"
  if echo "${out}" | grep -qiE 'HTTP 404|HTTP 422|already exists|409|HTTP 429|HTTP 502|HTTP 503|HTTP 504|rate limit|secondary rate'; then
    sleep $((attempt * 5))
    continue
  fi
  exit "${rc}"
done

echo "[E] 上传连续 ${MAX_ATTEMPTS} 次失败: ${RELEASE_TAG}" >&2
exit 1
