using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace DoubaoSkin
{
    internal sealed class SkinStatus
    {
        public string schema { get; set; }
        public bool enabled { get; set; }
        public bool startAtLogin { get; set; }
        public int? port { get; set; }
        public string themeDir { get; set; }
        public string themeId { get; set; }
        public string themeName { get; set; }
        public bool running { get; set; }
        public bool skinActive { get; set; }
        public bool supervisorRunning { get; set; }
        public string doubaoVersion { get; set; }
        public string chromiumVersion { get; set; }
        public string doubaoExecutable { get; set; }
    }

    internal sealed class ThemeSummary
    {
        public string id { get; set; }
        public string name { get; set; }
        public string directory { get; set; }
        public string background { get; set; }
        public string backgroundPath { get; set; }
        public string revision { get; set; }
    }

    internal sealed class InvalidThemeSummary
    {
        public string entry { get; set; }
        public string reason { get; set; }
    }

    internal sealed class ThemeLibrary
    {
        public string schema { get; set; }
        public string directory { get; set; }
        public ThemeSummary[] themes { get; set; }
        public InvalidThemeSummary[] invalid { get; set; }
    }

    internal static class Backend
    {
        private static readonly string RuntimeRoot =
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "runtime");
        private static readonly string ManagerScript =
            Path.Combine(RuntimeRoot, "scripts", "manage-doubao-skin-windows.ps1");

        public static Task<string> RunAsync(params string[] arguments)
        {
            return Task.Run(delegate
            {
                if (!File.Exists(ManagerScript))
                {
                    throw new InvalidOperationException(
                        "应用内的 Windows 皮肤运行时不完整，请重新安装 Doubao Skin。");
                }

                List<string> command = new List<string>();
                command.Add("-NoProfile");
                command.Add("-NonInteractive");
                command.Add("-ExecutionPolicy");
                command.Add("Bypass");
                command.Add("-File");
                command.Add(ManagerScript);
                command.AddRange(arguments);

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                    "System32",
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");
                startInfo.Arguments = JoinArguments(command);
                startInfo.WorkingDirectory = RuntimeRoot;
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;
                startInfo.RedirectStandardOutput = true;
                startInfo.RedirectStandardError = true;
                startInfo.StandardOutputEncoding = new UTF8Encoding(false);
                startInfo.StandardErrorEncoding = new UTF8Encoding(false);

                using (Process process = new Process())
                {
                    process.StartInfo = startInfo;
                    process.Start();
                    string standardOutput = process.StandardOutput.ReadToEnd();
                    string standardError = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        string message = string.IsNullOrWhiteSpace(standardError)
                            ? standardOutput
                            : standardError;
                        throw new InvalidOperationException(
                            string.IsNullOrWhiteSpace(message)
                                ? "操作没有完成。"
                                : message.Trim());
                    }
                    return standardOutput.Trim();
                }
            });
        }

        private static string JoinArguments(IEnumerable<string> arguments)
        {
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length > 0)
                {
                    result.Append(' ');
                }
                result.Append(QuoteArgument(argument ?? string.Empty));
            }
            return result.ToString();
        }

        private static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 &&
                argument.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                return argument;
            }

            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }

    internal sealed class SkinManagerForm : Form
    {
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private readonly Icon appIcon;
        private readonly bool startHidden;
        private readonly NotifyIcon trayIcon;
        private readonly FlowLayoutPanel themeFlow;
        private readonly Label statusTitle;
        private readonly Label statusDetail;
        private readonly Label messageLabel;
        private readonly Button applyButton;
        private readonly Button openDoubaoButton;
        private readonly Button disableButton;
        private readonly Button refreshButton;
        private readonly Button openLibraryButton;
        private readonly CheckBox startupCheckBox;
        private ThemeLibrary library;
        private SkinStatus status;
        private ThemeSummary selectedTheme;
        private bool busy;
        private bool exitRequested;
        private bool balloonShown;
        private bool updatingStartup;

        public SkinManagerForm(bool startHiddenValue)
        {
            startHidden = startHiddenValue;
            Text = "Doubao Skin";
            Width = 880;
            Height = 680;
            MinimumSize = new Size(760, 570);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(247, 245, 238);
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular);
            string appIconPath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "runtime",
                "assets",
                "DoubaoSkin.ico");
            appIcon = File.Exists(appIconPath)
                ? new Icon(appIconPath)
                : (Icon)SystemIcons.Application.Clone();
            Icon = appIcon;
            if (startHidden)
            {
                Opacity = 0;
                ShowInTaskbar = false;
            }

            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 94;
            header.Padding = new Padding(24, 18, 24, 12);
            header.BackColor = Color.FromArgb(238, 242, 232);

            Label title = new Label();
            title.Text = "Doubao Skin";
            title.Font = new Font(Font.FontFamily, 20F, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(46, 71, 54);
            title.AutoSize = true;
            title.Location = new Point(24, 17);

            Label subtitle = new Label();
            subtitle.Text = "Windows 豆包主题管理器 · 固定主题库 · 本地回环注入";
            subtitle.ForeColor = Color.FromArgb(100, 115, 102);
            subtitle.AutoSize = true;
            subtitle.Location = new Point(27, 58);

            statusTitle = new Label();
            statusTitle.Text = "读取中";
            statusTitle.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
            statusTitle.ForeColor = Color.FromArgb(49, 77, 57);
            statusTitle.AutoSize = true;
            statusTitle.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            statusTitle.Location = new Point(700, 22);

            statusDetail = new Label();
            statusDetail.Text = "正在检查豆包与主题库";
            statusDetail.ForeColor = Color.FromArgb(104, 117, 105);
            statusDetail.AutoEllipsis = true;
            statusDetail.TextAlign = ContentAlignment.MiddleRight;
            statusDetail.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            statusDetail.SetBounds(540, 52, 310, 22);

            header.Controls.Add(title);
            header.Controls.Add(subtitle);
            header.Controls.Add(statusTitle);
            header.Controls.Add(statusDetail);
            header.Resize += delegate
            {
                statusTitle.Left = Math.Max(520, header.ClientSize.Width - statusTitle.Width - 26);
                statusDetail.Left = Math.Max(440, header.ClientSize.Width - statusDetail.Width - 26);
            };

            Panel toolbar = new Panel();
            toolbar.Dock = DockStyle.Top;
            toolbar.Height = 54;
            toolbar.Padding = new Padding(18, 10, 18, 8);
            toolbar.BackColor = Color.FromArgb(250, 249, 245);

            refreshButton = CreateSecondaryButton("刷新", 84);
            openLibraryButton = CreateSecondaryButton("打开主题库", 120);
            refreshButton.Location = new Point(18, 10);
            openLibraryButton.Location = new Point(112, 10);
            refreshButton.Click += async delegate { await ReloadAsync(false); };
            openLibraryButton.Click += async delegate
            {
                await RunOperationAsync(
                    "正在打开主题库…",
                    new[] { "reveal-themes" },
                    false,
                    false);
            };
            startupCheckBox = new CheckBox();
            startupCheckBox.Text = "开机自动启动";
            startupCheckBox.AutoSize = true;
            startupCheckBox.Enabled = false;
            startupCheckBox.Location = new Point(262, 18);
            startupCheckBox.CheckedChanged += async delegate
            {
                if (updatingStartup || busy || status == null)
                {
                    return;
                }
                await RunOperationAsync(
                    startupCheckBox.Checked
                        ? "正在启用开机自动启动…"
                        : "正在关闭开机自动启动…",
                    new[] {
                        startupCheckBox.Checked
                            ? "enable-startup"
                            : "disable-startup"
                    },
                    true,
                    true);
            };
            toolbar.Controls.Add(refreshButton);
            toolbar.Controls.Add(openLibraryButton);
            toolbar.Controls.Add(startupCheckBox);

            themeFlow = new FlowLayoutPanel();
            themeFlow.Dock = DockStyle.Fill;
            themeFlow.AutoScroll = true;
            themeFlow.WrapContents = true;
            themeFlow.FlowDirection = FlowDirection.LeftToRight;
            themeFlow.Padding = new Padding(18, 14, 12, 14);
            themeFlow.BackColor = Color.FromArgb(247, 245, 238);

            Panel footer = new Panel();
            footer.Dock = DockStyle.Bottom;
            footer.Height = 142;
            footer.Padding = new Padding(20, 12, 20, 14);
            footer.BackColor = Color.FromArgb(250, 249, 245);

            messageLabel = new Label();
            messageLabel.Text = "正在读取主题库和状态…";
            messageLabel.AutoEllipsis = true;
            messageLabel.ForeColor = Color.FromArgb(91, 105, 93);
            messageLabel.SetBounds(22, 12, 810, 24);
            messageLabel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

            applyButton = CreatePrimaryButton("选择一个主题", 230);
            openDoubaoButton = CreateSecondaryButton("打开豆包", 105);
            disableButton = CreateSecondaryButton("停用并恢复", 122);
            applyButton.Location = new Point(20, 50);
            openDoubaoButton.Location = new Point(262, 50);
            disableButton.Location = new Point(379, 50);
            applyButton.Click += async delegate { await ApplySelectedThemeAsync(); };
            openDoubaoButton.Click += async delegate
            {
                await RunOperationAsync(
                    "正在打开豆包…",
                    new[] { "open" },
                    true,
                    false);
            };
            disableButton.Click += async delegate { await DisableSkinAsync(); };

            Label copyright = new Label();
            copyright.Text =
                "© 2026 陆思源Cyan · AGPL-3.0-only · 无担保；传播或售卖须保留版权并提供源码";
            copyright.ForeColor = Color.FromArgb(112, 120, 111);
            copyright.AutoEllipsis = true;
            copyright.SetBounds(22, 108, 670, 22);
            copyright.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;

            LinkLabel projectLink = new LinkLabel();
            projectLink.Text = "GitHub 项目";
            projectLink.TextAlign = ContentAlignment.MiddleRight;
            projectLink.SetBounds(730, 108, 120, 22);
            projectLink.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
            projectLink.LinkClicked += delegate
            {
                Process.Start("https://github.com/just-cyan-lu/doubao-skin");
            };

            footer.Controls.Add(messageLabel);
            footer.Controls.Add(applyButton);
            footer.Controls.Add(openDoubaoButton);
            footer.Controls.Add(disableButton);
            footer.Controls.Add(copyright);
            footer.Controls.Add(projectLink);

            Controls.Add(themeFlow);
            Controls.Add(footer);
            Controls.Add(toolbar);
            Controls.Add(header);

            ContextMenuStrip trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add("打开管理器", null, delegate { ShowManager(); });
            trayMenu.Items.Add("打开豆包", null, async delegate
            {
                await RunOperationAsync(
                    "正在打开豆包…",
                    new[] { "open" },
                    true,
                    false);
            });
            trayMenu.Items.Add("停用并恢复官方外观", null, async delegate
            {
                await DisableSkinAsync();
            });
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add("退出管理器", null, delegate { ExitManager(); });

            trayIcon = new NotifyIcon();
            trayIcon.Icon = appIcon;
            trayIcon.Text = "Doubao Skin";
            trayIcon.ContextMenuStrip = trayMenu;
            trayIcon.Visible = true;
            trayIcon.DoubleClick += delegate { ShowManager(); };

            Shown += async delegate
            {
                if (startHidden)
                {
                    Hide();
                    ShowInTaskbar = false;
                }
                try
                {
                    await Backend.RunAsync("ensure-supervisor");
                }
                catch
                {
                    // Reload below presents installation or identity errors.
                }
                await ReloadAsync(true);
            };
            FormClosing += OnManagerFormClosing;
        }

        private static Button CreatePrimaryButton(string text, int width)
        {
            Button button = new Button();
            button.Text = text;
            button.Width = width;
            button.Height = 38;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.BackColor = Color.FromArgb(65, 94, 70);
            button.ForeColor = Color.White;
            button.Cursor = Cursors.Hand;
            return button;
        }

        private static Button CreateSecondaryButton(string text, int width)
        {
            Button button = new Button();
            button.Text = text;
            button.Width = width;
            button.Height = 36;
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderColor = Color.FromArgb(198, 205, 194);
            button.BackColor = Color.FromArgb(255, 255, 252);
            button.ForeColor = Color.FromArgb(56, 76, 61);
            button.Cursor = Cursors.Hand;
            return button;
        }

        private async Task ReloadAsync(bool preferActive)
        {
            if (busy)
            {
                return;
            }
            SetBusy(true, "正在读取主题库和状态…");
            try
            {
                Task<string> libraryTask = Backend.RunAsync("list-themes");
                Task<string> statusTask = Backend.RunAsync("status");
                await Task.WhenAll(libraryTask, statusTask);
                ThemeLibrary latestLibrary =
                    serializer.Deserialize<ThemeLibrary>(libraryTask.Result);
                SkinStatus latestStatus =
                    serializer.Deserialize<SkinStatus>(statusTask.Result);
                if (latestLibrary == null ||
                    latestLibrary.schema != "doubao-skin-theme-library/1" ||
                    latestStatus == null ||
                    latestStatus.schema != "doubao-skin-status/1")
                {
                    throw new InvalidOperationException("无法读取有效的主题库或运行状态。");
                }
                library = latestLibrary;
                status = latestStatus;
                RetainSelection(preferActive);
                RenderThemes();
                UpdateStatus();
                int invalidCount = library.invalid == null ? 0 : library.invalid.Length;
                messageLabel.Text = invalidCount > 0
                    ? string.Format(
                        "找到 {0} 个有效主题；已忽略 {1} 个无效项目。",
                        library.themes == null ? 0 : library.themes.Length,
                        invalidCount)
                    : "主题库已就绪。把新主题文件夹粘贴进去后点“刷新”。";
            }
            catch (Exception exception)
            {
                messageLabel.Text = CleanMessage(exception.Message);
                statusTitle.Text = "读取失败";
                statusDetail.Text = "请检查安装与运行日志";
            }
            finally
            {
                SetBusy(false, null);
            }
        }

        private void RetainSelection(bool preferActive)
        {
            ThemeSummary[] themes = library.themes ?? new ThemeSummary[0];
            ThemeSummary previous = selectedTheme;
            ThemeSummary active = null;
            foreach (ThemeSummary theme in themes)
            {
                if (status.enabled &&
                    ((!string.IsNullOrEmpty(status.themeDir) &&
                      SamePath(status.themeDir, theme.directory)) ||
                     (string.IsNullOrEmpty(status.themeDir) &&
                      string.Equals(status.themeId, theme.id, StringComparison.Ordinal))))
                {
                    active = theme;
                    break;
                }
            }

            ThemeSummary retained = null;
            if (previous != null)
            {
                foreach (ThemeSummary theme in themes)
                {
                    if (SamePath(previous.directory, theme.directory))
                    {
                        retained = theme;
                        break;
                    }
                }
            }
            selectedTheme = preferActive && active != null
                ? active
                : retained ?? active ?? (themes.Length > 0 ? themes[0] : null);
        }

        private void RenderThemes()
        {
            while (themeFlow.Controls.Count > 0)
            {
                Control control = themeFlow.Controls[0];
                themeFlow.Controls.RemoveAt(0);
                PictureBox picture = control.Controls.Count > 0
                    ? FindPictureBox(control)
                    : null;
                if (picture != null && picture.Image != null)
                {
                    picture.Image.Dispose();
                    picture.Image = null;
                }
                control.Dispose();
            }
            ThemeSummary[] themes = library == null || library.themes == null
                ? new ThemeSummary[0]
                : library.themes;
            foreach (ThemeSummary theme in themes)
            {
                themeFlow.Controls.Add(CreateThemeCard(theme));
            }
            if (themes.Length == 0)
            {
                Label empty = new Label();
                empty.Text = "主题库中没有有效主题。点击“打开主题库”，粘贴包含 theme.json 和背景图的文件夹。";
                empty.ForeColor = Color.FromArgb(102, 112, 103);
                empty.AutoSize = false;
                empty.Width = 700;
                empty.Height = 80;
                empty.Padding = new Padding(16);
                themeFlow.Controls.Add(empty);
            }
            UpdateApplyButton();
        }

        private static PictureBox FindPictureBox(Control root)
        {
            PictureBox direct = root as PictureBox;
            if (direct != null)
            {
                return direct;
            }
            foreach (Control child in root.Controls)
            {
                PictureBox found = FindPictureBox(child);
                if (found != null)
                {
                    return found;
                }
            }
            return null;
        }

        private Control CreateThemeCard(ThemeSummary theme)
        {
            bool selected = selectedTheme != null &&
                SamePath(selectedTheme.directory, theme.directory);
            bool active = IsActive(theme);

            Panel outer = new Panel();
            outer.Width = 244;
            outer.Height = 184;
            outer.Margin = new Padding(8);
            outer.Padding = new Padding(selected ? 3 : 1);
            outer.BackColor = selected
                ? Color.FromArgb(89, 126, 96)
                : Color.FromArgb(210, 214, 205);
            outer.Cursor = Cursors.Hand;
            outer.Tag = theme;

            Panel card = new Panel();
            card.Dock = DockStyle.Fill;
            card.BackColor = Color.FromArgb(255, 255, 252);
            card.Padding = new Padding(8);
            card.Tag = theme;

            PictureBox picture = new PictureBox();
            picture.SetBounds(9, 9, 222, 124);
            picture.SizeMode = PictureBoxSizeMode.Zoom;
            picture.BackColor = Color.FromArgb(234, 235, 229);
            picture.Tag = theme;
            picture.Image = LoadUnlockedImage(theme.backgroundPath);

            Label name = new Label();
            name.Text = string.IsNullOrWhiteSpace(theme.name) ? theme.id : theme.name;
            name.Font = new Font(Font.FontFamily, 10F, FontStyle.Bold);
            name.ForeColor = Color.FromArgb(48, 68, 53);
            name.AutoEllipsis = true;
            name.SetBounds(11, 142, 164, 24);
            name.Tag = theme;

            Label badge = new Label();
            badge.Text = active ? "使用中" : theme.id;
            badge.ForeColor = active
                ? Color.FromArgb(53, 104, 61)
                : Color.FromArgb(120, 128, 119);
            badge.TextAlign = ContentAlignment.MiddleRight;
            badge.AutoEllipsis = true;
            badge.SetBounds(168, 142, 63, 24);
            badge.Tag = theme;

            EventHandler selectHandler = delegate
            {
                selectedTheme = theme;
                RenderThemes();
                messageLabel.Text = active
                    ? string.Format("{0} 是当前主题。", theme.name)
                    : string.Format("已选择 {0}，点击下方按钮切换。", theme.name);
            };
            outer.Click += selectHandler;
            card.Click += selectHandler;
            picture.Click += selectHandler;
            name.Click += selectHandler;
            badge.Click += selectHandler;

            card.Controls.Add(picture);
            card.Controls.Add(name);
            card.Controls.Add(badge);
            outer.Controls.Add(card);
            return outer;
        }

        private static Image LoadUnlockedImage(string path)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                {
                    return null;
                }
                using (FileStream stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read))
                using (Image source = Image.FromStream(stream))
                {
                    return new Bitmap(source);
                }
            }
            catch
            {
                return null;
            }
        }

        private async Task ApplySelectedThemeAsync()
        {
            if (selectedTheme == null)
            {
                messageLabel.Text = "请先选择一个有效主题。";
                return;
            }
            await RunOperationAsync(
                string.Format("正在校验并应用 {0}…", selectedTheme.name),
                new[] { "activate-library", "-ThemeDir", selectedTheme.directory },
                true,
                true);
        }

        private async Task DisableSkinAsync()
        {
            if (status == null || !status.enabled)
            {
                messageLabel.Text = "皮肤常驻当前没有启用。";
                return;
            }
            DialogResult result = MessageBox.Show(
                this,
                "这会停止皮肤常驻，并按官方方式重新打开豆包。主题文件仍会保留。",
                "停用 Doubao Skin",
                MessageBoxButtons.OKCancel,
                MessageBoxIcon.Information);
            if (result != DialogResult.OK)
            {
                return;
            }
            await RunOperationAsync(
                "正在停用常驻并恢复官方外观…",
                new[] { "disable" },
                true,
                true);
        }

        private async Task RunOperationAsync(
            string progress,
            string[] arguments,
            bool reloadAfter,
            bool showResult)
        {
            if (busy)
            {
                return;
            }
            SetBusy(true, progress);
            try
            {
                string output = await Backend.RunAsync(arguments);
                if (reloadAfter)
                {
                    SetBusy(false, null);
                    await Task.Delay(500);
                    await ReloadAsync(false);
                }
                if (showResult && !string.IsNullOrWhiteSpace(output))
                {
                    messageLabel.Text = output.Trim();
                }
                else if (!reloadAfter)
                {
                    messageLabel.Text = "操作完成。";
                }
            }
            catch (Exception exception)
            {
                string friendlyMessage = CleanMessage(exception.Message);
                messageLabel.Text = friendlyMessage;
                if (showResult)
                {
                    MessageBox.Show(
                        this,
                        friendlyMessage,
                        "操作失败",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
            }
            finally
            {
                SetBusy(false, null);
            }
        }

        private void SetBusy(bool value, string message)
        {
            busy = value;
            refreshButton.Enabled = !value;
            openLibraryButton.Enabled = !value;
            openDoubaoButton.Enabled = !value;
            disableButton.Enabled = !value && status != null && status.enabled;
            startupCheckBox.Enabled = !value && status != null && status.enabled;
            applyButton.Enabled = !value && selectedTheme != null;
            if (!string.IsNullOrWhiteSpace(message))
            {
                messageLabel.Text = message;
            }
            UseWaitCursor = value;
        }

        private void UpdateStatus()
        {
            if (status == null)
            {
                statusTitle.Text = "读取中";
                statusDetail.Text = "请稍候";
                return;
            }
            updatingStartup = true;
            try
            {
                startupCheckBox.Checked = status.startAtLogin;
            }
            finally
            {
                updatingStartup = false;
            }
            if (status.enabled)
            {
                statusTitle.Text = status.skinActive ? "皮肤已应用" : "常驻已启用";
                statusDetail.Text = status.skinActive
                    ? string.Format("豆包正在使用 {0}", status.themeName ?? "当前主题")
                    : string.Format("下次启动会恢复 {0}", status.themeName ?? "当前主题");
            }
            else
            {
                statusTitle.Text = "未启用";
                statusDetail.Text = string.Format(
                    "已识别官方豆包 {0}",
                    status.doubaoVersion ?? "未知版本");
            }
            disableButton.Enabled = !busy && status.enabled;
            startupCheckBox.Enabled = !busy && status.enabled;
            UpdateApplyButton();
        }

        private void UpdateApplyButton()
        {
            if (selectedTheme == null)
            {
                applyButton.Text = "主题库中暂无可用主题";
                applyButton.Enabled = false;
                return;
            }
            applyButton.Enabled = !busy;
            applyButton.Text = IsActive(selectedTheme)
                ? string.Format("重新应用 {0}", selectedTheme.name)
                : status != null && status.enabled
                    ? string.Format("切换到 {0}", selectedTheme.name)
                    : string.Format("启用 {0}", selectedTheme.name);
        }

        private bool IsActive(ThemeSummary theme)
        {
            if (status == null || !status.enabled || theme == null)
            {
                return false;
            }
            if (!string.IsNullOrWhiteSpace(status.themeDir))
            {
                return SamePath(status.themeDir, theme.directory);
            }
            return string.Equals(status.themeId, theme.id, StringComparison.Ordinal);
        }

        private static bool SamePath(string left, string right)
        {
            if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
            {
                return false;
            }
            try
            {
                return string.Equals(
                    Path.GetFullPath(left).TrimEnd('\\'),
                    Path.GetFullPath(right).TrimEnd('\\'),
                    StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static string CleanMessage(string value)
        {
            string message = string.IsNullOrWhiteSpace(value) ? "操作没有完成。" : value.Trim();
            if (message.Length > 1200)
            {
                message = message.Substring(0, 1200) + "…";
            }
            return message;
        }

        private void ShowManager()
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action(ShowManager));
                return;
            }
            ShowInTaskbar = true;
            Opacity = 1;
            Show();
            if (WindowState == FormWindowState.Minimized)
            {
                WindowState = FormWindowState.Normal;
            }
            BringToFront();
            Activate();
        }

        private void OnManagerFormClosing(object sender, FormClosingEventArgs arguments)
        {
            if (!exitRequested &&
                arguments.CloseReason != CloseReason.WindowsShutDown)
            {
                arguments.Cancel = true;
                Hide();
                ShowInTaskbar = false;
                if (!balloonShown)
                {
                    trayIcon.BalloonTipTitle = "Doubao Skin 仍在运行";
                    trayIcon.BalloonTipText = "可从系统托盘重新打开；只有“退出管理器”会结束程序。";
                    trayIcon.ShowBalloonTip(2500);
                    balloonShown = true;
                }
                return;
            }
            DisposeRuntimeObjects();
        }

        private void ExitManager()
        {
            exitRequested = true;
            DisposeRuntimeObjects();
            Application.Exit();
        }

        private void DisposeRuntimeObjects()
        {
            trayIcon.Visible = false;
            trayIcon.Dispose();
            appIcon.Dispose();
        }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main(string[] arguments)
        {
            bool background = false;
            foreach (string argument in arguments)
            {
                if (string.Equals(argument, "--background", StringComparison.OrdinalIgnoreCase))
                {
                    background = true;
                }
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new SkinManagerForm(background));
        }
    }
}
