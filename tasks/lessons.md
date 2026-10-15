# 教训记录

## 2026-10-14 — 合并函数库后，被 `set -u` source 时顶层 `$1` 会炸

**症状**：把 `ainas-build/scripts/func.sh` 合并进 `ainas-2in1/script/2in1func.sh`
后，2in1 / rr / ova 三个工作流的「编译镜像」步骤在**加载函数库的一瞬间**就失败：

```
.2in1/script/2in1func.sh: line 17: 1: unbound variable
##[error]Process completed with exit code 1.
```

**根因**：合并时带进来的顶层语句 `[ -n "${1}" ] && export TOKEN="${1}"`。
它原本在 func.sh 里总是**带 token 调用**，合并后三个工作流改成 `. 2in1func.sh`
**无参 source**，而工作流普遍开着 `set -euo pipefail` —— `${1}` 在无位置参数时
直接触发 unbound variable，函数一个都没定义就中止了。

**修复**：改成 `${1:-}` 判定 + `if` 包裹：

```bash
if [ -n "${1:-}" ]; then
  export TOKEN="${1:-}"
fi
```

用 `if` 而非 `[ ... ] && ...`，避免列表返回 1 影响被 source 文件的返回状态。

**模式（要记住的规则）**：
- 函数库被 source 时，**顶层（函数体之外）不允许出现任何依赖调用方上下文的语句**。
  位置参数一律写 `${1:-}` / `${2:-}`，变量一律写 `${X:-}`。
- 把函数库从「总是带参调用」改成「无参调用」时，必须专门审计顶层语句——
  只看函数体是查不出来的，因为函数体在 source 时根本不执行。
- 定位手法：`awk` 抽出顶层可执行行（跳过 `^function ` 到 `^}` 之间的内容），
  再本地 `bash -euo pipefail -c '. 函数库'` 复现，比等 CI 快得多。

**附带确认**：合并进来的 `get*` 函数依赖 `TOKEN`。当前只有 2in1.yml 的
`sudo env AINAS_TOKEN=... bash -c '. ...sh "$AINAS_TOKEN"'` 之后才调用它们，
rr.yml / ova.yml 无参 source 但不调用 `get*`，故无回归。

---

## 2026-10-14 — 容器内 source 函数库不能用相对路径（`-w` 会被 entrypoint 覆盖）

**症状**：修完上面那条后，rr / ova 的 DS918+ job 仍失败：

```
/opt/rr/build.sh: 行 3: ./2in1func.sh: No such file or directory
```

**根因**：`docker_rr_build` 生成的 build.sh 里写的是 `. ./2in1func.sh`，
依赖 `docker run -w "${WORKDIR}"` 把 CWD 设成宿主工作目录。但 `wjz304/rr`
镜像的 **entrypoint 会把 CWD 切回 `/opt/rr`**（日志里 `. menu.sh` 成功、
`. ./2in1func.sh` 失败即为证据 —— menu.sh 在镜像里，不在挂载的工作目录里）。

重构前的 build.sh **根本不 source 函数库**（addons 写入是内联的），所以这个
坑是本次重构新引入的；`-w` 能不能生效从来没被验证过。

**修复**：source 一律走**容器内的绝对路径**，与挂载点对齐：

- `docker_rr_build`：新增 `-v "${WORKDIR}/2in1func.sh:/opt/rr/2in1func.sh"`，
  build.sh 改 `. /opt/rr/2in1func.sh`
- `docker_2in1_build`：build.sh 改 `. /opt/ainas/2in1func.sh`
  （该文件本来就已挂到 /opt/ainas/，只是原来按相对路径取）

**模式（要记住的规则）**：
- 往容器里塞脚本让 build.sh source 时，**不要依赖 `docker run -w`**。
  镜像 ENTRYPOINT 可能在执行 CMD 前 `cd` 到自己的目录。一律显式挂载到固定
  绝对路径再 source。
- 判断容器内 CWD 的快速手法：看日志里哪条相对路径命令成功了。镜像自带的
  文件（menu.sh）能取到、你挂进去的文件取不到 → CWD 在镜像目录。

**另一个教训**：`2in1.yml` 的函数重构（commit ec37d866）此前**从未在 CI 跑过**
（`gh run list --workflow=2in1.yml` 只有失败记录，号称的"成功基线"
38519727178 已 404）。重构后必须立刻用最小型号矩阵实跑一遍，别信"改动已完成"。

---

## 2026-10-15 — 用脚本改 bash 函数时，heredoc 里的列 0 `}` 会骗过边界检测

**症状**：写 Python 脚本按「从 `function X() {` 找到下一个列 0 的 `}`」来定位函数体，
处理 `docker_2in1_build` / `docker_rr_build` 时断言失败：`docker_rr_build 未包含 docker pull`。
函数体**没有**被截断写坏 —— 是脚本根本没找对函数末尾。

**根因**：这两个函数用 `cat >build.sh <<'EOF2'` 生成 build.sh，而 heredoc 内容里
`fetch_and_make() { ... }` 的收尾 `}` 就在**列 0**。朴素的「第一个列 0 的 `}`」命中它，
于是函数体只取到 heredoc 中段，后面真正的宿主侧代码全被判成"函数外"。

**修复**：边界扫描必须感知 heredoc —— 命中 `<<'WORD'` 后进入「跳过」状态，
直到再次遇到列 0 的 `WORD` 才恢复：

```python
HEREDOC_RE = re.compile(r"<<-?'?([A-Za-z_][A-Za-z0-9_]*)'?")
```

`<<<`（herestring，如 `read -ra ARR <<<"${ADDONS}"`）**不会**误匹配：`<<` 之后既不是
`-`/`'` 也不是标识符字符。

**顺带的手法（强烈建议）**：改这类生成脚本的函数时，不要只做静态检查。把**改动前**
的函数库备份出来，用同一个桩环境（`sudo() { :; }` / `docker() { echo ...; }`）分别调用
新旧函数生成产物，再 `diff` 两份产物 —— 这次就是靠它确认了：
- rr 的 build.sh **逐字一致**
- 2in1 的 build.sh 只差「预期内的两处行为变更 + 三行注释」

比人眼读 diff 可靠得多。注意：函数库用 `BASH_SOURCE/..` 推导仓库根，备份文件要**放进
原仓库目录**再 source，否则 `cp "${AINAS2IN1_DIR}/..."` 会因路径不存在提前退出，
产生"看起来跑通了其实没跑到 docker 那步"的假象。

---

## 2026-10-15 — 删掉一个位置参数后，`shift N` 是最容易漏改的那处

**症状**：2in1 单型号 CI 全流程跑到 DSM 安装阶段才炸，前面所有重构过的函数都正常：

```
qemu-system-x86_64: -drive file=/rr.img,media=disk,format=raw,if=none,id=rrdisk:
  'file' driver requires '/rr.img' to be a regular file
[INFO] attempt=0 等待 180s 后 5000 端口仍未就绪（loader 可能未引导进 DSM）
[E] 重试 1 次后 DSM 5000 端口仍未就绪（loader 引导失败），退出
```

**根因**：`dsm_setup` 原本 12 个位置参数，`local BOOT_READY_TIMEOUT_DEFAULT="${11}"`
后面跟 `shift 11`，剩下的变参尾是 compose 的 sed 表达式。本次把 `AINAS2IN1_DIR`
内置掉之后参数变成 11 个，`${11}` 改成了 `${10}`，**`shift 11` 没改**。

于是 `shift 11` 把第 11 个参数（唯一的 sed 表达式）也 shift 掉了，
`COMPOSE_SEDS` 恒为空数组 —— sed 静默地一次都没执行。compose 里的
`./rr.img:/rr.img` 保持相对路径，解析到 `$DSM_INSTALL_DIR` 下并不存在，
**Docker 对不存在的 bind 源会建一个同名目录**，qemu 拿到的 `/rr.img` 是目录。

**修复**：`shift 11` → `shift 10`。

**模式（要记住的规则）**：
- **`shift N` 不是普通数字，它和最后一个 `${N}` 是同一个契约的两半**，必须一起改。
  本次所有静态检查都漏了它，因为 `local X="${N}"` 的数量对不上时，变参尾为空数组
  在 bash 里**不报错**，只是少做一件事。
- 静态检查要固化成不变式：**`shift N` 必须恰好等于该函数最后一个固定参数的序号**。
  已加进 `/www/tmp/check_arity.py`，并做了反例自检（改回 11 立刻报错）。
- 「删位置参数」的改动清单：函数内所有 `${N}` **加上** `shift N` **加上**调用点实参
  个数，三处一起核对。
- 症状与根因距离很远：报错在 qemu，根因在函数签名的第 2 行。凡是「参数形状变了」的
  重构，失败点可能落在整条流水线最末端，不要只看报错所在的那一步。

**顺带确认**：`docker build` 那一段（`docker_build`）虽然也改了签名，但它是靠
`$1`/`$2` 顺序读参数、没有 `shift`，所以没中招；`ova.yml` 的 `dsm_setup`
调用点同样受影响，一并随本次修复恢复。

---

## 2026-10-15 — 批量改名：sed 必须长名先于短名，去前缀前要验证裸名未被容器脚本占用

**背景**：三个工作流 + 函数库里的 DSM 版本号变量统一去掉 `DSM_` 前缀
（`DSM_VERSION`→`VERSION`、`DSM_LINE_REQ`→`LINE_REQ` 等）。

**坑 1 —— sed 规则的顺序**：`DSM_VERSION` 是 `DSM_VERSION_MAIN` / `DSM_VERSION_74`
的**前缀**。若先跑 `s/\bDSM_VERSION\b/VERSION/g`，`DSM_VERSION_MAIN` 会先被打成
`VERSION_MAIN`，针对 `DSM_VERSION_MAIN` 的规则**再也匹配不上**。危险在于结果看起来
"已经改过了"，很容易漏过。

**规则**：多规则批量改名一律**按名字长度降序**排列 sed 的 `-e`。

```bash
sed -i \
  -e 's/\bDSM_VERSION_MAIN\b/VER_MAIN/g'    \  # 长名先
  -e 's/\bDSM_VERSION_BUILD\b/VER_BUILD/g'  \
  -e 's/\bDSM_VERSION_74\b/VERSION_74/g'    \
  -e 's/\bDSM_VERSION\b/VERSION/g'          \  # 短名后
  ...
```

改完后必须**双保险**：`grep -o '\bDSM_[A-Za-z0-9_]*'` 看残留 + `diff -u` 逐行审查，
确认每一行都是预期改名（本次 5 个文件、约 60 行 diff 全部人工过了一遍）。

**坑 2 —— 裸名可能已被容器脚本占用**：`DSM_VERSION` 改名后，`VERSION` 会随
build.sh 注入容器执行。必须先确认镜像脚本（menu.sh 及其 include）没用这个名字：

```bash
command grep -rEo "(^|[^A-Za-z_0-9])VERSION([^A-Za-z_0-9]|$)" <镜像脚本目录> | wc -l  # 101
command grep -rnE "(^|[^A-Za-z_])VERSION[[:space:]]*=" <镜像脚本目录> | wc -l         # 0
```

**出现 101 次、赋值 0 次** → 全是 `${DSM_ROOT}/VERSION` 这类**文件路径**与日志字面量，
不是 shell 变量。只看"出现次数"会把它误判成高危冲突。

**坑 3 —— 同一个名字有两条独立通路**：`LINE_REQ` 既走 shell 也走 python 环境变量：

1. 工作流 `export LINE_REQ` → `dsm_setup` 形参 `local LINE_REQ="${2}"`
   （`local` **遮蔽**了环境变量且不重新 export）
2. python 内联 `os.environ.get('LINE_REQ', '7.3.2')` 读到的是**环境里那一份**

两条通路的值恰好一直相同，所以遮蔽问题从未暴露。改名时漏掉任何一条，
python 会**静默回退默认值 7.3.2** —— 不报错，只是版本选错。

**规则**：改一个变量的名字前，先 `grep -rn` 全仓库找出它的**所有**消费形态，
尤其是「字符串形式出现在别的语言里」（`os.environ.get('X')`、`jq -r '.X'`、sed 表达式）。

**最强验证依旧可用**：桩环境（`sudo() { :; }` / `docker() { echo; }`）分别用改名前后的
函数库生成 build.sh 再 diff。本次结果只有一行差异：

```
-DSM_VERSION="7.4.1-90080-0"
+VERSION="7.4.1-90080-0"
```
