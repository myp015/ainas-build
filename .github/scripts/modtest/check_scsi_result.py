#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ova-test SCSI/SAS profile 门禁：控制器驱动是否加载、测试盘是否识别、内核是否崩。

输入是 run_profile.sh 落盘的串口输出（<logs>/<profile>/cmd-*.out）。SCSI
profile 复用 probe.commands，优先读结构化行：
  @@SCSIHOST|hostN|proc_name|device 路径
  @@BLK|设备名|扇区数|vendor|model|所属 hostN
兼容旧 artifact 的自由文本行（/sys/class/scsi_host/... proc_name=...、
/sys/block/<b> ... size=...、ls -l /sys/block 的符号链接）。

判据（第一轮口径，用户 2026-11-05 定稿）：
  G-S1 采集完整性：日志目录、cmd-*.out、完成标记齐全 —— 硬失败
  G-S2 崩溃：dmesg 命中 BUG:/Oops/panic/#PF/GP —— 硬失败
         · IP 归属到模块 ⇒ 我们的 .ko 缺陷，**任何白名单都不能豁免**
         · IP 落在内核内建代码 ⇒ 需 RR 对照复现后才可登记 KERNEL_INTERNAL
         · 解析不到 IP ⇒ 保守硬失败（不豁免）
  G-S3 控制器驱动已加载 / G-S4 scsi_host proc_name 匹配 /
  G-S5 测试盘（2G=4194304 扇区）被识别 —— 只报告（--strict-ident 时硬失败）

退出码：0=通过（识别问题只打印 [INFO]）；1=硬失败；2=输入/环境错误。
"""

import argparse
import fnmatch
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_common as G  # noqa: E402

HOST_LEGACY_RE = re.compile(r"/sys/class/scsi_host/(host\d+)\s+proc_name=(\S+)")
BLK_LEGACY_RE = re.compile(
    r"/sys/block/(\S+)\s+vendor=(.*?) ?model=(.*?) ?size=(\d+)")
MOD_RE = re.compile(r"^(\S+)\s+srcversion=(\S+)")
LSPCI_RE = re.compile(r"Kernel driver in use:\s+(\S+)")
# `ls -l /sys/block` 的行既可能是裸的 "sata3 -> ../devices/..."，也可能是
# 完整权限串 "lrwxrwxrwx 1 root root 0 ... sata3 -> ..."：取箭头前最后一个
# token 作为设备名。
LINK_RE = re.compile(r"^.*?(\S+)\s+->\s+(.+)$")


def fail(msg):
    print("[FAIL] %s" % msg)
    return 1


def load_table(path):
    rows = {}
    for line in G.read_lines(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split("\t")
        if len(parts) < 5:
            print("[FAIL] SCSI 期望表列数不足: %r" % line)
            raise SystemExit(2)
        rows[parts[0]] = {
            "device": parts[1],
            "modules": [x for x in parts[2].split("|") if x],
            "proc_names": [x for x in parts[3].split("|") if x],
            "disk_sectors": int(parts[4]),
        }
    if not rows:
        print("[FAIL] SCSI 期望表为空: %s" % path)
        raise SystemExit(2)
    return rows


def load_allowlist(path):
    rows = []
    if not path or not os.path.isfile(path):
        return rows
    for line in G.read_lines(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split("\t")
        if len(parts) < 5:
            print("[FAIL] SCSI 白名单行格式非法: %r" % line)
            raise SystemExit(2)
        rows.append({"platform": parts[0], "profile": parts[1],
                     "verdict": parts[2], "reason": parts[3],
                     "evidence": " ".join(parts[4:])})
    return rows


def collect(logdir, profile, cmds_dir):
    """解析一个 profile 的全部 cmd-*.out，返回 (数据结构, 有效行, 文件列表)。"""
    files = G.cmd_files(logdir)
    echoes = G.load_command_echoes(cmds_dir, profile)
    lines = []
    for path in files:
        for line in G.read_lines(path):
            s = line.strip()
            if s and not G.is_echo(s, echoes):
                lines.append(s)

    data = {"hosts": [], "blocks": [], "modules": {}, "drivers_in_use": [],
            "sysblock_links": {}, "done": False}

    for line in lines:
        if line.startswith("@@"):
            parts = line.split("|")
            tag = parts[0]
            if tag == "@@SCSIHOST" and len(parts) >= 3:
                data["hosts"].append({"host": parts[1], "proc_name": parts[2],
                                      "path": parts[3] if len(parts) > 3 else ""})
            elif tag == "@@BLK" and len(parts) >= 6:
                data["blocks"].append({"name": parts[1], "size": parts[2],
                                       "vendor": parts[3].strip(),
                                       "model": parts[4].strip(),
                                       "host": parts[5].strip()})
            elif tag == "@@PROBE_DONE@@":
                data["done"] = True
            continue

        m = HOST_LEGACY_RE.search(line)
        if m:
            data["hosts"].append({"host": m.group(1), "proc_name": m.group(2),
                                  "path": ""})
            continue
        m = BLK_LEGACY_RE.search(line)
        if m:
            data["blocks"].append({"name": m.group(1), "size": m.group(4),
                                   "vendor": m.group(2).strip(),
                                   "model": m.group(3).strip(), "host": ""})
            continue
        m = MOD_RE.match(line)
        if m:
            data["modules"][m.group(1)] = m.group(2).strip()
            continue
        m = LSPCI_RE.search(line)
        if m:
            data["drivers_in_use"].append(m.group(1))
            continue
        m = LINK_RE.match(line)
        if m and "host" in m.group(2):
            data["sysblock_links"][m.group(1)] = m.group(2)
            continue
        if G.DUMP_DONE_RE.search(line):
            data["done"] = True

    # 旧格式没有 @@BLK 的 host 字段：从 ls -l 的符号链接补
    for blk in data["blocks"]:
        if blk["host"]:
            continue
        m = re.search(r"/host(\d+)/", data["sysblock_links"].get(blk["name"], ""))
        if m:
            blk["host"] = "host" + m.group(1)
    return data, lines, files


def scan_faults(lines):
    """返回崩溃现场列表；每条含行号、原文、IP 归属（module/kernel/unknown）。

    归属规则与 parse_results.py 一致：故障行之后的 IP/RIP 行带 [模块] 尾注
    ⇒ 模块内；有 IP 行但无模块尾注 ⇒ 内核内建代码；完全没有 IP 行 ⇒ unknown
    （保守处理，不允许豁免）。
    """
    faults = []
    for i, line in enumerate(lines):
        if not G.FAULT_RE.search(line):
            continue
        ip_lines = []
        for nxt in lines[i + 1:i + 41]:
            m = G.IP_RE.search(nxt)
            if m:
                ip_lines.append({"text": nxt, "module": m.group(2)})
        modules = [x for x in (ip["module"] for ip in ip_lines) if x]
        if modules:
            attribution = "module"
        elif ip_lines:
            attribution = "kernel"
        else:
            attribution = "unknown"
        faults.append({"line": i + 1, "text": line,
                       "attribution": attribution,
                       "modules": sorted(set(modules)),
                       "ips": ip_lines[:3]})
    return faults


def allowlisted_fault(rows, platform, profile):
    for row in rows:
        if row["verdict"] != "KERNEL_INTERNAL" or row["profile"] != profile:
            continue
        if fnmatch.fnmatchcase(platform, row["platform"]):
            return row
    return None


def check_profile(profile, cfg, args, ctx, allow_rows):
    logdir = os.path.join(args.logs, profile)
    result = {"profile": profile, "expected": cfg, "gates": [],
              "disk": None, "driver": None, "host": None, "faults": []}

    def gate(gid, ok, detail, level):
        result["gates"].append({"id": gid, "pass": ok, "level": level,
                                "detail": detail})

    if not os.path.isdir(logdir):
        gate("G-S1", False, "日志目录不存在: %s（run_profile 启动期即失败）"
             % logdir, "hard")
        docker = os.path.join(args.logs, profile, "docker.log")
        if os.path.isfile(docker):
            for line in G.read_lines(docker):
                if G.FAULT_RE.search(line):
                    result["faults"].append({"text": line.strip(),
                                             "attribution": "unknown",
                                             "source": "docker.log"})
        return result

    data, lines, files = collect(logdir, profile, args.cmds)
    if not files:
        gate("G-S1", False, "没有 cmd-*.out（串口采集未执行）", "hard")
        return result
    gate("G-S1", data["done"],
         "完成标记=%s，cmd 文件=%d" % ("有" if data["done"] else "缺失", len(files)),
         "hard")

    faults = scan_faults(lines)
    result["faults"] = faults
    hard_hits, exempts = [], []
    for f in faults:
        if f["attribution"] == "module":
            hard_hits.append("%s（IP 在模块 %s，不豁免）"
                             % (f["text"], ",".join(f["modules"])))
            continue
        if f["attribution"] == "kernel":
            row = allowlisted_fault(allow_rows, ctx["platform"], profile)
            if row:
                exempts.append("%s（KERNEL_INTERNAL：%s / %s）"
                               % (f["text"], row["reason"], row["evidence"]))
                continue
        hard_hits.append(f["text"])
    for msg in exempts:
        print("[EXEMPT] profile=%s %s" % (profile, msg))
    gate("G-S2", not hard_hits,
         "崩溃命中 %d 处" % len(hard_hits) if hard_hits else "无崩溃", "hard")

    # G-S3 驱动加载：模块 srcversion 存在，或 lspci 里出现期望驱动名
    mods = {m: v for m, v in data["modules"].items() if v and v != "absent"}
    loaded = [m for m in cfg["modules"] if m in mods]
    pci = [d for d in data["drivers_in_use"] if d in cfg["modules"]]
    driver_name = (loaded or pci or [None])[0]
    result["driver"] = {"loaded": bool(loaded or pci),
                        "via": "module" if loaded else ("lspci" if pci else ""),
                        "module": driver_name,
                        "srcversion": mods.get(driver_name, "")}
    gate("G-S3", result["driver"]["loaded"],
         "驱动 %s 已加载（%s）" % (driver_name or "<无>",
                                  result["driver"]["via"] or "无证据"), "soft")

    # G-S4 scsi_host 的 proc_name
    match_host = next((h for h in data["hosts"]
                       if h["proc_name"] in cfg["proc_names"]), None)
    result["host"] = match_host
    gate("G-S4", match_host is not None,
         "host=%s proc_name=%s（期望 %s）"
         % ((match_host or {}).get("host", "-"),
            (match_host or {}).get("proc_name", "-"),
            "|".join(cfg["proc_names"]),), "soft")

    # G-S5 测试盘：2G 稀疏盘 = 4194304 扇区（系统盘同 vendor 但尺寸不同）
    disk = None
    for blk in data["blocks"]:
        try:
            size = int(blk["size"])
        except (TypeError, ValueError):
            continue
        if size != cfg["disk_sectors"]:
            continue
        if not (blk["vendor"] or blk["model"]):
            continue  # md/loop/ram 没有 vendor/model
        if match_host and blk["host"] and blk["host"] != match_host["host"]:
            continue  # 明确挂在别的 host 上
        disk = blk
        break
    result["disk"] = disk
    gate("G-S5", disk is not None,
         "盘=%s size=%s vendor=%s model=%s host=%s"
         % (disk["name"], disk["size"], disk["vendor"], disk["model"],
            disk["host"] or "?") if disk else
         "未发现测试盘（%d 扇区）" % cfg["disk_sectors"], "soft")

    for g in result["gates"]:
        if g["pass"]:
            print("[PASS] profile=%s %s %s" % (profile, g["id"], g["detail"]))
        elif g["level"] == "hard":
            print("[FAIL] profile=%s %s %s" % (profile, g["id"], g["detail"]))
        else:
            print("[INFO] profile=%s %s %s" % (profile, g["id"], g["detail"]))
    for msg in hard_hits:
        print("[FAIL] profile=%s 崩溃：%s" % (profile, msg))
    return result


def run(args):
    table = load_table(args.table)
    allow_rows = load_allowlist(args.allowlist)
    ctx = {"platform": args.platform, "line": args.line,
           "kver": args.kver, "model": args.model, "kernel": args.kernel}
    profiles = args.profiles.split()
    if not profiles:
        return fail("未指定 profile")
    unknown = [p for p in profiles if p not in table]
    if unknown:
        return fail("期望表里没有 profile: %s" % ",".join(unknown))

    results, hard_fail = [], False
    for profile in profiles:
        r = check_profile(profile, table[profile], args, ctx, allow_rows)
        results.append(r)
        if not r["gates"]:
            hard_fail = True  # 目录缺失
        for g in r["gates"]:
            if not g["pass"] and (g["level"] == "hard" or args.strict_ident):
                hard_fail = True

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump({"schema": 1, "context": dict(ctx, profiles=profiles),
                   "profiles": results, "pass": not hard_fail}, f,
                  ensure_ascii=False, indent=2)
    print("[INFO] 结果写入 %s" % args.out)

    if hard_fail:
        print("[FAIL] SCSI/SAS 门禁未通过")
        return 1
    print("[PASS] SCSI/SAS 门禁通过（识别问题只报告，见上）")
    return 0


# ─────────────────────────── selftest ───────────────────────────

FIXTURE_GOOD = "\n".join([
    "root@SynologyNAS:~# for h in /sys/class/scsi_host/host*; do echo \"$h proc_name=$(cat $h/proc_name 2>/dev/null)\"; done",
    "/sys/class/scsi_host/host18 proc_name=megaraid_sas_pdoff",
    "root@SynologyNAS:~# for b in /sys/block/*; do echo \"$b vendor=$(cat $b/device/vendor 2>/dev/null) model=$(cat $b/device/model 2>/dev/null) size=$(cat $b/size 2>/dev/null)\"; done",
    "/sys/block/sata1 vendor=QEMU     model=HARDDISK size=5242880",
    "/sys/block/sata3 vendor=QEMU     model=QEMU HARDDISK size=4194304",
    "root@SynologyNAS:~# ls -l /sys/block",
    "sata3 -> ../devices/pci0000:00/0000:00:08.0/host18/target18:2:0/18:2:0:0/block/sata3",
    "root@SynologyNAS:~# for m in virtio_scsi megaraid_sas mptsas; do echo \"$m srcversion=$(cat /sys/module/$m/srcversion 2>/dev/null || echo absent)\"; done",
    "megaraid_sas srcversion=8F3C26CB1D436FAC6984AB3",
    "mptsas srcversion=absent",
    "__DSMEXEC_20__DONE",
])

FIXTURE_FAULT_MODULE = "\n".join([
    "[    9.1] BUG: unable to handle kernel NULL pointer dereference",
    "[    9.2] IP: [<ffffffffa2628ad3>] sdebug_driver_probe+0x.. [scsi_debug]",
    "[    9.3] ---[ end trace 1 ]---",
    "__DSMEXEC_20__DONE",
])

FIXTURE_FAULT_KERNEL = "\n".join([
    "[    9.1] BUG: unable to handle kernel NULL pointer dereference",
    "[    9.2] IP: [<ffffffff813e6116>] syno_usb_info_enum+0xa6/0x130",
    "[    9.3] ---[ end trace 1 ]---",
    "__DSMEXEC_20__DONE",
])

EXEMPT_TSV = ("v1000\tmegaraid\tKERNEL_INTERNAL\tsd_probe 空指针\tRR run 1\n")


def selftest():
    import io
    import tempfile
    from contextlib import redirect_stdout

    table_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "scsi-models.tsv")
    checks = [
        ("正常 megaraid（pdoff 命名 + 盘识别）", FIXTURE_GOOD, None, 0,
         "[PASS] SCSI/SAS 门禁通过"),
        ("模块内崩溃必须硬失败", FIXTURE_FAULT_MODULE, None, 1, "不豁免"),
        ("内核内建崩溃未豁免必须硬失败", FIXTURE_FAULT_KERNEL, None, 1,
         "[FAIL] profile=megaraid 崩溃"),
        ("内核内建崩溃 + RR 证据豁免", FIXTURE_FAULT_KERNEL, EXEMPT_TSV, 0,
         "[EXEMPT]"),
        ("命令回显里的故障模式不算崩溃", FIXTURE_GOOD, None, 0, "无崩溃"),
    ]
    failed = 0
    for name, text, allow, expect_rc, kw in checks:
        with tempfile.TemporaryDirectory() as root:
            logdir = os.path.join(root, "logs")
            sub = os.path.join(logdir, "megaraid")
            os.makedirs(sub)
            with open(os.path.join(sub, "cmd-1.out"), "w", encoding="utf-8") as f:
                f.write(text + "\n")
            argv = ["--logs", logdir, "--profiles", "megaraid",
                    "--table", table_path, "--platform", "v1000",
                    "--line", "7.3", "--kver", "4.4.302",
                    "--model", "DS1621+", "--kernel", "official",
                    "--out", os.path.join(root, "out.json")]
            if allow:
                ap = os.path.join(root, "allow.tsv")
                with open(ap, "w", encoding="utf-8") as f:
                    f.write(allow)
                argv += ["--allowlist", ap]
            args = parse_args(argv)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = run(args)
            out = buf.getvalue()
            if rc != expect_rc or kw not in out:
                failed += 1
                sys.stderr.write("[FAIL] %s: rc=%d(期望 %d) 关键字=%r\n%s\n"
                                 % (name, rc, expect_rc, kw, out[-800:]))
            else:
                print("[PASS] %s" % name)
    if failed:
        sys.stderr.write("[E] 自测失败 %d 项\n" % failed)
        return 1
    print("[PASS] check_scsi_result 自测 %d 项全部符合预期" % len(checks))
    return 0


def parse_args(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description="SCSI/SAS profile 门禁")
    p.add_argument("--logs", help="modtest 日志根目录（含 <profile>/cmd-*.out）")
    p.add_argument("--cmds", default="", help="命令文件目录（默认 <logs>/cmds）")
    p.add_argument("--profiles", default="", help="空格分隔的 profile 名")
    p.add_argument("--table", default=os.path.join(here, "scsi-models.tsv"))
    p.add_argument("--allowlist", default=os.path.join(here, "scsi-allowlist.tsv"))
    p.add_argument("--out", default="/tmp/modtest-logs/scsi-result.json")
    p.add_argument("--platform", default="")
    p.add_argument("--line", default="")
    p.add_argument("--kver", default="")
    p.add_argument("--model", default="")
    p.add_argument("--kernel", default="")
    p.add_argument("--strict-ident", action="store_true",
                   help="识别问题也硬失败（第一轮默认关闭）")
    p.add_argument("--selftest", action="store_true")
    args = p.parse_args(argv)
    if args.selftest:
        return args
    if not args.logs or not args.profiles:
        p.error("缺少 --logs 或 --profiles")
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
