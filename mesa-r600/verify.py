#!/usr/bin/env python3
"""校验 r600 VA 驱动产物的 ABI 是否能被 Emby 容器加载。

约束来自实测的原版驱动与容器环境（监 Job#210）：
  - 入口符号 __vaDriverInit_1_22（libva 2.22 / VA API 1.22）
  - 最高 GLIBC 符号版本 <= 2.27（容器 glibc 2.27）
  - 只依赖容器内已有的库（不含 libLLVM）
"""

import os
import re
import subprocess
import sys

SO = sys.argv[1] if len(sys.argv) > 1 else "mesa-r600/out/libgallium_drv_video.so"

ALLOWED_NEEDED = {
    "libdrm.so.2",
    "libdrm_radeon.so.1",
    "libdrm_amdgpu.so.1",
    "libz.so.1",
    "libm.so.6",
    "libdl.so.2",
    "librt.so.1",
    "libpthread.so.0",
    "libc.so.6",
    "ld-linux-x86-64.so.2",
}


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    errors = []

    if not os.path.isfile(SO):
        print(f"[FAIL] 产物不存在: {SO}")
        return 1

    dyn = run("readelf", "--dyn-syms", "-W", SO)
    if "__vaDriverInit_1_22" not in dyn:
        errors.append("缺少 __vaDriverInit_1_22 入口符号")

    ver = run("readelf", "--version-info", SO)
    vers = [tuple(map(int, v.split("."))) for v in re.findall(r"GLIBC_(\d+\.\d+(?:\.\d+)?)", ver)]
    top = max(vers) if vers else (0, 0)
    print(f"最高 GLIBC 符号版本: {'.'.join(map(str, top))}")
    if top > (2, 27):
        errors.append(f"GLIBC 符号版本 {top} 超过容器上限 2.27")

    needed = re.findall(r"Shared library: \[(.*?)\]", run("readelf", "-d", SO))
    print("NEEDED:", ", ".join(needed))
    if any("LLVM" in n for n in needed):
        errors.append("产物依赖了 libLLVM（容器内不存在）")
    extra = sorted(set(needed) - ALLOWED_NEEDED)
    if extra:
        errors.append(f"出现未预期依赖: {extra}")

    size = os.path.getsize(SO)
    print(f"产物大小: {size / 1024 / 1024:.1f} MiB")
    if size > 120 * 1024 * 1024:
        errors.append("产物体积异常（>120MiB）")

    if errors:
        for e in errors:
            print(f"[FAIL] {e}")
        return 1
    print("[PASS] ABI 校验全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
