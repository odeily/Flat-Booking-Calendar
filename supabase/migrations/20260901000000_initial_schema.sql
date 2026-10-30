-- =============================================================================
-- Migración inicial: Esquema PostgreSQL, Políticas RLS y RPC GDPR
-- Proyecto: Calendario Pisos (Channel Manager iCal RFC 5545)
-- =============================================================================

-- 1. Tabla principal de inmuebles y calendario consolidado JSONB
CREATE TABLE IF NOT EXISTS public.pisos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    nombre TEXT NOT NULL,
    url_airbnb TEXT,
    url_booking TEXT,
    ultima_sincronizacion TIMESTAMPTZ,
    reservas JSONB NOT NULL DEFAULT '{}'::jsonb,
    colores_inquilinos JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pisos_user_id ON public.pisos(user_id);

-- 2. Seguridad a Nivel de Fila (Row Level Security)
ALTER TABLE public.pisos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Usuarios leen exclusivamente sus propios pisos"
    ON public.pisos FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Usuarios insertan exclusivamente sus propios pisos"
    ON public.pisos FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Usuarios actualizan exclusivamente sus propios pisos"
    ON public.pisos FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Usuarios eliminan exclusivamente sus propios pisos"
    ON public.pisos FOR DELETE
    USING (auth.uid() = user_id);

-- 3. Función RPC de derecho al olvido (borrado integral de cuenta y datos asociados)
CREATE OR REPLACE FUNCTION public.delete_user()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM public.pisos WHERE user_id = auth.uid();
    DELETE FROM auth.users WHERE id = auth.uid();
END;
$$;
