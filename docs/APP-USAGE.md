# Doubao Skin 使用说明

macOS 与 Windows 使用同一套主题格式和固定主题库。管理器只负责选择、校验、
应用和恢复皮肤；它不会修改、解包或重签官方豆包。

## 第一次使用

### macOS

1. 打开 `Doubao-Skin-macOS-<版本>.dmg`，把 **Doubao Skin.app** 拖到
   **Applications**。
2. 双击 `/Applications/Doubao Skin.app`。
3. 如果 macOS 提示无法验证开发者，先在 Finder 中右键应用并选 **打开**；
   仍被拦截时到 **系统设置 → 隐私与安全性** 点 **仍要打开**。
4. 从 33 套内置主题缩略图中选择主题；默认是
   **INFP · 调停者男孩**。
5. 点 **启用 INFP · 调停者男孩**。第一次通常会重启一次豆包。
6. 管理窗口打开时，图标会显示在底部 Dock；关闭窗口后，Dock 图标消失，
   画笔图标仍留在顶部菜单栏。只有菜单栏中的 **退出 Doubao Skin** 会真正退出。

### Windows

使用发布 ZIP 时，先右键 ZIP 选择 **全部解压**，再双击：

```text
Install Doubao Skin.cmd
```

如果双击脚本被系统拦截，可在解压目录打开 PowerShell 并运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install Doubao Skin.ps1"
```

1. 从桌面或开始菜单打开 **Doubao Skin**。
2. 从 33 套内置主题缩略图中选择主题；默认是
   **INFP · 调停者男孩**。
3. 点 **启用 INFP · 调停者男孩**。第一次通常会重启一次豆包。
4. 按需要勾选或取消窗口顶部的 **开机自动启动**。
5. 点窗口右上角 **X** 后，管理器仍留在系统托盘；双击图标可重新打开。

Windows 托盘菜单可打开管理器、打开豆包、停用皮肤或明确退出管理器。只有
**退出管理器** 会结束托盘程序；点 **X** 不会退出。托盘图标可能被 Windows
收进任务栏右侧的 `^` 隐藏区。

程序安装在：

```text
%LOCALAPPDATA%\Programs\Doubao Skin\
```

安装器同时创建桌面和开始菜单中的 **Doubao Skin** 快捷方式。勾选 **开机自动启动**
后，下次登录会直接显示管理窗口及任务栏按钮；它不再静默隐藏启动。取消勾选只影响
以后登录，不会立刻退出当前管理器，也不会立即移除当前已应用的皮肤。
桌面快捷方式、管理窗口和右下角托盘均使用豆形叶片与画笔图标，不再显示通用
PowerShell 或空白程序图标。

## 为什么重启后还能保持

macOS 使用当前用户的 LaunchAgent：

```text
~/Library/LaunchAgents/com.local.doubao-skin.supervisor.plist
```

Windows 在勾选 **开机自动启动** 时使用当前用户的启动项：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  DoubaoSkin
```

两端遵循同一生命周期：

- 豆包已按皮肤模式运行：继续使用，页面重载后自动补注入；
- 用户正常打开了不带皮肤参数的豆包：校验官方应用后，自动按皮肤模式重开一次；
- 用户退出了豆包：保持安静，不主动拉起；
- 用户点 **停用并恢复**：卸载常驻，清除注入，并恢复官方启动方式。

Windows 的恢复是事件驱动的。独立的 PowerShell 事件监督程序只处理新出现的、
路径和所有者均匹配官方豆包的普通主进程；渲染器、工具进程和带 CDP 参数的启动
不会触发重开。后端会用同一个进程 ID 再校验一次，避免把退出过程中的进程抖动
误认为新的用户启动。

## 主题库

主题库只有一个，不需要配置“自定义主题位置”：

```text
macOS:
~/Library/Application Support/DoubaoSkin/themes/

Windows:
%LOCALAPPDATA%\DoubaoSkin\themes\
```

添加主题：

1. 在管理器中点 **打开主题库**；
2. 把完整主题文件夹粘贴进去；
3. 回到管理器点 **刷新**；
4. 选择出现的背景缩略图；
5. 点 **切换到…**。

MBTI 男生、女生各 16 套主题，以及 **陆思源 · 暖阳书房**，会在这版内置清单
第一次初始化时一次性加入。之后
直接删除不需要的主题文件夹，再点 **刷新**即可；软件不会把它自动补回来。每个
主题的 `id` 必须唯一，复制主题后如果要保留两份，需要同时修改新文件夹中
`theme.json` 的 `id` 和 `name`。旧版 `infp-garden` 已由
`mbti-boy-infp` 取代，不再显示为第二个 INFP 主题。

主题文件夹格式：

```text
my-theme/
  theme.json
  background.png
```

从仓库复制 `presets/_template/theme.json`，至少修改：

- `id`：稳定 ID，只使用字母、数字和连字符；
- `name`：管理器显示名称；
- `background`：同一文件夹内的 PNG、JPEG 或 WebP 文件名；
- `colors`、`typography`、`composer`、`surfaces`：各区域语义颜色。

背景不能是绝对路径，不能使用 `../`，不得超过 16 MB。主题与背景必须是普通文件，
不能是符号链接或 Windows 重解析点。管理器只显示通过完整校验的主题直属文件夹；
无效项目会被忽略。

详细字段和 AI agent 工作流见
[`THEME-AUTHORING.md`](THEME-AUTHORING.md)。

## 常用按钮

- **启用 / 切换到 / 重新应用**：重新校验主题并应用，保留当前开机启动选择；
- **开机自动启动**：控制 Windows 当前用户的登录启动项；登录启动时显示管理窗口；
- **打开豆包**：启用状态下直接按皮肤模式打开；
- **打开主题库**：打开固定主题库，供用户粘贴完整主题文件夹；
- **刷新**：只重新扫描主题库并更新本地背景缩略图，不新增或恢复主题；
- **停用并恢复**：卸载常驻、清除注入并恢复官方启动方式。

主题文件会保留，方便以后再次启用。命令行仍可导入开发目录，但图形管理器刻意不
提供任意文件夹选择器，避免“源文件夹”和“主题库”两个位置造成混淆。
停用后如需恢复皮肤，重新选择主题并点 **启用…**；单独点 **打开豆包** 只会按
当前启用状态启动豆包。Windows 应用失败时会弹窗显示具体原因，不再静默失败。

## 数据与日志

```text
macOS:
~/Library/Application Support/DoubaoSkin/

Windows:
%LOCALAPPDATA%\DoubaoSkin\
```

macOS 检查：

```bash
"$HOME/Library/Application Support/DoubaoSkin/runtime/scripts/manage-doubao-skin-macos.sh" status
"$HOME/Library/Application Support/DoubaoSkin/runtime/scripts/manage-doubao-skin-macos.sh" verify
```

Windows PowerShell 检查：

```powershell
& "$env:LOCALAPPDATA\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" status
& "$env:LOCALAPPDATA\Programs\Doubao Skin\runtime\scripts\manage-doubao-skin-windows.ps1" verify
```

如果豆包升级后皮肤不完整，先点 **停用并恢复**。不要修改、替换或重签官方应用；
按照 `THEME-AUTHORING.md` 更新选择器和身份契约，并在真实渲染器完成验收。

---

Copyright © 2026 陆思源Cyan。Doubao Skin 以 `AGPL-3.0-only` 发布且不提供任何
担保；传播或售卖时须保留版权与许可证并提供完整对应源码。完整条款见项目根目录
`LICENSE`。项目主页：<https://github.com/just-cyan-lu/doubao-skin>。
