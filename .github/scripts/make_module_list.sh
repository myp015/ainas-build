#!/usr/bin/env bash
#
# 生成 guest 侧模块测试清单（写入 loader p3 的 modtest/ 目录）。
#
# 用法：
#   make_module_list.sh <modules.tgz> <kver> <输出目录> [条数上限]
#
# 输入：
#   modules.tgz  <platform>-<line>-<kver>.tgz（rr.img p3/modules 里的模块包）
#   kver         目标内核版本（用于 vermagic fail fast）
#   输出目录     清单与 guest 脚本落在这里，随 rr.img 一起被 DSM 读取
#   条数上限     >0 时只保留拓扑序前 N 条（CI smoke 用），0=全部
#
# 输出文件：
#   <输出目录>/module-list.tsv   idx name rel depends ko_srcver policy
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

command -v modinfo >/dev/null || { echo "[E] 缺少 modinfo（安装 kmod）" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

EXTRACT="${WORK}/modules"
mkdir -p "${EXTRACT}" "${OUT_DIR}"
tar xzf "${MODULES_TGZ}" -C "${EXTRACT}"

python3 - "${EXTRACT}" "${OUT_DIR}/module-list.tsv" "${LIMIT}" "${KVER}" <<'PY'
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

if vermagics:
    bad = sorted(v for v in vermagics if kver not in v)
    print("[INFO] 模块 vermagic: %s" % ", ".join(sorted(vermagics)))
    if bad:
        raise SystemExit(
            "[E] 模块 vermagic 与目标内核 %s 不匹配: %s" % (kver, ", ".join(bad)))
else:
    print("[WARN] 无法读取 vermagic（modinfo 不可用？）")

# 同名模块（root 与 update/）保留两条，依赖图按 name 去重（优先 root）
by_name = {}
for e in entries:
    if e["name"] not in by_name or e["policy"] == "root":
        by_name[e["name"]] = e

ordered, done, visiting = [], set(), set()


def visit(name):
    if name in done or name not in by_name:
        return
    if name in visiting:
        return  # 循环依赖：交给后续追加
    visiting.add(name)
    for dep in by_name[name]["depends"].split():
        dep = dep.strip()
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
    lines.append("%d\t%s\t%s\t%s\t%s\t%s" % (
        idx, e["name"], e["rel"], e["depends"].replace("\t", " "),
        e["srcver"], e["policy"]))
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

echo "[INFO] 清单已写入: ${OUT_DIR}/module-list.tsv"
wc -l "${OUT_DIR}/module-list.tsv"
