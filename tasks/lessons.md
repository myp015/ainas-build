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

---

## 2026-10-15 — 批量删 `|| true` 前必须先分类，三类删了当场炸

**背景**：按要求清掉两个仓库全部 143 处 `|| true`（含写进 initrd 的运行时脚本
字符串字面量），让任何报错都直接让 job 红。清完第一次跑，4 个 run
（`38692398694` ainas-rr / `38692402516` 2in1 / `38692406503` rr / `38692409896` ova）
**全部 failure**。

**根因**：有几类 `|| true` 保护的不是构建错误，而是「预期非零」的正常路径。
一次删干净，等于把这些正常路径也判成了失败。

**判据**：这条命令失败，是否意味着产物（img/ova）不完整？
- 是 → 保持严格（mount、解包、复制产物、压缩）
- 否 → 保留容错，但**改写成显式形式**，不要再写裸 `|| true`

**实测删了必炸的 9 类**：

| # | 形态 | 为什么必炸 | 改成 |
|---|---|---|---|
| 1 | `timeout N docker logs -f dsm` | timeout 到点必返回 **124**（2in1/ova 的 failure 根因） | `\|\| [ $? -eq 124 ]` |
| 2 | `cp -f <可选文件> <dst> 2>/dev/null` | 源可能不存在（rr 的 `rr-original` 失败点：p1 无 user-config.yml / .locale） | `if [ -f src ]; then cp; fi` |
| 3 | **上游本来就带 `\|\| true` 的** | 如 `getExtractor` 的 `(cd ... && xz -dc <"rd.gz" \| cpio -idm)`，cpio 对归档内特殊文件返回非零（ainas-rr exit 2 根因） | 恢复 `\|\| true`，删前先对照上游 |
| 4 | `docker logs --tail N dsm`（诊断 dump） | 容器可能已退出，失败会**覆盖后面的 `exit 7` / `exit 1`** | `\|\| echo "[WARN] ..." >&2` |
| 5 | 失败分支里的 `df -h` / `free -h` | 同理覆盖 `return 1` | `\|\| echo "[WARN] ..." >&2` |
| 6 | `X="$(ls -1 <glob> 2>/dev/null \| head -n1)"` | `set -o pipefail` 下 glob 无匹配时 `ls` 返回 2 → 赋值中断 | `find . -maxdepth 1 -name 'X' -print -quit`（无匹配返回 0） |
| 7 | `depends=($(modinfo -F depends ... \| sed ...))` | modinfo 探测失败即中断 | `\| \|\| :` |
| 8 | `cp -rf ${SRC}/intel/iwlwifi/* ${SRC}/` | glob 无匹配即中断 | `[ -d "${SRC}/intel/iwlwifi" ] && cp ...` |
| 9 | `mv -f .../EXTERNALLY-MANAGED` | PEP 668 标记实际在 `/usr/lib/python3.x/`，`/usr/bin/` 下没有，mv 必然失败 | `[ -f ... ] && mv ...` |

**两个反直觉点**：

- `[ -f x ] && cmd` 删 `|| true` 是**安全**的：`&&` 列表里非末位的命令豁免 errexit。
  不能凭「有 `&&` 就该保留」一刀切，要看它在不在列表末位。
- `(( c )) && cmd` 作为**函数体最后一条**必须改写成 `if`，否则条件为假时函数返回 1，
  调用点在 `set -e` 下被判失败（`dsm_auto_install.sh` 的 `end_bar` 就是这种）。

**模式（要记住的规则）**：
- 批量删容错前先**分桶**：诊断输出 / 可选文件 / 上游既有容错 / 探测 / 产物操作。
  只有「产物操作」那一桶能直接删。
- 对照上游是最快的判据：`gh api repos/<repo>/contents/scripts/func.sh --jq '.content' | base64 -d`
  拉 `RROrg/rr` 同函数比一比，上游写着 `|| true` 的就别动。
- 删完立刻用最小矩阵实跑，不要只做静态检查 —— 本次 `bash -n` / YAML 校验 / 单测
  全绿，照样 4 个 run 全红。

**验证结果**：修完重跑（`5c9ab6c3`），4 个 run 全 success，关键标记齐全：
- ainas-rr：`getExtractor ... begin/end`、`repackInitrd: 模式 overlay`、`resizeImg: 扩容策略 parted`、`TAG=...; Status=200`
- 2in1 / ova：`5000 端口已就绪 (attempt=0)`、`repackInitrd: 模式 direct`、`安装完成`
- 产物量级同基线（2in1 img.gz ≈2.47 G、ova.gz ≈2.32 G、rr-26.9.0.img.zip 1538 MB）

---

## 2026-10-15 — 「抽取公共代码块」会把 `&&` 列表**变成**函数末条，返回码就此泄漏

**症状**：把 5 个 `get*` 里那段 14 行的 release 下载块抽成 `fetchReleaseAsset()` 后，
2in1 的 `build (DS918+)` 在**下载成功之后**当场失败：

```
TAG=26.10.12; Status=200
##[error]Process completed with exit code 1.
```

`Status=200` 说明资产取到了，函数却返回了 1。rr.yml 同一提交**全绿** —— 失败与否
取决于 release 里资产的**排列顺序**。

**根因**：块内最后一条是 `[ "${STATUS:-0}" -ne 200 ] && exit 1`。条件为假时
`&&` 列表整体返回 1，于是：

- 循环体末条 = 该 `&&` 列表 → `while` 的退出状态 = 1
- `while` 又正好是抽取后 `fetchReleaseAsset()` 的**最后一条** → 函数返回 1
- 调用方开着 `set -e` → 直接退出

抽取前这段后面还跟着 `unzip` 等语句，函数返回码取自它们，所以一直没暴露。
**同一个 `&&`，在原位置无害，被抽出来就成了函数末条。**

**为什么 rr.yml 没炸**：资产列表里若有**不匹配的条目**排在匹配项之后，
那条 `|| continue` 会把状态刷成 0，函数侥幸返回 0。rr 与 2in1 拿到的资产数不同，
于是只有一边翻车 —— 这类"看数据排列决定生死"的缺陷，本地静态检查是查不出来的。

**修复**：`[ ... ] && exit 1` → `if [ ... ]; then exit 1; fi`（`if` 条件为假时返回 0）。

**模式（要记住的规则）**：
- 上一节记的「`&&` 作为函数体最后一条要改成 `if`」不够用 —— 真正的判据是
  **这个 `&&` 所在的外层构造（函数体 / 循环体 / `if` 体）是不是函数或脚本的最后一条**。
  抽取代码时外层构造会变，必须**重新判一遍**，不能只看改动行本身。
- 抽取后的自查：扫「函数体末条」**和**「循环体末条」，两者都要看。
  现成脚本见本次会话的 Python 片段（按 `^function ` 到列 0 `}` 划函数体，
  再在体内找 `while|for` 到 `done`）。
- **本地单测通过 ≠ 没这个 bug**：这次桩测试全绿是因为桩恰好返回了「匹配项 + 不匹配项」
  两个资产，形状掩盖了缺陷。写回归断言时必须复刻**触发缺陷的那种数据形状**
  （这里是"资产列表只有一个匹配项"），否则测试是自我安慰。
  验证手法：把缺陷版本还原到临时副本，跑同一套测试，**必须看到它 FAIL**，
  否则断言等于没写。

---

## 2026-10-16 — 跑 lkms.yml 验证必须显式钉 `lkm_ref`，默认 `main` 是陈旧分支

**症状**：C4 改完后触发 `Build lkms`（`38728686915` @ `9bf1d756`），
`setup` job 成功、63 个 build job 名字全对，但唯一跑完的
`build (7.1, broadwellnk)` 编译失败，其余 62 个被 fail-fast 取消：

```
[INFO] makelkms: platform=broadwellnk kver=4.4.180 ver=7.1
include/linux/wait.h:188:39: error: 'TASK_NORMAL' undeclared
include/linux/wait.h:260:37: error: 'TASK_UNINTERRUPTIBLE' undeclared
.../source/internal/intercept_driver_register.c:191:9: note: in expansion of macro 'wake_up_all'
```

复跑一次，换了个平台照样挂：`build (7.2, broadwell)`，`kver=4.4.302`，
同一个源文件、同一类错误 → **所有 4.x 平台全挂**。

**排查过程（走了弯路，值得记住）**：先怀疑 runner 镜像升级
（`20261004.327` → `20261012.334`）、再怀疑 KSRC/toolchain 被上游重发
（两个 txz 体积都逐字节相同：106M / 490M）、又怀疑矩阵被 C4 改坏了
（矩阵与 HEAD 内联块逐项等值，且 63 个 job 名字全对）。全都不是。

**真正的一行证据**：对比成功/失败 job 日志里的 `Checking out the ref`：

| run | ainas-lkm 实际 checkout |
|---|---|
| `38405442331` 10-13 成功 | `fix/partition-guard-20261011` |
| `38728686915` 10-15 失败 | `main` |

10-13 的成功是**显式传了** `-f lkm_ref=fix/partition-guard-20261011`；
我这次没传，落到了 `default: main`。

**根因**：`myp015/ainas-lkm` 的 `main` 停在 `5fd69cc8`（2026-10-11 那次
PR 合并点），而 `fix/partition-guard-20261011` 已领先 **55 个提交**。
`main` 上的 `intercept_driver_register.c` 是**尚未回退的自研版本**
（自带 `DECLARE_WAIT_QUEUE_HEAD` / `wait_event` / `wake_up_all`，
却只 include `linux/wait.h`，没 include `linux/sched.h`）；
分支上的 `a993e33 对齐 RR：回退 4.x/5.x 自研偏离` 已把这套机制整个删掉，
所以分支能编、`main` 编不过。

**规则（要记住的）**：
- 跑 `lkms.yml` 验证时**一律带 `-f lkm_ref=<已知良好 ref>`**：

  ```bash
  gh workflow run lkms.yml --ref <workflow分支> -f lkm_ref=fix/partition-guard-20261011
  ```

  不传就是 `main`，等于拿一个 55 提交前的旧树跑全平台。
- **`gh run view --json inputs` 返回 `null` 时不要就此认定"用的默认值、和上次一样"**。
  `workflow_dispatch` 的 inputs 在 API 里经常是 null，默认值与非默认值**看起来完全一样**。
  要看**实际 checkout 的 ref**：日志里搜 `Checking out the ref`，
  或者 `Syncing repository: <owner>/<repo>` 后面那条 fetch 命令里的 refspec。
- 跨仓库的 CI 失败，先问"这次跑的到底是哪个 commit"，
  再去查环境/上游 —— 后者往往查半天全是死胡同。

**已处理**：`myp015/ainas-lkm` 的 `main` 已通过 PR #2 合并
`fix/partition-guard-20261011`（`main` = `a4fe2e3d`），默认 ref 不再是编不过的树。
验证：按**默认 `lkm_ref=main`** 触发 `Build lkms`（run `38815958625` @ `main`），
**65/65 job 全 success** —— 与钉分支那次（`38766622176`，64/64）一致。

**顺带记住的判断手法**：判断「这个默认值还能不能用」，看
`gh api repos/<owner>/<repo>/compare/main...<branch>` 的 `ahead_by`：
`ahead_by` 很大说明 main 长期没跟上，默认值多半已经指向陈旧树。

## 2026-10-16 — 抽取内联 shell 到共享脚本：`$GITHUB_ENV` 只对后续步骤生效，同步骤内用的中间变量会丢成空

**症状**：`ainas-rr.yml` 打包出的镜像里 `consts.sh` 的 `RR_VERSION=""`、
`VERSION` 文件为空 —— 版本号没写进去。

> 别把 `RR_RELEASE=""` 一起当 bug：它的用途是 `${RR_RELEASE:+(${RR_RELEASE})}`
> （非空才展开后缀），空 = 正式版；`prerelease=true` 时才是 `pre`。

**根因**：`6cc27d2e` 把六份「Calculate version」内联块收敛成 `calc_version.sh`。
原内联版在**同一个 shell** 里算出 `VERSION`，紧接着**同一步骤**就用它 `sed` 改 `consts.sh`；
抽成 `bash calc_version.sh`（子进程）后，脚本只把 `VERSION` 写 `$GITHUB_ENV`，
而 **`$GITHUB_ENV` 只对后续步骤生效、对当前步骤无效** → 同步骤的 `${VERSION}` 变空。
其余 5 个工作流都是「脚本在独立步骤、VERSION 在后续步骤用 `${{ env.VERSION }}`」，
所以只有 `ainas-rr.yml` 中招。

**铁证（不用看产物就能定位）**：`if [ -n "${VERSION}" ]` 为假会**跳过 `git push`**，
所以 `ainas-rr` 仓库的 `consts.sh` 长期停在旧值，最后成功 push 的时间早于抽取提交。
「修复前那次 run 虽 success 却没有任何 push 提交」即可坐实。

**规则（要记住的）**：
- **把内联 shell 抽成共享脚本前，先问：原代码有没有在「同一步骤内」用到中间变量？**
  有 → 要么让脚本把结果打到 **stdout** 供 `$(...)` 捕获，要么把使用点挪到后续步骤；
  只写 `$GITHUB_ENV` 不够。
- **`$GITHUB_ENV` / `$GITHUB_OUTPUT` 的可见范围是「后续步骤」**，不是当前步骤 ——
  GitHub Actions 最容易踩的时序坑之一。
- 判断「值到底有没有传下去」，别看脚本自己的 `echo`（那只是它自己的 stdout），
  要看**依赖该值的副作用**有没有发生（这里是 `consts.sh` 的 push）。

**已处理**：`calc_version.sh` 把纯版本号打到 stdout（人类日志改走 stderr），
`ainas-rr.yml` 用 `VERSION="$(bash ... )"` 捕获；`$GITHUB_ENV` 写入不变，
其余 5 个调用方不受影响。
验证：run `38850658666` @ `main` success —— `ainas-rr` 的 `consts.sh` 从 `26.10.13`
更新为 `26.10.15`（push 提交 `d37ffd05`），Release `26.10.15` 创建。

## 2026-10-22 复刻 rr-misc：两条交叉编译坑

**1. `AC_FUNC_MALLOC` 在交叉编译下必然误判**
configure 无法运行测试程序 → `ac_cv_func_malloc_0_nonnull=no` →
config.h 把 `malloc` 重定义为 `rpl_malloc`。若包本身不带 gnulib 的实现，
链接期就是 `undefined reference to rpl_malloc`（acpid 2.0.28 实测）。
修法：`CONFIGURE_ARGS += ac_cv_func_malloc_0_nonnull=yes` 与
`ac_cv_func_realloc_0_nonnull=yes`（spksrc 的 autossh/davfs2 已是此写法）。
看到 `rpl_malloc`/`rpl_realloc` 未定义，先查 config.h 的 `HAVE_MALLOC 0`。

**2. Synology 工具链裁剪了内核 UAPI 头**
sys-root 里没有 `linux/if_macsec.h`，而 wpa_supplicant 的 defconfig
默认开 `CONFIG_DRIVER_MACSEC_LINUX=y` → `fatal error: linux/if_macsec.h`。
根因不是代码，是头文件缺失。libnl 源码树自带兼容副本
（`include/linux-private/linux/if_macsec.h`），编译前拷到独立的
include 目录并 `-I` 进去即可，不要为了过编译关掉功能（旧 addon 带 macsec）。
判据：新旧二进制 `strings | grep macsec_linux` 对比，别凭感觉降级。

**3. 新 spksrc 的 .spk 是不压缩的 POSIX tar**
`tar -zxf *.spk` 会报 "not in gzip format"，要用 `tar -xf`；
里面的 `package.tgz` 才是 gzip。

**4. automake 里写死的绝对安装目录会绕过 prefix**
open-vm-tools 的 `scripts/Makefile.am` 把 `vmsupportdir = /usr/bin`、
`confdir = /etc/vmware-tools` 写死，`make install DESTDIR=... prefix=...`
只给 prefix 拼 DESTDIR，这两个目录直接落到 `$(DESTDIR)/usr/bin`、
`$(DESTDIR)/etc`，不在 staging 前缀下 → spk copy 阶段 PLIST `Cannot stat`。
判据：日志里 `install -c ... '/.../install/usr/bin'` 没有 `var/packages/.../target`。
修法：给 `post_install_target` 追加 recipe 搬进 `$(STAGING_INSTALL_PREFIX)`。

**5. 覆盖 spksrc 的 POST_INSTALL_TARGET 变量无效**
`spksrc.build/install.mk` 在 include 时就用 `$(POST_INSTALL_TARGET)` 展开了
`$(INSTALL_PLIST): ...` 与 `$(POST_INSTALL_TARGET): $(INSTALL_TARGET)` 的接线，
include 之后再改这个变量不会被调用。要挂钩子就直接给 `post_install_target`
追加 recipe（同一目标可以多次定义，前后依赖保留）。

**6. 手动删过 staging 目录后，cookie 必须成组清**
`install/` 是所有依赖共享的暂存区。删掉它却留着 `*-install_done` /
`*-dependency_done`，下次构建会认为依赖都已就绪，跳过重装 → configure
找不到 pkg-config（如 `glib2 >= 2.34.0 is required`）。清理范围：
`.*-install_done`、`.*-plist_done`、`.*-dependency_done`、`.dependency_done`。

**7. `cpp` 前端不接受 2 个以上输入，gcc 驱动的 `-E` 可以**
grub 2.12 生成 `libgrub.pp` 的规则是 `$(CPP) <200+ 源文件> > libgrub.pp`。
spksrc 把 `CPP` 设成 `<triple>-cpp`，该前端最多吃 2 个文件，第 3 个直接
`fatal error: too many input files`；换成宿主 `/usr/bin/cpp`（GCC 14）同样失败。
根因是 `cpp` 这个程序名本身的限制，不是版本或架构问题：同一套工具链里
`<triple>-gcc -E` 一次 300 个文件都正常（gcc 驱动会顺序拼接）。
修法：`make CPP="$(call tc,gcc) -E"`；spksrc 自己的
`mk/spksrc.native/env-default.mk` 也是 `CPP="$(NATIVE_CC) -E"`，属既有惯例。
判据：`cpp` 报 too many input files 时先用 `gcc -E` 复现，不要改上游规则。

## 2026-10-27 — 上游文案改名会让「前缀替换」的 sed 产出双重前缀

ainas-rr 把 `consts.sh` 的 `RR_TITLE` 从 `"RR v${RR_VERSION}"` 改成
`"AiNas_RR v${RR_VERSION}"` 后，2in1 的 `s/RR v/AiNas 2in1 Loader v/` 命中的是
`AiNas_RR v` 里的后半段 → 得到 `AiNas_AiNas 2in1 Loader v…`。
正则本身没写错，错在**替换目标的尾串与被替换串共享**（同 149 行「长名先于短名」）。
修法：先匹配最长的新前缀（`s/AiNas_RR v/…/g`），再留旧前缀分支给历史镜像。
验证：把新旧两版输入各跑一次 `diff`，结果必须为空——只验新版会漏掉兼容分支。

## 2026-10-27 — 2in1 升级包的 DT / 非 DT 两份本来就等价

`update-list.yml` 只取 p1/p3 的通用文件（bzImage/initrd/cks/lkms/addons/modules、
AINAS_VERSION、EFI），`patch_ram`（2in1 变体）与 `patch_addons_disk` 都不看型号，
`patch_part1` 唯一依赖型号的产物 grub.cfg 不进包 ⇒ 拆两个 job 属重复构建。
现在只留一个 `__UPDATE__`，产 `updateall-<版本>.zip`。
设备侧配套：`fan.iynas.cn/order_auth.php` 原按 `updateall-<版本>-<type>.zip` 拼地址，
已改为「version 里有 `file=` 行就用它，否则沿用旧名」，否则新包下载 404。

## 2026-10-27 — 2in1 repack 写满的是 **P6 分区**，不是 runner 磁盘

`repack_2in1` 往 `/tmp/repack/o/p6/modules/` rsync 时 `No space left on device`，
表现为 `rsync error … code 11` 后 `##[error]Process completed with exit code 11`。

**先前的「runner 磁盘只有 14G」归因是错的**：`/tmp/repack/o/p6` 是挂在镜像
P6 分区上的挂载点，ENOSPC 来自**分区内**空间耗尽。基础镜像的 P6(RAMDISK)
只有 2048MiB，而 loader `rr.img` 的 p3 载荷自 `modules-26.10.22` 起已约 2.0GB
（modules 976M + cks 429M + initrd 245M + 其余 72M），写到 modules 末尾
（`v1000nk-7.3`，字母序靠后）就满。铁证：loader 自己的 p3 分区是
`7133184` 扇区 = 3.4GiB（`sfdisk -d rr.img`），P6 取 2GiB 本就不够。

判据要点：**看到挂载点路径下的 ENOSPC，先 `df` 那个挂载点**，别拿宿主磁盘容量解释。
已修（ainas-2in1 `46dbd1f`）：整盘 14.5G→18G、P6 2048→2560MiB，并在
`repack_2in1_Img` 的 p3→p6 rsync 前加 `du -sb` vs `df` 容量校验 fail fast。

## 2026-10-27 — 2in1 6.2 线取不到 PAT：pats.xlsx 根本没有 6.2 行

修掉上面的 ENOSPC 后，同一个 job 立刻在下一步暴露第二个坑：
`[E] PAT 版本不匹配: req=6.2.4, got=7.4.1-90080-0`。

`dsm_setup` 从 `RROrg/rr` 的 `docs/pats.xlsx` 里按 `6.2.4-` 前缀找 PAT，找不到就退到
「该型号所有版本里最大的」（7.4.1），再做前缀校验并退出。上游表由 Synology **7.x** 升级 API
生成，**一行 6.2 都没有**（RR 24.4.0 起已移除 6.2 支持）。

修法（ainas-rr `c340f6d` / ainas-2in1 `1fdb52e` / ainas-build `a1afbb2e`）：
- `scripts/func.py` 的 `getpats` 在写文件前固定补 `DS918+`/`DS3617xs` 的 `6.2.4-25556-0`
  （官方 URL，`+`→`%2B`，sum 全 0），所以 data.yml 将来刷新也不会丢这两行；
- 三个工作流（2in1 / ainas-2in1-image / ova）的 `PAT_XLSX_URL` 改指
  `myp015/ainas-rr/main/docs/pats.xlsx`；
- 同步重新生成 `docs/pats.xlsx` 与 `docs/pats.json`。

实测 run `40487882268` 全绿：`PAT_VERSION=6.2.4-25556-0`、容器安装完成、制品已发布。
教训：**fail-fast 修掉一个会立刻暴露下一个**——「跑到下一个错」不等于修完，
要一直跑到整条链路绿为止。

## 2026-10-27 — 2in1 构建容器里 6.2 **只有 2 次 init**：别把 `docker logs --tail` 转储当成新一次启动

先按「6.2 需要两次重启、等第 3 次 `:: Starting /etc/rc` 再开始 300 秒计时」改了一版
（ainas-2in1 `19ff4f8`），run `40494912684` 等满 1200 秒超时 → 已回退（`c0c7dd7`）。

三个错误叠加：
1. **把转储时间当成启动时间**。之前看到的「10:35:54 第三次 /etc/rc」，其实是脚本停容器前
   `docker logs --tail 300` 把 boot2 的内容又打印了一遍，CI 给每行加的是**转储时刻**；
   同一段内容 pid 相同（`4476`/`4475`）、内核时间戳一字不差（`[16.380874]`）就是铁证。
2. **容器里根本没有第三次启动**。真实启动 2 次：安装引导一次 + 装完后一次；之后 20 分钟
   没有任何新内核/新 init 输出。2in1 镜像里 DSM 的「重启」是 `linuxrc.syno` 重跑，
   不重启 QEMU 内核，也不会重打内核 banner。
3. **`grep -c` 数的是行不是次数**。QEMU 串口用 `\r` 分行，`docker logs` 里整段控制台输出
   是一行，`grep -c ':: Starting /etc/rc'` 恒为 1；要数出现次数得
   `grep -o '...' | wc -l`。

判据结论：容器内无法用「重启次数」判断 6.2 装完没装完；300 秒套件等待保持原样。
真机上首次开机的展开/二次重启发生在用户设备上，构建侧观察不到。

**顺带修掉**：Web 探活里 `OUT=$(curl ...)` 在重启期间连接被拒会返回非零，`set -e` 直接
打断脚本，已加 `|| true`。

## 2026-10-27 — 纠正上面那条「容器里只有 2 次 init」：现在是 3 次启动 / 2 种内核 banner

上面 2026-10-27 那条结论在当时的镜像上成立，但 **2in1 镜像把 loader 与 DSM 装到同一块盘之后，
update7→update8 的完整链路在容器内确实跑通了**。run `40535696916`（DS918+ / 6.2.4）实测：

- DSM 内核启动 **3 次**：安装引导（build3）→ update7（build3）→ update8（build7）；
- 内核 banner 出现 **2 种**：`Linux version 4.4.59+ (root@build3)` 与 `... (root@build7)`；
- 串口在 update8 启动 ~120s 之后完全静默（每轮 0 新字节），与真机日志节律一致；
- 所以「6.2 装完」的判据可以、且必须用**不同 DSM banner 的种类数 ≥2**，
  而不是某个固定秒数或「静默」时间。静默只能作为附加条件。

推论：上面那条「容器内无法判断 6.2 装没装完」**已作废**，勿再据此回退判据。

## 2026-10-28 — 未初始化 DSM 6.2 的 `get_state.cgi` 会返回 500：Web 判据只能看「有没有 HTTP 状态行」

同一个 run 的取证里，`/webman/get_state.cgi` 在 update8 的最终系统上返回 **HTTP 500**：
一次响应体为空（0B），另一次却有 **11939 字节**。所以两种常见判据都不成立：

- 按状态码判 200 → 永远失败；
- 按「响应体非空」判 → 时真时假（取决于 nginx 有没有给出错误页），第一次失败 run 就是被它判成
  「Web 不可达」白等 900 秒。

**正确判据**：只要拿到 HTTP 状态行（`curl -w '%{http_code}'` 不是 `000`，即不是 connection
refused/超时）就算 Web 层起来了；系统是否真的进了 update8 由**内核 banner 种类数**兜底。
状态码与体长仍要打进日志（`WEB_STATE=路径|状态码|体长`），否则下次又只能靠猜。

## 2026-10-28 — `losetup --show -o` 必须带 `--find`，否则被拒且错误被 `2>/dev/null` 吞掉

想在分区设备内的某个偏移处看文件系统（DSM 的 md 成员）：

```sh
losetup --show -o 2097152 /dev/loop0p1            # ✗ 报错：
# the options --{sizelimit,partscan,read-only,show} are allowed during loop device setup only
losetup --find --show -o 2097152 /dev/loop0p1    # ✓
```

脚本里原本写的是前者 + `2>/dev/null || continue`，于是 9 个候选偏移全部**静默 continue**，
日志只剩一句「按常见偏移都挂不上」，完全看不出是命令用法错。教训：**探测类命令的 stderr
不许直接丢弃**，至少要在失败时打印一次原文。

顺带：DSM 盘上 p1/p2 的 `blkid` 都是 `linux_raid_member`（p1=md0 系统、p2=md1 swap），
但 **6.2 的成员其实是 fs 从分区起点开始**——不能按「md 1.2 超级块在 4KiB、数据在
data_offset 之后」去算。2026-10-28 直接抓产物镜像头部（`gh api -H "Range: bytes=0-…"`
+ 部分 `gzip -dc`）实测 DS918+/6.2.4 的 p1：ext4 魔数 `0xEF53` 在分区 **+1024**，
而分区 +4096 处既不是 `0xa92b4efc` 也不是其它已知魔数 ⇒ `mount -t ext4` 直接用**偏移 0**
即可（`losetup --find --show -o 0`）。md 1.2 的 `data_offset` 解析只能当兜底分支保留，
解析成功才用，失败是正常路径，别把它当成「必须解析出来」的前置条件。

判据上也要注意：`blkid` 报 `linux_raid_member` 不代表不能按 ext4 挂，
`mount` 不带 `-t ext4` 时它会听 libblkid 的自动识别而拒绝，必须显式 `-t ext4`。

## 2026-10-28 — 7.x 装完自己就重启：`reboot.cgi` 会超时，别把它当致命错误

run `40594465296`（DS920+ / 7.2.1）在 6.2 的改法上回归失败：

```
[INFO] 触发 DSM 重启（webman/reboot.cgi）
curl: (28) Operation timed out after 10002 milliseconds with 36 bytes received
[E] 触发重启失败：reboot.cgi 请求出错
```

区别就在这里：**6.2 装完不会自己重启**（靠前端 `installer.js` 在 Success 时 POST
`webman/reboot.cgi`），**7.x 装完系统自行重启**，这时 POST 的连接会被挂住/切断——
重启其实已经发生。把它当致命错误就直接误杀。

两条修正（ainas-2in1 `54e245f`）：
1. POST 非零退出只告警不退出，是否真重启交给等待循环判定
   （**内核 banner 次数增加 + Web 连续两次可达**）；真没重启照样超时失败，所以不算吞异常。
2. **`BOOTS_BEFORE` 必须在 POST 之前取**：7.x 自行重启时，POST 期间新的一次启动会被
   算进基线，后面「次数变多」的判据就永远不成立（这是比超时更隐蔽的坑）。

## 2026-10-28 — 7.x 串口不会静默：`synobios` 心跳让「连续 N 秒无新输出」的判据永远不成立

run `40596056118`（DS920+ / 7.2.1）稳定等待 600s 超时，日志里 `系统稳定中 30/90s`
原地重复 10 次。控制台原文：

```
[  297.834165] synobios get empty ttyS current
[  358.343154] synobios get empty ttyS current      ← 每 ~60.5s 一行
```

官方 `synobios` 会周期性打这行心跳（另有零星 `Invalid parameter`），所以
**7.x 永远不会有「连续 90s 零新字节」的时刻**。原判据在 6.2 上碰巧成立（6.2 的心跳少），
在 7.x 上结构性失效——这类判据要么对已知心跳免疫，要么别用。

改法（ainas-2in1 `3d5bdf6`）：稳定性 = **Web 连续可达 STABLE_SEC 秒 且期间没有新的
DSM 内核启动**（`boot_count_changed`）。重启仍能被抓住：重启必先断 Web、必新增 banner。
不要再用「串口静默」当任何完成判据。

## 2026-10-28 — 未初始化的 DSM `get_state.cgi` 恒返回 500：版本只能从系统盘 `/etc/VERSION` 读

用户要求「系统启动后 cat /etc/VERSION 确认版本」，本意是别为此停容器再挂镜像。
先按 `get_state.cgi` 的 `dsinfo` 取（`dsm_auto_install.sh` 就是这么解析 `build_ver` 的），
结果 **6.2 与 7.x 都拿不到**：响应是 HTTP 500 + 11939 字节 HTML 错误页。
原因不是超时——没跑过 setup 向导（未初始化）的 DSM，这个 CGI 根本不出 JSON。
于是日志里一直只有「系统自报版本=<未取到>」，等于没有版本证据。

可靠做法：镜像本来就是 **bind mount 进容器**的（`docker-compose.yaml` 的
`./rr.img:/rr.img`），容器运行中直接对宿主侧文件只读挂 p1 读文件即可，**无需停容器**：

- `losetup -Pf --show rr.img` → `losetup --find --show -o <data_offset>` → `mount -t ext4 -o ro,noload`
- `-o ro,noload` 不写盘、不重放日志，QEMU 继续写自己的不受影响；读到滞后内容就重挂重试（3 次足够）
- 6.2 的 fs 在分区起点（偏移 0），7.x 的 md0 成员走 `data_offset`；同一个探测函数两种都覆盖
- **挂载过程的日志必须走 stderr**：函数的 stdout 是 `$( )` 的返回值（VERSION 原文），
  混进去不影响解析但日志里就看不到挂载到底用了哪个偏移

实测（ainas-2in1 `667eef2` / `c98c1aa`，run `40604877753` + `40606875963` 均 success）：
6.2 → `6.2.4-25556-8`（`nano7-fullpatch`，`builddate=2024/11/25`），banner `build3` + `build7`；
7.2.1 → `7.2.1-69057-13`。6.2 若读到 `smallfixnumber < 8` 直接判「仍停在 update7」失败退出；
读不到只告警（此时 banner ≥2 种已证明 u8 内核在跑，别让挂载偶发失败误杀整轮构建）。

## 2026-10-28 — addon 的 install.sh 在 loader initrd 里跑：6.x 的 busybox 不认 mkdir -v / ln -v

真机 DSM 6.x 安装日志（用户反馈，CI 里可复现）：

```
Installing addon expand_volume - late
mkdir: invalid option -- 'v'
ln: invalid option -- 'v'
```

`ainas-2in1/addons/resizepart/all.tgz` 里的 install.sh 抄了上游 `expands` 的风格，用了
`mkdir -vp` / `ln -vsf`：GNU coreutils 支持，**6.x 的 busybox 的 mkdir/ln 不支持**
（`cp -v` 反而支持，所以只有这两行报错）。后果不只是刷屏——
`multi-user.target.wants/expand_volume.service` 这条软链建不出来，
**6.x 上插件等于没装**（6.x 没有 systemd，只能靠 loader 的 `dsm6-services.sh`
枚举 `multi-user.target.wants` 执行 unit）。

修法（ainas-2in1 `9e3bf9c`）：`mkdir -vp`→`mkdir -p`、`ln -vsf`→`ln -sf`、`cp -vpf`→`cp -pf`，
重打包 all.tgz。验证：run `40614029539`（DS918+ / 6.2.4）里两行报错消失，
`Installing addon ResizePart` 与 `dsm6-services: installed /usr/share/init/rr-addons.conf`
正常，最终系统仍为 `6.2.4-25556-8`。

教训：**addon 的 install.sh 只能用 POSIX/busybox 子集**，动手前先核对上游脚本里有没有
`-v`；另外 `all.tgz` 是二进制载荷，改了 install.sh 必须重新打包并核对清单（本次清单不变）。

## 2026-11-04 — rr 选 6.2 时的型号校验要前置到 plan，不能拖到 dsm_setup

`rr.yml` 选 DSM 6.2.4 时，`plan_sources.sh` 原先对 rr 直接丢弃 `custom_models`
（只编 DS918+），勾选项也只认 DS918+；用户输入其它型号会被静默忽略，而 2in1 线
放行后是编到 `dsm_setup` 才报 `PAT 版本不匹配: req=6.2.4, got=7.x`。

修法（plan_sources.sh）：
- 6.2 下勾选项与 `custom_models` 都生效；plan 阶段拉取 ainas-rr 的
  `docs/pats.json`（与构建实际使用的 PAT 表同源），只保留有 `6.2.*` 行的型号，
  并按官方写法还原大小写（`ds920+` → `DS920+`）。不在表内的型号立刻报错并列出可用型号。
- 全选仍只编 DS918+（23 个 6.2 型号逐个编代价太大），其它型号走勾选/自定义。
- 拉取失败同样 fail fast，不带着未校验的矩阵继续。

教训：**“这个型号能不能编这个 DSM 版本”应在 plan 阶段用数据表判定**；另外 rr 与
2in1 的 6.2 型号策略此前不一致（rr 静默忽略、2in1 放行），排查前先确认当前行为，
不要按另一个工作流的印象推断。

## 2026-11-04 — 资产下载失败只剩 exit code 1：选错 test release + 静默错误

`Build ainas-rr-original` 两次失败都停在 `[INFO] 正在获取系统模块`，下一行直接
`##[error]Process completed with exit code 1`。补上诊断输出后（run 41860498651）看到：

    [E] syno-modules@test-modules-26.11.0 中没有资产 modules-test-modules-26.11.0.zip

根因是 include-pre 的 release 选择：
- `syno-modules` 的 test release tag 是 `test-modules-26.11.0`，资产名是
  `modules-26.11.0-test.zip`；
- 旧逻辑用 `sort -rV` 选 tag，`test-modules-26.11.0` 会排在 `26.11.1` 之上；
- 旧逻辑按 `<前缀>-<TAG>.zip` 精确匹配，永远匹配不到该 test release 的资产；
- 下载根本没开始，而 `-s` 屏蔽 curl 错误、`[ ! -f ] && exit 1` 又不打印，日志只剩退出码。

修法（ainas-2in1 `fetchReleaseAsset`，`087dc34`）：
- include-pre 时按 `published_at` 取最新非草稿 release（与 `/releases/latest` 语义一致），
  不再用 `sort -rV` 比较任意字符串 tag；
- 资产按 `<前缀>-*.zip` 前缀匹配，与 tag 同名的精确匹配优先；
- 保留 `-sS` / `--retry-all-errors` 与逐项 `[E]` 输出。

验证：本地以 include-pre 调 ainas-lkm（15MB）与 syno-modules（934MB），均正确选到
26.10.68 / 26.11.1 并下载成功；单测确认 test release 发布时间更新时会被选中，且
`modules-26.11.0-test.zip` 能被前缀匹配。

教训：**先补可诊断输出，再谈根因**。最初“CDN 瞬时断流”的推断是错的——诊断输出一
上线就暴露出选错了 release。发布流程新增非常规命名的 release（如 `test-*`）时，
必须同步检查所有消费方的 tag/资产匹配逻辑。

## 2026-11-05 — Release 资产同名时 mv 会失败；覆盖语义别拆成多个开关

- `pack_update` 按镜像内版本命名，目标名可能正好同为 `updateall-<版本>.zip`；直接
  `mv -f "$RAW" "$TARGET"` 在同名路径上报 `are the same file` 并退出 1。改名逻辑应先比较
  basename，不同才 mv（rr.yml prepare-base 已按此修正）。
- 复用/覆盖开关按制品拆成 4 个 boolean（base / 按型号 update / 全型号 update / 原版镜像）
  容易组合出无效状态、维护成本高。用户要求合并为单个 `overwrite`（rr 与 2in1），默认
  全部复用；原版镜像始终进矩阵，产物已存在则跳过 job。新增制品时优先并入既有开关语义。

## 2026-11-05 — 串口回显在真实日志里是“坏掉”的，夹具必须覆盖损坏形态

Task#221 全矩阵 run 42002461964：DS918+ / DS925+ 启动日志门禁报 `[FAIL] VERMAGIC`，
命中行是 `probe.commands` 里那条 `/var/log/messages` 定向 grep 的**命令回显**。

- 串口并发写把 ANSI 颜色序列截断，只剩 `;32m` / `01;32m` 前缀，行首锚定的
  `PROMPT_RE`（`^user@host:...#`）匹配不上；
- 同一行里的命令字被打错（`Unknnown symbol`、`Loading modulles failed`），
  与 `.commands` 原文精确匹配也失效；
- 结果回显模式串 `Invalid module format` 命中了 VERMAGIC 硬判据 → 假失败。

修法：`gate_common.py` 增加 `PROMPT_ANY_RE`（提示符出现在行内任意位置即判回显），
`check_bootlog.py` 补夹具「ANSI 截断 + 打错字的 grep 回显」；真实 artifact 回放
两平台均转 PASS（只报告项不变）。

教训：**过滤规则要按“最坏形态”设计**。串口是并发异步通道，任何按“输出完整、
无噪声”假设写的精确匹配/行首锚定都会在真机上失效；夹具必须来自真实 artifact 的
损坏样本，而不是手写的理想样本。

Task#221 第二轮（run 42002461964 全矩阵）：同一根因的第二种形态——v1000/denverton/
icelaked 等平台的登录 shell 没展开 `\u@\h`，提示符只剩 `~#`，且 ANSI 被截断成
`01;34m`、命令字被打错（`genneral`/`duplicate  symbol`）。行首锚定与 user@host
规则全部失效，6 个平台同时在 SCSI G-S2 与 bootlog 硬门禁上假失败。

修法：`gate_common.is_echo` 增加 `~#`/`~$` 提示符、截断 ANSI 残留、以及
「词元重合率 ≥80% 视作命令回显」的模糊匹配；两脚本各补该形态的夹具。
真实 artifact 回放：15 平台里 14 个双门禁 PASS，FS3400 是真实安装失败（无数据）。

教训：串口回显的「坏法」是长尾分布，不要按形态逐个打补丁。只要拿到命令文件，
用命令词元做模糊匹配就能兜底所有提示符/截断/错字变体；提示符规则只当快路径。

## 2026-11-06 — test.yml 历次矩阵的验证背景（从工作流注释迁入）

以下两段原本长期占用 `test.yml` 的注释，targets 改为 workflow_dispatch 输入后
已无矩阵上下文，移至此处留档。

### Task#193：与 RR 同样不可加载的模块修复验证

背景：Task#192 把 4.x 残余 35 个不可解析符号判为"与 RR 同样的生态状态、
不修"。本轮复核后只剩两族真缺陷（另 2 个符号 amd_e400_c1e_detected /
sk_receive_skb 只在 4.4.180 target 上出现，是"拿 4.4.302 导出面核对
4.4.180"造成的假阳性——官方 7.1 模块自己就引用它们），本矩阵逐族产物级
验证：

族1 dib* 28 符号（消费者 dvb-usb-dib0700.ko，4.x 全平台）：
我们 src 树 dvb-frontends/Makefile 的 dib 行（30-34、68-69）被官方裁剪
注释，defines 只开了 CONFIG_DVB_USB_DIB0700=m 没开任何 demod/tuner →
28 个直接引用无提供者，模块永不加载。修复=取消 Makefile 注释 + 20 个
4.x defines 加 7 个 CONFIG_DVB_DIB*/TUNER_DIB* 键。
判据：新增 8 个 .ko（dib3000mc/dib7000m/dib7000p/dib8000/dib9000/
dib0070/dib0090/dibx000_common），且 dvb-usb-dib0700.ko 的 dib* UND
全部可解析（本 target 全部 .ko 导出面 ∪ 官方导出面）。

族2 syno_libata_* 5 符号（消费者 sata_sil.ko，4.x 全平台）：
KSRC include/linux/libata.h 的 SYNO_* 宏（MY_ABC_HERE）把 5 个回调塞进
ATA_BASE_SHT，官方 4.4 内核只导出 syno_libata_index_get 且仅 r1000/v1000
→ sata_sil.ko 全平台 Unknown symbol。修复=sata_sil.c 里 #undef/#define
这两个宏：只留 .syno_port_type = SYNO_PORT_TYPE_SATA，去掉 5 个回调。
判据：sata_sil.ko 无任何 syno_libata_* UND，其余 UND 全在官方导出面内。

平台覆盖：4.4 两树 × MY_DEF_HERE 平台（v1000/r1000，index_get 被官方
导出的那类）+ 非 MY_DEF_HERE 平台 broadwell（index_get 不导出）。其余
4.x 平台改动同形，由下一次 modules.yml 全量发布构建复核。

### 5.10 主线 drivers/scsi 官方化验证

背景：src/5.10.55/drivers/scsi 14 个文件（B 类 11 + C 类 3）按官方 GPL
5.10 源码（linux-5.10-7.3.x.txz，2026-01-30）整份替换，恢复 syno 分支。
实际参与自编的只有 sg.c（sg.ko）与 libiscsi.c（libiscsi.ko），其余
12 个文件为官方内核内置（scsi_mod/sd_mod 在 Makefile 中注释），只做
源码一致性。
判据：
- sg.ko 无新增 UND；libiscsi.ko 无新增 UND（taskqueuelock/back_lock
  两个字段在 KSRC 头中存在，spin_lock_irqsave 分支可编译）；
- 全部 scsi 系 .ko 的 UND ⊆ 官方导出面 ∪ 本 target 导出面；
- 所有 target 编译零错误。
版本取 7.4（最新 dev KSRC）与 7.1（最老 dev KSRC），覆盖头文件跨度。

## 2026-11-07 — 内核 printk 会插进 guest 的记录行中间（第三种串口坏法）

Task#221 7.3.2 全平台轮（run 42234387134）：DS1621+ 的模块门禁 G-M1 报
`完成标记=True mount_rc=0 逐条=425 清单=426`。artifact 里 `cmd-4.out` 实际有
426 条 `@@M` 与 `@@MODTEST_DONE@@ total=426 status=done` —— guest 跑完了，
解析侧少一条。异常行是：

```
@@M|354|sound_firmware|INSMOD_OK[   92.785733] modtest-marker idx=355 name=sp2
```

每个模块 insmod 前写 `/dev/kmsg` 的归因标记（默认 KERN_DEFAULT=4）与 guest
的 stdout 共用同一个串口 pty，printk 在记录行中间插进来，把 rc/details
尾段挤掉。与 2026-11-05 的「命令回显损坏」不同：这次是**内核写的**，不是回显。

修法分两层：
- guest（根因）：标记改写成 `<7>modtest-marker ...`（KERN_DEBUG），
  console_loglevel=7 时不上控制台、但仍进 dmesg 环形缓冲，归因能力不变；
  若环境把 console_loglevel 调到 8，进循环前临时降到 7、循环后恢复原值；
- 解析器（兜底）：`parse_results.py` 新增 `TRUNC_RE`，按前缀恢复
  idx/name/state 并把记录计入总数；被打断的若是 INSMOD_FAIL，err 文本已丢 →
  空 err 落进 OTHER 硬失败，不静默放过。夹具加 S23/S24；plan 阶段自测补跑
  `parse_results.py --selftest`。

教训：串口 pty 上的**用户态输出**与**内核 printk** 是两个竞争写者。高频、
自发的 printk（每模块一条 marker）必须用 KERN_DEBUG 级别或降 console_loglevel
从源头把它挡在控制台之外；只在解析侧做容错，等于每轮矩阵都赌字节不乱序。
