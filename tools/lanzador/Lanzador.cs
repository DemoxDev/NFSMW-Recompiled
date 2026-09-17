// =============================================================================
//  NFS Most Wanted - Recompiled: Launcher
//
//  Native Windows window, in C# with WinForms. Replaces lanzador.ps1 and
//  does exactly the same thing, with the game's cover art next to it like
//  an installer.
//
//  It's compiled with CONSTRUIR_LANZADOR.bat, which uses the csc.exe that
//  ALREADY SHIPS with Windows. No need to install Visual Studio, the .NET
//  SDK, or anything else: the compiler is at
//  C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe since Windows 8.
//
//  WHY C# AND NOT SOMETHING ELSE
//  =========================
//  A real .exe was needed, with its own icon, that didn't depend on
//  installing anything. The options were:
//
//    - Plain C++ with Win32: produces a small exe, but hand-building a
//      window with twenty controls is a huge amount of code for what it is.
//    - Packaged Python: you have to install Python and PyInstaller, and the
//      exe ends up weighing 30 MB.
//    - C# with the compiler Windows already ships: a single file, the same
//      controls the PowerShell launcher already used -WinForms is what was
//      underneath-, icon and cover art embedded in the exe, and zero
//      installs.
//
//  THIS IS COMPILED WITH AN OLD csc
//  ================================
//  The one Windows ships is C# 5 (2012). So NOTHING modern can be used
//  here: no interpolated strings $"...", no ?., no nameof, no expression-
//  bodied members (=>). Everything with string.Format and classic syntax.
//  If any of that slips in, the error you get doesn't say "you need a newer
//  compiler", it says weird things about missing ';', and you lose half an
//  afternoon.
//
//  SETTINGS ARE SHARED WITH THE OLD LAUNCHER
//  =============================================
//  The SAME lanzador.json is read and written, with the same field names.
//  So whatever configuration you already had is kept, and the two
//  launchers coexist without stepping on each other.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace NfsmwRecomp
{
    // -------------------------------------------------------------------------
    //  A flat json, by hand
    //
    //  The settings file is about a dozen non-nested key/value pairs. For
    //  that there's no need to bring in Newtonsoft (which would have to be
    //  downloaded) or JavaScriptSerializer (which forces referencing
    //  System.Web.Extensions). The only thing to watch out for is the
    //  backslashes in Windows paths, which are doubled up in json.
    // -------------------------------------------------------------------------
    internal static class Json
    {
        public static Dictionary<string, string> Leer(string texto)
        {
            Dictionary<string, string> d = new Dictionary<string, string>();
            if (texto == null)
                return d;

            int i = 0;
            while (i < texto.Length)
            {
                // Find the quote that opens a key.
                while (i < texto.Length && texto[i] != '"')
                    i++;
                if (i >= texto.Length)
                    break;

                string clave = LeerCadena(texto, ref i);

                // Skip ahead to the colon.
                while (i < texto.Length && texto[i] != ':')
                    i++;
                if (i >= texto.Length)
                    break;
                i++;

                while (i < texto.Length && char.IsWhiteSpace(texto[i]))
                    i++;
                if (i >= texto.Length)
                    break;

                string valor;
                if (texto[i] == '"')
                {
                    valor = LeerCadena(texto, ref i);
                }
                else
                {
                    int desde = i;
                    while (i < texto.Length && texto[i] != ',' && texto[i] != '}' &&
                           texto[i] != '\r' && texto[i] != '\n')
                        i++;
                    valor = texto.Substring(desde, i - desde).Trim();
                }

                if (clave.Length > 0)
                    d[clave] = valor;
            }
            return d;
        }

        // Enters pointing at the opening quote, exits after the closing one.
        private static string LeerCadena(string texto, ref int i)
        {
            StringBuilder sb = new StringBuilder();
            i++;  // the opening quote
            while (i < texto.Length && texto[i] != '"')
            {
                if (texto[i] == '\\' && i + 1 < texto.Length)
                {
                    i++;
                    char c = texto[i];
                    if (c == 'n') sb.Append('\n');
                    else if (c == 'r') sb.Append('\r');
                    else if (c == 't') sb.Append('\t');
                    else if (c == 'u' && i + 4 < texto.Length)
                    {
                        int cod;
                        if (int.TryParse(texto.Substring(i + 1, 4), NumberStyles.HexNumber,
                                         CultureInfo.InvariantCulture, out cod))
                        {
                            sb.Append((char)cod);
                            i += 4;
                        }
                    }
                    else sb.Append(c);   // \\ and \/ and \" fall here
                }
                else
                {
                    sb.Append(texto[i]);
                }
                i++;
            }
            i++;  // the closing quote
            return sb.ToString();
        }

        public static string Escapar(string s)
        {
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
            {
                if (c == '"' || c == '\\') { sb.Append('\\'); sb.Append(c); }
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else if (c < ' ') sb.Append("\\u" + ((int)c).ToString("x4"));
                else sb.Append(c);
            }
            return sb.ToString();
        }
    }

    // -------------------------------------------------------------------------
    //  The cover art panel
    //
    //  It's painted by hand instead of using a PictureBox because control is
    //  needed over HOW the image fits. The cover is 760x1064 -ratio 0.71- and
    //  the panel is much narrower and taller than that.
    //
    //  If it were stretched to fill the panel, it would have to be cropped on
    //  the sides and would eat into part of the title, which spans the full
    //  width at the top. So it's placed WHOLE, pinned to the top, and the gap
    //  at the bottom is used to show the project name. Which is exactly what
    //  the side band of an installer looks like.
    // -------------------------------------------------------------------------
    internal sealed class PanelPortada : Panel
    {
        private readonly Image portada;

        public PanelPortada(Image portada)
        {
            this.portada = portada;
            BackColor = Color.Black;
            // Without this the image flickers when resizing and when dragging
            // the window over other windows.
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(Color.Black);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;

            int alto = 0;
            if (portada != null)
            {
                alto = (int)Math.Round(portada.Height * (double)Width / portada.Width);
                if (alto > Height)
                    alto = Height;
                int ancho = (int)Math.Round(portada.Width * (double)alto / portada.Height);
                g.DrawImage(portada, (Width - ancho) / 2, 0, ancho, alto);
            }

            // A short gradient right below the image, so the hard cut between
            // the photo and the panel's black doesn't show.
            if (alto > 0 && alto < Height)
            {
                int difuminado = Math.Min(40, Height - alto);
                Rectangle r = new Rectangle(0, alto - difuminado, Width, difuminado);
                if (r.Height > 0 && r.Y >= 0)
                {
                    using (LinearGradientBrush b = new LinearGradientBrush(
                               r, Color.FromArgb(0, 0, 0, 0), Color.Black, 90f))
                        g.FillRectangle(b, r);
                }
            }

            using (Font f1 = new Font("Segoe UI", 12f, FontStyle.Bold))
            using (Font f2 = new Font("Segoe UI", 8.25f))
            using (SolidBrush blanco = new SolidBrush(Color.White))
            using (SolidBrush gris = new SolidBrush(Color.FromArgb(150, 150, 150)))
            {
                int y = Math.Max(alto + 18, Height - 96);
                g.DrawString("Recompilacion nativa", f1, blanco, 18, y);
                g.DrawString("Xbox 360 traducida a PC con ReXGlue.\n" +
                             "Necesita tu propia copia del juego.",
                             f2, gris, new RectangleF(18, y + 26, Width - 36, 60));
            }
        }
    }

    internal sealed class Ventana : Form
    {
        // ---- Presets, taken from the SDK's TryParseResolutionPreset -------------
        private static readonly string[,] Presets = {
            { "480p  - 640 x 480",   "480p"   },
            { "540p  - 960 x 540",   "540p"   },
            { "720p  - 1280 x 720",  "720p"   },
            { "900p  - 1600 x 900",  "900p"   },
            { "1080p - 1920 x 1080", "1080p"  },
            { "1440p - 2560 x 1440", "1440p"  },
            { "1800p - 3200 x 1800", "1800p"  },
            { "2160p - 3840 x 2160", "2160p"  },
            { "Personalizada",       "custom" },
        };

        // The texts have the "x" in front because that's the number people
        // look for: it's the same control as the "internal resolution x2" in
        // any emulator. They're saved as-is in lanzador.json, so changing them
        // breaks compatibility with what's already saved; that's why
        // CargarAjustes falls back to the first option when it doesn't
        // recognize the text, instead of failing.
        private static readonly string[,] Escalas = {
            { "x1  - la original de Xbox 360", "1" },
            { "x2  - 4 veces los pixeles",     "2" },
            { "x3  - 9 veces los pixeles",     "3" },
            { "x4  - 16 veces los pixeles",    "4" },
        };

        // ---- Where we are ----------------------------------------------------
        private string raiz;
        private string exeJuego;
        private string dirLogs;
        private string ficheroAjustes;
        private string fuentePresentador;
        private string logEjecucion;
        private bool distribuida;

        // ---- Controls --------------------------------------------------------
        private TextBox txtIso;
        private ComboBox cboRes, cboEsc;
        private NumericUpDown numAncho, numAlto, numFps;
        private RadioButton rbCompleta, rbVentana;
        private CheckBox chkVsync, chkLimite;
        private RadioButton rbVidAuto, rbVidRtv, rbVidRov;
        private RadioButton rbApiDx, rbApiVk;
        private Label lblParche, lblEstado, lblEscala;
        private TextBox txtCmd;
        private Button btnJugar, btnSalir;
        private bool cargando = true;

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Ventana());
        }

        public Ventana()
        {
            LocalizarTodo();
            Construir();
            CargarAjustes();
            cargando = false;
            EstadoInicial();
            Refrescar();
        }

        // ---------------------------------------------------------------------
        //  Where everything is
        //
        //  The exe can live in two places and has to work in both:
        //
        //    reparto   the portable folder, next to nfsmw.exe. There's no
        //              project or SDK there: just the game, and everything
        //              -logs, settings, ISO- hangs off that same folder.
        //    proyecto  the root of "NFSMW Recomp". The game is built at
        //              app\out\build\..., and the SDK sits next to it.
        //
        //  THE GAME IS CALLED nfsmw.exe, NOT NFS_Most_Wanted.exe
        //  =========================================================
        //  In the portable folder, "NFS_Most_Wanted.exe" IS THIS LAUNCHER. The
        //  actual game is called nfsmw.exe, which is also its name in the
        //  project tree, so both modes look for the same name.
        //
        //  The reason is just that: so double-clicking the game's icon opens
        //  this window. It's the same thing any game with a launcher does,
        //  and swapping the names is how to achieve it without touching the
        //  game's code.
        //
        //  It's NOT that the game can't start on its own: it can. nfsmw_app.h
        //  sets gpu_plugin, mnk_mode and readback_resolve for it if nobody
        //  asked for them, and it looks for an ISO in its own folder. Opening
        //  nfsmw.exe directly still works, and it's a useful fallback if the
        //  launcher were to give trouble.
        //
        //  One nuance of that ISO finder: it prefers one named THE SAME as
        //  the executable, and if not, it picks the first one alphabetically.
        //  After renaming it, an NFS_Most_Wanted.iso stops being the
        //  preferred one and falls to the second rule. With only one ISO in
        //  the folder it makes no difference; with several, it might pick a
        //  different one. It doesn't matter when opened from here, because
        //  this window always passes an explicit --game_data_root.
        //
        //  And it doesn't change where the game stores its stuff: the SDK
        //  gets that folder from GetName(), which is set in code -"nfsmw"-,
        //  not from the file name. See rex_app.cpp: user_dir =
        //  GetUserFolder() / GetName(). So the shader cache stays where it was.
        // ---------------------------------------------------------------------
        private void LocalizarTodo()
        {
            string mio = Path.GetDirectoryName(Application.ExecutablePath);

            // It can be at the project root or inside tools\; one level up is
            // also checked before giving up.
            string[] candidatos = { mio, Path.GetFullPath(Path.Combine(mio, "..")) };

            foreach (string c in candidatos)
            {
                if (File.Exists(Path.Combine(c, "nfsmw.exe")))
                {
                    distribuida = true;
                    raiz = c;
                    exeJuego = Path.Combine(c, "nfsmw.exe");
                    dirLogs = Path.Combine(c, "logs");
                    ficheroAjustes = Path.Combine(c, "lanzador.json");
                    fuentePresentador = null;
                    logEjecucion = Path.Combine(dirLogs, "lanzador.log");
                    return;
                }
            }

            foreach (string c in candidatos)
            {
                string j = Path.Combine(c, @"app\out\build\win-amd64-release\nfsmw.exe");
                if (File.Exists(j) || Directory.Exists(Path.Combine(c, "app")))
                {
                    distribuida = false;
                    raiz = c;
                    exeJuego = j;
                    dirLogs = Path.Combine(c, "logs");
                    ficheroAjustes = Path.Combine(c, @"config\lanzador.json");
                    fuentePresentador = Path.Combine(
                        Path.GetFullPath(Path.Combine(c, "..")),
                        @"rexglue-sdk\src\ui\d3d12\d3d12_presenter.cpp");
                    logEjecucion = Path.Combine(dirLogs, "lanzador.log");
                    return;
                }
            }

            // Neither one nor the other. Project mode is assumed, and it will
            // warn on startup that it can't find the executable; it's better
            // to open the window with a warning than to not open anything.
            distribuida = false;
            raiz = mio;
            exeJuego = Path.Combine(mio, @"app\out\build\win-amd64-release\nfsmw.exe");
            dirLogs = Path.Combine(mio, "logs");
            ficheroAjustes = Path.Combine(mio, @"config\lanzador.json");
            fuentePresentador = null;
            logEjecucion = Path.Combine(dirLogs, "lanzador.log");
        }

        private static Image CargarRecurso(string nombre)
        {
            try
            {
                Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(nombre);
                if (s == null)
                    return null;
                using (s)
                    return Image.FromStream(s);
            }
            catch
            {
                // Without cover art the window looks odd, but it still shows.
                // That's no reason to keep someone from playing.
                return null;
            }
        }

        // ---------------------------------------------------------------------
        //  The window
        // ---------------------------------------------------------------------
        private const int AnchoBanda = 380;
        private const int AltoUtil = 792;
        private const int X0 = AnchoBanda + 20;   // left margin of the column
        private const int AnchoCol = 580;

        private void Construir()
        {
            Text = "Need for Speed: Most Wanted - Recompilacion";
            ClientSize = new Size(AnchoBanda + AnchoCol + 40, AltoUtil);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            BackColor = Color.FromArgb(244, 244, 246);
            Font = new Font("Segoe UI", 8.25f);

            try
            {
                Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch
            {
                // Doesn't matter: the compiler already sets the exe's icon.
            }

            PanelPortada banda = new PanelPortada(CargarRecurso("portada.jpg"));
            banda.Location = new Point(0, 0);
            banda.Size = new Size(AnchoBanda, AltoUtil);
            Controls.Add(banda);

            // ---- ISO ----------------------------------------------------------
            GroupBox gIso = Grupo("Imagen del juego", 14, 74);

            txtIso = new TextBox();
            txtIso.Location = new Point(14, 26);
            txtIso.Size = new Size(AnchoCol - 130, 23);
            txtIso.TextChanged += delegate { Refrescar(); };
            gIso.Controls.Add(txtIso);

            Button btnIso = new Button();
            btnIso.Text = "Examinar...";
            btnIso.Location = new Point(AnchoCol - 110, 25);
            btnIso.Size = new Size(94, 25);
            btnIso.Click += ElegirIso;
            gIso.Controls.Add(btnIso);

            // ---- Screen and resolution ---------------------------------------
            //
            // THE TWO SETTINGS HERE ARE NOT THE SAME, AND THEY GET CONFUSED
            // =======================================================
            // This is THE confusing part of this window, so the names were
            // chosen so it doesn't happen:
            //
            //   "Tamano de la ventana"  -> --resolution. Changes the video
            //       mode the game thinks it has and the size of the window.
            //       It does NOT ask the game to draw more finely: Most Wanted,
            //       like almost every 360 game, draws into its own fixed-size
            //       render targets and lets the scaler stretch the result.
            //       Raising this enlarges the image, it doesn't improve it.
            //
            //   "Resolucion interna"    -> --resolution_scale. THIS is the one
            //       people are looking for: the same "x2" from any emulator.
            //       It multiplies the size of the render targets and of the
            //       emulated EDRAM, so the game actually draws more pixels.
            //
            // They used to be called "Resolucion de salida" and "Escala de
            // renderizado", and with those names it's easy to touch the first
            // one expecting the second, see that nothing changes, and assume
            // it's broken.
            GroupBox gPant = Grupo("Pantalla y resolucion", 96, 214);

            gPant.Controls.Add(Etiqueta("Tamano de la ventana", 14, 26, 150));
            cboRes = new ComboBox();
            cboRes.DropDownStyle = ComboBoxStyle.DropDownList;
            cboRes.Location = new Point(168, 23);
            cboRes.Size = new Size(200, 23);
            for (int i = 0; i < Presets.GetLength(0); i++)
                cboRes.Items.Add(Presets[i, 0]);
            cboRes.SelectedIndexChanged += delegate { Refrescar(); };
            gPant.Controls.Add(cboRes);

            numAncho = Numero(168, 52, 70, 320, 7680);
            numAlto = Numero(250, 52, 70, 240, 4320);
            gPant.Controls.Add(Etiqueta("Personalizada", 14, 55, 150));
            gPant.Controls.Add(numAncho);
            gPant.Controls.Add(Etiqueta("x", 240, 55, 12));
            gPant.Controls.Add(numAlto);

            gPant.Controls.Add(Etiqueta("Resolucion interna", 14, 87, 150));
            cboEsc = new ComboBox();
            cboEsc.DropDownStyle = ComboBoxStyle.DropDownList;
            cboEsc.Location = new Point(168, 84);
            cboEsc.Size = new Size(200, 23);
            for (int i = 0; i < Escalas.GetLength(0); i++)
                cboEsc.Items.Add(Escalas[i, 0]);
            cboEsc.SelectedIndexChanged += delegate { Refrescar(); };
            gPant.Controls.Add(cboEsc);

            // What the chosen scale actually does, written out on every change.
            // Without this, picking x2 and picking x1 look the same until you
            // launch.
            lblEscala = new Label();
            lblEscala.Location = new Point(168, 110);
            lblEscala.Size = new Size(AnchoCol - 190, 32);
            gPant.Controls.Add(lblEscala);

            rbCompleta = Radio("Pantalla completa", 14, 146, 150);
            rbVentana = Radio("En ventana", 168, 146, 150);
            gPant.Controls.Add(rbCompleta);
            gPant.Controls.Add(rbVentana);

            gPant.Controls.Add(Nota(14, 172, AnchoCol - 40, 36,
                "No son lo mismo: el tamano de la ventana solo AGRANDA la imagen. La que la " +
                "hace mas fina es la resolucion interna, que es el mismo \"x2\" de los " +
                "emuladores, y cuesta cara: x2 son cuatro veces los pixeles a dibujar."));

            // ---- Frames ---------------------------------------------------
            GroupBox gFps = Grupo("Fotogramas", 318, 124);

            chkVsync = Marca("Sincronizacion vertical (vsync)", 14, 24, 250);
            gFps.Controls.Add(chkVsync);

            chkLimite = Marca("Limitar a", 14, 52, 90);
            gFps.Controls.Add(chkLimite);
            numFps = Numero(108, 50, 70, 20, 300);
            gFps.Controls.Add(numFps);
            gFps.Controls.Add(Etiqueta("fps", 184, 53, 40));

            gFps.Controls.Add(Nota(14, 82, AnchoCol - 40, 34,
                "Los dos necesitan parche_presentador.py. La velocidad del juego no depende " +
                "de esto: se ajusta desde el menu de F4."));

            // ---- Video engine ------------------------------------------------
            GroupBox gVideo = Grupo("Motor de video (emulacion de la EDRAM)", 450, 92);

            rbVidAuto = Radio("Automatico", 14, 24, 110);
            rbVidRtv = Radio("Rapido (rtv)", 134, 24, 120);
            rbVidRov = Radio("Exacto (rov)", 264, 24, 120);
            gVideo.Controls.Add(rbVidAuto);
            gVideo.Controls.Add(rbVidRtv);
            gVideo.Controls.Add(rbVidRov);

            gVideo.Controls.Add(Nota(14, 50, AnchoCol - 40, 34,
                "Automatico usa lo que diga nfsmw.toml. Rapido puede duplicar los fps en " +
                "graficas integradas. Exacto se ve bien siempre y va mas lento."));

            // ---- Graphics API ----------------------------------------------------
            //
            // THIS GROUP IS AN EMERGENCY ESCAPE HATCH, AND THAT'S WHY IT HAS NO
            // 'AUTOMATIC'. See the long comment in ConstruirArgumentos.
            GroupBox gApi = Grupo("API grafica", 550, 92);

            rbApiDx = Radio("DirectX 12 (recomendada)", 14, 24, 190);
            rbApiVk = Radio("Vulkan (experimental)", 214, 24, 190);
            gApi.Controls.Add(rbApiDx);
            gApi.Controls.Add(rbApiVk);

            gApi.Controls.Add(Nota(14, 50, AnchoCol - 40, 34,
                "Esta ventana manda sobre nfsmw.toml, asi que elegir mal aqui nunca deja el " +
                "juego sin poder abrirse: vuelves y cambias."));

            // ---- Patch warning -------------------------------------------
            lblParche = new Label();
            lblParche.Location = new Point(X0, 650);
            lblParche.Size = new Size(AnchoCol, 32);
            lblParche.ForeColor = Color.Firebrick;
            Controls.Add(lblParche);

            // ---- What's going to run -------------------------------------
            GroupBox gCmd = Grupo("Lo que se va a ejecutar", 684, 60);
            txtCmd = new TextBox();
            txtCmd.Location = new Point(12, 20);
            txtCmd.Size = new Size(AnchoCol - 32, 32);
            txtCmd.Multiline = true;
            txtCmd.ReadOnly = true;
            txtCmd.ScrollBars = ScrollBars.Vertical;
            txtCmd.BackColor = Color.WhiteSmoke;
            txtCmd.Font = new Font("Consolas", 7.5f);
            gCmd.Controls.Add(txtCmd);

            // ---- Buttons ------------------------------------------------------
            btnJugar = new Button();
            btnJugar.Text = "JUGAR";
            btnJugar.Location = new Point(X0 + AnchoCol - 230, 754);
            btnJugar.Size = new Size(120, 30);
            btnJugar.Font = new Font("Segoe UI", 9.75f, FontStyle.Bold);
            btnJugar.Click += Jugar;
            Controls.Add(btnJugar);
            AcceptButton = btnJugar;

            btnSalir = new Button();
            btnSalir.Text = "Salir";
            btnSalir.Location = new Point(X0 + AnchoCol - 100, 754);
            btnSalir.Size = new Size(100, 30);
            btnSalir.Click += delegate { Close(); };
            Controls.Add(btnSalir);

            lblEstado = new Label();
            lblEstado.Location = new Point(X0, 760);
            lblEstado.Size = new Size(320, 32);
            lblEstado.ForeColor = Color.DimGray;
            Controls.Add(lblEstado);

            // Anything that changes the command line, hook it up to refresh.
            EventHandler r = delegate { Refrescar(); };
            chkVsync.CheckedChanged += r;
            chkLimite.CheckedChanged += r;
            rbCompleta.CheckedChanged += r;
            rbVidAuto.CheckedChanged += r;
            rbVidRtv.CheckedChanged += r;
            rbVidRov.CheckedChanged += r;
            rbApiDx.CheckedChanged += r;
            rbApiVk.CheckedChanged += r;
            numAncho.ValueChanged += r;
            numAlto.ValueChanged += r;
            numFps.ValueChanged += r;
        }

        // ---- Little control factories, so as not to repeat six lines each time ----
        private GroupBox Grupo(string texto, int y, int alto)
        {
            GroupBox g = new GroupBox();
            g.Text = texto;
            g.Location = new Point(X0, y);
            g.Size = new Size(AnchoCol, alto);
            Controls.Add(g);
            return g;
        }

        private static Label Etiqueta(string texto, int x, int y, int ancho)
        {
            Label l = new Label();
            l.Text = texto;
            l.Location = new Point(x, y);
            l.Size = new Size(ancho, 20);
            return l;
        }

        private static Label Nota(int x, int y, int ancho, int alto, string texto)
        {
            Label l = new Label();
            l.Text = texto;
            l.Location = new Point(x, y);
            l.Size = new Size(ancho, alto);
            l.ForeColor = Color.DimGray;
            return l;
        }

        private static RadioButton Radio(string texto, int x, int y, int ancho)
        {
            RadioButton b = new RadioButton();
            b.Text = texto;
            b.Location = new Point(x, y);
            b.Size = new Size(ancho, 22);
            return b;
        }

        private static CheckBox Marca(string texto, int x, int y, int ancho)
        {
            CheckBox c = new CheckBox();
            c.Text = texto;
            c.Location = new Point(x, y);
            c.Size = new Size(ancho, 22);
            return c;
        }

        private static NumericUpDown Numero(int x, int y, int ancho, int min, int max)
        {
            NumericUpDown n = new NumericUpDown();
            n.Location = new Point(x, y);
            n.Size = new Size(ancho, 23);
            n.Minimum = min;
            n.Maximum = max;
            n.Increment = 1;
            return n;
        }

        // ---------------------------------------------------------------------
        //  Settings: the same file and the same names as lanzador.ps1
        // ---------------------------------------------------------------------
        private void CargarAjustes()
        {
            Dictionary<string, string> a = new Dictionary<string, string>();
            try
            {
                if (File.Exists(ficheroAjustes))
                    a = Json.Leer(File.ReadAllText(ficheroAjustes, Encoding.UTF8));
            }
            catch
            {
                // A broken json can't prevent the launcher from opening.
            }

            txtIso.Text = Cadena(a, "iso", "");

            int i = IndiceDe(cboRes, Cadena(a, "preset", "720p  - 1280 x 720"));
            cboRes.SelectedIndex = i >= 0 ? i : 2;

            numAncho.Value = Acotar(numAncho, Entero(a, "ancho", 1280));
            numAlto.Value = Acotar(numAlto, Entero(a, "alto", 720));

            int e = IndiceDe(cboEsc, Cadena(a, "escala", "1x  - nativa del juego"));
            cboEsc.SelectedIndex = e >= 0 ? e : 0;

            bool completa = Booleano(a, "pantalla", true);
            rbCompleta.Checked = completa;
            rbVentana.Checked = !completa;

            chkVsync.Checked = Booleano(a, "vsync", false);
            chkLimite.Checked = Booleano(a, "limitar", false);
            numFps.Value = Acotar(numFps, Entero(a, "fps", 60));

            string v = Cadena(a, "video", "auto");
            rbVidRtv.Checked = v == "rtv";
            rbVidRov.Checked = v == "rov";
            rbVidAuto.Checked = !(rbVidRtv.Checked || rbVidRov.Checked);

            bool vulkan = Cadena(a, "api", "d3d12") == "vulkan";
            rbApiVk.Checked = vulkan;
            rbApiDx.Checked = !vulkan;
        }

        private void GuardarAjustes()
        {
            try
            {
                string dir = Path.GetDirectoryName(ficheroAjustes);
                if (!Directory.Exists(dir))
                    Directory.CreateDirectory(dir);

                StringBuilder sb = new StringBuilder();
                sb.AppendLine("{");
                sb.AppendLine("  \"iso\":  \"" + Json.Escapar(txtIso.Text) + "\",");
                sb.AppendLine("  \"preset\":  \"" + Json.Escapar(TextoDe(cboRes)) + "\",");
                sb.AppendLine("  \"ancho\":  " + ((int)numAncho.Value) + ",");
                sb.AppendLine("  \"alto\":  " + ((int)numAlto.Value) + ",");
                sb.AppendLine("  \"escala\":  \"" + Json.Escapar(TextoDe(cboEsc)) + "\",");
                sb.AppendLine("  \"pantalla\":  " + (rbCompleta.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"vsync\":  " + (chkVsync.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"limitar\":  " + (chkLimite.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"fps\":  " + ((int)numFps.Value) + ",");
                sb.AppendLine("  \"video\":  \"" + VideoElegido() + "\",");
                sb.AppendLine("  \"api\":  \"" + ApiElegida() + "\"");
                sb.Append("}");
                File.WriteAllText(ficheroAjustes, sb.ToString(), new UTF8Encoding(false));
            }
            catch
            {
                // Saving preferences is a nice-to-have, not a requirement to play.
            }
        }

        private static string Cadena(Dictionary<string, string> a, string k, string porDefecto)
        {
            string v;
            if (a.TryGetValue(k, out v) && v != null && v.Length > 0 && v != "null")
                return v;
            return porDefecto;
        }

        private static int Entero(Dictionary<string, string> a, string k, int porDefecto)
        {
            string v;
            int n;
            if (a.TryGetValue(k, out v) && int.TryParse(v, NumberStyles.Integer,
                                                        CultureInfo.InvariantCulture, out n))
                return n;
            return porDefecto;
        }

        private static bool Booleano(Dictionary<string, string> a, string k, bool porDefecto)
        {
            string v;
            if (a.TryGetValue(k, out v))
            {
                if (v == "true" || v == "True" || v == "1") return true;
                if (v == "false" || v == "False" || v == "0") return false;
            }
            return porDefecto;
        }

        private static decimal Acotar(NumericUpDown n, int v)
        {
            if (v < n.Minimum) return n.Minimum;
            if (v > n.Maximum) return n.Maximum;
            return v;
        }

        private static int IndiceDe(ComboBox c, string texto)
        {
            for (int i = 0; i < c.Items.Count; i++)
                if ((string)c.Items[i] == texto)
                    return i;
            return -1;
        }

        private static string TextoDe(ComboBox c)
        {
            return c.SelectedItem == null ? "" : (string)c.SelectedItem;
        }

        // ---------------------------------------------------------------------
        //  The command line
        // ---------------------------------------------------------------------
        private string SalidaElegida()
        {
            int i = cboRes.SelectedIndex;
            if (i < 0)
                return "720p";
            string v = Presets[i, 1];
            if (v == "custom")
                return string.Format(CultureInfo.InvariantCulture, "{0}x{1}",
                                     (int)numAncho.Value, (int)numAlto.Value);
            return v;
        }

        private int EscalaElegida()
        {
            int i = cboEsc.SelectedIndex;
            if (i < 0)
                return 1;
            return int.Parse(Escalas[i, 1], CultureInfo.InvariantCulture);
        }

        private string VideoElegido()
        {
            if (rbVidRtv.Checked) return "rtv";
            if (rbVidRov.Checked) return "rov";
            return "auto";
        }

        private string ApiElegida()
        {
            return rbApiVk.Checked ? "vulkan" : "d3d12";
        }

        private string ConstruirArgumentos()
        {
            List<string> a = new List<string>();
            a.Add("--log_level info");
            a.Add("--log_file \"" + logEjecucion + "\"");
            a.Add("--game_data_root \"" + txtIso.Text + "\"");
            a.Add("--gpu_plugin xenos");
            a.Add("--mnk_mode");

            // Fixed, and not a preference: without this the image comes out
            // washed out and the sun blown out.
            a.Add("--readback_resolve=fast");

            // ALWAYS, even if it matches what nfsmw.toml already says.
            //
            // In the SDK's cvar priority order, the command line outranks the
            // config file:
            //
            //     kDefault < kConfig < kEnvironment < kCommandLine < kRuntime
            //
            // gpu_backend can also be changed from the F4 menu, and that's
            // where the danger lies: if you pick an API that gives a black
            // screen on your machine, save, and restart, the value stays
            // written in the toml and there's no way back -to change it you
            // need the menu, and to reach the menu you need to see something-.
            // A real dead end.
            //
            // By always passing it from here, this window always wins over the
            // toml, and that can't happen. That's also why there's no
            // "automatic" option in the API group: an "automatic" that passed
            // nothing would hand control back to the toml, which is exactly the
            // hole we're avoiding.
            a.Add("--gpu_backend=" + ApiElegida());

            a.Add("--resolution " + SalidaElegida());

            int esc = EscalaElegida();
            if (esc > 1)
                a.Add("--resolution_scale " + esc);

            a.Add(rbCompleta.Checked ? "--fullscreen=true" : "--fullscreen=false");
            a.Add(chkVsync.Checked ? "--vsync=true" : "--vsync=false");
            if (chkLimite.Checked)
                a.Add("--max_fps " + ((int)numFps.Value));

            // These two only if chosen by hand. In automatic mode nothing is
            // passed and the toml takes over, which defaults to "rtv". Unlike
            // the API: here picking wrong doesn't make the game invisible,
            // just slower or with a weird band, so letting the file take
            // charge is harmless.
            if (rbVidRtv.Checked) a.Add("--render_target_path_d3d12=rtv");
            if (rbVidRov.Checked) a.Add("--render_target_path_d3d12=rov");

            return string.Join(" ", a.ToArray());
        }

        private void Refrescar()
        {
            if (cargando)
                return;

            bool esCustom = cboRes.SelectedIndex >= 0 &&
                            Presets[cboRes.SelectedIndex, 1] == "custom";
            numAncho.Enabled = esCustom;
            numAlto.Enabled = esCustom;
            numFps.Enabled = chkLimite.Checked;

            // Make it visible, BEFORE launching, that the scale does
            // something. Without this the only place x1 and x2 differ is the
            // command line down below, which almost nobody reads.
            //
            // The resolution in pixels is deliberately not shown: the scale
            // does NOT multiply the window size, it multiplies the game's
            // render targets, which have their own size that isn't known from
            // here. Showing "2560 x 1440" would just be making it up.
            int esc = EscalaElegida();
            if (esc <= 1)
            {
                lblEscala.ForeColor = Color.DimGray;
                lblEscala.Text = "El juego dibuja a su resolucion original de Xbox 360.";
            }
            else
            {
                lblEscala.ForeColor = Color.FromArgb(150, 90, 0);
                lblEscala.Text = string.Format(
                    "El juego dibuja {0} veces mas ancho y mas alto: {1} veces los pixeles.\n" +
                    "Se ve mas fino, y la GPU trabaja {1} veces mas.", esc, esc * esc);
            }

            txtCmd.Text = Path.GetFileName(exeJuego) + " " + ConstruirArgumentos();
        }

        // ---------------------------------------------------------------------
        //  Initial state: auto-detected ISO and patch warning
        // ---------------------------------------------------------------------
        private void EstadoInicial()
        {
            if (txtIso.Text.Length == 0)
            {
                try
                {
                    string[] isos = Directory.GetFiles(raiz, "*.iso", SearchOption.TopDirectoryOnly);
                    if (isos.Length > 0)
                        txtIso.Text = isos[0];
                }
                catch
                {
                }
            }

            // The SDK SOURCE is checked, not the DLL: that's where the truth
            // lives and it's cheap to check.
            //
            // In the distributable folder there's no source to check, but
            // there's no doubt either: that folder is built from an
            // already-patched tree.
            bool? parche = null;
            if (distribuida)
            {
                parche = true;
            }
            else if (fuentePresentador != null && File.Exists(fuentePresentador))
            {
                try
                {
                    parche = File.ReadAllText(fuentePresentador)
                                 .Contains("PARCHE LOCAL - vsync real y limitador de fps");
                }
                catch
                {
                }
            }

            if (parche == false)
            {
                lblParche.Text = "AVISO: vsync y el limite de fps NO haran nada todavia. De fabrica " +
                                 "el SDK no sincroniza y no trae limitador. Aplica " +
                                 "tools\\parche_presentador.py y recompila el SDK.";
            }
            else if (parche == null)
            {
                lblParche.ForeColor = Color.DimGray;
                lblParche.Text = "No encuentro el fuente del SDK, asi que no se si el parche de " +
                                 "vsync esta puesto.";
            }

            if (!File.Exists(exeJuego))
            {
                lblEstado.Text = "Aviso: no hay ejecutable compilado todavia.";
                lblEstado.ForeColor = Color.Firebrick;
            }
        }

        private void ElegirIso(object s, EventArgs e)
        {
            using (OpenFileDialog d = new OpenFileDialog())
            {
                d.Filter = "Imagen de disco (*.iso)|*.iso|Todos los archivos (*.*)|*.*";
                d.Title = "Elige la ISO de Need for Speed: Most Wanted";
                try
                {
                    if (txtIso.Text.Length > 0 && File.Exists(txtIso.Text))
                        d.InitialDirectory = Path.GetDirectoryName(txtIso.Text);
                    else
                        d.InitialDirectory = raiz;
                }
                catch
                {
                }
                if (d.ShowDialog(this) == DialogResult.OK)
                {
                    txtIso.Text = d.FileName;
                    Refrescar();
                }
            }
        }

        // ---------------------------------------------------------------------
        //  Play
        //
        //  The game is waited on IN ANOTHER THREAD. The PowerShell launcher
        //  used to call WaitForExit on the window's thread, and while you
        //  played the window would hang -Windows painted it white and marked
        //  it as "not responding"-. Here it's launched separately and control
        //  returns to the window via Invoke when it finishes.
        // ---------------------------------------------------------------------
        private void Jugar(object s, EventArgs e)
        {
            if (!File.Exists(exeJuego))
            {
                MessageBox.Show(this,
                    "No encuentro el ejecutable:\n\n" + exeJuego + "\n\nCompila primero.",
                    "Falta el ejecutable", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            if (txtIso.Text.Length == 0 || !File.Exists(txtIso.Text))
            {
                MessageBox.Show(this, "Elige una ISO que exista.", "Falta la ISO",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Save BEFORE launching: if the game crashes, the preferences are
            // still kept either way.
            GuardarAjustes();

            try
            {
                if (!Directory.Exists(dirLogs))
                    Directory.CreateDirectory(dirLogs);
            }
            catch
            {
            }

            btnJugar.Enabled = false;
            lblEstado.ForeColor = Color.DimGray;
            lblEstado.Text = "Jugando... (F3 para ver los fps)";

            string argumentos = ConstruirArgumentos();
            Thread hilo = new Thread(delegate ()
            {
                int codigo = 0;
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo(exeJuego, argumentos);
                    psi.WorkingDirectory = Path.GetDirectoryName(exeJuego);
                    psi.UseShellExecute = false;
                    using (Process p = Process.Start(psi))
                    {
                        if (p == null)
                            throw new InvalidOperationException(
                                "Windows no ha llegado a crear el proceso.");
                        p.WaitForExit();
                        codigo = p.ExitCode;
                    }
                }
                catch (Exception ex)
                {
                    string mensaje = ex.Message;
                    EnLaVentana(delegate
                    {
                        MessageBox.Show(this, "No se pudo lanzar:\n\n" + mensaje, "Error",
                                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                        btnJugar.Enabled = true;
                        lblEstado.Text = "";
                    });
                    return;
                }

                int cod = codigo;
                EnLaVentana(delegate { AlTerminar(cod); });
            });
            hilo.IsBackground = true;
            hilo.Start();
        }

        // Return to the window's thread from the thread that's waiting on the
        // game.
        //
        // The check up front is deliberate: if you close the launcher while
        // playing, by the time the game exits there's no window left to
        // return to, and calling Invoke on a disposed form blows up with an
        // uncaught exception and a .NET error window. Having the launcher
        // crash AFTER you've already closed it would look especially absurd.
        private void EnLaVentana(MethodInvoker que)
        {
            try
            {
                if (IsDisposed || !IsHandleCreated)
                    return;
                Invoke(que);
            }
            catch (ObjectDisposedException)
            {
                // It closed between the check and the Invoke. Nothing to do about it.
            }
            catch (InvalidOperationException)
            {
                // Same idea: the handle got destroyed along the way.
            }
        }

        private void AlTerminar(int codigo)
        {
            btnJugar.Enabled = true;
            lblEstado.Text = "";

            // If a scale was requested and the GPU couldn't handle it, the SDK
            // lowers it on its own and writes that to the log.
            string bajada = BuscarEnLog(new string[] { "draw resolution scale is not supported" },
                                        true);
            if (bajada != null)
            {
                MessageBox.Show(this,
                    "La escala de renderizado que pediste no la admite tu equipo, asi que el SDK " +
                    "la ha bajado sola:\n\n" + bajada,
                    "Escala reducida", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }

            if (codigo != 0)
            {
                string pistas = BuscarEnLog(new string[] { "[critical]", "FATAL", "unregistered" },
                                            false);
                MessageBox.Show(this,
                    string.Format("El juego termino con codigo {0}.{1}\n\nLog: {2}",
                                  codigo, pistas == null ? "" : "\n\n" + pistas, logEjecucion),
                    "Termino con error", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        // Returns the first line that contains one of the needles, or the
        // last eight together if soloLaPrimera is false. Null if there are none.
        private string BuscarEnLog(string[] agujas, bool soloLaPrimera)
        {
            try
            {
                if (!File.Exists(logEjecucion))
                    return null;

                List<string> encontradas = new List<string>();
                using (StreamReader r = new StreamReader(logEjecucion))
                {
                    string linea;
                    while ((linea = r.ReadLine()) != null)
                    {
                        foreach (string aguja in agujas)
                        {
                            if (linea.IndexOf(aguja, StringComparison.Ordinal) >= 0)
                            {
                                if (soloLaPrimera)
                                    return linea;
                                encontradas.Add(linea);
                                break;
                            }
                        }
                    }
                }

                if (encontradas.Count == 0)
                    return null;
                int desde = Math.Max(0, encontradas.Count - 8);
                return string.Join("\n", encontradas.GetRange(desde, encontradas.Count - desde)
                                                    .ToArray());
            }
            catch
            {
                return null;
            }
        }
    }
}
