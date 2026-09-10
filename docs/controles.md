# Controles

## Mando

**No hay que mapear nada.** El backend por defecto es SDL, que trae mapeos
nativos para los mandos habituales. Y las fuentes de entrada se **mezclan**:
`MergeInto` hace un OR de los botones de teclado y mando, así que los dos
funcionan a la vez y activar `--mnk_mode` no desactiva el mando.

### DualShock 4 / DualSense (PlayStation)

Funciona por USB y por Bluetooth. Este SDL está compilado con el driver
`hidapi`, que es el que maneja los mandos de PlayStation.

| Botón de 360 | Botón de PlayStation |
|---|---|
| **Start** | **Options** |
| Back | Share / Create |
| A | **Cruz** |
| B | Círculo |
| X | Cuadrado |
| Y | Triángulo |
| LB / RB | L1 / R1 |
| LT / RT | L2 / R2 |
| Stick izq. / der. | Stick izq. / der. |
| Pulsar sticks | L3 / R3 |
| Cruceta | Cruceta |
| Guide | PS (hay que activarlo con `--guide_button`) |

Para conducir: acelerar **R2**, frenar **L2**, girar con el stick izquierdo.

### Si el mando no responde

`FASE3_RUN.bat` imprime al final una sección **MANDOS DETECTADOS**. Si SDL lo
ha visto, aparece una línea `SDL OnControllerDeviceAdded` con su nombre y GUID.
Si no aparece nada:

1. **Steam abierto**: Steam Input secuestra los mandos de PlayStation y puede
   ocultarlos o presentarlos como un mando de Xbox. Cierra Steam o desactiva
   la compatibilidad con PlayStation en sus ajustes de mando.
2. **DS4Windows / DSX**: mismo problema, hacen de intermediario. Ciérralos.
3. **Bluetooth dormido**: pulsa el botón PS para despertarlo antes de arrancar
   el juego. SDL enumera al iniciar y también en caliente, pero es más fiable
   tenerlo despierto antes.
4. **Mapeo manual**: si SDL lo ve como joystick pero no como gamepad, hace falta
   un `gamecontrollerdb.txt` junto al ejecutable. El log avisa de que no existe
   (`SDL GameControllerDB: file does not exist`), pero es solo un aviso: los
   mapeos internos de SDL3 cubren el DS4. Solo hace falta el archivo para
   mandos raros. Se descarga del proyecto SDL_GameControllerDB y se apunta con
   `--hid_mappings_file`.

Alternativa para mandos de Xbox: `--input_backend xinput`.

## Teclado

**Hay que activarlo explícitamente con `--mnk_mode`.** Viene apagado de fábrica,
y por eso ninguna tecla hace nada aunque las asignaciones ya existan. Los
lanzadores del proyecto ya lo pasan.

| Botón de 360 | Tecla |
|---|---|
| **Start** | **X** o **Enter** |
| Back | Z o Tab |
| A | `;` o Espacio |
| B | `'` o Retroceso |
| X | L |
| Y | P |
| Gatillo izquierdo (LT) | Q o I |
| Gatillo derecho (RT) | E o O |
| Bumper izquierdo (LB) | 1 |
| Bumper derecho (RB) | 3 |
| Stick izquierdo | W A S D |
| Pulsar stick izquierdo | F |
| Stick derecho | Flechas |
| Pulsar stick derecho | K |
| Cruceta | Shift + flechas |
| Guide | sin asignar |

Ojo con la trampa: la tecla **X es Start**, no el botón X. El botón X es la **L**.

### Para conducir

- Acelerar: **E** o **O** (gatillo derecho)
- Frenar: **Q** o **I** (gatillo izquierdo)
- Girar: **A** / **D**
- Freno de mano: `;` o Espacio (botón A)

### Cambiar las asignaciones

Cada botón es un CVar y acepta varias teclas separadas por comas:

```
--keybind_start "Return,Space"
--keybind_right_trigger "Up"
```

`--mnk_mouse` usa el ratón para el stick derecho (la cámara).
`--mnk_sensitivity` ajusta su sensibilidad.
