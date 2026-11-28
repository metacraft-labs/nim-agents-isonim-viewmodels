## The inbox viewmodel (`InboxVM`): the server's order kept after every
## event, Previous and Next over a cursor the source keeps (the milestone's
## "Prev/Next over a fixture cursor"), the empty inbox with both disabled,
## auto-switch moving only for the operator's own answer, the count and its
## inks, the position, the explanation strip, the load states and the tab a
## step asks for.
##
## Test doubles, and why each is justified:
##
## - `ScriptedActionSource` is the prototypes' production source for the
##   inbox: it holds an invented inbox, keeps the cursor with the server's
##   rules (nim-agents' `walkNext` / `walkPrev`, with the targets of the next
##   presses from `aheadOf`) and answers actions from a script. A real server's inbox cursors are not served yet, and the
##   prototypes may not write to a server, so no live source exists to test
##   against; this source is the one every story uses.
## - `PendingDataSource` and `FailingDataSource` are the seam's state
##   sources: a server that does not answer, and one that fails.
## - `HeldPostSource` is that source with its cursor answers held back until
##   the test releases them: a server that has not answered yet, which is
##   the only way to show that a press does not wait for its answer.
##   `RefusingPostSource` refuses every cursor post, as a server that is down
##   would. `HeldReadSource` holds its reads of the inbox the same way, the
##   only way to put a stream's resync before the first read's answer.
## - IsoNim's `TestClock` dates the loading line.
##
## Expected values are written out by hand from the invented inboxes'
## documented order (`synthetic_inbox.nim`), never computed through the
## reducer or the cursor rule.

import std/[strutils, unittest]
import isonim/core/[owner, signals, clock]
import nim_agents_isonim_viewmodels

proc ids(vm: InboxVM): seq[string] =
  for item in vm.items: result.add item.id

proc ids(snapshot: InboxSnapshot): seq[string] =
  for item in snapshot.items: result.add item.id

proc firstItems(n: int): InboxSnapshot =
  ## The populated inbox's first `n` items.
  result = populatedInbox()
  result.items.setLen n

proc populated(): ScriptedActionSource =
  ScriptedActionSource(inboxFixture("populated"))

type
  HeldPost = object
    name: string
    post: CursorPost
    done: CursorAnswerCallback

  HeldPostSource = ref object of ScriptedActionSource
    held: seq[HeldPost]

  RefusingPostSource = ref object of ScriptedActionSource

  HeldReadSource = ref object of ScriptedActionSource
    reads: seq[(string, InboxReadCallback)]

method postInboxCursor(source: HeldPostSource; name: string; post: CursorPost;
                       done: CursorAnswerCallback) =
  source.held.add HeldPost(name: name, post: post, done: done)

proc release(source: HeldPostSource) =
  ## Answers the held posts in the order they were sent, as the server would.
  let held = source.held
  source.held = @[]
  for h in held:
    procCall postInboxCursor(ScriptedActionSource(source), h.name, h.post, h.done)

method postInboxCursor(source: RefusingPostSource; name: string; post: CursorPost;
                       done: CursorAnswerCallback) =
  done(failure[CursorAnswer]("POST /api/v1/inbox/cursors/" & name & " answered 503"))

method loadInboxRead(source: HeldReadSource; cursorName: string;
                     done: InboxReadCallback) =
  source.reads.add((cursorName, done))

proc answerRead(source: HeldReadSource; at: int) =
  ## Answers the read at `at` with the cursor as the source holds it now.
  let (name, done) = source.reads[at]
  procCall loadInboxRead(ScriptedActionSource(source), name, done)

proc resync(source: ScriptedActionSource) =
  ## The stream's first frame after it connects, as every server sends it.
  discard source.noticeSubscribers.broadcast(
    success(InboxNotice(kind: inResync)))

proc threeItemSource[T: ScriptedActionSource](kind: typedesc[T]): T =
  let base = ScriptedActionSource(inboxSource(firstItems(3), inboxDetails(),
                                              "three items"))
  result = T(label: base.label, effects: true, script: newActionScript(),
             inbox: base.inbox, details: base.details)

const
  P = PermissionItem
  Q = QuestionItem
  E = EndedTurnItem
  L = LoginItem
  F = FeedbackItem

proc resolvedEvent(id: string; order: openArray[string]): InboxEvent =
  var refs: seq[InboxItemRef]
  for o in order: refs.add InboxItemRef(id: o)
  InboxEvent(kind: ieResolved, target: InboxItemRef(id: id), hasOrder: true, order: refs)

suite "the server's order":
  test "the rows are the source's order, unchanged, after every event":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source)
      vm.load()
      check vm.ids == @[P, Q, E, L, F]
      check vm.ids == source.inbox.ids
      # A low item moved to the top by the server, an item added in the
      # middle, an update with no order, a resolution: the rows follow each.
      discard source.sendInbox(InboxEvent(kind: ieReordered, hasOrder: true,
        order: @[InboxItemRef(id: F), InboxItemRef(id: P), InboxItemRef(id: Q),
                 InboxItemRef(id: E), InboxItemRef(id: L)]))
      check vm.ids == @[F, P, Q, E, L]
      var arriving = source.inbox.items[2]
      arriving.id = "inbox-item-new"
      arriving.position = 2
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: arriving))
      check vm.ids == @[F, "inbox-item-new", P, Q, E, L]
      var updated = source.inbox.items[0]
      updated.effectivePriority = ipUrgent
      discard source.sendInbox(InboxEvent(kind: ieUpdated, item: updated))
      check vm.ids == @[F, "inbox-item-new", P, Q, E, L]
      discard source.sendInbox(resolvedEvent(P, [F, "inbox-item-new", Q, E, L]))
      check vm.ids == @[F, "inbox-item-new", Q, E, L]
      check vm.ids == source.inbox.ids
      vm.dispose()
      disposeRoot()

  test "the count, its inks, the title and the rows' words":
    createRoot proc(disposeRoot: proc()) =
      let vm = newInboxVM(populated())
      vm.load()
      check vm.count == 5
      check vm.blockedCount == 4      # everything but the feedback request
      check vm.feedbackCount == 1
      check vm.countText == "5 waiting"
      check vm.controlTitle == "5 tasks need input"
      check vm.positionText == "5 waiting"   # nothing on screen yet
      check vm.items[0].kindWord == "asks for permission"
      check vm.items[1].priorityChip == "high, raised"
      check vm.warmthOf(InboxItemRef(id: P), InboxT0) == "warm 3:12"
      check vm.warmthOf(InboxItemRef(id: P), InboxT0 + 12_000) == "warm 3:00"
      check vm.warmthOf(InboxItemRef(id: E), InboxT0) == "expiring"
      check vm.warmthOf(InboxItemRef(id: F), InboxT0) == ""
      check vm.explanationOf(InboxItemRef(id: E)) == "Waiting longest of the normal items."
      vm.dispose()
      disposeRoot()

  test "test_inbox_vm_pending_count: a session's feedback requests are counted by the viewmodel":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source)
      vm.load()
      let session4 = sessionIdOf(4)
      check vm.pendingFeedbackCount("", session4) == 1
      check vm.pendingFeedbackText(InboxItemRef(id: F)) == "Needs Follow-up"
      # Rows of other kinds carry no mark, and neither does an unknown item.
      for id in [P, Q, E, L, "inbox-item-none"]:
        check vm.pendingFeedbackText(InboxItemRef(id: id)) == ""
      # A second request of the same session arrives: both rows say so.
      var second = source.inbox.items[4]
      second.id = "inbox-item-feedback-2"
      second.position = 6
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: second))
      check vm.pendingFeedbackCount("", session4) == 2
      check vm.pendingFeedbackText(InboxItemRef(id: F)) == "2 pending"
      check vm.pendingFeedbackText(InboxItemRef(id: "inbox-item-feedback-2")) == "2 pending"
      # A question of that same session is not a feedback request: its row
      # carries no mark, and it is not counted.
      var question = source.inbox.items[0]
      check question.kind != ikAsyncFeedback
      question.id = "inbox-item-question-4"
      question.session = source.inbox.items[4].session
      question.position = 9
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: question))
      check vm.pendingFeedbackText(InboxItemRef(id: "inbox-item-question-4")) == ""
      check vm.pendingFeedbackCount("", session4) == 2
      # Another session's request, and the same session id on another
      # server, are counted apart.
      var other = source.inbox.items[4]
      other.id = "inbox-item-feedback-3"
      other.session.id = sessionIdOf(2)
      other.position = 7
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: other))
      var remote = source.inbox.items[4]
      remote.id = "inbox-item-feedback-4"
      remote.server = "relay-lab"
      remote.position = 8
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: remote))
      check vm.pendingFeedbackCount("", session4) == 2
      check vm.pendingFeedbackCount("", sessionIdOf(2)) == 1
      check vm.pendingFeedbackCount("relay-lab", session4) == 1
      check vm.pendingFeedbackText(InboxItemRef(id: "inbox-item-feedback-3")) ==
        "Needs Follow-up"
      check vm.pendingFeedbackText(InboxItemRef(server: "relay-lab",
                                                id: "inbox-item-feedback-4")) ==
        "Needs Follow-up"
      # One is answered elsewhere: the count follows the inbox.
      var order: seq[InboxItemRef]
      for item in source.inbox.items:
        if item.id != F: order.add item.refOf
      discard source.sendInbox(InboxEvent(kind: ieResolved, target: InboxItemRef(id: F),
                                          hasOrder: true, order: order))
      check vm.pendingFeedbackCount("", session4) == 1
      check vm.pendingFeedbackText(InboxItemRef(id: "inbox-item-feedback-2")) ==
        "Needs Follow-up"
      vm.dispose()
      disposeRoot()

suite "Previous and Next over a fixture cursor":
  test "Next goes to the top excluding the item on screen; Previous walks back the visited stack":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedActionSource(inboxSource(firstItems(3),
                                                    inboxDetails(), "three items"))
      let vm = newInboxVM(source)
      vm.load()
      check vm.canNext
      check vm.canPrev                  # Previous wraps to the last item
      check vm.next()
      check vm.current.val.id == P
      check vm.positionText == "1 of 3"
      check vm.requestedSession.val == sessionIdOf(3)
      check vm.next()
      check vm.current.val.id == Q
      check vm.positionText == "2 of 3"
      # Next again: the top of the order excluding the question is the
      # permission gate, already visited -- offered again because it is on top.
      check vm.next()
      check vm.current.val.id == P
      check vm.canPrev
      # Previous returns along the items visited (the question, then the
      # permission gate), not to the order's neighbour.
      check vm.prev()
      check vm.current.val.id == Q
      check vm.requestedSession.val == sessionIdOf(1)
      check vm.prev()
      check vm.current.val.id == P
      # Nothing left on the stack: Previous wraps to the last item.
      check vm.canPrev
      check vm.prev()
      check vm.current.val.id == E
      check vm.positionText == "3 of 3"
      check vm.requests.val == 6
      vm.dispose()
      disposeRoot()

  test "a second viewmodel on the same cursor name continues from the same item":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let first = newInboxVM(source)
      first.load()
      check first.next()
      check first.next()
      check first.current.val.id == Q
      let second = newInboxVM(source)
      second.load()
      check second.current.val.id == Q
      check second.canPrev
      check second.next()
      check second.current.val.id == P
      # Another cursor name is another walk.
      let other = newInboxVM(source, cursorName = "triage")
      other.load()
      check other.current.val.isNone
      check other.canPrev               # Previous wraps; its walk is its own
      first.dispose()
      second.dispose()
      other.dispose()
      disposeRoot()

  test "a story opened mid-walk shows its place and its explanation strip after a step":
    createRoot proc(disposeRoot: proc()) =
      let vm = newInboxVM(inboxFixture("cursor-middle"))
      vm.load()
      check vm.current.val.id == E
      check vm.positionText == "3 of 5"
      check vm.canPrev
      check vm.explanationStrip == ""    # not reached through a step here
      check vm.prev()
      check vm.current.val.id == Q
      check vm.explanationStrip ==
        "2 of 5 \xC2\xB7 Raised: its model cache is warm for three more minutes."
      vm.dispose()
      disposeRoot()

  test "with no items, Next and Prev are disabled and ask the source nothing":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source)
      vm.load()
      check vm.next()
      check vm.next()
      check vm.canPrev
      # Everything is answered elsewhere: the cursor still holds a visited
      # stack, and both buttons are disabled anyway.
      for id in [P, Q, E, L, F]:
        var rest: seq[string]
        for item in source.inbox.items:
          if item.id != id: rest.add item.id
        discard source.sendInbox(resolvedEvent(id, rest))
      check source.cursorOf("default").visited.len == 1
      check vm.isEmpty
      check vm.notice == EmptyInboxText
      check vm.positionText == ""
      check not vm.canNext
      check not vm.canPrev
      let moves = vm.moveCount
      check not vm.next()
      check not vm.prev()
      check vm.moveCount == moves
      vm.dispose()
      let empty = newInboxVM(inboxFixture("empty"))
      empty.load()
      check empty.isEmpty and not empty.canNext and not empty.canPrev
      check not empty.next()
      check empty.moveCount == 0
      check empty.countText == ""
      check empty.controlTitle == "No input required"
      empty.dispose()
      disposeRoot()

suite "a resync before the first read answers":
  test "the inbox is read again once the load lands, and the targets wait for that read":
    createRoot proc(disposeRoot: proc()) =
      let source = threeItemSource(HeldReadSource)
      let vm = newInboxVM(source)
      vm.load()
      check vm.state.val == asLoading
      check source.reads.len == 1
      source.resync()              # the stream connected before the read answered
      check source.reads.len == 1  # nothing is read while loading
      source.answerRead(0)
      check vm.state.val == asReady
      check source.reads.len == 2  # the read the resync asked for
      check not vm.heldAhead.known # a press now waits for it
      source.answerRead(1)
      check vm.heldAhead.known
      check vm.heldAhead.next.len == 3
      vm.dispose()
      disposeRoot()

  test "without a resync, the load's read is the only one":
    createRoot proc(disposeRoot: proc()) =
      let source = threeItemSource(HeldReadSource)
      let vm = newInboxVM(source)
      vm.load()
      source.answerRead(0)
      check vm.state.val == asReady
      check source.reads.len == 1
      check vm.heldAhead.known
      vm.dispose()
      disposeRoot()

suite "a press never waits on the server":
  test "Next and Prev switch before the source answers; a press past the targets held waits":
    createRoot proc(disposeRoot: proc()) =
      let source = threeItemSource(HeldPostSource)
      let vm = newInboxVM(source)
      vm.load()
      # Three presses switch at once, with nothing answered.
      check vm.next()
      check vm.current.val.id == P
      check vm.requestedSession.val == sessionIdOf(3)
      check vm.next()
      check vm.current.val.id == Q
      check vm.next()
      check vm.current.val.id == P
      check not vm.cursorPending.val
      check vm.inFlight == 3
      check source.held.len == 3
      # The fourth goes beyond the three targets the read held: it waits.
      check vm.next()
      check vm.cursorPending.val
      check vm.current.val.id == P
      check vm.inFlight == 4
      # The posts went out in the order pressed, each with the item switched
      # to, and the waiting one with none.
      check source.held[0].post.landedOn == P
      check source.held[1].post.landedOn == Q
      check source.held[2].post.landedOn == P
      check source.held[3].post.landedOn == ""
      check source.held[0].post.direction == pdNext
      # The server answers: the waiting press lands where the server put it
      # (from P, the top excluding P is Q).
      source.release()
      check not vm.cursorPending.val
      check vm.inFlight == 0
      check vm.current.val.id == Q
      check vm.moveCount == 4
      vm.dispose()
      disposeRoot()

  test "a second viewmodel on the same cursor follows a step made in the first":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let first = newInboxVM(source)
      let second = newInboxVM(source)
      first.load()
      second.load()
      check first.next()
      check first.current.val.id == P
      check second.current.val.id == P
      check second.requestedSession.val == first.requestedSession.val
      check second.moveCount == 0
      # The other device goes back: nothing was visited before P, so Previous
      # wraps to the last item, and the first follows.
      check second.prev()
      check second.current.val.id == F
      check first.current.val.id == F
      first.dispose()
      second.dispose()
      disposeRoot()

  test "a refused post releases the press, says why, and leaves the screen where it went":
    createRoot proc(disposeRoot: proc()) =
      let source = threeItemSource(RefusingPostSource)
      let vm = newInboxVM(source)
      vm.load()
      check vm.next()
      check vm.current.val.id == P
      check "503" in vm.cursorError.val
      check not vm.cursorPending.val
      check vm.inFlight == 0
      vm.dispose()
      disposeRoot()

suite "auto-switch":
  test "the operator's own answer moves on and focuses the next input; with it off nothing moves":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      check vm.next()
      check vm.current.val.id == P
      # Off: answering leaves the page where it is.
      check vm.page.choosePermission("allow_once")
      check vm.ids == @[Q, E, L, F]
      check vm.current.val.id == P
      check vm.positionText == "4 waiting"
      check vm.page.phaseText == AnswerSentText
      check vm.focusRequests.val == 0
      # On: Next, answer, and on to the next item by itself.
      vm.setAutoSwitch(true)
      check vm.next()
      check vm.current.val.id == Q
      vm.page.setText("Keep it behind a flag.")
      check vm.page.submit()
      check vm.current.val.id == E
      check vm.positionText == "1 of 3"
      check vm.focusRequests.val == 1
      check vm.requestedSession.val == sessionIdOf(2)
      check source.record.len == 2
      vm.dispose()
      disposeRoot()

  test "an item answered elsewhere, a failed answer and typing never move it":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      vm.setAutoSwitch(true)
      check vm.next()
      check vm.current.val.id == P
      # Answered on another front-end: not the operator's own action.
      discard source.sendInbox(resolvedEvent(P, [Q, E, L, F]))
      check vm.current.val.id == P
      check vm.focusRequests.val == 0
      # A failed answer: the item stays, and so does the page.
      check vm.next()
      check vm.current.val.id == Q
      source.script.setRule(oaAnswerQuestion, failedWith("the session ended"))
      vm.page.setText("Keep it behind a flag.")
      check vm.page.submit()
      check vm.page.phaseText == AnswerFailedText & ": the session ended"
      check vm.current.val.id == Q
      check vm.ids == @[Q, E, L, F]
      # Typing: the operator's own answer leaves the inbox, and the page holds.
      source.script.setRule(oaAnswerQuestion, confirmed())
      vm.setTyping(true)
      vm.page.setText("Keep it behind a flag.")
      check vm.page.submit()
      check vm.ids == @[E, L, F]
      check vm.current.val.id == Q
      check vm.focusRequests.val == 0
      # The move held back by typing is dropped, not made once typing stops:
      # the next change, one the operator did not cause, moves nothing.
      vm.setTyping(false)
      var later = source.inbox.items[0]
      later.explanation = "Still waiting."
      discard source.sendInbox(InboxEvent(kind: ieUpdated, item: later))
      check vm.explanationOf(InboxItemRef(id: E)) == "Still waiting."
      check vm.current.val.id == Q
      check vm.focusRequests.val == 0
      vm.dispose()
      disposeRoot()

  test "an answer sent with auto-switch off never moves it later, when auto-switch is turned on":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      check vm.next()
      check vm.page.choosePermission("allow_once")
      check vm.ids == @[Q, E, L, F]
      check vm.current.val.id == P
      # Auto-switch on afterwards, then a change the operator did not cause:
      # the answer that left the page was decided on when it left.
      vm.setAutoSwitch(true)
      discard source.sendInbox(resolvedEvent(F, [Q, E, L]))
      check vm.ids == @[Q, E, L]
      check vm.current.val.id == P
      check vm.focusRequests.val == 0
      check vm.moveCount == 1
      vm.dispose()
      disposeRoot()

  test "an item that arrives never takes the screen, even with auto-switch on":
    # Auto-switch moves only after the operator's own answer; an arrival is
    # the server's change, so it adds a row and nothing else: no step, no tab
    # asked for, no input focused -- whether nothing is on screen yet or the
    # operator is reading an item.
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      vm.setAutoSwitch(true)
      let tabBefore = vm.requestedSession.val
      # Nothing on screen: the arrival is listed at the top and stays a row.
      var first = source.inbox.items[1]
      first.id = "inbox-item-arrived-1"
      first.position = 1
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: first))
      check vm.ids == @["inbox-item-arrived-1", P, Q, E, L, F]
      check vm.current.val.isNone
      check vm.moveCount == 0
      check vm.focusRequests.val == 0
      check vm.requestedSession.val == tabBefore
      # Reading an item: a second arrival above it moves nothing.
      check vm.next()
      check vm.current.val.id == "inbox-item-arrived-1"
      check vm.next()
      check vm.current.val.id == P
      let moves = vm.moveCount
      let tab = vm.requestedSession.val
      check tab == sessionIdOf(3)
      var second = source.inbox.items[2]
      second.id = "inbox-item-arrived-2"
      second.position = 1
      discard source.sendInbox(InboxEvent(kind: ieAdded, item: second))
      check vm.ids == @["inbox-item-arrived-2", "inbox-item-arrived-1", P, Q, E, L, F]
      check vm.current.val.id == P
      check vm.moveCount == moves
      check vm.focusRequests.val == 0
      check vm.requestedSession.val == tab
      vm.dispose()
      disposeRoot()

  test "test_inbox_vm_item_hint: with items and nothing on screen the page's place holds the hint, and nothing opens":
    # The hint is the reader's cue to choose; asking for it opens nothing.
    # It goes once an item is on screen (with pages or without: a host
    # without pages opens the item's session), and never shows with nothing
    # waiting or before the inbox is read.
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source, showPages = true)
      check not vm.wantsItemHint    # not loaded yet
      vm.load()
      check vm.wantsItemHint
      check vm.wantsItemHint        # asking twice still opens nothing
      check vm.current.val.isNone
      check vm.page.isNil
      check vm.moveCount == 0
      check vm.requests.val == 0
      check vm.next()
      check not vm.wantsItemHint
      check not vm.page.isNil
      vm.dispose()
      let noPages = newInboxVM(populated())
      noPages.load()
      check noPages.wantsItemHint
      check noPages.next()
      check noPages.page.isNil
      check not noPages.wantsItemHint
      noPages.dispose()
      let empty = newInboxVM(inboxFixture("empty"), showPages = true)
      empty.load()
      check empty.isEmpty
      check not empty.wantsItemHint
      empty.dispose()
      let waiting = newInboxVM(newPendingDataSource(), showPages = true)
      waiting.load()
      check not waiting.wantsItemHint
      waiting.dispose()
      disposeRoot()

  test "it stops at the end of the inbox":
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedActionSource(inboxSource(firstItems(1),
                                                    inboxDetails(), "one item"))
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      vm.setAutoSwitch(true)
      check vm.next()
      let moves = vm.moveCount
      check vm.page.choosePermission("allow_once")
      check vm.isEmpty
      check vm.current.val.id == P
      check vm.moveCount == moves
      check vm.focusRequests.val == 0
      vm.dispose()
      disposeRoot()

suite "load states and restarts":
  test "loading counts its seconds, an error keeps its reason, a degraded server is named":
    createRoot proc(disposeRoot: proc()) =
      let clock = newTestClock(0)
      let pending = newPendingDataSource()
      let loading = newInboxVM(pending, clock = clock)
      loading.load()
      check loading.state.val == asLoading
      check loading.notice == InboxLoadingNotice
      clock.advance(7_000)
      check loading.notice == InboxLoadingNotice & " (7s)"
      check pending.pendingInbox.len == 1
      loading.dispose()
      let failing = newInboxVM(inboxFixture("error"))
      failing.load()
      check failing.state.val == asError
      check failing.error.val == InboxErrorText
      check failing.notice == ""
      check not failing.canNext
      failing.dispose()
      let fleet = newInboxVM(inboxFixture("fleet"))
      fleet.load()
      check fleet.degradedText == @["Incomplete: orbit-west could not be read (connection refused)"]
      check fleet.items[1].server == "relay-lab"
      fleet.dispose()
      disposeRoot()

  test "a reset reloads the inbox and keeps auto-switch":
    createRoot proc(disposeRoot: proc()) =
      let source = populated()
      let vm = newInboxVM(source)
      vm.load()
      vm.setAutoSwitch(true)
      check vm.next()
      discard source.resetSubscribers.broadcast(success(StreamReset(reason: "test")))
      check vm.state.val == asReady
      check vm.current.val.id == P     # the source's cursor, read again
      check vm.autoSwitch.val
      check vm.ids == @[P, Q, E, L, F]
      vm.dispose()
      disposeRoot()

  test "a held item and an unknown kind are listed in their place":
    createRoot proc(disposeRoot: proc()) =
      let vm = newInboxVM(inboxFixture("manager-held"))
      vm.load()
      check vm.ids == @[P, "inbox-item-budget", Q]
      check vm.items[1].kind == ikUnknown
      check vm.items[1].kindWord == "budget approval"
      check vm.items[0].holderText == "with the Manager"
      check vm.items[2].holderText == "needs you"
      vm.dispose()
      disposeRoot()

suite "the long inbox":
  test "every one of its forty items has a page, and one far down loads it":
    # The hosts' keyboard stories put the item on screen far down the long
    # list (`InboxLongKeyboard`): every item there must have a page to show.
    createRoot proc(disposeRoot: proc()) =
      let source = ScriptedActionSource(inboxFixture("long"))
      let order = source.inbox.orderOf
      check order.len == 40
      var pages: seq[string]
      for d in source.details: pages.add d.itemId
      check pages == source.inbox.ids
      source.setCursor("default", InboxCursor(current: order[31], visited: order[0 .. 30]))
      let vm = newInboxVM(source, showPages = true)
      vm.load()
      check vm.current.val.id == order[31].id
      check not vm.page.isNil
      check vm.page.state.val == asReady
      check vm.prev()
      check vm.current.val.id == order[30].id
      check vm.page.state.val == asReady
      vm.dispose()
      disposeRoot()
