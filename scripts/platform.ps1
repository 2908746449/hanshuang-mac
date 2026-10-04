# platform.ps1 —— Windows / macOS 差异适配层
#
# 构建时由 scripts/build.mjs（或移植脚本 port.py）复制到 resources/platform.ps1，
# 再由同目录下各 install*.ps1 以 `. $hsPlatformFile` 点入执行。
# 目的：脚本主体（4200+ 行已验证逻辑）一行不改，把所有 Windows 专有语义收敛到这里。
#
# 覆盖的 Windows 语义：
#   1. 环境变量：USERPROFILE / APPDATA / LOCALAPPDATA / ProgramFiles / SystemDrive / TEMP
#   2. 目录镜像复制：robocopy /E /MIR  =>  rsync -a [--delete]
#   3. 固定磁盘枚举：[IO.DriveInfo]::GetDrives()  =>  Unix 无盘符概念，返回空
#   4. 已安装程序定位：注册表 Uninstall 键  =>  /Applications/*.app 扫描
#   5. 应用启动/重启：Start-Process *.exe  =>  open -a
#
# 注意：Unix 下路径分隔符是 '/'，脚本里所有 Join-Path 的字面量子路径都已统一为 '/'
#      （'/' 在 Windows 上同样合法，因此改动对 Windows 版无副作用）。

$script:HSPlatform = 'unknown'

if ($PSVersionTable.PSEdition -eq 'Desktop' -or $PSVersionTable.PSVersion.Major -lt 6) {
  # Windows PowerShell 5.1：一定是 Windows
  $script:HSPlatform = 'win'
} elseif ((Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows) {
  $script:HSPlatform = 'win'
} elseif ((Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS) {
  $script:HSPlatform = 'mac'
} else {
  $script:HSPlatform = 'unix'
}

function Test-HsWindows {
  return ($script:HSPlatform -eq 'win')
}

# ---------- 1. 环境变量别名 ----------
# Windows 脚本里大量使用 $env:APPDATA / $env:LOCALAPPDATA / $env:USERPROFILE。
# macOS 上这些变量不存在，Join-Path 拿到 $null 会直接抛错。这里补上等价目录：
#   APPDATA / LOCALAPPDATA  -> ~/Library/Application Support
#   USERPROFILE             -> $HOME
#   ProgramFiles            -> /Applications
#   SystemDrive             -> /
#   TEMP                    -> 系统临时目录
function Initialize-HsPlatformEnv {
  if (Test-HsWindows) { return }

  if (-not $env:USERPROFILE) { $env:USERPROFILE = $HOME }

  $appSupport = Join-Path $HOME 'Library/Application Support'
  if (-not $env:APPDATA) { $env:APPDATA = $appSupport }
  if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $appSupport }

  if (-not $env:ProgramFiles) { $env:ProgramFiles = '/Applications' }
  try {
    if (-not [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) {
      [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', '/Applications')
      ${env:ProgramFiles(x86)} = '/Applications'
    }
  } catch { }

  if (-not $env:SystemDrive) { $env:SystemDrive = '/' }
  if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd([char]47) }
  if (-not $env:TMP) { $env:TMP = $env:TEMP }
}

# ---------- 2. 目录镜像复制 ----------
function Copy-HsTree {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Src,
    [Parameter(Mandatory = $true)][string]$Dest,
    # /MIR 语义：目标目录里不属于源的文件一并删除
    [switch]$Mirror
  )

  if (-not (Test-Path -LiteralPath $Src)) { throw "Copy-HsTree: 源目录不存在: $Src" }
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null

  if (Test-HsWindows) {
    $rargs = @($Src, $Dest, '/E', '/MT:16', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP')
    if ($Mirror) { $rargs += '/MIR' }
    & robocopy @rargs | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE for $Src" }
    return
  }

  # Unix：rsync -a（等价 /E），--delete（等价 /MIR）
  $srcArg = $Src.TrimEnd([char]47) + '/'
  $dstArg = $Dest.TrimEnd([char]47) + '/'
  $rargs = @('-a')
  if ($Mirror) { $rargs += '--delete' }
  $rargs += @($srcArg, $dstArg)

  $rsync = Get-Command -Name rsync -ErrorAction SilentlyContinue
  if ($rsync) {
    & rsync @rargs 2>&1 | Out-Null
    # rsync 退出码 24 = 复制期间源文件消失（可容忍）；其余非 0 走原生兜底
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 24) { return }
  }

  # 兜底：PowerShell 原生递归复制
  Get-ChildItem -LiteralPath $Src -Force -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force -ErrorAction Stop
  }
  if ($Mirror) {
    # 原生复制不会删多余文件，这里补一次差异删除（只删源里没有的同名条目）
    $srcNames = @(Get-ChildItem -LiteralPath $Src -Force -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty Name)
    Get-ChildItem -LiteralPath $Dest -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($srcNames -notcontains $_.Name) {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

# ---------- 3. 固定磁盘枚举 ----------
# Windows 版拿盘符去猜「.codex 被迁到哪个盘」。Unix 没有盘符概念，
# 返回空数组即可 —— 调用方的 `foreach ($d in @())` 自然不循环，落到默认 ~/.codex。
function Get-HsFixedDriveRoots {
  if (Test-HsWindows) {
    return @(
      [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName }
    )
  }
  return @()
}

# Windows 版用 <SystemDrive>\Users 扫描「其他账户」的数据目录；macOS 上是 /Users。
function Get-HsUsersRoot {
  if (Test-HsWindows) {
    if ($env:SystemDrive) { return (Join-Path $env:SystemDrive 'Users') }
    return 'C:\Users'
  }
  return '/Users'
}

# ---------- 4. 已安装程序定位 ----------
# Windows：注册表 Uninstall 键；macOS：/Applications 与 ~/Applications 下的 .app
function Find-HsAppInstallLocation {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string[]]$Names)

  if (Test-HsWindows) {
    $keys = @(
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = @()
    foreach ($k in $keys) {
      $items += @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)
    }
    foreach ($n in $Names) {
      foreach ($i in $items) {
        if ($i.DisplayName -and $i.DisplayName -like "*$n*") {
          if ($i.InstallLocation) { return [string]$i.InstallLocation }
        }
      }
    }
    return $null
  }

  $roots = @('/Applications', (Join-Path $HOME 'Applications'))
  foreach ($n in $Names) {
    foreach ($r in $roots) {
      if (-not (Test-Path -LiteralPath $r)) { continue }
      $hit = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.app' -and $_.Name -like "*$n*" } |
        Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
  }
  return $null
}

# 给出候选名列表，返回第一个真实存在的路径。
# 候选既可能是 .exe（Windows 词表）也可能是 .app（macOS 词表），
# 调用方把两套词表都传进来，这里按「存在与否」挑。
function Resolve-HsAppPath {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string[]]$Candidates)

  foreach ($c in $Candidates) {
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    if (Test-Path -LiteralPath $c) { return $c }
  }
  return $null
}

# ---------- 5. 应用启动 / 重启 ----------
# Windows 用 Start-Process <exe>；macOS 用 open -a <app 名或路径>
function Start-HsApp {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string[]]$Arguments = @()
  )

  if (Test-HsWindows) {
    if ($Arguments.Count -gt 0) {
      Start-Process -FilePath $Target -ArgumentList $Arguments
    } else {
      Start-Process -FilePath $Target
    }
    return $true
  }

  $open = Get-Command -Name open -ErrorAction SilentlyContinue
  if (-not $open) { return $false }
  $oargs = @('-a', $Target)
  if ($Arguments.Count -gt 0) { $oargs += '--args'; $oargs += $Arguments }
  & open @oargs 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}

# 按进程名终止（Unix 用 pkill，Windows 用 Stop-Process）
function Stop-HsProcess {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string[]]$Names)

  if (Test-HsWindows) {
    foreach ($n in $Names) {
      Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    return
  }
  foreach ($n in $Names) {
    & pkill -f $n 2>&1 | Out-Null
  }
}

Initialize-HsPlatformEnv
