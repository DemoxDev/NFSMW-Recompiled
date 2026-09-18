# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).

## [0.0.2] - 2026-09-17

### Añadido

- El lanzador acepta un `.iso` directamente: lo extrae solo la primera vez a
  `game_root_cache\` dentro de la carpeta portable y reutiliza esa copia después. Antes
  solo servía apuntar a una carpeta ya extraída (`--game_data_root` exige un directorio,
  el SDK no sabe montar `.iso`).
- Ventana del lanzador redimensionable y con scroll: la banda de portada se estrecha en
  pantallas pequeñas en vez de forzar scroll horizontal, y los ajustes se centran en
  pantallas anchas en vez de quedarse pegados a un lado con un hueco enorme.
- Ajustes del lanzador en dos columnas en vez de una lista larga.
- Tema oscuro para el lanzador.

### Cambiado

- El lanzador arranca por defecto a 1080p + escala x2 en vez de 720p + x1 en una
  instalación nueva (sin `lanzador.json` todavía) — coincide con lo que `nfsmw.toml` ya
  trae configurado de fábrica, en vez de arrancar más bajo que eso sin que nadie lo pida.
- La portada del lanzador cubre el panel entero ("cover", no "fit"): antes dejaba un
  tramo negro vacío debajo en proporciones de ventana altas.
- El juego se lanza con prioridad de proceso más alta.

### Arreglado

- Ventana del lanzador marcada DPI-aware: en monitores con escala de Windows (125%,
  150%...) salía borrosa por el bitmap-stretch de Windows; ahora nítida.
- "Banner duplicado" al agrandar la ventana del lanzador: faltaba
  `ControlStyles.ResizeRedraw` en el panel de la portada, así que al crecer el control
  solo se invalidaba la franja nueva expuesta y quedaba el recorte antiguo debajo.
- `nfsmw.toml` de la carpeta portable había perdido la sección de resolución
  (`video_mode_width`/`video_mode_height`/`resolution_scale`) al restaurar una copia de
  seguridad anterior; repuesta para que coincida con `app/nfsmw.toml` del repositorio.

## [0.0.1] - 2026-09-10

Primera versión ordenada del proyecto. Todo lo de abajo se hizo antes de que existiera
este repositorio; queda registrado aquí porque es el estado del que parte.

### Añadido

- Recompilación estática completa de NFS Most Wanted (2005, Xbox 360, `454107D9`) que
  arranca, pasa el prólogo y llega a mundo abierto.
- `parche_desatasco.py`: arregla el cuelgue del descodificador XMA que mataba el audio al
  salir del garaje y congelaba el juego al volver al menú.
- `parche_presentador.py`: vsync real y limitador de fps. Ninguno de los dos existía en
  el SDK.
- `parche_backend.py`: selector de API gráfica (D3D12 / Vulkan) desde el menú de F4, con
  respaldo automático si la elegida no está compilada.
- `parche_velocidad.py`: velocidad del juego ajustable en porcentaje, 0–200%.
- `parche_restaurar.py`: mejoras del menú de F4 — aviso de reinicio pendiente con botón
  para reiniciar, botón de restaurar la configuración de arranque, deslizadores con
  límites para los ajustes decimales, y la API gráfica en uso a la vista.
- `parche_gpu_fallback.py`: respaldo a WARP si no se puede crear el dispositivo D3D12.
- `parche_privilegios.py`: ajuste `grant_user_privileges` para pasar la puerta de
  privilegios de Xbox Live. Apagado por defecto.
- Lanzador nativo en C#/WinForms con la portada al lado, compilado con el `csc.exe` que
  ya trae Windows. Comparte los ajustes con el lanzador antiguo de PowerShell.
- Escalado de resolución interna hasta x4 desde el lanzador.

### Cambiado

- En la carpeta portable, `NFS_Most_Wanted.exe` pasa a ser **el lanzador** y el juego se
  llama `nfsmw.exe`, para que el icono del juego abra la ventana de opciones.
- El camino RTV de la EDRAM es el que viene elegido: casi duplica los fps en gráficas
  integradas frente a ROV.
- Los ajustes del lanzador se llaman "Tamaño de la ventana" y "Resolución interna", que
  es lo que hacen. Antes eran "Resolución de salida" y "Escala de renderizado" y se
  confundían.

### Arreglado

- El menú de F4 ya no abre siempre con un aviso falso de "hace falta reiniciar".
- Los parches ya no se duplican al ejecutarlos dos veces.
- `comprobar_dist.ps1` reconoce `mscoree.dll` como DLL del sistema, y ya no da por rota
  una carpeta que lleva el lanzador de .NET dentro.

### Sin resolver

- Vulkan renderiza en negro en Intel.
- Franja horizontal con el camino RTV en algunas integradas.
- Multijugador: faltan 114 de 158 funciones de red del SDK, incluidas las del System
  Link, y los manejadores de sesión son stubs. Ver
  [docs/diario/red-y-privilegios.md](docs/diario/red-y-privilegios.md).
