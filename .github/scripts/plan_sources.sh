#!/usr/bin/env bash
#
# Copyright (C) 2022 Ing <https://github.com/wjz304>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# 构建规划脚本：解析 RR 源版本、选择型号、生成 matrix 任务。
# 用法：plan_sources.sh <2in1|rr|ova>
#
# 输入（环境变量）：
#   GH_TOKEN          访问 GitHub API 的 token（必需）
#   RR_SOURCE         ainas | RROrg（单选，每次编译只用一个源）
#   RR_VERSION        指定 RR 版本，留空或 latest 表示取最新
#   DSM_VERSION       DSM 版本编号
#   ALL_MODELS        全选 | 自选
#   CUSTOM_MODELS     自定义型号（逗号分隔）
#   MODEL_*           各型号勾选状态（字符串 true/false）
#   BUILD_RR_ORIGINAL rr：是否生成原版 RR 镜像
#
# 输出（GITHUB_OUTPUT）：
#   source / rr_tag / rr_asset_url / release_tag / release_title / release_notes
#   base_asset / docker_image / docker_tag
#                   选中源的配置；因为每次只允许一个源，直接作为标量输出，
#                   下游 job 用 needs.plan.outputs.* 读取，不塞整串 JSON 到 env。
#   tasks           构建任务数组（model/kind），供 build matrix 使用
#
# 所有 Release 都发布在 myp015/ainas-2in1 仓库。

set -euo pipefail

PRODUCT="${1:-}"
case "${PRODUCT}" in
  2in1|rr|ova) ;;
  *)
    echo "[E] 用法: plan_sources.sh <2in1|rr|ova>（收到: ${PRODUCT:-<空>}）" >&2
    exit 1
    ;;
esac

: "${GITHUB_OUTPUT:?缺少 GITHUB_OUTPUT}"
: "${GH_TOKEN:?缺少 GH_TOKEN}"

ALL_MODELS="${ALL_MODELS:-全选}"
CUSTOM_MODELS="${CUSTOM_MODELS:-}"
DSM_VERSION="${DSM_VERSION:-}"
RR_VERSION="${RR_VERSION:-}"
BUILD_RR_ORIGINAL="${BUILD_RR_ORIGINAL:-false}"

if [ "${PRODUCT}" = "ova" ] && [ "${DSM_VERSION}" = "6.2.4" ]; then
  echo "[E] OVA 工作流不支持 DSM 6.2.4（仅 7.x）" >&2
  exit 1
fi

# ── 1. 源选择 ─────────────────────────────────────────────────────────
# 每次编译只允许一个源：两个源同时编译会争用同名 base/Release 资产，也拉长构建时间。
case "${RR_SOURCE:-}" in
  ainas|RROrg) SOURCES=("${RR_SOURCE}") ;;
  *)
    echo "[E] rr_source 非法: ${RR_SOURCE:-<空>}（只允许 ainas / RROrg，每次编译只能选一个源）" >&2
    exit 1
    ;;
esac

# wjz304/rr 在 RR 24.4.0 之后移除了 DSM 6.2 平台数据，RROrg 源构建 6.2 必然失败
if [ "${DSM_VERSION}" = "6.2.4" ]; then
  for s in "${SOURCES[@]}"; do
    if [ "${s}" = "RROrg" ]; then
      echo "[E] DSM 6.2.4 只支持 ainas 源：wjz304/rr 镜像已无 DSM 6.2 平台数据" >&2
      exit 1
    fi
  done
fi

# ── 2. 型号选择 ───────────────────────────────────────────────────────
MODELS=()

# 型号名大小写归一化：pats.xlsx 与 rr 内置型号表区分大小写，
# 自定义输入写成全小写（如 ds3617xs）会匹配不到型号，先还原成标准写法。
KNOWN_MODELS=(
  "DS918+" "DS920+" "DS923+" "DS925+" "DS3622xs+" "SA6400" "DS425+"
  "DVA3221" "DVA1622" "DS3617xs"
)
norm_model() {
  local raw="$1" low cm
  low="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  for cm in "${KNOWN_MODELS[@]}"; do
    if [ "$(printf '%s' "${cm}" | tr '[:upper:]' '[:lower:]')" = "${low}" ]; then
      printf '%s\n' "${cm}"
      return 0
    fi
  done
  printf '%s\n' "${raw}"
}

# DVA 系列已从工作流勾选项中移除，需要时通过 custom_models 手动输入（如 DVA3221）。
if [ "${DSM_VERSION}" = "6.2.4" ]; then
  # DSM 6.2 型号白名单：只有 DS918+(apollolake) 固定可选
  echo "[INFO] DSM 6.2 型号白名单：DS918+（其它 6.2 型号请用 custom_models 输入）"
  if [ "${ALL_MODELS}" = "全选" ]; then
    MODELS+=("DS918+")
  else
    [ "${MODEL_DS918P:-false}" = "true" ] && MODELS+=("DS918+")
  fi
  # 2in1 允许 6.2 自定义型号（DS3617xs 靠 custom_models 输入）；
  # rr/ova 沿用历史行为：6.2 忽略自定义型号。
  if [ "${PRODUCT}" != "2in1" ] && [ -n "$(printf '%s' "${CUSTOM_MODELS}" | tr -d '[:space:]')" ]; then
    echo "[WARN] DSM 6.2 走型号白名单，自定义型号 ${CUSTOM_MODELS} 已忽略"
    CUSTOM_MODELS=""
  fi
elif [ "${ALL_MODELS}" = "全选" ]; then
  echo "[INFO] 已开启全选，将编译工作流支持的全部型号"
  MODELS+=("DS918+" "DS920+" "DS923+" "DS925+" "DS3622xs+" "SA6400" "DS425+")
else
  [ "${MODEL_DS918P:-false}"    = "true" ] && MODELS+=("DS918+")
  [ "${MODEL_DS920P:-false}"    = "true" ] && MODELS+=("DS920+")
  [ "${MODEL_DS923P:-false}"    = "true" ] && MODELS+=("DS923+")
  [ "${MODEL_DS925P:-false}"    = "true" ] && MODELS+=("DS925+")
  [ "${MODEL_DS3622XSP:-false}" = "true" ] && MODELS+=("DS3622xs+")
  [ "${MODEL_SA6400:-false}"    = "true" ] && MODELS+=("SA6400")
  [ "${MODEL_DS425P:-false}"    = "true" ] && MODELS+=("DS425+")
fi

if [ -n "$(printf '%s' "${CUSTOM_MODELS}" | tr -d '[:space:]')" ]; then
  echo "[INFO] 检测到自定义型号输入: ${CUSTOM_MODELS}"
  IFS=',' read -ra CUSTOM_ARR <<< "${CUSTOM_MODELS}"
  for cm in "${CUSTOM_ARR[@]}"; do
    cm="$(printf '%s' "${cm}" | xargs)"
    [ -n "${cm}" ] && MODELS+=("$(norm_model "${cm}")")
  done
fi

# DS3617xs 只有 DSM 6.2 的 PAT；2in1 在 7.x 手动输入也必然在 dsm_setup 阶段才失败，提前拦下
if [ "${PRODUCT}" = "2in1" ] && [ "${DSM_VERSION}" != "6.2.4" ]; then
  for m in "${MODELS[@]}"; do
    if [ "${m}" = "DS3617xs" ]; then
      echo "[E] DS3617xs 仅支持 DSM 6.2.4，请将 DSM 版本改为 6.2.4" >&2
      exit 1
    fi
  done
fi

# 去重
UNIQ_MODELS=()
for m in "${MODELS[@]}"; do
  skip=0
  for u in "${UNIQ_MODELS[@]}"; do
    [ "${u}" = "${m}" ] && { skip=1; break; }
  done
  [ "${skip}" -eq 0 ] && UNIQ_MODELS+=("${m}")
done
MODELS=("${UNIQ_MODELS[@]}")

if [ "${#MODELS[@]}" -eq 0 ]; then
  # rr 允许只编原版 RR 镜像；其余产品必须至少勾选一个型号
  if [ "${PRODUCT}" = "rr" ] && [ "${BUILD_RR_ORIGINAL}" = "true" ]; then
    :
  else
    echo "[E] 请至少勾选一个型号" >&2
    exit 1
  fi
fi

# ── 3. 逐源解析 RR Release ────────────────────────────────────────────
REQ_TAG="$(printf '%s' "${RR_VERSION}" | tr -d '[:space:]')"
REQ_TAG="${REQ_TAG#rr-}"
REQ_TAG="${REQ_TAG%.img.zip}"
REQ_TAG="${REQ_TAG#v}"

SOURCES_TSV="$(mktemp)"
TASKS_TSV="$(mktemp)"
trap 'rm -f "${SOURCES_TSV}" "${TASKS_TSV}"' EXIT
: >"${SOURCES_TSV}"
: >"${TASKS_TSV}"

# 源 × 产品 的 Release/base 命名映射
release_tag_for() {
  local src="$1" tag="$2"
  case "${PRODUCT}:${src}" in
    2in1:ainas) printf 'ainas-2in1_%s\n' "${tag}" ;;
    2in1:RROrg) printf 'RROrg-2in1_%s\n' "${tag}" ;;
    rr:ainas)   printf 'ainas-rr-%s\n' "${tag}" ;;
    rr:RROrg)   printf 'RROrg-rr-%s\n' "${tag}" ;;
    ova:ainas)  printf 'ainas-ova-%s\n' "${tag}" ;;
    ova:RROrg)  printf 'RROrg-ova-%s\n' "${tag}" ;;
    *) echo "[E] 未定义的产品/源组合: ${PRODUCT}/${src}" >&2; return 1 ;;
  esac
}
release_title_for() {
  local src="$1" tag="$2"
  case "${PRODUCT}:${src}" in
    2in1:ainas) printf 'ainas-2in1_%s\n' "${tag}" ;;
    2in1:RROrg) printf 'RROrg-2in1_%s\n' "${tag}" ;;
    rr:ainas)   printf 'ainas-rr_%s\n' "${tag}" ;;
    rr:RROrg)   printf 'RROrg-rr_%s\n' "${tag}" ;;
    ova:ainas)  printf 'ainas-ova_%s\n' "${tag}" ;;
    ova:RROrg)  printf 'RROrg-ova_%s\n' "${tag}" ;;
    *) echo "[E] 未定义的产品/源组合: ${PRODUCT}/${src}" >&2; return 1 ;;
  esac
}
base_asset_for() {
  local src="$1" tag="$2"
  case "${PRODUCT}:${src}" in
    # 2in1 RROrg 使用源限定名：旧的 2in1-base-<tag> 是 get* 资产覆盖版，语义不兼容
    2in1:ainas) printf '2in1-base-%s.img.zst\n' "${tag}" ;;
    2in1:RROrg) printf '2in1-base-rrorg-%s.img.zst\n' "${tag}" ;;
    rr:*)       printf 'rr-base-%s.img.zst\n' "${tag}" ;;
    ova:*)      printf 'ova-base-%s.img.zst\n' "${tag}" ;;
    *) echo "[E] 未定义的产品/源组合: ${PRODUCT}/${src}" >&2; return 1 ;;
  esac
}

for src in "${SOURCES[@]}"; do
  case "${src}" in
    ainas) REPO="myp015/ainas-rr" ;;
    RROrg) REPO="RROrg/rr" ;;
  esac

  echo "[INFO] 解析 ${src} 源（${REPO}）"
  # 必须带凭据：runner 是共享出口 IP，匿名调用只有 60 次/小时，实测撞过 403
  if [ -z "${REQ_TAG}" ] || [ "${REQ_TAG}" = "latest" ]; then
    RELEASE_JSON="$(curl -fsSL --connect-timeout 10 \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      "https://api.github.com/repos/${REPO}/releases/latest")"
  else
    if ! RELEASE_JSON="$(curl -fsSL --connect-timeout 10 \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        "https://api.github.com/repos/${REPO}/releases/tags/${REQ_TAG}")"; then
      echo "[E] 指定的 rr_version=${RR_VERSION} 在 ${src}（${REPO}）中不存在（不做 latest 回退）" >&2
      exit 1
    fi
  fi

  RR_TAG="$(printf '%s' "${RELEASE_JSON}" | jq -r '.tag_name // empty' | sed 's/^v//')"
  RR_ASSET_URL="$(printf '%s' "${RELEASE_JSON}" | jq -r '.assets[]? | select(.name | test("^rr-.*[.]img[.]zip$")) | .browser_download_url' | head -n1)"
  if [ -z "${RR_TAG}" ] || [ -z "${RR_ASSET_URL}" ]; then
    echo "[E] 无法解析 ${src} 源的发布信息（rr_version=${RR_VERSION:-latest}）" >&2
    exit 1
  fi
  echo "[INFO] ${src} 源 RR 版本=${RR_TAG}"

  RELEASE_TAG="$(release_tag_for "${src}" "${RR_TAG}")"
  RELEASE_TITLE="$(release_title_for "${src}" "${RR_TAG}")"
  BASE_ASSET="$(base_asset_for "${src}" "${RR_TAG}")"

  if [ "${src}" = "ainas" ]; then
    DOCKER_IMAGE="myp015/rr"
    ALLOW_6_2="true"
  else
    DOCKER_IMAGE="wjz304/rr"
    ALLOW_6_2="false"
  fi

  # p3 的 cks/lkms/addons/modules 一律使用 rr.img 自带资产，不调用 get* 覆盖
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${src}" "${REPO}" "${RR_TAG}" "${RR_ASSET_URL}" \
    "${RELEASE_TAG}" "${RELEASE_TITLE}" "${BASE_ASSET}" \
    "${DOCKER_IMAGE}" "latest" "${ALLOW_6_2}" \
    "RR build artifacts for ${RR_TAG}" \
    >>"${SOURCES_TSV}"

  # ── 任务：型号 ──
  for m in "${MODELS[@]}"; do
    printf '%s\t%s\t%s\n' "${src}" "${m}" "normal" >>"${TASKS_TSV}"
  done
  # ── 任务：原版 RR 镜像（仅 rr）──
  if [ "${PRODUCT}" = "rr" ] && [ "${BUILD_RR_ORIGINAL}" = "true" ]; then
    printf '%s\t%s\t%s\n' "${src}" "__RR_ORIGINAL__" "original" >>"${TASKS_TSV}"
  fi
done

if [ ! -s "${TASKS_TSV}" ]; then
  echo "[E] 没有任何构建任务" >&2
  exit 1
fi

# ── 4. 生成 JSON 并写 GITHUB_OUTPUT ───────────────────────────────────
python3 - "${SOURCES_TSV}" "${TASKS_TSV}" <<'PY'
import json, os, sys

src_fields = [
    "source", "repo", "rr_tag", "rr_asset_url", "release_tag", "release_title",
    "base_asset", "docker_image", "docker_tag", "allow_6_2", "release_notes",
]
sources = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        sources.append(dict(zip(src_fields, line.split("\t"))))

# 单源：源配置作为 plan 的标量输出，build matrix 只保留 model/kind，
# 任务名不会被一长串 URL 撑爆，也不再需要向 job env 注入整串 JSON。
if len(sources) != 1:
    raise SystemExit("[E] 每次编译只能有一个源，实际解析到 %d 个" % len(sources))
src = sources[0]

tasks = []
with open(sys.argv[2], encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        _src, model, kind = line.split("\t")
        tasks.append({"model": model, "kind": kind})

def dump(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))

scalar_keys = [
    "source", "rr_tag", "rr_asset_url", "release_tag", "release_title",
    "base_asset", "docker_image", "docker_tag", "release_notes",
]
with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
    for k in scalar_keys:
        f.write("%s=%s\n" % (k, src[k]))
    f.write("tasks=" + dump(tasks) + "\n")

print("[INFO] 源: %s（%s）" % (src["source"], src["repo"]))
print("[INFO] 任务数: %d" % len(tasks))
PY
