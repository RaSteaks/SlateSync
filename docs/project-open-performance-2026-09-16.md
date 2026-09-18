# 多任务项目打开与任务轨道性能优化

## 修改

- `last_recognition_defaults` 记录 `{ empty: true }`，表示已确认没有成功识别记录，
  避免草稿/失败任务较多时每次打开都扫描任务正文、图片与 CSV。公开返回仍为 `null`；
  成功保存原子替换该缓存，删除源任务后重新推导，批量导入主动失效。旧版本把该值
  视为缓存未命中，因此兼容回退读取，不改变任务数据格式或 IPC。
- JSON 迁移在实际插入记录的同一事务内失效缓存；空迁移不失效。项目初始化等迁移
  完成后生成摘要，避免首个响应缺少旧任务计数或识别默认值。
- 把组合 COUNT/MAX 拆成两个标量子查询：SQLite 可单独统计索引并查找最新时间，
  无须逐行更新两个聚合器。不增加表、索引或依赖。
- 任务轨道首屏不建立搜索索引；开始搜索时才归一化历史文本，后续按键复用结果。
  React 延后结果计算以优先响应输入；日期格式化器复用，虚拟测量按稳定任务 ID 保存。
  保留既有外观、中文标签、键盘清除、错误反馈与工作区滚动规则。

## 合成性能数据

运行 `node test-support/refactor/project-open-performance.mjs`。每条任务包含 8 KiB
合成图片字符串；未加密临时 SQLite，除首次/重开为单次外均为 7 次测量的中位数。
基线直接执行修改前的扫描与聚合逻辑；完整快照计时包含 runtime 和任务摘要读取。

| 任务数 | 旧默认值扫描 | 缓存命中 | 首次建立缓存 | 旧统计 / 新统计 | 热快照 / 重开快照 |
| --- | --- | --- | --- | --- | --- |
| 1,000 | 5.514 ms | 0.007 ms | 6.330 ms | 0.029 / 0.008 ms | 1.023 / 3.712 ms |
| 5,000 | 72.546 ms | 0.007 ms | 71.264 ms | 0.121 / 0.009 ms | 12.276 / 14.798 ms |

这些是存储路径数据，不包含 Worker/Electron IPC、真实图片体积或 GUI。
历史项目第一次未命中仍需要扫描；加密库首次写入缓存仍涉及整库加密，未承诺消除
解密、完整任务摘要传输或整库加密保存的成本。

## 验证

- Node 完整套件：527/527，包括真实临时库、Worker、合成加密库读取不重写、缓存
  重开/增删改/迁移、初始化失败重试。使用现有 ABI，未重新构建原生依赖。
- Modern：34 文件、217/217；含 5,000 任务 DOM 数量上限、搜索索引复用和 Escape 清除。
- `npm run typecheck`、`npm run check`、`npm run build:modern`、
  `npm run build:storybook`、`git diff --check` 和 premium strict 审计通过，审计 0 findings。
- `node test-support/refactor/interaction-browser.cjs large-task-history`：隔离无头 Chrome、
  内存网关、5,000 任务，初始只挂载 10 行；模拟项目点击至任务计数可见约 129 ms。
  该单次数字只验证 Renderer，不代表真实 Electron 项目打开时间。覆盖滚到底后搜索、
  无结果、Tab/Enter 清除、Escape、960px 浅色窗口、刷新失败保留列表及重试；页面错误 0。
  截图已检查，证据位于 `/tmp/slatesync-interaction-browser/large-task-history.*`。
- 沿用既有布局与设计 token；未启动 Electron 前台窗口、读取真实项目库、提交或推送。
  构建仍有既有大 chunk 提示，jsdom 仍有既有 `act` / `scrollTo` 提示。
