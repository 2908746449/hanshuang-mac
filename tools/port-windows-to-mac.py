#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
寒霜破甲工具 · Windows -> macOS 移植变换器

对 resources/ 下的 7 个 install*.ps1 与 scripts/clear-injected-prompts.ps1 做定点改造。
所有替换都是「精确字符串 + 断言」，任何一条没命中就报错退出，绝不静默漏改。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "resources"
FAILS = []


def load(rel):
    p = ROOT / rel
    t = p.read_text(encoding="utf-8-sig")
    return p, t


def save(p, t):
    p.write_text(t, encoding="utf-8")


def sub(name, text, old, new, count=1):
    n = text.count(old)
    if n != count:
        FAILS.append(f"[{name}] 期望 {count} 处、实际 {n} 处: {old[:90]!r}")
        return text
    return text.replace(old, new)


# ---------------------------------------------------------------- 1. 点入适配层
# 注意：必须先把路径存进变量再点入。写成 `. (Join-Path ...)` 时 PowerShell 会把
# 括号表达式的结果当「命令名」，路径里带空格（本项目路径就带空格）就会报
# "The term '...' is not recognized as a name of a cmdlet"。
DOT = (
    "\n"
    "# ---- macOS / Windows 平台适配层（见同目录 platform.ps1）----\n"
    "# 必须在 param() 之后、任何路径计算之前点入：它负责补齐 Unix 下不存在的\n"
    "# USERPROFILE / APPDATA / LOCALAPPDATA / ProgramFiles / SystemDrive / TEMP。\n"
    "$hsPlatformFile = Join-Path $PSScriptRoot 'platform.ps1'\n"
    ". $hsPlatformFile\n"
)
DOT_SUB = (
    "\n"
    "# ---- macOS / Windows 平台适配层（见上级目录 platform.ps1）----\n"
    "$hsPlatformFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'platform.ps1'\n"
    ". $hsPlatformFile\n"
)

SCRIPTS_TOP = [
    "install.ps1",
    "install-claude.ps1",
    "install-cursor.ps1",
    "install-doubao.ps1",
    "install-dsh.ps1",
    "install-workbuddy.ps1",
    "install-zcode.ps1",
]
SCRIPTS_SUB = ["scripts/clear-injected-prompts.ps1"]

store = {}
for rel in SCRIPTS_TOP + SCRIPTS_SUB:
    p, t = load(rel)
    # 找 param 块的收尾行（首个顶格 ')'）
    lines = t.split("\n")
    close = None
    for i, ln in enumerate(lines):
        if ln.startswith("param("):
            for j in range(i + 1, len(lines)):
                if lines[j] == ")":
                    close = j
                    break
            break
    if close is None:
        FAILS.append(f"[{rel}] 找不到 param() 收尾行")
        continue
    lines.insert(close + 1, (DOT if rel in SCRIPTS_TOP else DOT_SUB).strip("\n"))
    t = "\n".join(lines)
    store[rel] = (p, t)


# ------------------------------------------------- 2. 单引号路径字面量 \ -> /
CJK = r"\u4e00-\u9fff"
LIT_RE = re.compile(r"'([^'\n]*)'")
BAD_CHARS = set("^$[]()*+?|{}")


def fix_literals(text):
    def repl(m):
        body = m.group(1)
        if "\\" not in body:
            return m.group(0)
        if any(c in body for c in BAD_CHARS):
            return m.group(0)
        if body.startswith("\\") or body.endswith("\\"):
            return m.group(0)
        # 只认「字母/数字/CJK/._- + \ + 字母/数字/CJK/._-」这类真路径分隔符
        if not re.search(r"[A-Za-z0-9_.%s-]\\[A-Za-z0-9_.%s-]" % (CJK, CJK), body):
            return m.group(0)
        return "'" + body.replace("\\", "/") + "'"

    return LIT_RE.sub(repl, text)


for rel, (p, t) in store.items():
    store[rel] = (p, fix_literals(t))


# ------------------------------------------------- 3. 双引号路径字面量 \ -> /
DQ_EDITS = {
    "install-cursor.ps1": [
        ('$result += (Join-Path $proj ".cursor\\rules\\$ruleFile")',
         '$result += (Join-Path $proj ".cursor/rules/$ruleFile")'),
        ('$result += (Join-Path $drv.RootDirectory.FullName ".cursor\\rules\\$ruleFile")',
         '$result += (Join-Path $drv ".cursor/rules/$ruleFile")'),
    ],
    "scripts/clear-injected-prompts.ps1": [
        ('$cand.Add((Join-Path $H ".cursor\\rules\\$ruleFile"))',
         '$cand.Add((Join-Path $H ".cursor/rules/$ruleFile"))'),
        ('$cand.Add((Join-Path $base "Cursor\\User\\rules\\$ruleFile"))',
         '$cand.Add((Join-Path $base "Cursor/User/rules/$ruleFile"))'),
        ('$cand.Add((Join-Path $base "Cursor\\rules\\$ruleFile"))',
         '$cand.Add((Join-Path $base "Cursor/rules/$ruleFile"))'),
        ('$cand.Add((Join-Path $loc ".cursor\\rules\\$ruleFile"))',
         '$cand.Add((Join-Path $loc ".cursor/rules/$ruleFile"))'),
        ('$cand.Add((Join-Path $drv.RootDirectory.FullName ".cursor\\rules\\$ruleFile"))',
         '$cand.Add((Join-Path $drv ".cursor/rules/$ruleFile"))'),
    ],
}
for rel, pairs in DQ_EDITS.items():
    p, t = store[rel]
    for old, new in pairs:
        t = sub(rel, t, old, new)
    store[rel] = (p, t)

# 阶段开关：PORT_PHASE=1 时只做「点入 + 路径分隔符」改造就落盘，
# 便于先看清改造后的真实文本，再写定点替换表。
import os
if os.environ.get("PORT_PHASE") == "1":
    if FAILS:
        print("阶段1 也有失败：")
        for f in FAILS:
            print("  -", f)
        sys.exit(1)
    for rel, (p, t) in store.items():
        save(p, t)
        print(f"phase1 ok  {rel}")
    sys.exit(0)


# ------------------------------------------------- 4. robocopy -> Copy-HsTree
ROBO_RE = re.compile(
    r"robocopy\s+(\$[\w.]+)\s+(\$[\w.]+)((?:\s+/[A-Za-z]+:?\d*)*)\s*\|\s*Out-Null"
)
ROBO_EDITS = {
    "install.ps1": 1,
    "install-claude.ps1": 1,
    "install-dsh.ps1": 2,
    "install-zcode.ps1": 1,
}
for rel, want in ROBO_EDITS.items():
    p, t = store[rel]
    hits = list(ROBO_RE.finditer(t))
    if len(hits) != want:
        FAILS.append(f"[{rel}] robocopy 期望 {want} 处、实际 {len(hits)} 处")
        continue
    out = []
    last = 0
    for m in hits:
        src, dest, flags = m.group(1), m.group(2), m.group(3)
        mirror = " -Mirror" if "/MIR" in flags.upper() else ""
        repl = f"Copy-HsTree -Src {src} -Dest {dest}{mirror}"
        out.append(t[last:m.start()])
        out.append(repl)
        last = m.end()
    out.append(t[last:])
    t = "".join(out)
    # 紧跟的 robocopy 退出码判断要一并去掉（Copy-HsTree 内部已抛错）
    t = re.sub(
        r"\n[ \t]*if \(\$LASTEXITCODE -ge 8\) \{ throw \"robocopy failed[^\n]*\n",
        "\n",
        t,
    )
    store[rel] = (p, t)


# ------------------------------------------------- 5. 定点替换表
EDITS = {
    # ---- install.ps1 ----
    "install.ps1": [
        # 相对路径裁剪：Windows 只裁 '\'，Unix 还得裁 '/'
        ("$rel = $f.FullName.Substring($Src.Length).TrimStart([char]92)",
         "$rel = $f.FullName.Substring($Src.Length).TrimStart([char]92, [char]47)"),
        # 盘符扫描：Unix 无盘符
        ("""        try {
            foreach ($d in [IO.DriveInfo]::GetDrives()) {
                if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
                $p = Join-Path $d.RootDirectory.FullName '.codex'
                if (Test-Path -LiteralPath $p) { $CodexHome = $p; break }
            }
        } catch { }""",
         """        try {
            # Unix 没有盘符概念，Get-HsFixedDriveRoots 返回空 -> 直接落到默认 ~/.codex
            foreach ($d in (Get-HsFixedDriveRoots)) {
                $p = Join-Path $d '.codex'
                if (Test-Path -LiteralPath $p) { $CodexHome = $p; break }
            }
        } catch { }"""),
        # 禁用技能名解析：Windows 把 / 换成 \ 再 Split-Path，Unix 下必须反过来
        ("$dir = Split-Path -Parent ($mPath.Groups[1].Value -replace '/', '\\')",
         "$dir = Split-Path -Parent ($mPath.Groups[1].Value -replace '\\\\', '/')"),
    ],
    # ---- install-claude.ps1 ----
    "install-claude.ps1": [
        # 无 Windows 专有语义，仅确认复制函数已换（由第 4 步完成）
    ],
    # ---- install-cursor.ps1 ----
    "install-cursor.ps1": [
        ("""        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady }
        if (-not $drives) { $drives = @((New-Object System.IO.DriveInfo($env:SystemDrive))) }
        foreach ($drv in $drives) {
            $result += (Join-Path $drv ".cursor/rules/$ruleFile")
        }""",
         """        # Unix 无盘符：返回空数组，跳过这一层规则（macOS 上没有等价的「卷宗根祖先规则」）
        foreach ($drv in (Get-HsFixedDriveRoots)) {
            $result += (Join-Path $drv ".cursor/rules/$ruleFile")
        }"""),
        ("""                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine""",
         """                $cmd = if (Test-HsWindows) {
                    (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
                } else { $null }"""),
    ],
    # ---- install-doubao.ps1 ----
    "install-doubao.ps1": [
        ("""    $cands = @()
    foreach ($rp in @('HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                      'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                      'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')) {
        $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*豆包*' -and $_.InstallLocation } | Select-Object -First 1
        if ($item) { $cands += ((($item.InstallLocation -replace '^"|"$', '').TrimEnd('\\')) + '\\Doubao.exe') }
    }
    $proc = Get-Process Doubao -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { $cands += $proc.Path }
    $cands += 'E:/Doubao/Doubao.exe'
    $cands += (Join-Path $env:LOCALAPPDATA 'Doubao/Doubao.exe')
    $cands += (Join-Path ${env:ProgramFiles} 'Doubao/Doubao.exe')""",
         """    $cands = @()
    if (Test-HsWindows) {
        foreach ($rp in @('HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                          'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                          'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')) {
            $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*豆包*' -and $_.InstallLocation } | Select-Object -First 1
            if ($item) { $cands += ((($item.InstallLocation -replace '^"|"$', '').TrimEnd('\\', '/')) + '\\Doubao.exe') }
        }
        $cands += 'E:\\Doubao\\Doubao.exe'
        $cands += (Join-Path $env:LOCALAPPDATA 'Doubao/Doubao.exe')
        $cands += (Join-Path ${env:ProgramFiles} 'Doubao/Doubao.exe')
    } else {
        # macOS：豆包是 .app 包，CDP 主体在 Contents/MacOS 下的可执行文件
        $app = Find-HsAppInstallLocation -Names @('Doubao', '豆包')
        if ($app) { $cands += (Join-Path $app 'Contents/MacOS/Doubao') }
        $cands += '/Applications/Doubao.app/Contents/MacOS/Doubao'
        $cands += (Join-Path $HOME 'Applications/Doubao.app/Contents/MacOS/Doubao')
    }
    $proc = Get-Process Doubao -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { $cands += $proc.Path }"""),
        ("""    # app\\Doubao.exe 是真正的 Chromium 主体；根目录那个是启动器，调试参数要交给 app 下的
    $appExe = Join-Path (Split-Path -Parent $Exe) 'app/Doubao.exe'
    if (-not (Test-Path -LiteralPath $appExe)) { $appExe = $Exe }
    Start-Process -FilePath $appExe -ArgumentList "--remote-debugging-port=$Port" | Out-Null""",
         """    # Windows 下 app\\Doubao.exe 才是 Chromium 主体；macOS 的 .app 里可执行文件本身就是主体
    $appExe = if (Test-HsWindows) { Join-Path (Split-Path -Parent $Exe) 'app/Doubao.exe' } else { $Exe }
    if (-not (Test-Path -LiteralPath $appExe)) { $appExe = $Exe }
    if (Test-HsWindows) {
        Start-Process -FilePath $appExe -ArgumentList "--remote-debugging-port=$Port" | Out-Null
    } else {
        Start-Process -FilePath $appExe -ArgumentList @('--remote-debugging-port=' + $Port) | Out-Null
    }"""),
        ("""    # $exe 可能已经是 app\\Doubao.exe（进程路径优先），别拼成 app\\app\\
    $appExe = if (-not $exe) { 'Doubao.exe' }
              elseif ($exe -like '*\\app\\Doubao.exe') { $exe }
              else { Join-Path (Split-Path -Parent $exe) 'app/Doubao.exe' }""",
         """    # $exe 可能已经是 app\\Doubao.exe（Windows，进程路径优先），别拼成 app\\app\\
    $appExe = if (-not $exe) { if (Test-HsWindows) { 'Doubao.exe' } else { '/Applications/Doubao.app' } }
              elseif ($exe -like '*\\app\\Doubao.exe') { $exe }
              elseif (Test-HsWindows) { Join-Path (Split-Path -Parent $exe) 'app/Doubao.exe' }
              else { $exe }"""),
    ],
    # ---- install-workbuddy.ps1 ----
    "install-workbuddy.ps1": [
        ("""    $proc = Get-Process WorkBuddyAI -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) { $cands += (Split-Path -Parent $proc.Path) }
    foreach ($rp in @('HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                      'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                      'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')) {
        $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*WorkBuddy*' -and $_.InstallLocation } | Select-Object -First 1
        if ($item) { $cands += ($item.InstallLocation -replace '^"|"$', '').TrimEnd('\\') }
    }""",
         """    foreach ($n in @('WorkBuddyAI', 'WorkBuddy AI')) {
        $proc = Get-Process $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path) { $cands += (Split-Path -Parent $proc.Path) }
    }
    if (Test-HsWindows) {
        foreach ($rp in @('HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                          'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
                          'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*')) {
            $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*WorkBuddy*' -and $_.InstallLocation } | Select-Object -First 1
            if ($item) { $cands += ($item.InstallLocation -replace '^"|"$', '').TrimEnd('\\', '/') }
        }
    } else {
        # macOS：WorkBuddy 是 .app 包；product.json 在 Contents/Resources 下，
        # 所以安装根取到 .app 这一层，后面的 'resources/...' 相对路径即可命中
        $app = Find-HsAppInstallLocation -Names @('WorkBuddy')
        if ($app) { $cands += $app }
        $cands += '/Applications/WorkBuddy AI.app'
        $cands += (Join-Path $HOME 'Applications/WorkBuddy AI.app')
    }"""),
        ("""            $pj = Join-Path $root 'resources/app.asar.unpacked/cli/product.json'""",
         """            $pjCands = @((Join-Path $root 'resources/app.asar.unpacked/cli/product.json'))
            if (-not (Test-HsWindows)) {
                # macOS 的 .app 里是 Contents/Resources（首字母大写）
                $pjCands = @(
                    (Join-Path $root 'Contents/Resources/app.asar.unpacked/cli/product.json'),
                    (Join-Path $root 'Resources/app.asar.unpacked/cli/product.json'),
                    (Join-Path $root 'resources/app.asar.unpacked/cli/product.json')
                )
            }
            $pj = $null
            foreach ($c in $pjCands) { if (Test-Path -LiteralPath $c) { $pj = $c; break } }"""),
        ("""        $exe = if ($InstallRoot) { Join-Path $InstallRoot 'WorkBuddyAI.exe' } else { '' }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            Start-Process -FilePath $exe | Out-Null
            Write-Host "  已重新拉起 WorkBuddyAI" -ForegroundColor Green
        } else { Write-Host "  未执行：未找到 WorkBuddyAI.exe，请手动启动" -ForegroundColor Yellow }""",
         """        $started = $false
        if (Test-HsWindows) {
            $exe = if ($InstallRoot) { Join-Path $InstallRoot 'WorkBuddyAI.exe' } else { '' }
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                Start-Process -FilePath $exe | Out-Null
                $started = $true
            }
        } elseif ($InstallRoot) {
            $started = Start-HsApp -Target $InstallRoot
        }
        if ($started) { Write-Host "  已重新拉起 WorkBuddy AI" -ForegroundColor Green }
        else { Write-Host "  未执行：未找到 WorkBuddy 客户端，请手动启动" -ForegroundColor Yellow }"""),
    ],
    # ---- install-zcode.ps1 ----
    "install-zcode.ps1": [
        ("$rel = $f.FullName.Substring($Src.Length).TrimStart('')",
         "$rel = $f.FullName.Substring($Src.Length).TrimStart([char]92, [char]47)"),
        ("""    # 2. 注册表卸载项
    $regPaths = @(
        'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
        'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',
        'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*'
    )
    foreach ($rp in $regPaths) {
        $item = Get-ItemProperty $rp -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*ZCode*' -and $_.InstallLocation } |
            Select-Object -First 1
        if ($item) {
            $candidate = Join-Path $item.InstallLocation 'resources/glm/zcode.cjs'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        if ($found) { break }
    }
    # 3. 常见安装位置
    $candidates = @(
        'C:/Program Files/ZCode/resources/glm/zcode.cjs',
        'C:\\Program Files (x86)\\ZCode\\resources\\glm\\zcode.cjs',
        "$env:LOCALAPPDATA\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
        "$env:APPDATA\\ZCode\\resources\\glm\\zcode.cjs"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    # 4. 盘符扫描兜底：ZCode 常被装在 D:/E: 等自定义目录（如 E:\\zcodess）
    #    跳过系统重目录，只扫每盘根目录下一级子目录的 1 层，避免全盘递归卡死
    try {
        $skip = @('Windows', '$RECYCLE.BIN', 'System Volume Information', 'ProgramData', 'MSOCache', '$SysReset')
        $drives = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
            Select-Object -First 6
        foreach ($drv in $drives) {
            $root = $drv.RootDirectory.FullName
            if (-not $root) { continue }
            $topDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $skip -notcontains $_.Name })
            foreach ($d in $topDirs) {
                # 目标形如 <topdir>\\resources\\glm\\zcode.cjs，相对 topdir 是第 2 层
                $hits = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'zcode.cjs' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Select-Object -First 2 -ExpandProperty FullName)
                foreach ($h in $hits) {
                    if ($h -match 'resources[\\\\/]glm[\\\\/]zcode\\.cjs$') { return $h }
                }
            }
        }
    } catch { }
    return $null""",
         """    # 2. 已安装程序登记（Windows 注册表 / macOS 的 /Applications）
    $regItem = Find-HsAppInstallLocation -Names @('ZCode')
    if ($regItem) {
        foreach ($rel in @('resources/glm/zcode.cjs', 'Contents/Resources/glm/zcode.cjs',
                           'Resources/glm/zcode.cjs')) {
            $candidate = Join-Path $regItem $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    # 3. 常见安装位置（Windows 词表 + macOS 词表；Resolve-HsAppPath 自动挑存在的）
    $candidates = @(
        'C:\\Program Files\\ZCode\\resources\\glm\\zcode.cjs',
        'C:\\Program Files (x86)\\ZCode\\resources\\glm\\zcode.cjs',
        "$env:LOCALAPPDATA\\Programs\\ZCode\\resources\\glm\\zcode.cjs",
        "$env:APPDATA\\ZCode\\resources\\glm\\zcode.cjs",
        '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs',
        '/Applications/ZCode.app/Contents/resources/glm/zcode.cjs',
        (Join-Path $HOME 'Applications/ZCode.app/Contents/Resources/glm/zcode.cjs')
    )
    $hit = Resolve-HsAppPath -Candidates $candidates
    if ($hit) { return $hit }
    # 4. Windows 盘符扫描兜底（Unix 无盘符，Get-HsFixedDriveRoots 返回空，自然跳过）
    try {
        $skip = @('Windows', '$RECYCLE.BIN', 'System Volume Information', 'ProgramData', 'MSOCache', '$SysReset', 'Library', 'System', 'Applications')
        foreach ($root in (Get-HsFixedDriveRoots | Select-Object -First 6)) {
            if (-not $root) { continue }
            $topDirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $skip -notcontains $_.Name })
            foreach ($d in $topDirs) {
                $hits = @(Get-ChildItem -LiteralPath $d.FullName -Filter 'zcode.cjs' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Select-Object -First 2 -ExpandProperty FullName)
                foreach ($h in $hits) {
                    if ($h -match 'resources[\\\\/]glm[\\\\/]zcode\\.cjs$') { return $h }
                }
            }
        }
    } catch { }
    return $null"""),
    ],
    # ---- scripts/clear-injected-prompts.ps1 ----
    "scripts/clear-injected-prompts.ps1": [
        ("""    foreach ($d in [IO.DriveInfo]::GetDrives()) {
      if ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) {
        $p = Join-Path $d.RootDirectory.FullName '.codex'
        if (Test-Path -LiteralPath $p) { return $p }
      }
    }""",
         """    foreach ($d in (Get-HsFixedDriveRoots)) {
      $p = Join-Path $d '.codex'
      if (Test-Path -LiteralPath $p) { return $p }
    }"""),
        ("""    foreach ($drv in [IO.DriveInfo]::GetDrives()) {
      if ($drv.DriveType -eq [IO.DriveType]::Fixed -and $drv.IsReady) {
        $cand.Add((Join-Path $drv ".cursor/rules/$ruleFile"))
      }
    }""",
         """    foreach ($drv in (Get-HsFixedDriveRoots)) {
      $cand.Add((Join-Path $drv ".cursor/rules/$ruleFile"))
    }"""),
        ("""      foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:APPDATA)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $cand = Join-Path $base 'ZCode/resources/glm/zcode.cjs'
        if (Test-Path -LiteralPath $cand) { $zcCjs = $cand; break }
      }""",
         """      $zcBases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'), $env:APPDATA)
      if (-not (Test-HsWindows)) {
        $zcBases = @('/Applications/ZCode.app/Contents', (Join-Path $HOME 'Applications/ZCode.app/Contents'))
      }
      foreach ($base in $zcBases) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        foreach ($rel in @('resources/glm/zcode.cjs', 'Resources/glm/zcode.cjs')) {
          $cand = Join-Path $base $rel
          if (Test-Path -LiteralPath $cand) { $zcCjs = $cand; break }
        }
        if ($zcCjs) { break }
      }"""),
    ],
}

for rel, pairs in EDITS.items():
    p, t = store[rel]
    for old, new in pairs:
        t = sub(rel, t, old, new)
    store[rel] = (p, t)

# ---------------------------------------------------------------- 写回
if FAILS:
    print("变换失败：")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)

for rel, (p, t) in store.items():
    save(p, t)
    print(f"ok  {rel}  ({len(t.splitlines())} 行)")

# 适配层主文件放在 scripts/（资源目录会被上游 zip 覆盖重建，放这里才不会被冲掉）
import shutil
shutil.copy2(ROOT.parent / "scripts" / "platform.ps1", ROOT / "platform.ps1")
print("ok  platform.ps1  (适配层)")

print("\n全部变换完成。")
