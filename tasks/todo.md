# Task#215 模块逐测 OVA 测试工作流（基于 ova.yml 复制）

## 背景
参考 `ova.yml` 的"生成群晖系统 + 重现安装"链路，复制一份测试工作流：安装一次 DSM 后保存预装镜像，
逐个 insmod 自编模块（安全档），并用 SCSI 虚拟设备矩阵重启采集启动日志，最后与 RROrg 源做启动日志对比。
阶段 1 只跑 SA6400（epyc7002 / 5.10.55），跑通后扩到 7 个通用型号。

## 计划
- [x] 1. `.github/scripts/plan_test_sources.sh`：包装 plan_sources.sh，支持 ainas/RROrg/both，
      补充 platform/kver/modules_key，输出 base_tasks/tasks
- [x] 2. `.github/scripts/make_module_list.sh`：解包模块包 → modinfo 清单 + 拓扑排序 +
      vermagic 与目标内核比对（fail fast）→ `module-list.tsv` 写入引导盘 p3 的 `modtest/`，
      可选条数上限（原 `make_module_disk.sh` 生成独立 ext4 模块盘不可行，已删除）
- [x] 3. `.github/scripts/modtest/guest/run-module-tests.sh`：guest 侧从引导盘 p3 读模块包，
      安全档逐模块测试（已加载只记录、不 rmmod），结果经串口 `@@M|...` 输出
- [x] 4. `.github/scripts/modtest/run_profile.sh` + `render_test_compose.sh`：复用已安装的
      rr.img + data.qcow2 启动，按 profile 注入 SCSI 设备，串口执行命令并采集日志
- [x] 5. `ainas-2in1/script/dsm_serial_driver.py`：向后兼容 `exec` 子命令
      （commit bd4432a，已推送）
- [x] 6. `.github/workflows/ova-test.yml`：复制 ova.yml，base 上传到独立测试 Release
      （`test-ova-<source>-<tag>` / `test-ova-base-<source>-<tag>.img.zst`）跨 run 复用，
      安装一次后多 profile 复用预装镜像
- [x] 7. 本地静态校验：YAML 解析、bash -n、sh -n、py_compile、真实模块包生成模块盘验证
- [x] 8. CI smoke：单型号单源跑通（SA6400 × ainas）。run 41593744122：
      `mount -t ext4 synoboot3` 成功（LABEL=RR3），20 个模块全部有结果
      （loaded=7 / ok=10 / fail=3），`@@MODTEST_DONE@@` 正常收尾
- [ ] 9. 阶段 2：双源 + SCSI 3 型 + 启动日志归一化 diff

## 进度
- 2026-11-03：脚本与 workflow 落地；本地用 epyc7002-7.4-5.10.55（495 个 .ko）生成模块盘通过，
  拓扑序（mii→8139cp）正确，vermagic 校验通过。
- 2026-11-03：触发 `ova-test.yml` smoke（rr_source=ainas、test_models=SA6400、
  scsi_profiles=跳过、run_module_test=true、module_limit=20），run 41564874040：
  plan 与 prepare-base 通过，install+test 进行中。
- 修复记录：plan 合并误用未输出的 repo 字段；run_profile 相对路径导致 cd 后找不到渲染脚本；
  Web 就绪判据改为「拿到 HTTP 状态行」。
- 2026-11-03：run 41564874040 模块盘挂 ahci1 → QEMU IDE 盘在 AHCI 下不支持 NCQ，DSM 持续
  `READ FPDMA QUEUED`/ABRT，启动 122s 后静默、900s Web 不就绪；改用 USB 存储。
- 2026-11-03：run 41569653418 命令直接执行模块盘上的脚本，盘未挂载 → `No such file or directory`。
- 2026-11-03：run 41573290378 USB 存储被 DSM 命名为 `synoboot`（`sd 18:0:0:0: [synoboot]`），
  与引导盘冲突，`mount` 报 wrong fs type → **放弃独立模块盘方案**：模块包直接从引导盘 p3
  （guest 内 `sata1p3`）读取，清单与 guest 脚本在编译阶段写入 `p3/modtest/`，结果全部经串口回读。
- 2026-11-03：用户指令：p3 的 modules/ 与 lkms/ 本身就是全平台模块，不裁剪即可挂载调用
  → 测试工作流跳过 `trim_p3_assets`（保留全平台资产约 1.4G，引导镜像 p3 为 2.4G 可容纳）。
- 2026-11-03：run 41577570778 modtest 启动后串口登录失败（`login: timed out after 60 seconds`
  后 serial getty 重启）→ 驱动 `login()` 增加最多 4 次重试（commit cfa12ad）。
- 2026-11-03：run 41581658294 登录重试生效，但 `/dev/sata1p3` 与 `/dev/sd?3` 均不存在
  （命令里 `exit 1` 还把 root shell 踢掉，1800s 等不到标记）。
- 2026-11-03：用户指令：引导盘分区在 DSM 里是 `/dev/synoboot3`，且需先
  `echo 1 > /proc/sys/kernel/syno_install_flag` 才可挂载；挂载方式
  `cd /dev && mount -t vfat synoboot3 <挂载点>`。据此替换 mknod 方案。
- 2026-11-03：run 41589941072（job 显示 success，但模块测试实际未跑）：`synoboot3`
  存在（8:3），但 `mount -t vfat` 报 wrong fs type。本地核对 grub2.14 镜像：
  p1=`RR1` vfat、p2=`RR2` ext2、**p3=`RR3` ext4**（2.4G）→ 挂载类型改 `-t ext4`。
- 2026-11-03：run 41593744122 smoke 通过：`blkid synoboot3` = `RR3` ext4，
  `MODTEST_MOUNT_RC=0`，脚本解包 `modules/epyc7002-7.4-5.10.55.tgz` 并逐个 insmod，
  20 条 `@@M|` 结果 + `@@MODTEST_DONE@@ total=20 loaded=7 ok=10 fail=3 skip=0`。
  失败样例：acpi_cpufreq（No such device，QEMU 无对应 CPU）、aic8800_fdrv/aic94xx
  （Unknown symbol，依赖未先加载）——待阶段 2 逐条核对依赖拓扑。
- 2026-11-03：用户指令：测试工作流取消耗时步骤——`patch_cpuinfo`、`patch_ram`
  （unpackInitrd 解包 initrd-rr / 生成语言文件 / rr menu.sh 升级菜单 / repackInitrd）；
  base 上传到独立命名的 Release 以便重复调用。已在 prepare-base 中跳过两个补丁，
  新增 overwrite_base 开关与 Release 复用检查。
- 2026-11-03：run 41597730680 全绿（ainas/SA6400）：prepare-base 命中已有
  `test-ova-ainas-26.11.0` base 直接复用；安装、base profile、modtest profile 全部成功，
  20 个模块结果 `total=20 loaded=7 ok=10 fail=3`（与 run 41593744122 一致）。
- 2026-11-03：用户指令：已有安装好的成品 OVA 可直接启动——改用
  `ainas-ova-26.11.0` / `RROrg-ova-26.9.0` Release 里 `*_741_*.ova.gz`（已安装，
  DSM 7.4.1/90080，与当前测试版本一致）。新增 `use_prebuilt`、`prebuilt_versions`、
  `modules_version` 输入；新增 `prepare_prebuilt.sh`：gzip 流式解包 OVA →
  按 `qemu-img` 虚机容量区分启动盘（2.5G）/数据盘（12G，不依赖 ovftool 命名）→
  转 raw qcow2 → 从 syno-modules 取同一份平台模块包注入 p3 的 modules/ 与 modtest/。
  预装模式下 prepare-base 与安装步骤整体跳过。

## Review
（完成后补写）

## 实机验证（bj3_dsm，DS918+/apollolake/4.4.302/DSM 7.4.1-90080）

- 2026-11-03：按用户要求在实机先跑通再回灌工作流。只读挂载 `/dev/synoboot3`
  （LABEL=RAMDISK，ext4，2.0G，已用 719M）确认 p3 有 `modules/apollolake-7.4-4.4.302.tgz`；
  在 DSM 本机生成清单（`modtest/module-list.tsv`）并执行
  `run-module-tests.sh apollolake-7.4-4.4.302`，安全档 20 条结果正常回读。
- **根因（实机实锤）**：`modinfo -F depends` 输出是逗号分隔
  （如 `cfg80211,aic_load_fw,usbcore`），`make_module_list.sh` 只按空白切分，
  多依赖模块的依赖从未被拓扑排序前置 → CI 与实机都出现 aic8800_fdrv / 9pnet_virtio
  `Unknown symbol`。修复为按 `[,\s]+` 切分后，实机验证：
  `rfkill → cfg80211 → aic_load_fw → aic8800_fdrv` 全部 insmod 成功，
  `virtio → virtio_ring → 9pnet_virtio` 成功；前 20 条重跑
  `total=20 loaded=16 ok=3 fail=1`（唯一失败 acpi_cpufreq = 实机 CPU 无对应接口，
  属设备差异，非加载顺序问题）。
- 实机全程不 rmmod（安全档），已加载模块仅记录 srcversion。
- 2026-11-03：run 41607024004（prebuilt 双源、仅 base profile）验证 analyze：
  加入 `always() + needs 结果检查` 后对比 job 正常运行并产出 bootlog-diff，
  证明此前被跳过是「被跳过的 prepare-base 祖先」影响了隐式 success() 语义。
- 2026-11-03：run 41608661790（prebuilt 双源、modtest 20 条）全绿：
  `total=20 loaded=9 ok=10 fail=1`（修复前 fail=3）；9pnet_virtio 现在
  INS_MOD_OK，aic8800_fdrv 因依赖排序后移出前 20；唯一失败 acpi_cpufreq = QEMU CPU 无接口。
