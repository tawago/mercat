# Deploy pipeline

Every push to `main` runs these stages:

| Stage  | Tool   | Time |
|--------|--------|------|
| build  | zig    | 40s  |
| test   | ci     | 2m   |
| ship   | brew   | 15s  |

```bash
zig build test && git tag v1.0.0
```

```mermaid
flowchart LR
  A[push] --> B[build] --> C[test] --> D[ship]
```
