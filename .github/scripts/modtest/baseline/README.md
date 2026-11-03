# 模块测试基线

文件名：`<platform>-<line>-<kver>-<kernel>.json`，例如
`epyc7002-7.4-5.10.55-official.json`。

门禁脚本 `parse_results.py` 比较两类集合：

1. **失败集合**（`failures`，仅白名单之外的真实失败）
   - 当前失败不在基线中 → `G-M6` 失败（新增失败必须解释后修基线）；
   - 基线中的失败已消失 → 仅告警并写入 summary（防无声放水）；
   - 基线缺失 → 只按白名单判定，仍会输出 `*-baseline-candidate.json`。
2. **安装集缺口**（`install_gap`：包内有但系统安装目录没有的 .ko 名）
   - 预装成品 OVA 模式的 `G-M5` 只告警（镜像模块来自 base rr.img 的构建，
     与测试包不要求同源）；
   - 非预装模式的 `G-M5` 要求"缺口相对基线无新增"，存量缺口是
     DSM 只安装映射子集的结构差异，不能用全量相等当判据。

基线文件由首次全量通过后的候选文件转入：

1. 从 ova-test artifact 取 `modtest-logs/modtest-result-baseline-candidate.json`；
2. 人工确认其 `failures` 为空（或仅含已解释的历史缺陷），`install_gap`
   里的条目都是已知的安装子集差异；
3. 改名放入本目录并提交。

`module_count` 用于防止清单被截断后基线自动"变绿"；`--module-limit > 0`
（smoke 测试）时脚本不启用基线比较。
