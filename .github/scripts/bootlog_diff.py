#!/usr/bin/env python3
#
# 启动日志归一化与对比（ainas vs RROrg 同环境双跑）。
#
# 用法：
#   bootlog_diff.py <ainas日志> <rr日志> <输出前缀>
#
# 输出：
#   <输出前缀>.diff           unified diff（归一化后）
#   <输出前缀>.summary.txt    分类摘要（行数、模块/驱动差异、驱动探测差异）
#
# 归一化只抹掉每次运行必然不同的噪声：时间戳、地址、CPU 编号、MAC、UUID、
# IP、PCI 地址、序列号、ANSI 转义。模块名、驱动名、设备型号、错误文本全部保留。

import difflib
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

RULES = [
    (re.compile(r"\[\s*\d+\.\d+\]"), ""),                 # 内核时间戳
    (re.compile(r"\[\s*\d{2}:\d{2}:\d{2}\.\d+\]"), ""),    # 用户态时间戳
    (re.compile(r"\[\s*\d{2}:\d{2}:\d{2}\]"), ""),
    (re.compile(r"0x[0-9a-fA-F]+"), "0xADDR"),
    (re.compile(r"\bCPU#\d+"), "CPU#N"),
    (re.compile(r"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"), "MAC"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "UUID"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "IP"),
    (re.compile(r"\b\d+\.\d+\.\d+\.\d+\.\d+\.\d+\b"), "PCI"),
    (re.compile(r"\(propagated\)"), ""),
    (re.compile(r"\b[A-Z0-9]{8,}\b"), "SERIAL"),          # 大写序列号/卷 ID
    (re.compile(r"\s+"), " "),
]

# 这些词出现的行单独归到「模块/驱动」类，便于人工核对
INTEREST = ("module", "insmod", "modprobe", "Loading", "loaded",
            "driver", "probe", "firmware", "scsi", "ata", "nic", "ethernet")


def normalize(path):
    lines = []
    with open(path, "rb") as f:
        for raw in f:
            text = ANSI.sub("", raw.decode("utf-8", "replace")).replace("\r", "")
            text = text.rstrip("\n")
            if not text.strip():
                continue
            for pat, repl in RULES:
                text = pat.sub(repl, text)
            lines.append(text.strip())
    return lines


def main(argv):
    if len(argv) not in (4, 6):
        print("用法: bootlog_diff.py <日志A> <日志B> <输出前缀> [标签A 标签B]",
              file=sys.stderr)
        return 2

    ainas_path, rr_path, prefix = argv[1], argv[2], argv[3]
    label_a = argv[4] if len(argv) == 6 else "ainas"
    label_b = argv[5] if len(argv) == 6 else "RROrg"
    ainas = normalize(ainas_path)
    rr = normalize(rr_path)

    diff = list(difflib.unified_diff(
        ainas, rr, fromfile=label_a, tofile=label_b, lineterm="", n=3))
    with open(prefix + ".diff", "w", encoding="utf-8") as f:
        f.write("\n".join(diff) + "\n")

    only_ainas = [l[1:] for l in diff if l.startswith("-") and not l.startswith("---")]
    only_rr = [l[1:] for l in diff if l.startswith("+") and not l.startswith("+++")]

    def interesting(lines):
        return [l for l in lines if any(k.lower() in l.lower() for k in INTEREST)]

    # 分类摘要：只看差异行，按关键症状分组，便于区分"预期差异"与"真实缺陷"
    CATEGORIES = (
        ("Unknown symbol（未解析符号，真实缺陷）", "unknown symbol"),
        ("probe failed（驱动探测失败）", "probe failed"),
        ("firmware（固件加载问题）", "firmware"),
    )

    def category_hits(lines):
        hits = {}
        for name, token in CATEGORIES:
            hits[name] = [l for l in lines if token in l.lower()]
        return hits

    hits_a = category_hits(only_ainas)
    hits_b = category_hits(only_rr)

    with open(prefix + ".summary.txt", "w", encoding="utf-8") as f:
        f.write("%s 行数=%d  %s 行数=%d\n"
                % (label_a, len(ainas), label_b, len(rr)))
        f.write("仅 %s=%d 仅 %s=%d\n\n"
                % (label_a, len(only_ainas), label_b, len(only_rr)))

        f.write("== 差异分类计数 ==\n")
        for name, _ in CATEGORIES:
            f.write("- %s: 仅%s=%d 仅%s=%d\n"
                    % (name, label_a, len(hits_a[name]),
                       label_b, len(hits_b[name])))
        f.write("\n")

        f.write("== 仅 %s 的模块/驱动行 ==\n" % label_a)
        for l in interesting(only_ainas):
            f.write(l + "\n")
        f.write("\n== 仅 %s 的模块/驱动行 ==\n" % label_b)
        for l in interesting(only_rr):
            f.write(l + "\n")
        for name, _ in CATEGORIES:
            for side, hits in ((label_a, hits_a[name]), (label_b, hits_b[name])):
                if hits:
                    f.write("\n== 仅 %s：%s ==\n" % (side, name))
                    for l in hits[:50]:
                        f.write(l + "\n")

    print("[INFO] %s: 仅%s=%d 仅%s=%d unknown_symbol(%s=%d,%s=%d) → %s.summary.txt"
          % (prefix, label_a, len(only_ainas), label_b, len(only_rr),
             label_a, len(hits_a["Unknown symbol（未解析符号，真实缺陷）"]),
             label_b, len(hits_b["Unknown symbol（未解析符号，真实缺陷）"]),
             prefix))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
