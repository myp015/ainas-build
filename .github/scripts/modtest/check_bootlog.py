#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""启动日志门禁：核对 base/SCSI/nic 启动日志与安装期日志里的模块/LKM 异常。

为什么新增：现有 parse_results.py 的崩溃判据只吃 modtest profile 的
`---DMESG-BEGIN/END---` 段；bootlog_diff.py 只做双源 diff 摘要且恒返回 0；
install 阶段的 `_serial_full.log` / `_messages.log` 虽然随 artifact 上传，
但从来没有解析脚本。结果是「启动时模块加载失败/符号缺失/内核崩溃」无人核对。

扫描源：
  <logs>/<profile>/cmd-*.out（base / SCSI / nic；modtest 由模块门禁负责）
  <install-logs>/*_serial_full.log、*_messages.log、*_corestatus.log、
                 *_pkgcheck.log（后者是前者的切片，靠去重合并）

判据与归属：
  硬失败：Kernel panic/Oops/BUG/#PF/GP、Unknown symbol in module、
          Invalid module format（无 duplicate-symbol 证据时）、
          GPL-only symbol、Loading modules failed
  降级：  <mod>: exports duplicate symbol 且该模块已在 env-fail-allowlist.tsv
          的 BUILTIN_DUP 段登记（历史实测 button/i8042/check_signature）
  只报告：exports duplicate symbol（未登记）、modprobe 找不到可选模块、
          firmware 加载失败、taint 提示、WARNING

去重与防误判：串口回读会打印命令本身（含 `grep -iE 'BUG:|Unknown symbol'`
模式串），按命令文件整行过滤；同一行在 serial_full 与 messages 重复出现时
只记一条（记录全部来源）。

退出码：0=只有「只报告」命中；1=硬失败（含输入缺失）；2=参数/环境错误。
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_common as G  # noqa: E402

SYSLOG_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\s+\S+\s+kernel:\s*")
KTS_RE = re.compile(r"^\[\s*\d+\.\d+\]\s*")
VERMAGIC_RE = re.compile(r"Invalid module format|version magic .* should be")
GPL_ONLY_RE = re.compile(r"GPL-only symbol")
LOADING_FAILED_RE = re.compile(r"Loading modules failed")
MODPROBE_MISSING_RE = re.compile(r"modprobe.*?Module (\S+) not found", re.I)
TAINT_RE = re.compile(r"taints kernel|Tainted:")
DUPSYM_RE = G.DUP_EXPORT_RE
MOD_OF_RE = re.compile(r"^(\S+?):\s")
# 不用 parse_results 的 FIRMWARE_FAIL_RE（`firmware.*(fail|error)`）：它会把
# `mount: /sys/firmware/efi/efivars ... failed` 这类伪影算成固件加载失败。
FIRMWARE_LOAD_FAIL_RE = re.compile(
    r"Direct firmware load for .* failed|failed to load firmware|"
    r"firmware_class.*(failed|error)", re.I)

HARD = "hard"
REPORT = "report"
EXEMPTABLE = "exemptable"


def normalize(line):
    """去 syslog 前缀与内核时间戳；同时告知 raw 行是否带内核时间戳。

    带 `[  9.2]` 前缀的才是内核打印（dmesg），像 `depmod: WARNING: ...` 这种
    用户态输出没有前缀，不能当成内核 WARNING 统计。
    """
    s = line.rstrip("\r\n")
    s = SYSLOG_RE.sub("", s)
    kernel_ts = bool(KTS_RE.match(s))
    s = KTS_RE.sub("", s)
    return s.strip(), kernel_ts


def dedup_key(text):
    s = re.sub(r"0x[0-9a-fA-F]+", "0xADDR", text)
    s = re.sub(r"\bCPU#\d+", "CPU#N", s)
    s = re.sub(r"\[\s*\d+\.\d+\]", "", s)
    return re.sub(r"\s+", " ", s).strip()


def classify(line, kernel_ts, dup_modules):
    """返回 [(category, level, module, detail)]；一行可能同时给出多种线索。"""
    out = []
    if G.FAULT_RE.search(line):
        out.append(("KERNEL_FAULT", HARD, "", line))
    m = G.UNKNOWN_SYM_RE.search(line)
    if m:
        out.append(("UNKNOWN_SYMBOL", HARD, "", line))
    m = DUPSYM_RE.search(line)
    if m:
        mod = MOD_OF_RE.match(line)
        name = mod.group(1) if mod else ""
        out.append(("BUILTIN_DUP", EXEMPTABLE, name, line))
    if VERMAGIC_RE.search(line):
        mod = MOD_OF_RE.match(line)
        name = mod.group(1) if mod else ""
        if name and name in dup_modules:
            out.append(("BUILTIN_DUP", EXEMPTABLE, name, line))
        else:
            out.append(("VERMAGIC", HARD, name, line))
    if GPL_ONLY_RE.search(line):
        out.append(("GPL_ONLY", HARD, "", line))
    if LOADING_FAILED_RE.search(line):
        out.append(("LOADING_FAILED", HARD, "", line))
    m = MODPROBE_MISSING_RE.search(line)
    if m:
        out.append(("MODPROBE_MISSING", REPORT, m.group(1), line))
    if FIRMWARE_LOAD_FAIL_RE.search(line):
        out.append(("FIRMWARE_FAIL", REPORT, "", line))
    if TAINT_RE.search(line):
        out.append(("TAINT", REPORT, "", line))
    if kernel_ts and "WARNING:" in line:
        out.append(("DMESG_WARNING", REPORT, "", line))
    return out


def load_dup_allowlist(path):
    rows = [r for r in G.load_allowlist(path) if r["category"] == "BUILTIN_DUP"]
    return rows


def dup_exempt(rows, ctx, name):
    if not name:
        return None
    for row in rows:
        if G.allowlisted(row, dict(ctx, name=name, category="BUILTIN_DUP")):
            return row
    return None


def scan_file(path, echoes, findings):
    for line in G.read_lines(path):
        s = line.strip()
        if not s or G.is_echo(s, echoes):
            continue
        text, kernel_ts = normalize(s)
        if not text:
            continue
        for cat, level, mod, detail in classify(text, kernel_ts,
                                                findings["dup_modules"]):
            key = (cat, mod, dedup_key(detail))
            found = findings["items"].get(key)
            if found is None:
                findings["items"][key] = {
                    "category": cat, "level": level, "module": mod,
                    "text": detail, "count": 1,
                    "sources": [path]}
            else:
                found["count"] += 1
                if path not in found["sources"]:
                    found["sources"].append(path)


def collect_dup_modules(paths):
    names = set()
    for path in paths:
        for line in G.read_lines(path):
            m = DUPSYM_RE.search(line)
            if m:
                text, _ = normalize(line.strip())
                mod = MOD_OF_RE.match(text)
                if mod:
                    names.add(mod.group(1))
    return names


def run(args):
    findings = {"items": {}, "dup_modules": set()}
    profiles = [p for p in args.profiles.split() if p]
    if not profiles:
        profiles = [d for d in os.listdir(args.logs)
                    if os.path.isdir(os.path.join(args.logs, d))
                    and d != "modtest"] if os.path.isdir(args.logs) else []
    echoes = G.load_command_echoes(args.cmds, "probe") if args.cmds else set()
    # 每个 profile 的命令文件可能不同（SCSI/nic 有专用命令文件）
    profile_echoes = {}
    for p in profiles:
        profile_echoes[p] = G.load_command_echoes(args.cmds, p) or echoes

    scanned = []
    for p in profiles:
        logdir = os.path.join(args.logs, p)
        if not os.path.isdir(logdir):
            continue
        for path in G.cmd_files(logdir):
            scan_file(path, profile_echoes[p], findings)
            scanned.append(path)

    install_paths = []
    if os.path.isdir(args.install_logs):
        for name in sorted(os.listdir(args.install_logs)):
            if name.endswith(("_serial_full.log", "_messages.log",
                              "_corestatus.log", "_pkgcheck.log")):
                install_paths.append(os.path.join(args.install_logs, name))
        # 先把 duplicate-symbol 证据收集齐，供 vermagic 降级判定
        findings["dup_modules"] = collect_dup_modules(install_paths)
        for path in install_paths:
            scan_file(path, set(), findings)
            scanned.append(path)
    elif not args.install_optional:
        print("[FAIL] 安装日志目录不存在: %s（use_prebuilt=true 时请加 "
              "--install-optional）" % args.install_logs)
        return 1
    else:
        print("[WARN] 安装日志目录不存在，跳过安装期核对（预装模式）")

    if not scanned:
        # 空跑等于没核对：采集缺失必须暴露，不能被“无异常”掩盖。
        print("[FAIL] 未找到任何可扫描日志（profile 采集与安装日志都缺失）")
        return 1

    dup_rows = load_dup_allowlist(args.module_allowlist)
    boot_rows = []
    if args.allowlist and os.path.isfile(args.allowlist):
        boot_rows = G.load_allowlist(args.allowlist)
    ctx = {"platform": args.platform, "line": args.line, "kver": args.kver,
           "model": args.model, "kernel": args.kernel}

    hard, exempt, silenced, report = [], [], [], []
    for item in findings["items"].values():
        if item["category"] == "BUILTIN_DUP":
            row = dup_exempt(dup_rows, ctx, item["module"])
            if row:
                exempt.append((item, row))
            else:
                report.append(item)
            continue
        if item["level"] == HARD:
            hard.append(item)
            continue
        # 只报告类允许用 bootlog-allowlist 静音（环境性噪声）；硬失败不允许。
        row = None
        for cand in boot_rows:
            if cand["category"] == item["category"] and G.allowlisted(
                    cand, dict(ctx, name=item["module"] or "*",
                               category=item["category"])):
                row = cand
                break
        (silenced if row else report).append((item, row) if row else item)

    for item, row in exempt:
        print("[EXEMPT] %s %s: %s（%s）" % (item["category"], item["module"],
                                           item["text"], row["reason"]))
    for item, row in silenced:
        print("[EXEMPT-INFO] %s: %s（%s）" % (item["category"], item["text"],
                                             row["reason"]))
    for item in hard:
        print("[FAIL] %s: %s（%d 次）" % (item["category"], item["text"],
                                         item["count"]))
    for item in report:
        print("[WARN] %s: %s（%d 次）" % (item["category"], item["text"],
                                         item["count"]))

    payload = {"schema": 1, "context": ctx, "scanned": scanned,
               "counts": {"hard": len(hard), "exempt": len(exempt),
                          "silenced": len(silenced), "report": len(report)},
               "hard": hard, "exempt": [{"item": i, "reason": r["reason"]}
                                        for i, r in exempt],
               "silenced": [{"item": i, "reason": r["reason"]}
                            for i, r in silenced],
               "report": report}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    summary = os.path.join(os.path.dirname(args.out),
                           os.path.basename(args.out).replace(".json", ".summary.md"))
    with open(summary, "w", encoding="utf-8") as f:
        f.write("# 启动日志模块/LKM 异常核对\n\n")
        f.write("- 平台: %s / %s / %s / %s\n" % (ctx["platform"], ctx["line"],
                                                 ctx["kver"], ctx["kernel"]))
        f.write("- 扫描文件: %d\n" % len(scanned))
        f.write("- 硬失败: %d，豁免: %d，静音: %d，只报告: %d\n\n"
                % (len(hard), len(exempt), len(silenced), len(report)))
        for item in hard:
            f.write("- [硬失败] %s: %s\n" % (item["category"], item["text"]))
        for item, row in exempt:
            f.write("- [豁免] %s %s: %s（%s）\n"
                    % (item["category"], item["module"], item["text"],
                       row["reason"]))
        for item, row in silenced:
            f.write("- [静音] %s: %s（%s）\n"
                    % (item["category"], item["text"], row["reason"]))
        for item in report:
            f.write("- [提示] %s: %s\n" % (item["category"], item["text"]))
    print("[INFO] 结果写入 %s / %s" % (args.out, summary))

    if hard:
        print("[FAIL] 启动日志门禁未通过（硬失败 %d 项）" % len(hard))
        return 1
    print("[PASS] 启动日志门禁通过（只报告 %d 项）" % len(report))
    return 0


# ─────────────────────────── selftest ───────────────────────────

CLEAN = "Btrfs loaded\nStarting kernel ...\n"

UNKNOWN = ("[    9.1] vmbus: Unknown symbol vmbus_open (err -2)\n"
           "[    9.2] hv_netvsc: Unknown symbol __vmbus_driver_register (err -2)\n")

DUP = "[    9.2] button: exports duplicate symbol acpi_lid_notifier_register (owned by kernel)\n"

VERMAGIC = "[    9.2] mlx5_core: version magic '5.10.55 SMP mod_unload' should be '4.4.302'\n"

PANIC = ("[    9.1] BUG: unable to handle kernel NULL pointer dereference\n"
         "[    9.2] IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130\n")

ECHO = ("root@SynologyNAS:~# dmesg | grep -iE 'BUG:|Oops|Unknown symbol|exports duplicate symbol'\n"
        "[    1.0] Btrfs loaded\n")

ENV_ALLOW = ("*\t*\t4.4.*\t*\tofficial\tbutton\tBUILTIN_DUP\t"
             "purley 内核内建 ACPI_BUTTON 并导出 acpi_lid_*；RR 包同构\n")

# 实测噪声（DS918+ 4.4.302 安装日志）：mount /sys/firmware 失败曾被旧正则
# `firmware.*(fail|error)` 误判为固件加载失败；depmod 是用户态 WARNING，
# 而 `[ 8.0] WARNING:` 才是内核 WARNING。
NOISE = ("mount: /sys/firmware/efi/efivars: mount(2) system call failed: "
         "Operation not supported.\n"
         "depmod: WARNING: could not open modules.order at /lib/modules: No such file or directory\n"
         "[    8.232781] WARNING: inconsistent syno gpio info, hdd detect\n")

FW_FAIL = ("[    9.2] bluetooth: Direct firmware load for brcm/BCM20702A1.hcd "
           "failed with error -2\n")

BOOT_ALLOW = ("*\t*\t*\t*\t*\t*\tFIRMWARE_FAIL\t"
              "QEMU 无对应硬件，固件请求失败属环境事实\n")

MODPROBE = ("[    9.3] modprobe: FATAL: Module coretemp not found in directory "
            "/lib/modules\n")

CASES = [
    dict(name="干净日志通过", text=CLEAN, rc=0, has="[PASS]"),
    dict(name="Unknown symbol 硬失败", text=UNKNOWN, rc=1,
         has="[FAIL] UNKNOWN_SYMBOL"),
    dict(name="duplicate symbol 未登记只报告", text=DUP, rc=0,
         has="[WARN] BUILTIN_DUP"),
    dict(name="duplicate symbol 已登记豁免", text=DUP, rc=0, has="[EXEMPT]",
         module_allow=ENV_ALLOW),
    dict(name="真 vermagic 硬失败", text=VERMAGIC, rc=1, has="[FAIL] VERMAGIC"),
    dict(name="内核崩溃硬失败", text=PANIC, rc=1, has="[FAIL] KERNEL_FAULT"),
    dict(name="命令回显不算异常", text=ECHO, rc=0, has="[PASS]"),
    dict(name="安装日志缺失且未声明可省略", text=CLEAN, rc=1,
         missing_install=True, has="安装日志目录不存在"),
    dict(name="固件路径/depmod 噪声不误报", text=NOISE, rc=0,
         has="[WARN] DMESG_WARNING", absent=("[WARN] FIRMWARE_FAIL", "depmod")),
    dict(name="只报告类可用 bootlog 白名单静音", text=FW_FAIL, rc=0,
         has="[EXEMPT-INFO]", absent=("[WARN] FIRMWARE_FAIL",),
         boot_allow=BOOT_ALLOW),
    dict(name="modprobe 找不到模块只报告", text=MODPROBE, rc=0,
         has="[WARN] MODPROBE_MISSING"),
]


def selftest():
    import io
    import tempfile
    from contextlib import redirect_stdout

    failed = 0
    for case in CASES:
        name = case["name"]
        text = case["text"]
        with tempfile.TemporaryDirectory() as root:
            logs = os.path.join(root, "logs")
            base = os.path.join(logs, "base")
            os.makedirs(base)
            with open(os.path.join(base, "cmd-1.out"), "w", encoding="utf-8") as f:
                f.write(text + "\n")
            install = os.path.join(root, "install")
            if not case.get("missing_install"):
                # 正常用例造一份安装期 messages 日志（内容干净），
                # 顺带验证 syslog 前缀归一化不误报。
                os.makedirs(install)
                with open(os.path.join(install, "FS6400_messages.log"),
                          "w", encoding="utf-8") as f:
                    f.write("2026-11-04T11:11:46-08:00 DiskStation kernel: "
                            "[    9.265131] Btrfs loaded, crc32c=1, zstd=1\n")
            argv = ["--logs", logs, "--profiles", "base",
                    "--install-logs", install,
                    "--out", os.path.join(root, "out.json"),
                    "--platform", "purley", "--line", "7.3",
                    "--kver", "4.4.302", "--model", "FS6400",
                    "--kernel", "official"]
            # 永远显式指定 allowlist：默认指向真实 env-fail-allowlist.tsv，
            # 其中 button 的 4.4.*/official 行会让“未登记”用例被误豁免。
            ap = os.path.join(root, "allow.tsv")
            with open(ap, "w", encoding="utf-8") as f:
                f.write(case.get("module_allow", ""))
            argv += ["--module-allowlist", ap]
            bp = os.path.join(root, "boot-allow.tsv")
            with open(bp, "w", encoding="utf-8") as f:
                f.write(case.get("boot_allow", ""))
            argv += ["--allowlist", bp]
            args = parse_args(argv)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = run(args)
            out = buf.getvalue()
            problems = []
            if rc != case["rc"]:
                problems.append("rc=%d(期望 %d)" % (rc, case["rc"]))
            if case["has"] not in out:
                problems.append("缺少关键字 %r" % case["has"])
            for bad in case.get("absent", ()):
                if bad in out:
                    problems.append("不该出现 %r" % bad)
            if problems:
                failed += 1
                sys.stderr.write("[FAIL] %s: %s\n%s\n"
                                 % (name, "，".join(problems), out[-800:]))
            else:
                print("[PASS] %s" % name)
    if failed:
        sys.stderr.write("[E] 自测失败 %d 项\n" % failed)
        return 1
    print("[PASS] check_bootlog 自测 %d 项全部符合预期" % len(CASES))
    return 0


def parse_args(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description="启动日志模块/LKM 异常门禁")
    p.add_argument("--logs", default="/tmp/modtest-logs")
    p.add_argument("--cmds", default="", help="命令文件目录（默认 <logs>/cmds）")
    p.add_argument("--profiles", default="", help="空格分隔；空=自动除 modtest 外全部")
    p.add_argument("--install-logs", default="/tmp/dsm-install/logs")
    p.add_argument("--install-optional", action="store_true",
                   help="允许安装日志缺失（use_prebuilt=true 时）")
    p.add_argument("--module-allowlist",
                   default=os.path.join(here, "env-fail-allowlist.tsv"))
    p.add_argument("--allowlist", default=os.path.join(here,
                                                       "bootlog-allowlist.tsv"))
    p.add_argument("--out", default="/tmp/modtest-logs/bootlog-result.json")
    p.add_argument("--platform", default="")
    p.add_argument("--line", default="")
    p.add_argument("--kver", default="")
    p.add_argument("--model", default="")
    p.add_argument("--kernel", default="")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args(argv)
    if args.selftest:
        return args
    if not args.cmds:
        args.cmds = os.path.join(args.logs, "cmds")
    return args


def main(argv):
    args = parse_args(argv)
    if args.selftest:
        return selftest()
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
