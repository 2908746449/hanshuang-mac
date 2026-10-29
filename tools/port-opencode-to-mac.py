#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
寒霜破甲工具 · OpenCode 注入脚本 Windows -> macOS 移植

输入：上游（aimeoa/hanshuang-codex）的 install-opencode.ps1
输出：resources/install-opencode.ps1（与本仓库其它 install*.ps1 同构）

所有替换都是「精确字符串 + 断言」，任何一条没命中就报错退出，绝不静默漏改。
用法：
    python3 tools/port-opencode-to-mac.py <上游 install-opencode.ps1> [输出路径]
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
DEFAULT_OUT = HERE / "resources" / "install-opencode.ps1"

FAILS = []


def sub(name, text, old, new, count=1):
    n = text.count(old)
    if n != count:
        FAILS.append(f"[{name}] 期望 {count} 处、实际 {n} 处: {old[:100]!r}")
        return text
    return text.replace(old, new)


DOT = """# ---- macOS / Windows 平台适配层（见同目录 platform.ps1）----
# 必须在 param() 之后、任何路径计算之前点入：它负责补齐 Unix 下不存在的
# USERPROFILE / APPDATA / LOCALAPPDATA / ProgramFiles / SystemDrive / TEMP，
# 并把 Windows 专有的 robocopy / 注册表 / 盘符扫描收敛成 Copy-HsTree 等函数。
$hsPlatformFile = Join-Path $PSScriptRoot 'platform.ps1'
. $hsPlatformFile
"""


def main(src: Path, out: Path) -> int:
    t = src.read_text(encoding="utf-8-sig")
    name = src.name

    # ---------------------------------------------------------- 1. 点入适配层
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
        print(f"[{name}] 找不到 param() 收尾行")
        return 1
    lines.insert(close + 1, DOT.rstrip("\n"))
    t = "\n".join(lines)

    # ---------------------------------------------------- 2. 路径字面量 \ -> /
    t = sub(name,
            t,
            "        $ConfigDir = Join-Path $HOME '.config\\opencode'",
            "        $ConfigDir = Join-Path $HOME '.config/opencode'")
    t = sub(name,
            t,
            "# （与 opencode 自身的 Global.Path.config 解析一致；Windows 上同样落在 %USERPROFILE%\\.config）",
            "# （与 opencode 自身的 Global.Path.config 解析一致：macOS / Linux 落在 ~/.config，"
            "Windows 落在 %USERPROFILE%\\.config）")

    # ------------------------------------------- 3. 技能库来源：本仓库没有 seep-kit
    t = sub(name,
            t,
            """    # 随包技能库：seep-kit/Tool/skill（本构建）；老包回落到 codex-skills
    $seepSkills = Join-Path $PSScriptRoot 'seep-kit\\Tool\\skill'
    $SkillsSource = if (Test-Path -LiteralPath $seepSkills) { $seepSkills } else { Join-Path $PSScriptRoot 'codex-skills' }""",
            """    # 随包技能库：macOS 版没有 seep-kit（300 MB 的 Windows 工具链）。
    # 优先用 codex-skills-v4（本仓库实际分发的库），老包回落到 codex-skills ——
    # 卸载时不传 -SkillsSource，这里算出来的名字集合就是「该删哪些技能」的过滤器，
    # 退回旧库会漏掉 l-* 四个技能（实测会残留在 skills/ 里清不掉）。
    $preferredSkills = Join-Path $PSScriptRoot 'codex-skills-v4'
    $SkillsSource = if (Test-Path -LiteralPath $preferredSkills) { $preferredSkills } else { Join-Path $PSScriptRoot 'codex-skills' }""")

    # -------------------------------------------- 4. robocopy -> Copy-HsTree
    t = sub(name,
            t,
            """        robocopy $d.FullName $dest /E /MT:16 /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $($d.FullName)" }""",
            """        # /E 语义；macOS 走 rsync -a，失败再退原生递归复制（Copy-HsTree 内部处理）
        Copy-HsTree -Src $d.FullName -Dest $dest""")

    # ------------------------------------- 5. 卸载后不留空壳目录（macOS 版增强）
    t = sub(name,
            t,
            """        Remove-Item -LiteralPath $statePath -Force
    }
    exit 0""",
            """        Remove-Item -LiteralPath $statePath -Force
    }
    # 3. 收尾：注入目录被清空后不留空壳（Windows 版靠 .NET 目录语义，macOS 上
    #    留两个空目录会让用户以为没卸干净）
    foreach ($d in @($managedDir, $skillsTarget)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        if ($null -eq (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
    exit 0""")

    # --------------------------------------------------- 5. 注释里的 Windows 措辞
    t = sub(name,
            t,
            "# 真正逐文件的差异由 robocopy /MIR 自己判断。",
            "# 真正逐文件的差异由 Copy-HsTree 自己判断。")

    if FAILS:
        print("变换失败：")
        for f in FAILS:
            print("  -", f)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(t, encoding="utf-8")
    print(f"ok  {out.relative_to(HERE)}  ({len(t.splitlines())} 行)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT))
