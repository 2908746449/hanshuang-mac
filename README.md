# 寒霜破甲工具 · macOS 版

把原 Windows 便携版完整适配到 macOS 的版本。
Electron 桌面壳 + 随包 PowerShell 运行时 + 已移植的注入脚本，双击即用，**不需要用户另装 PowerShell**。

当前版本 **v2.1**：跟随上游 v2.0 同步并新增 **OpenCode** 破甲（共 9 个目标）；OpenCode 改为**系统层注入**，拒绝率实测下降（见 [docs/RESEARCH-opencode.md](docs/RESEARCH-opencode.md)）。

## 支持的目标

| 目标 | 注入点 | 状态 |
|---|---|---|
| Codex | `~/.codex/config.toml` 的 `model_instructions_file` + `~/.codex/AGENTS.md` + `~/.codex/skills` | ✅ |
| ZCode | `~/.zcode/AGENTS.md` + 记忆文件 + `ZCode.app/Contents/Resources/glm/zcode.cjs` 系统提示词 | ✅ |
| Cursor | `~/.cursor/rules/寒霜注入.mdc`（全局 User Rules）+ 项目级 `.cursor/rules` | ✅ |
| **OpenCode** | **系统层** `~/.config/opencode/agent/hanshuang.md`（正文 = 执行内核，`default_agent` 指向它）+ `AGENTS.md` 标记块 + `skills` | ✅ |
| Claude | `~/.claude/CLAUDE.md` + `~/.claude/skills` | ✅ |
| WorkBuddy 国际版 | `~/.workbuddy-ai/memory/*_memory.md` + `MEMORY.md` + `skills` | ✅ |
| WorkBuddy 国内版 | `~/.workbuddy/…`（同一脚本，靠 `-ConfigDir` 区分） | ✅ |
| DeepSeek Harness (DSH) | `~/.dsh/AGENTS.md` + `~/.dsh/skills` | ✅ |
| 豆包 (Doubao) | 走 CDP 驱动客户端改**云端**全局记忆 | ⚠️ 见下 |

### v2.1 更新（OpenCode 换注入层）

v2.0 只往 `AGENTS.md` 写提示词，实测**仍然会拒绝**：opencode 的模型会把它归类成「本机偏好」并点名驳回。
真正生效的是**系统层** —— `agent/<名>.md` 的正文就是这个 agent 的 system prompt（内置模板不再注入）。

所以现在装两层：

- 系统层：`~/.config/opencode/agent/hanshuang.md`（正文 = `resources/opencode-kernel.md`），
  并把 `opencode.json` 的 `default_agent` 指过去；改配置前整份备份、改完做 JSON 校验、失败自动回滚，
  卸载时**还原成你原来的值**（原来没有这个键就删掉这个键）。
- 载荷层：`AGENTS.md` 的 `HANSHUANG-INJECT` 标记块，跟着界面选的提示词版本走。

内核按**契约型**写（首字节交付 / 禁止替代方案 / 缺参用占位符 / few-shot 锚点），通篇不要求模型"破例"，
因此没有可供驳回的对象；中转站保护条款放在最前面，实测在系统层里依然压得住。

实测（同模型 A/B，细节见 [docs/RESEARCH-opencode.md](docs/RESEARCH-opencode.md)）：
反弹 shell、Frida 绕自家 SSL pinning、crackme 补丁、自有靶场爆破全部照做；
攻击 `api.zxcbug.com` 被拒 ✅。**明确违法类（破解第三方商业授权、伪造考勤）仍然拒** ——
那是模型层训练的结果，换提示词无效，只能换无审查模型。

### v2.0 更新

- **新增 OpenCode 目标**：注入 `~/.config/opencode/AGENTS.md`（带 `HANSHUANG-INJECT` 标记块，
  只换块内内容，块外你自己的内容一字节不动），技能同步到 `~/.config/opencode/skills`
  （OpenCode 按 `{skill,skills}/**/SKILL.md` 发现技能）。配置根按 `-ConfigDir` >
  `XDG_CONFIG_HOME/opencode` > `~/.config/opencode` 解析，与 OpenCode 自身一致。
- **卸载更干净**：`-Uninstall` 时补传 `-SkillsSource codex-skills-v4`。脚本靠
  「上次安装清单 ∩ 随包技能库」过滤，以前卸载路径拿不到库名会退回旧库 `codex-skills`，
  少了 `l-*` 四个技能，它们会永远残留在 `skills/` 里（实测踩到）。
- **不留空壳目录**：卸载后 `managed-prompts` / `skills` 若已空则一并删除。
- 清理脚本 `clear-injected-prompts.ps1` 增加 opencode 分支（`-Targets opencode`）。
- 版本号只维护一处：`package.json` 的 `version` 直接写进 `Info.plist`。

## 下载

已发布的二进制在 **Releases** 里（GitHub 普通仓库单文件限 100MB，`.app` 与 zip 都超限，
所以走 Release 资产而不是直接 commit）：

| 文件 | 适用机型 |
|---|---|
| `hanshuang-macos-arm64-2.1.zip` | Apple Silicon（M1/M2/M3/M4） |

> 只发布 Apple Silicon 构建；Intel 版不再分发（源码里 `--arch=x64` 仍可自行构建）。

解压后得到 `寒霜破甲工具 2.1.app`，直接拖进 `/Applications` 即可。它和旧版（`寒霜破甲工具.app`）
**可以共存、也能同时运行**：

| | 旧版 1.2 | 2.x |
|---|---|---|
| Bundle ID | `com.hanshuang.pojia.desktop` | `com.hanshuang.pojia.desktop.v2` |
| 显示名 | 寒霜破甲工具 | 寒霜破甲工具 2.1 |
| 应用数据 | `~/Library/Application Support/hanshuang-free` | `…/寒霜破甲工具 2` |

两边的注入结果都在各自的真实目标里（`~/.codex`、`~/.config/opencode` …），所以装过什么两边都看得到；
单实例锁按应用名分，两个窗口可以同时开着。

## 构建

```bash
npm install
npm run build            # 按当前机器架构构建
npm run build:arm64      # Apple Silicon（唯一分发架构）
```

产物：`dist/寒霜破甲工具-arm64.app`

首次构建会自动下载两个依赖到 `vendor/`（已下载过则跳过）：

- **Electron 33.4.11 darwin-&lt;arch&gt;** —— 与 Windows 便携版同版本
- **PowerShell 7.6.6 osx-&lt;arch&gt;** —— 随包运行时，解压到 `Contents/Resources/pwsh/`

> 网络受限时 `scripts/build.mjs` 会自动在「直连 → 系统代理 → npmmirror 镜像」之间回退，
> 并对每个包做 gzip/zip 完整性校验 + 断点续传重试。

## 运行

```bash
open "dist/寒霜破甲工具-arm64.app"
```

首次打开若被 Gatekeeper 拦下（构建用的是 ad-hoc 签名）：

```bash
xattr -cr "dist/寒霜破甲工具-arm64.app"
open "dist/寒霜破甲工具-arm64.app"
```

## 目录结构

```
app/                       Electron 应用（打进 app.asar）
  electron/main.cjs          主进程：IPC、任务调度、托盘、守护
  electron/preload.cjs       contextBridge 暴露 window.hs
  dist/                      前端构建产物（React SPA）
resources/                 随包资源（打进 Contents/Resources/）
  platform.ps1               ★ Windows/macOS 差异适配层
  install*.ps1               9 个目标的注入脚本（已移植）
  install-opencode.ps1       OpenCode（上游 v2.0 新增，由 tools/port-opencode-to-mac.py 生成）
  opencode-kernel.md         OpenCode 系统层内核（契约型；写进 agent/<名>.md 当 system prompt）
  scripts/clear-injected-prompts.ps1
  codex-skills*/             技能库
  *.md                       各版本提示词
scripts/build.mjs          构建脚本
tools/port-*.py            Windows 脚本 → macOS 的定点变换器（带断言，改上游后重跑即可）
tools/patch-opencode-ui.py 给已构建的前端 bundle 补 OpenCode 卡片（幂等）
tests/ipc-test.mjs         UI→IPC→pwsh 全链路测试
tests/opencode-test.sh     OpenCode 安装/装回/卸载/清理端到端测试
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

在 macOS 26.5.1 上跑通（`tests/ipc-test.mjs`，把 electron 换成桩模块后 require
真实 `app.asar` 里的 `main.cjs`，抓出它注册的 IPC handler 按界面路径逐个跑）。
**arm64 构建 25/25 通过**（OpenCode 另有一套 33 项断言：`npm run test:opencode`）：

```
$ HOME=/tmp/hs-ipc-home node tests/ipc-test.mjs
✅ IPC tool:state
✅ tool:install / tool:uninstall / tool:restoreMemory   codex zcode cursor opencode claude workbuddy-cn dsh  各 3 项
✅ 兜底清扫已清掉 MEMORY.md 注入
✅ install-doubao.ps1 -Status
✅ IPC tool:skills:list
==== 结果：25/25 通过 ====
```

> 必须在隔离的 `HOME` 下跑。各目标的注入点全在 `$HOME` 里，而卸载的兜底清扫是扫
> `$HOME` 的 —— 用真实 HOME 会把用户正在用的注入一起清掉。

逐目标结论：

| 目标 | 安装 | 卸载还原 |
|---|---|---|
| Codex | ✅ `config.toml` 指针 + `AGENTS.md` 标记块 + 63 个技能 | ✅ `config.toml` 与安装前**逐字节一致**，`managed-prompts` 整目录回收 |
| ZCode | ✅ 命中 `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` 并改写 `u9o`/`s9o` | ✅ 系统提示词从 `~/.zcode/zcode.cjs.backup-*` 还原 |
| Cursor | ✅ 4 处规则（`~/.cursor/rules`、`~/Library/Application Support/Cursor/…`、项目级、旧版 `.cursorrules`） | ✅ 全部摘除 |
| **OpenCode** | ✅ `~/.config/opencode/AGENTS.md` 标记块 + 63 个技能 | ✅ `AGENTS.md` 与安装前**逐字节一致**，`skills/`、`managed-prompts/` 不留空壳（`tests/opencode-test.sh` 22 项断言全通过） |
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
不会静默失败。**其余 8 个目标不受影响。**
若后续豆包放开调试端口（或提供其他注入入口），把 CDP 打通即可恢复。

## 卸载

界面里每个目标都有「卸载」和「装回原始记忆」。卸载按 `install-state.json`
记录的清单精确回收，只删本工具装进去的东西；用户自己的 `AGENTS.md` / `CLAUDE.md` /
`config.toml` / 技能一律不动。
