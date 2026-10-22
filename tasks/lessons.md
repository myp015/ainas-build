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
