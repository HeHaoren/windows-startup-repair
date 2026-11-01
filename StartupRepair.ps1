#requires -Version 5.1
<#
.SYNOPSIS
    Windows 自启动修复工具 —— 扫描、诊断并修复"应用设置了自启却不开机启动"的问题。
.DESCRIPTION
    覆盖范围:
      - 注册表 Run 键(HKCU / HKLM 64位 / HKLM 32位 WOW6432Node)
      - 用户与公共启动文件夹(.lnk 及其他文件)
      - 登录/开机触发的计划任务(排除 \Microsoft\ 系统任务)
      - StartupApproved 残留标记(条目已被删除但禁用标记还在)
    诊断类型:
      - 已禁用          —— 任务管理器/系统设置中被关掉的启动项
      - 文件缺失        —— 目标程序不存在
      - 需要管理员权限  —— 程序要求提权,挂在 Run 键/启动文件夹会被系统静默跳过
      - 任务已禁用      —— 计划任务被禁用
      - 任务目标缺失    —— 计划任务指向的程序不存在
      - 残留标记        —— 自启条目本体已不存在(可能被清理软件删除)
    所有修复前自动备份到 backups\ 目录,支持从最近备份恢复。
.NOTES
    正常使用:双击 StartupRepair.bat(自动请求管理员权限)。
    只读命令行模式:powershell -ExecutionPolicy Bypass -File StartupRepair.ps1 -ScanOnly
#>
param(
    [switch]$ScanOnly
)

$ErrorActionPreference = 'Stop'

# ============ 全局状态 ============
# 运行目录:ps1 模式用 $PSScriptRoot;ps2exe 打包后该变量不可靠,回退到 exe 所在目录
$script:BaseDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:BaseDir)) {
    try { $script:BaseDir = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { $script:BaseDir = '' }
}
$script:BackupRoot = Join-Path $script:BaseDir 'backups'
try {
    if (-not (Test-Path -LiteralPath $script:BackupRoot -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
} catch {
    # 所在目录不可写(如被放进 Program Files)时,回退到用户本地数据目录
    $script:BackupRoot = Join-Path $env:LOCALAPPDATA 'WindowsStartupRepair\backups'
    if (-not (Test-Path -LiteralPath $script:BackupRoot -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
}
$script:LogBox = $null
$script:StatusLabel = $null
$script:GridTable = $null
$script:Grid = $null

# ============ 高 DPI 适配 ============
# 1) 启用 .NET 4.7+ WinForms 高 DPI 自动缩放(必须在创建任何控件之前设置)
try { [AppContext]::SetSwitch('Switch.System.Windows.Forms.EnableWindowsFormsHighDpiAutoResizing', $true) } catch {}
# 2) 进程级 Per-Monitor V2 感知(逐显示器矢量缩放,Win10 1703+);失败则回退 System DPI Aware
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class StartupRepairDpi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(int dpiAwarenessContext);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction Stop
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    if (-not [StartupRepairDpi]::SetProcessDpiAwarenessContext(-4)) {
        [StartupRepairDpi]::SetProcessDPIAware() | Out-Null
    }
} catch {}

# ============ 自启位置定义 ============
$script:RunLocations = @(
    [pscustomobject]@{
        Id = 'Run-HKCU'; Label = '注册表 Run · 当前用户'
        Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    }
    [pscustomobject]@{
        Id = 'Run-HKLM64'; Label = '注册表 Run · 所有用户'
        Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    }
    [pscustomobject]@{
        Id = 'Run-HKLM32'; Label = '注册表 Run · 所有用户 (32位)'
        Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
        Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
    }
)

$script:FolderLocations = @(
    [pscustomobject]@{
        Id = 'Folder-User'; Label = '启动文件夹 · 当前用户'
        Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
        Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }
    [pscustomobject]@{
        Id = 'Folder-Common'; Label = '启动文件夹 · 所有用户'
        Path = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
        Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    }
)

$script:ActionText = @{
    EnableApproved = '重新启用启动项'
    ConvertToTask  = '转为计划任务(最高权限)并移除原条目'
    EnableTask     = '启用计划任务'
    DeleteDead     = '删除失效条目'
    DeleteOrphan   = '清理残留标记'
    None           = ''
}

# ============ 基础工具函数 ============

function Find-LocationById([string]$id) {
    foreach ($loc in $script:RunLocations) { if ($loc.Id -eq $id) { return $loc } }
    foreach ($loc in $script:FolderLocations) { if ($loc.Id -eq $id) { return $loc } }
    return $null
}

function Get-LocationLabel([string]$id) {
    if ($id -eq 'Task') { return '计划任务 · 登录时' }
    $loc = Find-LocationById $id
    if ($null -ne $loc) { return $loc.Label }
    return $id
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 让界面线程在长循环中处理重绘与消息,避免"未响应";控制台模式下无 Forms 程序集,静默跳过
function Invoke-UiPump {
    try { [System.Windows.Forms.Application]::DoEvents() } catch {}
}

function ConvertFrom-HexString([string]$hex) {
    $hex = ($hex -replace '[^0-9A-Fa-f]', '')
    if ($hex.Length % 2 -ne 0) { $hex = '0' + $hex }
    $bytes = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }
    return ,$bytes
}

function ConvertTo-HexString([byte[]]$bytes) {
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

# 把命令行拆成 目标程序 + 参数;支持引号路径和未加引号的带空格路径(贪婪回退)
function Split-CommandLine([string]$cmd) {
    $result = [pscustomobject]@{ Target = $null; Arguments = '' }
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $result }
    $expanded = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
    $target = $null
    $rest = ''
    if ($expanded.StartsWith('"')) {
        $m = [regex]::Match($expanded, '^"([^"]+)"\s*(.*)$')
        if ($m.Success) { $target = $m.Groups[1].Value; $rest = $m.Groups[2].Value }
    }
    if ($null -eq $target) {
        $tokens = $expanded -split '\s+'
        $target = $tokens[0]
        $rest = ($tokens | Select-Object -Skip 1) -join ' '
    }
    if (-not (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue)) {
        $tokens = $expanded -split '\s+'
        for ($i = $tokens.Count; $i -ge 1; $i--) {
            $cand = ($tokens | Select-Object -First $i) -join ' '
            if (Test-Path -LiteralPath $cand -ErrorAction SilentlyContinue) {
                $target = $cand
                $rest = ($tokens | Select-Object -Skip $i) -join ' '
                break
            }
        }
    }
    $result.Target = $target
    $result.Arguments = $rest
    return $result
}

# 展开环境变量;裸命令名(如 cmd)通过 PATH 解析为完整路径
function Resolve-Target([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return $target }
    $target = [Environment]::ExpandEnvironmentVariables($target)
    if (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) { return $target }
    if ($target -notmatch '[\\/]') {
        $c = Get-Command $target -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $c -and $c.CommandType -eq 'Application') { return $c.Source }
    }
    return $target
}

# 计划任务 Execute 字段可能带引号、含转义双反斜杠,统一规整
function Normalize-TaskPath([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $s = $s.Trim().Trim('"')
    if (-not $s.StartsWith('\\')) { $s = $s -replace '\\\\', '\' }
    return $s
}

# ---------- 检测程序清单是否要求管理员权限 ----------

$script:AdminCache = @{}
$script:ManifestApi = $null
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StartupRepairManifest {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr FindResource(IntPtr hModule, IntPtr lpName, IntPtr lpType);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LockResource(IntPtr hResData);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeLibrary(IntPtr hModule);

    public static string ReadManifest(string path) {
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, 0x2);
        if (h == IntPtr.Zero) return null;
        try {
            IntPtr res = FindResource(h, new IntPtr(1), new IntPtr(24));
            if (res == IntPtr.Zero) return null;
            uint size = SizeofResource(h, res);
            if (size == 0 || size > 1048576) return null;
            IntPtr ptr = LockResource(LoadResource(h, res));
            if (ptr == IntPtr.Zero) return null;
            byte[] bytes = new byte[size];
            Marshal.Copy(ptr, bytes, 0, (int)size);
            return System.Text.Encoding.UTF8.GetString(bytes);
        } finally { FreeLibrary(h); }
    }
}
"@ -ErrorAction Stop
    $script:ManifestApi = [StartupRepairManifest]
} catch {}

# 检测程序清单是否要求管理员权限:只读内嵌清单资源(RT_MANIFEST)和外部 .manifest 文件里的
# requestedExecutionLevel。不做全文件字符串搜索——某些 exe 内部会嵌有 requireAdministrator
# 字样(如自带写清单的模板代码),会造成误报(LosslessScaling 即为此例,其真实清单为 asInvoker)。
# 提取清单中第一个 requestedExecutionLevel 的 level 值。
# 某些程序(如 Lossless Scaling)会在资源里附带多个清单模板(requireAdministrator/highestAvailable 等),
# 只有第一个声明才是程序自己的真实请求级别;全文件匹配会误报。
function Get-FirstManifestLevel([string]$xmlText) {
    if ([string]::IsNullOrWhiteSpace($xmlText)) { return '' }
    $m = [regex]::Match($xmlText, 'requestedExecutionLevel[^>]*?level\s*=\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Test-RequiresAdmin([string]$file) {
    if ([string]::IsNullOrWhiteSpace($file)) { return $false }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf -ErrorAction SilentlyContinue)) { return $false }
    $key = $file.ToLowerInvariant()
    if ($script:AdminCache.ContainsKey($key)) { return $script:AdminCache[$key] }
    $result = $false
    $manifestFile = $file + '.manifest'
    if (Test-Path -LiteralPath $manifestFile -ErrorAction SilentlyContinue) {
        try {
            if ((Get-FirstManifestLevel ([IO.File]::ReadAllText($manifestFile))) -eq 'requireAdministrator') { $result = $true }
        } catch {}
    }
    if (-not $result -and $null -ne $script:ManifestApi) {
        try {
            $xml = $script:ManifestApi::ReadManifest($file)
            if ($null -ne $xml -and (Get-FirstManifestLevel $xml) -eq 'requireAdministrator') { $result = $true }
        } catch {}
    }
    $script:AdminCache[$key] = $result
    return $result
}

# ---------- StartupApproved 状态读取 ----------

function Get-ApprovedBytes([string]$approvedPath, [string[]]$names) {
    if (-not (Test-Path -LiteralPath $approvedPath -ErrorAction SilentlyContinue)) { return $null }
    $props = Get-ItemProperty -LiteralPath $approvedPath -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $null }
    foreach ($n in $names) {
        $p = $props.PSObject.Properties[$n]
        if ($null -ne $p -and $p.Value -is [byte[]]) { return $p.Value }
    }
    return $null
}

# 首字节 0x03(win8+)/0x07(win7)= 禁用;0x02/0x06 = 启用;全 0 = 未设置(视为启用)
function Test-ApprovedDisabled([byte[]]$bytes) {
    if ($null -eq $bytes -or $bytes.Length -lt 2) { return $false }
    return ($bytes[0] -in 0x03, 0x07) -or ($bytes[1] -in 0x03, 0x07)
}

# ============ 条目对象 ============

function New-Entry {
    param($SourceType, $Location, $Name, $Command, $Target, $Arguments, $Source, $TaskPath = '', $TaskState = '')
    [pscustomobject]@{
        SourceType = $SourceType
        Location   = $Location
        Name       = $Name
        Command    = $Command
        Target     = $Target
        Arguments  = $Arguments
        Source     = $Source
        TaskPath   = $TaskPath
        TaskState  = $TaskState
        Status     = 'Normal'
        Detail     = ''
        Action     = 'None'
    }
}

# ============ 扫描函数 ============

function Get-RunEntries {
    $list = @()
    foreach ($loc in $script:RunLocations) {
        $props = Get-ItemProperty -LiteralPath $loc.Path -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $split = Split-CommandLine ([string]$p.Value)
            $list += New-Entry -SourceType 'Run' -Location $loc.Id -Name $p.Name `
                -Command ([string]$p.Value) -Target (Resolve-Target $split.Target) `
                -Arguments $split.Arguments -Source $loc.Path
        }
    }
    return $list
}

function Get-FolderEntries {
    $list = @()
    $shell = $null
    foreach ($loc in $script:FolderLocations) {
        if (-not (Test-Path -LiteralPath $loc.Path -ErrorAction SilentlyContinue)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $loc.Path -File -ErrorAction SilentlyContinue) {
            if ($f.Name -eq 'desktop.ini') { continue }
            $target = $null
            $args = ''
            if ($f.Extension -eq '.lnk') {
                if ($null -eq $shell) { $shell = New-Object -ComObject WScript.Shell }
                try {
                    $sh = $shell.CreateShortcut($f.FullName)
                    $target = [string]$sh.TargetPath
                    $args = [string]$sh.Arguments
                } catch { $target = $f.FullName }
            } else {
                $target = $f.FullName
            }
            $list += New-Entry -SourceType 'Folder' -Location $loc.Id -Name $f.Name `
                -Command $f.FullName -Target (Resolve-Target $target) -Arguments $args -Source $f.FullName
        }
    }
    return $list
}

function Get-TaskEntries {
    $list = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        $isStartup = $false
        foreach ($trig in @($t.Triggers)) {
            if ($trig.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')) { $isStartup = $true; break }
        }
        if (-not $isStartup) { continue }
        $act = @($t.Actions) | Select-Object -First 1
        $target = $null
        $args = ''
        if ($null -ne $act) {
            $target = Resolve-Target (Normalize-TaskPath ([string]$act.Execute))
            $args = [string]$act.Arguments
        }
        $list += New-Entry -SourceType 'Task' -Location 'Task' -Name $t.TaskName `
            -Command ($t.TaskPath + $t.TaskName) -Target $target -Arguments $args `
            -Source $t.TaskPath -TaskPath $t.TaskPath -TaskState ([string]$t.State)
        Invoke-UiPump
    }
    return $list
}

# StartupApproved 里残留的、对应条目已不存在的标记
function Get-OrphanEntries {
    $list = @()
    foreach ($loc in $script:RunLocations) {
        $props = Get-ItemProperty -LiteralPath $loc.Approved -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $live = @{}
        $rp = Get-ItemProperty -LiteralPath $loc.Path -ErrorAction SilentlyContinue
        if ($null -ne $rp) {
            foreach ($p in $rp.PSObject.Properties) {
                if ($p.Name -notlike 'PS*') { $live[$p.Name] = $true }
            }
        }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ($null -ne $live[$p.Name]) { continue }
            $list += New-Entry -SourceType 'Orphan' -Location $loc.Id -Name $p.Name `
                -Command '' -Target $null -Arguments '' -Source $loc.Approved
        }
    }
    foreach ($loc in $script:FolderLocations) {
        $props = Get-ItemProperty -LiteralPath $loc.Approved -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $liveNames = @{}
        foreach ($f in Get-ChildItem -LiteralPath $loc.Path -File -ErrorAction SilentlyContinue) {
            $liveNames[$f.FullName.ToLowerInvariant()] = $true
            $liveNames[$f.Name.ToLowerInvariant()] = $true
        }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $n = $p.Name.Trim().Trim('"')
            $base = [IO.Path]::GetFileName($n)
            $candidates = @($n, ($n + '.lnk'), $base, ($base + '.lnk'))
            $found = $false
            foreach ($c in $candidates) {
                if ($liveNames.ContainsKey($c.ToLowerInvariant())) { $found = $true; break }
            }
            if (-not $found -and -not (Test-Path -LiteralPath $n -ErrorAction SilentlyContinue)) {
                $list += New-Entry -SourceType 'Orphan' -Location $loc.Id -Name $p.Name `
                    -Command '' -Target $null -Arguments '' -Source $loc.Approved
            }
        }
    }
    return $list
}

# ============ 诊断 ============

function Add-Diagnosis($e) {
    $approved = $null
    if ($e.SourceType -eq 'Run') {
        $loc = Find-LocationById $e.Location
        $approved = Get-ApprovedBytes $loc.Approved @($e.Name)
    } elseif ($e.SourceType -eq 'Folder') {
        $loc = Find-LocationById $e.Location
        $approved = Get-ApprovedBytes $loc.Approved @($e.Source, $e.Name)
    }
    if (Test-ApprovedDisabled $approved) {
        $e.Status = 'Disabled'
        $e.Detail = '该启动项在任务管理器/系统设置中被禁用'
        $e.Action = 'EnableApproved'
        return
    }
    switch ($e.SourceType) {
        'Task' {
            if ($e.TaskState -eq 'Disabled') {
                $e.Status = 'TaskDisabled'
                $e.Detail = '计划任务被禁用'
                $e.Action = 'EnableTask'
                return
            }
            if (-not [string]::IsNullOrWhiteSpace($e.Target) -and -not (Test-Path -LiteralPath $e.Target -ErrorAction SilentlyContinue)) {
                $e.Status = 'TaskFileMissing'
                $e.Detail = '任务指向的文件不存在: ' + $e.Target
                $e.Action = 'DeleteDead'
                return
            }
        }
        'Orphan' {
            $e.Status = 'Orphan'
            $e.Detail = '对应的自启条目已不存在(可能被清理软件删除)。如仍需自启,请在应用内重新开启;或勾选清理此残留标记。'
            $e.Action = 'DeleteOrphan'
            return
        }
        default {
            if ([string]::IsNullOrWhiteSpace($e.Target)) { return }
            # URI 类目标(ms-settings: / http: / steam:)不做文件检查
            if ($e.Target -match '^[a-zA-Z][a-zA-Z0-9+.\-]*:(?!\\|/)') { return }
            if (-not (Test-Path -LiteralPath $e.Target -ErrorAction SilentlyContinue)) {
                $e.Status = 'FileMissing'
                $e.Detail = '目标文件不存在: ' + $e.Target
                $e.Action = 'DeleteDead'
                return
            }
            if ($e.SourceType -in @('Run', 'Folder') -and (Test-RequiresAdmin $e.Target)) {
                $e.Status = 'NeedsElevation'
                $e.Detail = '程序要求管理员权限,挂在 Run 键/启动文件夹会被系统静默跳过。建议转为计划任务(最高权限)启动。'
                $e.Action = 'ConvertToTask'
                return
            }
        }
    }
}

function Invoke-ScanEntries {
    $entries = @()
    try { $entries += @(Get-RunEntries) } catch { Write-Warning ('Run 键扫描失败: ' + $_.Exception.Message) }
    try { $entries += @(Get-FolderEntries) } catch { Write-Warning ('启动文件夹扫描失败: ' + $_.Exception.Message) }
    try { $entries += @(Get-TaskEntries) } catch { Write-Warning ('计划任务扫描失败: ' + $_.Exception.Message) }
    try { $entries += @(Get-OrphanEntries) } catch { Write-Warning ('残留标记扫描失败: ' + $_.Exception.Message) }
    foreach ($e in $entries) {
        try { Add-Diagnosis $e } catch { Write-Warning ('诊断失败(' + $e.Name + '): ' + $_.Exception.Message) }
        Invoke-UiPump
    }
    return @($entries)
}

# ============ 备份 / 恢复 ============

function Save-Backup($entries) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $script:BackupRoot $ts
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $items = @()
    $fileIndex = 0
    foreach ($e in $entries) {
        $item = [ordered]@{
            SourceType = $e.SourceType
            Location   = $e.Location
            Name       = $e.Name
            Source     = $e.Source
            TaskPath   = $e.TaskPath
            Action     = $e.Action
        }
        switch ($e.SourceType) {
            'Run' {
                $loc = Find-LocationById $e.Location
                $rp = Get-ItemProperty -LiteralPath $loc.Path -ErrorAction SilentlyContinue
                if ($null -ne $rp) {
                    $p = $rp.PSObject.Properties[$e.Name]
                    if ($null -ne $p) {
                        $item.ValueType = if ($p.Value -is [byte[]]) { 'Binary' } else { 'String' }
                        $item.Value = if ($p.Value -is [byte[]]) { ConvertTo-HexString $p.Value } else { [string]$p.Value }
                    }
                }
                $ab = Get-ApprovedBytes $loc.Approved @($e.Name)
                if ($null -ne $ab) { $item.Approved = ConvertTo-HexString $ab }
            }
            'Orphan' {
                $o = Get-ItemProperty -LiteralPath $e.Source -ErrorAction SilentlyContinue
                if ($null -ne $o) {
                    $p = $o.PSObject.Properties[$e.Name]
                    if ($null -ne $p -and $p.Value -is [byte[]]) {
                        $item.ValueType = 'Binary'
                        $item.Value = ConvertTo-HexString $p.Value
                    }
                }
            }
            'Folder' {
                $fileIndex++
                $copyName = ('file{0:D3}_{1}' -f $fileIndex, ($e.Name -replace '[\\/:*?"<>|]', '_'))
                Copy-Item -LiteralPath $e.Source -Destination (Join-Path $dir $copyName) -Force
                $item.File = $copyName
                $loc = Find-LocationById $e.Location
                $ab = Get-ApprovedBytes $loc.Approved @($e.Source, $e.Name)
                if ($null -ne $ab) { $item.Approved = ConvertTo-HexString $ab }
            }
            'Task' {
                $xml = Export-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath -ErrorAction SilentlyContinue
                if ($null -ne $xml) {
                    $fileIndex++
                    $copyName = ('file{0:D3}_task.xml' -f $fileIndex)
                    Set-Content -LiteralPath (Join-Path $dir $copyName) -Value $xml -Encoding UTF8
                    $item.TaskXml = $copyName
                }
            }
        }
        $items += $item
    }
    $items | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'backup.json') -Encoding UTF8
    return $dir
}

function Invoke-RestoreBackup([string]$dir) {
    $jsonPath = Join-Path $dir 'backup.json'
    if (-not (Test-Path -LiteralPath $jsonPath -ErrorAction SilentlyContinue)) {
        throw '该备份不包含可自动恢复的数据(可能是全量备份,请手动用 reg import 恢复)'
    }
    $items = @(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)
    $results = @()
    foreach ($item in $items) {
        $r = [pscustomobject]@{ Name = $item.Name; Success = $false; Message = '' }
        try {
            switch ($item.SourceType) {
                'Run' {
                    $loc = Find-LocationById $item.Location
                    if ($null -eq $loc) { throw ('未知位置: ' + $item.Location) }
                    if ($null -ne $item.PSObject.Properties['Value']) {
                        if ($item.ValueType -eq 'Binary') {
                            New-ItemProperty -LiteralPath $loc.Path -Name $item.Name -Type Binary -Value (ConvertFrom-HexString $item.Value) -Force | Out-Null
                        } else {
                            New-ItemProperty -LiteralPath $loc.Path -Name $item.Name -Type String -Value ([string]$item.Value) -Force | Out-Null
                        }
                    }
                    if ($null -ne $item.PSObject.Properties['Approved']) {
                        if (-not (Test-Path -LiteralPath $loc.Approved -ErrorAction SilentlyContinue)) { New-Item -Path $loc.Approved -Force | Out-Null }
                        Set-ItemProperty -LiteralPath $loc.Approved -Name $item.Name -Type Binary -Value (ConvertFrom-HexString $item.Approved)
                    }
                }
                'Orphan' {
                    if ($null -ne $item.PSObject.Properties['Value']) {
                        if (-not (Test-Path -LiteralPath $item.Source -ErrorAction SilentlyContinue)) { New-Item -Path $item.Source -Force | Out-Null }
                        Set-ItemProperty -LiteralPath $item.Source -Name $item.Name -Type Binary -Value (ConvertFrom-HexString $item.Value)
                    }
                }
                'Folder' {
                    if ($null -ne $item.PSObject.Properties['File']) {
                        $src = Join-Path $dir $item.File
                        if (Test-Path -LiteralPath $src -ErrorAction SilentlyContinue) {
                            Copy-Item -LiteralPath $src -Destination $item.Source -Force
                        }
                    }
                    $loc = Find-LocationById $item.Location
                    if ($null -ne $loc -and $null -ne $item.PSObject.Properties['Approved']) {
                        if (-not (Test-Path -LiteralPath $loc.Approved -ErrorAction SilentlyContinue)) { New-Item -Path $loc.Approved -Force | Out-Null }
                        Set-ItemProperty -LiteralPath $loc.Approved -Name $item.Source -Type Binary -Value (ConvertFrom-HexString $item.Approved)
                    }
                }
                'Task' {
                    if ($null -ne $item.PSObject.Properties['TaskXml']) {
                        $xml = Get-Content -LiteralPath (Join-Path $dir $item.TaskXml) -Raw
                        Register-ScheduledTask -TaskName $item.Name -TaskPath $item.TaskPath -Xml $xml -Force | Out-Null
                    }
                }
            }
            $r.Success = $true
        } catch {
            $r.Message = '失败: ' + $_.Exception.Message
        }
        $results += $r
    }
    return @($results)
}

# 全量备份:导出全部相关注册表项 + 复制启动文件夹 + 导出相关计划任务 XML
function Invoke-FullBackup {
    $dir = Join-Path $script:BackupRoot ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_full')
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $keys = @()
    foreach ($loc in $script:RunLocations) {
        $keys += @{ Path = $loc.Path; File = ($loc.Id + '.reg') }
        $keys += @{ Path = $loc.Approved; File = ($loc.Id + '_Approved.reg') }
    }
    foreach ($loc in $script:FolderLocations) {
        $keys += @{ Path = $loc.Approved; File = ($loc.Id + '_Approved.reg') }
    }
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k.Path -ErrorAction SilentlyContinue)) { continue }
        $regPath = $k.Path -replace '^([A-Za-z]+):', '$1'
        reg.exe export $regPath (Join-Path $dir $k.File) /y | Out-Null
    }
    foreach ($loc in $script:FolderLocations) {
        if (Test-Path -LiteralPath $loc.Path -ErrorAction SilentlyContinue) {
            Copy-Item -LiteralPath $loc.Path -Destination (Join-Path $dir $loc.Id) -Recurse -Force
        }
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        $isStartup = $false
        foreach ($trig in @($t.Triggers)) {
            if ($trig.CimClass.CimClassName -in @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger')) { $isStartup = $true; break }
        }
        if (-not $isStartup) { continue }
        $xml = Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
        if ($null -ne $xml) {
            $fname = 'task_' + ($t.TaskPath.Trim('\') -replace '\\', '_') + ($t.TaskName -replace '[\\/:*?"<>|]', '_') + '.xml'
            Set-Content -LiteralPath (Join-Path $dir $fname) -Value $xml -Encoding UTF8
        }
        Invoke-UiPump
    }
    return $dir
}

# ============ 修复动作 ============

function Convert-ToScheduledTask($e) {
    $taskName = 'StartupRepair - ' + ($e.Name -replace '[\\/:*?"<>|]', '_')
    $act = New-ScheduledTaskAction -Execute $e.Target
    if (-not [string]::IsNullOrWhiteSpace($e.Arguments)) { $act.Arguments = $e.Arguments }
    $wd = Split-Path -Parent $e.Target
    if (-not [string]::IsNullOrWhiteSpace($wd)) { $act.WorkingDirectory = $wd }
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    if ($e.Location -in @('Run-HKCU', 'Folder-User')) {
        $trig = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $princ = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    } else {
        $trig = New-ScheduledTaskTrigger -AtLogOn
        $princ = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Highest
    }
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trig -Principal $princ -Settings $set -Force | Out-Null
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($t.State -ne 'Ready') { throw ('任务已创建但状态异常: ' + $t.State) }
    # 任务确认创建成功后才移除原条目
    if ($e.SourceType -eq 'Run') {
        $loc = Find-LocationById $e.Location
        Remove-ItemProperty -LiteralPath $loc.Path -Name $e.Name
    } elseif ($e.SourceType -eq 'Folder') {
        Remove-Item -LiteralPath $e.Source -Force
    }
}

function Invoke-Repairs($entries) {
    $results = @()
    foreach ($e in $entries) {
        $r = [pscustomobject]@{ Name = $e.Name; Action = $e.Action; Success = $false; Message = '' }
        try {
            switch ($e.Action) {
                'EnableApproved' {
                    $loc = Find-LocationById $e.Location
                    $valName = if ($e.SourceType -eq 'Folder') { $e.Source } else { $e.Name }
                    if (Test-Path -LiteralPath $loc.Approved -ErrorAction SilentlyContinue) {
                        Set-ItemProperty -LiteralPath $loc.Approved -Name $valName -Type Binary -Value ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                    }
                    $r.Message = '已重新启用(下次登录生效)'
                }
                'ConvertToTask' {
                    Convert-ToScheduledTask $e
                    $r.Message = '已创建计划任务并移除原条目(下次登录生效)'
                }
                'EnableTask' {
                    Enable-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath | Out-Null
                    $r.Message = '计划任务已启用'
                }
                'DeleteDead' {
                    if ($e.SourceType -eq 'Run') {
                        $loc = Find-LocationById $e.Location
                        Remove-ItemProperty -LiteralPath $loc.Path -Name $e.Name
                    } elseif ($e.SourceType -eq 'Folder') {
                        Remove-Item -LiteralPath $e.Source -Force
                    } elseif ($e.SourceType -eq 'Task') {
                        Unregister-ScheduledTask -TaskName $e.Name -TaskPath $e.TaskPath -Confirm:$false
                    }
                    $r.Message = '已删除失效条目'
                }
                'DeleteOrphan' {
                    Remove-ItemProperty -LiteralPath $e.Source -Name $e.Name
                    $r.Message = '已清理残留标记'
                }
                default { $r.Message = '无操作' }
            }
            $r.Success = $true
        } catch {
            $r.Message = '失败: ' + $_.Exception.Message
        }
        $results += $r
    }
    return @($results)
}

# ============ 日志 ============

function Add-Log([string]$msg) {
    $line = ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg)
    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
    } else {
        Write-Host $line
    }
}

# ============ 只读命令行模式 ============

if ($ScanOnly) {
    Write-Output '正在扫描自启动配置(只读,不做任何修改)...'
    Write-Output ('管理员权限: ' + (Test-IsAdmin))
    Write-Output ''
    $entries = Invoke-ScanEntries
    $issues = @($entries | Where-Object { $_.Status -ne 'Normal' })
    Write-Output ('共扫描到 ' + $entries.Count + ' 个自启条目,异常 ' + $issues.Count + ' 个')
    Write-Output ''
    foreach ($e in $entries) {
        Write-Output ('[{0}]  {1}  |  {2}  |  {3}' -f $e.Status, (Get-LocationLabel $e.Location), $e.Name, ('' + $e.Target))
        if (-not [string]::IsNullOrWhiteSpace($e.Detail)) {
            Write-Output ('         ' + $e.Detail)
        }
    }
    return
}

# ============ 图形界面 ============

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-ConfirmForm($entries) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = '确认执行修复'
    $f.Size = New-Object System.Drawing.Size(760, 470)
    $f.MinimumSize = New-Object System.Drawing.Size(640, 360)
    $f.StartPosition = 'CenterParent'
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $f.ShowInTaskbar = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Dock = 'Top'
    $lbl.Height = 46
    $lbl.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
    $lbl.Text = ('即将执行以下 ' + $entries.Count + ' 项操作。执行前会自动备份到 backups\ 目录,可随时从最近备份恢复。')
    $f.Controls.Add($lbl)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.Columns.Add('操作', 240) | Out-Null
    $lv.Columns.Add('位置', 150) | Out-Null
    $lv.Columns.Add('名称', 160) | Out-Null
    $lv.Columns.Add('目标', 200) | Out-Null
    foreach ($e in $entries) {
        $it = $lv.Items.Add($script:ActionText[$e.Action])
        [void]$it.SubItems.Add((Get-LocationLabel $e.Location))
        [void]$it.SubItems.Add($e.Name)
        [void]$it.SubItems.Add([string]$e.Target)
    }
    $f.Controls.Add($lv)

    $pnl = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnl.Dock = 'Bottom'
    $pnl.Height = 48
    $pnl.FlowDirection = 'RightToLeft'
    $pnl.Padding = New-Object System.Windows.Forms.Padding(0, 8, 12, 0)
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '执行'
    $btnOk.DialogResult = 'OK'
    $btnOk.Size = New-Object System.Drawing.Size(110, 30)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.DialogResult = 'Cancel'
    $btnCancel.Size = New-Object System.Drawing.Size(110, 30)
    [void]$pnl.Controls.AddRange([System.Windows.Forms.Control[]]@($btnCancel, $btnOk))
    $f.Controls.Add($pnl)
    $f.AcceptButton = $btnOk
    $f.CancelButton = $btnCancel

    return ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-Gui {
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Windows 自启动修复工具'
    $form.Size = New-Object System.Drawing.Size(1020, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(880, 580)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('Fix', [bool])
    [void]$table.Columns.Add('Location', [string])
    [void]$table.Columns.Add('Name', [string])
    [void]$table.Columns.Add('Target', [string])
    [void]$table.Columns.Add('Status', [string])
    [void]$table.Columns.Add('ActionText', [string])
    [void]$table.Columns.Add('Detail', [string])
    [void]$table.Columns.Add('Entry', [object])
    $script:GridTable = $table

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.AutoGenerateColumns = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToOrderColumns = $true
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.CellBorderStyle = 'SingleHorizontal'
    $script:Grid = $grid

    $colFix = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colFix.HeaderText = '修复'
    $colFix.DataPropertyName = 'Fix'
    $colFix.Width = 44
    $colFix.SortMode = 'Automatic'
    $colLoc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLoc.HeaderText = '位置'
    $colLoc.DataPropertyName = 'Location'
    $colLoc.Width = 160
    $colLoc.ReadOnly = $true
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = '名称'
    $colName.DataPropertyName = 'Name'
    $colName.Width = 170
    $colName.ReadOnly = $true
    $colTarget = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colTarget.HeaderText = '目标程序'
    $colTarget.DataPropertyName = 'Target'
    $colTarget.Width = 270
    $colTarget.ReadOnly = $true
    $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStatus.HeaderText = '状态'
    $colStatus.DataPropertyName = 'Status'
    $colStatus.Width = 120
    $colStatus.ReadOnly = $true
    $colAction = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAction.HeaderText = '建议操作'
    $colAction.DataPropertyName = 'ActionText'
    $colAction.Width = 230
    $colAction.ReadOnly = $true
    $colDetail = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDetail.HeaderText = '说明'
    $colDetail.DataPropertyName = 'Detail'
    $colDetail.ReadOnly = $true
    $colDetail.AutoSizeMode = 'Fill'
    $colEntry = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colEntry.DataPropertyName = 'Entry'
    $colEntry.Visible = $false
    [void]$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colFix, $colLoc, $colName, $colTarget, $colStatus, $colAction, $colDetail, $colEntry))
    $grid.DataSource = $table

    # 顶部按钮区
    $topPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $topPanel.Dock = 'Top'
    $topPanel.Height = 42
    $topPanel.Padding = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
    $topPanel.WrapContents = $false

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = '重新扫描'
    $btnScan.Width = 88
    $btnScan.Height = 30
    $btnFix = New-Object System.Windows.Forms.Button
    $btnFix.Text = '修复选中项'
    $btnFix.Width = 100
    $btnFix.Height = 30
    $btnCheckAll = New-Object System.Windows.Forms.Button
    $btnCheckAll.Text = '全选'
    $btnCheckAll.Width = 60
    $btnCheckAll.Height = 30
    $btnUncheckAll = New-Object System.Windows.Forms.Button
    $btnUncheckAll.Text = '取消全选'
    $btnUncheckAll.Width = 76
    $btnUncheckAll.Height = 30
    $btnBackup = New-Object System.Windows.Forms.Button
    $btnBackup.Text = '全量备份'
    $btnBackup.Width = 88
    $btnBackup.Height = 30
    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = '从最近备份恢复'
    $btnRestore.Width = 128
    $btnRestore.Height = 30
    $btnOpenDir = New-Object System.Windows.Forms.Button
    $btnOpenDir.Text = '打开备份目录'
    $btnOpenDir.Width = 108
    $btnOpenDir.Height = 30
    $chkOnly = New-Object System.Windows.Forms.CheckBox
    $chkOnly.Text = '只显示异常项'
    $chkOnly.Checked = $true
    $chkOnly.AutoSize = $true
    $chkOnly.Margin = New-Object System.Windows.Forms.Padding(18, 6, 0, 0)
    [void]$topPanel.Controls.AddRange([System.Windows.Forms.Control[]]@($btnScan, $btnFix, $btnCheckAll, $btnUncheckAll, $btnBackup, $btnRestore, $btnOpenDir, $chkOnly))

    # 底部日志区
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = 'Bottom'
    $logPanel.Height = 150
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.Dock = 'Fill'
    $logBox.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248)
    $logPanel.Controls.Add($logBox)
    $script:LogBox = $logBox

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = '就绪'
    [void]$statusStrip.Items.Add($statusLabel)
    $script:StatusLabel = $statusLabel

    [void]$form.Controls.Add($grid)
    [void]$form.Controls.Add($topPanel)
    [void]$form.Controls.Add($logPanel)
    [void]$form.Controls.Add($statusStrip)

    # ---------- 表格更新 ----------

    function Update-Grid($entries) {
        $table.Rows.Clear()
        foreach ($e in $entries) {
            $row = $table.NewRow()
            $row.Fix = ($e.Action -in @('EnableApproved', 'ConvertToTask', 'EnableTask'))
            $row.Location = Get-LocationLabel $e.Location
            $row.Name = $e.Name
            $row.Target = if ($null -eq $e.Target) { '' } else { [string]$e.Target }
            $row.Status = switch ($e.Status) {
                'Disabled'      { '已禁用' }
                'FileMissing'   { '文件缺失' }
                'NeedsElevation'{ '需要管理员权限' }
                'TaskDisabled'  { '任务已禁用' }
                'TaskFileMissing'{ '任务目标缺失' }
                'Orphan'        { '残留标记' }
                default         { '正常' }
            }
            $row.ActionText = $script:ActionText[$e.Action]
            $row.Detail = $e.Detail
            $row.Entry = $e
            $table.Rows.Add($row)
        }
        foreach ($r in $grid.Rows) {
            if ($null -eq $r.DataBoundItem) { continue }
            $entry = $r.DataBoundItem.Entry
            if ($null -eq $entry) { continue }
            $color = switch ($entry.Status) {
                'Disabled'       { '#FFF3CD' }
                'FileMissing'    { '#F8D7DA' }
                'NeedsElevation' { '#D1ECF1' }
                'TaskDisabled'   { '#FFF3CD' }
                'TaskFileMissing'{ '#F8D7DA' }
                'Orphan'         { '#E9ECEF' }
                default          { $null }
            }
            if ($null -ne $color) {
                $r.DefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml($color)
            }
            $r.Cells[0].ReadOnly = ($entry.Action -eq 'None')
            if ($entry.Action -eq 'None') { $r.Cells[0].Value = $false }
            $r.Cells[3].ToolTipText = [string]$entry.Target
            $r.Cells[6].ToolTipText = [string]$entry.Detail
        }
        $issueCount = @($entries | Where-Object { $_.Status -ne 'Normal' }).Count
        $script:StatusLabel.Text = ('共 ' + $entries.Count + ' 项,异常 ' + $issueCount + ' 项')
        $script:GridTable.DefaultView.RowFilter = if ($chkOnly.Checked) { "[Status] <> '正常'" } else { '' }
    }

    function Invoke-RefreshScan {
        try {
            $script:StatusLabel.Text = '正在扫描...'
            Invoke-UiPump
            $entries = Invoke-ScanEntries
            Update-Grid $entries
            Add-Log ('扫描完成: 共 ' + $entries.Count + ' 项')
            if (-not (Test-IsAdmin)) {
                Add-Log '警告: 当前未以管理员身份运行,涉及 HKLM/计划任务的修复可能失败。请用 StartupRepair.bat 启动。'
            }
        } catch {
            Add-Log ('扫描出错: ' + $_.Exception.Message)
            [System.Windows.Forms.MessageBox]::Show('扫描出错: ' + $_.Exception.Message, '错误', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }

    # ---------- 事件 ----------

    $btnScan.Add_Click({ Invoke-RefreshScan })

    $chkOnly.Add_CheckedChanged({
        $filter = if ($chkOnly.Checked) { "[Status] <> '正常'" } else { '' }
        $script:GridTable.DefaultView.RowFilter = $filter
        foreach ($r in $grid.Rows) {
            if ($null -eq $r.DataBoundItem) { continue }
            $entry = $r.DataBoundItem.Entry
            if ($null -eq $entry) { continue }
            $color = switch ($entry.Status) {
                'Disabled'       { '#FFF3CD' }
                'FileMissing'    { '#F8D7DA' }
                'NeedsElevation' { '#D1ECF1' }
                'TaskDisabled'   { '#FFF3CD' }
                'TaskFileMissing'{ '#F8D7DA' }
                'Orphan'         { '#E9ECEF' }
                default          { $null }
            }
            if ($null -ne $color) {
                $r.DefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml($color)
            } else {
                $r.DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty
            }
        }
    })

    $btnFix.Add_Click({
        try {
            $selected = @()
            foreach ($r in $table.Rows) {
                if ($r.Fix -eq $true) { $selected += $r.Entry }
            }
            if ($selected.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('请先勾选要修复的条目。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            if (-not (Show-ConfirmForm $selected)) { return }
            Add-Log ('开始备份(' + $selected.Count + ' 项)...')
            $dir = Save-Backup $selected
            Add-Log ('已备份到: ' + $dir)
            $results = Invoke-Repairs $selected
            $okCount = 0
            foreach ($r in $results) {
                if ($r.Success) {
                    $okCount++
                    Add-Log ('[成功] ' + $r.Name + ' — ' + $r.Message)
                } else {
                    Add-Log ('[失败] ' + $r.Name + ' — ' + $r.Message)
                }
            }
            Add-Log ('修复完成: 成功 ' + $okCount + ' / ' + $results.Count)
            Invoke-RefreshScan
        } catch {
            Add-Log ('修复过程出错: ' + $_.Exception.Message)
        }
    })

    $btnCheckAll.Add_Click({
        $count = 0
        foreach ($r in $grid.Rows) {
            if ($null -eq $r.DataBoundItem) { continue }
            $entry = $r.DataBoundItem.Entry
            if ($null -eq $entry -or $entry.Action -eq 'None') { continue }
            $r.DataBoundItem['Fix'] = $true
            $count++
        }
        Add-Log ('已勾选 ' + $count + ' 项(仅当前可见列表)')
    })

    $btnUncheckAll.Add_Click({
        foreach ($r in $grid.Rows) {
            if ($null -ne $r.DataBoundItem) { $r.DataBoundItem['Fix'] = $false }
        }
        Add-Log '已取消全部勾选'
    })

    $btnBackup.Add_Click({
        try {
            $dir = Invoke-FullBackup
            Add-Log ('全量备份完成: ' + $dir)
            [System.Windows.Forms.MessageBox]::Show('全量备份完成:' + [Environment]::NewLine + $dir, '备份', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            Add-Log ('全量备份失败: ' + $_.Exception.Message)
        }
    })

    $btnRestore.Add_Click({
        try {
            $dirs = @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($dirs.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('还没有任何备份。', '提示', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $latest = $dirs[0]
            $ans = [System.Windows.Forms.MessageBox]::Show('将使用最近一次备份恢复:' + [Environment]::NewLine + $latest.Name + [Environment]::NewLine + '是否继续?', '恢复确认', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne 'Yes') { return }
            $results = Invoke-RestoreBackup $latest.FullName
            $okCount = 0
            foreach ($r in $results) {
                if ($r.Success) { $okCount++; Add-Log ('[恢复成功] ' + $r.Name) }
                else { Add-Log ('[恢复失败] ' + $r.Name + ' — ' + $r.Message) }
            }
            Add-Log ('恢复完成: 成功 ' + $okCount + ' / ' + $results.Count)
            Invoke-RefreshScan
        } catch {
            Add-Log ('恢复失败: ' + $_.Exception.Message)
        }
    })

    $btnOpenDir.Add_Click({
        Start-Process explorer.exe -ArgumentList $script:BackupRoot
    })

    $grid.Add_CellDoubleClick({
        param($s, $ev)
        if ($ev.RowIndex -lt 0) { return }
        $entry = $grid.Rows[$ev.RowIndex].DataBoundItem.Entry
        if ($null -eq $entry) { return }
        if (-not [string]::IsNullOrWhiteSpace($entry.Target) -and (Test-Path -LiteralPath $entry.Target -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe -ArgumentList ('/select,"' + $entry.Target + '"')
        } elseif (Test-Path -LiteralPath $entry.Source -ErrorAction SilentlyContinue) {
            Start-Process explorer.exe -ArgumentList ('/select,"' + $entry.Source + '"')
        }
    })

    $form.Add_Shown({ Invoke-RefreshScan })

    [System.Windows.Forms.Application]::Run($form)
}

Show-Gui
