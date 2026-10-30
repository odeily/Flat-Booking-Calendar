import 'package:flutter/material.dart';
import 'reserva_dia.dart';

/// Entidad principal que modela un inmueble gestionado en la cartera.
///
/// Agrupa el mapa diario de ocupación ([reservas]), la asignación cromática persistente
/// para huéspedes recurrentes ([coloresInquilinos]) y los enlaces de importación iCal.
class Piso {
  /// Identificador UUID en Supabase (o prefijo `local_` mientras esté pendiente de subida).
  String? id;

  /// Nombre descriptivo del alojamiento.
  String nombre;

  /// Mapa indexado por fecha normalizada (`00:00:00`) con la ocupación de cada noche.
  Map<DateTime, ReservaDia> reservas;

  /// Caché de colores asignados a nombres de huéspedes de reservas manuales.
  Map<String, Color> coloresInquilinos;

  /// URL de importación iCal (`.ics`) procedente de Airbnb.
  String? urlAirbnb;

  /// URL de importación iCal (`.ics`) procedente de Booking.com.
  String? urlBooking;

  /// Marca temporal de la última sincronización iCal completada con éxito.
  DateTime? ultimaSincronizacion;

  Piso({
    this.id,
    required this.nombre,
    Map<DateTime, ReservaDia>? reservas,
    Map<String, Color>? coloresInquilinos,
    this.urlAirbnb,
    this.urlBooking,
    this.ultimaSincronizacion,
  })  : reservas = reservas ?? {},
        coloresInquilinos = coloresInquilinos ?? {};

  /// Serializa el inmueble y sus colecciones anidadas a un mapa compatible con JSONB de PostgreSQL.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> reservasJson = {};
    reservas.forEach((fecha, reserva) {
      reservasJson[fecha.toIso8601String()] = reserva.toJson();
    });

    final Map<String, dynamic> coloresJson = {};
    coloresInquilinos.forEach((nombre, color) {
      coloresJson[nombre] = color.toARGB32().toRadixString(16);
    });

    return {
      if (id != null) 'id': id,
      'nombre': nombre,
      'url_airbnb': urlAirbnb,
      'url_booking': urlBooking,
      'ultima_sincronizacion': ultimaSincronizacion?.toIso8601String(),
      'reservas': reservasJson,
      'colores_inquilinos': coloresJson,
    };
  }

  /// Reconstruye una instancia de [Piso] a partir del registro JSON local o de Supabase.
  factory Piso.fromJson(Map<String, dynamic> json) {
    final Map<DateTime, ReservaDia> reservas = {};
    if (json['reservas'] != null) {
      final reservasMap = json['reservas'] as Map<String, dynamic>;
      reservasMap.forEach((fechaStr, reservaJson) {
        reservas[DateTime.parse(fechaStr)] = ReservaDia.fromJson(reservaJson);
      });
    }

    final Map<String, Color> coloresInquilinos = {};
    if (json['colores_inquilinos'] != null) {
      final coloresMap = json['colores_inquilinos'] as Map<String, dynamic>;
      coloresMap.forEach((nombre, colorHex) {
        coloresInquilinos[nombre] = Color(int.parse(colorHex, radix: 16));
      });
    }

    return Piso(
      id: json['id'],
      nombre: json['nombre'],
      urlAirbnb: json['url_airbnb'],
      urlBooking: json['url_booking'],
      ultimaSincronizacion: json['ultima_sincronizacion'] != null
          ? DateTime.parse(json['ultima_sincronizacion'])
          : null,
      reservas: reservas,
      coloresInquilinos: coloresInquilinos,
    );
  }
}
