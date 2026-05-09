import { serve } from 'bun'
import { existsSync, readFileSync } from 'fs'

const INSTANCE_ID = Bun.env.INSTANCE_ID ?? 'unknown'
const PORT = parseInt(Bun.env.PORT ?? '8080')
const DATA_DIR = Bun.env.DATA_DIR ?? '/app/data'

const K_NEIGHBORS = 5
const FRAUD_THRESHOLD = 0.6
const VECTOR_DIM = 14

let normalization: any = null
let mccRisk: any = null

let refIndexData: DataView | null = null
let refIndexCount = 0

function loadData() {
  try {
    const normPath = `${DATA_DIR}/normalization.json`
    normalization = existsSync(normPath)
      ? JSON.parse(readFileSync(normPath, 'utf8'))
      : { max_amount: 10000, max_installments: 12, amount_vs_avg_ratio: 10, max_minutes: 1440, max_km: 1000, max_tx_count_24h: 20, max_merchant_avg_amount: 10000 }

    const mccPath = `${DATA_DIR}/mcc_risk.json`
    mccRisk = existsSync(mccPath) ? JSON.parse(readFileSync(mccPath, 'utf8')) : {}

    const refPath = `${DATA_DIR}/refs.bin`
    if (existsSync(refPath)) {
      const buf = readFileSync(refPath)
      refIndexData = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
      refIndexCount = Math.floor(buf.byteLength / (VECTOR_DIM * 4 + 1))
    }
  } catch (e) {
    console.error(`[${INSTANCE_ID}] Load error: ${e}`)
  }
}

loadData()

const server = serve({
  port: PORT,
  fetch(req) {
    const url = new URL(req.url)
    if (url.pathname === '/ready' && req.method === 'GET') {
      return jsonResponse({ ready: true, instance: INSTANCE_ID })
    }
    if (url.pathname === '/fraud-score' && req.method === 'POST') {
      return handleFraudScore(req)
    }
    return jsonResponse({ error: 'not found' }, 404)
  },
})

console.log(`[${INSTANCE_ID}] TCP:${PORT} refs:${refIndexCount}`)

function handleFraudScore(req: Request): Response {
  const payload = parsePayload(req)
  if (!payload) return jsonResponse({ error: 'invalid payload' }, 400)

  const vector = normalizeToVector(payload)
  const fraudScore = searchKnn(vector)
  const approved = fraudScore < FRAUD_THRESHOLD

  return jsonResponse({
    id: payload.id ?? 'unknown',
    approved,
    fraud_score: Math.round(fraudScore * 1000) / 1000,
    instance: INSTANCE_ID,
  })
}

function parsePayload(req: Request): Record<string, any> | null {
  try {
    return req.json()
  } catch {
    return null
  }
}

function normalizeToVector(p: Record<string, any>): Float32Array {
  const v = new Float32Array(VECTOR_DIM)
  const tx = p.transaction ?? {}
  const cust = p.customer ?? {}
  const merch = p.merchant ?? {}
  const term = p.terminal ?? {}
  const last = p.last_transaction ?? null

  v[0] = clamp(tx.amount / normalization.max_amount)
  v[1] = clamp(tx.installments / normalization.max_installments)
  v[2] = clamp(tx.amount / cust.avg_amount / normalization.amount_vs_avg_ratio)
  v[3] = hourOfDay(tx.requested_at) / 23
  v[4] = dayOfWeek(tx.requested_at) / 6

  if (last === null) {
    v[5] = -1
    v[6] = -1
  } else {
    v[5] = clamp(last.minutes / normalization.max_minutes)
    v[6] = clamp(last.km_from_current / normalization.max_km)
  }

  v[7] = clamp(term.km_from_home / normalization.max_km)
  v[8] = clamp(cust.tx_count_24h / normalization.max_tx_count_24h)
  v[9] = term.is_online ? 1 : 0
  v[10] = term.card_present ? 1 : 0
  v[11] = isUnknownMerchant(merch.id, cust.known_merchants) ? 1 : 0
  v[12] = mccRisk[merch.mcc] ?? 0.5
  v[13] = clamp(merch.avg_amount / normalization.max_merchant_avg_amount)

  return v
}

function clamp(value: number): number {
  return Math.min(1, Math.max(0, value))
}

function hourOfDay(isoString: string): number {
  if (!isoString) return 0
  return new Date(isoString).getUTCHours()
}

function dayOfWeek(isoString: string): number {
  if (!isoString) return 0
  return new Date(isoString).getUTCDay()
}

function isUnknownMerchant(merchantId: string, knownMerchants: string[]): boolean {
  if (!merchantId || !knownMerchants) return true
  return !knownMerchants.includes(merchantId)
}

function searchKnn(query: Float32Array): number {
  if (refIndexCount === 0) return 0

  const distances: { idx: number; dist: number }[] = []

  for (let i = 0; i < refIndexCount; i++) {
    const dist = euclideanDistanceAt(query, i)
    distances.push({ idx: i, dist })
  }

  distances.sort((a, b) => a.dist - b.dist)

  const kNearest = distances.slice(0, K_NEIGHBORS)
  let fraudCount = 0
  for (const d of kNearest) {
    if (labelAt(d.idx) === 1) fraudCount++
  }

  return fraudCount / K_NEIGHBORS
}

function euclideanDistanceAt(a: Float32Array, refIdx: number): number {
  let sum = 0
  for (let i = 0; i < VECTOR_DIM; i++) {
    const d = a[i] - vectorAt(refIdx, i)
    sum += d * d
  }
  return Math.sqrt(sum)
}

function vectorAt(refIdx: number, dim: number): number {
  const dv = refIndexData
  if (!dv) return 0
  return dv.getFloat32(refIdx * (VECTOR_DIM * 4 + 1) + dim * 4, true)
}

function labelAt(refIdx: number): number {
  const dv = refIndexData
  if (!dv) return 0
  return dv.getUint8(refIdx * (VECTOR_DIM * 4 + 1) + VECTOR_DIM * 4)
}

function jsonResponse(data: object, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } })
}