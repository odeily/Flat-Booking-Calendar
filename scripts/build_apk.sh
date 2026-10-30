#!/usr/bin/env bash
set -euo pipefail

# Script de compilación de APK de producción inyectando variables de entorno locales.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f "env.json" ]]; then
  echo "❌ Error: No se encontró 'env.json' en la raíz del proyecto."
  echo "   Copia 'env.example.json' a 'env.json' y rellena tus credenciales de Supabase."
  exit 1
fi

VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)"
mkdir -p releases

echo "🚀 Compilando Calendario Pisos v${VERSION} (Release)..."
flutter build apk --release --dart-define-from-file=env.json

OUTPUT_APK="releases/calendario_pisos_v${VERSION}.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$OUTPUT_APK"

echo "✅ APK generado correctamente en: $OUTPUT_APK"
