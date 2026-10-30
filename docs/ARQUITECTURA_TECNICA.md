# Arquitectura Técnica — Calendario Pisos

Documento de referencia de ingeniería sobre el diseño modular, el modelo de seguridad, el motor de reconciliación iCalendar (RFC 5545) y la estrategia de persistencia **Offline-First** del proyecto.

---

## 1. Principios de Diseño

1. **Seguridad por Diseño (*Zero Hardcoded Secrets*)**:
   * Ninguna URL de proyecto ni clave de API reside en el código fuente versionado.
   * `AppConfig` (`lib/core/config/app_config.dart`) resuelve `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY` en tiempo de compilación mediante `--dart-define-from-file=env.json`.
   * En ausencia de credenciales (entornos de evaluación técnica o CI), la aplicación degrada de forma limpia a un modo autónomo respaldado por almacenamiento local sin errores de arranque.
2. **Aislamiento Multitenant en Base de Datos**:
   * La tabla `public.pisos` aplica **Row Level Security (RLS)** estricto (`auth.uid() = user_id`) para `SELECT`, `INSERT`, `UPDATE` y `DELETE`.
   * La eliminación de cuenta cumple los requisitos de privacidad mediante la función `public.delete_user()` (`SECURITY DEFINER`), purgando atómicamente inmuebles y credenciales en `auth.users`.
3. **Arquitectura Offline-First**:
   * Lectura inmediata desde caché local (`SharedPreferences`) ante cortes de conectividad.
   * Cola de mutaciones diferidas (`pending_sync_pisos` y `pending_orden_pisos`) que sincroniza altas, ediciones y reordenaciones pendientes en cuanto vuelve la red, actualizando transparentemente los identificadores temporales `local_*` por UUIDs definitivos de PostgreSQL.

---

## 2. Motor de Reconciliación iCal (`ServicioICal`)

### 2.1 Pipeline de Ingesta RFC 5545
1. **Normalización de Transporte**: Conversión de esquemas `webcal://` / `webcals://` a `https://` y envío de cabeceras explícitas (`Accept: text/calendar`, `Cache-Control: no-cache`).
2. **Decodificación UTF-8 Resiliente**: Decodificación prioritaria sobre `response.bodyBytes` en UTF-8 (según RFC 5545 §3.1.4) con *fallback* a `latin1`, evitando corrupción de caracteres diacríticos cuando servidores externos omiten `charset=utf-8` en `Content-Type`.
3. **Line Unfolding**: Reconstrucción previa de líneas plegadas (`\r\n ` o `\r\n\t`) para preservar URLs de reserva y códigos de confirmación partidos a los 75 octetos.

### 2.2 Matriz de Prioridad Estricta

| Estado Existente en App | Evento Entrante OTA | Resolución Automática |
| :--- | :--- | :--- |
| Día libre | `reservaReal` o `bloqueoExterno` | Se registra directamente con su canal e identificadores (`UID` y `codigoReserva`). |
| `reservaReal` (Airbnb / Booking / Manual) | `bloqueoExterno` (canal opuesto) | **Sin conflicto**: la reserva real mantiene el control y activa `sincronizadoEnCanalOpuesto = true` junto al canal bloqueado. |
| `bloqueoExterno` | `reservaReal` (canal opuesto) | **Sin conflicto**: la reserva real toma posesión del día y hereda el bloqueo previo como confirmación cruzada. |
| `reservaReal` (mismo canal, mismo `codigoReserva` o `UID`) | Actualización en web (ampliación, recorte o cambio de fechas) | Se reconcilia el rango futuro preservando intacto el `nombrePersonalizado` asignado por el anfitrión. |
| `reservaReal` (mismo canal) | Cancelada en web y sustituida por **otra** `reservaReal` con distinto código/`UID` | Se detecta cambio de identidad de estancia y se restablece el marcador `"Reservado #CÓDIGO"` para avisar de un nuevo huésped. |
| `reservaReal` (Canal A) | `reservaReal` (Canal B distinto) | **Conflicto crítico real (*Overbooking*)**: se notifica en `ResultadoSincronizacion.conflictos` para resolución guiada día a día. |

---

## 3. Exportación Bidireccional Anti-Bucle (`export-ical`)

La Edge Function `supabase/functions/export-ical/index.ts` genera calendarios `.ics` dinámicos a partir del estado consolidado de PostgreSQL:

* **Compactación de Eventos (*Event Merging*)**: Ordena cronológicamente los días ocupados y funde noches contiguas que comparten canal, nombre e identificador en un único `VEVENT` (`DTSTART;VALUE=DATE:YYYYMMDD` inclusivo y `DTEND;VALUE=DATE:YYYYMMDD` exclusivo).
* **Prevención de Bucles (*Target Filtering*)**:
  * `target=airbnb`: Excluye días con `origen == 'airbnb'`, exportando únicamente estancias de Booking y reservas manuales.
  * `target=booking`: Excluye días con `origen == 'booking'`, exportando únicamente estancias de Airbnb y reservas manuales.
  * Sin `target`: Exporta la totalidad de reservas reales para consulta en calendarios personales.
* **Compatibilidad con Validadores OTA**: Soporta rutas terminadas en `.ics` (`/export-ical/<uuid>_airbnb.ics`), peticiones `HEAD` de prevalidación y calendarios válidos vacíos sin `METHOD:PUBLISH` cuando el alojamiento aún no registra reservas.

---

## 4. Estrategia de Pruebas Automatizadas

* **`test/ical_priority_and_ui_test.dart`**: Verifica el desplegado RFC 5545, los cuatro cuadrantes de la matriz de prioridades, la retrocompatibilidad JSON con esquemas anteriores, el filtro de visibilidad del calendario global y el selector táctil de rangos en 3 toques.
* **`test/stress_sincronizacion_test.dart`**: Somete el motor a escenarios extremos de producción: preservación frente a reemplazo de nombres personalizados, estancias *back-to-back* el mismo día de cambio, ampliaciones/recortes/desplazamientos web, caídas parciales de red HTTP (`500`/`timeout` sin pérdida de datos), inmunidad del histórico pasado, verificación UTF-8 y reordenación *drag-and-drop* a 60 fps.
