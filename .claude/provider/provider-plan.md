# Better Provider 完整方案（单一方案 · 一次执行）

> 状态：方案已保存（2026-09-24）；开工后用户叫停，**未产生任何代码改动**，再次执行需用户明确批准。
> 本文档是 feat/better-provider 分支上 Provider 体系改造的唯一方案文件，
> 合并此前全部讨论结论：cc-switch 配置模型吸收、国内 Provider 预设库（11 家已逐一核对官方文档）、
> 全局默认与快速切换、OpenAI 兼容通道、输出规范化层、故障转移，以及对应的 UI 重设计。
> 2026-09-24 方向修订：本轮仅更新方案，尚未开始代码实施；主备组合、配置阶段验证、队列回退以本文修订条款为准。
> 执行纪律：不做 P1–P5 分批征询；全部条目按本文件一次性实施；每步遵守 AGENTS.md（编辑后补注释）与
> 本地化审查（English.json + audit_localization.py）。

---

## 0. 设计不变量（全程有效）

1. **数据合同不动**：原始识别输出永不改写；位宽规范化只作用于成功匹配字段；
   手工稀疏编辑逐字保留。规范化层只做"文本修复 + 宽松解码 + 报告"，不改字段语义规则。
2. **冻结面不破**：`RecognitionPrompts` 逐字 oracle、`RecognitionNormalizer` 既有归一化结果、
   `ProviderKind` 冻结 wire ID、`CustomProviderConfiguration` 旧字段别名解码全部保持；
   新能力一律以"可选字段 + 默认值 + 向后兼容解码"进入。
3. **单一机制**：业务提示词只有一份（RecognitionPrompts）；输出契约只有一份 Schema，
   按档位（json_schema / json_object / prompt）投影；厂商差异只存在于
   ①descriptor.jsonMode（持久化、预设建议、探针验证）②通用 JSON 文本修复阶梯。不写死任何厂商结论。
4. **探针驱动**：能力结论来自 `capabilityCache` / 发现与验证流程；预设里的档位只是"建议初值"。
5. **UI 主题不变**：Slate Workbench 冷灰 + 钨丝琥珀；琥珀只用于主操作/焦点/进行中；
   "默认"标记与来源徽章用中性灰文字；不单靠颜色表达状态；不新增主题色；不写局部 RGB/圆角。

## 1. 领域层（Sources/SlateSyncDomain）

| 变更 | 说明 |
| --- | --- |
| `CustomProviderConfiguration` += `notes: String?`、`sourcePresetID: String?` | 均可选 + 默认 nil + decodeIfPresent/encodeIfPresent；v2 配置文件照常解码；CustomProviderSummary 透出 |
| `GlobalSettingKey` += `defaultProviderID`、`defaultModelID`、`recognitionFailoverChain` | 全局默认组合与备用组合列表；链使用 JSON 数组保存有序 `{providerID, modelID}`，允许跨 Provider 换模型。validator 校验组合完整性、重复项和长度；空 = 未设置，旧配置不自动启用备用 |

## 2. 传输层（URLSessionProviderTransport）

- 保留现有 OpenAI 兼容认证与 OpenRouter 头逻辑，本轮不增加 Anthropic 原生协议。

## 3. 工作流层（Sources/SlateSyncWorkflow）

### 3.1 Provider 预设库（ProviderPresets.swift，新增）

纯编译期内置目录；预设 = CustomProviderSheet 的预填模板，不产生新 provider 类型，wire 合同零改动。
每条含：id、名称、分类（直连/聚合中转）、baseURL、transport、建议 jsonMode、建议模型 ID（仅在已核实处预填，
其余留空并以备注引导）、官网/取 Key/文档链接、备注（quirk 摘要，来自 2026-09 逐家文档核对）：

| 预设 | Base URL | 档位建议 | 备注（写入预设） |
| --- | --- | --- | --- |
| 阶跃 StepFun | https://api.stepfun.com/v1 | json_schema | 全档兼容最干净 |
| 硅基流动 SiliconFlow | https://api.siliconflow.cn/v1 | json_schema | 全档兼容；模型以 /models 为准 |
| 火山方舟 Volcano Ark | https://ark.cn-beijing.volces.com/api/v3 | json_schema | 模型 ID=推理接入点，需手动填；早期模型不支持结构化输出（自动降档兜底） |
| DeepSeek | https://api.deepseek.com/v1 | json_object | jsonObject 档；prompt 已含 JSON 字样满足其要求；模型 deepseek-flash |
| Kimi（月之暗面） | https://api.moonshot.cn/v1 | json_object | vision 系列；模型以服务端为准 |
| 智谱 BigModel | https://open.bigmodel.cn/api/paas/v4 | json_schema | 待实测项：data URL 前缀、VLM×response_format；失败会自动降档 |
| 百度千帆 | https://qianfan.baidubce.com/v2 | json_schema | VL×json_schema 待实测；自动降档兜底 |
| 腾讯混元 | https://api.hunyuan.cloud.tencent.com/v1 | prompt | 兼容表无 response_format；兼容接口域名为 api.hunyuan.cloud.tencent.com（2026-09 官方文档核对；api.hunyuan.tencentcloudapi.com 是 API 3.0 签名域名，勿用） |
| MiniMax | https://api.minimax.io/v1 | prompt | 标准兼容端点已核实，无 response_format |
| AiHubMix | https://aihubmix.com/v1 | json_schema | 聚合中转；透传上游 |
| 302.AI | https://api.302.ai/v1 | json_schema | 聚合中转；端点标准，视觉/结构化透传待实测 |

### 3.2 配置阶段验证与协议边界

- 配置 Provider 后，对拟使用的模型完成视觉输入和结构化输出验证；主选与备用均只允许使用当前配置下已验证的模型，任务中不探测未验证模型。
- 探针记录模型实际成功的 JSON 档位，写入结果、能力缓存及 Registry 投影；识别从该有效档位开始。
- 地址、密钥、协议及影响请求的设置改变后，旧验证失效；名称、备注等展示字段变更不使验证失效。异步探针结果必须校验配置版本，防止旧结果覆盖新配置。
- 本轮只使用现有 OpenAI 兼容协议。不增加 Anthropic 原生 transport、认证、payload、提取或官方 API 预设；只有确认现有协议无法满足目标服务时，才另行评估原生接入。

### 3.3 输出规范化层（RecognitionOutputRepair.swift，新增）

- `JSONTextRepair`：字符串感知状态机（非逐字符正则蛮干）。步骤：去 BOM → 剥 Markdown 围栏 →
  提取最外层平衡 JSON 对象（忽略字符串内部花括号）→ 仅在结构位做智能引号归一 → 移除尾逗号。
  字符串字面量内部的引号/花括号永不动。每步产出 RepairAction 审计项。
- `TolerantStructuredJSON.decode`：原始解析 → 修复后解析 → 抛 invalidStructuredJSON；
  返回 (JSONValue, [RepairAction])。`ProviderRecognitionClient.structuredJSON(from:)` 改为走该阶梯
  （原行为 = 阶梯前两步的子集，探针与识别同享收益）。
- `RecognitionNormalizer.normalize(_:pageNumber:report:)` 新增可选 report 出参：字段存在于原始 JSON
  但规范化失败 → 记为 degraded 字段。默认参数版行为逐字节不变（冻结测试不破）。
- 管线接线（RecognitionPagePipeline）：degraded 字段并入该页记录的 `reviewRequiredFields`（待人工语义，
  结果页 TakeMark 空心点即现有呈现）；修复动作与降级摘要追加为 sheet warnings（经现有 WarnRow 通道呈现）。
- 自修复预算：把 JSON 解析及必要结构校验纳入 stage 重试边界，不能只在提取响应文本的 client 内捕获外层才产生的 MODEL_JSON。每个 stage 的同档重发预算总计一次，不随降档重置；探针使用自己的输出契约，不套用 records 校验。
- 多对象、截断对象和智能引号歧义拒绝猜测；合法 null/空值不自动视为 degraded。报告绑定具体记录与字段，修复摘要贯穿 primary/audit/review 合并，原始响应不改写。

### 3.4 全局默认（RecognitionCoordinator）

- 解析链：请求参数 > 项目/任务设置 > **全局默认（defaultProviderID + defaultModelID 成对生效）**。
- 按完整 Provider＋模型组合解析优先级，禁止从不同层级拼接不相容组合；两者必须同时非空且已验证可用，否则提示配置问题。

### 3.5 故障转移与队列调度

- 任务界面仅选择主 Provider 与对应模型；备用 Provider＋模型组合及顺序只在全局设置配置。列表显式选择已验证组合，不自动推荐模型。
- `FailoverChain.plan(primary:chain:)` 生成有序候选，去重并排除主组合；Provider 级故障时排除该 Provider 的全部组合。
- 复用现有超时与有界重试配置；超时重试耗尽后确认本轮 Provider 不可用，原子更新共享调度状态。尚未发出的排队页面及排队识别任务在派发时检查状态，自动选择各自全局备用列表中可用的已验证组合，不能继续使用入队时缓存的主 Provider。
- 保留成功页面，仅将失败页面重派。切换模型后重新发送该页完整图片、OCR 证据、提示词、Schema 及复核所需上下文；高精度失败页整组重新执行，不混合新旧模型中间结果，本地预处理结果可复用。
- 已发出的其他请求可完成；它们失败后进入同一回退流程。已被替代的旧尝试取消并失去写入资格：以任务/页/尝试代次校验迟到响应，不能重复完成、覆盖结果或重复落库。网络取消不保证服务端停止计算。
- 旧 Provider 恢复不重启旧任务、不抢回已切换工作，本轮只向备用推进。故障隔离覆盖当前执行与排队批次；队列排空后的新批次可重新尝试首选，不把临时故障永久写成能力验证失败。
- 用户取消与输入错误不触发回退；单页 JSON 错误只在修复预算耗尽后回退该页，不据此判定整个 Provider 故障。其他服务级错误需在实施中列出明确分类，不能把所有异常视为 Provider 故障。
- 主选和所有已配置备用均不可用时，停止自动重试，提示“主服务与备用服务均不可用，请稍后重试或检查设置”；没有备用时提示主服务不可用及配置入口。保留已完成页供本次任务重试复用，不把部分结果标记为全部成功。
- 用户只看到进度、切换状态与最终结果，不增加逐页 Provider 来源展示或永久来源记录。运行时仅保留防止迟到结果写入所需的尝试身份；任务级 provider 字段保留主选择含义，不能将混合页面结果谎称全部由某个备用完成。


## 4. UI 层（Sources/SlateSyncUI）

### 4.1 组件（WorkbenchComponents）

- `CapabilityChip`（与 CredentialChip 并列，四态）：已验证（ok）/ 验证失败（danger）/ 未验证（次级灰）/
  需要注意（warn，读取失败或降档）；符号 + 文字双通道，胶囊复用 slateGlassSurface。
  数据源：自定义 provider 取 capabilityCache 汇总；内建取发现/验证结果计数。
- 不新增任何主题色、圆角、间距 token。

### 4.2 设置 Provider 段（SettingsRootView）

- 两个分区合并为一张统一列表：ProviderRow = 名称 + 来源徽章（内建/预设/自定义，中性灰）+ Base URL（mono）
  + 凭据 chip + 能力 chip + "默认"徽章（中性）；行尾操作保留现有动词。
- "添加 Provider…" 从单按钮变菜单：从预设库添加…（新 PresetPickerSheet）/ 添加内建 Provider…（现有凭据流）/
  添加自定义 Provider…（现有 sheet）。
- PresetPickerSheet：左分类（直连厂商/聚合中转）右列表；详情含备注、链接、建议档位；[使用此预设] 预填
  CustomProviderSheet（凭据留空），保存后行携带 sourcePresetID。
- CustomProviderSheet：增加"备注"字段；保留现有 transport 选择；预设预填支持。
- 行操作（菜单/按钮，全部走现有草稿+保存屏障语义）：设为默认组合；添加到全局备用列表时选择已验证模型；备用组合单独排序，与 Provider 展示顺序分离。
- 顶部新增"默认组合"控制：默认 Provider Picker + 默认模型 Picker（随 Provider 联动，选项来自现有投影）。

### 4.3 工作台（WorkspaceView）

- 服务商/模型 Picker 行尾"设为默认…"菜单动作 + 当前选择等于全局默认时显示中性"默认"小字。
- 工作台仅配置主选，不提供备用选择器；未验证或验证失效的模型不能开始识别，提示前往全局设置完成验证。
- 识别进行中的降档提示由状态栏既有消息通道承载；结果页 degraded/修复信息经 warnings 与待人工标记自然呈现。

## 5. 持久化与兼容

- GlobalConfigStore 零版本号变更：新 setting key 走既有 values 字典；CustomProviderConfiguration 新字段可选。
- notes/sourcePresetID 必须贯穿请求 DTO、validator、配置重建与保存路径；备用列表保存/取消遵循既有草稿屏障。
- 旧配置文件（无新字段、无新 key）解码结果与今日完全一致；`GlobalSettingValues` 未知 key 丢弃行为不变。

## 6. 本地化与文档

- 全部新 UI 文案进 `Sources/SlateSyncUI/Resources/English.json`，跑 `audit_localization.py`；
  Provider 描述走内建翻译通道，用户自定义名称/备注逐字保留。
- `AGENT.md` 顶部追加本轮实施记录；`.claude/ui-design/design-system.md` 组件表增补 CapabilityChip 一行。

## 7. 测试与验收

- WorkflowTests：JSONTextRepair 各步与"字符串内部不误伤"；structuredJSON 阶梯；有效档位缓存与配置阶段验证；
  nextMode 不变；自修复预算一次；normalize report（degraded 字段）；FailoverChain.plan；预设目录不变量
  （ID 唯一、URL 合法、transport 合法）；全局默认解析链。
- 调度集成测试：超时预算耗尽后排队任务转备用；成功页不重跑；失败页完整重发；高精度整页重跑；旧响应迟到被丢弃；并发切换去重；取消无回退；主备全失败提示；未验证组合不派发；新批次可重试主选。
- PersistenceTests：notes/sourcePresetID 往返 + 旧文件无字段解码；新 setting key 往返。
- UIUnitTests：CapabilityChip 状态映射；ProviderRow 来源徽章逻辑。
- 验收命令：`swift build` + `swift test`（UI 测试不在本轮门禁内，与仓库现状一致）。

## 8. 明确不做（本轮）

- 不做 cc-switch 式外部配置文件读写（SlateSync provider 是进程内出站连接，本就"热切换"）。
- 不做跨 Provider 的自动模型推荐、价格显示（目录原则：无价格数据）。
- 不新增 Figma 预览页（组件六态约束在实现中遵守，页面补录延后）。
