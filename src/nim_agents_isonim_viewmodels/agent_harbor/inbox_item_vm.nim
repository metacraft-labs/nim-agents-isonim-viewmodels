## `InboxItemVM`: one inbox item's page -- an ITEM PAGE pattern: what the
## agent asks or reports, and the form that answers it, on a page of its own
## (never a modal, and never replaced while the operator is on it).
##
## The domain is nim-agents' `inbox` (`InboxItemDetail`, `validateAnswer`)
## and `operator_actions` (the typed writes). This viewmodel publishes the
## item's page and holds the answer form:
##
## - **what the data puts in**: the load state, the item's page
##   (`detail`), the reason it cannot be loaded;
## - **what the reader sets**: the typed text, the chosen options, a
##   confirmation's decision, a sudo password (kept only until the action is
##   answered), whether the page is visible.
##
## **Answering.** `submit` builds the action the item's kind needs (an
## answer, the next instruction after an ended turn, a feedback response),
## checks it with `validateAnswer` and, only when it is valid, hands it to
## the shared `ActionTracker`, which sends it through the data source's
## `submitAction`. `choosePermission`, `decideApproval`, `cancelLogin`,
## `sendDraft` and `setPriority` are the page's buttons. The page's answer
## state (`phase`) is the tracker's state of its last action: submitting,
## answered (`Answer sent; waiting for the agent to continue.`), failed
## (`Failed to submit answer`, with the reason).
##
## **A login request** is drawn in one of its states (`loginState`,
## `loginText`): pending (the local-desktop handoff), cancelling (the
## server says so, or the operator's Cancel is in flight), completed in place
## (`Signed in to <provider> — login complete`), failed; a carry error (the
## sign-in finished but the agent could not take it up, and the request stays
## pending) is shown inline (`loginError`). When the item holds no request,
## or the operator's Cancel was confirmed (the request is withdrawn), the
## page says `No pending login requests.` (`hasLoginRequest` false). Cancel
## is offered only on a pending request with no cancel in flight
## (`canCancelLogin`); Continue only on a completed one (`canContinueLogin`),
## where it moves on from the item: the host binds it (the Inbox panel to
## its Next), since the page holds no order of its own.
##
## **Expiry.** A feedback request past its `expiresAt` is drawn with the
## `Expired` badge (`expiredBadge`, the request's state), and a submission
## to it is refused with the domain's message (`This request has expired`,
## `validation`): the badge says what the request is, the message why the
## press did nothing.
##
## **The viewing heartbeat.** While the page is visible (`setVisible`), the
## viewmodel tells the server the operator is looking at the session's
## waiting item: `markViewing` once when it becomes visible, then every
## `ViewingHeartbeatMs` on its clock, through the source's `submitAction`;
## it stops when the page is hidden or the viewmodel disposed. Without a
## clock it sends only the first.
##
## **Secrets.** A sudo password is held on the viewmodel only between
## `setPassword` and the answer to the action that carries it, and is never
## published through a signal (`passwordSet` says only whether one is
## typed).

import isonim/core/[signals, owner, clock]
import isonim/viewmodel
import nim_agents/agent_harbor/operator_actions
import ./data_source
import ./action_tracker

export data_source, action_tracker, viewmodel, signals, clock

const
  ItemLoadingNotice* = "Loading the item\xE2\x80\xA6"
  ItemErrorTitle* = "Could not load this item"
  AnswerSentText* = "Answer sent; waiting for the agent to continue."
  AnswerFailedText* = "Failed to submit answer"
  SubmittingText* = "Submitting\xE2\x80\xA6"
  ExpiredBadge* = "Expired"
  LocalSignInText* = "A sign-in window has opened on this desktop."
  CancellingSignInText* = "Cancelling sign-in\xE2\x80\xA6"
  SignInFailedText* = "Sign-in failed"
  NoLoginRequestText* = "No pending login requests."
  CancelFailedText* = "Failed to cancel the sign-in"

type
  PagePhase* = enum
    ppIdle = "idle"
    ppSubmitting = "submitting"
    ppAnswered = "answered"
    ppFailed = "failed"

  InboxItemVM* = ref object of ViewModel
    source: AgentHarborDataSource
    tracker: ActionTracker
    clock: ClockBase
    item*: InboxItemRef
    sessionId*: string
    loadToken: int
    detail: InboxItemDetail
    password: string
    lastTarget: string
    visible: bool
    timer: int
    hasTimer: bool
    heartbeats: int
    revision*: Signal[int]
      ## Moves whenever the data changes the page.
    state*: Signal[AsyncState]
    error*: Signal[string]
    unresolvable*: Signal[string]
    text*: Signal[string]
    choices*: Signal[seq[string]]
    decision*: Signal[string]
    passwordSet*: Signal[bool]
    validation*: Signal[string]
      ## Why the last press sent nothing ("" when it sent).
    focusInput*: Signal[int]
      ## Moves when a host should put the focus in the page's input.

proc stopHeartbeat(vm: InboxItemVM)

proc newInboxItemVM*(source: AgentHarborDataSource; item: InboxItemRef;
                     sessionId: string; tracker: ActionTracker = nil;
                     clock: ClockBase = nil): InboxItemVM =
  ## The page of `item` (of the session `sessionId`) over `source`; nothing
  ## loads until `load`. `tracker` is shared with the other viewmodels that
  ## send actions (a new one when nil); `clock` drives the viewing heartbeat.
  withViewModel proc(dispose: proc()): InboxItemVM =
    let vm = InboxItemVM(source: source, item: item, sessionId: sessionId,
                         tracker: (if tracker.isNil: newActionTracker() else: tracker),
                         clock: clock,
                         revision: createSignal(0), state: createSignal(asIdle),
                         error: createSignal(""), unresolvable: createSignal(""),
                         text: createSignal(""), choices: createSignal(newSeq[string]()),
                         decision: createSignal(""), passwordSet: createSignal(false),
                         validation: createSignal(""), focusInput: createSignal(0))
    # Disposing the page stops its heartbeat.
    onCleanup proc() = vm.stopHeartbeat()
    vm

proc tracker*(vm: InboxItemVM): ActionTracker = vm.tracker

proc bump(vm: InboxItemVM) =
  vm.revision.val = vm.revision.val + 1

proc load*(vm: InboxItemVM) =
  ## Loads the item's page; `asLoading` until the source answers.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  vm.unresolvable.val = ""
  let target = vm
  vm.source.loadInboxItemDetail(vm.item, proc(answer: DataResult[InboxItemDetail]) =
    if token != target.loadToken: return
    if not answer.ok:
      if answer.missing: target.unresolvable.val = answer.error
      else: target.error.val = answer.error
      target.state.val = asError
      return
    target.detail = answer.value
    if target.sessionId.len == 0: target.sessionId = answer.value.sessionId
    target.state.val = asReady
    target.bump())

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc detail*(vm: InboxItemVM): InboxItemDetail =
  ## Tracked: the item's page as loaded.
  discard vm.revision.val
  vm.detail

proc kind*(vm: InboxItemVM): InboxKind =
  discard vm.revision.val
  vm.detail.kind

proc notice*(vm: InboxItemVM): string =
  ## Tracked: what the page centres instead of its content ("" when it shows
  ## the content or an error block under `ItemErrorTitle`).
  case vm.state.val
  of asLoading: ItemLoadingNotice
  of asError: (if vm.unresolvable.val.len > 0: vm.unresolvable.val else: "")
  else: ""

proc banner*(vm: InboxItemVM): string =
  ## Tracked: a question's banner (blocked or not); "" for other kinds.
  discard vm.revision.val
  if vm.detail.kind in {ikBlockedQuestion, ikUnknown}: vm.detail.bannerText else: ""

proc leadsWithSummary*(vm: InboxItemVM): bool =
  ## Tracked: the operator no longer remembers the session, so its executive
  ## summary comes first; a familiar session shows the agent's messages only.
  discard vm.revision.val
  not vm.detail.familiar and vm.detail.executiveSummary.len > 0

proc optionsNotice*(vm: InboxItemVM): string =
  ## Tracked: `No options were provided for this question.` for a choice
  ## question that has none.
  discard vm.revision.val
  if vm.detail.kind == ikBlockedQuestion and vm.detail.form in {qfSingle, qfMulti} and
      vm.detail.options.len == 0: NoOptionsText
  else: ""

proc approvalLines*(vm: InboxItemVM): seq[string] =
  ## Tracked: each queued sudo or network approval as one line
  ## (`<command> in order to: <reason>`).
  discard vm.revision.val
  for a in vm.detail.approvals: result.add a.approvalSummary

proc itemTarget(vm: InboxItemVM): string =
  ## The tracker's target of an action answering this item (`targetOf`).
  "item:" & vm.item.server & ":" & vm.item.id

proc pageTarget(vm: InboxItemVM): string =
  ## The target whose state the page shows: its last action's, or, before
  ## the page sent one, an answer to its item sent from another page of it.
  if vm.lastTarget.len > 0: vm.lastTarget else: vm.itemTarget

proc cancelEntry(vm: InboxItemVM): tuple[found: bool, entry: TrackedAction] =
  ## The last action on this item when it is a cancel of its login request
  ## (from this page or another page of the same item).
  let e = vm.tracker.entryOf(vm.itemTarget)
  (e.status != astIdle and e.action.kind == oaCancelLogin, e)

proc hasLoginRequest*(vm: InboxItemVM): bool =
  ## Tracked: the page has a login request to show: the item is a login
  ## request, it names one, and the operator's Cancel of it was not
  ## confirmed (a withdrawn request is gone).
  discard vm.revision.val
  if vm.detail.kind != ikLoginRequest or vm.detail.login.requestId.len == 0:
    return false
  let c = vm.cancelEntry
  not (c.found and c.entry.status == astConfirmed)

proc loginState*(vm: InboxItemVM): LoginState =
  ## Tracked: the login request's state as the page draws it: the server's,
  ## except `lsCancelling` while the operator's Cancel of a pending request
  ## is in flight.
  discard vm.revision.val
  let c = vm.cancelEntry
  if vm.detail.login.state == lsPending and c.found and c.entry.status == astSubmitting:
    lsCancelling
  else: vm.detail.login.state

proc loginText*(vm: InboxItemVM): string =
  ## Tracked: the login request's state line: the local-desktop handoff (a
  ## remote view's prompt), `Cancelling sign-in…`, `Signed in to <provider> —
  ## login complete`, `Sign-in failed`; `No pending login requests.` for a
  ## login item with no request; "" for another kind.
  discard vm.revision.val
  if vm.detail.kind != ikLoginRequest: return ""
  if not vm.hasLoginRequest: return NoLoginRequestText
  let login = vm.detail.login
  case vm.loginState
  of lsPending: (if login.mode == lmLocalDesktop: LocalSignInText else: login.prompt)
  of lsCancelling: CancellingSignInText
  of lsCompleted: "Signed in to " & login.provider & " \xE2\x80\x94 login complete"
  of lsFailed: SignInFailedText

proc loginError*(vm: InboxItemVM): string =
  ## Tracked: the error shown inline under the request: a pending request's
  ## carry error, or why a sign-in failed; "" otherwise.
  if not vm.hasLoginRequest: return ""
  case vm.loginState
  of lsPending, lsFailed: vm.detail.login.error
  of lsCancelling, lsCompleted: ""

proc canCancelLogin*(vm: InboxItemVM): bool =
  ## Tracked: Cancel is offered: a pending request (a carry error keeps it
  ## pending) whose cancel is not in flight.
  vm.state.val == asReady and vm.hasLoginRequest and vm.loginState == lsPending

proc canContinueLogin*(vm: InboxItemVM): bool =
  ## Tracked: Continue is offered: the login request completed (the sign-in
  ## is confirmed in place), so the operator can move on from it. It sends
  ## nothing; what moving on means is the host's (`Next` in the Inbox panel).
  vm.state.val == asReady and vm.hasLoginRequest and vm.loginState == lsCompleted

proc isExpired*(vm: InboxItemVM; nowMs: int64): bool =
  ## Tracked: a feedback request past its deadline.
  discard vm.revision.val
  vm.detail.kind == ikAsyncFeedback and vm.detail.feedback.isExpired(nowMs)

proc expiredBadge*(vm: InboxItemVM; nowMs: int64): string =
  ## Tracked: `Expired` for a feedback request past its deadline, "" otherwise.
  if vm.isExpired(nowMs): ExpiredBadge else: ""

proc phase*(vm: InboxItemVM): PagePhase =
  ## Tracked: the state of the page's last action (or of the last answer to
  ## its item, when this page has sent none).
  discard vm.revision.val
  case vm.tracker.statusOf(vm.pageTarget)
  of astIdle: ppIdle
  of astSubmitting: ppSubmitting
  of astConfirmed: ppAnswered
  of astFailed: ppFailed

proc phaseText*(vm: InboxItemVM): string =
  ## Tracked: the line under the form for the page's last action. A login
  ## request's Cancel has none while it is in flight or once it is confirmed
  ## (the request's own line says `Cancelling sign-in…`, then `No pending
  ## login requests.`), and `Failed to cancel the sign-in` when refused.
  let entry = vm.tracker.entryOf(vm.pageTarget)
  let cancel = entry.status != astIdle and entry.action.kind == oaCancelLogin
  case vm.phase
  of ppIdle: ""
  of ppSubmitting: (if cancel: "" else: SubmittingText)
  of ppAnswered: (if cancel: "" else: AnswerSentText)
  of ppFailed:
    let head = if cancel: CancelFailedText else: AnswerFailedText
    if entry.reason.len > 0: head & ": " & entry.reason else: head

proc heartbeats*(vm: InboxItemVM): int =
  ## How many viewing heartbeats the page has sent.
  vm.heartbeats

proc isVisible*(vm: InboxItemVM): bool = vm.visible

# ---------------------------------------------------------------------------
# The form
# ---------------------------------------------------------------------------

proc setText*(vm: InboxItemVM; text: string) =
  vm.text.val = text
  vm.validation.val = ""

proc toggleChoice*(vm: InboxItemVM; optionId: string) =
  ## A multi-choice option on or off; a single choice replaces the choice.
  var chosen = vm.choices.val
  if vm.detail.form == qfSingle and vm.detail.kind != ikAsyncFeedback:
    chosen = if optionId in chosen: @[] else: @[optionId]
  else:
    let at = chosen.find(optionId)
    if at >= 0: chosen.delete(at) else: chosen.add optionId
  vm.choices.val = chosen
  vm.validation.val = ""

proc setDecision*(vm: InboxItemVM; decision: string) =
  ## A confirmation's `approve` or `reject`.
  vm.decision.val = decision
  vm.validation.val = ""

proc setPassword*(vm: InboxItemVM; password: string) =
  ## The sudo password typed into an approval; kept until its action is
  ## answered.
  vm.password = password
  vm.passwordSet.val = password.len > 0

proc nowMs(vm: InboxItemVM): int64 =
  if vm.clock.isNil: 0'i64 else: int64(vm.clock.now)

proc send(vm: InboxItemVM; action: OperatorAction): bool =
  ## Hands `action` to the tracker; the password is forgotten once the
  ## source answers.
  vm.validation.val = ""
  vm.lastTarget = action.targetOf
  let target = vm
  result = vm.tracker.submit(vm.source, action, proc(entry: TrackedAction) =
    target.password = ""
    target.passwordSet.val = false
    target.bump())
  vm.bump()

proc submit*(vm: InboxItemVM; nowMs = -1'i64): bool =
  ## Sends the form's answer: an answer to a question, the next instruction
  ## after an ended turn, a response to a feedback request. False, and
  ## nothing is sent, when the form is not valid (`validation` says why),
  ## when the page has not loaded, or while the item's last action is still
  ## submitting. `nowMs` is the moment expiry is judged at (the clock's when
  ## -1).
  if vm.state.val != asReady: return false
  let now = if nowMs >= 0: nowMs else: vm.nowMs
  let d = vm.detail
  let answer = Answer(text: vm.text.val, choices: vm.choices.val,
                      decision: vm.decision.val)
  let problem = validateAnswer(d, answer, now)
  if problem.len > 0:
    vm.validation.val = problem
    return false
  let action =
    case d.kind
    of ikEndedTurn:
      sendInstruction(vm.sessionId, answer.text, itemId = vm.item.id,
                      server = vm.item.server)
    of ikAsyncFeedback:
      respondFeedback(d.feedback.taskId, d.feedback.id, answer.text, answer.choices,
                      answer.decision, sessionId = vm.sessionId, itemId = vm.item.id,
                      server = vm.item.server)
    else:
      answerQuestion(vm.sessionId, d.requestId, answer.text, answer.choices,
                     answer.decision, itemId = vm.item.id, server = vm.item.server)
  vm.send(action)

proc choosePermission*(vm: InboxItemVM; optionId: string): bool =
  ## One of the agent's permission options (`allow_once`, …).
  if vm.state.val != asReady: return false
  var known = false
  for o in vm.detail.permissionOptions:
    if o.id == optionId: known = true
  if not known:
    vm.validation.val = "Unknown option: " & optionId
    return false
  vm.send(decidePermission(vm.sessionId, vm.detail.requestId, optionId,
                           itemId = vm.item.id, server = vm.item.server))

proc decideApproval*(vm: InboxItemVM; requestId: string;
                     decision: ApprovalDecision): bool =
  ## Approves (for once or for the session) or denies one queued sudo or
  ## network approval; a sudo approval carries the typed password.
  if vm.state.val != asReady: return false
  for a in vm.detail.approvals:
    if a.requestId == requestId:
      let password = if a.scope == asSudo and decision != adDeny: vm.password else: ""
      return vm.send(operator_actions.decideApproval(vm.sessionId, requestId, decision,
                                                     a.scope, password,
                                                     itemId = vm.item.id,
                                                     server = vm.item.server))
  vm.validation.val = "Unknown approval: " & requestId
  false

proc cancelLogin*(vm: InboxItemVM): bool =
  ## Withdraws the login request. False, and nothing is sent, unless Cancel
  ## is offered (`canCancelLogin`).
  if not vm.canCancelLogin: return false
  vm.send(operator_actions.cancelLogin(vm.sessionId, vm.detail.login.requestId,
                                       itemId = vm.item.id, server = vm.item.server))

proc sendDraft*(vm: InboxItemVM): bool =
  ## Sends the draft a manager prepared, as it is: to a feedback request as
  ## its response (the request is the feedback's, not the session's), to a
  ## question as its answer.
  if vm.state.val != asReady or not vm.detail.draft.present: return false
  let d = vm.detail
  if d.kind == ikAsyncFeedback:
    return vm.send(respondFeedback(d.feedback.taskId, d.feedback.id, d.draft.text,
                                   d.draft.choices, sessionId = vm.sessionId,
                                   itemId = vm.item.id, server = vm.item.server))
  vm.send(operator_actions.sendDraft(vm.sessionId, d.requestId, d.draft.text,
                                     d.draft.choices, itemId = vm.item.id,
                                     server = vm.item.server))

proc setPriority*(vm: InboxItemVM; priority: InboxPriority): bool =
  ## The session's priority (keys `1`-`4`, or the menu).
  vm.send(operator_actions.setPriority(vm.sessionId, $priority, server = vm.item.server))

# ---------------------------------------------------------------------------
# The viewing heartbeat
# ---------------------------------------------------------------------------

proc beat(vm: InboxItemVM) =
  inc vm.heartbeats
  vm.source.submitAction(markViewing(vm.sessionId, vm.item.server),
                         proc(answer: DataResult[ActionReceipt]) = discard)

proc scheduleBeat(vm: InboxItemVM) =
  if vm.clock.isNil: return
  let target = vm
  vm.timer = vm.clock.schedule(proc() =
    target.hasTimer = false
    if not target.visible: return
    target.beat()
    target.scheduleBeat(), float64(ViewingHeartbeatMs))
  vm.hasTimer = true

proc stopHeartbeat(vm: InboxItemVM) =
  vm.visible = false
  if vm.hasTimer:
    vm.clock.cancel(vm.timer)
    vm.hasTimer = false

proc setVisible*(vm: InboxItemVM; visible: bool) =
  ## The host shows or hides the page: visible starts the heartbeat (one at
  ## once, then one every `ViewingHeartbeatMs`), hidden stops it.
  if visible == vm.visible: return
  if visible:
    vm.visible = true
    vm.beat()
    vm.scheduleBeat()
  else:
    vm.stopHeartbeat()
