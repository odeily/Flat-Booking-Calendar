import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/config/app_config.dart';
import '../core/constants/app_colors.dart';
import '../models/piso.dart';
import '../services/supabase_service.dart';
import '../widgets/guia_sincronizacion_modal.dart';
import 'calendario_global_screen.dart';
import 'detalle_piso_screen.dart';

/// Pantalla principal con la cartera de alojamientos del usuario.
///
/// Soporta refresco táctil (*pull-to-refresh*), creación validada de inmuebles,
/// reordenación persistente manteniendo pulsado (*drag-and-drop*) y acceso directo
/// al calendario multipropiedad.
class ListaPisosScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const ListaPisosScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<ListaPisosScreen> createState() => _ListaPisosScreenState();
}

class _ListaPisosScreenState extends State<ListaPisosScreen> {
  final List<Piso> _pisos = [];
  final _supabaseService = SupabaseService();
  bool _isLoading = true;
  bool _sincronizadoConNube = true;

  @override
  void initState() {
    super.initState();
    _cargarPisos();
  }

  Future<void> _cargarPisos({bool mostrarSpinnerPantalla = true}) async {
    if (mostrarSpinnerPantalla && mounted) {
      setState(() => _isLoading = true);
    }

    final resultado = await _supabaseService.obtenerPisosConEstado();
    if (mounted) {
      setState(() {
        _pisos
          ..clear()
          ..addAll(resultado.pisos);
        _sincronizadoConNube =
            resultado.sincronizadoConNube && resultado.pendientesSubida == 0;
        _isLoading = false;
      });
    }
  }

  Future<void> _alReordenarPisos(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        oldIndex >= _pisos.length ||
        newIndex < 0 ||
        newIndex >= _pisos.length) {
      return;
    }

    HapticFeedback.selectionClick();
    setState(() {
      final Piso movido = _pisos.removeAt(oldIndex);
      _pisos.insert(newIndex, movido);
    });

    final bool sincronizado = await _supabaseService.guardarOrdenPisos(
      List<Piso>.from(_pisos),
    );
    if (mounted && !sincronizado) {
      setState(() => _sincronizadoConNube = false);
    }
  }

  Future<void> _alRefrescarLista() async {
    HapticFeedback.lightImpact();
    await _cargarPisos(mostrarSpinnerPantalla: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        backgroundColor: _sincronizadoConNube
            ? const Color(0xFF059669)
            : const Color(0xFFD97706),
        content: Text(
          _sincronizadoConNube
              ? 'Pisos actualizados y sincronizados con la nube.'
              : 'Mostrando caché local (sin conexión con la nube).',
        ),
      ),
    );
  }

  void _mostrarHojaAnadirPiso() {
    HapticFeedback.selectionClick();
    final TextEditingController controladorPiso = TextEditingController();
    String? errorTexto;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> guardarNuevoPiso() async {
              final nuevoPisoNombre = controladorPiso.text.trim();
              if (nuevoPisoNombre.isEmpty) {
                setSheetState(
                  () => errorTexto = 'Escribe un nombre para el apartamento.',
                );
                return;
              }

              final bool pisoExiste = _pisos.any(
                (p) => p.nombre.toLowerCase() == nuevoPisoNombre.toLowerCase(),
              );

              if (pisoExiste) {
                HapticFeedback.mediumImpact();
                setSheetState(
                  () => errorTexto =
                      'Ya existe un piso llamado "$nuevoPisoNombre". Usa un nombre distinto.',
                );
                return;
              }

              HapticFeedback.lightImpact();
              Navigator.pop(sheetCtx);
              setState(() => _isLoading = true);
              final nuevoPiso = Piso(nombre: nuevoPisoNombre);
              final guardado = await _supabaseService.guardarPiso(nuevoPiso);
              if (mounted) {
                setState(() {
                  if (guardado != null) {
                    _pisos.add(guardado);
                    _sincronizadoConNube = !(guardado.id?.startsWith('local_') ?? true);
                  }
                  _isLoading = false;
                });
                if (guardado != null && _pisos.length > 1) {
                  await _supabaseService.guardarOrdenPisos(
                    List<Piso>.from(_pisos),
                  );
                }
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
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
                  const Text(
                    'Añadir nuevo piso',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Podrás conectar Airbnb y Booking nada más crearlo.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controladorPiso,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (errorTexto != null) {
                        setSheetState(() => errorTexto = null);
                      }
                    },
                    onSubmitted: (_) => guardarNuevoPiso(),
                    decoration: InputDecoration(
                      labelText: 'Nombre del piso',
                      hintText: 'Ej: Apartamento Gran Vía',
                      errorText: errorTexto,
                      prefixIcon: const Icon(Icons.home_work_outlined),
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
                          onPressed: guardarNuevoPiso,
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: const Text(
                            'Crear piso',
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
      },
    );
  }

  void _abrirCalendarioGlobal() {
    HapticFeedback.selectionClick();
    if (_pisos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Registra al menos un piso antes de abrir el calendario global.',
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CalendarioGlobalScreen(
          pisos: _pisos,
          isDarkMode: widget.isDarkMode,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _mostrarGuiaSincronizacion() {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          GuiaSincronizacionModal(isDarkMode: widget.isDarkMode),
    );
  }

  Future<void> _cerrarSesion() async {
    final confirmar = await showModalBottomSheet<bool>(
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
              'Cerrar sesión',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              '¿Deseas cerrar tu sesión actual en este dispositivo?',
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
                    onPressed: () => Navigator.pop(ctx, false),
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
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Cerrar sesión'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirmar == true) {
      await Supabase.instance.client.auth.signOut();
    }
  }

  Future<void> _eliminarCuenta() async {
    final confirmar = await showModalBottomSheet<bool>(
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
              'Eliminar cuenta definitivamente',
              style: TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Se borrarán permanentemente tu cuenta, todos tus pisos y todas tus reservas. Esta acción no tiene vuelta atrás.',
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
                    onPressed: () => Navigator.pop(ctx, false),
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
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Eliminar todo'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirmar == true) {
      setState(() => _isLoading = true);
      try {
        await Supabase.instance.client.rpc('delete_user');
        await Supabase.instance.client.auth.signOut();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al eliminar la cuenta')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = widget.isDarkMode;
    final DateTime hoy = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Flexible(
              child: Text(
                'Mis Pisos',
                style: TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: _sincronizadoConNube
                  ? 'Nube conectada'
                  : 'Pendiente de conexión a la nube',
              child: Icon(
                _sincronizadoConNube
                    ? Icons.cloud_done_rounded
                    : Icons.cloud_outlined,
                size: 18,
                color: _sincronizadoConNube
                    ? const Color(0xFF10B981)
                    : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.calendar_month_rounded,
              color: Color(0xFF4F46E5),
            ),
            tooltip: 'Calendario Global',
            onPressed: _abrirCalendarioGlobal,
          ),
          IconButton(
            icon: const Icon(
              Icons.help_outline_rounded,
              color: Color(0xFF0891B2),
            ),
            tooltip: 'Guía de Sincronización iCal',
            onPressed: _mostrarGuiaSincronizacion,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              HapticFeedback.selectionClick();
              if (value == 'theme') {
                widget.onToggleTheme();
              } else if (value == 'logout') {
                _cerrarSesion();
              } else if (value == 'delete') {
                _eliminarCuenta();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(
                      isDark
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(isDark ? 'Modo claro' : 'Modo oscuro'),
                  ],
                ),
              ),
              if (AppConfig.isSupabaseConfigured) ...[
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'logout',
                  child: Row(
                    children: [
                      Icon(Icons.logout_rounded, color: Colors.grey, size: 20),
                      SizedBox(width: 10),
                      Text('Cerrar sesión'),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_forever_rounded,
                        color: Colors.red,
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Eliminar cuenta',
                        style: TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              color: const Color(0xFF4F46E5),
              onRefresh: _alRefrescarLista,
              child: _pisos.isEmpty
                  ? LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.home_work_outlined,
                                  size: 72,
                                  color: Colors.grey.shade400,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No hay pisos registrados todavía',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Pulsa "Nuevo Piso" para empezar o desliza hacia abajo para refrescar desde la nube.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                OutlinedButton.icon(
                                  onPressed: _mostrarGuiaSincronizacion,
                                  icon: const Icon(Icons.sync_alt_rounded),
                                  label: const Text(
                                    '¿Cómo sincronizar con Airbnb y Booking?',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                      itemCount: _pisos.length,
                      onReorderStart: (_) {
                        HapticFeedback.mediumImpact();
                      },
                      onReorderItem: _alReordenarPisos,
                      header: _pisos.length > 1
                          ? Padding(
                              padding: const EdgeInsets.only(
                                bottom: 6,
                                left: 4,
                                right: 4,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.drag_indicator_rounded,
                                    size: 16,
                                    color: isDark
                                        ? Colors.white38
                                        : Colors.grey.shade500,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Mantén pulsado un piso y arrástralo para ordenarlo',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? Colors.white54
                                            : Colors.grey.shade600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : null,
                      proxyDecorator: (child, index, animation) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            final double t =
                                Curves.easeOutCubic.transform(animation.value);
                            final double scale = 1.0 + (0.025 * t);
                            return Transform.scale(
                              scale: scale,
                              child: Material(
                                type: MaterialType.transparency,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF4F46E5)
                                            .withValues(alpha: 0.22 * t),
                                        blurRadius: 18 * t,
                                        spreadRadius: 1 * t,
                                        offset: Offset(0, 6 * t),
                                      ),
                                    ],
                                  ),
                                  child: child,
                                ),
                              ),
                            );
                          },
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final Piso pisoActual = _pisos[index];
                        final String claveItem =
                            SupabaseService.claveOrdenDePiso(pisoActual);
                        final Color colorPiso = paletaColoresManuales[
                            index % paletaColoresManuales.length];

                        final bool tieneAirbnb =
                            pisoActual.urlAirbnb?.trim().isNotEmpty ?? false;
                        final bool tieneBooking =
                            pisoActual.urlBooking?.trim().isNotEmpty ?? false;
                        final int nochesFuturas = pisoActual.reservas.entries
                            .where(
                              (e) =>
                                  !e.key.isBefore(hoy) &&
                                  e.value.esReservaReal,
                            )
                            .length;

                        return ReorderableDelayedDragStartListener(
                          key: ValueKey('piso_item_$claveItem'),
                          index: index,
                          child: Card(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              leading: Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: colorPiso.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(
                                  Icons.home_rounded,
                                  color: colorPiso,
                                  size: 24,
                                ),
                              ),
                              title: Text(
                                pisoActual.nombre,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF0F172A),
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      '$nochesFuturas noche${nochesFuturas == 1 ? '' : 's'} reservada${nochesFuturas == 1 ? '' : 's'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (tieneAirbnb)
                                      _buildChipCanal('Airbnb', colorAirbnb),
                                    if (tieneBooking)
                                      _buildChipCanal('Booking', colorBooking),
                                  ],
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_pisos.length > 1) ...[
                                    Icon(
                                      Icons.drag_indicator_rounded,
                                      size: 20,
                                      color: isDark
                                          ? Colors.white30
                                          : Colors.grey.shade400,
                                    ),
                                    const SizedBox(width: 2),
                                  ],
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.grey,
                                  ),
                                ],
                              ),
                              onTap: () async {
                                HapticFeedback.selectionClick();
                                final resultado = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => DetallePisoScreen(
                                      piso: pisoActual,
                                      isDarkMode: isDark,
                                    ),
                                  ),
                                );

                                if (resultado == true) {
                                  setState(() => _isLoading = true);
                                  if (pisoActual.id != null) {
                                    await _supabaseService.eliminarPiso(
                                      pisoActual.id!,
                                    );
                                  }
                                  if (mounted) {
                                    setState(() {
                                      _pisos.remove(pisoActual);
                                      _isLoading = false;
                                    });
                                  }
                                } else if (mounted) {
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _mostrarHojaAnadirPiso,
        backgroundColor: const Color(0xFF4F46E5),
        foregroundColor: Colors.white,
        elevation: 2,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Nuevo Piso',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildChipCanal(String nombre, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 7, color: color),
          const SizedBox(width: 4),
          Text(
            nombre,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
