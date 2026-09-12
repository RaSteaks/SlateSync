# Phase 04–07 回滚开关

按影响范围从新到旧关闭：

1. `SLATESYNC_CROP_RECHECK=false`
2. `SLATESYNC_IMAGE_PREPROCESS=false`
3. `VISIONOCR_ALTERNATIVES=0`
4. 保留 Phase 04 的导出配置与 CSV 兼容层；若仅需撤回 UI，可恢复 session override 并继续使用项目默认值。
5. 不删除旧任务、旧项目设置、OCR cache 或 `targetId`；旧快照按 additive optional 字段继续读取。

所有新开关默认值已保持关闭（crop/preprocess/alternatives），`SLATESYNC_CROP_RECHECK_MAX_TARGETS=12` 只提供预算上限，不会单独触发调用。
