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
| `agent_harbor/fleet_vm.nim` | `FleetSnapshotVM`: a fleet list, every session of a server, waiting-for-a-person first, filtered by category; loaded from a snapshot, it then follows lifecycle frames, listing entries and session events (`apply`, over nim-agents' `fleet_fold`). |
| `agent_harbor/initiatives_vm.nim` | `InitiativesVM`: running initiatives as a list, each with its sessions. |
| `agent_harbor/initiative_progress_vm.nim` | `InitiativeProgressVM`: one initiative's milestones grouped by status. |

Their domain is `nim-agents`' `nim_agents/agent_harbor/` (`session_directory`,
`activity_digest`, `session_replay`, `initiatives`, `fleet_records`).

One session's activity is a family of its own:

| Module | Pattern |
| --- | --- |
| `agent_harbor/session_timeline_vm.nim` | `SessionTimelineVM`: a cardless activity timeline -- one column of lines with no box around any event, runs of similar events collapsed into a group line (`Read 4 files`, `Ran 2 shell commands (1 failed)`, `Edited 3 files +40 −12`, a repeated line with `×N`), and every line expandable to its details and, for a shell command, the trace of the processes it ran. It keeps the reader's open lines, focus, following and filter across new events and restarts, counts the items that arrive while the reader is scrolled away, and names the line a host keeps still. |
| `agent_harbor/synthetic_timelines.nim` | Invented timelines for its static stories (every kind, every group, the trace states, a long session with gaps, long names, loading, empty, error, a session that cannot be loaded), and the viewmodel each story shows with its reader state set. |

Its domain is `nim-agents`' `nim_agents/activity_groups` (`TimelineFold`):
the item kinds, the grouping rules and what breaks a group, the stable ids,
and the policies for streamed or whole-line text and for the operator's
input. A line says the same words a fleet row's activity line says for the
same event (`nim_agents/agent_harbor/activity_words`).

## The data-source seam

Every Agent Harbor viewmodel reads through an `AgentHarborDataSource`
(`agent_harbor/data_source.nim`): loads (`loadFleet`, `loadInitiatives`,
`loadSessionEvents`, ...) and, after them, subscriptions to what happens.
Each subscription kind has one method, a cancellable handle
(`Subscription[T]`) and a base method that answers once that the source does
not provide it:

| Method | Delivers | Followed by |
| --- | --- | --- |
| `subscribeFleetFrames` | `FleetFrame`: a lifecycle frame, a session's listing entry, one event of a session's stream | the fleet list, the tab strip, the initiative tab bar, the Initiatives panel, the session activity timeline (its own session's events only) |
| `subscribeResumes` | `ResumeEvent`: the operator's input reached a waiting session | the tab strip, the initiative tab bar (auto-switch), the Initiatives panel |
| `subscribeRecordings` | `RecordingEvent`: a recording of an initiative appeared, or turned ready or failed | the initiative tab bar's recording switcher |
| `subscribeProgress` | `ProgressEvent`: a milestone's status changed, optionally with its deliverable and test counts as the plan now reads them (`hasCounts`) | the Initiatives and Initiative Progress panels, both tab bars |
| `subscribeResets` | `StreamReset`: the source started over; reload | every viewmodel above |

A session's event history (`loadSessionEvents`) carries each event's line
(`events`, newest first) and, where the source has them, the events
themselves (`rawEvents`, oldest first), which the timeline folds; a session
the source does not hold is answered `missing`, so a view says it cannot be
loaded rather than that the server failed. `TimelineDataSource` serves given
session events and sends the frames a story or test hands it (`sendFrame`).

A viewmodel subscribes on `load`, before it asks for anything, and cancels
when it is disposed (`agent_harbor/source_feed.nim`, `SourceFeeds`); its
`feeds` report each subscription, an error naming the gap when the source
does not provide a kind. What an entry changes is decided by the reducers in
`nim-agents`, never by the source.

## Playback scenarios and the playback source

`agent_harbor/playback_source.nim` `PlaybackDataSource` replays a scenario on
a clock, so a story can be watched changing and a test can stop it at any
moment. Scenarios are invented data only.

**The format** (`agent_harbor/playback_scenario.nim`, `PlaybackScenario`):

- `first`, the fleet listing at the scenario's first moment (`firstMs`), and
  `initiatives`, the initiatives then;
- `entries`, after that moment and in time order, each a `ScenarioEntry`
  stamped `atMs` (milliseconds since the Unix epoch) and of one kind: a
  lifecycle frame (`sekLifecycle`), a session's listing entry
  (`sekListing`), one event of a session's stream (`sekEvent`, with its
  1-based place in the session's history), a resume (`sekResume`), a
  progress event, i.e. a milestone's new status and, when it carries them,
  its counts (`sekProgress`), or a
  recording-state change (`sekRecording`). Entries at one moment are one
  moment: they are delivered together, in their order;
- an entry may carry a named `moment`, unique in its scenario; stories and
  tests seek to moments by name, and captures are taken there;
- `sessions`, every session the scenario names with its identity, start,
  removal and whole event history (events before the first moment
  included), from which a session's history at any moment is answered.

Scenarios are Nim values, not files, so they load the same way on the C and
JS targets. `buildScenario` is the authoring helper: from the sessions'
histories and the entries no history implies (resumes, progress events,
recording changes) it derives the first listing and the fleet entries a live
feed would send (`session_created` and a listing entry for a new session,
every event, a lifecycle frame beside each `status` event, removals).
`problemsOf` checks a scenario's own invariants: entries in time order and
after the first moment, every session introduced before an entry names it,
named moments unique, progress and recording changes naming known
initiatives and milestones, each resume matched by its session's own
input event, a single-session view (the activity timeline) naming a session
of the scenario and only moments with an entry about it, every
`tool_result` following its `tool_use` (the same `tool_execution_id`) and a
command trace naming programs its command runs, and no milestone reading
completed with a deliverable undone or a test pending or failing, in the
first listing or after any progress event.
A scenario's milestones move with their counts (a status alone would leave a
completed milestone reading "0/2 deliverables"), and an initiative's
executive summary says what it is for, not where its run is, so no moment
shows a summary the run has overtaken. `tests/test_playback.nim` also holds
every named moment to changing each viewmodel its entries feed.

**The scenarios** (`agent_harbor/playback_scenarios.nim`):

| Name | What it shows | Named moments |
| --- | --- | --- |
| `front-ends` | Sessions from CodeTracer, the CLI, the WebUI, the TUI and Telegram start, ask, are answered, fail, end and are removed, while their initiative's milestones move. | `new-session`, `port-asks`, `bench-asks`, `port-answered`, `migration-fails`, `config-answered`, `milestone-done`, `importer-ends`, `port-completes`, `importer-removed` |
| `initiative-run` | One initiative's progress events (a milestone blocked for a while, the plan completed) and its recordings loading, turning ready or failing, and being loaded again. | `specification-done`, `trace-loading`, `trace-ready`, `recording-fails`, `milestone-blocked`, `second-trace-ready`, `queue-done`, `recording-reloaded`, `plan-done`, `session-ends` |
| `session-run` | One agent session's work for the activity timeline (`session-activity`, over that session): an instruction, reads, searches, a command that fails with its trace, a question and its answer, edits, a plan, a repeated hook, a reply and completion, while a second session's events interleave and never show. | `instruction`, `reads-grouped`, `searches-grouped`, `command-running`, `command-fails`, `agent-asks`, `answered`, `edits-grouped`, `hook-repeats`, `agent-replies`, `session-completes` |

**The source.** Its loads answer the state at the playback head: the first
frame before anything is played, and later the state after the delivered
entries (so a viewmodel loaded late starts where the others are). It sends
each entry once, when the head reaches its moment, through the subscription
of its kind. Controls: `play`, `pause`, `step` (to the next entry's moment,
delivering every entry there), `seek` (to a time) and `seekMoment` (to a
named moment); `rewind` goes back to the first frame. Going backwards past a
delivered entry rebuilds: the source returns to its first frame, sends a
`StreamReset` (every subscribed viewmodel reloads) and delivers the entries
up to the target again.

**The clock** is IsoNim's clock interface (`isonim/core/clock`, `ClockBase`):
a `TestClock`, which moves only when advanced, in tests and captures; a
`RealClock` in a host that plays in real time. Nothing reads wall time.

```nim
import isonim/core/clock
import nim_agents_isonim_viewmodels

let clock = newTestClock(0)
let source = newPlaybackDataSource(playbackScenario("front-ends"), clock)
let fleet = newFleetSnapshotVM(source)
fleet.load()                        # the first frame
discard source.seekMoment("port-asks")
discard source.play()
clock.advance(30_000)               # thirty seconds of the run
```
