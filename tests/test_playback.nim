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

import std/[json, sequtils, strutils, unittest]
import isonim/core/[owner, signals, clock]
import nim_agents_isonim_viewmodels
from nim_agents/agent_harbor/session_replay import sessionAt
from nim_agents/agent_harbor/fleet_fold import sessionFrame

const Dot = " \xC2\xB7 "

# ---------------------------------------------------------------------------
# What the scenarios hold, read straight from their entries
# ---------------------------------------------------------------------------

proc inboxSubject(event: InboxEvent): string =
  ## An inbox event's kind and the item it names.
  $event.kind & " " & (if event.kind == ieResolved: event.target.id else: event.item.id)

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
  of sekInbox: "inbox " & inboxSubject(entry.inbox)
  of sekOperator: "press " & $entry.press.kind

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
    inbox: Subscription[InboxEvent]
    presses: Subscription[OperatorPress]

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
  r.inbox = source.subscribeInbox proc(a: DataResult[InboxEvent]): ProgressDelivery =
    r.log.add $r.source.nextDeliveredMs & " inbox " & inboxSubject(a.value)
    pdApplied
  r.presses = source.subscribePresses proc(a: DataResult[OperatorPress]): ProgressDelivery =
    r.log.add $r.source.nextDeliveredMs & " press " & $a.value.kind
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
  timeline: SessionTimelineVM
    ## nil unless a session's timeline is shown (`timelineSession`).
  inbox: InboxVM
    ## nil unless the scenario feeds the inbox (`withInbox`).
  operator: InboxPlaybackOperator
    ## The operator's presses on `inbox`, replayed from the scenario.
  center: ControlCenterVM
    ## nil unless the scenario feeds the control center (`withCenter`): the
    ## initiatives, and the sessions waiting for the operator.
  initiativeId: string

proc viewsOver(source: AgentHarborDataSource; initiativeId: string;
               autoSwitch = false; timelineSession = ""; withInbox = false;
               withCenter = false): Views =
  ## The viewmodels of every playback story, loaded over `source`: the fleet
  ## list, the tab strip, the sidebar list, the initiative tab bar, the
  ## Initiatives panel and the Initiative Progress panel showing
  ## `initiativeId`, and, given `timelineSession`, that session's activity
  ## timeline, and given `withInbox` (over a playback source) the inbox with
  ## its item pages and the operator's presses. Call inside a reactive root.
  result.initiativeId = initiativeId
  if withInbox:
    result.inbox = newInboxVM(source, showPages = true)
    result.inbox.load()
    result.operator = newInboxPlaybackOperator(PlaybackDataSource(source), result.inbox)
  if timelineSession.len > 0:
    result.timeline = newSessionTimelineVM(source, timelineSession)
    result.timeline.load()
  result.fleet = newFleetSnapshotVM(source)
  result.tabs = newSessionTabStripVM(source)
  result.list = newSessionTabStripVM(source, tsmSidebar)
  result.bar = newInitiativeTabStripVM(source)
  result.bar.autoSwitch.val = autoSwitch
  result.initiatives = newInitiativesVM(source)
  result.progress = newInitiativeProgressVM(source, initiativeId)
  if withCenter:
    result.center = newControlCenterVM(source, newScriptedRouter("test router"), source)
    result.center.load()
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
  if not views.center.isNil: views.center.dispose()
  if not views.timeline.isNil: views.timeline.dispose()
  if not views.operator.isNil: views.operator.stop()
  if not views.inbox.isNil: views.inbox.dispose()

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
  if views.timeline.isNil:
    result.add "timeline -"
  else:
    var lines: seq[string]
    for line in views.timeline.lines: lines.add line.text & " [" & line.textRole & "]"
    result.add "timeline " & views.timeline.statusLabel & " " & $lines
  if views.inbox.isNil:
    result.add "inbox -"
  else:
    var ids: seq[string]
    for item in views.inbox.items: ids.add item.id
    result.add "inbox " & $ids & " at " & views.inbox.current.val.id & " " &
      views.inbox.positionText & " next " & $views.inbox.canNext & " prev " &
      $views.inbox.canPrev & " " & views.inbox.notice
  if views.center.isNil:
    result.add "control-center -"
  else:
    var waiting: seq[string]
    for row in views.center.waiting: waiting.add row.item.id & " " & row.words
    result.add "control-center " & $waiting & " " & $views.center.initiatives.rows

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

proc initiativeOf(scenario: PlaybackScenario): string =
  ## The initiative a scenario's progress panel shows: its first ("" when it
  ## has none).
  if scenario.initiatives.len > 0: scenario.initiatives[0].id else: ""

proc firstInitiative(name: string): string =
  playbackScenario(name).initiativeOf

proc timelineOf(scenario: PlaybackScenario): string =
  ## The session a scenario's activity timeline shows ("" when it feeds none).
  if scenario.feeds("session-activity"): scenario.sessionOf("session-activity") else: ""

proc viewsOf(source: PlaybackDataSource): Views =
  ## Every view of the source's scenario, loaded over it.
  viewsOver(source, source.scenario.initiativeOf,
            timelineSession = source.scenario.timelineOf,
            withInbox = source.scenario.feeds("inbox"),
            withCenter = source.scenario.feeds("control-center"))

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

  test "session-run loads, and holds its invariants":
    let s = sessionRunScenario()
    check s.name == "session-run"
    check s.invariantFailures.len == 0
    check s.problemsOf.len == 0
    for p in s.problemsOf: checkpoint p
    # One view, the jitter session's timeline, at its own moments; the
    # logging session's events interleave and are on no list.
    check s.views.len == 1
    check s.views[0].view == "session-activity"
    check s.sessionOf("session-activity") == JitterSessionId
    check s.momentNames == @SessionRunMoments
    check s.momentNames("session-activity") == @SessionRunMoments
    var types: seq[string]
    var other = 0
    for entry in s.entries:
      if entry.kind != sekEvent: continue
      if entry.sessionId == LoggingSessionId:
        inc other
        check entry.moment == ""
      elif entry.event{"type"}.getStr notin types:
        types.add entry.event{"type"}.getStr
    check other == 6
    check types == @["user_input", "thought", "file_read", "tool_use", "tool_result",
                     "llm_request", "agent_question", "session_resumed", "file_edit",
                     "diff", "plan", "session_awaiting_input", "log", "status"]
    # The existing scenarios name no session for their views.
    for name in ["front-ends", "initiative-run"]:
      for view in playbackScenario(name).views: check view.sessionId == ""

  test "a session view's problems are reported":
    var foreign = sessionRunScenario()
    # A moment of the other session only, on the jitter session's list.
    for entry in foreign.entries.mitems:
      if entry.kind == sekEvent and entry.sessionId == LoggingSessionId and
          entry.event{"type"}.getStr == "log":
        entry.moment = "logging-replies"
    foreign.views[0].moments.insert("logging-replies", 9)
    check foreign.problemsOf == @["scenario session-run: the view session-activity names " &
      "logging-replies, which has no entry about " & JitterSessionId]
    var nobody = sessionRunScenario()
    nobody.views[0].sessionId = "5ca1ab1e-0000-4000-8000-000000000000"
    check nobody.problemsOf.len == 1
    check "names no session of the scenario" in nobody.problemsOf.join("\n")
    var fleetWide = frontEndsScenario()
    fleetWide.views[0].sessionId = PortSessionId
    check fleetWide.problemsOf == @["scenario front-ends: the view fleet shows the whole " &
      "fleet and names the session " & PortSessionId]
    var orphan = sessionRunScenario()
    let jitter = orphan.findSession(JitterSessionId)
    for event in orphan.sessions[jitter].history.mitems:
      if event{"type"}.getStr == "tool_result" and event{"tool_execution_id"}.getStr == "cmd-1":
        event["tool_execution_id"] = %"cmd-0"
    check orphan.problemsOf == @["scenario session-run: a tool_result of " & JitterSessionId &
      " names no tool_use before it (cmd-0)"]
    var stranger = sessionRunScenario()
    for event in stranger.sessions[jitter].history.mitems:
      if event{"command_trace"} != nil:
        event["command_trace"]["processes"][1]["argv"] = %["sed", "-n", "1p"]
    check stranger.problemsOf.len == 1
    check "names sed, which the command `pytest -q | tee test.log | tail -n 5` does not run" in
      stranger.problemsOf.join("\n")

  test "a milestone completed with work outstanding is reported":
    # The plans stay coherent (`problemsOf`): completing a milestone by its
    # status alone leaves "completed" beside "0/2 deliverables", and so does
    # a first listing that marks one completed with a test pending.
    var bare = initiativeRunScenario()
    for entry in bare.entries.mitems:
      if entry.kind == sekProgress and entry.progress.status == "completed":
        entry.progress.hasCounts = false
        break
    check bare.problemsOf.len == 1
    for p in bare.problemsOf: checkpoint p
    check "TR-M0 is completed with work outstanding" in bare.problemsOf.join("\n")
    var listed = frontEndsScenario()
    listed.initiatives[0].progress.milestones[0].verifications.pending = 1
    check listed.problemsOf.len == 1
    check "in the first listing" in listed.problemsOf.join("\n")

  test "inbox-run loads, and holds its invariants":
    let s = inboxRunScenario()
    check s.name == "inbox-run"
    check s.invariantFailures.len == 0
    let problems = s.problemsOf
    for p in problems: checkpoint p
    check problems.len == 0
    # It feeds the inbox only. Its entries are inbox events and presses, and
    # the question and the answer of the one session whose wait its own
    # events say; its sessions are running from before the first moment.
    check s.views.len == 1 and s.views[0].view == "inbox"
    check s.views[0].moments == @InboxRunMoments
    var kinds: set[ScenarioEntryKind]
    var events: seq[string]
    for entry in s.entries:
      kinds.incl entry.kind
      if entry.kind == sekEvent:
        events.add $(entry.atMs - s.firstMs) & " " & entry.event{"type"}.getStr
    check kinds == {sekEvent, sekInbox, sekOperator}
    check events == @["10000 agent_question", "60000 user_input"]
    check s.first.sessions.len == 5
    # The feedback request is waiting from before the first moment, so the
    # first frame is not the empty inbox (the story declares data).
    check s.inbox.items.len == 1
    check s.inbox.items[0].id == RunFeedback.id
    check s.inbox.items[0].position == 1
    check s.inboxDetails.len == 5

  test "an inbox scenario's problems are reported":
    var bad = inboxRunScenario()
    # An item of a session the scenario does not hold, an order that is not a
    # permutation of the items, a resolution of an item the inbox does not
    # hold, an item with no page, and an answer that says nothing.
    for entry in bad.entries.mitems:
      if entry.kind == sekInbox and entry.inbox.kind == ieAdded and
          entry.inbox.item.id == RunQuestion.id:
        entry.inbox.item.session.id = "no-such-session"
      if entry.kind == sekInbox and entry.moment == "boost-ends":
        entry.inbox.order = @[RunPermission, RunQuestion]
      if entry.kind == sekOperator and entry.press.kind == opAnswer and
          entry.press.text.len > 0:
        entry.press.text = ""
    bad.entries.add inboxEntry(bad.lastMs + 1_000,
      InboxEvent(kind: ieResolved, target: InboxItemRef(id: "never-added")))
    bad.inboxDetails = bad.inboxDetails[0 .. 3]   # the login item loses its page
    let text = bad.problemsOf.join("\n")
    checkpoint text
    check "names the session no-such-session, which is not a session of the scenario" in text
    check "boost-ends" in text and "carries an order that is not a permutation of the items" in text
    check "resolves an item the inbox does not hold" in text
    check "names the item run-login, which has no page" in text
    check "answers with nothing" in text
    check bad.problemsOf.len == 5

  test "an unknown scenario name is refused":
    expect ValueError: discard playbackScenario("no-such-scenario")
    for name in PlaybackScenarioNames: check playbackScenario(name).name == name

# ---------------------------------------------------------------------------
# Every named moment changes what it names
# ---------------------------------------------------------------------------

const
  SessionKinds = {sekLifecycle, sekListing, sekEvent, sekResume}
  FedBy: array[6, set[ScenarioEntryKind]] = [
    SessionKinds,              # 0 the fleet list
    SessionKinds,              # 1 the tab strip
    SessionKinds,              # 2 the sidebar list
    {sekProgress, sekRecording}, # 3 the initiative bar (n/m, recordings)
    {sekProgress},             # 4 the Initiatives panel
    {sekProgress}]             # 5 the Initiative Progress panel
    ## Which entries each surface of `shown` shows: a moment whose entries
    ## include one of these kinds must change that surface. The seventh, the
    ## session activity timeline (`TimelineAt`), shows only its own
    ## session's events; the eighth, the inbox (`InboxAt`), the inbox's
    ## events and the operator's presses on it.
  TimelineAt = 6
  InboxAt = 7
  ControlCenterAt = 8
    ## The ninth, the control center: its waiting sessions and the
    ## initiatives' summary.
  InboxKinds = {sekInbox, sekOperator}

proc heldStill(views: Views): seq[string] =
  ## `shown`, less what moves with the clock alone (the fleet's ages and
  ## durations): what an entry changes, and nothing else.
  result = views.shown
  var rows = views.fleet.rows
  for row in rows.mitems:
    row.ageLabel = ""
    row.durationLabel = ""
  result[0] = "fleet " & $rows & " " & $views.fleet.counts
  doAssert result.len == ControlCenterAt + 1

proc unchangedAtMoments(scenario: PlaybackScenario): seq[string] =
  ## Every (moment, surface) where the moment's entries -- those after the
  ## moment before it, up to and including its own -- feed the surface and
  ## the surface shows the same as at the moment before (the first frame
  ## before the first moment), and every moment with no entry since the one
  ## before it. Empty when every moment changes what it names.
  var found: seq[string]
  createRoot proc(disposeRoot: proc()) =
    let source = newPlaybackDataSource(scenario, newTestClock(0))
    let v = viewsOf(source)
    var before = v.heldStill
    var previousMs = scenario.firstMs
    for name in scenario.momentNames:
      let at = scenario.momentMs(name)
      var kinds: set[ScenarioEntryKind]
      var timelineFed = false
      for entry in scenario.entries:
        if entry.atMs > previousMs and entry.atMs <= at:
          kinds.incl entry.kind
          if entry.kind == sekEvent and entry.sessionId == scenario.timelineOf:
            timelineFed = true
      source.stepTo(at)
      let now = v.heldStill
      if kinds.card == 0:
        found.add scenario.name & " at " & name & ": no entry since the moment before"
      for i, fed in FedBy:
        if (fed * kinds).card > 0 and now[i] == before[i]:
          found.add scenario.name & " at " & name & ": " & now[i].split(' ')[0] &
            " shows the same as at the moment before (" & $(fed * kinds) & ")"
      if timelineFed and now[TimelineAt] == before[TimelineAt]:
        found.add scenario.name & " at " & name & ": timeline shows the same as at the moment before"
      if (kinds * InboxKinds).card > 0 and now[InboxAt] == before[InboxAt]:
        found.add scenario.name & " at " & name & ": inbox shows the same as at the moment before"
      before = now
      previousMs = at
    v.dispose()
    disposeRoot()
  found

const ShownAt = [("fleet", 0), ("session-tabs", 1), ("session-list", 2),
                 ("initiative-tabs", 3), ("initiatives", 4), ("initiative-progress", 5),
                 ("session-activity", TimelineAt), ("inbox", InboxAt),
                 ("control-center", ControlCenterAt)]
  ## Each view's line of `shown`.

proc shownIndex(view: string): int =
  for (v, i) in ShownAt:
    if v == view: return i
  doAssert false, "no line of shown for the view " & view

proc viewsUnmovedAtTheirMoments(scenario: PlaybackScenario): seq[string] =
  ## Every (view, moment) where the moment is on the view's list and the
  ## view shows the same as at the scenario's moment before it (the first
  ## frame before the first): a moment the view's story would show with
  ## nothing visibly happening. Empty when every listed moment moves its view.
  var found: seq[string]
  createRoot proc(disposeRoot: proc()) =
    let source = newPlaybackDataSource(scenario, newTestClock(0))
    let v = viewsOf(source)
    var before = v.heldStill
    for name in scenario.momentNames:
      source.stepTo(scenario.momentMs(name))
      let now = v.heldStill
      for view in scenario.views:
        if name notin view.moments: continue
        let i = shownIndex(view.view)
        if now[i] == before[i]:
          found.add scenario.name & " at " & name & ": the view " & view.view &
            " lists the moment and shows the same as at the moment before"
      before = now
    v.dispose()
    disposeRoot()
  found

suite "every named moment changes what it names":
  test "each view's moments move that view, in both scenarios":
    for name in PlaybackScenarioNames:
      let s = playbackScenario(name)
      check s.views.len > 0
      let unmoved = s.viewsUnmovedAtTheirMoments
      for u in unmoved: checkpoint u
      check unmoved.len == 0

  test "a view listing a moment that does not move it is reported":
    # The progress panel at trace-ready: a recording turns ready, which the
    # panel does not show.
    var listed = initiativeRunScenario()
    for view in listed.views.mitems:
      if view.view == "initiative-progress":
        view.moments = @["specification-done", "trace-ready", "milestone-blocked",
                         "queue-done", "plan-done"]
    check listed.problemsOf.len == 0
    let unmoved = listed.viewsUnmovedAtTheirMoments
    check unmoved == @["initiative-run at trace-ready: the view initiative-progress " &
                       "lists the moment and shows the same as at the moment before"]

  test "a timeline listing another session's moment is reported":
    # The logging session's check finishes at +58 s, and the jitter session
    # does nothing between +50 s and then: its timeline does not move, so the
    # moment does not belong on its list.
    var foreign = sessionRunScenario()
    for entry in foreign.entries.mitems:
      if entry.kind == sekEvent and entry.sessionId == LoggingSessionId and
          entry.event{"type"}.getStr == "tool_result":
        entry.moment = "logging-checked"
    foreign.views[0].moments.insert("logging-checked", 4)
    check foreign.viewsUnmovedAtTheirMoments == @["session-run at logging-checked: the view " &
      "session-activity lists the moment and shows the same as at the moment before"]

  test "a view's moments are named moments, in time order, and cover every moment":
    var bad = frontEndsScenario()
    bad.views[0].moments = @["port-asks", "new-session", "no-such-moment"]
    bad.views.add ScenarioView(view: "no-such-view", moments: @["new-session"])
    let problems = bad.problemsOf
    for p in problems: checkpoint p
    let text = problems.join("\n")
    check "the view fleet names new-session out of time order" in text
    check "the view fleet names no-such-moment, which is not a named moment" in text
    check "the view no-such-view is not one of the playback views" in text
    var uncovered = initiativeRunScenario()
    for view in uncovered.views.mitems:
      view.moments = view.moments.filterIt(it != "milestone-blocked")
    check uncovered.problemsOf == @["scenario initiative-run: the moment milestone-blocked " &
                                    "is on no view's list"]
    expect ValueError: discard frontEndsScenario().momentNames("initiative-progress")

  test "each moment changes every surface its entries feed, in both scenarios":
    for name in PlaybackScenarioNames:
      let unchanged = playbackScenario(name).unchangedAtMoments
      for u in unchanged: checkpoint u
      check unchanged.len == 0

  test "a moment whose entry changes nothing is reported":
    # A named moment on a progress event that repeats a milestone's status
    # and counts: the bar and both panels are fed by it and show the same.
    var still = initiativeRunScenario()
    var repeat: ScenarioEntry
    for entry in still.entries:
      if entry.kind == sekProgress: repeat = entry
    doAssert repeat.kind == sekProgress
    repeat.atMs = still.lastMs + 1_000
    repeat.moment = "nothing-moves"
    still.entries.add repeat
    for view in still.views.mitems:
      if view.view == "initiative-progress": view.moments.add "nothing-moves"
    check still.problemsOf.len == 0
    let unchanged = still.unchangedAtMoments
    for u in unchanged: checkpoint u
    check unchanged.len == 3
    check unchanged.join("\n").contains("at nothing-moves: progress")

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
          for moment in scenario.momentNames:
            let at = scenario.momentMs(moment)
            let sought = newPlayback(name)
            let stepped = newPlayback(name)
            let rs = record(sought)
            let rt = record(stepped)
            let a = viewsOf(sought)
            let b = viewsOf(stepped)
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
          let source = newPlayback(name)
          let r = record(source)
          let views = viewsOf(source)
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
            let freshViews = viewsOf(fresh)
            fresh.stepTo(at)
            check agree(views, freshViews, name & " sought back to " &
                        (if moment.len == 0: "the first moment" else: moment))
            # A viewmodel loaded after the seek starts where the others are.
            let late = viewsOf(source)
            check agree(late, freshViews, name & " loaded late at " & moment)
            late.dispose()
            freshViews.dispose()
          # Forwards again from the first moment, playing to the end.
          let straight = newPlayback(name)
          let straightViews = viewsOf(straight)
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
    let two = "1 initiative" & Dot & "2 sessions"
    let three = "1 initiative" & Dot & "3 sessions"
    let early = @["In progress (1)", "Planned (2)", "Completed (1)"]
    let afterDone = @["Planned (2)", "Completed (2)"]
    let afterStart = @["In progress (1)", "Planned (1)", "Completed (2)"]
    let quarter = "1 of 4 milestones" & Dot & "25%"
    let half = "2 of 4 milestones" & Dot & "50%"
    let expected = @[
      ("", front([1, 3, 0, 0, 0], 4, "4 sessions" & Dot & "1 needs input" & Dot & "3 running",
        isWorking, "1/4", route, "1 waiting", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", two & Dot & "2 in no initiative", quarter, early)),
      # The benchmark, launched for the route cache, joins its row at once.
      ("new-session", front([1, 3, 1, 0, 0], 5,
        "5 sessions" & Dot & "1 needs input" & Dot & "3 running" & Dot & "1 queued",
        isWorking, "1/4", route, "1 waiting", 4, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "2 in no initiative", quarter, early)),
      ("port-asks", front([2, 3, 0, 0, 0], 5, "5 sessions" & Dot & "2 need input" & Dot & "3 running",
        isNeedsInput, "1/4", route, "2 of 2", 4, isNeedsInput, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "1 needs input" & Dot & "2 in no initiative",
        quarter, early)),
      ("bench-asks", front([3, 2, 0, 0, 0], 5, "5 sessions" & Dot & "3 need input" & Dot & "2 running",
        isNeedsInput, "1/4", route, "2 of 3", 4, isNeedsInput, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "2 need input" & Dot & "2 in no initiative",
        quarter, early)),
      # Answered: auto-switch hands the view to the longest-waiting session.
      # The benchmark still waits, so the route cache's row needs input.
      ("port-answered", front([2, 3, 0, 0, 0], 5, "5 sessions" & Dot & "2 need input" & Dot & "3 running",
        isNeedsInput, "1/4", config, "1 of 2", 3, isNeedsInput, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "1 needs input" & Dot & "2 in no initiative",
        quarter, early)),
      ("migration-fails", front([1, 3, 0, 1, 0], 5,
        "5 sessions" & Dot & "1 needs input" & Dot & "3 running" & Dot & "1 failed",
        isWorking, "1/4", config, "1 of 1", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "2 in no initiative", quarter, early)),
      # The session in view stops waiting with nothing else waiting: it stays.
      ("config-answered", front([0, 4, 0, 1, 0], 5, "5 sessions" & Dot & "4 running" & Dot & "1 failed",
        isWorking, "1/4", config, "", 3, isWorking, "1/4" & Dot & "25%",
        "RC-M1: Data model", three & Dot & "2 in no initiative", quarter, early)),
      ("milestone-done", front([0, 4, 0, 1, 0], 5, "5 sessions" & Dot & "4 running" & Dot & "1 failed",
        isWorking, "2/4", config, "", 3, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", three & Dot & "2 in no initiative", half, afterDone)),
      ("importer-ends", front([0, 3, 0, 1, 1], 5,
        "5 sessions" & Dot & "3 running" & Dot & "1 failed" & Dot & "1 ended",
        isWorking, "2/4", config, "", 3, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", three & Dot & "2 in no initiative", half, afterStart)),
      # The benchmark still runs: the bar and the Initiatives row, which both
      # follow every session launched for the route cache, are working.
      ("port-completes", front([0, 1, 0, 1, 3], 5,
        "5 sessions" & Dot & "1 running" & Dot & "1 failed" & Dot & "3 ended",
        isWorking, "2/4", config, "", 3, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", three & Dot & "2 in no initiative", half, afterStart)),
      ("importer-removed", front([0, 1, 0, 1, 2], 4,
        "4 sessions" & Dot & "1 running" & Dot & "1 failed" & Dot & "2 ended",
        isWorking, "2/4", config, "", 2, isWorking, "2/4" & Dot & "50%",
        "RC-M2: Core change", three & Dot & "1 in no initiative", half, afterStart))]
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

suite "the session activity timeline at each named moment":
  test "session-run: the jitter session's timeline, stepping forward and after seeking back":
    # Each moment's top lines (text [role]) and the header's status, written
    # out from `sessionRunScenario`'s documented history.
    let instruction = "Add jitter to the upload client's retries, so clients that " &
      "fail together do not retry together. [label]"
    let thought = "Thinking: The retry loop lives in the upload client. Read it and its tests first. [quiet]"
    let reads = "Read 4 files [body]"
    let searches = "Searched 3 times [body]"
    let running = "Ran 2 shell commands Ran pytest -q | tee test.log | tail -n 5 [body]"
    let failed = "Ran 2 shell commands (1 failed) [body]"
    let question = "Use full jitter or equal jitter for the retry delay?"
    let edits = "Edited 3 files +40 \xE2\x88\x9212 [body]"
    let plan = "Plan updated: 3 steps, 2 done, 1 in progress [body]"
    let hooks = "Waiting for input (claude stop hook) \xC3\x973 [quiet]"
    let tests = "Ran pytest -q [body]"
    let reply = "The retry client backs off with full jitter; 18 tests pass. [body]"
    let answered = @[instruction, thought, reads, searches, failed, question & " [body]",
                     "Full jitter. [label]", "Resumed by operator [quiet]"]
    let expected = @[
      ("instruction", "running", @[instruction]),
      ("reads-grouped", "running", @[instruction, thought, reads]),
      ("searches-grouped", "running", @[instruction, thought, reads, searches]),
      ("command-running", "running", @[instruction, thought, reads, searches, running]),
      ("command-fails", "running", @[instruction, thought, reads, searches, failed]),
      ("agent-asks", "needs input",
       @[instruction, thought, reads, searches, failed, question & " [warning]"]),
      ("answered", "running", answered),
      ("edits-grouped", "running", answered & @[edits]),
      ("hook-repeats", "needs input", answered & @[edits, plan, hooks]),
      ("agent-replies", "running", answered & @[edits, plan, hooks, tests, reply]),
      ("session-completes", "completed", answered & @[edits, plan, hooks, tests, reply,
        "Status: completed Retries now wait a random time up to the exponential cap. [ended]"])]
    proc topOf(vm: SessionTimelineVM): seq[string] =
      for line in vm.lines:
        if line.indent == 0: result.add line.text & " [" & line.textRole & "]"
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("session-run")
      let vm = newSessionTimelineVM(source, JitterSessionId)
      vm.load()
      check vm.isEmpty
      check vm.notice == EmptyNotice
      for (moment, status, lines) in expected:
        checkpoint "stepping to " & moment
        source.stepTo(source.scenario.momentMs(moment))
        check source.currentMoment == moment
        check vm.statusLabel == status
        check vm.topOf == lines
      for i in countdown(expected.high, 0):
        let (moment, status, lines) = expected[i]
        checkpoint "seeking back to " & moment
        source.seek(source.scenario.lastMs)
        check source.seekMoment(moment)
        check vm.statusLabel == status
        check vm.topOf == lines
      vm.dispose()
      disposeRoot()

suite "the inbox at each named moment":
  test "inbox-run: items arrive, the operator walks, answers and goes back, stepping and seeking back":
    # Each moment's inbox, written out from `inboxRunScenario`'s documented
    # entries: the rows in the server's order, the item on screen, the
    # position, Next and Previous, the notice, the page's answer line,
    # auto-switch, and the tab the inbox asked for.
    type Expected = tuple[moment: string, rows: seq[string], at, position: string,
                          canNext, canPrev: bool, notice, phase: string,
                          autoSwitch: bool, session: string]
    let q = RunQuestion.id
    let e = RunEndedTurn.id
    let p = RunPermission.id
    let f = RunFeedback.id
    let l = RunLogin.id
    # The first frame: the feedback request waiting from before the run.
    let firstFrame: Expected = ("", @[f], "", "1 waiting", true, false, "", "", false, "")
    let expected: seq[Expected] = @[
      ("first-wait", @[q, f], "", "2 waiting", true, false, "", "", false, ""),
      ("four-waiting", @[p, e, q, f], "", "4 waiting", true, false, "", "", false, ""),
      ("next", @[p, e, q, f], p, "1 of 4", true, false, "", "", false, InboxSchemaSessionId),
      # The boost ends and the server reorders; the item on screen stays.
      ("boost-ends", @[p, q, e, f], p, "1 of 4", true, false, "", "", false,
       InboxSchemaSessionId),
      # Answered with auto-switch off: the page stays, its item gone.
      ("answered", @[q, e, f], p, "3 waiting", true, false, "", AnswerSentText, false,
       InboxSchemaSessionId),
      # Auto-switch on: Next to the question, answered, and on to the ended
      # turn by itself.
      ("auto-switch", @[e, f], e, "1 of 2", true, true, "", "", true,
       InboxLoggingSessionId),
      # Previous goes back to the item visited, answered since, not to the
      # order's neighbour.
      ("prev", @[e, f], q, "2 waiting", true, true, "", AnswerSentText, true,
       InboxRouteSessionId),
      # Answered on another front-end while on screen: nothing moves, though
      # auto-switch is on and the feedback request is still waiting.
      ("resolved-elsewhere", @[f], e, "1 waiting", true, true, "", "", true,
       InboxLoggingSessionId),
      # An item arrives while the operator reads the page: the row is added
      # in the server's order and nothing takes the screen (no step, no tab
      # asked for, no input focused).
      ("arrives-while-reading", @[f, l], e, "2 waiting", true, true, "", "", true,
       InboxLoggingSessionId)]
    proc shownOf(inbox: InboxVM): Expected =
      var rows: seq[string]
      for item in inbox.items: rows.add item.id
      let page = inbox.page
      (inbox.current.val.id, rows, inbox.current.val.id, inbox.positionText,
       inbox.canNext, inbox.canPrev, inbox.notice,
       (if page.isNil: "" else: page.phaseText), inbox.autoSwitch.val,
       inbox.requestedSession.val)
    template agreeWith(inbox: InboxVM; x: Expected) =
      # A template, so each `check` is the test's own (a `check` in a proc
      # outside the test sets a global and cannot fail it).
      let got = inbox.shownOf
      check got.rows == x.rows
      check got.at == x.at
      check got.position == x.position
      check got.canNext == x.canNext
      check got.canPrev == x.canPrev
      check got.notice == x.notice
      check got.autoSwitch == x.autoSwitch
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("inbox-run")
      let inbox = newInboxVM(source, showPages = true)
      inbox.load()
      let op = newInboxPlaybackOperator(source, inbox)
      check source.currentMoment == ""
      inbox.agreeWith(firstFrame)
      check inbox.page.isNil
      check inbox.requestedSession.val == ""
      check not inbox.isEmpty
      for x in expected:
        checkpoint "stepping to " & x.moment
        source.stepTo(source.scenario.momentMs(x.moment))
        check source.currentMoment == x.moment
        inbox.agreeWith(x)
        let page = inbox.page
        check (if page.isNil: "" else: page.phaseText) == x.phase
        check inbox.requestedSession.val == x.session
      check op.missed == 0
      check op.made == 7          # every press of the scenario was made
      check inbox.focusRequests.val == 1   # auto-switch focused the ended turn's input
      # The record: every action the operator sent, and no other.
      check source.script.record == @[
        "decide-permission session=" & InboxSchemaSessionId &
          " item=run-permission request=run-perm-1 decision=allow_once",
        "answer-question session=" & InboxRouteSessionId &
          " item=run-question request=run-q-1 text=\"Keep it behind a flag.\""]
      # Seeking back to each moment shows what stepping there showed; a
      # reset puts auto-switch back where the scenario starts.
      for i in countdown(expected.high, 0):
        let x = expected[i]
        checkpoint "seeking back to " & x.moment
        source.seek(source.scenario.lastMs)
        check source.seekMoment(x.moment)
        inbox.agreeWith(x)
        let page = inbox.page
        check (if page.isNil: "" else: page.phaseText) == x.phase
      # And back to the first frame, before any press.
      checkpoint "seeking back to the first frame"
      source.seek(source.scenario.firstMs)
      inbox.agreeWith(firstFrame)
      op.stop()
      inbox.dispose()
      disposeRoot()

  test "a second inbox on the same cursor joins the walk where it is":
    createRoot proc(disposeRoot: proc()) =
      let source = newPlayback("inbox-run")
      let first = newInboxVM(source, showPages = true)
      first.load()
      let op = newInboxPlaybackOperator(source, first)
      check source.seekMoment("auto-switch")
      let second = newInboxVM(source)
      second.load()
      check second.current.val == RunEndedTurn
      check second.positionText == "1 of 2"
      check second.canPrev
      # Previous on the second goes back along the stack the first built.
      check second.prev()
      check second.current.val == RunQuestion
      check second.positionText == "2 waiting"
      op.stop()
      first.dispose()
      second.dispose()
      disposeRoot()

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

  test "a session launched for an initiative joins its row with the frame that introduces it":
    # The Initiatives panel loads the initiatives once; a later frame that
    # introduces a session launched for the route cache (`planId`) puts it
    # in the route cache's row, with its counts and state, and the header
    # counts it, with no second load of the initiatives.
    createRoot proc(disposeRoot: proc()) =
      let scenario = frontEndsScenario()
      let source = LoadsOnlySource(label: "loads only", snapshot: scenario.first,
                                   initiatives: scenario.initiatives)
      let panel = newInitiativesVM(source)
      panel.load()
      proc ids(row: InitiativeRow): seq[string] =
        for item in row.sessions: result.add item.id
      check panel.rows[0].ids.len == 2
      check BenchSessionId notin panel.rows[0].ids
      check panel.summaryText == "1 initiative" & Dot & "2 sessions" & Dot & "2 in no initiative"
      var bench: ScenarioSession
      for s in scenario.sessions:
        if s.entry.id == BenchSessionId: bench = s
      # The benchmark waiting on a question, as its listing reads at +100 s.
      var count = 0
      for event in bench.history:
        if bench.eventTimeOf(event) <= PlaybackT0 + 100_000: inc count
      let listing = bench.entry.sessionAt(bench.history, count, bench.startMs)
      check panel.applyFleetFrame(sessionFrame(listing, PlaybackT0 + 100_000))
      let row = panel.rows[0]
      check BenchSessionId in row.ids
      check row.sessionCounts[saNeedsInput] == 1
      check row.state == isNeedsInput
      check row.missingSessions == 0
      check panel.summaryText == "1 initiative" & Dot & "3 sessions" & Dot & "1 needs input" &
        Dot & "2 in no initiative"
      # A session launched for no initiative joins no row.
      var other = listing
      other.id = "5ca1ab1e-0a09-4a00-8000-00000000a009"
      other.planId = ""
      other.initiative = ""
      check panel.applyFleetFrame(sessionFrame(other, PlaybackT0 + 101_000))
      check panel.rows[0].ids.len == 3
      check panel.summaryText == "1 initiative" & Dot & "3 sessions" & Dot & "1 needs input" &
        Dot & "3 in no initiative"
      panel.dispose()
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
