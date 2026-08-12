using System.Drawing;
using System.Drawing.Drawing2D;

namespace XM5Control.Services;

public static class TrayIconFactory
{
    /// <summary>Draws a simple headphone glyph; green status dot when connected, gray otherwise.</summary>
    public static Icon Create(bool connected)
    {
        using var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var band = new Pen(Color.White, 2f);
            g.DrawArc(band, 2, 2, 12, 12, 180, 180);            // headband
            using var pad = new SolidBrush(Color.White);
            g.FillRectangle(pad, 1, 8, 4, 6);                    // left pad
            g.FillRectangle(pad, 11, 8, 4, 6);                   // right pad
            using var dot = new SolidBrush(connected ? Color.LimeGreen : Color.Gray);
            g.FillEllipse(dot, 10, 10, 6, 6);                    // status dot
        }
        nint h = bmp.GetHicon();
        try { return (Icon)Icon.FromHandle(h).Clone(); }
        finally { DestroyIcon(h); }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint handle);
}
