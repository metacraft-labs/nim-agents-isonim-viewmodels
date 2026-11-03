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
## real source does on demand.
##
## Assertions about the fixture's contents are made against the fixture's own
## JSON, decoded independently with std/json, so a refreshed capture does not
## break them and an emptied one does.

import std/[json, os, sets, strutils, unittest]
import isonim/core/[computation, owner, signals]
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
    session.failureReason = "[exit] status=1"
    check session.failureOf == "[exit] status=1"
    check failureReasonOf([FleetActivity(kind: fakStatus, text: "Status: failed"),
                           FleetActivity(kind: fakLog, level: "info", text: "[exit] status=143"),
                           FleetActivity(kind: fakLog, level: "info", text: "older")]) ==
      "[exit] status=143"
    session = FleetSession(status: fsCompleted, recent: @[
      FleetActivity(kind: fakLog, level: "error", text: "late error")])
    check session.failureOf == ""

  test "repeated activity lines collapse into one, counted":
    let a = FleetActivity(text: "Resumed by human", level: "")
    let b = FleetActivity(text: "Waiting for input", level: "")
    let (texts, levels) = activityLines([b, a, a, a, b])
    check texts == @["Waiting for input", "Resumed by human \xC3\x973", "Waiting for input"]
    check levels.len == 3
    let (newest, _) = activityLines([a, b, a, b, a], limit = 2)
    check newest == @["Waiting for input", "Resumed by human"]

  test "a withheld prompt falls back to what a person calls the session":
    var session = FleetSession(id: "0123456789abcdef", promptWithheld: true,
                               withheld: @["prompt"])
    check session.titleOf == ("Session 01234567", "id")
    session.workspaceName = "orbit-ws-2"
    check session.titleOf == ("orbit-ws-2", "workspace")
    session.branch = "fix/step-count"
    check session.titleOf == ("fix/step-count", "branch")
    session.applyLabel(SessionLabel(name: "propagator", workspaceName: "ignored",
                                    initiative: "Retries", source: "a window"))
    check session.titleOf == ("propagator", "name")
    check session.workspaceName == "orbit-ws-2" # the listing's value wins
    check session.initiative == "Retries"
    session.prompt = "Fix the step counter\nand its tests"
    check session.titleOf == ("Fix the step counter", "prompt")
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
          check session.titleOf.source == "name"
    check named > 0

  test "failed sessions with a captured history carry its reason":
    let source = newFixtureDataSource()
    var withHistory, withReason = 0
    for session in source.snapshotOf.sessions:
      if session.category == fcFailed and
          source.manifest{"fleet", "events"}.hasKey(session.id):
        inc withHistory
        if session.failureOf.len > 0: inc withReason
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
