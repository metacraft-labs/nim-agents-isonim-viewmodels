## `OmniboxComposerVM`: the omnibox as the composer for every agent
## instruction -- a COMPOSER SHEET pattern: a one-line field, and under it a
## sheet that shows the instruction's context, where the routing agent sends
## it and what it cites, the destinations the operator can choose instead,
## the launch or initiative form when one applies, and each delivery's
## result.
##
## The domain is nim-agents' `instruction_composer` (`ComposerDraft`): the
## flow, what may be cited, redirects, deliveries and the forms' validation.
## This viewmodel publishes the draft through signals and adds what only
## the reader sets: whether the omnibox is open, which sections of the sheet
## are open, the gaze state. It talks to two seams: the front-end's own
## `InstructionRouter` (the routing agent, and the agent that performs UI
## actions), and the Agent Harbor data source, through which every delivery
## to Agent Harbor goes as an `OperatorAction` (`submitAction`: an
## instruction to the session or to a manager, a launch, a new initiative, a
## stop), the one way anything is asked of a server.
##
## **One step.** While the operator types, every change of the text asks
## the router again (`setText`), and its decision is shown live: the
## destination it chose and the context it cites, as chips the operator can
## cite or uncite, and destinations the operator can choose instead. `Enter`
## (`submit`) sends at once to the destination shown; pressed before the
## router has answered (and with no destination chosen by the operator), it
## sends as soon as the decision arrives. After sending, `sendAgain`
## redirects: the instruction is sent to another destination as well.
##
## **Keys** a host binds: `Enter` is `submit` (send; retry a failed
## delivery), `Shift+Enter` a newline in the text (`setText`), `↑` / `↓`
## `moveSelection` (another destination before sending), `Esc` `close` (the
## draft is kept and restored by the next `open`).
##
## **Answers** from the router are applied only while the draft is still in
## the step they answer: a route answer that arrives after the instruction
## was edited, or any answer after `dispose`, changes nothing.
##
## **Units.** The sheet's width rule takes the renderer's unit (pixels on
## the web and GPUI, cells in a terminal): `maxSheetWidth`, `sheetInset` and
## `narrowBelow` are fields a front-end sets together, in one unit.

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/agent_harbor/operator_actions
import ./instruction_router

export instruction_router, operator_actions, viewmodel, signals, computation

type
  ComposerChip* = object
    item*: ContextItem
    cited*: bool        ## the decision cites it

  RecentRow* = object
    text*: string       ## the instruction's first line
    line*: string       ## `Sent to this session · also sent to …`
    failed*: bool

  StopState* = enum
    ssNone = ""
    ssStopping = "stopping"
    ssStopped = "stopped"
    ssFailed = "failed"

  OmniboxComposerVM* = ref object of ViewModel
    router: InstructionRouter
    source: AgentHarborDataSource
    draft: ComposerDraft
    routeToken: int
    revision*: Signal[int]
      ## Moves whenever the draft changes.
    isOpen*: Signal[bool]
    optionsOpen*: Signal[bool]     ## the launch or initiative form
    scheduleOpen*: Signal[bool]
    addContextOpen*: Signal[bool]  ## the "add context" menu
    gaze*: Signal[GazeState]
    stopState*: Signal[StopState]
    stopMessage*: Signal[string]
    agentChoices*: seq[string]
      ## The agents a launch can choose from, as the host lists them.
    executorChoices*: seq[string]
      ## The executors a launch can run on (`Executor`).
    planDate*: string
      ## The date the plan file's preview names (`YYYY-MM-DD`); a host sets
      ## today's, a story a fixed one.
    maxSheetWidth*: int
    sheetInset*: int
    narrowBelow*: int

const
  AddContextItems* = ["Upload attachment", "Files & folders",
                      "Editor selection", "Recording / trace"]
    ## The Agent Activity prompt's "add context" items, in its order.

proc newOmniboxComposerVM*(router: InstructionRouter;
                           source: AgentHarborDataSource;
                           targets: openArray[RouteTarget];
                           context: openArray[ContextItem] = [];
                           planDate = "2026-01-01"): OmniboxComposerVM =
  ## A composer over `router` (routing, UI actions) and `source` (every
  ## delivery to Agent Harbor), for a window that offers `targets` and
  ## `context`. Closed until `open`.
  let draft = initDraft(targets, context)
  withViewModel proc(dispose: proc()): OmniboxComposerVM =
    let vm = OmniboxComposerVM(router: router, source: source, draft: draft,
      revision: createSignal(0), isOpen: createSignal(false),
      optionsOpen: createSignal(false), scheduleOpen: createSignal(false),
      addContextOpen: createSignal(false), gaze: createSignal(gsOff),
      stopState: createSignal(ssNone), stopMessage: createSignal(""),
      planDate: planDate, maxSheetWidth: 640, sheetInset: 8, narrowBelow: 480)
    vm

proc routerLabel*(vm: OmniboxComposerVM): string =
  if vm.router.isNil: "" else: vm.router.label

proc bump(vm: OmniboxComposerVM) =
  vm.revision.val = vm.revision.val + 1

proc draft*(vm: OmniboxComposerVM): ComposerDraft =
  ## Tracked: the draft itself.
  discard vm.revision.val
  vm.draft

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc text*(vm: OmniboxComposerVM): string =
  discard vm.revision.val
  vm.draft.text

proc phase*(vm: OmniboxComposerVM): ComposerPhase =
  discard vm.revision.val
  vm.draft.phase

proc fieldText*(vm: OmniboxComposerVM): string =
  ## What the one-line field shows: the instruction's first line.
  discard vm.revision.val
  firstLineAndMore(vm.draft.text).first

proc moreLines*(vm: OmniboxComposerVM): string =
  ## `+2 lines` beside the field for a multi-line instruction, else "".
  discard vm.revision.val
  moreLinesLabel(firstLineAndMore(vm.draft.text).more)

proc instructionBlock*(vm: OmniboxComposerVM): string =
  ## The whole instruction, for the sheet, when the field cannot show it
  ## (more than one line); "" otherwise.
  discard vm.revision.val
  if firstLineAndMore(vm.draft.text).more > 0: vm.draft.text else: ""

proc headerLine*(vm: OmniboxComposerVM): string =
  discard vm.revision.val
  vm.draft.headerLine

proc citesLine*(vm: OmniboxComposerVM): string =
  discard vm.revision.val
  vm.draft.citesLine

proc rows*(vm: OmniboxComposerVM): seq[DestinationRow] =
  discard vm.revision.val
  vm.draft.destinationRows

proc chips*(vm: OmniboxComposerVM): seq[ComposerChip] =
  ## The context the window offers, each with whether it is cited.
  discard vm.revision.val
  let cited = vm.draft.cited
  for c in vm.draft.context:
    var isCited = false
    for x in cited:
      if x.id == c.id: isCited = true
    result.add ComposerChip(item: c, cited: isCited)

proc intent*(vm: OmniboxComposerVM): RouteIntent =
  discard vm.revision.val
  vm.draft.intentOf

proc route*(vm: OmniboxComposerVM): RouteStatus =
  ## Tracked: whether the router is deciding, has decided or failed.
  discard vm.revision.val
  vm.draft.route

proc showsForm*(vm: OmniboxComposerVM): bool =
  ## The launch or initiative form applies: the decision is a launch or a
  ## new initiative, and the manager is where it goes.
  discard vm.revision.val
  vm.draft.phase == cpComposing and vm.draft.intentOf != riInstruct

proc sendLabel*(vm: OmniboxComposerVM): string =
  discard vm.revision.val
  sendLabel(if vm.draft.phase == cpComposing: vm.draft.intentOf else: riInstruct)

proc problems*(vm: OmniboxComposerVM): seq[LaunchProblem] =
  ## Why `Enter` cannot send: the form's problems, first first.
  discard vm.revision.val
  vm.draft.sendProblems

proc canSend*(vm: OmniboxComposerVM): bool =
  ## `Enter` would send (or, while the router decides, send when routed).
  discard vm.revision.val
  let d = vm.draft
  if d.phase != cpComposing or d.text.strip.len == 0: return false
  if d.route == rsRouting and not d.operatorChose and not d.intentChosen: return true
  d.isAvailable(d.chosen) and d.sendProblems.len == 0

proc sendDisabledReason*(vm: OmniboxComposerVM): string =
  ## The first problem, as the disabled send button's reason.
  let p = vm.problems
  if p.len > 0: p[0].text else: ""

proc launch*(vm: OmniboxComposerVM): LaunchOptions =
  discard vm.revision.val
  vm.draft.launch

proc initiative*(vm: OmniboxComposerVM): NewInitiativeForm =
  discard vm.revision.val
  vm.draft.initiative

proc planPreview*(vm: OmniboxComposerVM): string =
  discard vm.revision.val
  planFilePreview(vm.draft.initiative, vm.planDate)

proc recent*(vm: OmniboxComposerVM): seq[RecentRow] =
  discard vm.revision.val
  for rec in vm.draft.recent:
    var failed = false
    for d in rec.deliveries:
      if d.state == dsFailed: failed = true
    result.add RecentRow(text: firstLineAndMore(rec.text).first,
                         line: vm.draft.deliveryLine(rec), failed: failed)

proc sentLine*(vm: OmniboxComposerVM): string =
  ## After sending: `Sent to this session · also sent to …`; "" before.
  discard vm.revision.val
  if vm.draft.deliveries.len == 0: return ""
  vm.draft.deliveryLine(ComposerRecord(text: vm.draft.sentText,
                                       deliveries: vm.draft.deliveries))

proc sheetWidthFor*(vm: OmniboxComposerVM; window: int): int =
  ## The sheet's width in a window `window` wide, in the renderer's unit:
  ## at most `maxSheetWidth`, never closer than `sheetInset` to either edge.
  max(0, min(vm.maxSheetWidth, window - 2 * vm.sheetInset))

proc isNarrow*(vm: OmniboxComposerVM; window: int): bool =
  ## A narrow window stacks a row's reason under its label and the form's
  ## fields one per line.
  window < vm.narrowBelow

# ---------------------------------------------------------------------------
# Acting
# ---------------------------------------------------------------------------

proc open*(vm: OmniboxComposerVM) =
  ## Opens the composer on the kept draft.
  vm.isOpen.val = true

proc close*(vm: OmniboxComposerVM) =
  ## Closes it; the draft (text, context, decision) is kept.
  vm.isOpen.val = false
  vm.addContextOpen.val = false

proc startRouting(vm: OmniboxComposerVM)

proc setText*(vm: OmniboxComposerVM; text: string) =
  ## Typing: the text changes, and the router is asked again for it (an
  ## answer for the old text is void).
  let before = vm.draft
  vm.draft.setText(text)
  if vm.draft != before:
    inc vm.routeToken
    vm.bump()
    vm.startRouting()

proc setTargets*(vm: OmniboxComposerVM; targets: openArray[RouteTarget]) =
  ## What the window can reach changed (its session ended, Agent Harbor
  ## became unreachable). A chosen destination that is gone falls to the
  ## first available one.
  vm.draft.targets = @targets
  if not vm.draft.isAvailable(vm.draft.chosen):
    for kind in TargetOrder:
      if vm.draft.isAvailable(kind):
        vm.draft.chosen = kind
        break
  vm.bump()

proc toggleContext*(vm: OmniboxComposerVM; id: string) =
  if vm.draft.toggleContext(id): vm.bump()

proc addContext*(vm: OmniboxComposerVM; item: ContextItem) =
  vm.addContextOpen.val = false
  if vm.draft.addContext(item): vm.bump()

proc toggleAddContext*(vm: OmniboxComposerVM) =
  vm.addContextOpen.val = not vm.addContextOpen.val

proc toggleOptions*(vm: OmniboxComposerVM) =
  vm.optionsOpen.val = not vm.optionsOpen.val

proc toggleSchedule*(vm: OmniboxComposerVM) =
  vm.scheduleOpen.val = not vm.scheduleOpen.val

proc setGaze*(vm: OmniboxComposerVM; state: GazeState;
              lookedAt = ContextItem()) =
  ## The gaze state and, while tracking, what the gaze rested on longest
  ## (a `gazeChip`). Paused offers the `Gaze paused` note; off offers no
  ## gaze chip at all.
  vm.gaze.val = state
  if not vm.draft.isBeforeSend: return
  var kept: seq[ContextItem]
  for c in vm.draft.context:
    if c.kind != ckGaze: kept.add c
  case state
  of gsOff: discard
  of gsPaused: kept.add gazePausedChip()
  of gsTracking:
    if lookedAt.id.len > 0: kept.add lookedAt
  vm.draft.context = kept
  vm.bump()

proc chooseIntent*(vm: OmniboxComposerVM; intent: RouteIntent) =
  ## The operator says what is being composed (the control center's `New
  ## task` and `New initiative`): a launch or a new initiative goes to the
  ## manager whatever the router decides, and its form opens; `riInstruct`
  ## gives the decision back to the router (`instruction_composer.chooseIntent`).
  let changed = vm.draft.chooseIntent(intent)
  # The form opens for the intent chosen, whether or not it was chosen
  # already (a press on the mode already pressed opens a folded form).
  if intent != riInstruct and vm.draft.phase == cpComposing and
      vm.draft.intentChosen and vm.draft.chosenIntent == intent:
    vm.optionsOpen.val = true
  if changed: vm.bump()

proc chosenIntent*(vm: OmniboxComposerVM): RouteIntent =
  ## Tracked: the intent the operator chose, `riInstruct` when none.
  discard vm.revision.val
  if vm.draft.intentChosen: vm.draft.chosenIntent else: riInstruct

proc updateLaunch*(vm: OmniboxComposerVM; options: LaunchOptions) =
  if not vm.draft.isBeforeSend: return
  vm.draft.launch = options
  vm.bump()

proc updateInitiative*(vm: OmniboxComposerVM; form: NewInitiativeForm) =
  if not vm.draft.isBeforeSend: return
  vm.draft.initiative = form
  vm.bump()

proc routeRequest(vm: OmniboxComposerVM): RouteRequest =
  RouteRequest(text: vm.draft.text, context: vm.draft.context,
               targets: vm.draft.targets)

proc actionFor*(vm: OmniboxComposerVM; kind: TargetKind): OperatorAction =
  ## What a delivery to `kind` asks of Agent Harbor: the instruction (after
  ## the header of what it cites) to the session or the manager, or, for the
  ## manager, a launch or a new initiative with its options. Not for a UI
  ## action, which the front-end performs.
  let d = vm.draft
  let target = d.targetOf(kind)
  let text = deliveredText(d.sentText, d.cited)
  case kind
  of tkSession: sendInstruction(target.id, text)
  of tkManager:
    case d.sentIntent
    of riInstruct: instructManager(target.id, text)
    of riLaunchTask: launchTask(text, launchParams(d.launch), managerSessionId = target.id)
    of riNewInitiative:
      startInitiative(deliveredText(if d.initiative.goal.len > 0: d.initiative.goal
                                    else: d.sentText, d.cited),
                      initiativeParams(d.initiative, vm.planDate),
                      managerSessionId = target.id)
  of tkUiAction:
    raise newException(ValueError, "a UI action is the front-end's, not an Agent Harbor action")

proc deliverTo(vm: OmniboxComposerVM; kind: TargetKind) =
  ## Delivers the sent text to `kind`, whose delivery the draft has just
  ## started: a UI action through the router, everything else through the
  ## data source as an `OperatorAction`.
  let target = vm
  vm.optionsOpen.val = false
  vm.scheduleOpen.val = false
  let settle = proc(answer: DataResult[Receipt]) =
    if target.isDisposed: return
    let changed = if answer.ok: target.draft.applyReceipt(kind, answer.value)
                  else: target.draft.applyDeliveryFailure(kind, answer.error)
    if changed: target.bump()
  if kind == tkUiAction:
    let d = vm.draft
    let action = if d.decided and d.decision.target == tkUiAction: d.decision.action else: ""
    vm.router.performUiAction(UiActionRequest(text: d.sentText, action: action,
                                              cited: d.cited), settle)
  else:
    vm.source.submitAction(vm.actionFor(kind), proc(answer: DataResult[ActionReceipt]) =
      if answer.ok: settle(success(Receipt(notice: answer.value.message)))
      else: settle(failure[Receipt](answer.error)))

proc startRouting(vm: OmniboxComposerVM) =
  if not vm.draft.beginRouting(): return
  inc vm.routeToken
  let token = vm.routeToken
  vm.bump()
  let target = vm
  vm.router.route(vm.routeRequest, proc(answer: DataResult[RoutingDecision]) =
    if target.isDisposed or token != target.routeToken: return
    let changed = if answer.ok: target.draft.applyDecision(answer.value)
                  else: target.draft.applyRouteFailure(answer.error)
    if not changed: return
    if target.draft.intentOf != riInstruct:
      target.optionsOpen.val = true
    let send = target.draft.deliveryReady
    target.bump()
    if send: target.deliverTo(target.draft.chosen))

proc submit*(vm: OmniboxComposerVM) =
  ## `Enter`: send at once to the destination shown (when the router has
  ## not answered yet, as soon as it does); retry a failed delivery.
  case vm.draft.phase
  of cpComposing:
    if not vm.draft.beginSend():
      if vm.draft.intentOf != riInstruct: vm.optionsOpen.val = true
      return
    vm.bump()
    if not vm.draft.awaitingRoute: vm.deliverTo(vm.draft.chosen)
  of cpSendFailed:
    # The delivery `retry` reset, and no other: it answers its target.
    let retried = vm.draft.retry()
    if retried.ok:
      vm.bump()
      vm.deliverTo(retried.target)
  of cpSending, cpSent: discard

proc reroute*(vm: OmniboxComposerVM) =
  ## Asks the router again for the text as it is (after a failure).
  if vm.draft.phase == cpComposing:
    vm.startRouting()

proc choose*(vm: OmniboxComposerVM; kind: TargetKind) =
  ## Redirect before sending.
  if vm.draft.choose(kind): vm.bump()

proc moveSelection*(vm: OmniboxComposerVM; delta: int) =
  ## `↑` / `↓` before sending: the next available destination in the fixed
  ## order, wrapping.
  if vm.draft.phase != cpComposing or vm.draft.text.strip.len == 0 or
      delta == 0: return
  var at = 0
  for i, kind in TargetOrder:
    if kind == vm.draft.chosen: at = i
  let step = if delta > 0: 1 else: -1
  for n in 1 .. TargetOrder.len:
    let i = ((at + step * n) mod TargetOrder.len + TargetOrder.len) mod TargetOrder.len
    if vm.draft.isAvailable(TargetOrder[i]):
      vm.choose(TargetOrder[i])
      return

proc sendAgain*(vm: OmniboxComposerVM; kind: TargetKind) =
  ## Redirect after sending: the same instruction to `kind` as well.
  if vm.draft.sendAgain(kind):
    vm.bump()
    vm.deliverTo(kind)

proc retry*(vm: OmniboxComposerVM) =
  if vm.draft.phase == cpSendFailed: vm.submit()

proc recall*(vm: OmniboxComposerVM; index: int) =
  ## A `Recent` instruction back in the field; the router is asked again.
  if vm.draft.recall(index):
    inc vm.routeToken
    vm.bump()
    vm.startRouting()

proc stop*(vm: OmniboxComposerVM) =
  ## Stops the turn the window's session runs (`Stop agent`).
  let session = vm.draft.targetOf(tkSession)
  if not (session.available and session.running): return
  if vm.stopState.val == ssStopping: return
  vm.stopState.val = ssStopping
  vm.stopMessage.val = ""
  let target = vm
  vm.source.submitAction(stopSession(session.id), proc(answer: DataResult[ActionReceipt]) =
    if target.isDisposed: return
    if answer.ok:
      target.stopState.val = ssStopped
      target.stopMessage.val = if answer.value.message.len > 0: answer.value.message
                               else: "Stopped"
      var targets = target.draft.targets
      for t in targets.mitems:
        if t.kind == tkSession: t.running = false
      target.draft.targets = targets
      target.bump()
    else:
      target.stopState.val = ssFailed
      target.stopMessage.val = "Could not stop: " & answer.error)

proc isEmptyField*(vm: OmniboxComposerVM): bool =
  ## Nothing typed: the sheet shows the hint and `Recent`.
  vm.text.strip.len == 0 and vm.phase == cpComposing
