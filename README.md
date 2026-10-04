# 寒霜破甲工具 · macOS 版

把原 Windows 便携版（`寒霜破甲工具-便携版-1.2.zip`）完整适配到 macOS 的版本。
Electron 桌面壳 + 随包 PowerShell 运行时 + 已移植的注入脚本，双击即用，**不需要用户另装 PowerShell**。

## 支持的目标

| 目标 | 注入点 | 状态 |
|---|---|---|
| Codex | `~/.codex/config.toml` 的 `model_instructions_file` + `~/.codex/AGENTS.md` + `~/.codex/skills` | ✅ |
| ZCode | `~/.zcode/AGENTS.md` + 记忆文件 + `ZCode.app/Contents/Resources/glm/zcode.cjs` 系统提示词 | ✅ |
| Cursor | `~/.cursor/rules/寒霜注入.mdc`（全局 User Rules）+ 项目级 `.cursor/rules` | ✅ |
| Claude | `~/.claude/CLAUDE.md` + `~/.claude/skills` | ✅ |
| WorkBuddy 国际版 | `~/.workbuddy-ai/memory/*_memory.md` + `MEMORY.md` + `skills` | ✅ |
| WorkBuddy 国内版 | `~/.workbuddy/…`（同一脚本，靠 `-ConfigDir` 区分） | ✅ |
| DeepSeek Harness (DSH) | `~/.dsh/AGENTS.md` + `~/.dsh/skills` | ✅ |
| 豆包 (Doubao) | 走 CDP 驱动客户端改**云端**全局记忆 | ⚠️ 见下 |

## 构建

```bash
npm install
npm run build            # 按当前机器架构构建
npm run build:arm64      # Apple Silicon
npm run build:x64        # Intel
```

产物：`dist/寒霜破甲工具.app`

首次构建会自动下载两个依赖到 `vendor/`（已下载过则跳过）：

- **Electron 33.4.11 darwin-&lt;arch&gt;** —— 与 Windows 便携版同版本
- **PowerShell 7.6.6 osx-&lt;arch&gt;** —— 随包运行时，解压到 `Contents/Resources/pwsh/`

> 网络受限时 `scripts/build.mjs` 会自动在「直连 → 系统代理 → npmmirror 镜像」之间回退，
> 并对每个包做 gzip/zip 完整性校验 + 断点续传重试。

## 运行

```bash
open "dist/寒霜破甲工具.app"
```

首次打开若被 Gatekeeper 拦下（构建用的是 ad-hoc 签名）：

```bash
xattr -cr "dist/寒霜破甲工具.app"
open "dist/寒霜破甲工具.app"
```

## 目录结构

```
app/                       Electron 应用（打进 app.asar）
  electron/main.cjs          主进程：IPC、任务调度、托盘、守护
  electron/preload.cjs       contextBridge 暴露 window.hs
  dist/                      前端构建产物（React SPA）
resources/                 随包资源（打进 Contents/Resources/）
  platform.ps1               ★ Windows/macOS 差异适配层
  install*.ps1               7 个目标的注入脚本（已移植）
  scripts/clear-injected-prompts.ps1
  codex-skills*/             技能库
  *.md                       各版本提示词
scripts/build.mjs          构建脚本
assets/icon.png|icns       图标
```

## 移植说明（Windows → macOS）

原版逻辑一行没改，Windows 专有语义全部收敛到 `resources/platform.ps1`，
再由各 `install*.ps1` 在 `param()` 之后点入：

| Windows 语义 | macOS 实现 |
|---|---|
| `$env:USERPROFILE` | `$HOME` |
| `$env:APPDATA` / `$env:LOCALAPPDATA` | `~/Library/Application Support` |
| `$env:ProgramFiles` | `/Applications` |
| `$env:SystemDrive` | `/` |
| `$env:TEMP` | `[IO.Path]::GetTempPath()` |
| `robocopy /E /MIR` | `rsync -a [--delete]`（无 rsync 时退化到 `Copy-Item`） |
| `[IO.DriveInfo]::GetDrives()` | 返回空数组（Unix 无盘符概念） |
| 注册表 `Uninstall\*` 找安装目录 | 扫 `/Applications` 与 `~/Applications` 下的 `.app` |
| `Start-Process *.exe` | `open -a` |
| `taskkill /PID /T /F` | `kill(-pid, SIGKILL)`（子进程 detached 自成进程组） |
| `Get-StartApps` 重启 Codex | 扫 `/Applications` 找 Codex 系 `.app` → `open -a` |

另外两处细节修正：

- `Join-Path $x 'a\b'` 里的反斜杠统一改为 `/`（Windows 同样合法，因此对 Windows 版无副作用）。
- `Test-TreeCurrent` 的相对路径裁剪原本只裁 `\`，现在同时裁 `/`。

`main.cjs` 侧的改动：

- `psExe()`：优先用随包的 `Contents/Resources/pwsh/pwsh`，退回 `PATH` 上的 `pwsh`。
- Unix 上不传 `-ExecutionPolicy`（该策略在 Unix 不可设，带了会多一条警告）。
- 子进程以 `detached` 启动，超时可整组 `SIGKILL`，不留残留写入进程。
- 托盘图标在 macOS 上缩到 16pt 并标记 template，跟随菜单栏明暗色。
- `LANG`/`LC_ALL` 固定 `zh_CN.UTF-8`，保证脚本里的中文输出不乱码。

## 实测验证

在 macOS 26.5.1 / arm64 上跑通（`ipc-test.mjs`，把 electron 换成桩模块后 require
真实 `app.asar` 里的 `main.cjs`，抓出它注册的 IPC handler 按界面路径逐个跑）：

```
$ HOME=/tmp/hs-ipc-home node ipc-test.mjs
✅ IPC tool:state
✅ tool:install / tool:uninstall / tool:restoreMemory   codex zcode cursor claude workbuddy-cn dsh  各 3 项
✅ 兜底清扫已清掉 MEMORY.md 注入
✅ install-doubao.ps1 -Status
✅ IPC tool:skills:list
==== 结果：22/22 通过 ====
```

> 必须在隔离的 `HOME` 下跑。各目标的注入点全在 `$HOME` 里，而卸载的兜底清扫是扫
> `$HOME` 的 —— 用真实 HOME 会把用户正在用的注入一起清掉。

逐目标结论：

| 目标 | 安装 | 卸载还原 |
|---|---|---|
| Codex | ✅ `config.toml` 指针 + `AGENTS.md` 标记块 + 63 个技能 | ✅ `config.toml` 与安装前**逐字节一致**，`managed-prompts` 整目录回收 |
| ZCode | ✅ 命中 `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` 并改写 `u9o`/`s9o` | ✅ 系统提示词从 `~/.zcode/zcode.cjs.backup-*` 还原 |
| Cursor | ✅ 4 处规则（`~/.cursor/rules`、`~/Library/Application Support/Cursor/…`、项目级、旧版 `.cursorrules`） | ✅ 全部摘除 |
| Claude | ✅ `CLAUDE.md` + 63 个技能 | ✅ 还原 |
| WorkBuddy | ✅ 云记忆档案 `memoryBlock` + `MEMORY.md` + `generateMemoryEnabled` + 63 技能 | ✅ 档案 `memoryBlock`/`version`、`MEMORY.md`、`app-config.json` 全部按备份还原 |
| DSH | ✅ `AGENTS.md` + 71 个技能 + 懒人包文件 | ✅ 全部摘除 |
| 豆包 | ⚠️ 见下 | — |

### 豆包（Doubao）在 macOS 上的限制

代码已移植（路径解析实测正确指向
`/Applications/Doubao.app/Contents/Helpers/Doubao Browser.app/Contents/MacOS/Doubao Browser`
—— 那才是对应 Windows `app\Doubao.exe` 的 Chromium 主体），但**当前 macOS 版豆包客户端
会重写自身命令行**：

```
实测：以 --remote-debugging-port=9222 启动后
      进程命令行变成 ... --saman-from-chat=<pid>
      → 调试端口被丢弃，9222 不监听，DevToolsActivePort 不生成
      （已排除沙箱因素：同环境下 Python 绑 127.0.0.1:9333 正常）
```

所以 CDP 通道建不起来，这个目标在 macOS 上暂不可用。脚本在这种情况下会明确打印原因，
不会静默失败。**其余 6 个目标不受影响。**
若后续豆包放开调试端口（或提供其他注入入口），把 CDP 打通即可恢复。

## 卸载

界面里每个目标都有「卸载」和「装回原始记忆」。卸载按 `install-state.json`
记录的清单精确回收，只删本工具装进去的东西；用户自己的 `AGENTS.md` / `CLAUDE.md` /
`config.toml` / 技能一律不动。
