# Doubao Skin

给官方豆包 macOS / Windows 桌面端添加可恢复的本地主题。它只通过绑定在
`127.0.0.1` 的 Chrome DevTools Protocol 注入样式，不修改、解包、替换或重签
官方豆包。

项目主页：<https://github.com/just-cyan-lu/doubao-skin>

当前版本：`0.8.5`。已针对豆包 `2.19.9`、Chromium `135.0.7049.72` 验证。

## 最简用法

### macOS

1. 打开 `Doubao-Skin-macOS-<版本>.dmg`。
2. 把 **Doubao Skin.app** 拖进 **Applications**，然后打开。
3. 选择主题缩略图，点 **启用**。

### Windows

1. 右键 ZIP，选择 **全部解压**。
2. 双击解压目录根部的 `Install Doubao Skin.cmd`。
3. 从桌面打开 **Doubao Skin**，选择主题并点 **启用**。

macOS 打开管理窗口时会在 Dock 显示图标，点窗口左上角关闭后图标收回菜单栏；
Windows 关闭窗口后会留在系统托盘。关闭窗口都不会退出管理器，
想恢复豆包原始外观时，点 **停用并恢复**。

管理器中的 **对话页蒙版不透明度** 滑块只调整已有聊天页面的阅读遮罩：
`0%` 完全透明，`100%` 完全不透明；设置会保存并在下次启动时继续生效。

添加新主题只需在管理器中点 **打开主题库**，把同时包含 `theme.json` 和背景图的
完整主题文件夹粘贴进去，再点 **刷新**。主题库位置固定为：

```text
macOS:   ~/Library/Application Support/DoubaoSkin/themes/
Windows: %LOCALAPPDATA%\DoubaoSkin\themes\
```

更完整但仍面向普通用户的说明见
[`docs/APP-USAGE.md`](docs/APP-USAGE.md)。

## 从源码构建

需要 Node.js 22 或更高版本。macOS 还需要 Xcode Command Line Tools：

```bash
npm test
npm run build:dmg
```

Windows 请在 Windows PowerShell 5.1 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\build-windows-app.ps1
```

主题格式、选择器和 AI agent 修改规范见
[`docs/THEME-AUTHORING.md`](docs/THEME-AUTHORING.md) 与
[`AGENTS.md`](AGENTS.md)。

## 版权、搬运与售卖

Copyright © 2026 **陆思源Cyan**。

本仓库中由作者享有权利的 Doubao Skin 程序代码以
[`AGPL-3.0-only`](LICENSE) 发布。AGPL 允许使用、修改、搬运、二次发布，也允许
收费售卖，但搬运、分发或售卖原版及修改版时必须遵守许可证，至少包括：

`AGPL-3.0-only` 是标准 SPDX 标识：`3.0` 表示 GNU Affero GPL 第 3 版，
`only` 表示只按第 3 版授权，不自动包含未来版本；它并不是另一种 AGPL。

- 保留“陆思源Cyan”的版权声明、AGPL 声明和完整 `LICENSE`；
- 向接收者提供该版本的完整对应源码，且源码继续使用 `AGPL-3.0-only`；
- 修改版显著标明改动内容和日期，不得伪称原作或删除原作者署名；
- 若修改版通过网络向用户提供交互，须按 AGPL 第 13 条向这些用户提供对应源码。

因此，**收费本身并不违规**；删除署名、隐藏许可证、只发安装包却不提供对应源码，
或把修改版闭源搬运/售卖，才违反本项目的授权条件。

本项目与字节跳动无隶属或官方合作关系，也不得暗示获得作者或豆包官方
背书。本软件按“原样”提供，不作任何担保；完整条款以 [`LICENSE`](LICENSE)
为准。

## 安全边界

- 注入代码不发起网络请求，CDP 只监听本机回环地址。
- 两端都会校验官方应用身份、签名、进程所有者、可执行路径和渲染器 URL。
- 豆包升级后若身份或页面结构变化，程序会停止接管，而不是绕过校验。
- 项目不绕过登录、付费、权限或内容限制，并保留一键恢复官方外观的路径。
