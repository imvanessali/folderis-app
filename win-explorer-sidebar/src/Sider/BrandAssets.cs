using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Sider;

/// <summary>
/// 面板/引导页 logo 的统一来源：内置默认、内置 Clippy 或用户自定义图片
/// （对齐 mac BrandLogo.swift）。自定义图片导入时居中裁成正方形，超过
/// 512px 等比压缩，统一落盘为 PNG。
/// </summary>
public static class BrandAssets
{
    /// 处理后图片的最大边长（像素）。
    public const int MaxLogoPixels = 512;

    public static string CustomLogoPath => Path.Combine(SkillRunner.SupportRoot, "custom-logo.png");

    /// <summary>choice: orb | clippy | custom；自定义文件缺失/损坏时退回默认。</summary>
    public static ImageSource Logo(string choice)
    {
        if (choice == "custom" && File.Exists(CustomLogoPath))
        {
            try { return LoadFromFile(CustomLogoPath); }
            catch { /* 落盘文件损坏 → 退回内置 */ }
        }
        var name = choice == "clippy" ? "clippy.png" : "app.png";
        return new BitmapImage(new Uri($"pack://application:,,,/Assets/{name}"));
    }

    /// 不锁文件、绕过磁盘缓存：重新导入后无需重启即可生效。
    private static ImageSource LoadFromFile(string path)
    {
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.UriSource = new Uri(path);
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.CreateOptions = BitmapCreateOptions.IgnoreImageCache;
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    /// <summary>导入用户图片：居中裁方 + 压缩 + 存 PNG。抛错时原自定义图保持不变。</summary>
    public static void ImportCustom(string sourcePath)
    {
        BitmapSource src;
        using (var fs = File.OpenRead(sourcePath))
        {
            var decoder = BitmapDecoder.Create(fs, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            src = decoder.Frames[0];
        }

        var side = Math.Min(src.PixelWidth, src.PixelHeight);
        if (side < src.PixelWidth || side < src.PixelHeight)
        {
            src = new CroppedBitmap(src, new Int32Rect(
                (src.PixelWidth - side) / 2, (src.PixelHeight - side) / 2, side, side));
        }
        if (side > MaxLogoPixels)
        {
            var scale = (double)MaxLogoPixels / side;
            src = new TransformedBitmap(src, new ScaleTransform(scale, scale));
        }

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(src));
        Directory.CreateDirectory(SkillRunner.SupportRoot);
        using var output = File.Create(CustomLogoPath);
        encoder.Save(output);
    }
}
