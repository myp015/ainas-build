#!/bin/sh
#
# 在 DSM guest 内验证额外虚拟网卡：驱动加载/绑定 → DHCP 取 IP → 网关连通性。
#
# 由 CI 通过串口执行（命令文件已把引导盘 p3 挂到 /mnt/modtest）：
#   sh /mnt/modtest/modtest/run-nic-tests.sh <modules_key>
#
# 模块来源与 modtest 相同：p3 内 modules/<modules_key>.tgz（与本机内核同源）。
#
# 驱动来源有两种，脚本不假设是哪一种：
#   - 目标内核把这些网卡编成内建（=y）：启动时就已绑定，/sys/module 里没有
#     对应条目，insmod 会被内核拒绝（重复符号），这里只验证内建驱动路径；
#     官方 DSM 5.10 内核即是如此（实测 e1000/e1000e/vmxnet3/8139cp/ne2k
#     在启动 ~7s 内全部绑定）。
#   - 编成模块（=m）且系统未预载：从测试包 insmod，验证的就是我们自己编的
#     这份 .ko。
#
# 安全：只 insmod 网卡驱动（绝不 rmmod 任何模块），DHCP 只对新增网口发起。
#
# 输出（串口回读，由 check_nic_result.py 判定）：
#   @@NIC|<model>|<mac>|<ifname>|<driver>|<ipv4>|<gateway>|<ping>
#   缺阶段的字段用 "-"；最后一行 @@NIC_DONE@@ status=ok|fail

set -u

MOUNT=/mnt/modtest
KEY="${1:-}"
TABLE="${MOUNT}/modtest/nic-models.tsv"
TGZ="${MOUNT}/modules/${KEY}.tgz"
WORK=/tmp/nic-payload

[ -f "${TABLE}" ] || { echo "@@NIC_DONE@@ status=no_table"; exit 1; }
[ -f "${TGZ}" ] || { echo "@@NIC_DONE@@ status=no_tgz"; exit 1; }

# 整包解压，口径与 run-module-tests.sh 一致（不裁剪依赖：ne2k_pci 需要 8390）
rm -rf "${WORK}"
mkdir -p "${WORK}"
if ! tar xzf "${TGZ}" -C "${WORK}"; then
  echo "@@NIC_DONE@@ status=untar_failed"
  exit 1
fi

# load_mod <module 名>：已加载的直接成功；否则从测试包 insmod。
# 包内文件名可能是连字符形式（ne2k-pci.ko 的模块名是 ne2k_pci），两种都试。
# 返回 0=已就绪，1=没有该 .ko，2=insmod 失败（多半是内建驱动占用了同名符号）。
load_mod() {
  m="$1"
  [ -d "/sys/module/${m}" ] && return 0
  f="${WORK}/${m}.ko"
  [ -f "${f}" ] || f="${WORK}/$(echo "${m}" | tr '_' '-').ko"
  [ -f "${f}" ] || return 1
  insmod "${f}" 2>/dev/null && return 0
  return 2
}

# 按表加载全部候选驱动：同一设备加载多个候选无害，绑定由内核决定
while IFS='	' read -r model mac mods gw; do
  case "${model}" in
    ''|'#'*) continue ;;
  esac
  old_ifs="${IFS}"
  IFS='|'
  for m in ${mods}; do
    load_mod "${m}"
    rc=$?
    # rc=0 已就绪；1=包里没有；2=insmod 失败（内建驱动占用同名符号等）
    echo "@@NICLOAD|${model}|${m}|rc=${rc}"
  done
  IFS="${old_ifs}"
done < "${TABLE}"

# 驱动 probe 到创建 netdev 需要一点时间
sleep 3

fail=0
while IFS='	' read -r model mac mods gw; do
  case "${model}" in
    ''|'#'*) continue ;;
  esac

  # 按 MAC 找网口：DSM 的 ethN 编号不固定，MAC 是表里写死的唯一定位手段
  ifname=""
  lmac="$(echo "${mac}" | tr 'A-F' 'a-f')"
  for d in /sys/class/net/*; do
    [ -r "${d}/address" ] || continue
    [ "$(cat "${d}/address" 2>/dev/null)" = "${lmac}" ] || continue
    ifname="${d##*/}"
    break
  done

  if [ -z "${ifname}" ]; then
    echo "@@NIC|${model}|${mac}|-|-|-|${gw}|-"
    fail=$((fail + 1))
    continue
  fi

  driver="$(basename "$(readlink "/sys/class/net/${ifname}/device/driver" 2>/dev/null)" 2>/dev/null)"
  [ -n "${driver}" ] || driver="-"

  ip link set "${ifname}" up 2>/dev/null || true

  ipv4="$(ip -4 -o addr show dev "${ifname}" 2>/dev/null | awk '$3=="inet"{print $4; exit}')"

  # synonetd 不一定给新增网口自动跑 DHCP，这里手动补一发（只针对这一个网口）
  if [ -z "${ipv4}" ]; then
    timeout 40 dhclient -1 -q \
      -pf "/var/run/dhclient-nic-${ifname}.pid" \
      -lf "/var/run/dhclient-nic-${ifname}.lease" \
      "${ifname}" 2>/dev/null || true
    sleep 1
    ipv4="$(ip -4 -o addr show dev "${ifname}" 2>/dev/null | awk '$3=="inet"{print $4; exit}')"
  fi

  ping_state="-"
  if [ -n "${ipv4}" ]; then
    if ping -c 1 -W 2 "${gw}" >/dev/null 2>&1; then
      ping_state=ok
    else
      ping_state=fail
    fi
  else
    ipv4="-"
    fail=$((fail + 1))
  fi

  echo "@@NIC|${model}|${mac}|${ifname}|${driver}|${ipv4}|${gw}|${ping_state}"
done < "${TABLE}"

if [ "${fail}" -eq 0 ]; then
  echo "@@NIC_DONE@@ status=ok"
else
  echo "@@NIC_DONE@@ status=fail count=${fail}"
fi
