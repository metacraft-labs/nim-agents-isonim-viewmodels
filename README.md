# nim-agents-isonim-viewmodels

IsoNim viewmodels for agentic development: agent sessions, activity, the
inbox, initiatives, change review and test runs. Each viewmodel wraps the
signal-free state and reducers of [`nim-agents`](https://github.com/metacraft-labs/nim-agents)
in [IsoNim](https://github.com/metacraft-labs/isonim) signals, so front-ends
such as CodeTracer and the IsoNim Editor share one tested implementation.

`nim-agents` stays free of IsoNim; anything that does not need signals belongs
there. The viewmodels are headless and are tested without a renderer, driven by
Agent Harbor scenario files.

```nim
import nim_agents_isonim_viewmodels

let vm = newActivityTimelineVM()
createEffect proc() =
  echo vm.entries.len   # re-runs whenever the reducer changes the timeline
```
