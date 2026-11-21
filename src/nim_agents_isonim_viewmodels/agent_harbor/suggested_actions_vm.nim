## The suggested-actions block at the end of a session's timeline: an
## agent's suggested UI actions waiting on the operator, and, once decided,
## the line the timeline keeps for them. Over nim-agents'
## `suggested_actions` (`SuggestionDecision`, which holds every rule), the
## front-end's UI-action seam (`InstructionRouter.performUiAction`,
## `suggested_action_sources.nim`) and Agent Harbor's one write seam
## (`AgentHarborDataSource.submitAction`).
##
## **Approve** performs the checked actions one after another, in the
## block's order, through the performer; when every one has its outcome,
## the decision (`decideSuggestion`, `approve` and the approved ids) is sent
## to Agent Harbor. **Dismiss** performs nothing and sends `dismiss`. An
## **auto-approved** suggestion (`newSuggestedActionsVM(…, autoApproved =
## true)`) has no block: its actions are performed at once and the timeline
## keeps the line that says so. If telling Agent Harbor fails, the decision
## stands (the actions were performed) and the record says why under it.
##
## **Readings** a host draws: `shown` (the block is drawn while the
## suggestion waits or is being performed), `reasonText`, `rows`,
## `approveLabel`, `approveDisabledReason`, `approving`, and `recordLines`,
## the decided suggestion as lines of the session's timeline
## (`session_timeline_vm.TimelineLine`, item kind `ui-action`), which the
## timeline's own line renderers draw after its lines (codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## D23). Every reading is tracked through `revision`.
##
## Answers that arrive after `dispose` change nothing.

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import nim_agents/suggested_actions
import nim_agents/agent_harbor/operator_actions
import ./data_source
import ./instruction_router
import ./session_timeline_vm

export suggested_actions

type
  SuggestedActionRow* = object
    ## One action as the block lists it.
    id*: string
    description*: string
    checked*: bool
    disabled*: bool        ## the front-end cannot perform it
    reason*: string        ## why, when disabled
    dimmed*: bool          ## performable but unchecked by the operator

  SuggestedActionsVM* = ref object of ViewModel
    performer: InstructionRouter
    source: AgentHarborDataSource
    dec: SuggestionDecision
      ## The decision; readings go through `decision`, which tracks it.
    disposed: bool
    replySent: bool
    revision*: Signal[int]
      ## Moves whenever the decision changes.
    sentActions*: seq[OperatorAction]
      ## The decisions sent to Agent Harbor (a host's log, and a test's).

const
  UiActionItemKind* = "ui-action"
    ## The item kind of the record's decision line (one line, cut).
  UiActionOutcomeItemKind* = "ui-action-outcome"
    ## The item kind of the record's level-1 lines (an outcome, a failed
    ## reply): words that wrap, as the timeline's prose does.
  RecordLineIdPrefix* = "suggestion:"

proc bump(vm: SuggestedActionsVM) =
  vm.revision.val = vm.revision.val + 1

proc sendReply(vm: SuggestedActionsVM) =
  ## Tells Agent Harbor what was decided, once.
  if vm.replySent: return
  vm.replySent = true
  let d = vm.dec
  let action =
    if d.phase == spDismissed:
      decideSuggestion(d.suggestion.sessionId, d.suggestion.requestId, "dismiss")
    else:
      decideSuggestion(d.suggestion.sessionId, d.suggestion.requestId, "approve",
                       d.approvedIds)
  vm.sentActions.add action
  if vm.source.isNil: return
  let target = vm
  vm.source.submitAction(action, proc(answer: DataResult[ActionReceipt]) =
    if target.disposed: return
    if not answer.ok:
      target.dec.applyReplyFailure(answer.error)
      target.bump())

proc performApproved(vm: SuggestedActionsVM) =
  ## Asks the performer for each approved action in turn; the next is asked
  ## when the one before has its outcome, so they run in the block's order.
  let ids = vm.dec.approvedIds
  var next = 0
  for id in ids:
    if not vm.dec.outcomeOf(id)[0]: break
    inc next
  if next >= ids.len:
    vm.sendReply()
    return
  let id = ids[next]
  let action = vm.dec.actionOf(id)
  let target = vm
  if vm.performer.isNil:
    vm.dec.applyPerformFailure(id, "no front-end performer")
    vm.bump()
    vm.performApproved()
    return
  vm.performer.performUiAction(UiActionRequest(text: action.description, action: id),
    proc(answer: DataResult[Receipt]) =
      if target.disposed: return
      if answer.ok: target.dec.applyOutcome(id, answer.value)
      else: target.dec.applyPerformFailure(id, answer.error)
      target.bump()
      target.performApproved())

proc newSuggestedActionsVM*(suggestion: ActionSuggestion;
                            performer: InstructionRouter;
                            source: AgentHarborDataSource;
                            autoApproved = false;
                            vocabulary: openArray[string] = CodeTracerVocabulary): SuggestedActionsVM =
  ## The block for `suggestion`, its approved actions performed by
  ## `performer` and its decision sent through `source`. An `autoApproved`
  ## suggestion is performed at once and drawn only as its record line.
  let decision = newDecision(suggestion, vocabulary, autoApproved)
  withViewModel proc(dispose: proc()): SuggestedActionsVM =
    let vm = SuggestedActionsVM(performer: performer, source: source, dec: decision,
                                revision: createSignal(0))
    onCleanup proc() = vm.disposed = true
    if autoApproved: vm.performApproved()
    vm

proc decision*(vm: SuggestedActionsVM): SuggestionDecision =
  ## Tracked: the decision itself.
  discard vm.revision.val
  vm.dec

proc phase*(vm: SuggestedActionsVM): SuggestionPhase =
  vm.decision.phase

proc shown*(vm: SuggestedActionsVM): bool =
  ## Whether the block is drawn: while the suggestion waits, or while its
  ## approved actions are being performed.
  vm.decision.phase in {spPending, spApproving}

proc approving*(vm: SuggestedActionsVM): bool =
  vm.decision.phase == spApproving

proc reasonText*(vm: SuggestedActionsVM): string =
  vm.decision.suggestion.reason

proc sessionId*(vm: SuggestedActionsVM): string =
  vm.decision.suggestion.sessionId

proc rows*(vm: SuggestedActionsVM): seq[SuggestedActionRow] =
  ## Every action, in the agent's order.
  let d = vm.decision
  for a in d.suggestion.actions:
    let why = d.cannotPerform(a.id)
    let checked = d.isChecked(a.id)
    result.add SuggestedActionRow(id: a.id, description: a.description, checked: checked,
      disabled: why.len > 0, reason: why,
      dimmed: why.len == 0 and not checked)

proc approveLabel*(vm: SuggestedActionsVM): string =
  vm.decision.approveLabel

proc approveDisabledReason*(vm: SuggestedActionsVM): string =
  ## Why `Approve` cannot be pressed now ("" when it can): nothing checked,
  ## nothing performable, or the approved actions are being performed.
  if vm.decision.phase == spApproving: return ApprovingLabel
  vm.decision.approveDisabledReason

proc canApprove*(vm: SuggestedActionsVM): bool =
  vm.decision.canApprove

proc canDismiss*(vm: SuggestedActionsVM): bool =
  vm.decision.phase == spPending

proc toggle*(vm: SuggestedActionsVM; id: string) =
  ## Checks or unchecks an action (nothing for one CodeTracer cannot perform,
  ## or once decided).
  if vm.dec.toggle(id): vm.bump()

proc approve*(vm: SuggestedActionsVM) =
  ## Approves the checked actions and performs them; a second press while
  ## they are performed does nothing.
  if not vm.dec.beginApprove(): return
  vm.bump()
  vm.performApproved()

proc dismiss*(vm: SuggestedActionsVM) =
  if not vm.dec.dismiss(): return
  vm.bump()
  vm.sendReply()

proc recordLines*(vm: SuggestedActionsVM): seq[TimelineLine] =
  ## The decided suggestion as timeline lines, for the timeline's own
  ## renderers: the decision at level 0, each outcome (and a failed reply)
  ## at level 1. Empty while the block is shown. One line, one part (its
  ## text in its role), and the quiet `auto-approved` as a second part.
  let id = RecordLineIdPrefix & vm.decision.suggestion.requestId
  for i, rec in vm.decision.recordLines:
    var line = TimelineLine(id: id & (if i == 0: "" else: ":" & $i), kind: tlkItem,
      level: rec.level, indent: rec.level,
      itemKind: (if rec.level == 0: UiActionItemKind else: UiActionOutcomeItemKind),
      text: rec.text, textRole: rec.role,
      parts: @[LinePart(text: rec.text, role: rec.role)])
    if rec.tag.len > 0:
      line.parts.add LinePart(text: rec.tag, role: "quiet")
      line.text = rec.text & " " & rec.tag
    result.add line

proc describe*(vm: SuggestedActionsVM): string =
  ## One line naming the block's state, for a log or a test.
  result = vm.decision.describe
  if vm.decision.replyError.len > 0: result.add " reply-error=" & vm.decision.replyError
  let lines = vm.recordLines
  if lines.len > 0:
    var texts: seq[string]
    for l in lines: texts.add l.text
    result.add " record=" & texts.join(" | ")
