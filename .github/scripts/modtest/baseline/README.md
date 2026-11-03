# 模块测试基线

文件名：`<platform>-<line>-<kver>-<kernel>.json`，例如
`epyc7002-7.4-4.4.302-official.json`。

门禁脚本 `parse_results.py` 只比较"白名单之外的真实失败集合"：

- 当前失败不在基线中 → `G-M6` 失败（新增失败必须解释后修基线）；
- 基线中的失败已消失 → 仅告警并写入 summary（防无声放水）；
- 基线缺失 → 只按白名单判定，仍会输出 `*-baseline-candidate.json`。

基线文件由首次全量通过后的候选文件转入：

1. 从 ova-test artifact 取 `modtest-logs/modtest-result-baseline-candidate.json`；
2. 人工确认其 `failures` 为空（或仅含已解释的历史缺陷）；
3. 改名放入本目录并提交。

`module_count` 用于防止清单被截断后基线自动"变绿"；`--module-limit > 0`
（smoke 测试）时脚本不启用基线比较。
