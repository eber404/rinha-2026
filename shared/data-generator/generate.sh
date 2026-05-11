#!/usr/bin/env bun
import { readFileSync, writeFileSync, mkdirSync } from 'fs'
import { execSync } from 'child_process'

const SHARED_DATA = './shared/data'
const DATA_DIR = './fraud-api/data'
mkdirSync(DATA_DIR, { recursive: true })

console.log("=== Downloading reference files ===")
const urls = [
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/references.json.gz",
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/normalization.json",
    "https://github.com/zanfranceschi/rinha-de-backend-2026/raw/main/resources/mcc_risk.json"
]

for (const url of urls) {
    const filename = url.split('/').pop()!
    execSync(`curl -sL -o ${DATA_DIR}/${filename} ${url}`)
    console.log(`Downloaded ${filename}`)
}

console.log("=== Decompressing references ===")
execSync(`gunzip -f ${DATA_DIR}/references.json.gz`)

const DATA_FILE = `${DATA_DIR}/references.json`

console.log('Reading references.json...')
const raw = readFileSync(DATA_FILE, 'utf8')
interface Record {
  vector: number[]
  label: string
}
const data: Record[] = JSON.parse(raw)
const N = data.length
console.log(`Loaded ${N} records`)

const DIMS = 14
const NUM_CLUSTERS = 256

const labels: number[] = data.map((r) => (r.label === 'fraud' ? 1 : 0))

console.log('Calculating statistics...')
const means = new Float64Array(DIMS)
const stds = new Float64Array(DIMS)
const mins = new Float64Array(DIMS)
const maxs = new Float64Array(DIMS)

for (const rec of data) {
  const v = rec.vector
  for (let d = 0; d < DIMS; d++) {
    means[d] += v[d]
    if (v[d] < mins[d]) mins[d] = v[d]
    if (v[d] > maxs[d]) maxs[d] = v[d]
  }
}
for (let d = 0; d < DIMS; d++) means[d] /= N

for (const rec of data) {
  const v = rec.vector
  for (let d = 0; d < DIMS; d++) {
    const diff = v[d] - means[d]
    stds[d] += diff * diff
  }
}
for (let d = 0; d < DIMS; d++) {
  stds[d] = Math.sqrt(stds[d] / N)
  if (stds[d] < 1e-6) stds[d] = 1
}

console.log('Dimension stats (min/max/mean/std):')
for (let d = 0; d < DIMS; d++) {
  console.log(
    `  [${d}] ${mins[d].toFixed(4)} / ${maxs[d].toFixed(4)} / ${means[d].toFixed(4)} / ${stds[d].toFixed(4)}`
  )
}

const scales = stds
const offsets = means

console.log('\nNormalizing and quantizing to int8...')

const vectors_i8_buf = new Uint8Array(N * 16)

for (let i = 0; i < N; i++) {
  const v = data[i].vector
  for (let d = 0; d < DIMS; d++) {
    const normalized = (v[d] - offsets[d]) / scales[d]
    let q = Math.round(normalized * 127)
    if (q > 127) q = 127
    if (q < -127) q = -127
    vectors_i8_buf[i * 16 + d] = q < 0 ? q + 256 : q
  }
  vectors_i8_buf[i * 16 + 14] = 0
  vectors_i8_buf[i * 16 + 15] = 0
}

console.log('Computing centroids via sampling (fast IVF)...')

const centroids = new Float64Array(NUM_CLUSTERS * DIMS)
const clusterCounts = new Uint32Array(NUM_CLUSTERS)

const sampleSize = Math.min(N, 50000)
const random = () => {
  let x = Math.sin(Date.now() + Math.random() * 10000) * 10000
  return x - Math.floor(x)
}

for (let i = 0; i < sampleSize; i++) {
  const idx = Math.floor(random() * N)
  const v = data[idx].vector
  const c = i % NUM_CLUSTERS
  clusterCounts[c]++
  for (let d = 0; d < DIMS; d++) {
    centroids[c * DIMS + d] += v[d]
  }
}

for (let c = 0; c < NUM_CLUSTERS; c++) {
  if (clusterCounts[c] > 0) {
    for (let d = 0; d < DIMS; d++) {
      centroids[c * DIMS + d] /= clusterCounts[c]
    }
  }
}

console.log('Assigning vectors to clusters...')
const clusterAssignments = new Uint32Array(N)
const clusterRanges: { start: number; end: number }[] = Array.from(
  { length: NUM_CLUSTERS },
  () => ({ start: N, end: 0 })
)

for (let i = 0; i < N; i++) {
  const v = data[i].vector
  let bestC = 0
  let bestDist = Infinity
  for (let c = 0; c < NUM_CLUSTERS; c++) {
    let dist = 0
    for (let d = 0; d < DIMS; d++) {
      const diff = v[d] - centroids[c * DIMS + d]
      dist += diff * dist
    }
    if (dist < bestDist) {
      bestDist = dist
      bestC = c
    }
  }
  clusterAssignments[i] = bestC
  if (i < clusterRanges[bestC].start) clusterRanges[bestC].start = i
  if (i > clusterRanges[bestC].end) clusterRanges[bestC].end = i
}

for (let c = 0; c < NUM_CLUSTERS; c++) {
  clusterRanges[c].end++
}

console.log('Quantizing centroids to int8...')
const centroids_i8_buf = new Uint8Array(NUM_CLUSTERS * 16)

for (let c = 0; c < NUM_CLUSTERS; c++) {
  for (let d = 0; d < DIMS; d++) {
    const val = centroids[c * DIMS + d]
    const normalized = (val - offsets[d]) / scales[d]
    let q = Math.round(normalized * 127)
    if (q > 127) q = 127
    if (q < -127) q = -127
    centroids_i8_buf[c * 16 + d] = q < 0 ? q + 256 : q
  }
  centroids_i8_buf[c * 16 + 14] = 0
  centroids_i8_buf[c * 16 + 15] = 0
}

console.log('\nWriting binary files...')

writeFileSync(`${DATA_DIR}/vectors_i8.bin`, Buffer.from(vectors_i8_buf))
console.log(`  vectors_i8.bin: ${N * 16} bytes`)

writeFileSync(`${DATA_DIR}/labels.bin`, Buffer.from(new Uint8Array(labels)))
console.log(`  labels.bin: ${N} bytes`)

writeFileSync(`${DATA_DIR}/centroids_i8.bin`, Buffer.from(centroids_i8_buf))
console.log(`  centroids_i8.bin: ${NUM_CLUSTERS * 16} bytes`)

const clusterOffsetsBuf = Buffer.alloc(NUM_CLUSTERS * 8)
for (let c = 0; c < NUM_CLUSTERS; c++) {
  clusterOffsetsBuf.writeUInt32LE(clusterRanges[c].start, c * 8)
  clusterOffsetsBuf.writeUInt32LE(clusterRanges[c].end, c * 8 + 4)
}
writeFileSync(`${DATA_DIR}/cluster_offsets.bin`, clusterOffsetsBuf)
console.log(`  cluster_offsets.bin: ${NUM_CLUSTERS * 8} bytes`)

const scalesBuf = Buffer.alloc(14 * 4)
for (let d = 0; d < 14; d++) scalesBuf.writeFloatLE(scales[d], d * 4)
writeFileSync(`${DATA_DIR}/scales.bin`, scalesBuf)
console.log(`  scales.bin: 56 bytes`)

const offsetsBuf = Buffer.alloc(14 * 4)
for (let d = 0; d < 14; d++) offsetsBuf.writeFloatLE(offsets[d], d * 4)
writeFileSync(`${DATA_DIR}/offsets.bin`, offsetsBuf)
console.log(`  offsets.bin: 56 bytes`)

console.log('\nWriting refs.bin (flat vector + label)...')
const refsBuf = Buffer.alloc(N * (14 * 4 + 1))
for (let i = 0; i < N; i++) {
  const v = data[i].vector
  for (let d = 0; d < 14; d++) {
    refsBuf.writeFloatLE(v[d], i * 57 + d * 4)
  }
  refsBuf[i * 57 + 56] = labels[i]
}
writeFileSync(`${DATA_DIR}/refs.bin`, refsBuf)
console.log(`  refs.bin: ${N * 57} bytes`)

console.log('\nDone!')
