# Rinha 2026 — Refatoração Completa Design Spec

> Data: 2026-05-15
> Branch de trabalho: `chore/bun`

---

## 1. Objetivo

Refatorar completamente o repositório da Rinha de Backend 2026, removendo a implementação antiga (Zig + Go) e construindo uma nova solução com:

- **Load Balancer** em C++ (TCP:9999 → UDS round-robin)
- **Fraud API** em Bun (HTTP/UDS → JSON parse → vectorize → KNN via C++ addon)
- **Preprocessamento** em C++ (gera índice binário mmap-compatível)
- **Script de redução de dataset** que produz um arquivo binário menor mantendo resultados KNN exatos

---

## 2. Contexto Oficial

A Rinha 2026 exige:

- Dois endpoints: `GET /ready` e `POST /fraud-score`
- Vetorização de 14 dimensões com normalização fixa
- Busca dos 5 vizinhos mais próximos (KNN, k=5) em 3.000.000 vetores
- `fraud_score = frauds / 5`, `approved = fraud_score < 0.6`
- LB + 2+ instâncias da API, round-robin
- Limite total: 1 CPU + 350 MB RAM
- Rede `bridge`, sem `host`/`privileged`
- Imagens públicas `linux/amd64`
- Arquivos de referência imutáveis no build/startup

O teste oficial usa k6 com payloads pré-rotulados por brute-force exato (distância euclidiana). O score final depende de latência (p99, teto em 1ms → +3000) e detecção (taxa de falhas < 15%).

---

## 3. Arquitetura

```
[Cliente k6] → TCP:9999 [C++ LB] → UDS round-robin → [Bun API 1]
                                                  → [Bun API 2]
                                                  → [Bun API N]
```

### 3.1 Load Balancer (`load-balancer/`)

- **Linguagem:** C++17/20
- **I/O:** io_uring (liburing) para accept + read/write minimizando syscalls
- **Single-threaded** (ou 1 thread de event loop + 1 thread de worker se necessário)
- **Frontal:** TCP socket em `0.0.0.0:9999`
- **Backends:** UDS sockets em `/tmp/rinha/api-1.sock`, `/tmp/rinha/api-2.sock`, …
- **Algoritmo:** Round-robin simples, sem lógica de negócio, sem inspeção de payload
- **Comportamento:**
  1. `accept()` conn cliente via io_uring
  2. Seleciona próximo backend UDS
  3. Conecta ao backend UDS (reutiliza conexão se keep-alive / pool)
  4. Copia bytes cliente → backend e backend → cliente (zero-copy via splice se viável)
  5. Fecha conn quando EOF ou erro; libera recursos imediatamente
- **Hot reload em dev:** binário compilado localmente, container monta o binário via volume; restart do container pega novo binário

### 3.2 Fraud API (`fraud-api/`)

- **Linguagem:** Bun (TypeScript/JavaScript) + C++ addon nativo
- **Servidor:** `Bun.serve()` ouvindo em UDS socket
- **Endpoints:**
  - `GET /ready` → `200 OK` (simples, sem lógica)
  - `POST /fraud-score` → parse JSON, vectorize, chamar addon C++ `knnSearch`, responder `{approved, fraud_score}`
- **Vectorização:** implementada em TS puro (14 dimensões, normalização com constantes de `normalization.json` e `mcc_risk.json`)
- **KNN:** delegado a addon C++ via Bun FFI (`bun:ffi`)
- **Dataset:** arquivo binário mmapado em memória compartilhada entre as 2 instâncias (via volume compartilhado no Docker, ou arquivo no host mapeado para ambos)

### 3.3 C++ Addon / Scoring Engine (`fraud-api/native/` ou `shared/engine/`)

- **Linguagem:** C++17/20 compilado como shared library `.so`
- **Interface FFI:** função C exposta: `int knn_search(const float* query, int k, uint32_t* out_indices, float* out_distances)`
- **Algoritmo:** IVF (Inverted File Index)
  - Pré-processamento clusteriza os 3M vetores em ~512 centroides (k-means simples ou k-means++ aproximado)
  - No runtime: calcula distância do query aos 512 centroides, seleciona os 16 clusters mais próximos (NPROBE=16)
  - Busca brute-force exata dentro desses 16 clusters (~93k vetores, ~1.3M distâncias)
  - Mantém top-5 com max-heap de tamanho 5
  - Retorna os 5 vizinhos + suas distâncias; o addon também retorna os labels (0/1) para o Bun calcular o score
- **Dados em memória:**
  - Vetores em `float16` (ou `float32` se precisar) via `mmap()` do arquivo binário gerado no preprocess
  - Centroides e índices invertidos (lista de IDs por cluster) em memória alocada no startup do addon
- **Distância:** euclidiana exata (L2) — alinhada com o brute-force oficial

### 3.4 Preprocessamento (`scripts/preprocess.cpp`)

- **Entrada:** `.cache/rinha-official/resources/references.json.gz`
- **Saídas:**
  1. `vector-index/dataset.bin` — vetores em f16 ou f32 denso (14 dims × 3M = ~84MB f16 ou ~168MB f32)
  2. `vector-index/labels.bin` — 1 byte por vetor (fraud=1, legit=0) = 3MB
  3. `vector-index/ivf_index.bin` — centroides (512 × 14 dims) + posting lists (offsets e IDs)
- **Passos:**
  1. Descomprime `references.json.gz`
  2. Lê e converte vetores para array denso f16/f32 + labels
  3. Executa k-means++ em C++ para gerar 512 centroides
  4. Atribui cada vetor ao centroide mais próximo
  5. Escreve os 3 arquivos binários
- **Execução:** via `make preprocess` ou no build do container Docker

### 3.5 Script de Redução de Dataset (`scripts/reduce_dataset.cpp`)

- **Objetivo:** produzir um dataset menor a partir de `references.json.gz` que ainda mantém resultados KNN exatos (ou o mais próximo possível)
- **Estratégia:**
  - Usar o mesmo preprocessamento do IVF (k-means++ em 512 clusters)
  - Para cada cluster, identificar vetores que são "fronteira" (próximos de outros clusters) e vetores "interiores"
  - Manter todos os vetores de fronteira; para vetores interiores, manter apenas um subconjunto representativo (ex: média do cluster + amostra aleatória)
  - Ou, abordagem mais simples e robusta: **amostragem estratificada por cluster** — manter uma proporção fixa de vetores de cada cluster, garantindo cobertura espacial uniforme
  - Outra alternativa: **usar os centroides como representantes** e adicionar outliers detectados por distância ao centroide
- **Critério de parada:** o dataset reduzido deve ter <= X% do tamanho original (ex: 10% = 300k vetores) e, quando testado contra um conjunto de validação de queries, produzir os mesmos 5 vizinhos em >99% dos casos
- **Saída:** `vector-index/dataset_reduced.bin` + `labels_reduced.bin` + `ivf_index_reduced.bin`

---

## 4. Docker Compose

```yaml
services:
  preprocess:
    image: gcc:13-bookworm
    command: ["/workspace/scripts/preprocess.sh"]
    volumes:
      - ./:/workspace

  api-1: &api
    image: oven/bun:canary
    command: ["bun", "run", "/app/src/index.ts"]
    volumes:
      - ./fraud-api:/app
      - ./vector-index:/data:ro
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    depends_on:
      preprocess:
        condition: service_completed_successfully
    deploy:
      resources:
        limits:
          cpus: '0.35'
          memory: '128MB'

  api-2:
    <<: *api

  lb:
    image: debian:bookworm-slim
    command: ["/app/lb"]
    ports:
      - '9999:9999'
    volumes:
      - ./load-balancer/build/lb:/app/lb
      - rinha-sockets:/tmp/rinha
    networks:
      - rinha-net
    depends_on:
      - api-1
      - api-2
    deploy:
      resources:
        limits:
          cpus: '0.15'
          memory: '64MB'

networks:
  rinha-net:
    driver: bridge

volumes:
  rinha-sockets:
```

**Alocação de recursos (exemplo):**
- LB: 0.15 CPU / 64 MB
- API 1+2: 0.35 CPU / 128 MB cada → total API = 0.70 CPU / 256 MB
- Total: 0.85 CPU / 320 MB (dentro do limite de 1 CPU / 350 MB)

---

## 5. Hot Reload (Dev)

- **LB:** `make lb` recompila o binário C++ localmente. O container monta o binário via volume. `docker compose restart lb` pega o novo binário.
- **API:** o código Bun está montado via volume. `Bun.serve()` com `--watch` ou restart do container pega as mudanças automaticamente. O addon C++ `.so` também está montado; se recompilado, restart do container da API.

---

## 6. Makefile

```makefile
.PHONY: all preprocess build lb api benchmark clean

all: preprocess build

preprocess:
	g++ -O3 scripts/preprocess.cpp -o scripts/preprocess -lz && \
	./scripts/preprocess

lb:
	g++ -O3 -std=c++20 -luring load-balancer/src/main.cpp -o load-balancer/build/lb

api:
	cd fraud-api && bun install && bun run build-native

benchmark:
	cd .cache/rinha-official && ./run.sh

clean:
	rm -rf load-balancer/build/* fraud-api/dist/* vector-index/*.bin
```

---

## 7. Estrutura de Diretórios Final

```
load-balancer/
  src/main.cpp
  build/
  Dockerfile
fraud-api/
  src/index.ts
  src/vectorize.ts
  native/
    knn.cpp
    knn.h
    binding.cpp
  package.json
  tsconfig.json
  Dockerfile
scripts/
  preprocess.cpp       # gera dataset.bin + labels.bin + ivf_index.bin
  reduce_dataset.cpp   # gera dataset reduzido mantendo KNN exato
  preprocess.sh        # wrapper script invocado pelo container
vector-index/          # gitignored, gerado no build
  dataset.bin
  labels.bin
  ivf_index.bin
  (opcional) dataset_reduced.bin
  (opcional) labels_reduced.bin
  (opcional) ivf_index_reduced.bin
docker-compose.yml
Makefile
README.md
AGENTS.md
docs/
  superpowers/
    specs/YYYY-MM-DD-rinha-refactor-design.md
    plans/YYYY-MM-DD-rinha-refactor-plan.md
```

---

## 8. Riscos e Mitigações

| Risco | Mitigação |
|---|---|
| Bun FFI com C++ addon pode ser instável ou lento para chamadas frequentes | Testar early com benchmark; se lento, mover mais lógica para C++ (ex: toda a pipeline de vectorize+KNN em C++, Bun apenas como HTTP layer) |
| io_uring pode não estar disponível no ambiente de teste (kernel antigo) | Compilar com fallback para `epoll`/`select` ou usar imagem Docker com kernel >= 5.1 |
| IVF pode não ser suficientemente preciso (falsos vizinhos) | Ajustar NPROBE e número de clusters; testar com dataset reduzido contra brute-force exato |
| Memória do addon C++ + Bun > 128MB por instância | Usar f16 para vetores, mmap para o dataset, monitorar RSS |
| Hot reload do binário C++ requer restart do container | Aceitável; o container reinicia em <1s |

---

## 9. Critérios de Sucesso

- [ ] `docker compose up --build` sobe LB + 2 APIs sem erro
- [ ] `GET /ready` retorna 200
- [ ] `POST /fraud-score` retorna resposta correta para payloads de exemplo
- [ ] `make benchmark` roda o teste oficial e produz `results.json`
- [ ] `make preprocess` gera os binários do dataset e do índice
- [ ] `scripts/reduce_dataset` produz um dataset menor com >99% de acurácia KNN
- [ ] Nenhum rastro da implementação antiga (Zig, Go) nos docs principais

---

## 10. Próximos Passos

1. Aprovação deste design spec
2. Criação do plano de implementação (writing-plans skill)
3. Execução task-by-task via subagent-driven-development
