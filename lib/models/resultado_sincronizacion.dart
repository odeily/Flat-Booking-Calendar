import 'reserva_dia.dart';

/// Detalle de una colisión de sobreventa real (*overbooking*) en una fecha concreta.
class ConflictoDiaSincronizacion {
  final DateTime dia;
  final ReservaDia reservaActual;
  final ReservaDia reservaNueva;

  const ConflictoDiaSincronizacion({
    required this.dia,
    required this.reservaActual,
    required this.reservaNueva,
  });
}

/// Resumen estructurado tras ejecutar una sincronización iCal sobre un inmueble.
///
/// Separa las actualizaciones aplicadas automáticamente de los posibles conflictos
/// reales entre dos estancias verificadas de canales distintos.
class ResultadoSincronizacion {
  final int diasSinConflicto;
  final int bloqueosCruzadosDetectados;
  final List<ConflictoDiaSincronizacion> conflictos;
  final Map<DateTime, ReservaDia> cambiosConflictivos;
  final List<String> advertenciasConexion;

  const ResultadoSincronizacion({
    required this.diasSinConflicto,
    this.bloqueosCruzadosDetectados = 0,
    required this.conflictos,
    required this.cambiosConflictivos,
    this.advertenciasConexion = const [],
  });

  /// Devuelve `true` únicamente cuando coexisten dos reservas reales opuestas en la misma noche.
  bool get hayConflictos => conflictos.isNotEmpty;
}
