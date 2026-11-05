#!/usr/bin/env bash
#
# 生成测试用 compose：在 ova compose 基础上注入 SCSI profile 设备。
#
# 用法：
#   render_test_compose.sh <src compose> <dst compose> <profile>
#
# profile：
#   base / modtest   无额外设备（模块包走引导盘 p3，不需要第二块盘）
#   virtio-scsi / megaraid / mptsas   注入对应 SCSI 控制器与测试盘
#   nic              按 modtest/nic-models.tsv 注入额外虚拟网卡（取 IP 验证）
#
# 约定：compose 文件放在 rr/ 目录下，volume `./:/storage/alpine`；
#       scsi-<profile>.img 由调用方放在同目录。

set -euo pipefail

SRC="${1:?缺少源 compose}"
DST="${2:?缺少目标 compose}"
PROFILE="${3:?缺少 profile}"

case "${PROFILE}" in
  base|modtest) EXTRA="" ;;
  virtio-scsi)
    EXTRA="-device virtio-scsi-pci,id=vscsi0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=vdisk -device scsi-hd,drive=vdisk,bus=vscsi0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  megaraid)
    EXTRA="-device megasas,id=mr0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=mrdisk -device scsi-hd,drive=mrdisk,bus=mr0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  mptsas)
    EXTRA="-device mptsas1068,id=lsi0 -drive file=/storage/alpine/scsi-${PROFILE}.img,media=disk,format=raw,if=none,id=lsidisk -device scsi-hd,drive=lsidisk,bus=lsi0.0,channel=0,scsi-id=0,lun=0,rotation_rate=1" ;;
  nic)
    # 额外虚拟网卡：型号/MAC/网关来自 modtest/nic-models.tsv（唯一来源）。
    # 每块网卡配独立 user-mode netdev——slirp 自带 DHCP，dhcpstart 由网关
    # 推出（10.0.N.15）；romfile= 关掉网卡的 option ROM，避免多块网卡带出
    # 额外 PXE 启动项、拖慢引导或抢占 bootindex。
    NIC_TABLE="$(cd "$(dirname "$0")/modtest" && pwd)/nic-models.tsv"
    [ -f "${NIC_TABLE}" ] || { echo "[E] 缺少网卡表 ${NIC_TABLE}" >&2; exit 1; }
    EXTRA=""
    idx=0
    while IFS=$'\t' read -r model mac mods gw; do
      case "${model}" in
        ''|'#'*) continue ;;
      esac
      idx=$((idx + 1))
      subnet="${gw%.*}"
      EXTRA+=" -netdev user,id=nicnet${idx},net=${subnet}.0/24,dhcpstart=${subnet}.15"
      EXTRA+=" -device ${model},id=nicdev${idx},netdev=nicnet${idx},romfile=,mac=${mac}"
    done < "${NIC_TABLE}"
    ;;
  *)
    echo "[E] 未知 profile: ${PROFILE}" >&2
    exit 1 ;;
esac

python3 - "${SRC}" "${DST}" "${EXTRA}" <<'PY'
import re, sys

src, dst, extra = sys.argv[1:4]
text = open(src, encoding="utf-8").read()

# 1) container_name 统一为 dsm（driver 按这个名字 attach）
text = re.sub(r'^(\s*)container_name:\s*\S+$', r'\1container_name: dsm', text, flags=re.M)

# 2) restart: always -> "no"：测试容器不能自动重启掩盖失败
text = re.sub(r'^(\s*)restart:\s*.*$', r'\1restart: "no"', text, flags=re.M)

# 3) 追加 profile 设备到 ARGUMENTS（单行字符串）
if extra:
    m = re.search(r'^(\s*)ARGUMENTS:\s*"(.*)"\s*$', text, flags=re.M)
    if not m:
        raise SystemExit("[E] compose 中未找到单行 ARGUMENTS 字符串")
    indent, base = m.group(1), m.group(2)
    new_value = (base + " " + extra).replace('"', '\\"')
    text = text[:m.start()] + '%sARGUMENTS: "%s"' % (indent, new_value) + text[m.end():]

open(dst, "w", encoding="utf-8").write(text)
print("[INFO] 已生成 %s（profile=%s extra=%s）" % (dst, extra or "base", bool(extra)))
PY
