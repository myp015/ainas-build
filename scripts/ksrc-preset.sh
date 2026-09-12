#!/bin/bash
# KSRC(header-only 树) 缺失头文件预置脚本
#
# 背景：syno-compiler 容器的 KSRC(/opt/<platform>/build) 是 header-only 源码树，
# 它裁剪了部分主线 5.10.55 头文件。src/5.x 外模块编译时 `#include <...>`
# 命中 KSRC 缺失的头导致 fatal error。典型缺失：
#   1. net/bridge/br_private.h      <- trace/events/bridge.h 的相对 include
#   2. block/blk-wbt.h              <- trace/events/wbt.h 的相对 include
#   3. include/drm/drm_buddy.h      <- drm_buddy.c 的 <drm/drm_buddy.h>
#   4. trace 相对 include 头        <- 驱动定义 TRACE_INCLUDE_PATH，
#      由 include/trace/define_trace.h 的 #include TRACE_INCLUDE(...) 宏展开。
#      src/5.x 的 trace 头把 TRACE_INCLUDE_PATH 指到驱动目录相对路径
#      （../../<驱动目录>），展开后落到各自的 KSRC/<驱动目录>/<file>.h。
#      预置脚本扫描 src/5.x 所有定义 TRACE_INCLUDE_PATH 的 .h，把缺失目标
#      从源码复制到 KSRC 对应位置，同名 trace.h（sound/hda、regmap 等）各归
#      各的路径，不再互相覆盖。
#   5. trace 头内部的相对 include  <- 如 mlx5 diag/fs_tracepoint.h 的
#      ../fs_core.h：预置副本在 KSRC 驱动路径，../ 相对 KSRC 解析，需要
#      fs_core.h 等依赖头也在 KSRC。第 3 部分递归补齐这类相对依赖。
#
# 用法：容器内执行，需挂载 src/5.x 到 /input
#   docker run -v <src/5.x>:/input <image> bash /ksrc-preset.sh
#   KSRC 可用环境变量覆盖（默认 epyc7002；compile.yml 多平台矩阵传
#   /opt/<platform>/build）
set -e
KSRC="${KSRC:-/opt/epyc7002/build}"
SRC=/input

# 1. 已知的固定缺失头
mkdir -p "$KSRC/net/bridge" "$KSRC/block" "$KSRC/include/drm" "$KSRC/include/linux"
[ -f "$SRC/net/bridge/br_private.h" ] && cp -f "$SRC/net/bridge/br_private.h" "$KSRC/net/bridge/"
[ -f "$SRC/block/blk-wbt.h" ] && cp -f "$SRC/block/blk-wbt.h" "$KSRC/block/"
[ -f "$SRC/include/drm/drm_buddy.h" ] && cp -f "$SRC/include/drm/drm_buddy.h" "$KSRC/include/drm/"
[ -f "$SRC/include/linux/thunderbolt.h" ] && cp -f "$SRC/include/linux/thunderbolt.h" "$KSRC/include/linux/"
[ -f "$SRC/include/linux/vgaarb.h" ] && cp -f "$SRC/include/linux/vgaarb.h" "$KSRC/include/linux/"
# DSM 7.3/7.4 内核把 phy_set_max_speed 返回类型改为 void（KSRC phy.h 声明为 void），
# 7.1/7.2 仍是主线 int。src/5.x phy-core.c 按 7.3/7.4 ABI 定义为 void，故统一把
# KSRC phy.h 声明 sed 成 void——7.1/7.2 int 行被改、7.3/7.4 已 void 无操作（幂等）。
# 内核 KSRC 未开 CONFIG_PHYLIB（不导出该符号），模块自行导出同名符号无冲突。
sed -i 's/^int phy_set_max_speed(/void phy_set_max_speed(/' "$KSRC/include/linux/phy.h"
echo "[preset] 固定头预置完成"

# 2. trace 相对 include 全量预置（循环多轮处理嵌套依赖）
#
# 解析规则：
#   - 只认真正的 `#define` 行（`^#define` 锚定，排除注释里的字样，如
#     i40e_trace.h 第 25 行注释也含 "define TRACE_INCLUDE_FILE"）
#   - `tail -1` 取最后一个 define（驱动常先 #undef 再重定义，如 netvsc）
#   - 绝对路径（/tmp/input/...）跳过：do.sh 把源码 cp 到 /tmp/input，
#     编译时 `#include "/tmp/input/..."` 直接命中源码，无需预置
cd "$SRC"
for iter in $(seq 1 10); do
  FIXED=0
  while IFS= read -r h; do
    path=$(grep -E "^#define TRACE_INCLUDE_PATH" "$h" 2>/dev/null | tail -1 | sed 's/^#define TRACE_INCLUDE_PATH//' | tr -d ' \t')
    file=$(grep -E "^#define TRACE_INCLUDE_FILE" "$h" 2>/dev/null | tail -1 | sed 's/^#define TRACE_INCLUDE_FILE//' | tr -d ' \t')
    [ -n "$file" ] || continue
    [ -n "$path" ] || continue
    # 绝对路径（/tmp/input/...）：do.sh 编译时源码在 /tmp/input，直接命中，跳过
    case "$path" in
      /*) continue ;;
    esac
    target=$(realpath -m "$KSRC/include/trace/$path/$file.h" 2>/dev/null || true)
    src="$(dirname "$h")/$file.h"
    if [ -n "$target" ] && [ ! -f "$target" ] && [ -f "$src" ]; then
      mkdir -p "$(dirname "$target")"
      cp -f "$src" "$target"
      echo "[preset] $target"
      FIXED=$((FIXED+1))
    fi
  done < <(grep -rln "define TRACE_INCLUDE_PATH" . --include="*.h" 2>/dev/null || true)
  [ "$FIXED" -eq 0 ] && break
  echo "[preset] 第 ${iter} 轮预置 $FIXED 个 trace 头"
done

# 3. 递归补齐 trace 头内部的相对 include 依赖
#    预置副本在 KSRC 驱动路径，`#include "../xxx.h"` / `./xxx.h` 相对该路径
#    解析，需要依赖头也在 KSRC。从 trace 头出发，把缺失的相对依赖从 src
#    复制到 KSRC，新复制的继续扫描，直到无新依赖。
QUEUE=$(mktemp)
grep -rln "define TRACE_INCLUDE_PATH" . --include="*.h" 2>/dev/null | sed 's|^\./||' > "$QUEUE"
SRC_ROOT="$PWD"
for iter in $(seq 1 30); do
  FIXED=0
  NEWQ=$(mktemp)
  while IFS= read -r h; do
    [ -f "$h" ] || continue
    while IFS= read -r inc; do
      inc_file=$(echo "$inc" | sed 's/#include "\(.*\)"/\1/')
      # 跳过绝对路径（如 "/tmp/input/..."）
      case "$inc_file" in
        /*) continue ;;
      esac
      src_target=$(realpath -m "$(dirname "$h")/$inc_file" 2>/dev/null || true)
      [ -n "$src_target" ] || continue
      # 必须在 src 树内
      case "$src_target" in
        "$SRC_ROOT"/*) ;;
        *) continue ;;
      esac
      [ -f "$src_target" ] || continue
      ktarget="$KSRC/${src_target#$SRC_ROOT/}"
      if [ ! -f "$ktarget" ]; then
        mkdir -p "$(dirname "$ktarget")"
        cp -f "$src_target" "$ktarget"
        echo "[dep] $ktarget"
        FIXED=$((FIXED+1))
        echo "${src_target#$SRC_ROOT/}" >> "$NEWQ"
      fi
    done < <(grep -oE '#include "[^"]+"' "$h" 2>/dev/null || true)
  done < "$QUEUE"
  rm -f "$QUEUE"
  [ "$FIXED" -eq 0 ] && { rm -f "$NEWQ"; break; }
  echo "[preset] 第 ${iter} 轮补齐 $FIXED 个相对依赖头"
  QUEUE="$NEWQ"
done
rm -f "$QUEUE"
echo "[preset] KSRC 头预置全部完成"
