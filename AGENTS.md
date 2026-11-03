# nim-agents-isonim-viewmodels

IsoNim viewmodels for agentic development, layered over `nim-agents`.

Layering:
- `nim-agent-harbor`: the typed Agent Harbor REST/SSE client.
- `nim-agents`: app-agnostic, signal-free state and reducers.
- this repo: IsoNim viewmodels that wrap those reducers in signals.
- CodeTracer, the IsoNim Editor and other IsoNim front-ends consume this repo.

Domain logic (what an event changes) belongs in `nim-agents`, not here. A
viewmodel here publishes reducer state through signals and adds only
presentation state that needs reactivity.

Commands:
- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Siblings are expected next to this checkout (`../nim-agents`, `../isonim`, …);
`.github/sibling-repos` pins the commits CI uses.

Structure:
- `src/nim_agents_isonim_viewmodels/activity_vm.nim`: reactive view over `ActivityTimeline`.
