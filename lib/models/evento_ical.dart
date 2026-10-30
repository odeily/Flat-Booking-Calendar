/// Representación tipada de un bloque `VEVENT` extraído de un flujo iCalendar (RFC 5545).
///
/// Las fechas [dtStart] (check-in inclusivo) y [dtEnd] (check-out exclusivo) se normalizan
/// a medianoche local tras desplegar posibles líneas plegadas (*line unfolding*).
class EventoICal {
  final DateTime dtStart;
  final DateTime dtEnd;
  final String summary;
  final String description;
  final String uid;

  const EventoICal({
    required this.dtStart,
    required this.dtEnd,
    required this.summary,
    this.description = '',
    required this.uid,
  });
}
