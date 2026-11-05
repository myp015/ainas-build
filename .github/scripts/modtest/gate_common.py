#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""门禁脚本共享工具：按路径加载 parse_results.py 的正则与白名单逻辑。

为什么不用 `import parse_results`：CI 用 `python3 -I` 运行，隔离模式会把
脚本所在目录从 sys.path 移除，同目录模块无法直接 import。这里用
importlib 以绝对路径加载，等价于“只借用常量和纯函数”，不执行它的 main()。

复用清单（避免三份门禁各自复制正则后漂移）：
  FAULT_RE / IP_RE / ANSI_RE / UNKNOWN_SYM_RE / DUP_EXPORT_RE /
  FIRMWARE_FAIL_RE / load_allowlist / allowlisted

另外提供两个纯函数：读文件行、过滤串口命令回显。串口回读会把**发出去的
命令行本身**打印回来（含 `grep -iE 'BUG:|Oops'` 这种模式串），不过滤就会
把命令回显当成故障——这是本文件 exists 的主要原因。
"""

import importlib.util
import os
import re

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_parse_results():
    path = os.path.join(_HERE, "parse_results.py")
    spec = importlib.util.spec_from_file_location(
        "_modtest_parse_results", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PR = _load_parse_results()

FAULT_RE = PR.FAULT_RE
IP_RE = PR.IP_RE
ANSI_RE = PR.ANSI_RE
UNKNOWN_SYM_RE = PR.UNKNOWN_SYM_RE
DUP_EXPORT_RE = PR.DUP_EXPORT_RE
FIRMWARE_FAIL_RE = PR.FIRMWARE_FAIL_RE
load_allowlist = PR.load_allowlist
allowlisted = PR.allowlisted

DUMP_DONE_RE = re.compile(r"__DSMEXEC_\d+__DONE")
# 命令回显特征：提示符开头、命令替换、SUBST 未展开。
# 注意不要把 __DSMEXEC_N__DONE / @@PROBE_DONE@@ 当回显——它们正是 guest
# 执行器输出的“命令跑完”标记，过滤掉就没法判断采集完整性了。
ECHO_MARKERS = ("$(", "${", "`")
PROMPT_RE = re.compile(r"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:.*#")
# 串口并发写入会把 ANSI 颜色序列截断（只剩 `;32m` 前缀）、或把命令字打错
# （run 42002461964：`Unknnown symbol`），导致整行精确匹配和行首提示符都失效。
# 提示符出现在行内任意位置仍是可靠判据——真实内核日志不会包含 `user@host:~#`。
PROMPT_ANY_RE = re.compile(r"[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^\s]*[#$]")


def read_lines(path):
    """逐行读取（容忍非 UTF-8 字节与 ANSI 转义），返回去掉行尾的字符串列表。"""
    out = []
    with open(path, "rb") as f:
        for raw in f:
            text = ANSI_RE.sub("", raw.decode("utf-8", "replace"))
            out.append(text.replace("\r", "").rstrip("\n"))
    return out


def load_command_echoes(cmd_dir, profile):
    """读取本 profile 发出的命令文件，返回整行集合（用于精确匹配回显）。"""
    path = os.path.join(cmd_dir, "%s.commands" % profile)
    if not os.path.isfile(path):
        return set()
    lines = set()
    for line in read_lines(path):
        s = line.strip()
        if s and not s.startswith("#"):
            lines.add(s)
    return lines


def is_echo(line, echoes):
    """判断一行是否是串口命令回显（而非 guest 真实输出）。"""
    s = line.strip()
    if not s:
        return True
    if s in echoes:
        return True
    if PROMPT_RE.match(s):
        return True
    if PROMPT_ANY_RE.search(s):
        return True
    for marker in ECHO_MARKERS:
        if marker in s:
            return True
    return False


def cmd_files(logdir):
    """按 cmd-N.out 的数字顺序返回文件列表（N 不是零填充，必须按数值排）。"""
    files = []
    for name in os.listdir(logdir) if os.path.isdir(logdir) else []:
        m = re.match(r"cmd-(\d+)\.out$", name)
        if m:
            files.append((int(m.group(1)), os.path.join(logdir, name)))
    files.sort()
    return [p for _, p in files]
