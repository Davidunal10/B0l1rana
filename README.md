# B0l1rana

Sistema digital implementado en Verilog HDL sobre una FPGA Intel/Altera Cyclone IV (`EP4CE6E22C8`) para automatizar el conteo de puntos, control de turnos multijugador y visualización en tiempo real de una bolirana electrónica tradicional.

## Características Principales

* **Procesamiento en Hardware:** Monitoreo simultáneo de **4 sensores ópticos infrarrojos** mediante instancias paralelas independientes (`generate`), eliminando la latencia y saturación por interrupciones de las arquitecturas secuenciales tradicionales.
* **Modo Multijugador (1 a 4 Jugadores):** Configuración interactiva de participantes e iniciales personalizadas de 3 letras (`A`–`Z`) almacenadas en registros internos de la FPGA.
* **Meta de Puntaje Configurable:** Selección inmediata mediante 3 interruptores DIP con 8 niveles predefinidos desde 500 hasta 3500 puntos.
* **Acondicionamiento Temporal y Antirrebote:**
  * Sincronizadores de doble etapa en todas las entradas asíncronas para prevenir metaestabilidad.
  * Filtro antirrebote mecánico de $20\text{ ms}$ para los pulsadores de control, para evitar la lectura errónea del rebote mecánico como señal.
  * Bloqueo óptico individual y global (*lockout / cooldown*) de $500\text{ ms}$ tras cada anotación para evitar dobles conteos por rebotes físicos de la esfera.
* **Controlador Maestro I2C en Verilog:** Implementación desde cero del protocolo I2C a $100\text{ kHz}$ con salidas en drenador abierto (Salidas de alta impedancia) para manejar una pantalla LCD 16×2 (PCF8574) en modo de 4 bits.

---

## Hardware y Especificaciones del Prototipo

| Componente | Especificación | Función en el Sistema |
| :--- | :--- | :--- |
| **Tarjeta FPGA** | Cyclone IV `EP4CE6E22C8` ($50\text{ MHz}$) | Núcleo de procesamiento RTL, FSM, temporizadores y controlador I2C. |
| **Sensores Ópticos** | 4× Módulos IR `FC-51` ($3.3\text{ V}$) | Detección sin contacto en ductos: Canal 0 (`40 pts`), Canal 1 (`100 pts`), Canal 2 (`100 pts`), Canal 3 (`150 pts`). |
| **Pantalla Visual** | LCD $16\times 2$ + Expansor I2C `PCF8574` ($5\text{ V}$, dir. `0x27`) | Despliegue de menús, iniciales, turno activo, puntaje acumulado y ganador. |
| **Controles de Usuario** | 2 Pulsadores + 3 DIP Switches + Reset (En la FPGA) | Navegación de estados, selección de caracteres y ajuste de meta (*Active-LOW*). |
| **Estructura Física** | Caja de $60 \times 30 \times 50\text{ cm}$, inclinación $10^\circ$ ($\Delta h = 8.8\text{ cm}$) | Plataforma de rodamiento con tubos guía de $4\text{ cm}$ para aislamiento óptico. |

---

## Arquitectura Digital RTL (`proyecto_final_uno`)

El diseño responde a una arquitectura híbrida síncrona dividida en bloques secuenciales (gobernados por `clk_50mhz` y `rst_n`) y bloques combinacionales (`always @(*)`):

```text
[btn_next] ──────► [button_debouncer] ───┐
[btn_change] ────► [button_debouncer] ───┼──► [multi_player_game_fsm] ──► [lcd_formatter] ──► [i2c_lcd_16x2_controller] ──► (SCL/SDA)
[ir_sensors[3:0]]► [ir_sensor_lockout x4]┘              ▲                        ▲
[sw_limit[2:0]] ─► [limit_selector] ────────────────────┴────────────────────────┘
```

### Descripción de Módulos

1. **`button_debouncer` (Secuencial):** Sincroniza los pulsadores mecánicos (`btn_next`, `btn_change`), valida estabilidad durante $1\,000\,000$ de ciclos ($20\text{ ms}$) y emite un pulso limpio de $20\text{ ns}$ (1 ciclo de reloj) en el flanco de bajada.
2. **`ir_sensor_lockout` (Secuencial — 4 instancias paralelas):** Acondiciona las señales de los 4 sensores FC-51 e impone una ventana de bloqueo de $25\,000\,000$ de ciclos ($500\text{ ms}$) por canal tras detectar una esfera.
3. **`limit_selector` (Combinacional):** Invierte la polaridad *Active-LOW* de `sw_limit[2:0]` y decodifica en paralelo el puntaje meta numérico (`target_score[15:0]`) y su representación textual (`target_ascii[31:0]`).
4. **`multi_player_game_fsm` (Secuencial / Mixta):** Máquina de estados finitos de 5 fases con evaluación de prioridad excluyente (`if ... else if`) y enfriamiento global (`global_cooldown` de $500\text{ ms}$):
   * `0 - STATE_SETUP_PLAYERS`: Selección de $1$ a $4$ jugadores.
   * `1 - STATE_SETUP_LIMIT`: Confirmación visual de la meta configurada en los DIP switches.
   * `2 - STATE_SETUP_NAME`: Ingreso de 3 iniciales ASCII (`A`–`Z`) por cada participante.
   * `3 - STATE_GAME_PLAY`: Partida activa, acumulación de puntajes por sensor, cambio de turno manual (`btn_next`) y verificación continua de victoria (`scores[current_player] >= target_score`).
   * `4 - STATE_GAME_WIN`: Pantalla de celebración con el jugador ganador y reinicio de partida.
5. **`lcd_formatter` (Combinacional):** Convierte el puntaje activo de binario a dígitos BCD/ASCII en paralelo y multiplexa las dos líneas de $16\text{ caracteres}$ (`line1_text[127:0]` y `line2_text[127:0]`).
6. **`i2c_lcd_16x2_controller` (Secuencial y *Open-Drain*):** Divide el reloj maestro de $50\text{ MHz}$ entre $500$ para generar la frecuencia estándar I2C de **$100\text{ kHz}$**, inicializa el controlador HD44780 en modo de 4 bits y refresca continuamente los $32\text{ caracteres}$ de la pantalla.

---

## Puertos del Módulo Top-Level e Interfaz Eléctrica

| Puerto | Dirección | Ancho | Estándar / Polaridad | Descripción |
| :--- | :---: | :---: | :--- | :--- |
| `clk_50mhz` | `input` | 1 bit | `3.3-V LVTTL` | Reloj maestro de cristal de $50\text{ MHz}$ de la tarjeta. |
| `rst_n` | `input` | 1 bit | `Active-LOW` (Pull-up) | Reinicio asíncrono maestro del sistema. |
| `btn_change` | `input` | 1 bit | `Active-LOW` (Pull-up) | Incrementa cantidad de jugadores o avanza letra (`A`–`Z`). |
| `btn_next` | `input` | 1 bit | `Active-LOW` (Pull-up) | Confirma selección o cede el turno al siguiente jugador. |
| `sw_limit` | `input` | 3 bits | `Active-LOW` (Pull-up) | Selector binario de puntaje objetivo ($500$ a $3500\text{ pts}$). |
| `ir_sensors` | `input` | 4 bits | `Active-LOW` ($3.3\text{ V}$) | Entradas digitales de los 4 sensores ópticos FC-51. |
| `i2c_scl` | `inout` | 1 bit | `Open-Drain` ($100\text{ kHz}$) | Línea de reloj serial hacia el expansor PCF8574 (`0x27`). |
| `i2c_sda` | `inout` | 1 bit | `Open-Drain` ($100\text{ kHz}$) | Línea de datos bidireccional hacia el expansor PCF8574. |

> **Nota sobre compatibilidad eléctrica ($3.3\text{ V}$ vs. $5\text{ V}$):**
> * Los 4 sensores IR FC-51 se alimentan a $3.3\text{ V}$ desde la FPGA para garantizar niveles lógicos seguros en los pines de entrada.
> * La LCD 16×2 se alimenta a $5\text{ V}$ para asegurar el brillo de la luz de fondo, mientras que la FPGA controla `i2c_scl` e `i2c_sda` en alta impedancia (`1'bz` para nivel alto y `1'b0` para nivel bajo) evitando sobrevoltajes.
> * Todos los periféricos comparten un nodo común de tierra (`GND`).

---

## Potencia del sistema

La potencia total estimada que consume el sistema, según el programa Quartus Prime es de $61.26mW$, siendo esto bastante seguro para cualquier circuito eléctrico uy electrónico.

---

## Autores

* **Miguel Ángel Meza Sosa**
* **David Ricardo Benavides Castañeda**
* **Duvan Antonio Martinez Pajajoy**

**Universidad Nacional de Colombia — Sede Bogotá**  
*Departamento de Ingeniería Eléctrica y Electrónica — Electrónica Digital I*






