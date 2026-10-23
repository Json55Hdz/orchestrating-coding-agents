# orchestrating-coding-agents

> Un plugin de [Claude Code](https://code.claude.com) que permite a Claude **delegar el trabajo pesado** (implementación, ciclos largos de tests, arreglos de revisiones de PR) a un agente de código externo por línea de comandos, [**OpenCode**](https://opencode.ai) o el **CLI de Antigravity (AGY)**, para que el grueso corra con *su* presupuesto de tokens y no con el de Claude. Claude queda como arquitecto y revisor.

English: [README.md](README.md)

**Estado:** `0.2.0`, temprano. Funciona de punta a punta en Windows 11; macOS/Linux es nuevo y probado solo en Linux sin ventana. Licencia MIT.

## Qué incluye

- **Una skill** que enseña a Claude cuándo y cómo delegar: escribir un brief en archivo, preguntarte qué modelo usar, despachar, esperar, revisar el diff y verificar antes de creer un "DONE".
- **Ventanas de visor reales y persistentes**: una pestaña de Windows Terminal por backend, reutilizada en cada despacho. OpenCode muestra su **TUI real** (`opencode attach`); AGY muestra un resumen legible en vivo de sus eventos.
- **Hablarle al agente a mitad de tarea** con `say.ps1`, en ambos backends.
- **Un watchdog**: timeout y detección de "sin salida", mata todo el árbol de procesos y siempre deja un `done.json` (`DONE`/`FAILED`/`STALLED`/`TIMEOUT`).
- **Ayudas para ahorrar tokens**: `peek.ps1` (progreso compacto, sin leer el log JSON crudo) y `review.ps1` (resumen de cambios + el diff **completo** guardado en un archivo para leerlo si hay dudas).
- **Un mod** (`agent-runs-band`): una franja sobre el prompt con las ejecuciones activas y recientes, y un aviso cuando una termina, se estanca o se cierra su ventana.

## Requisitos

- **Windows 10/11**: Windows PowerShell 5.1 (incluido) y Windows Terminal (`wt.exe`). **macOS / Linux**: nada que instalar aparte de lo que trae el sistema (`bash`, `perl`, `curl`, `git`); el visor se abre en Terminal.app (macOS) o en tu emulador de terminal (Linux), o usa `-NoWindow`. El plugin elige la implementación correcta solo (`scripts/run.sh`). Sin Python, paquetes Node ni PowerShell en macOS/Linux.
- Al menos un backend con sesión iniciada:
  - **OpenCode**: `npm i -g opencode-ai` y luego `opencode providers login`
  - **AGY**: instala el CLI de Antigravity y ejecuta `agy` una vez para iniciar sesión (usa `AGY_PATH` si no está en la ruta por defecto ni en el `PATH`)

## Instalación

En una sesión de Claude Code:

```
/plugin install orchestrating-coding-agents --marketplace Json55Hdz/orchestrating-coding-agents
```

Responde `y` para añadir el marketplace y elige el alcance. Luego revisa tu equipo con `scripts\preflight.ps1` (Claude también puede correrlo).

**Un paso manual para AGY sin supervisión.** AGY necesita `--dangerously-skip-permissions`, y Claude Code se niega con razón a darse ese permiso a sí mismo. Añade tú esta regla con `/permissions` (o en `settings.json`):

```
Bash(agy --dangerously-skip-permissions:*)
```

## Uso

Pídele a Claude que delegue: *"Que OpenCode arregle estos 12 tests que fallan y me reporte."* Claude lista los modelos disponibles de ambos backends y **te pregunta cuál usar**, escribe el brief, despacha (se abre o se reutiliza la pestaña del visor), espera `done.json`, corre `review.ps1`, lee el diff completo donde algo no cuadre y ejecuta los tests antes de aceptar.

Para dirigir al agente: `say.ps1 -RunDir <RUN_DIR> -Text "cubre también el caso de cadena vacía" -Wait`.

Más detalle: [docs/SCRIPTS.md](docs/SCRIPTS.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) y [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## OpenCode vs AGY

| | OpenCode | AGY |
|---|---|---|
| Quién hace el trabajo | `opencode serve` compartido (sobrevive si se cierra la ventana) | un proceso `agy --print` de larga vida (stream-json) |
| Pestaña del visor | la **TUI real** de OpenCode | un resumen legible de los eventos de AGY (AGY no tiene servidor/attach) |
| Hablarle | siempre, incluso sesiones terminadas | mientras el worker viva |
| Si cierras la ventana | la tarea sigue | la tarea se detiene; se reanuda con `-Resume` |

## Qué está verificado y qué no

Verificado en vivo en Windows 11: despacho → trabajo → `done.json` en ambos backends, visor reutilizado, mensajes de seguimiento en ambos, watchdog `STALLED` en AGY, `review.ps1` sobre un repo real, y la validación y 3 tests del mod.

**Aún sin probar:** watchdog `TIMEOUT`, `STALLED` en OpenCode, salida por inactividad de AGY, otros sistemas operativos y tareas largas reales (todavía no hay una medición de ahorro de tokens).

## Seguridad

Ambos backends corren con auto-aprobación dentro del directorio objetivo: úsalo en repos de confianza y con el trabajo respaldado. El brief incluye el límite *"sin pushes/merges/deploys"* y la skill le indica a Claude que te consulte antes de publicar nada. Los scripts solo escriben en `%TEMP%\agent-runs\` y en el directorio objetivo; no leen ni envían credenciales.

## Licencia

[MIT](LICENSE) © 2026 Json55Hdz
