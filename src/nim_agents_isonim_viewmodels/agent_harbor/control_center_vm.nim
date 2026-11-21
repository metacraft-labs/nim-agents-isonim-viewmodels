## `ControlCenterVM`: the control center, a front-end's full-window tab for
## launching tasks and initiatives and following every initiative at once
## (CodeTracer Agent-Harbor-Front-End "The control center"). A DASHBOARD
## pattern of two columns:
##
## - **Launch** (left): the omnibox composer's launch and initiative forms,
##   inline (`composer`, an `OmniboxComposerVM`). The operator says what is
##   started (`newTask`, `newInitiative`: the composer's `chooseIntent`) and
##   which initiative it is for (`chooseInitiative`, which makes that
##   initiative's manager the launch's destination); typing, the forms, their
##   validation and the delivery are the composer's, unchanged. Under the
##   form, Agent Harbor's answer to the last launch (`launchNotice`) and the
##   recent launches (`recent`).
## - **Overview** (right): every initiative as the Initiatives panel shows it
##   (`initiatives`, an `InitiativesVM` over the same source), and under it
##   the sessions that wait for the operator, in inbox order (`waiting`).
##
## **After a launch.** Once Agent Harbor answers a launch, the form is ready
## for the next one -- its field empty and the launch's own names (branch,
## session name; an initiative's goal and plan file) cleared, where and how
## to launch kept (on a failure, the instruction back in the field to try
## again), the form open -- and the answer stays under it
## (`launchNotice`) until the next launch. The control center sees the
## answer through the action source it hands the composer
## (`LaunchAnswers`, which passes every action through unchanged).
##
## Narrow (`layoutFor`): one column, launching first.
##
## The waiting sessions follow the source as the Initiatives panel does: the
## listing on `load`, then its fleet frames, resumes and resets (`feeds`). A
## session launched from here joins its initiative's row, and the waiting
## list when it comes to wait, with the frame that introduces it; nothing is
## reloaded.
##
## The keys walk the waiting list (`moveFocus`: the next or previous row,
## wrapping; the first or last when none is focused) and `openFocused` opens
## the row they are on.
##
## Opening a waiting session publishes it on `requestedSession` (with
## `requests` moving each time), which a host turns into activating, or
## opening, the session's tab.
##
## Each waiting row carries its session's progress pie (`progress_pie`) and
## the pie's words; a front-end draws the words, and the pie where it draws
## pies.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/control_center
import ./data_source
import ./source_feed
import ./session_items
import ./initiatives_vm
import ./omnibox_composer_vm
import ./instruction_router

export control_center, initiatives_vm, omnibox_composer_vm, session_items

const
  ControlCenterNarrowBelow* = 720
    ## The width below which the control center is one column, in pixels
    ## (the web, GPUI). A terminal sets `narrowBelow` in cells.
  NoInitiativeManagerLabel* = "Agent Harbor"
    ## The destination of a launch for no initiative: the server starts the
    ## session itself.

type
  LaunchAnswers = ref object of AgentHarborDataSource
    ## The composer's action source: every action goes to `inner`, and
    ## `answered` hears each answer after the composer applied it.
    inner: AgentHarborDataSource
    answered: proc()

  WaitingRow* = object
    ## One session that waits for the operator.
    item*: SessionItem
      ## Its title, state, why it waits, its initiative, age and pie.
    words*: string
      ## Its pie's words (`needs input, progress unknown`): its accessible
      ## name.

  InitiativeChoice* = object
    ## An initiative a launch can be for.
    id*: string        ## "" for no initiative
    title*: string
    chosen*: bool

  ControlCenterVM* = ref object of ViewModel
    source: AgentHarborDataSource
    initiatives*: InitiativesVM
    composer*: OmniboxComposerVM
    directory: SessionDirectory
    nowMs: int64
    policy*: SessionPolicy
    feeds: SourceFeeds
    loadToken: int
    narrowBelow*: int
    revision*: Signal[int]
      ## Moves whenever the waiting sessions change.
    launchFor*: Signal[string]
      ## The initiative the next launch is for; "" for none.
    focused*: Signal[string]
      ## The waiting session the keys are on (`Down` / `Up` move it, `Enter`
      ## opens it); "" before the first move.
    requestedSession*: Signal[string]
    requests*: Signal[int]
    lastNotice: Signal[tuple[line: string, failed: bool]]
      ## Agent Harbor's answer to the last launch, kept under the form for
      ## the next one.

method submitAction*(source: LaunchAnswers; action: OperatorAction;
                     done: ActionCallback) =
  let after = source.answered
  source.inner.submitAction(action, proc(answer: DataResult[ActionReceipt]) =
    done(answer)
    if after != nil: after())

proc launchTargets(title, manager: string): seq[RouteTarget] =
  ## What a launch from the control center can reach: the manager it goes
  ## through, and neither a session (the tab is no session's window) nor a
  ## UI action (it performs none).
  @[RouteTarget(kind: tkSession, available: false,
                unavailableReason: "The control center has no agent session"),
    RouteTarget(kind: tkManager, id: manager,
                label: (if title.len > 0: managerLabel(title) else: NoInitiativeManagerLabel),
                available: true),
    RouteTarget(kind: tkUiAction, available: false,
                unavailableReason: "The control center performs no UI actions")]

proc newControlCenterVM*(source: AgentHarborDataSource; router: InstructionRouter;
                         actions: AgentHarborDataSource; planDate = "2026-01-01";
                         narrowBelow = ControlCenterNarrowBelow;
                         policy = tabStripSessionPolicy()): ControlCenterVM =
  ## The control center over `source` (the initiatives and the listing),
  ## sending launches through `actions` (the data source every delivery to
  ## Agent Harbor goes through; the same source in production). `router` is
  ## the composer's; the operator's chosen intent overrides its intent. The
  ## form starts on `New task` for no initiative. Nothing loads until `load`.
  withViewModel proc(disposeRoot: proc()): ControlCenterVM =
    let feeds = newSourceFeeds()
    let vm = ControlCenterVM(source: source, policy: policy, feeds: feeds,
      directory: initSessionDirectory(), narrowBelow: narrowBelow,
      revision: createSignal(0), launchFor: createSignal(""),
      focused: createSignal(""),
      requestedSession: createSignal(""), requests: createSignal(0),
      lastNotice: createSignal((line: "", failed: false)))
    vm.initiatives = newInitiativesVM(source)
    let answers = LaunchAnswers(label: actions.label, inner: actions)
    vm.composer = newOmniboxComposerVM(router, answers, launchTargets("", ""),
                                       planDate = planDate)
    let target = vm
    answers.answered = proc() =
      # The launch answered: keep the answer under the form and make the
      # form ready for the next one (the instruction kept on a failure).
      let d = target.composer.draft
      if d.phase notin {cpSent, cpSendFailed} or d.sentIntent == riInstruct: return
      let (line, failed, pending) = launchLine(ComposerRecord(text: d.sentText,
        intent: d.sentIntent, deliveries: d.deliveries))
      if pending: return
      target.lastNotice.val = (line: line, failed: failed)
      target.composer.setText(if failed: d.sentText else: "")
      if not failed:
        # What named the launch just made goes with it (its branch, its
        # session's name, an initiative's goal and plan file); where and how
        # to launch stays for the next one.
        var o = target.composer.launch
        o.branch = ""
        o.sessionName = ""
        target.composer.updateLaunch(o)
        var f = target.composer.initiative
        f.goal = ""
        f.planPath = ""
        target.composer.updateInitiative(f)
      target.composer.optionsOpen.val = true
    vm.composer.chooseIntent(riLaunchTask)
    vm.composer.open()
    onCleanup proc() =
      feeds.close()
      vm.initiatives.dispose()
      vm.composer.dispose()
    vm

proc bump(vm: ControlCenterVM) =
  vm.revision.val = vm.revision.val + 1

# ---------------------------------------------------------------------------
# The sessions the waiting list follows
# ---------------------------------------------------------------------------

proc applyFleetFrame*(vm: ControlCenterVM; frame: FleetFrame): bool =
  ## A fleet frame from the source, folded into the sessions the waiting list
  ## is taken from. True when it changed them.
  if not vm.directory.followFrame(vm.nowMs, frame): return false
  vm.bump()
  true

proc resume*(vm: ControlCenterVM; event: ResumeEvent): bool =
  ## The operator's input reached a waiting session: it leaves the list.
  if not vm.directory.resumeSession(event.sessionId, event.atMs): return false
  vm.nowMs = max(vm.nowMs, event.atMs)
  vm.bump()
  true

proc feeds*(vm: ControlCenterVM): SourceFeeds =
  ## The waiting list's subscriptions to the source (`frames`, `resumes`,
  ## `resets`); the Initiatives panel keeps its own (`initiatives.feeds`).
  vm.feeds

proc restartWaiting(vm: ControlCenterVM)

proc loadWaiting(vm: ControlCenterVM) =
  inc vm.loadToken
  let token = vm.loadToken
  let target = vm
  vm.feeds.frames.openFleetFrames(vm.source, proc(frame: FleetFrame): bool =
    target.applyFleetFrame(frame))
  vm.feeds.resumes.openResumes(vm.source, proc(event: ResumeEvent): bool =
    target.resume(event))
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restartWaiting()
    true)
  vm.source.loadFleet proc(answer: DataResult[FleetSnapshot]) =
    if token != target.loadToken or not answer.ok: return
    target.directory = initSessionDirectory(answer.value.sessions)
    target.nowMs = answer.value.capturedAtMs
    target.bump()

proc restartWaiting(vm: ControlCenterVM) =
  ## The source started over (a playback seeking back): the sessions go with
  ## the data they came from, and the listing is read again.
  vm.directory = initSessionDirectory()
  vm.nowMs = 0
  vm.bump()
  vm.loadWaiting()

proc load*(vm: ControlCenterVM) =
  ## Loads the Initiatives panel and the waiting sessions.
  vm.initiatives.load()
  vm.loadWaiting()

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc state*(vm: ControlCenterVM): AsyncState =
  ## Tracked: the overview's state, the initiatives' (loading, ready, error).
  vm.initiatives.state.val

proc error*(vm: ControlCenterVM): string =
  vm.initiatives.error.val

proc isEmptyFleet*(vm: ControlCenterVM): bool =
  ## Tracked: the initiatives answered, and there are none.
  vm.initiatives.state.val == asReady and vm.initiatives.rows.len == 0

proc layoutFor*(vm: ControlCenterVM; width: int): ControlCenterLayout =
  ## Two columns, or one (launch first) below `narrowBelow`.
  layoutFor(width, vm.narrowBelow)

proc waiting*(vm: ControlCenterVM): seq[WaitingRow] =
  ## Tracked: the sessions that wait for the operator, in inbox order (on a
  ## question first, then ended turns; the longest waiting first).
  discard vm.revision.val
  for i in inboxOrder(vm.directory.sessions, vm.policy.status):
    let session = vm.directory.sessions[i]
    var item = sessionItemOf(session, vm.nowMs, vm.policy)
    if item.initiativeTitle.len == 0 and session.planId.len > 0:
      item.initiativeTitle = vm.initiatives.initiative(session.planId).title
    result.add WaitingRow(item: item, words: item.pie.label)

proc mode*(vm: ControlCenterVM): LaunchMode =
  ## Tracked: what the form starts, a task or an initiative.
  modeOf(vm.composer.chosenIntent)

proc launchChoices*(vm: ControlCenterVM): seq[InitiativeChoice] =
  ## Tracked: what a launch can be for: no initiative, then every initiative
  ## in the Initiatives panel's order.
  let chosen = vm.launchFor.val
  result.add InitiativeChoice(id: "", title: noInitiativeLabel(), chosen: chosen.len == 0)
  for row in vm.initiatives.rows:
    result.add InitiativeChoice(id: row.id, title: row.title, chosen: row.id == chosen)

proc launchForTitle*(vm: ControlCenterVM): string =
  ## Tracked: the title of the initiative the next launch is for; "" none.
  let id = vm.launchFor.val
  if id.len == 0: "" else: vm.initiatives.initiative(id).title

proc launchNotice*(vm: ControlCenterVM): tuple[line: string, failed, pending: bool] =
  ## Tracked: `Launching…` while a launch waits for Agent Harbor; then its
  ## answer (`Started on hub-a · …`, `Could not launch: …`), kept until the
  ## next launch; empty before the first.
  let d = vm.composer.draft
  if d.phase == cpSending and d.sentIntent != riInstruct:
    return launchLine(ComposerRecord(text: d.sentText, intent: d.sentIntent,
                                     deliveries: d.deliveries))
  let last = vm.lastNotice.val
  (last.line, last.failed, false)

proc recent*(vm: ControlCenterVM): seq[RecentLaunch] =
  ## Tracked: the recent launches, newest first.
  recentLaunches(vm.composer.draft.recent)

# ---------------------------------------------------------------------------
# Acting
# ---------------------------------------------------------------------------

proc newTask*(vm: ControlCenterVM) =
  ## `New task`: the launch form.
  vm.composer.chooseIntent(riLaunchTask)

proc newInitiative*(vm: ControlCenterVM) =
  ## `New initiative`: the initiative form.
  vm.composer.chooseIntent(riNewInitiative)

proc chooseInitiative*(vm: ControlCenterVM; id: string) =
  ## The initiative the next launch is for ("" for none): its manager
  ## becomes the launch's destination. An id the panel does not hold is
  ## refused rather than launching through no manager under its name.
  if id == vm.launchFor.val: return
  var title, manager = ""
  if id.len > 0:
    let initiative = vm.initiatives.initiative(id)
    if initiative.id.len == 0: return
    title = initiative.title
    manager = initiative.manager
  vm.launchFor.val = id
  vm.composer.setTargets(launchTargets(title, manager))

proc openSession*(vm: ControlCenterVM; id: string) =
  ## Asks the host to show a waiting session's tab.
  if id.len == 0: return
  vm.requestedSession.val = id
  vm.requests.val = vm.requests.val + 1

proc moveFocus*(vm: ControlCenterVM; delta: int): bool =
  ## `Down` / `Up` over the waiting sessions: the next or previous row,
  ## wrapping; the first (or last) when none is focused, or the focused one
  ## stopped waiting. False when nothing waits.
  var ids: seq[string]
  for row in vm.waiting: ids.add row.item.id
  if ids.len == 0 or delta == 0: return false
  let at = ids.find(vm.focused.val)
  let next =
    if at < 0: (if delta > 0: 0 else: ids.high)
    else: ((at + delta) mod ids.len + ids.len) mod ids.len
  vm.focused.val = ids[next]
  true

proc openFocused*(vm: ControlCenterVM): bool =
  ## `Enter`: opens the focused waiting session (the first when none is
  ## focused). False when nothing waits.
  if vm.focused.val.len == 0 and not vm.moveFocus(1): return false
  var still = false
  for row in vm.waiting:
    if row.item.id == vm.focused.val: still = true
  if not still and not vm.moveFocus(1): return false
  vm.openSession(vm.focused.val)
  true
