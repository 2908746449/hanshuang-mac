#!/bin/zsh
# 断点续传 + 重试下载（GitHub 走 --noproxy 绕开本地代理的 502）
set -u
VENDOR="$(cd "$(dirname "$0")/.." && pwd)/vendor"
mkdir -p "$VENDOR"

fetch() {
  local url="$1" out="$2"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -sSL --noproxy '*' --http1.1 --retry 3 --retry-all-errors \
         --max-time 1800 -C - -o "$out" "$url"
    local rc=$?
    if [ $rc -eq 0 ]; then
      # 校验：gzip / zip 尾块完整性
      case "$out" in
        *.tar.gz) gzip -t "$out" 2>/dev/null && { echo "OK   $out"; return 0; } ;;
        *.zip)    unzip -t "$out" >/dev/null 2>&1 && { echo "OK   $out"; return 0; } ;;
        *)        echo "OK   $out"; return 0 ;;
      esac
    fi
    echo "retry $i (rc=$rc, $(stat -f%z "$out" 2>/dev/null || echo 0) bytes) $out"
    sleep 2
  done
  echo "FAIL $out"
  return 1
}

PS=v7.6.6
EL=33.4.11
fetch "https://github.com/PowerShell/PowerShell/releases/download/$PS/powershell-7.6.6-osx-arm64.tar.gz" "$VENDOR/pwsh-arm64.tar.gz"
fetch "https://github.com/PowerShell/PowerShell/releases/download/$PS/powershell-7.6.6-osx-x64.tar.gz"   "$VENDOR/pwsh-x64.tar.gz"
fetch "https://github.com/electron/electron/releases/download/v$EL/electron-v$EL-darwin-arm64.zip"      "$VENDOR/electron-darwin-arm64.zip"
fetch "https://github.com/electron/electron/releases/download/v$EL/electron-v$EL-darwin-x64.zip"        "$VENDOR/electron-darwin-x64.zip"
