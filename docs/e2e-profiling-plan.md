# E2E Latency Profiling Plan

Objetivo: instrumentar cada etapa do hotpath para identificar onde os microssegundos estão sendo gastos, tanto no LB quanto na API.

## 1. Arquitetura de medição

```
LB (io_uring)              API (UDS)
─────────────────          ─────────────

T_accept
  │
  ├── T_connect
  │
[recv_client]
  │
  ├── T_send_be
  │                       [recv UDS]
  │                         ├── T_hdr_parse
  │                         ├── T_json_parse
  │                         ├── T_quantize
  │                         ├── T_score
  │                         │    ├── T_find_centroids
  │                         │    ├── T_pass1
  │                         │    ├── T_pass2
  │                         │    └── T_label_lookup
  │                         └── T_response_write
  │                       [close UDS]
[recv_backend]
  │
  ├── T_send_cl
  │
[free]
```

## 2. Instrumentação na API (`fraud-api/src/main.zig`)

### 2.1. Timer helper (arquivo separado ou no topo)

```zig
const Timer = struct {
    start: u64,
    key: []const u8,
    fn start(key: []const u8) Timer { ... }
    fn end(self: *Timer) void { ... } // log via linux.write(stderr)
};
```

Usar `std.os.linux.clock_gettime(CLOCK.MONOTONIC, &ts)` → ns.

### 2.2. Pontos de medição em `handleConn`

Trecho atual:

```zig
const features = payload.parsePayload(body);
const q = quantization.quantize(&features);
const score = scorer.score(&q);
const approved = score < APPROVAL_THRESHOLD;
```

Instrumentado:

```zig
const t0 = nowNs();

const features = payload.parsePayload(body);
const t1 = nowNs();

const q = quantization.quantize(&features);
const t2 = nowNs();

const score = scorer.score(&q);
const t3 = nowNs();

const approved = score < APPROVAL_THRESHOLD;
// writeResponse...
const t4 = nowNs();

// log a cada 64 reqs
const req_num = req_counter.fetchAdd(1, .monotonic);
if (req_num & 63 == 0) {
    log(stderr, "api: parse={}us quant={}us score={}us write={}us\n",
        .{ (t1-t0)/1000, (t2-t1)/1000, (t3-t2)/1000, (t4-t3)/1000 });
}
```

### 2.3. Sub-etapas do scorer

Dentro de `score()`, adicionar timers nos mesmos pontos:

```zig
const t0 = nowNs();
const cluster_indices = s.findNearestClusters(query, NPROBE);
const t1 = nowNs();
// pass1 loop
const t2 = nowNs();
// pass2
const t3 = nowNs();
// label lookup + return
const t4 = nowNs();
// log a cada 64 reqs
```

### 2.4. Timer helper implementation

```zig
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
           @as(u64, @intCast(ts.nsec));
}
```

Overhead: ~10-20ns por chamada. 5 chamadas = 50-100ns por request (desprezível).

## 3. Instrumentação no LB (`lb-zig/src/main.zig`)

### 3.1. Campos na struct Conn

```zig
const Conn = struct {
    // ... campos existentes ...
    
    // profiling
    t_accept: u64 = 0,   // setado em processAccept
    t_connect_done: u64 = 0, // setado em processConnect
    t_recv_client_done: u64 = 0,
    t_send_backend_done: u64 = 0,
    t_recv_backend_done: u64 = 0,
    t_send_client_done: u64 = 0,
};
```

### 3.2. Pontos de medição

| Local | Campo | Momento |
|-------|-------|---------|
| `processAccept` | `t_accept` = `nowNs()` | após allocConn bem-sucedido |
| `processConnect` | `t_connect_done` = `nowNs()` | antes de submitRecvClient |
| `processRecvClient` | `t_recv_client_done` = `nowNs()` | antes de submitSendBackend |
| `processSendBackend` | `t_send_backend_done` = `nowNs()` | quando n >= to_backend_len (send completo) |
| `processRecvBackend` (res > 0) | `t_recv_backend_done` = `nowNs()` | antes de submitSendClient |
| `processSendClient` | `t_send_client_done` = `nowNs()` | quando n >= to_client_len (send completo) |

### 3.3. Logging

Em `freeConn`, após safeClose, calcular deltas e logar:

```
be: accept={} connect={} recv_cl={} send_be={} recv_be={} send_cl={} total={}
```

Logar a cada N frees (N=128) pra não poluir stderr.

## 4. Load Test

Não usar o benchmark oficial (2 min, muito longo pra debug).

Usar `hey` ou script k6 simples com carga fixa:

```bash
# hey (instalar: go install github.com/rakyll/hey@latest)
hey -n 5000 -c 50 -m POST \
  -H 'Content-Type: application/json' \
  -d '{"id":"tx-1","transaction":{"amount":384.88,"installments":3,"requested_at":"2026-03-11T20:23:35Z"},"customer":{"avg_amount":769.76,"tx_count_24h":3,"known_merchants":["MERC-009","MERC-001"]},"merchant":{"id":"MERC-001","mcc":"5912","avg_amount":298.95},"terminal":{"is_online":false,"card_present":true,"km_from_home":13.7},"last_transaction":{"timestamp":"2026-03-11T14:58:35Z","km_from_current":18.86}}' \
  http://localhost:9999/fraud-score
```

Parâmetros:
- 5000 requests
- 50 conexões concorrentes (simula carga média do benchmark)
- Payload único e pequeno (evita variação de parser)

## 5. Coleta e análise

### 5.1. Formato do log (stderr)

```
api: parse=12 quant=3 score=45 write=2
api_score: find_cent=8 pass1=30 pass2=5 label=2
be: accept=15 connect=10 recv_cl=50 send_be=5 recv_be=120 send_cl=5 total=205
```

### 5.2. Extração dos dados

```bash
docker logs lb-zig 2>&1 | grep "^be:" > /tmp/lb_timings.txt
docker logs api-1 2>&1 | grep "^api:" > /tmp/api_timings.txt
```

### 5.3. Cálculo das métricas

Script python simples pra calcular min/max/avg/p50/p99 de cada etapa:

```python
import sys, statistics

def parse_and_stats(lines, prefix):
    values = {}
    for line in lines:
        if not line.startswith(prefix): continue
        parts = line.strip().split()[1:]
        for p in parts:
            k, v = p.split('=')
            values.setdefault(k, []).append(int(v))
    for k, vs in sorted(values.items()):
        vs.sort()
        print(f"{k}: avg={statistics.mean(vs):.0f} p50={vs[len(vs)//2]} p99={vs[int(len(vs)*0.99)]} min={vs[0]} max={vs[-1]}")
```

## 6. Execução

### Passo a passo

1. **Modificar código da API** (`main.zig`): adicionar timer helper + logging em `handleConn`
2. **Modificar código do scorer** (`scorer.zig`): adicionar timers nas sub-etapas
3. **Modificar código do LB** (`main.zig`): adicionar campos + logging em `freeConn`
4. **Reconstruir imagens**: `docker build -f fraud-api/Dockerfile -t fraud-api:local .` + `zig build-exe lb-zig/src/main.zig ...`
5. **Subir stack**: `docker compose up -d`
6. **Instalar hey** (se não tiver): `go install github.com/rakyll/hey@latest`
7. **Rodar load test**: script acima
8. **Coletar logs**: `docker logs lb-zig 2>&1 | grep "^be:"`, idem api-1/2
9. **Rodar análise**: script python
10. **Identificar gargalo**: etapa com maior contribuição no P99

### Tempo estimado

| Etapa | Tempo |
|-------|-------|
| Modificação API | 10 min |
| Modificação scorer | 10 min |
| Modificação LB | 15 min |
| Rebuild + deploy | 10 min |
| Load test + coleta | 5 min |
| Análise | 10 min |
| **Total** | **~60 min** |

## 7. Riscos

- `clock_gettime` pode não ser monotônico cross-core (skew entre CPUs). Solução: usar `CLOCK_MONOTONIC_RAW` que é ainda mais estável.
- Logging em stderr pode interferir no hotpath. Solução: logar só a cada 64 reqs.
- O LB loga no stdout (fd 1), API logs vão pro stderr do container. Coletar separadamente.
- O `hey` pode saturar conexões do host. Usar `-c 50` que é menor que o k6 (250 VUs).
- `nowNs()` faz syscall `clock_gettime` (~10-20ns). Multiplicado por 7 pontos = ~100ns/req. Em 900 req/s = 90μs/s de overhead. Aceitável.
