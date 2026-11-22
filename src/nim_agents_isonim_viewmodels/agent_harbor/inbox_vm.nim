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
## - **The server keeps the cursor.** `next` and `prev` ask the source to
##   move the cursor `cursorName` (`moveInboxCursor`) and show the item it
##   answers; the viewmodel keeps no order and no visited stack. `canPrev` is
##   what the source last said about its stack. A second viewmodel on the
##   same cursor name joins the walk where it is (`loadInboxCursor` on
##   load).
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
    cursorCanPrev: bool
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
  ## How many cursor moves the viewmodel asked its source for.
  vm.moves

proc bump(vm: InboxVM) =
  vm.revision.val = vm.revision.val + 1

proc nowMs(vm: InboxVM): int64 =
  if vm.clock.isNil: 0'i64 else: int64(vm.clock.now)

proc itemOf(vm: InboxVM; r: InboxItemRef): tuple[found: bool, item: InboxItem] =
  let at = vm.snapshot.indexOf(r)
  if at < 0: (false, InboxItem()) else: (true, vm.snapshot.items[at])

proc remember(vm: InboxVM) =
  ## Notes the session of every item held now.
  for item in vm.snapshot.items:
    var known = false
    for (r, _) in vm.seen:
      if r == item.refOf: known = true
    if not known: vm.seen.add (item.refOf, item.session.id)

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

proc place(vm: InboxVM; position: CursorPosition; stepped: bool) =
  ## Shows where the source says the cursor is.
  let before = vm.current.val
  vm.cursorCanPrev = position.canPrev
  if position.current != before:
    vm.current.val = position.current
    vm.stepped = stepped and position.moved
    vm.ownAnswer = InboxItemRef()
  elif stepped and position.moved:
    vm.stepped = true
  let sessionId = vm.sessionOf(position.current)
  if stepped and position.moved and sessionId.len > 0:
    vm.requestedSession.val = sessionId
    vm.requests.val = vm.requests.val + 1
  vm.syncPage(sessionId)
  vm.bump()

proc canNext*(vm: InboxVM): bool =
  ## Tracked: Next has somewhere to go (the inbox is not empty).
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len > 0

proc canPrev*(vm: InboxVM): bool =
  ## Tracked: the source's visited stack has an item to go back to, and the
  ## inbox is not empty.
  discard vm.revision.val
  vm.state.val == asReady and vm.snapshot.items.len > 0 and vm.cursorCanPrev

proc step(vm: InboxVM; direction: CursorDirection; focus: bool): bool =
  inc vm.moves
  let target = vm
  vm.source.moveInboxCursor(vm.cursorName, direction,
    proc(answer: DataResult[CursorPosition]) =
      if not answer.ok:
        target.cursorError.val = answer.error
        target.bump()
        return
      target.cursorError.val = ""
      target.place(answer.value, stepped = true)
      if focus and answer.value.moved:
        target.focusRequests.val = target.focusRequests.val + 1)
  true

proc next*(vm: InboxVM): bool =
  ## Next: the source moves the cursor to the top of its order, excluding the
  ## item on screen. False, and nothing is asked, when the inbox is empty.
  if not vm.canNext: return false
  vm.step(cdNext, focus = false)

proc prev*(vm: InboxVM): bool =
  ## Previous: the source moves the cursor back along the items visited.
  ## False, and nothing is asked, when there is none or the inbox is empty.
  if not vm.canPrev: return false
  vm.step(cdPrev, focus = false)

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
  discard vm.step(cdNext, focus = true)

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
    vm.remember()
    vm.bump()
    vm.maybeAutoSwitch()

proc restart*(vm: InboxVM)

proc load*(vm: InboxVM) =
  ## Subscribes to the source's inbox events and resets, then loads the
  ## inbox and the cursor; `asLoading` until the inbox answers.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  vm.loadStartedMs = vm.nowMs
  let target = vm
  if vm.listener == 0:
    vm.listener = vm.tracker.listen(proc(entry: TrackedAction) =
      target.noteSettled(entry))
  vm.feeds.inbox.openInbox(vm.source, proc(event: InboxEvent): bool =
    target.applyEvent(event))
  vm.feeds.resets.openResets(vm.source, proc(reset: StreamReset): bool =
    target.restart()
    true)
  vm.source.loadInbox(proc(answer: DataResult[InboxSnapshot]) =
    if token != target.loadToken: return
    if not answer.ok:
      target.error.val = answer.error
      target.state.val = asError
      target.bump()
      return
    target.snapshot = answer.value
    target.remember()
    target.state.val = asReady
    target.bump()
    target.source.loadInboxCursor(target.cursorName,
      proc(position: DataResult[CursorPosition]) =
        if token != target.loadToken: return
        if not position.ok:
          target.cursorError.val = position.error
          target.bump()
          return
        target.place(position.value, stepped = false)))

proc restart*(vm: InboxVM) =
  ## Starts over, as after a source's reset: the inbox, the cursor, the
  ## operator's answered items and the settled actions are dropped and load
  ## again; auto-switch and typing are kept.
  vm.snapshot = InboxSnapshot()
  vm.current.val = InboxItemRef()
  vm.cursorCanPrev = false
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
