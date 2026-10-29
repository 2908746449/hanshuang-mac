[CmdletBinding()]
param(
    [string]$SourcePrompt,
    # OpenCode 的全局配置目录（默认 ~/.config/opencode，可用 XDG_CONFIG_HOME 改）
    [string]$ConfigDir,
    [string]$SkillsSource,
    # 分号分隔的其他提示词绝对路径：AGENTS.md 正文与之相同 = 之前贴的就是提示词，可直接整份改写
    [string]$KnownPrompts,
    [switch]$Uninstall,
    # 只把注入的内容还原成原版（AGENTS.md 摘块），技能库与 install-state.json 一概不动。
    # 界面上的「装回原始记忆」按钮走这条路径。
    [switch]$RestoreMemory
)
# ---- macOS / Windows 平台适配层（见同目录 platform.ps1）----
# 必须在 param() 之后、任何路径计算之前点入：它负责补齐 Unix 下不存在的
# USERPROFILE / APPDATA / LOCALAPPDATA / ProgramFiles / SystemDrive / TEMP，
# 并把 Windows 专有的 robocopy / 注册表 / 盘符扫描收敛成 Copy-HsTree 等函数。
$hsPlatformFile = Join-Path $PSScriptRoot 'platform.ps1'
. $hsPlatformFile

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 统一 UTF-8 输出：避免按系统代码页（GBK/437…）写 stdout 导致界面日志乱码
try {
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# 顶层错误捕获：任何失败打印原因并以非零码退出，界面能立即看到真实错误
trap {
    Write-Host ("寒霜工具错误: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# 定位 AGENTS.md 里的注入块，返回起止下标。按 HANSHUANG-INJECT:BEGIN/END 匹配而不是
# 写死整行，这样老版本写下的标记也能被认出来并正确摘除。
function Find-InjectBlock([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $m = [regex]::Match($Text, '<!--[^\r\n]*HANSHUANG-INJECT:BEGIN[^\r\n]*-->')
    if (-not $m.Success) { return $null }
    # 注意：这里必须用两个两参 Match。写成 [regex]::Match($Text, $pat, $startat) 会命中
    # 「(string, string, RegexOptions)」重载，PowerShell 拿起始下标去转 RegexOptions 枚举
    # 直接抛「无法将值 2944 转换为 RegexOptions」——卸载就报退出码 1。
    $tail = $Text.Substring($m.Index + $m.Length)
    $e = [regex]::Match($tail, '<!--[^\r\n]*HANSHUANG-INJECT:END[^\r\n]*-->')
    if (-not $e.Success) { return $null }
    return @{ Start = $m.Index; End = $m.Index + $m.Length + $e.Index + $e.Length }
}

# 寒霜提示词独有的特征串。老版本是「整份覆盖」式注入，不留标记，只能靠内容认出来。
# 实测要覆盖到历届版本：V4/V3 的「拒绝话术全清单」「激活词」、V5 的「样例 A：给另一 AI」，
# 以及早期那份 SES-OS 规范（只含「寒霜」「SES-OS」两个词，漏了就认不出来）。
$injectSignatures = @(
    'HANSHUANG-INJECT',
    '拒绝话术全清单',
    '激活词',
    '寒霜',
    'SES-OS',
    '样例 A：给另一 AI',
    'CTF Lab'
)

# 判断一份文件是不是「注入产物」：带注入标记或命中特征串。
# 用途一：别把早先的注入产物当成「原始备份」还原回去（那样卸载等于没卸）。
# 用途二：认出没有标记的老式注入残渣，装/卸时都能正确处理而不是当用户内容追加。
function Test-InjectionArtifact([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { $t = Read-Utf8 $Path } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    foreach ($sig in $injectSignatures) {
        if ($t.Contains($sig)) { return $true }
    }
    return $false
}

# 找一份「干净的」原始 AGENTS.md 备份（最新的优先）：覆盖各家备份命名，
# 排除注入产物与空文件；找不到返回 $null。
function Get-CleanAgentsBackup {
    $cands = @()
    foreach ($pat in @('AGENTS.md.bak', 'AGENTS.md.bak_*', 'AGENTS.md.backup-*', 'AGENTS.md.hanshuang.bak')) {
        $cands += @(Get-ChildItem -LiteralPath $ConfigDir -Filter $pat -File -ErrorAction SilentlyContinue)
    }
    $managedBak = Join-Path $managedDir 'AGENTS.md.bak'
    if (Test-Path -LiteralPath $managedBak -PathType Leaf) {
        $cands += @(Get-Item -LiteralPath $managedBak)
    }
    foreach ($c in ($cands | Where-Object { $_ -and $_.Length -gt 0 } | Sort-Object LastWriteTime -Descending)) {
        if ($c.FullName -eq $agentsMd) { continue }
        if (Test-InjectionArtifact $c.FullName) { continue }
        return $c.FullName
    }
    return $null
}

# OpenCode 的全局配置目录：-ConfigDir > XDG_CONFIG_HOME/opencode > ~/.config/opencode
# （与 opencode 自身的 Global.Path.config 解析一致：macOS / Linux 落在 ~/.config，Windows 落在 %USERPROFILE%\.config）
if ([string]::IsNullOrWhiteSpace($ConfigDir)) {
    if ($env:XDG_CONFIG_HOME) {
        $ConfigDir = Join-Path $env:XDG_CONFIG_HOME 'opencode'
    } else {
        $ConfigDir = Join-Path $HOME '.config/opencode'
    }
}
$ConfigDir = [System.IO.Path]::GetFullPath($ConfigDir)
$agentsMd = Join-Path $ConfigDir 'AGENTS.md'
$managedDir = Join-Path $ConfigDir 'managed-prompts'
$backupPath = Join-Path $managedDir 'AGENTS.md.bak'
$markerEnd = '<!-- HANSHUANG-INJECT:END -->'

# OpenCode 在配置目录下按 {skill,skills}/**/SKILL.md 发现技能，所以技能落 <ConfigDir>\skills。
if ([string]::IsNullOrWhiteSpace($SkillsSource)) {
    # 随包技能库：macOS 版没有 seep-kit（300 MB 的 Windows 工具链）。
    # 优先用 codex-skills-v4（本仓库实际分发的库），老包回落到 codex-skills ——
    # 卸载时不传 -SkillsSource，这里算出来的名字集合就是「该删哪些技能」的过滤器，
    # 退回旧库会漏掉 l-* 四个技能（实测会残留在 skills/ 里清不掉）。
    $preferredSkills = Join-Path $PSScriptRoot 'codex-skills-v4'
    $SkillsSource = if (Test-Path -LiteralPath $preferredSkills) { $preferredSkills } else { Join-Path $PSScriptRoot 'codex-skills' }
} else {
    $SkillsSource = Join-Path $PSScriptRoot $SkillsSource
}
$skillsSource = $SkillsSource
$skillsTarget = Join-Path $ConfigDir 'skills'
$skillsManifestKey = 'installedSkills'

# 单个技能目录已是最新时跳过删除+复制（重装时几乎所有技能都没变）。
# 省掉磁盘写入 = 省掉杀软实时扫描，实测重装从 7 秒级降到 1 秒级。
function Test-SkillCurrent([string]$SrcDir, [string]$DestDir) {
    # 只比 SKILL.md 的大小+时间戳当"这个技能没变过"的代理指标 —— 便宜且够用：
    # 真正逐文件的差异由 Copy-HsTree 自己判断。
    $srcFile = [System.IO.Path]::Combine($SrcDir, 'SKILL.md')
    $dstFile = [System.IO.Path]::Combine($DestDir, 'SKILL.md')
    if (-not [System.IO.File]::Exists($srcFile)) { return $false }
    if (-not [System.IO.File]::Exists($dstFile)) { return $false }
    $s = New-Object System.IO.FileInfo($srcFile)
    $d = New-Object System.IO.FileInfo($dstFile)
    if ($s.Length -ne $d.Length) { return $false }
    if ([Math]::Abs(($s.LastWriteTimeUtc - $d.LastWriteTimeUtc).TotalSeconds) -gt 2) { return $false }
    return $true
}

function Get-SkillDirs {
    if (-not (Test-Path -LiteralPath $skillsSource)) { return @() }
    return @(Get-ChildItem -LiteralPath $skillsSource -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
}

function Install-Skills {
    $installed = @()
    $dirs = Get-SkillDirs
    if ($dirs.Count -eq 0) { return $installed }
    New-Item -ItemType Directory -Force -Path $skillsTarget | Out-Null

    # 上次由本工具装的技能名单 + 已备份的用户技能。
    # 名单里没有的同名目录 = 用户自己的技能：先整目录挪到 <名>.bak-<时间戳>，
    # 卸载时再原样搬回来 —— 覆盖别人的技能却不留后路是不可逆的。
    $prevNames = @()
    $script:backedUpSkills = @{}
    $stPath = Join-Path $managedDir 'install-state.json'
    if (Test-Path -LiteralPath $stPath) {
        try {
            $ps = Read-Utf8 $stPath | ConvertFrom-Json
            if ($ps.installedSkills) { $prevNames = @($ps.installedSkills) }
            if ($ps.backedUpSkills) {
                foreach ($prop in $ps.backedUpSkills.PSObject.Properties) {
                    $script:backedUpSkills[$prop.Name] = [string]$prop.Value
                }
            }
        } catch {}
    }

    foreach ($d in $dirs) {
        $dest = Join-Path $skillsTarget $d.Name
        if ((Test-Path -LiteralPath $dest) -and ($prevNames -notcontains $d.Name)) {
            $bak = Join-Path $skillsTarget ($d.Name + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $dest -Destination $bak -Force
            $script:backedUpSkills[$d.Name] = $bak
            Write-Host ("Backed up existing skill " + $d.Name + " -> " + (Split-Path -Leaf $bak)) -ForegroundColor Yellow
        }
        if (Test-SkillCurrent $d.FullName $dest) {
            $installed += $d.Name
            continue
        }
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        # /E 语义；macOS 走 rsync -a，失败再退原生递归复制（Copy-HsTree 内部处理）
        Copy-HsTree -Src $d.FullName -Dest $dest
        $installed += $d.Name
    }
    return $installed
}

# 随包技能库里有哪些技能名。卸载/清理时只认这些名字 —— 用户自己装的技能一个都不碰。
function Get-ShippedSkillNames {
    return @(Get-SkillDirs | Select-Object -ExpandProperty Name)
}

# 候选 = 上次安装清单 ∩ 随包技能库。
# 只删同时满足三条的目录：上次由本工具装过、当前版本已不再分发、目录下确实有 SKILL.md。
function Prune-StaleSkills([string[]]$Previous, [string[]]$Current) {
    $removedSkills = @()
    if (-not $Previous) { return $removedSkills }
    $shipped = Get-ShippedSkillNames
    foreach ($hsSkillName in $Previous) {
        if ([string]::IsNullOrWhiteSpace($hsSkillName)) { continue }
        if ($shipped -notcontains $hsSkillName) { continue }  # 非随包技能，不动
        if ($Current -contains $hsSkillName) { continue }
        $dest = Join-Path $skillsTarget $hsSkillName
        if (-not (Test-Path -LiteralPath $dest)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md'))) { continue }
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $removedSkills += $hsSkillName
    }
    return $removedSkills
}

# 卸载时只删「上次安装清单 ∩ 随包技能库」。
# 变量名不要用 $Names：PowerShell 动态作用域下，函数内 foreach 的迭代变量会写进
# 调用方同名变量，会把不属于本工具的技能一起删掉。
function Remove-Skills([string[]]$SkillNames) {
    $removedSkills = @()
    if (-not $SkillNames) { return $removedSkills }
    $shipped = Get-ShippedSkillNames
    foreach ($hsSkillName in $SkillNames) {
        if ([string]::IsNullOrWhiteSpace($hsSkillName)) { continue }
        if ($shipped -notcontains $hsSkillName) { continue }  # 非随包技能，不动
        $dest = Join-Path $skillsTarget $hsSkillName
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
            $removedSkills += $hsSkillName
        }
    }
    return $removedSkills
}

# 卸载/还原模式不解析提示词文件，安装模式才要求它存在。
if ([string]::IsNullOrWhiteSpace($SourcePrompt) -and -not ($Uninstall -or $RestoreMemory)) {
    $mdFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.md' -File | Sort-Object Name)
    if ($mdFiles.Count -eq 0) {
        throw "No .md prompt file found in $PSScriptRoot"
    }
    $SourcePrompt = $mdFiles[0].FullName
}

if ($Uninstall -or $RestoreMemory) {
    # 1. 摘掉注入块：只按标记删，块外用户自己写的内容原样保留。
    if (Test-Path -LiteralPath $agentsMd) {
        $cur = Read-Utf8 $agentsMd
        $blk = Find-InjectBlock $cur
        if ($blk) {
            $left = ($cur.Substring(0, $blk.Start) + $cur.Substring($blk.End)).Trim()
            # 安装前留的原始备份还在、且块外内容与它一致（用户装完后没自己改过）时整份还原，
            # 做到逐字节回到安装前的样子（换行符 / 末尾空行都不漂移）。
            $managedBak = Join-Path $managedDir 'AGENTS.md.bak'
            $normFn = { param($s) (($s -replace "`r`n", "`n").Trim()) }
            if ((Test-Path -LiteralPath $managedBak -PathType Leaf) -and
                ((& $normFn $left) -eq (& $normFn (Read-Utf8 $managedBak)))) {
                Copy-Item -LiteralPath $managedBak -Destination $agentsMd -Force
                Remove-Item -LiteralPath $managedBak -Force -ErrorAction SilentlyContinue
                Write-Host "Restored original AGENTS.md byte-for-byte (pre-install backup consumed)"
            } elseif ($left.Length -eq 0) {
                # 摘完什么都不剩 = 这份文件本来就是我们建的：能找回干净的原始文件就还原，否则删掉。
                # 用 Get-CleanAgentsBackup 而不是直接拿 managed-prompts 里那份备份 ——
                # 那份备份本身可能就是更早的一次注入，还原它等于没卸载。
                $clean = Get-CleanAgentsBackup
                if ($clean) {
                    Copy-Item -LiteralPath $clean -Destination $agentsMd -Force
                    Write-Host ("Restored original AGENTS.md from " + (Split-Path -Leaf $clean))
                } else {
                    Remove-Item -LiteralPath $agentsMd -Force
                    Write-Host "Removed injected AGENTS.md"
                }
            } else {
                Write-Utf8NoBom $agentsMd ($left + [Environment]::NewLine)
                Write-Host "Removed injected block from AGENTS.md (user content kept)"
            }
        } elseif (Test-InjectionArtifact $agentsMd) {
            # 没有标记、但内容就是提示词（老版本覆盖式注入留下的）：挪到一边留证，
            # 能找回干净的原始文件就还原，找不到就让它不存在。
            $aside = Join-Path $ConfigDir ('AGENTS.md.inject-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $agentsMd -Destination $aside -Force
            $clean = Get-CleanAgentsBackup
            if ($clean) {
                Copy-Item -LiteralPath $clean -Destination $agentsMd -Force
                Write-Host ("Restored original AGENTS.md from " + (Split-Path -Leaf $clean) +
                    " (stale injection kept at " + (Split-Path -Leaf $aside) + ")")
            } else {
                Write-Host ("Removed stale injected AGENTS.md (kept a copy at " + (Split-Path -Leaf $aside) + ")")
            }
        } else {
            Write-Host "No injection found, nothing to do"
        }
    } else {
        Write-Host "No AGENTS.md found, nothing to do"
    }
    # 2. 删除同步安装的 skills —— 「装回原始记忆」模式跳过整块：技能要留着，
    #    install-state.json（技能清单就存在里面）也必须一起留。
    if ($RestoreMemory) {
        Write-Host "Restore-memory: managed skills and install-state.json kept"
        exit 0
    }
    $statePath = Join-Path $managedDir 'install-state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.$skillsManifestKey) {
                $removedSkills = Remove-Skills @($state.$skillsManifestKey)
                if ($removedSkills.Count -gt 0) {
                    Write-Host ("Removed managed skills: " + ($removedSkills -join ", "))
                } else {
                    Write-Host "No managed skills to remove"
                }
            }
            # 把安装前属于用户自己的同名技能搬回来（安装时挪成了 <名>.bak-<时间戳>）
            if ($state.backedUpSkills) {
                foreach ($prop in $state.backedUpSkills.PSObject.Properties) {
                    $bak = [string]$prop.Value
                    if (-not (Test-Path -LiteralPath $bak)) { continue }
                    $dest = Join-Path $skillsTarget $prop.Name
                    if (Test-Path -LiteralPath $dest) {
                        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $bak -Destination $dest -Force
                    Write-Host ("Restored original skill: " + $prop.Name)
                }
            }
        } catch {
            Write-Host "Failed to read install-state.json, skipping skill removal"
        }
        Remove-Item -LiteralPath $statePath -Force
    }
    # 3. 收尾：注入目录被清空后不留空壳（Windows 版靠 .NET 目录语义，macOS 上
    #    留两个空目录会让用户以为没卸干净）
    foreach ($d in @($managedDir, $skillsTarget)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        if ($null -eq (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $SourcePrompt)) {
    throw "Prompt file not found: $SourcePrompt"
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $managedDir | Out-Null

# 注入方式：带标记的块。原则和其它目标一致 ——
#   · 用户自己写的内容一律保留（首次注入前备份一份原文件）
#   · 已经有块就只换块内内容
#   · 整份文件本来就是提示词（含老版本写下的「标记+提示词」形态）才整份改写
$promptText = (Read-Utf8 $SourcePrompt).TrimEnd()
$markerBegin = '<!-- HANSHUANG-INJECT:BEGIN prompt=' + (Split-Path -Leaf $SourcePrompt) + ' -->'
$block = $markerBegin + [Environment]::NewLine + $promptText + [Environment]::NewLine + $markerEnd
$norm = { param($s) ($s -replace "`r`n", "`n").Trim() }
$normBody = & $norm $promptText

$existing = ''
if (Test-Path -LiteralPath $agentsMd) { $existing = Read-Utf8 $agentsMd }
$normExisting = & $norm $existing

$isPromptOnly = $false
if ($normExisting.Length -gt 0) {
    if ($normExisting -eq $normBody) {
        $isPromptOnly = $true
    } else {
        # 去掉已有的注入块之后再比：老版本写下的「块内只有提示词」也算
        $blk0 = Find-InjectBlock $existing
        if ($blk0) {
            $outside = & $norm ($existing.Substring(0, $blk0.Start) + $existing.Substring($blk0.End))
            if ($outside.Length -eq 0) { $isPromptOnly = $true }
        }
        if (-not $isPromptOnly -and -not [string]::IsNullOrWhiteSpace($KnownPrompts)) {
            foreach ($k in ($KnownPrompts -split ';')) {
                if ([string]::IsNullOrWhiteSpace($k)) { continue }
                if (-not (Test-Path -LiteralPath $k)) { continue }
                if ($normExisting -eq (& $norm (Read-Utf8 $k))) { $isPromptOnly = $true; break }
            }
        }
    }
}

$blk = Find-InjectBlock $existing
if ($blk) {
    # 已有注入块：只换块内内容，块外的用户内容原样保留
    $existing = $existing.Substring(0, $blk.Start) + $block + $existing.Substring($blk.End)
    Write-Utf8NoBom $agentsMd ($existing.TrimEnd() + [Environment]::NewLine)
    Write-Host "Updated injected block in AGENTS.md (user content kept)"
} elseif ($normExisting.Length -eq 0 -or $isPromptOnly) {
    Write-Utf8NoBom $agentsMd ($block + [Environment]::NewLine)
    Write-Host "Injected prompt -> $agentsMd"
} elseif (Test-InjectionArtifact $agentsMd) {
    # 老版本覆盖式注入留下的残渣（没标记、内容却就是提示词）：挪到一边留证再写新块，
    # 不能当成"用户自己的内容"往后追加，否则会越堆越长
    $aside = Join-Path $ConfigDir ('AGENTS.md.inject-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $agentsMd -Destination $aside -Force
    Write-Utf8NoBom $agentsMd ($block + [Environment]::NewLine)
    Write-Host ("Replaced stale injection -> " + $agentsMd + " (stale copy kept at " + (Split-Path -Leaf $aside) + ")")
} else {
    # 用户自己的内容：仅首次备份原文件，再把块追加到末尾
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $agentsMd -Destination $backupPath -Force
        Write-Host "Backed up original AGENTS.md"
    }
    Write-Utf8NoBom $agentsMd ($existing.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $block + [Environment]::NewLine)
    Write-Host "Appended injected block -> $agentsMd (original content kept)"
}

# 先读上一次安装写下的技能清单（新版装完要按它清理旧版遗留）
$prevSkills = @()
$prevStatePath = Join-Path $managedDir 'install-state.json'
if (Test-Path -LiteralPath $prevStatePath) {
    try {
        $prevState = Read-Utf8 $prevStatePath | ConvertFrom-Json
        if ($prevState.installedSkills) { $prevSkills = @($prevState.installedSkills) }
    } catch {}
}

# 同步安装 skills
$installedSkills = Install-Skills
if ($installedSkills.Count -gt 0) {
    Write-Host ("Installed skills: " + ($installedSkills -join ", "))
} else {
    Write-Host ("No skills installed (source: " + $skillsSource + ")")
}

# 清掉上一版遗留、新版技能库里已移除的技能
$staleSkills = Prune-StaleSkills $prevSkills $installedSkills
if ($staleSkills.Count -gt 0) {
    Write-Host ("Pruned stale skills from previous version: " + ($staleSkills -join ", "))
}

$state = @{ $skillsManifestKey = $installedSkills }
if ($script:backedUpSkills -and $script:backedUpSkills.Count -gt 0) {
    $state['backedUpSkills'] = $script:backedUpSkills
}
$statePath = Join-Path $managedDir 'install-state.json'
$stateJson = $state | ConvertTo-Json
Write-Utf8NoBom $statePath $stateJson

Write-Host "Restart OpenCode to load the configured instructions."
