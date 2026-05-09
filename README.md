# Rinha 2026 - Fraud Detection

Monorepo para o desafio da Rinha de Backend 2026.

## Stack

- **Load Balancer**: Zig (std.net)
- **API**: Bun
- **Busca Vetorial**: Índice bináriommap

## Estrutura

```
├── load-balancer/     # LB em Zig
├── fraud-api/         # API em Bun
├── build/             # Scripts de build
├── docs/              # Documentação
└── docker-compose.yml
```

## Quick Start

```bash
# Baixar dados
npm run build:data

# Dev API
npm run dev:api

# Dev LB
npm run dev:lb

# Docker
npm run docker:up
```

## Endpoints

- `GET /ready` - Healthcheck
- `POST /fraud-score` - Detecção de fraude

## Regras

Ver [docs/plans/](docs/plans/2026-05-08-rinha-fraud-detection-design.md)
