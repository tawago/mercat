# DSR hang sample

Any markdown works; this file only has to open in `mercat -t`.

```mermaid
flowchart LR
  A[quit] --> B{DSR answered?}
  B -- yes --> C[exit]
  B -- no --> D[hang in Loop.stop]
```
