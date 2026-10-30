import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_alquiler_jefe/models/origen_reserva.dart';
import 'package:app_alquiler_jefe/models/piso.dart';
import 'package:app_alquiler_jefe/models/reserva_dia.dart';
import 'package:app_alquiler_jefe/screens/calendario_global_screen.dart';
import 'package:app_alquiler_jefe/screens/detalle_piso_screen.dart';
import 'package:app_alquiler_jefe/screens/lista_pisos_screen.dart';
import 'package:app_alquiler_jefe/services/servicio_ical.dart';
import 'package:app_alquiler_jefe/services/supabase_service.dart';
import 'package:app_alquiler_jefe/widgets/dialogo_sincronizacion_piso.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final DateTime fechaRef = DateTime(2026, 12, 1);

  group('SUITE 1: Persistencia de Identidad de Huésped (Renombrado vs Nueva Reserva Distinta)', () {
    test('1.1 Reserva nueva llega como Reservado -> Anfitrión asigna nombre -> Múltiples sincronizaciones la preservan', () async {
      final piso = Piso(id: 'piso-oro-1', nombre: 'Ático Gran Vía');

      const icsAirbnb = '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:airbnb-stay-1001@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261214
SUMMARY:Reserved
DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HM10203040\\nPhone Number (Last 4 Digits): 4321
END:VEVENT
END:VCALENDAR
''';

      const icsBookingEspejo = '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:booking-mirror-99@booking.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261214
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      // 1ª Sincronización: llega como "Reservado #HM10203040 (Airbnb)"
      final r1 = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnb,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );
      expect(r1.hayConflictos, isFalse);

      for (int d = 10; d <= 13; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Reservado #HM10203040 (Airbnb)');
        expect(res.nombrePersonalizado, isFalse);
        expect(res.codigoReserva, 'HM10203040');
      }

      // El anfitrión personaliza "Reservado..." por "Pedro Gómez"
      for (int d = 10; d <= 13; d++) {
        final fecha = DateTime(2026, 12, d);
        piso.reservas[fecha] = piso.reservas[fecha]!.copyWith(
          nombreInquilino: 'Pedro Gómez',
          nombrePersonalizado: true,
        );
      }

      // 5 re-sincronizaciones seguidas combinando Airbnb y bloqueo espejo en Booking
      final mockClient = MockClient((req) async {
        if (req.url.host.contains('airbnb')) {
          return http.Response(icsAirbnb, 200);
        }
        return http.Response(icsBookingEspejo, 200);
      });

      for (int ciclo = 0; ciclo < 5; ciclo++) {
        final resSync = await ServicioICal.sincronizarPiso(
          piso,
          urlAirbnb: 'https://www.airbnb.es/calendar/ical/123.ics',
          urlBooking: 'https://ical.booking.com/v1/export?t=456',
          fechaReferencia: fechaRef,
          httpClient: mockClient,
        );
        expect(resSync.hayConflictos, isFalse);

        for (int d = 10; d <= 13; d++) {
          final res = piso.reservas[DateTime(2026, 12, d)]!;
          expect(res.nombreInquilino, 'Pedro Gómez');
          expect(res.nombrePersonalizado, isTrue);
          expect(res.origen, OrigenReserva.airbnb);
          expect(res.sincronizadoEnCanalOpuesto, isTrue);
          expect(
            res.etiquetaSincronizacion,
            'Sincronizado / Bloqueado en Booking',
          );
        }
      }
    });

    test('1.2 Mismas fechas exactas, DISTINTA reserva (Cancelación + Nueva reserva con otro UID y código) -> SÍ sobrescribe por Reservado', () async {
      final piso = Piso(id: 'piso-oro-2', nombre: 'Loft Malasaña');

      const icsReserva1 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:uid-primera-reserva@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261215
SUMMARY:Reserved
DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMAAAA1111
END:VEVENT
END:VCALENDAR
''';

      const icsBloqueoBooking = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blk-booking-10-15@booking.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261215
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      // Llega Reserva 1 + Bloqueo cruzado de Booking
      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsReserva1,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );
      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBloqueoBooking,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );

      // El anfitrión la renombra a "Pedro Gómez"
      for (int d = 10; d <= 14; d++) {
        final f = DateTime(2026, 12, d);
        piso.reservas[f] = piso.reservas[f]!.copyWith(
          nombreInquilino: 'Pedro Gómez',
          nombrePersonalizado: true,
        );
      }

      // Pedro Gómez cancela en Airbnb y entra OTRA reserva distinta en las MISMAS fechas (10 al 15 dic)
      const icsReserva2Distinta = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:uid-segunda-reserva@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261215
SUMMARY:Reserved
DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMBBBB2222
END:VEVENT
END:VCALENDAR
''';

      final rCambio = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsReserva2Distinta,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );
      expect(rCambio.hayConflictos, isFalse);

      // Debe haberse sobrescrito "Pedro Gómez" por "Reservado #HMBBBB2222 (Airbnb)"
      for (int d = 10; d <= 14; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Reservado #HMBBBB2222 (Airbnb)');
        expect(res.nombrePersonalizado, isFalse);
        expect(res.idEventoExt, 'uid-segunda-reserva@airbnb.com');
        expect(res.codigoReserva, 'HMBBBB2222');
        // Y además conserva el bloqueo cruzado que ya tenía Booking en esas fechas
        expect(res.canalesBloqueados.contains(OrigenReserva.booking), isTrue);
        expect(res.sincronizadoEnCanalOpuesto, isTrue);
      }

      // Ahora el anfitrión renombra la segunda reserva a "Lucía Méndez" y vuelve a sincronizar
      for (int d = 10; d <= 14; d++) {
        final f = DateTime(2026, 12, d);
        piso.reservas[f] = piso.reservas[f]!.copyWith(
          nombreInquilino: 'Lucía Méndez',
          nombrePersonalizado: true,
        );
      }

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsReserva2Distinta,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 10; d <= 14; d++) {
        expect(piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino, 'Lucía Méndez');
      }
    });

    test('1.3 Mismo UID reutilizado por portal pero DISTINTO Confirmation Code -> Detecta reserva distinta y resetea a Reservado', () async {
      final piso = Piso(id: 'piso-oro-3', nombre: 'Estudio Sol');

      const ics1 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:contenedor-fijo@ota.com
DTSTART;VALUE=DATE:20261218
DTEND;VALUE=DATE:20261220
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: BK-11111
END:VEVENT
END:VCALENDAR
''';

      const ics2MismoUidDistintoCodigo = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:contenedor-fijo@ota.com
DTSTART;VALUE=DATE:20261218
DTEND;VALUE=DATE:20261220
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: BK-99999
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: ics1,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );

      piso.reservas[DateTime(2026, 12, 18)] =
          piso.reservas[DateTime(2026, 12, 18)]!.copyWith(nombreInquilino: 'Hans Müller');
      piso.reservas[DateTime(2026, 12, 19)] =
          piso.reservas[DateTime(2026, 12, 19)]!.copyWith(nombreInquilino: 'Hans Müller');

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: ics2MismoUidDistintoCodigo,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );

      expect(
        piso.reservas[DateTime(2026, 12, 18)]!.nombreInquilino,
        'Reservado #BK-99999 (Booking)',
      );
      expect(piso.reservas[DateTime(2026, 12, 18)]!.nombrePersonalizado, isFalse);
    });

    test('1.4 Misma reserva pierde DESCRIPTION en siguiente sync pero mantiene UID -> Conserva nombre personalizado y código', () async {
      final piso = Piso(id: 'piso-oro-4', nombre: 'Piso Prado');

      const icsConDesc = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:uid-estable-77@airbnb.com
DTSTART;VALUE=DATE:20261205
DTEND;VALUE=DATE:20261208
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM77770000
END:VEVENT
END:VCALENDAR
''';

      const icsSinDescMismoUid = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:uid-estable-77@airbnb.com
DTSTART;VALUE=DATE:20261205
DTEND;VALUE=DATE:20261208
SUMMARY:Reserved
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsConDesc,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 5; d <= 7; d++) {
        final f = DateTime(2026, 12, d);
        piso.reservas[f] = piso.reservas[f]!.copyWith(nombreInquilino: 'Carmen Sevilla');
      }

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsSinDescMismoUid,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 5; d <= 7; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Carmen Sevilla');
        expect(res.codigoReserva, 'HM77770000');
      }
    });

    test('1.5 Reservas Back-to-Back (Check-out día 15 y Check-in día 15) no se mezclan al renombrar ni al cancelar una de ellas', () async {
      final piso = Piso(id: 'piso-b2b', nombre: 'Apartamento Serrano');

      const icsBackToBack = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:b2b-guest-1@airbnb.com
DTSTART;VALUE=DATE:20261212
DTEND;VALUE=DATE:20261215
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM11110000
END:VEVENT
BEGIN:VEVENT
UID:b2b-guest-2@airbnb.com
DTSTART;VALUE=DATE:20261215
DTEND;VALUE=DATE:20261218
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM22220000
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBackToBack,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      // Día 14 (última noche Guest 1) y Día 15 (primera noche Guest 2) NO pertenecen a la misma estancia
      expect(
        piso.reservas[DateTime(2026, 12, 14)]!
            .perteneceAMismaEstancia(piso.reservas[DateTime(2026, 12, 15)]!),
        isFalse,
      );

      // El anfitrión asigna el nombre de ambos huéspedes
      for (int d = 12; d <= 14; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Marta Díaz');
      }
      for (int d = 15; d <= 17; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Jorge Soler');
      }

      // Guest 1 cancela y entra Guest 3 en 12..15; Guest 2 sigue igual en 15..18
      const icsReemplazoGuest1 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:b2b-guest-3@airbnb.com
DTSTART;VALUE=DATE:20261212
DTEND;VALUE=DATE:20261215
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM33330000
END:VEVENT
BEGIN:VEVENT
UID:b2b-guest-2@airbnb.com
DTSTART;VALUE=DATE:20261215
DTEND;VALUE=DATE:20261218
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM22220000
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsReemplazoGuest1,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 12; d <= 14; d++) {
        expect(
          piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino,
          'Reservado #HM33330000 (Airbnb)',
        );
      }
      for (int d = 15; d <= 17; d++) {
        expect(
          piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino,
          'Jorge Soler',
        );
      }
    });
  });

  group('SUITE 2: Modificaciones desde la Web (Ampliaciones, Recortes, Cambios de Fecha y Cancelaciones)', () {
    test('2.1 Ampliación de estancia en la web -> Los nuevos días heredan automáticamente el nombre personalizado', () async {
      final piso = Piso(id: 'piso-ext', nombre: 'Dúplex Retiro');

      const icsInicial = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ext-uid-1@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261213
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM50505050
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsInicial,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 10; d <= 12; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Pedro Gómez');
      }

      // Pedro amplía en Airbnb hasta el día 16 (noches 10..15)
      const icsAmpliado = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ext-uid-1@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261216
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM50505050
END:VEVENT
END:VCALENDAR
''';

      final r = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAmpliado,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );
      expect(r.hayConflictos, isFalse);

      for (int d = 10; d <= 15; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Pedro Gómez');
        expect(res.nombrePersonalizado, isTrue);
      }
    });

    test('2.2 Recorte de estancia en la web -> Libera noches canceladas y conserva el nombre personalizado en las restantes', () async {
      final piso = Piso(id: 'piso-short', nombre: 'Piso Castellana');

      const icsLargo = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:short-uid-1@booking.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261216
SUMMARY:CLOSED - Not available
DESCRIPTION:Reservation ID: 88776655
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsLargo,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );

      for (int d = 10; d <= 15; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Claire Moreau');
      }

      // Claire recorta su estancia a noches 11, 12 y 13 (check-out 14)
      const icsRecortado = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:short-uid-1@booking.com
DTSTART;VALUE=DATE:20261211
DTEND;VALUE=DATE:20261214
SUMMARY:CLOSED - Not available
DESCRIPTION:Reservation ID: 88776655
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsRecortado,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );

      expect(piso.reservas.containsKey(DateTime(2026, 12, 10)), isFalse);
      expect(piso.reservas.containsKey(DateTime(2026, 12, 14)), isFalse);
      expect(piso.reservas.containsKey(DateTime(2026, 12, 15)), isFalse);

      for (int d = 11; d <= 13; d++) {
        expect(piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino, 'Claire Moreau');
      }
    });

    test('2.3 Cambio completo de fechas en la web (Date Shift) -> Libera fechas antiguas y traslada el nombre personalizado', () async {
      final piso = Piso(id: 'piso-shift', nombre: 'Estudio Chamberí');

      const icsFechas1 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:shift-uid-99@airbnb.com
DTSTART;VALUE=DATE:20261205
DTEND;VALUE=DATE:20261208
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMSHIFT123
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsFechas1,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 5; d <= 7; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Roberto Carlos');
      }

      // Mueve la misma reserva a los días 20..23 de diciembre
      const icsFechas2 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:shift-uid-99@airbnb.com
DTSTART;VALUE=DATE:20261220
DTEND;VALUE=DATE:20261223
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMSHIFT123
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsFechas2,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 5; d <= 7; d++) {
        expect(piso.reservas.containsKey(DateTime(2026, 12, d)), isFalse);
      }
      for (int d = 20; d <= 22; d++) {
        expect(piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino, 'Roberto Carlos');
        expect(piso.reservas[DateTime(2026, 12, d)]!.nombrePersonalizado, isTrue);
      }
    });

    test('2.4 Solapamiento parcial por cancelación + nueva reserva distinta -> Libera días huérfanos y resetea solapados a Reservado', () async {
      final piso = Piso(id: 'piso-overlap-replace', nombre: 'Ático Ópera');

      const icsAntigua = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:old-stay@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261215
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMOLD11111
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAntigua,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      for (int d = 10; d <= 14; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Elena Nito');
      }

      // Elena cancela (10..15) y otra persona reserva del 12 al 17
      const icsNuevaSolapada = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:new-stay@airbnb.com
DTSTART;VALUE=DATE:20261212
DTEND;VALUE=DATE:20261217
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMNEW22222
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsNuevaSolapada,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      expect(piso.reservas.containsKey(DateTime(2026, 12, 10)), isFalse);
      expect(piso.reservas.containsKey(DateTime(2026, 12, 11)), isFalse);

      for (int d = 12; d <= 16; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Reservado #HMNEW22222 (Airbnb)');
        expect(res.nombrePersonalizado, isFalse);
      }
    });

    test('2.5 Cancelación en Airbnb con latencia real en Booking (3 ciclos HTTP con MockClient) sin bucles zombi', () async {
      final piso = Piso(id: 'piso-latencia', nombre: 'Piso Huertas');

      String feedAirbnb = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:sofia-1@airbnb.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261213
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMSOFIA123
END:VEVENT
END:VCALENDAR
''';

      String feedBooking = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:mirror-blk@booking.com
DTSTART;VALUE=DATE:20261210
DTEND;VALUE=DATE:20261213
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final client = MockClient((req) async {
        if (req.url.host.contains('airbnb')) {
          return http.Response(feedAirbnb, 200);
        }
        return http.Response(feedBooking, 200);
      });

      // Ciclo 1: Reserva activa en Airbnb + bloqueo espejo en Booking
      await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/1.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=1',
        fechaReferencia: fechaRef,
        httpClient: client,
      );
      for (int d = 10; d <= 12; d++) {
        piso.reservas[DateTime(2026, 12, d)] = piso
            .reservas[DateTime(2026, 12, d)]!
            .copyWith(nombreInquilino: 'Sofía Lara');
      }

      // Ciclo 2: Sofía cancela en Airbnb, pero Booking aún no ha refrescado su iCal
      feedAirbnb = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n';
      await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/1.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=1',
        fechaReferencia: fechaRef,
        httpClient: client,
      );
      for (int d = 10; d <= 12; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.esBloqueoExterno, isTrue);
        expect(res.origen, OrigenReserva.booking);
      }

      // Ciclo 3: Booking refresca export-ical (que excluye bloqueoExterno) y libera el cierre
      feedBooking = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n';
      await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/1.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=1',
        fechaReferencia: fechaRef,
        httpClient: client,
      );
      expect(piso.reservas.isEmpty, isTrue);
    });
  });

  group('SUITE 3: Histórico, Errores de Red, GDPR Booking, Anti-Bucle y Simulación Caos', () {
    test('3.1 Histórico pasado (< hoy) y primera mitad de estancia en curso NUNCA se borran cuando la OTA omite el pasado', () async {
      final DateTime hoySimulado = DateTime(2026, 12, 10);
      final piso = Piso(
        id: 'piso-hist',
        nombre: 'Piso Histórico',
        reservas: {
          // Reserva pasada de noviembre con nombre personalizado
          DateTime(2026, 11, 15): ReservaDia(
            nombreInquilino: 'Cliente Noviembre',
            origen: OrigenReserva.airbnb,
            idEventoExt: 'past-nov@airbnb.com',
            nombrePersonalizado: true,
          ),
          // Estancia en curso (8 al 12 dic) que hace early-checkout el día 11
          for (int d = 8; d <= 11; d++)
            DateTime(2026, 12, d): ReservaDia(
              nombreInquilino: 'Huésped Actual',
              origen: OrigenReserva.airbnb,
              idEventoExt: 'ongoing@airbnb.com',
              nombrePersonalizado: true,
            ),
        },
      );

      // Airbnb ya no incluye noviembre y acorta la estancia actual hasta DTEND:20261211 (última noche día 10)
      const icsActualizado = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ongoing@airbnb.com
DTSTART;VALUE=DATE:20261208
DTEND;VALUE=DATE:20261211
SUMMARY:Reserved
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsActualizado,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: hoySimulado,
      );

      // Noviembre intacto
      expect(
        piso.reservas[DateTime(2026, 11, 15)]!.nombreInquilino,
        'Cliente Noviembre',
      );
      // Días pasados y hoy (8, 9, 10) intactos
      for (int d = 8; d <= 10; d++) {
        expect(
          piso.reservas[DateTime(2026, 12, d)]!.nombreInquilino,
          'Huésped Actual',
        );
      }
      // Noche futura acortada (11 dic) liberada
      expect(piso.reservas.containsKey(DateTime(2026, 12, 11)), isFalse);
    });

    test('3.2 Caída de red (HTTP 503 o HTML inválido) NO borra reservas existentes y devuelve advertencia', () async {
      final piso = Piso(
        id: 'piso-red',
        nombre: 'Piso Resiliente',
        reservas: {
          DateTime(2026, 12, 15): ReservaDia(
            nombreInquilino: 'Diego Armando',
            origen: OrigenReserva.airbnb,
            idEventoExt: 'abnb-ok@airbnb.com',
            nombrePersonalizado: true,
          ),
        },
      );

      final clientCaido = MockClient((req) async {
        if (req.url.host.contains('airbnb')) {
          return http.Response('Service Temporarily Unavailable', 503);
        }
        return http.Response('<html>Maintenance</html>', 200);
      });

      final res = await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/fail.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=html',
        fechaReferencia: fechaRef,
        httpClient: clientCaido,
      );

      expect(res.advertenciasConexion.length, 2);
      expect(
        piso.reservas[DateTime(2026, 12, 15)]!.nombreInquilino,
        'Diego Armando',
      );
    });

    test('3.3 Reserva GDPR de Booking (CLOSED - Not available) personalizada sobrevive syncs y se reemplaza si cambia UID', () async {
      final piso = Piso(id: 'piso-gdpr', nombre: 'Apartamento Sol');

      const icsGdpr1 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:gdpr-booking-111@booking.com
DTSTART;VALUE=DATE:20261203
DTEND;VALUE=DATE:20261206
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsGdpr1,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );
      expect(piso.reservas[DateTime(2026, 12, 3)]!.esBloqueoExterno, isTrue);

      // El anfitrión confirma en su extranet que es Sophie Dubois y la nombra en la app
      for (int d = 3; d <= 5; d++) {
        final f = DateTime(2026, 12, d);
        piso.reservas[f] = piso.reservas[f]!.copyWith(
          nombreInquilino: 'Sophie Dubois',
          tipoOcupacion: TipoOcupacion.reservaReal,
          nombrePersonalizado: true,
        );
      }

      // Re-sincronizar Booking + Bloqueo espejo de Airbnb
      const icsAirbnbMirror = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:abnb-mirror-1@airbnb.com
DTSTART;VALUE=DATE:20261203
DTEND;VALUE=DATE:20261206
SUMMARY:Airbnb (Not available)
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsGdpr1,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );
      final rMirror = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsAirbnbMirror,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );
      expect(rMirror.hayConflictos, isFalse);

      for (int d = 3; d <= 5; d++) {
        final res = piso.reservas[DateTime(2026, 12, d)]!;
        expect(res.nombreInquilino, 'Sophie Dubois');
        expect(res.esReservaReal, isTrue);
        expect(res.etiquetaSincronizacion, 'Sincronizado / Bloqueado en Airbnb');
      }

      // Si Sophie cancela y entra un bloqueo/evento distinto (gdpr-booking-222), NO conserva Sophie Dubois
      const icsGdpr2 = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:gdpr-booking-222@booking.com
DTSTART;VALUE=DATE:20261203
DTEND;VALUE=DATE:20261206
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsGdpr2,
        origenManual: OrigenReserva.booking,
        fechaReferencia: fechaRef,
      );
      expect(
        piso.reservas[DateTime(2026, 12, 3)]!.nombreInquilino,
        isNot('Sophie Dubois'),
      );
    });

    test('3.4 Protección Anti-Eco (@calendariopisos) y Parser RFC 5545 Torture Test (DATE-TIME, DTEND omitido, escapes)', () async {
      final piso = Piso(
        id: 'piso-eco',
        nombre: 'Piso Torture',
        reservas: {
          DateTime(2026, 12, 20): ReservaDia(
            nombreInquilino: 'Reserva Directa Propietario',
            origen: OrigenReserva.manual,
            nombrePersonalizado: true,
          ),
        },
      );

      const icsTorture = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          // Evento 1: Eco propio de @calendariopisos -> jamás debe crear conflicto
          'BEGIN:VEVENT\r\n'
          'UID:res-piso-eco-20261220-20261221@calendariopisos\r\n'
          'DTSTART;VALUE=DATE:20261220\r\n'
          'DTEND;VALUE=DATE:20261221\r\n'
          'SUMMARY:Ocupado / Reservado\r\n'
          'END:VEVENT\r\n'
          // Evento 2: Formato DATE-TIME con zona UTC y caracteres escapados + línea plegada con TAB
          'BEGIN:VEVENT\r\n'
          'UID:dt-utc-1@airbnb.com\r\n'
          'DTSTART:20261222T150000Z\r\n'
          'DTEND:20261224T110000Z\r\n'
          'SUMMARY;LANGUAGE=es:Reserved\r\n'
          'DESCRIPTION:Guest: O\'Connor\\, Liam\\; VIP\\NConfirmation \r\n'
          '\tCode: HMTORTURE99\r\n'
          'END:VEVENT\r\n'
          // Evento 3: Sin DTEND (1 sola noche implícita)
          'BEGIN:VEVENT\r\n'
          'UID:single-night@airbnb.com\r\n'
          'DTSTART;VALUE=DATE:20261228\r\n'
          'SUMMARY:Reserved\r\n'
          'DESCRIPTION:Confirmation Code: HMSINGLE01\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';

      final r = await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsTorture,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: fechaRef,
      );

      expect(r.hayConflictos, isFalse);
      expect(
        piso.reservas[DateTime(2026, 12, 20)]!.nombreInquilino,
        'Reserva Directa Propietario',
      );
      expect(
        piso.reservas[DateTime(2026, 12, 22)]!.nombreInquilino,
        "O'Connor, Liam; VIP (Airbnb)",
      );
      expect(piso.reservas[DateTime(2026, 12, 22)]!.codigoReserva, 'HMTORTURE99');
      expect(piso.reservas.containsKey(DateTime(2026, 12, 23)), isTrue);
      expect(piso.reservas.containsKey(DateTime(2026, 12, 24)), isFalse);
      expect(
        piso.reservas[DateTime(2026, 12, 28)]!.nombreInquilino,
        'Reservado #HMSINGLE01 (Airbnb)',
      );
    });

    test('3.5 Reserva Manual + Desbloqueo y Rebloqueo dinámico en OTAs actualiza etiquetas en vivo', () async {
      final fecha = DateTime(2026, 12, 25);
      final piso = Piso(
        id: 'piso-dyn',
        nombre: 'Casa Navidad',
        reservas: {
          fecha: ReservaDia(
            nombreInquilino: 'Estancia Familiar Directa',
            origen: OrigenReserva.manual,
            nombrePersonalizado: true,
          ),
        },
      );

      String abnb = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blk-a@airbnb.com
DTSTART;VALUE=DATE:20261225
DTEND;VALUE=DATE:20261226
SUMMARY:Not available
END:VEVENT
END:VCALENDAR
''';
      String bkng = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blk-b@booking.com
DTSTART;VALUE=DATE:20261225
DTEND;VALUE=DATE:20261226
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final client = MockClient((req) async {
        return http.Response(
          req.url.host.contains('airbnb') ? abnb : bkng,
          200,
        );
      });

      await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/a.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=b',
        fechaReferencia: fechaRef,
        httpClient: client,
      );
      expect(
        piso.reservas[fecha]!.etiquetaSincronizacion,
        'Protegida en OTAs (Airbnb y Booking)',
      );

      // Booking deja de bloquear esa fecha
      bkng = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n';
      await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://www.airbnb.es/calendar/ical/a.ics',
        urlBooking: 'https://ical.booking.com/v1/export?t=b',
        fechaReferencia: fechaRef,
        httpClient: client,
      );
      expect(
        piso.reservas[fecha]!.etiquetaSincronizacion,
        'Protegida en OTAs (Bloqueado en Airbnb)',
      );
    });

    test('3.6 Simulación Caos Mensual Completo (Agosto Temporada Alta con 7 estancias simultáneas y mutaciones)', () async {
      final refAgosto = DateTime(2027, 8, 1);
      final piso = Piso(
        id: 'piso-agosto',
        nombre: 'Villa Marbella',
        reservas: {
          // Estancia manual fija 25..27 agosto (noches 25, 26)
          DateTime(2027, 8, 25): ReservaDia(
            nombreInquilino: 'Reserva Directa Invitados',
            origen: OrigenReserva.manual,
            nombrePersonalizado: true,
          ),
          DateTime(2027, 8, 26): ReservaDia(
            nombreInquilino: 'Reserva Directa Invitados',
            origen: OrigenReserva.manual,
            nombrePersonalizado: true,
          ),
        },
      );

      String abnbAgosto = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:aug-a1@airbnb.com
DTSTART;VALUE=DATE:20270801
DTEND;VALUE=DATE:20270805
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMAUG00001
END:VEVENT
BEGIN:VEVENT
UID:aug-a2@airbnb.com
DTSTART;VALUE=DATE:20270810
DTEND;VALUE=DATE:20270814
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMAUG00002
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-b1@airbnb.com
DTSTART;VALUE=DATE:20270805
DTEND;VALUE=DATE:20270809
SUMMARY:Airbnb (Not available)
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-manual@airbnb.com
DTSTART;VALUE=DATE:20270825
DTEND;VALUE=DATE:20270827
SUMMARY:Airbnb (Not available)
END:VEVENT
END:VCALENDAR
''';

      String bkngAgosto = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:aug-b1@booking.com
DTSTART;VALUE=DATE:20270805
DTEND;VALUE=DATE:20270809
SUMMARY:CLOSED - Not available
DESCRIPTION:Confirmation Code: BKAUG100
END:VEVENT
BEGIN:VEVENT
UID:aug-b2@booking.com
DTSTART;VALUE=DATE:20270815
DTEND;VALUE=DATE:20270820
SUMMARY:CLOSED - Not available
DESCRIPTION:Confirmation Code: BKAUG200
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-a1@booking.com
DTSTART;VALUE=DATE:20270801
DTEND;VALUE=DATE:20270805
SUMMARY:CLOSED - Not available
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-a2@booking.com
DTSTART;VALUE=DATE:20270810
DTEND;VALUE=DATE:20270814
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final client = MockClient((req) async {
        return http.Response(
          req.url.host.contains('airbnb') ? abnbAgosto : bkngAgosto,
          200,
        );
      });

      // Fase 1: Importación inicial del mes completo -> 0 conflictos
      final r1 = await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://airbnb.com/aug.ics',
        urlBooking: 'https://booking.com/aug.ics',
        fechaReferencia: refAgosto,
        httpClient: client,
      );
      expect(r1.hayConflictos, isFalse);

      // Fase 2: El anfitrión asigna los nombres reales a las 4 reservas OTA
      for (int d = 1; d <= 4; d++) {
        piso.reservas[DateTime(2027, 8, d)] = piso
            .reservas[DateTime(2027, 8, d)]!
            .copyWith(nombreInquilino: 'Familia Rossi');
      }
      for (int d = 5; d <= 8; d++) {
        piso.reservas[DateTime(2027, 8, d)] = piso
            .reservas[DateTime(2027, 8, d)]!
            .copyWith(nombreInquilino: 'John Smith');
      }
      for (int d = 10; d <= 13; d++) {
        piso.reservas[DateTime(2027, 8, d)] = piso
            .reservas[DateTime(2027, 8, d)]!
            .copyWith(nombreInquilino: 'Familia Ibáñez');
      }
      for (int d = 15; d <= 19; d++) {
        piso.reservas[DateTime(2027, 8, d)] = piso
            .reservas[DateTime(2027, 8, d)]!
            .copyWith(nombreInquilino: 'Klara Fischer');
      }

      // Fase 3: Mutaciones masivas en la web:
      // - Familia Rossi (1..4) sigue igual -> debe conservar "Familia Rossi"
      // - John Smith (5..8) amplía al 9 (5..10) -> día 9 debe heredar "John Smith"
      // - Familia Ibáñez (10..13) CANCELA y entra NUEVA reserva (aug-a3, HMAUG00003) en 10..13 -> debe cambiar a "Reservado #HMAUG00003 (Airbnb)"
      // - Klara Fischer (15..19) acorta su salida al 18 (noches 15, 16, 17) -> días 18 y 19 libres, 15..17 siguen "Klara Fischer"
      // - Entra reserva nueva en hueco 28..31 agosto -> "Reservado #HMAUG00004 (Airbnb)"
      abnbAgosto = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:aug-a1@airbnb.com
DTSTART;VALUE=DATE:20270801
DTEND;VALUE=DATE:20270805
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMAUG00001
END:VEVENT
BEGIN:VEVENT
UID:aug-a3-new@airbnb.com
DTSTART;VALUE=DATE:20270810
DTEND;VALUE=DATE:20270814
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMAUG00003
END:VEVENT
BEGIN:VEVENT
UID:aug-a4-new@airbnb.com
DTSTART;VALUE=DATE:20270828
DTEND;VALUE=DATE:20270831
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMAUG00004
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-b1@airbnb.com
DTSTART;VALUE=DATE:20270805
DTEND;VALUE=DATE:20270810
SUMMARY:Airbnb (Not available)
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-manual@airbnb.com
DTSTART;VALUE=DATE:20270825
DTEND;VALUE=DATE:20270827
SUMMARY:Airbnb (Not available)
END:VEVENT
END:VCALENDAR
''';

      bkngAgosto = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:aug-b1@booking.com
DTSTART;VALUE=DATE:20270805
DTEND;VALUE=DATE:20270810
SUMMARY:CLOSED - Not available
DESCRIPTION:Confirmation Code: BKAUG100
END:VEVENT
BEGIN:VEVENT
UID:aug-b2@booking.com
DTSTART;VALUE=DATE:20270815
DTEND;VALUE=DATE:20270818
SUMMARY:CLOSED - Not available
DESCRIPTION:Confirmation Code: BKAUG200
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-a1@booking.com
DTSTART;VALUE=DATE:20270801
DTEND;VALUE=DATE:20270805
SUMMARY:CLOSED - Not available
END:VEVENT
BEGIN:VEVENT
UID:aug-mirror-a3@booking.com
DTSTART;VALUE=DATE:20270810
DTEND;VALUE=DATE:20270814
SUMMARY:CLOSED - Not available
END:VEVENT
END:VCALENDAR
''';

      final rCaos = await ServicioICal.sincronizarPiso(
        piso,
        urlAirbnb: 'https://airbnb.com/aug.ics',
        urlBooking: 'https://booking.com/aug.ics',
        fechaReferencia: refAgosto,
        httpClient: client,
      );
      expect(rCaos.hayConflictos, isFalse);

      // Verificación exhaustiva día a día del mes entero
      for (int d = 1; d <= 4; d++) {
        expect(piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino, 'Familia Rossi');
      }
      for (int d = 5; d <= 9; d++) {
        expect(piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino, 'John Smith');
      }
      for (int d = 10; d <= 13; d++) {
        expect(
          piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino,
          'Reservado #HMAUG00003 (Airbnb)',
        );
      }
      expect(piso.reservas.containsKey(DateTime(2027, 8, 14)), isFalse);
      for (int d = 15; d <= 17; d++) {
        expect(piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino, 'Klara Fischer');
      }
      expect(piso.reservas.containsKey(DateTime(2027, 8, 18)), isFalse);
      expect(piso.reservas.containsKey(DateTime(2027, 8, 19)), isFalse);
      for (int d = 25; d <= 26; d++) {
        expect(piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino, 'Reserva Directa Invitados');
        expect(
          piso.reservas[DateTime(2027, 8, d)]!.etiquetaSincronizacion,
          'Protegida en OTAs (Bloqueado en Airbnb)',
        );
      }
      for (int d = 28; d <= 30; d++) {
        expect(
          piso.reservas[DateTime(2027, 8, d)]!.nombreInquilino,
          'Reservado #HMAUG00004 (Airbnb)',
        );
      }

      // Persistencia completa JSON ida y vuelta
      final roundTrip =
          Piso.fromJson(jsonDecode(jsonEncode(piso.toJson())) as Map<String, dynamic>);
      expect(roundTrip.reservas[DateTime(2027, 8, 9)]!.nombreInquilino, 'John Smith');
      expect(roundTrip.reservas[DateTime(2027, 8, 9)]!.nombrePersonalizado, isTrue);
      expect(
        roundTrip.reservas[DateTime(2027, 8, 10)]!.nombrePersonalizado,
        isFalse,
      );
    });
  });

  group('SUITE 4: Pruebas UI Móvil End-to-End (Flujo Operativo Completo en Teléfono)', () {
    testWidgets('4.1 Tocar UN SOLO DÍA de una estancia "Reservado" de 4 noches y pulsar Editar renombra TODAS las noches y resiste re-sincronización', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ahora = DateTime.now();
      final mes = DateTime(ahora.year, ahora.month, 1);
      final piso = Piso(id: 'piso-ui-1', nombre: 'Piso Sol Móvil');

      final String yyyy = mes.year.toString().padLeft(4, '0');
      final String mm = mes.month.toString().padLeft(2, '0');

      final icsInicial = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ui-stay-1@airbnb.com
DTSTART;VALUE=DATE:$yyyy${mm}10
DTEND;VALUE=DATE:$yyyy${mm}14
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM77778888
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsInicial,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: DateTime(mes.year, mes.month, 1),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: DetallePisoScreen(piso: piso, isDarkMode: false),
          ),
        ),
      );

      // El anfitrión toca SOLO el día 11 (un único día en mitad de la reserva 10..13)
      await tester.tap(find.text('11').first);
      await tester.pumpAndSettle();

      // Aparece el botón Editar con el rango completo detectado
      expect(find.text('Editar'), findsOneWidget);
      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();

      // Verifica que muestra que se editarán las 4 noches completas y el estado genérico actual
      expect(find.textContaining('(4 noches)'), findsOneWidget);
      expect(
        find.textContaining('Estado actual: Reservado #HM77778888 (Airbnb)'),
        findsOneWidget,
      );

      // El anfitrión escribe el nombre real del huésped y guarda
      await tester.enterText(find.byType(TextField), 'Ana Belén Torres');
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      // LAS 4 NOCHES (10, 11, 12 y 13) deben haberse renombrado a "Ana Belén Torres"
      for (int d = 10; d <= 13; d++) {
        final res = piso.reservas[DateTime(mes.year, mes.month, d)]!;
        expect(res.nombreInquilino, 'Ana Belén Torres');
        expect(res.origen, OrigenReserva.airbnb);
        expect(res.idEventoExt, 'ui-stay-1@airbnb.com');
        expect(res.codigoReserva, 'HM77778888');
        expect(res.nombrePersonalizado, isTrue);
      }

      // Al volver a sincronizar la MISMA reserva -> NO se sobrescribe por Reservado
      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsInicial,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: DateTime(mes.year, mes.month, 1),
      );
      for (int d = 10; d <= 13; d++) {
        expect(
          piso.reservas[DateTime(mes.year, mes.month, d)]!.nombreInquilino,
          'Ana Belén Torres',
        );
      }

      // Si esa reserva se cancela y entra OTRA reserva distinta en las mismas fechas -> SÍ vuelve a Reservado
      final icsOtraDistinta = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ui-stay-2-distinta@airbnb.com
DTSTART;VALUE=DATE:$yyyy${mm}10
DTEND;VALUE=DATE:$yyyy${mm}14
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HM00009999
END:VEVENT
END:VCALENDAR
''';
      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsOtraDistinta,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: DateTime(mes.year, mes.month, 1),
      );
      for (int d = 10; d <= 13; d++) {
        expect(
          piso.reservas[DateTime(mes.year, mes.month, d)]!.nombreInquilino,
          'Reservado #HM00009999 (Airbnb)',
        );
      }
    });

    testWidgets('4.2 Ampliar manualmente una reserva OTA con noches extra libres protege las noches extra al sincronizar', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ahora = DateTime.now();
      final mes = DateTime(ahora.year, ahora.month, 1);
      final String yyyy = mes.year.toString().padLeft(4, '0');
      final String mm = mes.month.toString().padLeft(2, '0');

      final piso = Piso(id: 'piso-ui-ext', nombre: 'Ático Terraza');
      final icsBase = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:ota-base@airbnb.com
DTSTART;VALUE=DATE:$yyyy${mm}10
DTEND;VALUE=DATE:$yyyy${mm}13
SUMMARY:Reserved
DESCRIPTION:Confirmation Code: HMBASE1234
END:VEVENT
END:VCALENDAR
''';

      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBase,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: mes,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: DetallePisoScreen(piso: piso, isDarkMode: false),
          ),
        ),
      );

      // Seleccionar rango del 12 (ocupado) al 14 (días 13 y 14 libres)
      await tester.tap(find.text('12').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('14').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Marcos Alonso');
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();

      // Elegir "Añadir todos" en la hoja de confirmación
      expect(find.text('Añadir todos'), findsOneWidget);
      await tester.tap(find.text('Añadir todos'));
      await tester.pumpAndSettle();

      // Días 10, 11, 12 son Airbnb ("Marcos Alonso") y días 13, 14 son Manual ("Marcos Alonso")
      for (int d = 10; d <= 12; d++) {
        expect(piso.reservas[DateTime(mes.year, mes.month, d)]!.origen, OrigenReserva.airbnb);
        expect(piso.reservas[DateTime(mes.year, mes.month, d)]!.nombreInquilino, 'Marcos Alonso');
      }
      for (int d = 13; d <= 14; d++) {
        expect(piso.reservas[DateTime(mes.year, mes.month, d)]!.origen, OrigenReserva.manual);
        expect(piso.reservas[DateTime(mes.year, mes.month, d)]!.nombreInquilino, 'Marcos Alonso');
      }

      // Al re-sincronizar Airbnb (que solo trae 10..12), las noches extra manuales 13 y 14 NO se borran
      await ServicioICal.sincronizarPiso(
        piso,
        contenidoManual: icsBase,
        origenManual: OrigenReserva.airbnb,
        fechaReferencia: mes,
      );
      for (int d = 10; d <= 14; d++) {
        expect(piso.reservas[DateTime(mes.year, mes.month, d)]!.nombreInquilino, 'Marcos Alonso');
      }
    });

    testWidgets('4.3 Eliminar reserva completa tocando un solo día vs liberar solo 1 día en DetallePisoScreen', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ahora = DateTime.now();
      final mes = DateTime(ahora.year, ahora.month, 1);

      final piso = Piso(
        id: 'piso-ui-del',
        nombre: 'Estudio Mar',
        reservas: {
          for (int d = 10; d <= 12; d++)
            DateTime(mes.year, mes.month, d): ReservaDia(
              nombreInquilino: 'Estancia Parcial',
              origen: OrigenReserva.manual,
              nombrePersonalizado: true,
            ),
          for (int d = 18; d <= 21; d++)
            DateTime(mes.year, mes.month, d): ReservaDia(
              nombreInquilino: 'Estancia 4 Noches',
              origen: OrigenReserva.manual,
              nombrePersonalizado: true,
            ),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DetallePisoScreen(piso: piso, isDarkMode: false),
        ),
      );

      // 1) Tocar día 10 de "Estancia Parcial" y liberar SOLO ese día
      await tester.tap(find.text('10').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Liberar días seleccionados'));
      await tester.pumpAndSettle();

      expect(find.text('Solo 1 día(s)'), findsOneWidget);
      await tester.tap(find.text('Solo 1 día(s)'));
      await tester.pumpAndSettle();

      expect(piso.reservas.containsKey(DateTime(mes.year, mes.month, 10)), isFalse);
      expect(piso.reservas.containsKey(DateTime(mes.year, mes.month, 11)), isTrue);
      expect(piso.reservas.containsKey(DateTime(mes.year, mes.month, 12)), isTrue);

      // 2) Tocar únicamente el día 19 de "Estancia 4 Noches" y eliminar la reserva completa
      await tester.tap(find.text('19').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Liberar días seleccionados'));
      await tester.pumpAndSettle();

      expect(find.text('Eliminar reserva completa (4 noches)'), findsOneWidget);
      await tester.tap(find.text('Eliminar reserva completa (4 noches)'));
      await tester.pumpAndSettle();

      for (int d = 18; d <= 21; d++) {
        expect(piso.reservas.containsKey(DateTime(mes.year, mes.month, d)), isFalse);
      }
    });

    testWidgets('4.4 Resolución interactiva día a día de Sobreventa Real en DialogoSincronizacionPiso', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final d1 = DateTime(2026, 12, 24);
      final d2 = DateTime(2026, 12, 25);

      final piso = Piso(
        id: 'piso-overbooking-ui',
        nombre: 'Loft Centro',
        reservas: {
          d1: ReservaDia(
            nombreInquilino: 'Huésped Airbnb',
            origen: OrigenReserva.airbnb,
            idEventoExt: 'ab-1@airbnb.com',
            nombrePersonalizado: true,
          ),
          d2: ReservaDia(
            nombreInquilino: 'Huésped Airbnb',
            origen: OrigenReserva.airbnb,
            idEventoExt: 'ab-1@airbnb.com',
            nombrePersonalizado: true,
          ),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => DialogoSincronizacionPiso.mostrar(
                    ctx,
                    piso: piso,
                    isDarkMode: false,
                    onActualizado: () {},
                  ),
                  child: const Text('Abrir Sync'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Sync'));
      await tester.pumpAndSettle();

      // Abrir ExpansionTile de importación manual .ics y simular llegada de Booking real en las mismas fechas
      final tileFinder = find.text('Opción avanzada: Pegar contenido .ics manual');
      await tester.ensureVisible(tileFinder);
      await tester.tap(tileFinder);
      await tester.pumpAndSettle();

      // Seleccionar Booking en el desplegable
      final dropdownFinder = find.byType(DropdownButtonFormField<OrigenReserva>);
      await tester.ensureVisible(dropdownFinder);
      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Booking.com (Azul #003580)').last);
      await tester.pumpAndSettle();

      const icsBookingChoque = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:bk-choque@booking.com
DTSTART;VALUE=DATE:20261224
DTEND;VALUE=DATE:20261226
SUMMARY:CLOSED - Pierre Dupont
END:VEVENT
END:VCALENDAR
''';

      await tester.enterText(find.byType(TextField).last, icsBookingChoque);
      final btnProcesar = find.text('Procesar texto .ics pegado');
      await tester.ensureVisible(btnProcesar);
      await tester.tap(btnProcesar);
      await tester.pumpAndSettle();

      // Debe mostrarse la alerta crítica de sobreventa
      expect(find.text('¡ALERTA CRÍTICA DE SOBREVENTA!'), findsOneWidget);

      // En el segundo día (25/12) elegimos "Usar entrante", dejando el 24/12 con el actual
      await tester.tap(find.text('Usar entrante').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Aplicar resolución día a día'));
      await tester.pumpAndSettle();

      expect(piso.reservas[d1]!.nombreInquilino, 'Huésped Airbnb');
      expect(piso.reservas[d1]!.origen, OrigenReserva.airbnb);
      expect(piso.reservas[d2]!.nombreInquilino, 'Pierre Dupont (Booking)');
      expect(piso.reservas[d2]!.origen, OrigenReserva.booking);
    });

    testWidgets('4.5 CalendarioGlobalScreen sin overflows en móviles pequeños (360x640), horizontal (844x390) y conmutación Agenda/Barras', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final hoy = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
      final pisos = List.generate(
        5,
        (i) => Piso(
          id: 'p-$i',
          nombre: 'Apartamento Turístico Número ${i + 1}',
          reservas: {
            hoy: i == 4
                ? ReservaDia(
                    nombreInquilino: 'Bloqueado (Airbnb)',
                    origen: OrigenReserva.airbnb,
                    tipoOcupacion: TipoOcupacion.bloqueoExterno,
                  )
                : ReservaDia(
                    nombreInquilino: 'Huésped Real ${i + 1}',
                    origen: i.isEven ? OrigenReserva.airbnb : OrigenReserva.booking,
                    tipoOcupacion: TipoOcupacion.reservaReal,
                    nombrePersonalizado: true,
                    sincronizadoEnCanalOpuesto: true,
                    canalesBloqueados: {
                      i.isEven ? OrigenReserva.booking : OrigenReserva.airbnb,
                    },
                  ),
          },
        ),
      );

      // 1. Móvil compacto 360x640 (Modo Agenda por defecto + Conmutación a Modo Barras)
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarioGlobalScreen(pisos: pisos, isDarkMode: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('4 ocupados · 1 libre'), findsOneWidget);
      expect(find.text('Bloqueado (Airbnb)'), findsNothing);

      // Conmutar a Vista de Barras en pantalla estrecha
      await tester.tap(find.byTooltip('Cambiar modo de vista'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 2. Móvil en horizontal 844x390
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarioGlobalScreen(pisos: pisos, isDarkMode: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('4.6 Compatibilidad real Airbnb/Booking: URL .ics, webcal://, UTF-8 sin charset e instrucciones del Paso 2', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 1. Verificar formato de URL exportada acabada en .ics + query params
      final urlExpAirbnb =
          ServicioICal.construirUrlExportacion('uuid-99', target: 'airbnb');
      final uriExp = Uri.parse(urlExpAirbnb);
      expect(uriExp.path.endsWith('/uuid-99_airbnb.ics'), isTrue);
      expect(uriExp.queryParameters['piso_id'], 'uuid-99');
      expect(uriExp.queryParameters['target'], 'airbnb');

      // 2. Verificar normalización webcal:// (iOS/macOS) y decodificación UTF-8 pura sin charset en Content-Type
      const icsUtf8 = 'BEGIN:VCALENDAR\r\n'
          'VERSION:2.0\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:utf8-1@booking.com\r\n'
          'DTSTART;VALUE=DATE:20261215\r\n'
          'DTEND;VALUE=DATE:20261217\r\n'
          'SUMMARY:CLOSED - José María Muñoz\r\n'
          'DESCRIPTION:Código de confirmación: BKUTF8123\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';

      final utf8Client = MockClient((req) async {
        expect(req.url.scheme, 'https');
        // Servidor envía bytes UTF-8 pero cabecera Content-Type sin charset=utf-8
        return http.Response.bytes(
          utf8.encode(icsUtf8),
          200,
          headers: {'content-type': 'text/calendar'},
        );
      });

      final piso = Piso(id: 'uuid-99', nombre: 'Piso Prueba Real');
      final verif = await ServicioICal.verificarEnlace(
        'webcal://ical.booking.com/v1/export?t=1234-abcd',
        httpClient: utf8Client,
      );
      expect(verif.esValido, isTrue);
      expect(verif.reservasReales, 1);

      await ServicioICal.sincronizarPiso(
        piso,
        urlBooking: 'webcal://ical.booking.com/v1/export?t=1234-abcd',
        fechaReferencia: fechaRef,
        httpClient: utf8Client,
      );
      expect(
        piso.reservas[DateTime(2026, 12, 15)]!.nombreInquilino,
        'José María Muñoz (Booking)',
      );
      expect(
        piso.reservas[DateTime(2026, 12, 15)]!.codigoReserva,
        'BKUTF8123',
      );

      // 3. Verificar que el Paso 2 del panel muestra cómo conseguir los enlaces de Airbnb y Booking
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DialogoSincronizacionPiso(
              piso: piso,
              isDarkMode: false,
              onActualizado: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Cómo conseguirlo en Airbnb:'), findsOneWidget);
      expect(
        find.textContaining('Cómo conseguirlo en Booking.com:'),
        findsOneWidget,
      );
    });

    test('4.7 Orden personalizado de pisos: persistencia, nuevos pisos al final y eliminación limpia', () async {
      final p1 = Piso(id: 'id-1', nombre: 'Piso Playa');
      final p2 = Piso(id: 'id-2', nombre: 'Piso Centro');
      final p3 = Piso(id: 'id-3', nombre: 'Piso Montaña');

      final service = SupabaseService();
      await service.guardarPiso(p1);
      await service.guardarPiso(p2);
      await service.guardarPiso(p3);

      // Reordenar a: Montaña -> Playa -> Centro
      await service.guardarOrdenPisos([p3, p1, p2]);

      final recargados = await service.obtenerPisos();
      expect(
        recargados.map((p) => p.nombre).toList(),
        ['Piso Montaña', 'Piso Playa', 'Piso Centro'],
      );

      // Si llega un piso nuevo aún no incluido en el orden guardado, se coloca al final sin romper el orden previo
      final p4 = Piso(id: 'id-4', nombre: 'Ático Nuevo');
      final combinados = SupabaseService.aplicarOrdenPersonalizado(
        [p1, p2, p3, p4],
        ['id-3', 'id-1', 'id-2'],
      );
      expect(
        combinados.map((p) => p.nombre).toList(),
        ['Piso Montaña', 'Piso Playa', 'Piso Centro', 'Ático Nuevo'],
      );

      // Si se elimina Piso Playa, el resto mantiene su orden relativo
      await service.eliminarPiso('id-1');
      final trasBorrar = await service.obtenerPisos();
      expect(
        trasBorrar.map((p) => p.nombre).toList(),
        ['Piso Montaña', 'Piso Centro'],
      );
    });

    testWidgets('4.8 Mantener pulsado y arrastrar en ListaPisosScreen reordena la lista y conserva el orden al reabrir', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = SupabaseService();
      await service.guardarPiso(Piso(id: 'p-playa', nombre: 'Piso Playa'));
      await service.guardarPiso(Piso(id: 'p-centro', nombre: 'Piso Centro'));
      await service.guardarPiso(Piso(id: 'p-montana', nombre: 'Piso Montaña'));

      await tester.pumpWidget(
        MaterialApp(
          home: ListaPisosScreen(
            isDarkMode: false,
            onToggleTheme: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Verificar orden inicial vertical: Playa arriba, Centro en medio, Montaña abajo
      expect(
        tester.getTopLeft(find.text('Piso Playa')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Centro')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Piso Centro')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Montaña')).dy),
      );

      // Gesto real de mantener pulsado sobre "Piso Montaña" y arrastrarlo suavemente arriba del todo (60fps)
      final TestGesture gesture =
          await tester.startGesture(tester.getCenter(find.text('Piso Montaña')));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      for (int step = 0; step < 12; step++) {
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Ahora "Piso Montaña" debe estar arriba del todo, por encima de "Piso Playa" y "Piso Centro"
      expect(
        tester.getTopLeft(find.text('Piso Montaña')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Playa')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Piso Playa')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Centro')).dy),
      );

      // Simular cierre y reapertura completa de la pantalla
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: ListaPisosScreen(
            isDarkMode: false,
            onToggleTheme: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // El orden personalizado persiste tras reabrir
      expect(
        tester.getTopLeft(find.text('Piso Montaña')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Playa')).dy),
      );

      // Probar también arrastrar suavemente hacia ABAJO (de primero a último)
      final TestGesture gestureDown =
          await tester.startGesture(tester.getCenter(find.text('Piso Montaña')));
      await tester.pump(kLongPressTimeout + kPressTimeout);
      for (int step = 0; step < 12; step++) {
        await gestureDown.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gestureDown.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(
        tester.getTopLeft(find.text('Piso Playa')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Centro')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Piso Centro')).dy,
        lessThan(tester.getTopLeft(find.text('Piso Montaña')).dy),
      );
    });
  });
}
