# Task#215 模块逐测 OVA 测试工作流（基于 ova.yml 复制）

## 背景
参考 `ova.yml` 的"生成群晖系统 + 重现安装"链路，复制一份测试工作流：安装一次 DSM 后保存预装镜像，
逐个 insmod 自编模块（安全档），并用 SCSI 虚拟设备矩阵重启采集启动日志，最后与 RROrg 源做启动日志对比。
阶段 1 只跑 SA6400（epyc7002 / 5.10.55），跑通后扩到 7 个通用型号。

## 计划
- [x] 1. `.github/scripts/plan_test_sources.sh`：包装 plan_sources.sh，支持 ainas/RROrg/both，
      补充 platform/kver/modules_key，输出 base_tasks/tasks
- [x] 2. `.github/scripts/make_module_disk.sh`：解包模块包 → modinfo 清单 + 拓扑排序 +
      vermagic 与目标内核比对（fail fast）→ ext4 模块盘，可选条数上限
- [x] 3. `.github/scripts/modtest/guest/run-module-tests.sh`：guest 侧挂盘（LABEL=MODTEST）、
      安全档逐模块测试（已加载只记录、不 rmmod）、逐条 sync + progress
- [x] 4. `.github/scripts/modtest/run_profile.sh` + `render_test_compose.sh`：复用已安装的
      rr.img + data.qcow2 启动，按 profile 注入 SCSI 设备/模块盘，串口采集后回读结果
- [x] 5. `ainas-2in1/script/dsm_serial_driver.py`：向后兼容 `exec` 子命令
      （commit bd4432a，已推送）
- [x] 6. `.github/workflows/ova-test.yml`：复制 ova.yml，base 改用 artifact、不写 Release、
      安装一次后多 profile 复用预装镜像
- [x] 7. 本地静态校验：YAML 解析、bash -n、sh -n、py_compile、真实模块包生成模块盘验证
- [ ] 8. CI smoke：单型号单源跑通（SA6400 × ainas）
- [ ] 9. 阶段 2：双源 + SCSI 3 型 + 启动日志归一化 diff

## 进度
- 2026-11-03：脚本与 workflow 落地；本地用 epyc7002-7.4-5.10.55（495 个 .ko）生成模块盘通过，
  拓扑序（mii→8139cp）正确，vermagic 校验通过。
- 2026-11-03：触发 `ova-test.yml` smoke（rr_source=ainas、test_models=SA6400、
  scsi_profiles=跳过、run_module_test=true、module_limit=20），run 41564874040：
  plan 与 prepare-base 通过，install+test 进行中。
- 修复记录：plan 合并误用未输出的 repo 字段；run_profile 相对路径导致 cd 后找不到渲染脚本；
  Web 就绪判据改为「拿到 HTTP 状态行」。

## Review
（完成后补写）
