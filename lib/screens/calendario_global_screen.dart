import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants/app_colors.dart';
import '../models/origen_reserva.dart';
import '../models/piso.dart';
import '../models/reserva_dia.dart';
import '../widgets/header_dia.dart';
import 'detalle_piso_screen.dart';

/// Modos de visualización disponibles para el calendario consolidado multipropiedad.
enum ModoVistaGlobal { agendaPuntos, barras }

/// Calendario consolidado multipropiedad adaptado a pantallas móviles y tabletas.
///
/// Aplica un filtro estricto de visibilidad que muestra todas las estancias reales
/// (incluidas aquellas con sello de protección cruzada) y omite cierres vacíos externos.
class CalendarioGlobalScreen extends StatefulWidget {
  final List<Piso> pisos;
  final bool isDarkMode;

  const CalendarioGlobalScreen({
    super.key,
    required this.pisos,
    required this.isDarkMode,
  });

  @override
  State<CalendarioGlobalScreen> createState() => _CalendarioGlobalScreenState();
}

class _CalendarioGlobalScreenState extends State<CalendarioGlobalScreen> {
  late DateTime _mesActual;
  late DateTime _diaSeleccionado;
  ModoVistaGlobal? _modoVista;

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _mesActual = DateTime(ahora.year, ahora.month, 1);
    _diaSeleccionado = DateTime(ahora.year, ahora.month, ahora.day);
  }

  DateTime _limpiarHora(DateTime fecha) {
    return DateTime(fecha.year, fecha.month, fecha.day);
  }

  /// Regla estricta: Las reservas reales NUNCA se ocultan (incluso con bloqueo cruzado);
  /// únicamente se ocultan los bloqueos vacíos que no pertenecen a ninguna estancia real.
  bool _esVisibleEnGlobal(ReservaDia? reserva) {
    return reserva != null && reserva.esReservaReal;
  }

  List<_InfoReservaGlobal> _obtenerReservasRealesDelDia(DateTime fechaDia) {
    final List<_InfoReservaGlobal> lista = [];
    for (final piso in widget.pisos) {
      final ReservaDia? res = piso.reservas[fechaDia];
      if (_esVisibleEnGlobal(res)) {
        lista.add(
          _InfoReservaGlobal(
            piso: piso,
            reserva: res!,
            colorReserva: _obtenerColorParaReserva(res, piso),
          ),
        );
      }
    }
    return lista;
  }

  Color _obtenerColorParaReserva(ReservaDia reserva, Piso piso) {
    if (reserva.origen == OrigenReserva.airbnb) {
      return colorAirbnb;
    }
    if (reserva.origen == OrigenReserva.booking) {
      return colorBooking;
    }

    int index = widget.pisos.indexOf(piso);
    if (index == -1) index = 0;
    return paletaColoresManuales[index % paletaColoresManuales.length];
  }

  void _cambiarMes(int delta) {
    HapticFeedback.selectionClick();
    setState(() {
      _mesActual = DateTime(_mesActual.year, _mesActual.month + delta, 1);
      final hoy = _limpiarHora(DateTime.now());
      if (_mesActual.year == hoy.year && _mesActual.month == hoy.month) {
        _diaSeleccionado = hoy;
      } else {
        _diaSeleccionado = DateTime(_mesActual.year, _mesActual.month, 1);
      }
    });
  }

  void _abrirDetallePiso(Piso piso) {
    HapticFeedback.selectionClick();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DetallePisoScreen(
          piso: piso,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _mostrarHojaDiaGlobal(
    DateTime fechaLimpia,
    List<_InfoReservaGlobal> reservasDia,
  ) {
    final bool isDark = widget.isDarkMode;
    HapticFeedback.selectionClick();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
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
                const SizedBox(height: 14),
                _buildEncabezadoDiaSeleccionado(
                  fechaLimpia,
                  reservasDia.length,
                  isDark,
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: reservasDia.isEmpty
                      ? _buildEstadoLibreDia(isDark)
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: reservasDia.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, idx) => _buildTarjetaOcupacionPiso(
                            reservasDia[idx],
                            isDark,
                            cerrarSheetAlIr: true,
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEncabezadoDiaSeleccionado(
    DateTime fecha,
    int ocupados,
    bool isDark,
  ) {
    final int libres = (widget.pisos.length - ocupados).clamp(0, 999);
    return Row(
      children: [
        const Icon(
          Icons.event_note_rounded,
          color: Color(0xFF4F46E5),
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Ocupación ${fecha.day.toString().padLeft(2, '0')}/${fecha.month.toString().padLeft(2, '0')}/${fecha.year}',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : const Color(0xFF0F172A),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: ocupados > 0
                ? const Color(0xFF4F46E5).withValues(alpha: 0.12)
                : const Color(0xFF059669).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$ocupados ocupado${ocupados == 1 ? '' : 's'} · $libres libre${libres == 1 ? '' : 's'}',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
              color: ocupados > 0
                  ? const Color(0xFF4F46E5)
                  : const Color(0xFF059669),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEstadoLibreDia(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 36,
              color: const Color(0xFF10B981).withValues(alpha: 0.8),
            ),
            const SizedBox(height: 8),
            Text(
              'Todos los pisos están disponibles en esta fecha.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: isDark ? Colors.white70 : const Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTarjetaOcupacionPiso(
    _InfoReservaGlobal item,
    bool isDark, {
    required bool cerrarSheetAlIr,
  }) {
    final Color col = item.colorReserva;
    final String etiquetaOrigen = switch (item.reserva.origen) {
      OrigenReserva.airbnb => 'Airbnb',
      OrigenReserva.booking => 'Booking',
      OrigenReserva.manual => 'Manual',
    };
    final String? etiquetaSync = item.reserva.etiquetaSincronizacion;

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        if (cerrarSheetAlIr) Navigator.pop(context);
        _abrirDetallePiso(item.piso);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: col.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: col.withValues(alpha: 0.38)),
        ),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 38,
              decoration: BoxDecoration(
                color: col,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.piso.nombre,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: col.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          etiquetaOrigen,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: col,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.reserva.nombreInquilino,
                    style: TextStyle(
                      fontSize: 12.8,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white70 : const Color(0xFF334155),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (etiquetaSync != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(
                          Icons.verified_user_rounded,
                          size: 12,
                          color: Color(0xFF059669),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            etiquetaSync,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF059669),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: col),
          ],
        ),
      ),
    );
  }

  void _mostrarLeyendaModal() {
    final bool isDark = widget.isDarkMode;
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
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
            const Text(
              'Leyenda de Canales y Pisos',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                _itemLeyenda(colorAirbnb, 'Airbnb (Exclusivo)', isDark),
                _itemLeyenda(colorBooking, 'Booking (Exclusivo)', isDark),
                ...widget.pisos.asMap().entries.map((entry) {
                  final Color c = paletaColoresManuales[
                      entry.key % paletaColoresManuales.length];
                  return _itemLeyenda(c, '${entry.value.nombre} (Manual)', isDark);
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemLeyenda(Color color, String texto, bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          texto,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white70 : const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final double anchoPantalla = MediaQuery.of(context).size.width;
    final ModoVistaGlobal modoEfectivo = _modoVista ??
        (anchoPantalla < 640
            ? ModoVistaGlobal.agendaPuntos
            : ModoVistaGlobal.barras);

    final DateTime hoy = _limpiarHora(DateTime.now());
    final DateTime primerDiaMes =
        DateTime(_mesActual.year, _mesActual.month, 1);
    final DateTime ultimoDiaMes =
        DateTime(_mesActual.year, _mesActual.month + 1, 0);
    final int diasEnMes = ultimoDiaMes.day;
    final int diaSemanaInicio = primerDiaMes.weekday;

    final Color cellBg =
        isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final List<_InfoReservaGlobal> reservasDiaSeleccionado =
        _obtenerReservasRealesDelDia(_diaSeleccionado);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: const Text(
          'Calendario Global',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            tooltip: 'Cambiar modo de vista',
            icon: Icon(
              modoEfectivo == ModoVistaGlobal.agendaPuntos
                  ? Icons.view_stream_rounded
                  : Icons.apps_rounded,
              color: const Color(0xFF4F46E5),
            ),
            onPressed: () {
              HapticFeedback.selectionClick();
              setState(() {
                _modoVista = modoEfectivo == ModoVistaGlobal.agendaPuntos
                    ? ModoVistaGlobal.barras
                    : ModoVistaGlobal.agendaPuntos;
              });
            },
          ),
          IconButton(
            tooltip: 'Leyenda de colores',
            icon: const Icon(Icons.palette_outlined),
            onPressed: _mostrarLeyendaModal,
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra superior de navegación de mes + selector rápido de vista
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _cambiarMes(-1),
                ),
                Expanded(
                  child: Text(
                    '${_obtenerNombreMes(_mesActual.month)} ${_mesActual.year}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _cambiarMes(1),
                ),
                const SizedBox(width: 4),
                SegmentedButton<ModoVistaGlobal>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment<ModoVistaGlobal>(
                      value: ModoVistaGlobal.agendaPuntos,
                      icon: Icon(Icons.calendar_view_month_rounded, size: 16),
                      tooltip: 'Vista mensual + lista diaria',
                    ),
                    ButtonSegment<ModoVistaGlobal>(
                      value: ModoVistaGlobal.barras,
                      icon: Icon(Icons.stacked_bar_chart_rounded, size: 16),
                      tooltip: 'Vista de barras apiladas',
                    ),
                  ],
                  selected: {modoEfectivo},
                  onSelectionChanged: (sel) {
                    HapticFeedback.selectionClick();
                    setState(() => _modoVista = sel.first);
                  },
                ),
              ],
            ),
          ),

          // Encabezado Días de la semana
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

          // MODO 1 (ÓPTIMO EN MÓVIL): VISTA MENSUAL CON PUNTOS + LISTA DE OCUPACIÓN DIARIA INFERIOR
          if (modoEfectivo == ModoVistaGlobal.agendaPuntos)
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final int totalCeldas = diasEnMes + (diaSemanaInicio - 1);
                  final int filas = (totalCeldas / 7).ceil();
                  final double alturaCelda =
                      ((constraints.maxHeight * 0.48) / filas).clamp(36.0, 52.0);

                  return Column(
                    children: [
                      GestureDetector(
                        onHorizontalDragEnd: (details) {
                          if ((details.primaryVelocity ?? 0) < -250) {
                            _cambiarMes(1);
                          } else if ((details.primaryVelocity ?? 0) > 250) {
                            _cambiarMes(-1);
                          }
                        },
                        child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 7,
                            mainAxisExtent: alturaCelda,
                            crossAxisSpacing: 3,
                            mainAxisSpacing: 3,
                          ),
                          itemCount: totalCeldas,
                          itemBuilder: (context, index) {
                            if (index < diaSemanaInicio - 1) {
                              return const SizedBox.shrink();
                            }

                            final int numeroDia = index - (diaSemanaInicio - 2);
                            final DateTime fechaDia = _limpiarHora(
                              DateTime(
                                _mesActual.year,
                                _mesActual.month,
                                numeroDia,
                              ),
                            );
                            final bool esSeleccionado =
                                fechaDia.isAtSameMomentAs(_diaSeleccionado);
                            final bool esHoy = fechaDia.isAtSameMomentAs(hoy);
                            final List<_InfoReservaGlobal> reservasDia =
                                _obtenerReservasRealesDelDia(fechaDia);

                            return GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _diaSeleccionado = fechaDia);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                decoration: BoxDecoration(
                                  color: esSeleccionado
                                      ? const Color(0xFF4F46E5)
                                          .withValues(alpha: 0.16)
                                      : cellBg.withValues(
                                          alpha: isDark ? 0.55 : 0.75,
                                        ),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: esSeleccionado
                                        ? const Color(0xFF4F46E5)
                                        : (esHoy
                                            ? const Color(0xFF0891B2)
                                            : (isDark
                                                ? const Color(0xFF334155)
                                                : const Color(0xFFE2E8F0))),
                                    width: esSeleccionado
                                        ? 2
                                        : (esHoy ? 1.5 : 0.8),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '$numeroDia',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12.5,
                                        color: esSeleccionado
                                            ? const Color(0xFF4F46E5)
                                            : (isDark
                                                ? Colors.white
                                                : const Color(0xFF0F172A)),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    if (reservasDia.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: Wrap(
                                          alignment: WrapAlignment.center,
                                          spacing: 2.5,
                                          runSpacing: 2,
                                          children: [
                                            ...reservasDia.take(4).map(
                                                  (r) => Container(
                                                    width: 6.5,
                                                    height: 6.5,
                                                    decoration: BoxDecoration(
                                                      color: r.colorReserva,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ),
                                            if (reservasDia.length > 4)
                                              Text(
                                                '+${reservasDia.length - 4}',
                                                style: const TextStyle(
                                                  fontSize: 8,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF4F46E5),
                                                ),
                                              ),
                                          ],
                                        ),
                                      )
                                    else
                                      const SizedBox(height: 6.5),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const Divider(height: 10),
                      // Lista de Ocupación Diaria Inferior integrada
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildEncabezadoDiaSeleccionado(
                                _diaSeleccionado,
                                reservasDiaSeleccionado.length,
                                isDark,
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: reservasDiaSeleccionado.isEmpty
                                    ? _buildEstadoLibreDia(isDark)
                                    : ListView.separated(
                                        itemCount:
                                            reservasDiaSeleccionado.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (_, idx) =>
                                            _buildTarjetaOcupacionPiso(
                                          reservasDiaSeleccionado[idx],
                                          isDark,
                                          cerrarSheetAlIr: false,
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            )
          // MODO 2: VISTA DE BARRAS CON SCROLL VERTICAL EN CELDAS
          else ...[
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  childAspectRatio: 0.48,
                  crossAxisSpacing: 0,
                  mainAxisSpacing: 4,
                ),
                itemCount: diasEnMes + (diaSemanaInicio - 1),
                itemBuilder: (context, index) {
                  if (index < diaSemanaInicio - 1) {
                    return const SizedBox.shrink();
                  }

                  final int numeroDia = index - (diaSemanaInicio - 2);
                  final DateTime fechaDia = _limpiarHora(
                    DateTime(_mesActual.year, _mesActual.month, numeroDia),
                  );
                  final List<_InfoReservaGlobal> reservasDia =
                      _obtenerReservasRealesDelDia(fechaDia);

                  return GestureDetector(
                    onTap: () => _mostrarHojaDiaGlobal(fechaDia, reservasDia),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: cellBg.withValues(alpha: isDark ? 0.45 : 0.65),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0),
                          width: 0.8,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 4,
                              left: 5,
                              right: 4,
                            ),
                            child: Text(
                              '$numeroDia',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 11.5,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          // Scroll vertical habilitado para que las barras jamás se corten
                          Expanded(
                            child: SingleChildScrollView(
                              physics: const BouncingScrollPhysics(),
                              child: Column(
                                children: widget.pisos.map((piso) {
                                  final ReservaDia? res =
                                      piso.reservas[fechaDia];
                                  if (!_esVisibleEnGlobal(res)) {
                                    return const SizedBox(height: 17);
                                  }

                                  final ReservaDia resReal = res!;
                                  final Color colReserva =
                                      _obtenerColorParaReserva(resReal, piso);

                                  final DateTime diaAnt = fechaDia.subtract(
                                    const Duration(days: 1),
                                  );
                                  final DateTime diaSig = fechaDia.add(
                                    const Duration(days: 1),
                                  );

                                  final ReservaDia? resAnt =
                                      piso.reservas[diaAnt];
                                  final ReservaDia? resSig =
                                      piso.reservas[diaSig];

                                  final bool conectaAnt =
                                      _esVisibleEnGlobal(resAnt) &&
                                          resReal.perteneceAMismaEstancia(
                                            resAnt!,
                                          );
                                  final bool conectaSig =
                                      _esVisibleEnGlobal(resSig) &&
                                          resReal.perteneceAMismaEstancia(
                                            resSig!,
                                          );

                                  BorderRadius bRadius =
                                      BorderRadius.circular(7);
                                  if (conectaAnt && conectaSig) {
                                    bRadius = BorderRadius.zero;
                                  } else if (!conectaAnt && conectaSig) {
                                    bRadius = const BorderRadius.horizontal(
                                      left: Radius.circular(7),
                                    );
                                  } else if (conectaAnt && !conectaSig) {
                                    bRadius = const BorderRadius.horizontal(
                                      right: Radius.circular(7),
                                    );
                                  }

                                  return Container(
                                    height: 15,
                                    margin: EdgeInsets.only(
                                      bottom: 2,
                                      left: conectaAnt ? 0 : 2,
                                      right: conectaSig ? 0 : 2,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: colReserva,
                                      borderRadius: bRadius,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      !conectaAnt ||
                                              fechaDia.weekday == DateTime.monday
                                          ? '${piso.nombre}: ${resReal.nombreInquilino}'
                                          : '',
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
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

class _InfoReservaGlobal {
  final Piso piso;
  final ReservaDia reserva;
  final Color colorReserva;

  _InfoReservaGlobal({
    required this.piso,
    required this.reserva,
    required this.colorReserva,
  });
}
