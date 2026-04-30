# State Vocabulary Reference

## 1. Minimal Documentation

Provide official reference documentation covering:

### State Vocabulary Table

| State Name | Cognitive Description | Typical Confidence Range | Context Needs |
|------------|----------------------|-------------------------|---------------|
| channelling | High-confidence retrieval | 0.8-1.0 | Existing knowledge sufficient |
| synthesizing | Cross-domain bridging | 0.6-0.9 | May benefit from domain expertise |
| discombobulating | High entropy/uncertainty | 0.2-0.6 | Missing context or contradictory info |
| ... | | | |

### API Surface

```typescript
getCurrentCognitiveState(): CognitiveState
```
Query current state

```typescript
onCognitiveStateChange(callback)
```
Subscribe to state transitions

```typescript
getCognitiveHistory(): CognitiveState[]
```
Analyze state transitions over time

## 2. Integration Points

Make this available through:

- **Hook system** (for real-time intervention)
- **CLI flags** (`--expose-telemetry` for debugging)
- **MCP server interface** (for external tooling)
