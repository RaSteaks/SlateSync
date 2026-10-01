# Repository Instructions

- 在对代码进行编辑后，添加/更新代码注释。
- 根目录项目方案记录在 `AGENT.md`。
- 工作时默认使用 `./script/ci_preflight.sh`、构建和离线检查；不要在本机启动完整 SM-09 Gate、XCUI 或前台性能测试。完整 UI/打包验收使用 GitHub macOS runner，保持必需检查和断言。只有用户明确安排本机前台验收时才启动应用、占用焦点或运行前台测试。
