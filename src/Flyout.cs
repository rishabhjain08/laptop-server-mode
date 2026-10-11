// Tray flyout in the Windows 11 style (like the Wi-Fi or OneDrive flyouts):
// a server mode card, a services card, and a footer with battery and actions.
// Everything is drawn here so it stays crisp at any DPI. Tray.ps1 fills in
// the public fields, calls Relayout(), and handles ActionRequested.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LSM
{
    public class FlyoutService
    {
        public string Name, Title, Status;   // Status: running | stopped | failing | needs-setup
        public bool On;
    }

    public class FlyoutActionArgs : EventArgs
    {
        public string Action, Arg;
    }

    public class Flyout : Form
    {
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

        // Model, set by the tray before Relayout().
        public bool ServerOn, OnAC, NoBattery, WatchdogDown;
        public string Reason = "off";          // on | battery | off
        public int Battery = 100;
        public List<FlyoutService> Services = new List<FlyoutService>();

        public event EventHandler<FlyoutActionArgs> ActionRequested;
        public DateTime HiddenAt = DateTime.MinValue;

        class Hit { public RectangleF R; public string Action, Arg, Tip; }
        readonly List<Hit> hits = new List<Hit>();
        readonly ToolTip tip = new ToolTip();
        int hover = -1, focus = -1;
        bool keyboard;

        Theme t;
        Font fTitle, fBody, fSmall, fHead, fIcon;
        RectangleF hero, banner, group, footer;
        float rowH;

        public Flyout(Theme theme)
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            KeyPreview = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            SetTheme(theme);
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x80;          // WS_EX_TOOLWINDOW: not in Alt+Tab
                cp.ClassStyle |= 0x20000;    // CS_DROPSHADOW
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return false; } }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Win.Style(Handle, t);
        }

        public void SetTheme(Theme theme)
        {
            t = theme;
            fTitle = t.Font(11.5f, FontStyle.Bold);
            fBody  = t.Font(10f);
            fSmall = t.Font(9f);
            fHead  = t.Font(10f, FontStyle.Bold);
            fIcon  = new Font(t.IconFont, 12f);
            BackColor = t.Base;
            if (IsHandleCreated) Win.Style(Handle, t);
            Relayout();
        }

        // ------------------------------------------------------------ copy

        string HeroText()
        {
            if (Reason == "on") return "On. The laptop keeps running with the lid closed.";
            if (Reason == "battery") return "Paused at " + Battery + "% battery. Resumes when you plug in.";
            return "Off. Your normal sleep and lid settings apply.";
        }

        Color HeroColor()
        {
            return Reason == "on" ? t.Good : Reason == "battery" ? t.Warn : t.Fg2;
        }

        string StatusText(FlyoutService s, out Color c)
        {
            c = t.Fg2;
            switch (s.Status)
            {
                case "needs-setup": c = t.Warn; return "Needs sign-in";
                case "failing":     c = t.Bad;  return "Not responding, retrying";
                case "running":
                    if (s.On) { c = t.Good; return "Running"; }
                    return "Stopping…";
            }
            if (!s.On) return "Off";
            return ServerOn ? "Starting…" : "Starts with server mode";
        }

        // ------------------------------------------------------------ layout

        float P(float v) { return t.Px(v); }

        public void Relayout()
        {
            hits.Clear();
            float w = P(360), pad = P(12), inner = P(16);

            // Server mode card: status tile, title, description, switch.
            float textX = pad + inner + P(40) + P(14);
            float textW = w - pad - inner - P(40) - P(12) - textX;
            var desc = TextRenderer.MeasureText(HeroText(), fBody, new Size((int)textW, 10000), TextFormatFlags.WordBreak);
            float textH = fTitle.Height + P(2) + desc.Height;
            hero = new RectangleF(pad, pad, w - 2 * pad, Math.Max(P(40), textH) + 2 * inner);
            hits.Add(new Hit { R = hero, Action = "toggle" });
            float y = hero.Bottom;

            banner = RectangleF.Empty;
            if (WatchdogDown)
            {
                banner = new RectangleF(pad, y + P(8), w - 2 * pad, P(48));
                hits.Add(new Hit { R = banner, Action = "watchdog" });
                y = banner.Bottom;
            }

            // Services card: one row per service, divided by hairlines.
            y += P(20) + fHead.Height + P(8);
            rowH = P(60);
            int n = Math.Max(1, Services.Count);
            group = new RectangleF(pad, y, w - 2 * pad, rowH * n);
            for (int i = 0; i < Services.Count; i++)
                hits.Add(new Hit { R = new RectangleF(group.X, group.Y + i * rowH, group.Width, rowH), Action = "service", Arg = Services[i].Name });

            footer = new RectangleF(0, group.Bottom + pad, w, P(52));
            string[,] buttons = {
                { "quit",     "", "Quit tray" },
                { "logs",     "", "Open logs" },
                { "stopall",  "", "Stop all services now" },
                { "screenoff","", "Turn screen off" },
            };
            float bs = P(36), bx = w - P(10) - bs;
            for (int i = 0; i < buttons.GetLength(0); i++, bx -= bs + P(2))
                hits.Add(new Hit { R = new RectangleF(bx, footer.Y + (footer.Height - bs) / 2, bs, bs), Action = buttons[i, 0], Arg = buttons[i, 1], Tip = buttons[i, 2] });

            int bottom = Visible ? Bottom : 0;
            Size = new Size((int)w, (int)Math.Ceiling(footer.Bottom));
            if (Visible) Top = bottom - Height;
            if (focus >= hits.Count) focus = hits.Count - 1;
            Invalidate();
        }

        // Opens above the taskbar, near the pointer, on the pointer's screen.
        public void ShowAt(Point cursor)
        {
            Relayout();
            Rectangle wa = Screen.FromPoint(cursor).WorkingArea;
            Rectangle sb = Screen.FromPoint(cursor).Bounds;
            int m = t.Px(12);
            int x = Math.Max(wa.Left + m, Math.Min(cursor.X - Width / 2, wa.Right - Width - m));
            int y = wa.Top > sb.Top ? wa.Top + m : wa.Bottom - Height - m;   // taskbar on top or bottom
            Location = new Point(x, y);
            hover = -1; focus = -1; keyboard = false;
            Show();
            Activate();
            SetForegroundWindow(Handle);
        }

        public void HideFlyout()
        {
            if (!Visible) return;
            tip.Hide(this);
            Hide();
            HiddenAt = DateTime.Now;
        }

        protected override void OnDeactivate(EventArgs e) { base.OnDeactivate(e); HideFlyout(); }

        // ------------------------------------------------------------ input

        int HitAt(Point p)
        {
            for (int i = 0; i < hits.Count; i++) if (hits[i].R.Contains(p)) return i;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = HitAt(e.Location);
            if (h == hover) return;
            hover = h;
            Cursor = h >= 0 ? Cursors.Hand : Cursors.Default;
            if (h >= 0 && hits[h].Tip != null)
                tip.Show(hits[h].Tip, this, (int)hits[h].R.X, (int)hits[h].R.Y - t.Px(30), 3000);
            else
                tip.Hide(this);
            Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            hover = -1; tip.Hide(this); Invalidate();
        }

        // Fires on release over the target that was pressed, like a button:
        // dragging off it cancels.
        int pressed = -1;

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left) pressed = HitAt(e.Location);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;
            int h = HitAt(e.Location), p = pressed;
            pressed = -1;
            keyboard = false;
            if (h >= 0 && h == p) Fire(hits[h]);
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys key)
        {
            switch (key)
            {
                case Keys.Escape: HideFlyout(); return true;
                case Keys.Tab: case Keys.Down: case Keys.Right: Step(1); return true;
                case Keys.Shift | Keys.Tab: case Keys.Up: case Keys.Left: Step(-1); return true;
                case Keys.Enter: case Keys.Space:
                    if (focus >= 0) Fire(hits[focus]);
                    return true;
            }
            return base.ProcessCmdKey(ref msg, key);
        }

        void Step(int d)
        {
            keyboard = true;
            focus = focus < 0 ? (d > 0 ? 0 : hits.Count - 1) : (focus + d + hits.Count) % hits.Count;
            Invalidate();
        }

        void Fire(Hit h)
        {
            var svc = h.Action == "service" ? Services.Find(s => s.Name == h.Arg) : null;
            // Show the change at once; the watchdog confirms it within seconds.
            if (h.Action == "toggle") ServerOn = !ServerOn;
            if (svc != null) svc.On = !svc.On;
            if (h.Action == "screenoff" || h.Action == "logs" || h.Action == "quit") HideFlyout();
            Invalidate();
            var handler = ActionRequested;
            if (handler != null) handler(this, new FlyoutActionArgs { Action = h.Action, Arg = h.Arg });
        }

        // ------------------------------------------------------------ paint

        protected override void OnPaint(PaintEventArgs e) { Draw(e.Graphics); }

        // Renders the flyout to a PNG without showing it (for screenshots and tests).
        public void SavePreview(string path, int hoverIndex)
        {
            Relayout();
            hover = hoverIndex;
            using (var bmp = new Bitmap(Width, Height, System.Drawing.Imaging.PixelFormat.Format24bppRgb))
            {
                using (var g = Graphics.FromImage(bmp)) Draw(g);
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            hover = -1;
        }

        bool Is(int i, string action) { return i >= 0 && i < hits.Count && hits[i].Action == action; }

        void Draw(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(t.Base);

            // Server mode card.
            Card(g, hero, Is(hover, "toggle") ? t.CardHover : t.Card);
            float inner = P(16);
            var tile = new RectangleF(hero.X + inner, hero.Y + inner, P(40), P(40));
            bool lit = Reason != "off";
            using (var p = Art.Round(tile, P(8)))
            using (var br = new SolidBrush(lit ? HeroColor() : t.Hover))
                g.FillPath(br, p);
            Art.FillGlyph(g, t.IconFont, "", RectangleF.Inflate(tile, -P(10), -P(10)), lit ? t.OnStatus : t.Fg2);

            float tx = tile.Right + P(14), sw = P(40);
            float tw = hero.Right - inner - sw - P(12) - tx;
            TextRenderer.DrawText(g, "Server mode", fTitle, new Point((int)tx, (int)(hero.Y + inner - P(2))), t.Fg, TextFormatFlags.NoPadding);
            var dr = new Rectangle((int)tx, (int)(hero.Y + inner - P(2) + fTitle.Height + P(2)), (int)tw, 10000);
            TextRenderer.DrawText(g, HeroText(), fBody, dr, Reason == "battery" ? t.Warn : t.Fg2, TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            Switch(g, new RectangleF(hero.Right - inner - sw, tile.Y + (tile.Height - P(20)) / 2, sw, P(20)), ServerOn, Is(hover, "toggle"));

            // Watchdog warning.
            if (WatchdogDown)
            {
                Card(g, banner, Theme.Mix(t.Card, t.Warn, Is(hover, "watchdog") ? 0.22f : 0.14f));
                Art.FillGlyph(g, t.IconFont, "", new RectangleF(banner.X + P(14), banner.Y + (banner.Height - P(16)) / 2, P(16), P(16)), t.Warn);
                var br = new Rectangle((int)(banner.X + P(42)), (int)banner.Y, (int)(banner.Width - P(56)), (int)banner.Height);
                TextRenderer.DrawText(g, "Background checks stopped. Click to restart them.", fSmall, br, t.Fg,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
            }

            // Services card.
            TextRenderer.DrawText(g, "Services", fHead, new Point((int)(group.X + P(4)), (int)(group.Y - P(8) - fHead.Height)), t.Fg, TextFormatFlags.NoPadding);
            Card(g, group, t.Card);
            if (Services.Count == 0)
                TextRenderer.DrawText(g, "No services installed", fBody, Rectangle.Round(group), t.Fg2, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
            for (int i = 0; i < Services.Count; i++)
            {
                var s = Services[i];
                var r = new RectangleF(group.X, group.Y + i * rowH, group.Width, rowH);
                bool hot = hover >= 0 && hits[hover].Action == "service" && hits[hover].Arg == s.Name;
                if (hot)
                    using (var clip = Art.Round(RectangleF.Inflate(group, -0.5f, -0.5f), P(6)))
                    {
                        g.SetClip(clip);
                        using (var hb = new SolidBrush(t.CardHover)) g.FillRectangle(hb, r);
                        g.ResetClip();
                    }
                if (i > 0)
                    using (var pen = new Pen(t.CardBorder, Math.Max(1f, t.Scale)))
                        g.DrawLine(pen, r.X + P(1), r.Y, r.Right - P(1), r.Y);

                Color sc;
                string status = StatusText(s, out sc);
                float x = r.X + inner, top = r.Y + (rowH - fBody.Height - P(2) - fSmall.Height) / 2;
                TextRenderer.DrawText(g, s.Title, fBody, new Point((int)x, (int)top), t.Fg, TextFormatFlags.NoPadding);
                float dy = top + fBody.Height + P(2);
                float d = P(7);
                using (var db = new SolidBrush(sc)) g.FillEllipse(db, x, dy + (fSmall.Height - d) / 2, d, d);
                TextRenderer.DrawText(g, status, fSmall, new Point((int)(x + d + P(6)), (int)dy), sc == t.Fg2 ? t.Fg2 : sc, TextFormatFlags.NoPadding);
                Switch(g, new RectangleF(r.Right - inner - sw, r.Y + (rowH - P(20)) / 2, sw, P(20)), s.On, hot);
            }

            // Footer: battery on the left, actions on the right.
            using (var fb = new SolidBrush(t.Footer)) g.FillRectangle(fb, footer);
            using (var pen = new Pen(t.CardBorder, Math.Max(1f, t.Scale))) g.DrawLine(pen, 0, footer.Y, footer.Right, footer.Y);
            string batt = NoBattery ? "" : ((char)((OnAC ? 0xEBA0 : 0xE850) + Math.Min(10, Math.Max(0, (Battery + 5) / 10)))).ToString();
            if (!NoBattery && !OnAC && Battery >= 95) batt = "";
            if (!NoBattery && OnAC && Battery >= 95) batt = "";
            var bi = new RectangleF(P(18), footer.Y + (footer.Height - P(16)) / 2, P(16), P(16));
            Art.FillGlyph(g, t.IconFont, batt, bi, t.Fg);
            string power = NoBattery ? "Plugged in" : Battery + "%, " + (OnAC ? "plugged in" : "on battery");
            TextRenderer.DrawText(g, power, fSmall, new Rectangle((int)(bi.Right + P(10)), (int)footer.Y, (int)P(160), (int)footer.Height), t.Fg2,
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            for (int i = 0; i < hits.Count; i++)
            {
                var h = hits[i];
                if (h.Tip == null) continue;
                if (i == hover)
                    using (var p = Art.Round(h.R, P(4)))
                    using (var hb = new SolidBrush(t.Dark ? Color.FromArgb(18, 255, 255, 255) : Color.FromArgb(14, 0, 0, 0)))
                        g.FillPath(hb, p);
                Art.FillGlyph(g, t.IconFont, h.Arg, RectangleF.Inflate(h.R, -P(10.5f), -P(10.5f)), t.Fg);
            }

            // Keyboard focus ring.
            if (keyboard && focus >= 0)
                using (var p = Art.Round(RectangleF.Inflate(hits[focus].R, -P(1), -P(1)), P(6)))
                using (var pen = new Pen(t.Fg, P(2)))
                    g.DrawPath(pen, p);
        }

        void Card(Graphics g, RectangleF r, Color fill)
        {
            using (var p = Art.Round(new RectangleF(r.X + 0.5f, r.Y + 0.5f, r.Width - 1, r.Height - 1), P(6)))
            {
                using (var br = new SolidBrush(fill)) g.FillPath(br, p);
                using (var pen = new Pen(t.CardBorder, Math.Max(1f, t.Scale))) g.DrawPath(pen, p);
            }
        }

        // Windows 11 toggle switch; the knob grows a little on hover.
        void Switch(Graphics g, RectangleF r, bool on, bool hot)
        {
            float h = r.Height;
            using (var p = Art.Round(r, h / 2))
            {
                if (on) using (var br = new SolidBrush(t.Accent)) g.FillPath(br, p);
                else using (var pen = new Pen(t.Fg2, Math.Max(1f, t.Scale))) g.DrawPath(pen, p);
            }
            float knob = h * (hot ? 0.7f : 0.6f);
            float x = on ? r.Right - h / 2 - knob / 2 : r.X + h / 2 - knob / 2;
            using (var br = new SolidBrush(on ? t.OnAccent : t.Fg2))
                g.FillEllipse(br, x, r.Y + (h - knob) / 2, knob, knob);
        }
    }
}
