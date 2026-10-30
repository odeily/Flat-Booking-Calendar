import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants/app_colors.dart';
import '../models/origen_reserva.dart';
import '../models/piso.dart';
import '../models/reserva_dia.dart';
import '../services/supabase_service.dart';
import '../widgets/dialogo_sincronizacion_piso.dart';
import '../widgets/header_dia.dart';

/// Pantalla operativa de calendario individual de un inmueble.
///
/// Integra selección táctil de rangos en 3 toques, edición y liberación inteligente de
/// estancias completas, estadísticas mensuales de ocupación por canal y sincronización iCal.
class DetallePisoScreen extends StatefulWidget {
  final Piso piso;
  final bool isDarkMode;

  const DetallePisoScreen({
    super.key,
    required this.piso,
    required this.isDarkMode,
  });

  @override
  State<DetallePisoScreen> createState() => _DetallePisoScreenState();
}

class _RangoReservaInfo {
  final String nombre;
  final OrigenReserva origen;
  final DateTime inicio;
  final DateTime fin;
  final ReservaDia reservaDia;

  _RangoReservaInfo({
    required this.nombre,
    required this.origen,
    required this.inicio,
    required this.fin,
    required this.reservaDia,
  });
}

enum EstadoSync { sincronizado, guardando, sinNube }

class _DetallePisoScreenState extends State<DetallePisoScreen> {
  final Set<DateTime> _diasSeleccionados = {};
  DateTime? _inicioRango;
  DateTime? _finRango;

  late EstadoSync _estadoSync;
  final _supabaseService = SupabaseService();
  DateTime _mesActual = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    final tieneIdRemoto = widget.piso.id != null &&
        widget.piso.id!.isNotEmpty &&
        !widget.piso.id!.startsWith('local_');
    _estadoSync = tieneIdRemoto ? EstadoSync.sincronizado : EstadoSync.sinNube;
  }

  void _limpiarSeleccion() {
    _diasSeleccionados.clear();
    _inicioRango = null;
    _finRango = null;
  }

  /// Selector intuitivo de rango en 3 toques con soporte de deselección en 1 toque.
  void _alTocarDia(DateTime fechaDia) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_diasSeleccionados.isEmpty) {
        // 1er toque: Selecciona fecha de entrada (check-in)
        _inicioRango = fechaDia;
        _finRango = null;
        _diasSeleccionados.add(fechaDia);
      } else if (_inicioRango != null &&
          _finRango == null &&
          _diasSeleccionados.length == 1) {
        if (fechaDia.isAtSameMomentAs(_inicioRango!)) {
          // Deselección directa con un toque si se toca el mismo día
          _limpiarSeleccion();
        } else {
          // 2º toque: Selecciona fecha final y rellena automáticamente días intermedios
          final DateTime inicio =
              fechaDia.isBefore(_inicioRango!) ? fechaDia : _inicioRango!;
          final DateTime fin =
              fechaDia.isBefore(_inicioRango!) ? _inicioRango! : fechaDia;
          _inicioRango = inicio;
          _finRango = fin;
          _diasSeleccionados.clear();

          DateTime cursor = inicio;
          while (!cursor.isAfter(fin)) {
            _diasSeleccionados.add(_limpiarHora(cursor));
            cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
          }
        }
      } else {
        // 3er toque: Reinicia la selección (deselecciona si toca dentro o inicia nuevo rango si toca fuera)
        if (_diasSeleccionados.contains(fechaDia)) {
          _limpiarSeleccion();
        } else {
          _diasSeleccionados
            ..clear()
            ..add(fechaDia);
          _inicioRango = fechaDia;
          _finRango = null;
        }
      }
    });
  }

  void _alMantenerDia(DateTime fechaDia) {
    HapticFeedback.lightImpact();
    setState(() {
      if (_diasSeleccionados.contains(fechaDia)) {
        _diasSeleccionados.remove(fechaDia);
        if (_diasSeleccionados.isEmpty) {
          _inicioRango = null;
          _finRango = null;
        }
      } else {
        _diasSeleccionados.add(fechaDia);
      }
    });
  }

  Color _obtenerColorParaReserva(ReservaDia reserva) {
    if (reserva.esBloqueoExterno) {
      return const Color(0xFF64748B);
    }
    if (reserva.origen == OrigenReserva.airbnb) {
      return colorAirbnb;
    }
    if (reserva.origen == OrigenReserva.booking) {
      return colorBooking;
    }
    return _obtenerColorParaInquilinoManual(reserva.nombreInquilino);
  }

  Color _obtenerColorParaInquilinoManual(String nombre) {
    if (widget.piso.coloresInquilinos.containsKey(nombre)) {
      Color c = widget.piso.coloresInquilinos[nombre]!;
      if (c == colorAirbnb || c == colorBooking) {
        c = paletaColoresManuales[0];
        widget.piso.coloresInquilinos[nombre] = c;
      }
      return c;
    }

    final coloresEnUso = widget.piso.coloresInquilinos.values.toSet();
    Color? colorElegido;

    for (final color in paletaColoresManuales) {
      if (!coloresEnUso.contains(color) &&
          color != colorAirbnb &&
          color != colorBooking) {
        colorElegido = color;
        break;
      }
    }

    if (colorElegido == null) {
      final int n = widget.piso.coloresInquilinos.length;
      final double hue = (n * 137.5) % 360;
      colorElegido = HSLColor.fromAHSL(1.0, hue, 0.70, 0.45).toColor();
      if (colorElegido == colorAirbnb || colorElegido == colorBooking) {
        colorElegido = const Color(0xFF4F46E5);
      }
    }

    widget.piso.coloresInquilinos[nombre] = colorElegido;
    return colorElegido;
  }

  Future<void> _guardarEnSupabase() async {
    setState(() => _estadoSync = EstadoSync.guardando);
    final result = await _supabaseService.guardarPiso(widget.piso);
    if (!mounted) return;

    final sincronizadoRemoto = result != null &&
        result.id != null &&
        !result.id!.startsWith('local_');
    setState(() {
      _estadoSync =
          sincronizadoRemoto ? EstadoSync.sincronizado : EstadoSync.sinNube;
    });
  }

  void _abrirPanelSincronizacion({bool destacarExportacion = false}) {
    HapticFeedback.selectionClick();
    DialogoSincronizacionPiso.mostrar(
      context,
      piso: widget.piso,
      isDarkMode: widget.isDarkMode,
      destacarExportacion: destacarExportacion,
      onActualizado: () {
        if (mounted) {
          setState(() {});
          _guardarEnSupabase();
        }
      },
    );
  }

  void _mostrarAlertaEliminarPiso() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Row(
                children: [
                  Icon(Icons.delete_forever_rounded, color: Colors.red, size: 26),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '¿Eliminar este piso?',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Estás a punto de eliminar "${widget.piso.nombre}" junto con todas sus reservas y enlaces configurados. Esta acción no se puede deshacer.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: widget.isDarkMode ? Colors.white70 : const Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(sheetCtx),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        Navigator.pop(sheetCtx);
                        Navigator.pop(context, true);
                      },
                      child: const Text(
                        'Eliminar piso',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  DateTime _limpiarHora(DateTime fecha) {
    return DateTime(fecha.year, fecha.month, fecha.day);
  }

  bool _sonDiasConsecutivos(List<DateTime> dias) {
    if (dias.length <= 1) return true;
    final List<DateTime> ordenados = List.from(dias)..sort();
    for (int i = 0; i < ordenados.length - 1; i++) {
      final int diferencia = ordenados[i + 1].difference(ordenados[i]).inDays;
      if (diferencia != 1) return false;
    }
    return true;
  }

  List<DateTime> _expandirRangoDias(DateTime inicio, DateTime fin) {
    final List<DateTime> dias = [];
    DateTime cursor = _limpiarHora(inicio);
    final DateTime limite = _limpiarHora(fin);
    while (!cursor.isAfter(limite)) {
      dias.add(cursor);
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
    return dias;
  }

  Map<String, _RangoReservaInfo> _obtenerRangosImplicados(Set<DateTime> dias) {
    final Map<String, _RangoReservaInfo> reservasImplicadas = {};
    final List<DateTime> diasOrdenados = dias.toList()..sort();

    for (final dia in diasOrdenados) {
      if (widget.piso.reservas.containsKey(dia)) {
        final res = widget.piso.reservas[dia]!;
        DateTime startBound = dia;
        while (widget.piso.reservas
                .containsKey(startBound.subtract(const Duration(days: 1))) &&
            res.perteneceAMismaEstancia(widget.piso
                .reservas[startBound.subtract(const Duration(days: 1))]!)) {
          startBound = startBound.subtract(const Duration(days: 1));
        }
        DateTime endBound = dia;
        while (widget.piso.reservas
                .containsKey(endBound.add(const Duration(days: 1))) &&
            res.perteneceAMismaEstancia(
                widget.piso.reservas[endBound.add(const Duration(days: 1))]!)) {
          endBound = endBound.add(const Duration(days: 1));
        }

        final String idEstancia =
            (res.codigoReserva?.trim().isNotEmpty == true)
                ? res.codigoReserva!.trim()
                : ((res.idEventoExt?.trim().isNotEmpty == true)
                    ? res.idEventoExt!.trim()
                    : res.nombreInquilino);

        final String clave =
            '${startBound.toIso8601String()}_${res.origen.name}_${res.tipoOcupacion.name}_$idEstancia';

        reservasImplicadas.putIfAbsent(
          clave,
          () => _RangoReservaInfo(
            nombre: res.nombreInquilino,
            origen: res.origen,
            inicio: startBound,
            fin: endBound,
            reservaDia: res,
          ),
        );
      }
    }
    return reservasImplicadas;
  }

  void _confirmarEliminarReservaSeleccionada() {
    final List<DateTime> diasOcupadosSeleccionados = _diasSeleccionados
        .where((dia) => widget.piso.reservas.containsKey(dia))
        .toList()
      ..sort();

    if (diasOcupadosSeleccionados.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Los días seleccionados ya están libres.'),
        ),
      );
      return;
    }

    final rangos = _obtenerRangosImplicados(_diasSeleccionados);
    final List<DateTime>? diasEstanciaCompleta = rangos.length == 1
        ? _expandirRangoDias(
            rangos.values.first.inicio,
            rangos.values.first.fin,
          )
        : null;
    final bool seleccionParcialDeEstancia = diasEstanciaCompleta != null &&
        diasEstanciaCompleta.length > diasOcupadosSeleccionados.length;

    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Liberar fechas seleccionadas',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                seleccionParcialDeEstancia
                    ? 'Has tocado ${diasOcupadosSeleccionados.length} día(s) de una estancia de ${diasEstanciaCompleta.length} noches ("${rangos.values.first.nombre}"). ¿Qué deseas liberar?'
                    : '¿Deseas eliminar la ocupación de los ${diasOcupadosSeleccionados.length} día(s) seleccionados y dejarlos disponibles?',
                style: TextStyle(
                  fontSize: 13.5,
                  color: widget.isDarkMode ? Colors.white70 : const Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 20),
              if (seleccionParcialDeEstancia) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    Navigator.pop(sheetCtx);
                    setState(() {
                      for (final dia in diasEstanciaCompleta) {
                        widget.piso.reservas.remove(dia);
                      }
                      _limpiarSeleccion();
                    });
                    _guardarEnSupabase();
                  },
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: Text(
                    'Eliminar reserva completa (${diasEstanciaCompleta.length} noches)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => Navigator.pop(sheetCtx),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(sheetCtx);
                          setState(() {
                            for (final dia in _diasSeleccionados) {
                              widget.piso.reservas.remove(dia);
                            }
                            _limpiarSeleccion();
                          });
                          _guardarEnSupabase();
                        },
                        child: Text(
                          'Solo ${diasOcupadosSeleccionados.length} día(s)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => Navigator.pop(sheetCtx),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(sheetCtx);
                          setState(() {
                            for (final dia in _diasSeleccionados) {
                              widget.piso.reservas.remove(dia);
                            }
                            _limpiarSeleccion();
                          });
                          _guardarEnSupabase();
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text(
                          'Eliminar',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  void _gestionarAsignacionDias(String nombrePrellenado, bool esEditar) {
    if (_diasSeleccionados.isEmpty) return;
    HapticFeedback.selectionClick();

    final rangos = _obtenerRangosImplicados(_diasSeleccionados);
    final bool eraNombreGenerico =
        esEditar && ReservaDia.esNombreGenericoAutomatico(nombrePrellenado);

    final controladorNombre = TextEditingController(
      text: eraNombreGenerico ? '' : nombrePrellenado,
    );

    final Set<DateTime> diasResumenSet = {..._diasSeleccionados};
    if (esEditar && rangos.length == 1) {
      diasResumenSet.addAll(
        _expandirRangoDias(rangos.values.first.inicio, rangos.values.first.fin),
      );
    }

    final List<DateTime> ordenados = diasResumenSet.toList()..sort();
    final DateTime primerDia = ordenados.first;
    final DateTime checkOut = ordenados.last.add(const Duration(days: 1));
    final String resumenFechas =
        'Entrada ${primerDia.day.toString().padLeft(2, '0')}/${primerDia.month.toString().padLeft(2, '0')} · Salida ${checkOut.day.toString().padLeft(2, '0')}/${checkOut.month.toString().padLeft(2, '0')} (${ordenados.length} noche${ordenados.length == 1 ? '' : 's'})';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                esEditar ? 'Editar Reserva' : 'Nueva Reserva Manual',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                resumenFechas,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4F46E5),
                ),
              ),
              if (eraNombreGenerico && nombrePrellenado.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Estado actual: $nombrePrellenado',
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.isDarkMode
                        ? Colors.white60
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: controladorNombre,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (val) {
                  final limpio = val.trim();
                  if (limpio.isNotEmpty) {
                    Navigator.pop(sheetCtx);
                    _procesarGuardadoReserva(
                      limpio,
                      nombreAntiguo: esEditar ? nombrePrellenado : null,
                      esEditar: esEditar,
                    );
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Nombre del huésped',
                  hintText: 'Ej: Laura Martínez',
                  prefixIcon: const Icon(Icons.person_outline_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(sheetCtx),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        final nuevoNombre = controladorNombre.text.trim();
                        if (nuevoNombre.isEmpty) return;
                        Navigator.pop(sheetCtx);
                        _procesarGuardadoReserva(
                          nuevoNombre,
                          nombreAntiguo: esEditar ? nombrePrellenado : null,
                          esEditar: esEditar,
                        );
                      },
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text(
                        'Guardar',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _procesarGuardadoReserva(
    String nombreInquilino, {
    String? nombreAntiguo,
    required bool esEditar,
  }) {
    final rangos = _obtenerRangosImplicados(_diasSeleccionados);

    // Si estamos editando una única reserva, abarcar automáticamente todas las noches de esa estancia
    final List<DateTime> diasBaseEstancia = (esEditar && rangos.length == 1)
        ? _expandirRangoDias(
            rangos.values.first.inicio,
            rangos.values.first.fin,
          )
        : (_diasSeleccionados.toList()..sort());

    final List<DateTime> diasLibresSeleccionados = _diasSeleccionados
        .where((d) => !widget.piso.reservas.containsKey(d))
        .toList()
      ..sort();

    if (esEditar &&
        nombreAntiguo != null &&
        diasLibresSeleccionados.isNotEmpty) {
      final List<DateTime> diasAmpliados = {
        ...diasBaseEstancia,
        ...diasLibresSeleccionados,
      }.toList()
        ..sort();

      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Ampliar o editar estancia',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                'Has seleccionado ${diasLibresSeleccionados.length} día(s) libre(s) además de la reserva existente. ¿Quieres añadirlos a la estancia o editar únicamente la reserva actual?',
                style: const TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _ejecutarGuardadoReserva(
                          nombreInquilino,
                          nombreAntiguo: nombreAntiguo,
                          esEditar: esEditar,
                          diasLista: diasBaseEstancia,
                        );
                      },
                      child: const Text('Solo ocupados'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _ejecutarGuardadoReserva(
                          nombreInquilino,
                          nombreAntiguo: nombreAntiguo,
                          esEditar: esEditar,
                          diasLista: diasAmpliados,
                        );
                      },
                      child: const Text('Añadir todos'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } else {
      _ejecutarGuardadoReserva(
        nombreInquilino,
        nombreAntiguo: nombreAntiguo,
        esEditar: esEditar,
        diasLista: esEditar
            ? diasBaseEstancia
            : (_diasSeleccionados.toList()..sort()),
      );
    }
  }

  void _ejecutarGuardadoReserva(
    String nombreInquilino, {
    String? nombreAntiguo,
    required bool esEditar,
    required List<DateTime> diasLista,
  }) {
    final bool consecutivos = _sonDiasConsecutivos(diasLista);

    final List<String> cambiosSobrescritos = [];
    for (final dia in diasLista) {
      if (widget.piso.reservas.containsKey(dia)) {
        final resPrev = widget.piso.reservas[dia]!;
        if (resPrev.esReservaReal && resPrev.nombreInquilino != nombreInquilino) {
          cambiosSobrescritos.add(
            '• ${dia.day}/${dia.month}/${dia.year}: "${resPrev.nombreInquilino}" → "$nombreInquilino"',
          );
        }
      }
    }

    // Buscar metadatos base si estamos editando una única reserva existente
    ReservaDia? plantillaExistente;
    if (esEditar) {
      for (final d in diasLista) {
        if (widget.piso.reservas.containsKey(d)) {
          plantillaExistente = widget.piso.reservas[d];
          break;
        }
      }
    }

    void aplicarCambios() {
      HapticFeedback.lightImpact();
      setState(() {
        for (final dia in diasLista) {
          final ReservaDia? actualDia = widget.piso.reservas[dia];

          if (esEditar && actualDia != null && actualDia.esReservaReal) {
            // Preservar canal original (Airbnb / Booking / Manual), UID, código y bloqueos cruzados,
            // marcando nombrePersonalizado = true para que futuras sincronizaciones de la MISMA reserva
            // jamás vuelvan a sobreescribirlo por "Reservado".
            widget.piso.reservas[dia] = actualDia.copyWith(
              nombreInquilino: nombreInquilino,
              tipoOcupacion: TipoOcupacion.reservaReal,
              nombrePersonalizado: true,
            );
          } else if (esEditar &&
              actualDia != null &&
              actualDia.esBloqueoExterno &&
              plantillaExistente != null &&
              plantillaExistente.esBloqueoExterno) {
            // Si el anfitrión nombra un bloqueo externo (p. ej. reserva GDPR de Booking),
            // asciende a reservaReal manteniendo su canal, UID y marcando nombrePersonalizado = true
            widget.piso.reservas[dia] = actualDia.copyWith(
              nombreInquilino: nombreInquilino,
              tipoOcupacion: TipoOcupacion.reservaReal,
              nombrePersonalizado: true,
              sincronizadoEnCanalOpuesto: actualDia.canalesBloqueados.isNotEmpty,
            );
          } else {
            // Nueva reserva manual (o noches libres adicionales añadidas manualmente en la app:
            // se guardan como OrigenReserva.manual para que las OTAs no las borren al sincronizar
            // y export-ical las bloquee automáticamente en Airbnb y Booking)
            final Set<OrigenReserva> bloqueosPrevios = {};
            if (actualDia != null && actualDia.esBloqueoExterno) {
              if (actualDia.origen != OrigenReserva.manual) {
                bloqueosPrevios.add(actualDia.origen);
              }
              bloqueosPrevios.addAll(actualDia.canalesBloqueados);
            }

            widget.piso.reservas[dia] = ReservaDia(
              nombreInquilino: nombreInquilino,
              origen: OrigenReserva.manual,
              tipoOcupacion: TipoOcupacion.reservaReal,
              nombrePersonalizado: true,
              sincronizadoEnCanalOpuesto: bloqueosPrevios.isNotEmpty,
              canalesBloqueados: bloqueosPrevios,
            );
          }
        }
        _limpiarSeleccion();
      });
      _guardarEnSupabase();
    }

    final List<String> avisos = [];
    if (!consecutivos) {
      avisos.add('Los días seleccionados no forman un rango continuo.');
    }
    if (cambiosSobrescritos.isNotEmpty && !esEditar) {
      avisos.add(
        'Vas a reemplazar reservas activas:\n${cambiosSobrescritos.join("\n")}',
      );
    }

    if (avisos.isNotEmpty) {
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706)),
                  SizedBox(width: 8),
                  Text(
                    'Confirmar cambios',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                avisos.join('\n\n'),
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        aplicarCambios();
                      },
                      child: const Text(
                        'Confirmar',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    } else {
      aplicarCambios();
    }
  }

  void _mostrarEstadisticas() {
    HapticFeedback.selectionClick();
    final DateTime hoy = _limpiarHora(DateTime.now());
    final diasFuturos = widget.piso.reservas.keys
        .where((d) => !d.isBefore(hoy))
        .toList()
      ..sort();

    final diasReales = diasFuturos
        .where((d) => widget.piso.reservas[d]!.esReservaReal)
        .toList();
    final int diasBloqueoVacio = diasFuturos.length - diasReales.length;

    final int diasOcupadosTotal = diasReales.length;
    final int diasOcupadosMes = diasReales
        .where((d) => d.year == hoy.year && d.month == hoy.month)
        .length;

    int reservasTotal = 0;
    int reservasMes = 0;

    ReservaDia? reservaAnterior;
    DateTime? diaAnterior;

    for (final dia in diasReales) {
      final ReservaDia resActual = widget.piso.reservas[dia]!;
      bool esNuevaReserva = false;

      if (reservaAnterior == null || diaAnterior == null) {
        esNuevaReserva = true;
      } else if (dia.difference(diaAnterior).inDays > 1 ||
          !resActual.perteneceAMismaEstancia(reservaAnterior)) {
        esNuevaReserva = true;
      }

      if (esNuevaReserva) {
        reservasTotal++;
        if (dia.year == hoy.year && dia.month == hoy.month) {
          reservasMes++;
        }
      }

      reservaAnterior = resActual;
      diaAnterior = dia;
    }

    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.analytics_outlined,
                    color: Color(0xFF0891B2),
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Estadísticas del piso',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: widget.isDarkMode
                          ? Colors.white
                          : const Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Contabiliza estancias reales a partir de hoy (excluye bloqueos vacíos).',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 18),
              _buildStatRow(
                'Reservas reales (este mes)',
                '$reservasMes',
                Icons.book_rounded,
              ),
              const SizedBox(height: 12),
              _buildStatRow(
                'Noches ocupadas (este mes)',
                '$diasOcupadosMes',
                Icons.calendar_today_rounded,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              _buildStatRow(
                'Reservas reales (futuro)',
                '$reservasTotal',
                Icons.collections_bookmark_rounded,
              ),
              const SizedBox(height: 12),
              _buildStatRow(
                'Noches ocupadas (futuro)',
                '$diasOcupadosTotal',
                Icons.event_available_rounded,
              ),
              if (diasBloqueoVacio > 0) ...[
                const SizedBox(height: 12),
                _buildStatRow(
                  'Días con cierre externo',
                  '$diasBloqueoVacio',
                  Icons.block_rounded,
                ),
              ],
              const SizedBox(height: 22),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Cerrar',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF64748B)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14.5,
              color: widget.isDarkMode
                  ? Colors.white70
                  : const Color(0xFF334155),
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: widget.isDarkMode ? Colors.white : const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }

  Widget _buildIndicadorNube() {
    if (_estadoSync == EstadoSync.guardando) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final bool nubeActiva = _estadoSync == EstadoSync.sincronizado;
    return Tooltip(
      message: nubeActiva
          ? 'Guardado y sincronizado en la nube'
          : 'Modo local (pendiente de conexión)',
      child: Icon(
        nubeActiva ? Icons.cloud_done_rounded : Icons.cloud_outlined,
        size: 18,
        color: nubeActiva ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final DateTime hoy = _limpiarHora(DateTime.now());

    final DateTime primerDiaMes =
        DateTime(_mesActual.year, _mesActual.month, 1);
    final DateTime ultimoDiaMes =
        DateTime(_mesActual.year, _mesActual.month + 1, 0);
    final int diasEnMes = ultimoDiaMes.day;
    final int diaSemanaInicio = primerDiaMes.weekday;

    final Color cellBg =
        isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.piso.nombre,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _buildIndicadorNube(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync_rounded, color: Color(0xFF4F46E5)),
            tooltip: 'Sincronización Bidireccional iCal',
            onPressed: () => _abrirPanelSincronizacion(),
          ),
          PopupMenuButton<String>(
            tooltip: 'Más opciones',
            onSelected: (valor) {
              if (valor == 'exportar') {
                _abrirPanelSincronizacion(destacarExportacion: true);
              } else if (valor == 'estadisticas') {
                _mostrarEstadisticas();
              } else if (valor == 'eliminar') {
                _mostrarAlertaEliminarPiso();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem<String>(
                value: 'exportar',
                child: Row(
                  children: [
                    Icon(Icons.ios_share_rounded, size: 20, color: Color(0xFF4F46E5)),
                    SizedBox(width: 10),
                    Text('Exportar enlaces iCal'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'estadisticas',
                child: Row(
                  children: [
                    Icon(Icons.analytics_outlined, size: 20, color: Color(0xFF0891B2)),
                    SizedBox(width: 10),
                    Text('Estadísticas del piso'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'eliminar',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 20, color: Colors.red),
                    SizedBox(width: 10),
                    Text(
                      'Eliminar piso',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra compacta de estado iCal y guía de selección por rango
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFEFF6FF),
            child: Row(
              children: [
                Icon(
                  widget.piso.ultimaSincronizacion != null
                      ? Icons.sync_alt_rounded
                      : Icons.touch_app_rounded,
                  size: 16,
                  color: const Color(0xFF0284C7),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _diasSeleccionados.length == 1 && _finRango == null
                        ? 'Toca la fecha final para completar el rango o pulsa Asignar'
                        : (widget.piso.ultimaSincronizacion != null
                            ? 'Última sinc: ${widget.piso.ultimaSincronizacion!.day.toString().padLeft(2, '0')}/${widget.piso.ultimaSincronizacion!.month.toString().padLeft(2, '0')} ${widget.piso.ultimaSincronizacion!.hour.toString().padLeft(2, '0')}:${widget.piso.ultimaSincronizacion!.minute.toString().padLeft(2, '0')}'
                            : 'Toca entrada y salida para seleccionar un rango'),
                    style: TextStyle(
                      fontSize: 11.8,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : const Color(0xFF1E40AF),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.piso.urlAirbnb?.isNotEmpty == true ||
                    widget.piso.urlBooking?.isNotEmpty == true)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.piso.urlAirbnb?.isNotEmpty == true)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: const BoxDecoration(
                            color: colorAirbnb,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (widget.piso.urlBooking?.isNotEmpty == true)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: const BoxDecoration(
                            color: colorBooking,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),

          // Navegación mensual con soporte táctil
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _mesActual =
                          DateTime(_mesActual.year, _mesActual.month - 1, 1);
                    });
                  },
                ),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _mesActual =
                          DateTime(DateTime.now().year, DateTime.now().month, 1);
                    });
                  },
                  child: Text(
                    '${_obtenerNombreMes(_mesActual.month)} ${_mesActual.year}',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _mesActual =
                          DateTime(_mesActual.year, _mesActual.month + 1, 1);
                    });
                  },
                ),
              ],
            ),
          ),

          // Encabezado Días de la semana
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                HeaderDia('L'),
                HeaderDia('M'),
                HeaderDia('X'),
                HeaderDia('J'),
                HeaderDia('V'),
                HeaderDia('S'),
                HeaderDia('D'),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Cuadrícula mensual con selección de rango y distintivos de sincronización
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) < -250) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _mesActual =
                        DateTime(_mesActual.year, _mesActual.month + 1, 1);
                  });
                } else if ((details.primaryVelocity ?? 0) > 250) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _mesActual =
                        DateTime(_mesActual.year, _mesActual.month - 1, 1);
                  });
                }
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final int totalCeldas = diasEnMes + (diaSemanaInicio - 1);
                  final int filas = (totalCeldas / 7).ceil().clamp(4, 6);
                  final double altoFila =
                      ((constraints.maxHeight - 8 - ((filas - 1) * 4)) / filas)
                          .clamp(48.0, 86.0);

                  return GridView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      mainAxisExtent: altoFila,
                      crossAxisSpacing: 0,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: totalCeldas,
                itemBuilder: (context, index) {
                  if (index < diaSemanaInicio - 1) {
                    return const SizedBox.shrink();
                  }

                  final int numeroDia = index - (diaSemanaInicio - 2);
                  final DateTime fechaDia = _limpiarHora(
                    DateTime(_mesActual.year, _mesActual.month, numeroDia),
                  );

                  final bool esHoy = fechaDia.isAtSameMomentAs(hoy);
                  final bool estaSeleccionado =
                      _diasSeleccionados.contains(fechaDia);
                  final bool esExtremoRango =
                      (_inicioRango != null &&
                          fechaDia.isAtSameMomentAs(_inicioRango!)) ||
                      (_finRango != null &&
                          fechaDia.isAtSameMomentAs(_finRango!));

                  final ReservaDia? reserva = widget.piso.reservas[fechaDia];
                  final bool estaOcupado = reserva != null;

                  BorderRadius borderRadiusBarra = BorderRadius.circular(10);
                  bool conectaAnterior = false;
                  bool conectaSiguiente = false;

                  if (estaOcupado) {
                    final DateTime diaAnterior =
                        fechaDia.subtract(const Duration(days: 1));
                    final DateTime diaSiguiente =
                        fechaDia.add(const Duration(days: 1));

                    final ReservaDia? resAnt =
                        widget.piso.reservas[diaAnterior];
                    final ReservaDia? resSig =
                        widget.piso.reservas[diaSiguiente];

                    conectaAnterior =
                        resAnt != null && reserva.perteneceAMismaEstancia(resAnt);
                    conectaSiguiente =
                        resSig != null && reserva.perteneceAMismaEstancia(resSig);

                    if (conectaAnterior && conectaSiguiente) {
                      borderRadiusBarra = BorderRadius.zero;
                    } else if (!conectaAnterior && conectaSiguiente) {
                      borderRadiusBarra = const BorderRadius.horizontal(
                        left: Radius.circular(10),
                      );
                    } else if (conectaAnterior && !conectaSiguiente) {
                      borderRadiusBarra = const BorderRadius.horizontal(
                        right: Radius.circular(10),
                      );
                    }
                  }

                  final Color colorBarra = estaOcupado
                      ? _obtenerColorParaReserva(reserva)
                      : Colors.transparent;
                  final bool tieneProteccionCruzada =
                      estaOcupado && reserva.etiquetaSincronizacion != null;

                  return GestureDetector(
                    onTap: () => _alTocarDia(fechaDia),
                    onLongPress: () => _alMantenerDia(fechaDia),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: estaSeleccionado
                            ? const Color(0xFF4F46E5)
                                .withValues(alpha: esExtremoRango ? 0.22 : 0.12)
                            : cellBg,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(
                          color: estaSeleccionado
                              ? const Color(0xFF4F46E5)
                              : (esHoy
                                  ? const Color(0xFF0891B2)
                                  : (isDark
                                      ? const Color(0xFF334155)
                                      : const Color(0xFFE2E8F0))),
                          width: estaSeleccionado ? 2 : (esHoy ? 1.5 : 0.8),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 5,
                              left: 5,
                              right: 4,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$numeroDia',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12.5,
                                    color: estaSeleccionado
                                        ? const Color(0xFF4F46E5)
                                        : (isDark
                                            ? Colors.white
                                            : const Color(0xFF0F172A)),
                                  ),
                                ),
                                if (tieneProteccionCruzada && !conectaAnterior)
                                  const Icon(
                                    Icons.verified_rounded,
                                    size: 11,
                                    color: Color(0xFF10B981),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                if (estaOcupado)
                                  Positioned(
                                    left: conectaAnterior ? -4.0 : 2.0,
                                    right: conectaSiguiente ? -4.0 : 2.0,
                                    bottom: 4,
                                    height: 24,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: reserva.esBloqueoExterno
                                            ? colorBarra.withValues(alpha: 0.65)
                                            : colorBarra,
                                        borderRadius: borderRadiusBarra,
                                      ),
                                      alignment: Alignment.centerLeft,
                                      padding: EdgeInsets.only(
                                        left: conectaAnterior ? 6 : 4,
                                        right: conectaSiguiente ? 6 : 4,
                                      ),
                                      child: Row(
                                        children: [
                                          if (reserva.esBloqueoExterno &&
                                              !conectaAnterior)
                                            const Padding(
                                              padding: EdgeInsets.only(right: 2),
                                              child: Icon(
                                                Icons.lock_outline_rounded,
                                                size: 9,
                                                color: Colors.white70,
                                              ),
                                            ),
                                          Expanded(
                                            child: Text(
                                              !conectaAnterior ||
                                                      fechaDia.weekday ==
                                                          DateTime.monday
                                                  ? reserva.nombreInquilino
                                                  : '',
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 1,
                                              style: const TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
                },
              ),
            ),
          ),

          // BARRA INFERIOR DE ACCIONES SOBRE DÍAS SELECCIONADOS
          if (_diasSeleccionados.isNotEmpty)
            Builder(
              builder: (context) {
                final Map<String, _RangoReservaInfo> reservasImplicadas =
                    _obtenerRangosImplicados(_diasSeleccionados);

                final bool multiplesReservas = reservasImplicadas.length > 1;
                final bool esEditar = reservasImplicadas.isNotEmpty;
                final String nombreActual = reservasImplicadas.length == 1
                    ? reservasImplicadas.values.first.nombre
                    : '';

                return SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (reservasImplicadas.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: reservasImplicadas.values.map((info) {
                                final String startStr =
                                    '${info.inicio.day.toString().padLeft(2, '0')}/${info.inicio.month.toString().padLeft(2, '0')}';
                                final DateTime checkOut =
                                    info.fin.add(const Duration(days: 1));
                                final String endStr =
                                    '${checkOut.day.toString().padLeft(2, '0')}/${checkOut.month.toString().padLeft(2, '0')}';

                                final Color tagColor =
                                    _obtenerColorParaReserva(info.reservaDia);
                                final String? etiquetaSync =
                                    info.reservaDia.etiquetaSincronizacion;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tagColor.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: tagColor.withValues(alpha: 0.45),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              info.nombre,
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.bold,
                                                color: tagColor,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          Text(
                                            '$startStr → $endStr',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? Colors.white70
                                                  : const Color(0xFF334155),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (etiquetaSync != null) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const Icon(
                                              Icons.verified_user_rounded,
                                              size: 13,
                                              color: Color(0xFF059669),
                                            ),
                                            const SizedBox(width: 5),
                                            Expanded(
                                              child: Text(
                                                etiquetaSync,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: Color(0xFF059669),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Limpiar selección',
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                setState(_limpiarSeleccion);
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: Colors.red,
                              ),
                              tooltip: 'Liberar días seleccionados',
                              visualDensity: VisualDensity.compact,
                              onPressed: _confirmarEliminarReservaSeleccionada,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '${_diasSeleccionados.length} noche${_diasSeleccionados.length == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13.5,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: () {
                                if (multiplesReservas) {
                                  HapticFeedback.mediumImpact();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Selecciona una sola reserva para editar su nombre.',
                                      ),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                } else {
                                  _gestionarAsignacionDias(
                                    nombreActual,
                                    esEditar,
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: multiplesReservas
                                    ? Colors.grey
                                    : (esEditar
                                        ? const Color(0xFF0891B2)
                                        : const Color(0xFF4F46E5)),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: Icon(
                                esEditar
                                    ? Icons.edit_rounded
                                    : Icons.edit_calendar_rounded,
                                size: 17,
                              ),
                              label: Text(
                                esEditar ? 'Editar' : 'Asignar',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  String _obtenerNombreMes(int mes) {
    const meses = [
      'Enero',
      'Febrero',
      'Marzo',
      'Abril',
      'Mayo',
      'Junio',
      'Julio',
      'Agosto',
      'Septiembre',
      'Octubre',
      'Noviembre',
      'Diciembre',
    ];
    return meses[mes - 1];
  }
}
