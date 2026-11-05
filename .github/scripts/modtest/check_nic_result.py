#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ova-test nic profile 门禁：断言每块额外虚拟网卡都拿到 IPv4。

输入是 run_profile.sh 落盘的串口输出（<logs>/cmd-*.out），guest 侧
run-nic-tests.sh 打印 `@@NIC|model|mac|ifname|driver|ipv4|gateway|ping`。

判据（fail-fast，任一不满足即非零退出）：
  1. 必须出现 `@@NIC_DONE@@ status=ok`（脚本跑完，不是中途被串口打断）；
  2. 表里每块网卡都要有对应 MAC 的记录，且 ifname、ipv4 都不是 "-"。
网关 ping 只作信息展示（slirp 对 ICMP 的处理与真实网络不同，不做硬判据）。
"""

import argparse
import glob
import os
import re
import sys


def die(msg):
    print("[FAIL] %s" % msg)
    sys.exit(1)


def load_table(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                die("网卡表列数不足: %r" % line)
            rows.append({"model": parts[0], "mac": parts[1].lower(),
                         "gw": parts[3]})
    if not rows:
        die("网卡表为空: %s" % path)
    return rows


def read_records(logs):
    """按 cmd-N.out 的数字顺序读，后出现的记录覆盖前面的（同 MAC 以最后一次为准）。"""
    files = glob.glob(os.path.join(logs, "cmd-*.out"))
    files.sort(key=lambda p: int(re.search(r"cmd-(\d+)\.out$", p).group(1)))
    records = {}
    done = None
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "@@NIC|" in line:
                    line = line[line.index("@@NIC|"):].strip()
                    parts = line.split("|")
                    if len(parts) < 8:
                        continue
                    # parts[0] 是 "@@NIC"
                    rec = {"model": parts[1], "mac": parts[2].lower(),
                           "ifname": parts[3], "driver": parts[4],
                           "ipv4": parts[5], "gw": parts[6], "ping": parts[7]}
                    records[rec["mac"]] = rec
                if "@@NIC_DONE@@" in line:
                    done = line[line.index("@@NIC_DONE@@"):].strip()
    return records, done


def main(argv):
    p = argparse.ArgumentParser(description="额外虚拟网卡取 IP 门禁")
    p.add_argument("--logs", required=True, help="nic profile 日志目录")
    p.add_argument("--table", required=True, help="nic-models.tsv")
    args = p.parse_args(argv)

    rows = load_table(args.table)
    if not os.path.isdir(args.logs):
        die("日志目录不存在: %s" % args.logs)
    records, done = read_records(args.logs)

    if not done:
        die("缺少 @@NIC_DONE@@ 完成标记（guest 脚本未跑完或串口半途中断）")
    if not done.endswith("status=ok"):
        die("guest 脚本自评失败: %s" % done)

    bad = []
    for row in rows:
        rec = records.get(row["mac"])
        if rec is None:
            bad.append("%s(%s): 无记录（设备未出现或驱动未加载）"
                       % (row["model"], row["mac"]))
            continue
        if rec["ifname"] == "-":
            bad.append("%s(%s): 没有生成网口（驱动未绑定）"
                       % (row["model"], row["mac"]))
            continue
        if rec["ipv4"] == "-":
            bad.append("%s(%s): %s 未拿到 IPv4（driver=%s）"
                       % (row["model"], row["mac"], rec["ifname"],
                          rec["driver"]))
            continue
        note = "" if rec["ping"] == "ok" else "（网关 ping=%s，仅提示）" % rec["ping"]
        print("[PASS] nic %s mac=%s if=%s driver=%s ip=%s%s"
              % (row["model"], row["mac"], rec["ifname"], rec["driver"],
                 rec["ipv4"], note))

    if bad:
        for msg in bad:
            print("[FAIL] %s" % msg)
        print("[FAIL] %d/%d 块网卡未通过" % (len(bad), len(rows)))
        return 1
    print("[PASS] %d/%d 块额外网卡全部拿到 IPv4" % (len(rows), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
