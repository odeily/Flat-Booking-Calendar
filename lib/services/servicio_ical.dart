import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/config/app_config.dart';
import '../models/evento_ical.dart';
import '../models/origen_reserva.dart';
import '../models/piso.dart';
import '../models/reserva_dia.dart';
import '../models/resultado_sincronizacion.dart';

/// Resultado de diagnóstico en vivo de un enlace de calendario externo `.ics`.
class VerificacionEnlaceICal {
  final bool esValido;
  final int totalEventos;
  final int reservasReales;
  final int bloqueos;
  final String mensaje;

  const VerificacionEnlaceICal({
    required this.esValido,
    this.totalEventos = 0,
    this.reservasReales = 0,
    this.bloqueos = 0,
    required this.mensaje,
  });
}

class _SnapshotCanal {
  final Map<String, ReservaDia> porCodigo = {};
  final Map<String, ReservaDia> porUid = {};

  ReservaDia? buscarCoincidencia(EventoICal ev, String? codigoNuevo) {
    if (codigoNuevo != null && codigoNuevo.isNotEmpty) {
      final porCod = porCodigo[codigoNuevo];
      if (porCod != null) return porCod;
      // Si el evento nuevo trae un código explícito y no coincide con ninguno conocido,
      // verificar si el UID existía pero pertenecía a OTRO código distinto
      if (ev.uid.isNotEmpty) {
        final candidatoUid = porUid[ev.uid];
        if (candidatoUid != null) {
          final codViejo = candidatoUid.codigoReserva?.trim() ?? '';
          if (codViejo.isNotEmpty && codViejo != codigoNuevo) {
            return null; // Reserva distinta reutilizando contenedor
          }
          return candidatoUid;
        }
      }
      return null;
    }

    if (ev.uid.isNotEmpty) {
      return porUid[ev.uid];
    }
    return null;
  }
}

/// Motor de sincronización bidireccional y Channel Manager iCalendar (estándar RFC 5545).
///
/// Gestiona el desplegado de líneas (*line unfolding*), la decodificación UTF-8 resiliente,
/// la clasificación estricta entre reservas reales y bloqueos cruzados de disponibilidad,
/// la protección de nombres personalizados de huéspedes y la detección de sobreventas.
class ServicioICal {
  /// Endpoint base de exportación iCal resuelto desde la configuración de entorno.
  static String get baseExportUrl => AppConfig.exportIcalBaseUrl;

  static const Map<String, String> _icalHttpHeaders = {
    'Accept': 'text/calendar, text/plain, */*',
    'Cache-Control': 'no-cache',
    'User-Agent': 'CalendarioPisosChannelManager/1.1 (+RFC5545)',
  };

  /// Construye la URL de exportación iCal acabada en `.ics` en la ruta y con parámetros explícitos
  /// para máxima compatibilidad tanto con Airbnb como con la Extranet de Booking.com.
  static String construirUrlExportacion(String pisoId, {String? target}) {
    final String idLimpio = pisoId.trim();
    final String? targetLimpio =
        (target != null && target.trim().isNotEmpty)
            ? target.trim().toLowerCase()
            : null;

    final String sufijoArchivo =
        targetLimpio != null ? '_$targetLimpio' : '';
    final String pathIcs =
        '$baseExportUrl/${Uri.encodeComponent(idLimpio)}$sufijoArchivo.ics';

    final String baseQuery =
        '$pathIcs?piso_id=${Uri.encodeQueryComponent(idLimpio)}';
    if (targetLimpio != null) {
      return '$baseQuery&target=${Uri.encodeQueryComponent(targetLimpio)}';
    }
    return baseQuery;
  }

  /// Normaliza enlaces iCal convirtiendo esquemas `webcal://` o `webcals://` (habituales en iPhone/Mac) a `https://`.
  static String normalizarUrlICal(String url) {
    final limpia = url.trim();
    if (limpia.toLowerCase().startsWith('webcal://')) {
      return 'https://${limpia.substring(9)}';
    }
    if (limpia.toLowerCase().startsWith('webcals://')) {
      return 'https://${limpia.substring(10)}';
    }
    return limpia;
  }

  /// Decodifica el cuerpo HTTP en UTF-8 por defecto según RFC 5545 Sec 3.1.4
  /// (evita caracteres corruptos cuando el servidor envía `Content-Type: text/calendar` sin `charset=utf-8`).
  static String _decodificarCuerpoICal(http.Response res) {
    try {
      return utf8.decode(res.bodyBytes);
    } on FormatException {
      return latin1.decode(res.bodyBytes);
    }
  }

  /// Valida sintácticamente si una URL tiene formato válido de calendario iCal web.
  static bool validarFormatoUrlICal(String url) {
    final limpia = normalizarUrlICal(url);
    if (limpia.isEmpty) return true;
    final uri = Uri.tryParse(limpia);
    if (uri == null) return false;
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    if (uri.host.isEmpty || !uri.host.contains('.')) return false;
    return true;
  }

  /// Comprueba en vivo un enlace iCal descargando y validando su estructura RFC 5545.
  static Future<VerificacionEnlaceICal> verificarEnlace(
    String url, {
    http.Client? httpClient,
  }) async {
    final limpia = normalizarUrlICal(url);
    if (limpia.isEmpty) {
      return const VerificacionEnlaceICal(
        esValido: false,
        mensaje: 'Enlace vacío',
      );
    }
    if (!validarFormatoUrlICal(limpia)) {
      return const VerificacionEnlaceICal(
        esValido: false,
        mensaje: 'Formato de URL no válido (debe comenzar por https://)',
      );
    }

    try {
      final futureGet = httpClient != null
          ? httpClient.get(Uri.parse(limpia), headers: _icalHttpHeaders)
          : http.get(Uri.parse(limpia), headers: _icalHttpHeaders);
      final res = await futureGet.timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        return VerificacionEnlaceICal(
          esValido: false,
          mensaje: 'El servidor respondió con código HTTP ${res.statusCode}',
        );
      }
      final String cuerpo = _decodificarCuerpoICal(res);
      if (!cuerpo.toUpperCase().contains('BEGIN:VCALENDAR')) {
        return const VerificacionEnlaceICal(
          esValido: false,
          mensaje: 'La URL no devuelve un calendario iCal (.ics) válido',
        );
      }

      final eventos = parsearICal(cuerpo);
      int reales = 0;
      int bloqueos = 0;
      for (final ev in eventos) {
        if (clasificarEvento(ev) == TipoOcupacion.reservaReal) {
          reales++;
        } else {
          bloqueos++;
        }
      }

      return VerificacionEnlaceICal(
        esValido: true,
        totalEventos: eventos.length,
        reservasReales: reales,
        bloqueos: bloqueos,
        mensaje:
            'Conectado: ${eventos.length} evento(s) ($reales reserva(s), $bloqueos bloqueo(s))',
      );
    } catch (_) {
      return const VerificacionEnlaceICal(
        esValido: false,
        mensaje: 'No se pudo conectar con el servidor (revisa la URL o tu red)',
      );
    }
  }

  /// Parsea un archivo .ics respetando line unfolding y secuencias escapadas de RFC 5545.
  static List<EventoICal> parsearICal(String contenidoIcs) {
    final List<EventoICal> eventos = [];
    // RFC 5545 Sec 3.1: Desplegar líneas continuadas con espacio o tabulador
    final String desplegado = contenidoIcs.replaceAll(RegExp(r'\r?\n[ \t]'), '');
    final List<String> lineas = desplegado.split(RegExp(r'\r\n|\n|\r'));

    bool enEvento = false;
    String dtStartStr = '';
    String dtEndStr = '';
    String summaryStr = '';
    String descriptionStr = '';
    String uidStr = '';

    for (final String lineaRaw in lineas) {
      final String linea = lineaRaw.trim();
      final String lineaUpper = linea.toUpperCase();

      if (lineaUpper == 'BEGIN:VEVENT') {
        enEvento = true;
        dtStartStr = '';
        dtEndStr = '';
        summaryStr = '';
        descriptionStr = '';
        uidStr = '';
      } else if (lineaUpper == 'END:VEVENT') {
        if (enEvento && dtStartStr.isNotEmpty) {
          final DateTime? start = _parsearFecha(dtStartStr);
          DateTime? end =
              dtEndStr.isNotEmpty ? _parsearFecha(dtEndStr) : start;
          if (start != null) {
            end ??= start;
            eventos.add(EventoICal(
              dtStart: start,
              dtEnd: end,
              summary: summaryStr.isEmpty ? 'Reservado' : summaryStr,
              description: descriptionStr,
              uid: uidStr,
            ));
          }
        }
        enEvento = false;
      } else if (enEvento) {
        final int idx = linea.indexOf(':');
        if (idx != -1) {
          final String propName =
              linea.substring(0, idx).split(';').first.trim().toUpperCase();
          final String propVal = linea.substring(idx + 1).trim();

          switch (propName) {
            case 'DTSTART':
              dtStartStr = propVal;
              break;
            case 'DTEND':
              dtEndStr = propVal;
              break;
            case 'SUMMARY':
              summaryStr = _desescaparTextoICal(propVal);
              break;
            case 'DESCRIPTION':
              descriptionStr = _desescaparTextoICal(propVal);
              break;
            case 'UID':
              uidStr = propVal;
              break;
          }
        }
      }
    }
    return eventos;
  }

  static String _desescaparTextoICal(String valor) {
    return valor
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\\', '\\')
        .trim();
  }

  static DateTime? _parsearFecha(String str) {
    try {
      final String soloDigitos = str.replaceAll(RegExp(r'[^0-9]'), '');
      if (soloDigitos.length >= 8) {
        final int anio = int.parse(soloDigitos.substring(0, 4));
        final int mes = int.parse(soloDigitos.substring(4, 6));
        final int dia = int.parse(soloDigitos.substring(6, 8));
        return DateTime(anio, mes, dia);
      }
    } catch (_) {}
    return null;
  }

  /// Extrae código único de reserva si existe en DESCRIPTION (itinerario Airbnb HM..., código Booking, etc.).
  static String? extraerCodigoConfirmacion(String description) {
    if (description.trim().isEmpty) return null;

    final matchCode = RegExp(
      r'(?:Confirmation\s*Code|Código\s*de\s*confirmación|Codigo\s*de\s*confirmacion|Booking\s*ID|Reservation\s*ID|Número\s*de\s*reserva|Numero\s*de\s*reserva)\s*:\s*([A-Z0-9-]+)',
      caseSensitive: false,
    ).firstMatch(description);
    if (matchCode != null) {
      return matchCode.group(1)!.trim().toUpperCase();
    }

    final matchUrlCode = RegExp(
      r'/reservations/(?:details/)?([A-Z0-9]{8,14})',
      caseSensitive: false,
    ).firstMatch(description);
    if (matchUrlCode != null) {
      return matchUrlCode.group(1)!.trim().toUpperCase();
    }

    final matchAirbnbHm =
        RegExp(r'\b(HM[A-Z0-9]{8,12})\b').firstMatch(description);
    if (matchAirbnbHm != null) {
      return matchAirbnbHm.group(1)!.trim().toUpperCase();
    }

    return null;
  }

  /// Clasifica estrictamente un evento iCal entre reserva real verificada y bloqueo externo genérico.
  static TipoOcupacion clasificarEvento(EventoICal ev) {
    // 1. Eventos exportados por nuestra propia función Edge nunca deben tratarse como nueva reserva externa
    if (ev.uid.toLowerCase().contains('@calendariopisos')) {
      return TipoOcupacion.bloqueoExterno;
    }

    // 2. Inspeccionar DESCRIPTION en busca de metadatos verificables de reserva real
    final String desc = ev.description.trim();
    if (desc.isNotEmpty) {
      final String descLower = desc.toLowerCase();
      final bool tieneMetadatosReserva = descLower.contains('reservation url') ||
          descLower.contains('url de la reserva') ||
          descLower.contains('/reservations/') ||
          descLower.contains('confirmation code') ||
          descLower.contains('código de confirmación') ||
          descLower.contains('codigo de confirmacion') ||
          descLower.contains('phone number') ||
          descLower.contains('last 4 digits') ||
          descLower.contains('teléfono') ||
          descLower.contains('telefono') ||
          descLower.contains('itinerary') ||
          descLower.contains('itinerario') ||
          descLower.contains('booking id') ||
          descLower.contains('reservation id') ||
          descLower.contains('número de reserva') ||
          descLower.contains('numero de reserva') ||
          descLower.contains('huésped') ||
          descLower.contains('huesped') ||
          descLower.contains('guest') ||
          descLower.contains('check-in') ||
          RegExp(r'\bHM[A-Z0-9]{8,12}\b').hasMatch(desc);

      if (tieneMetadatosReserva) {
        return TipoOcupacion.reservaReal;
      }
    }

    // 3. Inspeccionar SUMMARY limpiando prefijos/sufijos de plataforma
    final String nucleo = _limpiarNombrePlataforma(ev.summary);
    if (nucleo.isEmpty) {
      final String rawLower = ev.summary.toLowerCase();
      if (_contieneSoloCierreGenerico(rawLower)) {
        return TipoOcupacion.bloqueoExterno;
      }
      return TipoOcupacion.reservaReal;
    }

    final RegExp prefijoClosed =
        RegExp(r'^(closed|cerrado|cerrada)\s*[-:–—]?\s*', caseSensitive: false);
    if (prefijoClosed.hasMatch(nucleo)) {
      final String resto = nucleo.replaceFirst(prefijoClosed, '').trim();
      if (resto.isEmpty || _esTerminoCierreGenerico(resto)) {
        return TipoOcupacion.bloqueoExterno;
      }
      return TipoOcupacion.reservaReal;
    }

    if (_esTerminoCierreGenerico(nucleo)) {
      return TipoOcupacion.bloqueoExterno;
    }

    return TipoOcupacion.reservaReal;
  }

  static String _limpiarNombrePlataforma(String summary) {
    String limpio = summary.trim();
    final RegExp envoltorioParen = RegExp(
      r'^(Airbnb|Booking\.com|Booking)\s*\((.+)\)$',
      caseSensitive: false,
    );
    final matchParen = envoltorioParen.firstMatch(limpio);
    if (matchParen != null) {
      limpio = matchParen.group(2)!.trim();
    }

    limpio = limpio
        .replaceAll(
          RegExp(r'^(Airbnb|Booking\.com|Booking)\s*[-:–—|]+\s*',
              caseSensitive: false),
          '',
        )
        .trim();
    limpio = limpio
        .replaceAll(
          RegExp(r'\s*\((Airbnb|Booking\.com|Booking)\)$',
              caseSensitive: false),
          '',
        )
        .trim();
    limpio = limpio
        .replaceAll(
          RegExp(r'\s*[-:–—|]+\s*(Airbnb|Booking\.com|Booking)$',
              caseSensitive: false),
          '',
        )
        .trim();

    if (RegExp(r'^(Airbnb|Booking\.com|Booking)$', caseSensitive: false)
        .hasMatch(limpio)) {
      return '';
    }
    return limpio;
  }

  static bool _esTerminoCierreGenerico(String texto) {
    final String lower = texto
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[()\[\].!]'), '')
        .trim();

    const Set<String> cierresExactos = {
      'not available',
      'no available',
      'unavailable',
      'closed',
      'blocked',
      'bloqueado',
      'bloqueada',
      'no disponible',
      'cerrado',
      'cerrada',
      'owner block',
      'bloqueo manual',
      'mantenimiento',
      'ocupado / reservado',
    };

    if (cierresExactos.contains(lower)) return true;

    if ((lower.contains('not available') ||
            lower.contains('unavailable') ||
            lower.contains('no disponible') ||
            lower.contains('blocked') ||
            lower.contains('bloqueado')) &&
        !lower.contains('reserved') &&
        !lower.contains('reservado')) {
      return true;
    }

    return false;
  }

  static bool _contieneSoloCierreGenerico(String rawLower) {
    return rawLower.contains('not available') ||
        rawLower.contains('unavailable') ||
        rawLower.contains('closed') ||
        rawLower.contains('blocked') ||
        rawLower.contains('bloqueado') ||
        rawLower.contains('no disponible');
  }

  static String? _extraerIdentificadorDesdeDescripcion(String description) {
    if (description.trim().isEmpty) return null;

    final matchGuest = RegExp(
      r'(?:Guest(?:\s*Name)?|Huésped|Huesped|Nombre)\s*:\s*([^\r\n]+)',
      caseSensitive: false,
    ).firstMatch(description);
    if (matchGuest != null) {
      final guest = matchGuest.group(1)!.trim();
      if (guest.isNotEmpty) return guest;
    }

    final String? codigo = extraerCodigoConfirmacion(description);
    if (codigo != null) {
      return 'Reservado #$codigo';
    }

    return null;
  }

  static String formatearTitulo(
    String summary,
    OrigenReserva origen, {
    String description = '',
    TipoOcupacion? tipo,
  }) {
    final TipoOcupacion tipoEfectivo = tipo ??
        clasificarEvento(EventoICal(
          dtStart: DateTime(2000, 1, 1),
          dtEnd: DateTime(2000, 1, 2),
          summary: summary,
          description: description,
          uid: '',
        ));

    if (tipoEfectivo == TipoOcupacion.bloqueoExterno) {
      if (origen == OrigenReserva.airbnb) return 'Bloqueado (Airbnb)';
      if (origen == OrigenReserva.booking) return 'Bloqueado (Booking)';
      return 'Bloqueado';
    }

    // Es una Reserva Real: jamás debe llamarse "Bloqueado"
    String limpio = _limpiarNombrePlataforma(summary);
    final RegExp prefijoClosed =
        RegExp(r'^(closed|cerrado|cerrada)\s*[-:–—]?\s*', caseSensitive: false);
    if (prefijoClosed.hasMatch(limpio)) {
      limpio = limpio.replaceFirst(prefijoClosed, '').trim();
    }

    final String limpioLower = limpio.toLowerCase();
    final bool esResumenGenerico = limpio.isEmpty ||
        limpioLower == 'reserved' ||
        limpioLower == 'reservado' ||
        limpioLower == 'booked' ||
        _esTerminoCierreGenerico(limpio);

    if (esResumenGenerico) {
      limpio = _extraerIdentificadorDesdeDescripcion(description) ?? 'Reservado';
    }

    if (origen == OrigenReserva.airbnb) {
      return '$limpio (Airbnb)';
    } else if (origen == OrigenReserva.booking) {
      return '$limpio (Booking)';
    }
    return limpio;
  }

  /// Determina con precisión si un evento entrante del mismo canal corresponde a la MISMA reserva existente
  /// o a una reserva DISTINTA (p. ej. tras una cancelación y nueva reserva en las mismas fechas).
  static bool _esMismaReservaMismoCanal({
    required Map<DateTime, ReservaDia> mapaReservas,
    required DateTime diaLimpio,
    required ReservaDia existente,
    required EventoICal evNuevo,
    required DateTime inicioEv,
    required DateTime finEv,
  }) {
    final String codExistente = existente.codigoReserva?.trim() ?? '';
    final String codNuevo =
        extraerCodigoConfirmacion(evNuevo.description)?.trim() ?? '';

    // 1. Si ambos tienen código de confirmación verificable, el código decide al 100%
    if (codExistente.isNotEmpty && codNuevo.isNotEmpty) {
      return codExistente == codNuevo;
    }

    // 2. Si ambos tienen UID iCal explícito, comparar UID
    final String uidExistente = existente.idEventoExt?.trim() ?? '';
    final String uidNuevo = evNuevo.uid.trim();
    if (uidExistente.isNotEmpty && uidNuevo.isNotEmpty) {
      if (uidExistente != uidNuevo) {
        return false; // Distinto UID => es otra reserva distinta
      }
      return true;
    }

    // 3. Fallback solo para registros antiguos sin UID ni código: comparar límites exactos de la estancia
    DateTime startBound = diaLimpio;
    while (mapaReservas
            .containsKey(startBound.subtract(const Duration(days: 1))) &&
        existente.perteneceAMismaEstancia(
            mapaReservas[startBound.subtract(const Duration(days: 1))]!)) {
      startBound = startBound.subtract(const Duration(days: 1));
    }
    DateTime endBound = diaLimpio;
    while (mapaReservas.containsKey(endBound.add(const Duration(days: 1))) &&
        existente.perteneceAMismaEstancia(
            mapaReservas[endBound.add(const Duration(days: 1))]!)) {
      endBound = endBound.add(const Duration(days: 1));
    }

    return startBound.isAtSameMomentAs(inicioEv) &&
        endBound.isAtSameMomentAs(finEv);
  }

  static _SnapshotCanal _construirSnapshotCanal(Piso piso, OrigenReserva canal) {
    final snapshot = _SnapshotCanal();
    for (final res in piso.reservas.values) {
      if (res.origen != canal) continue;

      bool mejoraSnapshot(ReservaDia? previo, ReservaDia candidato) {
        if (previo == null) return true;
        if (!previo.nombrePersonalizado && candidato.nombrePersonalizado) {
          return true;
        }
        if (!previo.tieneNombrePersonalizado &&
            candidato.tieneNombrePersonalizado) {
          return true;
        }
        if (previo.esBloqueoExterno && candidato.esReservaReal) {
          return true;
        }
        return false;
      }

      final String cod = res.codigoReserva?.trim() ?? '';
      if (cod.isNotEmpty && mejoraSnapshot(snapshot.porCodigo[cod], res)) {
        snapshot.porCodigo[cod] = res;
      }

      final String uid = res.idEventoExt?.trim() ?? '';
      if (uid.isNotEmpty && mejoraSnapshot(snapshot.porUid[uid], res)) {
        snapshot.porUid[uid] = res;
      }
    }
    return snapshot;
  }

  static Future<ResultadoSincronizacion> sincronizarPiso(
    Piso piso, {
    String? urlAirbnb,
    String? urlBooking,
    String? contenidoManual,
    OrigenReserva? origenManual,
    DateTime? fechaReferencia,
    http.Client? httpClient,
  }) async {
    List<EventoICal> eventosAirbnb = [];
    List<EventoICal> eventosBooking = [];
    List<EventoICal> eventosManual = [];
    final List<String> advertenciasConexion = [];

    bool airbnbFeedCompleto = false;
    bool bookingFeedCompleto = false;

    final DateTime ref = fechaReferencia ?? DateTime.now();
    final DateTime hoy = DateTime(ref.year, ref.month, ref.day);

    Future<(List<EventoICal>, bool)> obtenerEventos(
      String url,
      String nombreCanal,
    ) async {
      try {
        final String urlNormalizada = normalizarUrlICal(url);
        final futureGet = httpClient != null
            ? httpClient.get(Uri.parse(urlNormalizada), headers: _icalHttpHeaders)
            : http.get(Uri.parse(urlNormalizada), headers: _icalHttpHeaders);
        final res = await futureGet.timeout(const Duration(seconds: 10));
        final String cuerpo = _decodificarCuerpoICal(res);
        if (res.statusCode == 200 &&
            cuerpo.toUpperCase().contains('BEGIN:VCALENDAR')) {
          return (parsearICal(cuerpo), true);
        }
        advertenciasConexion.add(
          'No se pudo validar el feed de $nombreCanal (HTTP ${res.statusCode}).',
        );
      } catch (_) {
        advertenciasConexion.add(
          'Tiempo agotado o sin conexión al consultar $nombreCanal.',
        );
      }
      return (<EventoICal>[], false);
    }

    if (urlAirbnb != null && urlAirbnb.trim().isNotEmpty) {
      final (evs, ok) = await obtenerEventos(urlAirbnb.trim(), 'Airbnb');
      eventosAirbnb = evs;
      airbnbFeedCompleto = ok;
    }
    if (urlBooking != null && urlBooking.trim().isNotEmpty) {
      final (evs, ok) = await obtenerEventos(urlBooking.trim(), 'Booking');
      eventosBooking = evs;
      bookingFeedCompleto = ok;
    }

    bool manualFeedCompleto = false;
    if (contenidoManual != null &&
        contenidoManual.trim().isNotEmpty &&
        origenManual != null) {
      eventosManual = parsearICal(contenidoManual);
      manualFeedCompleto =
          contenidoManual.toUpperCase().contains('BEGIN:VCALENDAR');
    }

    // Capturar snapshots de identidades/nombres personalizados ANTES de reconciliar
    final _SnapshotCanal snapshotAirbnb =
        _construirSnapshotCanal(piso, OrigenReserva.airbnb);
    final _SnapshotCanal snapshotBooking =
        _construirSnapshotCanal(piso, OrigenReserva.booking);
    final _SnapshotCanal? snapshotManual =
        origenManual != null ? _construirSnapshotCanal(piso, origenManual) : null;

    // Mapa auxiliar para conservar bloqueos cruzados cuando una reserva se sustituye por otra distinta del mismo canal
    final Map<DateTime, Set<OrigenReserva>> bloqueosHeredados = {};

    /// Reconcilia fechas desde `hoy` en adelante para un canal cuyo VCALENDAR completo se ha recibido:
    /// - Elimina estancias/bloqueos cancelados o acortados en la web.
    /// - Prepara sustitución limpia si en las mismas fechas ha entrado una reserva DISTINTA.
    /// - Conserva intacto el histórico pasado (`fecha < hoy`) y las reservas de otros canales.
    void reconciliarCanal(List<EventoICal> eventosCanal, OrigenReserva canal) {
      final Map<DateTime, (EventoICal, DateTime, DateTime, TipoOcupacion)>
          mapaActivos = {};

      for (final ev in eventosCanal) {
        DateTime temp = ev.dtStart;
        DateTime fin = ev.dtEnd;
        if (fin.isBefore(temp) || fin.isAtSameMomentAs(temp)) {
          fin = temp.add(const Duration(days: 1));
        }
        final DateTime inicioEv = DateTime(temp.year, temp.month, temp.day);
        final DateTime finEv = DateTime(fin.year, fin.month, fin.day)
            .subtract(const Duration(days: 1));
        final TipoOcupacion tipoEv = clasificarEvento(ev);

        while (temp.isBefore(fin)) {
          final DateTime dia = DateTime(temp.year, temp.month, temp.day);
          final existenteEnMapa = mapaActivos[dia];
          // Si un mismo feed trae bloqueo y reserva real en el mismo día, priorizar reservaReal
          if (existenteEnMapa == null ||
              (existenteEnMapa.$4 == TipoOcupacion.bloqueoExterno &&
                  tipoEv == TipoOcupacion.reservaReal)) {
            mapaActivos[dia] = (ev, inicioEv, finEv, tipoEv);
          }
          temp = temp.add(const Duration(days: 1));
        }
      }

      final List<DateTime> diasAEliminar = [];
      final Map<DateTime, ReservaDia> actualizaciones = {};

      for (final entry in piso.reservas.entries) {
        final DateTime fecha = entry.key;
        final ReservaDia res = entry.value;

        // Nunca borrar histórico pasado que las OTAs ya no exportan
        if (fecha.isBefore(hoy)) continue;

        final activo = mapaActivos[fecha];

        if (res.origen == canal) {
          if (activo == null) {
            // Esta fecha fue cancelada, acortada o desbloqueada en el portal
            if (res.canalesBloqueados.isEmpty) {
              diasAEliminar.add(fecha);
            } else {
              final otroCanal = res.canalesBloqueados.first;
              final restantes = Set<OrigenReserva>.from(res.canalesBloqueados)
                ..remove(otroCanal);
              actualizaciones[fecha] = ReservaDia(
                nombreInquilino: formatearTitulo(
                  'Not available',
                  otroCanal,
                  tipo: TipoOcupacion.bloqueoExterno,
                ),
                origen: otroCanal,
                tipoOcupacion: TipoOcupacion.bloqueoExterno,
                canalesBloqueados: restantes,
                sincronizadoEnCanalOpuesto: false,
              );
            }
          } else {
            final (evNuevo, inicioEv, finEv, _) = activo;
            final bool mismaReserva = _esMismaReservaMismoCanal(
              mapaReservas: piso.reservas,
              diaLimpio: fecha,
              existente: res,
              evNuevo: evNuevo,
              inicioEv: inicioEv,
              finEv: finEv,
            );

            if (!mismaReserva) {
              // Ha entrado una reserva DISTINTA en esta fecha del mismo canal:
              // retirar la antigua para que entre limpia con "Reservado..." sin arrastrar el nombre del inquilino anterior
              if (res.canalesBloqueados.isNotEmpty) {
                bloqueosHeredados[fecha] =
                    Set<OrigenReserva>.from(res.canalesBloqueados);
              }
              diasAEliminar.add(fecha);
            }
          }
        } else if (res.canalesBloqueados.contains(canal) && activo == null) {
          // El otro canal ya no bloquea esta fecha
          final nuevosBloqueos = Set<OrigenReserva>.from(res.canalesBloqueados)
            ..remove(canal);
          actualizaciones[fecha] = res.copyWith(
            canalesBloqueados: nuevosBloqueos,
            sincronizadoEnCanalOpuesto: nuevosBloqueos.isNotEmpty,
          );
        }
      }

      for (final d in diasAEliminar) {
        piso.reservas.remove(d);
      }
      piso.reservas.addAll(actualizaciones);

      // Si otro canal dejó bloqueos heredados y este canal ya no bloquea esa fecha, depurarlos
      for (final entry in bloqueosHeredados.entries) {
        if (!entry.key.isBefore(hoy) && !mapaActivos.containsKey(entry.key)) {
          entry.value.remove(canal);
        }
      }
    }

    if (airbnbFeedCompleto) {
      reconciliarCanal(eventosAirbnb, OrigenReserva.airbnb);
    }
    if (bookingFeedCompleto) {
      reconciliarCanal(eventosBooking, OrigenReserva.booking);
    }
    if (manualFeedCompleto && origenManual != null && origenManual != OrigenReserva.manual) {
      reconciliarCanal(eventosManual, origenManual);
    }

    int diasSinConflicto = 0;
    int bloqueosCruzados = 0;
    final List<ConflictoDiaSincronizacion> listaConflictos = [];
    final Map<DateTime, ReservaDia> cambiosConflictivos = {};

    void procesarEventos(
      List<EventoICal> eventos,
      OrigenReserva origen,
      _SnapshotCanal? snapshot,
    ) {
      final Map<DateTime, ReservaDia> mapaReferenciaCanal =
          Map<DateTime, ReservaDia>.from(piso.reservas);

      for (final ev in eventos) {
        DateTime temp = ev.dtStart;
        DateTime fin = ev.dtEnd;

        if (fin.isBefore(temp) || fin.isAtSameMomentAs(temp)) {
          fin = temp.add(const Duration(days: 1));
        }

        final String? codigoNuevo = extraerCodigoConfirmacion(ev.description);
        final ReservaDia? previaMismaReserva =
            snapshot?.buscarCoincidencia(ev, codigoNuevo);

        final TipoOcupacion tipoRaw = clasificarEvento(ev);
        final String tituloRaw = formatearTitulo(
          ev.summary,
          origen,
          description: ev.description,
          tipo: tipoRaw,
        );

        // Si ya conocíamos esta MISMA reserva (mismo código o mismo UID), preservar el nombre
        // personalizado asignado por el anfitrión (incluso si la estancia amplió o movió fechas en la web).
        final TipoOcupacion tipoNuevo =
            (previaMismaReserva != null && previaMismaReserva.esReservaReal)
                ? TipoOcupacion.reservaReal
                : tipoRaw;

        String tituloEfectivo = tituloRaw;
        bool personalizadoEfectivo = false;

        if (previaMismaReserva != null) {
          if (previaMismaReserva.nombrePersonalizado) {
            tituloEfectivo = previaMismaReserva.nombreInquilino;
            personalizadoEfectivo = true;
          } else if (!ReservaDia.esNombreGenericoAutomatico(
                  previaMismaReserva.nombreInquilino) &&
              ReservaDia.esNombreGenericoAutomatico(tituloRaw)) {
            tituloEfectivo = previaMismaReserva.nombreInquilino;
          } else if (previaMismaReserva.esReservaReal &&
              tipoRaw == TipoOcupacion.bloqueoExterno) {
            tituloEfectivo = previaMismaReserva.nombreInquilino;
          }
        }

        final DateTime inicioEv = DateTime(temp.year, temp.month, temp.day);
        final DateTime finEv = DateTime(fin.year, fin.month, fin.day)
            .subtract(const Duration(days: 1));

        while (temp.isBefore(fin)) {
          final DateTime diaLimpio = DateTime(temp.year, temp.month, temp.day);

          if (!piso.reservas.containsKey(diaLimpio)) {
            final Set<OrigenReserva> heredados =
                bloqueosHeredados[diaLimpio] ?? const {};
            piso.reservas[diaLimpio] = ReservaDia(
              nombreInquilino: tituloEfectivo,
              origen: origen,
              tipoOcupacion: tipoNuevo,
              idEventoExt: ev.uid.isNotEmpty ? ev.uid : null,
              codigoReserva: codigoNuevo,
              nombrePersonalizado: personalizadoEfectivo,
              sincronizadoEnCanalOpuesto:
                  tipoNuevo == TipoOcupacion.reservaReal && heredados.isNotEmpty,
              canalesBloqueados: heredados,
            );
            diasSinConflicto++;
          } else {
            final ReservaDia existente = piso.reservas[diaLimpio]!;

            // CASO 1: Evento del MISMO canal que ya existía en el calendario
            if (existente.origen == origen) {
              final bool esMismoEvento = _esMismaReservaMismoCanal(
                mapaReservas: mapaReferenciaCanal,
                diaLimpio: diaLimpio,
                existente: existente,
                evNuevo: ev,
                inicioEv: inicioEv,
                finEv: finEv,
              );

              if (esMismoEvento) {
                final TipoOcupacion tipoPreservado = existente.esReservaReal
                    ? TipoOcupacion.reservaReal
                    : tipoNuevo;

                String nombrePreservado;
                bool siguePersonalizado = existente.nombrePersonalizado;
                if (existente.nombrePersonalizado) {
                  // El anfitrión ya asignó el nombre del huésped -> NUNCA sobrescribir con marcador genérico
                  nombrePreservado = existente.nombreInquilino;
                  siguePersonalizado = true;
                } else if (personalizadoEfectivo) {
                  // Otro día de esta misma reserva ya tenía nombre personalizado -> unificar estancia
                  nombrePreservado = tituloEfectivo;
                  siguePersonalizado = true;
                } else if (!ReservaDia.esNombreGenericoAutomatico(
                    tituloEfectivo)) {
                  nombrePreservado = tituloEfectivo;
                } else if (!ReservaDia.esNombreGenericoAutomatico(
                    existente.nombreInquilino)) {
                  nombrePreservado = existente.nombreInquilino;
                } else if (existente.esBloqueoExterno &&
                    tipoNuevo == TipoOcupacion.reservaReal) {
                  nombrePreservado = tituloEfectivo;
                } else {
                  nombrePreservado = existente.nombreInquilino;
                }

                piso.reservas[diaLimpio] = existente.copyWith(
                  nombreInquilino: nombrePreservado,
                  tipoOcupacion: tipoPreservado,
                  idEventoExt:
                      ev.uid.isNotEmpty ? ev.uid : existente.idEventoExt,
                  codigoReserva: codigoNuevo ?? existente.codigoReserva,
                  nombrePersonalizado: siguePersonalizado,
                );
              } else {
                // Mismo canal, DISTINTA reserva
                if (existente.esReservaReal &&
                    tipoNuevo == TipoOcupacion.bloqueoExterno) {
                  // Un bloqueo suelto del mismo canal no pisa una reserva real activa
                } else {
                  // Reserva nueva distinta en el mismo canal -> Sobrescribe con "Reservado..." (o nombre nuevo)
                  piso.reservas[diaLimpio] = ReservaDia(
                    nombreInquilino: tituloEfectivo,
                    origen: origen,
                    tipoOcupacion: tipoNuevo,
                    idEventoExt: ev.uid.isNotEmpty ? ev.uid : null,
                    codigoReserva: codigoNuevo,
                    nombrePersonalizado: personalizadoEfectivo,
                    sincronizadoEnCanalOpuesto:
                        tipoNuevo == TipoOcupacion.reservaReal &&
                            existente.canalesBloqueados.isNotEmpty,
                    canalesBloqueados: existente.canalesBloqueados,
                  );
                  diasSinConflicto++;
                }
              }
            }
            // CASO 2: Eventos de CANALES DISTINTOS -> MATRIZ ESTRICTA DE PRIORIDAD
            else {
              if (existente.esReservaReal &&
                  tipoNuevo == TipoOcupacion.bloqueoExterno) {
                // JERARQUÍA: Reserva Real (Airbnb, Booking o Manual) > Bloqueo Externo
                final nuevosBloqueos =
                    Set<OrigenReserva>.from(existente.canalesBloqueados)
                      ..add(origen);
                piso.reservas[diaLimpio] = existente.copyWith(
                  sincronizadoEnCanalOpuesto: true,
                  canalesBloqueados: nuevosBloqueos,
                );
                bloqueosCruzados++;
              } else if (existente.esBloqueoExterno &&
                  tipoNuevo == TipoOcupacion.reservaReal) {
                // JERARQUÍA: Llega una Reserva Real sobre un Bloqueo Externo previo -> Sobrescribe automáticamente sin conflicto
                final nuevosBloqueos =
                    Set<OrigenReserva>.from(existente.canalesBloqueados)
                      ..add(existente.origen)
                      ..remove(origen);
                piso.reservas[diaLimpio] = ReservaDia(
                  nombreInquilino: tituloEfectivo,
                  origen: origen,
                  tipoOcupacion: TipoOcupacion.reservaReal,
                  idEventoExt: ev.uid.isNotEmpty ? ev.uid : null,
                  codigoReserva: codigoNuevo,
                  nombrePersonalizado: personalizadoEfectivo,
                  sincronizadoEnCanalOpuesto: nuevosBloqueos.isNotEmpty,
                  canalesBloqueados: nuevosBloqueos,
                );
                diasSinConflicto++;
                bloqueosCruzados++;
              } else if (existente.esBloqueoExterno &&
                  tipoNuevo == TipoOcupacion.bloqueoExterno) {
                // Ambos son bloqueos externos vacíos -> Unificar sin conflicto
                final nuevosBloqueos =
                    Set<OrigenReserva>.from(existente.canalesBloqueados)
                      ..add(origen);
                piso.reservas[diaLimpio] = existente.copyWith(
                  canalesBloqueados: nuevosBloqueos,
                );
              } else {
                // ÚNICO CASO DE CONFLICTO REAL (OVERBOOKING):
                // Coexisten dos reservas reales verificadas de canales distintos en la misma fecha.
                final ReservaDia nuevaRes = ReservaDia(
                  nombreInquilino: tituloEfectivo,
                  origen: origen,
                  tipoOcupacion: TipoOcupacion.reservaReal,
                  idEventoExt: ev.uid.isNotEmpty ? ev.uid : null,
                  codigoReserva: codigoNuevo,
                  nombrePersonalizado: personalizadoEfectivo,
                );

                listaConflictos.removeWhere(
                    (c) => c.dia.isAtSameMomentAs(diaLimpio));
                listaConflictos.add(ConflictoDiaSincronizacion(
                  dia: diaLimpio,
                  reservaActual: existente,
                  reservaNueva: nuevaRes,
                ));
                cambiosConflictivos[diaLimpio] = nuevaRes;
              }
            }
          }

          temp = temp.add(const Duration(days: 1));
        }
      }
    }

    procesarEventos(eventosAirbnb, OrigenReserva.airbnb, snapshotAirbnb);
    procesarEventos(eventosBooking, OrigenReserva.booking, snapshotBooking);
    if (origenManual != null && eventosManual.isNotEmpty) {
      procesarEventos(eventosManual, origenManual, snapshotManual);
    }

    listaConflictos.sort((a, b) => a.dia.compareTo(b.dia));
    piso.ultimaSincronizacion = DateTime.now();

    return ResultadoSincronizacion(
      diasSinConflicto: diasSinConflicto,
      bloqueosCruzadosDetectados: bloqueosCruzados,
      conflictos: listaConflictos,
      cambiosConflictivos: cambiosConflictivos,
      advertenciasConexion: advertenciasConexion,
    );
  }
}
