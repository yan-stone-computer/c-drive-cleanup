<div align="center">

# C 盘急救箱

### 别再用“全选删除”救 C 盘了。

一个会先体检、默认只试运行、主动拒绝误删用户数据的 Windows 清理 skill。

它还会生成“软件存储地图”：安装目录、聊天文件、下载安装包、模型、游戏库、虚拟机数据只要落在 C 盘，就会报告路径、体积、风险和迁移方案。

[![CI](https://github.com/yan-stone-computer/c-drive-cleanup/actions/workflows/test.yml/badge.svg)](https://github.com/yan-stone-computer/c-drive-cleanup/actions/workflows/test.yml)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)](#适用环境)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#适用环境)
[![Tests](https://img.shields.io/badge/safety_tests-49%20passed-2ea44f)](#验证)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/yan-stone-computer/c-drive-cleanup?style=social)](https://github.com/yan-stone-computer/c-drive-cleanup)

</div>

---

## 512 GB 的 C 盘只剩 8 GB？

真正危险的不是空间少，而是“看起来都像垃圾”。

`%TEMP%` 可能藏着未保存文档，`WinSxS` 里有系统组件硬链接，`Windows.old` 是回退旧版本的唯一路径，VSS 卷影也不等于系统还原点。网上的“一键清理”经常在这些地方越界。

**C 盘急救箱的立场很明确：**

- 先只读体检，不先删。
- 默认 dry-run，真实删除必须双确认。
- 诊断日志、回收站、浏览器缓存、休眠、DISM 都要单独选择。
- 还原点、`Windows.old`、升级残留、用户资料**不做自动删除**。

> 少清 2 GB 没关系，删掉一份无法恢复的数据才是真事故。

## 一眼看懂

```text
只读体检 → 展示可清理项 → 用户确认 → dry-run → -Apply -Yes → 复测
                │
                └─ 不可逆项 → 只给 Windows 官方手动步骤
```

它既是可独立运行的 PowerShell 工具，也是一个可直接放进 `~/.agents/skills/` 的 Codex skill。

## 快速开始

要求 Windows 10/11，Windows PowerShell 5.1 或 PowerShell 7+。

```powershell
git clone https://github.com/yan-stone-computer/c-drive-cleanup.git
Set-Location .\c-drive-cleanup

# 1) 只读体检
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan.ps1

# 2) 试运行全部安全缓存：不会删除
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 -Level safe -AllSafe

# 3) 确认清单后，执行全部安全缓存清理
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 -Level safe -AllSafe -Apply -Yes

# 4) 复测
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan.ps1
```

只在试运行里看到想清理的项目，不代表它会自动清。真实删除还需要 `-Apply -Yes`。

## 它会主动拒绝什么

这三个旧“一键深清”参数仍可被解析，但脚本会在任何删除动作前退出：

```text
-PruneRestorePoints
-RemoveWindowsOld
-RemoveWindowsUpgradeTemp
```

原因不是“做起来麻烦”，而是它们不安全：

- `vssadmin delete shadows /oldest` 删除的是最早**卷影副本**，不保证是系统还原点，可能误伤文件历史或备份。
- `Windows.old` 直接 `takeown` / `icacls` 后递归删除，会改权限并可能与 Windows 自己的磁盘清理并发。
- 更新安装、待重启或 DISM 运行中停止服务/杀进程，可能破坏更新或组件存储状态。

这些操作请在 Windows 的“存储”“系统保护”或“磁盘清理”界面里逐项确认。

## 能自动化什么

### 默认安全项与 `-AllSafe`

| 项目 | 说明 |
| --- | --- |
| `LocalAppData\Temp` | 只处理 Windows 已知临时目录；默认保留最近 24 小时文件 |
| `C:\Windows\Temp` | 需要管理员；占用文件跳过 |
| 传递优化缓存 | Windows 更新 P2P 缓存 |
| 缩略图 / 图标缓存 | Explorer 自动重建 |
| 浏览器缓存 | `-AllSafe` 启用；不清 Cookie、密码、历史 |
| Windows Update 下载缓存 | 管理员 + `-AllSafe`；不停止 BITS/WU，活动任务时跳过 |

`-AllSafe` 是建议给代理使用的完整安全档位，但仍会保留最近 24 小时文件、跳过占用文件，不包含回收站、诊断证据、休眠、DISM、还原点或 Windows.old。

### 必须显式开启

| 开关 | 作用 | 代价 |
| --- | --- | --- |
| `-IncludeBrowserCache` | Edge/Chrome `Default` 与 `Profile *` 缓存 | 首次打开网页略慢；不清 Cookie/密码/历史 |
| `-IncludeRecycleBin` | 清空 C 盘回收站 | **不可恢复** |
| `-IncludeDiagnostics` | WER、CBS、系统/应用崩溃转储 | 会删除排障证据 |
| `-ResetUpdateCache` | 清理 24 小时前的更新下载缓存 | 不停止服务；活动更新/BITS 任务存在时跳过 |
| `-DisableHibernate` | `powercfg -h off` | 关闭休眠和快速启动 |
| `-DismCleanup` | DISM 清理被取代组件 | 时间较长，不能中途强杀 |

`-AllSafe` 已包含浏览器缓存和更新下载缓存；单独出现的这两个开关仍可用于精细控制。

### 明确授权后的全清理

只有在用户明确授权管理员权限、并要求清理不可逆系统数据并愿意承担后果时，才使用：

```powershell
# 先查看完整计划
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -FullCleanup -AcceptRisk

# 真正执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -FullCleanup -AcceptRisk -Apply -Yes
```

`-FullCleanup` 必须与 `-AcceptRisk` 同时出现，并且需要管理员终端；UAC 仍由用户亲自确认。该模式会启用：

- `-AllSafe`
- 回收站、诊断日志、休眠、DISM、更新缓存
- 升级临时目录
- Windows 官方磁盘清理处理 `Windows.old`
- C 盘全部 VSS 卷影清理

它会删除最近 24 小时内的 Temp 文件，并可能永久丢失回收站、诊断证据、旧版本回退和备份卷影。聊天记录、用户文件夹、安装包和软件数据迁移仍不会自动执行。

## 软件存储地图

只读体检会检查：

- 注册表中可验证的软件安装位置。
- 微信、QQ、企业微信、钉钉、飞书、Telegram、Discord、Slack、Teams、Zoom、Outlook 等数据目录。
- 下载和桌面中的 `.exe`、`.msi`、`.msix`、`.appx`、`.iso`、`.img` 安装包或便携程序。
- Ollama 模型、Docker/WSL、Steam/Epic 游戏库。
- `C:\Windows\Installer`、`C:\ProgramData\Package Cache`、`WinSxS` 等受保护安装/系统缓存。

每项包含：

```text
Name / Kind / Path / Bytes / OnC / Risk / Action
```

例如聊天文件会建议在应用设置内迁移，游戏库会建议使用 Steam/Epic 官方移动功能，安装包会建议确认后移到其他分区，`Windows\Installer` 和 `Package Cache` 则明确标记为禁止删除。

注册表没有 `InstallLocation` 的软件无法可靠判断安装路径，会显示为未知，不会猜测后自动处理。

示例：

```powershell
# 全部安全缓存（推荐）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -Level safe -AllSafe -Apply -Yes

# 额外清空回收站（确认无需恢复）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -Level safe -AllSafe -Apply -Yes -IncludeRecycleBin

# 管理员：关闭休眠
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -Level deep -Apply -Yes -DisableHibernate

# 管理员：组件存储清理
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clean.ps1 `
  -Level deep -Apply -Yes -DismCleanup
```

## 安全模型

项目不是靠一句“别乱删”，而是在代码里落实边界：

1. **Known Folder，不信任 `%TEMP%`**  
   删除候选从 Windows 特殊文件夹解析，`TEMP/TMP` 被改写也不会扩大删除范围。
2. **精确白名单**  
   每个删除 helper 都必须收到非空精确根；没有白名单就失败。
3. **用户资料硬拒绝**  
   桌面、文档、下载、图片、视频、音乐，以及盘符根、UNC、系统关键目录都不能成为清理根。
4. **不跟随 junction/symlink**  
   最终路径或父路径命中重解析点就跳过。
5. **近期文件默认保留**  
   默认跳过 24 小时内修改的文件，减少误删正在使用的临时数据。
6. **不强制中断系统事务**  
   不停止 BITS，不强杀 DISM，不自动提权，不点击 UAC。

完整威胁边界见 [`references/safety.md`](references/safety.md)。

## 输出报告

体检报告默认写到：

```text
%LOCALAPPDATA%\c-drive-cleanup\reports\latest-scan.json
```

关键字段：

```text
Candidates[]                 每个候选的体积、权限、开关和动作类型
Totals.SafeUserBytes          普通权限默认可处理
Totals.SafeAdminBytes         管理员默认可处理
Totals.DiagnosticsBytes       默认保留的排障证据
Totals.RequiresOptInBytes     必须显式开关的量
FreeSpaceDelta                清理前后实际空间变化
StorageLocations[]            软件安装、数据、安装包和受保护缓存
StorageOnC[]                  仅在 C 盘的额外存储项
```

报告包含本机路径、体积和状态，不包含文件内容。公开贴报告前请先移除用户名和本地路径。

## 常用命令

```powershell
# 只处理指定项
.\scripts\clean.ps1 -Level safe -Ids user-temp,thumbnail-cache

# 排除指定项
.\scripts\clean.ps1 -Level safe -SkipIds browser-cache

# 生成 Markdown 行动清单
.\scripts\guide.ps1 -OutFile .\cleanup-checklist.md

# 结构化 JSON
.\scripts\scan.ps1 -Json
.\scripts\clean.ps1 -Level safe -DryRun -Json
```

参数说明和动作分级见 [`SKILL.md`](SKILL.md)。

## 手动清理清单

Windows.old、系统还原点、虚拟内存、用户文件夹和微信/QQ 数据不是“垃圾”。  
`guide.ps1` 会读取最近一次清理结果，列出仍未完成的项、精确路径、失败原因和手动步骤。

完整路径与操作见：

[`references/manual-steps.md`](references/manual-steps.md)

明确不建议清：

- `C:\Windows\Installer`
- `C:\Windows\WinSxS` 里的单个文件
- `System Volume Information`
- `Prefetch`
- `ProgramData\Package Cache`
- 应用聊天记录或游戏存档

## 作为 Codex Skill 使用

仓库根目录就是 skill 目录。可把仓库放在：

```text
%USERPROFILE%\.codex\skills\c-drive-cleanup
```

之后在 Codex 里直接说“清理 C 盘”，skill 会先体检、执行 `-AllSafe` dry-run，并在用户确认后清理全部可重建的安全缓存。

## 验证

本项目只使用临时目录做安全测试，不接触真实系统目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\test-lib.ps1
```

当前覆盖 **49 项断言**，包括：

- 盘符根、UNC、用户资料、系统目录拒绝
- `TEMP/TMP` 环境变量污染
- 精确白名单缺失
- dry-run 不删除
- 近期文件与占用文件保留
- junction/reparse 跳过
- 不可逆自动化禁用
- 软件存储 C 盘识别和迁移方案字段
- `FullCleanup` 必须获得 `AcceptRisk` 的授权闸
- PowerShell 语法与 JSON 基础结构

GitHub Actions 会在 `windows-latest` 上运行同一套测试。

## 仓库结构

```text
.
├─ SKILL.md
├─ README.md
├─ SECURITY.md
├─ references/
│  ├─ safety.md
│  └─ manual-steps.md
├─ scripts/
│  ├─ scan.ps1
│  ├─ clean.ps1
│  ├─ guide.ps1
│  ├─ lib.ps1
│  ├─ lib-audit.ps1
│  ├─ lib-actions.ps1
│  └─ tests/
│     ├─ test-lib.ps1
│     └─ validate-json.ps1
└─ .github/workflows/test.yml
```

## 适用环境

- Windows 10 / 11
- Windows PowerShell 5.1
- PowerShell 7+
- 普通权限可做用户级清理；系统项需要管理员终端

不是 Windows 专用驱动清理器，也不会清理 Linux 文件系统、容器镜像或 WSL 虚拟磁盘。Docker/WSL 的虚拟磁盘压缩属于另一类需要停机与备份的操作。

## 贡献

欢迎提交测试、误报和不安全边界。修改删除逻辑时请遵守一条规则：

> 先证明它不会越界，再证明它能释放空间。

安全问题和敏感报告请优先通过 GitHub Security Advisory 提交，不要在公开 issue 中附带个人信息或完整本机路径。

## License

[MIT](LICENSE)

---

### English TL;DR

A safety-first Windows C-drive cleanup skill: read-only audit first, dry-run by default, explicit approval for deletion, no automated removal of restore points, `Windows.old`, user data, or other irreversible recovery artifacts.
