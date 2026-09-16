# 运行逻辑与存储性能修复 — 2026-09-16

## 修复结果

1. **保存正确性**：旧保存失败保留更新的 pending 快照，重复重试写入最新版本；旧任务失败不会覆盖新任务。只有当前版本完成持久化才报告 saved。
2. **连接所有权**：项目初始化 Promise 在 await 前登记；并发首次请求只打开一个句柄，初始化失败和关闭竞争有清理保障。请求与识别全生命周期持有租约。
3. **后台存储**：一个 Node Worker 持有项目库、runtime、SQLite 与加密操作。Main 使用白名单异步代理，识别算法、Renderer IPC 和数据格式不变。命令串行包含异步 JSON 快照，不重放结果不确定的写入。
4. **只读成本**：打开数据库先检查 schema，只为缺失对象或列运行 additive 迁移事务。初始化后的加密库反复列出/打开不重写密文。项目列表顺序读取并关闭临时库。
5. **回收与退出**：最多保留一个闲置项目，60 秒闲置回收；活动租约不回收。取消确认等待租约释放。Renderer 阻止退出时仍能保存，所有窗口同意关闭后才停止 IPC 接收并等待存储落盘，库切换不再定时强退。

内部入口：`lib/storage-client.mjs`、`lib/storage-worker.mjs`、`lib/storage-protocol.mjs`。

## 验证结果

所有数据位于新建临时目录；加密测试使用合成密钥，不访问登录钥匙串中的真实密钥。没有启动 GUI 窗口，也没有读取或复制真实项目库。

| 验证 | 结果 |
| --- | --- |
| 完整 Node 套件 | 519/519 |
| Modern Vitest | 34 文件，215/215 |
| Electron Node-only 原生 ABI 专项 | 74/74，与 Node 套件部分重叠 |
| TypeScript | 通过 |
| `npm run check` 与新增模块语法检查 | 通过 |
| `npm run build:modern` | 通过 |
| 临时 ASAR 普通库/合成加密库 | Worker、原生模块和持久化往返通过 |
| `git diff --check` | 通过 |

覆盖并发初始化、初始化失败重试、租约关闭竞争、闲置容量/超时、归档读写隔离、最新快照重试、退出排空、Worker 崩溃拒绝、取消/退出期间诊断持久化、迟到取消等待租约释放、缺失索引/列恢复、外部加密提交刷新及已有加密互通回归。

退出事件测试以实际 Main 生命周期代码搭配事件模拟器验证窗口否决，不将其描述为 GUI 验收。ASAR 使用 Electron `ELECTRON_RUN_AS_NODE=1` 执行，不加载应用窗口。任务结束时恢复开始时的 Node SQLite 原生二进制。

构建仍提示既有 Renderer bundle 大于 500 kB；DOM 测试仍有既有 act/scrollTo 提示。Electron Node-only 运行输出 macOS codesign 查询提示，用例与 ASAR 往返成功；未进行签名发行认证。

## 合成性能测量

原始数据：[runtime-storage-performance-2026-09-16.json](runtime-storage-performance-2026-09-16.json)。

比较的是**同一修复后存储实现**在调用线程直接执行与通过 Worker 执行；每组执行 3 次小任务保存，库中预置大型合成诊断证据。调用线程以 5 ms 定时器观察阻塞；不包含真实图片大载荷的 IPC 复制或 GUI 渲染。

| 数据库 | 同步 3 次保存 | Worker 3 次保存 | 同步最大定时器间隔 | Worker 最大定时器间隔 |
| --- | ---: | ---: | ---: | ---: |
| 32.11 MiB | 102.07 ms | 94.93 ms | 36.47 ms | 5.70 ms |
| 128.20 MiB | 331.03 ms | 325.00 ms | 114.43 ms | 5.96 ms |

| 数据库 | 同步期间全进程 CPU | Worker 期间全进程 CPU | 同步测量后全进程 RSS | Worker 测量后全进程 RSS |
| --- | ---: | ---: | ---: | ---: |
| 32.11 MiB | 73.06 ms | 74.11 ms | 360.84 MiB | 433.53 MiB |
| 128.20 MiB | 238.55 ms | 236.14 ms | 1490.98 MiB | 1367.61 MiB |

Worker 测量结束各保留一个闲置上下文，显式关闭 runtime 后上下文/租约均为 0。线程 heap/external 观测值见原始 JSON。RSS/CPU 是全进程统计，包含合成数据准备、旧测量的内存分配和 Worker；未采集连续内存峰值，不能据此宣称实际应用内存降低。SQLite/分配器释放句柄也不保证 RSS 立即归还操作系统。

结论：Worker 明显降低调用线程阻塞；全库 AES-GCM、序列化、fsync 的 CPU、磁盘和临时内存成本仍存在。保持 Swift 现有加密格式和即时落盘保证，没有采用延迟写入或增量加密。

## 复现命令

```sh
# Node ABI 下的回归与合成测量（均无窗口）
node --import ./test-support/refactor/legacy-test-gateway.mjs --test test/*.test.mjs test/refactor/ip-02/*.test.mjs
npm run test:modern
npm run typecheck
npm run check
npm run build:modern
node test-support/storage-performance.mjs

# ASAR 测试需要事先准备 Electron ABI；会创建并清理临时 ASAR
npm run rebuild:native:electron
node test-support/storage-package-check.mjs
# 完成后根据接下来的运行方式恢复 Node ABI，或保留 Electron ABI
npm run rebuild:native:node
```

加密性能与 ASAR dylib 验证面向 macOS。没有新增依赖、发布包、Git 提交或推送。

## 后续 Review 修复

本轮修复了项目库重启被草稿拦截后无法继续保存、退出未取消模型探针、
以及嵌套租约重复计算项目摘要的问题。路径激活与 relaunch 延至窗口接受退出；
否决退出时恢复当前库访问（改名使用改名后的实际路径）。设置草稿门禁覆盖
项目/全局 dirty 和 saving 状态。外层 IPC 复用租约投影，Worker store 命令
保留连接/归档访问检查但不再重新计算摘要。

后台回归结果：Node 525/525、Modern 216/216（34 文件），类型、静态检查、
生产构建通过。冷/热草稿快照各生成 1 次摘要。新增测试使用临时库与事件模拟，
未启动 GUI、未访问真实库。本轮没有重新测量大库性能；以上性能数字保留原实验含义。
