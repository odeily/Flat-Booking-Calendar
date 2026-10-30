/**
 * Supabase Edge Function: `export-ical`
 *
 * Exportador público de calendarios iCalendar (RFC 5545) con compactación automática
 * de noches consecutivas (Event Merging) y segmentación anti-bucle por canal destino
 * (`?target=airbnb` / `?target=booking`) para sincronización bidireccional con OTAs.
 */
import { serve } from "https://deno.land/std@0.177.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

interface ReservaDiaJson {
  nombreInquilino?: string
  origen?: string
  tipoOcupacion?: string
  idEventoExt?: string | null
  codigoReserva?: string | null
}

interface DiaNormalizado {
  ymd: string // "YYYY-MM-DD"
  epochDay: number
  origen: string
  nombreInquilino: string
  idEventoExt: string
  codigoReserva: string
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

function parseYmdToUtc(dateStr: string): { ymd: string; epochDay: number } | null {
  const match = dateStr.trim().match(/^(\d{4})-(\d{2})-(\d{2})/)
  if (!match) return null

  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  const utcMs = Date.UTC(year, month - 1, day)
  if (Number.isNaN(utcMs)) return null

  const epochDay = Math.floor(utcMs / 86_400_000)
  return {
    ymd: `${match[1]}-${match[2]}-${match[3]}`,
    epochDay,
  }
}

function epochDayToICalDate(epochDay: number): string {
  const d = new Date(epochDay * 86_400_000)
  const yyyy = d.getUTCFullYear().toString().padStart(4, "0")
  const mm = (d.getUTCMonth() + 1).toString().padStart(2, "0")
  const dd = d.getUTCDate().toString().padStart(2, "0")
  return `${yyyy}${mm}${dd}`
}

function formatUtcTimestamp(date: Date): string {
  const yyyy = date.getUTCFullYear().toString().padStart(4, "0")
  const mm = (date.getUTCMonth() + 1).toString().padStart(2, "0")
  const dd = date.getUTCDate().toString().padStart(2, "0")
  const hh = date.getUTCHours().toString().padStart(2, "0")
  const mi = date.getUTCMinutes().toString().padStart(2, "0")
  const ss = date.getUTCSeconds().toString().padStart(2, "0")
  return `${yyyy}${mm}${dd}T${hh}${mi}${ss}Z`
}

function esBloqueoExterno(res: ReservaDiaJson): boolean {
  if (res.tipoOcupacion === "bloqueoExterno") return true
  if (res.tipoOcupacion === "reservaReal") return false

  // Inferencia retrocompatible para registros antiguos sin tipoOcupacion
  if (!res.origen || res.origen === "manual") return false
  const n = (res.nombreInquilino ?? "").trim().toLowerCase()
  return (
    n.startsWith("bloqueado") ||
    n.includes("not available") ||
    n.includes("unavailable") ||
    n.includes("no disponible") ||
    n === "closed" ||
    n.startsWith("closed - not available")
  )
}

function pertenecenAMismaReserva(a: DiaNormalizado, b: DiaNormalizado): boolean {
  if (a.origen !== b.origen) return false
  if (a.codigoReserva && b.codigoReserva) {
    return a.codigoReserva === b.codigoReserva
  }
  if (a.idEventoExt && b.idEventoExt) {
    return a.idEventoExt === b.idEventoExt
  }
  return a.nombreInquilino === b.nombreInquilino
}

function escapeICalText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n")
}

// RFC 5545 Sec 3.1: Plegado de líneas a máximo 75 octetos UTF-8 con CRLF + espacio
function foldICalLine(line: string): string {
  const encoder = new TextEncoder()
  if (encoder.encode(line).length <= 75) return line

  const segments: string[] = []
  let current = ""
  let currentBytes = 0
  let maxLimit = 75

  for (const ch of line) {
    const chBytes = encoder.encode(ch).length
    if (currentBytes + chBytes > maxLimit && current.length > 0) {
      segments.push(current)
      current = " " + ch
      currentBytes = 1 + chBytes
      maxLimit = 75
    } else {
      current += ch
      currentBytes += chBytes
    }
  }
  if (current.length > 0) {
    segments.push(current)
  }
  return segments.join("\r\n")
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  const url = new URL(req.url)
  let pisoId = url.searchParams.get("piso_id")?.trim() || null
  let target = url.searchParams.get("target")?.trim().toLowerCase() || null

  // Soporte adicional por ruta .ics (ej: /export-ical/<pisoId>_airbnb.ics o /export-ical/<pisoId>.ics)
  if (!pisoId) {
    const segments = url.pathname.split("/").filter(Boolean)
    const lastSeg = segments[segments.length - 1] ?? ""
    if (lastSeg.toLowerCase().endsWith(".ics")) {
      const base = lastSeg.slice(0, -4)
      if (base.toLowerCase().endsWith("_airbnb")) {
        pisoId = base.slice(0, -7)
        if (!target) target = "airbnb"
      } else if (base.toLowerCase().endsWith("_booking")) {
        pisoId = base.slice(0, -8)
        if (!target) target = "booking"
      } else if (base.toLowerCase() !== "calendario") {
        pisoId = base
      }
    }
  }

  if (!pisoId) {
    return new Response("Missing piso_id", { status: 400, headers: corsHeaders })
  }

  if (target && target !== "airbnb" && target !== "booking") {
    return new Response("Invalid target parameter. Allowed: airbnb, booking", {
      status: 400,
      headers: corsHeaders,
    })
  }

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  )

  const { data, error } = await supabaseAdmin
    .from("pisos")
    .select("nombre, reservas")
    .eq("id", pisoId)
    .single()

  if (error || !data) {
    return new Response("Piso not found", { status: 404, headers: corsHeaders })
  }

  const reservasRaw = (data.reservas ?? {}) as Record<string, ReservaDiaJson>
  const diasValidos: DiaNormalizado[] = []

  for (const [dateStr, res] of Object.entries(reservasRaw)) {
    if (!res) continue

    // Excluir cierres externos vacíos para evitar bucles de retroalimentación entre OTAs
    if (esBloqueoExterno(res)) continue

    const origen = (res.origen ?? "manual").toLowerCase()

    // Feeds segmentados anti-bucle:
    // ?target=airbnb  -> excluye reservas nacidas en Airbnb
    // ?target=booking -> excluye reservas nacidas en Booking
    if (target === "airbnb" && origen === "airbnb") continue
    if (target === "booking" && origen === "booking") continue

    const parsed = parseYmdToUtc(dateStr)
    if (!parsed) continue

    diasValidos.push({
      ymd: parsed.ymd,
      epochDay: parsed.epochDay,
      origen,
      nombreInquilino: (res.nombreInquilino ?? "Reservado").trim(),
      idEventoExt: (res.idEventoExt ?? "").trim(),
      codigoReserva: (res.codigoReserva ?? "").trim(),
    })
  }

  // Ordenar fechas cronológicamente y eliminar posibles claves duplicadas del mismo día
  diasValidos.sort((a, b) => a.epochDay - b.epochDay)
  const diasUnicos: DiaNormalizado[] = []
  for (const d of diasValidos) {
    if (diasUnicos.length === 0 || diasUnicos[diasUnicos.length - 1].epochDay !== d.epochDay) {
      diasUnicos.push(d)
    }
  }

  // Compactación de días contiguos (Event Merging)
  interface RangoCompactado {
    startEpochDay: number
    endExclusiveEpochDay: number
    origen: string
    nombreInquilino: string
  }

  const rangos: RangoCompactado[] = []
  for (let i = 0; i < diasUnicos.length; i++) {
    const dia = diasUnicos[i]
    const ultimo = rangos[rangos.length - 1]
    const prevDia = i > 0 ? diasUnicos[i - 1] : null

    if (
      ultimo &&
      ultimo.endExclusiveEpochDay === dia.epochDay &&
      prevDia &&
      prevDia.epochDay === dia.epochDay - 1 &&
      pertenecenAMismaReserva(prevDia, dia)
    ) {
      ultimo.endExclusiveEpochDay = dia.epochDay + 1
    } else {
      rangos.push({
        startEpochDay: dia.epochDay,
        endExclusiveEpochDay: dia.epochDay + 1,
        origen: dia.origen,
        nombreInquilino: dia.nombreInquilino,
      })
    }
  }

  const dtstamp = formatUtcTimestamp(new Date())
  const calNameSuffix = target ? ` (${target.toUpperCase()})` : ""
  const calName = escapeICalText(`${data.nombre || "Calendario Piso"}${calNameSuffix}`)

  const lines: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//CalendarioPisos//Channel Manager RFC5545//ES",
    "CALSCALE:GREGORIAN",
    foldICalLine(`X-WR-CALNAME:${calName}`),
  ]

  for (const rango of rangos) {
    const inicio = epochDayToICalDate(rango.startEpochDay)
    const fin = epochDayToICalDate(rango.endExclusiveEpochDay)
    const uid = `res-${pisoId}-${inicio}-${fin}@calendariopisos`

    lines.push("BEGIN:VEVENT")
    lines.push(foldICalLine(`UID:${uid}`))
    lines.push(`DTSTAMP:${dtstamp}`)
    lines.push(`DTSTART;VALUE=DATE:${inicio}`)
    lines.push(`DTEND;VALUE=DATE:${fin}`)
    lines.push("SUMMARY:Ocupado / Reservado")
    if (!target) {
      // En calendarios personales sin target se incluye detalle informativo en DESCRIPTION
      const desc = escapeICalText(`${data.nombre}: ${rango.nombreInquilino} [${rango.origen}]`)
      lines.push(foldICalLine(`DESCRIPTION:${desc}`))
    }
    lines.push("STATUS:CONFIRMED")
    lines.push("TRANSP:OPAQUE")
    lines.push("END:VEVENT")
  }

  lines.push("END:VCALENDAR")
  const icalBody = lines.join("\r\n") + "\r\n"
  const filenameSuffix = target ? `_${target}` : ""

  return new Response(req.method === "HEAD" ? null : icalBody, {
    status: 200,
    headers: {
      ...corsHeaders,
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": `inline; filename="calendario_${pisoId}${filenameSuffix}.ics"`,
      "Cache-Control": "no-cache, no-store, must-revalidate",
    },
  })
})
