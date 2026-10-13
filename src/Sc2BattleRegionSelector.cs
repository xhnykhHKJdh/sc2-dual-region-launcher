// SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;

// The selector operates only the signed official client's game controls. It has
// no keyboard, pointer, credential, installation-edit or process-termination API.
public static class Sc2BattleRegionSelector
{
    private const RegexOptions NameOptions = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private const string RegionNames = "Europe|Americas|Asia|欧洲|歐洲|美洲|亚洲|亞洲";
    private static readonly Regex PlayName = new Regex(
        "^(?:Play|开始游戏|開始遊戲|启动|啟動):\\s*(?:StarCraft II|星际争霸\\s*II|星際爭霸\\s*II|星海爭霸\\s*II),\\s*(?:Region|区域|區域|地区|地區):\\s*(?<region>" + RegionNames + "),\\s*(?:Version|版本):\\s*(?<version>\\d+\\.\\d+\\.\\d+\\.\\d+)$", NameOptions);
    private static readonly Regex RegionMenuName = new Regex(
        "^(?:Region|区域|區域|地区|地區):\\s*(?<region>" + RegionNames + ")$", NameOptions);

    private static string NormalizeName(string name)
    {
        return name == null ? String.Empty : Regex.Replace(name.Normalize(NormalizationForm.FormKC), "\\s+", " ").Trim();
    }

    public static string ParseRegionOptionName(string name)
    {
        string value = NormalizeName(name);
        if (String.Equals(value, "Europe", StringComparison.OrdinalIgnoreCase) || value == "欧洲" || value == "歐洲") return "EU";
        if (String.Equals(value, "Americas", StringComparison.OrdinalIgnoreCase) || value == "美洲") return "US";
        if (String.Equals(value, "Asia", StringComparison.OrdinalIgnoreCase) || value == "亚洲" || value == "亞洲") return "KR";
        return null;
    }

    public static string ParseRegionMenuName(string name)
    {
        Match match = RegionMenuName.Match(NormalizeName(name));
        return match.Success ? ParseRegionOptionName(match.Groups["region"].Value) : null;
    }

    public static string ParseRegionFromPlayName(string name)
    {
        Match match = PlayName.Match(NormalizeName(name));
        return match.Success ? ParseRegionOptionName(match.Groups["region"].Value) : null;
    }

    public static bool IsConfirmedPlay(string name, string expectedRegion)
    {
        return (expectedRegion == "EU" || expectedRegion == "US" || expectedRegion == "KR") && ParseRegionFromPlayName(name) == expectedRegion;
    }

    private static string PlayVersion(string name)
    {
        Match match = PlayName.Match(NormalizeName(name));
        return match.Success ? match.Groups["version"].Value : null;
    }

    private sealed class Request
    {
        internal string Region;
        internal string GameDirectory;
        internal string LauncherPath;
    }

    private sealed class Result
    {
        public bool Success { get; set; }
        public string Region { get; set; }
        public string Status { get; set; }
        public string Message { get; set; }
        public bool GameRegionConfirmed { get; set; }
    }

    private static Result Failure(string region, string status, string message)
    {
        return new Result { Success = false, Region = region ?? String.Empty, Status = status, Message = message, GameRegionConfirmed = false };
    }

    public static int Run(string[] arguments)
    {
        string resultPath = null;
        for (int index = 0; index + 1 < arguments.Length; index++)
            if (arguments[index] == "--result-path") { resultPath = arguments[index + 1]; break; }
        FileStream output;
        try { output = OpenResultFile(resultPath); }
        catch { return 1; }
        using (output)
        {
            Result result = Failure(null, "InvalidRequest", "地区启动参数未通过检查，请重新打开启动器。");
            try
            {
                Request request = ParseArguments(arguments);
                result.Region = request.Region;
                result = SelectAndLaunch(request);
            }
            catch (ArgumentException) { }
            catch { result = Failure(result.Region, "Failed", "无法确认官方游戏地区，请在战网窗口手动选择地区后启动。"); }
            try
            {
                byte[] data = new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(result));
                output.Write(data, 0, data.Length);
                output.Flush();
            }
            catch { return 1; }
            return result.Success ? 0 : 1;
        }
    }

    private static Request ParseArguments(string[] arguments)
    {
        if (arguments.Length != 8 || arguments[0] != "--switch-region") throw new ArgumentException();
        Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int index = 0; index < arguments.Length; index += 2)
        {
            string key = arguments[index];
            if (key != "--switch-region" && key != "--game-directory" && key != "--launcher-path" && key != "--result-path") throw new ArgumentException();
            if (values.ContainsKey(key) || String.IsNullOrWhiteSpace(arguments[index + 1])) throw new ArgumentException();
            values.Add(key, arguments[index + 1]);
        }
        string region = values["--switch-region"];
        if (region != "EU" && region != "US" && region != "KR") throw new ArgumentException();
        string gameDirectory = OrdinaryPath(values["--game-directory"]);
        string launcherPath = OrdinaryPath(values["--launcher-path"]);
        string fileName = Path.GetFileName(launcherPath);
        if (!Directory.Exists(gameDirectory) || !File.Exists(launcherPath) ||
            (fileName != "Battle.net Launcher.exe" && fileName != "Battle.net.exe")) throw new ArgumentException();
        return new Request { Region = region, GameDirectory = gameDirectory, LauncherPath = launcherPath };
    }

    private static string OrdinaryPath(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.StartsWith("\\\\") || path.StartsWith("//")) throw new ArgumentException();
        string full = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (full.Length < 3 || !Path.IsPathRooted(full)) throw new ArgumentException();
        string current = full;
        while (!String.IsNullOrEmpty(current))
        {
            try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new ArgumentException(); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            current = Path.GetDirectoryName(current);
        }
        return full;
    }

    private static FileStream OpenResultFile(string path)
    {
        string full = OrdinaryPath(path);
        string parent = Path.GetDirectoryName(full);
        string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (Path.GetFileName(full) != "region.json" || !Directory.Exists(parent) ||
            !String.Equals(Path.GetDirectoryName(parent), temp, StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(Path.GetFileName(parent), "^sc2-launcher-[0-9a-f]{32}$") ||
            File.Exists(full) || Directory.Exists(full)) throw new ArgumentException();
        return new FileStream(full, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }

    private static string ReadInternationalVersion(string directory)
    {
        string path = OrdinaryPath(Path.Combine(directory, ".build.info"));
        if (!File.Exists(path) || new FileInfo(path).Length > 1024 * 1024 || !File.Exists(Path.Combine(directory, "StarCraft II.exe"))) throw new ArgumentException();
        string[] lines = File.ReadAllLines(path, new UTF8Encoding(false, true));
        if (lines.Length < 2) throw new ArgumentException();
        string[] columns = lines[0].TrimStart('\uFEFF').Split('|');
        int active = -1, branch = -1, version = -1, product = -1;
        for (int index = 0; index < columns.Length; index++)
        {
            string column = columns[index].Split('!')[0];
            if (column == "Active") active = index;
            if (column == "Branch") branch = index;
            if (column == "Version") version = index;
            if (column == "Product") product = index;
        }
        if (active < 0 || branch < 0 || version < 0) throw new ArgumentException();
        string expected = null;
        foreach (string line in lines)
        {
            string[] row = line.Split('|');
            if (row.Length != columns.Length || row[active] != "1") continue;
            if (expected != null || (row[branch] != "eu" && row[branch] != "us" && row[branch] != "kr") ||
                (product >= 0 && row[product] != String.Empty && row[product] != "s2") ||
                !Regex.IsMatch(row[version], "^\\d+\\.\\d+\\.\\d+\\.\\d+$")) throw new ArgumentException();
            expected = row[version];
        }
        if (expected == null) throw new ArgumentException();
        return expected;
    }

    private static bool GameIsRunning()
    {
        string[] names = { "SC2", "SC2_x64", "SC2Editor", "SC2Editor_x64", "SC2Switcher", "SC2Switcher_x64" };
        foreach (string name in names)
        {
            Process[] processes = Process.GetProcessesByName(name);
            bool found = processes.Length > 0;
            foreach (Process process in processes) process.Dispose();
            if (found) return true;
        }
        return false;
    }

    private static Result SelectAndLaunch(Request request)
    {
        Result result = Failure(request.Region, "NeedsOfficialSelection", "未能确认国际服游戏地区，请在官方战网选择欧洲、美洲或亚洲后启动。");
        if (GameIsRunning()) return Failure(request.Region, "GameRunning", "星际争霸 II 或编辑器已经运行，请先退出后再切换地区。");
        string expectedVersion;
        try { expectedVersion = ReadInternationalVersion(request.GameDirectory); }
        catch { return Failure(request.Region, "InvalidRequest", "国际服安装登记未通过检查，请重新检查安装。"); }
        string mainExecutable = Path.Combine(Path.GetDirectoryName(request.LauncherPath), "Battle.net.exe");
        if (!IsBlizzardExecutable(request.LauncherPath) || !IsBlizzardExecutable(mainExecutable))
            return Failure(request.Region, "InvalidRequest", "官方战网程序未通过检查，请重新安装或更新官方战网。");

        DateTime deadline = DateTime.UtcNow.AddSeconds(45);
        AutomationElement window = null;
        bool sawWindow = false;
        while (DateTime.UtcNow < deadline)
        {
            bool login;
            window = FindGameWindow(mainExecutable, out sawWindow, out login);
            if (login) return Failure(request.Region, "NeedsLogin", "请先在官方战网完成登录，再点击对应地区启动。");
            if (window != null) break;
            Thread.Sleep(250);
        }
        if (window == null) return sawWindow ? Failure(request.Region, "NeedsLogin", "请先在官方战网完成登录并打开星际争霸 II 页面，再点击启动。") : result;
        AutomationElement navigation = ById(window, "game-nav-btn-S2");
        if (navigation == null || !Activate(navigation, false)) return result;
        Thread.Sleep(250);

        AutomationElement settings = null;
        while (DateTime.UtcNow < deadline && settings == null)
        {
            settings = FindSettings(window);
            if (settings == null) Thread.Sleep(250);
        }
        if (settings == null || !Activate(settings, false)) return result;
        AutomationElement menu = null;
        while (DateTime.UtcNow < deadline && menu == null)
        {
            menu = FindRegionMenu(window);
            if (menu == null) Thread.Sleep(100);
        }
        if (menu == null || !Activate(menu, true)) return result;
        AutomationElement option = null;
        while (DateTime.UtcNow < deadline && option == null)
        {
            option = FindRegionOption(window, menu, request.Region);
            if (option == null) Thread.Sleep(100);
        }
        if (option == null || !Activate(option, false)) return result;

        AutomationElement play = null;
        while (DateTime.UtcNow < deadline && play == null)
        {
            play = FindPlay(window, request.Region, expectedVersion);
            if (play == null) Thread.Sleep(250);
        }
        if (play == null) return result;
        result.GameRegionConfirmed = true;
        if (GameIsRunning()) return Failure(request.Region, "GameRunning", "星际争霸 II 或编辑器已经运行，本次未重复启动。");
        if (ReadInternationalVersion(request.GameDirectory) != expectedVersion || !IsConfirmedPlay(play.Current.Name, request.Region) || PlayVersion(play.Current.Name) != expectedVersion) return result;
        if (!Activate(play, false)) return result;
        result.Success = true;
        result.Status = "Started";
        result.Message = "已确认官方游戏地区并启动星际争霸 II。";
        return result;
    }

    private static AutomationElement FindGameWindow(string mainExecutable, out bool sawWindow, out bool login)
    {
        sawWindow = false; login = false;
        AutomationElement match = null;
        Process[] processes = Process.GetProcessesByName("Battle.net");
        foreach (Process process in processes)
        {
            try
            {
                if (!String.Equals(process.MainModule.FileName, mainExecutable, StringComparison.OrdinalIgnoreCase)) continue;
                AutomationElementCollection windows = AutomationElement.RootElement.FindAll(TreeScope.Children, new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id));
                foreach (AutomationElement window in windows)
                {
                    if (window.Current.IsOffscreen) continue;
                    sawWindow = true;
                    string name = NormalizeName(window.Current.Name);
                    if (Regex.IsMatch(name, "(?:Login|Sign In|登录|登入)", NameOptions)) { login = true; continue; }
                    AutomationElement nav = ById(window, "game-nav-btn-S2");
                    if (nav == null || !Regex.IsMatch(NormalizeName(nav.Current.Name), "^(?:StarCraft II|星际争霸\\s*II|星際爭霸\\s*II|星海爭霸\\s*II)$", NameOptions)) continue;
                    if (match != null) return null;
                    match = window;
                }
            }
            catch (ElementNotAvailableException) { }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            finally { process.Dispose(); }
        }
        return match;
    }

    private static AutomationElement ById(AutomationElement root, string id)
    {
        return root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, id));
    }

    private static bool Visible(AutomationElement element)
    {
        return !element.Current.IsOffscreen && element.Current.IsEnabled;
    }

    private static AutomationElement FindSettings(AutomationElement window)
    {
        AutomationElement match = null;
        bool globalVersion = false;
        AutomationElementCollection buttons = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
        foreach (AutomationElement button in buttons)
        {
            if (!Visible(button) || !Regex.IsMatch(button.Current.AutomationId, "^DropdownMenu_[0-9]+_button$")) continue;
            string name = NormalizeName(button.Current.Name);
            if (Regex.IsMatch(name, "^(?:Game Version|游戏版本|遊戲版本) (?:StarCraft II|星际争霸\\s*II|星際爭霸\\s*II|星海爭霸\\s*II)$", NameOptions)) globalVersion = true;
            if (name.Length != 0) continue;
            if (match != null) return null;
            match = button;
        }
        return globalVersion ? match : null;
    }

    private static AutomationElement FindRegionMenu(AutomationElement window)
    {
        AutomationElement match = null;
        foreach (AutomationElement item in window.FindAll(TreeScope.Descendants, Condition.TrueCondition))
        {
            if (!Visible(item) || !Regex.IsMatch(item.Current.AutomationId, "^DropdownMenu_[0-9]+_[0-9]+$") || ParseRegionMenuName(item.Current.Name) == null) continue;
            if (match != null) return null;
            match = item;
        }
        return match;
    }

    private static AutomationElement FindRegionOption(AutomationElement window, AutomationElement menu, string region)
    {
        Match id = Regex.Match(menu.Current.AutomationId, "^DropdownMenu_([0-9]+)_([0-9]+)$");
        if (!id.Success) return null;
        AutomationElement submenu = ById(window, "DropdownMenu_" + id.Groups[1].Value + "_submenu_" + id.Groups[2].Value);
        if (submenu == null || ParseRegionMenuName(submenu.Current.Name) == null) return null;
        Dictionary<string, AutomationElement> options = new Dictionary<string, AutomationElement>();
        foreach (AutomationElement item in submenu.FindAll(TreeScope.Descendants, Condition.TrueCondition))
        {
            ControlType type = item.Current.ControlType;
            if (!Visible(item) || (type != ControlType.MenuItem && type != ControlType.Button && type != ControlType.ListItem)) continue;
            string parsed = ParseRegionOptionName(item.Current.Name);
            if (parsed == null) continue;
            if (options.ContainsKey(parsed)) return null;
            options.Add(parsed, item);
        }
        return options.Count == 3 && options.ContainsKey(region) ? options[region] : null;
    }

    private static AutomationElement FindPlay(AutomationElement window, string region, string version)
    {
        AutomationElement match = null;
        foreach (AutomationElement button in window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)))
        {
            if (!Visible(button) || !IsConfirmedPlay(button.Current.Name, region) || PlayVersion(button.Current.Name) != version) continue;
            if (match != null) return null;
            match = button;
        }
        return match;
    }

    private static bool Activate(AutomationElement element, bool expand)
    {
        if (!Visible(element)) return false;
        object pattern;
        if (expand && element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out pattern))
        {
            ExpandCollapsePattern expandable = (ExpandCollapsePattern)pattern;
            if (expandable.Current.ExpandCollapseState != ExpandCollapseState.Expanded) expandable.Expand();
            return true;
        }
        if (element.TryGetCurrentPattern(InvokePattern.Pattern, out pattern)) { ((InvokePattern)pattern).Invoke(); return true; }
        if (!expand && element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pattern)) { ((SelectionItemPattern)pattern).Select(); return true; }
        return false;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile
    {
        internal uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] internal string Path;
        internal IntPtr File;
        internal IntPtr Subject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData
    {
        internal uint Size;
        internal IntPtr Policy;
        internal IntPtr Sip;
        internal uint UiChoice;
        internal uint Revocation;
        internal uint UnionChoice;
        internal IntPtr File;
        internal uint StateAction;
        internal IntPtr State;
        internal IntPtr Url;
        internal uint ProviderFlags;
        internal uint UiContext;
    }

    [DllImport("wintrust.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);

    private static bool IsBlizzardExecutable(string path)
    {
        IntPtr filePointer = IntPtr.Zero;
        try
        {
            OrdinaryPath(path);
            if (!File.Exists(path)) return false;
            using (X509Certificate2 certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path)))
            {
                if (certificate.GetNameInfo(X509NameType.SimpleName, false) != "Blizzard Entertainment, Inc.") return false;
            }
            TrustFile file = new TrustFile { Size = (uint)Marshal.SizeOf(typeof(TrustFile)), Path = path };
            filePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TrustFile)));
            Marshal.StructureToPtr(file, filePointer, false);
            TrustData data = new TrustData { Size = (uint)Marshal.SizeOf(typeof(TrustData)), UiChoice = 2, UnionChoice = 1, File = filePointer, ProviderFlags = 0x1000 };
            Guid action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            return WinVerifyTrust(IntPtr.Zero, ref action, ref data) == 0;
        }
        catch { return false; }
        finally
        {
            if (filePointer != IntPtr.Zero) { Marshal.DestroyStructure(filePointer, typeof(TrustFile)); Marshal.FreeHGlobal(filePointer); }
        }
    }
}
