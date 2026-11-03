#!/usr/bin/env bash
#
# 模块逐测工作流的规划包装脚本。
#
# 复用 plan_sources.sh 的版本解析与型号选择逻辑（不复制一份），按源逐个调用后合并：
#   - RR_SOURCE=ainas / RROrg：调用一次；
#   - RR_SOURCE=both：ainas 与 RROrg 各调用一次，用于同环境双源对比。
#
# 与正式 ova.yml 的差异：
#   - base 上传到独立 Release（test-ova-<source>-<tag>），跨 run 复用；
#   - tasks 里补 platform / kver / modules_key，供模块包定位与测试盘生成；
#   - 输出 base_tasks 与 tasks 两个 matrix 数组。
#
# 输入（环境变量，均透传给 plan_sources.sh）：
#   GH_TOKEN / RR_SOURCE / RR_VERSION / DSM_VERSION / ALL_MODELS /
#   CUSTOM_MODELS / MODEL_DS918P ... MODEL_DS425P
#   MODELS_JSON    models.json 路径（默认 .2in1-plan/script/models.json）
#   USE_PREBUILT   true=复用已安装的成品 OVA（跳过 base 构建与安装）
#   PREBUILT_VERSIONS  "ainas=26.11.0,RROrg=26.9.0"：各源成品 OVA 的版本号，
#                  用于拼 Release 名 <source>-ova-<version>
#   MODULES_VERSION   模块包版本（留空=取 myp015/syno-modules 最新 Release）
#
# 输出（GITHUB_OUTPUT）：
#   base_tasks       [{source, rr_tag, rr_asset_url, release_tag, base_asset, docker_image, docker_tag}]
#   tasks            [{source, model, model_slug, platform, kver, modules_key,
#                      rr_tag, release_tag, base_asset, docker_image, docker_tag,
#                      ova_release_tag, ova_asset_glob, modules_release_tag}]
#   task_count

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GITHUB_OUTPUT:?缺少 GITHUB_OUTPUT}"
: "${GH_TOKEN:?缺少 GH_TOKEN}"

RR_SOURCE="${RR_SOURCE:-ainas}"
DSM_VERSION="${DSM_VERSION:-7.4.1}"
MODELS_JSON="${MODELS_JSON:-.2in1-plan/script/models.json}"

case "${RR_SOURCE}" in
  ainas|RROrg) SOURCES=("${RR_SOURCE}") ;;
  both)        SOURCES=(ainas RROrg) ;;
  *)
    echo "[E] rr_source 非法: ${RR_SOURCE}（只允许 ainas / RROrg / both）" >&2
    exit 1
    ;;
esac

if [ ! -f "${MODELS_JSON}" ]; then
  echo "[E] 找不到 models.json: ${MODELS_JSON}" >&2
  exit 1
fi

DSM_LINE="${DSM_VERSION%.*}"

# ── 预装成品模式：解析各源 OVA Release 与模块包版本 ─────────────────────
USE_PREBUILT="${USE_PREBUILT:-false}"
case "${USE_PREBUILT}" in
  true|false) ;;
  *) echo "[E] USE_PREBUILT 只允许 true/false: ${USE_PREBUILT}" >&2; exit 1 ;;
esac

MODULES_RELEASE_TAG="${MODULES_VERSION:-}"
if [ "${USE_PREBUILT}" = "true" ] && [ -z "${MODULES_RELEASE_TAG}" ]; then
  # 最新模块包 Release（与主流程发布物同源）
  MODULES_RELEASE_TAG="$(GH_REPO=myp015/syno-modules gh release view --json tagName --jq '.tagName')"
fi
if [ "${USE_PREBUILT}" = "true" ]; then
  [ -n "${MODULES_RELEASE_TAG}" ] || {
    echo "[E] 无法解析 syno-modules 最新 Release 版本" >&2; exit 1; }
fi
export USE_PREBUILT MODULES_RELEASE_TAG PREBUILT_VERSIONS DSM_VERSION

# TEST_MODELS（逗号分隔）优先于 ALL_MODELS/MODEL_*：
# 阶段 1 只跑一个型号，脚本把它翻译成 plan_sources.sh 认识的开关。
TEST_MODELS="${TEST_MODELS:-}"
if [ -n "${TEST_MODELS}" ]; then
  export ALL_MODELS="自选"
  for raw in $(printf '%s' "${TEST_MODELS}" | tr ',' ' '); do
    m="$(printf '%s' "${raw}" | xargs)"
    [ -n "${m}" ] || continue
    case "${m}" in
      DS918+)    export MODEL_DS918P=true ;;
      DS920+)    export MODEL_DS920P=true ;;
      DS923+)    export MODEL_DS923P=true ;;
      DS925+)    export MODEL_DS925P=true ;;
      DS3622xs+) export MODEL_DS3622XSP=true ;;
      SA6400)    export MODEL_SA6400=true ;;
      DS425+)    export MODEL_DS425P=true ;;
      *)
        export CUSTOM_MODELS="${CUSTOM_MODELS:+${CUSTOM_MODELS},}${m}" ;;
    esac
  done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── 1. 逐源调用 plan_sources.sh（每次写独立临时 GITHUB_OUTPUT）────────
idx=0
for src in "${SOURCES[@]}"; do
  out="${WORK}/${src}.out"
  echo "[INFO] 规划 ${src} 源"
  GITHUB_OUTPUT="${out}" RR_SOURCE="${src}" \
    bash "${SCRIPT_DIR}/plan_sources.sh" ova
  [ -s "${out}" ] || { echo "[E] ${src} 源规划输出为空" >&2; exit 1; }
  idx=$((idx + 1))
done

# ── 2. 合并、补平台信息并写 GITHUB_OUTPUT ─────────────────────────────
python3 - "${WORK}" "${MODELS_JSON}" "${DSM_LINE}" "${SOURCES[@]}" <<'PY'
import json, os, sys

work, models_json, line = sys.argv[1], sys.argv[2], sys.argv[3]
sources_arg = sys.argv[4:]

models = json.load(open(models_json, encoding="utf-8"))

use_prebuilt = os.environ.get("USE_PREBUILT", "false") == "true"
modules_release_tag = os.environ.get("MODULES_RELEASE_TAG", "")
dsm_version = os.environ.get("DSM_VERSION", "")

# 预装成品 OVA 的版本映射：ainas=26.11.0,RROrg=26.9.0
prebuilt_versions = {}
raw_versions = os.environ.get("PREBUILT_VERSIONS", "").strip()
if use_prebuilt and raw_versions:
    for item in raw_versions.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit("[E] PREBUILT_VERSIONS 格式错误（应为 ainas=26.11.0,RROrg=26.9.0）: %s" % item)
        k, v = item.split("=", 1)
        prebuilt_versions[k.strip()] = v.strip()

# 成品 OVA 资产名形如 SA6400_741_90080_ainas_26_11_0.ova.gz / DS918+_741_...，
# 其中 741 是 DSM 主版本号数字（7.4.1 -> 741）；用它与当前 dsm_version 做匹配校验。
dsm_ver_digits = dsm_version.replace(".", "")
if use_prebuilt and not dsm_ver_digits:
    raise SystemExit("[E] 预装成品模式必须提供 DSM_VERSION")


def parse_output(path):
    data = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw or "=" not in raw:
                continue
            k, v = raw.split("=", 1)
            if k in ("tasks",):
                data[k] = json.loads(v)
            else:
                data[k] = v
    return data


def model_slug(model):
    # artifact 名不允许 '+'：DS918+ -> DS918p
    return model.replace("+", "p")


def locate(model):
    for platform, entry in models.items():
        if not isinstance(entry, dict):
            continue
        if model in entry.get("models", []):
            pv = entry.get("productvers", {}).get(line)
            if not pv:
                raise SystemExit(
                    "[E] %s 不支持 DSM %s（无 productvers 条目）" % (model, line))
            kver = pv.split("-", 1)[1]
            return platform, kver
    raise SystemExit("[E] models.json 中不存在型号: %s" % model)


base_tasks, tasks = [], []
for src in sources_arg:
    cfg = parse_output(os.path.join(work, "%s.out" % src))
    # 测试版 base 用独立 Release 命名，避免与正式 ova 工作流（ainas-ova-*/RROrg-ova-*）
    # 的 Release 与资产名冲突，便于跨 run 重复复用。
    rel_tag = "test-ova-%s-%s" % (src.lower(), cfg["rr_tag"])
    base_asset = "test-ova-base-%s-%s.img.zst" % (src.lower(), cfg["rr_tag"])
    base_tasks.append({
        "source": src,
        "rr_tag": cfg["rr_tag"],
        "rr_asset_url": cfg["rr_asset_url"],
        "release_tag": rel_tag,
        "base_asset": base_asset,
        "docker_image": cfg["docker_image"],
        "docker_tag": cfg.get("docker_tag", "latest"),
    })
    for t in cfg.get("tasks", []):
        model = t["model"]
        if t.get("kind", "normal") != "normal":
            continue
        platform, kver = locate(model)
        ova_release_tag = ""
        ova_asset_glob = ""
        if use_prebuilt:
            ver = prebuilt_versions.get(src)
            if not ver:
                raise SystemExit(
                    "[E] 预装成品模式缺少 %s 源版本（PREBUILT_VERSIONS）" % src)
            ova_release_tag = "%s-ova-%s" % (src, ver)
            ova_asset_glob = "%s_%s_*.ova.gz" % (model, dsm_ver_digits)
        tasks.append({
            "source": src,
            "model": model,
            "model_slug": model_slug(model),
            "platform": platform,
            "kver": kver,
            "modules_key": "%s-%s-%s" % (platform, line, kver),
            "rr_tag": cfg["rr_tag"],
            "release_tag": rel_tag,
            "base_asset": base_asset,
            "docker_image": cfg["docker_image"],
            "docker_tag": cfg.get("docker_tag", "latest"),
            "ova_release_tag": ova_release_tag,
            "ova_asset_glob": ova_asset_glob,
            "modules_release_tag": modules_release_tag,
        })


def dump(v):
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
    f.write("base_tasks=" + dump(base_tasks) + "\n")
    f.write("tasks=" + dump(tasks) + "\n")
    f.write("task_count=%d\n" % len(tasks))

print("[INFO] base 任务: %d，模型任务: %d" % (len(base_tasks), len(tasks)))
for t in tasks:
    print("[INFO] %s/%s platform=%s kver=%s key=%s" % (
        t["source"], t["model"], t["platform"], t["kver"], t["modules_key"]))
PY
