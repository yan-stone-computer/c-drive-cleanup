# C 盘自动清理与手动操作手册

原则：代理清理可重建缓存；管理员项给出提权命令；不可逆、破坏证据、改系统设置或需要关闭应用的项，必须人工确认。

## 代理可直接清理

普通权限：

- `%LOCALAPPDATA%\Temp`，默认保留最近 24 小时文件。
- `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db`
- `%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db`
- Edge/Chrome 的 `Cache`、`Code Cache`、`GPUCache`、`Service Worker\CacheStorage`

管理员权限：

- `C:\Windows\Temp`
- `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache`
- `C:\Windows\SoftwareDistribution\Download`，仅空闲时，且不停止 BITS/WU 服务

推荐代理命令：

```powershell
$Skill = Join-Path $env:USERPROFILE '.codex\skills\c-drive-cleanup'
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\scan.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" -Level safe -AllSafe
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" -Level safe -AllSafe -Apply -Yes
```

`-AllSafe` 不包含回收站、诊断证据、休眠、系统还原点、Windows.old 或 DISM。

## 用户明确授权后的全清理

仅当用户同时满足以下条件时才可使用：

1. 明确授权管理员权限。
2. 明确知道回收站、诊断证据、旧 Windows 回退、VSS 备份/文件历史会永久丢失。
3. 明确表示愿意承担这些后果。

仍然必须由用户亲自确认 UAC；代理不得模拟点击。

```powershell
$Skill = Join-Path $env:USERPROFILE '.codex\skills\c-drive-cleanup'

# 完整高风险计划，dry-run
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" `
  -FullCleanup -AcceptRisk

# 用户已再次确认后执行
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" `
  -FullCleanup -AcceptRisk -Apply -Yes
```

`-FullCleanup` 会启用：

- `-AllSafe`
- 回收站和诊断日志
- 休眠、DISM、Windows Update 缓存
- Windows 升级临时目录
- 通过 Windows 官方 `cleanmgr` 清理 `Windows.old`
- 删除 C 盘全部 VSS 卷影
- `SkipRecentHours = 0`

特别注意：

- 删除全部 VSS 卷影可能破坏系统还原、文件历史和第三方备份。
- `Windows.old` 删除后无法回退旧 Windows；脚本不使用 `takeown` / `icacls` 兜底。
- 最近 24 小时的 Temp 文件也会进入清理范围；仍被应用占用的文件会跳过。
- 聊天记录、用户文件夹、安装包和软件数据迁移不会自动执行。

## 文件被占用：为什么不能强删

### 用户临时目录

路径：`%LOCALAPPDATA%\Temp`

原因：应用、安装器、Codex 或沙箱进程可能仍在使用临时文件。强制终止未知进程可能丢失未保存工作。

手动处理：

1. 退出正在安装的软件、编辑器和大型应用。
2. 重跑 `clean.ps1 -Level safe -AllSafe -Apply -Yes`。
3. 仍被占用时注销或重启后再清理。
4. 可在资源监视器 → CPU → 关联的句柄中搜索完整路径，确认持有者后再关闭对应应用。

### 缩略图 / 图标缓存

路径：`%LOCALAPPDATA%\Microsoft\Windows\Explorer`

原因：Explorer 持有 `thumbcache_*.db` / `iconcache_*.db`，运行中通常拒绝删除。

手动处理：关闭资源管理器窗口后重试；仍锁定可注销或重启。若明确接受桌面和任务栏短暂重启，可执行：

```powershell
Stop-Process -Name explorer -Force
Start-Process explorer
```

这不会删除用户文件，但会关闭当前 Explorer 窗口。

### 浏览器缓存

路径：

- `%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache`
- `%LOCALAPPDATA%\Microsoft\Edge\User Data\Profile *\Cache`
- `%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache`
- `%LOCALAPPDATA%\Google\Chrome\User Data\Profile *\Cache`

原因：浏览器运行时锁定缓存文件；清理后首次访问站点会重新下载资源。

手动处理：先运行 `-AllSafe`；仍有锁定项时关闭全部浏览器窗口/后台进程后重试。不要勾选密码、Cookie 或历史记录，除非明确需要。

## 需要管理员权限

### Windows Temp

路径：`C:\Windows\Temp`

原因：普通用户没有删除全部系统临时文件的权限。

操作：在“以管理员身份运行”的 PowerShell 中执行：

```powershell
$Skill = Join-Path $env:USERPROFILE '.codex\skills\c-drive-cleanup'
powershell -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" -Level safe -AllSafe -Apply -Yes
```

### 传递优化缓存

路径：`C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache`

原因：该缓存由系统服务持有，需要管理员权限。

操作：使用上面的管理员 `-AllSafe` 命令。

### Windows Update 下载缓存

路径：`C:\Windows\SoftwareDistribution\Download`

原因：需要管理员权限；更新安装中或 BITS 传输活跃时清理可能中断更新。

操作：确认没有待重启更新后使用管理员 `-AllSafe`。脚本不停止 BITS/WU 服务，发现活动任务会跳过。

### DISM / WinSxS

路径：`C:\Windows\WinSxS`

原因：禁止手动删除组件；DISM 耗时较长，并会让部分旧更新无法卸载。

操作：

```powershell
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
```

不要在中途关闭终端或强杀 DISM。

## 不可逆或会破坏证据

### 回收站

路径：C 盘回收站

原因：清空后无法恢复，可能包含误删文件。

操作：先打开回收站逐项确认。只有明确接受不可恢复后才使用 `-IncludeRecycleBin`。

### 错误报告、CBS 日志、崩溃转储

路径：

- `C:\ProgramData\Microsoft\Windows\WER`
- `C:\Windows\Logs\CBS`
- `C:\Windows\MEMORY.DMP`
- `C:\Windows\Minidump`
- `%LOCALAPPDATA%\CrashDumps`

原因：这些是排障证据，删除后无法还原。蓝屏/组件安装故障排障前必须保留。

操作：确认不再分析故障后，管理员运行 `-IncludeDiagnostics`。

### 系统还原点

路径：`System Volume Information`，由系统保护管理。

原因：VSS 卷影不等于系统还原点。`vssadmin delete shadows /oldest` 可能删除备份或文件历史卷影。

操作：系统属性 → 系统保护 → 选择 C: → 配置。不要使用第三方卷影删除命令。

### Windows.old

路径：`C:\Windows.old`

原因：删除后不能回退旧版本 Windows；直接改 ACL、递归删除可能与系统清理并发。

操作：设置 → 系统 → 存储 → 临时文件 → “以前的 Windows 安装”；或磁盘清理 → 清理系统文件。

### Windows 升级残留

路径：`C:\$Windows.~BT`、`C:\$Windows.~WS`

原因：升级、回滚或待重启流程可能仍在使用。

操作：确认升级完成或已取消后，用 Windows 设置/磁盘清理删除。

## 会改变系统设置

### 休眠文件

路径：`C:\hiberfil.sys`

原因：关闭休眠会同时关闭快速启动，属于用户设置变更。

操作：管理员终端运行 `powercfg -h off`。恢复：`powercfg -h on`。

### 虚拟内存

路径：`C:\pagefile.sys`

原因：分页文件被系统锁定，迁移需要修改虚拟内存设置并重启。

操作：高级系统设置 → 性能 → 高级 → 虚拟内存；选择其他分区“系统托管”，重启生效。不要完全禁用分页文件。

## 应迁移而不是删除

### 用户文件夹

路径：

- `%USERPROFILE%\Desktop`
- `%USERPROFILE%\Documents`
- `%USERPROFILE%\Downloads`
- `%USERPROFILE%\Pictures`
- `%USERPROFILE%\Videos`
- `%USERPROFILE%\Music`

原因：这些是用户原始数据，不是缓存。

操作：右键文件夹 → 属性 → 位置 → 移动；迁移前备份，迁移后验证路径。

### 应用数据

常见路径：

- `%USERPROFILE%\Documents\WeChat Files`
- `%USERPROFILE%\Documents\xwechat_files`
- `%USERPROFILE%\Documents\Tencent Files`
- `%USERPROFILE%\Documents\WXWork`
- `%USERPROFILE%\Documents\DingTalk`
- `%LOCALAPPDATA%\Feishu`、`%APPDATA%\Feishu`
- `%LOCALAPPDATA%\Lark`、`%APPDATA%\Lark`
- `%APPDATA%\Telegram Desktop`
- `%APPDATA%\discord`
- `%APPDATA%\Slack`
- `%APPDATA%\Microsoft\Teams`
- `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe`
- `%APPDATA%\Zoom`、`%USERPROFILE%\Documents\Zoom`
- `%LOCALAPPDATA%\Microsoft\Outlook`
- `%LOCALAPPDATA%\Netease\CloudMusic`

原因：可能包含聊天记录、接收文件、录制、邮件数据、账号状态和离线内容。

操作：先在应用设置中迁移存储位置；不支持自定义目录的客户端不要直接移动整个数据目录，应按官方卸载/重装或导出导入流程处理。

### 安装包与便携程序

检测路径：

- `%USERPROFILE%\Downloads`
- `%USERPROFILE%\Desktop`

检测扩展名：`.exe`、`.msi`、`.msix`、`.msixbundle`、`.appx`、`.appxbundle`、`.iso`、`.img`

原因：这些可能是安装包、驱动包、系统镜像或仍在使用的便携程序。它们属于用户文件，不能因为扩展名相似就自动删除。

操作：确认安装完成后，把安装包移动到其他分区或删除。桌面上的 `.exe` 也可能是便携应用，必须逐个确认。

### 游戏、模型与虚拟机

- Steam：`steamapps\libraryfolders.vdf` 中列出的所有库。
- Epic：`C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests` 中记录的安装目录。
- Ollama：`%USERPROFILE%\.ollama\models`
- Docker Desktop：`%LOCALAPPDATA%\Docker\wsl`
- WSL：注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss` 中各发行版记录的 `BasePath`

操作：

- Steam 用“设置 → 存储”移动游戏。
- Epic 用启动器的游戏管理功能移动。
- Ollama 先设置 `OLLAMA_MODELS`，再迁移模型目录。
- Docker/WSL 使用官方导出导入或搬迁功能，禁止直接搬 VHDX。

### 安装缓存

- `C:\Windows\Installer`：Windows Installer 修复/卸载数据库，禁止删除。
- `C:\ProgramData\Package Cache`：Visual Studio 等安装器的修复缓存，禁止手动删除。
- `C:\Windows\WinSxS`：组件存储，只能通过管理员 DISM。

### 开发者缓存

命令：

```powershell
npm cache clean --force
pnpm store prune
pip cache purge
dotnet nuget locals all --clear
```

原因：可重建，但会重新下载，离线/计量网络环境不适合。只在确认工具链和网络条件后手动执行。

### Shader / DirectX 缓存

常见路径：`%LOCALAPPDATA%\D3DSCache`、`%LOCALAPPDATA%\NVIDIA\DXCache`、`%LOCALAPPDATA%\AMD\DxCache`

原因：可重建，但清理后游戏可能短暂卡顿，不作为常规 C 盘清理。

## 不要清

- `C:\Windows\Installer`
- `C:\Windows\WinSxS` 内单个文件
- `System Volume Information`
- `Prefetch`
- `ProgramData\Package Cache`
- 用户桌面/文档/下载中的未知文件
- 应用聊天记录和游戏存档

## 检测边界

- 注册表没有 `InstallLocation` 的软件无法可靠判断安装路径，应报告“未知”，不能猜测。
- 应用数据路径随版本变化；只把实际存在的已知路径列入结果。
- 安装包只扫描下载和桌面，不会遍历整块 C 盘寻找同扩展名文件。
- 体积可能来自注册表 `EstimatedSize` 或目录实测；路径重叠时不能把总和当成唯一可释放空间。
