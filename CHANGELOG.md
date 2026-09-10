# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/).

## [Sin publicar]

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
