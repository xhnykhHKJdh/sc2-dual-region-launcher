// SPDX-License-Identifier: MIT
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("StarCraft II Dual Region Launcher")]
[assembly: AssemblyDescription("Windows host for the local StarCraft II launcher interface")]
[assembly: AssemblyProduct("StarCraft II Dual Region Launcher")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Sc2LauncherHost
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        if (arguments.Length != 0) return Sc2BattleRegionSelector.Run(arguments);
        try
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // The generated executable lives in dist, beside the source scripts.
            string repositoryRoot = Path.GetFullPath(
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            string scriptPath = Path.Combine(repositoryRoot, "scripts", "Show-SC2Launcher.ps1");
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException(
                    "找不到启动器界面。请保留完整的启动器文件夹，然后运行 Start.cmd。", scriptPath);
            }

            InitialSessionState session = InitialSessionState.CreateDefault();
            // This applies only to the in-process runspace and its fixed local entry point.
            session.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace runspace = RunspaceFactory.CreateRunspace(session))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                runspace.Open();

                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    // Invoke a file command so PSScriptRoot and InvocationInfo remain correct.
                    // The UI's Application.Run keeps this invocation alive until it closes.
                    powershell.AddCommand(scriptPath);
                    powershell.Invoke();
                    if (powershell.HadErrors)
                    {
                        StringBuilder errors = new StringBuilder();
                        int count = Math.Min(powershell.Streams.Error.Count, 5);
                        for (int index = 0; index < count; index++)
                        {
                            if (index > 0) errors.AppendLine().AppendLine();
                            errors.Append(powershell.Streams.Error[index].ToString());
                        }
                        throw new InvalidOperationException(errors.ToString());
                    }
                }
            }
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "启动器无法打开。\r\n\r\n" + exception.Message,
                "星际争霸 II 双服启动器",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
