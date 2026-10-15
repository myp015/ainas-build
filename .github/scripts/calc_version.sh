#!/usr/bin/env bash
#
# 计算按月低增的发布版本号（<YY.M.N>），并写入 $GITHUB_ENV。
# modules / lkms / cks / addons / buildroot / ainas-rr 六个工作流的
# 「Calculate version」步骤共用。
#
# 用法:
#   calc_version.sh <owner/repo> [<requested_version>]
#
# 依赖环境变量:
#   GH_TOKEN    访问 api.github.com 的凭据（调用方从 secrets.AiNas 传入）
#   GITHUB_ENV  GitHub Actions 注入的变量文件，VERSION 追加于此
#
# 规则:
#   1. requested_version 非空、且前两段等于当前年月（%y.%-m）→ 直接采用
#   2. 否则查 <repo> 的 releases[0].tag_name：
#        - 同月且 3 段 → 第 3 段 +1
#        - 同月且 4 段（旧格式，如 26.9.13.1）→ 不参与低增，回退月份首版
#        - 跨月 / 查不到 → 月份首版 .0
#   3. 再循环 +1 直到 <repo> 的 git tag 不存在（最多 20 次，防死循环）
#      历史失败 run 可能留下 git tag 而无 release 对象 → release-action 422 already_exists
#
# 与原内联版本的差异（有意为之）：API 调用现在校验 HTTP 状态码，
# 网络故障 / 限流 / 非预期状态码一律显式报错退出，不再静默回退到月份首版 ——
# 后者会算出一个错误的版本号，并可能重复发布。
set -euo pipefail

REPO="${1:?用法: calc_version.sh <owner/repo> [<requested_version>]}"
REQUESTED="${2:-}"
: "${GH_TOKEN:?缺少 GH_TOKEN}"
: "${GITHUB_ENV:?缺少 GITHUB_ENV}"

API="https://api.github.com/repos/${REPO}"

# GET <url> → stdout 为响应体；非 200 即报错退出
api_get() {
  local url="${1}" resp code
  resp="$(curl -skL -w '\n%{http_code}' -H "Authorization: Bearer ${GH_TOKEN}" "${url}")"
  code="${resp##*$'\n'}"
  if [ "${code}" != "200" ]; then
    echo "[E] GET ${url} 返回 HTTP ${code}" >&2
    echo "${resp%$'\n'*}" >&2
    return 1
  fi
  printf '%s' "${resp%$'\n'*}"
}

# tag_exists <version> → 200 存在 / 404 不存在 / 其它报错退出
tag_exists() {
  local url="${API}/git/refs/tags/${1}" code
  code="$(curl -skL -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GH_TOKEN}" "${url}")"
  case "${code}" in
    200) return 0 ;;
    404) return 1 ;;
    *)
      echo "[E] GET ${url} 返回 HTTP ${code}" >&2
      exit 1
      ;;
  esac
}

bump() { echo "${1}" | awk -F '.' '{$3=$3+1}1' OFS='.'; }

MONTH="$(date +'%y.%-m')"

if [ -n "${REQUESTED}" ] && [ "$(echo "${REQUESTED}" | cut -d '.' -f 1,2)" = "${MONTH}" ]; then
  VERSION="${REQUESTED}"
else
  # 自动：查最新 tag，同月则第 3 段 +1，跨月则 .0
  LATEST_TAG="$(api_get "${API}/releases" | jq -r '.[0].tag_name')"
  if [ -n "${LATEST_TAG}" ] && [ "$(echo "${LATEST_TAG}" | cut -d '.' -f 1,2)" = "${MONTH}" ]; then
    if [ "$(echo "${LATEST_TAG}" | awk -F '.' '{print NF}')" -ge 4 ]; then
      VERSION="${MONTH}.0"
    else
      VERSION="$(bump "${LATEST_TAG}")"
    fi
  else
    VERSION="${MONTH}.0"
  fi
fi

# 防残留 tag 冲突
for _ in $(seq 1 20); do
  if tag_exists "${VERSION}"; then
    VERSION="$(bump "${VERSION}")"
  else
    break
  fi
done

echo "VERSION: ${VERSION}"
echo "VERSION=${VERSION}" >> "${GITHUB_ENV}"
