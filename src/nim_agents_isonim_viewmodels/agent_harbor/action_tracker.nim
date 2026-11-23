## `ActionTracker`: the operator's submitted actions and what became of each
## -- idle, submitting, confirmed, failed with the reason -- shared by the
## viewmodels that send actions (the Changes panel, the inbox, an inbox
## item's page), so a press made on one surface shows the same state on
## every surface that names the same target.
##
## An action's state moves only on the source's answer to
## `AgentHarborDataSource.submitAction`: `submitting` until it answers,
## `confirmed` when it answered with a receipt, `failed` with the source's
## reason otherwise. A source that never answers leaves the action
## `submitting`. Nothing here decides that an action worked.
##
## **One action in flight per target** (`targetOf`: an inbox item, a spec
## card, a session's priority, its viewing heartbeat): a second press on a
## target whose action is still submitting is refused and sends nothing.
##
## **Secrets.** The tracker keeps each action with its secrets forgotten
## (`clearSecrets`): a sudo password reaches the source once, inside the
## submitted action, and is never held here.
##
## Listeners (`listen`) are told of each action as it settles, after the
## tracker's state moved; the inbox uses this to tell its own answers from
## changes it did not cause (auto-switch moves only for the operator's own
## action).

import isonim/core/signals
import ./data_source

type
  ActionStatus* = enum
    astIdle = "idle"
    astSubmitting = "submitting"
    astConfirmed = "confirmed"
    astFailed = "failed"

  TrackedAction* = object
    target*: string
    action*: OperatorAction   ## as submitted, its secrets forgotten
    status*: ActionStatus
    reason*: string           ## astFailed: the source's reason
    message*: string          ## astConfirmed: what the receipt said, if anything

  ActionListener* = proc(entry: TrackedAction) {.closure.}

  ActionTracker* = ref object
    entries: seq[TrackedAction]
    listeners: seq[(int, ActionListener)]
    nextListener: int
    sent: int
    revision*: Signal[int]
      ## Moves whenever an action's state moves.

proc newActionTracker*(): ActionTracker =
  ActionTracker(revision: createSignal(0))

proc bump(tracker: ActionTracker) =
  tracker.revision.val = tracker.revision.val + 1

proc indexOf(tracker: ActionTracker; target: string): int =
  for i, e in tracker.entries:
    if e.target == target: return i
  -1

proc entryOf*(tracker: ActionTracker; target: string): TrackedAction =
  ## Tracked: the last action on `target` (status `astIdle` when none).
  discard tracker.revision.val
  let at = tracker.indexOf(target)
  if at < 0: TrackedAction(target: target, status: astIdle)
  else: tracker.entries[at]

proc statusOf*(tracker: ActionTracker; target: string): ActionStatus =
  ## Tracked: the state of the last action on `target`.
  tracker.entryOf(target).status

proc inFlight*(tracker: ActionTracker; target: string): bool =
  tracker.statusOf(target) == astSubmitting

proc sentCount*(tracker: ActionTracker): int =
  ## How many actions this tracker handed to a source.
  tracker.sent

proc listen*(tracker: ActionTracker; listener: ActionListener): int =
  ## Calls `listener` for each action as it settles; returns the id
  ## `unlisten` takes.
  inc tracker.nextListener
  tracker.listeners.add (tracker.nextListener, listener)
  tracker.nextListener

proc unlisten*(tracker: ActionTracker; id: int) =
  var kept: seq[(int, ActionListener)]
  for (i, l) in tracker.listeners:
    if i != id: kept.add (i, l)
  tracker.listeners = kept

proc settle(tracker: ActionTracker; entry: TrackedAction) =
  let at = tracker.indexOf(entry.target)
  if at < 0: tracker.entries.add entry else: tracker.entries[at] = entry
  tracker.bump()
  let listeners = tracker.listeners
  for (_, l) in listeners: l(entry)

proc submit*(tracker: ActionTracker; source: AgentHarborDataSource;
             action: OperatorAction;
             done: proc(entry: TrackedAction) {.closure.} = nil): bool =
  ## Hands `action` to `source` and tracks it. False, and nothing is sent,
  ## while an earlier action on the same target is still submitting. `done`
  ## is called once the source answers (never, for a source that does not).
  let target = action.targetOf
  if source.isNil or tracker.inFlight(target): return false
  var kept = action
  kept.clearSecrets()
  tracker.settle(TrackedAction(target: target, action: kept, status: astSubmitting))
  inc tracker.sent
  let t = tracker
  source.submitAction(action, proc(answer: DataResult[ActionReceipt]) =
    var entry = TrackedAction(target: target, action: kept)
    if answer.ok:
      entry.status = astConfirmed
      entry.message = answer.value.message
    else:
      entry.status = astFailed
      entry.reason = answer.error
    t.settle(entry)
    if not done.isNil: done(entry))
  true

proc clearSettled*(tracker: ActionTracker) =
  ## Forgets every settled action, keeping those still submitting: what a
  ## source's restart voids.
  var kept: seq[TrackedAction]
  for e in tracker.entries:
    if e.status == astSubmitting: kept.add e
  if kept.len != tracker.entries.len:
    tracker.entries = kept
    tracker.bump()

proc forget*(tracker: ActionTracker; target: string) =
  ## Forgets the last action on `target` unless it is still submitting
  ## (a form opened again starts idle).
  let at = tracker.indexOf(target)
  if at >= 0 and tracker.entries[at].status != astSubmitting:
    tracker.entries.delete(at)
    tracker.bump()

proc submitting*(tracker: ActionTracker): seq[TrackedAction] =
  ## Tracked: every action still submitting, in the order first sent. What
  ## a surface reads to disable the presses another surface's action still
  ## covers (a test run's start names several tests and platforms, and its
  ## target is the whole request, not one cell).
  discard tracker.revision.val
  for e in tracker.entries:
    if e.status == astSubmitting: result.add e
