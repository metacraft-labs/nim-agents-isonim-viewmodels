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

## Alternative viewmodels

One concern may have several viewmodels, one per UI pattern, side by side;
an application picks the ones that suit it. A concern is designed as a
family:

- **the domain** -- state, reducers and the rules beneath every variant -- is
  single and signal-free, in `nim-agents`;
- **policies** where variants legitimately differ (ordering, grouping, which
  waits count as needing input, label fallbacks) are options of that domain,
  not one fixed rule;
- **a shared contract** a front-end binds to, where one fits;
- **the variants**, each in its own module whose header says which UI pattern
  it serves, so an application imports only the ones it uses. Each variant has
  its own tests and its own stories.

The Agent Harbor sessions are the first family:

| Module | Pattern |
| --- | --- |
| `agent_harbor/session_items.nim` | The contract: `SessionItem`, what one session says in any sessions view. |
| `agent_harbor/session_tabs_vm.nim` | `SessionTabStripVM`: session tabs -- one line, several lines, a sidebar list, docked as a panel. |
| `agent_harbor/fleet_vm.nim` | `FleetSnapshotVM`: a fleet list, every session of a server, waiting-for-a-person first, filtered by category. |
| `agent_harbor/initiatives_vm.nim` | `InitiativesVM`: running initiatives as a list, each with its sessions. |
| `agent_harbor/initiative_progress_vm.nim` | `InitiativeProgressVM`: one initiative's milestones grouped by status. |

Their domain is `nim-agents`' `nim_agents/agent_harbor/` (`session_directory`,
`activity_digest`, `session_replay`, `initiatives`, `fleet_records`).
