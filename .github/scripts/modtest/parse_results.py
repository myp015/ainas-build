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
# 安全原则：只有白名单类别（ENV/BUILTIN/DMESG_WARNING）允许豁免；
# Unknown symbol / vermagic / 依赖顺序 / MISSING / 内核崩溃 一律硬失败。

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
ENV_CATEGORIES = {"ENV", "BUILTIN"}
ALLOWABLE_CATEGORIES = ENV_CATEGORIES | {"DMESG_WARNING"}

FAULT_RE = re.compile(
    r"(BUG:|Oops|Kernel panic|Call Trace|Unable to handle|general protection)")
WARNING_RE = re.compile(r"WARNING:")
FIRMWARE_FAIL_RE = re.compile(r"firmware.*(fail|error)", re.I)
MARKER_RE = re.compile(r"modtest-marker idx=(\d+) name=(\S+)")
UNKNOWN_SYM_RE = re.compile(r"Unknown symbol (\S+)")

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
        entries.append({"idx": int(idx), "name": name, "rel": rel,
                        "depends": depends, "srcver": srcver, "policy": policy})
    return entries


def load_allowlist(path):
    rows = []
    if not path:
        return rows
    for line in read_lines(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split("\t")
        if len(parts) < 5:
            die("白名单行格式非法: %r" % line)
        if len(parts) >= 7:
            category = parts[5]
            reason = " ".join(parts[6:])
        elif len(parts) == 6:
            category, reason = "ENV", parts[5]
        else:
            category, reason = "ENV", ""
        rows.append({"platform": parts[0], "line": parts[1], "kver": parts[2],
                     "model": parts[3], "name": parts[4],
                     "category": category, "reason": reason})
    return rows


def allowlisted(row, ctx):
    def match(pat, val):
        return pat == "*" or fnmatch.fnmatchcase(val, pat)
    return (match(row["platform"], ctx["platform"])
            and match(row["line"], ctx["line"])
            and match(row["kver"], ctx["kver"])
            and match(row["model"], ctx["model"])
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
            records.append({
                "idx": int(m.group(1)), "name": m.group(2), "state": m.group(3),
                "rc": m.group(4), "details": details,
                "src": src_m.group(1) if src_m else "-",
                "pkg": pkg_m.group(1) if pkg_m else "",
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
    fault_by_name, warnings_by_name = {}, {}
    firmware_fail = 0
    unknown_syms = {}
    cur_name = None
    for line in parse_dmesg(lines):
        m = MARKER_RE.search(line)
        if m:
            cur_name = m.group(2)
            continue
        if FIRMWARE_FAIL_RE.search(line):
            firmware_fail += 1
        m = UNKNOWN_SYM_RE.search(line)
        if m:
            key = cur_name or "<unknown>"
            unknown_syms.setdefault(key, set()).add(m.group(1))
        if FAULT_RE.search(line):
            key = cur_name or "<unknown>"
            fault_by_name[key] = fault_by_name.get(key, 0) + 1
        elif WARNING_RE.search(line):
            key = cur_name or "<unknown>"
            warnings_by_name[key] = warnings_by_name.get(key, 0) + 1

    allow_rows = load_allowlist(args.allowlist)
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
                              "err": "运行时 srcversion=%s 不在包内 %s"
                                     % (sys_src, sorted(pkg_set))})
            continue
        if state != "INSMOD_FAIL" and state != "MISSING":
            # 未知状态按失败处理，避免静默
            failures.append({**r, "category": "OTHER",
                             "err": "未知状态: %s" % state})
            continue

        category = "MISSING" if state == "MISSING" else classify(r["err"])
        ctx = {"platform": args.platform, "line": args.line, "kver": args.kver,
               "model": args.model, "name": r["name"], "category": category}
        allowed = (category in ALLOWABLE_CATEGORIES
                   and any(allowlisted(row, ctx) for row in allow_rows))
        item = {**r, "category": category, "allowed": allowed}
        if allowed:
            skips.append(item)
        else:
            failures.append(item)

    for name, syms in unknown_syms.items():
        for f in failures:
            if f["name"] == name and f["category"] == "UNKNOWN_SYMBOL":
                f["symbols"] = sorted(syms)
                break

    kernel_faults = [{"name": n, "hits": c, "allowed": False}
                     for n, c in fault_by_name.items()]
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
    def gate(gid, okflag, detail):
        gates.append({"id": gid, "pass": bool(okflag), "detail": detail})

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

    stale_fail = stale if not args.allow_stale_loaded else []
    gate("G-M3", not stale_fail,
         "STALE_LOADED %d 条（pkg 与运行内核不一致）" % len(stale))

    gate("G-M4", not kernel_faults,
         "内核崩溃/异常归因 %d 条" % len(kernel_faults))

    # P0-4 安装集核对
    installed_chunks = parse_section(lines, "installed")
    installed = set()
    for c in installed_chunks:
        for line in c:
            s = line.strip()
            if not s or s.startswith("@@P|") or s.startswith("root@"):
                continue
            installed.add(s)
    boot_chunks = parse_section(lines, "bootloaded")
    boot_loaded = set()
    for c in boot_chunks:
        for line in c:
            s = line.strip()
            if not s or s.startswith("@@P|") or s.startswith("root@"):
                continue
            boot_loaded.add(s.replace("-", "_"))

    pkg_rel = {e["rel"] for e in module_list}
    install_gap = sorted(pkg_rel - installed) if installed else []
    install_extra = sorted(installed - pkg_rel)
    if args.skip_install_check:
        install_ok = True
        install_detail = "已按参数跳过安装集核对"
    else:
        install_ok = bool(installed) and not install_gap
        install_detail = ("installed=%d boot_loaded=%d gap=%d extra=%d"
                          % (len(installed), len(boot_loaded),
                             len(install_gap), len(install_extra)))
    gate("G-M5", install_ok, install_detail)

    # 基线比较
    baseline_new, baseline_gone, baseline_info = [], [], None
    baseline = None
    if args.baseline and os.path.isfile(args.baseline):
        with open(args.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
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
                    "profile": args.profile, "logs": args.logs},
        "totals": {"total": total, "loaded": loaded, "ok": ok,
                   "fail": fail, "skip": skip, "hazard": hazard},
        "declared": declared,
        "failures": [{k: f.get(k) for k in
                      ("idx", "name", "rel", "state", "rc", "category",
                       "err", "symbols")} for f in hard],
        "allowlisted": [{k: f.get(k) for k in
                         ("idx", "name", "category", "err")} for f in skips],
        "stale_loaded": [{k: f.get(k) for k in ("name", "src", "pkg", "err")}
                         for f in stale],
        "kernel_faults": kernel_faults,
        "dmesg_warnings": warning_faults,
        "firmware_fail": firmware_fail,
        "install": {"installed": len(installed), "boot_loaded": len(boot_loaded),
                    "gap": install_gap, "extra": install_extra},
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
        lines.append("- [%s] %s %s" % ("PASS" if g["pass"] else "FAIL",
                                       g["id"], g["detail"]))
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
        lines.append("- %s: %s" % (f["name"], f.get("err", "")))
    lines.append("")
    lines.append("## 内核崩溃/告警")
    for f in result["kernel_faults"]:
        lines.append("- KERNEL_FAULT %s x%d" % (f["name"], f["hits"]))
    for f in result["dmesg_warnings"]:
        lines.append("- DMESG_WARNING %s x%d" % (f["name"], f["hits"]))
    if result["firmware_fail"]:
        lines.append("- firmware 失败行: %d" % result["firmware_fail"])
    if not (result["kernel_faults"] or result["dmesg_warnings"]):
        lines.append("无")
    lines.append("")
    inst = result["install"]
    lines.append("## 安装集")
    lines.append("- installed=%d boot_loaded=%d gap=%d extra=%d"
                 % (inst["installed"], inst["boot_loaded"],
                    len(inst["gap"]), len(inst["extra"])))
    if inst["gap"]:
        lines.append("- 包内有但未安装: %s" % ", ".join(inst["gap"][:20]))
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
              "@@P|bootloaded|begin\n\n@@P|bootloaded|end\n"
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
                 installed=["a.ko"], pkg="NEW"),
        scenario("S7 全绿", 0, "[PASS] G-M1", [ok], installed=["a.ko"]),
        scenario("S8 安装集缺口", 1, "G-M5", [ok], installed=["other.ko"]),
        scenario("S9 内核崩溃归因", 1, "KERNEL_FAULT", [ok],
                 installed=["a.ko"],
                 dmesg="[  1.1] modtest-marker idx=1 name=a\n"
                       "[  1.2] BUG: unable to handle kernel NULL pointer\n"
                       "[  1.3] Call Trace:\n"),
        scenario("S10 生成基线", 0, "G-M6", [ok], installed=["a.ko"],
                 extra=emit_case),
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
