import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_alquiler_jefe/models/origen_reserva.dart';
import 'package:app_alquiler_jefe/models/piso.dart';
import 'package:app_alquiler_jefe/models/reserva_dia.dart';
import 'package:app_alquiler_jefe/screens/calendario_global_screen.dart';
import 'package:app_alquiler_jefe/screens/detalle_piso_screen.dart';
import 'package:app_alquiler_jefe/services/servicio_ical.dart';

void main() {
  group('Motor de Prioridades iCal RFC 5545 y Escenarios de Reconciliación', () {
    test('Clasificación RFC 5545 con líneas plegadas (unfolding) y DESCRIPTION', () {
      const icsAirbnb = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'BEGIN:VEVENT\r\n'
          'DTSTART;VALUE=DATE:20261110\r\n'
          'DTEND;VALUE=DATE:20261113\r\n'
          'UID:7f881122@airbnb.com\r\n'
          'SUMMARY:Reserved\r\n'
          'DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/\r\n'
          ' details/HMA1B2C3D4\\nPhone Number (Last 4 Digits): 9876\r\n'
          'END:VEVENT\r\n'
          'BEGIN:VEVENT\r\n'
          'DTSTART;VALUE=DATE:20261120\r\n'
          'DTEND;VALUE=DATE:20261122\r\n'
          'UID:block-999@airbnb.com\r\n'
          'SUMMARY:Airbnb (Not available)\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';

      final eventos = ServicioICal.parsearICal(icsAirbnb);
      expect(eventos.length, 2);

      // Evento 1: Reserva real con código desplegado desde DESCRIPTION
      expect(ServicioICal.clasificarEvento(eventos[0]), TipoOcupacion.reservaReal);
      final tituloReal = ServicioICal.formatearTitulo(
        eventos[0].summary,
        OrigenReserva.airbnb,
        description: eventos[0].description,
      );
      expect(tituloReal, 'Reservado #HMA1B2C3D4 (Airbnb)');
      expect(tituloReal.contains('Bloqueado'), isFalse);

      // Evento 2: Bloqueo vacío
      expect(ServicioICal.clasificarEvento(eventos[1]), TipoOcupacion.bloqueoExterno);
      expect(
        ServicioICal.formatearTitulo(eventos[1].summary, OrigenReserva.airbnb),
        'Bloqueado (Airbnb)',
      );
    });

    test('Escenario 1: Reserva real en Airbnb + Bloqueo en Booking -> Cero conflictos y sello en Booking', () async {
      final piso = Piso(id: 'uuid-1', nombre: 'Piso Sol');

      const icsAirbnb = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:res-airbnb-1@airbnb.com
DTSTART;VALUE=DATE:20261201
DTEND;VALUE=DATE:20261204
SUMMARY:Reserved
DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HM11223344
END:VEVENT
END:VCALENDAR
''';

      const icsBookingBloqueo = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:closed-booking-1@booking.com
DTSTART;VALUE=DATE:20261201
DTEND;VALUE=DATE:20261204
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final r1 = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnb,
        origenManual: OrigenReserva.airbnb,
      );
      expect(r1.hayConflictos, isFalse);

      final r2 = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBookingBloqueo,
        origenManual: OrigenReserva.booking,
      );
      expect(r2.hayConflictos, isFalse);

      final dia = DateTime(2026, 12, 1);
      final res = piso.reservas[dia]!;
      expect(res.origen, OrigenReserva.airbnb);
      expect(res.esReservaReal, isTrue);
      expect(res.sincronizadoEnCanalOpuesto, isTrue);
      expect(res.canalesBloqueados.contains(OrigenReserva.booking), isTrue);
      expect(res.etiquetaSincronizacion, 'Sincronizado / Bloqueado en Booking');
    });

    test('Escenario 2: Reserva real en Booking + Bloqueo previo en Airbnb -> Sobrescritura limpia a favor de Booking', () async {
      final piso = Piso(id: 'uuid-2', nombre: 'Piso Playa');

      const icsAirbnbBloqueo = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:block-airbnb-1@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261213
SUMMARY:Airbnb (Not available)
END:VEVENT
END:VCALENDAR
''';

      const icsBookingReal = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:booking-real-1@booking.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261213
SUMMARY:CLOSED - Martin Weber
END:VEVENT
END:VCALENDAR
''';

      // Primero llega el bloqueo de Airbnb
      final r1 = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnbBloqueo,
        origenManual: OrigenReserva.airbnb,
      );
      expect(r1.hayConflictos, isFalse);
      expect(piso.reservas[DateTime(2026, 12, 10)]!.esBloqueoExterno, isTrue);

      // Después llega la reserva real de Booking -> debe tomar control absoluto sin conflicto
      final r2 = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBookingReal,
        origenManual: OrigenReserva.booking,
      );
      expect(r2.hayConflictos, isFalse);

      final res = piso.reservas[DateTime(2026, 12, 10)]!;
      expect(res.origen, OrigenReserva.booking);
      expect(res.esReservaReal, isTrue);
      expect(res.nombreInquilino, 'Martin Weber (Booking)');
      expect(res.sincronizadoEnCanalOpuesto, isTrue);
      expect(res.etiquetaSincronizacion, 'Sincronizado / Bloqueado en Airbnb');
    });

    test('Escenario 3: Reserva Manual + Bloqueos en Airbnb y Booking -> Manual prevalece protegida en ambas OTAs', () async {
      final fecha = DateTime(2026, 12, 20);
      final piso = Piso(
        id: 'uuid-3',
        nombre: 'Ático Centro',
        reservas: {
          fecha: ReservaDia(
            nombreInquilino: 'Familia Aguirre',
            origen: OrigenReserva.manual,
            tipoOcupacion: TipoOcupacion.reservaReal,
          ),
        },
      );

      const bloqueoAirbnb = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blk-a@airbnb.com
DTSTART;VALUE=DATE:20261220
DTEND;VALUE=DATE:20261221
SUMMARY:Not available
END:VEVENT
END:VCALENDAR
''';

      const bloqueoBooking = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blk-b@booking.com
DTSTART;VALUE=DATE:20261220
DTEND;VALUE=DATE:20261221
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final rA = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: bloqueoAirbnb,
        origenManual: OrigenReserva.airbnb,
      );
      final rB = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: bloqueoBooking,
        origenManual: OrigenReserva.booking,
      );

      expect(rA.hayConflictos, isFalse);
      expect(rB.hayConflictos, isFalse);

      final res = piso.reservas[fecha]!;
      expect(res.origen, OrigenReserva.manual);
      expect(res.nombreInquilino, 'Familia Aguirre');
      expect(res.sincronizadoEnCanalOpuesto, isTrue);
      expect(
        res.canalesBloqueados,
        containsAll([OrigenReserva.airbnb, OrigenReserva.booking]),
      );
      expect(res.etiquetaSincronizacion, 'Protegida en OTAs (Airbnb y Booking)');
    });

    test('Escenario 4: Sobreventa Real (Dos reservas reales de canales distintos) -> Detecta conflicto', () async {
      final piso = Piso(id: 'uuid-4', nombre: 'Loft Norte');

      const icsAirbnbReal = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:real-a@airbnb.com
DTSTART;VALUE=DATE:20261224
DTEND;VALUE=DATE:20261226
SUMMARY:Ana López
END:VEVENT
END:VCALENDAR
''';

      const icsBookingReal = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:real-b@booking.com
DTSTART;VALUE=DATE:20261224
DTEND;VALUE=DATE:20261226
SUMMARY:CLOSED - Not available
DESCRIPTION:Confirmation Code: 9988776655
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnbReal,
        origenManual: OrigenReserva.airbnb,
      );
      final resConflicto = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBookingReal,
        origenManual: OrigenReserva.booking,
      );

      expect(resConflicto.hayConflictos, isTrue);
      expect(resConflicto.conflictos.length, 2);
      expect(resConflicto.conflictos.first.reservaActual.origen, OrigenReserva.airbnb);
      expect(resConflicto.conflictos.first.reservaNueva.origen, OrigenReserva.booking);
    });

    test('Escenario 5: Actualización de nombre de inquilino y borrado de reservas + persistencia JSON retrocompatible', () async {
      final piso = Piso(id: 'uuid-5', nombre: 'Estudio Río');
      const icsAirbnb = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:persist-uid-99@airbnb.com
DTSTART;VALUE=DATE:20261105
DTEND;VALUE=DATE:20261107
SUMMARY:Reserved
DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HM55667788
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnb,
        origenManual: OrigenReserva.airbnb,
      );

      final d1 = DateTime(2026, 11, 5);
      final d2 = DateTime(2026, 11, 6);

      // El anfitrión personaliza el nombre del huésped manteniendo el canal y UID
      piso.reservas[d1] = piso.reservas[d1]!.copyWith(nombreInquilino: 'Carlos Ruiz');
      piso.reservas[d2] = piso.reservas[d2]!.copyWith(nombreInquilino: 'Carlos Ruiz');

      // Re-sincronizar: debe conservar el nombre personalizado sin lanzar conflicto
      final reSync = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnb,
        origenManual: OrigenReserva.airbnb,
      );
      expect(reSync.hayConflictos, isFalse);
      expect(piso.reservas[d1]!.nombreInquilino, 'Carlos Ruiz');
      expect(piso.reservas[d1]!.origen, OrigenReserva.airbnb);

      // Serialización / Deserialización completa de Piso (Supabase / SharedPreferences)
      final jsonStr = jsonEncode(piso.toJson());
      final pisoRestaurado = Piso.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      expect(pisoRestaurado.reservas[d1]!.nombreInquilino, 'Carlos Ruiz');
      expect(pisoRestaurado.reservas[d1]!.origen, OrigenReserva.airbnb);
      expect(pisoRestaurado.reservas[d1]!.esReservaReal, isTrue);

      // Compatibilidad con datos legacy sin campo 'tipoOcupacion'
      final legacyBloqueo = ReservaDia.fromJson({
        'nombreInquilino': 'Bloqueado (Booking)',
        'origen': 'booking',
        'idEventoExt': 'old-1',
      });
      expect(legacyBloqueo.esBloqueoExterno, isTrue);

      final legacyRealConBloqueo = ReservaDia.fromJson({
        'nombreInquilino': 'Elena (Airbnb)',
        'origen': 'airbnb',
        'idEventoExt': 'old-2',
        'bloqueoExtra': 'Bloqueado (Booking)',
      });
      expect(legacyRealConBloqueo.esReservaReal, isTrue);
      expect(legacyRealConBloqueo.sincronizadoEnCanalOpuesto, isTrue);
      expect(
        legacyRealConBloqueo.etiquetaSincronizacion,
        'Sincronizado / Bloqueado en Booking',
      );

      // Borrado de reserva
      pisoRestaurado.reservas.remove(d1);
      pisoRestaurado.reservas.remove(d2);
      expect(pisoRestaurado.reservas.isEmpty, isTrue);
    });

    test('Construcción de enlaces de exportación segmentados anti-bucle', () {
      expect(
        ServicioICal.construirUrlExportacion('abc-123', target: 'airbnb'),
        contains('piso_id=abc-123&target=airbnb'),
      );
      expect(
        ServicioICal.construirUrlExportacion('abc-123', target: 'booking'),
        contains('piso_id=abc-123&target=booking'),
      );
      expect(
        ServicioICal.construirUrlExportacion('abc-123').contains('target='),
        isFalse,
      );
    });
  });

  group('Interfaz Móvil: CalendarioGlobalScreen y DetallePisoScreen', () {
    testWidgets('CalendarioGlobalScreen muestra reservas reales con bloqueo cruzado y oculta bloqueos vacíos', (tester) async {
      final hoy = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
      final pisoReal = Piso(
        id: 'p1',
        nombre: 'Piso Gran Vía',
        reservas: {
          hoy: ReservaDia(
            nombreInquilino: 'Lucía Fernández (Airbnb)',
            origen: OrigenReserva.airbnb,
            tipoOcupacion: TipoOcupacion.reservaReal,
            sincronizadoEnCanalOpuesto: true,
            canalesBloqueados: {OrigenReserva.booking},
          ),
        },
      );
      final pisoSoloBloqueo = Piso(
        id: 'p2',
        nombre: 'Piso Retiro',
        reservas: {
          hoy: ReservaDia(
            nombreInquilino: 'Bloqueado (Booking)',
            origen: OrigenReserva.booking,
            tipoOcupacion: TipoOcupacion.bloqueoExterno,
          ),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: CalendarioGlobalScreen(
              pisos: [pisoReal, pisoSoloBloqueo],
              isDarkMode: false,
            ),
          ),
        ),
      );

      // La reserva real aparece visible junto con su distintivo de protección cruzada
      expect(find.text('Piso Gran Vía'), findsOneWidget);
      expect(find.text('Lucía Fernández (Airbnb)'), findsOneWidget);
      expect(find.text('Sincronizado / Bloqueado en Booking'), findsOneWidget);

      // El piso que solo tenía un bloqueo vacío NO aparece como ocupado
      expect(find.text('Bloqueado (Booking)'), findsNothing);
      expect(find.textContaining('1 ocupado · 1 libre'), findsOneWidget);
    });

    testWidgets('DetallePisoScreen tiene AppBar despejada y selector de rango de 3 toques', (tester) async {
      final piso = Piso(id: 'p-rango', nombre: 'Apartamento Mar');

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: DetallePisoScreen(piso: piso, isDarkMode: false),
          ),
        ),
      );

      // Verificar AppBar despejada: icono principal sync + menú desplegable
      expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);

      // 1er toque en día 10 -> 1 noche seleccionada
      await tester.tap(find.text('10').first);
      await tester.pumpAndSettle();
      expect(find.text('1 noche'), findsOneWidget);

      // 2º toque en día 13 -> Rellena automáticamente 10, 11, 12 y 13 (4 noches)
      await tester.tap(find.text('13').first);
      await tester.pumpAndSettle();
      expect(find.text('4 noches'), findsOneWidget);

      // 3er toque dentro del rango -> Reinicia / deselecciona
      await tester.tap(find.text('11').first);
      await tester.pumpAndSettle();
      expect(find.text('4 noches'), findsNothing);
    });
  });
}
