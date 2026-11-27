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

Alternative viewmodels (README.md): a concern may have several viewmodels,
one per UI pattern (a tab strip and a list of the same sessions). Keep the
domain single and signal-free in `nim-agents`, make the choices variants
legitimately differ on into policies there, put a shared contract where one
fits (`agent_harbor/session_items.nim`), give each variant its own module
whose header names its UI pattern, and give each variant its own tests and
stories. Keep viewmodels front-end neutral: no web-only assumption (a
measured width is a number in the renderer's unit, pixels or cells), and
feed them only through the data-source seam, so a live or playback source
can drive them event by event.

Commands:
- `just build`: compile native and JS targets.
- `just test`: run native and JS tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Siblings are expected next to this checkout (`../nim-agents`, `../isonim`, …);
`.github/sibling-repos` pins the commits CI uses.

Structure:
- `src/nim_agents_isonim_viewmodels/activity_vm.nim`: reactive view over `ActivityTimeline`.
- `src/nim_agents_isonim_viewmodels/agent_panels/`: the agent panels that moved
  here from CodeTracer (CTF-M1, D87 (a)): `agent_activity_vm.nim`
  `AgentActivityVM` (the Agent Activity feed and its composer) and
  `agent_workspace_vm.nim` `AgentWorkspaceVM` (the Agent Workspace sidebar).
  The host gives each its store as a plain `ViewModel` that the viewmodel
  keeps and never reads, and gives the activity panel its `ct test` run
  recogniser (`testRunProjector`, D90) and its `traceOpen` / `reviewOpen`
  services. Neither is in the umbrella module; import them by path.
- `src/nim_agents_isonim_viewmodels/agent_harbor/`: the Agent Harbor front-end
  prototypes' viewmodels (`fleet_vm.nim` `FleetSnapshotVM`, the fleet list;
  `session_tabs_vm.nim` `SessionTabStripVM`, sessions as tabs, over the
  `session_items.nim` contract; `initiatives_vm.nim`,
  `initiative_progress_vm.nim`), invented working sets -- a coherent
  default set (each session titled from its own initiative) and the states no
  capture shows (`synthetic_fleet.nim`), their records (`records.nim`, a
  re-export of nim-agents' `fleet_records`) and the data-source seam they read through
  (`data_source.nim` `AgentHarborDataSource`, with state sources for loading,
  error and empty; `fixture_source.nim` `FixtureDataSource`). Besides its
  loads, the seam delivers initiative progress events as they happen
  (`subscribeProgress`, a cancellable `ProgressSubscription`); the
  Initiatives and Initiative Progress viewmodels subscribe through
  `progress_feed.nim` `ProgressFeed` on `load` and unsubscribe when disposed,
  so a source, not the host, moves them. The same pattern carries fleet
  frames, resumes, recording states and resets (`subscribeFleetFrames`,
  `subscribeResumes`, `subscribeRecordings`, `subscribeResets`; a
  viewmodel's `SourceFeeds`, `source_feed.nim`), which every viewmodel opens
  on `load`. `session_timeline_vm.nim` `SessionTimelineVM` is one
  session's cardless activity timeline, over nim-agents' `activity_groups`
  fold; `synthetic_timelines.nim` holds the invented timelines of its static
  stories, `session_events.nim` the builders of invented session events both
  it and the scenarios use, and `data_source.nim` `TimelineDataSource` the
  source that serves them. `playback_source.nim` `PlaybackDataSource` replays a synthetic
  scenario (`playback_scenario.nim` the format, `playback_scenarios.nim` the
  scenarios; README.md documents both) on an IsoNim clock, with play, pause,
  step and seek; `tests/test_playback.nim` tests it. A live source over
  `nim-agent-harbor` implements the same seam later.
  It does: `live_source.nim` `LiveDataSource` (native: worker threads and a
  blocking feed). A desktop app whose main process follows the server for
  its windows (D92) uses two halves instead: `node_follower.nim`
  `NodeHarborFollower` in the main process (JavaScript on Node, `fetch`),
  which posts `host_messages.nim` `HostMessage`s, and `host_fed_source.nim`
  `HostFedDataSource` in each window (pure), which asks the host for the
  fleet and delivers the messages it is handed. Tests:
  `tests/test_host_fed_source.nim` (native and JS) and
  `tests/test_node_follower.nim` (a real server, the follower run under
  Node by `tests/probes/node_follower_probe.nim`).
  A change's review is `changes_vm.nim` `ChangesVM`; the operator's inbox
  `inbox_vm.nim` `InboxVM`, one item's page `inbox_item_vm.nim`
  `InboxItemVM`, and the actions they send `action_tracker.nim`
  `ActionTracker`, all over nim-agents' `review_record`, `change_diff`,
  `inbox` and `operator_actions`. `synthetic_changes.nim` and
  `synthetic_inbox.nim` hold their invented data, and
  `inbox_playback.nim` replays a scenario's operator presses (`inbox-run`).
  The omnibox composer is `omnibox_composer_vm.nim` `OmniboxComposerVM`,
  over nim-agents' `instruction_composer` and the front-end's own seam
  `instruction_router.nim` (`InstructionRouter`: the routing agent and the
  UI-action agent, never Agent Harbor); its deliveries to Agent Harbor are
  operator actions through `submitAction`. The omnibox's result commands
  and search are `result_commands_vm.nim` `ResultCommandsVM`, over
  nim-agents' `result_commands` and the seams `result_sources.nim`
  (`SearchProvider` for `/search`, `InputCommandSource` for Agent Harbor's
  input-command discovery and queries, both read-only). An agent's suggested UI
  actions, the block at a session timeline's end, are
  `suggested_actions_vm.nim` `SuggestedActionsVM`, over nim-agents'
  `suggested_actions`: approved actions are performed through the
  front-end's UI-action seam (`InstructionRouter.performUiAction`;
  `suggested_action_sources.nim` `ScriptedActionPerformer` in the
  prototypes), the decision goes to Agent Harbor through `submitAction`,
  and the decided suggestion is drawn as the timeline's own lines
  (`recordLines`).
  The control center is `control_center_vm.nim` `ControlCenterVM`, over
  nim-agents' `control_center`: the composer's launch and initiative forms
  inline (the operator's `New task` / `New initiative` is the composer's
  `chooseIntent`; a launch goes through the chosen initiative's manager),
  every initiative through an `InitiativesVM` over the same source, and the
  sessions waiting for the operator in inbox order, each with its progress
  pie's words. The status line's gaze mark is `gaze_status_vm.nim`
  `GazeStatusVM` (its words, tooltip and pause key are `instruction_composer`'s).
  A change's tests on Agent Harbor's platforms are `test_runs_vm.nim`
  `TestRunsVM` over `test_run_feed.nim` `TestRunFeed` (the reads and the
  Run / Record / open rules every surface over the same tests calls; never
  restate one in a viewmodel), over nim-agents' `test_runs`; the trace
  links' button is `trace_opener_vm.nim` `TraceOpenerVM` (where a trace
  opens: `trace_placement.nim`), over nim-agents' `trace_links`, whose link
  parts `SessionTimelineVM` also carries. Their invented data is
  `synthetic_test_runs.nim`, and `ScriptedTestRunSource`
  (`scripted_actions.nim`) answers their writes. This package does not
  re-export nim-agents' `test_runs` or `trace_links` (their names would
  shadow a consumer's own): import them where their types are named.
- **Writes.** An operator's action leaves a viewmodel only through
  `AgentHarborDataSource.submitAction`. The prototypes answer it with
  `scripted_actions.nim` `ScriptedActionSource` (and the playback source's
  `ActionScript`), which records it and never reaches a server: no module
  here imports a transport, and `tests/test_inbox_item_vm.nim` checks the
  prototypes' modules for one. Never point a prototype or a test at a hub or
  a mock server to make a press work.
- `fixtures/agent-harbor/`: the SYNTHETIC fixture set (invented data in the
  Agent Harbor wire shapes), generated by CodeTracer's
  `tools/agent-harbor-fixtures/synthesize.mjs`; never edit it by hand and never
  copy captured data into it. Captured data is private and stays outside this
  public repository; `fixture_source.nim` embeds it instead of the synthetic
  set when a build can see it (its module comment gives the order), and
  `AGENT_HARBOR_FIXTURES=synthetic just test` tests the public path anyway.
  Run `just test` both ways after touching the seam or the fixtures.
