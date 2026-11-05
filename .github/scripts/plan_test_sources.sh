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
#   KERNEL            official|custom（custom=aina-cks 自编 5.10.55 内核）
#   CKS_VERSION       ainas-cks Release 版本（custom 时留空=用 rr.img p3 内置 cks 快照）
#   ALL_PLATFORMS     true=按 .github/scripts/modtest/platform-representatives.tsv
#                     每个平台取一个代表型号（与 TEST_MODELS 互斥）；覆盖不全即退出 1
#
# 输出（GITHUB_OUTPUT）：
#   base_tasks       [{source, rr_tag, rr_asset_url, release_tag, base_asset, docker_image, docker_tag}]
#   tasks            [{source, model, model_slug, platform, kver, modules_key,
#                      kernel, cks_version,
#                      rr_tag, release_tag, base_asset, docker_image, docker_tag,
#                      ova_release_tag, ova_asset_glob, modules_release_tag}]
#   task_count
#   kernel

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

# 三段式（7.2.2 → 7.2）取前两段；两段式（7.0/7.1）本身即版本线（models.json
# 的 productvers 键就是 7.0/7.1，用 ${%.*} 会截成 "7" 导致查不到条目）。
DSM_LINE="${DSM_VERSION%.*}"
case "${DSM_VERSION}" in
  *.*.*) ;;
  *) DSM_LINE="${DSM_VERSION}" ;;
esac

# ── 预装成品模式：解析各源 OVA Release 与模块包版本 ─────────────────────
USE_PREBUILT="${USE_PREBUILT:-false}"
case "${USE_PREBUILT}" in
  true|false) ;;
  *) echo "[E] USE_PREBUILT 只允许 true/false: ${USE_PREBUILT}" >&2; exit 1 ;;
esac

KERNEL="${KERNEL:-official}"
case "${KERNEL}" in
  official|custom) ;;
  *) echo "[E] KERNEL 只允许 official/custom: ${KERNEL}" >&2; exit 1 ;;
esac
CKS_VERSION="${CKS_VERSION:-}"
if [ "${KERNEL}" = "custom" ] && [ "${USE_PREBUILT}" = "true" ]; then
  echo "[E] 预装成品模式不能与自定义内核组合（预装 rr.img 已按官方内核安装）" >&2
  exit 1
fi

MODULES_RELEASE_TAG="${MODULES_VERSION:-}"
# 两种模式都要测"本次指定的模块包"：预装模式注入已安装 OVA 的 p3，
# 非预装模式在编译前覆盖 base rr.img 的 p3/modules，避免 base 快照里的
# 旧模块包（与当前发布不同源）造成误报。留空时取最新 Release。
if [ -z "${MODULES_RELEASE_TAG}" ]; then
  MODULES_RELEASE_TAG="$(GH_REPO=myp015/syno-modules gh release view --json tagName --jq '.tagName')" || true
fi
[ -n "${MODULES_RELEASE_TAG}" ] || {
  echo "[E] 无法解析 syno-modules 模块包 Release 版本" >&2; exit 1; }
export USE_PREBUILT MODULES_RELEASE_TAG PREBUILT_VERSIONS DSM_VERSION RR_SOURCE
export KERNEL CKS_VERSION

# ── 全平台模式：按代表型号表展开 TEST_MODELS ───────────────────────────
# 一个平台一个代表型号即可覆盖该平台的模块包（key 是 platform-line-kver）。
# 表与 models.json 做双向覆盖校验：新增平台/表项过期都直接退出 1，
# 防止静默少跑。
ALL_PLATFORMS="${ALL_PLATFORMS:-false}"
case "${ALL_PLATFORMS}" in
  true|false) ;;
  *) echo "[E] ALL_PLATFORMS 只允许 true/false: ${ALL_PLATFORMS}" >&2; exit 1 ;;
esac
PLATFORM_TABLE="${PLATFORM_TABLE:-${SCRIPT_DIR}/modtest/platform-representatives.tsv}"
if [ "${ALL_PLATFORMS}" = "true" ]; then
  if [ -n "${TEST_MODELS:-}" ]; then
    echo "[E] all_platforms 与 test_models 互斥，只能二选一" >&2
    exit 1
  fi
  [ -f "${PLATFORM_TABLE}" ] || {
    echo "[E] 找不到代表型号表: ${PLATFORM_TABLE}" >&2; exit 1; }
  TEST_MODELS="$(python3 - "${PLATFORM_TABLE}" "${MODELS_JSON}" \
    "${DSM_LINE}" "${KERNEL}" <<'PY'
import json
import sys

table, models_json, line, kernel = sys.argv[1:5]

rows, excludes = [], {}
with open(table, encoding="utf-8") as f:
    for raw in f:
        s = raw.rstrip("\n")
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        parts = s.split("\t")
        if parts[0] == "!exclude" and len(parts) >= 3:
            excludes[parts[1]] = parts[2]
            continue
        if len(parts) != 3:
            sys.exit("[E] 代表型号表格式错误（应为 3 列 TAB）: %r" % s)
        rows.append({"platform": parts[0], "model": parts[1],
                     "kernels": [k for k in parts[2].split(",") if k]})

with open(models_json, encoding="utf-8") as f:
    models = json.load(f)

expected = {p for p, e in models.items()
            if isinstance(e, dict) and e.get("productvers", {}).get(line)}
if not expected:
    sys.exit("[E] models.json 中没有任何平台支持 DSM %s" % line)

known = {r["platform"] for r in rows}
missing = sorted(expected - known - set(excludes))
stale = sorted(known - expected)
if missing or stale:
    sys.exit("[E] 代表型号表与 models.json 不匹配：缺少 %s，多余 %s"
             % (", ".join(missing) or "-", ", ".join(stale) or "-"))

sel = [r for r in rows if kernel in r["kernels"]]
sel_platforms = {r["platform"] for r in sel}
if kernel == "custom":
    cks = {"epyc7002", "geminilakenk", "r1000nk", "v1000nk"}
    want = expected & cks
    bad = sorted(sel_platforms - cks)
    if bad:
        sys.exit("[E] custom 模式下列出了非 cks 平台: %s" % ", ".join(bad))
else:
    want = expected - set(excludes)
if sel_platforms != want:
    sys.exit("[E] KERNEL=%s 时应覆盖 %d 个平台，表只列出 %d 个：缺少 %s"
             % (kernel, len(want), len(sel_platforms),
                ", ".join(sorted(want - sel_platforms)) or "-"))

out = []
for r in sel:
    e = models.get(r["platform"], {})
    if r["model"] not in e.get("models", []):
        sys.exit("[E] %s 不属于平台 %s（models.json）" % (r["model"], r["platform"]))
    out.append(r["model"])
print(",".join(out))
PY
  )" || exit 1
  echo "[INFO] all_platforms 展开 $(printf '%s' "${TEST_MODELS}" | tr ',' '\n' | wc -l) 个型号: ${TEST_MODELS}"
fi

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
kernel = os.environ.get("KERNEL", "official")
cks_version = os.environ.get("CKS_VERSION", "")

# ainas-cks 支持矩阵（ainas-cks 仅有这些平台/版本的 bzImage 与模块包）
CKS_SUPPORTED = {
    "epyc7002": {"7.2", "7.3", "7.4"},
    "geminilakenk": {"7.2", "7.3", "7.4"},
    "r1000nk": {"7.2", "7.3", "7.4"},
    "v1000nk": {"7.2", "7.3", "7.4"},
}
CKS_KVER = "5.10.55"

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
        if kernel == "custom":
            if platform not in CKS_SUPPORTED or line not in CKS_SUPPORTED[platform]:
                raise SystemExit(
                    "[E] %s/%s 不在 ainas-cks 支持矩阵（%s）" % (
                        model, line, ", ".join(sorted(CKS_SUPPORTED))))
            kver = CKS_KVER
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
            "kernel": kernel,
            "cks_version": cks_version,
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
    # analyze job 用它判断是否双源（job 级 if 里 inputs 上下文不可靠，改走 plan 输出）
    f.write("source_mode=%s\n" % os.environ.get("RR_SOURCE", "ainas"))
    f.write("kernel=%s\n" % kernel)

print("[INFO] base 任务: %d，模型任务: %d" % (len(base_tasks), len(tasks)))
for t in tasks:
    print("[INFO] %s/%s platform=%s kver=%s key=%s" % (
        t["source"], t["model"], t["platform"], t["kver"], t["modules_key"]))
PY
