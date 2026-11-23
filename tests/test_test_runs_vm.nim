## The Tests panel's viewmodel (`TestRunsVM`) and the feed it shares with
## other surfaces (`TestRunFeed`): per-platform rows and final statuses as a
## run's events stream, a disabled Record with its reason, an unservable
## platform refused by name, the headline's arms, cancel asking first, the
## open control's modes, the requests a press builds, the keyboard, and the
## folds of the generated fixture set's test runs.
##
## Test doubles, and why each is justified:
##
## - `ScriptedTestRunSource` (through `testRunsFixture`) is the prototypes'
##   production source for test runs: the test-run reads are only proposed
##   and the prototypes may not write to a server, so every story reads and
##   writes through it. Its record is what the write tests read, and its
##   `startScript` and `sendUpdate` are the run's event stream.
## - `NoActions` serves the same reads and leaves `submitAction` to the
##   seam's base: a source with no way to send an action, which must never
##   show a press as sent.
## - `PendingDataSource` and `FailingDataSource` are the seam's state sources.
##
## Expected values are written out by hand from the invented runs
## (`synthetic_test_runs.nim`), never computed through the reducer.

import std/[json, os, strutils, unittest]
import isonim/core/[owner, signals]
import nim_agents/agent_harbor/[test_runs, trace_links]
import nim_agents_isonim_viewmodels

const Dot = " \xC2\xB7 "

type NoActions = ref object of AgentHarborDataSource
  inner: ScriptedTestRunSource

method loadTestPlatforms(source: NoActions; done: TestPlatformsCallback) =
  source.inner.loadTestPlatforms(done)
method loadTestCatalog(source: NoActions; change: string; platform: seq[string];
                       done: TestCatalogCallback) =
  source.inner.loadTestCatalog(change, platform, done)
method loadSessionTestRuns(source: NoActions; sessionId: string;
                           done: SessionTestRunsCallback) =
  source.inner.loadSessionTestRuns(sessionId, done)

let LinuxKey = platformKey(LinuxX86)
let LinuxArmKey = platformKey(LinuxArm)
let MacKey = platformKey(MacArm)
let WindowsKey = platformKey(WindowsX86)
let WindowsArmKey = platformKey(WindowsArm)

proc testsOver(fixture: string): TestRunsVM =
  result = newTestRunsVM(testRunsFixture(fixture), testRunsScope())
  result.load()

proc scripted(vm: TestRunsVM): ScriptedTestRunSource =
  ScriptedTestRunSource(vm.feed.source)

proc cellWords(vm: TestRunsVM; testId: string): seq[string] =
  ## `<platform label> <status word>` for each platform switched on.
  for g in vm.groups:
    for r in g.rows:
      if r.testId == testId:
        for c in r.cells: result.add c.label & " " & c.statusWord

proc rowOf(vm: TestRunsVM; testId: string): TestRowView =
  for g in vm.groups:
    for r in g.rows:
      if r.testId == testId: return r

proc cellOf(vm: TestRunsVM; testId, platform: string): TestCellView =
  for c in vm.rowOf(testId).cells:
    if c.platform == platform: return c

let depth = relayTestId("test_depth_metric_reports_each_queue")
let bound = relayTestId("test_queue_bound_holds")
let window = relayTestId("relay_codec::window::tests::slides")
let roundTrip = relayTestId("relay_codec::frame::tests::round_trip")

suite "the feed: platforms, catalogs and the Verification join":
  test "the catalog's order, by file, never sorted; one cell per platform switched on":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("populated")
      check vm.state == asReady
      check vm.platformKeys == @[LinuxKey, LinuxArmKey, MacKey, WindowsKey]
      var files: seq[string]
      for g in vm.groups: files.add g.file & " " & $g.count
      check files == @["tests/test_queue.py 4", "tests/test_metrics.py 2",
                       "tests/test_flow.py 3", "crates/relay-codec/src/frame.rs 2",
                       "crates/relay-codec/src/window.rs 1"]
      check vm.groups[0].rows[0].name == "test_queue_bound_holds"
      check vm.groups[0].rows[3].name == "test_queue_drains_in_order"
      check vm.cellWords(bound) == @["Linux x86-64 not run", "Linux arm64 not run",
                                     "macOS arm64 not run", "Windows x86-64 not run"]
      # The Windows catalog lacks the window test: not discovered there.
      check vm.runAbsence(window, WindowsKey) == NotDiscoveredText
      check vm.runAbsence(window, LinuxKey) == ""
      vm.setPlatform(MacKey, false)
      check vm.cellWords(bound).len == 3
      check vm.headline == "12 tests, not run yet"
      vm.dispose()
      disposeRoot()

  test "the plan's Verification entries tag their tests; one the catalog lacks is listed with why":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("not-in-catalog")
      check vm.rowOf(bound).milestones == @["RB-M1"]
      check vm.rowOf(depth).milestones == @["RB-M2"]
      check vm.rowOf(roundTrip).milestones.len == 0
      let missing = vm.notInCatalog
      check missing.len == 1
      check missing[0].entry.testName == "test_runbook_links_resolve"
      check missing[0].entry.milestoneId == "RB-M3"
      check missing[0].reason == "No test in the catalog is named test_runbook_links_resolve"
      vm.dispose()
      disposeRoot()

  test "loading, error, empty, no platform, discovering and a failed discovery":
    createRoot proc(disposeRoot: proc()) =
      let loading = testsOver("loading")
      check loading.state == asLoading
      check loading.notice == TestsLoadingNotice
      check loading.headline == ""
      let error = testsOver("error")
      check error.state == asError
      check error.error == TestRunsErrorText
      check error.notice == ""
      let empty = testsOver("empty")
      check empty.notice == TestsEmptyNotice
      check empty.hint == TestsEmptyHint
      check empty.headline == "no tests found"
      let none = testsOver("no-platform")
      check none.notice == NoPlatformNotice
      check none.hint == NoPlatformHint
      check none.runAllAbsence == NoPlatformNotice
      check none.recordAllAbsence == NoPlatformNotice
      check not none.run()
      let discovering = testsOver("discovering")
      check discovering.platformHeads[2].catalogWord == "Discovering tests on macOS arm64\xE2\x80\xA6"
      check discovering.runAbsence(bound, MacKey) == NotDiscoveredText
      check discovering.cellWords(bound).len == 4   # the others still listed
      let failed = testsOver("discovery-failed")
      check failed.platformHeads[3].catalogWord ==
        "Discovery failed on Windows x86-64: pytest could not import tests/conftest.py"
      check failed.testCount == 12
      for vm in [loading, error, empty, none, discovering, failed]: vm.dispose()
      disposeRoot()

  test "the folds of the generated fixture set's test runs":
    # Every run the fixture source serves, as its event stream, through the
    # same reducer the feed folds with: one cell per platform and test, and
    # the counts the run's own totals give.
    let source = newFixtureDataSource()
    var captures: seq[TestRunCapture]
    source.loadTestRuns(proc(answer: DataResult[seq[TestRunCapture]]) =
      doAssert answer.ok, answer.error
      captures = answer.value)
    check captures.len >= 2
    for capture in captures:
      checkpoint capture.name
      let events = parseJson(capture.testRunEventsJson)
      check events.kind == JArray and events.len > 0
      var state = TestRunState(id: events[0]{"testRunId"}.getStr)
      var totals: TestCounts
      var hasTotals = false
      var finishedIds: seq[(string, string)]
      for node in events:
        let e = testRunEventFromJson(node)
        discard state.applyTestRunEvent(e)
        if e.kind == tekRunFinished and e.hasTotals:
          totals = e.totals
          hasTotals = true
        if e.kind == tekTestFinished and (platformKey(e.platform), e.testId) notin finishedIds:
          finishedIds.add (platformKey(e.platform), e.testId)
      var cells = 0
      for run in state.platformRuns:
        for testId in state.order:
          if state.hasCell(platformKey(run.platform), testId): inc cells
      check cells >= finishedIds.len
      let counts = state.countsOf
      check counts.passed + counts.failed + counts.skipped + counts.errored >= finishedIds.len
      if hasTotals and AgentHarborFixtureSet == "synthetic":
        check counts.passed == totals.passed
        check counts.failed == totals.failed
        check counts.skipped == totals.skipped
    if AgentHarborFixtureSet == "synthetic":
      var names: seq[string]
      for c in captures: names.add c.name
      check names == @["units-library-tests", "scheduler-tests"]
      var units = TestRunState(id: "synthetic-units-library-tests")
      for node in parseJson(captures[0].testRunEventsJson):
        discard units.applyTestRunEvent(testRunEventFromJson(node))
      let key = platformKey(["os.linux", "arch.x86_64"])
      check units.order.len == 5
      check units.order[0].endsWith("test_metres_to_feet")
      check units.cell(key, units.order[0]).recording == recRecorded
      check units.cell(key, units.order[2]).status == tsFailed
      check units.cell(key, units.order[4]).status == tsSkipped
      check countsText(units.countsOf) == "3 passed" & Dot & "1 failed" & Dot & "1 skipped"
      var scheduler = TestRunState(id: "synthetic-scheduler-tests")
      for node in parseJson(captures[1].testRunEventsJson):
        discard scheduler.applyTestRunEvent(testRunEventFromJson(node))
      check scheduler.platformRuns.len == 1
      check platformKey(scheduler.platformRuns[0].platform) == MacKey
      check scheduler.countsOf.passed == 3
      check scheduler.cell(key, scheduler.order[0]).status == tsNotRun   # another platform's

suite "per-platform rows and final statuses":
  test "test_test_runs_vm_per_platform_rows_stream_to_their_final_statuses":
    # One test run on two platforms: the two cells move queued, running and
    # end in their own statuses as the events stream, each with its backend.
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("populated")
      let source = vm.scripted
      source.startScript = @[
        runStartedEvent("", LinuxX86, "reprobuild", "pytest"),
        testStartedEvent("", LinuxX86, depth),
        runStartedEvent("", WindowsX86, "reprobuild", "pytest"),
        testFinishedEvent("", LinuxX86, depth, "passed", 30),
        testStartedEvent("", WindowsX86, depth),
        failureEvent("", WindowsX86, depth, "uplink gauge missing", "tests/test_metrics.py", 21),
        testFinishedEvent("", WindowsX86, depth, "failed", 41),
        runFinishedEvent("", LinuxX86),
        runFinishedEvent("", WindowsX86)]
      vm.setPlatform(LinuxArmKey, false)
      vm.setPlatform(MacKey, false)
      check vm.run(RunScope(kind: scTest, testId: depth))
      check source.record == @["start-test-run session=" & TestRunsSessionId &
        " choices=" & depth & " platform=" & LinuxKey & " platform=" & WindowsKey &
        " record=none reuse=certified"]
      check vm.cellWords(depth) == @["Linux x86-64 queued", "Windows x86-64 queued"]
      check vm.headline == RunningHeadline
      var seen: seq[seq[string]]
      while source.playNext():
        let words = vm.cellWords(depth)
        if seen.len == 0 or seen[^1] != words: seen.add words
      check seen == @[
        @["Linux x86-64 queued", "Windows x86-64 queued"],   # run-started: still queued
        @["Linux x86-64 running", "Windows x86-64 queued"],
        @["Linux x86-64 passed", "Windows x86-64 queued"],
        @["Linux x86-64 passed", "Windows x86-64 running"],
        @["Linux x86-64 passed", "Windows x86-64 failed"]]
      check vm.cellOf(depth, LinuxKey).cell.backend == "reprobuild"
      check vm.cellOf(depth, WindowsKey).cell.failure == "uplink gauge missing"
      check vm.cellOf(depth, WindowsKey).durationText == "41 ms"
      check vm.headline == "1 passed" & Dot & "1 failed"
      var heads: seq[string]
      for h in vm.platformHeads:
        if h.enabled: heads.add h.label & ": " & h.runWord
      check heads == @["Linux x86-64: 1 passed", "Windows x86-64: 1 failed"]
      vm.dispose()
      disposeRoot()

  test "every status, the run's diagnostics, and the headline's counts":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("finished")
      vm.setPlatform(LinuxArmKey, false)   # not in the run: not run there
      check vm.headline == "31 passed" & Dot & "2 failed" & Dot & "1 errored" & Dot & "1 skipped"
      check vm.cellWords(depth) == @["Linux x86-64 failed", "macOS arm64 passed",
                                     "Windows x86-64 failed"]
      check vm.cellWords(window) == @["Linux x86-64 errored", "macOS arm64 passed",
                                      "Windows x86-64 not run"]
      check vm.rowOf(depth).statusWord == "failed"
      check vm.rowOf(window).statusWord == "errored"
      let failed = vm.cellOf(depth, LinuxKey).cell
      check failed.location.file == "tests/test_metrics.py" and failed.location.line == 21
      check failed.output.len == 2 and failed.output[1].stream == "stderr"
      let heads = vm.platformHeads
      check heads[3].diagnostics.len == 1
      check heads[3].diagnostics[0].level == "warning"
      check vm.cellOf(window, LinuxKey).cell.diagnostics[0].level == "error"
      check heads[0].runWord == "9 passed" & Dot & "1 failed" & Dot & "1 errored" & Dot & "1 skipped"
      check heads[0].backend == "reprobuild" and heads[2].backend == "ah-executors"
      vm.dispose()
      disposeRoot()

  test "one test, two platforms, two results":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("split")
      let shed = relayTestId("test_oldest_frame_is_shed")
      check vm.cellWords(shed) == @["Linux x86-64 passed", "Linux arm64 not run",
                                    "macOS arm64 not run", "Windows x86-64 failed"]
      check vm.cellOf(shed, LinuxKey).cell.backend == "ah-executors"
      check vm.cellOf(shed, WindowsKey).cell.backend == "reprobuild"
      vm.dispose()
      disposeRoot()

  test "a reused result is passed, with its certificate and no duration":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("reused")
      check vm.headline == "12 passed (3 reused)"
      let c = vm.cellOf(bound, LinuxKey)
      check c.cell.reused
      check c.durationText == ""
      check c.reusedTitle == "Reused: a test certificate (cert:relay/1@e4f5a6b) shows it " &
        "passed at this tree, so it was not run"
      check vm.cellOf(roundTrip, LinuxKey).durationText.len > 0
      vm.dispose()
      disposeRoot()

  test "a run with no test reported says no tests ran":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedTestRunSource(testRunsFixture("populated"))
      var run = newTestRunState("run-9", @[LinuxX86], @["reprobuild"])
      run.foldEvents([runStartedEvent("run-9", LinuxX86, "reprobuild", "pytest"),
                      diagnosticEvent("run-9", LinuxX86, "error", "the executor lost its workspace"),
                      runFinishedEvent("run-9", LinuxX86, cancelled = true)])
      source.runs = @[run]
      let vm = newTestRunsVM(source, testRunsScope())
      vm.load()
      check vm.headline == NoTestsRanHeadline
      check vm.platformHeads[0].runWord == "cancelled"
      vm.dispose()
      disposeRoot()

suite "a disabled Record, and an unservable platform":
  test "test_test_runs_vm_record_disabled_with_the_reason":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("record-disabled")
      check not vm.canRecord(bound, WindowsKey)
      check vm.recordAbsence(bound, WindowsKey) == WindowsRecordReason
      check vm.cellOf(bound, WindowsKey).recordAbsence == WindowsRecordReason
      check vm.canRecord(bound, MacKey)                 # pytest records on macOS
      check vm.recordAbsence(roundTrip, MacKey) == MacCargoReason   # cargo does not
      check vm.canRecord(roundTrip, LinuxKey)
      check vm.canRun(bound, WindowsKey)                # Run stays available
      check vm.platformHeads[3].recordReason == WindowsRecordReason
      check vm.platformHeads[0].recordReason == ""
      check vm.recordSkipped == @[("Windows x86-64", WindowsRecordReason)]
      # The cell's Record sends nothing; the header's skips Windows.
      check not vm.record(RunScope(kind: scCell, testId: bound, platform: WindowsKey))
      check vm.scripted.record.len == 0
      check vm.record()
      check vm.scripted.record.len == 1
      check ("platform=" & WindowsKey) notin vm.scripted.record[0]
      check "record=failing" in vm.scripted.record[0]
      check "reuse=never" in vm.scripted.record[0]
      # The open control with no recorder: record-and-open, disabled.
      let mode = vm.openMode(bound, WindowsKey)
      check mode.kind == omRecordAndOpen
      check mode.absence == WindowsRecordReason
      check not vm.open(bound, WindowsKey)
      vm.dispose()
      disposeRoot()

  test "an unservable platform is refused by name; the others run":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("unservable")
      check vm.platformKeys[^1] == WindowsArmKey
      check vm.runAbsence(bound, WindowsArmKey) ==
        "No backend serves arch.aarch64 os.windows"
      for key in [LinuxArmKey, MacKey, WindowsKey]: vm.setPlatform(key, false)
      check vm.run(RunScope(kind: scTest, testId: bound))
      check vm.refusal.val == "Not started on Windows arm64: No backend serves arch.aarch64 os.windows"
      check vm.feed.runs.len == 1
      check vm.cellWords(bound) == @["Linux x86-64 queued", "Windows arm64 not run"]
      # Only the unservable platform: refused as a whole.
      vm.setPlatform(LinuxKey, false)
      check vm.run(RunScope(kind: scTest, testId: bound))
      check vm.refusal.val == "Not started: No backend serves arch.aarch64 os.windows"
      check vm.feed.runs.len == 1
      vm.dispose()
      disposeRoot()

  test "a start refused before it starts says why and queues nothing":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("refused-unpushed")
      check vm.run()
      check vm.refusal.val == NotStartedPrefix & UnpushedReason
      check vm.feed.runs.len == 1
      check not vm.feed.latestRun.isActive
      vm.dispose()
      disposeRoot()

suite "a run in progress, and cancelling it":
  test "a platform with an active run offers no Run, and the others' cells stay pressable":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("running")
      check vm.headline == RunningHeadline
      check vm.runAbsence(bound, LinuxKey) == RunInProgressOnPlatformText
      check vm.runAbsence(bound, MacKey) == RunInProgressOnPlatformText   # queued is active
      check vm.runAbsence(bound, LinuxArmKey) == ""
      let heads = vm.platformHeads
      check heads[0].runWord == "running on reprobuild (pytest)"
      check heads[2].runWord == "queued on ah-executors"
      check vm.cellWords(relayTests()[4].id)[0] == "Linux x86-64 running"
      check vm.cellWords(relayTests()[5].id)[0] == "Linux x86-64 queued"
      vm.dispose()
      disposeRoot()

  test "test_test_runs_vm_cancel_asks_first_and_keeps_finished_cells":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("cancel")
      check vm.canCancel
      vm.cancel()
      check vm.confirming.val
      check vm.cancelQuestion == "Cancel the run on 3 platforms?"
      check vm.scripted.record.len == 0
      vm.keepRunning()
      check not vm.confirming.val
      check not vm.confirmCancel()
      check vm.scripted.record.len == 0
      vm.cancel()
      check vm.confirmCancel()
      check vm.scripted.record == @["cancel-test-run session=" & TestRunsSessionId &
                                    " test-run=run-2"]
      let tests = relayTests()
      check vm.cellWords(tests[0].id)[0] == "Linux x86-64 passed"
      check vm.cellWords(tests[2].id)[0] == "Linux x86-64 failed"
      check vm.cellWords(tests[4].id)[0] == "Linux x86-64 cancelled"
      check vm.cellWords(tests[4].id)[2] == "macOS arm64 cancelled"
      check not vm.canCancel
      check vm.headline == "3 passed" & Dot & "1 failed" & Dot & "32 cancelled"
      vm.dispose()
      disposeRoot()

  test "with nothing active, Cancel is disabled and sends nothing":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("finished")
      check not vm.canCancel
      check vm.cancelAbsence == "No run is in progress"
      vm.cancel()
      check not vm.confirming.val
      check not vm.confirmCancel()
      check vm.scripted.record.len == 0
      vm.dispose()
      disposeRoot()

  test "a lost stream says so, and a resumed one stops saying it":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("stream-lost")
      let source = vm.scripted
      check vm.streamNotice == ""
      discard source.sendUpdate(TestRunUpdate(kind: truLost, testRunId: "run-2",
                                              reason: "the connection reset"))
      check vm.streamNotice == StreamLostPrefix
      check vm.feed.lostReason == "the connection reset"
      check vm.cellWords(relayTests()[0].id)[0] == "Linux x86-64 passed"   # rows as last known
      discard source.sendUpdate(TestRunUpdate(kind: truResumed, testRunId: "run-2"))
      check vm.streamNotice == ""
      discard source.sendEvent(testFinishedEvent("run-2", LinuxX86, relayTests()[4].id, "passed", 9))
      check vm.cellWords(relayTests()[4].id)[0] == "Linux x86-64 passed"
      vm.dispose()
      disposeRoot()

suite "the open control and the requests a press builds":
  test "test_test_runs_vm_open_existing_runs_nothing":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("recorded")
      let mode = vm.openMode(depth, LinuxKey)
      check mode.kind == omOpenExisting and mode.absence == ""
      check vm.open(depth, LinuxKey)
      check vm.scripted.record.len == 0
      check vm.traceRequests.val == 1
      let request = vm.requestedTrace.val
      check request.reference.kind == trkAgentHarbor
      check request.reference.id == OneTraceId
      check request.testId == depth and request.platform == LinuxKey
      check request.destination == tdNewTab
      check vm.openTitle(depth, LinuxKey) ==
        "Open the recorded trace. Opens in a new tab; Ctrl+click opens it in this tab."
      # Redirected (Ctrl): this tab.
      check vm.open(depth, LinuxKey, redirected = true)
      check vm.requestedTrace.val.destination == tdCurrentTab
      vm.dispose()
      disposeRoot()

  test "a recording that was not kept says so and offers no open of a trace":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("recorded")
      let c = vm.cellOf(bound, LinuxKey)
      check c.cell.status == tsPassed
      check c.recordingWord == RecordingDiscardedText
      check c.open.kind == omRecordAndOpen
      vm.dispose()
      disposeRoot()

  test "Shift records again and opens the new trace once it is created":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("recorded")
      let source = vm.scripted
      source.startScript = @[
        runStartedEvent("", LinuxX86, "reprobuild", "pytest"),
        testStartedEvent("", LinuxX86, depth),
        testFinishedEvent("", LinuxX86, depth, "failed", 20),
        traceStartedEvent("", LinuxX86, depth, "ct-pytest"),
        traceCreatedEvent("", LinuxX86, depth, SecondTraceId),
        runFinishedEvent("", LinuxX86)]
      vm.shiftHeld.val = true
      check vm.openMode(depth, LinuxKey).kind == omRefreshAndOpen
      check vm.openTitle(depth, LinuxKey).startsWith("Record again, then open the new trace. ")
      check vm.open(depth, LinuxKey)
      check source.record.len == 1
      check "choices=" & depth in source.record[0]
      check "platform=" & LinuxKey in source.record[0]
      check "record=all" in source.record[0] and "reuse=never" in source.record[0]
      check vm.traceRequests.val == 0
      check vm.waitingToOpen == 1
      check source.playNext() and source.playNext() and source.playNext() and source.playNext()
      check vm.traceRequests.val == 0
      check source.playNext()   # trace-created
      check vm.traceRequests.val == 1
      check vm.requestedTrace.val.reference.id == SecondTraceId
      check vm.waitingToOpen == 0
      source.playAll()
      check vm.traceRequests.val == 1
      vm.dispose()
      disposeRoot()

  test "a recorded cell can be opened while another platform runs, and a running cell cannot record":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("recording")
      let rec = vm.openMode(depth, LinuxKey)
      check rec.kind == omRecordAndOpen
      check rec.absence == RunInProgressOnPlatformText
      check vm.cellOf(depth, LinuxKey).recordingWord == RecordingWord
      check vm.openMode(depth, MacKey).kind == omRecordAndOpen
      check vm.openMode(depth, MacKey).absence == ""
      vm.dispose()
      disposeRoot()

  test "Run, Record and the header's Record build their requests":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("populated")
      let source = vm.scripted
      source.script.setRule(oaStartTestRun, neverAnswered())
      check vm.run(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      check source.record[^1] == "start-test-run session=" & TestRunsSessionId &
        " choices=" & bound & " platform=" & LinuxKey & " record=none reuse=certified"
      vm.setReuse(false)
      check vm.run(RunScope(kind: scCell, testId: bound, platform: MacKey))
      check "record=none" in source.record[^1] and "reuse=never" in source.record[^1]
      check vm.record(RunScope(kind: scCell, testId: depth, platform: LinuxArmKey))
      check "record=all" in source.record[^1] and "reuse=never" in source.record[^1]
      vm.setRecordMode(rmAll)
      check vm.record()
      check "record=all" in source.record[^1]
      check source.record.len == 4
      vm.dispose()
      disposeRoot()

  test "a start still sending disables every cell it covers, on every surface over the same feed":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedTestRunSource(testRunsFixture("populated"))
      source.script.setRule(oaStartTestRun, neverAnswered())
      let tracker = newActionTracker()
      let feed = newTestRunFeed(source, testRunsScope(), tracker)
      let a = newTestRunsVM(source, testRunsScope(), tracker = tracker, feed = feed)
      let b = newTestRunsVM(source, testRunsScope(), tracker = tracker, feed = feed)
      a.load()
      check a.run(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      check b.runAbsence(bound, LinuxKey) == SendingText
      # Record waits behind the Run, and says so: never a silently inert button.
      check b.recordAbsence(bound, LinuxKey) == RecordWaitsForRunText
      check b.feed.recordWaiting(bound, LinuxKey)
      check b.cellOf(bound, LinuxKey).recordWaiting
      check b.cellOf(bound, LinuxKey).recordAbsence == RecordWaitsForRunText
      check not b.cellOf(bound, MacKey).recordWaiting
      # The open control's recording modes are Records: they wait too.
      check b.openMode(bound, LinuxKey).absence == RecordWaitsForRunText
      check b.runAbsence(bound, MacKey) == ""
      check b.runAbsence(depth, LinuxKey) == ""
      # The same request again sends nothing.
      check not b.run(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      check source.record.len == 1
      # Answered: no longer sending.
      source.script.settle(0, ok = false, reason = "refused")
      check b.runAbsence(bound, LinuxKey) == ""
      check a.refusal.val == NotStartedPrefix & "refused"
      a.dispose()
      b.dispose()
      disposeRoot()

  test "a press on a source without actions shows failed, never sent":
    createRoot proc(disposeRoot: proc()) =
      let inner = ScriptedTestRunSource(testRunsFixture("populated"))
      let source = NoActions(label: "reads only", inner: inner)
      let vm = newTestRunsVM(source, testRunsScope())
      vm.load()
      check vm.state == asReady
      check vm.run(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      check vm.refusal.val == NotStartedPrefix &
        "the data source 'reads only' does not provide operator actions"
      check vm.feed.runs.len == 0
      check vm.tracker.statusOf(vm.feed.runRequest([bound], [LinuxKey]).targetOf) == astFailed
      check inner.record.len == 0
      vm.dispose()
      disposeRoot()

suite "Record behind Run, and a run that ends before reaching a test":
  test "a Record pressed while its Run is being sent waits, says so, and sends nothing":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedTestRunSource(testRunsFixture("populated"))
      source.script.setRule(oaStartTestRun, neverAnswered())
      let vm = newTestRunsVM(source, testRunsScope())
      vm.load()
      check vm.run(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      let cell = vm.cellOf(bound, LinuxKey)
      check cell.recordWaiting
      check cell.recordAbsence == RecordWaitsForRunText
      check RecordWaitsForRunText.len > 0
      check not vm.canRecord(bound, LinuxKey)
      check not vm.record(RunScope(kind: scCell, testId: bound, platform: LinuxKey))
      check source.record.len == 1
      # A Record being sent is not a Run: the Run's cell is only sending.
      check vm.record(RunScope(kind: scCell, testId: depth, platform: MacKey))
      check vm.cellOf(depth, MacKey).recordAbsence == SendingText
      check not vm.cellOf(depth, MacKey).recordWaiting
      # The header: its Run being sent, the same Run says it is sending and
      # the header's Record (the same tests on the same platforms) waits
      # behind it, with words; neither sends anything.
      vm.setPlatform(LinuxArmKey, false)
      vm.setPlatform(WindowsKey, false)
      check vm.runAllAbsence == ""
      check vm.recordAllAbsence == ""
      check vm.run()
      check source.record.len == 3
      check vm.runAllAbsence == SendingText
      check vm.recordAllAbsence == RecordWaitsForRunText
      check not vm.run()
      check not vm.record()
      check source.record.len == 3
      vm.dispose()
      disposeRoot()

  test "an ended run's unreached tests read not run, with why; a cancelled one's cancelled":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("populated")
      let source = vm.scripted
      source.startScript = @[
        runStartedEvent("", LinuxX86, "reprobuild", "pytest"),
        testFinishedEvent("", LinuxX86, depth, "passed", 30),
        runFinishedEvent("", LinuxX86),
        runStartedEvent("", MacArm, "ah-executors", "pytest"),
        runFinishedEvent("", MacArm, cancelled = true)]
      source.playOnStart = true
      vm.setPlatform(LinuxArmKey, false)
      vm.setPlatform(WindowsKey, false)
      check vm.run()
      check not vm.feed.latestRun.isActive
      # The test Linux reached keeps its result; the ones it never reached
      # are not run, and say why. Never left queued.
      check vm.cellOf(depth, LinuxKey).statusWord == "passed"
      check vm.cellOf(depth, LinuxKey).statusTitle == ""
      check vm.cellOf(bound, LinuxKey).statusWord == "not run"
      check vm.cellOf(bound, LinuxKey).cell.unreached
      check vm.cellOf(bound, LinuxKey).statusTitle == UnreachedText
      # The cancelled platform keeps its own word.
      check vm.cellOf(bound, MacKey).statusWord == "cancelled"
      check vm.cellOf(bound, MacKey).statusTitle == ""
      for g in vm.groups:
        for r in g.rows:
          for c in r.cells: check c.statusWord != "queued"
      check vm.headline.startsWith("1 passed")
      check vm.runAbsence(bound, LinuxKey) == ""
      vm.dispose()
      disposeRoot()

suite "the reader's state and the keyboard":
  test "filter, query and the empty match":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("filtered")
      vm.setFilter(tfFailing)
      var names: seq[string]
      for g in vm.groups:
        for r in g.rows: names.add r.name
      check names == @["test_depth_metric_reports_each_queue", "slides"]
      vm.setFilter(tfAll)
      vm.setQuery("METRIC")
      check vm.groups.len == 1 and vm.groups[0].count == 2
      vm.setQuery("no such test")
      check vm.notice == NoMatchNotice
      vm.setQuery("")
      vm.setFilter(tfNotRun)
      check vm.groups.len == 0   # every test ran somewhere switched on
      vm.dispose()
      disposeRoot()

  test "the keyboard moves over drawn rows and cells; Enter, r and R act on them":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("populated")
      vm.scripted.script.setRule(oaStartTestRun, neverAnswered())
      vm.toggleGroup("tests/test_queue.py")
      check vm.focusables.len == 8
      vm.focusNext()
      check vm.focusRow.val == depth
      vm.focusPrevious()
      check vm.focusRow.val == depth
      vm.toggleFocused()
      check vm.rowOf(depth).open
      vm.stepCell(1)
      check vm.focusedCell == LinuxKey
      vm.stepCell(10)
      check vm.focusedCell == WindowsKey
      vm.stepCell(-10)
      check vm.focusedCell == ""
      vm.stepCell(1)
      check vm.runFocused()
      check "choices=" & depth in vm.scripted.record[^1]
      check "platform=" & LinuxKey in vm.scripted.record[^1]
      vm.stepCell(-1)
      check vm.recordFocused()
      check "record=all" in vm.scripted.record[^1]
      # Windows cannot record, and Linux is still sending the Run above.
      check vm.scripted.record[^1].count("platform=") == 2
      check ("platform=" & LinuxKey) notin vm.scripted.record[^1]
      check ("platform=" & WindowsKey) notin vm.scripted.record[^1]
      vm.dispose()
      disposeRoot()

  test "a selected test is the keyboard's row, and its folded group opens":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("selected")
      vm.toggleGroup("tests/test_flow.py")
      check vm.groups[2].folded
      let slow = relayTestId("test_slow_station_is_told_to_slow_down")
      vm.select(slow)
      check not vm.groups[2].folded
      check vm.rowOf(slow).selected and vm.rowOf(slow).focused
      vm.openLocation(depth)
      check vm.requestedFile.val == "tests/test_metrics.py:21"
      check vm.fileRequests.val == 1
      vm.dispose()
      disposeRoot()

  test "a restart loads again and keeps what the reader set":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("finished")
      vm.setPlatform(MacKey, false)
      vm.toggleRow(depth)
      vm.setFilter(tfFailing)
      vm.restart()
      check vm.state == asReady
      check not vm.isEnabled(MacKey)
      check vm.rowOf(depth).open
      check vm.filter.val == tfFailing
      vm.dispose()
      disposeRoot()

  test "a long catalog lists every test, grouped, and folds":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("long")
      check vm.testCount == 320
      check vm.groups.len == 40
      vm.toggleGroup(vm.groups[0].file)
      check vm.focusables.len == 312
      vm.dispose()
      disposeRoot()

  test "the legend names every status, chip and backend":
    createRoot proc(disposeRoot: proc()) =
      let vm = testsOver("platforms")
      var terms: seq[string]
      for e in vm.legend: terms.add e.term
      for t in ["not run", "queued", "running", "passed", "failed", "skipped", "errored",
                "cancelled", "reused", NotDiscoveredText, "reprobuild", "ah-executors"]:
        check t in terms
      for e in vm.legend: check e.meaning.len > 0
      vm.dispose()
      disposeRoot()

suite "no transport":
  test "the test-run and trace modules import no transport":
    const dir = currentSourcePath().parentDir.parentDir /
      "src/nim_agents_isonim_viewmodels/agent_harbor"
    const modules = block:
      var found: seq[(string, string)]
      for name in ["test_run_feed.nim", "test_runs_vm.nim", "trace_opener_vm.nim",
                   "trace_placement.nim", "synthetic_test_runs.nim", "scripted_actions.nim"]:
        found.add (name, staticRead(dir / name))
      found
    const Transports = ["httpclient", "asynchttpserver", "asyncnet", "net",
                        "nativesockets", "nim_agent_harbor", "websocket", "jsfetch"]
    proc imports(text: string): seq[string] =
      for line in text.splitLines:
        let l = line.strip
        if l.startsWith("import ") or l.startsWith("from "):
          for w in l.split({' ', ',', '/', '[', ']', '.'}):
            if w in Transports: result.add l
    check imports("import std/[json, httpclient]").len == 1   # the scan sees one
    for (name, text) in modules:
      checkpoint name
      check text.len > 0
      check imports(text).len == 0
