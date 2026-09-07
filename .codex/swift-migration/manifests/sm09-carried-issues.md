# SM-09 遗留问题统一台账（SM-00～SM-08 全部未结项）

建立于 2026-09-07（Owner 指令：所有前阶段遗留问题并入 SM-09 一起修复）。
本文件是**唯一权威遗留清单**；每项含来源、描述、建议处置与状态。修复实施
前不得删除条目；完成后在状态列记录修复提交 SHA。

## 一、代码遗留（计划在 SM-09 内修复，当前全部待修）

### CARRY-01 — OCR wire payload 多次全量 JSON 编解码（审查 #8 剩余部分）
- 来源：SM-07 审查（SM-05/06 代理 P3-3），Owner 当时裁定"只暴露 stderrTail"，
  现按本指令并入 SM-09。
- 描述：`OCRProcessSupervisor.payload`/`envelope` 对大请求（可达 ~80MB 的
  base64 页面数据）全量 JSON decode/encode 3-5 次过手，伴随数百 MB 瞬时内存
  峰值；stderrTail 部分已于本轮修复。
- 建议处置：payload/envelope 单次构造的字节等价重构（splice 或 JSONValue
  树直传），必须以现有 wire 黄金测试 + 新增等价对照测试锁定字节。
- 状态：待修复（建议 WP-1 baseline 之后、WP-6 删除前实施）。

### CARRY-02 — CI timeout 偏紧（审查遗留提示）
- 来源：SM-01/02 审查 P3-10。
- 描述：`ci.yml` `timeout-minutes: 15`，而完整 Gate（swift build/test +
  Xcode Debug + UI Test plan + Release/Archive + npm 全家桶）本地实测
  15-20 分钟，GitHub 托管 runner 更慢；CI 解析器修复后该风险变为现实。
- 建议处置：WP-4 重写 CI 为 native-only 步骤时按实测定值。
- 状态：**已修复**（Owner 指定本项）。`ci.yml` test job 15→60、
  `release.yml` build job 30→60，均附实测依据注释；WP-4/WP-5 重写对应
  workflow 时按 native-only 步骤重新核定。验证：YAML 语法通过，
  sm02 平台契约（断言 workflows 调用共享 Gate 且未硬编码阶段）通过。

### CARRY-03 — createProject 孤儿目录（审查遗留）
- 来源：SM-01/02 审查 P3-9。
- 描述修正（修复时核实）：SM-04（b23a83e）已为 `createProjectWithID` 加了
  失败补偿（`stageOrRemoveUnindexedProject`：删除失败再暂存改名），原审查
  描述的"无清理"在 HEAD 已不成立。修复时发现的真正缺口是：①补偿路径零
  测试覆盖；②补偿无差别删除——调用前已存在于目标路径的目录也会被整目录
  删除（对内部 API 调用方是破坏性的）。`importProject` 路径经核实自身有
  while 循环保证 ID/目录均不存在，无需修改。
- 建议处置：补偿精确化 + 失败注入回归。
- 状态：**已修复**。实现：以 `directoryPreExisted` 存在性检查守卫补偿
  （只删本次调用创建的目录，预存在路径原样保留并上抛原始错误）；
  `createProjectWithID` 改为 internal 供失败注入测试；新增两个回归——
  新建失败后 Projects/ 无孤儿残留、预存在目录及其文件在失败后原样保留。
  验证：SlateSyncPersistenceTests 62/62 通过。

### CARRY-04 — defaultProjectID 悬空契约（审查遗留）
- 来源：SM-01/02 审查 P3-9。
- 描述：`ProjectLibraryStore.defaultProjectID`（"project-default"）参与
  canArchive 判定，但该行仅由 v1 全局数据一次性迁移路径播种，全新 Library
  中不存在对应行。
- 建议处置：核实迁移语义后二选一——文档注释澄清"仅迁移路径产生该行"，或
  在 bootstrap 时保证播种。禁止运行时静默造行。
- 状态：待修复（含核实）。

### CARRY-05 — OCR 关闭/取消错误不可区分（审查遗留）
- 来源：SM-05/06 审查 P3-7。
- 描述：`OCRSelection.swift` 的 terminal 错误归并（`MediaFailure.isTerminal`
  分支）把 OCR_CLOSED（引擎已关闭）与用户取消统一抛 `MediaFailure.canceled`，
  上层无法区分，也影响重试提示语义。
- 建议处置：区分映射——引擎关闭保留原错误码，仅真实取消报 canceled；
  补充对应回归。
- 状态：**已修复**。实现：`LocalOCRService.recognize` 的 terminal 归并中，
  无真实取消标记（operation 未取消、会话代际未推进）且错误为引擎关闭
  （`MediaFailure.isEngineClosed`，OCR_CLOSED）时保留原错误码向上传播；
  仅真实取消（operation 取消/代际推进/CancellationError）归并 canceled，
  与 close() 先取消后关引擎的既有链路语义一致；缓存移除在两种终态前
  统一执行。新增 `OCRPolicyTests.
  testEngineClosedKeepsOriginalCodeDistinctFromCancellation`（已验证对
  修复前代码失败：旧代码抛 RECOGNITION_CANCELED），锁定"closed 保留
  原码、取消竞态仍报 canceled"两个契约面。
  验证：全量 swift test 231 项通过（2 项环境门控跳过）。

### CARRY-06 — OCR 等待队列忙轮询、非 FIFO（审查遗留）
- 来源：SM-05/06 审查 P3-8。
- 描述：`OCRProcessSupervisor`/`VisionOCRService` 的等待队列以 5ms 忙轮询
  实现，多等待者按唤醒顺序抢占，无先到先得保证；规模小影响有限。
- 建议处置：改造成基于 continuation 的 FIFO 等待；并发敏感，必须在 WP-1
  baseline 之后实施并配确定性回归（排队顺序/取消不误杀）。
- 状态：待修复（WP-1 后）。

### CARRY-07 — App 组合根强制解包（审查遗留）
- 来源：SM-08 审查 P3 观察。
- 描述：`SlateSyncApp.swift:39` 的 `UserDefaults(suiteName:)!` 强制解包
  （suiteName 为非空常量拼接，实际不可达 nil，但与 Gate 禁止不安全构造的
  精神不一致）。
- 建议处置：显式分支去掉 `!`；隔离语义不得静默降级到 `.standard`。
- 状态：**已修复**（Owner 指定先修本项）。实现：主 suite（原名保留）→
  `SlateSync.isolated.ephemeral` 备用 suite 的显式回退链替代 `!`；隔离
  运行下以 `precondition` 保证终极回退显式失败——任何隔离运行都不写真实
  用户偏好。验证：Xcode Debug 构建 + 完整 Test Plan（含隔离启动路径的
  8 项 UI 用例）通过。

## 二、Gate/治理遗留（随对应 WP 收敛时修复）

### CARRY-08 — Gate 日志分类函数 rg 无退出码防护
- 来源：本轮审查 #10 的有意保留部分。
- 描述：`phase_gate_lib.sh` 分类路径的多处 `rg -qi ... "$log_path"` 未做
  退出码防护；rg 故障会被当"无匹配"，最终方向仍收敛 FAIL（不会放行真实
  失败），但可能把 BLOCKED_ENV 场景误报为 FAIL（更严不是更松）。
- 建议处置：WP-9 final Gate 收敛时并入 `assert_scan_healthy` 模式。
- 状态：待修复（WP-9）。

### CARRY-09 — 阶段状态断言的时序刚性
- 来源：SM-01/02 审查 P2-4。
- 描述：`gate_validate_phase_state` 强制 `lifecycleState == "COMPLETE"`，
  "Gate PASS → Owner 批准"的中间态无法通过任何 Gate 重跑；这是 SM-02
  无效准入作废风波的深层原因之一，治理流程被迫把两步压缩进单一提交。
- 建议处置：WP-9 final Gate/治理语义统一时裁决是否引入合法中间态。
- 状态：待修复（WP-9，需 Owner 治理决策）。

## 三、已裁决不修 / 历史封存（无 HEAD 动作）

### CARRY-10 — ⌘W 无 keyWindow 时静默无操作
- 来源：SM-08 审查 P3 观察。
- 裁决：接受。与 macOS 系统行为一致（无 key window 时 Close 无目标对象）；
  菜单项在有可关窗口时才可达。

### CARRY-11 — slate.txt 后缀匹配语义
- 来源：审查 #9。
- 裁决：保持。`/slate\.txt$/i` 是旧版冻结兼容语义，黄金测试要求接受
  `A001C001-SLATE.TXT`；已用注释固化语义与两层兜底说明，行为不变。

### CARRY-12 — 历史问题三项
- 来源：审查 #2/#4/#12（Codex 核查确认"历史已修复/历史观察"）。
- 内容：1f82c16 提交语法残缺却携带通过证据；a289954 硬编码断言击穿 SM-02
  合法准入（已被 3b688d9 修复）；Electron 时代大型混合提交治理。
- 裁决：仅存在于历史提交，仓库禁止改写历史；随 WP-6 删除 legacy 输入后
  该面自然闭合，不改写历史 review 或证据。

### CARRY-13 — Electron 时代 8 提交仅做风险抽样
- 来源：本轮审查覆盖度声明。
- 裁决：WP-1 pre-cutover 矩阵将全量执行 Electron/Node/Modern 套件作为
  删除前最终差分，等效补足覆盖；不另做逐行审计。

## 四、环境性观察（非代码缺陷）

### CARRY-14 — 后台 XCUI 在前台应用争抢下偶发失败
- 来源：本轮 SM-08 收尾 Gate 的 UI 车道观察。
- 现象：Gate 全量运行时 UI 计划偶发 2-4 项失败（"Failed to activate
  application"/"Asynchronous wait failed"/hit point 丢失），失败集合每轮
  漂移；同一树隔离复跑 10/10 全过；解锁控制台后前台节奏车道正常。
- 处置：WP-1 baseline 的 UI 车道按"隔离复跑 + 解锁控制台 + 避免前台争抢"
  执行并记录运行条件；不因抖动删除或放宽 UI 断言。
- 状态：流程性记录，随 WP-1 落实。

## 已闭合项（备查，非遗留）

12 项审查清单中的 8 项已在本轮修复并提交：#1 CI 阶段固定（59f5451/648644c/
1950840）、#3 AGENT.md 治理矛盾（2d44b3a）、#5 EPIPE 竞态（5d06dd0）、
#6 Vision 协作线程占用（5d06dd0）、#7 CSV 64MiB 预算（23bbc5c）、
#8 的 stderrTail 部分（5d06dd0）、#10 Gate fail-open（59f5451）、
#11 WAL 附属文件权限（ca989dc）；#9 以注释裁决（23bbc5c）。
SM-09 开工新增的 Gate 脚手架缺陷（native-evidence technical 模式、
前台门控分支）已由 b86a866/82c9908 修复。
