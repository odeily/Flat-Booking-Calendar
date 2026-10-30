import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

/// Hoja modal interactiva con la guía paso a paso de conexión bidireccional iCal
/// frente a los paneles de anfitrión de Airbnb y la Extranet de Booking.com.
class GuiaSincronizacionModal extends StatelessWidget {
  final bool isDarkMode;
  const GuiaSincronizacionModal({super.key, required this.isDarkMode});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.86,
        ),
        child: SingleChildScrollView(
          child: Column(
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
              Row(
                children: [
                  const Icon(
                    Icons.sync_alt_rounded,
                    color: Color(0xFF4F46E5),
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Sincronización Bidireccional iCal',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                        color: isDarkMode ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Conecta tus apartamentos en ambos sentidos entre la app, Airbnb y Booking sin bucles ni falsos conflictos.',
                style: TextStyle(fontSize: 13.5, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 18),

              const _TarjetaGuia(
                colorPlataforma: Color(0xFF4F46E5),
                titulo: 'Paso 1: Exportar de la App a los Portales',
                pasos: [
                  'Entra al piso y pulsa el icono de Sincronización en la barra superior.',
                  'Copia el "Enlace exclusivo para Airbnb" y pégalo en Airbnb (Calendario → Disponibilidad → Importar calendario).',
                  'Copia el "Enlace exclusivo para Booking" y pégalo en la Extranet de Booking (Tarifas y disponibilidad → Sincronizar calendarios).',
                  'Cada enlace filtra automáticamente sus propias reservas para evitar bucles de retroalimentación.',
                ],
              ),
              const SizedBox(height: 14),

              const _TarjetaGuia(
                colorPlataforma: colorAirbnb,
                titulo: 'Paso 2A: Cómo conseguir el enlace de Airbnb',
                pasos: [
                  'Entra en Airbnb en Modo Anfitrión → Calendario → selecciona tu anuncio.',
                  'Abre "Disponibilidad" (icono ⚙️) → baja hasta "Conectar calendarios" → "Conectar con otro sitio web".',
                  'En el Paso 1 verás tu enlace de Airbnb acabado en ".ics": pulsa "Copiar enlace" y pégalo en el campo Airbnb de la app.',
                  'Sus reservas reales se mostrarán siempre en Rosa (#FF385C).',
                ],
              ),
              const SizedBox(height: 14),

              const _TarjetaGuia(
                colorPlataforma: colorBooking,
                titulo: 'Paso 2B: Cómo conseguir el enlace de Booking.com',
                pasos: [
                  'Abre la Extranet en el navegador en admin.booking.com (esta opción no aparece en la app móvil Pulse).',
                  'Ve a "Tarifas y disponibilidad" (o "Calendario") → "Sincronizar calendarios" → "Añadir conexión de calendario".',
                  'En el apartado "Exportar calendario", pulsa "Copiar enlace" (empieza por https://ical.booking.com/v1/export?t=...), pégalo en la app y pulsa "Guardar y Sincronizar Ahora".',
                  'Sus reservas reales se mostrarán siempre en Azul (#003580).',
                ],
              ),
              const SizedBox(height: 14),

              const _TarjetaGuia(
                colorPlataforma: Color(0xFF059669),
                titulo: 'Motor Inteligente Anti-Conflictos',
                pasos: [
                  'Cuando bloqueas en Booking unas fechas reservadas en Airbnb (o viceversa), la reserva real prevalece automáticamente y muestra el sello de protección cruzada.',
                  'Solo recibirás una alerta crítica si ocurriera una sobreventa real (2 huéspedes distintos en la misma fecha).',
                  'Recuerda que Airbnb y Booking refrescan enlaces iCal automáticamente cada 1 a 3 horas.',
                ],
              ),
              const SizedBox(height: 22),

              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Entendido',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TarjetaGuia extends StatelessWidget {
  final Color colorPlataforma;
  final String titulo;
  final List<String> pasos;

  const _TarjetaGuia({
    required this.colorPlataforma,
    required this.titulo,
    required this.pasos,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: colorPlataforma.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorPlataforma.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colorPlataforma,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.5,
                    color: colorPlataforma,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...pasos.map(
            (paso) => Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorPlataforma,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      paso,
                      style: const TextStyle(fontSize: 12.8, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
