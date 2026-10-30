import 'package:flutter/material.dart';

/// Color corporativo reservado exclusivamente para reservas originadas en Airbnb.
const Color colorAirbnb = Color(0xFFFF385C);

/// Color corporativo reservado exclusivamente para reservas originadas en Booking.com.
const Color colorBooking = Color(0xFF003580);

/// Paleta curada de alto contraste para estancias manuales/directas.
///
/// Excluye deliberadamente [colorAirbnb] y [colorBooking] para garantizar que el canal
/// de origen sea distinguible de un vistazo en cualquier vista del calendario.
const List<Color> paletaColoresManuales = [
  Color(0xFF4F46E5), // Índigo moderno
  Color(0xFF059669), // Esmeralda suave
  Color(0xFFD97706), // Ámbar cálido
  Color(0xFF7C3AED), // Violeta vibrante
  Color(0xFF0891B2), // Cian turquesa
  Color(0xFFDB2777), // Magenta suave
  Color(0xFF65A30D), // Lima esmeralda
  Color(0xFFEA580C), // Naranja bermellón
  Color(0xFF0D9488), // Teal profundo
  Color(0xFF9333EA), // Púrpura suave
  Color(0xFF475569), // Slate azulado
];
