#!/bin/sh
#
# 在 DSM guest 内逐个测试模块（安全档）。
#
# 由 CI 通过串口驱动执行：
#   sh /mnt/modtest/payload/run-module-tests.sh
#
# 安全规则：
#   - 已加载模块只记录（/proc/modules + /sys/module/<name>/srcversion），绝不 rmmod；
#   - 未加载模块逐个 insmod，记录 rc 与错误文本；
#   - 同名 root/update 模块：root 已加载时 update 条目记为 SKIP_UPDATE；
#   - 每条结果 append 后 sync，progress 文件用于 hang 后定位。
#
# 模块盘由 CI 生成（LABEL=MODTEST），布局：
#   /payload/modules/        .ko（含 update/）
#   /payload/module-list.tsv idx name rel depends ko_srcver policy
#   /results/                guest 写入

set -u

MOUNT=/mnt/modtest
PAYLOAD="${MOUNT}/payload"
RESULTS="${MOUNT}/results"
OUT="${RESULTS}/module-results.tsv"
PROGRESS="${RESULTS}/progress"

log() { echo "[modtest] $*"; }

# ── 1. 挂载模块盘 ─────────────────────────────────────────────────────
# 脚本自身就在模块盘上，无法自举挂载：CI 的命令文件会先挂载到 /mnt/modtest
# 再执行本脚本。这里检测已挂载则直接使用；未挂载时按 LABEL 探测并挂载（兜底）。
mkdir -p "${MOUNT}"
DEV=""
if [ -f "${PAYLOAD}/module-list.tsv" ]; then
  log "模块盘已由调用方挂载: ${MOUNT}"
else
  if command -v blkid >/dev/null 2>&1; then
    DEV="$(blkid -L MODTEST 2>/dev/null || true)"
    [ -n "${DEV}" ] || DEV="$(blkid 2>/dev/null | grep 'LABEL="MODTEST"' | cut -d: -f1 | head -n1)"
  fi
  if [ -z "${DEV}" ]; then
    for d in /dev/sd? /dev/vd? /dev/hd?; do
      [ -b "${d}" ] || continue
      if blkid "${d}" 2>/dev/null | grep -q 'LABEL="MODTEST"'; then
        DEV="${d}"
        break
      fi
    done
  fi
  if [ -z "${DEV}" ] || [ ! -b "${DEV}" ]; then
    log "ERROR: 未找到 MODTEST 模块盘"
    echo "@@MODTEST_DONE@@ total=0 loaded=0 ok=0 fail=0 skip=0 status=no_disk"
    exit 1
  fi

  mkdir -p "${MOUNT}/results"
  if ! mount -t ext4 -o rw "${DEV}" "${MOUNT}" 2>/dev/null; then
    modprobe ext4 >/dev/null 2>&1 || true
    if ! mount -t ext4 -o rw "${DEV}" "${MOUNT}" 2>/dev/null; then
      log "ERROR: 挂载 ${DEV} 失败"
      echo "@@MODTEST_DONE@@ total=0 loaded=0 ok=0 fail=0 skip=0 status=mount_failed"
      exit 1
    fi
  fi
  log "模块盘已挂载: ${DEV}"
fi

[ -f "${PAYLOAD}/module-list.tsv" ] || {
  log "ERROR: 模块盘上缺少 module-list.tsv"
  echo "@@MODTEST_DONE@@ total=0 loaded=0 ok=0 fail=0 skip=0 status=no_list"
  exit 1
}

mkdir -p "${RESULTS}"
: >"${OUT}"
: >"${PROGRESS}"

total=0
loaded=0
ok=0
fail=0
skip=0

# ── 2. 逐模块测试 ─────────────────────────────────────────────────────
while IFS='	' read -r idx name rel depends ko_srcver policy; do
  [ -n "${idx}" ] || continue
  ko="${PAYLOAD}/modules/${rel}"
  total=$((total + 1))

  # progress 先落盘并 sync：模块 hang 后 host 可定位到当前条目
  printf '%s\t%s\t%s\n' "${idx}" "${name}" "$(date +%s 2>/dev/null || echo 0)" >"${PROGRESS}"
  sync

  if [ ! -f "${ko}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${idx}" "${name}" "${rel}" "MISSING" "-" "file_not_found" "-" "${ko_srcver}" "${policy}" >>"${OUT}"
    sync
    fail=$((fail + 1))
    continue
  fi

  # 已加载：只记录，不 rmmod
  if grep -q "^${name} " /proc/modules 2>/dev/null || [ -d "/sys/module/${name}" ]; then
    sys_src="$(cat "/sys/module/${name}/srcversion" 2>/dev/null || echo '-')"
    if [ "${policy}" = "update" ]; then
      state="SKIP_UPDATE"
      skip=$((skip + 1))
    else
      state="LOADED"
      loaded=$((loaded + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${idx}" "${name}" "${rel}" "${state}" "-" "-" "${sys_src}" "${ko_srcver}" "${policy}" >>"${OUT}"
    sync
    continue
  fi

  # 未加载：insmod
  err="$(insmod "${ko}" 2>&1)"
  rc=$?
  err="$(printf '%s' "${err}" | tr '\n\t' '  ' | cut -c1-240)"
  sys_src="$(cat "/sys/module/${name}/srcversion" 2>/dev/null || echo '-')"

  if [ "${rc}" -eq 0 ]; then
    state="INSMOD_OK"
    ok=$((ok + 1))
  else
    state="INSMOD_FAIL"
    fail=$((fail + 1))
    err_tail="$(dmesg 2>/dev/null | tail -n 3 | tr '\n\t' '  ' | cut -c1-240)"
    [ -n "${err_tail}" ] && err="${err} | dmesg: ${err_tail}"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${idx}" "${name}" "${rel}" "${state}" "${rc}" "${err}" "${sys_src}" "${ko_srcver}" "${policy}" >>"${OUT}"
  sync
done <"${PAYLOAD}/module-list.tsv"

# ── 3. 收尾：快照与统计 ───────────────────────────────────────────────
lsmod >"${RESULTS}/lsmod-after.txt" 2>/dev/null || cat /proc/modules >"${RESULTS}/lsmod-after.txt"
cat /proc/modules >"${RESULTS}/proc-modules-after.txt" 2>/dev/null || true
dmesg >"${RESULTS}/dmesg-after.txt" 2>/dev/null || true

sync
umount "${MOUNT}" 2>/dev/null || true

log "完成: total=${total} loaded=${loaded} ok=${ok} fail=${fail} skip=${skip}"
echo "@@MODTEST_DONE@@ total=${total} loaded=${loaded} ok=${ok} fail=${fail} skip=${skip} status=done"
