## IsoNim viewmodels for agentic development. Each viewmodel wraps the
## signal-free state and reducers of `nim_agents` in IsoNim signals; the
## domain logic itself stays in `nim_agents`.
##
## A concern may have several viewmodels, one per UI pattern (README.md,
## "Alternative viewmodels"). Import only the variants a front-end uses; this
## umbrella module imports them all.
##
## The Agent Harbor viewmodels (`agent_harbor/`) read through a data-source
## seam (`agent_harbor/data_source`), with a fixture implementation over
## captured data (`agent_harbor/fixture_source`) and a playback source that
## replays a synthetic scenario on a clock (`agent_harbor/playback_source`,
## over `agent_harbor/playback_scenarios`). One session's cardless activity
## timeline is `agent_harbor/session_timeline_vm`, with invented timelines
## for its static stories in `agent_harbor/synthetic_timelines`. A change's
## review in four tabs is `agent_harbor/changes_vm`; the operator's inbox,
## its item pages and the actions they send are `agent_harbor/inbox_vm`,
## `agent_harbor/inbox_item_vm` and `agent_harbor/action_tracker`, answered
## in the prototypes by `agent_harbor/scripted_actions`, with invented data
## in `agent_harbor/synthetic_changes` and `agent_harbor/synthetic_inbox`.
## The omnibox composer is `agent_harbor/omnibox_composer_vm`, over its
## routing seam `agent_harbor/instruction_router`; its result commands and
## search are `agent_harbor/result_commands_vm`, over the seams
## `agent_harbor/result_sources`. An agent's suggested UI actions, the block
## at a session timeline's end, are `agent_harbor/suggested_actions_vm`,
## performed through `agent_harbor/suggested_action_sources`. The progress
## pie every row and tab carries (its state's colour family, its progress and
## the words that name it) is `agent_harbor/progress_pie`. The control
## center, the tab that launches tasks and initiatives and shows every
## initiative with the sessions waiting for the operator, is
## `agent_harbor/control_center_vm`; the status line's gaze mark is
## `agent_harbor/gaze_status_vm`. A change's tests on Agent Harbor's
## platforms are `agent_harbor/test_runs_vm`, over the shared
## `agent_harbor/test_run_feed`; the trace links' button is
## `agent_harbor/trace_opener_vm` (where a trace opens:
## `agent_harbor/trace_placement`); their invented data is in
## `agent_harbor/synthetic_test_runs`. The domain modules they read
## (nim-agents' `agent_harbor/test_runs` and `agent_harbor/trace_links`) are
## not re-exported here: import them where their types are named.
import nim_agents_isonim_viewmodels/activity_vm
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, fixture_source,
  synthetic_fleet, session_items, fleet_vm, session_tabs_vm, initiatives_vm,
  initiative_progress_vm, progress_feed, source_feed, recording_switcher,
  initiative_tabs_vm, progress_pie, playback_scenario, playback_scenarios, playback_source,
  session_events, session_timeline_vm, synthetic_timelines, action_tracker,
  scripted_actions, changes_vm, inbox_item_vm, inbox_vm, inbox_playback,
  synthetic_changes, synthetic_inbox,
  instruction_router, omnibox_composer_vm, result_sources, result_commands_vm,
  suggested_action_sources, suggested_actions_vm, control_center_vm, gaze_status_vm,
  test_run_feed, test_runs_vm, trace_placement, trace_opener_vm, synthetic_test_runs]
export activity_vm, data_source, fixture_source, synthetic_fleet, session_items,
  fleet_vm, session_tabs_vm, initiatives_vm, initiative_progress_vm, progress_feed,
  source_feed, recording_switcher, initiative_tabs_vm, progress_pie, playback_scenario,
  playback_scenarios, playback_source, session_events, session_timeline_vm,
  synthetic_timelines, action_tracker, scripted_actions, changes_vm, inbox_item_vm,
  inbox_vm, inbox_playback, synthetic_changes, synthetic_inbox, instruction_router,
  omnibox_composer_vm, result_sources, result_commands_vm, suggested_action_sources,
  suggested_actions_vm, control_center_vm, gaze_status_vm, test_run_feed, test_runs_vm,
  trace_placement, trace_opener_vm, synthetic_test_runs
