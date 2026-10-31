# 安全边界与回滚

## 不变量

1. **先体检后动手**：`scan.ps1` 不删除文件。
2. **默认 dry-run**：`clean.ps1` 不带 `-Apply` 只生成计划。
3. **真实删除需要双确认**：`-Apply -Yes` 同时出现。
4. **精确路径**：路径必须落在内置候选给出的精确根内；不接受模型或用户临时拼出的删除目录。
5. **Known Folder 优先**：`LocalAppData`、用户目录和 `ProgramData` 从 Windows 特殊文件夹解析，不信任可被进程环境覆盖的 `%TEMP%` 等变量。
6. **不跟随链接**：最终路径或任一父目录是 junction/symlink 时跳过。
7. **近期文件默认保留**：默认跳过最近 24 小时修改的文件。
8. **不强行中断**：不停止 BITS/Windows Update，不强杀 DISM，不接管 ACL。

## 风险分级

| 操作 | 默认策略 | 风险与恢复 |
| --- | --- | --- |
| LocalAppData\Temp、Windows Temp、传递优化缓存 | 默认安全项 | 可重建；占用文件跳过 |
| 缩略图/图标缓存 | 默认安全项 | 资源管理器重建，首次打开略慢 |
| 浏览器缓存 | `-IncludeBrowserCache` | 不影响 Cookie/密码/历史；离线页面首次需联网 |
| Windows Update 下载缓存 | `-ResetUpdateCache` | 不停止服务；活动更新/BITS 任务存在时跳过 |
| WER/CBS/崩溃转储 | `-IncludeDiagnostics` | 删除排障证据，无法从系统恢复 |
| 回收站 | `-IncludeRecycleBin` | **不可恢复** |
| 休眠文件 | `-DisableHibernate` | `powercfg -h on` 可恢复；快速启动同时关闭 |
| DISM 组件清理 | `-DismCleanup` | 不可卸载被清理的旧更新；必须一次运行完成 |
| 系统还原点 | 手动 | 删除后无法恢复；必须用“系统保护”界面 |
| Windows.old / 升级残留 | 手动 | 删除后失去旧版本回退；必须用 Windows 存储或磁盘清理 |
| 用户资料/应用聊天数据 | 手动 | 迁移，不删除；先备份 |

## 为什么不再自动删除“安全大目录”

### VSS 卷影副本

`vssadmin delete shadows /oldest` 删除的是最早卷影，不保证那个卷影是系统还原点。它可能破坏文件历史、备份软件或服务器卷影链。因此本 skill 不再自动执行 VSS 删除，只读取 `Get-ComputerRestorePoint` 做展示。

### Windows.old 与 `$Windows.~BT/~WS`

直接 `takeown`/`icacls` 后递归删除会改变系统目录权限，并可能在磁盘清理仍在运行时并发删除。升级待重启或安装程序活动时，这些目录还可能是恢复路径。只允许通过 Windows 官方界面删除。

### Windows Update 与 BITS

停止 BITS 会影响其他应用正在进行的下载，而不只是 Windows Update。`-ResetUpdateCache` 不改变服务状态；只要检测到更新待重启、`TiWorker` 或活动 BITS 任务，就跳过。

### DISM

组件服务事务不能安全强杀。脚本不设置强制超时；窗口看起来长时间静止时，应等待，而不是重复启动多个 DISM。

## 权限

- 用户 Temp、浏览器缓存、回收站、缩略图：普通权限。
- Windows Temp、传递优化、更新缓存、WER/CBS、DISM、休眠：管理员。
- 脚本不自行提权，也不模拟 UAC。需要时用户自行在管理员终端执行。

## 回滚

| 操作 | 回滚 |
| --- | --- |
| 休眠 | 管理员执行 `powercfg -h on`，重启后恢复 |
| 浏览器缓存 | 无需回滚，浏览器自动重建 |
| 临时文件 | 无需回滚，应用自动重建 |
| 回收站/诊断证据/还原点/Windows.old | 不可恢复；删除前必须确认 |
| 用户文件夹迁移 | 属性 → 位置 → 还原默认值，迁移前先备份 |
| 虚拟内存迁移 | 改回自动管理并重启 |

## 报告与隐私

报告保存在 `%LOCALAPPDATA%\c-drive-cleanup\reports`，包含本机路径、体积与状态，不包含文件内容。公开分享报告前应删除用户名和本地路径。
