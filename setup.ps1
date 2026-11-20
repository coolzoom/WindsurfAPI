# WindsurfAPI Windows 一键脚本 —— setup.sh 的 Windows 版。
# 菜单:[1] 配置环境 / [2] 编译打包 / [3] 启动服务 / [4] 一键全部(1→2→3)
#      / [5] 状态检查 / [6] 重启服务 / [7] 停止服务 / [0] 退出。
# 双击 setup.bat 启动(.bat 全 ASCII,中文只在本 .ps1,避免 GBK 码页乱码)。
# 本文件必须以 UTF-8 带 BOM 保存,否则 Win PowerShell 5.1 按 ANSI 误读中文字面量。

$ErrorActionPreference = 'Stop'
# 控制台按 UTF-8 输出,否则中文文案在默认 GBK/936 码页的 cmd 窗口里显示为乱码。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root    = $PSScriptRoot
Set-Location $Root
$EnvPath = Join-Path $Root '.env'
$ExePath = Join-Path $Root 'dist-windows\windsurfapi.exe'

function Pause-Back {
  Write-Host ''
  Write-Host '按任意键返回菜单...' -ForegroundColor DarkGray
  $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Test-Node {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
  $raw = (& node -v) -replace '^v', ''
  try { return [version]$raw } catch { return $null }
}

function Assert-Node {
  $v = Test-Node
  if (-not $v) {
    Write-Host '[X] 未检测到 Node.js。请安装 Node 22.13+: https://nodejs.org' -ForegroundColor Red
    return $null
  }
  if ($v -lt [version]'22.13.0') {
    Write-Host "[X] Node v$v 过低,需 >= 22.13。" -ForegroundColor Red
    return $null
  }
  return $v
}

# 强随机密钥(RandomNumberGenerator,非 Get-Random)。
function New-Secret([int]$bytes = 24) {
  $buf = New-Object 'System.Byte[]' $bytes
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($buf); $rng.Dispose()
  return ([Convert]::ToBase64String($buf)) -replace '\+', '-' -replace '/', '_' -replace '=', ''
}

# ⚠️ 必须无 BOM 写(UTF8Encoding($false))。写后 best-effort 收紧 ACL 为仅当前用户
# (.env 存 API_KEY / DASHBOARD_PASSWORD);失败只警告,不让密钥已写好的引导失败。
function Write-EnvFile([string[]]$lines) {
  $text = ($lines -join "`r`n") + "`r`n"
  [System.IO.File]::WriteAllText($EnvPath, $text, (New-Object System.Text.UTF8Encoding($false)))
  $aclUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
  try { & icacls $EnvPath /inheritance:r /grant:r "${aclUser}:(F)" *> $null } catch { }
}

function Read-EnvMap([string]$path) {
  $map = @{}
  foreach ($l in (Get-Content $path -Encoding UTF8)) {
    $t = $l.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $eq = $t.IndexOf('='); if ($eq -lt 1) { continue }
    $map[$t.Substring(0, $eq).Trim()] = $t.Substring($eq + 1).Trim()
  }
  return $map
}

# ── Devin 本机账号注入 ───────────────────────────────────────
# Devin Desktop 把 session 存在 %APPDATA%\Devin\User\globalStorage\state.vscdb
# 的 windsurfAuthStatus 键里,形如 {"apiKey":"devin-session-token$<JWT>",...}。
# devin-session-token$ 就是 DEVIN_CONNECT 要的上游 apiKey(auth.js
# addAccountByPastedSecret 的 session 分支直接 addAccountByKey)。
# FileShare.ReadWrite:Devin 运行中 SQLite 被独占,普通 ReadAllBytes 会失败。
function Get-DevinSessionToken {
  $vscdb = Join-Path $env:APPDATA 'Devin\User\globalStorage\state.vscdb'
  if (-not (Test-Path $vscdb)) { return $null }
  try {
    $fs = [IO.File]::Open($vscdb, 'Open', 'Read', 'ReadWrite')
    $buf = New-Object byte[] $fs.Length
    [void]$fs.Read($buf, 0, $fs.Length); $fs.Close()
    $txt = [Text.Encoding]::UTF8.GetString($buf)
    $tok = [regex]::Matches($txt, 'devin-session-token\$[A-Za-z0-9_\-.]+') |
      ForEach-Object { $_.Value } | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $tok) { return $null }
    $server = 'https://server.codeium.com'
    $m = [regex]::Match($txt, '"apiServerUrl"\s*:\s*"([^"]+)"')
    if ($m.Success) { $server = $m.Groups[1].Value }
    return @{ token = $tok; apiServerUrl = $server }
  } catch { return $null }
}

# 向运行中的网关 POST /dashboard/api/accounts(操作员鉴权走 x-dashboard-password)。
# addAccountByKey 按 apiKey 去重,重复注入返回既有账号,幂等。
function Import-DevinAccount([string]$baseUrl, [string]$dashPassword) {
  $cred = Get-DevinSessionToken
  if (-not $cred) { return 'notfound' }
  try {
    $body = @{ api_key = $cred.token; label = 'devin-desktop-local'; apiServerUrl = $cred.apiServerUrl } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$baseUrl/dashboard/api/accounts" -Method POST `
      -ContentType 'application/json' -Headers @{ 'x-dashboard-password' = $dashPassword } `
      -Body $body -TimeoutSec 15
  } catch { return "error: $($_.Exception.Message)" }
}

# 后台 job:轮询 /health 等服务就绪,账号池为空则注入本机 Devin token。
# Invoke-Start 阻塞跑 node/exe 前调用;进程退出后 job 随脚本结束。
function Start-AccountInjector([string]$baseUrl, [string]$dashPassword) {
  Start-Job -ScriptBlock {
    param($baseUrl, $pw)
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
      try {
        $h = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 3
        if ($h.accounts.total -eq 0) {
          $vscdb = Join-Path $env:APPDATA 'Devin\User\globalStorage\state.vscdb'
          if (Test-Path $vscdb) {
            $fs = [IO.File]::Open($vscdb, 'Open', 'Read', 'ReadWrite')
            $buf = New-Object byte[] $fs.Length
            [void]$fs.Read($buf, 0, $fs.Length); $fs.Close()
            $txt = [Text.Encoding]::UTF8.GetString($buf)
            $tok = [regex]::Matches($txt, 'devin-session-token\$[A-Za-z0-9_\-.]+') |
              ForEach-Object { $_.Value } | Sort-Object Length -Descending | Select-Object -First 1
            $server = 'https://server.codeium.com'
            $m = [regex]::Match($txt, '"apiServerUrl"\s*:\s*"([^"]+)"')
            if ($m.Success) { $server = $m.Groups[1].Value }
            if ($tok) {
              $body = @{ api_key = $tok; label = 'devin-desktop-local'; apiServerUrl = $server } | ConvertTo-Json
              Invoke-RestMethod -Uri "$baseUrl/dashboard/api/accounts" -Method POST `
                -ContentType 'application/json' -Headers @{ 'x-dashboard-password' = $pw } `
                -Body $body -TimeoutSec 15 | Out-Null
            }
          }
        }
        return
      } catch { Start-Sleep -Milliseconds 800 }
    }
  } -ArgumentList $baseUrl, $dashPassword | Out-Null
}

# ── [1] 配置环境(对标 setup.sh 的 4 步)─────────────────────────
function Invoke-Setup {
  Write-Host ''
  Write-Host '===== [1] 配置环境 =====' -ForegroundColor Cyan

  $nv = Assert-Node
  if ($nv) {
    Write-Host "[OK] Node.js v$nv" -ForegroundColor Green
  } else {
    Write-Host '     .env 仍会生成,但编译/启动需要 Node。' -ForegroundColor Yellow
  }

  # language_server 仅 Linux/macOS(config.js defaultLsBinaryPath)——
  # Windows 上唯一可用后端是 DEVIN_CONNECT(纯 HTTP,无需二进制)。
  Write-Host '[OK] 后端:DEVIN_CONNECT(纯 HTTP,Windows 无 language_server)' -ForegroundColor Green

  New-Item -ItemType Directory -Force -Path (Join-Path $Root 'logs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP 'windsurf-workspace') | Out-Null
  Write-Host '[OK] 目录:logs\ 与 %TEMP%\windsurf-workspace' -ForegroundColor Green

  $genApiKey = $null; $genPassword = $null

  if (-not (Test-Path $EnvPath)) {
    # 全新生成(对标 setup.sh 的 .env 模板;密钥直接生成,空值会 fail-closed)。
    $genApiKey   = 'sk-windsurf-' + (New-Secret 24)
    $genPassword = New-Secret 18
    Write-EnvFile @(
      'PORT=3003',
      'HOST=127.0.0.1',
      '# Empty API_KEY is fail-closed (401) even on 127.0.0.1.',
      "API_KEY=$genApiKey",
      'DATA_DIR=',
      '# Must be a DEVIN_CONNECT-resolvable name. Matches src/config.js when unset.',
      'DEFAULT_MODEL=claude-sonnet-4.6',
      'MAX_TOKENS=8192',
      'LOG_LEVEL=info',
      '# Empty DASHBOARD_PASSWORD is fail-closed even on localhost.',
      "DASHBOARD_PASSWORD=$genPassword",
      'ALLOW_PRIVATE_PROXY_HOSTS=',
      '',
      '# ===== Backend: DEVIN_CONNECT (only working backend on Windows) =====',
      '# Pure HTTP to Devin cloud - Windows has no language_server binary',
      '# (Linux/macOS only). Add an account via the dashboard login page,',
      '# or scripts/devin-connect-login.mjs.',
      'DEVIN_CONNECT=1',
      'DEVIN_CONNECT_AUTO_RELOGIN=1',
      '# Required for auto-relogin to actually persist credentials (32+ chars):',
      '# DEVIN_CONNECT_CRED_KEY=',
      '',
      '# ===== Legacy Cascade backend (language server, Linux/macOS only) =====',
      '# LS_BINARY_PATH=/opt/windsurf/language_server_linux_x64',
      '# LS_DATA_DIR=/opt/windsurf/data',
      '# LS_PORT=42100'
    )
    Write-Host '[OK] 已生成 .env(含强随机 API_KEY / DASHBOARD_PASSWORD)' -ForegroundColor Green
  }
  else {
    # 已存在:只补关键缺失键,不动用户已设值(对齐 deploy/windows/start.ps1)。
    $lines   = @(Get-Content $EnvPath -Encoding UTF8)
    $existing = Read-EnvMap $EnvPath
    function Need([string]$k) { (-not $existing.ContainsKey($k)) -or [string]::IsNullOrWhiteSpace($existing[$k]) }

    $add = @()
    if (Need 'PORT')     { $add += 'PORT=3003' }
    # HOST=127.0.0.1 必需:默认 0.0.0.0 + 空 API_KEY = fail-closed 锁死。
    if (Need 'HOST')     { $add += 'HOST=127.0.0.1' }
    if (Need 'API_KEY')  { $genApiKey = 'sk-windsurf-' + (New-Secret 24); $add += "API_KEY=$genApiKey" }
    if (Need 'DASHBOARD_PASSWORD') { $genPassword = New-Secret 18; $add += "DASHBOARD_PASSWORD=$genPassword" }
    if ((Need 'DEVIN_CONNECT') -and (Need 'DEVIN_ONLY')) { $add += 'DEVIN_CONNECT=1'; $add += 'DEVIN_CONNECT_AUTO_RELOGIN=1' }

    if ($add.Count -gt 0) {
      $out = New-Object System.Collections.Generic.List[string]
      foreach ($l in $lines) { $out.Add($l) }
      if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out.Add('') }
      $out.Add("# --- added by setup.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ---")
      foreach ($a in $add) { $out.Add($a) }
      Write-EnvFile $out.ToArray()
      Write-Host "[OK] .env 已补齐 $($add.Count) 个缺失键" -ForegroundColor Green
    } else {
      Write-Host '[OK] .env 已存在且关键项齐全,未改动' -ForegroundColor Green
    }
  }

  $cfg = Read-EnvMap $EnvPath
  $port     = if ($cfg['PORT']) { $cfg['PORT'] } else { '3003' }
  $hostVal  = if ($cfg['HOST']) { $cfg['HOST'] } else { '0.0.0.0' }
  $dispHost = if ($hostVal -eq '0.0.0.0') { '127.0.0.1' } else { $hostVal }

  if ($genPassword -or $genApiKey) {
    Write-Host ''
    Write-Host '################################################################' -ForegroundColor Green
    Write-Host '#            已为你自动生成密钥(请截图妥善保存)              #' -ForegroundColor Green
    Write-Host '################################################################' -ForegroundColor Green
    Write-Host ''
    if ($genPassword) {
      Write-Host '  面板登录密码 (DASHBOARD_PASSWORD):' -ForegroundColor Yellow
      Write-Host "     $genPassword" -ForegroundColor White
    }
    if ($genApiKey) {
      Write-Host '  网关调用密钥 (API_KEY,给 Claude Code / SDK 用):' -ForegroundColor Yellow
      Write-Host "     $genApiKey" -ForegroundColor White
    }
    Write-Host '  密钥已写入项目根 .env,下次启动沿用。' -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host "  >> 面板地址:http://${dispHost}:$port/dashboard" -ForegroundColor Cyan

  # 本机 Devin 账号注入:服务已在跑且池为空 → 立即注入;否则 [3]/[4] 启动时自动补。
  $baseUrl = "http://127.0.0.1:$port"
  $dashPw  = if ($cfg['DASHBOARD_PASSWORD']) { $cfg['DASHBOARD_PASSWORD'] } else { '' }
  $running = $false
  try { $h = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 2; $running = $true } catch { }
  if ($running) {
    if ($h.accounts.total -gt 0) {
      Write-Host "  >> 账号池已有 $($h.accounts.total) 个账号,跳过自动注入" -ForegroundColor DarkGray
    } elseif (-not $dashPw) {
      Write-Host '  [!] DASHBOARD_PASSWORD 为空,无法自动注入账号(面板会 fail-closed)。' -ForegroundColor Yellow
    } else {
      $res = Import-DevinAccount $baseUrl $dashPw
      if ($res -eq 'notfound') {
        Write-Host '  [!] 未在本机找到 Devin session(state.vscdb 无 token),请到面板手动加号。' -ForegroundColor Yellow
      } elseif ($res -is [string]) {
        Write-Host "  [!] 账号注入失败:$res" -ForegroundColor Yellow
      } else {
        Write-Host "  >> 已注入本机 Devin 账号:$($res.account.email) [$($res.account.status)]" -ForegroundColor Green
      }
    }
  } else {
    Write-Host '  >> 服务未在运行:启动([3]/[4])时会自动注入本机 Devin 账号(若存在)。' -ForegroundColor DarkGray
  }
  return $true
}

# ── [2] 编译打包(对标 release.yml windows-exe job)──────────────
function Invoke-Build {
  Write-Host ''
  Write-Host '===== [2] 编译打包 =====' -ForegroundColor Cyan

  if (-not (Assert-Node)) { return $false }
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host '[X] 未找到 npm(随 Node.js 安装)。' -ForegroundColor Red
    return $false
  }

  # 工具链与 CI 同 pin(release.yml):esbuild 把 ESM 树打成一个 CJS 文件,
  # 再由 @yao-pkg/pkg 包成单 exe。pkg 首次构建需联网下载 node22 基座。
  $needInstall = (-not (Get-Command esbuild -ErrorAction SilentlyContinue)) -or
                 (-not (Get-Command pkg     -ErrorAction SilentlyContinue))
  if ($needInstall) {
    Write-Host '[..] 安装构建工具:npm i -g @yao-pkg/pkg@6.21.0 esbuild@0.28.1'
    & npm i -g '@yao-pkg/pkg@6.21.0' 'esbuild@0.28.1'
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[X] 构建工具安装失败(需要网络)。' -ForegroundColor Red
      return $false
    }
  }

  Write-Host '[..] npm run build:exe(esbuild bundle → pkg node22-win-x64,首次较慢)'
  & npm run build:exe
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ExePath)) {
    Write-Host '[X] 构建失败,未生成 dist-windows\windsurfapi.exe' -ForegroundColor Red
    return $false
  }
  $sizeMB = [math]::Round((Get-Item $ExePath).Length / 1MB, 1)
  Write-Host "[OK] 已生成 $ExePath(${sizeMB} MB)" -ForegroundColor Green

  # 与 CI 相同的冒烟:boot + /health + dashboard 资源(端口 3999,独立临时数据目录)。
  Write-Host '[..] 冒烟校验 exe(scripts/exe-boot-smoke.mjs)'
  & node scripts\exe-boot-smoke.mjs $ExePath
  if ($LASTEXITCODE -eq 0) {
    Write-Host '[OK] 冒烟通过' -ForegroundColor Green
  } else {
    Write-Host '[!] 冒烟未通过,exe 可能无法正常启动(日志见上)。' -ForegroundColor Yellow
  }
  return $true
}

# ── 服务状态(端口归属 + 可选 /health 探活)────────────────────
# 端口以 .env 的 PORT 为准(默认 3003)。-Probe 才打 /health(慢——
# 菜单顶栏每次重绘都调本函数,不能每次等 HTTP)。
function Get-ServiceState([switch]$Probe) {
  $cfg  = if (Test-Path $EnvPath) { Read-EnvMap $EnvPath } else { @{} }
  $port = if ($cfg['PORT']) { [int]$cfg['PORT'] } else { 3003 }
  $state = [pscustomobject]@{
    port = $port; listening = $false; pid = $null; procName = $null; cmdline = ''; health = $null
  }
  $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
  if ($listeners.Count -gt 0) {
    $state.listening = $true
    $state.pid = @($listeners | ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)[0]
    try {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction Stop
      $state.procName = $proc.Name
      $state.cmdline  = [string]$proc.CommandLine
    } catch {
      $state.procName = (Get-Process -Id $state.pid -ErrorAction SilentlyContinue).ProcessName
    }
    if ($Probe) {
      try { $state.health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 } catch { }
    }
  }
  return $state
}

# ── [5] 状态检查 ─────────────────────────────────────────────
function Invoke-Status {
  Write-Host ''
  Write-Host '===== [5] 状态检查 =====' -ForegroundColor Cyan
  Write-Host ''
  $s = Get-ServiceState -Probe
  if (-not $s.listening) {
    Write-Host "  [X] 服务未运行(端口 $($s.port) 无监听者)" -ForegroundColor Red
    Write-Host '      用 [3] 启动,或 [6] 重启。' -ForegroundColor DarkGray
    return
  }
  $mode = if ($s.cmdline -match 'windsurfapi\.exe') { '打包 exe (dist-windows)' }
          elseif ($s.cmdline -match 'src[\\/]index\.js') { 'node 源码模式 (src/index.js)' }
          else { '未知进程' }
  Write-Host "  [OK] 服务运行中 —— 端口 $($s.port) 监听中" -ForegroundColor Green
  Write-Host "      PID:      $($s.pid) ($($s.procName))"
  Write-Host "      模式:     $mode"
  Write-Host "      命令行:   $($s.cmdline)" -ForegroundColor DarkGray
  if ($s.health) {
    $h = $s.health
    Write-Host "      /health:  status=$($h.status)  version=$($h.version)  uptime=$([int]$h.uptime)s  accounts=$($h.accounts.total)(active=$($h.accounts.active))" -ForegroundColor Green
  } else {
    Write-Host '      /health:  无响应 —— 端口被占但服务未就绪(可能在重试或假死)' -ForegroundColor Yellow
  }
  Write-Host ''
  Write-Host "  >> 面板:  http://127.0.0.1:$($s.port)/dashboard" -ForegroundColor Cyan
}

# 停掉占用服务端口的所有进程并等端口释放。[6] 重启的内部步骤。
function Stop-WindsurfService {
  $s = Get-ServiceState
  if (-not $s.listening) { Write-Host '  服务未在运行,无需停止。' -ForegroundColor DarkGray; return $true }
  $pids = @(Get-NetTCPConnection -LocalPort $s.port -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { $_.OwningProcess } | Sort-Object -Unique)
  foreach ($p in $pids) {
    $pn = (Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName
    try {
      Write-Host "  [..] 停止 PID $p ($pn)..."
      Stop-Process -Id $p -Force -ErrorAction Stop
    } catch {
      Write-Host "  [!] 停止 PID $p 失败:$($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-NetTCPConnection -LocalPort $s.port -State Listen -ErrorAction SilentlyContinue)) { return $true }
    Start-Sleep -Milliseconds 300
  }
  Write-Host '  [!] 端口仍未释放,放弃启动新实例。' -ForegroundColor Yellow
  return $false
}

# ── [7] 停止服务(按端口关闭占用进程,不影响其它 node/exe)───
function Invoke-Stop {
  Write-Host ''
  Write-Host '===== [7] 停止服务 =====' -ForegroundColor Cyan
  if (Stop-WindsurfService) {
    Write-Host '  [OK] 服务已停止。' -ForegroundColor Green
  }
}

# ── [6] 重启服务(先按端口杀掉旧实例,再走 [3] 的启动流程)────
function Invoke-Restart {
  Write-Host ''
  Write-Host '===== [6] 重启服务 =====' -ForegroundColor Cyan
  if (Stop-WindsurfService) {
    Write-Host '  [OK] 旧实例已停止,端口已释放。' -ForegroundColor Green
    Invoke-Start
  }
}

# ── [3] 启动服务(前台,Ctrl-C 停)───────────────────────────────
function Invoke-Start {
  Write-Host ''
  Write-Host '===== [3] 启动服务 =====' -ForegroundColor Cyan

  # 端口已有人监听 → 新实例只会空转重试绑定(node/exe 各自重试 10 次再死),
  # 先拦下提醒,避免「启动了两份还不知道」。
  $pre = Get-ServiceState
  if ($pre.listening) {
    Write-Host "[!] 端口 $($pre.port) 已被占用:PID $($pre.pid)($($pre.procName))。" -ForegroundColor Yellow
    Write-Host '    到 [5] 查看状态,或用 [6] 重启替换它。' -ForegroundColor Yellow
    $ans = Read-Host '    仍要强行再启一个实例吗?(y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { return }
  }

  if (-not (Test-Path $EnvPath)) {
    Write-Host '[!] 未找到 .env —— 空密钥 fail-closed,建议先执行 [1] 配置环境。' -ForegroundColor Yellow
  }

  # 后台注入器:等服务就绪后,若账号池为空则自动写入本机 Devin token。
  $cfgS = if (Test-Path $EnvPath) { Read-EnvMap $EnvPath } else { @{} }
  $portS = if ($cfgS['PORT']) { $cfgS['PORT'] } else { '3003' }
  $dashPwS = if ($cfgS['DASHBOARD_PASSWORD']) { $cfgS['DASHBOARD_PASSWORD'] } else { '' }
  if ($dashPwS) {
    Start-AccountInjector "http://127.0.0.1:$portS" $dashPwS
    Write-Host '[OK] 已注册账号自动注入(就绪后若池为空,写入本机 Devin 账号)' -ForegroundColor Green
  } else {
    Write-Host '[!] 无 DASHBOARD_PASSWORD,跳过账号自动注入' -ForegroundColor DarkGray
  }

  if (Test-Path $ExePath) {
    # 打包 exe 读「同目录」.env(IS_PACKAGED 路径),不读项目根的;
    # 同目录没有就把根 .env 复制过去,保持与 [1] 打印的同一组密钥。
    $exeEnv = Join-Path (Split-Path $ExePath) '.env'
    if ((Test-Path $EnvPath) -and -not (Test-Path $exeEnv)) {
      Copy-Item $EnvPath $exeEnv
      Write-Host "[OK] 已复制 .env 到 exe 同目录:$exeEnv" -ForegroundColor Green
    }
    Write-Host "[>>] 启动 $ExePath(Ctrl-C 停止)" -ForegroundColor Cyan
    Write-Host ''
    & $ExePath
    Write-Host ''
    Write-Host '[OK] 服务已退出。' -ForegroundColor Green
    return
  }

  if (-not (Assert-Node)) { return }
  # 与 run.ps1 相同的环境兜底(不覆盖用户显式值;config.js 环境变量优先于 .env)。
  if (-not $env:DEVIN_CONNECT -and -not $env:DEVIN_ONLY) { $env:DEVIN_CONNECT = '1' }
  if (-not $env:LOG_LEVEL)    { $env:LOG_LEVEL = 'info' }
  Write-Host '[>>] 启动 node src\index.js(Ctrl-C 停止)' -ForegroundColor Cyan
  Write-Host '     后台/托盘/开机自启见 deploy\windows\(install-task.bat / tray.vbs)。' -ForegroundColor DarkGray
  Write-Host ''
  & node src\index.js
  Write-Host ''
  Write-Host '[OK] 服务已退出。' -ForegroundColor Green
}

# ── 主菜单 ───────────────────────────────────────────────────
while ($true) {
  Clear-Host
  Write-Host '================================================' -ForegroundColor Cyan
  Write-Host '        WindsurfAPI 一键脚本 (Windows)' -ForegroundColor Cyan
  Write-Host '================================================' -ForegroundColor Cyan

  $stNode = Test-Node
  $stNode = if ($stNode) { "v$stNode" } else { 'NOT FOUND' }
  $stEnv  = if (Test-Path $EnvPath) { 'OK' } else { 'missing' }
  $stExe  = if (Test-Path $ExePath) { 'built' } else { 'none' }
  $svc = Get-ServiceState
  $stSvc = if ($svc.listening) { "run PID $($svc.pid) :$($svc.port)" } else { 'stopped' }
  Write-Host "   Node: $stNode   |   .env: $stEnv   |   exe: $stExe   |   svc: $stSvc" -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '   [1] 配置环境    检查 Node + 生成 .env(自动密钥)'
  Write-Host '   [2] 编译打包    构建 dist-windows\windsurfapi.exe'
  Write-Host '   [3] 启动服务    前台运行(有 exe 用 exe,否则 node)'
  Write-Host '   [4] 一键全部    依次执行 1 -> 2 -> 3'
  Write-Host '   [5] 状态检查    端口 / 进程 / 账号池 / 面板地址'
  Write-Host '   [6] 重启服务    停掉端口占用进程后重新启动'
  Write-Host '   [7] 停止服务    关闭占用该端口的服务进程'
  Write-Host '   [0] 退出'
  Write-Host ''

  switch ((Read-Host '请选择').Trim()) {
    '1' { [void](Invoke-Setup); Pause-Back }
    '2' { [void](Invoke-Build); Pause-Back }
    '3' { Invoke-Start; Pause-Back }
    '4' {
      [void](Invoke-Setup)
      [void](Invoke-Build)
      Invoke-Start
      Pause-Back
    }
    '5' { Invoke-Status; Pause-Back }
    '6' { Invoke-Restart; Pause-Back }
    '7' { Invoke-Stop; Pause-Back }
    { $_ -in '0', 'q', 'Q', 'exit', 'quit' } { exit 0 }
    default { }
  }
}
