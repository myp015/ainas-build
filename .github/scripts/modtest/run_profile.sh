#!/usr/bin/env bash
#
# 启动已安装的 DSM 镜像并执行一组串口命令，采集该 profile 的启动日志。
#
# 用法：
#   run_profile.sh <workdir> <compose源> <profile> <with_moddisk> <命令文件> <日志目录> <驱动路径>
#
# 前置：<workdir>/rr 下已有安装好的 rr.img 与 data.qcow2；
#       with_moddisk=true 时还需 rr/modtest.img。
#
# profile：base | virtio-scsi | megaraid | mptsas
# 退出码：0 成功；1 启动/Web 未就绪；其他为串口驱动退出码。

set -uo pipefail

WORKDIR="${1:?缺少 workdir}"
COMPOSE_SRC="${2:?缺少 compose 源}"
PROFILE="${3:?缺少 profile}"
WITH_MODDISK="${4:-false}"
CMD_FILE="${5:?缺少命令文件}"
LOGDIR="${6:?缺少日志目录}"
DRIVER="${7:?缺少串口驱动路径}"

# 必须在 cd 之前解析：调用方可能用相对路径（CI 传 .github/scripts/modtest/...）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER="dsm"
RRDIR="${WORKDIR}/rr"
COMPOSE_DST="${RRDIR}/docker-compose.test.yaml"
mkdir -p "${LOGDIR}/${PROFILE}"

cd "${RRDIR}"

# 每个 profile 一个独立小盘（不格式化，仅用于触发控制器/驱动 probe）
if [ "${PROFILE}" != "base" ]; then
  [ -f "scsi-${PROFILE}.img" ] || truncate -s 2G "scsi-${PROFILE}.img"
fi

echo "[profile:${PROFILE}] 渲染测试 compose"
bash "${SCRIPT_DIR}/../render_test_compose.sh" \
  "${COMPOSE_SRC}" "${COMPOSE_DST}" "${PROFILE}" "${WITH_MODDISK}" || exit 1

cleanup() {
  docker logs "${CONTAINER}" >"${LOGDIR}/${PROFILE}/docker.log" 2>&1 || true
  ( cd "${RRDIR}" && docker compose -f docker-compose.test.yaml down >/dev/null 2>&1 ) || true
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[profile:${PROFILE}] 启动容器"
( cd "${RRDIR}" && docker compose -f docker-compose.test.yaml down >/dev/null 2>&1 ) || true
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
( cd "${RRDIR}" && docker compose -f docker-compose.test.yaml up -d ) || exit 1

echo "[profile:${PROFILE}] 等待 DSM Web 就绪（最多 900s）"
ready=0
for _ in $(seq 1 180); do
  # 判据与 dsm_setup 一致：拿到 HTTP 状态行即用户态已起（500 也算），
  # 不能用 curl -f（未初始化/异常时 get_state.cgi 可能返回 500）
  code="$(curl -skS --max-time 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:5000/webman/get_state.cgi" 2>/dev/null || true)"
  if [ "${code:-000}" != "000" ]; then
    ready=1
    break
  fi
  sleep 5
done
if [ "${ready}" -ne 1 ]; then
  echo "[profile:${PROFILE}] [E] 900s 内 DSM Web 未就绪" >&2
  docker logs --tail 200 "${CONTAINER}" >"${LOGDIR}/${PROFILE}/docker-tail.log" 2>&1 || true
  exit 1
fi
echo "[profile:${PROFILE}] DSM Web 已就绪"

echo "[profile:${PROFILE}] 执行串口命令"
python3 -I "${DRIVER}" exec "${CONTAINER}" "${CMD_FILE}" 1800 \
  "${LOGDIR}/${PROFILE}" >"${LOGDIR}/${PROFILE}/driver.log" 2>&1
rc=$?
echo "[profile:${PROFILE}] 串口驱动退出码=${rc}"

# 回读模块盘上的测试结果（模块测试 profile 才有意义）
if [ "${WITH_MODDISK}" = "true" ] && [ -f "${RRDIR}/modtest.img" ]; then
  RESULT_DIR="${LOGDIR}/${PROFILE}/module-results"
  UNPACK="${LOGDIR}/${PROFILE}/.modtest-unpack"
  mkdir -p "${RESULT_DIR}" "${UNPACK}"
  if sudo mount -o ro,noload -t ext4 "${RRDIR}/modtest.img" "${UNPACK}" 2>/dev/null; then
    sudo cp -a "${UNPACK}/results/." "${RESULT_DIR}/" 2>/dev/null || true
    sudo umount "${UNPACK}" 2>/dev/null || true
  else
    echo "[profile:${PROFILE}] [WARN] ext4 回读失败，尝试 debugfs"
    debugfs -R 'cat /results/module-results.tsv' "${RRDIR}/modtest.img" \
      >"${LOGDIR}/${PROFILE}/module-results/module-results.tsv" 2>/dev/null || true
    debugfs -R 'cat /results/progress' "${RRDIR}/modtest.img" \
      >"${LOGDIR}/${PROFILE}/module-results/progress" 2>/dev/null || true
    debugfs -R 'cat /results/lsmod-after.txt' "${RRDIR}/modtest.img" \
      >"${LOGDIR}/${PROFILE}/module-results/lsmod-after.txt" 2>/dev/null || true
  fi
fi

exit "${rc}"
