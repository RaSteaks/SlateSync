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

---

## 施工包元数据与执行状态

> **施工包状态：READY FOR IMPLEMENTATION — DOCUMENT ONLY**
>
> 以下内容是 Phase 04 的详细施工包。本次只生成文档，不执行源码修改、测试、
> 构建、Electron、真实文件保存、Project Library 写入或 Git 操作。

- 施工分支：feat/electron/accuracy-csv
- 上游门禁：Phase 01 已冻结 ProjectSettings v2/ExportOptions；Phase 02 已冻结
  canonical field value 和 review metadata；Phase 03 已提供统一 semantic table
  builder、Worker payload 与编码错误边界。
- 本阶段目标：在 modern/legacy 中提供同一套导出配置和预览体验，且 options 的
  来源、生命周期和保存行为可解释。
- 下游交接：Phase 05/06 只消费 effective project/session settings，不再依赖
  UI 内部状态；Phase 07 需要 modern/legacy parity 证据。

## 施工目标与非目标

### 必须完成

1. modern 与 legacy 以同一 ExportOptions 字段 key、默认值、校验和文案语义提供
   导出控制。
2. 明确 system default、project default、session override 的优先级和生命周期：
   当前会话覆盖值 > 项目默认值 > 系统默认值。
3. 导出预览和最终下载都调用 Phase 03 的同一 Worker builder，并对同一 effective
   options 生成表格与 bytes。
4. modern 项目设置页和 legacy 项目设置表单读取/保存 export 分支，保存后不丢失
   未展示的未知字段。
5. 实现纯 filename template resolver，支持 project/source/date/time，过滤路径
   分隔符、控制字符和非法文件名字符，测试可注入固定时间。
6. 任务切换、任务恢复、项目切换和保存项目默认值都有明确的 state reset/merge
   行为，不允许隐式沿用上一个任务的导出状态。

### 明确不做

- 不在 UI 中重新实现 CSV 解码、字段归一化、semantic table 或编码算法。
- 不改变 Phase 03 默认 CSV bytes、Resolve source table 的非目标列和 Worker error
  contract。
- 不把 session override 自动写入 ProjectSettings，除非用户明确点击保存项目默认。
- 不添加新的 IPC channel；文件保存继续使用现有 files API。
- 不在本阶段启用 OCR alternatives、图像增强或 crop recheck。
- 不因导出选项 UI 重建 v1 ProjectSettings 或丢弃未知 JSON-safe branch。

## 实施前门禁与允许路径

执行前必须记录 branch、status、上游 Phase 03 验收结果和工作区已有 diff。本次不执行。

允许修改：

- src/renderer/features/export/ExportOptionsPanel.tsx（新增）
- src/renderer/state/export-store.ts 与对应 state types
- src/renderer/features/workspace/WorkspacePage.tsx
- src/renderer/features/settings/ProjectSettingsPage.tsx
- src/renderer/features/settings/projectSettingsActions.ts（如需保存 action 接线）
- src/renderer/features/settings/GlobalSettingsPage.tsx 仅在系统默认展示需要时
- public/index.html、public/app.js、public/styles.css
- src/shared/contracts/index.ts、public/task-persistence.js 的可选 snapshot 类型
- 新增共享 filename/options pure helper 及相关测试
- modern/legacy export、settings、task persistence 测试

禁止扩大：

- electron/IPC channel、SQLite schema、Provider/OCR、默认 Project Library。
- Phase 03 builder 内部的语义/编码实现；若 UI 需要绕过 builder，必须停止。

## 当前基线事实

| 区域 | 当前事实 | Phase 04 施工要求 |
| --- | --- | --- |
| modern export store | 当前保存 table、previewTable、filename、edits、CSV records、processing 和 error，没有 ExportOptions/session override。 | 增加 options/session override、effective options 或可审计的等价状态，并清理 task/project 生命周期。 |
| WorkspacePage | 当前使用 settings.resolve.fieldFormats/comments，文件名临时拼接，Worker export payload 尚未带 ExportOptions。 | 调用统一 effective options，预览/导出用同一 request builder；文件名由纯函数解析。 |
| ProjectSettingsPage | 已有 v2 export 默认 merge，但页面目前主要展示识别、Resolve 格式和项目包。 | 增加 export 面板或 section，保存时以当前完整 settings 为基底。 |
| legacy | public/index.html 有下载按钮和结果预览；public/app.js 有 legacy 项目设置构造和导出流程。 | 等价控件、同一 key/default/filename 函数、保留 export/unknown branches。 |
| task restore | task persistence 已保存 metadataTable/sourceEncoding/csvEdits 等可选数据。 | session options 作为可选任务快照保存或明确 reset；两者必须在文档和测试中固定。 |

## 配置优先级与生命周期

### 三层模型

固定以下来源：

1. system default：DEFAULT_EXPORT_OPTIONS 的不可变副本；
2. project default：ProjectSettings.export，经过 Main/shared normalize；
3. session override：当前工作台临时修改，默认不改变项目设置。

effective options 只能由共享纯函数计算：

~~~text
effective = normalizeExportOptions(
  sessionOverride ?? project.settings.export ?? DEFAULT_EXPORT_OPTIONS
)
~~~

要求：

- 每次计算得到新对象；禁止把 DEFAULT_EXPORT_OPTIONS 或项目 settings 原对象直接
  作为可变 draft。
- columns 按 ExportColumnKey 去重，保留合法顺序和用户排序策略；header 统一
  校验；format 只接受三个输出编码。
- 非法值回退到上一层合法值，再回退系统默认；不能在 modern/legacy 分别定义
  不同 fallback。
- session override 只保存用户实际改动的 patch 或完整 normalized options，但
  必须能区分“未覆盖”和“覆盖为空/关闭”。

### 任务切换策略

采用明确、可测试的规则：

- 切换到另一任务时，清空当前任务的 session override，并以目标项目默认值
  初始化新任务。
- 若任务快照中明确保存了 exportSessionOptions，则恢复该快照的 override；
  该字段缺失的旧任务按项目默认处理。
- 切换回原任务时只恢复该任务快照中的显式 override，不从上一个任务的内存 store
  继承。
- 切换项目时先清空旧 session override；新项目 settings 经过 normalize 后再生成。
- 点击“恢复默认”只恢复 system/project 层定义的默认，必须在 UI 文案中说明是
  “本次会话恢复默认”还是“项目默认恢复默认”，两者不能混淆。

### 保存项目默认

- 用户点击保存项目默认时，将当前 effective options 经 shared normalize 后写入
  ProjectSettings.export。
- 保存成功后以 Main 返回的完整 settings 作为 baseline，并清除 session override；
  保存失败保留 draft 和 session override。
- legacy buildProjectSettingsFromForm 从 current settings 展开，只更新可见字段，
  不重建 columns 数组、不清除未知 export branch。
- 保存项目默认不是自动发生的；导出按钮不改变项目设置。

## ExportOptionsPanel 施工设计

### modern 结构

新增 src/renderer/features/export/ExportOptionsPanel.tsx，面板只负责：

- 读取当前 project default 和 export-store session override；
- 调用 shared normalize/options helper；
- 发出 setSessionOptions 或 saveProjectDefault 回调；
- 触发 preview refresh，不直接读写 Worker；
- 显示 preview/error/loading/accessibility 状态。

建议控件：

1. semantic columns：checkbox enabled、header input、顺序控制；
2. output encoding：UTF-8、UTF-16LE、UTF-16BE；
3. BOM、delimiter、line ending、final newline；
4. filename template；
5. “恢复本次默认”“保存为项目默认”；
6. 当前 effective source 标签：系统默认/项目默认/本次会话。

行为规则：

- columns key 永远不可编辑；header 可以编辑但必须在 blur/submit 时校验。
- 至少保留一个 enabled column；默认四列仍为 Scene、Shot、Take、Comments。
- 预览更新使用 debounce 或 operation token，旧请求返回不能覆盖新 options。
- 选项修改期间若 Worker 正在处理，保留当前 preview，显示 processing，不清空
  已有结果；错误只显示在面板，不破坏 table/edits。
- 输入框和 select 必须可键盘操作；非法 header 给出字段级错误，不静默回退。

### WorkspacePage 接线

- WorkspacePage 计算 effectiveOptions，并把同一对象传给 merge-preview 和
  export-resolve/export-standalone。
- export state 保存 options、preview request id、processing 和 error；页面卸载
  或路由切换时取消/忽略过期 preview。
- effective filename 根据 source/project/task context 解析后传给 Worker/file save，
  原始 template 和 resolved filename 分开保存。
- export button 的 canExport 只依据当前有效 table/records、options 和 processing；
  options 错误时禁用导出并给出原因。
- source CSV 的 sourceEncoding 只展示为输入事实，不能被 output encoding select
  误修改。

## legacy UI 施工设计

### 页面控件

在 public/index.html 的结果/导出区域增加与 modern 等价的控件：

- 列启用和自定义表头；
- encoding/BOM/delimiter/line ending/final newline；
- filename template；
- 当前会话恢复默认和保存项目默认；
- effective source 和错误提示。

控件 ID 和 data-key 必须以 ExportColumnKey 为语义，不以中文/英文表头判断。

### public/app.js 状态

- state 增加 exportOptions/sessionOverride/effectiveOptions/exportOptionsError/
  exportOptionsRevision。
- resetRecognitionResults、switchTask、restoreTask、clearResolveCsv 和项目切换
  明确处理这些字段。
- legacy 的 preview refresh 和 exportCsv 均调用 Phase 03 Worker task，不能保留
  旧的直接拼 headers/rows 分支。
- buildProjectSettingsFromForm 继续从 current settings 展开，并保留 export 及
  未知字段；project default save 成功后使用 Main 返回的完整 settings。
- legacy fallback 与 modern 使用同一个 filename/options module；如果浏览器脚本
  不能直接 import TypeScript，只能 import public-side ESM helper，不能复制算法。

## 文件名模板纯函数

建立可在 Node、modern、legacy 测试的纯函数，职责等价于：

~~~js
resolveExportFilename(template, context, clock)
~~~

支持 token：

- project：项目名称；
- source：源文件去扩展名的 base name；standalone 无 source 时使用场记标题或
  预设 fallback；
- date：本地时间 YYYY-MM-DD；
- time：本地时间 HH-mm-ss。

规则：

1. token 未知时保留文字还是报错必须固定；建议保留 token 文字并在校验提示中标记
   未知 token，最终文件名不能包含花括号控制语义。
2. 过滤 slash、backslash、冒号、控制字符、NUL 和 macOS/Windows 禁止字符；
   合并连续空格，去除首尾点/空格。
3. 禁止解析为绝对路径或包含父目录跳转；输出只能是 basename。
4. 空 template、过滤后为空、保留名冲突由调用方使用稳定 fallback，不覆盖用户
   选择的 output encoding。
5. clock 必须可注入；测试不能依赖系统当前时间。
6. source/project 中的 Unicode 中文保留；只过滤文件系统控制字符，不做无依据
   拼音或大小写转换。

默认 template 仍为 {source}_场记识别.csv；Resolve merge 可使用
{source}_场记已回填.csv 的产品默认，但必须在 effective options/文案中明确，
不能由 export mode 隐式改写用户已保存 template。

## 项目设置与兼容性

- ProjectSettingsPage 的 draft 以 settingsForDraft 的完整 v2 结果为基底，export
  columns、format、filenameTemplate 通过 shared normalize。
- 保存时仅提交完整 v2 settings；Main 端仍是最终兼容真相。
- legacy settings 表单不显示的 export future fields 必须通过展开 current settings
  保留；不可使用 Object literal 重新列出已知字段。
- v1 读取后展示系统默认 export；用户保存后写 v2，但不能删除 unknown top-level
  或 nested branch。
- task snapshot 的 exportSessionOptions 为可选；旧任务恢复不报错。

## 测试矩阵

### shared pure tests

- 三层 priority：session > project > system。
- session 显式关闭列、空 header、非法 encoding、重复 key、全部关闭时结果稳定。
- template token、固定 clock、路径字符、控制字符、空值和 Unicode 文件名。
- modern/legacy 传入同一 fixture 得到深相等 effective options 和 filename。

### modern tests

- panel 渲染默认列/格式，修改后 preview request 带同一 options。
- debounce/operation token 丢弃旧 preview。
- 保存项目默认后 session override 清除，返回 settings 进入 store。
- 切换任务清理旧 override；带 explicit snapshot 时只恢复目标任务 override。
- 面板错误不清空 table/edits，保存失败保留 draft。

### legacy tests

- public/index.html 控件存在且 data-key 使用 semantic key。
- public/app.js 旧项目保存保留 export 和 unknown branches。
- legacy 预览/最终导出请求和 modern 相同 options，filename resolver parity。
- 任务恢复、清除 CSV、项目切换不泄漏上一个任务的 override。

### integration

- Phase 03 baseline default bytes unchanged。
- 自定义 header 在保存/恢复/Worker round-trip 后仍映射正确 key。
- preview table 与最终 bytes 的 headers/rows/format 深相等。
- output encoding 与 sourceEncoding 分离。

推荐命令：

~~~sh
npm run check
npm run typecheck
npm run test:node
npm run test:modern
npm run validate:modern
git diff --check
~~~

## 停止条件、回滚与交接

必须停止的情况：

- UI 直接拼 CSV 或直接通过表头判断字段；
- preview 与最终 export 的 options 不同；
- 项目保存丢失 export/unknown fields，或 v1 任务恢复失败；
- 切换任务后出现隐式 session override；
- filename resolver 产生路径、控制字符或依赖系统当前时间而无法复现；
- Worker 旧请求覆盖新预览，或选项错误清空原 table/edits；
- 需要新增 IPC/数据库 schema。

回滚只撤销 Phase 04 UI、state、helper 和测试改动，不清理 Phase 01–03 的成果。

交给 Phase 05 的状态：

- modern/legacy 都能产生同一份 effective ExportOptions；
- ProjectSettings、task snapshot 和 session override 生命周期有真实测试；
- export UI 不改变 OCR 输入、quality、targetId 和 CSV backend；
- Phase 05 可安全增加 OCR summary/processing telemetry，而无需修改导出配置真相。
