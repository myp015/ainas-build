#!/usr/bin/env bash
#
# 生成 guest 侧模块测试清单（写入 loader p3 的 modtest/ 目录）。
#
# 用法：
#   make_module_list.sh <modules.tgz> <kver> <输出目录> [条数上限] [平台]
#
# 输入：
#   modules.tgz  <platform>-<line>-<kver>.tgz（rr.img p3/modules 里的模块包）
#   kver         目标内核版本（用于 vermagic fail fast）
#   输出目录     清单与 guest 脚本落在这里，随 rr.img 一起被 DSM 读取
#   条数上限     >0 时只保留拓扑序前 N 条（CI smoke 用），0=全部
#   平台         可选；给出时按 modtest/known-hazards.tsv 匹配，命中模块
#                policy 置 hazard（guest 侧只记录、绝不 insmod）
#
# policy 取值：
#   root     常规模块，未加载则 insmod
#   update   update/ 同名模块，root 已加载时 SKIP_UPDATE
#   hazard   已知官方内核缺陷，guest 一律 SKIP_HAZARD
#
# 输出文件：
#   <输出目录>/module-list.tsv   idx name rel depends ko_srcver policy
#                                 （depends/ko_srcver 为空时写 "-"，防止 read 折叠空列）
#   <输出目录>/run-module-tests.sh（由调用方复制 guest 脚本）
#
# 说明：不再生成独立的 ext4 模块盘。实测 DSM 会把额外的 USB 存储命名为
# synoboot（与引导盘冲突）、把额外 ahci 盘当内部盘并触发 NCQ 错误，因此
# 模块包直接从引导盘 p3 读取，测试结果经串口输出。

set -euo pipefail

MODULES_TGZ="${1:?缺少 modules.tgz}"
KVER="${2:?缺少 kver}"
OUT_DIR="${3:?缺少输出目录}"
LIMIT="${4:-0}"
PLATFORM="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAZARDS="${SCRIPT_DIR}/modtest/known-hazards.tsv"

command -v modinfo >/dev/null || { echo "[E] 缺少 modinfo（安装 kmod）" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

EXTRACT="${WORK}/modules"
mkdir -p "${EXTRACT}" "${OUT_DIR}"
tar xzf "${MODULES_TGZ}" -C "${EXTRACT}"

python3 - "${EXTRACT}" "${OUT_DIR}/module-list.tsv" "${LIMIT}" "${KVER}" \
          "${PLATFORM}" "${HAZARDS}" <<'PY'
import os, re, subprocess, sys

(root, out, limit, kver,
 platform, hazards_path) = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], \
                          sys.argv[5], sys.argv[6]


def load_hazards(path, platform):
    """读取 platform<TAB>module<TAB>原因；platform 支持 *。"""
    if not platform or not os.path.exists(path):
        return set()
    hit = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise SystemExit("[E] known-hazards 行格式非法: %r" % line)
            p, mod = parts[0].strip(), parts[1].strip()
            if p in (platform, "*"):
                hit.add(mod.replace("-", "_"))
    return hit


HAZARDS = load_hazards(hazards_path, platform)


def modinfo(path, field):
    try:
        return subprocess.run(
            ["modinfo", "-F", field, path],
            capture_output=True, text=True, check=False
        ).stdout.strip()
    except Exception:
        return ""


entries = []
vermagics = set()
for dirpath, _dirnames, filenames in os.walk(root):
    for fn in filenames:
        if not fn.endswith(".ko"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        name = modinfo(path, "name") or fn[:-3].replace("-", "_")
        depends = modinfo(path, "depends") or ""
        srcver = modinfo(path, "srcversion") or ""
        vm = modinfo(path, "vermagic")
        if vm:
            vermagics.add(vm)
        policy = "update" if rel.startswith("update/") else "root"
        # 已知官方内核缺陷：无论 root/update 一律置 hazard，guest 不加载
        if name.replace("-", "_") in HAZARDS:
            policy = "hazard"
            print("[WARN] 命中 known-hazards: %s (%s)" % (name, rel))
        entries.append({
            "name": name, "rel": rel, "depends": depends,
            "srcver": srcver, "policy": policy,
        })

if vermagics:
    bad = sorted(v for v in vermagics if kver not in v)
    print("[INFO] 模块 vermagic: %s" % ", ".join(sorted(vermagics)))
    if bad:
        raise SystemExit(
            "[E] 模块 vermagic 与目标内核 %s 不匹配: %s" % (kver, ", ".join(bad)))
else:
    print("[WARN] 无法读取 vermagic（modinfo 不可用？）")

# 同名模块（root 与 update/）保留两条，依赖图按 name 去重（优先 root）
#
# 命名风格差异（全量测试实锤）：modinfo -F name 给下划线名（snd_hda_codec），
# 而 depends 字段给连字符名（snd-hda-core,snd-pcm,i915-compat）。按原样查表
# 会让所有连字符依赖查不到、从未被前置加载，snd/DRM 升级栈整体 Unknown symbol。
def norm(name):
    return name.replace("-", "_")


by_name = {}
for e in entries:
    key = norm(e["name"])
    if key not in by_name or e["policy"] == "root":
        by_name[key] = e

ordered, done, visiting = [], set(), set()


def visit(name):
    if name in done or name not in by_name:
        return
    if name in visiting:
        return  # 循环依赖：交给后续追加
    visiting.add(name)
    # modinfo -F depends 是逗号分隔（如 "cfg80211,aic_load_fw,usbcore"），
    # 早先只按空白切分导致多依赖模块的依赖从未被提前排序加载
    # （aic8800_fdrv / 9pnet_virtio 因此 Unknown symbol）。
    # 依赖名同时做连字符→下划线归一（depends 用 snd-pcm，name 用 snd_pcm）。
    for dep in re.split(r"[,\s]+", by_name[name]["depends"]):
        dep = norm(dep.strip())
        if dep:
            visit(dep)
    visiting.discard(name)
    done.add(name)
    ordered.append(by_name[name])


for name in sorted(by_name):
    visit(name)

for name in sorted(by_name):
    if name not in done:
        ordered.append(by_name[name])

lines = []
idx = 0
for e in ordered:
    idx += 1
    # 空字段必须写 "-"：guest 侧 `IFS=<TAB> read` 会把连续的 TAB 折叠成一个
    # 分隔符（TAB 属空白类 IFS），空 depends/srcver 会让后续列整体左移 ——
    # 实测后果是 pkg 变成 policy 值（pkg=root）、hazard 策略丢失（不再跳过）。
    lines.append("%d\t%s\t%s\t%s\t%s\t%s" % (
        idx, e["name"], e["rel"], e["depends"].replace("\t", " ") or "-",
        e["srcver"] or "-", e["policy"]))
for e in entries:
    if e["policy"] == "update" and by_name.get(norm(e["name"]), {}).get("rel") != e["rel"]:
        idx += 1
        lines.append("%d\t%s\t%s\t%s\t%s\t%s" % (
            idx, e["name"], e["rel"], e["depends"].replace("\t", " ") or "-",
            e["srcver"] or "-", e["policy"]))

total = len(lines)
if limit > 0 and total > limit:
    lines = lines[:limit]
    print("[INFO] 按上限 %d 截断清单: %d/%d" % (limit, len(lines), total))

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print("[INFO] 模块条目: %d（去重后拓扑节点: %d）" % (len(lines), len(ordered)))
PY

echo "[INFO] 清单已写入: ${OUT_DIR}/module-list.tsv"
wc -l "${OUT_DIR}/module-list.tsv"
