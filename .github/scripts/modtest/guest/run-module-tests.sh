#!/bin/sh
#
# 在 DSM guest 内逐个测试模块（安全档）。
#
# 由 CI 通过串口驱动执行（命令文件先挂载引导盘 p3 到 /mnt/modtest）：
#   sh /mnt/modtest/modtest/run-module-tests.sh <modules_key>
#
# 模块来源：引导盘 p3 内的 modules/<modules_key>.tgz（与本机内核同源）。
# 结果全部经串口输出（@@M|idx|name|state|rc|err），不再写模块盘：
# DSM 会把额外 USB 存储命名为 synoboot（与引导盘冲突），额外 ahci 盘会
# 触发 NCQ 错误导致启动卡死，因此放弃独立模块盘方案。
#
# 安全规则：
#   - 已加载模块只记录（/proc/modules + /sys/module/<name>/srcversion），绝不 rmmod；
#   - 未加载模块逐个 insmod，记录 rc 与错误文本；
#   - update/ 同名模块在 root 已加载时记为 SKIP_UPDATE；
#   - 清单 policy=hazard（known-hazards.tsv 命中的官方内核缺陷）记为 SKIP_HAZARD，不加载。

set -u

MOUNT=/mnt/modtest
KEY="${1:-}"
LIST="${MOUNT}/modtest/module-list.tsv"
TGZ="${MOUNT}/modules/${KEY}.tgz"
WORK=/tmp/modtest-payload

log() { echo "[modtest] $*"; }

[ -f "${LIST}" ] || { echo "@@MODTEST_DONE@@ status=no_list"; exit 1; }
[ -f "${TGZ}" ] || { echo "@@MODTEST_DONE@@ status=no_tgz"; exit 1; }

rm -rf "${WORK}"
mkdir -p "${WORK}"
log "解包模块包: ${TGZ}"
if ! tar xzf "${TGZ}" -C "${WORK}"; then
  echo "@@MODTEST_DONE@@ status=untar_failed"
  exit 1
fi

total=0
loaded=0
ok=0
fail=0
skip=0

# 在每个可能触发内核崩溃的动作前打标记，便于 CI 把 Oops/BUG 归因到具体模块。
# /dev/kmsg 不可写时静默降级（仅失去归因能力，不因此判失败）。
#
# 标记固定为 KERN_DEBUG（<7> 前缀）：guest 的 stdout 与内核控制台共用同一个
# 串口 pty，默认级别（KERN_DEFAULT=4）的 printk 会插进正在输出的 @@M 记录行
# 中间，把一行截断、尾段丢失（2026-11-06 DS1621+ 实测：426 条记录中 1 条被
# 下一个模块的 marker 插断，G-M1 误报"逐条=425 清单=426"）。KERN_DEBUG 在
# console_loglevel=7 时不输出到控制台，但仍进内核环形缓冲，末尾 dmesg 归因不受影响。
mark() {
  printf '<7>modtest-marker idx=%s name=%s\n' "$idx" "$name" > /dev/kmsg 2>/dev/null || true
}

# 少数环境把 console_loglevel 调到 8（连 KERN_DEBUG 也上控制台）：
# 进入循环前临时降到 7，循环结束后恢复原值。
console_level="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || echo 7)"
case "${console_level}" in
  ''|*[!0-9]*) console_level=7 ;;
esac
restore_level=""
if [ "${console_level}" -gt 7 ]; then
  if echo 7 > /proc/sys/kernel/printk 2>/dev/null; then
    restore_level="${console_level}"
  fi
fi

while IFS='	' read -r idx name rel depends ko_srcver policy; do
  [ -n "${idx}" ] || continue
  # 清单用 "-" 占位空字段（空 depends/srcver 的连续 TAB 会被 read 折叠，
  # 导致 pkg 取到 policy、hazard 策略丢失）。
  [ "${ko_srcver}" = "-" ] && ko_srcver=""
  ko="${WORK}/${rel}"
  total=$((total + 1))

  if [ ! -f "${ko}" ]; then
    echo "@@M|${idx}|${name}|MISSING|-|file_not_found"
    fail=$((fail + 1))
    continue
  fi

  if grep -q "^${name} " /proc/modules 2>/dev/null || [ -d "/sys/module/${name}" ]; then
    sys_src="$(cat "/sys/module/${name}/srcversion" 2>/dev/null || echo '-')"
    if [ "${policy}" = "update" ]; then
      state="SKIP_UPDATE"
      skip=$((skip + 1))
    else
      state="LOADED"
      loaded=$((loaded + 1))
    fi
    echo "@@M|${idx}|${name}|${state}|-|src=${sys_src} pkg=${ko_srcver}"
    continue
  fi

  # 已知官方内核缺陷（清单 policy=hazard）：只记录，绝不 insmod，避免打挂测试机
  if [ "${policy}" = "hazard" ]; then
    echo "@@M|${idx}|${name}|SKIP_HAZARD|-|official_kernel_bug"
    skip=$((skip + 1))
    continue
  fi

  mark
  err="$(insmod "${ko}" 2>&1)"
  rc=$?
  err="$(printf '%s' "${err}" | tr '\n\t|' '   ' | cut -c1-200)"
  sys_src="$(cat "/sys/module/${name}/srcversion" 2>/dev/null || echo '-')"
  if [ "${rc}" -eq 0 ]; then
    state="INSMOD_OK"
    ok=$((ok + 1))
  else
    state="INSMOD_FAIL"
    fail=$((fail + 1))
  fi

  echo "@@M|${idx}|${name}|${state}|${rc}|src=${sys_src} pkg=${ko_srcver} err=${err}"
done <"${LIST}"

# 恢复控制台日志级别（仅在循环前为压制 KERN_DEBUG 标记调低过时才动作）。
if [ -n "${restore_level}" ]; then
  echo "${restore_level}" > /proc/sys/kernel/printk 2>/dev/null || true
fi

# 只回传故障相关 dmesg 摘要（不整份回传，避免串口超时）。
echo "---DMESG-BEGIN---"
# tail 放宽到 1000：marker 每模块一条（400~700 条），300 行会把前半程模块的
# 证据（尤其 "exports duplicate symbol"，对应 insmod 的 "Invalid module format"）
# 截掉，导致只读门禁无法把 BUILTIN_DUP 与真 vermagic 失败区分开。
dmesg | grep -Ei 'modtest-marker|BUG:|WARNING:|Oops|panic|Call Trace|Unable to handle|general protection|\] (IP|RIP):|firmware.*(fail|error)|exports duplicate symbol|disagrees about version of symbol|Unknown symbol' | tail -n 1000
echo "---DMESG-END---"

echo "@@MODTEST_DONE@@ total=${total} loaded=${loaded} ok=${ok} fail=${fail} skip=${skip} status=done"
