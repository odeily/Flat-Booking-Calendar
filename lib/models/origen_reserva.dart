/// Canal de distribución en el que se originó una estancia o bloqueo de calendario.
enum OrigenReserva {
  /// Reserva directa o bloqueo introducido manualmente en la aplicación.
  manual,

  /// Evento importado desde el flujo iCal de Airbnb.
  airbnb,

  /// Evento importado desde el flujo iCal de la Extranet de Booking.com.
  booking,
}
