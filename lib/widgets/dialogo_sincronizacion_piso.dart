import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants/app_colors.dart';
import '../models/origen_reserva.dart';
import '../models/piso.dart';
import '../models/reserva_dia.dart';
import '../models/resultado_sincronizacion.dart';
import '../services/servicio_ical.dart';

/// Panel modal bidireccional de configuración y diagnóstico iCal (RFC 5545) por inmueble.
///
/// Guía en dos pasos la exportación segmentada anti-bucle hacia Airbnb y Booking.com,
/// valida la conectividad de los enlaces de importación y ofrece resolución asistida
/// día a día en caso de detectar una sobreventa real.
class DialogoSincronizacionPiso extends StatefulWidget {
  final Piso piso;
  final bool isDarkMode;
  final VoidCallback onActualizado;
  final bool destacarExportacion;

  const DialogoSincronizacionPiso({
    super.key,
    required this.piso,
    required this.isDarkMode,
    required this.onActualizado,
    this.destacarExportacion = false,
  });

  static Future<void> mostrar(
    BuildContext context, {
    required Piso piso,
    required bool isDarkMode,
    required VoidCallback onActualizado,
    bool destacarExportacion = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => DialogoSincronizacionPiso(
        piso: piso,
        isDarkMode: isDarkMode,
        onActualizado: onActualizado,
        destacarExportacion: destacarExportacion,
      ),
    );
  }

  @override
  State<DialogoSincronizacionPiso> createState() =>
      _DialogoSincronizacionPisoState();
}

class _DialogoSincronizacionPisoState extends State<DialogoSincronizacionPiso> {
  late final TextEditingController _ctrlAirbnb;
  late final TextEditingController _ctrlBooking;
  late final TextEditingController _ctrlICalManual;

  bool _cargando = false;
  bool _comprobando = false;
  String? _copiadoReciente; // 'airbnb' | 'booking' | 'general'
  VerificacionEnlaceICal? _verifAirbnb;
  VerificacionEnlaceICal? _verifBooking;
  OrigenReserva _origenManualSeleccionado = OrigenReserva.airbnb;

  bool get _tieneIdNube =>
      widget.piso.id != null &&
      widget.piso.id!.isNotEmpty &&
      !widget.piso.id!.startsWith('local_');

  @override
  void initState() {
    super.initState();
    _ctrlAirbnb = TextEditingController(text: widget.piso.urlAirbnb ?? '');
    _ctrlBooking = TextEditingController(text: widget.piso.urlBooking ?? '');
    _ctrlICalManual = TextEditingController();
  }

  @override
  void dispose() {
    _ctrlAirbnb.dispose();
    _ctrlBooking.dispose();
    _ctrlICalManual.dispose();
    super.dispose();
  }

  void _copiarEnlaceExportacion({String? target, required String clave}) {
    if (!_tieneIdNube) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Guarda el piso con conexión a internet para activar su enlace público iCal.',
          ),
          backgroundColor: Color(0xFFD97706),
        ),
      );
      return;
    }

    final url = ServicioICal.construirUrlExportacion(
      widget.piso.id!,
      target: target,
    );
    Clipboard.setData(ClipboardData(text: url));
    HapticFeedback.lightImpact();

    setState(() => _copiadoReciente = clave);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _copiadoReciente == clave) {
        setState(() => _copiadoReciente = null);
      }
    });
  }

  Future<void> _pegarDesdePortapapeles(TextEditingController ctrl, bool esAirbnb) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final texto = ServicioICal.normalizarUrlICal(data?.text ?? '');
    if (texto.isNotEmpty) {
      HapticFeedback.selectionClick();
      setState(() {
        ctrl.text = texto;
        if (esAirbnb) {
          _verifAirbnb = null;
        } else {
          _verifBooking = null;
        }
      });
    }
  }

  Future<void> _comprobarEnlaces() async {
    final urlA = _ctrlAirbnb.text.trim();
    final urlB = _ctrlBooking.text.trim();
    if (urlA.isEmpty && urlB.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Introduce al menos un enlace de Airbnb o Booking para comprobarlo.'),
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      _comprobando = true;
      _verifAirbnb = null;
      _verifBooking = null;
    });

    VerificacionEnlaceICal? resA;
    VerificacionEnlaceICal? resB;

    if (urlA.isNotEmpty) {
      resA = await ServicioICal.verificarEnlace(urlA);
    }
    if (urlB.isNotEmpty) {
      resB = await ServicioICal.verificarEnlace(urlB);
    }

    if (!mounted) return;
    HapticFeedback.lightImpact();
    setState(() {
      _comprobando = false;
      _verifAirbnb = resA;
      _verifBooking = resB;
    });
  }

  Future<void> _ejecutarSincronizacionWeb() async {
    final urlA = ServicioICal.normalizarUrlICal(_ctrlAirbnb.text);
    final urlB = ServicioICal.normalizarUrlICal(_ctrlBooking.text);

    if (!ServicioICal.validarFormatoUrlICal(urlA) ||
        !ServicioICal.validarFormatoUrlICal(urlB)) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Revisa el formato de las URLs antes de sincronizar (deben empezar por https://).'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      _cargando = true;
      _ctrlAirbnb.text = urlA;
      _ctrlBooking.text = urlB;
    });
    widget.piso.urlAirbnb = urlA;
    widget.piso.urlBooking = urlB;

    final resultado = await ServicioICal.sincronizarPiso(
      widget.piso,
      urlAirbnb: widget.piso.urlAirbnb,
      urlBooking: widget.piso.urlBooking,
    );

    await _manejarResultadoSincronizacion(resultado);
  }

  Future<void> _importarICalManual() async {
    if (_ctrlICalManual.text.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _cargando = true);

    final resultado = await ServicioICal.sincronizarPiso(
      widget.piso,
      contenidoManual: _ctrlICalManual.text.trim(),
      origenManual: _origenManualSeleccionado,
    );

    await _manejarResultadoSincronizacion(resultado);
  }

  Future<void> _manejarResultadoSincronizacion(
    ResultadoSincronizacion resultado,
  ) async {
    setState(() => _cargando = false);
    widget.onActualizado();

    if (!mounted) return;

    if (!resultado.hayConflictos) {
      HapticFeedback.lightImpact();
      final String extraBloqueos = resultado.bloqueosCruzadosDetectados > 0
          ? ' (${resultado.bloqueosCruzadosDetectados} bloqueos cruzados conciliados automáticamente)'
          : '';
      final String avisoRed = resultado.advertenciasConexion.isNotEmpty
          ? ' · Aviso: ${resultado.advertenciasConexion.join(" ")}'
          : '';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Sincronización completada: ${resultado.diasSinConflicto} días actualizados$extraBloqueos.$avisoRed',
          ),
          backgroundColor: resultado.advertenciasConexion.isNotEmpty
              ? const Color(0xFFD97706)
              : const Color(0xFF059669),
        ),
      );
      Navigator.pop(context);
      return;
    }

    // ÚNICO CASO DE CONFLICTO REAL: DOBLE RESERVA / OVERBOOKING
    HapticFeedback.heavyImpact();
    await _mostrarHojaResolucionOverbooking(resultado);
  }

  Future<void> _mostrarHojaResolucionOverbooking(
    ResultadoSincronizacion resultado,
  ) async {
    // Mapa de decisión día a día: false = conservar reservaActual, true = aplicar reservaNueva
    final Map<DateTime, bool> usarNuevaPorDia = {
      for (final c in resultado.conflictos) c.dia: false,
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final bool isDark = widget.isDarkMode;
            final int totalNuevasSeleccionadas =
                usarNuevaPorDia.values.where((v) => v).length;

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.86,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Alerta crítica visual de Sobreventa
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFDC2626),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_rounded,
                            color: Color(0xFFDC2626),
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '¡ALERTA CRÍTICA DE SOBREVENTA!',
                                  style: TextStyle(
                                    color: Color(0xFFDC2626),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Coexisten 2 reservas reales verificadas de canales distintos en ${resultado.conflictos.length} fecha(s). Toca qué reserva debe prevalecer en cada día:',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.35,
                                    color: isDark
                                        ? Colors.white70
                                        : const Color(0xFF334155),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Acciones rápidas de selección masiva
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              setSheetState(() {
                                for (final k in usarNuevaPorDia.keys.toList()) {
                                  usarNuevaPorDia[k] = false;
                                }
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              'Elegir actuales en todos',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              setSheetState(() {
                                for (final k in usarNuevaPorDia.keys.toList()) {
                                  usarNuevaPorDia[k] = true;
                                }
                              });
                            },
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              'Elegir entrantes en todos',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Lista detallada día a día
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: resultado.conflictos.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final c = resultado.conflictos[i];
                          final bool usarNueva = usarNuevaPorDia[c.dia] ?? false;
                          final String fechaStr =
                              '${c.dia.day.toString().padLeft(2, '0')}/${c.dia.month.toString().padLeft(2, '0')}/${c.dia.year}';

                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1E293B)
                                  : const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFCBD5E1),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.event_busy_rounded,
                                      size: 16,
                                      color: Color(0xFFDC2626),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'Fecha en conflicto: $fechaStr',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _buildTarjetaOpcionConflicto(
                                        tituloOpcion: 'Conservar actual',
                                        reserva: c.reservaActual,
                                        seleccionada: !usarNueva,
                                        isDark: isDark,
                                        onTap: () {
                                          HapticFeedback.selectionClick();
                                          setSheetState(
                                            () => usarNuevaPorDia[c.dia] = false,
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _buildTarjetaOpcionConflicto(
                                        tituloOpcion: 'Usar entrante',
                                        reserva: c.reservaNueva,
                                        seleccionada: usarNueva,
                                        isDark: isDark,
                                        onTap: () {
                                          HapticFeedback.selectionClick();
                                          setSheetState(
                                            () => usarNuevaPorDia[c.dia] = true,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),

                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        for (final c in resultado.conflictos) {
                          if (usarNuevaPorDia[c.dia] == true) {
                            widget.piso.reservas[c.dia] = c.reservaNueva;
                          } else {
                            widget.piso.reservas[c.dia] = c.reservaActual;
                          }
                        }
                        Navigator.pop(sheetCtx);
                        Navigator.pop(context);
                        widget.onActualizado();

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Sobreventa resuelta: $totalNuevasSeleccionadas día(s) actualizados y ${resultado.conflictos.length - totalNuevasSeleccionadas} conservados.',
                            ),
                            backgroundColor: const Color(0xFF059669),
                          ),
                        );
                      },
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: const Text(
                        'Aplicar resolución día a día',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTarjetaOpcionConflicto({
    required String tituloOpcion,
    required ReservaDia reserva,
    required bool seleccionada,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final Color colorCanal = _colorPorOrigen(reserva.origen);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: seleccionada
              ? colorCanal.withValues(alpha: 0.14)
              : (isDark ? const Color(0xFF0F172A) : Colors.white),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: seleccionada
                ? colorCanal
                : Colors.grey.withValues(alpha: 0.35),
            width: seleccionada ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  seleccionada
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 16,
                  color: seleccionada ? colorCanal : Colors.grey,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tituloOpcion,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: seleccionada ? colorCanal : Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _buildBadgeOrigen(reserva.origen),
            const SizedBox(height: 5),
            Text(
              reserva.nombreInquilino,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _colorPorOrigen(OrigenReserva origen) {
    switch (origen) {
      case OrigenReserva.airbnb:
        return colorAirbnb;
      case OrigenReserva.booking:
        return colorBooking;
      case OrigenReserva.manual:
        return const Color(0xFF4F46E5);
    }
  }

  Widget _buildBadgeOrigen(OrigenReserva origen) {
    final Color col = _colorPorOrigen(origen);
    final String etiqueta = switch (origen) {
      OrigenReserva.airbnb => 'Airbnb',
      OrigenReserva.booking => 'Booking',
      OrigenReserva.manual => 'Manual',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: col.withValues(alpha: 0.5)),
      ),
      child: Text(
        etiqueta,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: col,
        ),
      ),
    );
  }

  Widget _buildCampoImportacion({
    required TextEditingController controller,
    required String label,
    required String hint,
    required String instruccionObtencion,
    required Color colorMarca,
    required bool esAirbnb,
    required VerificacionEnlaceICal? verificacion,
  }) {
    final String valor = ServicioICal.normalizarUrlICal(controller.text);
    final bool formatoValido = ServicioICal.validarFormatoUrlICal(valor);
    final bool pareceICal = valor.isNotEmpty &&
        formatoValido &&
        (valor.toLowerCase().contains('.ics') ||
            valor.toLowerCase().contains('ical') ||
            valor.toLowerCase().contains('calendar') ||
            valor.toLowerCase().contains('export'));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorMarca.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorMarca.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) {
              setState(() {
                if (esAirbnb) {
                  _verifAirbnb = null;
                } else {
                  _verifBooking = null;
                }
              });
            },
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor:
                  widget.isDarkMode ? const Color(0xFF0F172A) : Colors.white,
              prefixIcon: Icon(Icons.circle, color: colorMarca, size: 14),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (valor.isNotEmpty)
                    Icon(
                      !formatoValido
                          ? Icons.error_outline_rounded
                          : (pareceICal
                              ? Icons.check_circle_rounded
                              : Icons.info_outline_rounded),
                      size: 18,
                      color: !formatoValido
                          ? Colors.redAccent
                          : (pareceICal
                              ? const Color(0xFF059669)
                              : const Color(0xFFD97706)),
                    ),
                  IconButton(
                    tooltip: valor.isEmpty ? 'Pegar enlace' : 'Limpiar campo',
                    icon: Icon(
                      valor.isEmpty
                          ? Icons.content_paste_rounded
                          : Icons.close_rounded,
                      size: 18,
                    ),
                    onPressed: () {
                      if (valor.isEmpty) {
                        _pegarDesdePortapapeles(controller, esAirbnb);
                      } else {
                        HapticFeedback.selectionClick();
                        setState(() {
                          controller.clear();
                          if (esAirbnb) {
                            _verifAirbnb = null;
                          } else {
                            _verifBooking = null;
                          }
                        });
                      }
                    },
                  ),
                ],
              ),
              errorText: !formatoValido
                  ? 'Introduce una URL válida que empiece por https://'
                  : null,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          if (verificacion != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: Row(
                children: [
                  Icon(
                    verificacion.esValido
                        ? Icons.check_circle_outline_rounded
                        : Icons.warning_amber_rounded,
                    size: 15,
                    color: verificacion.esValido
                        ? const Color(0xFF059669)
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      verificacion.mensaje,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: verificacion.esValido
                            ? const Color(0xFF059669)
                            : Colors.redAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            instruccionObtencion,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.32,
              color: widget.isDarkMode
                  ? Colors.white70
                  : const Color(0xFF475569),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTarjetaExportacion({
    required String tituloBoton,
    required String instruccionExtranet,
    required Color colorPortal,
    required String claveCopiado,
    required String target,
  }) {
    final bool recienCopiado = _copiadoReciente == claveCopiado;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorPortal.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorPortal.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  recienCopiado ? const Color(0xFF059669) : colorPortal,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () =>
                _copiarEnlaceExportacion(target: target, clave: claveCopiado),
            icon: Icon(
              recienCopiado ? Icons.check_rounded : Icons.copy_rounded,
              size: 18,
            ),
            label: Text(
              recienCopiado ? '¡Enlace copiado al portapapeles!' : tituloBoton,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            instruccionExtranet,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.3,
              color: widget.isDarkMode
                  ? Colors.white70
                  : const Color(0xFF475569),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.90,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tirador superior estilo nativo móvil
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.sync_alt_rounded,
                    color: Color(0xFF4F46E5),
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Sincronización Bidireccional',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 17,
                            color: isDark ? Colors.white : const Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          widget.piso.nombre,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.grey.shade500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Contenido desplazable a prueba de teclado virtual
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // PASO 1: EXPORTAR HACIA TUS PORTALES
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4F46E5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'PASO 1',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Exportar hacia tus portales',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Cada enlace filtra automáticamente las reservas del propio portal para evitar bucles de bloqueo:',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 12),

                    _buildTarjetaExportacion(
                      tituloBoton: 'Copiar enlace exclusivo para Airbnb',
                      instruccionExtranet:
                          'Dónde pegarlo en Airbnb: Modo Anfitrión → Calendario → selecciona tu anuncio → Disponibilidad (⚙️) → Conectar calendarios → Conectar con otro sitio web → pega ahí este enlace.',
                      colorPortal: colorAirbnb,
                      claveCopiado: 'airbnb',
                      target: 'airbnb',
                    ),
                    const SizedBox(height: 10),
                    _buildTarjetaExportacion(
                      tituloBoton: 'Copiar enlace exclusivo para Booking',
                      instruccionExtranet:
                          'Dónde pegarlo en Booking.com: Abre admin.booking.com en el navegador → Tarifas y disponibilidad (o Calendario) → Sincronizar calendarios → Añadir conexión de calendario → pega ahí este enlace.',
                      colorPortal: colorBooking,
                      claveCopiado: 'booking',
                      target: 'booking',
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            _copiarEnlaceExportacion(clave: 'general'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: Icon(
                          _copiadoReciente == 'general'
                              ? Icons.check_rounded
                              : Icons.calendar_today_rounded,
                          size: 15,
                        ),
                        label: Text(
                          _copiadoReciente == 'general'
                              ? 'Enlace personal copiado'
                              : 'Copiar enlace completo (Google / Apple Calendar)',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),

                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(height: 1),
                    ),

                    // PASO 2: IMPORTAR DESDE TUS PORTALES
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0891B2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'PASO 2',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Importar desde tus portales',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _comprobando ? null : _comprobarEnlaces,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: _comprobando
                              ? const SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.wifi_tethering_rounded,
                                  size: 16,
                                ),
                          label: Text(
                            _comprobando ? 'Verificando...' : 'Comprobar',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Consigue el enlace iCal en cada portal siguiendo estos pasos y pégalo aquí:',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    const SizedBox(height: 12),

                    _buildCampoImportacion(
                      controller: _ctrlAirbnb,
                      label: 'URL iCal de Airbnb',
                      hint: 'https://www.airbnb.es/calendar/ical/...',
                      instruccionObtencion:
                          'Cómo conseguirlo en Airbnb: Modo Anfitrión → Calendario → toca tu anuncio → Disponibilidad (⚙️) → baja a "Conectar calendarios" → "Conectar con otro sitio web" → en el Paso 1 verás tu dirección de Airbnb acabada en .ics → pulsa "Copiar enlace".',
                      colorMarca: colorAirbnb,
                      esAirbnb: true,
                      verificacion: _verifAirbnb,
                    ),
                    const SizedBox(height: 12),

                    _buildCampoImportacion(
                      controller: _ctrlBooking,
                      label: 'URL iCal de Booking.com',
                      hint: 'https://ical.booking.com/v1/export?t=...',
                      instruccionObtencion:
                          'Cómo conseguirlo en Booking.com: Entra desde el navegador web en admin.booking.com (no aparece en la app móvil Pulse) → Tarifas y disponibilidad → Sincronizar calendarios → Añadir conexión de calendario → en el Paso 2 ("Exportar calendario") pulsa "Copiar enlace".',
                      colorMarca: colorBooking,
                      esAirbnb: false,
                      verificacion: _verifBooking,
                    ),
                    const SizedBox(height: 14),

                    // Aviso pedagógico de latencia natural iCal
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF0F172A)
                            : const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFD97706).withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.schedule_rounded,
                            size: 18,
                            color: Color(0xFFD97706),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Latencia natural iCal: Airbnb y Booking tardan entre 1 y 3 horas en refrescar automáticamente los calendarios externos. Pulsa "Comprobar" para verificar que tus enlaces responden al instante.',
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.35,
                                color: isDark
                                    ? Colors.amber.shade200
                                    : const Color(0xFF92400E),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Importación avanzada por texto .ics manual
                    Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                      ),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          'Opción avanzada: Pegar contenido .ics manual',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        children: [
                          const SizedBox(height: 6),
                          DropdownButtonFormField<OrigenReserva>(
                            initialValue: _origenManualSeleccionado,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'Canal de origen del archivo',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: OrigenReserva.airbnb,
                                child: Text('Airbnb (Rosa #FF385C)'),
                              ),
                              DropdownMenuItem(
                                value: OrigenReserva.booking,
                                child: Text('Booking.com (Azul #003580)'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(
                                    () => _origenManualSeleccionado = val);
                              }
                            },
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _ctrlICalManual,
                            maxLines: 3,
                            decoration: InputDecoration(
                              hintText: 'BEGIN:VCALENDAR...',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(42),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: _cargando ? null : _importarICalManual,
                            icon: const Icon(Icons.upload_file_rounded, size: 18),
                            label: const Text('Procesar texto .ics pegado'),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Botón principal de guardado y sincronización
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _cargando ? null : _ejecutarSincronizacionWeb,
                      icon: _cargando
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync_rounded),
                      label: Text(
                        _cargando
                            ? 'Sincronizando calendarios...'
                            : 'Guardar y Sincronizar Ahora',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
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
    );
  }
}
