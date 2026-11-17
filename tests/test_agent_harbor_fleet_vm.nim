## The Agent Harbor data-source seam and `FleetSnapshotVM`, over the fixture
## set the build embedded and the state sources. The fixture set is the
## private capture of a real fleet and real tool runs where the build can see
## it, and the committed synthetic set otherwise (`fixture_source.nim` says
## how it is chosen); every assertion below holds for both, and the few that
## are specific to one set say so. `AGENT_HARBOR_FIXTURES=synthetic just test`
## runs them over the synthetic set where both are available.
##
## No mocks: the fixture source replays real captures, and the state sources
## (`PendingDataSource`, `FailingDataSource`, `SnapshotDataSource`) are
## production implementations of the seam for the states no capture shows.
## `OutOfOrderSource` below is the one test double: it holds answers back so
## the test can deliver them in an order a live server may produce, which no
## real source does on demand. The frames a list follows after its first
## snapshot (the last suite) are an invented run's, built in this file, and
## the two synthetic playback scenarios' (`playback_scenarios.nim`); the list
## under test folds them through its production reducer, and the oracle it is
## compared with is a second list loaded through `SnapshotDataSource` from a
## listing rebuilt from scratch in this file.
##
## Assertions about the fixture's contents are made against the fixture's own
## JSON, decoded independently with std/json, so a refreshed capture does not
## break them and an emptied one does.

import std/[algorithm, json, os, sets, strutils, tables, unittest]
import isonim/core/[computation, owner, signals]
import nim_agents/agent_harbor/session_replay
import nim_agents_isonim_viewmodels

type
  OutOfOrderSource = ref object of AgentHarborDataSource
    held: seq[FleetCallback]

method loadFleet(source: OutOfOrderSource; done: FleetCallback) =
  source.held.add(done)

proc fleetJson(source: FixtureDataSource): JsonNode =
  parseJson(source.fixtureText(source.manifest{"fleet", "sessions"}.getStr))

proc snapshotOf(source: AgentHarborDataSource): FleetSnapshot =
  var got: DataResult[FleetSnapshot]
  source.loadFleet proc(answer: DataResult[FleetSnapshot]) = got = answer
  doAssert got.ok, got.error
  got.value

suite "Agent Harbor records":
  test "RFC 3339 timestamps decode identically on every target":
    check parseIsoMs("1970-01-01T00:00:00Z") == 0
    check parseIsoMs("2026-11-03T18:34:17.310422349Z") == 1_793_730_857_310'i64
    check parseIsoMs("2026-11-03T20:34:17.310+02:00") == 1_793_730_857_310'i64
    check parseIsoMs("") == 0
    check parseIsoMs("not a time") == 0

  test "ages and durations use the snapshot's clock":
    let now = parseIsoMs("2026-11-03T19:00:00Z")
    check ageLabel(now, now - 5_000) == "now"
    check ageLabel(now, now - 45_000) == "45s"
    check ageLabel(now, now - 12 * 60_000) == "12m"
    check ageLabel(now, now - 3 * 3_600_000) == "3h"
    check ageLabel(now, now - 2 * 86_400_000) == "2d"
    check ageLabel(now, 0) == ""
    check durationLabel(now - 65 * 60_000, now) == "1h 05m"
    check durationLabel(now, now - 1) == ""

  test "a question's text is never echoed into an activity line":
    let event = parseJson("""{"type":"agent_question","kind":"single_choice",
      "prompt":"private words","options":[{"label":"more private words"}]}""")
    let line = activityFromJson(event)
    check line.kind == fakQuestion
    check line.text == "Asked a single-choice question"
    check "private" notin line.text

  test "an input request is named by its words, never by ids":
    check requestLabel("0f0e0d0c-1b2a-4c3d-8e4f-a0b1c2d3e4f5:native-question:3") ==
      "native question"
    check requestLabel("claude-stop-hook") == "claude stop hook"
    check requestLabel("") == ""
    let line = activityFromJson(parseJson("""{"type":"session_awaiting_input",
      "request":"0f0e0d0c-1b2a-4c3d-8e4f-a0b1c2d3e4f5:native-question:3"}"""))
    check line.text == "Waiting for input (native question)"
    let stalled = activityFromJson(parseJson(
      """{"type":"anti_halting_resume_confirmed","stallType":"unknown"}"""))
    check stalled.text == "Anti-halting resumed a stalled turn"

  test "the status shown is the effective one: needing input wins":
    # INV-P2-13/14/19: a live session that waits for a person shows "needs
    # input", whatever its wire status; an inferred wait says so.
    var session = FleetSession(status: fsRunning, rawStatus: "running",
                               awaitingInput: true,
                               awaitingInputSource: "claude-stop-hook")
    check session.effectiveStatusLabel == "needs input"
    session.awaitingInputSource = "settle-heuristic"
    check session.effectiveStatusLabel == "needs input (estimated)"
    session.awaitingInput = false
    check session.effectiveStatusLabel == "running"
    session.status = fsPaused
    check session.effectiveStatusLabel == "needs input"
    # An ended session never needs input, even with a stale flag.
    session = FleetSession(status: fsCompleted, awaitingInput: true)
    check session.effectiveStatusLabel == "completed"
    session = FleetSession(status: fsUnknown, rawStatus: "hibernating")
    check session.effectiveStatusLabel == "hibernating"
    # And a row shows that label, never the wire one beside a badge.
    let rows = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "s1",
      status: fsRunning, rawStatus: "running", awaitingInput: true)]), ffAll)
    check rows[0].statusLabel == "needs input"
    check rows[0].needsInput

  test "a failed session's reason is its last error, else its last log line":
    var session = FleetSession(status: fsFailed, recent: @[
      FleetActivity(kind: fakLog, level: "info", text: "[exit] status=143"),
      FleetActivity(kind: fakStatus, text: "Status: failed")])
    check session.failureOf == "[exit] status=143"
    session.recent.insert(FleetActivity(kind: fakLog, level: "error",
                                        text: "workspace provisioning failed"), 0)
    check session.failureOf == "workspace provisioning failed"
    session.recent = @[FleetActivity(kind: fakStatus, text: "Status: failed")]
    check session.failureOf == ""
    session.recent.add(FleetActivity(kind: fakLog, level: "info",
                                     text: "[scrubbed: quoted prompt text]"))
    check session.failureOf == ""
    # An error-level scrubbed line is no reason either, in the listing or in
    # a history.
    session.recent.add(FleetActivity(kind: fakLog, level: "error",
                                     text: "[scrubbed: quoted prompt text]"))
    check session.failureOf == ""
    check failureReasonOf([FleetActivity(kind: fakLog, level: "error",
                                         text: "[scrubbed: quoted prompt text]"),
                           FleetActivity(kind: fakLog, level: "info",
                                         text: "[exit] status=2")]) ==
      "[exit] status=2"
    session.failureReason = "[exit] status=1"
    check session.failureOf == "[exit] status=1"
    check failureReasonOf([FleetActivity(kind: fakStatus, text: "Status: failed"),
                           FleetActivity(kind: fakLog, level: "info", text: "[exit] status=143"),
                           FleetActivity(kind: fakLog, level: "info", text: "older")]) ==
      "[exit] status=143"
    session = FleetSession(status: fsCompleted, recent: @[
      FleetActivity(kind: fakLog, level: "error", text: "late error")])
    check session.failureOf == ""

  test "a row's activity collapses repeats and leads with what says most":
    # Manager note 4(3): the routine "Resumed by human" / "Waiting for input"
    # events collapse, counted, and the most informative recent event leads.
    let a = FleetActivity(kind: fakResumed, text: "Resumed by human", level: "")
    let b = FleetActivity(kind: fakAwaitingInput, text: "Waiting for input", level: "")
    let c = FleetActivity(kind: fakLog, text: "assistant: wrote the migration", level: "info")
    var row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "s1",
      status: fsRunning, recent: @[c, b, a, a, a, b])]), ffAll)[0]
    check row.activity == @["assistant: wrote the migration",
                            "Waiting for input \xC3\x972", "Resumed by human \xC3\x973"]
    check row.activityLevels.len == 3
    check row.activityMore == 0
    check not row.expanded
    # More distinct lines than a row shows are counted, not dropped silently.
    row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "s1", status: fsRunning,
      recent: @[c, b, a, FleetActivity(kind: fakStatus, text: "Status: running")])]),
      ffAll, expanded = "s1")[0]
    check row.activity.len == FleetActivityLineLimit
    check row.activityMore == 1
    check row.expanded

  test "a withheld prompt falls back to what a person calls the session":
    var session = FleetSession(id: "0123456789abcdef", promptWithheld: true,
                               withheld: @["prompt"])
    check session.titleOf == ("Session 01234567", lsId)
    session.workspaceName = "orbit-ws-2"
    check session.titleOf == ("orbit-ws-2", lsWorkspace)
    session.branch = "fix/step-count"
    check session.titleOf == ("fix/step-count", lsBranch)
    session.applyLabel(SessionLabel(name: "propagator", workspaceName: "ignored",
                                    initiative: "Retries", source: "a window"))
    check session.titleOf == ("propagator", lsName)
    check session.workspaceName == "orbit-ws-2" # the listing's value wins
    check session.initiative == "Retries"
    session.prompt = "Fix the step counter\nand its tests"
    check session.titleOf == ("Fix the step counter", lsPrompt)
    let row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "abcdef0123",
      promptWithheld: true, name: "propagator", status: fsRunning)]), ffAll)[0]
    check row.title == "propagator"
    check not row.titleIsPlaceholder
    check row.promptNote == FleetWithheldPromptText

  test "the lifecycle feed's SSE frames decode in order":
    let frames = parseLifecycleSse(
      "event: resync\ndata: {\"cursor\":\"e1-9\",\"reason\":\"no_cursor\"}\n\n" &
      ": keep-alive comment\n\n" &
      "event: lifecycle\ndata: {\"kind\":\"session_created\",\"sessionId\":\"s1\"," &
      "\"status\":\"queued\",\"at\":\"2026-11-03T06:42:41.806Z\"}\nid: e1-10\n\n")
    check frames.len == 2
    check frames[0].event == "resync"
    check frames[0].cursor == "e1-9"
    check frames[0].reason == "no_cursor"
    check frames[1].kind == "session_created"
    check frames[1].sessionId == "s1"
    check frames[1].cursor == "e1-10"
    check frames[1].atMs > 0

  test "a session waiting for a person outranks running":
    var session = FleetSession(status: fsRunning, awaitingInput: true)
    check session.category == fcNeedsInput
    session.awaitingInput = false
    check session.category == fcRunning
    session.status = fsFailed
    session.awaitingInput = true
    check session.category == fcFailed

const forcedFixtures = getEnv("AGENT_HARBOR_FIXTURES")
  ## What this test binary was compiled with, if anything.

suite "FixtureDataSource":
  test "the fixture set the build asked for is the one embedded":
    if forcedFixtures == "synthetic":
      check AgentHarborFixtureSet == "synthetic"
      check AgentHarborFixtureRoot.endsWith("fixtures" / "agent-harbor")
    elif forcedFixtures.len > 0:
      check AgentHarborFixtureRoot == forcedFixtures
    else:
      # The default: the private set where it is beside the checkout.
      check AgentHarborFixtureSet in ["private", "synthetic"]
      if AgentHarborFixtureSet == "private":
        check "codetracer-pm" in AgentHarborFixtureRoot

  test "the fleet snapshot decodes every listed session":
    let source = newFixtureDataSource()
    let raw = source.fleetJson
    let snapshot = source.snapshotOf
    check raw["items"].len > 0
    check snapshot.sessions.len == raw["items"].len
    check snapshot.total == raw["total"].getInt
    check snapshot.capturedAtMs > 0
    var ids = initHashSet[string]()
    for i, session in snapshot.sessions:
      check session.id == raw["items"][i]["id"].getStr
      check session.status != fsUnknown or session.rawStatus.len > 0
      ids.incl(session.id)
    check ids.len == snapshot.sessions.len

  test "the embedded set is labelled, and its prompts are in their set's state":
    let source = newFixtureDataSource()
    check AgentHarborFixtureSet in ["private", "synthetic"]
    check source.manifest{"fixtureSet"}.getStr == AgentHarborFixtureSet
    let sessions = source.snapshotOf.sessions
    if AgentHarborFixtureSet == "private":
      # A capture is scrubbed: no prompt survives. (Most sessions are also
      # marked withheld; a session the server listed with an empty prompt of
      # its own is not, and the capture keeps that state as it was.)
      var withheld = 0
      for session in sessions:
        check session.prompt.len == 0
        if session.promptWithheld: inc withheld
      check withheld > 0
    else:
      # The synthetic set shows both states a front-end must render.
      var withPrompt, withheld = 0
      for session in sessions:
        if session.promptWithheld:
          inc withheld
          check session.prompt.len == 0
        elif session.prompt.len > 0:
          inc withPrompt
      check withPrompt > 0
      check withheld > 0

  test "every captured event history loads, an uncaptured one fails":
    let source = newFixtureDataSource()
    let ids = source.capturedSessionIds
    check ids.len > 0
    for id in ids:
      var got: DataResult[SessionEventHistory]
      source.loadSessionEvents(id, proc(a: DataResult[SessionEventHistory]) = got = a)
      check got.ok
      check got.value.sessionId == id
      check got.value.events.len ==
        parseJson(source.fixtureText(source.manifest{"fleet", "events", id}.getStr))["events"].len
    var missing: DataResult[SessionEventHistory]
    source.loadSessionEvents("no-such-session",
      proc(a: DataResult[SessionEventHistory]) = missing = a)
    check not missing.ok
    check "no-such-session" in missing.error

  test "the label table names sessions whose prompt is withheld":
    let source = newFixtureDataSource()
    let labelsPath = source.manifest{"fleet", "labels"}.getStr
    check labelsPath.len > 0
    let table = parseJson(source.fixtureText(labelsPath))
    var named = 0
    for session in source.snapshotOf.sessions:
      if table.hasKey(session.id) and table[session.id]{"name"}.getStr.len > 0:
        inc named
        check session.name == table[session.id]["name"].getStr
        if session.prompt.len == 0:
          check session.titleOf.source == lsName
    check named > 0

  test "every session of the embedded fleet has a title; the synthetic fleet's are all different":
    # `titleOf` gives every session a title, whatever is withheld. Telling
    # sessions apart by title is a property of the invented (synthetic) set,
    # which is written so a fleet panel over it shows rows a person can pick
    # between (the IsoNim Editor smoke in CodeTracer checks the rendered rows
    # for exactly this). The captured fleet legitimately repeats titles: many
    # sessions share one working copy and branch, and their prompts are
    # withheld, so the name, branch or workspace they fall back to is the
    # same. Uniqueness is therefore asserted for the synthetic set only.
    let source = newFixtureDataSource()
    var seen = initHashSet[string]()
    var repeated: seq[string]
    for session in source.snapshotOf.sessions:
      let title = session.titleOf.text
      check title.len > 0
      if title in seen: repeated.add(title)
      seen.incl(title)
    if AgentHarborFixtureSet == "synthetic":
      check repeated.len == 0
      if repeated.len > 0:
        checkpoint "titles shared by more than one session: " & $repeated

  test "failed sessions with a captured history carry its reason":
    let source = newFixtureDataSource()
    var withHistory, withReason = 0
    for session in source.snapshotOf.sessions:
      if session.category == fcFailed and
          source.manifest{"fleet", "events"}.hasKey(session.id):
        inc withHistory
        if session.failureOf.len > 0: inc withReason
      # No row shows a line the capture scrubbed as its failure.
      check not session.failureOf.startsWith("[scrubbed")
    check withHistory > 0
    check withReason > 0

  test "the lifecycle replay holds lifecycle frames":
    var got: DataResult[seq[LifecycleFrame]]
    newFixtureDataSource().loadLifecycle(
      proc(a: DataResult[seq[LifecycleFrame]]) = got = a)
    check got.ok
    var lifecycle = 0
    for frame in got.value:
      if frame.event == "lifecycle":
        inc lifecycle
        check frame.sessionId.len > 0
    check lifecycle > 0

  test "plans, diffs, test runs and scenario runs are served":
    let source = newFixtureDataSource()
    var plans: DataResult[seq[PlanFile]]
    source.loadPlans(proc(a: DataResult[seq[PlanFile]]) = plans = a)
    check plans.ok
    check plans.value.len >= 2
    for plan in plans.value:
      check plan.text.contains(":status:")
    var diffs: DataResult[seq[BranchDiff]]
    source.loadDiffs(proc(a: DataResult[seq[BranchDiff]]) = diffs = a)
    check diffs.ok
    check diffs.value.len >= 2
    for diff in diffs.value:
      check diff.unifiedDiff.startsWith("diff --git ")
      check diff.filesChanged > 0
    var runs: DataResult[seq[TestRunCapture]]
    source.loadTestRuns(proc(a: DataResult[seq[TestRunCapture]]) = runs = a)
    check runs.ok
    check runs.value.len >= 1
    for run in runs.value:
      check parseJson(run.testRunEventsJson).len > 0
      check run.runnerEventsJsonl.strip.len > 0
    var scenarios: DataResult[seq[ScenarioRunCapture]]
    source.loadScenarioRuns(proc(a: DataResult[seq[ScenarioRunCapture]]) = scenarios = a)
    check scenarios.ok
    check scenarios.value.len >= 2
    for run in scenarios.value:
      check parseJson(run.eventsJson)["events"].len > 0

  test "a failed row shows its reason once, as the failure, not again as activity":
    # The reason a failed row shows (`failureText`) is read from its newest
    # error-level log line; the same line in the activity digest would say it
    # twice, one line under the other (the playback fleet at
    # `migration-fails`). The activity keeps every other line, and the count
    # of lines beyond the limit leaves the repeated one out too.
    let err = FleetActivity(kind: fakLog, level: "error",
                            text: "error: the migration test failed")
    let tool = FleetActivity(kind: fakToolUse, level: "", text: "just test")
    let failed = FleetSnapshot(sessions: @[FleetSession(id: "f1", status: fsFailed, rawStatus: "failed",
      recent: @[tool, err, FleetActivity(kind: fakStatus, text: "Status: failed")])])
    var row = rowsOf(failed, ffAll)[0]
    check row.failureText == "error: the migration test failed"
    check row.activity == @["just test"]
    check row.activityLevels == @[""]
    check row.activityMore == 0
    # Repeated, it is still the failure alone (its count is not shown either).
    row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "f1", status: fsFailed,
      recent: @[err, tool, err])]), ffAll)[0]
    check row.failureText == err.text
    check row.activity == @["just test"]
    # A live session's error is not a failure: it stays an activity line.
    row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "r1", status: fsRunning,
      recent: @[tool, err])]), ffAll)[0]
    check row.failureText == ""
    check row.activity == @["error: the migration test failed", "just test"]
    # A failure whose reason is not among the activity lines (the listing's
    # own `failureReason`) removes nothing.
    row = rowsOf(FleetSnapshot(sessions: @[FleetSession(id: "f2", status: fsFailed,
      failureReason: "[exit] status=1", recent: @[tool])]), ffAll)[0]
    check row.failureText == "[exit] status=1"
    check row.activity == @["just test"]

suite "FleetSnapshotVM":
  test "idle until loaded, loading until answered":
    createRoot proc(disposeRoot: proc()) =
      let pending = newPendingDataSource()
      let vm = newFleetSnapshotVM(pending)
      check vm.state.val == asIdle
      vm.load()
      check vm.state.val == asLoading
      check vm.rows.len == 0
      check pending.pendingFleet.len == 1
      vm.dispose()
      disposeRoot()

  test "a failed load publishes the error and no rows":
    createRoot proc(disposeRoot: proc()) =
      let vm = newFleetSnapshotVM(newFailingDataSource("connection refused"))
      vm.load()
      check vm.state.val == asError
      check vm.error.val == "connection refused"
      check vm.rows.len == 0
      vm.dispose()
      disposeRoot()

  test "an empty fleet is ready with no rows":
    createRoot proc(disposeRoot: proc()) =
      let vm = newFleetSnapshotVM(newSnapshotDataSource(FleetSnapshot()))
      vm.load()
      check vm.state.val == asReady
      check vm.rows.len == 0
      check vm.counts.listed == 0
      vm.dispose()
      disposeRoot()

  test "the captured fleet is ordered: needing input first, then by recency":
    createRoot proc(disposeRoot: proc()) =
      let vm = newFleetSnapshotVM(newFixtureDataSource())
      vm.load()
      check vm.state.val == asReady
      let rows = vm.rows
      let counts = vm.counts
      check rows.len == counts.listed
      var sum = 0
      for category in FleetCategory: sum += counts.byCategory[category]
      check sum == counts.listed
      for i in 1 ..< rows.len:
        check ord(rows[i - 1].category) <= ord(rows[i].category)
      check counts.byCategory[fcNeedsInput] > 0
      check rows[0].needsInput
      for row in rows:
        check row.activity.len <= FleetActivityLineLimit
        check row.title.len > 0
      vm.dispose()
      disposeRoot()

  test "a filter narrows the rows and leaves the counts alone":
    createRoot proc(disposeRoot: proc()) =
      let vm = newFleetSnapshotVM(newFixtureDataSource())
      vm.load()
      var countRuns = 0
      var rowRuns = 0
      createEffect proc() =
        discard vm.counts
        inc countRuns
      createEffect proc() =
        discard vm.rows
        inc rowRuns
      let before = vm.counts
      vm.setFilter(ffFailed)
      check vm.rows.len == before.byCategory[fcFailed]
      for row in vm.rows: check row.category == fcFailed
      check rowRuns == 2
      # counts reads the revision only, which a filter does not move.
      check countRuns == 1
      vm.setFilter(ffAll)
      check vm.rows.len == before.listed
      vm.dispose()
      disposeRoot()

  test "whether any session names an initiative is the snapshot's, not the filter's":
    createRoot proc(disposeRoot: proc()) =
      let (snapshot, plans) = syntheticWorkingSet(3, 2, 1_800_000_000_000'i64)
      let vm = newFleetSnapshotVM(newSnapshotDataSource(snapshot, "invented", plans))
      vm.load()
      check vm.anyInitiative
      vm.setFilter(ffQueued)
      check vm.rows.len == 0
      check vm.anyInitiative          # a wide list keeps its columns
      vm.dispose()
      let none = newFleetSnapshotVM(newSnapshotDataSource(syntheticWorkingSet(3, 0, 1_800_000_000_000'i64).snapshot))
      none.load()
      check not none.anyInitiative
      none.dispose()
      disposeRoot()

  test "selecting a session loads its events; an uncaptured one errors":
    createRoot proc(disposeRoot: proc()) =
      let source = newFixtureDataSource()
      let vm = newFleetSnapshotVM(source)
      vm.load()
      let id = source.capturedSessionIds[0]
      vm.select(id)
      check vm.eventsState.val == asReady
      check vm.selectedEvents.val.sessionId == id
      var selectedRows = 0
      for row in vm.rows:
        if row.selected:
          inc selectedRows
          check row.id == id
      check selectedRows == 1
      vm.select("no-such-session")
      check vm.eventsState.val == asError
      check vm.eventsError.val.len > 0
      vm.dispose()
      disposeRoot()

  test "an answer to a superseded load is ignored":
    createRoot proc(disposeRoot: proc()) =
      let source = OutOfOrderSource(label: "out of order")
      let vm = newFleetSnapshotVM(source)
      vm.load()
      vm.load()
      check source.held.len == 2
      let fresh = newFixtureDataSource().snapshotOf
      source.held[1](success(fresh))
      check vm.state.val == asReady
      check vm.counts.listed == fresh.sessions.len
      source.held[0](failure[FleetSnapshot]("stale answer"))
      check vm.state.val == asReady
      check vm.error.val == ""
      vm.dispose()
      disposeRoot()

# ---------------------------------------------------------------------------
# A fleet list that follows frames after its first snapshot
# ---------------------------------------------------------------------------
#
# An invented run over the synthetic working set (`synthetic_fleet`): its
# sessions' titles, plans, origins and agents, each given an invented event
# history. The oracle is independent of the fold: the listing at a moment is
# rebuilt from scratch, every session replayed from its start to that moment
# by `replayedFromScratch` (written out below; `sessionAt` would share the
# fold's own per-event step), and loaded into a viewmodel of its own; the
# viewmodel under test only loads the first listing and then folds the frames
# one at a time.

type
  RunSession = object
    entry: FleetSession      ## what the listing says besides its state
    startMs: int64
    removedAtMs: int64       ## 0: never removed
    history: seq[JsonNode]   ## oldest first; timestamps in µs since start

  FleetRun = object
    firstMs: int64
    sessions: seq[RunSession]
    initiatives: seq[Initiative]

const
  RunT0 = 1_800_000_000_000'i64
  RunSessions = 18
  RunFirstListed = 14        ## sessions already started at the first listing
  RunRemoved = 2             ## the session removed during the run

proc runEvent(s: RunSession; atMs: int64; body: JsonNode): JsonNode =
  result = body
  result["timestamp"] = %((atMs - s.startMs) * 1000)

proc inventedFleetRun(): FleetRun =
  ## Sessions that start, ask, are answered, run, fail, end and are removed,
  ## in five patterns over the working set's sessions. Every moment after the
  ## first listing belongs to one phase of one session (`phaseMs`), and
  ## sessions started during the run start before any phase.
  let (snapshot, initiatives) = syntheticWorkingSet(RunSessions, 4, RunT0)
  result = FleetRun(firstMs: RunT0, initiatives: initiatives)
  proc phaseMs(phase, i: int): int64 =
    RunT0 + 150_000 + int64(phase) * 30_000 + int64(i) * 1_000
  for i, listed in snapshot.sessions:
    var s = RunSession(entry: listed)
    s.entry.failureReason = ""
    s.startMs =
      if i < RunFirstListed: listed.startedAtMs
      else: RunT0 + 10_000 + int64(i - RunFirstListed) * 20_000
    if i == RunRemoved: s.removedAtMs = RunT0 + 300_000
    let pattern = i mod 5
    s.history.add s.runEvent(s.startMs + 1_000, %*{"type": "status", "status": "queued"})
    let runningAt = if pattern == 3: phaseMs(0, i) else: s.startMs + 3_000
    if pattern != 3:
      s.history.add s.runEvent(runningAt, %*{"type": "status", "status": "running"})
    s.history.add s.runEvent(s.startMs + 60_000, %*{"type": "tool_use",
      "status": "started", "tool_name": "runCmd", "tool_args": {"command": "just test"}})
    case pattern
    of 0:
      s.history.add s.runEvent(phaseMs(0, i), %*{"type": "agent_question",
        "kind": "single_choice", "prompt": "invented"})
      s.history.add s.runEvent(phaseMs(1, i), %*{"type": "user_input", "content": "invented"})
      s.history.add s.runEvent(phaseMs(2, i), %*{"type": "tool_use",
        "status": "started", "tool_name": "runCmd", "tool_args": {"command": "just lint"}})
      s.history.add s.runEvent(phaseMs(3, i), %*{"type": "status", "status": "completed"})
    of 1:
      s.history.add s.runEvent(phaseMs(1, i), %*{"type": "log", "level": "error",
        "message": "error: the build failed"})
      s.history.add s.runEvent(phaseMs(2, i), %*{"type": "status", "status": "failed"})
    of 2:
      for phase in 0 .. 2:
        s.history.add s.runEvent(phaseMs(phase, i), %*{"type": "log",
          "level": "info", "message": "assistant: Running the tests again."})
    of 3:
      s.history.add s.runEvent(phaseMs(0, i), %*{"type": "status", "status": "running"})
      s.history.add s.runEvent(phaseMs(1, i), %*{"type": "tool_use",
        "status": "started", "tool_name": "runCmd", "tool_args": {"command": "just build"}})
    else:
      s.history.add s.runEvent(phaseMs(2, i), %*{"type": "agent_question",
        "kind": "single_choice", "prompt": "invented"})
    result.sessions.add s

proc timeOf(s: RunSession; event: JsonNode): int64 =
  s.startMs + event["timestamp"].getBiggestInt div 1000

proc replayedFromScratch(session: FleetSession; events: openArray[JsonNode];
                         count: int; startMs: int64): FleetSession =
  ## The session after its first `count` events, derived from the whole
  ## prefix at once: the last `status` event's status, a question wait when
  ## it is live and its last event is the agent asking, its end at its last
  ## update when it is no longer live, and its last three events.
  result = session
  let n = max(0, min(count, events.len))
  result.rawStatus = "queued"
  result.awaitingInput = false
  result.awaitingInputSource = ""
  result.endedAtMs = 0
  result.recent = @[]
  result.startedAtMs = startMs
  result.createdAtMs = startMs
  result.updatedAtMs = startMs
  for i in 0 ..< n:
    let at = startMs + events[i]{"timestamp"}.getBiggestInt div 1000
    result.updatedAtMs = max(result.updatedAtMs, at)
    if events[i]{"type"}.getStr == "status":
      result.rawStatus = events[i]{"status"}.getStr
  result.status = parseFleetStatus(result.rawStatus)
  if not result.status.isActive:
    result.endedAtMs = result.updatedAtMs
  elif n > 0 and events[n - 1]{"type"}.getStr in ["agent_question", "session_awaiting_input"]:
    result.awaitingInput = true
    result.awaitingInputSource = result.id & ":native-question:" & $n
  for i in max(0, n - 3) ..< n:
    var line = activityFromJson(events[i])
    line.timestampMs = startMs + events[i]{"timestamp"}.getBiggestInt div 1000
    result.recent.add line

proc listedAt(run: FleetRun; t: int64): FleetSnapshot =
  ## The oracle: the listing a server would give at `t`.
  result = FleetSnapshot(capturedAtMs: t, sourceLabel: "invented run")
  for s in run.sessions:
    if s.startMs > t or (s.removedAtMs > 0 and s.removedAtMs <= t): continue
    var count = 0
    for event in s.history:
      if s.timeOf(event) <= t: inc count
    result.sessions.add s.entry.replayedFromScratch(s.history, count, s.startMs)
  result.total = result.sessions.len

proc framesOf(run: FleetRun): seq[FleetFrame] =
  ## What a live feed delivers after the first listing, in time order: a new
  ## session's `session_created` and its listing entry, every event, a
  ## lifecycle frame beside every status event, and removals.
  var timed: seq[(int64, int, FleetFrame)]
  proc add(t: int64; frame: FleetFrame) =
    var stamped = frame
    stamped.atMs = t
    timed.add (t, timed.len, stamped)
  for s in run.sessions:
    let id = s.entry.id
    if s.startMs > run.firstMs:
      add(s.startMs, lifecycleFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_created", sessionId: id, status: "queued",
        agent: s.entry.agentSoftware, atMs: s.startMs)))
      add(s.startMs, sessionFrame(s.entry.sessionAt(s.history, 0, s.startMs)))
    for i, event in s.history:
      let t = s.timeOf(event)
      if t <= run.firstMs: continue
      add(t, eventFrame(id, event, i + 1))
      if event["type"].getStr == "status":
        let st = event["status"].getStr
        add(t, lifecycleFrame(LifecycleFrame(event: "lifecycle",
          kind: (if parseFleetStatus(st).isActive: "session_status_changed"
                 else: "session_completed"),
          sessionId: id, status: st, atMs: t)))
    if s.removedAtMs > run.firstMs:
      add(s.removedAtMs, lifecycleFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_removed", sessionId: id, atMs: s.removedAtMs)))
  timed.sort proc(a, b: (int64, int, FleetFrame)): int =
    cmp((a[0], a[1]), (b[0], b[1]))
  for entry in timed: result.add entry[2]

proc groupsOf(rows: openArray[FleetRow]): seq[(FleetCategory, seq[string])] =
  ## The rows as the list groups them: by what each session needs from the
  ## reader, in the list's order.
  for row in rows:
    if result.len == 0 or result[^1][0] != row.category:
      result.add (row.category, newSeq[string]())
    result[^1][1].add row.id

proc listDifferences(followed, loaded: FleetSnapshotVM): seq[string] =
  ## What the two lists show differently: rows (with their activity digests),
  ## groups, counts and the clock.
  let a = followed.rows
  let b = loaded.rows
  if a.len != b.len:
    result.add "rows " & $a.len & " != " & $b.len
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      result.add "row " & $i & ": " & $a[i] & " != " & $b[i]
      break
  if a.groupsOf != b.groupsOf:
    result.add "groups " & $a.groupsOf & " != " & $b.groupsOf
  if followed.counts != loaded.counts:
    result.add "counts " & $followed.counts & " != " & $loaded.counts
  if followed.capturedAgeLabel != loaded.capturedAgeLabel:
    result.add "clock " & followed.capturedAgeLabel & " != " & loaded.capturedAgeLabel

proc loadedAt(run: FleetRun; t: int64): FleetSnapshotVM =
  result = newFleetSnapshotVM(newSnapshotDataSource(run.listedAt(t), "invented run",
                                                    run.initiatives))
  result.load()

proc runOf(scenario: PlaybackScenario): FleetRun =
  ## A playback scenario's sessions as a run the oracle rebuilds listings
  ## from: each session's identity, start, removal and whole history.
  result = FleetRun(firstMs: scenario.firstMs, initiatives: scenario.initiatives)
  for s in scenario.sessions:
    result.sessions.add RunSession(entry: s.entry, startMs: s.startMs,
                                   removedAtMs: s.removedAtMs, history: s.history)

proc fleetFramesOf(scenario: PlaybackScenario): seq[FleetFrame] =
  ## The fleet frames a playback of the scenario delivers, in its order.
  for entry in scenario.entries:
    if entry.isFleetEntry: result.add entry.frameOf

proc foldDifferences(run: FleetRun; first: FleetSnapshot; frames: seq[FleetFrame];
                     label: string): tuple[failures: seq[string], moments: int] =
  ## Loads `first`, folds `frames` one at a time, and compares the list after
  ## each moment's last frame with a list loaded from the listing rebuilt
  ## from scratch at that moment (and the first listing with the one rebuilt
  ## at the first moment).
  let followed = newFleetSnapshotVM(newSnapshotDataSource(first, label, run.initiatives))
  followed.load()
  let start = run.loadedAt(run.firstMs)
  for d in listDifferences(followed, start):
    result.failures.add label & ": the first snapshot: " & d
  start.dispose()
  for i, frame in frames:
    let outcome = followed.apply(frame)
    if outcome notin {foApplied, foUnchanged}:
      result.failures.add label & ": frame " & $i & " (" & $frame & ") was " & $outcome
    if i < frames.high and frames[i + 1].atMs == frame.atMs: continue
    inc result.moments
    let loaded = run.loadedAt(frame.atMs)
    for d in listDifferences(followed, loaded):
      result.failures.add label & ": after frame " & $i & " (" & $frame & "): " & d
    loaded.dispose()
  followed.dispose()

suite "FleetSnapshotVM follows frames":
  test "test_ctf_p1c_fleet_folds_lifecycle_frames":
    # Folding a run's frames from its first snapshot gives, at every moment,
    # the rows, groups, counts and activity digests of a list loaded from the
    # snapshot taken at that moment. Frames sharing a moment (a status event
    # and its lifecycle frame, a new session's frame and its listing entry)
    # are compared after the moment's last one. Three runs: the invented run
    # above, and the fleet frames of both synthetic playback scenarios, from
    # each scenario's own first listing.
    createRoot proc(disposeRoot: proc()) =
      var failures: seq[string]
      let run = inventedFleetRun()
      let frames = run.framesOf
      let invented = foldDifferences(run, run.listedAt(run.firstMs), frames, "invented run")
      failures.add invented.failures
      check frames.len == 85
      check invented.moments == 61
      for name in PlaybackScenarioNames:
        let scenario = playbackScenario(name)
        let scenarioFrames = scenario.fleetFramesOf
        let played = foldDifferences(scenario.runOf, scenario.first, scenarioFrames,
                                     "scenario " & name)
        failures.add played.failures
        # Every scenario has frames to fold, at moments of their own.
        check scenarioFrames.len > 0
        check played.moments > 0
        checkpoint name & ": " & $scenarioFrames.len & " frames over " &
          $played.moments & " moments"
      check playbackScenario("front-ends").fleetFramesOf.len == 25
      check playbackScenario("initiative-run").fleetFramesOf.len == 4
      for f in failures: checkpoint f
      check failures.len == 0
      disposeRoot()

  test "the run moves every count and group the list shows":
    # The positive control for the test above: the run starts, asks,
    # answers, fails, ends and removes sessions, so a list that missed any
    # of these would be compared against one that shows it.
    createRoot proc(disposeRoot: proc()) =
      let run = inventedFleetRun()
      let vm = run.loadedAt(run.firstMs)
      let first = vm.counts
      var seen: set[FleetCategory]
      var changed: set[FleetCategory]
      var created, removed = false
      for frame in run.framesOf:
        discard vm.apply(frame)
        for row in vm.rows: seen.incl row.category
        for c in FleetCategory:
          if vm.counts.byCategory[c] != first.byCategory[c]: changed.incl c
        if frame.kind == ffLifecycle:
          created = created or frame.lifecycle.kind == "session_created"
          removed = removed or frame.lifecycle.kind == "session_removed"
      check seen == {fcNeedsInput, fcRunning, fcQueued, fcFailed, fcEnded}
      check changed == {fcNeedsInput, fcRunning, fcQueued, fcFailed, fcEnded}
      check created and removed
      check vm.counts.listed == RunSessions - 1
      check vm.counts.total == RunSessions - 1
      vm.dispose()
      disposeRoot()

  test "a list only ever loaded shows its snapshot exactly":
    createRoot proc(disposeRoot: proc()) =
      let source = newFixtureDataSource()
      let fleet = source.snapshotOf
      let vm = newFleetSnapshotVM(source)
      vm.load()
      check vm.snapshot == fleet
      var byId: Table[string, FleetSession]
      for s in fleet.sessions: byId[s.id] = s
      for row in vm.rows:
        # The digest is the one a row always showed, less the line a failed
        # row's reason already shows (it is shown once, as the failure).
        let failure = byId[row.id].failureOf
        var digest: seq[DigestLine]
        for line in digestActivity(byId[row.id].recent,
                                   currentStatus = byId[row.id].rawStatus):
          if failure.len == 0 or line.text != failure: digest.add line
        check row.activity.len == min(digest.len, FleetActivityLineLimit)
        for i, line in row.activity: check line == digest[i].lineText
        check row.activityMore == digest.len - row.activity.len
      check vm.rows == rowsOf(fleet, ffAll)
      vm.dispose()
      disposeRoot()

  test "only a frame that changes the fleet moves the list":
    createRoot proc(disposeRoot: proc()) =
      let run = inventedFleetRun()
      let vm = run.loadedAt(run.firstMs)
      var rowRuns = 0
      createEffect proc() =
        discard vm.rows
        inc rowRuns
      let id = run.sessions[0].entry.id
      check vm.applyFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_status_changed", sessionId: id, status: "running",
        atMs: RunT0 + 1)) == foUnchanged
      check vm.apply(eventFrame("no-such-session", %*{"type": "log"}, 1)) == foUnknownSession
      check vm.apply(eventFrame(id, nil, 9)) == foMalformed
      check rowRuns == 1
      check vm.applyFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_completed", sessionId: id, status: "completed",
        atMs: RunT0 + 1)) == foApplied
      check rowRuns == 2
      for row in vm.rows:
        if row.id == id: check row.category == fcEnded
      vm.dispose()
      disposeRoot()

  test "a listed stop-hook wait still needs input after the session's events":
    # The listing says the agent's turn ended (a stop-hook wait); the row
    # reads "needs input" until the operator's input reaches the session.
    createRoot proc(disposeRoot: proc()) =
      let run = inventedFleetRun()
      var listed = run.listedAt(run.firstMs)
      let id = listed.sessions[1].id
      listed.sessions[1].awaitingInput = true
      listed.sessions[1].awaitingInputSource = "claude-stop-hook"
      let vm = newFleetSnapshotVM(newSnapshotDataSource(listed, "invented run",
                                                        run.initiatives))
      vm.load()
      proc rowOf(): FleetRow =
        for row in vm.rows:
          if row.id == id: return row
      check rowOf().statusLabel == "needs input"
      let needing = vm.counts.byCategory[fcNeedsInput]
      check vm.apply(eventFrame(id, %*{"type": "log", "level": "info",
        "message": "assistant: still here", "timestamp": 1}, 50)) == foApplied
      check vm.apply(eventFrame(id, %*{"type": "tool_use", "status": "started",
        "tool_name": "runCmd", "tool_args": {"command": "just test"},
        "timestamp": 2}, 51)) == foApplied
      check rowOf().statusLabel == "needs input"
      check rowOf().category == fcNeedsInput
      check vm.counts.byCategory[fcNeedsInput] == needing
      check vm.apply(eventFrame(id, %*{"type": "user_input", "content": "invented",
        "timestamp": 3}, 52)) == foApplied
      check rowOf().statusLabel != "needs input"
      check vm.counts.byCategory[fcNeedsInput] == needing - 1
      vm.dispose()
      disposeRoot()

  test "a removed session is no longer selected or expanded":
    createRoot proc(disposeRoot: proc()) =
      let run = inventedFleetRun()
      let vm = run.loadedAt(run.firstMs)
      let id = run.sessions[RunRemoved].entry.id
      vm.select(id)
      vm.toggleExpanded(id)
      check vm.selectedId.val == id
      check vm.apply(lifecycleFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_removed", sessionId: id, atMs: RunT0 + 1))) == foApplied
      check vm.selectedId.val == ""
      check vm.expandedId.val == ""
      check vm.eventsState.val == asIdle
      for row in vm.rows: check row.id != id
      vm.dispose()
      disposeRoot()

  test "a frame before the first answer is replaced by that answer":
    createRoot proc(disposeRoot: proc()) =
      let pending = newPendingDataSource()
      let vm = newFleetSnapshotVM(pending)
      vm.load()
      check vm.applyFrame(LifecycleFrame(event: "lifecycle",
        kind: "session_created", sessionId: "early", status: "queued",
        atMs: RunT0)) == foApplied
      check vm.counts.listed == 1
      let run = inventedFleetRun()
      pending.pendingFleet[0](success(run.listedAt(run.firstMs)))
      check vm.state.val == asReady
      check vm.counts.listed == RunFirstListed
      for row in vm.rows: check row.id != "early"
      vm.dispose()
      disposeRoot()
