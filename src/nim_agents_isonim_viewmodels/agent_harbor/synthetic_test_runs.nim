## Invented test runs for the Tests panel (`test_runs_vm.nim`) and the trace
## links (`trace_opener_vm.nim`, the session timeline's links): the platforms
## an invented fleet offers, each platform's catalog of the relay backpressure
## change of `synthetic_changes.nim` (its plan's Verification entries name
## these tests, so the panel joins them), runs in every state as the events a
## stream delivers, session messages citing traces, recordings and files,
## and the playback scenario `test-run`. Every name, id, path, backend
## assignment, duration and message in this module is invented; nothing here
## is captured data. The runs follow the proposed event shape: one
## `run-started` per platform run, results counted from the tests.
##
## - `testRunsFixture(name)` (`TestRunsFixtureNames`) is the source of each
##   Tests story: a `ScriptedTestRunSource`, or the pending and failing
##   sources for loading and error;
## - `traceLinkFixture(name)` (`TraceLinkFixtureNames`) is the source of each
##   trace-link story: a `TraceLinkSource`, which also serves the session's
##   messages;
## - `testRunScenario()` is the playback scenario `test-run`.

import std/[json, strutils]
import nim_agents/agent_harbor/[test_runs, trace_links]
import ./data_source
import ./scripted_actions
import ./playback_scenario
import ./session_events
import ./synthetic_changes

const
  LinuxX86* = @["arch.x86_64", "os.linux"]
  LinuxArm* = @["arch.aarch64", "os.linux"]
  MacArm* = @["arch.aarch64", "os.macos"]
  WindowsX86* = @["arch.x86_64", "os.windows"]
  WindowsArm* = @["arch.aarch64", "os.windows"]
  TestRunsSessionId* = RelaySessionId
    ## The session whose change the runs test: the relay backpressure session.
  TestRunsServer* = "https://harbor.example.invalid"
    ## The invented server the sessions run on (an https trace link on it is
    ## a trace).
  MacCargoReason* = "No recorder for cargo on macOS arm64: the native recorder needs Linux"
  WindowsRecordReason* = "No recorder for pytest or cargo on Windows x86-64"
  UnpushedReason* = "commit 7c41d2e is on no remote the executors can reach"
  TestRunsErrorText* = "the test platforms could not be read: " &
    "GET /api/v1/test-platforms answered 503"
  TestRunsFixtureNames* = ["populated", "running", "finished", "split", "reused",
    "recording", "recorded", "row-open", "cancel", "cancelled", "refused-unpushed",
    "stream-lost", "platforms", "record-disabled", "unservable", "one-platform",
    "no-platform", "discovering", "discovery-failed", "not-in-catalog", "filtered",
    "long", "selected", "empty", "loading", "error"]
    ## Every Tests story's fixture.
  TraceLinkFixtureNames* = ["one-link", "many-links", "malformed", "replaying",
    "unavailable", "gone", "download", "download-failed", "summary", "file-links",
    "local-recording", "link"]
    ## Every trace-link story's fixture (`link` is the session timeline's
    ## own story with a trace link and a file link).
  OneTraceId* = "3f9b2c1e-7a4d-4e8b-9c2f-1a2b3c4d5e6f"
  SecondTraceId* = "8d7e6f5a-4b3c-4d2e-8f1a-0b9c8d7e6f5a"
  GoneTraceId* = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  TraceGoneAnswer* = "This trace is no longer stored"

proc t(file, name: string; runner = "pytest"; line = 0): CatalogTest =
  ## A catalog test: pytest ids are `<file>::<name>`, cargo ids the test's
  ## module path.
  let id = if runner == "pytest": "pytest/" & file & "::" & name
           else: "cargo/" & name
  let short = if runner == "pytest": name else: name.split("::")[^1]
  CatalogTest(id: id, runner: runner, name: short, file: file, line: line)

proc relayTests*(): seq[CatalogTest] =
  ## The relay change's tests, in the catalog's order: twelve in five files,
  ## two runners.
  @[t("tests/test_queue.py", "test_queue_bound_holds", line = 12),
    t("tests/test_queue.py", "test_oldest_frame_is_shed", line = 27),
    t("tests/test_queue.py", "test_queue_reports_when_full", line = 41),
    t("tests/test_queue.py", "test_queue_drains_in_order", line = 58),
    t("tests/test_metrics.py", "test_depth_metric_reports_each_queue", line = 9),
    t("tests/test_metrics.py", "test_shed_counter_increments", line = 30),
    t("tests/test_flow.py", "test_slow_station_is_told_to_slow_down", line = 15),
    t("tests/test_flow.py", "test_fast_station_is_not_throttled", line = 44),
    t("tests/test_flow.py", "test_backoff_caps_at_thirty_seconds", line = 70),
    t("crates/relay-codec/src/frame.rs", "relay_codec::frame::tests::round_trip", "cargo", 140),
    t("crates/relay-codec/src/frame.rs", "relay_codec::frame::tests::rejects_truncated_frame", "cargo", 162),
    t("crates/relay-codec/src/window.rs", "relay_codec::window::tests::slides", "cargo", 88)]

proc relayTestId*(name: string): string =
  ## The id of the relay test named `name`.
  ## A cargo test is named by its module path (`relay_codec::frame::tests::round_trip`).
  for test in relayTests():
    if test.name == name or test.id == "cargo/" & name: return test.id
  raise newException(ValueError, "no relay test named " & name)

proc ability(runner: string; canRecord: bool; reason = ""; recorders: seq[string] = @[]): RunnerAbility =
  RunnerAbility(runner: runner, canRecord: canRecord, reason: reason,
                recorders: (if canRecord and recorders.len == 0: @["ct-" & runner] else: recorders))

proc offer(features: seq[string]; backends: seq[BackendOffer]): PlatformOffer =
  PlatformOffer(platform: testPlatform(features), backends: backends)

proc fleetOffers*(): seq[PlatformOffer] =
  ## Four platforms: Linux x86-64 (`reprobuild` and `ah-executors`, both
  ## record), Linux arm64 (`ah-executors`, records), macOS arm64
  ## (`ah-executors`; cargo cannot record there), Windows x86-64
  ## (`reprobuild`, no recorder).
  @[offer(LinuxX86, @[
      BackendOffer(backend: "reprobuild", runners: @[ability("pytest", true), ability("cargo", true)]),
      BackendOffer(backend: "ah-executors", runners: @[ability("pytest", true), ability("cargo", true)])]),
    offer(LinuxArm, @[
      BackendOffer(backend: "ah-executors", runners: @[ability("pytest", true), ability("cargo", true)])]),
    offer(MacArm, @[
      BackendOffer(backend: "ah-executors", runners: @[ability("pytest", true),
                                                       ability("cargo", false, MacCargoReason)])]),
    offer(WindowsX86, @[
      BackendOffer(backend: "reprobuild", runners: @[ability("pytest", false, WindowsRecordReason),
                                                     ability("cargo", false, WindowsRecordReason)])])]

proc catalogFor*(features: seq[string]; tests: seq[CatalogTest];
                 state = csDiscovered; reason = ""): PlatformCatalog =
  PlatformCatalog(platform: testPlatform(features), state: state, reason: reason,
                  tests: tests)

proc relayCatalogs*(offers: seq[PlatformOffer]): seq[PlatformCatalog] =
  ## Every offered platform's catalog of the relay change; the Windows one
  ## lacks the codec's window test.
  for o in offers:
    var tests = relayTests()
    if platformKey(o.platform) == platformKey(WindowsX86):
      tests.setLen(tests.len - 1)
    result.add catalogFor(o.platform.features, tests)

# ---------------------------------------------------------------------------
# Runs, as the events a stream delivers
# ---------------------------------------------------------------------------

proc testRunEvent*(kind: TestRunEventKind; run: string; platform: seq[string]; backend = "";
         testId = ""): TestRunEvent =
  ## An event of `run` on `platform`.
  TestRunEvent(kind: kind, kindText: $kind, testRunId: run, platform: platform,
               backend: backend, testId: testId)

proc runStartedEvent*(run: string; platform: seq[string]; backend, runner: string): TestRunEvent =
  result = testRunEvent(tekRunStarted, run, platform, backend)
  result.runner = runner

proc testStartedEvent*(run: string; platform: seq[string]; testId: string): TestRunEvent =
  testRunEvent(tekTestStarted, run, platform, testId = testId)

proc testFinishedEvent*(run: string; platform: seq[string]; testId, status: string; ms = 0;
               reused = false; certificate = ""): TestRunEvent =
  result = testRunEvent(tekTestFinished, run, platform, testId = testId)
  result.status = status
  result.reused = reused
  result.certificate = certificate
  if not reused:
    result.durationMs = ms
    result.hasDuration = true

proc failureEvent*(run: string; platform: seq[string]; testId, message: string;
             file = ""; line = 0): TestRunEvent =
  result = testRunEvent(tekFailure, run, platform, testId = testId)
  result.message = message
  result.location = TestLocation(file: file, line: line)

proc outputEvent*(run: string; platform: seq[string]; testId, stream, text: string): TestRunEvent =
  result = testRunEvent(tekOutput, run, platform, testId = testId)
  result.stream = stream
  result.text = text

proc traceStartedEvent*(run: string; platform: seq[string]; testId, recorder: string): TestRunEvent =
  result = testRunEvent(tekTraceStarted, run, platform, testId = testId)
  result.recorder = recorder

proc traceCreatedEvent*(run: string; platform: seq[string]; testId, trace: string): TestRunEvent =
  result = testRunEvent(tekTraceCreated, run, platform, testId = testId)
  result.trace = AgentHarborTracePrefix & trace

proc runFinishedEvent*(run: string; platform: seq[string]; cancelled = false;
                  reason = ""): TestRunEvent =
  result = testRunEvent(tekRunFinished, run, platform)
  result.cancelled = cancelled
  result.reason = reason

proc diagnosticEvent*(run: string; platform: seq[string]; level, message: string;
                 testId = ""): TestRunEvent =
  result = testRunEvent(tekDiagnostic, run, platform, testId = testId)
  result.level = level
  result.message = message

proc foldEvents*(state: var TestRunState; events: openArray[TestRunEvent]) =
  ## Folds invented events; each must be legal where it comes.
  for e in events:
    doAssert state.applyTestRunEvent(e), "an invented event is illegal: " & $e.kind &
      " " & e.testId

proc newTestRunState*(id: string; platforms: seq[seq[string]]; backends: seq[string];
             tests: seq[CatalogTest] = relayTests(); record = rmNone;
             reuse = rpCertified; startedMs = -1'i64): TestRunState =
  ## A run as created: every test queued on every platform.
  var ps: seq[TestPlatform]
  for p in platforms: ps.add testPlatform(p)
  var ids: seq[string]
  for t in tests: ids.add t.id
  initTestRunState(id, ids, ps, backends, record, reuse, startedMs)

proc passAll(run: string; platform: seq[string]; tests: seq[CatalogTest];
             base = 10): seq[TestRunEvent] =
  for i, t in tests:
    result.add testStartedEvent(run, platform, t.id)
    result.add testFinishedEvent(run, platform, t.id, "passed", base + i * 7)

proc finishedRun*(id = "run-1"): TestRunState =
  ## Every status on three platforms: on Linux x86-64 (`reprobuild`) the
  ## depth metric fails with a location and output, one test is skipped, one
  ## errors; macOS arm64 (`ah-executors`) passes all; Windows x86-64
  ## (`reprobuild`) fails the depth metric too and warns about a slow disk.
  let tests = relayTests()
  # Windows's catalog lacks the window test, so the run asks for it only
  # where the events report it (each platform's own cells).
  result = newTestRunState(id, @[LinuxX86, MacArm, WindowsX86], @["reprobuild", "ah-executors", "reprobuild"],
                  tests[0 .. ^2], startedMs = 120_000)
  let depth = relayTestId("test_depth_metric_reports_each_queue")
  let backoff = relayTestId("test_backoff_caps_at_thirty_seconds")
  let window = relayTestId("relay_codec::window::tests::slides")
  var linux = @[runStartedEvent(id, LinuxX86, "reprobuild", "pytest")]
  for i, t in tests:
    linux.add testStartedEvent(id, LinuxX86, t.id)
    if t.id == depth:
      linux.add outputEvent(id, LinuxX86, t.id, "stdout", "collected queue gauges: ingest, uplink")
      linux.add outputEvent(id, LinuxX86, t.id, "stderr", "AssertionError: uplink depth not reported")
      linux.add failureEvent(id, LinuxX86, t.id, "assert 'uplink' in reported_queues",
                       "tests/test_metrics.py", 21)
      linux.add testFinishedEvent(id, LinuxX86, t.id, "failed", 214)
    elif t.id == backoff:
      linux.add testFinishedEvent(id, LinuxX86, t.id, "skipped", 0)
    elif t.id == window:
      linux.add diagnosticEvent(id, LinuxX86, "error", "the codec crate did not build: linker exited 1", t.id)
      linux.add testFinishedEvent(id, LinuxX86, t.id, "errored", 1_250)
    else:
      linux.add testFinishedEvent(id, LinuxX86, t.id, "passed", 15 + i * 9)
  linux.add runFinishedEvent(id, LinuxX86)
  var mac = @[runStartedEvent(id, MacArm, "ah-executors", "pytest")]
  mac.add passAll(id, MacArm, tests, 20)
  mac.add runFinishedEvent(id, MacArm)
  var windows = @[runStartedEvent(id, WindowsX86, "reprobuild", "pytest"),
                  diagnosticEvent(id, WindowsX86, "warning", "the executor's disk is 92% full")]
  for i, t in tests[0 .. ^2]:
    windows.add testStartedEvent(id, WindowsX86, t.id)
    if t.id == depth:
      windows.add failureEvent(id, WindowsX86, t.id, "assert 'uplink' in reported_queues")
      windows.add testFinishedEvent(id, WindowsX86, t.id, "failed", 380)
    else:
      windows.add testFinishedEvent(id, WindowsX86, t.id, "passed", 30 + i * 11)
  windows.add runFinishedEvent(id, WindowsX86)
  result.foldEvents(linux)
  result.foldEvents(mac)
  result.foldEvents(windows)

proc runningRun*(id = "run-2"): TestRunState =
  ## Mid-way: Linux x86-64 running with four results, macOS arm64 queued,
  ## Windows x86-64 just started.
  let tests = relayTests()
  result = newTestRunState(id, @[LinuxX86, MacArm, WindowsX86], @["reprobuild", "ah-executors", "reprobuild"],
                  startedMs = 240_000)
  var events = @[runStartedEvent(id, LinuxX86, "reprobuild", "pytest")]
  for i in 0 .. 3:
    events.add testStartedEvent(id, LinuxX86, tests[i].id)
    events.add testFinishedEvent(id, LinuxX86, tests[i].id, (if i == 2: "failed" else: "passed"), 20 + i)
  events.add testStartedEvent(id, LinuxX86, tests[4].id)
  events.add runStartedEvent(id, WindowsX86, "reprobuild", "pytest")
  result.foldEvents(events)

proc splitRun*(id = "run-3"): TestRunState =
  ## One test on two platforms: passed on Linux x86-64, failed on Windows
  ## x86-64.
  let test = relayTests()[1]
  result = newTestRunState(id, @[LinuxX86, WindowsX86], @["ah-executors", "reprobuild"], @[test])
  result.foldEvents([runStartedEvent(id, LinuxX86, "ah-executors", "pytest"),
               testStartedEvent(id, LinuxX86, test.id),
               testFinishedEvent(id, LinuxX86, test.id, "passed", 18),
               runFinishedEvent(id, LinuxX86),
               runStartedEvent(id, WindowsX86, "reprobuild", "pytest"),
               testStartedEvent(id, WindowsX86, test.id),
               failureEvent(id, WindowsX86, test.id, "the oldest frame was kept: frame 1 != frame 2",
                      "tests/test_queue.py", 35),
               testFinishedEvent(id, WindowsX86, test.id, "failed", 26),
               runFinishedEvent(id, WindowsX86)])

proc reusedRun*(id = "run-4"): TestRunState =
  ## Three tests reused from certificates on Linux x86-64, the rest run.
  let tests = relayTests()
  result = newTestRunState(id, @[LinuxX86], @["reprobuild"])
  var events = @[runStartedEvent(id, LinuxX86, "reprobuild", "pytest")]
  for i, t in tests:
    if i < 3:
      events.add testFinishedEvent(id, LinuxX86, t.id, "passed", reused = true,
                          certificate = "cert:relay/" & $(i + 1) & "@e4f5a6b")
    else:
      events.add testStartedEvent(id, LinuxX86, t.id)
      events.add testFinishedEvent(id, LinuxX86, t.id, "passed", 12 + i)
  events.add runFinishedEvent(id, LinuxX86)
  result.foldEvents(events)

proc recordingRun*(id = "run-5"; created = false; discarded = false): TestRunState =
  ## A recorded run (`record=all`) of two tests on Linux x86-64: the first
  ## failed and is being recorded; with `created`, its trace is kept; with
  ## `discarded`, the run finished and the second test's recording was not
  ## kept.
  let a = relayTests()[4]
  let b = relayTests()[0]
  result = newTestRunState(id, @[LinuxX86], @["reprobuild"], @[a, b], rmAll, rpNever)
  var events = @[runStartedEvent(id, LinuxX86, "reprobuild", "pytest"),
                 testStartedEvent(id, LinuxX86, a.id),
                 failureEvent(id, LinuxX86, a.id, "assert 'uplink' in reported_queues",
                        "tests/test_metrics.py", 21),
                 testFinishedEvent(id, LinuxX86, a.id, "failed", 230),
                 traceStartedEvent(id, LinuxX86, a.id, "ct-pytest")]
  if created or discarded:
    events.add traceCreatedEvent(id, LinuxX86, a.id, OneTraceId)
  if discarded:
    events.add testStartedEvent(id, LinuxX86, b.id)
    events.add testFinishedEvent(id, LinuxX86, b.id, "passed", 40)
    events.add runFinishedEvent(id, LinuxX86)
  result.foldEvents(events)

proc longTests*(count = 320): seq[CatalogTest] =
  ## A long catalog: `count` tests in deep paths, forty files.
  for i in 0 ..< count:
    let file = "tests/stations/region_" & $(i mod 8) & "/adapters/telemetry/frames/test_decoder_" &
      $(i mod 40) & ".py"
    result.add t(file, "test_decodes_frame_" & $i & "_with_a_long_descriptive_name_about_its_window")

# ---------------------------------------------------------------------------
# The stories' sources
# ---------------------------------------------------------------------------

proc relaySource(label: string): ScriptedTestRunSource =
  ## The relay change's offers and catalogs, its plan (for the Verification
  ## join), and no runs yet.
  result = newScriptedTestRunSource(label)
  result.sessionId = TestRunsSessionId
  result.offers = fleetOffers()
  result.catalogs = relayCatalogs(result.offers)
  result.reviews.add (RelayTaskId, TaskReview(record: relayRecord(), hasPlan: true))

proc testRunsScope*(): ReviewScope =
  ## The relay change: its task (for the plan's Verification entries) and its
  ## session.
  ReviewScope(taskId: RelayTaskId, sessionId: TestRunsSessionId)

proc testRunsFixture*(name: string): AgentHarborDataSource =
  ## The source of the Tests story `name` (`TestRunsFixtureNames`). Raises
  ## `ValueError` for an unknown name.
  let label = "invented test runs: " & name
  case name
  of "loading": return newPendingDataSource()
  of "error": return newFailingDataSource(TestRunsErrorText)
  else: discard
  let s = relaySource(label)
  case name
  of "populated", "not-in-catalog", "platforms", "record-disabled": discard
  of "running", "cancel", "stream-lost": s.runs = @[finishedRun(), runningRun()]
  of "cancelled":
    var run = runningRun()
    for p in [LinuxX86, MacArm, WindowsX86]:
      run.foldEvents([runFinishedEvent(run.id, p, cancelled = true, reason = "cancelled by the operator")])
    s.runs = @[finishedRun(), run]
  of "finished", "row-open", "filtered", "selected": s.runs = @[finishedRun()]
  of "split": s.runs = @[splitRun()]
  of "reused": s.runs = @[reusedRun()]
  of "recording": s.runs = @[finishedRun(), recordingRun()]
  of "recorded": s.runs = @[finishedRun(), recordingRun(discarded = true)]
  of "refused-unpushed":
    s.runs = @[finishedRun()]
    s.script.setRule(oaStartTestRun, failedWith(UnpushedReason))
  of "unservable":
    s.offers.add offer(WindowsArm, @[])
  of "one-platform":
    s.offers = @[fleetOffers()[0]]
    s.catalogs = relayCatalogs(s.offers)
  of "no-platform":
    s.offers = @[]
    s.catalogs = @[]
  of "discovering":
    s.catalogs[2] = catalogFor(MacArm, @[], csDiscovering)
  of "discovery-failed":
    s.catalogs[3] = catalogFor(WindowsX86, @[], csFailed,
                               "pytest could not import tests/conftest.py")
  of "long":
    s.offers = fleetOffers()[0 .. 1]
    s.catalogs = @[catalogFor(LinuxX86, longTests()), catalogFor(LinuxArm, longTests())]
  of "empty":
    s.catalogs = relayCatalogs(s.offers)
    for c in s.catalogs.mitems: c.tests = @[]
  else: raise newException(ValueError, "no Tests story named " & name)
  s

# ---------------------------------------------------------------------------
# Trace links
# ---------------------------------------------------------------------------

type
  TraceLinkSource* = ref object of ScriptedTestRunSource
    ## A scripted test-run source that also serves its session's messages
    ## (`loadSessionEvents`), for the trace-link stories.
    sessionEvents*: seq[JsonNode]

method loadSessionEvents*(source: TraceLinkSource; sessionId: string;
                          done: EventsCallback) =
  if sessionId != source.sessionId:
    done(missingResult[SessionEventHistory]("no session " & sessionId & " in " & source.label))
  else:
    done(success(historyOf(sessionId, source.sessionEvents)))

proc stamped(events: openArray[JsonNode]): seq[JsonNode] =
  ## Each event three seconds after the one before.
  for i, e in events:
    var x = e.copy
    x["timestamp"] = %(int64(i) * 3_000_000)
    result.add x

proc oneLinkText*(): string =
  "The failing test is recorded: agent-harbor://trace/" & OneTraceId &
    " -- it shows the uplink queue never registering its gauge."

proc manyLinksText*(): string =
  "Two traces: agent-harbor://trace/" & OneTraceId & " (Linux) and " &
    TestRunsServer & "/trace/" & SecondTraceId & "?at=frame-118 (Windows), which " &
    "replays the same failure at frame 118; the run summary is at " &
    "https://ci.example.invalid/relay/runs/41."

proc malformedText*(): string =
  "These are not traces: agent-harbor://trace/ and agent-harbor://trace/.. and " &
    "agent-harbor://trace/a%2Fb, nor agent-harbor://session/12."

proc localRecordingText*(): string =
  "Recorded locally as codetracer://recordings/test_queue_bound_holds?mode=refresh " &
    "and on the fleet as agent-harbor://trace/" & OneTraceId & "."

const
  FileLinksText* = "I changed src/relay/queue.py and src/relay/flow.py, read " &
    "src/relay/ and docs/missing.md, and the codec lives in " &
    "crates/relay-codec/src/transports/websocket/framing/compression/window.rs."
  LinkText* = "The depth metric fails because src/relay/metrics.py skips the uplink; " &
    "see agent-harbor://trace/" & OneTraceId & "."

proc spanOf(text, needle: string; targets: seq[FileTarget]; after = ""): FileLinkSpan =
  ## The span of `needle` in `text` (its first place after `after`).
  let from0 = if after.len > 0: text.find(after) + after.len else: 0
  let start = text.find(needle, from0)
  doAssert start >= 0, needle
  FileLinkSpan(start: start, finish: start + needle.len, targets: targets)

proc target(path: string; exists = true; isDir = false; line = 0): FileTarget =
  FileTarget(path: path, exists: exists, isDir: isDir, line: line)

proc fileSpans*(): seq[FileLinkSpan] =
  ## `FileLinksText`'s file links: a unique file, an ambiguous one, a
  ## directory, a missing file and a long path.
  let text = FileLinksText
  @[spanOf(text, "src/relay/queue.py", @[target("src/relay/queue.py", line = 31)]),
    spanOf(text, "src/relay/flow.py", @[target("src/relay/flow.py"),
                                        target("vendor/relay/src/relay/flow.py")]),
    spanOf(text, "src/relay/", @[target("src/relay", isDir = true)], after = "read "),
    spanOf(text, "docs/missing.md", @[target("docs/missing.md", exists = false)]),
    spanOf(text, "crates/relay-codec/src/transports/websocket/framing/compression/window.rs",
           @[target("crates/relay-codec/src/transports/websocket/framing/compression/window.rs")])]

proc traceLinkFixture*(name: string): TraceLinkSource =
  ## The source of the trace-link story `name` (`TraceLinkFixtureNames`): the
  ## session's messages, their file links, its runs, and the replay and
  ## download answers. Raises `ValueError` for an unknown name.
  result = TraceLinkSource(label: "invented trace links: " & name, effects: true,
                           nextRun: 1, script: newActionScript())
  result.sessionId = TestRunsSessionId
  result.offers = fleetOffers()
  result.catalogs = relayCatalogs(result.offers)
  var events = @[userInput("Why does the depth metric fail?"),
                 thoughtEvent("Run the metrics tests and record the failure.")]
  case name
  of "one-link", "replaying", "unavailable", "gone", "download", "download-failed":
    events.add agentReply(oneLinkText())
  of "many-links": events.add agentReply(manyLinksText())
  of "malformed": events.add agentReply(malformedText())
  of "local-recording": events.add agentReply(localRecordingText())
  of "file-links":
    events.add agentReply(FileLinksText)
    result.linkSpans = @[(TestRunsSessionId,
                          @[MessageLinkSpans(ordinal: 3, spans: fileSpans())])]
  of "link":
    events.add agentReply(LinkText)
    let text = LinkText
    result.linkSpans = @[(TestRunsSessionId, @[MessageLinkSpans(ordinal: 3,
      spans: @[spanOf(text, "src/relay/metrics.py", @[target("src/relay/metrics.py", line = 44)])])])]
  of "summary":
    events.add commandCall("t1", "pytest tests/")
    events.add toolResult("t1", "runCmd", 1, "1 failed, 5 passed")
    events.add agentReply("The run is below.")
    var run = splitRun("run-7")
    run.startedMs = 4_000
    result.runs = @[run, recordingRun("run-8", discarded = true)]
    result.runs[1].startedMs = 7_000
  else: raise newException(ValueError, "no trace-link story named " & name)
  case name
  of "unavailable":
    result.replayAnswers = @[(OneTraceId, failedWith("no replay host is free near the trace"))]
  of "gone":
    result.replayAnswers = @[(OneTraceId, failedWith(TraceGoneAnswer))]
  of "download":
    result.downloadAnswers = @[(OneTraceId, confirmedWith("relay-depth-metric.ct"))]
  of "download-failed":
    result.downloadAnswers = @[(OneTraceId, failedWith("the trace store refused: quota exceeded"))]
  else: discard
  result.sessionEvents = stamped(events)

# ---------------------------------------------------------------------------
# The playback scenario `test-run`
# ---------------------------------------------------------------------------

const
  TestRunT0* = 1_800_000_000_000'i64
    ## The scenario's first moment, the playback scenarios' own
    ## (`playback_scenarios.PlaybackT0`, 2027-01-15 08:00 UTC).
  TestRunMoments* = ["started", "first-results", "reused", "recording", "recorded",
                     "cancelled"]

proc at(s: int): int64 = TestRunT0 + int64(s) * 1000

proc testRunScenario*(): PlaybackScenario =
  ## The relay session's test runs on three platforms, for the Tests panel
  ## (`tests`). At the first moment the earlier run (`run-1`) is finished and
  ## the operator's Run (`run-2`, six tests, `record=failing`) is queued on
  ## Linux x86-64 (`reprobuild`), macOS arm64 (`ah-executors`) and Windows
  ## x86-64 (`reprobuild`). The session, queued at the first moment, starts
  ## running at +2 s.
  ##
  ## - +5 s, `started`: Linux and macOS start;
  ## - +10 s, `first-results`: four tests finish on Linux, one fails; macOS
  ##   starts one;
  ## - +15 s, `reused`: Windows starts and answers two tests as reused;
  ## - +20 s, `recording`: the failing test is recorded on Linux;
  ## - +25 s, `recorded`: its trace is created;
  ## - +30 s, `cancelled`: the operator cancels; macOS, still running, ends
  ##   cancelled, the others keep their results.
  let tests = relayTests()[0 .. 5]
  var session = ScenarioSession(
    entry: FleetSession(id: TestRunsSessionId, prompt: "Bound every relay queue at 256 frames",
                        agentSoftware: "Claude", agentVersion: "2.1.0", agentCount: 1,
                        host: "host-a", originFrontEnd: "codetracer",
                        labelSource: "invented"),
    startMs: at(-10))
  # The session is listed before the first moment (queued at -9 s) on
  # purpose: in a scenario with no initiatives, a session first listed after
  # the first moment makes the initiative tab bar's session tab active when
  # the bar is loaded after the session appeared, and not when the bar
  # followed the playback there, so the "loaded late" agreement check of
  # `test_playback` fails. That is a defect of the tab bar, recorded as an
  # issue ("initiative tab bar active tab depends on load order"); this
  # fixture keeps clear of it until it is fixed.
  for (s, status) in [(-9, "queued"), (2, "running")]:
    session.history.add scenarioEvent(session.startMs, at(s),
                                      %*{"type": "status", "status": status})
  let id = "run-2"
  var run = newTestRunState(id, @[LinuxX86, MacArm, WindowsX86],
                   @["reprobuild", "ah-executors", "reprobuild"], tests, rmFailing, rpCertified)
  let depth = tests[4].id
  var extras: seq[ScenarioEntry]
  proc add(s: int; e: TestRunEvent) = extras.add testRunEntry(at(s), e)
  add(5, runStartedEvent(id, LinuxX86, "reprobuild", "pytest"))
  add(5, runStartedEvent(id, MacArm, "ah-executors", "pytest"))
  for i in 0 .. 3:
    let testId = if i == 3: depth else: tests[i].id
    add(10, testStartedEvent(id, LinuxX86, testId))
    if testId == depth:
      add(10, failureEvent(id, LinuxX86, testId, "assert 'uplink' in reported_queues",
                     "tests/test_metrics.py", 21))
      add(10, testFinishedEvent(id, LinuxX86, testId, "failed", 214))
    else:
      add(10, testFinishedEvent(id, LinuxX86, testId, "passed", 14 + i))
  add(10, testStartedEvent(id, MacArm, tests[0].id))
  add(15, runStartedEvent(id, WindowsX86, "reprobuild", "pytest"))
  for i in 0 .. 1:
    add(15, testFinishedEvent(id, WindowsX86, tests[i].id, "passed", reused = true,
                     certificate = "cert:relay/" & $(i + 1) & "@e4f5a6b"))
  add(20, traceStartedEvent(id, LinuxX86, depth, "ct-pytest"))
  add(25, traceCreatedEvent(id, LinuxX86, depth, OneTraceId))
  add(30, runFinishedEvent(id, MacArm, cancelled = true, reason = "cancelled by the operator"))
  result = buildScenario("test-run", "the relay change's tests on three platforms",
    TestRunT0, @[session], @[], extras = extras,
    moments = [(at(5), "started"), (at(10), "first-results"), (at(15), "reused"),
               (at(20), "recording"), (at(25), "recorded"), (at(30), "cancelled")],
    views = [("tests", @TestRunMoments)])
  result.testPlatforms = @[fleetOffers()[0], fleetOffers()[2], fleetOffers()[3]]
  result.testCatalogs = relayCatalogs(result.testPlatforms)
  var earlier = finishedRun()
  earlier.startedMs = -60_000
  run.startedMs = 0
  result.testRuns = @[ScenarioTestRun(sessionId: TestRunsSessionId, state: earlier),
                      ScenarioTestRun(sessionId: TestRunsSessionId, state: run)]
