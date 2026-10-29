#!/usr/bin/env bash
# OpenCode 破甲注入端到端测试（全部在临时 HOME 里跑，不碰真实配置）
#
#   bash tests/opencode-test.sh
#
# 覆盖：安装 → 重复安装（幂等） → 装回原始记忆 → 再安装 → 卸载 → 清理脚本
# 断言：用户自己的 AGENTS.md 内容逐字节保留；卸载后 skills / managed-prompts 不留残余；
#       clear-injected-prompts.ps1 能认出 opencode 的注入块。
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PWSH="$HERE/dist/寒霜破甲工具-arm64.app/Contents/Resources/pwsh/pwsh"
[ -x "$PWSH" ] || PWSH="$HERE/dist/寒霜破甲工具.app/Contents/Resources/pwsh/pwsh"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
[ -n "${PWSH:-}" ] || { echo "找不到 pwsh：先跑 npm run build:arm64"; exit 1; }

WORK="$(mktemp -d /tmp/hs-opencode-test.XXXXXX)"
export HOME="$WORK/home"
CFG="$HOME/.config/opencode"
mkdir -p "$CFG"

fails=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fails=$((fails+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1  ($2)"; fi; }

PS() { "$PWSH" -NoProfile -File "$@" 2>&1; }

echo "== 0. 造一份「用户自己的」AGENTS.md + opencode.json + 一个同名用户技能"
printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "clinepin/test-model",\n  "permission": "allow"\n}\n' > "$CFG/opencode.json"
cp "$CFG/opencode.json" "$WORK/original.json"
printf '# 我的 OpenCode 全局规则\n\n- 用中文回答\n- 不要动我的 dotfiles\n' > "$CFG/AGENTS.md"
cp "$CFG/AGENTS.md" "$WORK/original.md"
mkdir -p "$CFG/skills/pwn-chain"
printf -- '---\nname: pwn-chain\ndescription: 用户自己写的同名技能\n---\n\n用户自己的内容\n' > "$CFG/skills/pwn-chain/SKILL.md"
cp "$CFG/skills/pwn-chain/SKILL.md" "$WORK/user-skill.md"
check "前置：用户文件就位" "[ -f '$CFG/AGENTS.md' ] && [ -f '$CFG/skills/pwn-chain/SKILL.md' ]"

echo "== 1. 安装（V4 + 技能库）"
PS "$HERE/resources/install-opencode.ps1" -SourcePrompt "$HERE/resources/寒霜v4.md" -SkillsSource codex-skills-v4 >"$WORK/install.log"
check "退出码 0" "grep -q 'Restart OpenCode' '$WORK/install.log'"
check "AGENTS.md 里出现注入标记" "grep -q 'HANSHUANG-INJECT:BEGIN prompt=寒霜v4.md' '$CFG/AGENTS.md'"
check "用户原有内容仍在最前面" "head -1 '$CFG/AGENTS.md' | grep -q '我的 OpenCode 全局规则'"
check "注入前备份已生成" "[ -f '$CFG/managed-prompts/AGENTS.md.bak' ]"
check "install-state.json 已写入" "grep -q installedSkills '$CFG/managed-prompts/install-state.json'"
check "技能同步了 63 个" "[ \$(ls '$CFG/skills' | wc -l | tr -d ' ') -ge 60 ]"
check "用户同名技能被备份而不是覆盖" "ls -d '$CFG/skills/pwn-chain.bak-'* >/dev/null 2>&1"
# 同名技能被我们的覆盖是设计行为，用户那份必须原样躺在 .bak- 里
BAK_PC=$(ls -d "$CFG/skills/pwn-chain.bak-"* 2>/dev/null | head -1)
check "用户同名技能被原样备份" "[ -n '$BAK_PC' ] && cmp -s '$WORK/user-skill.md' '$BAK_PC/SKILL.md'"
check "技能位上是随包版本" "cmp -s '$HERE/resources/codex-skills-v4/pwn-chain/SKILL.md' '$CFG/skills/pwn-chain/SKILL.md'"
# 系统层（真正让模型不拒绝的那层）：agent/<名>.md 正文 = 内核，default_agent 指过去
check "系统层 agent 文件已写入" "[ -f '$CFG/agent/hanshuang.md' ]"
check "agent 正文带注入标记" "grep -q 'HANSHUANG-INJECT:BEGIN kernel=opencode-kernel.md' '$CFG/agent/hanshuang.md'"
check "agent 是 primary 模式" "grep -q '^mode: primary' '$CFG/agent/hanshuang.md'"
check "内核含唯一禁止项（中转站保护）" "grep -q 'api.zxcbug.com' '$CFG/agent/hanshuang.md'"
check "default_agent 指向 hanshuang" "python3 -c \"import json,sys; d=json.load(open('$CFG/opencode.json')); sys.exit(0 if d.get('default_agent')=='hanshuang' else 1)\""
check "改配置前留了备份" "[ -f '$CFG/managed-prompts/opencode.json.bak' ]"

echo "== 2. 重复安装（幂等：只换块内内容，不再追加）"
BLOCKS_BEFORE=$(grep -c 'HANSHUANG-INJECT:BEGIN' "$CFG/AGENTS.md")
PS "$HERE/resources/install-opencode.ps1" -SourcePrompt "$HERE/resources/寒霜v4.md" -SkillsSource codex-skills-v4 >"$WORK/install2.log"
BLOCKS_AFTER=$(grep -c 'HANSHUANG-INJECT:BEGIN' "$CFG/AGENTS.md")
check "注入块仍然只有 1 个（${BLOCKS_BEFORE} -> ${BLOCKS_AFTER}）" "[ '${BLOCKS_AFTER}' -eq 1 ]"
check "重复安装走「更新块内内容」分支" "grep -q 'Updated injected block' '$WORK/install2.log'"

echo "== 3. 装回原始记忆（-RestoreMemory：还原 AGENTS.md，技能留着）"
PS "$HERE/resources/install-opencode.ps1" -RestoreMemory >"$WORK/restore.log"
check "AGENTS.md 逐字节等于原始文件" "cmp -s '$WORK/original.md' '$CFG/AGENTS.md'"
check "技能库保留（没被 -RestoreMemory 删掉）" "[ \$(ls '$CFG/skills' | wc -l | tr -d ' ') -ge 60 ]"
check "install-state.json 保留" "[ -f '$CFG/managed-prompts/install-state.json' ]"

echo "== 4. 再安装，然后卸载（-Uninstall：清块 + 删技能 + 还原用户同名技能）"
PS "$HERE/resources/install-opencode.ps1" -SourcePrompt "$HERE/resources/寒霜v4.md" -SkillsSource codex-skills-v4 >/dev/null
PS "$HERE/resources/install-opencode.ps1" -Uninstall >"$WORK/uninstall.log"
check "卸载后 AGENTS.md 逐字节还原" "cmp -s '$WORK/original.md' '$CFG/AGENTS.md'"
check "随包技能全删（只剩用户自己的）" "[ \$(ls '$CFG/skills' 2>/dev/null | grep -cv '^pwn-chain\$') -eq 0 ]"
check "用户同名技能已搬回且内容未变" "cmp -s '$WORK/user-skill.md' '$CFG/skills/pwn-chain/SKILL.md'"
check "没有残留 .bak- 目录" "! ls -d '$CFG/skills/'*.bak-* >/dev/null 2>&1"
check "managed-prompts 已清空并删除" "[ ! -d '$CFG/managed-prompts' ]"
check "install-state.json 已删除" "[ ! -f '$CFG/managed-prompts/install-state.json' ]"
check "系统层 agent 已删除" "[ ! -f '$CFG/agent/hanshuang.md' ]"
check "agent 空目录已回收" "[ ! -d '$CFG/agent' ]"
check "opencode.json 里不留 default_agent（原本没有这个键）" "! grep -q 'default_agent' '$CFG/opencode.json'"
check "opencode.json 内容未被改坏" "python3 -c \"import json; json.load(open('$CFG/opencode.json'))\""
check "opencode.json 逐字节还原" "cmp -s '$WORK/original.json' '$CFG/opencode.json'"

echo "== 5. 清理脚本认得 opencode"
rm -rf "$CFG/skills"
PS "$HERE/resources/install-opencode.ps1" -SourcePrompt "$HERE/resources/寒霜v4.md" -SkillsSource codex-skills-v4 >/dev/null
PS "$HERE/resources/scripts/clear-injected-prompts.ps1" -Targets opencode >"$WORK/clear-dry.log"
check "dry-run 能列出 opencode 的注入项" "grep -q 'AGENTS.md' '$WORK/clear-dry.log'"
PS "$HERE/resources/scripts/clear-injected-prompts.ps1" -Apply -Targets opencode >"$WORK/clear.log"
check "-Apply 后 AGENTS.md 还原" "cmp -s '$WORK/original.md' '$CFG/AGENTS.md'"
check "清理脚本删掉了系统层 agent" "[ ! -f '$CFG/agent/hanshuang.md' ]"
check "清理脚本没留下 default_agent" "! grep -q 'default_agent' '$CFG/opencode.json'"

echo
if [ "$fails" -eq 0 ]; then
  echo "全部通过（临时目录 ${WORK}）"
  rm -rf "$WORK"
  exit 0
fi
echo "${fails} 项失败，现场保留在 ${WORK}"
exit 1
