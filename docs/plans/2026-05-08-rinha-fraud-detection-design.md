# Rinha 2026 — Detecção de Fraude por Busca Vetorial

## Overview

Monorepo com:
- **Load Balancer**: Zig puro (std.net), round-robin
- **API**: Bun puro, busca vetorial com índice binário
- **Porta**: 9999

## Arquitetura

```
[ cliente ] → :9999 (LB Zig, round-robin) → :9999 (API Bun 1)
                                               :9999 (API Bun 2)
```

## Componentes

### 1. Load Balancer (Zig)
- Escuta na porta 9999
- Round-robin entre N instâncias
- Proxy puro — sem lógica de fraude
- Usa std.net (sem dependências externas)

### 2. API Fraud Detection (Bun)
Endpoints:
- `GET /ready` → 200 OK
- `POST /fraud-score` → `{ approved: bool, fraud_score: number }`

Fluxo:
1. Parse payload
2. Normaliza para vetor 14D (REGRAS_DE_DETECCAO.md)
3. Busca 5 vizinhos mais próximos no índice binário
4. fraud_score = fraud_count / 5
5. approved = fraud_score < 0.6

### 3. Build Script
- Baixa `references.json.gz`, `normalization.json`, `mcc_risk.json`
- Converte para bináriommap otimizado (`index.bin`)
- Gera `normalization.bin` e `mcc_risk.bin`

## Infraestrutura

- **docker-compose.yml** com 1 lb + 2 réplicas API
- Limite total: 1 CPU, 350MB RAM
- Rede: bridge
- Imagens: public linux-amd64

## Dados

- `references.json.gz` → 3M vetores rotulados (fraud/legit)
- `normalization.json` → constantes de normalização
- `mcc_risk.json` → risco por MCC

## Pontuação

- Latência p99: cada 10x melhora = +1000 (max +3000)
- Detecção: falso positivo/negativo/erro HTTP ponderados
- Total: -6000 a +6000

## Stack

| Componente | Tecnologia | Bibliotecas |
|------------|------------|-------------|
| Load Balancer | Zig 0.14 | std.net (puro) |
| API | Bun | Built-in only |
| Busca Vetorial | Bun | Índice bináriommap |
| Container | Docker | docker-compose |

## Roadmap

1. Build script (download + gerar índice binário)
2. Load Balancer em Zig
3. API em Bun
4. docker-compose.yml
5. Testes locais
