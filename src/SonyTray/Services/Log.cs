using System.IO;

namespace SonyTray.Services;

public static class Log
{
    private static readonly object Gate = new();
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SonyTray", "logs");
    private static readonly string File_ = Path.Combine(Dir, "app.log");
    private const long MaxBytes = 1_000_000;

    public static void Info(string message) => Write("INF", message);
    public static void Debug(string message) => Write("DBG", message);
    public static void Error(string message) => Write("ERR", message);

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                if (File.Exists(File_) && new FileInfo(File_).Length > MaxBytes)
                    File.Move(File_, Path.Combine(Dir, "app.1.log"), overwrite: true);
                File.AppendAllText(File_, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {message}{Environment.NewLine}");
            }
            catch (IOException) { /* logging must never crash the app */ }
        }
    }
}
