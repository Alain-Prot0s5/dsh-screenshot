#requires -version 5.1
<#
  dsh-screenshot.ps1 — 截图自动粘贴到 DeepSeek Harness 输入框（热键 + 输入框按钮双入口）

  热键流程（默认 Alt+A）:
    - 触发时 DSH 在前台 → 打开系统截图（ms-screenclip:，不注入按键）→ 等剪贴板出现新图片
      → 激活 DSH → 自动 Ctrl+V 粘贴
    - 触发时 DSH 不在前台 → 只打开系统截图（图留在剪贴板，不切换窗口、不自动粘贴）
    - 单飞防抖：一次截图流程进行中，新触发忽略；等待是非阻塞的，期间热键/按钮照常响应

  输入框按钮流程（DSH Web 插件 dsh-screenshot 调用）:
    本脚本同时在本机启动一个轻量 HTTP 触发服务（默认 http://127.0.0.1:17890/trigger），
    按钮点击 → 请求该地址 → 走上面的聚焦感知流程（按钮点击时 DSH 必在前台）。

  微信冲突:
    Windows 全局热键"先到先得"。微信占用 Alt+A 时本脚本注册失败(1409)，自动进入等待态：
    微信运行期间不抢，微信退出后自动接管。彻底解法：改微信 设置→快捷键。

  静音: 默认不发声（$Config.Beep = $false 可开启）。
  改热键: 改 $Config.Modifiers / $Config.Vk。
#>
[CmdletBinding()]
param(
  [switch]$DryRun,              # 测试模式：只记录日志，不真正发送按键/截图
  [switch]$ExitWhenDshGone,     # 绑定 DSH Desktop 生命周期：DSH 进程消失约 8 秒后本脚本自动退出
  [int]$HotkeyModifiers = -1,   # 热键修饰键覆盖（-1 = 用脚本默认），由插件设置页传入
  [int]$HotkeyVk = -1,          # 热键键码覆盖（-1 = 用脚本默认）
  [switch]$NoAutoPaste,         # 关闭自动粘贴（只截图，图片留在剪贴板）
  [switch]$SwitchWhenBackground # DSH 在后台时也跳到前台并自动粘贴
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$LogFile = Join-Path $ScriptDir 'dsh-screenshot.log'

# ================= 可配置区（默认值；插件设置页可覆盖） =================
$Config = @{
  Modifiers     = 0x0001   # 热键修饰键: 1=Alt 2=Ctrl 4=Shift 8=Win，可相加（Alt+Shift = 5）
  Vk            = 0x41     # 键码: 0x41='A' → 默认 Alt+A；要 Alt+Shift+A 就把 Modifiers 改成 5
  DshProcess    = 'DSH Desktop'        # DSH 桌面版进程名（优先）
  DshTitle      = 'DeepSeek Harness Desktop'  # 窗口标题（精确匹配）
  DshTitleLoose = 'DeepSeek Harness'          # 窗口标题（宽松匹配，兜底）
  WaitSec       = 30       # 截图等待超时（秒），按 Esc 取消会走到超时
  WeChatCheckMs = 2000     # 微信进程检测间隔（毫秒）
  Beep          = $false   # 完成/失败时是否发声（默认静音）
  TriggerPort   = 17890    # 输入框截图按钮触发的本地 HTTP 端口（与插件一致）
  AutoPaste            = $true   # 截图后自动粘贴到输入框（false = 只截图）
  SwitchWhenBackground = $false  # DSH 在后台时也跳到前台并粘贴（true = 自动跳转）
}
# ===========================================
# 插件设置页传入的参数覆盖默认值（不传则保持上面默认）
if ($HotkeyModifiers -ge 0) { $Config.Modifiers = $HotkeyModifiers }
if ($HotkeyVk -ge 0) { $Config.Vk = $HotkeyVk }
$Config.AutoPaste = -not $NoAutoPaste
$Config.SwitchWhenBackground = [bool]$SwitchWhenBackground

# ---------- Win32 互操作 ----------
if (-not ('DshSnipWin' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DshSnipWin
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    public static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateMutex(IntPtr lpMutexAttributes, bool bInitialOwner, string lpName);

    [DllImport("user32.dll")]
    public static extern bool OpenClipboard(IntPtr hWndNewOwner);
    [DllImport("user32.dll")]
    public static extern IntPtr GetClipboardData(uint uFormat);
    [DllImport("user32.dll")]
    public static extern bool CloseClipboard();

    // 主动读一次剪贴板位图数据，迫使 SnippingTool 完成延迟渲染（delayed rendering），
    // 避免"格式已就绪但数据未渲染完"时粘贴落空（间歇性假粘贴的候选根因之一）。
    public static void PinClipboardImage()
    {
        if (!OpenClipboard(IntPtr.Zero)) return;
        try
        {
            foreach (uint fmt in new uint[] { 8, 17, 2 }) // CF_DIB / CF_DIBV5 / CF_BITMAP
            {
                IntPtr h = GetClipboardData(fmt);
                if (h != IntPtr.Zero) break;
            }
        }
        finally { CloseClipboard(); }
    }
}
'@ | Out-Null
}

# ---------- 工具函数 ----------
function Write-Log([string]$Msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
  Write-Host $line
}

function Safe-Beep([int]$freq, [int]$ms) {
  if ($Config.Beep) { try { [Console]::Beep($freq, $ms) } catch { } }
}

function Get-HotkeyName {
  $parts = @()
  if ($Config.Modifiers -band 0x0001) { $parts += 'Alt' }
  if ($Config.Modifiers -band 0x0002) { $parts += 'Ctrl' }
  if ($Config.Modifiers -band 0x0004) { $parts += 'Shift' }
  if ($Config.Modifiers -band 0x0008) { $parts += 'Win' }
  return ($parts -join '+') + '+' + [char]$Config.Vk
}

# ---------- 截图触发与键盘模拟 ----------
# 截图触发用系统 URI ms-screenclip:（纯进程启动，不注入按键，比 Win+Shift+S 可靠）
# 粘贴 Ctrl+V 用 keybd_event（01:14 实测可用）

function Clear-StaleSnippingTool {
  # SnippingTool 卡死（无主窗口且存活>20秒）会吞掉后续截图请求，触发前先清理。
  # 正常截图遮罩/编辑器都有窗口，不受影响。
  $threshold = (Get-Date).AddSeconds(-20)
  Get-Process SnippingTool -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowHandle -eq 0 -and $_.StartTime -lt $threshold
  } | ForEach-Object {
    Write-Log ("清理卡死的 SnippingTool 实例 PID " + $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-SystemSnip {
  Clear-StaleSnippingTool
  try {
    Start-Process explorer.exe -ArgumentList 'ms-screenclip:' -ErrorAction Stop
  } catch {
    Write-Log ("打开系统截图失败（ms-screenclip:）：" + $_.Exception.Message)
  }
}

function Send-VkDown([int]$vk) { [DshSnipWin]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero) }
function Send-VkUp([int]$vk)   { [DshSnipWin]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero) }

function Send-CtrlV {
  Send-VkDown 0x11                      # Ctrl
  Send-VkDown 0x56                      # V
  Start-Sleep -Milliseconds 30
  Send-VkUp 0x56
  Send-VkUp 0x11
}

function Send-AltTap {
  # 按下再松开 Alt，可解除 SetForegroundWindow 的前台切换限制（后台进程抢焦点经典技巧）
  Send-VkDown 0x12
  Start-Sleep -Milliseconds 30
  Send-VkUp 0x12
}

# ---------- DSH 窗口 ----------
function Get-DshWindowHandle {
  $p = Get-Process -ErrorAction SilentlyContinue |
       Where-Object { $_.ProcessName -eq $Config.DshProcess -and $_.MainWindowHandle -ne 0 } |
       Select-Object -First 1
  if (-not $p) {
    $p = Get-Process -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowTitle -eq $Config.DshTitle -and $_.MainWindowHandle -ne 0 } |
         Select-Object -First 1
  }
  if (-not $p) {
    $p = Get-Process -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowTitle -like "*$($Config.DshTitleLoose)*" -and $_.MainWindowHandle -ne 0 } |
         Select-Object -First 1
  }
  if ($p) { return $p.MainWindowHandle }
  return [IntPtr]::Zero
}

function Test-DshFocused {
  $dsh = Get-DshWindowHandle
  if ($dsh -eq [IntPtr]::Zero) { return $false }
  return ([DshSnipWin]::GetForegroundWindow() -eq $dsh)
}

function Set-DshForeground([IntPtr]$hwnd) {
  if ($hwnd -eq [IntPtr]::Zero) { return $false }
  [DshSnipWin]::ShowWindow($hwnd, 9) | Out-Null              # SW_RESTORE（最小化时恢复）
  $fg = [DshSnipWin]::GetForegroundWindow()
  $fgTid = [uint32]0
  if ($fg -ne [IntPtr]::Zero) { [DshSnipWin]::GetWindowThreadProcessId($fg, [ref]$fgTid) | Out-Null }
  $myTid = [DshSnipWin]::GetCurrentThreadId()
  $attached = $false
  if ($fgTid -ne 0 -and $fgTid -ne $myTid) {
    $attached = [DshSnipWin]::AttachThreadInput($myTid, $fgTid, $true)
  }
  Send-AltTap
  [DshSnipWin]::SetForegroundWindow($hwnd) | Out-Null
  [DshSnipWin]::BringWindowToTop($hwnd) | Out-Null
  if ($attached) { [DshSnipWin]::AttachThreadInput($myTid, $fgTid, $false) | Out-Null }
  Start-Sleep -Milliseconds 200
  return $true
}

# ---------- 微信检测 ----------
$WeChatNames = @('wechat', 'weixin', 'wechatappex', 'wechatapp')
function Test-WeChatRunning {
  return [bool](Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $WeChatNames -contains $_.ProcessName.ToLowerInvariant() } |
    Select-Object -First 1)
}

# ---------- 热键所有权管理 ----------
$HotkeyId = 0x5EED
$script:OwnHotkey   = $false
$script:WeChatWarned = $false

function Update-HotkeyOwnership {
  $wc = Test-WeChatRunning
  if ($script:OwnHotkey) {
    if ($wc -and -not $script:WeChatWarned) {
      $script:WeChatWarned = $true
      Write-Log '检测到微信运行：若微信的 Alt+A 截图热键失效，请到 微信→设置→快捷键 修改或关闭，或重启微信。'
    }
    return
  }
  if ($wc) {
    if (-not $script:WeChatWarned) {
      $script:WeChatWarned = $true
      Write-Log '微信正在运行并占用 Alt+A：本脚本暂停注册（不抢），微信退出后自动接管。'
    }
    return
  }
  $ok = [DshSnipWin]::RegisterHotKey([IntPtr]::Zero, $HotkeyId, [uint32]$Config.Modifiers, [uint32]$Config.Vk)
  if ($ok) {
    $script:OwnHotkey = $true
    $script:WeChatWarned = $false
    Write-Log ("已注册全局热键 " + (Get-HotkeyName) + "：DSH 在前台时截图后自动粘贴")
  } else {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (-not $script:WeChatWarned) {
      $script:WeChatWarned = $true
      Write-Log ("热键注册失败 (error=" + $err + ")。若为 1409 = 其他程序占用了 " + (Get-HotkeyName) + '，请关闭占用程序，或修改本脚本顶部 $Config 里的 Modifiers/Vk 换一个热键。')
    }
  }
}

# ---------- 截图→粘贴主流程（热键与按钮共用，聚焦感知 + 非阻塞等待 + 单飞防抖） ----------
$script:SnipPending    = $false
$script:PasteActive   = $false   # 图像就绪→Ctrl+V 完成期间保持 true，供 /health 报告给客户端焦点守护
$script:SnipSeqBefore  = [uint32]0
$script:SnipDeadline   = $null
$script:SnipStartedAt  = $null
$script:SnipSawProcess = $false   # 触发后是否见过 SnippingTool 进程（区分"冷启动未弹出"与"弹出后已退出"）

function Start-Snip([string]$Source = '') {
  $tag = if ($Source) { '（' + $Source + '）' } else { '' }
  # 单飞：一次截图流程进行中，忽略新触发（防止连击叠层/攒单补发）
  # 注意：截图取消（Esc/关闭遮罩）后 Tick-SnipPending 会立即复位，不会卡 30 秒
  if ($script:SnipPending) {
    Write-Log '已有截图流程进行中，忽略本次触发（防重复）'
    return
  }
  if ($DryRun) {
    Write-Log ("DRY-RUN" + $tag + "：DSH 前台=" + (Test-DshFocused) + "，本应触发截图流程")
    return
  }
  # 是否走"截图→自动粘贴"：需开启自动粘贴，且（DSH 在前台 或 开启后台跳转）
  $focused = Test-DshFocused
  $doPaste = $Config.AutoPaste -and ($focused -or $Config.SwitchWhenBackground)
  if (-not $doPaste) {
    Write-Log ('触发截图' + $tag + '：未满足自动粘贴条件（未开启自动粘贴，或 DSH 在后台且未开启跳转）→ 仅打开系统截图（图片留在剪贴板）')
    Invoke-SystemSnip
    return
  }
  Write-Log ('触发截图' + $tag + '：截图并自动粘贴到输入框')
  $script:SnipSeqBefore  = [DshSnipWin]::GetClipboardSequenceNumber()
  $script:SnipDeadline   = (Get-Date).AddSeconds($Config.WaitSec)
  $script:SnipStartedAt  = Get-Date
  $script:SnipSawProcess = $false
  $script:SnipPending    = $true
  Invoke-SystemSnip
}

function Tick-SnipPending {
  # 主循环每轮调用；等待期间热键/按钮触发服务照常工作（非阻塞）
  if (-not $script:SnipPending) { return }
  $hasImg = [DshSnipWin]::IsClipboardFormatAvailable(8)  -or   # CF_DIB
            [DshSnipWin]::IsClipboardFormatAvailable(17) -or   # CF_DIBV5
            [DshSnipWin]::IsClipboardFormatAvailable(2)        # CF_BITMAP
  if ($hasImg -and [DshSnipWin]::GetClipboardSequenceNumber() -ne $script:SnipSeqBefore) {
    $script:SnipPending = $false
    $script:PasteActive = $true   # 粘贴完成前保持 pending：客户端焦点守护（window.focus → /health）依赖它
    # 图片已进剪贴板。绝不杀 SnippingTool：它可能用延迟渲染提供剪贴板数据，
    # 杀掉会导致粘贴进 DSH 的图片损坏（手动 Ctrl+V 正常、自动粘贴损坏即此原因）。
    $hwnd = Get-DshWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) {
      Write-Log '未找到 DSH 窗口：截图已在剪贴板，请手动 Ctrl+V。'
      $script:PasteActive = $false
      Safe-Beep 200 700
      return
    }
    # 置前台 + 校验：SetForegroundWindow 对后台进程可能被系统忽略，失败就重试；
    # 未确认 DSH 在前台就盲发 Ctrl+V 会误粘到其它窗口（极端情况在 explorer 里产生文件）。
    Set-DshForeground $hwnd | Out-Null
    $foregroundOk = $false
    for ($i = 0; $i -lt 3; $i++) {
      Start-Sleep -Milliseconds 150
      if ([DshSnipWin]::GetForegroundWindow() -eq $hwnd) { $foregroundOk = $true; break }
      Set-DshForeground $hwnd | Out-Null
    }
    if (-not $foregroundOk) {
      Write-Log '警告：DSH 窗口未在前台（重试 3 次仍失败），跳过粘贴避免误粘到其它窗口'
      $script:PasteActive = $false
      Safe-Beep 320 200
      return
    }
    # 主动读一次剪贴板位图：迫使 SnippingTool 完成延迟渲染（delayed rendering），
    # 避免"格式已就绪但数据未渲染完"就粘贴导致落空。
    [DshSnipWin]::PinClipboardImage() | Out-Null
    # 多等一会儿：让 DSH webview 完成激活与焦点恢复（截图遮罩开合后的竞态窗口）。
    Start-Sleep -Milliseconds 400
    Send-CtrlV
    $script:PasteActive = $false
    Write-Log '已粘贴到 DSH 输入框 ✓'
    Safe-Beep 1200 120
    return
  }
  # 取消检测（过了 3 秒宽限后生效；宽限期内让截图工具冷启动，避免误判）
  $st = Get-Process SnippingTool -ErrorAction SilentlyContinue
  if ($st) { $script:SnipSawProcess = $true }
  if ((Get-Date) -ge $script:SnipStartedAt.AddSeconds(3)) {
    if (-not $st) {
      # 形态A：见过进程但现在一个都没有 → 截图工具已退出（取消）
      if ($script:SnipSawProcess) {
        $script:SnipPending = $false
        Write-Log '检测到截图已取消（截图工具已关闭且未出图），可立即重新触发'
        Safe-Beep 240 150
        return
      }
    } else {
      # 形态B：进程还在但全部无窗口 → 遮罩已关闭（取消）
      $withWindow = $st | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
      if (-not $withWindow) {
        $script:SnipPending = $false
        Write-Log '检测到截图已取消（遮罩关闭且未出图），可立即重新触发'
        $st | Stop-Process -Force -ErrorAction SilentlyContinue
        Safe-Beep 240 150
        return
      }
    }
  }
  if ((Get-Date) -ge $script:SnipDeadline) {
    $script:SnipPending = $false
    Write-Log ("等待截图超时（" + $Config.WaitSec + " 秒）——可能按了 Esc 取消，未粘贴。")
    Safe-Beep 320 250
    Safe-Beep 240 250
  }
}

# ---------- 本地触发服务（供 DSH 输入框截图按钮调用） ----------
# 不启用额外线程：在主循环里用 Pending() 非阻塞轮询，避免 PS 5.1 裸线程崩溃。
$TriggerFile = Join-Path $env:TEMP 'dsh-screenshot-trigger'
$script:TriggerListener = $null

function Start-TriggerServer {
  try {
    $script:TriggerListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Config.TriggerPort)
    $script:TriggerListener.Start()
    Write-Log ("本地触发服务已启动: http://127.0.0.1:" + $Config.TriggerPort + "/trigger（DSH 输入框截图按钮调用）")
  } catch {
    Write-Log ("本地触发端口 " + $Config.TriggerPort + " 启动失败（可能被占用），截图按钮将不可用")
    $script:TriggerListener = $null
  }
}

function Serve-TriggerRequest {
  if ($null -eq $script:TriggerListener -or -not $script:TriggerListener.Pending()) { return }
  $client = $null
  try {
    $client = $script:TriggerListener.AcceptTcpClient()
    $client.ReceiveTimeout = 1500
    $stream = $client.GetStream()
    $buf = New-Object byte[] 4096
    $read = 0
    try { $read = $stream.Read($buf, 0, $buf.Length) } catch { }
    $head = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
    $path = '/'
    if ($head -match '^GET\s+(\S+)') { $path = $Matches[1] }
    $status = '200 OK'
    $body = ''
    if ($path -eq '/trigger') {
      try { [System.IO.File]::WriteAllText($TriggerFile, '1') } catch { }
      $body = '{"ok":true}'
    } elseif ($path -eq '/health') {
      $pend = if ($script:SnipPending -or $script:PasteActive) { 'true' } else { 'false' }
      $body = '{"ok":true,"running":true,"pending":' + $pend + '}'
    } else {
      $status = '404 Not Found'
      $body = '{"ok":false,"error":"not found"}'
    }
    $payload = [System.Text.Encoding]::UTF8.GetBytes($body)
    $resp = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nAccess-Control-Allow-Origin: *`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($resp)
    $stream.Write($headBytes, 0, $headBytes.Length)
    $stream.Write($payload, 0, $payload.Length)
    $stream.Flush()
  } catch { }
  if ($client) { try { $client.Close() } catch { } }
}

# ---------- 主循环 ----------
function Main {
  # 单实例保护
  $null = [DshSnipWin]::CreateMutex([IntPtr]::Zero, $true, 'Local\DSH_Screenshot_Hotkey')
  if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -eq 183) {
    Write-Host 'dsh-screenshot 已在运行（单实例）。'
    exit 0
  }
  Write-Log '======== dsh-screenshot 启动 ========'
  Start-TriggerServer
  Write-Log ("模式：热键=" + (Get-HotkeyName) + " 自动粘贴=" + $Config.AutoPaste + " 后台跳转粘贴=" + $Config.SwitchWhenBackground)
  $script:tick = 0
  $script:dshGoneCount = 0
  if ($ExitWhenDshGone) { Write-Log '已绑定 DSH Desktop 生命周期：DSH 退出后本脚本自动退出' }
  Update-HotkeyOwnership
  while ($true) {
    $msg = New-Object 'DshSnipWin+MSG'
    while ([DshSnipWin]::PeekMessage([ref]$msg, [IntPtr]::Zero, 0, 0, 1)) {
      if ($msg.message -eq 0x0312) { Start-Snip -Source '热键' }   # WM_HOTKEY
      [DshSnipWin]::TranslateMessage([ref]$msg) | Out-Null
      [DshSnipWin]::DispatchMessage([ref]$msg) | Out-Null
      $msg = New-Object 'DshSnipWin+MSG'
    }
    # 输入框按钮触发（本地 HTTP 触发服务写入触发文件，主循环消费）
    Serve-TriggerRequest
    if (Test-Path $TriggerFile) {
      Remove-Item $TriggerFile -Force -ErrorAction SilentlyContinue
      Start-Snip -Source '按钮'
    }
    # 截图等待（非阻塞：每轮只查一次剪贴板，等待期间热键/按钮照常响应）
    Tick-SnipPending
    $script:tick += 200
    if ($script:tick -ge $Config.WeChatCheckMs) {
      $script:tick = 0
      Update-HotkeyOwnership
      # DSH 生命周期看门狗：连续约 8 秒检测不到 DSH Desktop 进程 → 退出
      if ($ExitWhenDshGone) {
        $dshProc = Get-Process -Name $Config.DshProcess -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dshProc) { $script:dshGoneCount = 0 } else { $script:dshGoneCount++ }
        if ($script:dshGoneCount -ge 4) {
          Write-Log 'DSH Desktop 已退出，监听器随之退出'
          exit 0
        }
      }
    }
    Start-Sleep -Milliseconds 200
  }
}

Main
