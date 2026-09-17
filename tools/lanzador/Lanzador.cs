// =============================================================================
//  NFS Most Wanted - Recompilacion : Lanzador
//
//  Ventana nativa de Windows, en C# con WinForms. Sustituye a lanzador.ps1 y
//  hace exactamente lo mismo, con la portada del juego al lado en plan
//  instalador.
//
//  Se compila con CONSTRUIR_LANZADOR.bat, que usa el csc.exe del .NET
//  Framework que YA VIENE con Windows. No hay que instalar Visual Studio, ni
//  el SDK de .NET, ni nada: el compilador esta en
//  C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe desde Windows 8.
//
//  POR QUE C# Y NO OTRA COSA
//  =========================
//  Hacia falta un .exe de verdad, con su icono, y que no dependa de instalar
//  nada. Las opciones eran:
//
//    - C++ con Win32 a pelo: sale un exe pequeno, pero montar a mano una
//      ventana con veinte controles es muchisimo codigo para lo que es.
//    - Python empaquetado: hay que instalar Python y PyInstaller, y el exe
//      acaba pesando 30 MB.
//    - C# con el compilador que ya trae Windows: un solo fichero, los mismos
//      controles que ya usaba el lanzador de PowerShell -WinForms es lo que
//      habia debajo-, icono y portada dentro del exe, y cero instalaciones.
//
//  ESTO SE COMPILA CON UN csc VIEJO
//  ================================
//  El que trae Windows es de C# 5 (2012). Asi que aqui NO se puede usar nada
//  moderno: ni cadenas interpoladas $"...", ni ?., ni nameof, ni miembros con
//  =>. Todo con string.Format y sintaxis clasica. Si algo de eso se cuela, el
//  error que sale no dice "necesitas un compilador mas nuevo", dice cosas
//  raras sobre ';' que faltan, y se pierde media tarde.
//
//  LOS AJUSTES SE COMPARTEN CON EL LANZADOR VIEJO
//  =============================================
//  Se lee y se escribe el MISMO lanzador.json, con los mismos nombres de
//  campo. Asi que la configuracion que ya tuvieras se conserva, y los dos
//  lanzadores conviven sin pisarse.
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
    //  Un json plano, a mano
    //
    //  El fichero de ajustes es una decena de parejas clave/valor sin anidar.
    //  Para eso no hace falta traerse Newtonsoft (que habria que descargar) ni
    //  JavaScriptSerializer (que obliga a referenciar System.Web.Extensions).
    //  Lo unico con lo que hay que tener cuidado es con las barras invertidas de
    //  las rutas de Windows, que en json van dobladas.
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
                // Buscar la comilla que abre una clave.
                while (i < texto.Length && texto[i] != '"')
                    i++;
                if (i >= texto.Length)
                    break;

                string clave = LeerCadena(texto, ref i);

                // Saltar hasta los dos puntos.
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

        // Entra apuntando a la comilla de apertura, sale despues de la de cierre.
        private static string LeerCadena(string texto, ref int i)
        {
            StringBuilder sb = new StringBuilder();
            i++;  // la comilla de apertura
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
                    else sb.Append(c);   // \\ y \/ y \" caen aqui
                }
                else
                {
                    sb.Append(texto[i]);
                }
                i++;
            }
            i++;  // la comilla de cierre
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
    //  El panel de la portada
    //
    //  Se pinta a mano en vez de usar un PictureBox porque hace falta control
    //  sobre COMO encaja la imagen. La portada es 760x1064 -relacion 0,71- y el
    //  panel es mucho mas estrecho y alto que eso.
    //
    //  Si se estirase para llenar el panel, habria que recortar por los lados y
    //  se comeria parte del titulo, que ocupa todo el ancho arriba. Asi que se
    //  mete ENTERA, pegada arriba, y el hueco de abajo se aprovecha para poner
    //  el nombre del proyecto. Que es justo la pinta que tiene la banda lateral
    //  de un instalador.
    // -------------------------------------------------------------------------
    internal sealed class PanelPortada : Panel
    {
        private readonly Image portada;

        public PanelPortada(Image portada)
        {
            this.portada = portada;
            BackColor = Color.Black;
            // Sin esto la imagen parpadea al redimensionar y al arrastrar la
            // ventana por encima de otras.
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

            // Un degradado corto justo debajo de la imagen, para que no se vea el
            // corte seco entre la foto y el negro del panel.
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
        // ---- Presets, sacados de TryParseResolutionPreset del SDK -------------
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

        // Los textos llevan el "x" delante porque es el numero que la gente
        // busca: es el mismo mando que el "resolucion interna x2" de cualquier
        // emulador. Se guardan tal cual en lanzador.json, asi que cambiarlos
        // rompe la compatibilidad con lo guardado; por eso CargarAjustes cae a
        // la primera opcion cuando no reconoce el texto, en vez de fallar.
        private static readonly string[,] Escalas = {
            { "x1  - la original de Xbox 360", "1" },
            { "x2  - 4 veces los pixeles",     "2" },
            { "x3  - 9 veces los pixeles",     "3" },
            { "x4  - 16 veces los pixeles",    "4" },
        };

        // Antialiasing por postproceso (--swap_post_effect). El valor es el que
        // espera el cvar del recomp: none / fxaa / fxaa_extreme. Se aplica al
        // reiniciar el juego, igual que la resolucion.
        private static readonly string[,] Antialias = {
            { "Desactivado",  "none" },
            { "FXAA",         "fxaa" },
            { "FXAA Extreme", "fxaa_extreme" },
        };

        // Filtrado anisotropico (--anisotropic_override). El recomp fuerza el
        // filtrado de texturas aunque el juego no lo pida; 0 lo apaga.
        private static readonly string[,] Anisotropico = {
            { "Desactivado (bilinear)", "0" },
            { "1x",                     "1" },
            { "2x",                     "2" },
            { "4x",                     "3" },
            { "8x",                     "4" },
            { "16x",                    "5" },
        };

        // Efecto al pasar la imagen final a la ventana (--present_effect). Son
        // los que trae el SDK de ReXGlue (FidelityFX); si este runtime no los
        // tuviera, el cvar rechaza el valor y se queda en bilinear, sin romper.
        private static readonly string[,] Efectos = {
            { "Ninguno (bilinear)", "bilinear" },
            { "CAS (nitidez)",      "cas" },
            { "FSR (FidelityFX)",   "fsr" },
        };

        // ---- Donde estamos ----------------------------------------------------
        private string raiz;
        private string exeJuego;
        private string dirLogs;
        private string ficheroAjustes;
        private string fuentePresentador;
        private string logEjecucion;
        private bool distribuida;

        // ---- Controles --------------------------------------------------------
        private TextBox txtIso;
        private ComboBox cboRes, cboEsc, cboAA, cboAniso, cboEfecto, cboMon;
        private NumericUpDown numAncho, numAlto, numFps, numNitidez;
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
        //  Donde esta cada cosa
        //
        //  El exe puede vivir en dos sitios y tiene que funcionar en los dos:
        //
        //    reparto   la carpeta portable, junto a nfsmw.exe. Ahi no hay
        //              proyecto ni SDK: solo el juego, y todo -logs, ajustes,
        //              ISO- cuelga de esa misma carpeta.
        //    proyecto  la raiz de "NFSMW Recomp". El juego esta compilado en
        //              app\out\build\..., y al lado hay SDK que mirar.
        //
        //  EL JUEGO SE LLAMA nfsmw.exe, NO NFS_Most_Wanted.exe
        //  ===================================================
        //  En la carpeta portable, "NFS_Most_Wanted.exe" ES ESTE LANZADOR. El
        //  juego de verdad se llama nfsmw.exe, que ademas es como se llama en el
        //  arbol del proyecto, asi que los dos modos buscan el mismo nombre.
        //
        //  El motivo es solo ese: que al hacer doble clic en el icono del juego
        //  salga esta ventana. Es lo mismo que hace cualquier juego con
        //  lanzador, y el intercambio de nombres es la forma de conseguirlo sin
        //  tocar el codigo del juego.
        //
        //  NO es que el juego no sepa arrancar solo: sabe. nfsmw_app.h le pone
        //  gpu_plugin, mnk_mode y readback_resolve si nadie los pidio, y busca
        //  una ISO en su propia carpeta. Abrir nfsmw.exe a pelo sigue
        //  funcionando, y es una salida util si el lanzador diera problemas.
        //
        //  Un matiz de ese buscador de ISO: prefiere la que se llame IGUAL que
        //  el ejecutable, y si no, coge la primera por orden alfabetico. Al
        //  renombrarlo, una NFS_Most_Wanted.iso deja de ser la preferida y pasa
        //  a entrar por la segunda regla. Con una sola ISO en la carpeta da lo
        //  mismo; con varias, podria coger otra. Da igual cuando se abre desde
        //  aqui, porque esta ventana pasa --game_data_root explicito.
        //
        //  Y no cambia donde guarda sus cosas el juego: el SDK saca esa carpeta
        //  de GetName(), que va en el codigo -"nfsmw"-, no del nombre del
        //  fichero. Ver rex_app.cpp:  user_dir = GetUserFolder() / GetName().
        //  Asi que la cache de shaders sigue donde estaba.
        // ---------------------------------------------------------------------
        private void LocalizarTodo()
        {
            string mio = Path.GetDirectoryName(Application.ExecutablePath);

            // Puede estar en la raiz del proyecto o dentro de tools\; se mira
            // tambien un nivel mas arriba antes de darse por vencido.
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

            // Ni una cosa ni la otra. Se asume proyecto y ya avisara al arrancar
            // de que no encuentra el ejecutable; es mejor abrir la ventana con un
            // aviso que no abrir nada.
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
                // Sin portada la ventana se ve rara, pero se ve. No es motivo
                // para no dejar jugar.
                return null;
            }
        }

        // ---------------------------------------------------------------------
        //  La ventana
        // ---------------------------------------------------------------------
        private const int AnchoBanda = 380;
        private const int AltoUtil = 1030;
        private const int X0 = AnchoBanda + 20;   // margen izquierdo de la columna
        private const int AnchoCol = 580;

        private static string[,] Monitores()
        {
            Screen[] pantallas = Screen.AllScreens;
            string[,] m = new string[pantallas.Length + 1, 2];
            m[0, 0] = "Automatico (predeterminado)";
            m[0, 1] = "0";
            for (int i = 0; i < pantallas.Length; i++)
            {
                m[i + 1, 0] = "Monitor " + (i + 1) + " - " + pantallas[i].Bounds.Width + "x" +
                              pantallas[i].Bounds.Height + " (" + pantallas[i].DeviceName + ")";
                m[i + 1, 1] = (i + 1).ToString(CultureInfo.InvariantCulture);
            }
            return m;
        }

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
                // Da igual: el icono del exe ya lo pone el compilador.
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

            // ---- Pantalla y resolucion ---------------------------------------
            //
            // LOS DOS AJUSTES DE AQUI NO SON EL MISMO, Y SE CONFUNDEN
            // =======================================================
            // Es LA confusion de esta ventana, asi que los nombres van elegidos
            // para que no pase:
            //
            //   "Tamano de la ventana"  -> --resolution. Cambia el modo de
            //       video que el juego cree tener y el tamano de la ventana.
            //       NO le pide al juego que dibuje mas fino: Most Wanted, como
            //       casi todo juego de 360, dibuja en sus propios render
            //       targets de tamano fijo y deja que el escalador estire el
            //       resultado. Subir esto agranda la imagen, no la mejora.
            //
            //   "Resolucion interna"    -> --resolution_scale. ESTE es el que
            //       la gente busca: el mismo "x2" de cualquier emulador.
            //       Multiplica el tamano de los render targets y de la EDRAM
            //       emulada, asi que el juego dibuja de verdad mas pixeles.
            //
            // Se llamaban "Resolucion de salida" y "Escala de renderizado", y
            // con esos nombres es facil tocar el primero esperando lo segundo,
            // ver que no cambia nada y darlo por roto.
            GroupBox gPant = Grupo("Pantalla y resolucion", 96, 252);

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

            // Lo que hace de verdad la escala elegida, escrito en cada cambio.
            // Sin esto, elegir x2 y elegir x1 se ven igual hasta que arrancas.
            lblEscala = new Label();
            lblEscala.Location = new Point(168, 110);
            lblEscala.Size = new Size(AnchoCol - 190, 32);
            gPant.Controls.Add(lblEscala);

            rbCompleta = Radio("Pantalla completa", 14, 146, 150);
            rbVentana = Radio("En ventana", 168, 146, 150);
            gPant.Controls.Add(rbCompleta);
            gPant.Controls.Add(rbVentana);

            gPant.Controls.Add(Etiqueta("Monitor de salida", 14, 180, 150));
            cboMon = new ComboBox();
            cboMon.DropDownStyle = ComboBoxStyle.DropDownList;
            cboMon.Location = new Point(168, 177);
            cboMon.Size = new Size(200, 23);
            string[,] mon = Monitores();
            for (int i = 0; i < mon.GetLength(0); i++)
                cboMon.Items.Add(mon[i, 0]);
            cboMon.SelectedIndexChanged += delegate { Refrescar(); };
            gPant.Controls.Add(cboMon);

            gPant.Controls.Add(Nota(14, 214, AnchoCol - 40, 36,
                "No son lo mismo: el tamano de la ventana solo AGRANDA la imagen. La que la " +
                "hace mas fina es la resolucion interna, que es el mismo \"x2\" de los " +
                "emuladores, y cuesta cara: x2 son cuatro veces los pixeles a dibujar."));

            // ---- Calidad de imagen ---------------------------------------------
            //
            // Todo son cvars del SDK de ReXGlue que el recomp lee por linea de
            // comandos; aqui no se toca el juego ni el runtime.
            GroupBox gCal = Grupo("Calidad de imagen", 352, 196);

            gCal.Controls.Add(Etiqueta("Antialiasing", 14, 26, 150));
            cboAA = new ComboBox();
            cboAA.DropDownStyle = ComboBoxStyle.DropDownList;
            cboAA.Location = new Point(168, 23);
            cboAA.Size = new Size(200, 23);
            for (int i = 0; i < Antialias.GetLength(0); i++)
                cboAA.Items.Add(Antialias[i, 0]);
            cboAA.SelectedIndexChanged += delegate { Refrescar(); };
            gCal.Controls.Add(cboAA);

            gCal.Controls.Add(Etiqueta("Filtrado anisotropico", 14, 58, 150));
            cboAniso = new ComboBox();
            cboAniso.DropDownStyle = ComboBoxStyle.DropDownList;
            cboAniso.Location = new Point(168, 55);
            cboAniso.Size = new Size(200, 23);
            for (int i = 0; i < Anisotropico.GetLength(0); i++)
                cboAniso.Items.Add(Anisotropico[i, 0]);
            cboAniso.SelectedIndexChanged += delegate { Refrescar(); };
            gCal.Controls.Add(cboAniso);

            gCal.Controls.Add(Etiqueta("Efecto de acabado", 14, 90, 150));
            cboEfecto = new ComboBox();
            cboEfecto.DropDownStyle = ComboBoxStyle.DropDownList;
            cboEfecto.Location = new Point(168, 87);
            cboEfecto.Size = new Size(200, 23);
            for (int i = 0; i < Efectos.GetLength(0); i++)
                cboEfecto.Items.Add(Efectos[i, 0]);
            cboEfecto.SelectedIndexChanged += delegate { Refrescar(); };
            gCal.Controls.Add(cboEfecto);

            gCal.Controls.Add(Etiqueta("Nitidez (CAS)", 14, 122, 150));
            numNitidez = Numero(168, 119, 90, 0, 100);
            gCal.Controls.Add(numNitidez);
            gCal.Controls.Add(Etiqueta("%", 264, 122, 20));

            gCal.Controls.Add(Nota(14, 156, AnchoCol - 40, 34,
                "El anisotropico afina las texturas y el acabado remata la imagen al pasarla " +
                "a la ventana. Se aplican al reiniciar el juego."));

            // ---- Fotogramas ---------------------------------------------------
            GroupBox gFps = Grupo("Fotogramas", 556, 124);

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

            // ---- Motor de video ------------------------------------------------
            GroupBox gVideo = Grupo("Motor de video (emulacion de la EDRAM)", 688, 92);

            rbVidAuto = Radio("Automatico", 14, 24, 110);
            rbVidRtv = Radio("Rapido (rtv)", 134, 24, 120);
            rbVidRov = Radio("Exacto (rov)", 264, 24, 120);
            gVideo.Controls.Add(rbVidAuto);
            gVideo.Controls.Add(rbVidRtv);
            gVideo.Controls.Add(rbVidRov);

            gVideo.Controls.Add(Nota(14, 50, AnchoCol - 40, 34,
                "Automatico usa lo que diga nfsmw.toml. Rapido puede duplicar los fps en " +
                "graficas integradas. Exacto se ve bien siempre y va mas lento."));

            // ---- API grafica ----------------------------------------------------
            //
            // ESTE GRUPO ES UNA SALIDA DE EMERGENCIA, Y POR ESO NO TIENE
            // 'AUTOMATICO'. Ver el comentario largo de ConstruirArgumentos.
            GroupBox gApi = Grupo("API grafica", 788, 92);

            rbApiDx = Radio("DirectX 12 (recomendada)", 14, 24, 190);
            rbApiVk = Radio("Vulkan (experimental)", 214, 24, 190);
            gApi.Controls.Add(rbApiDx);
            gApi.Controls.Add(rbApiVk);

            gApi.Controls.Add(Nota(14, 50, AnchoCol - 40, 34,
                "Esta ventana manda sobre nfsmw.toml, asi que elegir mal aqui nunca deja el " +
                "juego sin poder abrirse: vuelves y cambias."));

            // ---- Aviso del parche -------------------------------------------
            lblParche = new Label();
            lblParche.Location = new Point(X0, 888);
            lblParche.Size = new Size(AnchoCol, 32);
            lblParche.ForeColor = Color.Firebrick;
            Controls.Add(lblParche);

            // ---- Lo que se va a ejecutar -------------------------------------
            GroupBox gCmd = Grupo("Lo que se va a ejecutar", 922, 60);
            txtCmd = new TextBox();
            txtCmd.Location = new Point(12, 20);
            txtCmd.Size = new Size(AnchoCol - 32, 32);
            txtCmd.Multiline = true;
            txtCmd.ReadOnly = true;
            txtCmd.ScrollBars = ScrollBars.Vertical;
            txtCmd.BackColor = Color.WhiteSmoke;
            txtCmd.Font = new Font("Consolas", 7.5f);
            gCmd.Controls.Add(txtCmd);

            // ---- Botones ------------------------------------------------------
            btnJugar = new Button();
            btnJugar.Text = "JUGAR";
            btnJugar.Location = new Point(X0 + AnchoCol - 230, 992);
            btnJugar.Size = new Size(120, 30);
            btnJugar.Font = new Font("Segoe UI", 9.75f, FontStyle.Bold);
            btnJugar.Click += Jugar;
            Controls.Add(btnJugar);
            AcceptButton = btnJugar;

            btnSalir = new Button();
            btnSalir.Text = "Salir";
            btnSalir.Location = new Point(X0 + AnchoCol - 100, 992);
            btnSalir.Size = new Size(100, 30);
            btnSalir.Click += delegate { Close(); };
            Controls.Add(btnSalir);

            lblEstado = new Label();
            lblEstado.Location = new Point(X0, 998);
            lblEstado.Size = new Size(320, 32);
            lblEstado.ForeColor = Color.DimGray;
            Controls.Add(lblEstado);

            // Todo lo que cambia la linea de comandos, a refrescarla.
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
            numNitidez.ValueChanged += r;
        }

        // ---- Fabriquitas de controles, para no repetir seis lineas cada vez ----
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
        //  Ajustes: el mismo fichero y los mismos nombres que lanzador.ps1
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
                // Un json roto no puede impedir abrir el lanzador.
            }

            txtIso.Text = Cadena(a, "iso", "");

            int i = IndiceDe(cboRes, Cadena(a, "preset", "720p  - 1280 x 720"));
            cboRes.SelectedIndex = i >= 0 ? i : 2;

            numAncho.Value = Acotar(numAncho, Entero(a, "ancho", 1280));
            numAlto.Value = Acotar(numAlto, Entero(a, "alto", 720));

            int e = IndiceDe(cboEsc, Cadena(a, "escala", "1x  - nativa del juego"));
            cboEsc.SelectedIndex = e >= 0 ? e : 0;

            int mo = IndiceDe(cboMon, Cadena(a, "monitor", "Automatico (predeterminado)"));
            cboMon.SelectedIndex = mo >= 0 ? mo : 0;

            int aa = IndiceDe(cboAA, Cadena(a, "antialiasing", "Desactivado"));
            cboAA.SelectedIndex = aa >= 0 ? aa : 0;

            int an = IndiceDe(cboAniso, Cadena(a, "anisotropico", "8x"));
            cboAniso.SelectedIndex = an >= 0 ? an : 4;

            int ef = IndiceDe(cboEfecto, Cadena(a, "efecto", "Ninguno (bilinear)"));
            cboEfecto.SelectedIndex = ef >= 0 ? ef : 0;

            numNitidez.Value = Acotar(numNitidez, Entero(a, "nitidez", 50));

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
                sb.AppendLine("  \"monitor\":  \"" + Json.Escapar(TextoDe(cboMon)) + "\",");
                sb.AppendLine("  \"pantalla\":  " + (rbCompleta.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"vsync\":  " + (chkVsync.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"limitar\":  " + (chkLimite.Checked ? "true" : "false") + ",");
                sb.AppendLine("  \"fps\":  " + ((int)numFps.Value) + ",");
                sb.AppendLine("  \"antialiasing\":  \"" + Json.Escapar(TextoDe(cboAA)) + "\",");
                sb.AppendLine("  \"anisotropico\":  \"" + Json.Escapar(TextoDe(cboAniso)) + "\",");
                sb.AppendLine("  \"efecto\":  \"" + Json.Escapar(TextoDe(cboEfecto)) + "\",");
                sb.AppendLine("  \"nitidez\":  " + ((int)numNitidez.Value) + ",");
                sb.AppendLine("  \"video\":  \"" + VideoElegido() + "\",");
                sb.AppendLine("  \"api\":  \"" + ApiElegida() + "\"");
                sb.Append("}");
                File.WriteAllText(ficheroAjustes, sb.ToString(), new UTF8Encoding(false));
            }
            catch
            {
                // Guardar preferencias es un lujo, no una condicion para jugar.
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
        //  La linea de comandos
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

        private string AAElegida()
        {
            int i = cboAA.SelectedIndex;
            if (i < 0)
                return "none";
            return Antialias[i, 1];
        }

        private int AnisotropicoElegido()
        {
            int i = cboAniso.SelectedIndex;
            if (i < 0)
                return 4;
            return int.Parse(Anisotropico[i, 1], CultureInfo.InvariantCulture);
        }

        private string EfectoElegido()
        {
            int i = cboEfecto.SelectedIndex;
            if (i < 0)
                return "bilinear";
            return Efectos[i, 1];
        }

        private decimal NitidezElegida()
        {
            return ((decimal)numNitidez.Value) / 100m;
        }

        private int MonitorElegido()
        {
            int i = cboMon.SelectedIndex;
            if (i <= 0 || i > Screen.AllScreens.Length)
                return 0;
            return i;
        }

        private string ConstruirArgumentos()
        {
            List<string> a = new List<string>();
            a.Add("--log_level info");
            a.Add("--log_file \"" + logEjecucion + "\"");
            a.Add("--game_data_root \"" + txtIso.Text + "\"");
            a.Add("--gpu_plugin xenos");
            a.Add("--mnk_mode");

            // Fijo, y no es una preferencia: sin esto la imagen sale lavada y el
            // sol reventado.
            a.Add("--readback_resolve=fast");

            // SIEMPRE, aunque coincida con lo que ya diga nfsmw.toml.
            //
            // En el orden de prioridad de los cvars del SDK la linea de comandos
            // manda sobre el fichero de configuracion:
            //
            //     kDefault < kConfig < kEnvironment < kCommandLine < kRuntime
            //
            // gpu_backend tambien se puede cambiar desde el menu de F4, y ahi
            // esta el peligro: si eliges una API que en tu equipo da pantalla
            // negra, guardas y reinicias, el valor se queda escrito en el toml y
            // ya no hay forma de volver -para cambiarlo necesitas el menu, y
            // para llegar al menu necesitas ver algo-. Paso de verdad.
            //
            // Pasandolo desde aqui siempre, esta ventana gana al toml y eso no
            // puede ocurrir. Por eso tampoco hay opcion "automatico" en el grupo
            // de la API: un automatico que no pasara nada devolveria el mando al
            // toml, que es justo el agujero.
            a.Add("--gpu_backend=" + ApiElegida());

            a.Add("--resolution " + SalidaElegida());

            int esc = EscalaElegida();
            if (esc > 1)
                a.Add("--resolution_scale " + esc);

            // Antialiasing: SIEMPRE se pasa, como la API. Asi elegir
            // "Desactivado" aqui gana a lo que diga nfsmw.toml, en vez de
            // devolverle el mando al fichero.
            a.Add("--swap_post_effect=" + AAElegida());

            // Calidad de imagen: aniso y nitidez siempre (manda esta ventana);
            // el efecto de acabado solo cuando no es el de siempre.
            a.Add("--anisotropic_override " + AnisotropicoElegido());
            if (EfectoElegido() != "bilinear")
                a.Add("--present_effect=" + EfectoElegido());
            a.Add("--present_cas_additional_sharpness " +
                  string.Format(CultureInfo.InvariantCulture, "{0:0.##}", NitidezElegida()));

            a.Add(rbCompleta.Checked ? "--fullscreen=true" : "--fullscreen=false");
            a.Add("--monitor " + MonitorElegido());
            a.Add(chkVsync.Checked ? "--vsync=true" : "--vsync=false");
            if (chkLimite.Checked)
                a.Add("--max_fps " + ((int)numFps.Value));

            // Estos dos solo si se han elegido a mano. En automatico no se pasa
            // nada y manda el toml, que trae "rtv". Al reves que la API: aqui
            // elegir mal no deja el juego invisible, solo mas lento o con una
            // franja rara, asi que dejar mandar al fichero no tiene peligro.
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

            // Que se vea, ANTES de arrancar, que la escala hace algo. Sin esto
            // el unico sitio donde x1 y x2 se distinguen es la linea de
            // comandos de ahi abajo, que casi nadie lee.
            //
            // No se pone la resolucion en pixeles a proposito: la escala NO
            // multiplica el tamano de la ventana, multiplica los render targets
            // del juego, que son de un tamano suyo que desde aqui no se conoce.
            // Poner "2560 x 1440" seria inventarselo.
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
        //  Estado inicial: ISO encontrada sola y aviso del parche
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

            // Se mira el FUENTE del SDK, no la DLL: es donde vive la verdad y es
            // barato de comprobar.
            //
            // En la carpeta repartible no hay fuente que mirar, pero tampoco
            // duda: esa carpeta se arma desde un arbol ya parcheado.
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
        //  Jugar
        //
        //  El juego se espera EN OTRO HILO. El lanzador de PowerShell hacia
        //  WaitForExit en el hilo de la ventana, y mientras jugabas la ventana
        //  se quedaba colgada -Windows la pintaba en blanco y la marcaba como
        //  "no responde"-. Aqui se lanza aparte y se vuelve a la ventana con
        //  Invoke cuando termina.
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

            // Guardar ANTES de lanzar: si el juego revienta, las preferencias se
            // quedan puestas igualmente.
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

        // Volver al hilo de la ventana desde el hilo que espera al juego.
        //
        // Con la comprobacion delante a proposito: si cierras el lanzador
        // mientras juegas, cuando el juego termina ya no hay ventana a la que
        // volver, e Invoke sobre un formulario destruido revienta con una
        // excepcion sin capturar y una ventana de error de .NET. Que el lanzador
        // pete DESPUES de haberlo cerrado tu queda especialmente absurdo.
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
                // Se cerro entre la comprobacion y el Invoke. No hay nada que hacer.
            }
            catch (InvalidOperationException)
            {
                // Idem: el handle se destruyo por el camino.
            }
        }

        private void AlTerminar(int codigo)
        {
            btnJugar.Enabled = true;
            lblEstado.Text = "";

            // Si se pidio escala y la grafica no pudo, el SDK la baja sola y lo
            // deja escrito en el log.
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

        // Devuelve la primera linea que contenga alguna de las agujas, o las
        // ultimas ocho juntas si soloLaPrimera es false. Null si no hay ninguna.
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
