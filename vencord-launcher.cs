using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

// Compile as WindowsApplication: the launcher itself must never own a console.
internal static class VencordLauncher
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);

    private static int Main(string[] args)
    {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""
                    + Path.Combine(directory, "setup-vencord-launcher.ps1") + "\" -Mode "
                    + (args.Length == 1 && args[0] == "--setup" ? "ConfigureShortcut" : "Launch"),
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process process = Process.Start(start))
            {
                process.WaitForExit();
                if (process.ExitCode == 0 && args.Length == 1 && args[0] == "--setup")
                {
                    string shortcut = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                        @"Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Discord.lnk");
                    // Tell Explorer that its existing pinned shell link changed.
                    SHChangeNotify(0x2000, 0x1005, shortcut, IntPtr.Zero);
                }
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            File.AppendAllText(Path.Combine(directory, "launcher.log"),
                DateTime.Now.ToString("o") + " " + error.Message + Environment.NewLine);
            return 1;
        }
    }
}
