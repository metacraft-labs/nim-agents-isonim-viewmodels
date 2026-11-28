## `InboxVM`: the operator's inbox in the server's order -- an INBOX LIST
## pattern with Previous and Next: one row per item that waits for the
## operator, the count in the chrome, and a cursor that walks them.
##
## The domain is nim-agents' `inbox`: the items as served, `applyInboxEvent`
## (which keeps the order each event carries), the words and chips. This
## viewmodel publishes them and adds no order of its own:
##
## - **The server orders; this viewmodel never does.** `items` is the
##   snapshot's order after every event, unchanged.
## - **The server keeps the cursor, and a press never waits for it.** The
##   inbox is read with the cursor `cursorName` and the targets of its next
##   presses (`loadInboxRead`). `next` and `prev` switch at once to the first
##   target the inbox still lists (nim-agents' `FastCursor`), and post the
##   move behind the switch (`postInboxCursor`, with the version held and the
##   item switched to). A press beyond the targets held waits for its answer
##   and shows as pending (`cursorPending`). Answers and the stream's notices
##   reconcile: the server's targets and version are taken, and the item on
##   screen moves only for a press that waited, or for a move made elsewhere
##   while this viewmodel has nothing in flight. The viewmodel keeps no order
##   and no visited stack. Previous wraps to the last item, so `canPrev` is
##   true whenever the inbox holds an item. A second viewmodel on the same
##   cursor name joins the walk where it is (its read on load) and follows it
##   (the notices).
## - **Sessions are tabs.** A step or `open` publishes the item's session on
##   `requestedSession` (with `requests` moving each time), which a host
##   turns into activating, or opening, the session's tab.
## - **Auto-switch** (`autoSwitch`, off by default): when the item on screen
##   leaves the inbox because of the operator's own action -- an action on
##   it the shared `ActionTracker` saw confirmed -- the viewmodel steps to
##   the next item and asks the host to focus its input (`focusRequests`).
##   It never moves for a change the operator did not cause (an item answered
##   elsewhere), never while the operator is typing (`typing`, set by the
##   host), and stops at the end of the inbox. The move is decided once, when
##   the item leaves: a move not made then (auto-switch off, the operator
##   typing, the end of the inbox) is dropped, never made later on some other
##   change.
##
## What the data puts in (the snapshot, the cursor, the operator's own
## answer awaiting auto-switch, the item pages) is cleared on `restart`; what the reader
## sets (auto-switch, typing) is kept.
##
## **Pages.** With `showPages` on, the viewmodel keeps an `InboxItemVM` for
## the item on screen (`page`), replaced when the cursor moves, visible while
## `pagesVisible` is on (its viewing heartbeat runs only then). With items
## waiting but none on screen, the page's place holds a hint
## (`wantsItemHint`); the viewmodel never puts an item on screen to fill it.

import isonim/core/[signals, owner, clock]
import isonim/viewmodel
import ./data_source
import ./source_feed
import ./action_tracker
import ./inbox_item_vm

export data_source, action_tracker, inbox_item_vm, viewmodel, signals

const
  InboxPanelTitle* = "Inbox"
  InboxLoadingNotice* = "Loading the inbox\xE2\x80\xA6"
  InboxErrorTitle* = "Could not load the inbox"

type
  InboxVM* = ref object of ViewModel
    source: AgentHarborDataSource
    tracker: ActionTracker
    clock: ClockBase
    cursorName*: string
    feeds: SourceFeeds
    loadToken: int
    listener: int
    snapshot: InboxSnapshot
    fast: FastCursor
      ## The cursor as this viewmodel holds it: the item on screen, the
      ## targets of the next presses and the posts in flight.
    readToken: int
      ## Moves on every read, so an older read's answer is dropped.
    resyncWhileLoading: bool
      ## The stream resynced before the first read answered. That read may
      ## have been served before the stream connected, so whatever changed
      ## in between is read once the load lands.
    stepped: bool
      ## The item on screen was reached through Next or Previous (the
      ## explanation strip shows while it was).
    ownAnswer: InboxItemRef
      ## The item on screen when an action of the operator's own on it was
      ## confirmed, until auto-switch has decided on it or the cursor moves
      ## (none otherwise).
    seen: seq[(InboxItemRef, string)]
      ## The session of every item the inbox has held, so a step back to an
      ## item that has left still names its session's tab.
    loadStartedMs: int64
    moves: int
    showPages*: bool
    pagesVisible: bool
    currentPage: InboxItemVM
    revision*: Signal[int]
      ## Moves whenever the data changes the inbox or the cursor.
    state*: Signal[AsyncState]
    error*: Signal[string]
    cursorError*: Signal[string]
      ## Why the cursor could not be read or moved ("" when it could).
    cursorPending*: Signal[bool]
      ## A press waits for the server's answer: it went beyond the targets
      ## held (a burst, or right after the inbox changed).
    current*: Signal[InboxItemRef]
      ## The item the cursor is on (`id` empty for none), as the source says.
    autoSwitch*: Signal[bool]
    typing*: Signal[bool]
      ## The operator is typing in a text field: auto-switch holds still.
    requestedSession*: Signal[string]
    requests*: Signal[int]
      ## Moves each time a session's tab is asked for (`requestedSession`).
    focusRequests*: Signal[int]
      ## Moves when auto-switch asks the host to focus the new item's input.

proc newInboxVM*(source: AgentHarborDataSource; cursorName = "default";
                 tracker: ActionTracker = nil; clock: ClockBase = nil;
                 showPages = false): InboxVM =
  ## The inbox over `source`, walking the cursor `cursorName`; nothing loads
  ## until `load`. `tracker` is shared with the other viewmodels that send
  ## actions (a new one when nil); `clock` dates the loading line and drives
  ## the pages' heartbeat.
  withViewModel proc(disposeRoot: proc()): InboxVM =
    let feeds = newSourceFeeds()
    let vm = InboxVM(source: source, cursorName: cursorName,
                     tracker: (if tracker.isNil: newActionTracker() else: tracker),
                     clock: clock, feeds: feeds, showPages: showPages,
                     revision: createSignal(0), state: createSignal(asIdle),
                     error: createSignal(""), cursorError: createSignal(""),
                     cursorPending: createSignal(false), fast: newFastCursor(),
                     current: createSignal(InboxItemRef()),
                     autoSwitch: createSignal(false), typing: createSignal(false),
                     requestedSession: createSignal(""), requests: createSignal(0),
                     focusRequests: createSignal(0))
    onCleanup proc() =
      feeds.close()
      vm.tracker.unlisten(vm.listener)
      if not vm.currentPage.isNil:
        vm.currentPage.dispose()
        vm.currentPage = nil
    vm

proc tracker*(vm: InboxVM): ActionTracker = vm.tracker
proc feeds*(vm: InboxVM): SourceFeeds = vm.feeds

proc moveCount*(vm: InboxVM): int =
  ## How many cursor moves the viewmodel posted to its source.
  vm.moves

proc inFlight*(vm: InboxVM): int =
  ## The posts sent and not answered yet.
  vm.fast.inFlight

proc heldAhead*(vm: InboxVM): CursorAhead =
  ## The Next and Prev targets a press would switch to at once. Empty after
  ## the inbox changed or the stream resynced, until the next read answers.
  vm.fast.heldAhead

proc bump(vm: InboxVM) =
  vm.revision.val = vm.revision.val + 1

proc nowMs(vm: InboxVM): int64 =
  if vm.clock.isNil: 0'i64 else: int64(vm.clock.now)

proc itemOf(vm: InboxVM; r: InboxItemRef): tuple[found: bool, item: InboxItem] =
  let at = vm.snapshot.indexOf(r)
  if at < 0: (false, InboxItem()) else: (true, vm.snapshot.items[at])

proc rememberItem(vm: InboxVM; item: InboxItem) =
  for (r, _) in vm.seen:
    if r == item.refOf: return
  vm.seen.add (item.refOf, item.session.id)

proc remember(vm: InboxVM) =
  ## Notes the session of every item held now.
  for item in vm.snapshot.items: vm.rememberItem(item)

proc sessionOf(vm: InboxVM; r: InboxItemRef): string =
  for (seenRef, sessionId) in vm.seen:
    if seenRef == r: return sessionId
  ""

# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

proc syncPage(vm: InboxVM; sessionId: string) =
  ## Keeps `page` on the item on screen.
  if not vm.showPages: return
  let r = vm.current.val
  if not vm.currentPage.isNil and vm.currentPage.item == r: return
  if not vm.currentPage.isNil:
    vm.currentPage.dispose()
    vm.currentPage = nil
  if r.isNone: return
  vm.currentPage = newInboxItemVM(vm.source, r, sessionId, vm.tracker, vm.clock)
  vm.currentPage.load()
  if vm.pagesVisible: vm.currentPage.setVisible(true)

proc page*(vm: InboxVM): InboxItemVM =
  ## Tracked: the page of the item on screen (nil when none, or without
  ## `showPages`).
  discard vm.revision.val
  vm.currentPage

proc setPagesVisible*(vm: InboxVM; visible: bool) =
  ## The host shows or hides the item page.
  vm.pagesVisible = visible
  if not vm.currentPage.isNil: vm.currentPage.setVisible(visible)

# ---------------------------------------------------------------------------
# The cursor
# ---------------------------------------------------------------------------

proc show(vm: InboxVM; r: InboxItemRef; stepped, request, focus: bool) =
  ## Puts `r` on screen. `stepped`: reached through Next or Previous (here or
  ## on another device); `request`: ask the host for its session's tab;
  ## `focus`: and for its input.
  if r != vm.current.val:
    vm.current.val = r
    vm.stepped = stepped
    vm.ownAnswer = InboxItemRef()
  elif stepped:
    vm.stepped = true
  let sessionId = vm.sessionOf(r)
  if request and sessionId.len > 0:
    vm.requestedSession.val = sessionId
    vm.requests.val = vm.requests.val + 1
  if focus:
    vm.focusRequests.val = vm.focusRequests.val + 1
  vm.syncPage(sessionId)
  vm.bump()

proc syncPending(vm: InboxVM) =
  let pending = vm.fast.pending
  if vm.cursorPending.val != pending: vm.cursorPending.val = pending

proc canNext*(vm: InboxVM): bool =
  ## Tracked: Next has somewhere to go (the inbox is not empty).
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len > 0

proc canPrev*(vm: InboxVM): bool =
  ## Tracked: Previous has somewhere to go. It wraps to the last item, so
  ## that is whenever the inbox is not empty.
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len > 0

proc reread(vm: InboxVM)

proc step(vm: InboxVM; direction: PressDirection; focus: bool): bool =
  ## One press: switches at once when the cursor holds a target for it, and
  ## posts the move behind it; a press that waits shows as pending and moves
  ## the screen when its answer comes.
  let outcome = vm.fast.press(vm.snapshot, direction)
  if not outcome.posts: return false
  inc vm.moves
  if outcome.switched:
    vm.show(outcome.target, stepped = true, request = true, focus = focus)
  vm.syncPending()
  let token = vm.loadToken
  let target = vm
  vm.source.postInboxCursor(vm.cursorName, outcome.post,
    proc(answer: DataResult[CursorAnswer]) =
      if token != target.loadToken: return
      if not answer.ok:
        target.fast.reconcileFailure()
        target.cursorError.val = answer.error
        target.syncPending()
        target.bump()
        target.reread()
        return
      target.cursorError.val = ""
      if answer.value.hasItem: target.rememberItem(answer.value.item)
      let reconciled = target.fast.reconcileAnswer(answer.value)
      target.syncPending()
      if not reconciled.moveTo.isNone:
        target.show(reconciled.moveTo, stepped = true, request = true,
                    focus = focus)
      else:
        target.bump())
  true

proc next*(vm: InboxVM): bool =
  ## Next: the top of the server's order, excluding the item on screen,
  ## switched to at once. False, and nothing is posted, when the inbox is
  ## empty.
  if not vm.canNext: return false
  vm.step(pdNext, focus = false)

proc prev*(vm: InboxVM): bool =
  ## Previous: back along the items visited that still wait, and with none
  ## left the last item, switched to at once. False, and nothing is posted,
  ## when the inbox is empty.
  if not vm.canPrev: return false
  vm.step(pdPrev, focus = false)

proc open*(vm: InboxVM; r: InboxItemRef) =
  ## A row pressed: asks the host for the item's session tab. The cursor does
  ## not move.
  let sessionId = vm.sessionOf(r)
  if sessionId.len == 0: return
  vm.requestedSession.val = sessionId
  vm.requests.val = vm.requests.val + 1

# ---------------------------------------------------------------------------
# Auto-switch
# ---------------------------------------------------------------------------

proc setAutoSwitch*(vm: InboxVM; on: bool) = vm.autoSwitch.val = on
proc setTyping*(vm: InboxVM; typing: bool) = vm.typing.val = typing

proc maybeAutoSwitch(vm: InboxVM) =
  ## Once the item on screen has left the inbox because of the operator's
  ## own confirmed action (the receipt and the inbox event may come in either
  ## order), decides once: moves on when auto-switch is on, nobody types and
  ## the inbox holds another item; otherwise stays, for good.
  let r = vm.current.val
  if r.isNone or r != vm.ownAnswer or vm.snapshot.indexOf(r) >= 0: return
  vm.ownAnswer = InboxItemRef()
  if not vm.autoSwitch.val or vm.typing.val: return
  if vm.snapshot.items.len == 0: return   # the end of the inbox: stay
  discard vm.step(pdNext, focus = true)

proc noteSettled(vm: InboxVM; entry: TrackedAction) =
  ## An action settled: one of the operator's own answers to the item on
  ## screen, confirmed, is what auto-switch waits for.
  if entry.status != astConfirmed or entry.action.itemId.len == 0: return
  if entry.action.kind in {oaMarkViewing, oaSetPriority}: return
  let r = InboxItemRef(server: entry.action.server, id: entry.action.itemId)
  if r != vm.current.val: return
  vm.ownAnswer = r
  vm.maybeAutoSwitch()

# ---------------------------------------------------------------------------
# Loading and following
# ---------------------------------------------------------------------------

proc applyEvent*(vm: InboxVM; event: InboxEvent): bool =
  ## One inbox event, as the source delivers it. True when it changed the
  ## inbox. The item on screen stays on screen whatever happens to it.
  if vm.state.val != asReady: return false
  result = vm.snapshot.applyInboxEvent(event)
  if result:
    # The targets held came from the order before the change: the next press
    # waits for the server's answer, which brings new ones.
    vm.fast.forgetAhead()
    vm.remember()
    vm.bump()
    vm.maybeAutoSwitch()

proc restart*(vm: InboxVM)

proc takeRead(vm: InboxVM; read: InboxRead) =
  ## A read of the inbox with the cursor: the items as served, and the
  ## cursor reconciled (the first read puts the screen where the cursor is).
  vm.snapshot = read.snapshot
  vm.remember()
  let reconciled = vm.fast.reconcileRead(read.cursor, read.ahead)
  if not reconciled.moveTo.isNone:
    vm.show(reconciled.moveTo, stepped = false, request = false, focus = false)
  vm.syncPending()
  vm.bump()
  vm.maybeAutoSwitch()

proc reread(vm: InboxVM) =
  ## Reads the inbox and the cursor again (on a notice, or after a refused
  ## post); a newer read supersedes an older one still out.
  if vm.state.val != asReady: return
  inc vm.readToken
  let token = vm.loadToken
  let read = vm.readToken
  let target = vm
  vm.source.loadInboxRead(vm.cursorName, proc(answer: DataResult[InboxRead]) =
    if token != target.loadToken or read != target.readToken: return
    if not answer.ok:
      target.cursorError.val = answer.error
      target.bump()
      return
    target.takeRead(answer.value))

proc applyNotice*(vm: InboxVM; notice: InboxNotice): bool =
  ## One notice of the inbox stream. A move of this viewmodel's cursor made
  ## elsewhere is followed when nothing of its own is in flight; a notice
  ## that the inbox changed, or a resync, reads the inbox again. True when it
  ## moved the item on screen or asked for a read.
  if vm.state.val == asLoading and notice.kind == inResync:
    vm.resyncWhileLoading = true
    return false
  if vm.state.val != asReady: return false
  case notice.kind
  of inResync:
    vm.fast.forgetAhead()
    vm.reread()
    result = true
  of inChanged:
    let (told, move) = notice.cursorNoticeFor(vm.cursorName)
    if told:
      let reconciled = vm.fast.reconcileNotice(move, vm.snapshot)
      if not reconciled.moveTo.isNone:
        vm.show(reconciled.moveTo, stepped = true, request = true, focus = false)
        result = true
    if notice.entered.len > 0 or notice.left.len > 0 or notice.claims.len > 0 or
        (not told and notice.cursors.len == 0):
      vm.fast.forgetAhead()
      vm.reread()
      result = true
  of inOther:
    result = false

proc load*(vm: InboxVM) =
  ## Subscribes to the source's inbox events, notices and resets, then reads
  ## the inbox with the cursor; `asLoading` until it answers.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.resyncWhileLoading = false
  vm.error.val = ""
  vm.loadStartedMs = vm.nowMs
  let target = vm
  if vm.listener == 0:
    vm.listener = vm.tracker.listen(proc(entry: TrackedAction) =
      target.noteSettled(entry))
  vm.feeds.inbox.openInbox(vm.source, proc(event: InboxEvent): bool =
    target.applyEvent(event))
  vm.feeds.notices.openNotices(vm.source, proc(notice: InboxNotice): bool =
    target.applyNotice(notice))
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restart()
    true)
  inc vm.readToken
  let read = vm.readToken
  vm.source.loadInboxRead(vm.cursorName, proc(answer: DataResult[InboxRead]) =
    if token != target.loadToken or read != target.readToken: return
    if not answer.ok:
      target.error.val = answer.error
      target.state.val = asError
      target.bump()
      return
    target.state.val = asReady
    target.takeRead(answer.value)
    if target.resyncWhileLoading:
      target.resyncWhileLoading = false
      target.fast.forgetAhead()
      target.reread())

proc restart*(vm: InboxVM) =
  ## Starts over, as after a source's reset: the inbox, the cursor, the
  ## operator's answered items and the settled actions are dropped and load
  ## again; auto-switch and typing are kept.
  vm.snapshot = InboxSnapshot()
  vm.current.val = InboxItemRef()
  vm.fast = newFastCursor()
  vm.cursorPending.val = false
  vm.stepped = false
  vm.ownAnswer = InboxItemRef()
  vm.seen = @[]
  vm.cursorError.val = ""
  vm.tracker.clearSettled()
  if not vm.currentPage.isNil:
    vm.currentPage.dispose()
    vm.currentPage = nil
  vm.bump()
  vm.load()

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc snapshot*(vm: InboxVM): InboxSnapshot =
  ## Tracked: the inbox as served and followed.
  discard vm.revision.val
  vm.snapshot

proc items*(vm: InboxVM): seq[InboxItem] =
  ## Tracked: the items, in the server's order, unchanged.
  discard vm.revision.val
  vm.snapshot.items

proc count*(vm: InboxVM): int =
  discard vm.revision.val
  vm.snapshot.items.len

proc blockedCount*(vm: InboxVM): int =
  ## Tracked: the items whose agent stopped on them (the count's amber ink).
  discard vm.revision.val
  for item in vm.snapshot.items:
    if item.isBlocked: inc result

proc feedbackCount*(vm: InboxVM): int =
  ## Tracked: the async feedback requests (the count's second ink).
  discard vm.revision.val
  for item in vm.snapshot.items:
    if item.kind == ikAsyncFeedback: inc result

proc pendingFeedbackCount*(vm: InboxVM; server, sessionId: string): int =
  ## Tracked: how many feedback requests of one session (of the fleet server
  ## `server`, "" for the one connected) the inbox holds -- the session's
  ## pending-request count.
  discard vm.revision.val
  for item in vm.snapshot.items:
    if item.kind == ikAsyncFeedback and item.session.id == sessionId and
        item.server == server:
      inc result

proc pendingFeedbackText*(vm: InboxVM; r: InboxItemRef): string =
  ## Tracked: the pending-request mark a feedback request's row carries:
  ## `Needs Follow-up` when it is its session's only feedback request,
  ## `N pending` when the session has several; "" for a row of another kind
  ## or an item the inbox does not hold. Every host's row reads it here, so
  ## each counts alike.
  discard vm.revision.val
  let found = vm.itemOf(r)
  if not found.found or found.item.kind != ikAsyncFeedback: return ""
  pendingCountText(vm.pendingFeedbackCount(found.item.server, found.item.session.id))

proc countText*(vm: InboxVM): string =
  ## Tracked: `3 waiting`, "" for none.
  countText(vm.count)

proc controlTitle*(vm: InboxVM): string =
  ## Tracked: the inbox control's title.
  controlTitle(vm.count)

proc positionText*(vm: InboxVM): string =
  ## Tracked: `2 of 5` while the item on screen is in the inbox, `5 waiting`
  ## otherwise, "" when the inbox is empty.
  discard vm.revision.val
  positionText(vm.snapshot, vm.current.val)

proc currentItem*(vm: InboxVM): tuple[found: bool, item: InboxItem] =
  ## Tracked: the item on screen, while it is in the inbox.
  discard vm.revision.val
  vm.itemOf(vm.current.val)

proc explanationStrip*(vm: InboxVM): string =
  ## Tracked: under the session's header while it was reached through Next
  ## or Previous: the position and the server's one-line explanation
  ## (`2 of 5 · <explanation>`); "" otherwise.
  discard vm.revision.val
  if not vm.stepped: return ""
  let found = vm.itemOf(vm.current.val)
  if not found.found: return ""
  positionText(vm.snapshot, vm.current.val) & " \xC2\xB7 " & found.item.explanation

proc explanationOf*(vm: InboxVM; r: InboxItemRef): string =
  ## Tracked: an item's explanation, as served.
  discard vm.revision.val
  vm.itemOf(r).item.explanation

proc warmthOf*(vm: InboxVM; r: InboxItemRef; nowMs: int64): string =
  ## Tracked: an item's warmth chip at `nowMs`.
  discard vm.revision.val
  let found = vm.itemOf(r)
  if found.found: warmthChip(found.item.warmth, nowMs) else: ""

proc isEmpty*(vm: InboxVM): bool =
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len == 0

proc notice*(vm: InboxVM; nowMs = -1'i64): string =
  ## Tracked: what the panel centres instead of rows: `Loading the inbox… (Ns)`
  ## with the seconds waited, `Nothing is waiting for you.`; "" when it shows
  ## rows or an error block (`error` under `InboxErrorTitle`).
  case vm.state.val
  of asLoading:
    let now = if nowMs >= 0: nowMs else: vm.nowMs
    let waited = max(0'i64, now - vm.loadStartedMs) div 1000
    if waited > 0: InboxLoadingNotice & " (" & $waited & "s)" else: InboxLoadingNotice
  of asReady: (if vm.isEmpty: EmptyInboxText else: "")
  else: ""

proc wantsItemHint*(vm: InboxVM): bool =
  ## Tracked: the place an item's page takes holds the quiet hint that an
  ## item can be chosen (a press on a row, or Next) instead: items wait and
  ## none is on screen. With pages on, the page then opens there; without,
  ## the host opens the item's session. Nothing is opened for the reader: an
  ## item reaches the screen only through the reader's own press, never by
  ## arriving or by being first.
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len > 0 and vm.current.val.isNone

proc degradedText*(vm: InboxVM): seq[string] =
  ## Tracked: one line per server the inbox could not read.
  discard vm.revision.val
  for d in vm.snapshot.degraded:
    result.add "Incomplete: " & d.server & " could not be read (" & d.reason & ")"
