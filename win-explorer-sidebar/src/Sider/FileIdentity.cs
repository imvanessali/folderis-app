using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Sider;

/// NTFS 文件身份（卷序列号 + FileIndex）：重命名/同卷移动后保持不变，
/// 作为会话绑定的稳定标识。拿不到（网络盘、无权限、FAT 卷不保证）返回 null，
/// 调用方退回路径比较。
internal static class FileIdentity
{
    public static string? TryGet(string path)
    {
        try
        {
            // dwDesiredAccess=0：只查元数据，不要求读权限；
            // FILE_FLAG_BACKUP_SEMANTICS 才能打开文件夹句柄。
            using var handle = CreateFileW(
                path, 0,
                (uint)(FileShare.ReadWrite | FileShare.Delete),
                IntPtr.Zero, OpenExisting, FileFlagBackupSemantics, IntPtr.Zero);
            if (handle.IsInvalid) return null;
            if (!GetFileInformationByHandle(handle, out var info)) return null;
            var index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            return $"id:{info.VolumeSerialNumber:x8}-{index:x16}";
        }
        catch
        {
            return null;
        }
    }

    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle hFile, out ByHandleFileInformation lpFileInformation);
}
