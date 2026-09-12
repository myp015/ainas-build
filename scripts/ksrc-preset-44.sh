#!/bin/bash
# KSRC(header-only 树) 缺失头预置脚本（4.4 平台专用）
#
# 背景：syno-compiler 容器的 KSRC(/opt/<platform>/build) 是 header-only 裁剪树，
# 与 5.x 同源问题：裁剪时删了部分基础头/宏。4.4 典型缺失：
#   include/linux/init.h：精简版缺 postcore_initcall/console_initcall/device_initcall
#     等宏（只留 module_init 等最常用）。regmap.c/hvc_console.c 编译报
#     "type defaults to 'int' in declaration of 'xxx_initcall'"。
#     用 GPL44（DSM 4.4 官方 GPL 源码，/tmp/syno-extract/4.4/linux-4.4.x）的完整
#     init.h 覆盖，同源安全（模块场景 initcall section 不执行，保持原运行行为）。
#
# 用法：容器内执行，需挂载 src/4.x 到 /input
#   docker run -v <src/4.x>:/input <image> bash /ksrc-preset-44.sh
#   KSRC 可用环境变量覆盖（compile.yml 多平台矩阵传 /opt/<platform>/build）
set -e
KSRC="${KSRC:-/opt/apollolake/build}"
SRC=/input

# 1. init.h：GPL44 完整版覆盖 KSRC 精简版（src/4.x/include/linux/init.h 即 GPL44 副本，
#    仅作为 KSRC 预置源，不参与编译——外部模块编译不用 src/include）
#    ⚠ 局限性：实测覆盖 KSRC 已存在的头对编译不生效（do.sh 编译环境可能重置已存在头），
#    仅对【新增头文件】类缺口有效。init.h 保留预置仅作保险，可靠方案是源码内 #ifndef 兜底。
if [ -f "$SRC/include/linux/init.h" ]; then
  mkdir -p "$KSRC/include/linux"
  cp -f "$SRC/include/linux/init.h" "$KSRC/include/linux/init.h"
  echo "[preset-44] include/linux/init.h -> KSRC"
fi

# 2. syno_quirks.h：DSM 私有头（GPL44 有，KSRC 无此文件=新增缺口，预置有效）。
#    GPL44 usb/host/ehci-hcd.c/ehci-q.c 引用 <linux/usb/syno_quirks.h>（UPS 断连过滤等
#    DSM 定制宏），KSRC 裁剪树缺失 → ehci-hcd.c fatal。KSRC 无同名文件，cp 新增可生效。
if [ -f "$SRC/include/linux/usb/syno_quirks.h" ]; then
  mkdir -p "$KSRC/include/linux/usb"
  cp -f "$SRC/include/linux/usb/syno_quirks.h" "$KSRC/include/linux/usb/syno_quirks.h"
  echo "[preset-44] include/linux/usb/syno_quirks.h -> KSRC"
fi

# 3. drm 头族：GPL44（DSM 4.4 官方 GPL）drivers/gpu/drm 编译所需头。
#    KSRC 裁剪树无 include/drm/ + include/uapi/drm/（src/4.x 侧此前亦空，
#    批 5C 换 GPL44 纯 4.4 drm 源码后必须配齐同源头）。KSRC 无同名文件=新增，预置有效。
if [ -d "$SRC/include/drm" ]; then
  mkdir -p "$KSRC/include/drm"
  cp -rf "$SRC/include/drm/." "$KSRC/include/drm/"
  echo "[preset-44] include/drm/ -> KSRC ($(find "$SRC/include/drm" -type f | wc -l) files)"
fi
if [ -d "$SRC/include/uapi/drm" ]; then
  mkdir -p "$KSRC/include/uapi/drm"
  cp -rf "$SRC/include/uapi/drm/." "$KSRC/include/uapi/drm/"
  echo "[preset-44] include/uapi/drm/ -> KSRC ($(find "$SRC/include/uapi/drm" -type f | wc -l) files)"
fi

# 4. drm_trace.h：drm_trace_points.o 经 TRACE_INCLUDE_PATH(../../drivers/gpu/drm) 相对路径
#    从 KSRC 树解析 drm_trace.h（KSRC 是 header-only 树，无 drivers/gpu/drm/ 目录）。
#    需预置到 KSRC 对应位置（src/4.x/drivers/gpu/drm/drm_trace.h 即 GPL44 同源）。
#    KSRC 无此文件=新增，预置有效。
if [ -f "$SRC/drivers/gpu/drm/drm_trace.h" ]; then
  mkdir -p "$KSRC/drivers/gpu/drm"
  cp -f "$SRC/drivers/gpu/drm/drm_trace.h" "$KSRC/drivers/gpu/drm/drm_trace.h"
  echo "[preset-44] drivers/gpu/drm/drm_trace.h -> KSRC"
fi

# 5. siphash.h：src/4.x 的 nf_conntrack_core.c/sch_sfq.c 等为 4.4.302 版（4.4 稳定分支
#    backport 后引入 siphash API），KSRC 4.4.180 裁剪树缺失 include/linux/siphash.h →
#    nf_conntrack_core.c fatal。src/4.x/include/linux/siphash.h 即 Synology KSRC 同源
#    副本（仅依赖 types.h/kernel.h，自包含）。KSRC 无此文件=新增，预置有效。
if [ -f "$SRC/include/linux/siphash.h" ]; then
  mkdir -p "$KSRC/include/linux"
  cp -f "$SRC/include/linux/siphash.h" "$KSRC/include/linux/siphash.h"
  echo "[preset-44] include/linux/siphash.h -> KSRC"
fi

# 6. KSRC 版本标志头：src/4.x 同时服务 4.4.180（7.0/7.1）与 4.4.302（7.2-7.4）两套 KSRC。
#    少数 API 在 4.4 稳定分支有 backport 差异（pptp_msg_name 数组→函数、red_check_params
#    3→5 参数、ipv6_stub 成员 ipv6_dst_lookup→ipv6_dst_lookup_flow），源码需按 KSRC 版本
#    条件编译。判断依据：4.4.302 的 nf_conntrack_pptp.h 把 pptp_msg_name 声明成函数。
#    生成 arc-ksrc-ver.h（新增头），sch_sfq.c/addr.c include 它做 #if 分支。
if [ -f "$KSRC/include/linux/netfilter/nf_conntrack_pptp.h" ]; then
  mkdir -p "$KSRC/include/linux"
  if grep -q 'pptp_msg_name(u_int16_t' "$KSRC/include/linux/netfilter/nf_conntrack_pptp.h"; then
    cat > "$KSRC/include/linux/arc-ksrc-ver.h" <<'EOF'
#define ARC_KSRC_44_302 1
/* 4.4.302 的 pptp_msg_name 由数组声明改成函数：调用处用 ARC_PPTP_NAME 统一。 */
#define ARC_PPTP_NAME(msg) pptp_msg_name(msg)
EOF
    echo "[preset-44] arc-ksrc-ver.h: KSRC=4.4.302"
  else
    cat > "$KSRC/include/linux/arc-ksrc-ver.h" <<'EOF'
#define ARC_KSRC_44_180 1
/* 4.4.180 的 pptp_msg_name 仍是数组：调用处用 ARC_PPTP_NAME 统一。 */
#define ARC_PPTP_NAME(msg) pptp_msg_name[msg]
EOF
    echo "[preset-44] arc-ksrc-ver.h: KSRC=4.4.180"
  fi
fi

# 7. qed RDMA 头族（4.4 qedr 自编译专用）：src/4.x 用 qedr 4.10 源码（合入主线
#    第一版，用旧式 ib_ah_attr/ib_umem.page_size，rdma_ah_attr 等 4.11+ 框架依赖
#    归零——这是 qedr 4.4 自编译可行性的根因；4.14 版 19 处 rdma_ah 已验证不可行）
#    + qed RDMA 4.10（qed_roce.c 提供 qed_get_rdma_ops，编入 qed.ko，qedr.ko 由
#    qedr 目录 3 文件合成）。KSRC 4.4 裁剪树无 include/linux/qed/ 下任何 qed RDMA
#    头（qed_roce_if.h/qede_roce.h/rdma_common.h/roce_common.h/qed_ll2_if.h 全缺，
#    qed_if.h/qed_chain.h/common_hsi.h 为 4.4 基础版）→ 全部 8 个 4.10 头预置，
#    KSRC 无同名文件=新增，预置有效。源=src/4.x/include/linux/qed/（4.10 同源副本）。
if [ -d "$SRC/include/linux/qed" ]; then
  # 强制覆盖：KSRC 已有 4.4 基础版 qed 头（qed_if.h/qed_chain.h/common_hsi.h 等），
  # cp 覆盖已存在头对编译不生效（do.sh 编译环境重置已存在头）→ 先删整个目录再复制，
  # 使 v4.10 头成为"新增"。qed/qede 源码已统一 v4.10，KSRC 头必须同为 v4.10，
  # 否则 eth_common.h/common_hsi.h 结构重定义、qed_eth_ops 缺 dcb 等混用错误。
  rm -rf "$KSRC/include/linux/qed"
  mkdir -p "$KSRC/include/linux/qed"
  cp -rf "$SRC/include/linux/qed/." "$KSRC/include/linux/qed/"
  echo "[preset-44] include/linux/qed/ -> KSRC ($(find "$SRC/include/linux/qed" -type f | wc -l) files, 强制覆盖)"
fi

# 8. qedr ABI 头（4.4 qedr 自编译）：qedr 4.14 源码 include <rdma/qedr-abi.h>，
#    KSRC 4.4 无此 UAPI 头（qedr 4.4 本不编译）。v4.14 实际位于 include/uapi/rdma/
#    （外部模块编译 include/uapi/ 在搜索路径内）。KSRC 无同名文件=新增，预置有效。
if [ -d "$SRC/include/uapi/rdma" ]; then
  mkdir -p "$KSRC/include/uapi/rdma"
  cp -rf "$SRC/include/uapi/rdma/." "$KSRC/include/uapi/rdma/"
  echo "[preset-44] include/uapi/rdma/ -> KSRC ($(find "$SRC/include/uapi/rdma" -type f | wc -l) files)"
fi

echo "[preset-44] 完成"
