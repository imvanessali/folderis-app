using System.IO;
using System.Runtime.InteropServices;

namespace Sider;

/// <summary>
/// 资源管理器上下文追踪：当前活跃的 Explorer 窗口、其目录与选中项。
/// Windows 在这件事上有正式接口（Shell.Application COM 自动化），
/// 不需要 macOS 那种 AppleScript 轮询 hack。
/// </summary>
public sealed record ExplorerContext(
    nint Hwnd,
    string? FolderPath,
    IReadOnlyList<string> SelectedPaths);

public sealed class ExplorerTracker
{
    private dynamic? _shell;

    private dynamic Shell =>
        _shell ??= Activator.CreateInstance(
            Type.GetTypeFromProgID("Shell.Application")
                ?? throw new InvalidOperationException("Shell.Application 不可用"))!;

    private nint _lastHwnd;

    /// <summary>枚举所有 Explorer 窗口，返回前台那个（或 null）。</summary>
    public ExplorerContext? GetFrontmost()
    {
        var foreground = NativeMethods.GetForegroundWindow();
        var matches = new List<ExplorerContext>();
        ExplorerContext? last = null, first = null;

        foreach (var ctx in EnumerateWindows())
        {
            if (ctx.Hwnd == foreground) matches.Add(ctx);
            if (ctx.Hwnd == _lastHwnd) last ??= ctx;
            first ??= ctx;
        }

        if (matches.Count > 0)
        {
            _lastHwnd = foreground;
            if (matches.Count == 1) return matches[0];
            // Win11 标签页：同一 HWND 会对应多个 ShellWindows 条目（每标签一个）。
            // 用窗口标题（=活动标签的文件夹名）挑出当前标签。
            var title = NativeMethods.GetWindowTitle(foreground);
            return matches.FirstOrDefault(m =>
                       !string.IsNullOrEmpty(m.FolderPath) &&
                       title.Contains(Path.GetFileName(m.FolderPath.TrimEnd('\\'))))
                   ?? matches[^1];
        }
        // 前台不是 Explorer（比如用户在面板里打字）：保持上一个窗口的上下文，
        // 而不是跳回枚举顺序里的第一个窗口。
        return last ?? first;
    }

    public IReadOnlyList<ExplorerContext> EnumerateWindows()
    {
        var result = new List<ExplorerContext>();
        object? windowsObject = null;
        try
        {
            dynamic windows = Shell.Windows();
            windowsObject = windows;
            int count = windows.Count;
            for (int i = 0; i < count; i++)
            {
                object? windowObject = null;
                object? documentObject = null;
                object? folderObject = null;
                object? selfObject = null;
                object? itemsObject = null;
                try
                {
                    dynamic window = windows.Item(i);
                    windowObject = window;
                    if (windowObject is null) continue;

                    string fullName = (string)window.FullName;
                    if (!fullName.EndsWith("explorer.exe", StringComparison.OrdinalIgnoreCase))
                        continue;

                    nint hwnd = (nint)(long)window.HWND;
                    dynamic document = window.Document;
                    documentObject = document;
                    dynamic folderItem = document.Folder;
                    folderObject = folderItem;
                    dynamic self = folderItem.Self;
                    selfObject = self;
                    string? folder = self.Path as string;
                    if (folder is null || folder.StartsWith("::")) continue;

                    var selected = new List<string>();
                    dynamic items = document.SelectedItems();
                    itemsObject = items;
                    int itemCount = items.Count;
                    for (int j = 0; j < itemCount; j++)
                    {
                        object? itemObject = null;
                        try
                        {
                            dynamic item = items.Item(j);
                            itemObject = item;
                            string? path = item?.Path as string;
                            if (path is not null) selected.Add(path);
                        }
                        catch (COMException) { }
                        finally { ReleaseCom(itemObject); }
                    }
                    result.Add(new ExplorerContext(hwnd, folder, selected));
                }
                catch (COMException)
                {
                    // Explorer windows disappear during close/tab switches. Skip stale RCWs.
                }
                catch (InvalidComObjectException) { }
                finally
                {
                    ReleaseCom(itemsObject);
                    ReleaseCom(selfObject);
                    ReleaseCom(folderObject);
                    ReleaseCom(documentObject);
                    ReleaseCom(windowObject);
                }
            }
        }
        catch (COMException)
        {
            ResetShell();
        }
        catch (InvalidComObjectException)
        {
            ResetShell();
        }
        finally
        {
            ReleaseCom(windowsObject);
        }
        return result;
    }

    private void ResetShell()
    {
        ReleaseCom(_shell);
        _shell = null;
    }

    private static void ReleaseCom(object? value)
    {
        if (value is null || !Marshal.IsComObject(value)) return;
        try { Marshal.ReleaseComObject(value); }
        catch (COMException) { }
        catch (InvalidComObjectException) { }
    }
}
