import 'origen_reserva.dart';
import 'tipo_ocupacion.dart';

export 'tipo_ocupacion.dart';

/// Modelo inmutable de ocupación para una noche concreta dentro del calendario de un piso.
///
/// Conserva la trazabilidad completa del evento: canal de origen ([origen]), clasificación
/// semántica ([tipoOcupacion]), identificadores externos ([idEventoExt], [codigoReserva]),
/// protección de nombre personalizado ([nombrePersonalizado]) y estado de bloqueo cruzado
/// en portales opuestos ([sincronizadoEnCanalOpuesto], [canalesBloqueados]).
class ReservaDia {
  final String nombreInquilino;
  final OrigenReserva origen;
  final TipoOcupacion tipoOcupacion;
  final String? idEventoExt;
  final String? codigoReserva;
  final bool nombrePersonalizado;
  final bool sincronizadoEnCanalOpuesto;
  final Set<OrigenReserva> canalesBloqueados;
  final String? bloqueoExtra;

  ReservaDia({
    required this.nombreInquilino,
    this.origen = OrigenReserva.manual,
    this.tipoOcupacion = TipoOcupacion.reservaReal,
    this.idEventoExt,
    this.codigoReserva,
    bool? nombrePersonalizado,
    this.sincronizadoEnCanalOpuesto = false,
    Set<OrigenReserva>? canalesBloqueados,
    this.bloqueoExtra,
  })  : nombrePersonalizado = nombrePersonalizado ??
            (origen == OrigenReserva.manual
                ? !esNombreGenericoAutomatico(nombreInquilino)
                : false),
        canalesBloqueados =
            Set<OrigenReserva>.unmodifiable(canalesBloqueados ?? const {});

  bool get esReservaReal => tipoOcupacion == TipoOcupacion.reservaReal;
  bool get esBloqueoExterno => tipoOcupacion == TipoOcupacion.bloqueoExterno;

  /// Determina si la reserva ya tiene un nombre real/personalizado puesto por el anfitrión
  /// (incluso para registros antiguos cargados sin el booleano explícito).
  bool get tieneNombrePersonalizado =>
      nombrePersonalizado || !esNombreGenericoAutomatico(nombreInquilino);

  /// Detecta si un título corresponde a un marcador genérico automático ("Reservado", "Bloqueado", etc.)
  /// frente al nombre real de una persona.
  static bool esNombreGenericoAutomatico(String nombre) {
    String limpio = nombre.trim();
    if (limpio.isEmpty) return true;

    // Retirar sufijos de canal como "(Airbnb)" o "(Booking)"
    limpio = limpio
        .replaceAll(
          RegExp(r'\s*\((Airbnb|Booking\.com|Booking)\)$', caseSensitive: false),
          '',
        )
        .trim();

    final String lower = limpio.toLowerCase();
    if (lower.isEmpty ||
        lower == 'reservado' ||
        lower == 'reserved' ||
        lower == 'booked' ||
        lower == 'ocupado' ||
        lower == 'ocupado / reservado' ||
        lower == 'bloqueado' ||
        lower == 'bloqueada' ||
        lower == 'blocked' ||
        lower == 'closed' ||
        lower == 'not available' ||
        lower == 'unavailable' ||
        lower == 'no disponible') {
      return true;
    }

    // Marcadores automáticos con código (ej: "Reservado #HMA1B2C3D4") o bloqueos
    if (RegExp(r'^reservado\s*#[a-z0-9-]+$', caseSensitive: false)
        .hasMatch(limpio)) {
      return true;
    }
    if (lower.startsWith('bloqueado') ||
        lower.startsWith('closed - not available')) {
      return true;
    }

    return false;
  }

  /// Etiqueta legible para mostrar en la interfaz el estado de protección/bloqueo cruzado.
  String? get etiquetaSincronizacion {
    if (!esReservaReal) return null;
    if (!sincronizadoEnCanalOpuesto &&
        canalesBloqueados.isEmpty &&
        bloqueoExtra == null) {
      return null;
    }

    if (origen == OrigenReserva.airbnb) {
      return 'Sincronizado / Bloqueado en Booking';
    }
    if (origen == OrigenReserva.booking) {
      return 'Sincronizado / Bloqueado en Airbnb';
    }

    // Reserva manual protegida en las OTAs
    final tieneAirbnb = canalesBloqueados.contains(OrigenReserva.airbnb);
    final tieneBooking = canalesBloqueados.contains(OrigenReserva.booking);
    if (tieneAirbnb && tieneBooking) {
      return 'Protegida en OTAs (Airbnb y Booking)';
    } else if (tieneAirbnb) {
      return 'Protegida en OTAs (Bloqueado en Airbnb)';
    } else if (tieneBooking) {
      return 'Protegida en OTAs (Bloqueado en Booking)';
    }
    return 'Protegida en las OTAs';
  }

  /// Determina si dos días adyacentes pertenecen a la misma estancia continua.
  bool perteneceAMismaEstancia(ReservaDia otra) {
    if (origen != otra.origen || tipoOcupacion != otra.tipoOcupacion) {
      return false;
    }
    final codA = codigoReserva?.trim() ?? '';
    final codB = otra.codigoReserva?.trim() ?? '';
    if (codA.isNotEmpty && codB.isNotEmpty) {
      return codA == codB;
    }
    final idA = idEventoExt?.trim() ?? '';
    final idB = otra.idEventoExt?.trim() ?? '';
    if (idA.isNotEmpty && idB.isNotEmpty) {
      return idA == idB;
    }
    return nombreInquilino == otra.nombreInquilino;
  }

  ReservaDia copyWith({
    String? nombreInquilino,
    OrigenReserva? origen,
    TipoOcupacion? tipoOcupacion,
    String? idEventoExt,
    String? codigoReserva,
    bool? nombrePersonalizado,
    bool? sincronizadoEnCanalOpuesto,
    Set<OrigenReserva>? canalesBloqueados,
    String? bloqueoExtra,
  }) {
    final String nuevoNombre = nombreInquilino ?? this.nombreInquilino;
    final bool nuevoPersonalizado = nombrePersonalizado ??
        (nombreInquilino != null && nombreInquilino != this.nombreInquilino
            ? !esNombreGenericoAutomatico(nuevoNombre)
            : this.nombrePersonalizado);

    return ReservaDia(
      nombreInquilino: nuevoNombre,
      origen: origen ?? this.origen,
      tipoOcupacion: tipoOcupacion ?? this.tipoOcupacion,
      idEventoExt: idEventoExt ?? this.idEventoExt,
      codigoReserva: codigoReserva ?? this.codigoReserva,
      nombrePersonalizado: nuevoPersonalizado,
      sincronizadoEnCanalOpuesto:
          sincronizadoEnCanalOpuesto ?? this.sincronizadoEnCanalOpuesto,
      canalesBloqueados: canalesBloqueados ?? this.canalesBloqueados,
      bloqueoExtra: bloqueoExtra ?? this.bloqueoExtra,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'nombreInquilino': nombreInquilino,
      'origen': origen.name,
      'tipoOcupacion': tipoOcupacion.name,
      'idEventoExt': idEventoExt,
      if (codigoReserva != null) 'codigoReserva': codigoReserva,
      'nombrePersonalizado': nombrePersonalizado,
      'sincronizadoEnCanalOpuesto': sincronizadoEnCanalOpuesto,
      'canalesBloqueados': canalesBloqueados.map((c) => c.name).toList(),
      if (bloqueoExtra != null) 'bloqueoExtra': bloqueoExtra,
    };
  }

  factory ReservaDia.fromJson(Map<String, dynamic> json) {
    final String nombre = (json['nombreInquilino'] as String?) ?? 'Reservado';
    final OrigenReserva origen = OrigenReserva.values.firstWhere(
      (e) => e.name == json['origen'],
      orElse: () => OrigenReserva.manual,
    );

    // Compatibilidad retroactiva con registros previos sin 'tipoOcupacion'
    TipoOcupacion tipo;
    if (json['tipoOcupacion'] != null) {
      tipo = TipoOcupacion.values.firstWhere(
        (e) => e.name == json['tipoOcupacion'],
        orElse: () => TipoOcupacion.reservaReal,
      );
    } else {
      tipo = _inferirTipoDesdeNombreLegacy(nombre, origen);
    }

    final Set<OrigenReserva> bloqueados = {};
    if (json['canalesBloqueados'] is List) {
      for (final item in (json['canalesBloqueados'] as List)) {
        for (final val in OrigenReserva.values) {
          if (val.name == item) {
            bloqueados.add(val);
          }
        }
      }
    }

    final String? bloqueoLegacy = json['bloqueoExtra'] as String?;
    if (bloqueados.isEmpty &&
        bloqueoLegacy != null &&
        bloqueoLegacy.isNotEmpty) {
      final lower = bloqueoLegacy.toLowerCase();
      if (lower.contains('airbnb')) bloqueados.add(OrigenReserva.airbnb);
      if (lower.contains('booking')) bloqueados.add(OrigenReserva.booking);
    }

    final bool sincronizado = (json['sincronizadoEnCanalOpuesto'] as bool?) ??
        (tipo == TipoOcupacion.reservaReal &&
            (bloqueados.isNotEmpty ||
                (bloqueoLegacy != null && bloqueoLegacy.isNotEmpty)));

    final bool personalizado = (json['nombrePersonalizado'] as bool?) ??
        (tipo == TipoOcupacion.reservaReal &&
            !esNombreGenericoAutomatico(nombre));

    return ReservaDia(
      nombreInquilino: nombre,
      origen: origen,
      tipoOcupacion: tipo,
      idEventoExt: json['idEventoExt'] as String?,
      codigoReserva: json['codigoReserva'] as String?,
      nombrePersonalizado: personalizado,
      sincronizadoEnCanalOpuesto: sincronizado,
      canalesBloqueados: bloqueados,
      bloqueoExtra: bloqueoLegacy,
    );
  }

  static TipoOcupacion _inferirTipoDesdeNombreLegacy(
    String nombre,
    OrigenReserva origen,
  ) {
    if (origen == OrigenReserva.manual) {
      return TipoOcupacion.reservaReal;
    }
    final n = nombre.trim().toLowerCase();
    if (n.startsWith('bloqueado') ||
        n.contains('not available') ||
        n.contains('unavailable') ||
        n.contains('no disponible') ||
        n == 'closed' ||
        n.startsWith('closed - not available')) {
      return TipoOcupacion.bloqueoExterno;
    }
    return TipoOcupacion.reservaReal;
  }
}
