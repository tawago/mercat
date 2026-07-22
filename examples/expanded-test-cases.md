# Expanded Test Cases for Mermaid Verification

These test cases target specific gaps found in the initial verification report.

---

# 1. TD/BT Vertical Routing Tests

## 1.1 Basic TD Chain (3 nodes)
```mermaid
graph TD
    A[Start] --> B[Process] --> C[End]
```

## 1.2 Long TD Chain (5 nodes)
```mermaid
graph TD
    A[Step 1] --> B[Step 2]
    B --> C[Step 3]
    C --> D[Step 4]
    D --> E[Step 5]
```

## 1.3 Wide Nodes in TD
```mermaid
graph TD
    A["Wide Node Label Here"] --> B["Another Wide Label"]
    B --> C["Short"]
```

## 1.4 BT Direction (Bottom to Top)
```mermaid
graph BT
    A[Bottom] --> B[Middle] --> C[Top]
```

## 1.5 TD with Branching
```mermaid
graph TD
    A[Root] --> B[Left]
    A --> C[Right]
    B --> D[End Left]
    C --> E[End Right]
```

---

# 2. Cyclic Graph Tests (Back-Edge Verification)

## 2.1 Simple 3-Node Cycle
```mermaid
graph LR
    A[Node A] --> B[Node B]
    B --> C[Node C]
    C --> A
```

## 2.2 Simple TD Cycle
```mermaid
graph TD
    A[Start] --> B[Process]
    B --> C[Check]
    C --> A
```

## 2.3 Self-Loop
```mermaid
graph LR
    A[Retry] --> A
    A --> B[Done]
```

## 2.4 Multi-Cycle Graph
```mermaid
graph LR
    A[A] --> B[B]
    B --> C[C]
    C --> D[D]
    D --> B
    C --> A
```

## 2.5 Diamond with Back-Edge
```mermaid
graph TD
    A[Start] --> B[Left]
    A --> C[Right]
    B --> D[Merge]
    C --> D
    D --> A
```

---

# 3. Nested Subgraph Tests

## 3.1 Two-Level Nesting
```mermaid
graph LR
    subgraph Outer["Outer Group"]
        subgraph Inner["Inner Group"]
            A[Node A]
        end
        B[Node B]
    end
    A --> B
```

## 3.2 Three-Level Nesting
```mermaid
graph LR
    subgraph Level1["System"]
        subgraph Level2["Subsystem"]
            subgraph Level3["Component"]
                A[Core]
            end
            B[Helper]
        end
        C[External]
    end
    A --> B --> C
```

## 3.3 Multiple Siblings at Same Level
```mermaid
graph TD
    subgraph Parent["Container"]
        subgraph Child1["Module A"]
            A[Service A]
        end
        subgraph Child2["Module B"]
            B[Service B]
        end
    end
    A --> B
```

## 3.4 Subgraph with Long Title
```mermaid
graph LR
    subgraph LongTitle["This Is A Very Long Subgraph Title"]
        A[Node A]
        B[Node B]
    end
    A --> B
```

---

# 4. Long Label Tests

## 4.1 Single Long Label (50+ chars)
```mermaid
graph LR
    A["This is a very long label that should wrap within node boundaries"] --> B[Short]
```

## 4.2 Multiple Long Labels
```mermaid
graph TD
    A["Process customer order and validate payment information"]
    --> B["Store transaction data in database and update cache"]
    --> C["Send confirmation notification to customer email"]
```

## 4.3 Long Edge Label
```mermaid
graph LR
    A[Start] -->|"This is a very long edge label describing the transition"| B[End]
```

## 4.4 Mixed Long and Short
```mermaid
graph LR
    A["Long label that needs to wrap properly"] --> B[X]
    B --> C["Another long label in the chain"]
    C --> D[Y]
```

---

# 5. Dense Graph Tests

## 5.1 Ten-Node Chain
```mermaid
graph LR
    A[1] --> B[2] --> C[3] --> D[4] --> E[5]
    E --> F[6] --> G[7] --> H[8] --> I[9] --> J[10]
```

## 5.2 Tree with Multiple Branches
```mermaid
graph TD
    Root[Root]
    Root --> A[A]
    Root --> B[B]
    Root --> C[C]
    A --> A1[A1]
    A --> A2[A2]
    B --> B1[B1]
    B --> B2[B2]
    C --> C1[C1]
    C --> C2[C2]
```

## 5.3 Grid Structure (3x3)
```mermaid
graph LR
    A1[1] --> A2[2] --> A3[3]
    B1[4] --> B2[5] --> B3[6]
    C1[7] --> C2[8] --> C3[9]
    A1 --> B1 --> C1
    A2 --> B2 --> C2
    A3 --> B3 --> C3
```

## 5.4 Fully Connected (5 nodes)
```mermaid
graph LR
    A[A] --> B[B]
    A --> C[C]
    A --> D[D]
    A --> E[E]
    B --> C
    B --> D
    B --> E
    C --> D
    C --> E
    D --> E
```

---

# 6. Width Fitting Stress Tests

## 6.1 Wide LR (Force Label Wrap at Narrow Width)
```mermaid
graph LR
    A["Input Processor"] --> B["Data Validator"] --> C["Storage Handler"] --> D["Output Generator"]
```

## 6.2 Very Wide with Subgraphs
```mermaid
graph LR
    subgraph Frontend["Frontend Layer"]
        A["Web Server"]
        B["Load Balancer"]
    end
    subgraph Backend["Backend Layer"]
        C["API Gateway"]
        D["Service Mesh"]
    end
    subgraph Data["Data Layer"]
        E["Database"]
        F["Cache"]
    end
    A --> C
    B --> C
    C --> E
    D --> F
```

## 6.3 Complex TD (Force Direction Switch)
```mermaid
graph TD
    A["Authentication Service"] --> B["Authorization Check"]
    B --> C["Token Validation"]
    C --> D["Permission Lookup"]
    D --> E["Access Grant"]
    E --> F["Audit Log"]
```

---

# 7. Edge Style Variations

## 7.1 All Edge Types Together
```mermaid
graph LR
    A[A] --> B[B]
    B --- C[C]
    C -.-> D[D]
    D ==> E[E]
    E <--> F[F]
```

## 7.2 Mixed Styles with Labels
```mermaid
graph LR
    A[Start] -->|solid| B[Mid]
    B -.->|dotted| C[Next]
    C ==>|thick| D[End]
```

---

# 8. Complex Combined Test

## 8.1 Full Feature Test
```mermaid
graph TD
    subgraph Input["Input Layer"]
        A["Data Source"]
        B["Parser"]
    end
    subgraph Process["Processing Layer"]
        subgraph Validate["Validation"]
            C["Schema Check"]
            D["Data Clean"]
        end
        E["Transform"]
    end
    subgraph Output["Output Layer"]
        F["Writer"]
        G["Logger"]
    end
    
    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    E --> G
    G -.-> A
```
