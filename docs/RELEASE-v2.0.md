# 寒霜破甲工具 · macOS 版 v2.0

跟随上游 Windows 版 v2.0 同步，macOS 版补齐一个此前没有的破甲目标：**OpenCode**。

## 新增

- **OpenCode 破甲**（第 9 个目标）
  - 注入点：`~/.config/opencode/AGENTS.md`，写入带 `HANSHUANG-INJECT:BEGIN/END` 标记的块；
    文件里你自己写的内容一字节不动，重复安装只换块内内容，卸载时按标记精确摘除。
  - 技能库：同步到 `~/.config/opencode/skills`（OpenCode 按 `{skill,skills}/**/SKILL.md` 发现）。
  - 配置根解析顺序与 OpenCode 自身一致：`-ConfigDir` > `$XDG_CONFIG_HOME/opencode` > `~/.config/opencode`。
  - 安装前备份原文件到 `~/.config/opencode/managed-prompts/AGENTS.md.bak`；
    卸载优先用它做**逐字节还原**，还原不了才退回删除标记块。
  - 你原本就有的同名技能会被挪成 `<名>.bak-<时间戳>` 保留，卸载时原样搬回来。

## 修复

- **卸载残留技能**：`-Uninstall` 时补传 `-SkillsSource codex-skills-v4`。脚本用
  「上次安装清单 ∩ 随包技能库」做过滤，卸载路径以前拿不到库名只能退回旧库，
  少了 `l-gameassist` / `l-license` / `l-reverse` / `l-webrecon` 四个，它们会永远留在 `skills/`。
- **卸载后不留空壳**：`managed-prompts` / `skills` 清空后一并删除，不再是「删了但目录还在」。
- **清理脚本认 OpenCode**：`clear-injected-prompts.ps1 -Targets opencode` 可摘块、还原备份、
  回收技能树（技能按 `SKILL.md` 哈希确权，用户自己装的不动）。
- **版本号单点维护**：`scripts/build.mjs` 从 `package.json` 读 `version` 写进 `Info.plist`，
  不再和 `variant.json` 两边各写一份（以前是 4.4.0 / 1.0 / 1.2 三个不同的数）。

## 验证

macOS 26.5.1，arm64 构建：

```
npm run test            # UI→IPC→pwsh 全链路，25/25 通过（新增 opencode 三项）
npm run test:opencode   # OpenCode 专用端到端，22 项断言全通过
```

`tests/opencode-test.sh` 覆盖：安装 → 重复安装（幂等）→ 装回原始记忆 → 再安装 → 卸载 →
清理脚本；断言用户 `AGENTS.md` 逐字节还原、用户同名技能原样搬回、无 `.bak-` 残留、
`managed-prompts` / `install-state.json` 不留余。

界面侧另外做了实测：在隔离 HOME 下真点「安装 / 卸载」，状态徽标、日志与磁盘结果一致
（`HS_INSTALLTEST=opencode` 那套截图钩子），OpenCode 页面在导航「破甲目标」组第 4 位。

## 安装

| 文件 | 机型 |
|---|---|
| `hanshuang-macos-arm64-2.0.zip` | Apple Silicon（M1/M2/M3/M4） |

> 只发布 Apple Silicon 构建，Intel 版不再分发。

未做代码签名（ad-hoc），首次打开若被拦：

```bash
xattr -cr "/Applications/寒霜破甲工具.app"
open "/Applications/寒霜破甲工具.app"
```

## 已知限制

- 豆包（Doubao）仍然不可用：macOS 客户端会把自身命令行里的 `--remote-debugging-port` 抹掉，
  CDP 通道建不起来。脚本会明确打印原因，不会静默失败。其余 8 个目标不受影响。
- 上游 v2.0 的 Seep 逆向工作台（约 300 MB、4600 个文件、依赖 Windows 工具链）没有随 macOS 版分发。
