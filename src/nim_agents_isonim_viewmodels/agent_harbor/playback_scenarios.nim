## The synthetic playback scenarios (format: `playback_scenario.nim`), every
## name, id, path and line in them invented:
##
## - `front-ends` (`frontEndsScenario`): sessions launched from several
##   front-ends (CodeTracer, the CLI, the WebUI, the TUI, Telegram) start,
##   ask a question, are answered, fail and end, and one is removed, while
##   the milestones of the initiative most of them work for move;
## - `initiative-run` (`initiativeRunScenario`): one initiative over its run:
##   its milestones move (one is blocked for a while) until its plan is done,
##   and its recordings appear loading and turn ready or fail (one fails and
##   is loaded again), while its one session works and ends.
##
## Each scenario's named moments are the states its stories are captured at;
## their expected viewmodel states are written out by hand in
## `tests/test_playback.nim`.

import std/json
import nim_agents/agent_harbor/initiatives
import ./playback_scenario

export playback_scenario

const
  PlaybackT0* = 1_800_000_000_000'i64
    ## Both scenarios' first moment (2027-01-15 08:00 UTC).

proc sec(s: int): int64 = PlaybackT0 + int64(s) * 1000
  ## A moment `s` seconds after the first (negative: before it).

proc invented(id, prompt, origin, planId, initiative, software, version,
              host: string): FleetSession =
  FleetSession(id: id, prompt: prompt, agentSoftware: software,
               agentVersion: version, agentCount: 1, host: host,
               originFrontEnd: origin, planId: planId, initiative: initiative,
               labelSource: "invented")

proc counted(status: string): (DeliverableCounts, VerificationCounts) =
  ## A milestone's two deliverables and one test as a plan reads them in each
  ## status: all done and passing once completed; one deliverable done and
  ## the test pending while in progress; one done and the test failing while
  ## blocked; none done before it starts. A progress event carries the counts
  ## of its new status (`progressEntry`), so a milestone never reads
  ## "completed" beside "0/2 deliverables".
  case status
  of "completed": (DeliverableCounts(done: 2, total: 2), VerificationCounts(passing: 1))
  of "in_progress": (DeliverableCounts(done: 1, total: 2), VerificationCounts(pending: 1))
  of "blocked": (DeliverableCounts(done: 1, total: 2), VerificationCounts(failing: 1))
  else: (DeliverableCounts(done: 0, total: 2), VerificationCounts(pending: 1))

proc moved(atMs: int64; initiativeId, milestoneId, status: string): ScenarioEntry =
  ## A progress event moving a milestone to `status`, with that status's
  ## counts (`counted`).
  let (deliverables, verifications) = counted(status)
  progressEntry(atMs, initiativeId, milestoneId, status, deliverables, verifications)

proc plan(id, title, prefix: string; milestones: openArray[(string, string)];
          current: int; summary: string): Initiative =
  ## An invented initiative whose milestones are `prefix-M<i>`, titled and
  ## with the statuses given (and their counts, `counted`), the `current`th
  ## current. The executive summary says what the initiative is for, not
  ## where its run is: a run moves the plan under it, and a summary naming a
  ## milestone's state would be stale at the next moment.
  var progress = MilestoneFileProgress(
    path: "milestones/" & id & ".milestones.org", title: title & " Milestones",
    status: "in_progress", lastUpdated: "2027-01-14")
  for i, (title, status) in milestones:
    let (deliverables, verifications) = counted(status)
    progress.milestones.add MilestoneDetail(
      id: prefix & "-M" & $i, title: title, status: status,
      deliverables: deliverables, verifications: verifications)
  progress.currentMilestone = prefix & "-M" & $current
  progress.summarize()
  Initiative(id: id, title: title, repository: "orbit-labs/" & id,
             planPath: progress.path, executiveSummary: summary,
             progress: progress)

type Script = object
  s: ScenarioSession

proc script(entry: FleetSession; startMs: int64; removedAtMs = 0'i64): Script =
  Script(s: ScenarioSession(entry: entry, startMs: startMs, removedAtMs: removedAtMs))

proc at(script: var Script; atMs: int64; body: JsonNode) =
  script.s.history.add scenarioEvent(script.s.startMs, atMs, body)

proc status(script: var Script; atMs: int64; status: string) =
  script.at(atMs, %*{"type": "status", "status": status})

proc tool(script: var Script; atMs: int64; command: string) =
  script.at(atMs, %*{"type": "tool_use", "status": "started", "tool_name": "runCmd",
                     "tool_args": {"command": command}})

proc said(script: var Script; atMs: int64; text: string; level = "info") =
  script.at(atMs, %*{"type": "log", "level": level, "message": text})

proc asks(script: var Script; atMs: int64) =
  script.at(atMs, %*{"type": "agent_question", "kind": "single_choice",
                     "prompt": "Keep the old behaviour behind a flag?"})

proc answered(script: var Script; atMs: int64) =
  script.at(atMs, %*{"type": "user_input", "content": "Keep it behind a flag."})

proc started(script: var Script) =
  ## Queued a second after its start, running two seconds later.
  script.status(script.s.startMs + 1_000, "queued")
  script.status(script.s.startMs + 3_000, "running")

# ---------------------------------------------------------------------------
# front-ends
# ---------------------------------------------------------------------------

const
  RouteCache* = "route-cache"
  RouteCacheTitle* = "Route cache on the new storage layer"
  ImporterSessionId* = "5ca1ab1e-0a04-4a00-8000-00000000a004"
    ## Started from the TUI, launched for no initiative; ends, then removed.
  MigrationSessionId* = "5ca1ab1e-0a02-4a00-8000-00000000a002"
    ## Started from the CLI for the route cache; fails.
  PortSessionId* = "5ca1ab1e-0a01-4a00-8000-00000000a001"
    ## Started from CodeTracer for the route cache; asks, is answered, ends.
  ConfigSessionId* = "5ca1ab1e-0a05-4a00-8000-00000000a005"
    ## Started from Telegram for no initiative; waits on a question from the
    ## start, is answered, ends.
  BenchSessionId* = "5ca1ab1e-0a03-4a00-8000-00000000a003"
    ## Started from the WebUI for the route cache during the run; asks and
    ## is answered.

proc frontEndsScenario*(): PlaybackScenario =
  ## Sessions launched from several front-ends start, need input, resume,
  ## fail and end while the route-cache initiative's milestones move. In the
  ## order the sessions started (the first listing's order):
  ##
  ## - the importer profile (TUI, no initiative): running; completes at
  ##   +240 s; removed at +330 s;
  ## - the cache migration (CLI, route cache): running; logs an error at
  ##   +170 s and fails at +180 s;
  ## - the cache port (CodeTracer, route cache): running; asks at +60 s, is
  ##   answered at +120 s, completes at +300 s;
  ## - the config question (Telegram, no initiative): waiting on a question
  ##   from before the first moment; answered at +200 s, completes at +270 s;
  ## - the read benchmark (WebUI, route cache): starts at +30 s, runs at
  ##   +40 s, asks at +90 s, is answered at +150 s.
  ##
  ## The route cache's plan: `RC-M1` (current) completes at +210 s, which
  ## makes `RC-M2` current, and `RC-M2` starts at +215 s.
  var importer = script(invented(ImporterSessionId, "Profile the importer on the large fixture",
    "tui", "", "", "Opencode", "0.6.1", "host-d"), sec(-1200), sec(330))
  importer.started()
  importer.tool(sec(-1140), "just profile")
  importer.status(sec(240), "completed")
  var migration = script(invented(MigrationSessionId, "Migrate cached routes without a cold start",
    "cli", RouteCache, RouteCacheTitle, "Codex", "0.9.4", "host-b"), sec(-900))
  migration.started()
  migration.tool(sec(-840), "just test")
  migration.said(sec(170), "error: the migration test failed", "error")
  migration.status(sec(180), "failed")
  var port = script(invented(PortSessionId, "Port the route cache to the new storage layer",
    "codetracer", RouteCache, RouteCacheTitle, "Claude", "2.1.0", "host-a"), sec(-600))
  port.started()
  port.tool(sec(-540), "just test")
  port.asks(sec(60))
  port.answered(sec(120))
  port.tool(sec(125), "just lint")
  port.status(sec(300), "completed")
  var config = script(invented(ConfigSessionId, "Answer the question about the config format",
    "telegram", "", "", "Claude", "2.1.0", "host-e"), sec(-300))
  config.started()
  config.asks(sec(-100))
  config.answered(sec(200))
  config.said(sec(210), "assistant: The config format is TOML.")
  config.status(sec(270), "completed")
  var bench = script(invented(BenchSessionId, "Benchmark route cache reads on the new layer",
    "webui", RouteCache, RouteCacheTitle, "Grok", "1.2.0", "host-c"), sec(30))
  bench.status(sec(31), "queued")
  bench.status(sec(40), "running")
  bench.tool(sec(50), "just bench")
  bench.asks(sec(90))
  bench.answered(sec(150))
  bench.said(sec(160), "assistant: Reads are three times faster on the new layer.")
  var routeCache = plan(RouteCache, RouteCacheTitle, "RC",
    [("Specification", "completed"), ("Data model", "in_progress"),
     ("Core change", "planned"), ("Front-end", "planned")], 1,
    RouteCacheTitle & ": cached routes move to the new storage layer without a cold start.")
  routeCache.sessionIds = @[MigrationSessionId, PortSessionId]
  buildScenario("front-ends",
    "sessions from several front-ends, and their initiative's milestones",
    PlaybackT0,
    @[importer.s, migration.s, port.s, config.s, bench.s], @[routeCache],
    extras = @[
      resumeEntry(sec(120), PortSessionId),
      resumeEntry(sec(150), BenchSessionId),
      resumeEntry(sec(200), ConfigSessionId),
      moved(sec(210), RouteCache, "RC-M1", "completed"),
      moved(sec(215), RouteCache, "RC-M2", "in_progress")],
    moments = [(sec(30), "new-session"), (sec(60), "port-asks"),
               (sec(90), "bench-asks"), (sec(120), "port-answered"),
               (sec(180), "migration-fails"), (sec(200), "config-answered"),
               (sec(210), "milestone-done"), (sec(240), "importer-ends"),
               (sec(300), "port-completes"), (sec(330), "importer-removed")])

# ---------------------------------------------------------------------------
# initiative-run
# ---------------------------------------------------------------------------

const
  TelemetryRetry* = "telemetry-retry"
  TelemetryRetryTitle* = "Telemetry upload retries"
  RetrySessionId* = "5ca1ab1e-0b01-4b00-8000-00000000b001"
    ## Started from CodeTracer for the telemetry retries; ends at +210 s.

proc trace(id, name, revision, origin: string; state: RecordingState;
           error = ""): RecordingEntry =
  RecordingEntry(id: id, name: name, revision: revision, origin: origin,
                 state: state, error: error)

proc initiativeRunScenario*(): PlaybackScenario =
  ## The telemetry-retry initiative over its run. Its plan (`TR-M0` current,
  ## in progress): `TR-M0` completes at +20 s (`TR-M1` current), `TR-M1`
  ## starts at +25 s, is blocked at +80 s, resumes at +110 s and completes
  ## at +150 s (`TR-M2` current), `TR-M2` starts at +155 s and completes at
  ## +200 s, which completes the plan. Its recordings: a test trace appears
  ## loading at +30 s and is ready at +45 s; an agent session recording
  ## appears at +60 s and fails to load at +75 s, is loaded again at +160 s
  ## and is ready at +170 s; a second test trace appears at +120 s and is
  ## ready at +135 s. Its one session (CodeTracer) runs throughout, logs at
  ## +100 s and +190 s, and completes at +210 s.
  var retry = script(invented(RetrySessionId, "Retry telemetry uploads with exponential backoff",
    "codetracer", TelemetryRetry, TelemetryRetryTitle, "Claude", "2.1.0", "host-a"), sec(-120))
  retry.started()
  retry.tool(sec(-60), "just test")
  retry.said(sec(100), "assistant: The retry queue survives a restart now.")
  retry.said(sec(190), "assistant: Backoff with jitter is in; the tests pass.")
  retry.status(sec(210), "completed")
  var telemetry = plan(TelemetryRetry, TelemetryRetryTitle, "TR",
    [("Specification", "in_progress"), ("Retry queue", "planned"),
     ("Backoff", "planned")], 0,
    TelemetryRetryTitle & ": failed uploads are retried with exponential backoff.")
  telemetry.sessionIds = @[RetrySessionId]
  let testTrace = "invented-recording-retry-test"
  let sessionRecording = "invented-recording-agent-session"
  let backoffTrace = "invented-recording-backoff-test"
  proc rec(atMs: int64; entry: RecordingEntry): ScenarioEntry =
    recordingEntry(atMs, TelemetryRetry, entry)
  buildScenario("initiative-run",
    "an initiative's progress and its recordings over its run",
    PlaybackT0, @[retry.s], @[telemetry],
    extras = @[
      moved(sec(20), TelemetryRetry, "TR-M0", "completed"),
      moved(sec(25), TelemetryRetry, "TR-M1", "in_progress"),
      rec(sec(30), trace(testTrace, "retry test trace", "4f2a9c1", "ct test run", rsLoading)),
      rec(sec(45), trace(testTrace, "retry test trace", "4f2a9c1", "ct test run", rsReady)),
      rec(sec(60), trace(sessionRecording, "agent session recording", "4f2a9c1",
                         "agent session", rsLoading)),
      rec(sec(75), trace(sessionRecording, "agent session recording", "4f2a9c1",
                         "agent session", rsFailed, "the recording file is truncated")),
      moved(sec(80), TelemetryRetry, "TR-M1", "blocked"),
      moved(sec(110), TelemetryRetry, "TR-M1", "in_progress"),
      rec(sec(120), trace(backoffTrace, "backoff test trace", "7d03e5b", "ct test run", rsLoading)),
      rec(sec(135), trace(backoffTrace, "backoff test trace", "7d03e5b", "ct test run", rsReady)),
      moved(sec(150), TelemetryRetry, "TR-M1", "completed"),
      moved(sec(155), TelemetryRetry, "TR-M2", "in_progress"),
      rec(sec(160), trace(sessionRecording, "agent session recording", "4f2a9c1",
                          "agent session", rsLoading)),
      rec(sec(170), trace(sessionRecording, "agent session recording", "4f2a9c1",
                          "agent session", rsReady)),
      moved(sec(200), TelemetryRetry, "TR-M2", "completed")],
    moments = [(sec(20), "specification-done"), (sec(30), "trace-loading"),
               (sec(45), "trace-ready"), (sec(75), "recording-fails"),
               (sec(80), "milestone-blocked"), (sec(135), "second-trace-ready"),
               (sec(150), "queue-done"), (sec(170), "recording-reloaded"),
               (sec(200), "plan-done"), (sec(210), "session-ends")])

# ---------------------------------------------------------------------------

const PlaybackScenarioNames* = ["front-ends", "initiative-run"]
  ## Every synthetic playback scenario, by name.

proc playbackScenario*(name: string): PlaybackScenario =
  ## The synthetic scenario named `name`. Raises `ValueError` for an unknown
  ## name rather than playing some other scenario under it.
  case name
  of "front-ends": frontEndsScenario()
  of "initiative-run": initiativeRunScenario()
  else: raise newException(ValueError, "no playback scenario named " & name)
