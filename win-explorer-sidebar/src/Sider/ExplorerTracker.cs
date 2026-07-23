using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Automation;

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
    private string? _lastFolder;
    private ExplorerContext? _lastContext;
    private readonly Dictionary<(nint Hwnd, string Folder), string> _selectionSnapshots = [];

    /// <summary>枚举所有 Explorer 窗口，返回前台那个（或 null）。</summary>
    public ExplorerContext? GetFrontmost()
    {
        var foreground = NativeMethods.GetForegroundWindow();
        var contexts = EnumerateWindows();
        var matches = new List<ExplorerContext>();
        var previousWindow = new List<ExplorerContext>();
        ExplorerContext? first = null;

        foreach (var ctx in contexts)
        {
            if (ctx.Hwnd == foreground) matches.Add(ctx);
            if (ctx.Hwnd == _lastHwnd) previousWindow.Add(ctx);
            first ??= ctx;
        }

        ExplorerContext? resolved = null;
        if (matches.Count > 0)
        {
            _lastHwnd = foreground;
            resolved = matches.Count == 1
                ? matches[0]
                : ResolveTabbedWindow(matches, NativeMethods.GetWindowTitle(foreground));
            _lastFolder = resolved.FolderPath;
            _lastContext = resolved;
        }
        UpdateSelectionSnapshots(contexts);
        if (resolved is not null) return resolved;
        // 前台不是 Explorer（比如用户在面板里打字）：保持上一个窗口的上下文，
        // 且 Win11 多标签共享 HWND 时恢复上次精确解析的标签，而不是该 HWND
        // 在 ShellWindows 枚举顺序里的第一个标签。
        return PreviousContext(previousWindow) ?? first;
    }

    private ExplorerContext? PreviousContext(IReadOnlyList<ExplorerContext> candidates)
    {
        if (_lastContext is not null)
        {
            var exact = candidates.FirstOrDefault(candidate =>
                string.Equals(candidate.FolderPath, _lastContext.FolderPath, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(SelectionKey(candidate.SelectedPaths),
                              SelectionKey(_lastContext.SelectedPaths),
                              StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;
        }
        if (_lastFolder is not null)
            return candidates.FirstOrDefault(candidate =>
                string.Equals(candidate.FolderPath, _lastFolder, StringComparison.OrdinalIgnoreCase));
        return candidates.FirstOrDefault();
    }

    /// <summary>
    /// Win11 tabs share an HWND. Prefer the folder that best matches the active
    /// window title, and use a newly changed selection to break ambiguous title
    /// matches (for example two tabs whose leaf folders have the same name).
    /// </summary>
    private ExplorerContext ResolveTabbedWindow(
        IReadOnlyList<ExplorerContext> matches,
        string title)
    {
        var titleScored = matches
            .Select(context => (Context: context, Score: TitleMatchScore(context.FolderPath, title)))
            .ToArray();
        var bestTitleScore = titleScored.Max(candidate => candidate.Score);
        var candidates = titleScored
            .Where(candidate => candidate.Score == bestTitleScore)
            .Select(candidate => candidate.Context)
            .ToArray();
        if (candidates.Length == 1) return candidates[0];

        var addressBarText = GetAddressBarText(matches[0].Hwnd);
        var addressScored = candidates
            .Select(context => (
                Context: context,
                Score: AddressMatchScore(context.FolderPath, addressBarText)))
            .ToArray();
        var bestAddressScore = addressScored.Max(candidate => candidate.Score);
        candidates = addressScored
            .Where(candidate => candidate.Score == bestAddressScore)
            .Select(candidate => candidate.Context)
            .ToArray();
        if (candidates.Length == 1) return candidates[0];

        var changed = candidates.Where(SelectionChangedSinceLastPoll).ToArray();
        if (changed.Length == 1) return changed[0];

        if (_lastFolder is not null)
        {
            var previous = candidates.FirstOrDefault(candidate =>
                string.Equals(candidate.FolderPath, _lastFolder, StringComparison.OrdinalIgnoreCase));
            if (previous is not null) return previous;
        }
        return candidates[^1];
    }

    /// <summary>
    /// Explorer's localized address bar keeps enough parent-folder context to
    /// distinguish tabs whose leaf names (and therefore window titles) match.
    /// Automation id 41477 is the shell address-band control; failures remain
    /// non-fatal because title/selection heuristics still work.
    /// </summary>
    private static string? GetAddressBarText(nint hwnd)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            var address = root.FindFirst(
                TreeScope.Descendants,
                new PropertyCondition(AutomationElement.AutomationIdProperty, "41477"));
            if (address is null) return null;

            var parts = new List<string>();
            if (!string.IsNullOrWhiteSpace(address.Current.Name))
                parts.Add(address.Current.Name);
            if (address.TryGetCurrentPattern(ValuePattern.Pattern, out var directPattern) &&
                directPattern is ValuePattern directValue &&
                !string.IsNullOrWhiteSpace(directValue.Current.Value))
                parts.Add(directValue.Current.Value);

            var valueElements = address.FindAll(
                TreeScope.Descendants,
                new PropertyCondition(AutomationElement.IsValuePatternAvailableProperty, true));
            foreach (AutomationElement element in valueElements)
            {
                if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern) &&
                    pattern is ValuePattern value &&
                    !string.IsNullOrWhiteSpace(value.Current.Value))
                    parts.Add(value.Current.Value);
            }
            return string.Join("\n", parts.Distinct(StringComparer.OrdinalIgnoreCase));
        }
        catch
        {
            return null;
        }
    }

    internal static int TitleMatchScore(string? folderPath, string title)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || string.IsNullOrWhiteSpace(title)) return 0;
        var folder = folderPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.Equals(title, folder, StringComparison.OrdinalIgnoreCase) ||
            title.StartsWith(folder + " - ", StringComparison.OrdinalIgnoreCase))
            return 3;
        var leaf = Path.GetFileName(folder);
        if (string.IsNullOrEmpty(leaf)) return 0;
        if (string.Equals(title, leaf, StringComparison.OrdinalIgnoreCase) ||
            title.StartsWith(leaf + " - ", StringComparison.OrdinalIgnoreCase))
            return 2;
        return title.Contains(leaf, StringComparison.OrdinalIgnoreCase) ? 1 : 0;
    }

    internal static int AddressMatchScore(string? folderPath, string? addressBarText)
    {
        if (string.IsNullOrWhiteSpace(folderPath) || string.IsNullOrWhiteSpace(addressBarText))
            return 0;
        var folder = folderPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var components = folder
            .Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries)
            .Where(component => !component.EndsWith(':'))
            .ToArray();
        if (components.Length == 0) return 0;

        var addressComponents = addressBarText
            .Split(['\\', '/', '>', '\n'],
                   StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var longestRun = 0;
        for (var candidateStart = 0; candidateStart < components.Length; candidateStart++)
        {
            for (var addressStart = 0; addressStart < addressComponents.Length; addressStart++)
            {
                var run = 0;
                while (candidateStart + run < components.Length &&
                       addressStart + run < addressComponents.Length &&
                       string.Equals(components[candidateStart + run],
                                     addressComponents[addressStart + run],
                                     StringComparison.OrdinalIgnoreCase))
                    run++;
                longestRun = Math.Max(longestRun, run);
                if (candidateStart == 0 && run == components.Length)
                    return 80;
            }
        }
        return longestRun;
    }

    private bool SelectionChangedSinceLastPoll(ExplorerContext context)
    {
        if (context.FolderPath is null) return false;
        return _selectionSnapshots.TryGetValue((context.Hwnd, context.FolderPath), out var previous) &&
               !string.Equals(previous, SelectionKey(context.SelectedPaths), StringComparison.OrdinalIgnoreCase);
    }

    private void UpdateSelectionSnapshots(IEnumerable<ExplorerContext> contexts)
    {
        _selectionSnapshots.Clear();
        foreach (var context in contexts)
        {
            if (context.FolderPath is not null)
                _selectionSnapshots[(context.Hwnd, context.FolderPath)] = SelectionKey(context.SelectedPaths);
        }
    }

    private static string SelectionKey(IEnumerable<string> paths) =>
        string.Join("\n", paths.OrderBy(path => path, StringComparer.OrdinalIgnoreCase));

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
