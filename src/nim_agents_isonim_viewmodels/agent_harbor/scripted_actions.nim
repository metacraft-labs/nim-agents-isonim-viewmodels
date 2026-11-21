## The scripted action seam: where the prototypes' writes go instead of a
## server.
##
## Most of what the Inbox and the Changes panel are for writes to Agent
## Harbor -- answering, deciding, approving, reverting, setting a priority,
## the viewing heartbeat. The prototypes draw every one of those presses and
## send each through `AgentHarborDataSource.submitAction`. This module is the
## only implementation of that method in the repository besides the base
## (which answers that the source does not provide actions) and the state
## sources (pending: never answers; failing: answers the error):
##
## - `ActionScript`: what to answer to each action kind (`confirmed`,
##   `failed: <reason>`, or `never`, which leaves the action submitting), and
##   the record of every action received -- one line per action, as
##   `OperatorAction`'s `$` writes it, so a password is recorded as
##   `secret supplied` and never as its text;
## - `ScriptedActionSource`: the data source of the Changes and Inbox
##   prototypes. It serves given review records, change diffs, an inbox and
##   its item pages, keeps the inbox cursors per cursor name as a server
##   would (nim-agents' `cursorNext` / `cursorPrev`), and answers every
##   action from its script. When the script confirms an action, the source
##   first applies what a server would do (`effects`): an answered inbox item
##   leaves the inbox (sent as an `item.resolved` event), an approved spec
##   change turns approved, a reverted one leaves the record, a staged card
##   is applied or discarded, a priority changes.
##
## **No transport.** Nothing here, and nothing this module imports, opens a
## connection: it holds no client and no URL. The live source over
## `nim-agent-harbor` will implement the same seam; the viewmodels do not
## change when it does.

import std/[strutils, tables]
import ./data_source

type
  ReceiptRule* = enum
    rrConfirmed = "confirmed"
    rrFailed = "failed"
    rrNever = "never"         ## no answer: the action stays submitting

  ActionRule* = object
    receipt*: ReceiptRule
    reason*: string           ## rrFailed: the error the source answers
    message*: string          ## rrConfirmed: what the receipt says, if anything

  PendingAction* = object
    action*: OperatorAction   ## its secrets forgotten
    done: ActionCallback

  ActionScript* = ref object
    ## What a scripted source answers to each action, and what it received.
    rules*: seq[(OperatorActionKind, ActionRule)]
    default*: ActionRule      ## for a kind `rules` does not name: confirmed
    record*: seq[string]      ## every action received, in order (`$action`)
    pending*: seq[PendingAction]  ## the actions answered `never`

const ScriptedApprovalDate* = "2027-01-15"
  ## The date a scripted approval is recorded with (invented).

proc newActionScript*(rules: openArray[(OperatorActionKind, ActionRule)] = []): ActionScript =
  ## A script answering each kind as `rules` says, and every other kind
  ## `confirmed`.
  result = ActionScript(default: ActionRule(receipt: rrConfirmed))
  for r in rules: result.rules.add r

proc confirmed*(): ActionRule = ActionRule(receipt: rrConfirmed)
proc confirmedWith*(message: string): ActionRule =
  ## Confirmed, with what the server says back (a launch's notice).
  ActionRule(receipt: rrConfirmed, message: message)
proc failedWith*(reason: string): ActionRule = ActionRule(receipt: rrFailed, reason: reason)
proc neverAnswered*(): ActionRule = ActionRule(receipt: rrNever)

proc ruleFor*(script: ActionScript; kind: OperatorActionKind): ActionRule =
  for (k, rule) in script.rules:
    if k == kind: return rule
  script.default

proc setRule*(script: ActionScript; kind: OperatorActionKind; rule: ActionRule) =
  for r in script.rules.mitems:
    if r[0] == kind:
      r[1] = rule
      return
  script.rules.add (kind, rule)

proc answer(script: ActionScript; rule: ActionRule; action: OperatorAction;
            done: ActionCallback) =
  ## Answers `done` as `rule` says; an action answered `never` is kept,
  ## without its secrets, in `pending`, for `settle`.
  var kept = action
  kept.clearSecrets()
  case rule.receipt
  of rrConfirmed: done(success(ActionReceipt(action: kept, message: rule.message)))
  of rrFailed: done(failure[ActionReceipt](rule.reason))
  of rrNever: script.pending.add PendingAction(action: kept, done: done)

proc receive*(script: ActionScript; action: OperatorAction;
              done: ActionCallback): ReceiptRule =
  ## Records `action` and answers `done` as the script says; returns the rule
  ## applied.
  script.record.add $action
  let rule = script.ruleFor(action.kind)
  script.answer(rule, action, done)
  rule.receipt

proc settle*(script: ActionScript; index: int; ok: bool; reason = "") =
  ## Answers the `index`th action left pending: confirmed, or failed with
  ## `reason`.
  let p = script.pending[index]
  script.pending.delete(index)
  if ok: p.done(success(ActionReceipt(action: p.action)))
  else: p.done(failure[ActionReceipt](reason))

# ---------------------------------------------------------------------------
# Inbox cursors, kept as a server keeps them
# ---------------------------------------------------------------------------

type
  CursorBook* = object
    ## The inbox cursors a source keeps, one per cursor name, as a server
    ## keeps them per user.
    cursors: Table[string, InboxCursor]

proc cursorOf*(book: CursorBook; name: string): InboxCursor =
  book.cursors.getOrDefault(name)

proc place*(book: var CursorBook; name: string; cursor: InboxCursor) =
  book.cursors[name] = cursor

proc clear*(book: var CursorBook) =
  book.cursors.clear()

proc positionOf*(book: CursorBook; name: string; moved = false): CursorPosition =
  let cursor = book.cursorOf(name)
  CursorPosition(moved: moved, current: cursor.current, canPrev: cursor.canPrev)

proc move*(book: var CursorBook; name: string; order: openArray[InboxItemRef];
           direction: CursorDirection): CursorPosition =
  ## Moves the cursor `name` by the server's rule (nim-agents' `cursorNext`
  ## and `cursorPrev`): Next to the top of `order` excluding the item on
  ## screen, Previous back along the visited stack.
  var cursor = book.cursorOf(name)
  let moved =
    case direction
    of cdNext: cursorNext(order, cursor).moved
    of cdPrev: cursorPrev(cursor).moved
  book.cursors[name] = cursor
  book.positionOf(name, moved)

# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------

type
  ScriptedActionSource* = ref object of AgentHarborDataSource
    reviews*: seq[(string, TaskReview)]
      ## By task id.
    diffs*: seq[(string, string, SessionDiff)]
      ## By session id and base id.
    inbox*: InboxSnapshot
    details*: seq[InboxItemDetail]
    cursors*: CursorBook
    script*: ActionScript
    effects*: bool
      ## Whether a confirmed action changes the source's data as a server
      ## would (on by default).
    inboxSubscribers*: Subscribers[InboxEvent]
    resetSubscribers*: Subscribers[StreamReset]

proc newScriptedActionSource*(label = "scripted actions";
                              script: ActionScript = nil): ScriptedActionSource =
  ScriptedActionSource(label: label, effects: true,
                       script: (if script.isNil: newActionScript() else: script))

proc record*(source: ScriptedActionSource): seq[string] =
  ## Every action the source received, in order: the story's record.
  source.script.record

proc cursorOf*(source: ScriptedActionSource; name: string): InboxCursor =
  source.cursors.cursorOf(name)

proc setCursor*(source: ScriptedActionSource; name: string; cursor: InboxCursor) =
  ## Places the cursor `name` (a story that opens in the middle of a walk).
  source.cursors.place(name, cursor)

proc addDiff*(source: ScriptedActionSource; sessionId: string; base: DiffBase;
              diff: ChangeDiff; bases: seq[DiffBase] = @[]) =
  ## Serves `diff` as the change of `sessionId` against `base`, offering
  ## `bases` in the base selector (just `base` when empty).
  source.diffs.add (sessionId, base.id,
                    SessionDiff(diff: diff, base: base,
                                bases: (if bases.len > 0: bases else: @[base])))

method loadReviewRecord*(source: ScriptedActionSource; scope: ReviewScope;
                         done: ReviewCallback) =
  for (id, review) in source.reviews:
    if id == scope.taskId:
      done(success(review))
      return
  done(missingResult[TaskReview]("no task " & scope.taskId & " in " & source.label))

proc diffOf(source: ScriptedActionSource; sessionId, base: string): int =
  for i, (id, b, _) in source.diffs:
    if id == sessionId and b == base: return i
  -1

proc holdsSession(source: ScriptedActionSource; sessionId: string): bool =
  for (id, _, _) in source.diffs:
    if id == sessionId: return true
  false

proc fileList(diff: ChangeDiff): ChangeDiff =
  ## The file list a change read answers: every file without its hunks.
  result = diff
  for f in result.files.mitems:
    f.hunks = @[]
    f.hasHunks = false

method loadChangeDiff*(source: ScriptedActionSource; sessionId, base: string;
                       done: SessionDiffCallback) =
  let at = source.diffOf(sessionId, base)
  if at < 0:
    let what = if source.holdsSession(sessionId): "no base " & base & " for session " & sessionId
               else: "no session " & sessionId & " in " & source.label
    done(missingResult[SessionDiff](what))
    return
  var answer = source.diffs[at][2]
  answer.diff = fileList(answer.diff)
  done(success(answer))

method loadFileDiff*(source: ScriptedActionSource; sessionId, base, path: string;
                     done: FileDiffCallback) =
  let at = source.diffOf(sessionId, base)
  if at < 0:
    done(missingResult[ChangedFile]("no session " & sessionId & " in " & source.label))
    return
  let found = source.diffs[at][2].diff.specDiff(path)
  if not found.found:
    done(missingResult[ChangedFile]("the change does not touch " & path))
    return
  var file = found.file
  file.hasHunks = true
  done(success(file))

method loadInbox*(source: ScriptedActionSource; done: InboxCallback) =
  done(success(source.inbox))

method subscribeInbox*(source: ScriptedActionSource;
                       callback: FeedCallback[InboxEvent]): Subscription[InboxEvent] =
  ## Sends what the source's own effects cause and what `sendInbox` sends.
  source.inboxSubscribers.subscribe(callback)

method subscribeResets*(source: ScriptedActionSource;
                        callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  ## Accepted; the source never starts over.
  source.resetSubscribers.subscribe(callback)

proc sendInbox*(source: ScriptedActionSource;
                event: InboxEvent): seq[ProgressDelivery] =
  ## Applies one inbox event to the source's inbox (so a later `loadInbox`
  ## answers the inbox after it), then sends it to every subscriber: an item
  ## another front-end answered, an item that arrived, a new order.
  discard source.inbox.applyInboxEvent(event)
  source.inboxSubscribers.broadcast(success(event))

method loadInboxCursor*(source: ScriptedActionSource; name: string;
                        done: CursorCallback) =
  done(success(source.cursors.positionOf(name)))

method moveInboxCursor*(source: ScriptedActionSource; name: string;
                        direction: CursorDirection; done: CursorCallback) =
  done(success(source.cursors.move(name, source.inbox.orderOf, direction)))

method loadInboxItemDetail*(source: ScriptedActionSource; item: InboxItemRef;
                            done: ItemDetailCallback) =
  for d in source.details:
    if d.itemId == item.id:
      done(success(d))
      return
  done(missingResult[InboxItemDetail]("no item " & item.id & " in " & source.label))

# ---------------------------------------------------------------------------
# What a confirmed action does
# ---------------------------------------------------------------------------

proc resolveItem(source: ScriptedActionSource; server, itemId: string) =
  let target = InboxItemRef(server: server, id: itemId)
  if source.inbox.indexOf(target) < 0: return
  var order: seq[InboxItemRef]
  for r in source.inbox.orderOf:
    if r != target: order.add r
  discard source.sendInbox(InboxEvent(kind: ieResolved, target: target,
                                      hasOrder: true, order: order))

proc detailIndex(source: ScriptedActionSource; itemId: string): int =
  for i, d in source.details:
    if d.itemId == itemId: return i
  -1

proc reviewIndex(source: ScriptedActionSource; taskId: string): int =
  for i, (id, _) in source.reviews:
    if id == taskId: return i
  -1

proc applyEffects(source: ScriptedActionSource; action: OperatorAction) =
  case action.kind
  of oaAnswerQuestion, oaSendInstruction, oaDecidePermission, oaCancelLogin,
     oaRespondFeedback, oaSendDraft:
    if action.itemId.len > 0: source.resolveItem(action.server, action.itemId)
  of oaDecideApproval:
    # An item may hold several approvals; it leaves the inbox with its last.
    let d = source.detailIndex(action.itemId)
    var left = 0
    if d >= 0:
      var kept: seq[ApprovalRequest]
      for a in source.details[d].approvals:
        if a.requestId != action.requestId: kept.add a
      source.details[d].approvals = kept
      left = kept.len
    if left == 0 and action.itemId.len > 0:
      source.resolveItem(action.server, action.itemId)
  of oaSetPriority:
    for item in source.inbox.items.mitems:
      if item.session.id == action.sessionId and item.server == action.server:
        item.priority = parsePriority(action.priority)
        item.effectivePriority = item.priority
        discard source.inboxSubscribers.broadcast(success(InboxEvent(kind: ieUpdated,
                                                                     item: item)))
  of oaApproveSpecChange, oaRevertSpecChange, oaApplyStaged, oaDiscardStaged:
    let r = source.reviewIndex(action.taskId)
    if r < 0: return
    var review = source.reviews[r][1]
    case action.kind
    of oaApproveSpecChange:
      for m in review.record.milestones.mitems:
        for c in m.specChanges.mitems:
          if c.spec == action.specPath and
              (action.milestoneId.len == 0 or m.id == action.milestoneId):
            c.approval = SpecApproval(state: apApproved, date: ScriptedApprovalDate,
                                      who: "operator", feedbackId: action.requestId)
      var requests: seq[SpecApprovalRequest]
      for q in review.approvalRequests:
        if q.feedbackId != action.requestId: requests.add q
      review.approvalRequests = requests
    of oaRevertSpecChange:
      for m in review.record.milestones.mitems:
        var kept: seq[SpecChange]
        for c in m.specChanges:
          if not (c.spec == action.specPath and
                  (action.milestoneId.len == 0 or m.id == action.milestoneId)):
            kept.add c
        m.specChanges = kept
    of oaApplyStaged:
      for c in review.record.stagedCards.mitems:
        if c.path == action.specPath: c.staged = false
    of oaDiscardStaged:
      var kept: seq[TierCard]
      for c in review.record.stagedCards:
        if c.path != action.specPath: kept.add c
      review.record.stagedCards = kept
    else: discard
    source.reviews[r][1] = review
  of oaRequestSpecChanges, oaMarkViewing, oaInstructManager, oaLaunchTask,
     oaStartInitiative, oaStopSession, oaDecideSuggestion:
    discard   # recorded; nothing a reader sees changes

method submitAction*(source: ScriptedActionSource; action: OperatorAction;
                     done: ActionCallback) =
  ## Records the action and answers from the script. A confirmed action's
  ## effects are applied first, as a server makes a change and then answers
  ## for it: a read after the receipt sees the change, and the inbox event
  ## it causes reaches a subscriber before the receipt does.
  source.script.record.add $action
  let rule = source.script.ruleFor(action.kind)
  if rule.receipt == rrConfirmed and source.effects: source.applyEffects(action)
  source.script.answer(rule, action, done)

proc describeRecord*(source: ScriptedActionSource): string =
  ## The record, one action per line.
  source.script.record.join("\n")
