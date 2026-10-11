// Windows 11 look for the tray: theme, menu renderer, icons, buttons.
// Compiled at runtime by Tray.ps1 (Add-Type), so the repo has no binaries.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace LSM
{
    public static class Win
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr hProcess);

        // Gives back memory used only during startup (compiling, loading).
        public static void Trim()
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
        }

        // Rounded corners, border color and dark title bar on Windows 11 (ignored on 10).
        public static void Style(IntPtr hwnd, Theme t)
        {
            int round = 2, dark = t.Dark ? 1 : 0, border = ColorTranslator.ToWin32(t.Border);
            DwmSetWindowAttribute(hwnd, 33, ref round, 4);
            DwmSetWindowAttribute(hwnd, 34, ref border, 4);
            DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
        }

        public static void ScreenOff()
        {
            PostMessage((IntPtr)0xffff, 0x0112, (IntPtr)0xF170, (IntPtr)2);
        }
    }

    public class Theme
    {
        public bool Dark, TaskbarDark;
        public Color Bg, Fg, Fg2, Hover, Line, Border, Accent, OnAccent, Good, Warn, Bad, Button, ButtonHover;
        public float Scale = 1f;
        public string IconFont, TextFont;

        public int Px(float v) { return (int)Math.Round(v * Scale); }

        public static Theme Load(float scale)
        {
            var t = new Theme();
            t.Scale = scale;
            t.Dark = ReadDword(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) == 0;
            t.TaskbarDark = ReadDword(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0) == 0;

            // AccentColor is stored as 0xAABBGGRR.
            int abgr = ReadDword(@"Software\Microsoft\Windows\DWM", "AccentColor", unchecked((int)0xFFD47800));
            Color accent = Color.FromArgb(255, abgr & 0xFF, (abgr >> 8) & 0xFF, (abgr >> 16) & 0xFF);

            if (t.Dark)
            {
                t.Bg = Color.FromArgb(44, 44, 44); t.Fg = Color.FromArgb(255, 255, 255); t.Fg2 = Color.FromArgb(170, 170, 170);
                t.Hover = Color.FromArgb(58, 58, 58); t.Line = Color.FromArgb(64, 64, 64); t.Border = Color.FromArgb(70, 70, 70);
                t.Accent = Mix(accent, Color.White, 0.35f); t.OnAccent = Color.Black;
                t.Good = Color.FromArgb(108, 203, 95); t.Warn = Color.FromArgb(252, 200, 60); t.Bad = Color.FromArgb(255, 153, 164);
                t.Button = Color.FromArgb(55, 55, 55); t.ButtonHover = Color.FromArgb(65, 65, 65);
            }
            else
            {
                t.Bg = Color.FromArgb(249, 249, 249); t.Fg = Color.FromArgb(26, 26, 26); t.Fg2 = Color.FromArgb(96, 96, 96);
                t.Hover = Color.FromArgb(234, 234, 234); t.Line = Color.FromArgb(225, 225, 225); t.Border = Color.FromArgb(214, 214, 214);
                t.Accent = accent; t.OnAccent = Color.White;
                t.Good = Color.FromArgb(15, 123, 15); t.Warn = Color.FromArgb(157, 93, 0); t.Bad = Color.FromArgb(196, 43, 28);
                t.Button = Color.FromArgb(255, 255, 255); t.ButtonHover = Color.FromArgb(243, 243, 243);
            }

            t.IconFont = HasFont("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
            t.TextFont = HasFont("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";
            return t;
        }

        public Font Font(float pt) { return Font(pt, FontStyle.Regular); }

        public Font Font(float pt, FontStyle style)
        {
            string name = (style & FontStyle.Bold) != 0 && HasFont("Segoe UI Variable Display Semibold")
                ? "Segoe UI Variable Display Semibold" : TextFont;
            if (name.EndsWith("Semibold")) style &= ~FontStyle.Bold;
            return new Font(name, pt, style);
        }

        static int ReadDword(string key, string name, int fallback)
        {
            using (var k = Registry.CurrentUser.OpenSubKey(key))
            {
                object v = k == null ? null : k.GetValue(name);
                return v is int ? (int)v : fallback;
            }
        }

        static bool HasFont(string name)
        {
            using (var f = new Font(name, 10f)) return f.Name == name;
        }

        public static Color Mix(Color a, Color b, float t)
        {
            return Color.FromArgb(255, (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }
    }

    public static class Art
    {
        public static GraphicsPath Round(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = radius * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static Graphics Smooth(Bitmap bmp)
        {
            var g = Graphics.FromImage(bmp);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            return g;
        }

        // Icon-font glyph scaled to fill `box`, centred in a size x size bitmap.
        static void FillGlyph(Graphics g, string font, string glyph, RectangleF box, Color c)
        {
            using (var fam = new FontFamily(font))
            using (var path = new GraphicsPath())
            {
                path.AddString(glyph, fam, 0, 100f, PointF.Empty, StringFormat.GenericTypographic);
                RectangleF b = path.GetBounds();
                float s = Math.Min(box.Width / b.Width, box.Height / b.Height);
                using (var m = new Matrix())
                {
                    m.Translate(box.X + (box.Width - b.Width * s) / 2, box.Y + (box.Height - b.Height * s) / 2);
                    m.Scale(s, s);
                    m.Translate(-b.X, -b.Y);
                    path.Transform(m);
                }
                using (var br = new SolidBrush(c)) g.FillPath(br, path);
            }
        }

        public static Bitmap Glyph(Theme t, string glyph, int size, Color c)
        {
            return Glyph(t, glyph, size, c, 0.06f);
        }

        // `pad` is the empty margin on each side, as a fraction of `size`.
        public static Bitmap Glyph(Theme t, string glyph, int size, Color c, float pad)
        {
            var bmp = new Bitmap(size, size);
            using (var g = Smooth(bmp))
            {
                pad *= size;
                FillGlyph(g, t.IconFont, glyph, new RectangleF(pad, pad, size - 2 * pad, size - 2 * pad), c);
            }
            return bmp;
        }

        public static Bitmap Dot(int size, Color c)
        {
            var bmp = new Bitmap(size, size);
            using (var g = Smooth(bmp))
            using (var br = new SolidBrush(c))
            {
                float d = size * 0.5f;
                g.FillEllipse(br, (size - d) / 2, (size - d) / 2, d, d);
            }
            return bmp;
        }

        // Monochrome laptop like the other tray icons, plus a status badge
        // cut out of the glyph (same idea as the OneDrive/sync badges).
        public static Icon Tray(Theme t, int size, Color? badge, bool dim)
        {
            Color fg = t.TaskbarDark ? Color.White : Color.Black;
            if (dim) fg = Color.FromArgb(150, fg);
            var bmp = new Bitmap(size, size);
            using (var g = Smooth(bmp))
            {
                FillGlyph(g, t.IconFont, "\uE7F8", new RectangleF(0, size * 0.08f, size, size * 0.84f), fg);
                if (badge.HasValue)
                {
                    float d = size * 0.5f, ring = size * 0.09f;
                    var r = new RectangleF(size - d, size - d, d, d);
                    g.CompositingMode = CompositingMode.SourceCopy;
                    using (var clear = new SolidBrush(Color.Transparent))
                        g.FillEllipse(clear, RectangleF.Inflate(r, ring, ring));
                    g.CompositingMode = CompositingMode.SourceOver;
                    using (var br = new SolidBrush(badge.Value)) g.FillEllipse(br, r);
                }
            }
            return System.Drawing.Icon.FromHandle(bmp.GetHicon());
        }

        // App tile used for notifications: brand-blue rounded square, white laptop.
        public static Bitmap Tile(Theme t, int size)
        {
            var bmp = new Bitmap(size, size);
            using (var g = Smooth(bmp))
            {
                using (var path = Round(new RectangleF(0, 0, size - 1, size - 1), size * 0.22f))
                using (var br = new LinearGradientBrush(new Rectangle(0, 0, size, size),
                           Color.FromArgb(56, 148, 230), Color.FromArgb(16, 96, 176), 90f))
                    g.FillPath(br, path);
                float pad = size * 0.2f;
                FillGlyph(g, t.IconFont, "\uE7F8", new RectangleF(pad, pad, size - 2 * pad, size - 2 * pad), Color.White);
            }
            return bmp;
        }
    }

    // Menu renderer in the Windows 11 style: flat, rounded hover, toggle switch.
    // Item roles are set through ToolStripItem.Name:
    //   "toggle-on" / "toggle-off"  draws a switch in the shortcut column
    //   "header"                    disabled but drawn in normal text color
    //   "status-good|warn|bad|none" colors the shortcut column text
    public class Renderer : ToolStripRenderer
    {
        readonly Theme t;
        public Renderer(Theme theme) { t = theme; }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(t.Bg); }
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }
        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected || !e.Item.Enabled) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(0, t.Px(1), e.Item.Width - 1, e.Item.Height - t.Px(2));
            using (var p = Art.Round(r, t.Px(4)))
            using (var br = new SolidBrush(t.Hover))
                e.Graphics.FillPath(br, p);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            var mi = e.Item as ToolStripMenuItem;
            string role = e.Item.Name ?? "";
            bool shortcut = mi != null && !string.IsNullOrEmpty(mi.ShortcutKeyDisplayString) && e.Text == mi.ShortcutKeyDisplayString;

            if (shortcut && role.StartsWith("toggle"))
            {
                DrawSwitch(e.Graphics, e.TextRectangle, e.Item.Width - t.Px(12), role == "toggle-on");
                return;
            }
            Color c = e.Item.Enabled || role == "header" ? t.Fg : t.Fg2;
            if (shortcut && role == "status-good") c = t.Good;
            if (shortcut && role == "status-warn") c = t.Warn;
            if (shortcut && role == "status-bad") c = t.Bad;
            if (shortcut && role == "status-none") c = t.Fg2;
            TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, e.TextRectangle, c, e.TextFormat);
        }

        void DrawSwitch(Graphics g, Rectangle area, float right, bool on)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float w = t.Px(40), h = t.Px(20);
            var r = new RectangleF(right - w, area.Y + (area.Height - h) / 2f, w, h);
            using (var p = Art.Round(r, h / 2))
            {
                if (on) using (var br = new SolidBrush(t.Accent)) g.FillPath(br, p);
                else using (var pen = new Pen(t.Fg2, Math.Max(1f, t.Scale))) g.DrawPath(pen, p);
            }
            float knob = h * (on ? 0.6f : 0.5f);
            float x = on ? r.Right - h / 2 - knob / 2 : r.X + h / 2 - knob / 2;
            using (var br = new SolidBrush(on ? t.OnAccent : t.Fg2))
                g.FillEllipse(br, x, r.Y + (h - knob) / 2, knob, knob);
        }

        protected override void OnRenderItemImage(ToolStripItemImageRenderEventArgs e)
        {
            if (e.Image != null) e.Graphics.DrawImage(e.Image, e.ImageRectangle);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { OnRenderItemImage(e); }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using (var pen = new Pen(t.Line, Math.Max(1f, t.Scale)))
                e.Graphics.DrawLine(pen, t.Px(4), y, e.Item.Width - t.Px(4), y);
        }

        // Chevron that scales with DPI (the stock arrow stays 4px).
        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float cx = e.ArrowRectangle.X + e.ArrowRectangle.Width / 2f, cy = e.ArrowRectangle.Y + e.ArrowRectangle.Height / 2f;
            float a = t.Px(3.5f);
            using (var pen = new Pen(t.Fg2, Math.Max(1f, t.Px(1.2f))))
            {
                pen.StartCap = pen.EndCap = LineCap.Round;
                g.DrawLines(pen, new[] { new PointF(cx - a / 2, cy - a), new PointF(cx + a / 2, cy), new PointF(cx - a / 2, cy + a) });
            }
        }
    }

    // Flat rounded button (accent-filled when Primary).
    public class FlatButton : Button
    {
        public Theme T;
        public bool Primary;
        bool hover;

        public FlatButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            Cursor = Cursors.Hand;
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Parent.BackColor);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            Color fill = Primary ? (hover ? Theme.Mix(T.Accent, T.Dark ? Color.Black : Color.White, 0.1f) : T.Accent)
                                 : (hover ? T.ButtonHover : T.Button);
            using (var p = Art.Round(r, T.Px(4)))
            {
                using (var br = new SolidBrush(fill)) g.FillPath(br, p);
                if (!Primary) using (var pen = new Pen(T.Border)) g.DrawPath(pen, p);
            }
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, Primary ? T.OnAccent : T.Fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
}
