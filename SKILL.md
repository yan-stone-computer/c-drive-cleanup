---
name: c-drive-cleanup
description: Use when the user wants to free space on the Windows C drive, diagnose a full or near-full system disk, or safely clean temporary files, update/download caches, diagnostics, browser caches, hibernation, or component-store data. Chinese triggers include C盘清理、C盘爆满、C盘空间不足、磁盘满了、清理垃圾、释放空间、清理临时文件. Always audit read-only first, require explicit approval before any deletion, and never automate irreversible system rollback data removal.
---

# C 盘安全清理（可执行 skill）

目标是释放可重建缓存，而不是“看到大目录就删”。默认只读；真实删除必须同时带 `-Apply -Yes`；不可逆项只给官方界面步骤。

## 安全边界

- 删除根只来自内置候选表，且必须匹配精确白名单；不接受调用方任意路径。
- 临时文件只清理 Windows Known Folder `LocalAppData\Temp`，不信任可被进程改写的 `%TEMP%` / `%TMP%`。
- 拒绝盘符根、UNC、用户桌面/文档/下载/图片/视频/音乐、系统关键目录，以及路径链中的 junction/symlink。
- 默认保留最近 24 小时临时文件；被占用文件跳过，不强制结束进程。
- 不自动停止 Windows Update/BITS，不强杀 DISM，不接管 ACL，不删除卷影副本。
- 还原点、`Windows.old`、`$Windows.~BT/~WS`、用户资料和虚拟内存迁移只提供手动步骤。

## 工作流

```powershell
$Skill = Join-Path $env:USERPROFILE '.agents\skills\c-drive-cleanup'
$PS = 'powershell'   # PowerShell 7 可用 'pwsh'

# 1. 只读体检
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\scan.ps1"

# 2. 试运行；不删除任何文件
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" -Level safe

# 3. 征得用户同意后清理默认安全项
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\clean.ps1" -Level safe -Apply -Yes

# 4. 复测并对比
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\scan.ps1"

# 5. 生成手动清单
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\guide.ps1"
```

先报体检数字、风险级别、需要管理员或手动处理的项，再请求明确确认。用户拒绝或犹豫时，只交付体检与手动清单。

## 自动化等级

### 默认安全项

- `LocalAppData\Temp`（保留最近 24 小时文件）
- Windows Temp（管理员）
- 传递优化缓存（管理员）
- Explorer 缩略图/图标缓存（占用文件跳过）

### 必须显式开关

| 开关 | 作用 | 代价 |
| --- | --- | --- |
| `-IncludeBrowserCache` | Edge/Chrome `Default` 与 `Profile *` 浏览器缓存 | 首次打开网页略慢；不清 Cookie/密码/历史 |
| `-IncludeRecycleBin` | 清空 C 盘回收站 | **不可恢复** |
| `-IncludeDiagnostics` | WER、CBS 日志、系统/应用崩溃转储 | 丢失排障证据；排障结束前不要用 |
| `-ResetUpdateCache` | 删除 24 小时前的 Windows Update 下载缓存 | 不停止服务；更新待重启或存在活动 BITS 任务时跳过 |
| `-DisableHibernate` | `powercfg -h off` | 关闭休眠与快速启动；可 `powercfg -h on` 恢复 |
| `-DismCleanup` | DISM 清理被取代的组件 | 不能卸载已安装更新；不得中途强杀 |

这些开关仍受 `-Level` 限制。`-Auto` 只能运行默认安全项，遇到任何显式开关或 deep 项会拒绝。

### 仅手动，脚本明确拒绝自动化

- 系统还原点：VSS 卷影不等于还原点；请用“系统保护”界面。
- `C:\Windows.old`：使用“设置 → 系统 → 存储 → 临时文件”或磁盘清理。
- `C:\$Windows.~BT` / `$Windows.~WS`：确认升级完成/取消后，用 Windows 官方清理界面。
- 虚拟内存迁移：改系统设置并重启。
- 微信/QQ 等聊天文件、用户文件夹：应用内改路径或“属性 → 位置 → 移动”。

`-PruneRestorePoints`、`-RemoveWindowsOld`、`-RemoveWindowsUpgradeTemp` 仅为兼容旧命令而保留；传入后脚本会在任何清理动作前直接拒绝。

## 参数

```text
scan.ps1  [-Json] [-SkipSizes] [-OutFile <path>] [-TopApps N]

clean.ps1 [-Level safe|deep] [-Apply] [-Yes] [-DryRun] [-Auto]
          [-Ids id1,id2] [-SkipIds id1]
          [-IncludeRecycleBin] [-IncludeBrowserCache] [-IncludeDiagnostics]
          [-ResetUpdateCache] [-DisableHibernate] [-DismCleanup]
          [-SkipWuCache] [-CreateRestorePoint]
          [-SkipRecentHours N] [-Json] [-LogDir <path>]

guide.ps1 [-OutFile <path>] [-TopApps N]
```

- `-SkipRecentHours N`：默认 24；设为 0 才会考虑最近修改的文件，必须由用户明确要求。
- `-CreateRestorePoint`：管理员 deep 清理前尝试创建还原点；系统保护未开启时可能失败。
- `-Json`：stdout 输出结构化结果，报告写入 `%LOCALAPPDATA%\c-drive-cleanup\reports`。

## 非管理员

脚本不会自行提权或点击 UAC。需要管理员的项会返回 `needs-admin` 和一条由用户自行确认执行的 `Start-Process -Verb RunAs` 命令。

## 读报告

- `Candidates[]`：`Id / Name / Level / RequiresAdmin / Exists / Bytes / Files / OptIn / Kind`。
- `Totals.SafeUserBytes`：普通权限默认可处理项。
- `Totals.SafeAdminBytes`：需管理员的默认安全项。
- `Totals.RequiresOptInBytes`：必须显式开关的项。
- `Totals.DiagnosticsBytes`：排障证据体积，默认保留。
- `Totals.DeepOptInBytes`：深度或仅手动项，不能据此推断脚本会删除。

清理报告包含每项 `Status`、`BytesFreed` 与 `FreeSpaceDelta`。退出码：`0` 无异常；`2` 有跳过/部分完成/需手工；`1` 参数或致命错误。

## 不要做

- 不要绕过脚本直接递归删除 `C:\Windows`、`WinSxS`、`Installer`、用户资料或未知大目录。
- 不要把 `%TEMP%` 环境变量值直接作为删除根。
- 不要用 `vssadmin delete shadows` 冒充“清理还原点”。
- 不要为了清理 `Windows.old` 授权、改 ACL 或递归接管系统目录。
- 不要在更新安装、待重启、DISM 运行中停止服务或杀进程。
- 不要清理 Prefetch、`System Volume Information`、`ProgramData\Package Cache` 或应用聊天记录来“省空间”。
- 不要承诺固定释放量。

## 自检

```powershell
& $PS -NoProfile -ExecutionPolicy Bypass -File "$Skill\scripts\tests\test-lib.ps1"
```

测试只在临时目录创建/删除夹具，覆盖白名单、环境变量污染、用户目录拒绝、junction、近期文件、占用文件、危险自动化禁用和 JSON 基础格式。

## 参考

- `references/safety.md`：威胁边界、回滚与人工步骤。
- `references/manual-steps.md`：Windows 11 清理与迁移手册。
