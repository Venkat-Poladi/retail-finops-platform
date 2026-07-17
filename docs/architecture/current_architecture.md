# Current Architecture — Synthetic Billing Foundation

```mermaid
flowchart LR
    subgraph Drivers[Shared retail business drivers]
        BA[365-day business activity\ntraffic, transactions, queries, AI requests]
    end

    subgraph AWS[AWS source path]
        AG[AWS generator]
        AS[AWS CUR-style CSV]
        AV[AWS source validation]
        AF[AWS FOCUS-aligned staging]
    end

    subgraph GCP[GCP source path]
        GG[GCP generator]
        GS[GCP nested JSONL]
        GV[GCP source validation]
        GF[GCP FOCUS-aligned staging\nparent rows + credit child rows]
    end

    BA --> AG --> AS --> AV --> AF
    BA --> GG --> GS --> GV --> GF

    AF --> U[Post-conformance UNION ALL]
    GF --> U
    U --> RC[Reconciliation controls]
    U --> DQ[Data-quality controls]

    RC --> O[Controlled normalized outputs]
    DQ --> O
```

## Grain by layer

| Layer | Grain |
|---|---|
| AWS source | One row per AWS billing line item |
| GCP source | One row per GCP billing export record with nested labels and credits |
| AWS staging | One row per AWS source billing line item |
| GCP staging | One parent row per GCP source record plus one child row per nested credit |
| Multi-cloud union | One row per conformed staging record after provider schemas match |

## Control sequence

```text
AWS source → AWS validation → AWS staging reconciliation
GCP source → GCP validation → GCP staging reconciliation
AWS staging + GCP staging → post-conformance union → all-cloud reconciliation
```

## Explicit non-equivalences

- AWS usage account is not presented as the native equivalent of a GCP project.
- AWS line-item type is not presented as a one-to-one equivalent of GCP `cost_type`.
- AWS credit rows are not processed like GCP nested credits.
- AWS flat exports are not processed like GCP nested/repeated exports.
