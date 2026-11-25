## The omnibox composer's viewmodel (`OmniboxComposerVM`) over its two
## seams -- the front-end's `InstructionRouter` (routing, UI actions) and the
## Agent Harbor data source's `submitAction` (every delivery to Agent
## Harbor): one step (the decision shown live while
## typing, `Enter` sending at once, or when routed if pressed before),
## answers that arrive late or after disposal, the draft kept across
## closing, redirects with the keys and after sending, the launch and
## initiative forms, Stop, gaze context, and the sheet's width rule.
##
## No test doubles beyond the seams' own implementations: `ScriptedRouter`
## (decisions by instruction, a UI action's outcome, held until released
## where a test needs an answer to arrive late), `PendingRouter` and
## `FailingRouter`, and `ScriptedActionSource`, which records every action
## as `$action` writes it and answers it from its script -- what the
## prototype's stories use, because no live routing agent exists and the
## prototypes never write to a server. Every expectation is written out by
## hand. The data is invented (an upload client's retry work).

import std/[strutils, tables, unittest]
import isonim/core/[owner, signals]
import nim_agents_isonim_viewmodels

const Dot = " \xC2\xB7 "

proc targets(running = false; session = true): seq[RouteTarget] =
  @[RouteTarget(kind: tkSession, id: "sess-upload-retry",
                label: "Make the upload client retry with jitter",
                available: session, running: running,
                unavailableReason: (if session: "" else: "No agent session in this window")),
    RouteTarget(kind: tkManager, id: "mgr-reliability",
                label: "Upload reliability manager", available: true),
    RouteTarget(kind: tkUiAction, id: "codetracer", label: "CodeTracer",
                available: true)]

proc context(): seq[ContextItem] =
  @[ContextItem(id: "file", kind: ckFile, label: "src/upload/client.py:42",
                reference: "src/upload/client.py:42"),
    ContextItem(id: "replay", kind: ckReplay, label: "Replay at step 1,284",
                reference: "trace:upload-retry#1284")]

proc scripted(): ScriptedRouter =
  result = newScriptedRouter("test router")
  result.decide("Also retry on a 503", RoutingDecision(target: tkSession,
    reason: "It is about the retry this session is changing", cited: @["file"]))
  result.decide("Start a task: a 503 retry test", RoutingDecision(
    target: tkManager, intent: riLaunchTask, reason: "New work"))
  result.decide("Start an initiative: uploads survive a flaky network",
    RoutingDecision(target: tkManager, intent: riNewInitiative, reason: "A new goal"))
  result.decide("Show the client beside the test", RoutingDecision(
    target: tkUiAction, action: "Show client.py beside test_retry.py"))
  result.uiOutcome = Receipt(outcome: uoDone,
    result: "Opened client.py beside test_retry.py")

const LaunchNotice = "Started on server-a" & Dot & "executor exec-7" & Dot &
                     "session 5ca1ab1e"

var actions: ScriptedActionSource
  ## The last composer's action source: what it was asked to send.

proc composer(router: InstructionRouter; running = false; session = true;
              source: AgentHarborDataSource = nil): OmniboxComposerVM =
  actions = newScriptedActionSource("test actions")
  actions.script.setRule(oaLaunchTask, confirmedWith(LaunchNotice))
  newOmniboxComposerVM(router, (if source.isNil: AgentHarborDataSource(actions) else: source),
                       targets(running, session), context(), planDate = "2026-11-17")

proc sent(): seq[string] =
  ## Every action sent to Agent Harbor, as `$action` writes it.
  actions.record

proc marks(vm: OmniboxComposerVM): seq[RowMark] =
  for r in vm.rows: result.add r.mark

proc selected(vm: OmniboxComposerVM): seq[TargetKind] =
  for r in vm.rows:
    if r.selected: result.add r.target

suite "one step":
  test "the decision shows while typing, and Enter sends at once":
    let router = scripted()
    let vm = composer(router)
    vm.open()
    vm.setText("Also retry on a 503")
    check router.routed.len == 1              # asked while typing
    check router.routed[0].text == "Also retry on a 503"
    check router.routed[0].targets.len == 3
    check vm.route == rsDecided
    check vm.phase == cpComposing
    check sent().len == 0 and router.performed.len == 0  # shown, not sent
    check vm.marks == @[rmRouted, rmNone, rmNone]
    check vm.rows[0].reason == "It is about the retry this session is changing"
    check vm.citesLine == "Cites src/upload/client.py:42"
    check vm.chips[0].cited and not vm.chips[1].cited
    check vm.canSend
    vm.submit()                               # one Enter
    check sent().len == 1
    # The instruction after the header of what it cites: the file, not the
    # replay position, which it does not cite (`$action` escapes the text).
    check sent()[0] == "send-instruction session=sess-upload-retry text=" &
      escape("Context from the operator's window:\n- src/upload/client.py:42\n\n" &
             "Also retry on a 503")
    check vm.phase == cpSent
    check vm.sentLine == "Sent to this session"
    check vm.text == ""
    check vm.recent.len == 1
    vm.dispose()

  test "every change of the text asks the router again":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Also")
    vm.setText("Also retry on a 503")
    check router.routed.len == 2
    check router.routed[1].text == "Also retry on a 503"
    vm.setText("   ")                         # nothing to route
    check router.routed.len == 2
    check vm.rows[0].mark == rmNone
    vm.dispose()

  test "Enter before the decision sends when it arrives":
    let router = scripted()
    router.hold = true
    let vm = composer(router)
    vm.setText("Show the client beside the test")
    check vm.route == rsRouting
    check vm.canSend
    vm.submit()
    check vm.phase == cpSending
    check router.performed.len == 0           # nothing sent before the decision
    check vm.headerLine == "Routing\xE2\x80\xA6" & Dot & "sends when routed"
    router.releaseOne()                       # the decision
    check router.performed.len == 1           # the UI action, the front-end's
    check router.performed[0].action == "Show client.py beside test_retry.py"
    check sent().len == 0
    router.release()                          # the receipt
    check vm.phase == cpSent
    vm.dispose()

  test "an older route's answer is ignored":
    let router = scripted()
    router.hold = true
    let vm = composer(router)
    vm.setText("Also retry on a 503")
    vm.setText("Show the client beside the test")   # edited while routing
    check router.pendingAnswers == 2
    router.releaseOne()                       # the first text's answer
    check vm.route == rsRouting
    router.releaseOne()
    check vm.route == rsDecided
    check vm.draft.decision.target == tkUiAction
    vm.dispose()

  test "an answer after dispose changes nothing":
    let router = scripted()
    router.hold = true
    let vm = composer(router)
    vm.setText("Also retry on a 503")
    let revision = vm.revision.val
    vm.dispose()
    router.release()
    check vm.revision.val == revision
    check vm.route == rsRouting

  test "an answer after the owner is disposed changes nothing":
    # Disposed with the root it was made under, never by `vm.dispose()`:
    # the late answer is ignored because the ViewModel base marks the
    # composer disposed when that root goes.
    let router = scripted()
    router.hold = true
    var vm: OmniboxComposerVM
    var revision: int
    createRoot proc(disposeRoot: proc()) =
      vm = composer(router)
      vm.setText("Also retry on a 503")
      revision = vm.revision.val
      disposeRoot()
    check vm.isDisposed
    router.release()
    check vm.revision.val == revision
    check vm.route == rsRouting

  test "the draft survives closing":
    let vm = composer(scripted())
    vm.open()
    vm.setText("Also retry on a 503")
    vm.toggleAddContext()
    vm.close()
    check not vm.isOpen.val
    check not vm.addContextOpen.val
    vm.open()
    check vm.text == "Also retry on a 503"
    check vm.route == rsDecided
    check vm.phase == cpComposing
    vm.dispose()

suite "where it goes":
  test "the arrow keys choose another destination before sending":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Also retry on a 503")
    vm.moveSelection(1)
    check vm.selected == @[tkManager]
    check vm.marks == @[rmRouterChoice, rmChosen, rmNone]
    check vm.headerLine == "Enter sends it where you chose"
    vm.moveSelection(1)
    check vm.selected == @[tkUiAction]
    vm.moveSelection(1)                       # wraps
    check vm.selected == @[tkSession]
    check vm.marks == @[rmRouted, rmNone, rmNone]
    vm.moveSelection(-1)
    check vm.selected == @[tkUiAction]
    vm.setText("Also retry on a 503, please")  # routed again: the choice stands
    check vm.selected == @[tkUiAction]
    vm.submit()
    check router.performed.len == 1
    check sent().len == 0
    vm.dispose()

  test "the arrow keys skip a destination the window cannot reach":
    let vm = composer(scripted(), session = false)
    vm.setText("Show the client beside the test")
    check vm.selected == @[tkUiAction]
    vm.moveSelection(1)
    check vm.selected == @[tkManager]         # not the session
    vm.moveSelection(1)
    check vm.selected == @[tkUiAction]
    check not vm.rows[0].enabled
    check vm.rows[0].reason == "No agent session in this window"
    vm.dispose()

  test "a routing failure: Enter sends to the destination shown":
    let router = newScriptedRouter()
    router.routeFailure = "the routing agent did not answer in 20 s"
    let vm = composer(router)
    vm.setText("Anything")
    check vm.route == rsFailed
    check vm.headerLine == "Could not route: the routing agent did not answer in 20 s"
    check vm.selected == @[tkSession]
    vm.submit()
    check sent().len == 1
    check sent()[0].startsWith("send-instruction session=sess-upload-retry")
    vm.dispose()

  test "Enter that waited for a failed decision sends nothing":
    let router = newScriptedRouter()
    router.routeFailure = "the routing agent did not answer in 20 s"
    router.hold = true
    let vm = composer(router)
    vm.setText("Anything")
    vm.submit()
    check vm.phase == cpSending
    router.release()
    check vm.phase == cpComposing
    check sent().len == 0
    check vm.route == rsFailed
    vm.dispose()

  test "a failing router and a pending one":
    let failing = composer(newFailingRouter("connection refused"),
                           source = newFailingDataSource("connection refused"))
    failing.setText("Anything")
    check failing.route == rsFailed
    failing.submit()
    check failing.phase == cpSendFailed
    check failing.rows[0].error == "connection refused"
    failing.dispose()
    let pendingRouter = newPendingRouter()
    let pending = composer(pendingRouter)
    pending.setText("Anything")
    check pending.route == rsRouting
    check pendingRouter.calls == 1
    pending.submit()
    check pending.phase == cpSending          # waits for a decision that never comes
    check pendingRouter.calls == 1
    pending.dispose()

  test "an uncited chip is not sent":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Also retry on a 503")
    vm.toggleContext("file")
    check vm.citesLine == "Cites nothing from this window"
    vm.toggleContext("replay")
    check vm.citesLine == "Cites Replay at step 1,284"
    vm.submit()
    check "trace:upload-retry#1284 (Replay at step 1,284)" in sent()[0]
    check "src/upload/client.py:42" notin sent()[0]
    vm.dispose()

suite "after sending":
  test "sending again adds a delivery":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Also retry on a 503")
    vm.submit()
    check vm.rows[1].canSendAgain
    vm.sendAgain(tkManager)
    check sent().len == 2
    check sent()[1].startsWith("instruct-manager session=mgr-reliability text=")
    check vm.sentLine == "Sent to this session" & Dot & "redirected to the manager agent"
    check vm.recent.len == 1
    check vm.recent[0].line == vm.sentLine
    vm.dispose()

  test "a failed delivery, retried with Enter":
    let router = scripted()
    let vm = composer(router)
    actions.script.setRule(oaSendInstruction, failedWith("Agent Harbor answered 503"))
    vm.setText("Also retry on a 503")
    vm.submit()
    check vm.phase == cpSendFailed
    check vm.headerLine == "Failed to send"
    check vm.rows[0].error == "Agent Harbor answered 503"
    check vm.text == "Also retry on a 503"
    actions.script.setRule(oaSendInstruction, confirmed())
    vm.submit()
    check sent().len == 2
    check vm.phase == cpSent
    vm.dispose()

  test "two failed deliveries: Enter retries the first, to its own target only":
    let router = scripted()
    let vm = composer(router)
    actions.script.setRule(oaSendInstruction, failedWith("Agent Harbor answered 503"))
    actions.script.setRule(oaInstructManager, failedWith("Agent Harbor answered 503"))
    vm.setText("Also retry on a 503")
    vm.submit()                               # to the session: fails
    vm.sendAgain(tkManager)                   # redirected: fails too
    check sent().len == 2
    check vm.phase == cpSendFailed
    actions.script.setRule(oaSendInstruction, confirmed())
    actions.script.setRule(oaInstructManager, confirmed())
    vm.submit()                               # retries the session's, only
    check sent().len == 3
    check sent()[2].startsWith("send-instruction session=sess-upload-retry")
    check vm.rows[0].delivery == dsSent
    check vm.rows[1].delivery == dsFailed
    check vm.phase == cpSendFailed
    vm.submit()                               # then the manager's
    check sent().len == 4
    check sent()[3].startsWith("instruct-manager session=mgr-reliability")
    check vm.phase == cpSent
    check vm.rows[0].delivery == dsSent and vm.rows[1].delivery == dsSent
    vm.dispose()

  test "a UI action's result":
    let vm = composer(scripted())
    vm.setText("Show the client beside the test")
    check vm.rows[2].label == "Show client.py beside test_retry.py"
    vm.submit()
    check outcomeLine(vm.rows[2].receipt) == "Opened client.py beside test_retry.py"
    vm.dispose()

  test "Recent gives an instruction back":
    let vm = composer(scripted())
    vm.setText("Also retry on a 503")
    vm.submit()
    check not vm.isEmptyField                 # the sheet shows the result
    vm.setText("")                            # typing starts the next one
    check vm.isEmptyField
    check vm.recent[0].text == "Also retry on a 503"
    check vm.recent[0].line == "Sent to this session"
    vm.recall(0)
    check vm.text == "Also retry on a 503"
    check vm.phase == cpComposing
    vm.dispose()

suite "launching and initiatives":
  test "a launch opens its form, and Enter waits for its problems":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Start a task: a 503 retry test")
    check vm.showsForm
    check vm.optionsOpen.val
    check vm.sendLabel == "Launch"
    check not vm.canSend
    check vm.sendDisabledReason == "Choose a repository"
    vm.submit()
    check sent().len == 0
    vm.updateLaunch(LaunchOptions(repository: "upload-service",
                                  agents: @["Claude Code"], openIn: oiNewTab))
    check vm.canSend
    vm.submit()
    check sent().len == 1
    check sent()[0].startsWith("launch-task session=mgr-reliability " &
                               "repository=upload-service agents=Claude Code " &
                               "run-on=This machine open-in=New tab text=")
    check outcomeLine(vm.rows[1].receipt) == "Started on server-a" & Dot &
      "executor exec-7" & Dot & "session 5ca1ab1e"
    check not vm.optionsOpen.val
    vm.dispose()

  test "a launch redirected to the session is an instruction":
    let router = scripted()
    let vm = composer(router)
    vm.setText("Start a task: a 503 retry test")
    vm.choose(tkSession)
    check not vm.showsForm
    check vm.sendLabel == "Send"
    check vm.canSend
    vm.submit()
    check sent()[0].startsWith("send-instruction session=sess-upload-retry")
    vm.dispose()

  test "a new initiative and its plan file":
    let vm = composer(scripted())
    vm.setText("Start an initiative: uploads survive a flaky network")
    check vm.sendLabel == "Start initiative"
    check vm.sendDisabledReason == "Say what the initiative is for"
    vm.updateInitiative(NewInitiativeForm(goal: "Uploads survive a flaky network",
                                          iteration: imAuto))
    check vm.planPreview ==
      "milestones/2026-11-17-uploads-survive-a-flaky-network.milestones.org"
    check vm.canSend
    vm.dispose()

suite "the window":
  test "Stop stops the session's turn":
    let router = scripted()
    let vm = composer(router, running = true)
    actions.script.setRule(oaStopSession, confirmedWith("Stopped after the current tool call"))
    check vm.rows[0].canStop
    vm.stop()
    check sent() == @["stop-session session=sess-upload-retry"]
    check vm.stopState.val == ssStopped
    check vm.stopMessage.val == "Stopped after the current tool call"
    check not vm.rows[0].canStop
    vm.stop()
    check sent().len == 1                    # nothing left to stop
    vm.dispose()

  test "a stop that fails says why":
    let router = scripted()
    let vm = composer(router, running = true)
    actions.script.setRule(oaStopSession, failedWith("the session is not running"))
    vm.stop()
    check vm.stopState.val == ssFailed
    check vm.stopMessage.val == "Could not stop: the session is not running"
    vm.dispose()

  test "gaze: tracking offers what was looked at, paused a note, off nothing":
    let vm = composer(scripted())
    vm.setGaze(gsTracking, gazeChip("gaze", "retries += 1",
                                    "src/upload/client.py:44", 1400))
    check vm.chips.len == 3
    check vm.chips[2].item.label == "Looked at retries += 1" & Dot & "1.4 s"
    vm.setGaze(gsPaused)
    check vm.chips.len == 3
    check vm.chips[2].item.label == "Gaze paused"
    check vm.chips[2].item.note
    vm.setGaze(gsOff)
    check vm.chips.len == 2
    check gazeMark(vm.gaze.val) == (false, "")
    vm.dispose()

  test "the session going away moves the selection":
    let vm = composer(scripted())
    vm.setText("Also retry on a 503")
    check vm.selected == @[tkSession]
    vm.setTargets(targets(session = false))
    check vm.selected == @[tkManager]
    vm.dispose()

  test "a multi-line instruction":
    let vm = composer(scripted())
    vm.setText("Also retry on a 503\nand on a 504\nwith the same jitter")
    check vm.fieldText == "Also retry on a 503"
    check vm.moreLines == "+2 lines"
    check vm.instructionBlock.count('\n') == 2
    vm.setText("One line")
    check vm.moreLines == ""
    check vm.instructionBlock == ""
    vm.dispose()

  test "the sheet's width, in the renderer's unit":
    let vm = composer(scripted())
    check vm.sheetWidthFor(1440) == 640
    check vm.sheetWidthFor(360) == 344
    check vm.isNarrow(360) and not vm.isNarrow(760)
    vm.maxSheetWidth = 80                    # a terminal, in cells
    vm.sheetInset = 1
    vm.narrowBelow = 60
    check vm.sheetWidthFor(180) == 80
    check vm.sheetWidthFor(45) == 43
    check vm.isNarrow(45)
    vm.dispose()

  test "the add-context items are the prompt's":
    check AddContextItems == ["Upload attachment", "Files & folders",
                              "Editor selection", "Recording / trace"]
