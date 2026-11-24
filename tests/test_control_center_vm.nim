## The control center's viewmodel (`ControlCenterVM`) and the gaze mark's
## (`GazeStatusVM`), native and JS: the Initiatives panel, the launch form
## and the waiting sessions composed over one source; a launch through the
## chosen initiative's manager, its notice, and its session joining the
## initiative as `queued` with the frame that introduces it; loading, error
## and an empty fleet; opening a waiting session; disposal; and the gaze
## mark's words, tooltip, pause key and the composer following it.
##
## No test doubles beyond the seams' own implementations: a
## `TimelineDataSource` (a snapshot source whose fleet-frame stream sends what
## the test sends), the pending and failing sources, a `ScriptedRouter` and a
## `ScriptedActionSource`, which records every action as `$action` writes it
## and answers from its script -- what the prototype's stories use, because
## the prototypes never write to a server. Every expectation is written out
## by hand. The data is invented (an upload service's reliability work).

import std/[strutils, unittest]
import isonim/core/[owner, signals, computation]
import nim_agents_isonim_viewmodels

const
  Dot = " \xC2\xB7 "
  Notice = "Started on server-a" & Dot & "executor exec-7" & Dot & "session 5ca1ab1e"
  Now = 1_000_000_000'i64
  Minute = 60_000'i64

proc session(id, title, planId: string; status = fsRunning; waits = "";
             minutesAgo = 1): FleetSession =
  FleetSession(id: id, prompt: title, name: title, status: status, rawStatus: $status,
               createdAtMs: Now - 90 * Minute, startedAtMs: Now - 90 * Minute,
               updatedAtMs: Now - int64(minutesAgo) * Minute,
               awaitingInput: waits.len > 0, awaitingInputSource: waits,
               planId: planId)

proc initiative(id, title, manager: string; sessionIds: seq[string]): Initiative =
  var progress = MilestoneFileProgress(path: "milestones/" & id & ".org", title: title,
    milestones: @[MilestoneDetail(id: "M1", title: "First", status: "completed"),
                  MilestoneDetail(id: "M2", title: "Second", status: "in_progress")])
  progress.summarize()
  Initiative(id: id, title: title, manager: manager, sessionIds: sessionIds,
             progress: progress)

proc fleet(): TimelineDataSource =
  result = newTimelineDataSource(@[], label = "test fleet")
  result.snapshot = FleetSnapshot(capturedAtMs: Now, sessions: @[
    session("s-retry", "Retry uploads with jitter", "reliability"),
    session("s-asks-late", "Pick the retry budget", "reliability",
            waits = "s-asks-late:native-question:1", minutesAgo = 3),
    session("s-asks-early", "Choose the chunk size", "throughput",
            waits = "s-asks-early:native-question:1", minutesAgo = 20),
    session("s-idle", "Write the changelog", "", waits = "claude-stop-hook",
            minutesAgo = 40),
    session("s-done", "Answer a question", "", status = fsCompleted, minutesAgo = 50)])
  result.initiatives = @[
    initiative("reliability", "Upload reliability", "mgr-reliability",
               @["s-retry", "s-asks-late"]),
    initiative("throughput", "Upload throughput", "mgr-throughput", @["s-asks-early"])]

var actions: ScriptedActionSource

proc router(): ScriptedRouter =
  result = newScriptedRouter("test router")
  result.decideByDefault(RoutingDecision(target: tkManager, reason: "fleet work"))

proc center(source: AgentHarborDataSource): ControlCenterVM =
  actions = newScriptedActionSource("test actions")
  actions.script.setRule(oaLaunchTask, confirmedWith(Notice))
  result = newControlCenterVM(source, router(), actions, planDate = "2026-11-17")
  result.load()

proc waitingIds(vm: ControlCenterVM): seq[string] =
  for row in vm.waiting: result.add row.item.id

proc fill(vm: ControlCenterVM; text: string) =
  ## A launch the form accepts.
  vm.composer.setText(text)
  vm.composer.updateLaunch(LaunchOptions(repository: "upload-service",
                                         agents: @["Claude"], openIn: oiNewTab))

suite "composed over one source":
  test "the initiatives, the launch form and the waiting sessions":
    let vm = center(fleet())
    check vm.state == asReady
    check vm.initiatives.rows.len == 2
    check vm.mode == lmTask
    check vm.composer.showsForm                     # before anything is typed
    check vm.composer.chosenIntent == riLaunchTask
    # On a question first, the longest waiting first; then ended turns; never
    # a running or completed session.
    check vm.waitingIds == @["s-asks-early", "s-asks-late", "s-idle"]
    let first = vm.waiting[0]
    check first.item.initiativeTitle == "Upload throughput"
    check first.words == "needs input, progress unknown"
    check first.words == first.item.pie.label
    check first.item.pie.role == prWarning
    check vm.waiting[2].item.attention == saIdle
    check vm.isEmptyFleet == false
    vm.dispose()

  test "the launch choices: no initiative, then the panel's initiatives":
    let vm = center(fleet())
    var titles: seq[string]
    for c in vm.launchChoices: titles.add c.title
    check titles[0] == "No initiative"
    check titles.len == 3
    check "Upload reliability" in titles and "Upload throughput" in titles
    check vm.launchChoices[0].chosen
    vm.dispose()

  test "the layout rule":
    let vm = center(fleet())
    check vm.layoutFor(1440) == clTwoColumns
    check vm.layoutFor(480) == clOneColumn
    vm.narrowBelow = 100                            # cells, in a terminal
    check vm.layoutFor(95) == clOneColumn
    check vm.layoutFor(180) == clTwoColumns
    vm.dispose()

suite "launching":
  test "a task for an initiative goes through its manager, with its notice":
    let source = fleet()
    let vm = center(source)
    vm.chooseInitiative("reliability")
    check vm.launchForTitle == "Upload reliability"
    check vm.launchChoices[0].chosen == false
    vm.fill("Add a 503 retry test")
    var o = vm.composer.launch
    o.branch = "test/503-retry"
    vm.composer.updateLaunch(o)
    check vm.composer.showsForm
    check vm.composer.canSend
    vm.composer.submit()
    check actions.record.len == 1
    check actions.record[0].startsWith("launch-task session=mgr-reliability")
    check vm.launchNotice == (Notice, false, false)
    # The form is ready for the next launch, the answer kept under it.
    check vm.composer.phase == cpComposing
    check vm.composer.text == ""
    check vm.composer.showsForm and vm.composer.optionsOpen.val
    check vm.composer.launch.branch == ""           # the launch's own name goes
    check vm.composer.launch.repository == "upload-service"  # where to, stays
    check vm.recent.len == 1
    check recentLine(vm.recent[0]) == "Manager of Upload reliability" & Dot & Notice
    # The server reports the new session: it joins its initiative, queued.
    let launched = session("s-new", "Add a 503 retry test", "reliability", status = fsQueued)
    discard source.sendFrame(FleetFrame(kind: ffSession, session: launched))
    var queued = false
    for row in vm.initiatives.rows:
      if row.id == "reliability":
        for item in row.sessions:
          if item.id == "s-new": queued = item.attention == saQueued
    check queued
    check "s-new" notin vm.waitingIds               # queued does not wait
    vm.dispose()

  test "after a launch, the next one starts in either mode, its form open":
    let vm = center(fleet())
    vm.newInitiative()
    vm.composer.setText("Uploads survive a hub restart")
    vm.composer.updateInitiative(NewInitiativeForm(goal: "Uploads survive a hub restart"))
    actions.script.setRule(oaStartInitiative, confirmedWith("Plan started"))
    vm.composer.submit()
    check vm.composer.phase == cpComposing          # ready for the next one
    check vm.launchNotice.line == "Plan started"
    vm.newTask()
    check vm.composer.phase == cpComposing
    check vm.composer.text == ""
    check vm.mode == lmTask
    check vm.composer.optionsOpen.val
    check vm.recent.len == 1                        # the launch is kept
    vm.composer.optionsOpen.val = false
    vm.newTask()                                    # the mode already pressed
    check vm.composer.optionsOpen.val
    vm.dispose()

  test "no initiative: the server starts it; an unknown initiative is refused":
    let vm = center(fleet())
    vm.chooseInitiative("no-such-plan")
    check vm.launchFor.val == ""
    vm.fill("Run the upload benchmarks")
    vm.composer.submit()
    check actions.record[0].startsWith("launch-task ")
    check "session=" notin actions.record[0]        # no manager session
    check recentLine(vm.recent[0]) == "Agent Harbor" & Dot & Notice
    vm.dispose()

  test "New initiative, a failed launch, and a launch still waiting":
    let vm = center(fleet())
    vm.newInitiative()
    check vm.mode == lmInitiative
    check vm.composer.optionsOpen.val
    vm.newTask()
    check vm.mode == lmTask
    actions.script.setRule(oaLaunchTask, failedWith("Agent Harbor answered 503"))
    vm.fill("Add a 504 retry test")
    vm.composer.submit()
    check vm.launchNotice == ("Could not launch: Agent Harbor answered 503", true, false)
    check vm.composer.text == "Add a 504 retry test"  # kept, to try again
    check vm.composer.canSend
    actions.script.setRule(oaLaunchTask, neverAnswered())
    vm.fill("Add a 502 retry test")
    vm.composer.submit()
    check vm.launchNotice.pending
    check vm.composer.chosenIntent == riLaunchTask  # the mode stands
    vm.dispose()

  test "a launch in flight locks the form until Agent Harbor answers":
    let vm = center(fleet())
    vm.chooseInitiative("reliability")
    actions.script.setRule(oaLaunchTask, neverAnswered())
    check not vm.launching
    vm.fill("Add a 429 retry test")
    vm.composer.submit()
    check vm.launching
    check vm.launchNotice == ("Launching\xE2\x80\xA6", false, true)
    check not vm.composer.canSend                   # Launch is busy
    check vm.composer.optionsOpen.val               # the form stays drawn
    # Locked: the initiative, the mode, the text and the options stay.
    vm.chooseInitiative("throughput")
    check vm.launchFor.val == "reliability"
    check vm.launchForTitle == "Upload reliability"
    vm.newInitiative()
    check vm.mode == lmTask
    vm.composer.setText("something else")
    check vm.composer.text == "Add a 429 retry test"
    vm.composer.updateLaunch(LaunchOptions(repository: "elsewhere"))
    check vm.composer.launch.repository == "upload-service"
    # Answered (a failure): unlocked, the instruction back in the field.
    actions.script.settle(0, false, "Agent Harbor answered 503")
    check not vm.launching
    check vm.launchNotice == ("Could not launch: Agent Harbor answered 503", true, false)
    check vm.composer.text == "Add a 429 retry test"
    check vm.composer.canSend
    vm.chooseInitiative("throughput")
    check vm.launchFor.val == "throughput"
    vm.dispose()

suite "states":
  test "loading and error come from the source":
    let loading = center(newPendingDataSource("waiting"))
    check loading.state == asLoading
    check loading.waiting.len == 0
    loading.dispose()
    let failing = center(newFailingDataSource("GET /api/v1/initiatives failed", "down"))
    check failing.state == asError
    check failing.error == "GET /api/v1/initiatives failed"
    check not failing.isEmptyFleet                  # an error is not an empty fleet
    failing.dispose()

  test "an empty fleet":
    let vm = center(newSnapshotDataSource(FleetSnapshot(capturedAtMs: Now), "empty"))
    check vm.isEmptyFleet
    check vm.waiting.len == 0
    check vm.launchChoices.len == 1
    vm.dispose()

suite "the waiting sessions follow the source":
  test "a session comes to wait, one is answered, and the reader is told":
    let source = fleet()
    let vm = center(source)
    var seen = 0
    createRoot proc(dispose: proc()) =
      createEffect proc() =
        discard vm.waiting
        inc seen
    let before = seen
    var asks = session("s-retry", "Retry uploads with jitter", "reliability",
                       waits = "s-retry:native-question:1", minutesAgo = 0)
    discard source.sendFrame(FleetFrame(kind: ffSession, session: asks))
    check seen > before
    check vm.waitingIds == @["s-asks-early", "s-asks-late", "s-retry", "s-idle"]
    check vm.resume(ResumeEvent(sessionId: "s-asks-early", atMs: Now + Minute))
    check vm.waitingIds == @["s-asks-late", "s-retry", "s-idle"]
    vm.dispose()

  test "opening a waiting session asks the host for its tab":
    let vm = center(fleet())
    vm.openSession("s-asks-late")
    check vm.requestedSession.val == "s-asks-late"
    check vm.requests.val == 1
    vm.openSession("")
    check vm.requests.val == 1
    vm.dispose()

  test "the keys walk the waiting list and open the row they are on":
    let vm = center(fleet())
    check vm.moveFocus(1)
    check vm.focused.val == "s-asks-early"
    check vm.moveFocus(1)
    check vm.moveFocus(1)
    check vm.focused.val == "s-idle"
    check vm.moveFocus(1)                           # wraps
    check vm.focused.val == "s-asks-early"
    check vm.moveFocus(-1)
    check vm.focused.val == "s-idle"
    check vm.openFocused()
    check vm.requestedSession.val == "s-idle"
    # The focused session stops waiting: Enter opens the first that does.
    check vm.resume(ResumeEvent(sessionId: "s-idle", atMs: Now + Minute))
    check vm.openFocused()
    check vm.requestedSession.val == "s-asks-early"
    vm.dispose()
    let empty = center(newSnapshotDataSource(FleetSnapshot(capturedAtMs: Now), "empty"))
    check not empty.moveFocus(1)
    check not empty.openFocused()
    empty.dispose()

  test "disposed: a late frame moves nothing":
    let source = fleet()
    let vm = center(source)
    vm.dispose()
    let r = vm.revision.val
    discard source.sendFrame(FleetFrame(kind: ffSession,
      session: session("s-late", "Late", "reliability", waits = "x:native-question:1")))
    check vm.revision.val == r
    check vm.feeds.lateEvents == 0 or vm.feeds.frames.closed

suite "the gaze mark":
  test "off draws nothing; tracking and paused, with the key":
    let vm = newGazeStatusVM(gsOff, "Ctrl+Alt+G")
    check not vm.shown
    check vm.text == ""
    check vm.tooltip == ""
    vm.setState(gsTracking)
    check vm.shown and vm.text == "Gaze" and not vm.struck
    check vm.tooltip.endsWith("Ctrl+Alt+G pauses it.")
    check vm.togglePause()
    check vm.text == "Gaze paused" and vm.struck
    check vm.tooltip.endsWith("Ctrl+Alt+G resumes it.")
    check vm.togglePause()
    check vm.state.val == gsTracking
    vm.dispose()

  test "the pause key never turns tracking on":
    let vm = newGazeStatusVM(gsOff, "Ctrl+Alt+G")
    check not vm.togglePause()
    check vm.state.val == gsOff
    vm.dispose()

  test "the composer's chip follows the mark":
    let composer = newOmniboxComposerVM(router(), newScriptedActionSource("a"),
      [RouteTarget(kind: tkSession, id: "s", label: "S", available: true)])
    let vm = newGazeStatusVM(gsTracking, "Ctrl+Alt+G",
      onChange = proc(state: GazeState) = composer.setGaze(state))
    check vm.togglePause()
    check composer.gaze.val == gsPaused
    var labels: seq[string]
    for chip in composer.chips: labels.add chip.item.label
    check labels == @["Gaze paused"]
    check vm.togglePause()
    check composer.gaze.val == gsTracking
    vm.dispose()
    composer.dispose()
