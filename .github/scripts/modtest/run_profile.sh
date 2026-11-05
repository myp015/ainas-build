#!/usr/bin/env bash
#
# 启动已安装的 DSM 镜像并执行一组串口命令，采集该 profile 的启动日志。
#
# 用法：
#   run_profile.sh <workdir> <compose源> <profile> <命令文件> <日志目录> <驱动路径> [web_mode]
#
# 前置：<workdir>/rr 下已有安装好的 rr.img 与 data.qcow2。
#
# profile：base | virtio-scsi | megaraid | mptsas | nic
# web_mode：strict（默认，Web 900s 未就绪即失败）| soft（超时只告警，
#           仍执行串口命令）。nic profile 用 soft：多块额外网卡会改变
#           DSM 的网口编号，主网卡可能不再是安装时记录的 eth0，Web 可能
#           不可达，但串口测试本身不依赖 Web。
# 退出码：0 成功；1 启动/Web 未就绪；其他为串口驱动退出码。

set -uo pipefail

WORKDIR="${1:?缺少 workdir}"
COMPOSE_SRC="${2:?缺少 compose 源}"
PROFILE="${3:?缺少 profile}"
CMD_FILE="${4:?缺少命令文件}"
LOGDIR="${5:?缺少日志目录}"
DRIVER="${6:?缺少串口驱动路径}"
WEB_MODE="${7:-strict}"
case "${WEB_MODE}" in
  strict|soft) ;;
  *) echo "[E] 未知 web_mode: ${WEB_MODE}" >&2; exit 1 ;;
esac

# 必须在 cd 之前解析：调用方可能用相对路径（CI 传 .github/scripts/modtest/...）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER="dsm"
RRDIR="${WORKDIR}/rr"
COMPOSE_DST="${RRDIR}/docker-compose.test.yaml"
mkdir -p "${LOGDIR}/${PROFILE}"

cd "${RRDIR}"

# 每个 SCSI profile 一个独立小盘（不格式化，仅用于触发控制器/驱动 probe）
case "${PROFILE}" in
  virtio-scsi|megaraid|mptsas)
    [ -f "scsi-${PROFILE}.img" ] || truncate -s 2G "scsi-${PROFILE}.img" ;;
esac

echo "[profile:${PROFILE}] 渲染测试 compose"
bash "${SCRIPT_DIR}/../render_test_compose.sh" \
  "${COMPOSE_SRC}" "${COMPOSE_DST}" "${PROFILE}" || exit 1

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

# soft 模式只做 300s 快速试探（DSM 用户态约 30s 起、Web 约 120s 起），
# 超时不影响后续串口测试；strict 保持 900s 完整窗口。
if [ "${WEB_MODE}" = "soft" ]; then
  WEB_TRIES=60
else
  WEB_TRIES=180
fi
echo "[profile:${PROFILE}] 等待 DSM Web 就绪（最多 $((WEB_TRIES * 5))s，模式=${WEB_MODE}）"
ready=0
for _ in $(seq 1 "${WEB_TRIES}"); do
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
  if [ "${WEB_MODE}" = "soft" ]; then
    echo "[profile:${PROFILE}] [W] $((WEB_TRIES * 5))s 内 DSM Web 未就绪（soft 模式继续）" >&2
  else
    echo "[profile:${PROFILE}] [E] $((WEB_TRIES * 5))s 内 DSM Web 未就绪" >&2
  fi
  docker logs --tail 200 "${CONTAINER}" >"${LOGDIR}/${PROFILE}/docker-tail.log" 2>&1 || true
  # 现场：容器是否还在跑、QEMU 是否在消耗 CPU（区分卡死与空转）
  docker inspect "${CONTAINER}" --format \
    'status={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}}' \
    >"${LOGDIR}/${PROFILE}/docker-inspect.txt" 2>&1 || true
  docker exec "${CONTAINER}" sh -c \
    'ps -eo pid,etime,pcpu,args | grep -E "qemu-system|passt" | grep -v grep' \
    >"${LOGDIR}/${PROFILE}/qemu-ps.txt" 2>&1 || true
  # 网络现场（仅 nic profile 之类多网卡场景有意义）：qemux 的 NAT/tap 模式给
  # VM 固定 IP 172.30.0.2、网关是容器内的 bridge `docker`。DNSmasq/iptables
  # 是否把端口转发指向这个 IP，靠二层可达性和 DNAT 规则来判断。
  docker exec "${CONTAINER}" sh -c \
    'echo "--neigh--"; ip neigh show dev docker 2>/dev/null; echo "--ping--"; ping -c 1 -W 2 172.30.0.2 2>&1 | tail -n 3; echo "--dnat--"; iptables -t nat -L PREROUTING -n 2>/dev/null | head -n 12; echo "--forward--"; iptables -L FORWARD -n 2>/dev/null | head -n 6' \
    >"${LOGDIR}/${PROFILE}/net-probe.txt" 2>&1 || true
  if [ "${WEB_MODE}" != "soft" ]; then
    exit 1
  fi
  echo "[profile:${PROFILE}] [W] soft 模式：跳过 Web 等待，直接跑串口命令" >&2
else
  echo "[profile:${PROFILE}] DSM Web 已就绪"
fi

echo "[profile:${PROFILE}] 执行串口命令"
python3 -I "${DRIVER}" exec "${CONTAINER}" "${CMD_FILE}" 1800 \
  "${LOGDIR}/${PROFILE}" >"${LOGDIR}/${PROFILE}/driver.log" 2>&1
rc=$?
echo "[profile:${PROFILE}] 串口驱动退出码=${rc}"

exit "${rc}"
