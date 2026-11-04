#!/usr/bin/env python3
#
# 解析 guest 侧模块测试结果（@@M / @@P / dmesg 摘要），执行机器门禁。
#
# 输入：ova-test 的 artifact 目录（含 <profile>/cmd-*.out）、module-list.tsv、
# 可选 modtest-meta.txt / cks-image-info.txt、白名单与基线。
# 输出：<prefix>.json、<prefix>.summary.md、<prefix>-baseline-candidate.json。
#
# 退出码：0=门禁通过；1=门禁失败；2=输入/环境错误。
#
# 约定（与 guest/run-module-tests.sh 一致）：
#   @@M|<idx>|<name>|<state>|<rc>|<details>
#   details 中可能含 "src=<sys_srcversion> pkg=<pkg_srcversion> err=<text>"
#   @@MODTEST_DONE@@ total=.. loaded=.. ok=.. fail=.. skip=.. status=done
#   @@P|<tag>|begin .. @@P|<tag>|end（kernelid / installed / bootloaded）
#   ---DMESG-BEGIN--- .. ---DMESG-END---
#
# 安全原则：只有白名单类别（ENV/BUILTIN/BUILTIN_DUP/DEP_ENV/DMESG_WARNING）
# 允许豁免；Unknown symbol / 真·vermagic 不匹配 / 依赖顺序 / MISSING / 内核崩溃
# 一律硬失败。
#
# BUILTIN_DUP：模块导出名与**内核已导出符号**重名，内核打印
# "<mod>: exports duplicate symbol <sym> (owned by <owner>)" 并以 ENOEXEC 拒绝
# 加载（insmod 只显示 "Invalid module format"，极易误判成 vermagic）。这是
# "内核已内建/已加载同名功能"的等价情形，不是模块缺陷；但必须有该 dmesg 证据
# 才降级，否则仍按 VERMAGIC 硬失败（防止把真 vermagic 问题静默掩盖）。

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

HARD_CATEGORIES = {"UNKNOWN_SYMBOL", "VERMAGIC", "DEPEND", "MISSING", "OTHER",
                   "STALE_LOADED", "KERNEL_FAULT"}
# DEP_ENV：依赖模块因环境缺失（ENV/BUILTIN）未加载，依赖方随之 Unknown symbol。
# 典型：非 Hyper-V 环境下 hv_vmbus "No such device"，hid_hyperv/hv_netvsc 等
# 全部 Unknown symbol —— 属环境级联，不是模块缺陷。
ENV_CATEGORIES = {"ENV", "BUILTIN", "BUILTIN_DUP", "DEP_ENV"}
ALLOWABLE_CATEGORIES = ENV_CATEGORIES | {"DMESG_WARNING"}

# KERNEL_INTERNAL：崩溃现场 IP 落在**内核内建代码**（IP 行无 [模块] 归属），
# 模块只是在调用链上触发了它（典型：scsi_debug 合成磁盘进入 sd_probe 的
# syno_usb_info_enum，官方 4.4.302 内核在非 USB host 上解引用 NULL）。
# 这类崩溃模块侧无法修复，但仍需白名单显式豁免（不静默放过）；
# IP 解析不到或 IP 在模块内时一律按 KERNEL_FAULT 硬失败（保守，防误放）。
KERNEL_INTERNAL_CATEGORY = "KERNEL_INTERNAL"
# 同一现场会让 insmod 随之失败（模块在 probe 里进内核内建代码崩溃），
# 因此模块侧失败也归 KERNEL_INTERNAL，白名单一行同时覆盖 G-M2 与 G-M4。
ALLOWABLE_CATEGORIES = ALLOWABLE_CATEGORIES | {KERNEL_INTERNAL_CATEGORY}

# 真故障只认 BUG/Oops/panic/#PF/GP 行：这几种一律先打印其中一句，再跟 Call Trace。
# **不能把 "Call Trace" 单独当故障** —— 同一行也跟在每次 WARNING 后面
# （典型：cfg80211 regulatory_init 的 reg.c WARN、binder 的 sysfs_warn_dup、
# DSM 的 "inconsistent syno gpio info"），否则所有内核自带 WARN 都会把 G-M4 判失败。
FAULT_RE = re.compile(
    r"(BUG:|Oops|Kernel panic|Unable to handle|general protection)")
# 故障现场 IP 行（x86 4.4/5.10 两种写法都覆盖）：
#   IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130
#   RIP: 0010:[<ffffffffa2628ad3>]  [<ffffffffa2628ad3>] sdebug_driver_probe+0x.. [scsi_debug]
# group(1)=符号名（可能是 "sym+off/size"），group(2)=模块名（有 [mod] 尾注时）。
IP_RE = re.compile(
    r"(?:IP|RIP):\s*(?:[0-9a-fA-F]{4}:)?\s*(?:\[<[0-9a-fA-F]+>\])?\s*"
    r"(?:\[<[0-9a-fA-F]+>\]\s*)?([^ \t\[]+)(?:\s+\[([^\]\s]+)\])?")
WARNING_RE = re.compile(r"WARNING:")
FIRMWARE_FAIL_RE = re.compile(r"firmware.*(fail|error)", re.I)
MARKER_RE = re.compile(r"modtest-marker idx=(\d+) name=(\S+)")
UNKNOWN_SYM_RE = re.compile(r"Unknown symbol (\S+)")
DUP_EXPORT_RE = re.compile(r"exports duplicate symbol (\S+)")

M_RE = re.compile(r"^@@M\|(\d+)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$")
DONE_RE = re.compile(
    r"^@@MODTEST_DONE@@(.*)$")
DONE_KV_RE = re.compile(r"(\w+)=(\S+)")
SRC_RE = re.compile(r"\bsrc=(\S+)")
PKG_RE = re.compile(r"\bpkg=(\S+)")


def die(msg):
    sys.stderr.write("[E] %s\n" % msg)
    raise SystemExit(2)


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return [ANSI_RE.sub("", line.rstrip("\r\n")) for line in f]


def find_cmd_outputs(logs_dir, profile):
    """递归找 cmd-*.out；给了 profile 时只取同名目录下的文件。"""
    out = []
    for root, _dirs, files in os.walk(logs_dir):
        if profile and os.path.basename(root) != profile:
            continue
        for fn in files:
            m = re.match(r"cmd-(\d+)\.out$", fn)
            if m:
                out.append((int(m.group(1)), os.path.join(root, fn)))
    if not out:
        die("在 %s 下未找到 %s 的 cmd-*.out" % (logs_dir, profile or "任意 profile"))
    out.sort(key=lambda x: (os.path.dirname(x[1]), x[0]))
    return [p for _i, p in out]


def parse_section(lines, tag):
    """抽取 @@P|<tag>|begin/end 之间的行；marker 必须整行相等（避免回显命令干扰）。"""
    begin, end = "@@P|%s|begin" % tag, "@@P|%s|end" % tag
    chunks, cur = [], None
    for line in lines:
        s = line.strip()
        if s == begin:
            cur = []
            continue
        if s == end and cur is not None:
            chunks.append(cur)
            cur = None
            continue
        if cur is not None:
            cur.append(line)
    return chunks


def parse_dmesg(lines):
    begin, end = "---DMESG-BEGIN---", "---DMESG-END---"
    chunks, cur = [], None
    for line in lines:
        s = line.strip()
        if s == begin:
            cur = []
            continue
        if s == end and cur is not None:
            chunks.append(cur)
            cur = None
            continue
        if cur is not None:
            cur.append(line)
    return [l for c in chunks for l in c]


def load_module_list(path):
    """返回 list[dict] 与 name -> {srcversions} 映射。"""
    entries = []
    for line in read_lines(path):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 6:
            die("module-list.tsv 行格式非法: %r" % line)
        idx, name, rel, depends, srcver, policy = parts[:6]
        # "-" 是清单里空字段的占位符（见 make_module_list.sh）
        srcver = "" if srcver == "-" else srcver
        entries.append({"idx": int(idx), "name": name, "rel": rel,
                        "depends": depends, "srcver": srcver, "policy": policy})
    return entries


def load_allowlist(path):
    """读取白名单。

    当前格式（8 列，TAB 分隔）：
        platform  line  kver  model  kernel  name  category  reason
    兼容旧的 7 列格式（无 kernel 列，等价 kernel=*）：
        platform  line  kver  model  name  category  reason
    kernel 列用于区分 official/custom：custom 构建的镜像与测试包同源，
    任何身份/版本差异都是真缺陷，不应被 official 的豁免顺带掩盖。
    """
    rows = []
    if not path:
        return rows
    for line in read_lines(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split("\t")
        if len(parts) >= 8:
            platform, ln, kver, model, kernel = parts[:5]
            name, category, reason = parts[5], parts[6], " ".join(parts[7:])
        elif len(parts) >= 7:
            platform, ln, kver, model, name = parts[:5]
            kernel, category, reason = "*", parts[5], " ".join(parts[6:])
        elif len(parts) == 6:
            platform, ln, kver, model, name = parts[:5]
            kernel, category, reason = "*", "ENV", parts[5]
        else:
            die("白名单行格式非法: %r" % line)
        rows.append({"platform": platform, "line": ln, "kver": kver,
                     "model": model, "kernel": kernel, "name": name,
                     "category": category, "reason": reason})
    return rows


def allowlisted(row, ctx):
    def match(pat, val):
        return pat == "*" or fnmatch.fnmatchcase(val, pat)
    return (match(row["platform"], ctx["platform"])
            and match(row["line"], ctx["line"])
            and match(row["kver"], ctx["kver"])
            and match(row["model"], ctx["model"])
            and match(row["kernel"], ctx["kernel"])
            and fnmatch.fnmatchcase(ctx["name"], row["name"])
            and row["category"] == ctx["category"])


def classify(err):
    e = err.lower()
    if "unknown symbol" in e:
        return "UNKNOWN_SYMBOL"
    if "invalid module format" in e or "version magic" in e or "vermagic" in e:
        return "VERMAGIC"
    if "already loaded" in e:
        return "DEPEND"
    if "file exists" in e:
        # 模块已内建（builtin）时 insmod 报 File exists，属环境差异而非排序缺陷。
        return "BUILTIN"
    env_tokens = ("no such device", "no such file", "operation not permitted",
                  "operation not supported", "device or resource busy",
                  "invalid argument", "unknown parameter")
    if any(t in e for t in env_tokens):
        return "ENV"
    return "OTHER"


def analyze(args):
    if not os.path.isdir(args.logs):
        die("日志目录不存在: %s" % args.logs)
    if not os.path.isfile(args.module_list):
        die("清单不存在: %s" % args.module_list)

    module_list = load_module_list(args.module_list)
    pkg_src = {}
    for e in module_list:
        if e["srcver"]:
            pkg_src.setdefault(e["name"], set()).add(e["srcver"])

    cmd_files = find_cmd_outputs(args.logs, args.profile)
    lines = []
    for f in cmd_files:
        lines.extend(read_lines(f))

    records, done_kv, mount_rc = [], None, None
    for line in lines:
        s = line.strip()
        m = M_RE.match(s)
        if m:
            details = m.group(5)
            src_m = SRC_RE.search(details)
            pkg_m = PKG_RE.search(details)
            pkg_val = pkg_m.group(1) if pkg_m else ""
            if pkg_val == "-":
                pkg_val = ""
            records.append({
                "idx": int(m.group(1)), "name": m.group(2), "state": m.group(3),
                "rc": m.group(4), "details": details,
                "src": src_m.group(1) if src_m else "-",
                "pkg": pkg_val,
                "err": "",
            })
            continue
        m = DONE_RE.match(s)
        if m:
            done_kv = dict(DONE_KV_RE.findall(m.group(1)))
            continue
        m = re.match(r"^MODTEST_MOUNT_RC=(\d+)$", s)
        if m:
            mount_rc = int(m.group(1))

    # err 文本：details 里 " err=" 之后的部分；老格式则整段就是错误文本
    for r in records:
        d = r["details"]
        if " err=" in d:
            r["err"] = d.split(" err=", 1)[1]
        elif d and "src=" not in d and "pkg=" not in d and d != "-":
            r["err"] = d

    # dmesg 摘要归因
    # 故障按「块」计数（一次 Oops 会打印 BUG:/Oops:/Call Trace 多行，同一现场
    # 只算一次），并按现场 IP 归属拆成两类：
    #   - IP 有 [模块] 尾注（或解析不到 IP）→ KERNEL_FAULT，模块侧硬失败；
    #   - IP 是内核内建符号（无 [模块]）→ KERNEL_INTERNAL，可经白名单豁免。
    fault_by_name, internal_by_name = {}, {}
    fault_syms, internal_syms = {}, {}
    warnings_by_name = {}
    firmware_fail = 0
    unknown_syms = {}
    dup_exports_by_name = {}
    cur_name = None
    fault_owner, fault_kind, fault_sym = None, None, ""

    def close_fault():
        nonlocal fault_owner, fault_kind, fault_sym
        if fault_owner is None:
            return
        key = fault_owner
        if fault_kind == "internal":
            internal_by_name[key] = internal_by_name.get(key, 0) + 1
            if fault_sym:
                internal_syms.setdefault(key, set()).add(fault_sym)
        else:
            # IP 在模块内、或无法解析 IP：保守按模块侧硬失败。
            fault_by_name[key] = fault_by_name.get(key, 0) + 1
            if fault_sym:
                fault_syms.setdefault(key, set()).add(fault_sym)
        fault_owner, fault_kind, fault_sym = None, None, ""

    for line in parse_dmesg(lines):
        m = MARKER_RE.search(line)
        if m:
            close_fault()
            cur_name = m.group(2)
            continue
        if "end trace" in line:
            close_fault()
            continue
        if FIRMWARE_FAIL_RE.search(line):
            firmware_fail += 1
        m = UNKNOWN_SYM_RE.search(line)
        if m:
            key = cur_name or "<unknown>"
            unknown_syms.setdefault(key, set()).add(m.group(1))
        m = DUP_EXPORT_RE.search(line)
        if m:
            # 与内核导出面重名：内核返回 ENOEXEC（insmod 显示 Invalid module format）。
            key = cur_name or "<unknown>"
            dup_exports_by_name.setdefault(key, set()).add(m.group(1))
        if WARNING_RE.search(line):
            key = cur_name or "<unknown>"
            warnings_by_name[key] = warnings_by_name.get(key, 0) + 1
        if fault_owner is None:
            if FAULT_RE.search(line):
                fault_owner = cur_name or "<unknown>"
                fault_kind = None
        else:
            m = IP_RE.search(line)
            if m and fault_kind is None:
                fault_sym = m.group(1)
                fault_kind = "module" if m.group(2) else "internal"
    close_fault()

    allow_rows = load_allowlist(args.allowlist)

    def is_allowed(name, category):
        ctx = {"platform": args.platform, "line": args.line, "kver": args.kver,
               "model": args.model, "kernel": args.kernel, "name": name,
               "category": category}
        return any(allowlisted(row, ctx) for row in allow_rows)

    failures, skips, stale = [], [], []
    hazard = 0

    for r in records:
        state = r["state"]
        if state == "SKIP_HAZARD":
            hazard += 1
            continue
        if state in ("LOADED", "SKIP_UPDATE", "INSMOD_OK"):
            pkg_set = pkg_src.get(r["name"], set())
            sys_src = r["src"]
            if pkg_set and sys_src not in (None, "", "-") and sys_src not in pkg_set:
                stale.append({**r, "category": "STALE_LOADED",
                              "allowed": is_allowed(r["name"], "STALE_LOADED"),
                              "err": "运行时 srcversion=%s 不在包内 %s"
                                     % (sys_src, sorted(pkg_set))})
            continue
        if state != "INSMOD_FAIL" and state != "MISSING":
            # 未知状态按失败处理，避免静默
            failures.append({**r, "category": "OTHER", "allowed": False,
                             "err": "未知状态: %s" % state})
            continue

        category = "MISSING" if state == "MISSING" else classify(r["err"])
        # 崩溃现场在内核内建代码（见上 dmesg 归因）时，模块只是触发方；
        # insmod 随崩溃失败，归同类别（白名单按 KERNEL_INTERNAL 豁免）。
        if state == "INSMOD_FAIL" and r["name"] in internal_by_name:
            category = KERNEL_INTERNAL_CATEGORY
        # "Invalid module format" 有两类根因：真 vermagic 不匹配（硬失败）与
        # 模块导出名撞上内核已导出符号（内核 prints "exports duplicate symbol"
        # 后返回 ENOEXEC）。只有拿到 diag 证据才降级为 BUILTIN_DUP。
        if category == "VERMAGIC" and r["name"] in dup_exports_by_name:
            category = "BUILTIN_DUP"
        allowed = (category in ALLOWABLE_CATEGORIES
                   and is_allowed(r["name"], category))
        item = {**r, "category": category, "allowed": allowed}
        if allowed:
            skips.append(item)
        else:
            failures.append(item)

    # 依赖环境级联：某模块的依赖因环境缺失（ENV/BUILTIN）未加载时（典型：
    # 非 Hyper-V 环境的 hv_vmbus "No such device"），依赖方随之 Unknown symbol，
    # 属环境级联而非模块缺陷。只做"降级到 DEP_ENV"，仍需白名单显式豁免。
    dep_map = {}
    for e in module_list:
        dep_map.setdefault(e["name"], []).extend(
            d.replace("-", "_")
            for d in re.split(r"[,\s]+", e["depends"]) if d and d != "-")
    # SKIP_UPDATE / LOADED 也计入"环境缺失"：系统已加载同名模块（多为官方
    # 内核自带的旧栈或官方 PAT 模块），包内版本因此根本没参与运行，依赖它的
    # 模块必然解析失败 —— 这是环境限制（典型：官方 DRM 已加载，update/ 6.5
    # 栈的 ttm/amdgpu 级联 Unknown symbol；官方 ib_core/mlx4_core 已加载，
    # 包内新版 ib_uverbs/mlx4_en 缺符号），不是依赖顺序缺陷。
    env_down = {x["name"] for x in failures + skips
                if x["category"] in ENV_CATEGORIES}
    env_down |= {r["name"] for r in records
                 if r["state"] in ("SKIP_UPDATE", "LOADED")}
    cascaded = []
    for f in failures:
        if f["category"] != "UNKNOWN_SYMBOL":
            continue
        hit = sorted({d for d in dep_map.get(f["name"], []) if d in env_down})
        if not hit:
            continue
        f["category"] = "DEP_ENV"
        f["err"] = "%s（依赖 %s 环境缺失）" % (f["err"], ",".join(hit))
        f["allowed"] = is_allowed(f["name"], "DEP_ENV")
        if f["allowed"]:
            cascaded.append(f)
    for f in cascaded:
        failures.remove(f)
        skips.append(f)

    for name, syms in unknown_syms.items():
        for f in failures:
            if f["name"] == name and f["category"] == "UNKNOWN_SYMBOL":
                f["symbols"] = sorted(syms)
                break

    kernel_faults = ([{"name": n, "hits": c, "kind": "module", "allowed": False,
                       "symbols": sorted(fault_syms.get(n, ()))}
                      for n, c in fault_by_name.items()]
                     + [{"name": n, "hits": c, "kind": "internal",
                         "allowed": is_allowed(n, KERNEL_INTERNAL_CATEGORY),
                         "symbols": sorted(internal_syms.get(n, ()))}
                        for n, c in internal_by_name.items()])
    warning_faults = [{"name": n, "hits": c} for n, c in warnings_by_name.items()]

    # 汇总计数
    total = len(records)
    loaded = sum(1 for r in records if r["state"] == "LOADED")
    ok = sum(1 for r in records if r["state"] == "INSMOD_OK")
    fail = sum(1 for r in records
               if r["state"] in ("INSMOD_FAIL", "MISSING") or
               r["state"] not in ("LOADED", "SKIP_UPDATE", "INSMOD_OK", "SKIP_HAZARD"))
    skip = sum(1 for r in records if r["state"] in ("SKIP_UPDATE", "SKIP_HAZARD"))

    gates = []
    def gate(gid, okflag, detail, warn=False):
        # warn=True 表示"报告但不阻断"：pass 恒真，输出 [WARN]
        gates.append({"id": gid, "pass": True if warn else bool(okflag),
                      "detail": detail, "level": "warn" if warn else "fail"})

    declared = done_kv or {}
    counts_ok = True
    if declared:
        expect = {"total": total, "loaded": loaded, "ok": ok,
                  "fail": fail, "skip": skip}
        try:
            for key, val in expect.items():
                if key in declared and int(declared[key]) != val:
                    counts_ok = False
        except ValueError:
            counts_ok = False
    gate("G-M1", done_kv is not None and mount_rc == 0 and counts_ok
         and total == len(module_list),
         "完成标记=%s mount_rc=%s 逐条=%d 清单=%d" %
         (done_kv is not None, mount_rc, total, len(module_list)))

    hard = [f for f in failures]
    gate("G-M2", not hard,
         "未白名单失败 %d 条" % len(hard) + (
             ": " + ", ".join("%s(%s)" % (f["name"], f["category"]) for f in hard[:8])
             if hard else ""))

    # 运行内核的模块树是否由本次测试包构建：
    #   - custom 内核：系统模块树来自本次自编模块包，必须与包内版本一致；
    #   - official 内核：系统模块树来自官方 DSM PAT（安装器只装官方映射子集），
    #     与测试包天然不同源；预装模式同样如此。这类差异只作告警，
    #     真实缺陷仍由 G-M1/G-M2/G-M4/G-M8 与失败基线拦截。
    install_drift = bool(args.prebuilt) or args.kernel != "custom"
    drift_reason = "预装模式" if args.prebuilt else "官方内核"

    # G-M3：运行中模块的 srcversion 不是测试包那一版。
    #   - 严格模式（custom 内核）：硬失败 —— 说明测的不是这一版；
    #   - 漂移模式（official 内核/预装）：告警 —— 已加载模块来自官方 PAT 或
    #     base rr.img 的旧构建，本来就不参与 insmod 测试。差异仍逐条列进
    #     summary/JSON，供判断安装镜像是否过期。
    stale_fail = [] if args.allow_stale_loaded else \
        [s for s in stale if not s["allowed"]]
    stale_detail = ("STALE_LOADED %d 条（pkg 与运行内核不一致）" % len(stale) + (
        ": " + ", ".join("%s(src=%s pkg=%s)" % (s["name"], s["src"], s["pkg"])
                         for s in stale_fail[:8]) if stale_fail else ""))
    if install_drift:
        gate("G-M3", True, stale_detail + ("（%s按告警处理）" % drift_reason),
             warn=bool(stale_fail))
    else:
        gate("G-M3", not stale_fail, stale_detail)

    # KERNEL_FAULT（IP 在模块内或无法定位）不可豁免；KERNEL_INTERNAL（IP 在
    # 内核内建代码）必须由白名单显式登记，登记后只报告不阻断。
    fault_blocking = [f for f in kernel_faults if not f["allowed"]]
    fault_detail = "内核崩溃/异常归因 %d 条" % len(fault_blocking)
    if fault_blocking:
        fault_detail += ": " + ", ".join(
            "%s(%s%s)" % (f["name"], f["kind"],
                          "/" + ",".join(f["symbols"]) if f["symbols"] else "")
            for f in fault_blocking[:8])
    gate("G-M4", not fault_blocking, fault_detail)

    # P0-4 安装集核对
    # guest 侧每行：<文件名>[TAB<srcversion>]（modinfo 不可用时只有文件名）
    installed_chunks = parse_section(lines, "installed")
    installed, inst_src = set(), {}
    for c in installed_chunks:
        for line in c:
            s = line.strip()
            if not s or s.startswith("@@P|") or s.startswith("root@"):
                continue
            parts = s.split("\t", 1)
            name = parts[0].strip()
            # 串口会回显 probe 的命令行/哨兵，只有以 .ko 结尾的才是安装文件。
            if not name.endswith(".ko"):
                continue
            installed.add(name)
            if len(parts) > 1 and parts[1].strip() not in ("", "-"):
                inst_src.setdefault(name, set()).add(parts[1].strip())
    boot_chunks = parse_section(lines, "bootloaded")
    boot_loaded = set()
    for c in boot_chunks:
        for line in c:
            s = line.strip()
            if not s or s.startswith("@@P|") or s.startswith("root@"):
                continue
            # 过滤串口回显的 shell 命令行，只接受合法模块名。
            if not re.match(r"^[A-Za-z0-9_+.-]+$", s):
                continue
            boot_loaded.add(s.replace("-", "_"))

    # 安装目录只按文件名可见（root 与 update/ 同名无法区分），故按 basename 比较。
    pkg_base, pkg_base_src = set(), {}
    for e in module_list:
        base = os.path.basename(e["rel"])
        pkg_base.add(base)
        if e["srcver"]:
            pkg_base_src.setdefault(base, set()).add(e["srcver"])
    install_gap = sorted(pkg_base - installed) if installed else []
    install_extra = sorted(installed - pkg_base)

    # 安装模块身份：装到系统里的 .ko 必须是本次测试包那一版（证明重建生效）。
    identity = []
    for name in sorted(set(inst_src) & pkg_base):
        want = pkg_base_src.get(name)
        if not want:
            continue
        have = inst_src[name]
        if not (want & have):
            identity.append({"name": name, "pkg": sorted(want),
                             "installed": sorted(have)})

    # 基线（失败集合 + 安装集缺口）在 G-M5 就要用，故此处先加载。
    baseline = None
    if args.baseline and os.path.isfile(args.baseline):
        with open(args.baseline, encoding="utf-8") as f:
            baseline = json.load(f)

    # 预装模式：镜像内模块必然可能来自 base rr.img 的旧构建，缺口/身份只作告警；
    # 非预装：缺口相对基线增量必须为 0（存量缺口是包内全量 vs 安装子集的结构差异，
    # DSM 只安装官方映射子集，不能用全量相等当判据）。
    new_gap = []
    if baseline and args.module_limit == 0:
        new_gap = sorted(set(install_gap) - set(baseline.get("install_gap", [])))
    identity_bad = [x for x in identity
                    if not is_allowed(x["name"], "INSTALLED_MISMATCH")]
    probe_ok = bool(installed) and bool(boot_loaded)
    install_ok = probe_ok and not new_gap and not identity_bad
    install_detail = ("installed=%d boot_loaded=%d gap=%d extra=%d "
                      "identity_mismatch=%d new_gap=%d"
                      % (len(installed), len(boot_loaded), len(install_gap),
                         len(install_extra), len(identity_bad), len(new_gap)))
    if args.skip_install_check:
        gate("G-M5", True, "已按参数跳过安装集核对")
    elif install_drift:
        # 只有"相对基线新增缺口/安装身份不一致"值得告警；存量 gap/extra 是
        # "DSM 安装子集 vs 包内全量"的结构差异，纯信息。
        actionable = bool(new_gap) or bool(identity_bad)
        gate("G-M5", probe_ok,
             install_detail + ("（%s：差异只作告警）" % drift_reason
                               if actionable else ""),
             warn=probe_ok and actionable)
    else:
        gate("G-M5", install_ok, install_detail)

    # G-M6 基线回归（失败集合新增 / 清单缩水）
    baseline_new, baseline_gone, baseline_info = [], [], None
    shrink_ok = True
    if baseline and args.module_limit == 0:
        expected = int(baseline.get("module_count", 0))
        shrink_ok = len(module_list) >= expected or args.allow_shrink
        base_set = {(x["name"], x.get("category", ""))
                    for x in baseline.get("failures", [])}
        cur_set = {(f["name"], f["category"]) for f in hard}
        baseline_new = sorted(cur_set - base_set)
        baseline_gone = sorted(base_set - cur_set)
        baseline_info = ("baseline=%d current=%d new=%d gone=%d shrink=%s"
                         % (len(base_set), len(cur_set), len(baseline_new),
                            len(baseline_gone), shrink_ok))
    gate("G-M6", (not baseline_new) and shrink_ok, baseline_info or "未启用基线")

    # 内核身份（custom）
    kernel_id = {"checked": False, "pass": True, "detail": "official 内核，跳过"}
    if args.kernel == "custom":
        reluser, uts = parse_cks_image_info(args.cks_image_info)
        kid_lines = []
        for c in parse_section(lines, "kernelid"):
            kid_lines.extend(c)
        version_lines = [l for l in kid_lines if "Linux version" in l]
        hit = any(reluser and uts and reluser in l and uts in l
                  for l in version_lines)
        kernel_id = {"checked": True, "pass": hit, "reluser": reluser,
                     "uts": uts, "detail": "发现 Linux version 行=%d" % len(version_lines)}
        gate("G-M7", hit and bool(version_lines),
             "%s / %s 命中=%s" % (reluser, uts, hit))

    # 包来源（modtest-meta.txt）
    meta = parse_kv_file(args.meta)
    meta_ok, meta_detail = True, "未提供 meta"
    if meta:
        pkg_path = meta.get("package_path", "")
        entries = meta.get("package_entries", "")
        payload = meta.get("test_payload_sha256", "")
        pkg_sha = meta.get("package_sha256", "")
        checks = []
        if args.kernel == "custom":
            checks.append("/cks/modules-" in pkg_path)
        if entries.isdigit():
            checks.append(int(entries) == len(module_list))
        if payload and pkg_sha:
            checks.append(payload == pkg_sha)
        meta_ok = all(checks) if checks else False
        meta_detail = "path=%s entries=%s sha_equal=%s" % (
            pkg_path, entries, payload == pkg_sha)
        gate("G-M8", meta_ok, meta_detail)

    result = {
        "schema": 1,
        "context": {"source": args.source, "model": args.model,
                    "kernel": args.kernel, "platform": args.platform,
                    "line": args.line, "kver": args.kver,
                    "profile": args.profile, "prebuilt": bool(args.prebuilt),
                    "install_drift": bool(install_drift),
                    "logs": args.logs},
        "totals": {"total": total, "loaded": loaded, "ok": ok,
                   "fail": fail, "skip": skip, "hazard": hazard},
        "declared": declared,
        "failures": [{k: f.get(k) for k in
                      ("idx", "name", "rel", "state", "rc", "category",
                       "err", "symbols")} for f in hard],
        "allowlisted": [{k: f.get(k) for k in
                         ("idx", "name", "category", "err")} for f in skips],
        "stale_loaded": [{k: f.get(k) for k in
                          ("name", "src", "pkg", "err", "allowed")}
                         for f in stale],
        "kernel_faults": kernel_faults,
        "dmesg_warnings": warning_faults,
        "firmware_fail": firmware_fail,
        "install": {"installed": len(installed), "boot_loaded": len(boot_loaded),
                    "gap": install_gap, "extra": install_extra,
                    "identity_mismatch": identity,
                    "new_gap": new_gap},
        "baseline": {"new": baseline_new, "gone": baseline_gone},
        "kernel_identity": kernel_id,
        "package_meta": meta,
        "gates": gates,
        "pass": all(g["pass"] for g in gates),
    }

    emit(args, result)
    return 0 if result["pass"] else 1


def parse_cks_image_info(path):
    if not path:
        return "", ""
    if not os.path.isfile(path):
        die("cks-image-info.txt 不存在: %s" % path)
    text = " ".join(l.strip() for l in read_lines(path))
    if ", version " not in text:
        die("cks-image-info.txt 无法解析 version: %r" % text)
    ver = text.split(", version ", 1)[1].split(", RO-rootFS", 1)[0]
    if " #" not in ver:
        die("cks-image-info.txt 缺少 UTS 段: %r" % ver)
    reluser, uts = ver.split(" #", 1)
    return reluser.strip(), ("#" + uts.strip())


def parse_kv_file(path):
    if not path or not os.path.isfile(path):
        return {}
    kv = {}
    for line in read_lines(path):
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()
    return kv


def emit(args, result):
    prefix = args.out_prefix or "modtest-result"
    summary_path = prefix + ".summary.md"
    json_path = prefix + ".json"

    lines = []
    c = result["context"]
    t = result["totals"]
    lines.append("# 模块测试门禁报告\n")
    lines.append("- 上下文: source=%s model=%s kernel=%s platform=%s line=%s kver=%s profile=%s"
                 % (c["source"], c["model"], c["kernel"], c["platform"],
                    c["line"], c["kver"], c["profile"]))
    lines.append("- 计数: total=%d loaded=%d ok=%d fail=%d skip=%d hazard=%d"
                 % (t["total"], t["loaded"], t["ok"], t["fail"],
                    t["skip"], t["hazard"]))
    lines.append("")
    lines.append("## 门禁")
    for g in result["gates"]:
        if g.get("level") == "warn":
            mark = "WARN"
        else:
            mark = "PASS" if g["pass"] else "FAIL"
        lines.append("- [%s] %s %s" % (mark, g["id"], g["detail"]))
    lines.append("")
    lines.append("## 失败明细")
    if result["failures"]:
        lines.append("| idx | name | category | err |")
        lines.append("|---|---|---|---|")
        for f in result["failures"]:
            err = (f.get("err") or "").replace("|", "\\|")[:120]
            lines.append("| %s | %s | %s | %s |" % (f["idx"], f["name"],
                                                    f["category"], err))
    else:
        lines.append("无")
    lines.append("")
    lines.append("## 白名单命中（%d）" % len(result["allowlisted"]))
    for f in result["allowlisted"]:
        lines.append("- %s (%s)" % (f["name"], f["category"]))
    lines.append("")
    lines.append("## STALE_LOADED（%d）" % len(result["stale_loaded"]))
    for f in result["stale_loaded"]:
        if f.get("allowed"):
            tag = "白名单"
        else:
            tag = "WARN" if result["context"].get("install_drift") else "FAIL"
        lines.append("- %s [%s] %s" % (f["name"], tag, f.get("err", "")))
    lines.append("")
    lines.append("## 内核崩溃/告警")
    for f in result["kernel_faults"]:
        label = "KERNEL_FAULT" if f.get("kind") == "module" else "KERNEL_INTERNAL"
        tag = " [已豁免]" if f.get("allowed") else ""
        sym = " (%s)" % ",".join(f["symbols"]) if f.get("symbols") else ""
        lines.append("- %s %s x%d%s%s" % (label, f["name"], f["hits"], sym, tag))
    for f in result["dmesg_warnings"]:
        lines.append("- DMESG_WARNING %s x%d" % (f["name"], f["hits"]))
    if result["firmware_fail"]:
        lines.append("- firmware 失败行: %d" % result["firmware_fail"])
    if not (result["kernel_faults"] or result["dmesg_warnings"]):
        lines.append("无")
    lines.append("")
    inst = result["install"]
    lines.append("## 安装集")
    lines.append("- installed=%d boot_loaded=%d gap=%d extra=%d "
                 "identity_mismatch=%d new_gap=%d"
                 % (inst["installed"], inst["boot_loaded"],
                    len(inst["gap"]), len(inst["extra"]),
                    len(inst["identity_mismatch"]), len(inst["new_gap"])))
    if inst["gap"]:
        lines.append("- 包内有但未安装（DSM 只装映射子集，属常态）: %s"
                     % ", ".join(inst["gap"][:20]))
    if inst["new_gap"]:
        lines.append("- 相对基线新增缺口: %s" % ", ".join(inst["new_gap"][:20]))
    for x in inst["identity_mismatch"]:
        lines.append("- 安装版与测试包不一致: %s（pkg=%s installed=%s）"
                     % (x["name"], ",".join(x["pkg"]),
                        ",".join(x["installed"])))
    lines.append("")
    lines.append("## 基线")
    lines.append("- 新增失败: %s" % (result["baseline"]["new"] or "无"))
    lines.append("- 已消失失败: %s" % (result["baseline"]["gone"] or "无"))
    lines.append("")
    lines.append("## 内核身份")
    ki = result["kernel_identity"]
    lines.append("- %s" % ki.get("detail", ""))

    text = "\n".join(lines) + "\n"
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write(text)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    sys.stdout.write(text)

    candidate = dict(result)
    candidate.pop("gates", None)
    candidate.pop("pass", None)
    candidate["failures"] = [{k: f.get(k) for k in ("name", "category", "err")}
                             for f in result["failures"]]
    candidate["module_count"] = len(load_module_list(args.module_list))
    candidate["install_gap"] = result["install"]["gap"]
    with open(prefix + "-baseline-candidate.json", "w", encoding="utf-8") as f:
        json.dump(candidate, f, ensure_ascii=False, indent=2)

    if args.emit_baseline:
        os.replace(prefix + "-baseline-candidate.json", args.emit_baseline)


def main(argv):
    p = argparse.ArgumentParser(description="ova-test 模块测试门禁")
    p.add_argument("--logs", help="artifact 根目录（含 <profile>/cmd-*.out）")
    p.add_argument("--profile", default="modtest")
    p.add_argument("--module-list", help="module-list.tsv")
    p.add_argument("--source", default="ainas")
    p.add_argument("--model", default="")
    p.add_argument("--kernel", default="official", choices=["official", "custom"])
    p.add_argument("--platform", default="")
    p.add_argument("--line", default="")
    p.add_argument("--kver", default="")
    p.add_argument("--allowlist", default="")
    p.add_argument("--baseline", default="")
    p.add_argument("--cks-image-info", default="")
    p.add_argument("--meta", default="")
    p.add_argument("--module-limit", type=int, default=0)
    p.add_argument("--allow-stale-loaded", action="store_true")
    p.add_argument("--allow-shrink", action="store_true")
    p.add_argument("--prebuilt", action="store_true",
                   help="预装成品 OVA 模式：镜像模块可能来自 base rr.img 旧构建，"
                        "STALE/安装集差异降级为告警")
    p.add_argument("--skip-install-check", action="store_true",
                   help="仅用于回放历史日志（无 installed 段）")
    p.add_argument("--emit-baseline", default="")
    p.add_argument("--out-prefix", default="modtest-result")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args(argv)
    if args.selftest:
        return run_selftest()
    if not args.logs or not args.module_list:
        die("缺少 --logs 或 --module-list")
    return analyze(args)


# ── 自测（负向 fixture，参照 ainas-modules gate_selftest.sh 的惯例）─────────

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def run_cli(argv):
    proc = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)] + argv,
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def make_fixture(logs_dir, records, done=True, dmesg="", installed=None,
                 pkg=""):
    """按 records 生成 cmd-0/1.out 与 module-list.tsv，返回清单路径。

    logs_dir 是 --logs 目录，子目录 modtest 对应 --profile 默认值。
    """
    prof = os.path.join(logs_dir, "modtest")
    os.makedirs(prof, exist_ok=True)
    body = "\n".join(records) + "\n"
    if dmesg:
        body += "---DMESG-BEGIN---\n%s\n---DMESG-END---\n" % dmesg
    stats = {"loaded": 0, "ok": 0, "fail": 0, "skip": 0}
    for line in records:
        state = line.split("|")[3]
        if state == "LOADED":
            stats["loaded"] += 1
        elif state == "INSMOD_OK":
            stats["ok"] += 1
        elif state in ("INSMOD_FAIL", "MISSING"):
            stats["fail"] += 1
        elif state in ("SKIP_UPDATE", "SKIP_HAZARD"):
            stats["skip"] += 1
    if done:
        body += ("@@MODTEST_DONE@@ total=%d loaded=%d ok=%d fail=%d skip=%d "
                 "status=done\n" % (len(records), stats["loaded"], stats["ok"],
                                    stats["fail"], stats["skip"]))
    write(os.path.join(prof, "cmd-1.out"), body)
    if installed is not None:
        write(os.path.join(prof, "cmd-0.out"),
              "@@P|installed|begin\n%s\n@@P|installed|end\n"
              "@@P|bootloaded|begin\nboot0\n@@P|bootloaded|end\n"
              "MODTEST_MOUNT_RC=0\n" % "\n".join(installed))
    list_path = os.path.join(logs_dir, "module-list.tsv")
    rows = []
    for i, line in enumerate(records, 1):
        name = line.split("|")[2]
        rows.append("%d\t%s\t%s.ko\t\t%s\troot" % (i, name, name, pkg))
    write(list_path, "\n".join(rows) + "\n")
    return list_path


def run_selftest():
    def base_args(root, list_path, extra):
        return (["--logs", os.path.join(root, "logs"),
                 "--module-list", list_path,
                 "--platform", "epyc7002", "--line", "7.4",
                 "--kver", "5.10.55", "--model", "SA6400",
                 "--out-prefix", os.path.join(root, "out")] + extra)

    def scenario(name, rc, keyword, records, done=True, dmesg="",
                 installed=None, pkg="", extra=None):
        """extra 可为 list，也可为 (root, list_path) -> list 的函数。"""
        def run(root):
            lp = make_fixture(os.path.join(root, "logs"), records, done=done,
                              dmesg=dmesg, installed=installed, pkg=pkg)
            tail = extra(root, lp) if callable(extra) else list(extra or [])
            return run_cli(base_args(root, lp, tail))
        return {"name": name, "rc": rc, "kw": keyword, "run": run}

    def allowlist_case(root, lp):
        path = os.path.join(root, "allow.tsv")
        write(path, "#platform\tline\tkver\tmodel\tname\tcategory\treason\n"
                     "epyc7002\t7.4\t5.10.55\tSA6400\ta\tENV\tQEMU\n")
        return ["--allowlist", path]

    def baseline_new_case(root, lp):
        path = os.path.join(root, "base.json")
        write(path, json.dumps({"module_count": 1, "failures": []}))
        return ["--baseline", path]

    def baseline_gone_case(root, lp):
        path = os.path.join(root, "base.json")
        write(path, json.dumps({"module_count": 1,
                                "failures": [{"name": "c", "category": "ENV"}]}))
        return ["--baseline", path]

    def emit_case(root, lp):
        return ["--emit-baseline", os.path.join(root, "emit.json")]

    def baseline_install_case(root, lp):
        path = os.path.join(root, "base.json")
        write(path, json.dumps({"module_count": 1, "failures": [],
                                "install_gap": []}))
        return ["--baseline", path]

    def prebuilt_case(root, lp):
        return ["--prebuilt"]

    def custom_case(root, lp):
        # custom 内核的系统模块树由本次自编包构建，STALE/安装身份必须严格。
        return ["--kernel", "custom"]

    def baseline_install_custom_case(root, lp):
        return baseline_install_case(root, lp) + ["--kernel", "custom"]

    def dep_env_case(root, lp):
        # b 依赖 a；a 因环境缺失（No such device）未加载，b 的 Unknown symbol
        # 应降级为 DEP_ENV，并由白名单显式豁免。
        write(lp, "1\ta\troot/a.ko\t\tx\troot\n"
                  "2\tb\troot/b.ko\ta\tx\troot\n")
        path = os.path.join(root, "allow.tsv")
        write(path, "epyc7002\t7.4\t5.10.55\tSA6400\t*\ta\tENV\tQEMU\n"
                    "epyc7002\t7.4\t5.10.55\tSA6400\t*\tb\tDEP_ENV\t依赖环境缺失\n")
        return ["--allowlist", path]

    def builtin_dup_case(root, lp):
        path = os.path.join(root, "allow.tsv")
        write(path, "epyc7002\t7.4\t5.10.55\tSA6400\t*\ta\tBUILTIN_DUP\t"
                    "内核已导出同名符号\n")
        return ["--allowlist", path]

    def internal_allow_case(root, lp):
        # KERNEL_INTERNAL：崩溃 IP 落在内核内建代码（模块只是触发方）。
        path = os.path.join(root, "allow.tsv")
        write(path, "epyc7002\t7.4\t5.10.55\tSA6400\t*\ta\tKERNEL_INTERNAL\t"
                    "内核内建代码缺陷\n")
        return ["--allowlist", path]

    def skip_update_cascade_case(root, lp):
        # b 依赖 a，a 因系统已加载同名模块（SKIP_UPDATE）未参与运行 → b 的
        # Unknown symbol 应降级为 DEP_ENV。
        write(lp, "1\ta\tupdate/a.ko\t\t-\tupdate\n"
                  "2\tb\tupdate/b.ko\ta\t-\tupdate\n")
        path = os.path.join(root, "allow.tsv")
        write(path, "epyc7002\t7.4\t5.10.55\tSA6400\t*\tb\tDEP_ENV\t"
                    "依赖的 update 模块被系统同名模块取代\n")
        return ["--allowlist", path]

    ok = "@@M|1|a|INSMOD_OK|0|src=x pkg=x err="
    cases = [
        scenario("S1 缺 DONE", 1, "G-M1", [ok], done=False,
                 installed=["a.ko"]),
        scenario("S2 Unknown symbol", 1, "UNKNOWN_SYMBOL",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err=unknown symbol foo"],
                 installed=["a.ko"]),
        scenario("S3 白名单命中", 0, "白名单命中（1）",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err=No such device"],
                 installed=["a.ko"], extra=allowlist_case),
        scenario("S4 基线新增失败", 1, "G-M6",
                 ["@@M|1|b|INSMOD_FAIL|1|src=- pkg=- err=No such device"],
                 installed=["b.ko"], extra=baseline_new_case),
        scenario("S5 基线失败消失", 0, "已消失失败",
                 ["@@M|1|c|INSMOD_OK|0|src=x pkg=x err="],
                 installed=["c.ko"], extra=baseline_gone_case),
        scenario("S6 STALE_LOADED", 1, "STALE_LOADED",
                 ["@@M|1|a|LOADED|-|src=OLD pkg=NEW"],
                 installed=["a.ko"], pkg="NEW", extra=custom_case),
        scenario("S7 全绿", 0, "[PASS] G-M1", [ok], installed=["a.ko"]),
        scenario("S8 安装集探针为空", 1, "G-M5", [ok], installed=[]),
        scenario("S9 内核崩溃归因", 1, "KERNEL_FAULT", [ok],
                 installed=["a.ko"],
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] Call Trace:\n"),
        scenario("S10 生成基线", 0, "G-M6", [ok], installed=["a.ko"],
                 extra=emit_case),
        scenario("S11 预装模式 STALE 仅告警", 0, "[WARN] G-M3",
                 ["@@M|1|a|LOADED|-|src=OLD pkg=NEW"],
                 installed=["a.ko\tOLD"], pkg="NEW", extra=prebuilt_case),
        scenario("S12 安装版与测试包不一致（custom）", 1, "安装版与测试包不一致",
                 ["@@M|1|a|INSMOD_OK|0|src=NEW pkg=NEW err="],
                 installed=["a.ko\tOLD"], pkg="NEW", extra=custom_case),
        scenario("S13 基线新增安装缺口（custom）", 1, "G-M5", [ok],
                 installed=["other.ko"], extra=baseline_install_custom_case),
        scenario("S14 依赖环境级联 DEP_ENV", 0, "DEP_ENV",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err=No such device",
                  "@@M|2|b|INSMOD_FAIL|1|src=- pkg=- err=unknown symbol hv_x"],
                 installed=["a.ko", "b.ko"], pkg="x", extra=dep_env_case),
        scenario("S15 官方内核 STALE/安装身份仅告警", 0, "[WARN] G-M3",
                 ["@@M|1|a|LOADED|-|src=OLD pkg=NEW"],
                 installed=["a.ko\tOLD"], pkg="NEW"),
        scenario("S16 内核重复导出证据 → BUILTIN_DUP 可豁免", 0, "BUILTIN_DUP",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err=insmod: ERROR: "
                  "could not insert module a.ko: Invalid module format"],
                 installed=["a.ko"], pkg="x", extra=builtin_dup_case,
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] a: exports duplicate symbol foo (owned by kernel)\n"),
        scenario("S17 无重复导出证据的 VERMAGIC 仍硬失败", 1, "VERMAGIC",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err=insmod: ERROR: "
                  "could not insert module a.ko: Invalid module format"],
                 installed=["a.ko"], pkg="x", extra=builtin_dup_case,
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"),
        scenario("S18 SKIP_UPDATE 依赖级联 → DEP_ENV", 0, "DEP_ENV",
                 ["@@M|1|a|SKIP_UPDATE|-|src=- pkg=",
                  "@@M|2|b|INSMOD_FAIL|1|src=- pkg=- err=unknown symbol drm_x"],
                 installed=["a.ko"], pkg="",
                 extra=skip_update_cascade_case),
        # 内核内建代码崩溃：IP 无 [模块] 归属 → KERNEL_INTERNAL。未登记白名单
        # 仍失败（S19），登记后只报告不阻断（S20）。IP 在模块内则不可豁免（S21）。
        scenario("S19 内核内建代码崩溃未豁免仍失败", 1, "KERNEL_INTERNAL",
                 [ok], installed=["a.ko"],
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130\n"
                       "[  1.4] Call Trace:\n"
                       "[  1.5]  [<ffffffffa2628ad3>] foo+0x20d/0x232 [a]\n"
                       "[  1.6] ---[ end trace 1 ]---\n"),
        scenario("S20 内核内建代码崩溃登记白名单后通过", 0, "KERNEL_INTERNAL",
                 [ok], installed=["a.ko"], extra=internal_allow_case,
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130\n"
                       "[  1.4] Call Trace:\n"
                       "[  1.5] ---[ end trace 1 ]---\n"),
        scenario("S21 模块内崩溃不可用内建白名单豁免", 1, "KERNEL_FAULT",
                 [ok], installed=["a.ko"], extra=internal_allow_case,
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] IP: [<ffffffffa2628ad3>] foo+0x20d/0x232 [a]\n"
                       "[  1.4] ---[ end trace 1 ]---\n"),
        # 同一现场模块的 insmod 也会失败（probe 里进内核内建代码崩溃），
        # 该失败应与 dmesg 侧同归 KERNEL_INTERNAL，一行白名单覆盖 G-M2/G-M4。
        scenario("S22 内建代码崩溃连带 insmod 失败归 KERNEL_INTERNAL", 0,
                 "a (KERNEL_INTERNAL)",
                 ["@@M|1|a|INSMOD_FAIL|1|src=- pkg=- err="],
                 installed=["a.ko"], extra=internal_allow_case,
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130\n"
                       "[  1.4] ---[ end trace 1 ]---\n"),
    ]

    failed = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as root:
            rc, out = case["run"](root)
        if rc != case["rc"] or case["kw"] not in out:
            failed += 1
            sys.stderr.write("[FAIL] %s: rc=%d(期望 %d) 关键字=%r\n%s\n"
                             % (case["name"], rc, case["rc"], case["kw"],
                                out[-800:]))
        else:
            sys.stdout.write("[PASS] %s\n" % case["name"])
    if failed:
        sys.stderr.write("[E] 自测失败 %d 项\n" % failed)
        return 1
    sys.stdout.write("[PASS] 门禁负向测试 %d 项全部符合预期\n" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
