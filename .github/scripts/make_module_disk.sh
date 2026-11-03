#!/usr/bin/env bash
#
# 生成模块测试用的 ext4 第二块盘（guest 内挂载读取）。
#
# 用法：
#   make_module_disk.sh <modules.tgz> <kver> <输出镜像> <guest脚本目录> [条数上限]
#
# 输入：
#   modules.tgz   <platform>-<line>-<kver>.tgz（由 rr.img 的 p3/modules 复制）
#   kver          内核版本（如 5.10.55）
#   输出镜像      例如 rr/modtest.img
#   guest脚本目录 含 run-module-tests.sh / probe.commands / read-results.sh
#
# 盘内布局：
#   /payload/modules/       解包后的 .ko（含 update/）
#   /payload/module-list.tsv 拓扑排序后的清单
#   /payload/run-module-tests.sh
#   /payload/probe.commands
#   /results/               测试结果（guest 写入，host 回读）

set -euo pipefail

MODULES_TGZ="${1:?缺少 modules.tgz}"
KVER="${2:?缺少 kver}"
OUT_IMG="${3:?缺少输出镜像路径}"
GUEST_DIR="${4:?缺少 guest 脚本目录}"
LIMIT="${5:-0}"  # >0 时只保留清单前 N 条（CI smoke 用），0=全部

command -v mkfs.ext4 >/dev/null || { echo "[E] 缺少 mkfs.ext4（安装 e2fsprogs）" >&2; exit 1; }
command -v modinfo >/dev/null || { echo "[E] 缺少 modinfo（安装 kmod）" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

STAGE="${WORK}/stage"
PAYLOAD="${STAGE}/payload"
mkdir -p "${PAYLOAD}/modules" "${STAGE}/results"

echo "[INFO] 解包模块包: ${MODULES_TGZ}"
tar xzf "${MODULES_TGZ}" -C "${PAYLOAD}/modules"

# ── 生成模块清单（name / relpath / depends / srcversion / policy）────
python3 - "${PAYLOAD}/modules" "${PAYLOAD}/module-list.tsv" "${LIMIT}" "${KVER}" <<'PY'
import os, subprocess, sys

root, out, limit, kver = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


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
        entries.append({
            "name": name, "rel": rel, "depends": depends,
            "srcver": srcver, "policy": policy,
        })

# fail fast：模块与安装内核版本不一致时，逐个 insmod 只会得到一片无意义的
# version magic 报错，必须在生成测试盘前就暴露
if vermagics:
    bad = sorted(v for v in vermagics if kver not in v)
    print("[INFO] 模块 vermagic: %s" % ", ".join(sorted(vermagics)))
    if bad:
        raise SystemExit(
            "[E] 模块 vermagic 与目标内核 %s 不匹配: %s" % (kver, ", ".join(bad)))
else:
    print("[WARN] 无法读取 vermagic（modinfo 不可用？）")

# 同名模块（root 与 update/）保留两条，但依赖图按 name 去重（优先 root）
by_name = {}
for e in entries:
    if e["name"] not in by_name or e["policy"] == "root":
        by_name[e["name"]] = e

# 拓扑排序：依赖在前；循环依赖/缺失依赖的节点最后追加
ordered, done, visiting = [], set(), set()


def visit(name, chain=()):
    if name in done or name not in by_name:
        return
    if name in visiting:
        return  # 循环依赖：交给后续追加
    visiting.add(name)
    for dep in by_name[name]["depends"].split():
        dep = dep.strip()
        if dep:
            visit(dep, chain + (name,))
    visiting.discard(name)
    done.add(name)
    ordered.append(by_name[name])


for name in sorted(by_name):
    visit(name)

# 未被拓扑到的（循环依赖）追加在末尾
for name in sorted(by_name):
    if name not in done:
        ordered.append(by_name[name])

# 输出顺序：拓扑序的 root/update 条目 + 同名 update 条目附在最后
lines = []
idx = 0
for e in ordered:
    idx += 1
    lines.append("%d\t%s\t%s\t%s\t%s\t%s" % (
        idx, e["name"], e["rel"], e["depends"].replace("\t", " "),
        e["srcver"], e["policy"]))
# 补上被去重的 update 同名条目（安全档下会因已加载而跳过）
for e in entries:
    if e["policy"] == "update" and by_name.get(e["name"], {}).get("rel") != e["rel"]:
        idx += 1
        lines.append("%d\t%s\t%s\t%s\t%s\t%s" % (
            idx, e["name"], e["rel"], e["depends"].replace("\t", " "),
            e["srcver"], e["policy"]))

total = len(lines)
if limit > 0 and total > limit:
    lines = lines[:limit]
    print("[INFO] 按上限 %d 截断清单: %d/%d" % (limit, len(lines), total))

with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print("[INFO] 模块条目: %d（去重后拓扑节点: %d）" % (len(lines), len(ordered)))
PY

cp -f "${GUEST_DIR}/run-module-tests.sh" "${PAYLOAD}/run-module-tests.sh"
chmod +x "${PAYLOAD}/run-module-tests.sh"

# ── 生成 ext4 镜像（-d 直接灌目录，无需 mount）────────────────────────
SIZE_MB=$(du -sm "${STAGE}" | cut -f1)
SIZE_MB=$((SIZE_MB + 96))
[ "${SIZE_MB}" -lt 256 ] && SIZE_MB=256
if [ "${SIZE_MB}" -gt 2048 ]; then
  echo "[E] 模块盘需要 ${SIZE_MB}MB，超过 2GB 上限" >&2
  exit 1
fi
echo "[INFO] 生成 ext4 模块盘: ${OUT_IMG}（${SIZE_MB}MB）"
truncate -s "${SIZE_MB}M" "${OUT_IMG}"
mkfs.ext4 -F -q -L MODTEST -d "${STAGE}" "${OUT_IMG}"

echo "[INFO] 模块盘校验:"
debugfs -R 'ls -l /payload' "${OUT_IMG}" 2>/dev/null | head -n 10
