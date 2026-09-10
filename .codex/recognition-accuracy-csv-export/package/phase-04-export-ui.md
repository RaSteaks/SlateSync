# Phase 04：modern/legacy 导出界面

## 目标

在两套 Renderer 中提供一致的导出选项、预览和项目默认配置管理。

## 配置优先级

```text
当前会话覆盖值 > 项目默认值 > 系统默认值
```

切换任务时，会话覆盖值应明确清除或继承，不能产生隐式状态。

## 主要任务

### 1. modern Renderer

- 新增 `ExportOptionsPanel`。
- 在 `export-store` 保存会话级配置。
- 在 `WorkspacePage` 中计算 effective options。
- 预览刷新和最终导出使用相同 options。
- 支持保存为项目默认。

### 2. legacy Renderer

- 在 `public/index.html` 增加等效入口。
- 在 `public/app.js` 复用相同字段和默认值。
- 不允许 legacy 保存逻辑重新生成 v1 设置并丢弃 `export`。

### 3. ProjectSettings 接入

- modern 项目设置页读取并保存 `export`。
- legacy `buildProjectSettingsFromForm` 保留现有设置分支。
- 保存项目默认值时使用共享归一化逻辑。

### 4. 文件名模板

实现纯函数处理：

- `{project}`
- `{source}`
- `{date}`
- `{time}`

必须过滤路径分隔符、控制字符和非法文件名字符，并为测试注入固定时间。

## 重点文件

- `src/renderer/features/workspace/WorkspacePage.tsx`
- `src/renderer/features/settings/ProjectSettingsPage.tsx`
- `src/renderer/features/export/ExportOptionsPanel.tsx`
- `src/renderer/state/export-store.ts`
- `public/index.html`
- `public/app.js`

## 验收标准

- modern 和 legacy 选项名称、默认值、输出结果一致。
- 修改选项后预览立即同步。
- 保存项目默认值后重新打开项目仍然生效。
- 旧项目设置不会因为导出界面保存而丢失字段。
- 文件名模板在不同导出模式下含义明确且可测试。
