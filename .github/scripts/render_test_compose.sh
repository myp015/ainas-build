#!/usr/bin/env bash
#
# 生成测试用 compose：在 ova compose 基础上注入模块盘与 SCSI profile。
#
# 用法：
#   render_test_compose.sh <src compose> <dst compose> <profile> <with_moddisk:true|false>
#
# profile：
#   base | virtio-scsi | megaraid | mptsas
#
# 约定：compose 文件放在 rr/ 目录下，volume `./:/storage/alpine`；
#       rr.img / modtest.img / scsi-<profile>.img 由调用方放在同目录。

set -euo pipefail

SRC="${1:?缺少源 compose}"
DST="${2:?缺少目标 compose}"
PROFILE="${3:?缺少 profile}"
WITH_MODDISK="${4:-false}"

case "${PROFILE}" in
  base|modtest) EXTRA="" ;;
  virtio-scsi)
    EXTRA="-device virtio-scsi-pci,id=vscsi0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=vdisk -device scsi-hd,drive=vdisk,bus=vscsi0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  megaraid)
    EXTRA="-device megasas,id=mr0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=mrdisk -device scsi-hd,drive=mrdisk,bus=mr0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  mptsas)
    EXTRA="-device mptsas1068,id=lsi0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=lsidisk -device scsi-hd,drive=lsidisk,bus=lsi0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  *)
    echo "[E] 未知 profile: ${PROFILE}" >&2
    exit 1 ;;
esac

MODDISK=""
if [ "${WITH_MODDISK}" = "true" ]; then
  # 用 USB 存储挂模块盘：AHCI 控制器下 QEMU 的 IDE 盘不走 NCQ，DSM 的
  # ahci 驱动会持续 FPDMA QUEUED 失败（实测 ata13 大量 ABRT 后启动卡死）；
  # usb-storage 不用 NCQ，且 DSM 不会把它当内部盘纳入存储池。
  MODDISK="-drive file=/storage/alpine/modtest.img,media=disk,format=raw,if=none,id=moddisk -device usb-storage,bus=usb0.0,port=1,drive=moddisk,removable=on"
fi

python3 - "${SRC}" "${DST}" "${EXTRA}" "${MODDISK}" <<'PY'
import re, sys

src, dst, extra, moddisk = sys.argv[1:5]
text = open(src, encoding="utf-8").read()

# 1) container_name 统一为 dsm（driver 按这个名字 attach）
text = re.sub(r'^(\s*)container_name:\s*\S+$', r'\1container_name: dsm', text, flags=re.M)

# 2) restart: always -> "no"：测试容器不能自动重启掩盖失败
text = re.sub(r'^(\s*)restart:\s*.*$', r'\1restart: "no"', text, flags=re.M)

# 3) 追加模块盘与 profile 设备到 ARGUMENTS（单行字符串）
m = re.search(r'^(\s*)ARGUMENTS:\s*"(.*)"\s*$', text, flags=re.M)
if not m:
    raise SystemExit("[E] compose 中未找到单行 ARGUMENTS 字符串")
indent, base = m.group(1), m.group(2)
added = " ".join(x for x in (moddisk, extra) if x)
new_value = (base + (" " + added if added else "")).replace('"', '\\"')
text = text[:m.start()] + '%sARGUMENTS: "%s"' % (indent, new_value) + text[m.end():]

open(dst, "w", encoding="utf-8").write(text)
print("[INFO] 已生成 %s（profile=%s moddisk=%s）" % (dst, extra or "base", bool(moddisk)))
PY
