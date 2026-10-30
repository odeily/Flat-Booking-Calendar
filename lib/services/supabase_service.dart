import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/piso.dart';

/// Resultado tipado de la consulta de cartera de inmuebles, incluyendo telemetría de sincronización.
class ResultadoCargaPisos {
  final List<Piso> pisos;
  final bool sincronizadoConNube;
  final int pendientesSubida;

  const ResultadoCargaPisos({
    required this.pisos,
    required this.sincronizadoConNube,
    required this.pendientesSubida,
  });
}

/// Repositorio de persistencia **Offline-First** respaldado por Supabase PostgreSQL y `SharedPreferences`.
///
/// Garantiza disponibilidad inmediata sin red mediante caché local, encola escrituras pendientes
/// (`pending_sync_pisos`) para reconciliarlas automáticamente al recuperar conectividad y sincroniza
/// el orden personalizado de la cartera en el perfil del usuario (`user_metadata.orden_pisos`).
class SupabaseService {
  static const _cacheKey = 'cache_pisos';
  static const _pendingSyncKey = 'pending_sync_pisos';
  static const _ordenLocalFallbackKey = 'orden_pisos_local';
  static const _pendingOrdenFallbackKey = 'pending_orden_pisos_local';

  SupabaseClient? get _supabaseOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static String _claveOrdenPrefs(String? userId) =>
      (userId != null && userId.isNotEmpty)
          ? 'orden_pisos_$userId'
          : _ordenLocalFallbackKey;

  static String _clavePendienteOrden(String? userId) =>
      (userId != null && userId.isNotEmpty)
          ? 'pending_orden_pisos_$userId'
          : _pendingOrdenFallbackKey;

  /// Identificador estable de un piso para conservar su posición en la lista.
  static String claveOrdenDePiso(Piso piso) {
    final id = piso.id?.trim();
    if (id != null && id.isNotEmpty) {
      return id;
    }
    return 'nombre:${piso.nombre.trim().toLowerCase()}';
  }

  /// Ordena determinísticamente la lista de pisos según `ordenGuardado`.
  /// Los pisos nuevos que aún no estén en `ordenGuardado` se colocan al final respetando su orden relativo.
  static List<Piso> aplicarOrdenPersonalizado(
    List<Piso> pisos,
    List<String> ordenGuardado,
  ) {
    if (ordenGuardado.isEmpty || pisos.length <= 1) {
      return List<Piso>.from(pisos);
    }

    final Map<String, int> posiciones = {};
    for (int i = 0; i < ordenGuardado.length; i++) {
      posiciones.putIfAbsent(ordenGuardado[i], () => i);
    }

    int obtenerPosicion(Piso p, int indiceOriginal) {
      final claveId = claveOrdenDePiso(p);
      if (posiciones.containsKey(claveId)) {
        return posiciones[claveId]!;
      }
      final claveNombre = 'nombre:${p.nombre.trim().toLowerCase()}';
      if (posiciones.containsKey(claveNombre)) {
        return posiciones[claveNombre]!;
      }
      return ordenGuardado.length + indiceOriginal;
    }

    final List<MapEntry<int, Piso>> indexados =
        pisos.asMap().entries.toList();
    indexados.sort((a, b) {
      final posA = obtenerPosicion(a.value, a.key);
      final posB = obtenerPosicion(b.value, b.key);
      return posA.compareTo(posB);
    });

    return indexados.map((e) => e.value).toList();
  }

  List<String> _cargarOrdenDePrefs(SharedPreferences prefs, String? userId) {
    final List<String>? guardadoUsuario =
        prefs.getStringList(_claveOrdenPrefs(userId));
    if (guardadoUsuario != null && guardadoUsuario.isNotEmpty) {
      return List<String>.from(guardadoUsuario);
    }
    if (userId != null && userId.isNotEmpty) {
      final List<String>? fallback =
          prefs.getStringList(_ordenLocalFallbackKey);
      if (fallback != null && fallback.isNotEmpty) {
        return List<String>.from(fallback);
      }
    }
    return [];
  }

  Future<void> _guardarOrdenEnPrefs(
    SharedPreferences prefs,
    String? userId,
    List<String> ordenClaves,
  ) async {
    await prefs.setStringList(_claveOrdenPrefs(userId), ordenClaves);
    await prefs.setStringList(_ordenLocalFallbackKey, ordenClaves);
  }

  Future<void> _reemplazarIdEnOrdenLocal(
    SharedPreferences prefs,
    String? userId,
    String idAntiguo,
    String idNuevo,
  ) async {
    final actual = _cargarOrdenDePrefs(prefs, userId);
    if (actual.isEmpty) return;
    bool cambiado = false;
    final actualizado = actual.map((item) {
      if (item == idAntiguo) {
        cambiado = true;
        return idNuevo;
      }
      return item;
    }).toList();
    if (cambiado) {
      await _guardarOrdenEnPrefs(prefs, userId, actualizado);
      await prefs.setBool(_clavePendienteOrden(userId), true);
    }
  }

  /// Guarda el nuevo orden elegido por el usuario tanto en local como en su perfil de Supabase.
  Future<bool> guardarOrdenPisos(List<Piso> pisosOrdenados) async {
    final prefs = await SharedPreferences.getInstance();
    final client = _supabaseOrNull;
    final user = client?.auth.currentUser;
    final List<String> ordenClaves =
        pisosOrdenados.map(claveOrdenDePiso).toList();

    await _guardarOrdenEnPrefs(prefs, user?.id, ordenClaves);
    await prefs.setString(
      _cacheKey,
      jsonEncode(pisosOrdenados.map((p) => p.toJson()).toList()),
    );

    if (client == null || user == null) {
      await prefs.setBool(_clavePendienteOrden(user?.id), true);
      return false;
    }

    try {
      await client.auth.updateUser(
        UserAttributes(data: {'orden_pisos': ordenClaves}),
      );
      await prefs.setBool(_clavePendienteOrden(user.id), false);
      return true;
    } catch (e) {
      debugPrint('Error guardando orden de pisos en la nube: $e');
      await prefs.setBool(_clavePendienteOrden(user.id), true);
      return false;
    }
  }

  Future<List<Piso>> obtenerPisos() async {
    final res = await obtenerPisosConEstado();
    return res.pisos;
  }

  Future<ResultadoCargaPisos> obtenerPisosConEstado() async {
    final prefs = await SharedPreferences.getInstance();
    final client = _supabaseOrNull;
    final user = client?.auth.currentUser;

    try {
      if (client == null || user == null) {
        final ordenLocal = _cargarOrdenDePrefs(prefs, user?.id);
        final pisosCache = aplicarOrdenPersonalizado(
          _cargarCacheLocal(prefs),
          ordenLocal,
        );
        return ResultadoCargaPisos(
          pisos: pisosCache,
          sincronizadoConNube: false,
          pendientesSubida: _contarPendientes(prefs, user?.id),
        );
      }

      // Intentar sincronizar cambios offline pendientes primero (pisos y orden)
      await _sincronizarPendientes(prefs);

      final data = await client.from('pisos').select().order('created_at');
      final pisosBrutos =
          (data as List).map((json) => Piso.fromJson(json)).toList();

      final refreshedUser = client.auth.currentUser ?? user;
      final bool ordenPendienteLocal =
          prefs.getBool(_clavePendienteOrden(refreshedUser.id)) ?? false;
      final List<String> ordenLocal =
          _cargarOrdenDePrefs(prefs, refreshedUser.id);

      List<String> ordenEfectivo = ordenLocal;
      if (!ordenPendienteLocal) {
        final dynamic metaOrden = refreshedUser.userMetadata?['orden_pisos'];
        if (metaOrden is List && metaOrden.isNotEmpty) {
          ordenEfectivo = metaOrden.map((e) => e.toString()).toList();
          await _guardarOrdenEnPrefs(prefs, refreshedUser.id, ordenEfectivo);
        } else if (ordenLocal.isNotEmpty) {
          // Si ya existía un orden local pero aún no estaba en userMetadata, lo subimos
          try {
            await client.auth.updateUser(
              UserAttributes(data: {'orden_pisos': ordenLocal}),
            );
          } catch (_) {}
        }
      }

      final pisosOrdenados =
          aplicarOrdenPersonalizado(pisosBrutos, ordenEfectivo);

      // Actualizar caché local respetando el orden personalizado
      await prefs.setString(
        _cacheKey,
        jsonEncode(pisosOrdenados.map((p) => p.toJson()).toList()),
      );

      return ResultadoCargaPisos(
        pisos: pisosOrdenados,
        sincronizadoConNube: true,
        pendientesSubida: _contarPendientes(prefs, refreshedUser.id),
      );
    } catch (e) {
      debugPrint('No internet, loading from cache: $e');
      final ordenLocal = _cargarOrdenDePrefs(prefs, user?.id);
      final pisosCache = aplicarOrdenPersonalizado(
        _cargarCacheLocal(prefs),
        ordenLocal,
      );
      return ResultadoCargaPisos(
        pisos: pisosCache,
        sincronizadoConNube: false,
        pendientesSubida: _contarPendientes(prefs, user?.id),
      );
    }
  }

  int _contarPendientes(SharedPreferences prefs, [String? userId]) {
    int total = 0;
    final String? pendingStr = prefs.getString(_pendingSyncKey);
    if (pendingStr != null) {
      try {
        final Map<String, dynamic> pendingMap = jsonDecode(pendingStr);
        total += pendingMap.length;
      } catch (_) {}
    }
    if (prefs.getBool(_clavePendienteOrden(userId)) ?? false) {
      total += 1;
    }
    return total;
  }

  List<Piso> _cargarCacheLocal(SharedPreferences prefs) {
    final String? cacheStr = prefs.getString(_cacheKey);
    if (cacheStr == null) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(cacheStr);
      return jsonList.map((json) => Piso.fromJson(json)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> _sincronizarPendientes(SharedPreferences prefs) async {
    final client = _supabaseOrNull;
    final user = client?.auth.currentUser;
    if (client == null || user == null) return;

    final String? pendingStr = prefs.getString(_pendingSyncKey);
    if (pendingStr != null) {
      try {
        final Map<String, dynamic> pendingMap = jsonDecode(pendingStr);
        List<String> keysToRemove = [];

        for (final key in pendingMap.keys) {
          final dataToSave = Map<String, dynamic>.from(pendingMap[key]);
          dataToSave['user_id'] = user.id;

          try {
            // Si el ID fue generado localmente (empieza por local_), lo borramos para que Supabase asigne un UUID real
            if (dataToSave['id'] != null &&
                dataToSave['id'].toString().startsWith('local_')) {
              final String oldLocalId = dataToSave['id'].toString();
              dataToSave.remove('id');
              final inserted = await client
                  .from('pisos')
                  .insert(dataToSave)
                  .select()
                  .single();
              final String? newCloudId = inserted['id']?.toString();
              if (newCloudId != null && newCloudId.isNotEmpty) {
                await _reemplazarIdEnOrdenLocal(
                  prefs,
                  user.id,
                  oldLocalId,
                  newCloudId,
                );
              }
              keysToRemove.add(key);
            } else if (dataToSave['id'] == null) {
              await client.from('pisos').insert(dataToSave);
              keysToRemove.add(key);
            } else {
              await client.from('pisos').upsert(dataToSave);
              keysToRemove.add(key);
            }
          } catch (e) {
            debugPrint('Fallo al sincronizar elemento $key: $e');
          }
        }

        // Eliminar los que se sincronizaron con éxito
        for (final key in keysToRemove) {
          pendingMap.remove(key);
        }

        if (pendingMap.isEmpty) {
          await prefs.remove(_pendingSyncKey);
        } else {
          await prefs.setString(_pendingSyncKey, jsonEncode(pendingMap));
        }
      } catch (e) {
        debugPrint('Error general sincronizando pendientes: $e');
      }
    }

    // Sincronizar también el orden personalizado si quedó pendiente estando sin red
    final bool ordenPendiente =
        prefs.getBool(_clavePendienteOrden(user.id)) ?? false;
    if (ordenPendiente) {
      final ordenLocal = _cargarOrdenDePrefs(prefs, user.id);
      if (ordenLocal.isNotEmpty) {
        try {
          await client.auth.updateUser(
            UserAttributes(data: {'orden_pisos': ordenLocal}),
          );
          await prefs.setBool(_clavePendienteOrden(user.id), false);
        } catch (e) {
          debugPrint('Fallo al sincronizar orden pendiente: $e');
        }
      } else {
        await prefs.setBool(_clavePendienteOrden(user.id), false);
      }
    }
  }

  Future<Piso?> guardarPiso(Piso piso) async {
    final prefs = await SharedPreferences.getInstance();
    final client = _supabaseOrNull;
    final user = client?.auth.currentUser;
    final dataToSave = piso.toJson();
    final String? idAnterior = piso.id;

    // Intentamos subir lo pendiente por si acaba de volver el internet
    await _sincronizarPendientes(prefs);

    try {
      if (client == null || user == null) throw Exception('No logged in user');
      dataToSave['user_id'] = user.id;

      Piso pisoGuardado;
      if (piso.id == null || piso.id!.startsWith('local_')) {
        dataToSave.remove('id');
        final result = await client.from('pisos').insert(dataToSave).select().single();
        pisoGuardado = Piso.fromJson(result);
        if (idAnterior != null && pisoGuardado.id != null) {
          await _reemplazarIdEnOrdenLocal(
            prefs,
            user.id,
            idAnterior,
            pisoGuardado.id!,
          );
        }
        piso.id = pisoGuardado.id;
      } else {
        final result = await client.from('pisos').update(dataToSave).eq('id', piso.id!).select().single();
        pisoGuardado = Piso.fromJson(result);
      }

      // Update cache
      await _actualizarPisoEnCache(
        prefs,
        pisoGuardado,
        idAnterior: idAnterior,
      );
      return pisoGuardado;
    } catch (e) {
      debugPrint('Error saving to cloud, saving locally: $e');

      // Add to pending sync
      String? pendingStr = prefs.getString(_pendingSyncKey);
      Map<String, dynamic> pendingMap = pendingStr != null ? jsonDecode(pendingStr) : {};

      // If offline new piso, generate a temporary local id
      piso.id ??= 'local_${DateTime.now().millisecondsSinceEpoch}';
      dataToSave['id'] = piso.id;

      pendingMap[piso.id!] = dataToSave;
      await prefs.setString(_pendingSyncKey, jsonEncode(pendingMap));

      // Update cache so UI reflects it immediately
      await _actualizarPisoEnCache(prefs, piso, idAnterior: idAnterior);
      return piso;
    }
  }

  Future<void> _actualizarPisoEnCache(
    SharedPreferences prefs,
    Piso piso, {
    String? idAnterior,
  }) async {
    List<Piso> cache = _cargarCacheLocal(prefs);
    int index = cache.indexWhere(
      (p) => p.id == piso.id || (idAnterior != null && p.id == idAnterior),
    );
    if (index >= 0) {
      cache[index] = piso;
    } else {
      cache.add(piso);
    }
    await prefs.setString(_cacheKey, jsonEncode(cache.map((p) => p.toJson()).toList()));
  }

  Future<bool> eliminarPiso(String id) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final client = _supabaseOrNull;
      final user = client?.auth.currentUser;
      if (!id.startsWith('local_') && client != null) {
        await client.from('pisos').delete().eq('id', id);
      }

      // Update cache
      List<Piso> cache = _cargarCacheLocal(prefs);
      cache.removeWhere((p) => p.id == id);
      await prefs.setString(_cacheKey, jsonEncode(cache.map((p) => p.toJson()).toList()));

      // Limpiar también del orden guardado si existía
      final ordenActual = _cargarOrdenDePrefs(prefs, user?.id);
      if (ordenActual.contains(id)) {
        ordenActual.removeWhere((item) => item == id);
        await _guardarOrdenEnPrefs(prefs, user?.id, ordenActual);
        if (client != null && user != null) {
          try {
            await client.auth.updateUser(
              UserAttributes(data: {'orden_pisos': ordenActual}),
            );
          } catch (_) {
            await prefs.setBool(_clavePendienteOrden(user.id), true);
          }
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error deleting floor: $e');
      return false;
    }
  }
}
