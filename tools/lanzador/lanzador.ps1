# =============================================================================
#  NFSMW Recomp - Launcher
#
#  PowerShell + Windows Forms: both come with Windows, nothing to install.
#  Opened from LANZADOR.bat.
#
#  Fixed, and why:
#    --readback_resolve=fast   without this the image comes out washed out
#                              and the sun blown out. It's a fix, not a
#                              preference.
#    --gpu_plugin xenos        it's the only backend that's built.
#    --mnk_mode                keyboard and mouse in addition to the gamepad.
#    --gpu_backend=...         always, even if it matches the toml. See the
#                              "Graphics API" group: it's what keeps you from
#                              losing the ability to play after picking an
#                              API that doesn't work.
#
#
#  THE TWO RESOLUTIONS, WHICH ARE NOT THE SAME
#  =============================================
#  This took effort to understand and is worth writing down.
#
#  --resolution  (OUTPUT)
#    Changes the guest's video mode -what VdQueryVideoMode answers the game
#    when it asks what resolution the screen has- and, incidentally, the
#    window size: Window::Create receives 1280x720 but only as a request,
#    and ResolveWindowWidth/Height override it with this preset.
#
#    WHAT IT DOESN'T DO: force the game to render at finer detail. Most
#    Wanted, like almost every 360 game, draws into its own fixed-size
#    render targets and lets the console's scaler stretch the result up to
#    the video mode. So raising this makes the image bigger, not better.
#
#  --resolution_scale  (RENDERING)
#    This one does. It multiplies the size of the render targets and of the
#    emulated EDRAM, so the game actually draws double or triple the
#    pixels. It's the resolution scale inherited from Xenia. Its own
#    description in the SDK: "Draw resolution scale for both X and Y axes".
#
#    It's expensive on the GPU and grows with the square: 2x is four times
#    the pixels. If the card can't handle the requested scale, the SDK
#    lowers it on its own and writes it to the log ("reducing to NxN").
#
#
#  VSYNC AND FPS LIMIT: NEED THE PATCH
#  ======================================
#  Out of the box neither of the two works:
#
#    - "vsync" exists as a cvar but doesn't sync anything. It's read in a
#      single spot in the SDK, and only decides whether the command
#      processor sleeps or spins during guest waits. The D3D12 presenter's
#      Present had SyncInterval hardcoded to 0.
#
#    - There was no fps limiter at all. None.
#
#  tools\parche_presentador.py fixes both things. If it isn't applied, this
#  window warns about it in red at the top.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Where we are -----------------------------------------------------------
#
# This script lives in TWO PLACES and has to work in both:
#
#   project    NFSMW Recomp\tools\lanzador.ps1
#              The executable is at app\out\build\win-amd64-release\, the
#              logs and the settings hang off the project root, and the SDK
#              source sits right next to it, so it's possible to check
#              whether the presenter patch is applied.
#
#   folder     build\lanzador.ps1  (next to nfsmw.exe)
#              Here there's no project or SDK: just the game. Everything
#              -exe, ISO, logs, settings- lives in this same folder.
#
# It's told apart by the most reliable thing there is: if the executable is
# RIGHT NEXT TO the script, we're in the distributable folder.
#
# THE GAME IS CALLED nfsmw.exe. Since Lanzador.exe exists, in build\ the name
# NFS_Most_Wanted.exe is carried by THE LAUNCHER, so that double-clicking the
# game's icon brings up the options window. Looking here for the pretty name
# would make this script launch itself, in a loop.
#
# The old name is still accepted as a fallback, for folders that were put
# together before the change, where NFS_Most_Wanted.exe is still the game.
$JUEGO = $null
foreach ($n in @('nfsmw.exe', 'NFS_Most_Wanted.exe')) {
    $c = Join-Path $PSScriptRoot $n
    if (Test-Path -LiteralPath $c) { $JUEGO = $c; break }
}
$DISTRIBUIDA = [bool]$JUEGO

if ($DISTRIBUIDA) {
    $RAIZ    = $PSScriptRoot
    $EXE     = $JUEGO
    $LOGDIR  = Join-Path $PSScriptRoot 'logs'
    $AJUSTES = Join-Path $PSScriptRoot 'lanzador.json'
    # No SDK to check. And there's no need to: the distributable folder is
    # built from the dist target, which only exists in a tree where the
    # patch is already applied.
    $FUENTE_PRESENTADOR = $null
} else {
    $RAIZ    = Split-Path -Parent $PSScriptRoot
    $EXE     = Join-Path $RAIZ 'app\out\build\win-amd64-release\nfsmw.exe'
    $LOGDIR  = Join-Path $RAIZ 'logs'
    $AJUSTES = Join-Path $RAIZ 'config\lanzador.json'
    $FUENTE_PRESENTADOR = Join-Path (Split-Path -Parent $RAIZ) 'rexglue-sdk\src\ui\d3d12\d3d12_presenter.cpp'
}
$RUNLOG  = Join-Path $LOGDIR 'lanzador.log'

# Presets the SDK knows how to parse, taken from TryParseResolutionPreset in
# include/rex/graphics/video_mode_util.h. It also accepts "WIDTHxHEIGHT".
$PRESETS = [ordered]@{
    '480p  - 640 x 480'    = '480p'
    '540p  - 960 x 540'    = '540p'
    '720p  - 1280 x 720'   = '720p'
    '900p  - 1600 x 900'   = '900p'
    '1080p - 1920 x 1080'  = '1080p'
    '1440p - 2560 x 1440'  = '1440p'
    '1800p - 3200 x 1800'  = '1800p'
    '2160p - 3840 x 2160'  = '2160p'
    'Personalizada'        = 'custom'
}

$ESCALAS = [ordered]@{
    '1x  - nativa del juego'       = 1
    '2x  - 4 veces los pixeles'    = 2
    '3x  - 9 veces los pixeles'    = 3
}

$defectos = @{
    iso      = ''
    preset   = '720p  - 1280 x 720'
    ancho    = 1280
    alto     = 720
    escala   = '1x  - nativa del juego'
    pantalla = $true     # the SDK starts in fullscreen by default
    vsync    = $false
    limitar  = $false
    fps      = 60
    # 'auto' = don't pass anything and let nfsmw.toml take charge, which
    # ships with "rtv". Without the toml, 'auto' means the SDK decides: ROV
    # on Intel, RTV everywhere else. Which is exactly the per-vendor
    # decision we want to be able to bypass.
    video    = 'auto'
    # The graphics API. THERE IS NO 'auto' HERE ON PURPOSE, and that's what
    # makes this window an emergency exit: see the group's comment.
    api      = 'd3d12'
}

function Cargar-Ajustes {
    $a = $defectos.Clone()
    if (Test-Path -LiteralPath $AJUSTES) {
        try {
            $j = Get-Content -LiteralPath $AJUSTES -Raw | ConvertFrom-Json
            foreach ($k in @($a.Keys)) {
                if ($j.PSObject.Properties.Name -contains $k) { $a[$k] = $j.$k }
            }
        } catch {
            # A corrupt json shouldn't prevent the launcher from opening.
        }
    }
    return $a
}

function Guardar-Ajustes($a) {
    try {
        $dir = Split-Path -Parent $AJUSTES
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $a | ConvertTo-Json | Set-Content -LiteralPath $AJUSTES -Encoding UTF8
    } catch {
        # Saving preferences is a nice-to-have, not a condition for playing.
    }
}

# Checks the SDK SOURCE, not the DLL: that's where the truth lives and it's
# cheap to check. If it's patched but not recompiled, the warning below says so.
function Parche-Aplicado {
    # In the distributable folder there's no source to check, but there's no
    # doubt either: that folder is built from a tree that's already patched.
    # Returning $null there would only show whoever receives it a warning
    # about an SDK they don't have in front of them.
    if ($DISTRIBUIDA) { return $true }
    if (-not $FUENTE_PRESENTADOR) { return $null }
    if (-not (Test-Path -LiteralPath $FUENTE_PRESENTADOR)) { return $null }
    try {
        return [bool](Select-String -LiteralPath $FUENTE_PRESENTADOR -SimpleMatch `
                        -Pattern 'PARCHE LOCAL - vsync real y limitador de fps' -Quiet)
    } catch {
        return $null
    }
}

$cfg = Cargar-Ajustes

# =============================================================================
#  Window
# =============================================================================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'NFS Most Wanted - Recompilacion'
$form.Size            = New-Object System.Drawing.Size(560, 888)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false

function Nuevo-Grupo($texto, $y, $alto) {
    $g          = New-Object System.Windows.Forms.GroupBox
    $g.Text     = $texto
    $g.Location = New-Object System.Drawing.Point(12, $y)
    $g.Size     = New-Object System.Drawing.Size(520, $alto)
    $form.Controls.Add($g)
    return $g
}

function Nueva-Nota($padre, $x, $y, $ancho, $alto, $texto) {
    $l           = New-Object System.Windows.Forms.Label
    $l.Location  = New-Object System.Drawing.Point($x, $y)
    $l.Size      = New-Object System.Drawing.Size($ancho, $alto)
    $l.ForeColor = [System.Drawing.Color]::DimGray
    $l.Text      = $texto
    $padre.Controls.Add($l)
    return $l
}

# ---- ISO --------------------------------------------------------------------
$gIso = Nuevo-Grupo 'Imagen del juego' 8 78

$txtIso          = New-Object System.Windows.Forms.TextBox
$txtIso.Location = New-Object System.Drawing.Point(12, 24)
$txtIso.Size     = New-Object System.Drawing.Size(390, 22)
$txtIso.Text     = [string]$cfg.iso
$gIso.Controls.Add($txtIso)

$btnIso          = New-Object System.Windows.Forms.Button
$btnIso.Text     = 'Examinar...'
$btnIso.Location = New-Object System.Drawing.Point(410, 23)
$btnIso.Size     = New-Object System.Drawing.Size(96, 24)
$gIso.Controls.Add($btnIso)

[void](Nueva-Nota $gIso 12 52 494 18 `
    'Se lee al vuelo: no se copia nada a disco, asi que tiene que seguir ahi.')

# ---- Screen -----------------------------------------------------------------
$gPant = Nuevo-Grupo 'Pantalla y resolucion' 92 210

$rbVentana          = New-Object System.Windows.Forms.RadioButton
$rbVentana.Text     = 'En ventana'
$rbVentana.Location = New-Object System.Drawing.Point(14, 22)
$rbVentana.Size     = New-Object System.Drawing.Size(120, 22)
$gPant.Controls.Add($rbVentana)

$rbCompleta          = New-Object System.Windows.Forms.RadioButton
$rbCompleta.Text     = 'Pantalla completa'
$rbCompleta.Location = New-Object System.Drawing.Point(150, 22)
$rbCompleta.Size     = New-Object System.Drawing.Size(160, 22)
$gPant.Controls.Add($rbCompleta)

if ([bool]$cfg.pantalla) { $rbCompleta.Checked = $true } else { $rbVentana.Checked = $true }

# Output
$lblSalida          = New-Object System.Windows.Forms.Label
$lblSalida.Text     = 'Salida'
$lblSalida.Location = New-Object System.Drawing.Point(14, 54)
$lblSalida.Size     = New-Object System.Drawing.Size(80, 20)
$gPant.Controls.Add($lblSalida)

$cboRes               = New-Object System.Windows.Forms.ComboBox
$cboRes.Location      = New-Object System.Drawing.Point(100, 51)
$cboRes.Size          = New-Object System.Drawing.Size(220, 22)
$cboRes.DropDownStyle = 'DropDownList'
foreach ($k in $PRESETS.Keys) { [void]$cboRes.Items.Add($k) }
$gPant.Controls.Add($cboRes)

$numAncho          = New-Object System.Windows.Forms.NumericUpDown
$numAncho.Location = New-Object System.Drawing.Point(330, 51)
$numAncho.Size     = New-Object System.Drawing.Size(70, 22)
$numAncho.Minimum  = 640        # limits enforced by the SDK itself
$numAncho.Maximum  = 4095
$numAncho.Value    = [int]$cfg.ancho
$gPant.Controls.Add($numAncho)

$lblPor          = New-Object System.Windows.Forms.Label
$lblPor.Text     = 'x'
$lblPor.Location = New-Object System.Drawing.Point(406, 54)
$lblPor.Size     = New-Object System.Drawing.Size(12, 20)
$gPant.Controls.Add($lblPor)

$numAlto          = New-Object System.Windows.Forms.NumericUpDown
$numAlto.Location = New-Object System.Drawing.Point(422, 51)
$numAlto.Size     = New-Object System.Drawing.Size(70, 22)
$numAlto.Minimum  = 480
$numAlto.Maximum  = 4095
$numAlto.Value    = [int]$cfg.alto
$gPant.Controls.Add($numAlto)

[void](Nueva-Nota $gPant 100 76 400 32 `
    ("Tamano de la ventana y de la imagen final. NO hace que el juego dibuje " +
     "mas fino: solo estira lo que ya dibuja."))

# Rendering
$lblEsc          = New-Object System.Windows.Forms.Label
$lblEsc.Text     = 'Renderizado'
$lblEsc.Location = New-Object System.Drawing.Point(14, 116)
$lblEsc.Size     = New-Object System.Drawing.Size(80, 20)
$gPant.Controls.Add($lblEsc)

$cboEsc               = New-Object System.Windows.Forms.ComboBox
$cboEsc.Location      = New-Object System.Drawing.Point(100, 113)
$cboEsc.Size          = New-Object System.Drawing.Size(220, 22)
$cboEsc.DropDownStyle = 'DropDownList'
foreach ($k in $ESCALAS.Keys) { [void]$cboEsc.Items.Add($k) }
$gPant.Controls.Add($cboEsc)

[void](Nueva-Nota $gPant 100 138 400 60 `
    ("ESTA es la resolucion interna de verdad: multiplica los render targets y " +
     "la EDRAM emulada. Cuesta cara y crece al cuadrado (2x son cuatro veces " +
     "los pixeles). Si la grafica no puede, el SDK la baja sola y lo apunta " +
     "en el log."))

# ---- Frames -----------------------------------------------------------------
$gFps = Nuevo-Grupo 'Fotogramas' 310 130

$chkVsync          = New-Object System.Windows.Forms.CheckBox
$chkVsync.Text     = 'Vsync (sincronizar con la pantalla)'
$chkVsync.Location = New-Object System.Drawing.Point(14, 22)
$chkVsync.Size     = New-Object System.Drawing.Size(300, 22)
$chkVsync.Checked  = [bool]$cfg.vsync
$gFps.Controls.Add($chkVsync)

[void](Nueva-Nota $gFps 32 44 474 18 `
    'Quitalo para medir fps de verdad: con vsync todo marca lo que el monitor.')

$chkLimite          = New-Object System.Windows.Forms.CheckBox
$chkLimite.Text     = 'Limitar a'
$chkLimite.Location = New-Object System.Drawing.Point(14, 68)
$chkLimite.Size     = New-Object System.Drawing.Size(80, 22)
$chkLimite.Checked  = [bool]$cfg.limitar
$gFps.Controls.Add($chkLimite)

$numFps          = New-Object System.Windows.Forms.NumericUpDown
$numFps.Location = New-Object System.Drawing.Point(100, 67)
$numFps.Size     = New-Object System.Drawing.Size(60, 22)
$numFps.Minimum  = 10
$numFps.Maximum  = 1000
$numFps.Value    = [int]$cfg.fps
$gFps.Controls.Add($numFps)

$lblFps          = New-Object System.Windows.Forms.Label
$lblFps.Text     = 'fps'
$lblFps.Location = New-Object System.Drawing.Point(166, 70)
$lblFps.Size     = New-Object System.Drawing.Size(30, 20)
$gFps.Controls.Add($lblFps)

[void](Nueva-Nota $gFps 32 92 474 30 `
    ("Limitador de verdad, dentro del presentador: duerme hasta que toca el " +
     "siguiente fotograma. Util para que la GPU no vaya a tope sin motivo."))

# ---- Video engine -----------------------------------------------------------
#
# The Xbox 360 doesn't have normal render targets: it has 10 MB of embedded
# memory -the EDRAM- where the fixed-function hardware does blending and
# depth testing. Emulating that can be done in two ways, and they're not
# equivalent in either speed or accuracy. See nfsmw.toml, which explains it
# in full.
$gVideo = Nuevo-Grupo 'Motor de video (emulacion de la EDRAM)' 444 88

$rbVidAuto          = New-Object System.Windows.Forms.RadioButton
$rbVidAuto.Text     = 'Automatico'
$rbVidAuto.Location = New-Object System.Drawing.Point(14, 22)
$rbVidAuto.Size     = New-Object System.Drawing.Size(110, 22)
$gVideo.Controls.Add($rbVidAuto)

$rbVidRtv          = New-Object System.Windows.Forms.RadioButton
$rbVidRtv.Text     = 'Rapido (rtv)'
$rbVidRtv.Location = New-Object System.Drawing.Point(134, 22)
$rbVidRtv.Size     = New-Object System.Drawing.Size(120, 22)
$gVideo.Controls.Add($rbVidRtv)

$rbVidRov          = New-Object System.Windows.Forms.RadioButton
$rbVidRov.Text     = 'Exacto (rov)'
$rbVidRov.Location = New-Object System.Drawing.Point(264, 22)
$rbVidRov.Size     = New-Object System.Drawing.Size(120, 22)
$gVideo.Controls.Add($rbVidRov)

switch ([string]$cfg.video) {
    'rtv'   { $rbVidRtv.Checked  = $true }
    'rov'   { $rbVidRov.Checked  = $true }
    default { $rbVidAuto.Checked = $true }
}

[void](Nueva-Nota $gVideo 14 46 494 34 `
    ("Automatico usa lo que diga nfsmw.toml. Rapido puede duplicar los fps en " +
     "graficas integradas, pero en algunas deja una franja horizontal rara. " +
     "Exacto se ve bien siempre y va bastante mas lento."))

# ---- Graphics API -----------------------------------------------------------
#
# THIS GROUP IS AN EMERGENCY EXIT, AND THAT'S WHY IT HAS NO 'AUTOMATIC'
# =====================================================================
# gpu_backend can also be changed from the F4 menu, inside the game. The
# problem is that if you pick an API that gives you a black screen on your
# machine, save, and restart, the value stays written in nfsmw.toml and
# there's no way back: to change it you need the menu, and to reach the menu
# you need to see something. That happened, and that's why this window
# exists.
#
# The rule that fixes it comes from the SDK itself: in the cvar priority
# order the command line outranks the config file
# -kDefault < kConfig < kEnvironment < kCommandLine < kRuntime-. So if the
# launcher ALWAYS passes --gpu_backend, whatever is in the toml doesn't
# matter: the window always wins.
#
# That's why there's no 'automatic' option here. An automatic that passes
# nothing would let the toml take charge again, which is exactly the hole
# people fall through. In 'Video engine', which can't leave the game
# invisible, it does make sense.
$gApi = Nuevo-Grupo 'API grafica' 540 86

$rbApiDx          = New-Object System.Windows.Forms.RadioButton
$rbApiDx.Text     = 'DirectX 12 (recomendada)'
$rbApiDx.Location = New-Object System.Drawing.Point(14, 22)
$rbApiDx.Size     = New-Object System.Drawing.Size(200, 22)
$gApi.Controls.Add($rbApiDx)

$rbApiVk          = New-Object System.Windows.Forms.RadioButton
$rbApiVk.Text     = 'Vulkan (experimental)'
$rbApiVk.Location = New-Object System.Drawing.Point(234, 22)
$rbApiVk.Size     = New-Object System.Drawing.Size(200, 22)
$gApi.Controls.Add($rbApiVk)

if ([string]$cfg.api -eq 'vulkan') { $rbApiVk.Checked = $true } else { $rbApiDx.Checked = $true }

[void](Nueva-Nota $gApi 14 46 494 34 `
    ("DirectX 12 es la que se ha probado. Vulkan esta compilado pero en " +
     "graficas Intel puede salir en negro; si pasa, vuelve aqui y marca " +
     "DirectX 12, que esta ventana manda sobre nfsmw.toml."))

# ---- Patch warning ----------------------------------------------------------
$lblParche           = New-Object System.Windows.Forms.Label
$lblParche.Location  = New-Object System.Drawing.Point(14, 632)
$lblParche.Size      = New-Object System.Drawing.Size(516, 32)
$lblParche.ForeColor = [System.Drawing.Color]::Firebrick
$form.Controls.Add($lblParche)

# ---- Command line -----------------------------------------------------------
$gCmd = Nuevo-Grupo 'Lo que se va a ejecutar' 668 86

$txtCmd            = New-Object System.Windows.Forms.TextBox
$txtCmd.Location   = New-Object System.Drawing.Point(12, 20)
$txtCmd.Size       = New-Object System.Drawing.Size(494, 56)
$txtCmd.Multiline  = $true
$txtCmd.ReadOnly   = $true
$txtCmd.ScrollBars = 'Vertical'
$txtCmd.BackColor  = [System.Drawing.Color]::WhiteSmoke
$txtCmd.Font       = New-Object System.Drawing.Font('Consolas', 8)
$gCmd.Controls.Add($txtCmd)

# ---- Buttons ----------------------------------------------------------------
$btnJugar          = New-Object System.Windows.Forms.Button
$btnJugar.Text     = 'JUGAR'
$btnJugar.Location = New-Object System.Drawing.Point(300, 766)
$btnJugar.Size     = New-Object System.Drawing.Size(120, 34)
$btnJugar.Font     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnJugar)

$btnSalir          = New-Object System.Windows.Forms.Button
$btnSalir.Text     = 'Salir'
$btnSalir.Location = New-Object System.Drawing.Point(430, 766)
$btnSalir.Size     = New-Object System.Drawing.Size(100, 34)
$form.Controls.Add($btnSalir)

$lblEstado           = New-Object System.Windows.Forms.Label
$lblEstado.Location  = New-Object System.Drawing.Point(14, 772)
$lblEstado.Size      = New-Object System.Drawing.Size(280, 40)
$lblEstado.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblEstado)

# =============================================================================
#  Logic
# =============================================================================

function Salida-Elegida {
    $clave = [string]$cboRes.SelectedItem
    if (-not $clave) { return '720p' }
    $v = $PRESETS[$clave]
    if ($v -eq 'custom') { return ('{0}x{1}' -f [int]$numAncho.Value, [int]$numAlto.Value) }
    return $v
}

function Escala-Elegida {
    $clave = [string]$cboEsc.SelectedItem
    if (-not $clave) { return 1 }
    return [int]$ESCALAS[$clave]
}

function Construir-Argumentos {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('--log_level info')
    $a.Add('--log_file "{0}"' -f $RUNLOG)
    $a.Add('--game_data_root "{0}"' -f $txtIso.Text)
    $a.Add('--gpu_plugin xenos')
    $a.Add('--mnk_mode')
    $a.Add('--readback_resolve=fast')

    # ALWAYS, even when it matches what the toml already says. This is what
    # turns this window into the emergency exit: by passing it here, a bad
    # gpu_backend saved from F4 can't leave the game invisible.
    $a.Add('--gpu_backend={0}' -f $(if ($rbApiVk.Checked) { 'vulkan' } else { 'd3d12' }))

    $a.Add('--resolution {0}' -f (Salida-Elegida))

    $esc = Escala-Elegida
    if ($esc -gt 1) { $a.Add('--resolution_scale {0}' -f $esc) }

    if ($rbCompleta.Checked) { $a.Add('--fullscreen=true') } else { $a.Add('--fullscreen=false') }
    if ($chkVsync.Checked)   { $a.Add('--vsync=true') }       else { $a.Add('--vsync=false') }
    if ($chkLimite.Checked)  { $a.Add('--max_fps {0}' -f [int]$numFps.Value) }

    # Only passed if it's been chosen by hand. In automatic nothing is set,
    # so whatever nfsmw.toml has keeps ruling: command-line arguments
    # override the config file, not the other way around.
    if ($rbVidRtv.Checked) { $a.Add('--render_target_path_d3d12=rtv') }
    if ($rbVidRov.Checked) { $a.Add('--render_target_path_d3d12=rov') }

    return ($a -join ' ')
}

function Refrescar {
    $esCustom = ([string]$cboRes.SelectedItem -and $PRESETS[[string]$cboRes.SelectedItem] -eq 'custom')
    $numAncho.Enabled = $esCustom
    $numAlto.Enabled  = $esCustom
    $numFps.Enabled   = $chkLimite.Checked
    $txtCmd.Text      = (Split-Path -Leaf $EXE) + ' ' + (Construir-Argumentos)
}

$rbVidAuto.Add_CheckedChanged({ Refrescar })
$rbVidRtv.Add_CheckedChanged({ Refrescar })
$rbVidRov.Add_CheckedChanged({ Refrescar })
$rbApiDx.Add_CheckedChanged({ Refrescar })
$rbApiVk.Add_CheckedChanged({ Refrescar })

$btnIso.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Imagen de disco (*.iso)|*.iso|Todos los archivos (*.*)|*.*'
    $dlg.Title  = 'Elige la ISO de Need for Speed: Most Wanted'
    if ($txtIso.Text -and (Test-Path -LiteralPath $txtIso.Text)) {
        $dlg.InitialDirectory = Split-Path -Parent $txtIso.Text
    } else {
        $dlg.InitialDirectory = $RAIZ
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtIso.Text = $dlg.FileName
        Refrescar
    }
})

$cboRes.Add_SelectedIndexChanged({ Refrescar })
$cboEsc.Add_SelectedIndexChanged({ Refrescar })
$chkLimite.Add_CheckedChanged({ Refrescar })
$chkVsync.Add_CheckedChanged({ Refrescar })
$rbCompleta.Add_CheckedChanged({ Refrescar })
$numAncho.Add_ValueChanged({ Refrescar })
$numAlto.Add_ValueChanged({ Refrescar })
$numFps.Add_ValueChanged({ Refrescar })
$txtIso.Add_TextChanged({ Refrescar })

$btnSalir.Add_Click({ $form.Close() })

$btnJugar.Add_Click({
    if (-not (Test-Path -LiteralPath $EXE)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("No encuentro el ejecutable:`n`n{0}`n`nCompila primero." -f $EXE),
            'Falta el ejecutable', 'OK', 'Warning')
        return
    }
    if (-not $txtIso.Text -or -not (Test-Path -LiteralPath $txtIso.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            'Elige una ISO que exista.', 'Falta la ISO', 'OK', 'Warning')
        return
    }

    # Save before launching: if the game crashes, the preferences still stick.
    Guardar-Ajustes @{
        iso      = $txtIso.Text
        preset   = [string]$cboRes.SelectedItem
        ancho    = [int]$numAncho.Value
        alto     = [int]$numAlto.Value
        escala   = [string]$cboEsc.SelectedItem
        pantalla = [bool]$rbCompleta.Checked
        vsync    = [bool]$chkVsync.Checked
        limitar  = [bool]$chkLimite.Checked
        fps      = [int]$numFps.Value
        video    = $(if ($rbVidRtv.Checked) { 'rtv' } elseif ($rbVidRov.Checked) { 'rov' } else { 'auto' })
        api      = $(if ($rbApiVk.Checked) { 'vulkan' } else { 'd3d12' })
    }

    if (-not (Test-Path -LiteralPath $LOGDIR)) {
        New-Item -ItemType Directory -Path $LOGDIR -Force | Out-Null
    }

    $btnJugar.Enabled = $false
    $lblEstado.Text   = 'Jugando... (F3 para ver los fps)'
    $form.Refresh()

    try {
        $p = Start-Process -FilePath $EXE -ArgumentList (Construir-Argumentos) `
                           -WorkingDirectory (Split-Path -Parent $EXE) -PassThru
        $p.WaitForExit()
        $codigo = $p.ExitCode
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("No se pudo lanzar:`n`n{0}" -f $_.Exception.Message), 'Error', 'OK', 'Error')
        $btnJugar.Enabled = $true
        $lblEstado.Text   = ''
        return
    }

    $btnJugar.Enabled = $true
    $lblEstado.Text   = ''

    # If a scale was requested and the GPU couldn't do it, the SDK lowers it and writes it down.
    if (Test-Path -LiteralPath $RUNLOG) {
        $bajada = Select-String -LiteralPath $RUNLOG -SimpleMatch `
                    -Pattern 'draw resolution scale is not supported' |
                  Select-Object -First 1
        if ($bajada) {
            [void][System.Windows.Forms.MessageBox]::Show(
                ("La escala de renderizado que pediste no la admite tu equipo, " +
                 "asi que el SDK la ha bajado sola:`n`n{0}" -f $bajada.Line),
                'Escala reducida', 'OK', 'Information')
        }
    }

    if ($codigo -ne 0) {
        $pistas = ''
        if (Test-Path -LiteralPath $RUNLOG) {
            $m = Select-String -LiteralPath $RUNLOG -SimpleMatch `
                    -Pattern '[critical]', 'FATAL', 'unregistered' |
                 Select-Object -Last 8 | ForEach-Object { $_.Line }
            if ($m) { $pistas = "`n`n" + ($m -join "`n") }
        }
        [void][System.Windows.Forms.MessageBox]::Show(
            ("El juego termino con codigo {0}.{1}`n`nLog: {2}" -f $codigo, $pistas, $RUNLOG),
            'Termino con error', 'OK', 'Warning')
    }
})

# ---- Initial state ----------------------------------------------------------
$idx = $cboRes.Items.IndexOf([string]$cfg.preset)
if ($idx -lt 0) { $idx = $cboRes.Items.IndexOf('720p  - 1280 x 720') }
if ($idx -lt 0) { $idx = 0 }
$cboRes.SelectedIndex = $idx

$idxE = $cboEsc.Items.IndexOf([string]$cfg.escala)
if ($idxE -lt 0) { $idxE = 0 }
$cboEsc.SelectedIndex = $idxE

if (-not $txtIso.Text) {
    $encontrada = Get-ChildItem -LiteralPath $RAIZ -Filter '*.iso' -File -ErrorAction SilentlyContinue |
                  Select-Object -First 1
    if ($encontrada) { $txtIso.Text = $encontrada.FullName }
}

$parche = Parche-Aplicado
if ($parche -eq $false) {
    $lblParche.Text = ("AVISO: vsync y el limite de fps NO haran nada todavia. De fabrica el SDK " +
                       "no sincroniza (Present con SyncInterval 0) y no trae limitador. " +
                       "Aplica tools\parche_presentador.py y recompila el SDK.")
} elseif ($parche -eq $true) {
    $lblParche.Text = ''
} else {
    $lblParche.ForeColor = [System.Drawing.Color]::DimGray
    $lblParche.Text = 'No encuentro el fuente del SDK, asi que no se si el parche de vsync esta puesto.'
}

if (-not (Test-Path -LiteralPath $EXE)) {
    $lblEstado.Text      = 'Aviso: no hay ejecutable compilado todavia.'
    $lblEstado.ForeColor = [System.Drawing.Color]::Firebrick
}

Refrescar
[void]$form.ShowDialog()
