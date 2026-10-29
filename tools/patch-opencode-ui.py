#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
寒霜破甲工具 · macOS 版 —— 给已构建的前端 SPA 补上「OpenCode 破甲」目标

背景：macOS 版仓库里只提交了构建产物 app/dist/（没有 src/），前端用 Vite 打包成
带 hash 的单文件 bundle。要新增一个破甲目标，只能在 bundle 的目标数组里插一条，
再补上图标映射与使用教程文案 —— 页面渲染、导航、安装/卸载流程都是按这份数据驱动的，
所以插进数组就等于多了一整页。

三条改动各自带断言，任何一条没命中就报错退出；已打过补丁时直接跳过（幂等）。

用法：
    python3 tools/patch-opencode-ui.py            # 原地打补丁
    python3 tools/patch-opencode-ui.py --check    # 只检查是否已打补丁
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
DIST = HERE / "app" / "dist"


def find_bundle() -> Path:
    html = (DIST / "index.html").read_text(encoding="utf-8")
    m = re.search(r'assets/(index-[A-Za-z0-9_-]+\.js)', html)
    if not m:
        raise SystemExit("找不到 index.html 引用的 assets/index-*.js")
    p = DIST / "assets" / m.group(1)
    if not p.exists():
        raise SystemExit(f"bundle 不存在: {p}")
    return p


# ---------------------------------------------------------------- 1. 目标数据
CURSOR_ENTRY = (
    '{id:"cursor",icon:"Cu",nav:"Cursor 破甲",eyebrow:"CURSOR 破甲",title:"Cursor 破甲",'
    'desc:"寒霜工作规范注入 Cursor 全局规则（User Rules）；卸载时可还原原规则。",'
    'uninstallLabel:"卸载 Cursor",versions:['
    '{name:"Cursor 破甲 V4",desc:"寒霜 v4 规范注入 Cursor 全局规则（推荐）",file:"寒霜v4.md",recommended:!0},'
    '{name:"Cursor 破甲 V3",desc:"寒霜 v3 规范注入 Cursor 全局规则",file:"寒霜v3.md"}]}'
)

OPENCODE_ENTRY = (
    ',{id:"opencode",icon:"Oc",nav:"OpenCode 破甲",eyebrow:"OPENCODE 破甲",title:"OpenCode 破甲",'
    'desc:"寒霜工作规范注入 ~/.config/opencode/AGENTS.md（带 HANSHUANG-INJECT 标记块，'
    '你自己的内容保留），技能同步到 ~/.config/opencode/skills；卸载可还原原文件。",'
    'uninstallLabel:"卸载 OpenCode",versions:['
    '{name:"OpenCode 破甲 V4",desc:"寒霜工作规范 v4 → AGENTS.md + V4 技能库（推荐）",'
    'file:"寒霜v4.md",recommended:!0},'
    '{name:"OpenCode 破甲 V3",desc:"寒霜工作规范 v3 → AGENTS.md",file:"寒霜v3.md"}]}'
)

# ---------------------------------------------------------------- 2. 图标映射
ICON_MAP_OLD = "jg={codex:cr,zcode:Sg,cursor:Tg,claude:Ng,"
ICON_MAP_NEW = "jg={codex:cr,zcode:Sg,cursor:Tg,opencode:Tg,claude:Ng,"

# ---------------------------------------------------------------- 3. 使用教程
TUTORIAL_ANCHOR = ',"永久免费       QQ群819678765"].join'
TUTORIAL_INSERT = (
    ',"","OpenCode 注入：点 OpenCode 卡片安装，写入 ~/.config/opencode/AGENTS.md '
    '+ 技能库（~/.config/opencode/skills，可用 XDG_CONFIG_HOME 改根目录），'
    '重启 opencode 生效"\n'
)

FAILS = []


def sub(text, old, new, label, count=1):
    global FAILS
    n = text.count(old)
    if n != count:
        FAILS.append(f"[{label}] 期望 {count} 处、实际 {n} 处")
        return text
    return text.replace(old, new)


def main() -> int:
    bundle = find_bundle()
    src = bundle.read_text(encoding="utf-8")
    patched = 'id:"opencode"' in src

    if "--check" in sys.argv:
        print(f"{bundle.name}: {'已打补丁' if patched else '未打补丁'}")
        return 0 if patched else 1

    if patched:
        print(f"{bundle.name}: 已包含 OpenCode 目标，跳过")
        return 0

    out = sub(src, CURSOR_ENTRY, CURSOR_ENTRY + OPENCODE_ENTRY, "目标数组")
    out = sub(out, ICON_MAP_OLD, ICON_MAP_NEW, "图标映射")
    out = sub(out, TUTORIAL_ANCHOR, TUTORIAL_INSERT + TUTORIAL_ANCHOR, "使用教程文案")

    if FAILS:
        print("打补丁失败（bundle 结构已变，锚点没命中）：")
        for f in FAILS:
            print("  -", f)
        return 1

    # 兜底：改动只应新增内容，长度必须变大，且目标总数必须 +1
    if len(out) <= len(src):
        print("打补丁失败：bundle 长度没有增加")
        return 1
    if out.count('id:"') != src.count('id:"') + 1:
        print("打补丁失败：目标数量不是 +1")
        return 1

    bundle.write_text(out, encoding="utf-8")
    print(f"ok  {bundle.name}  已插入 OpenCode 目标（{len(src)} -> {len(out)} 字节）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
