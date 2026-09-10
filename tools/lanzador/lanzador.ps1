# =============================================================================
#  NFSMW Recomp - Lanzador
#
#  PowerShell + Windows Forms: los dos vienen con Windows, no hay nada que
#  instalar. Se abre desde LANZADOR.bat.
#
#  Fijo, y por que:
#    --readback_resolve=fast   sin esto la imagen sale lavada y el sol
#                              reventado. Es un arreglo, no una preferencia.
#    --gpu_plugin xenos        es el unico backend construido.
#    --mnk_mode                teclado y raton ademas del mando.
#    --gpu_backend=...         siempre, aunque coincida con el toml. Ver el
#                              grupo "API grafica": es lo que impide quedarse
#                              sin poder jugar tras elegir una API que no va.
#
#
#  LAS DOS RESOLUCIONES, QUE NO SON LA MISMA
#  =========================================
#  Esto costo entenderlo y conviene dejarlo escrito.
#
#  --resolution  (SALIDA)
#    Cambia el modo de video del guest -lo que VdQueryVideoMode le contesta al
#    juego cuando pregunta que resolucion tiene la pantalla- y, de paso, el
#    tamano de la ventana: Window::Create recibe 1280x720 pero solo como
#    peticion, y ResolveWindowWidth/Height la pisan con este preset.
#
#    LO QUE NO HACE: obligar al juego a renderizar mas fino. Most Wanted, como
#    casi todo juego de 360, dibuja en sus propios render targets de tamano
#    fijo y deja que el escalador de la consola estire el resultado hasta el
#    modo de video. Asi que subir esto agranda la imagen, no la mejora.
#
#  --resolution_scale  (RENDERIZADO)
#    Esta si. Multiplica el tamano de los render targets y de la EDRAM
#    emulada, asi que el juego dibuja de verdad el doble o el triple de
#    pixeles. Es la escala de resolucion heredada de Xenia. Su descripcion en
#    el propio SDK: "Draw resolution scale for both X and Y axes".
#
#    Cuesta cara en GPU y crece con el cuadrado: 2x son cuatro veces los
#    pixeles. Si la tarjeta no puede con la escala pedida, el SDK la baja sola
#    y lo deja escrito en el log ("reducing to NxN").
#
#
#  VSYNC Y LIMITE DE FPS: NECESITAN EL PARCHE
#  ==========================================
#  De fabrica ninguno de los dos funciona:
#
#    - "vsync" existe como cvar pero no sincroniza nada. Se lee en un solo
#      sitio del SDK, y solo decide si el procesador de comandos duerme o gira
#      en las esperas del guest. El Present del presentador de D3D12 llevaba
#      el SyncInterval clavado a 0.
#
#    - No habia ningun limitador de fps. Ninguno.
#
#  tools\parche_presentador.py arregla las dos cosas. Si no esta aplicado,
#  esta ventana lo avisa arriba en rojo.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Donde estamos ----------------------------------------------------------
#
# Este script vive en DOS SITIOS y tiene que funcionar en los dos:
#
#   proyecto   NFSMW Recomp\tools\lanzador.ps1
#              El ejecutable esta en app\out\build\win-amd64-release\, los
#              logs y la configuracion cuelgan de la raiz del proyecto, y el
#              fuente del SDK esta al lado, asi que se puede comprobar si el
#              parche del presentador esta puesto.
#
#   carpeta    build\lanzador.ps1  (junto a nfsmw.exe)
#              Aqui no hay proyecto ni SDK: solo el juego. Todo -exe, ISO,
#              logs, ajustes- vive en esta misma carpeta.
#
# Se distingue por lo mas fiable que hay: si el ejecutable esta AL LADO del
# script, estamos en la carpeta repartible.
#
# EL JUEGO SE LLAMA nfsmw.exe. Desde que existe Lanzador.exe, en build\ el
# nombre NFS_Most_Wanted.exe lo lleva EL LANZADOR, para que al hacer doble
# clic en el icono del juego salga la ventana de opciones. Buscar aqui el
# nombre bonito haria que este script se lanzase a si mismo, en bucle.
#
# Se sigue aceptando el nombre viejo detras, para carpetas armadas antes del
# cambio, donde NFS_Most_Wanted.exe todavia es el juego.
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
    # No hay SDK que mirar. Y no hace falta: la carpeta repartible se arma con
    # el target dist, que solo existe en un arbol donde el parche ya esta.
    $FUENTE_PRESENTADOR = $null
} else {
    $RAIZ    = Split-Path -Parent $PSScriptRoot
    $EXE     = Join-Path $RAIZ 'app\out\build\win-amd64-release\nfsmw.exe'
    $LOGDIR  = Join-Path $RAIZ 'logs'
    $AJUSTES = Join-Path $RAIZ 'config\lanzador.json'
    $FUENTE_PRESENTADOR = Join-Path (Split-Path -Parent $RAIZ) 'rexglue-sdk\src\ui\d3d12\d3d12_presenter.cpp'
}
$RUNLOG  = Join-Path $LOGDIR 'lanzador.log'

# Presets que el SDK sabe interpretar, sacados de TryParseResolutionPreset en
# include/rex/graphics/video_mode_util.h. Ademas acepta "ANCHOxALTO".
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
    pantalla = $true     # el SDK arranca en pantalla completa por defecto
    vsync    = $false
    limitar  = $false
    fps      = 60
    # 'auto' = no pasar nada y dejar que mande nfsmw.toml, que trae "rtv".
    # Sin el toml, 'auto' significa que decide el SDK: ROV en Intel, RTV en el
    # resto. Que es justo la decision por marca que queremos poder saltarnos.
    video    = 'auto'
    # La API grafica. AQUI NO HAY 'auto' A PROPOSITO, y es lo que hace que esta
    # ventana sea una salida de emergencia: ver el comentario del grupo.
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
            # Un json corrupto no debe impedir abrir el lanzador.
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
        # Guardar preferencias es un lujo, no una condicion para jugar.
    }
}

# Mira el FUENTE del SDK, no el DLL: es donde vive la verdad y es barato de
# comprobar. Si esta parcheado pero sin recompilar, el aviso de abajo lo dice.
function Parche-Aplicado {
    # En la carpeta repartible no hay fuente que mirar, pero tampoco duda: esa
    # carpeta se arma desde un arbol ya parcheado. Devolver $null ahi solo
    # serviria para ensenarle a quien la recibe un aviso sobre un SDK que no
    # tiene delante.
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
#  Ventana
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

# ---- Pantalla ---------------------------------------------------------------
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

# Salida
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
$numAncho.Minimum  = 640        # limites que aplica el propio SDK
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

# Renderizado
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

# ---- Fotogramas -------------------------------------------------------------
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

# ---- Motor de video ---------------------------------------------------------
#
# La Xbox 360 no tiene render targets normales: tiene 10 MB de memoria embebida
# -la EDRAM- donde el hardware fijo hace la mezcla y el test de profundidad.
# Emular eso se puede de dos formas, y no son equivalentes ni en velocidad ni
# en exactitud. Ver nfsmw.toml, que lo cuenta entero.
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

# ---- API grafica ------------------------------------------------------------
#
# ESTE GRUPO ES UNA SALIDA DE EMERGENCIA, Y POR ESO NO TIENE 'AUTOMATICO'
# =======================================================================
# gpu_backend tambien se puede cambiar desde el menu de F4, dentro del juego.
# El problema es que si eliges una API que en tu equipo da pantalla negra,
# guardas y reinicias, el valor se queda escrito en nfsmw.toml y ya no hay
# forma de volver: para cambiarlo necesitas el menu, y para llegar al menu
# necesitas ver algo. Eso paso, y por eso existe esta ventana.
#
# La regla que lo arregla es del propio SDK: en el orden de prioridad de los
# cvars la linea de comandos manda sobre el archivo de configuracion
# -kDefault < kConfig < kEnvironment < kCommandLine < kRuntime-. Asi que si el
# lanzador pasa SIEMPRE --gpu_backend, lo que haya en el toml da igual: la
# ventana siempre gana.
#
# Por eso aqui no hay opcion 'automatico'. Un automatico que no pase nada
# dejaria mandar otra vez al toml, que es justo el agujero por el que uno se
# queda fuera. En 'Motor de video', que no puede dejar el juego invisible, si
# tiene sentido.
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

# ---- Aviso del parche -------------------------------------------------------
$lblParche           = New-Object System.Windows.Forms.Label
$lblParche.Location  = New-Object System.Drawing.Point(14, 632)
$lblParche.Size      = New-Object System.Drawing.Size(516, 32)
$lblParche.ForeColor = [System.Drawing.Color]::Firebrick
$form.Controls.Add($lblParche)

# ---- Linea de comandos ------------------------------------------------------
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

# ---- Botones ----------------------------------------------------------------
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
#  Logica
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

    # SIEMPRE, incluso cuando coincide con lo que ya dice el toml. Es lo que
    # convierte esta ventana en la salida de emergencia: pasandolo aqui, un
    # gpu_backend malo guardado desde F4 no puede dejar el juego invisible.
    $a.Add('--gpu_backend={0}' -f $(if ($rbApiVk.Checked) { 'vulkan' } else { 'd3d12' }))

    $a.Add('--resolution {0}' -f (Salida-Elegida))

    $esc = Escala-Elegida
    if ($esc -gt 1) { $a.Add('--resolution_scale {0}' -f $esc) }

    if ($rbCompleta.Checked) { $a.Add('--fullscreen=true') } else { $a.Add('--fullscreen=false') }
    if ($chkVsync.Checked)   { $a.Add('--vsync=true') }       else { $a.Add('--vsync=false') }
    if ($chkLimite.Checked)  { $a.Add('--max_fps {0}' -f [int]$numFps.Value) }

    # Solo se pasa si se ha elegido a mano. En automatico no se pone nada, y
    # asi lo que valga en nfsmw.toml sigue mandando: los argumentos de la
    # linea de comandos pisan al archivo de configuracion, no al reves.
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

    # Guardar antes de lanzar: si el juego revienta, las preferencias se quedan.
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

    # Si se pidio escala y la grafica no pudo, el SDK la baja y lo deja escrito.
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

# ---- Estado inicial ---------------------------------------------------------
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
