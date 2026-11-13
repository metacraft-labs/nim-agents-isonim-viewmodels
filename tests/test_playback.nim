## The playback data source (`playback_source.nim`), the two synthetic
## playback scenarios it replays (`playback_scenarios.nim`, in the format of
## `playback_scenario.nim`), and the seam's subscriptions the viewmodels
## follow it through (fleet frames, resumes, recordings, progress, resets).
##
## Test doubles, and why each is justified:
##
## - The clock is IsoNim's `TestClock`, the production implementation of the
##   clock interface for tests: time moves only when the test advances it,
##   which is what makes "deliver exactly what is due at this moment"
##   checkable at all. No wall time is read.
## - `Recorder` is a subscriber, not a stand-in for a component: it
##   subscribes to every kind the source sends and writes down each delivery,
##   so the order and multiplicity of deliveries can be compared with the
##   scenario's own entries.
## - `LoadsOnlySource` is a `SnapshotDataSource` that leaves every new
##   `subscribe…` method to the base: a server that answers loads and has no
##   streams, which is the case the base methods' "does not provide" answer
##   exists for and which no production source in this repo is any more.
##
## Everything else is production code: the playback source, the scenarios
## and the viewmodels over them. The expected viewmodel states at each named
## moment are written out by hand below, from the scenarios' documented
## timelines, never computed through the reducers or the source. The other
## oracle is a second playback, built fresh and stepped to the same moment:
## seeking (forwards, or backwards through a rebuild) must give exactly what
## stepping gives. Because that second playback runs the same source and
## reducers, the hand-written values are also checked after seeking back to
## each named moment, so a defect the two playbacks share cannot pass.

import std/[json, strutils, unittest]
import isonim/core/[owner, signals, clock]
import nim_agents_isonim_viewmodels

const Dot = " \xC2\xB7 "

# ---------------------------------------------------------------------------
# What the scenarios hold, read straight from their entries
# ---------------------------------------------------------------------------

proc subjectOf(entry: ScenarioEntry): string =
  ## What an entry is about, read from its own fields.
  case entry.kind
  of sekLifecycle: "frame " & entry.lifecycle.sessionId
  of sekListing: "frame " & entry.listing.id
  of sekEvent: "frame " & entry.sessionId
  of sekResume: "resume " & entry.resume.sessionId
  of sekProgress: "progress " & entry.progress.milestoneId & "=" & entry.progress.status
  of sekRecording: "recording " & entry.recording.entry.id & "=" &
    $entry.recording.entry.state

proc expectedLog(scenario: PlaybackScenario; upTo: int64): seq[string] =
  ## The deliveries a playback that reached `upTo` has made, in order.
  for entry in scenario.entries:
    if entry.atMs <= upTo: result.add $entry.atMs & " " & entry.subjectOf

proc nextDeliveredMs(source: PlaybackDataSource): int64 =
  ## The moment of the entry being delivered (the last counted one).
  if source.position == 0: source.scenario.firstMs
  else: source.scenario.entries[source.position - 1].atMs

# ---------------------------------------------------------------------------
# A subscriber that writes down what it receives
# ---------------------------------------------------------------------------

type
  Recorder = ref object
    source: PlaybackDataSource
    log: seq[string]
    resets: int
    frames: Subscription[FleetFrame]
    resumes: Subscription[ResumeEvent]
    progress: ProgressSubscription
    recordings: Subscription[RecordingEvent]
    resetFeed: Subscription[StreamReset]

proc record(source: PlaybackDataSource): Recorder =
  ## Subscribes to every kind `source` sends. Each delivery is written down
  ## stamped with the head's moment at delivery.
  let r = Recorder(source: source)
  r.frames = source.subscribeFleetFrames proc(a: DataResult[FleetFrame]): ProgressDelivery =
    let f = a.value
    let id = case f.kind
      of ffLifecycle: f.lifecycle.sessionId
      of ffSession: f.session.id
      of ffEvent: f.sessionId
    r.log.add $f.atMs & " frame " & id
    pdApplied
  r.resumes = source.subscribeResumes proc(a: DataResult[ResumeEvent]): ProgressDelivery =
    r.log.add $a.value.atMs & " resume " & a.value.sessionId
    pdApplied
  r.progress = source.subscribeProgress proc(a: DataResult[ProgressEvent]): ProgressDelivery =
    r.log.add $r.source.nextDeliveredMs & " progress " & a.value.milestoneId & "=" & a.value.status
    pdApplied
  r.recordings = source.subscribeRecordings proc(a: DataResult[RecordingEvent]): ProgressDelivery =
    r.log.add $r.source.nextDeliveredMs & " recording " & a.value.entry.id & "=" &
      $a.value.entry.state
    pdApplied
  r.resetFeed = source.subscribeResets proc(a: DataResult[StreamReset]): ProgressDelivery =
    inc r.resets
    r.log.setLen 0
    pdApplied
  r

# ---------------------------------------------------------------------------
# Every viewmodel over one source, and what they show
# ---------------------------------------------------------------------------

type Views = object
  fleet: FleetSnapshotVM
  tabs: SessionTabStripVM
  list: SessionTabStripVM
  bar: InitiativeTabStripVM
  initiatives: InitiativesVM
  progress: InitiativeProgressVM
  initiativeId: string

proc viewsOver(source: AgentHarborDataSource; initiativeId: string;
               autoSwitch = false): Views =
  ## The viewmodels of every playback story, loaded over `source`: the fleet
  ## list, the tab strip, the sidebar list, the initiative tab bar, the
  ## Initiatives panel and the Initiative Progress panel showing
  ## `initiativeId`. Call inside a reactive root.
  result.initiativeId = initiativeId
  result.fleet = newFleetSnapshotVM(source)
  result.tabs = newSessionTabStripVM(source)
  result.list = newSessionTabStripVM(source, tsmSidebar)
  result.bar = newInitiativeTabStripVM(source)
  result.bar.autoSwitch.val = autoSwitch
  result.initiatives = newInitiativesVM(source)
  result.progress = newInitiativeProgressVM(source, initiativeId)
  result.fleet.load()
  result.tabs.load()
  result.list.load()
  result.bar.load()
  result.initiatives.load()
  result.progress.load()

proc dispose(views: Views) =
  views.fleet.dispose()
  views.tabs.dispose()
  views.list.dispose()
  views.bar.dispose()
  views.initiatives.dispose()
  views.progress.dispose()

proc shown(views: Views): seq[string] =
  ## Everything the viewmodels publish to a view, one line per surface: the
  ## state two playbacks at the same moment must agree on exactly.
  result.add "fleet " & $views.fleet.rows & " " & $views.fleet.counts & " " &
    views.fleet.capturedAgeLabel
  result.add "tabs " & $views.tabs.tabs & " " & views.tabs.summaryText
  result.add "list " & $views.list.groups
  result.add "bar " & $views.bar.tabs & " " & views.bar.activeTab.val & " " &
    views.bar.inboxPosition & " " & $views.bar.elsewhere & " " &
    $views.bar.recordingButtonsOf(views.initiativeId) & " " &
    $views.bar.popupOf(views.initiativeId)
  result.add "initiatives " & $views.initiatives.rows & " " & views.initiatives.summaryText
  result.add "progress " & views.progress.headline & " " & $views.progress.groups

proc agree(a, b: Views; label: string): bool =
  ## Whether two sets of viewmodels show the same; the first difference is
  ## reported under `label`.
  let x = a.shown
  let y = b.shown
  for i in 0 ..< x.len:
    if x[i] != y[i]:
      checkpoint label & ": " & x[i] & "\n  !=\n" & y[i]
      return false
  true

proc stepTo(source: PlaybackDataSource; atMs: int64) =
  ## Steps the source entry by entry until its head reaches `atMs`.
  while not source.finished and source.nextMs <= atMs:
    doAssert source.step()

proc newPlayback(name: string): PlaybackDataSource =
  newPlaybackDataSource(playbackScenario(name), newTestClock(0))

proc firstInitiative(name: string): string =
  playbackScenario(name).initiatives[0].id

proc testClock(source: PlaybackDataSource): TestClock = TestClock(source.clock)

# ---------------------------------------------------------------------------
# The scenarios
# ---------------------------------------------------------------------------

proc invariantFailures(scenario: PlaybackScenario): seq[string] =
  ## The scenario's invariants, checked here from its fields (independently
  ## of `problemsOf`): timestamps in order and after the first moment, every
  ## session an entry names introduced before it, named moments unique.
  var known: seq[string]
  for s in scenario.first.sessions: known.add s.id
  var previous = scenario.firstMs
  var moments: seq[string]
  for i, entry in scenario.entries:
    if entry.atMs <= scenario.firstMs or entry.atMs < previous:
      result.add "entry " & $i & " out of order"
    previous = entry.atMs
    if entry.moment.len > 0:
      if entry.moment in moments: result.add "moment " & entry.moment & " repeated"
      moments.add entry.moment
    var id = ""
    case entry.kind
    of sekLifecycle:
      id = entry.lifecycle.sessionId
      if entry.lifecycle.kind == "session_created": known.add id
    of sekListing:
      id = entry.listing.id
      known.add id
    of sekEvent: id = entry.sessionId
    of sekResume: id = entry.resume.sessionId
    else: discard
    if entry.kind in {sekLifecycle, sekListing, sekEvent, sekResume} and id notin known:
      result.add "entry " & $i & " names " & id & " before it is introduced"

suite "the synthetic playback scenarios":
  test "front-ends loads, and holds its invariants":
    let s = frontEndsScenario()
    check s.name == "front-ends"
    check s.invariantFailures.len == 0
    check s.problemsOf.len == 0
    for p in s.problemsOf: checkpoint p
    # What the scenario must show: sessions from several front-ends that
    # start, need input, resume, fail and end, and milestones moving.
    var origins: seq[string]
    for session in s.sessions:
      if session.entry.originFrontEnd notin origins: origins.add session.entry.originFrontEnd
    check origins == @["tui", "cli", "codetracer", "telegram", "webui"]
    var kinds: set[ScenarioEntryKind]
    var lifecycle: seq[string]
    var questions = 0
    for entry in s.entries:
      kinds.incl entry.kind
      if entry.kind == sekLifecycle and entry.lifecycle.kind notin lifecycle:
        lifecycle.add entry.lifecycle.kind
      if entry.kind == sekEvent and entry.event{"type"}.getStr == "agent_question":
        inc questions
    check kinds == {sekLifecycle, sekListing, sekEvent, sekResume, sekProgress}
    check lifecycle.len == 4   # created, status changed, completed, removed
    check questions == 2
    check s.first.sessions.len == 4
    check s.momentNames == @["new-session", "port-asks", "bench-asks",
      "port-answered", "migration-fails", "config-answered", "milestone-done",
      "importer-ends", "port-completes", "importer-removed"]

  test "initiative-run loads, and holds its invariants":
    let s = initiativeRunScenario()
    check s.name == "initiative-run"
    check s.invariantFailures.len == 0
    check s.problemsOf.len == 0
    for p in s.problemsOf: checkpoint p
    var states: seq[string]
    var progress = 0
    for entry in s.entries:
      if entry.kind == sekRecording: states.add $entry.recording.entry.state
      if entry.kind == sekProgress: inc progress
    # Recordings appear loading, and turn ready or fail; one is loaded again.
    check states == @["loading", "ready", "loading", "failed", "loading",
                      "ready", "loading", "ready"]
    check progress == 7
    check s.momentNames.len == 10

  test "a scenario that breaks an invariant is reported":
    # Negative controls for both checks above: each mutation is caught.
    var outOfOrder = frontEndsScenario()
    swap(outOfOrder.entries[2], outOfOrder.entries[8])
    check outOfOrder.invariantFailures.len > 0
    check outOfOrder.problemsOf.len > 0
    var early = frontEndsScenario()
    # The new session's first event, moved before its creation.
    for i, entry in early.entries:
      if entry.kind == sekEvent and entry.sessionId == BenchSessionId:
        let moved = early.entries[i]
        early.entries.delete(i)
        early.entries.insert(moved, 0)
        early.entries[0].atMs = early.firstMs + 1
        break
    check early.invariantFailures.len > 0
    check early.problemsOf.len > 0
    var twice = initiativeRunScenario()
    twice.entries[^1].moment = twice.entries[0].moment
    check twice.invariantFailures.len > 0
    check twice.problemsOf.len > 0
    var unmatched = frontEndsScenario()
    unmatched.entries.add resumeEntry(unmatched.lastMs + 1, BenchSessionId)
    check unmatched.problemsOf.len == 1
    var unknown = initiativeRunScenario()
    unknown.entries.add progressEntry(unknown.lastMs + 1, TelemetryRetry, "TR-M9", "completed")
    check unknown.problemsOf.len == 1

  test "an unknown scenario name is refused":
    expect ValueError: discard playbackScenario("no-such-scenario")
    for name in PlaybackScenarioNames: check playbackScenario(name).name == name

# ---------------------------------------------------------------------------
# The source on its clock
# ---------------------------------------------------------------------------

suite "the playback data source":
  test "test_ctf_p1c_playback_source_replays_on_its_clock":
    for name in PlaybackScenarioNames:
      checkpoint "scenario " & name
      let scenario = playbackScenario(name)
      var times: seq[int64]
      for entry in scenario.entries:
        if times.len == 0 or times[^1] != entry.atMs: times.add entry.atMs

      # -- Stepping delivers each moment's entries, in order, once. ------
      block stepping:
        let source = newPlayback(name)
        let r = record(source)
        check r.log.len == 0 and source.position == 0
        for t in times:
          check source.step()
          check source.currentMs == t
          check r.log == scenario.expectedLog(t)
        check source.finished
        check not source.step()
        check r.log == scenario.expectedLog(scenario.lastMs)

      # -- Playing on the clock: exactly the entries at or before the
      #    clock's moment, in order, once. ------------------------------
      block playing:
        let source = newPlayback(name)
        let clock = source.testClock
        let r = record(source)
        check source.play()
        check not source.play()
        for t in times:
          clock.setTime(float64(t - scenario.firstMs - 1))
          check r.log == scenario.expectedLog(t - 1)
          clock.setTime(float64(t - scenario.firstMs))
          check r.log == scenario.expectedLog(t)
          check source.currentMs == t
        clock.advance(1_000_000)
        check source.finished and not source.playing
        check r.log == scenario.expectedLog(scenario.lastMs)

      # -- Pause holds; play resumes from where it paused. -------------
      block pausing:
        let source = newPlayback(name)
        let clock = source.testClock
        let r = record(source)
        let middle = times[times.len div 2]
        check source.play()
        clock.setTime(float64(middle - scenario.firstMs))
        check source.pause()
        check not source.pause()
        let held = r.log
        check held == scenario.expectedLog(middle)
        clock.advance(10_000_000)   # far past the end of the scenario
        check r.log == held
        check source.currentMs == middle
        check not source.finished
        # Resuming: the paused time does not count; the next entry comes
        # after the time that was left to it, not at once.
        let next = source.nextMs
        check source.play()
        clock.advance(float64(next - middle - 1))
        check r.log == held
        clock.advance(1)
        check r.log == scenario.expectedLog(next)

      # -- Seeking forward equals stepping there. -----------------------
      block seekingForward:
        createRoot proc(disposeRoot: proc()) =
          let initiative = firstInitiative(name)
          for moment in scenario.momentNames:
            let at = scenario.momentMs(moment)
            let sought = newPlayback(name)
            let stepped = newPlayback(name)
            let rs = record(sought)
            let rt = record(stepped)
            let a = viewsOver(sought, initiative)
            let b = viewsOver(stepped, initiative)
            check sought.seekMoment(moment)
            stepped.stepTo(at)
            check sought.currentMoment == moment
            check rs.log == rt.log
            check rs.log == scenario.expectedLog(at)
            check agree(a, b, name & " sought forward to " & moment)
            a.dispose()
            b.dispose()
          disposeRoot()

      # -- Seeking backwards equals a fresh playback stepped there; and
      #    seeking forwards again equals playing straight through. --------
      block seekingBackwards:
        createRoot proc(disposeRoot: proc()) =
          let initiative = firstInitiative(name)
          let source = newPlayback(name)
          let r = record(source)
          let views = viewsOver(source, initiative)
          source.seek(scenario.lastMs)
          var targets = scenario.momentNames
          targets.add ""            # the first moment
          var rebuilds = 0
          for i in countdown(targets.high, 0):
            let moment = targets[i]
            let at = if moment.len == 0: scenario.firstMs else: scenario.momentMs(moment)
            # From the end every time: each seek goes backwards, and
            # rebuilds unless it lands on the last moment itself.
            source.seek(scenario.lastMs)
            if moment.len == 0: source.seek(at) else: check source.seekMoment(moment)
            if at < scenario.lastMs: inc rebuilds
            check source.resets == rebuilds
            check source.currentMs == at
            check r.log == scenario.expectedLog(at)
            let fresh = newPlayback(name)
            let freshViews = viewsOver(fresh, initiative)
            fresh.stepTo(at)
            check agree(views, freshViews, name & " sought back to " &
                        (if moment.len == 0: "the first moment" else: moment))
            # A viewmodel loaded after the seek starts where the others are.
            let late = viewsOver(source, initiative)
            check agree(late, freshViews, name & " loaded late at " & moment)
            late.dispose()
            freshViews.dispose()
          # Forwards again from the first moment, playing to the end.
          let straight = newPlayback(name)
          let straightViews = viewsOver(straight, initiative)
          check straight.play()
          straight.testClock.advance(float64(scenario.lastMs - scenario.firstMs + 1))
          check straight.finished
          check source.play()
          source.testClock.advance(float64(scenario.lastMs - scenario.firstMs + 1))
          check source.finished
          check agree(views, straightViews, name & " played to the end after seeking back")
          check r.log == scenario.expectedLog(scenario.lastMs)
          # Every viewmodel follows the source: none is behind on a feed.
          check views.fleet.feeds.lateEvents == 0
          check views.bar.feeds.lateEvents == 0
          straightViews.dispose()
          views.dispose()
          disposeRoot()

  test "an unknown moment is refused, and the head never goes before the first frame":
    let source = newPlayback("front-ends")
    check not source.seekMoment("no-such-moment")
    check source.position == 0
    source.seek(source.scenario.firstMs - 60_000)
    check source.currentMs == source.scenario.firstMs
    check source.position == 0
    check source.resets == 0
    source.seek(source.scenario.lastMs)
    source.rewind()
    check source.position == 0 and source.resets == 1
    check not source.playing

  test "the loads answer the state at the head":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("front-ends")
      var fleet: FleetSnapshot
      source.loadFleet proc(a: DataResult[FleetSnapshot]) = fleet = a.value
      check fleet.sessions.len == 4
      check fleet.capturedAtMs == PlaybackT0
      var events: SessionEventHistory
      source.loadSessionEvents(PortSessionId,
        proc(a: DataResult[SessionEventHistory]) = events = a.value)
      check events.events.len == 3      # queued, running, the test run
      var missing = true
      source.loadSessionEvents(BenchSessionId,
        proc(a: DataResult[SessionEventHistory]) = missing = not a.ok)
      check missing                     # not started yet
      check source.seekMoment("port-answered")
      source.loadSessionEvents(PortSessionId,
        proc(a: DataResult[SessionEventHistory]) = events = a.value)
      check events.events.len == 5
      check events.events[0].kind == fakUserInput   # newest first
      source.loadFleet proc(a: DataResult[FleetSnapshot]) = fleet = a.value
      check fleet.sessions.len == 5
      var frames: seq[LifecycleFrame]
      source.loadLifecycle proc(a: DataResult[seq[LifecycleFrame]]) = frames = a.value
      check frames.len == 3     # bench created, queued, running
      check source.seekMoment("milestone-done")
      var plans: seq[Initiative]
      source.loadInitiatives proc(a: DataResult[seq[Initiative]]) = plans = a.value
      check plans[0].progress.currentMilestone == "RC-M2"
      check source.seekMoment("importer-removed")
      source.loadSessionEvents(ImporterSessionId,
        proc(a: DataResult[SessionEventHistory]) = missing = not a.ok)
      check missing                     # removed
      disposeRoot()

  test "a late recordings subscriber starts with every recording's state":
    let source = newPlayback("initiative-run")
    check source.seekMoment("second-trace-ready")
    var got: seq[string]
    let sub = source.subscribeRecordings proc(a: DataResult[RecordingEvent]): ProgressDelivery =
      got.add a.value.entry.id & "=" & $a.value.entry.state
      pdApplied
    check got == @["invented-recording-retry-test=ready",
                   "invented-recording-agent-session=failed",
                   "invented-recording-backoff-test=ready"]
    sub.cancel()

# ---------------------------------------------------------------------------
# The viewmodels at each named moment, written out by hand
# ---------------------------------------------------------------------------

type FrontEndsMoment = object
  counts: array[FleetCategory, int]   ## needs input, running, queued, failed, ended
  listed: int
  summary: string                     ## the tab strip's summary
  barState: InitiativeState           ## the route cache's tab
  barProgress: string
  activeTab: string
  inbox: string
  elsewhere: int
  rowState: InitiativeState           ## the Initiatives panel's route-cache row
  rowProgress: string
  rowCurrent: string
  initiativesSummary: string
  headline: string
  groups: seq[string]

proc cats(a: array[5, int]): array[FleetCategory, int] =
  ## Counts per category, in the categories' order.
  for c in FleetCategory: result[c] = a[ord(c)]

proc front(counts: array[5, int]; listed: int; summary: string;
           barState: InitiativeState; barProgress, activeTab, inbox: string;
           elsewhere: int; rowState: InitiativeState;
           rowProgress, rowCurrent, initiativesSummary, headline: string;
           groups: seq[string]): FrontEndsMoment =
  FrontEndsMoment(counts: cats(counts), listed: listed, summary: summary,
    barState: barState, barProgress: barProgress, activeTab: activeTab,
    inbox: inbox, elsewhere: elsewhere, rowState: rowState,
    rowProgress: rowProgress, rowCurrent: rowCurrent,
    initiativesSummary: initiativesSummary, headline: headline, groups: groups)

suite "the viewmodels at each named moment":
  test "front-ends: sessions start, ask, are answered, fail and end":
    # The operator turns auto-switch on and, when the cache port asks, looks
    # at it (`showSession`); everything else is the playback's.
    let route = "initiative:" & RouteCache
    let config = "session:" & ConfigSessionId
    let unattached2 = "1 initiative" & Dot & "2 sessions"
    let early = @["In progress (1)", "Planned (2)", "Completed (1)"]
    let afterDone = @["Planned (2)", "Completed (2)"]
    let afterStart = @["In progress (1)", "Planned (1)", "Completed (2)"]
    let quarter = "1 of 4 milestones" & Dot & "25%"
    let half = "2 of 4 milestones" & Dot & "50%"
    let expected = @[
      ("", front([1, 3, 0, 0, 0], 4, "4 sessions" & Dot & "1 needs input" & Dot & "3 running",
        isWorking, "1/4", route, "1 waiting", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "2 in no initiative", quarter, early)),
      ("new-session", front([1, 3, 1, 0, 0], 5, "5 sessions" & Dot & "1 needs input" & Dot & "3 running",
        isWorking, "1/4", route, "1 waiting", 4, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "2 in no initiative", quarter, early)),
      ("port-asks", front([2, 3, 0, 0, 0], 5, "5 sessions" & Dot & "2 need input" & Dot & "3 running",
        isNeedsInput, "1/4", route, "2 of 2", 4, isNeedsInput, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "1 needs input" & Dot & "2 in no initiative",
        quarter, early)),
      ("bench-asks", front([3, 2, 0, 0, 0], 5, "5 sessions" & Dot & "3 need input" & Dot & "2 running",
        isNeedsInput, "1/4", route, "2 of 3", 4, isNeedsInput, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "1 needs input" & Dot & "2 in no initiative",
        quarter, early)),
      # Answered: auto-switch hands the view to the longest-waiting session.
      ("port-answered", front([2, 3, 0, 0, 0], 5, "5 sessions" & Dot & "2 need input" & Dot & "3 running",
        isNeedsInput, "1/4", config, "1 of 2", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "2 in no initiative", quarter, early)),
      ("migration-fails", front([1, 3, 0, 1, 0], 5,
        "5 sessions" & Dot & "1 needs input" & Dot & "3 running" & Dot & "1 failed",
        isWorking, "1/4", config, "1 of 1", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "2 in no initiative", quarter, early)),
      # The session in view stops waiting with nothing else waiting: it stays.
      ("config-answered", front([0, 4, 0, 1, 0], 5, "5 sessions" & Dot & "4 running" & Dot & "1 failed",
        isWorking, "1/4", config, "", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", unattached2 & Dot & "2 in no initiative", quarter, early)),
      ("milestone-done", front([0, 4, 0, 1, 0], 5, "5 sessions" & Dot & "4 running" & Dot & "1 failed",
        isWorking, "2/4", config, "", 3, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", unattached2 & Dot & "2 in no initiative", half, afterDone)),
      ("importer-ends", front([0, 3, 0, 1, 1], 5, "5 sessions" & Dot & "3 running" & Dot & "1 failed",
        isWorking, "2/4", config, "", 3, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", unattached2 & Dot & "2 in no initiative", half, afterStart)),
      # The bench (not among the initiative's listed sessions) still runs:
      # the bar, which groups by each session's plan, is working; the
      # Initiatives row, which lists the plan's named sessions, is idle.
      ("port-completes", front([0, 1, 0, 1, 3], 5, "5 sessions" & Dot & "1 running" & Dot & "1 failed",
        isWorking, "2/4", config, "", 3, isIdle, "2/4" & Dot & "50%",
        "RC-M2: Core change", unattached2 & Dot & "2 in no initiative", half, afterStart)),
      ("importer-removed", front([0, 1, 0, 1, 2], 4, "4 sessions" & Dot & "1 running" & Dot & "1 failed",
        isWorking, "2/4", config, "", 2, isIdle, "2/4" & Dot & "50%",
        "RC-M2: Core change", unattached2 & Dot & "1 in no initiative", half, afterStart))]
    proc checkData(v: Views; e: FrontEndsMoment) =
      ## What the data decides at a moment, whatever the operator did: every
      ## surface but the bar's active tab and what follows from it (the
      ## inbox position, the sessions brought into view).
      let c = v.fleet.counts
      check c.byCategory == e.counts
      check c.listed == e.listed
      check v.tabs.summaryText == e.summary
      check v.list.summaryText == e.summary
      let barTab = v.bar.tabs[0]
      check barTab.id == RouteCache
      check barTab.state == e.barState
      check barTab.progressText == e.barProgress
      let row = v.initiatives.rows[0]
      check row.state == e.rowState
      check row.progressText == e.rowProgress
      check row.currentMilestone == e.rowCurrent
      check v.initiatives.summaryText == e.initiativesSummary
      check v.progress.headline == e.headline
      var groups: seq[string]
      for g in v.progress.groups: groups.add g.title
      check groups == e.groups
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("front-ends")
      let v = viewsOver(source, RouteCache, autoSwitch = true)
      var seen: seq[string]
      for (moment, e) in expected:
        if moment.len > 0:
          source.stepTo(source.scenario.momentMs(moment))
          check source.currentMoment == moment
        if moment == "port-asks": check v.bar.showSession(PortSessionId)
        seen.add moment
        checkpoint "at " & (if moment.len == 0: "the first moment" else: moment)
        checkData(v, e)
        check v.bar.activeTab.val == e.activeTab
        check v.bar.inboxPosition == e.inbox
        check v.bar.elsewhereCount == e.elsewhere
      check seen.len == 1 + source.scenario.momentNames.len
      # Seeking back from the end to each moment rebuilds the same state,
      # checked against the same hand-written values (not against a second
      # playback, which shares the source's and reducers' code).
      for i in countdown(expected.high, 0):
        let (moment, e) = expected[i]
        source.seek(source.scenario.lastMs)
        if moment.len == 0: source.seek(source.scenario.firstMs)
        else: check source.seekMoment(moment)
        checkpoint "sought back to " & (if moment.len == 0: "the first moment" else: moment)
        checkData(v, e)
      v.dispose()
      disposeRoot()

  test "initiative-run: milestones move and recordings load, fail and turn ready":
    let tr = TelemetryRetry
    type Moment = tuple[moment: string, counts: array[5, int],
                        state: InitiativeState, progress, headline, current: string,
                        groups, buttons: seq[string]]
    proc buttonsOf(v: Views): seq[string] =
      for b in v.bar.recordingButtonsOf(tr).buttons:
        result.add $b.number & ":" & $b.state & (if b.active: "*" else: "")
    let expected: seq[Moment] = @[
      ("", [0, 1, 0, 0, 0], isWorking, "0/3", "0 of 3 milestones" & Dot & "0%",
       "TR-M0: Specification", @["In progress (1)", "Planned (2)"], @[]),
      ("specification-done", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["Planned (2)", "Completed (1)"], @[]),
      ("trace-loading", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["In progress (1)", "Planned (1)", "Completed (1)"],
       @["1:loading*"]),
      ("trace-ready", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["In progress (1)", "Planned (1)", "Completed (1)"],
       @["1:ready*"]),
      ("recording-fails", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["In progress (1)", "Planned (1)", "Completed (1)"],
       @["1:ready*", "2:failed"]),
      # Blocked, but its session works: the tab reads working.
      ("milestone-blocked", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["Blocked (1)", "Planned (1)", "Completed (1)"],
       @["1:ready*", "2:failed"]),
      ("second-trace-ready", [0, 1, 0, 0, 0], isWorking, "1/3", "1 of 3 milestones" & Dot & "33%",
       "TR-M1: Retry queue", @["In progress (1)", "Planned (1)", "Completed (1)"],
       @["1:ready*", "2:failed", "3:ready"]),
      ("queue-done", [0, 1, 0, 0, 0], isWorking, "2/3", "2 of 3 milestones" & Dot & "67%",
       "TR-M2: Backoff", @["Planned (1)", "Completed (2)"],
       @["1:ready*", "2:failed", "3:ready"]),
      ("recording-reloaded", [0, 1, 0, 0, 0], isWorking, "2/3", "2 of 3 milestones" & Dot & "67%",
       "TR-M2: Backoff", @["In progress (1)", "Completed (2)"],
       @["1:ready*", "2:ready", "3:ready"]),
      ("plan-done", [0, 1, 0, 0, 0], isWorking, "3/3", "3 of 3 milestones" & Dot & "100%",
       "", @["Completed (3)"], @["1:ready*", "2:ready", "3:ready"]),
      # The plan is done and nothing runs: the initiative has ended.
      ("session-ends", [0, 0, 0, 0, 1], isEnded, "3/3", "3 of 3 milestones" & Dot & "100%",
       "", @["Completed (3)"], @["1:ready*", "2:ready", "3:ready"])]
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("initiative-run")
      let v = viewsOver(source, tr)
      proc checkAt(v: Views; e: Moment) =
        check v.fleet.counts.byCategory == cats(e.counts)
        check v.bar.tabs[0].state == e.state
        check v.bar.tabs[0].progressText == e.progress
        check v.bar.popupOf(tr).headline == e.headline
        check v.progress.headline == e.headline
        check v.initiatives.rows[0].currentMilestone == e.current
        check v.initiatives.rows[0].state == e.state
        var groups: seq[string]
        for g in v.progress.groups: groups.add g.title
        check groups == e.groups
        check v.buttonsOf == e.buttons
      for e in expected:
        if e.moment.len > 0:
          source.stepTo(source.scenario.momentMs(e.moment))
          check source.currentMoment == e.moment
        checkpoint "at " & (if e.moment.len == 0: "the first moment" else: e.moment)
        checkAt(v, e)
      # Seeking back from the end to each moment: the same hand-written
      # values (the recordings the source delivered after it are gone).
      for i in countdown(expected.high, 0):
        let e = expected[i]
        source.seek(source.scenario.lastMs)
        if e.moment.len == 0: source.seek(source.scenario.firstMs)
        else: check source.seekMoment(e.moment)
        checkpoint "sought back to " & (if e.moment.len == 0: "the first moment" else: e.moment)
        checkAt(v, e)
      check source.seekMoment("session-ends")
      check "failed to load: the recording file is truncated" notin
        v.bar.recordingButtonsOf(tr).buttons[1].tooltip
      check source.seekMoment("recording-fails")
      check "(failed to load: the recording file is truncated)" in
        v.bar.recordingButtonsOf(tr).buttons[1].tooltip
      v.dispose()
      disposeRoot()

# ---------------------------------------------------------------------------
# The seam's subscriptions
# ---------------------------------------------------------------------------

type LoadsOnlySource = ref object of SnapshotDataSource

suite "the viewmodels follow a source through the seam":
  test "every viewmodel subscribes on load and unsubscribes when disposed":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("front-ends")
      proc counts(): seq[int] =
        @[source.frameSubscribers.activeCount, source.resumeSubscribers.activeCount,
          source.recordingSubscribers.activeCount, source.progressSubscribers.activeCount,
          source.resetSubscribers.activeCount]
      check counts() == @[0, 0, 0, 0, 0]
      let v = viewsOver(source, RouteCache)
      # Frames: fleet, tabs, list, bar, initiatives. Resumes: tabs, list,
      # bar, initiatives. Recordings: bar. Progress: tabs, list, bar,
      # initiatives, progress. Resets: all six.
      check counts() == @[5, 4, 1, 5, 6]
      # A reload replaces its subscriptions rather than adding to them.
      v.bar.load()
      v.fleet.load()
      check counts() == @[5, 4, 1, 5, 6]
      v.fleet.dispose()
      check counts() == @[4, 4, 1, 5, 5]
      v.bar.dispose()
      check counts() == @[3, 3, 0, 4, 4]
      v.tabs.dispose()
      v.list.dispose()
      v.initiatives.dispose()
      v.progress.dispose()
      check counts() == @[0, 0, 0, 0, 0]
      # Nothing the source sends now reaches a disposed viewmodel.
      check source.seekMoment("importer-removed")
      check v.fleet.counts.listed == 4    # as it was loaded
      disposeRoot()

  test "a resume alone moves the bar on and ends a tab's wait":
    # The resume path by itself: the scenario delivers each resume with its
    # session's input event, which also ends the wait, so here the source's
    # resume subscribers are sent the resume alone.
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("front-ends")
      let v = viewsOver(source, RouteCache, autoSwitch = true)
      check source.seekMoment("port-asks")
      check v.bar.showSession(PortSessionId)
      check v.bar.activeSessionId == PortSessionId
      check v.tabs.summaryText == "5 sessions" & Dot & "2 need input" & Dot & "3 running"
      let deliveries = source.resumeSubscribers.broadcast(
        success(ResumeEvent(sessionId: PortSessionId, atMs: PlaybackT0 + 61_000)))
      check deliveries == @[pdApplied, pdApplied, pdApplied, pdApplied]
      check v.bar.activeTab.val == "session:" & ConfigSessionId
      check v.tabs.summaryText == "5 sessions" & Dot & "1 needs input" & Dot & "4 running"
      check v.initiatives.rows[0].sessionCounts[saNeedsInput] == 0
      # A session that does not wait is not resumed again.
      check source.resumeSubscribers.broadcast(
        success(ResumeEvent(sessionId: PortSessionId, atMs: PlaybackT0 + 62_000))) ==
        @[pdUnchanged, pdUnchanged, pdUnchanged, pdUnchanged]
      v.dispose()
      disposeRoot()

  test "a source that only answers loads leaves the viewmodels as loaded":
    createRoot proc(disposeRoot: proc()) =
      let scenario = frontEndsScenario()
      let source = LoadsOnlySource(label: "loads only", snapshot: scenario.first,
                                   initiatives: scenario.initiatives)
      let v = viewsOver(source, RouteCache)
      check v.fleet.state.val == asReady
      check v.fleet.counts.listed == 4
      for feed in [v.fleet.feeds.frames.state.val, v.bar.feeds.frames.state.val,
                   v.tabs.feeds.frames.state.val, v.initiatives.feeds.frames.state.val]:
        check feed == asError
      check v.fleet.feeds.frames.error.val ==
        "the data source 'loads only' does not provide fleet frames"
      check v.bar.feeds.resumes.error.val ==
        "the data source 'loads only' does not provide session resumes"
      check v.bar.feeds.recordings.error.val ==
        "the data source 'loads only' does not provide recording states"
      check v.progress.feeds.resets.error.val ==
        "the data source 'loads only' does not provide stream resets"
      # Progress events: the snapshot source provides them.
      check v.progress.progressState.val == asReady
      check v.tabs.summaryText == "4 sessions" & Dot & "1 needs input" & Dot & "3 running"
      v.dispose()
      disposeRoot()

  test "a failing source answers every subscription with its error":
    createRoot proc(disposeRoot: proc()) =
      let source = newFailingDataSource("connection refused")
      let v = viewsOver(source, RouteCache)
      check v.fleet.feeds.frames.error.val == "connection refused"
      check v.bar.feeds.recordings.error.val == "connection refused"
      check v.bar.feeds.resets.error.val == "connection refused"
      v.dispose()
      disposeRoot()

  test "a recording event adds or replaces one recording, and keeps the active one":
    var entries: seq[RecordingEntry]
    let a = RecordingEntry(id: "a", name: "first", state: rsLoading)
    check entries.applyRecording(a)
    check not entries.applyRecording(a)
    var b = RecordingEntry(id: "b", name: "second", state: rsLoading)
    check entries.applyRecording(b)
    b.state = rsFailed
    check entries.applyRecording(b)
    check entries.len == 2 and entries[1].state == rsFailed and entries[0].id == "a"
    check not entries.applyRecording(RecordingEntry())
    createRoot proc(disposeRoot: proc()) =
      let bar = newInitiativeTabStripVM(newPlayback("initiative-run"))
      check bar.applyRecording(RecordingEvent(initiativeId: "x", entry: a))
      check bar.applyRecording(RecordingEvent(initiativeId: "x", entry: b))
      let buttons = bar.recordingButtonsOf("x").buttons
      check buttons.len == 2 and buttons[0].active and not buttons[1].active
      bar.dispose()
      disposeRoot()
