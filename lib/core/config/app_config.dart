/// Configuración centralizada de entorno inyectada en tiempo de compilación.
///
/// Las credenciales se cargan de forma segura mediante `--dart-define-from-file=env.json`
/// para evitar exponer URLs de infraestructura o claves públicas en el control de versiones.
/// Si no se inyectan variables (por ejemplo, al clonar el repositorio para evaluación
/// o ejecutar pruebas automatizadas), la aplicación arranca automáticamente en
/// **Modo Demo Offline-First** respaldado por almacenamiento local.
abstract final class AppConfig {
  /// URL base del proyecto en Supabase (`https://<project-ref>.supabase.co`).
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');

  /// Clave pública/anónima de cliente de Supabase protegida por políticas RLS.
  static const String supabasePublishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// Esquema de enlace profundo registrado en Android e iOS para flujos de autenticación.
  static const String authRedirectUrl = 'calendariopisos://login-callback';

  /// Indica si se han proporcionado credenciales válidas de Supabase en compilación.
  static bool get isSupabaseConfigured =>
      supabaseUrl.trim().isNotEmpty &&
      supabasePublishableKey.trim().isNotEmpty &&
      !supabaseUrl.contains('your-project-ref');

  /// Endpoint base de la Edge Function `export-ical` derivado dinámicamente del proyecto.
  static String get exportIcalBaseUrl {
    final trimmed = supabaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isNotEmpty && !trimmed.contains('your-project-ref')) {
      return '$trimmed/functions/v1/export-ical';
    }
    return 'https://demo-offline.supabase.co/functions/v1/export-ical';
  }
}
