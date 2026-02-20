# Men Architecture Seed (Gateway First)

This folder is the architecture seed for `men`.

Goal:
- lock big-module boundaries first
- then split each big module into submodules
- keep `gong` as runtime engine and avoid boundary drift

Seed files:
- `seed/v1.module-registry.seed.yaml`: module registry and path ownership
- `seed/v1.target-matrix.yaml`: ideal dependency contract
- `seed/v1.transition-matrix.yaml`: temporary migration edges
- `seed/v1.gates.yaml`: acceptance gates for transition and target
- `openclaw-analysis-sources.md`: imported findings from `Cli` and `gong`
- `v1-architecture-plan.md`: top-down module plan for implementation

Execution order:
1. implement directory/module skeleton by `v1.module-registry.seed.yaml`
2. implement webhook -> gateway -> runtime bridge happy path
3. keep temporary edges only in transition file
4. remove transition edges in phases until target gates pass
