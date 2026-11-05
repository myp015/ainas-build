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
- [x] 9. 阶段 2：双源 + SCSI 3 型 + 启动日志归一化 diff
      （run 41610717372：双源 × 5 profile 全绿，三型设备均被对应驱动识别）
- [x] 10. 全量模块一次性验证（module_limit=0）：run 41613847561（514 条，9分13秒），
      发现连字符依赖排序缺陷 → 修复后 run 41616244893 全绿，fail 66→21
- [x] 11. 残余 21 个失败分类：17 个为环境/硬件缺失（正常），4 个 Unknown symbol
      （nf_socket_ipv6/nf_tproxy_ipv6 及级联 xt_socket/xt_TPROXY）
- [x] 12. 4 个 Unknown symbol 修复：源码改用 `__udp6_lib_lookup` + refcount 契约
      （两树同步，ainas-modules ebb70628），test.yml 单平台编译验证通过，
      UND 与 RR 成品逐符号一致；测试 Release 上机回归 4 个模块全部 INSMOD_OK
- [x] 13. 常规全量发布（modules.yml 63 target + cks.yml 12 target，版本 26.11.0）
      run 41623997006 全绿（63 build + firmware + release，12:26 发布）；
      cks run 41624016278 全绿（12 build + firmware + release，12:31 发布），
      ainas-cks `release/` 已推送到 5c4d515
- [ ] 14. 多型号验证（4.x）：DS918+/DS3622xs+ 全量跑通；DS920+/DS923+ 因加载
      scsi_debug 触发官方内核 Oops 卡死 → 新增 known-hazards 豁免（geminilake/r1000），
      重跑中（run 41643536367）

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
  （Unknown symbol，依赖未先加载）——**已由依赖切分修复解决**（见实机验证段）。
- 2026-11-03：阶段 2 前本地校验：三种 SCSI 设备命令行在 QEMU 10.0.13 上语法通过
  （virtio-scsi-pci/megasas/mptsas1068 + scsi-hd 挂 bus），render_test_compose.sh
  对真实 compose 渲染四种 profile 结果正确（container_name/restart/ARGUMENTS 注入）。
  探针增加 `scsi_host proc_name`、`/sys/bus/scsi/devices`、dmesg 关键行 grep。
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
- 2026-11-03：run 41610717372（双源 + 全部三型 SCSI + 20 条 smoke）全绿（20m52s）：
  每源 5 次启动（base/modtest/virtio-scsi/megaraid/mptsas），三型设备均被识别：
  virtio_scsi → `scsi host18 proc_name=virtio_scsi`、sata3=QEMU HARDDISK；
  megaraid_sas（ainas 版为 syno `megaraid_sas_pdoff`）→ scsi 18:2:0:0；
  mptsas → `proc_name=mptsas`，scsi 6:0:0:0。双源 bootlog-diff 已产出。
- 2026-11-03：全量模块一次性验证（module_limit=0，单源预装）run 41613847561：
  514 条 `total=514 loaded=83 ok=365 fail=66`，总耗时 9分13秒。
- **全量暴露第二依赖缺陷**：`modinfo -F name` 是下划线名（snd_hda_codec），
  `depends` 字段是连字符名（snd-hda-core,snd-pcm,i915-compat）→ 原样查表查不到，
  依赖从不前置。修复（norm 连字符→下划线）后本地清单 514 条 0 违例；
  run 41616244893：`total=514 loaded=83 ok=410 fail=21`，全量一次跑完约 9 分钟。
- 残余失败分类：17 个环境/硬件缺失（acpi_cpufreq/coretemp/intel_idle/it87/gpio_*/
  kvm_amd/kvm_intel/cpufreq_userspace/binder_linux/ch35x_38x/syno_hddpwrctl_test 等，
  均属预期）；4 个 Unknown symbol：nf_socket_ipv6、nf_tproxy_ipv6 及级联
  xt_socket、xt_TPROXY。根因：defines 打开了 CONFIG_NF_SOCKET_IPV6/NF_TPROXY_IPV6=m，
  我方 nf_socket_ipv6.ko 导入 `udp6_lib_lookup`（仅当该配置在**内核**里开启时 ipv6.ko
  才导出）；官方 DSM 7.4 内核未开启该配置（官方 ipv6.ko 只有 `__udp6_lib_lookup`），
  且官方包本就不含这 4 个模块。RR 的 nf_socket_ipv6.ko 导入的是 `__udp6_lib_lookup`
  （与官方内核兼容）。
- 速度结论：模块全量验证 = 一次启动（base 基线可关，约 6 分钟）；SCSI 三型各需
  一次启动（用于启动日志对比），与模块测试相比是额外 3 次启动，不是模块数导致。
- 2026-11-03：run 41608661790（prebuilt 双源、modtest 20 条）全绿：
  `total=20 loaded=9 ok=10 fail=1`（修复前 fail=3）；9pnet_virtio 现在
  INS_MOD_OK，aic8800_fdrv 因依赖排序后移出前 20；唯一失败 acpi_cpufreq = QEMU CPU 无接口。
- 2026-11-03：IPv6 修复（ainas-modules ebb70628）：nf_socket_ipv6.c / nf_tproxy_ipv6.c
  的 `udp6_lib_lookup` 改为 `__udp6_lib_lookup(..., 0, &udp_table, NULL)` +
  `refcount_inc_not_zero`（与 IPv4 版同款写法），src/5.10.55 与 src/5.10.55-ck 同步。
  依据：官方导出面 `exports_epyc7002_74.txt` 只有 `udp_table`，`__udp6_lib_lookup`
  由官方 ipv6.ko 导出（`exports_mod_epyc7002_74.txt`）；RR 同模块 UND 即此两符号。
- 2026-11-03：test.yml 矩阵改为 `inputs.targets`（JSON）驱动（add08c35），
  run 41620846897 只编 epyc7002 7.4/7.1，9分28秒全绿；产物 `nf_socket_ipv6.ko` /
  `nf_tproxy_ipv6.ko` 的 UND 与 RR 成品**逐符号一致**（9 条 / 13 条，含依赖 `ipv6`）。
- 2026-11-03：端到端回归用临时 Release `test-modules-26.11.0`（预发布，只含
  epyc7002 7.4/7.1 打包产物，非正式发布）；ova-test run 41622951773
  （ainas/SA6400/预装/base 关闭/全量）5分25秒全绿：
  `total=495 loaded=79 ok=399 fail=17`，4 个模块全部 `INSMOD_OK`
  （nf_socket_ipv6 #250、nf_tproxy_ipv6 #252、xt_TPROXY #474、xt_socket #491）。
  495 与正式包 514 的差额 = 发布流程额外合并的 19 个官方模块（本包不含）。
- 2026-11-03：残余 17 失败均为环境/硬件缺失（acpi_cpufreq/binder_linux/ch35x_38x/
  coretemp/cpufreq_userspace/f71882fg/gpio_f7188x/gpio_it87/gpio_sch311x/intel_idle/
  ipmi_si/it87/kvm_amd/kvm_intel/nct6683/nct6775/syno_hddpwrctl_test），无 Unknown symbol。
- 2026-11-03：4 型号（4.x）验证 run 41624753391：DS918+（459 条 loaded=90 ok=354 fail=15）、
  DS3622xs+（418 条 loaded=72 ok=333 fail=13）全量跑通；DS920+/DS923+ 卡死（串口驱动 exit 13）。
  根因：`scsi_debug` insmod 产生假 SCSI 盘 → `sd_probe → redpill sd_probe_shim` →
  官方 4.4.302 内核 `syno_usb_info_enum+0xa6` 空指针 Oops（0xe0），insmod rc=137，
  随后 `sr_mod` insmod 永久挂起。各平台 scsi_debug.ko srcversion 相同
  （533BB7E5866E52F63B9ACCB），官方 hda1 包不含该模块，RR 带但 loader 不自动加载
  （`N scsi_debug.ko`）→ 属官方内核缺陷 + 测试专用触发，非我方编译问题。
- 2026-11-03：新增 `.github/scripts/modtest/known-hazards.tsv`（platform/module/原因），
  `make_module_list.sh` 增加可选平台参数并置 policy=hazard，
  guest 对 hazard 输出 `SKIP_HAZARD` 且绝不 insmod；ova-test.yml 与 prepare_prebuilt.sh
  两处调用传平台（commit 7127a427）。本地验证：geminilake-7.3/r1000-7.3 清单
  scsi_debug=hazard（1 条），broadwellnk 不受影响（0 条）。
- 2026-11-03：触发 ova-test run 41643536367（ainas、DS920+/DS923+、预装模式、
  modules_version=test-modules-26.11.0、全量）验证豁免。

## rr 预处理阶段生成全型号升级包（2026-11-05）

实现：
- [x] `rr.yml` 的 `prepare-base` 增加“全型号升级包”流程：在 p3 尚未按型号裁剪时
      用 `pack_update` 生成 `updateall-<RR 版本>.zip`（含所有型号的 lkms/modules/cks/addons）。
- [x] base 复用（未重建）而升级包缺失时，下载公共 base 解压为 `rr/rr.img` 再打包。
- [x] 复用策略：rr/2in1 的 `overwrite_base`、`overwrite_update`（rr 另有 `overwrite_updateall`）
      合并为单个 `overwrite`，默认不覆盖，同时作用于 base、按型号包、全型号包与原版镜像。
- [x] `build_rr_original` 输入删除：rr 的 matrix 始终包含 `__RR_ORIGINAL__`；Release 已有
      `<品牌>-<RR 版本>.img.zip` 时该 job 默认跳过，勾选 `overwrite` 才重新编译。
- [x] 打包后删除 `rr/rr.img`、上传 base 后删除本地副本，降低同 job 磁盘峰值。
- [x] 本地校验 YAML 解析、run 块 bash 语法；复用判定三态单元测试通过。
- [x] CI 首次运行 run 41976503824 暴露：pack_update 产物与目标同名时 `mv` 报
      "are the same file" 退出 1；已改为仅名称不同时改名。

验证（本地真实镜像 26.10.42，未裁剪的官方 rr.img）：
- [x] `pack_update` 产出 `updateall-26.10.42.zip`（1.7 GiB，< 2GB 不需分卷）。
- [x] 包内含 update-list.yml/update-check.sh/RR_VERSION、p1 引导文件、bzImage-rr/initrd-rr，
      以及 cks.tgz（epyc7002/geminilakenk/r1000nk 等全平台）、lkms.tgz（17 个平台 214 个文件）、
      modules.tgz（74 个平台/DSM 版本包）、addons.tgz，确认 p3 未被裁剪。

CI 验证：
- [x] run 41976857789（修复 mv 后）：base 复用、全型号包缺失 → 下载 base 还原 rr.img、
      打包并上传成功，Release `ainas-rr-26.11.1` 出现 `updateall-26.11.1.zip`（1.69 GB）。
- [x] run 41978110420（选项合并后，overwrite=false）：prepare-base 的 base/全型号包检查
      均判定复用并跳过全部构建步骤；原版镜像 job 检测到 `ainas_rr-26.11.1.img.zip` 已存在，
      按预期跳过编译与发布。

# Task#221 全平台 SCSI/SAS 不崩 + 启动日志 LKM 异常核对（2026-11-05）

## 背景
用户要求：所有平台全部跑一遍测试，加挂 SCSI/SAS 硬盘验证驱动不崩；同时核对所有平台
启动日志里是否有模块/LKM 异常。口径：官方 13 平台 + custom 4 平台（DSM 7.3.2）、
SCSI 只跑 SAS 两型（megaraid + mptsas）、崩溃硬失败/识别问题先报告。

## 计划与进度
- [x] 1. `scsi_profiles` 新增「仅 SAS 两型」（megaraid mptsas）
- [x] 2. `probe.commands` 增加结构化采集（`@@SCSIHOST|`、`@@BLK|`）与启动期异常 grep
- [x] 3. `gate_common.py`：按路径加载 parse_results 正则与白名单 + 命令回显过滤
- [x] 4. `check_scsi_result.py` + `scsi-models.tsv` + `scsi-allowlist.tsv`：
      G-S1 采集完整性 / G-S2 崩溃（模块归属不豁免，内核归属需 RR 对照证据）/
      G-S3 驱动加载 / G-S4 proc_name / G-S5 测试盘识别（后三项只报告）
- [x] 5. `check_bootlog.py` + `bootlog-allowlist.tsv`：硬失败=崩溃/Unknown symbol/
      真 vermagic/GPL-only/Loading modules failed；BUILTIN_DUP 按 env-fail-allowlist
      降级；firmware/modprobe/taint/WARNING 只报告；空采集硬失败
- [x] 6. `platform-representatives.tsv` + `plan_test_sources.sh` 的 `all_platforms`
      （13 官方 + 4 custom，broadwellntbap 显式排除；与 models.json 双向覆盖校验）
- [x] 7. `ova-test.yml` 接入：`all_platforms`/`run_bootlog_gate` 输入、两个门禁步骤
      （always()）、plan 阶段两个 selftest、artifact 追加 `/tmp/bootlog-check`
- [x] 8. 本地验证：两个脚本 selftest 全过；历史 artifact 回放
      （SA6400 全 PASS；mptsas 2G 盘未识别只报告）；4.4.302 DS918+ 安装日志回放
      只命中 TAINT/MODPROBE_MISSING/gpio WARNING（均只报告）
- [ ] 9. CI 冒烟：SA6400 + 仅 SAS 两型 + run_bootlog_gate
- [ ] 10. 全矩阵：官方 13 平台、custom 4 平台（use_prebuilt=false、run_bootlog_gate=true）
- [ ] 11. panic 平台逐个 RR 对照（RR 复现同栈才登记 scsi-allowlist）
- [ ] 12. 收口：环境性启动日志噪声登记 bootlog-allowlist；模块内崩溃按源码修复

## 关键事实
- 4.4.302 `sd_probe` 经 DSM 定制 `syno_usb_info_enum` 在非 USB SCSI host 上解引用
  NULL（v1000/broadwellnkv2/purley 已登记 env-fail-allowlist），SAS 盘走同一路径，
  三平台预计 panic，需 RR 对照。
- apollolake 4.4.302 包内无 coretemp/k10temp（RR 同样没有），启动脚本加载失败属
  环境性，第一轮只报告。

# 2in1 全平台升级包（2026-11-05）

## 变更
- [x] `2in1.yml` 输入合并为单个 `overwrite`（base + 全平台升级包，默认复用）。
- [x] `prepare-base` 新增 `check_update`：Release 已有 `updateall-<RR 版本>.zip`（或
      `.part.000`）且未勾选覆盖时跳过，否则生成。
- [x] 新增「生成全平台升级包（不裁剪 p3）」：base 已重建直接用 `rr/rr.img`，否则从
      Release 下载公共 base 解压还原；`pack_update ... "2in1"` 打包后删除本地 img。
- [x] 新增「上传全平台升级包到 Release」，复用 `release_publish.sh` 的分卷/重试/覆盖。
- [x] 删除 base 构建末尾的 `rm -rf "$AINAS2IN1_DIR"`（升级包步骤仍需 source 该目录），
      改为上传 base 后删除本地副本；下载 RR zip 解压后立即删除。
- [x] YAML 解析 + 全部 run 块 `bash -n` 通过（2in1.yml、rr.yml）。

## 待验证
- [ ] CI 触发一次 2in1（自选单型号、overwrite=false）：确认 base 复用、updateall 缺失时
      下载 base 打包并上传到 `ainas-2in1_<版本>` Release。
