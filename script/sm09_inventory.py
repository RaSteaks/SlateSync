#!/usr/bin/env python3
"""SM-09 WP-0 清单生成器（只读审计，不修改任何被扫描文件）。

按 SM-09 施工包 WP-0 的要求，对全部 tracked 文件生成删除/保留分类清单：
- 输出 `.codex/swift-migration/manifests/sm09-inventory.json`（tracked、可 hash）；
- 每个文件记录 path、bytes、sha256、category、note 与引用者（referencers）；
- 分类规则按顺序首次命中；无法机械判定的落入 decision-required，
  不得仅凭扩展名批量删除（WP-0 明确要求逐项判定）。

用法：`python3 script/sm09_inventory.py`（在仓库根目录执行）。
本脚本只依赖标准库与 git/rg，可在最终 native-only Gate 工具集内运行。
"""

import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUTPUT = REPO / ".codex/swift-migration/manifests/sm09-inventory.json"

# (前缀或文件名精确匹配, 分类, 备注)。规则按顺序首次命中。
RULES = [
    (".codex/refactor/", "migration-history", "不可改写的 Electron 时代历史证据（WP-6.3 原样保留）"),
    (".codex/swift-migration/", "migration-history", "迁移治理：packages/reviews/manifests/状态文件"),
    (".codex/environments/", "migration-history", "Codex 环境配置（.codex 治理范围）"),
    (".github/workflows/", "release-input", "CI/release lane，WP-4/WP-5 切换为 native-only"),
    ("Sources/", "native-product", "原生 Swift 业务模块"),
    ("Tests/", "native-test", "SwiftPM 测试目标"),
    ("SlateSyncTests/", "native-test", "Xcode 单元测试目标"),
    ("SlateSyncUITests/", "native-test", "Xcode UI 测试目标"),
    ("SlateSyncApp/", "native-product", "原生 App（含 Resources；WP-2 增补 PaddleOCR canonical 资源）"),
    ("SlateSync.xcodeproj/", "release-input", "唯一 App 构建/测试入口（scheme/test plan），WP-2 冻结发布设置"),
    ("Package.swift", "release-input", "SwiftPM 五模块定义"),
    ("SlateSync.xctestplan", "release-input", "共享 Test Plan"),
    ("script/phase_gate.sh", "release-input", "统一 Gate 入口，WP-9 收敛为 native-only"),
    ("script/lib/", "release-input", "Gate 共享函数库"),
    ("script/build_and_run.sh", "release-input", "原生 build/run/debug/verify 开发入口"),
    ("script/archive_release.sh", "release-input", "原生 Universal Release archive 入口"),
    ("script/package_release.sh", "release-input", "同源 ZIP/DMG、checksum 与 manifest 打包入口"),
    ("script/verify_bundle.sh", "release-input", "原生 bundle 架构/版本/资源/依赖/签名审计"),
    ("script/tests/phase_gate_tests.zsh", "release-input", "Gate 自测（zsh，native 工具集）"),
    ("script/tests/release_pipeline_tests.zsh", "native-test", "原生归档/打包负向与清理自测"),
    ("script/tests/sm09_release_contract.py", "native-test", "Xcode/resources/workflow 原生发布合同"),
    ("script/sm09_coverage.py", "release-input", "SM-09 legacy 删除项到原生验收的覆盖映射工具"),
    ("script/sm09_seal_baseline.py", "release-input", "SM-09 删除前基线证据封存工具"),
    ("script/sm09_inventory.py", "release-input", "SM-09 原生清单与引用审计工具"),
    ("script/tests/sm09_coverage_tests.py", "native-test", "覆盖映射完整性与故障回归"),
    ("script/tests/sm09_inventory_tests.py", "native-test", "清单故障与完整引用回归"),
    ("script/tests/", "legacy-remove", "Node 合同脚本：仍有治理价值的断言先迁入 Swift/zsh（WP-6.4）再删除"),
    ("scripts/paddleocr_runner.py", "fixture-migrate", "WP-2 迁入 SlateSyncApp/Resources/PaddleOCR/ 唯一 canonical 位置"),
    ("requirements-ocr.txt", "fixture-migrate", "WP-2 与 runner 一起迁入 App Resources；不捆绑 venv/cache/模型"),
    ("scripts/vision_ocr.swift", "decision-required", "旧 Vision 桥源码：SM-06 显式 binary 兼容车道（VISIONOCR_BINARY）是否随 cutover 保留需 Owner 决策"),
    ("scripts/setup-paddleocr.sh", "decision-required", "旧 Paddle 安装入口：SM-08 原生 installer 已替代，确认后删除"),
    ("scripts/", "legacy-remove", "Electron/Node 构建编排脚本（build-vision-ocr/copy-pdfjs/electron-build-host/electron-dev）"),
    ("electron/", "legacy-remove", "Electron main/preload 运行时"),
    ("lib/", "legacy-remove", "Electron 主进程业务库（OCR/CSV/SQLite/Provider 的 JS 实现）"),
    ("public/", "legacy-remove", "legacy renderer 与 JS 兼容层；元数据公共模块的冻结语义已由 Swift 黄金测试锁定"),
    ("src/", "legacy-remove", "Modern React renderer"),
    ("test/", "legacy-remove", "Node/Modern/Electron 测试；必要 fixtures/assertions 先迁移（WP-6.2）"),
    ("test-support/", "legacy-remove", "测试支撑与视觉基线脚本；需长期保留的摘要进 .codex/refactor"),
    (".storybook/", "legacy-remove", "Storybook 配置"),
    ("electron-builder.yml", "legacy-remove", "Electron 打包入口，WP-3 原生 archive/package 管线替代"),
    ("package.json", "legacy-remove", "Node 依赖与脚本（WSL 兼容矩阵在 pre-cutover 后失效）"),
    ("package-lock.json", "legacy-remove", "Node 锁文件"),
    ("tsconfig", "legacy-remove", "TypeScript 项目配置（renderer/main/preload/shared）"),
    ("vite.", "legacy-remove", "Vite 构建/预加载配置"),
    ("playwright.config.ts", "legacy-remove", "E2E 配置"),
    ("vitest.config.ts", "legacy-remove", "Modern 测试配置"),
    ("build/entitlements.mac.plist", "decision-required", "Electron 签名 entitlements：与原生 SlateSync entitlements 的取舍需逐项判定"),
    ("build/", "release-input", "图标等发布资源（引用情况见 referencers，WP-2 收敛为唯一来源）"),
    ("assets/", "decision-required", "根目录资产：逐项判定是否被原生 bundle 引用"),
    (".env.example", "decision-required", "Electron 环境变量模板：SM-03 原生 GlobalConfig 已覆盖其非敏感项"),
    ("slatesync.config.json", "decision-required", "根目录配置：确认是否仍被任何入口读取"),
    ("premium-audit.json", "decision-required", "历史 UI 审计工件：确认归档或删除"),
    ("premium-ui.json", "decision-required", "历史 UI 审计工件：确认归档或删除"),
    ("README.md", "release-input", "WP-8 改写为原生唯一入口文档"),
    ("AGENT.md", "release-input", "根目录项目方案（随阶段推进更新）"),
    ("AGENTS.md", "release-input", "仓库协作说明（保留并随 WP-8 收敛为 native-only）"),
    ("LICENSE", "release-input", "分发许可"),
    ("DESIGN.md", "migration-history", "保留为设计/审查输入，不进 bundle（WP-6.3）"),
    ("UX-CONTRACT.md", "migration-history", "保留为设计/审查输入，不进 bundle（WP-6.3）"),
    (".gitignore", "release-input", "WP-6.6 清理 Node ignores，保留 Swift/Xcode/Gate/Paddle 需要"),
    (".gitattributes", "release-input", "二进制标记等仓库属性"),
]


def classify(path: str) -> tuple[str, str]:
    for prefix, category, note in RULES:
        if path == prefix or path.startswith(prefix):
            return category, note
    return "decision-required", "未匹配任何规则：逐项判定"


def tracked_files() -> list[str]:
    # -z 输出 NUL 分隔且不做 quotepath 转义，中文/长破折号文件名原样保留。
    result = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, capture_output=True, check=True)
    return [line for line in result.stdout.decode("utf-8").split("\0") if line]


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def referencers_of(path: str, tracked: set[str]) -> list[str]:
    # 在 tracked 文本中搜索该路径字符串，给出删除前引用图候选。
    # -I 跳过二进制；自身排除；动态拼接路径仍需人工确认（见 note）。
    result = subprocess.run(
        ["git", "grep", "-z", "-l", "-I", "-F", "-e", path, "--", "."],
        cwd=REPO, capture_output=True, text=True,
    )
    # Exit 1 means no references; every other failure invalidates the audit.
    # NUL delimiters preserve Unicode/newline paths without Git quote escaping.
    if result.returncode not in (0, 1):
        raise RuntimeError(f"reference scan failed for {path}: exit {result.returncode}")
    hits = result.stdout.split("\0")
    return sorted({hit for hit in hits if hit != path and hit in tracked})


def audit_entry(relative: str, tracked: set[str]) -> dict:
    category, note = classify(relative)
    absolute = REPO / relative
    entry = {
        "path": relative,
        "category": category,
        "note": note,
        "owner": {
            "native-product": "native-product",
            "native-test": "native-validation",
            "release-input": "native-release",
            "migration-history": "migration-governance",
            "legacy-remove": "WP-6-coverage-review",
            "fixture-migrate": "WP-2-resource-migration",
            "decision-required": "Owner-decision-pending",
        }[category],
    }
    # A manifest cannot contain its own final hash. Explicitly exclude that
    # digest instead of silently recording the previous generation's bytes.
    if absolute == OUTPUT:
        entry["hashDisposition"] = "self-excluded; hash externally when sealing evidence"
    else:
        entry.update(bytes=absolute.stat().st_size, sha256=sha256_of(absolute))
    # Native/release resources also need incoming references, not just removals.
    entry["referencers"] = referencers_of(relative, tracked)
    return entry


def main() -> int:
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
    files = tracked_files()
    tracked_set = set(files)
    inventory = []
    counts: dict[str, int] = {}
    for relative in sorted(files):
        entry = audit_entry(relative, tracked_set)
        inventory.append(entry)
        category = entry["category"]
        counts[category] = counts.get(category, 0) + 1

    workspace_status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=REPO, capture_output=True, text=True, check=True,
    ).stdout

    document = {
        "schemaVersion": 2,
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit,
        "sourceType": "working-tree",
        "dirtyWorkspace": bool(workspace_status),
        "approvable": False,
        "referenceScope": "tracked literal path references; dynamic references require manual review",
        "categories": ["native-product", "native-test", "release-input", "migration-history", "fixture-migrate", "legacy-remove", "decision-required"],
        "summary": {"total": len(inventory), **counts},
        "files": inventory,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"inventory: {len(inventory)} files -> {OUTPUT.relative_to(REPO)}")
    for name in document["categories"]:
        print(f"  {name}: {counts.get(name, 0)}")
    # decision-required 必须显式列出（WP-0 逐项判定），不能静默留在清单里。
    for entry in inventory:
        if entry["category"] == "decision-required":
            print(f"  [decision] {entry['path']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
