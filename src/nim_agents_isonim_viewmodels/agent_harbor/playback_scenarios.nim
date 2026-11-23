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
##   is loaded again), while its one session works and ends;
## - `session-run` (`sessionRunScenario`): one agent session's work event by
##   event -- reads, searches, commands (one fails, with its trace), a
##   question and its answer, edits, a plan, a hook that repeats, a reply,
##   completion -- for the session activity timeline, while another
##   session's events interleave;
## - `inbox-run` (`inboxRunScenario`): the operator's inbox over a run --
##   a feedback request is waiting from before the run, items arrive
##   (nothing takes the screen), the operator walks them with Next, a boost
##   ends and the server reorders, the operator answers with auto-switch off
##   and then on, goes back with Previous, an item is answered on another
##   front-end, and a last item arrives while the operator reads a page.
##
## Each scenario's named moments are the states its stories are captured at,
## each view at the moments whose event it shows (`views`); their expected
## viewmodel states are written out by hand in `tests/test_playback.nim`.

import std/json
import nim_agents/agent_harbor/initiatives
import ./playback_scenario
import ./session_events
import ./synthetic_test_runs

export playback_scenario

const
  PlaybackT0* = 1_800_000_000_000'i64
    ## Every scenario's first moment (2027-01-15 08:00 UTC).

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

# The helpers below write a session's work event by event, in the wire shapes
# of `session_events.nim`. The two scenarios after them use only the helpers
# above this line, and are unchanged by these.

proc instructs(script: var Script; atMs: int64; text: string) =
  script.at(atMs, userInput(text))

proc thinks(script: var Script; atMs: int64; text: string) =
  script.at(atMs, thoughtEvent(text))

proc reads(script: var Script; atMs: int64; path: string) =
  script.at(atMs, fileRead(path))

proc searched(script: var Script; atMs: int64; id, tool, pattern, path,
              matches: string) =
  ## A search tool's call and its result, at one moment.
  script.at(atMs, searchCall(id, tool, pattern, path))
  script.at(atMs, toolResult(id, tool, 0, matches))

proc requests(script: var Script; atMs: int64; model: string; messages: int) =
  script.at(atMs, modelRequest(model, messages))

proc ran(script: var Script; atMs: int64; id, command: string) =
  ## A shell command started; its result comes with `finished`.
  script.at(atMs, commandCall(id, command))

proc finished(script: var Script; atMs: int64; id: string; exitCode: int;
              output: string; trace: JsonNode = nil) =
  ## A shell command's result, with its trace when given.
  script.at(atMs, toolResult(id, "runCmd", exitCode, output, trace))

proc edits(script: var Script; atMs: int64; path: string; added, removed: int;
           description: string) =
  script.at(atMs, fileEdit(path, added, removed, description))

proc diffed(script: var Script; atMs: int64; path: string; added, removed: int;
            patch: string) =
  script.at(atMs, diffEvent(path, added, removed, patch))

proc plans(script: var Script; atMs: int64; steps: openArray[(string, string)];
           update: bool) =
  script.at(atMs, planEvent(steps, update))

proc question(script: var Script; atMs: int64; prompt: string;
              options: openArray[string]) =
  script.at(atMs, agentQuestion(prompt, options))

proc resumed(script: var Script; atMs: int64) =
  script.at(atMs, sessionResumed())

proc replies(script: var Script; atMs: int64; text: string) =
  script.at(atMs, agentReply(text))

proc hook(script: var Script; atMs: int64; request: string) =
  script.at(atMs, awaitingInput(request))

proc completes(script: var Script; atMs: int64; summary: string) =
  script.at(atMs, statusEvent("completed", summary))

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
               (sec(300), "port-completes"), (sec(330), "importer-removed")],
    # Each view's moments: those whose event it shows. The session views show
    # every session's state; the session list's group headers also show the
    # route cache's milestones (`n/m`), and the fleet's config row the line
    # it logs at milestone-done. The Initiatives panel shows the route
    # cache's sessions and milestones, and in its header the sessions in no
    # initiative (the importer's removal); not the importer's or the config
    # session's state. The control center shows the Initiatives panel's
    # moments and, in its waiting list, each session that comes to wait or
    # is answered (the config question answered too).
    views = [
      ("fleet", @["new-session", "port-asks", "bench-asks", "port-answered",
                  "migration-fails", "config-answered", "milestone-done",
                  "importer-ends", "port-completes", "importer-removed"]),
      ("session-tabs", @["new-session", "port-asks", "bench-asks", "port-answered",
                         "migration-fails", "config-answered", "importer-ends",
                         "port-completes", "importer-removed"]),
      ("session-list", @["new-session", "port-asks", "bench-asks", "port-answered",
                         "migration-fails", "config-answered", "milestone-done",
                         "importer-ends", "port-completes", "importer-removed"]),
      ("initiatives", @["new-session", "port-asks", "bench-asks", "port-answered",
                        "migration-fails", "milestone-done", "port-completes",
                        "importer-removed"]),
      ("control-center", @["new-session", "port-asks", "bench-asks", "port-answered",
                           "migration-fails", "config-answered", "milestone-done",
                           "port-completes", "importer-removed"])])

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
               (sec(200), "plan-done"), (sec(210), "session-ends")],
    # The initiative tabs show the plan's `n/m`, the recordings and the
    # session's end (the tab's mark), not a blocked milestone while the
    # session still works; the progress panel shows the milestones only.
    views = [
      ("initiative-tabs", @["specification-done", "trace-loading", "trace-ready",
                            "recording-fails", "second-trace-ready", "queue-done",
                            "recording-reloaded", "plan-done", "session-ends"]),
      ("initiative-progress", @["specification-done", "milestone-blocked",
                                "queue-done", "plan-done"])])

# ---------------------------------------------------------------------------
# session-run
# ---------------------------------------------------------------------------

const
  JitterSessionId* = "5ca1ab1e-0c01-4c00-8000-00000000c001"
    ## Started from CodeTracer: adds retry jitter to the upload client; the
    ## session the `session-activity` view shows.
  LoggingSessionId* = "5ca1ab1e-0c02-4c00-8000-00000000c002"
    ## Started from the CLI; its events interleave with the jitter session's
    ## and must never show in that session's timeline.
  SessionRunMoments* = ["instruction", "reads-grouped", "searches-grouped",
                        "command-running", "command-fails", "agent-asks",
                        "answered", "edits-grouped", "hook-repeats",
                        "agent-replies", "session-completes"]
    ## The `session-activity` moments, in time order.

proc pipelineTrace(): JsonNode =
  ## The failing test run's trace: a three-stage pipeline whose first stage
  ## fails, `tee` and `tail` succeed; the environment holds an invented token,
  ## which the timeline redacts.
  const output = "..F...\nFAILED tests/test_client.py::test_retry_waits_with_jitter\n" &
    "1 failed, 17 passed in 14.1s\n"
  commandTrace([
    tracedProcess(5102, 5101, ["pytest", "-q"], 0, 14_200, 1, stdout = output,
                  exe = "/usr/bin/python3"),
    tracedProcess(5103, 5101, ["tee", "test.log"], 0, 14_210, 0),
    tracedProcess(5104, 5101, ["tail", "-n", "5"], 2, 14_215, 0,
                  stdout = "1 failed, 17 passed in 14.1s\n")],
    output,
    %*{"PATH": "/usr/bin", "UPLOAD_CLIENT_ENV": "test",
       "UPLOAD_API_TOKEN": "invented-token-not-a-secret"})

proc sessionRunScenario*(): PlaybackScenario =
  ## One agent session's work, event by event, for the session activity
  ## timeline (`session-activity`, over the jitter session):
  ##
  ## - +5 s, `instruction`: the operator asks for retry jitter;
  ## - a thought, then four reads with a thought between them (+20 s,
  ##   `reads-grouped`: the fourth read);
  ## - three searches with a model request between them (+35 s,
  ##   `searches-grouped`);
  ## - a test command that passes, then the full test run piped through
  ##   `tee` and `tail` (+50 s, `command-running`), which fails with exit 1
  ##   and carries its trace (+65 s, `command-fails`);
  ## - the agent asks which jitter to use (+80 s, `agent-asks`) and the
  ##   operator answers (+110 s, `answered`);
  ## - three edits, +40 −12 in all (+150 s, `edits-grouped`), and a plan
  ##   update;
  ## - the stop hook holds the session three times (+170 s, `hook-repeats`);
  ## - the tests pass, and the agent replies (+200 s, `agent-replies`);
  ## - the session completes with a summary (+230 s, `session-completes`).
  ##
  ## A second session (the CLI's logging tidy-up) works at the same time;
  ## its events interleave with these and are on no view's list.
  var jitter = script(invented(JitterSessionId, "Add retry jitter to the upload client",
    "codetracer", "", "", "Claude", "2.1.0", "host-a"), sec(-10))
  jitter.started()
  jitter.instructs(sec(5), "Add jitter to the upload client's retries, so " &
    "clients that fail together do not retry together.")
  jitter.thinks(sec(8), "The retry loop lives in the upload client. Read it and its tests first.")
  jitter.reads(sec(10), "src/upload/client.py")
  jitter.reads(sec(13), "src/upload/backoff.py")
  jitter.thinks(sec(15), "Backoff is exponential with no jitter; check how the tests pin the delays.")
  jitter.reads(sec(17), "tests/test_client.py")
  jitter.reads(sec(20), "tests/test_backoff.py")
  jitter.searched(sec(25), "search-1", "grep", "retry", "src/upload", "src/upload/client.py:41: for attempt in range(retries):")
  jitter.requests(sec(30), "invented-model-large", 14)
  jitter.searched(sec(32), "search-2", "glob", "**/*retry*", ".", "tests/test_retry_budget.py")
  jitter.searched(sec(35), "search-3", "rg", "time.sleep", "src", "src/upload/backoff.py:22: time.sleep(delay)")
  jitter.ran(sec(42), "cmd-1", "pytest -q tests/test_backoff.py")
  jitter.finished(sec(46), "cmd-1", 0, "......\n6 passed in 0.4s\n")
  jitter.ran(sec(50), "cmd-2", "pytest -q | tee test.log | tail -n 5")
  jitter.finished(sec(65), "cmd-2", 1,
    "1 failed, 17 passed in 14.1s\n", pipelineTrace())
  jitter.question(sec(80), "Use full jitter or equal jitter for the retry delay?",
    ["Full jitter", "Equal jitter"])
  jitter.instructs(sec(110), "Full jitter.")
  jitter.resumed(sec(110))
  jitter.edits(sec(120), "src/upload/backoff.py", 18, 4,
    "Draw each delay uniformly between zero and the exponential cap.")
  jitter.diffed(sec(130), "src/upload/client.py", 10, 6,
    "@@ -38,6 +38,10 @@\n-        time.sleep(base * 2 ** attempt)\n+        time.sleep(backoff.full_jitter(base, attempt, cap))\n")
  jitter.edits(sec(150), "tests/test_backoff.py", 12, 2,
    "Seed the jitter so the delays are reproducible in tests.")
  jitter.plans(sec(155), [("Read the retry loop", "completed"),
                          ("Add full jitter", "completed"),
                          ("Run the tests", "in_progress")], update = true)
  jitter.hook(sec(160), "claude-stop-hook")
  jitter.hook(sec(165), "claude-stop-hook")
  jitter.hook(sec(170), "claude-stop-hook")
  jitter.ran(sec(180), "cmd-3", "pytest -q")
  jitter.finished(sec(194), "cmd-3", 0, "..................\n18 passed in 13.8s\n")
  jitter.replies(sec(200), "The retry client backs off with full jitter; 18 tests pass.")
  jitter.completes(sec(230), "Retries now wait a random time up to the exponential cap.")
  var logging = script(invented(LoggingSessionId, "Tidy the upload client's logging",
    "cli", "", "", "Codex", "0.9.4", "host-b"), sec(-60))
  logging.started()
  logging.reads(sec(12), "src/upload/log.py")
  logging.ran(sec(47), "log-cmd-1", "ruff check src/upload")
  logging.finished(sec(58), "log-cmd-1", 0, "All checks passed!\n")
  logging.edits(sec(125), "src/upload/log.py", 5, 9, "Use the module logger.")
  logging.replies(sec(190), "The upload client logs through its module logger now.")
  logging.completes(sec(215), "Logging tidied.")
  buildScenario("session-run",
    "one agent session's activity, event by event",
    PlaybackT0, @[jitter.s, logging.s], @[],
    extras = @[resumeEntry(sec(110), JitterSessionId)],
    moments = [(sec(5), "instruction"), (sec(20), "reads-grouped"),
               (sec(35), "searches-grouped"), (sec(50), "command-running"),
               (sec(65), "command-fails"), (sec(80), "agent-asks"),
               (sec(110), "answered"), (sec(150), "edits-grouped"),
               (sec(170), "hook-repeats"), (sec(200), "agent-replies"),
               (sec(230), "session-completes")],
    sessionViews = [("session-activity", JitterSessionId, @SessionRunMoments)])

# ---------------------------------------------------------------------------
# inbox-run
# ---------------------------------------------------------------------------

const
  InboxRouteSessionId* = "5ca1ab1e-0e01-4e00-8000-00000000e001"
    ## Asks a question (the item `run-question`), answered here.
  InboxLoggingSessionId* = "5ca1ab1e-0e02-4e00-8000-00000000e002"
    ## Ends its turn (`run-ended-turn`), answered on another front-end.
  InboxSchemaSessionId* = "5ca1ab1e-0e03-4e00-8000-00000000e003"
    ## Asks for permission (`run-permission`), allowed here.
  InboxNotesSessionId* = "5ca1ab1e-0e04-4e00-8000-00000000e004"
    ## Asks for feedback (`run-feedback`), waiting from before the run and
    ## never answered in it.
  InboxBenchSessionId* = "5ca1ab1e-0e05-4e00-8000-00000000e005"
    ## Asks the operator to sign in (`run-login`), the run's last item.
  RunQuestion* = InboxItemRef(id: "run-question")
  RunEndedTurn* = InboxItemRef(id: "run-ended-turn")
  RunPermission* = InboxItemRef(id: "run-permission")
  RunFeedback* = InboxItemRef(id: "run-feedback")
  RunLogin* = InboxItemRef(id: "run-login")
  InboxRunMoments* = ["first-wait", "four-waiting", "next", "boost-ends", "answered",
                      "auto-switch", "prev", "resolved-elsewhere", "arrives-while-reading"]

proc waiting(r: InboxItemRef; kind: InboxKind; sessionId, title: string;
             atMs: int64; explanation: string; priority = ipNormal;
             boosted = false): InboxItem =
  ## An invented waiting item, as the inbox stream would send it.
  result = InboxItem(id: r.id, kind: kind, kindText: $kind,
                     session: InboxSession(id: sessionId, title: title, label: title,
                                           agent: "Claude Code", host: "build-01",
                                           status: "running"),
                     priority: priority, effectivePriority: priority,
                     explanation: explanation, enteredAtMs: atMs)
  if boosted:
    result.effectivePriority = ipHigh
    result.boost = InboxBoost(active: true, reason: "cache_warm",
                              reasons: @["cache_warm"], deadlineMs: atMs + 20_000)

proc added(atMs: int64; item: InboxItem; order: openArray[InboxItemRef];
           moment = ""): ScenarioEntry =
  inboxEntry(atMs, InboxEvent(kind: ieAdded, item: item, hasOrder: true,
                              order: @order), moment)

proc updated(atMs: int64; item: InboxItem; order: openArray[InboxItemRef];
             moment = ""): ScenarioEntry =
  inboxEntry(atMs, InboxEvent(kind: ieUpdated, item: item, hasOrder: true,
                              order: @order), moment)

proc resolved(atMs: int64; r: InboxItemRef; order: openArray[InboxItemRef];
              moment = ""): ScenarioEntry =
  inboxEntry(atMs, InboxEvent(kind: ieResolved, target: r, hasOrder: true,
                              order: @order), moment)

proc pressed(atMs: int64; kind: OperatorPressKind; text = "", option = "";
             on = false; moment = ""): ScenarioEntry =
  pressEntry(atMs, OperatorPress(kind: kind, text: text, option: option, on: on), moment)

proc inboxRunScenario*(): PlaybackScenario =
  ## The operator's inbox over a run. Five invented sessions are running
  ## from before the first moment; their waits reach the inbox as the
  ## server's inbox events, and the operator's presses are entries of their
  ## own. The route-cache session's question and the operator's answer are
  ## also events of its own stream (a question wait is the one a session's
  ## events say; the others are the listing's). Only the inbox view is fed.
  ##
  ## The inbox is never empty: a low-priority feedback request is waiting
  ## from before the first moment and stays to the end, as the sessions are
  ## running from before it. So the first frame, like every moment, shows
  ## items, and the story declares data; the empty inbox is a static story
  ## of its own, and `tests/test_inbox_vm.nim` holds the inbox emptying
  ## under a walk (Next and Previous disabled though a stack was visited).
  var sessions: seq[ScenarioSession]
  for (id, prompt) in [(InboxRouteSessionId, "Port the route cache"),
                       (InboxLoggingSessionId, "Tidy the upload client's logging"),
                       (InboxSchemaSessionId, "Migrate the cache schema"),
                       (InboxNotesSessionId, "Write the release notes"),
                       (InboxBenchSessionId, "Benchmark the cache")]:
    var s = script(invented(id, prompt, "codetracer", "", "", "Claude Code", "2.1.4",
                            "build-01"), sec(-120))
    s.started()
    if id == InboxRouteSessionId:
      s.asks(sec(10))
      s.answered(sec(60))
    sessions.add s.s
  let question = waiting(RunQuestion, ikBlockedQuestion, InboxRouteSessionId,
    "Port the route cache", sec(10), "Blocked on your answer for 0:10.")
  let ended = waiting(RunEndedTurn, ikEndedTurn, InboxLoggingSessionId,
    "Tidy the upload client's logging", sec(20),
    "Raised: its model cache is warm for 0:20.", boosted = true)
  let endedCold = waiting(RunEndedTurn, ikEndedTurn, InboxLoggingSessionId,
    "Tidy the upload client's logging", sec(20), "Its cache went cold; waiting 0:20.")
  let permission = waiting(RunPermission, ikPermissionGate, InboxSchemaSessionId,
    "Migrate the cache schema", sec(20),
    "Urgent: the migration holds a write lock until you decide.", priority = ipUrgent)
  let feedback = waiting(RunFeedback, ikAsyncFeedback, InboxNotesSessionId,
    "Write the release notes", sec(-60), "Low priority; the agent keeps working.",
    priority = ipLow)
  let login = waiting(RunLogin, ikLoginRequest, InboxBenchSessionId,
    "Benchmark the cache", sec(90), "Blocked until someone signs in.", priority = ipLow)
  let extras = @[
    added(sec(10), question, [RunQuestion, RunFeedback]),
    added(sec(20), ended, [RunEndedTurn, RunQuestion, RunFeedback]),
    added(sec(20), permission, [RunPermission, RunEndedTurn, RunQuestion, RunFeedback]),
    pressed(sec(30), opNext),
    updated(sec(40), endedCold, [RunPermission, RunQuestion, RunEndedTurn, RunFeedback]),
    pressed(sec(50), opAnswer, option = "allow_once"),
    resolved(sec(50), RunPermission, [RunQuestion, RunEndedTurn, RunFeedback]),
    pressed(sec(60), opAutoSwitch, on = true),
    pressed(sec(60), opNext),
    pressed(sec(60), opAnswer, text = "Keep it behind a flag."),
    resolved(sec(60), RunQuestion, [RunEndedTurn, RunFeedback]),
    pressed(sec(70), opPrev),
    pressed(sec(75), opNext),
    resolved(sec(80), RunEndedTurn, [RunFeedback]),
    added(sec(90), login, [RunFeedback, RunLogin])]
  result = buildScenario("inbox-run", "the operator's inbox over a run",
    PlaybackT0, sessions, @[], extras = extras,
    moments = [(sec(10), "first-wait"), (sec(20), "four-waiting"), (sec(30), "next"),
               (sec(40), "boost-ends"), (sec(50), "answered"), (sec(60), "auto-switch"),
               (sec(70), "prev"), (sec(80), "resolved-elsewhere"),
               (sec(90), "arrives-while-reading")],
    views = [("inbox", @InboxRunMoments)])
  var waitingBefore = feedback
  waitingBefore.position = 1   # 1-based, as a listing serves it
  result.inbox = InboxSnapshot(generatedAtMs: PlaybackT0, items: @[waitingBefore])
  result.inboxDetails = @[
    InboxItemDetail(itemId: RunQuestion.id, sessionId: InboxRouteSessionId,
                    kind: ikBlockedQuestion, blocked: true, requestId: "run-q-1",
                    prompt: "Keep the old behaviour behind a flag?", form: qfFreeForm,
                    familiar: true),
    InboxItemDetail(itemId: RunEndedTurn.id, sessionId: InboxLoggingSessionId,
                    kind: ikEndedTurn, familiar: true,
                    lastReply: "Done. The upload client logs through its module logger now."),
    InboxItemDetail(itemId: RunPermission.id, sessionId: InboxSchemaSessionId,
                    kind: ikPermissionGate, requestId: "run-perm-1", familiar: true,
                    prompt: "Run `psql -f migrations/0042_cache.sql` against staging?",
                    permissionOptions: @[
                      PermissionOption(id: "allow_once", kind: "allow_once",
                                       label: permissionLabel("allow_once")),
                      PermissionOption(id: "reject_once", kind: "reject_once",
                                       label: permissionLabel("reject_once"))]),
    InboxItemDetail(itemId: RunFeedback.id, sessionId: InboxNotesSessionId,
                    kind: ikAsyncFeedback, familiar: true,
                    feedback: FeedbackRequest(id: "run-fb-1", taskId: "release-notes",
                                              feedbackType: ftQuestion,
                                              prompt: "Which changes belong in the highlights?")),
    InboxItemDetail(itemId: RunLogin.id, sessionId: InboxBenchSessionId,
                    kind: ikLoginRequest, familiar: true,
                    login: LoginRequest(requestId: "run-login-1", provider: "Example Cloud",
                                        prompt: "Sign in to read the benchmark bucket."))]

# ---------------------------------------------------------------------------

const PlaybackScenarioNames* = ["front-ends", "initiative-run", "session-run",
                                "inbox-run", "test-run"]
  ## Every synthetic playback scenario, by name.

proc playbackScenario*(name: string): PlaybackScenario =
  ## The synthetic scenario named `name`. Raises `ValueError` for an unknown
  ## name rather than playing some other scenario under it.
  case name
  of "front-ends": frontEndsScenario()
  of "initiative-run": initiativeRunScenario()
  of "session-run": sessionRunScenario()
  of "inbox-run": inboxRunScenario()
  of "test-run": testRunScenario()
  else: raise newException(ValueError, "no playback scenario named " & name)
