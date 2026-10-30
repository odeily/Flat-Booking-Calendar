/// Clasificación semántica de un evento de ocupación dentro de la matriz de prioridades.
enum TipoOcupacion {
  /// Estancia verificada con huésped, código de confirmación o reserva directa.
  /// Prevalece automáticamente sobre cualquier [bloqueoExterno].
  reservaReal,

  /// Cierre genérico de disponibilidad (`CLOSED`, `Not available`) emitido por una OTA.
  bloqueoExterno,
}
