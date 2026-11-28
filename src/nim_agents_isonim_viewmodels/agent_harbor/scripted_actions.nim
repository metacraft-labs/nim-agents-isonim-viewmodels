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
##   would (nim-agents' `walkNext` / `walkPrev`, with a version and the
##   targets of the next presses, and a notice to every subscriber when one
##   moves), and answers every
##   action from its script. When the script confirms an action, the source
##   first applies what a server would do (`effects`): an answered inbox item
##   leaves the inbox (sent as an `item.resolved` event), an approved spec
##   change turns approved, a reverted one leaves the record, a staged card
##   is applied or discarded, a priority changes.
##
## - `ScriptedTestRunSource`: the scripted source of the Tests panel and the
##   trace links (additions for test runs). It also serves the platforms the
##   fleet offers, each platform's catalog, the session's test runs, their
##   events and the file links of the session's messages, and its confirmed
##   test-run writes do what a server would: a start creates a run (on the
##   platforms a backend serves; a platform none serves is refused, named in
##   the receipt, and a start that no platform can serve is refused as a
##   whole) and plays the story's event script into it, all at once
##   (`playOnStart`) or one event per `playNext`; a cancel finishes every
##   active platform run of the run as cancelled. A replay or a download is
##   answered per trace (`replayAnswers`, `downloadAnswers`), the script's
##   rule for its kind otherwise.
##
## **No transport.** Nothing here, and nothing this module imports, opens a
## connection: it holds no client and no URL. The live source over
## `nim-agent-harbor` will implement the same seam; the viewmodels do not
## change when it does.

import std/[strutils, tables]
import nim_agents/agent_harbor/test_runs
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
    ## keeps them per user: where each is, its visited stack and its version,
    ## which every move advances.
    cursors: Table[string, InboxCursor]
    versions: Table[string, int64]

proc cursorOf*(book: CursorBook; name: string): InboxCursor =
  book.cursors.getOrDefault(name)

proc versionOf*(book: CursorBook; name: string): int64 =
  book.versions.getOrDefault(name)

proc place*(book: var CursorBook; name: string; cursor: InboxCursor) =
  ## Puts the cursor `name` somewhere (a scenario's start), as a move would.
  book.cursors[name] = cursor
  book.versions[name] = book.versionOf(name) + 1

proc clear*(book: var CursorBook) =
  book.cursors.clear()
  book.versions.clear()

proc readOf*(book: CursorBook; name: string; snapshot: InboxSnapshot): InboxRead =
  ## The inbox read with `?cursor=name`: the items, where the cursor is, and
  ## the targets of its next presses.
  let cursor = book.cursorOf(name)
  let version = book.versionOf(name)
  InboxRead(snapshot: snapshot,
    cursor: CursorState(known: true, name: name, item: cursor.current,
                        visitedDepth: cursor.visited.len, cursorVersion: version),
    ahead: aheadOf(snapshot.orderOf, cursor, AheadDepth, version))

proc move*(book: var CursorBook; name: string; snapshot: InboxSnapshot;
           post: CursorPost): CursorAnswer =
  ## Moves the cursor `name` by the server's rules (nim-agents' `walkNext`
  ## and `walkPrev`: Next to the top of the order excluding the item on
  ## screen; Previous back along the items visited that still wait, wrapping
  ## to the last) and answers where it landed, with the targets of the next
  ## presses. Like the server, it moves by its own state: what the front-end
  ## switched to (`post.landedOn`) is not consulted.
  let order = snapshot.orderOf
  var cursor = book.cursorOf(name)
  let moved =
    case post.direction
    of pdNext: walkNext(order, cursor).moved
    of pdPrev: walkPrev(order, cursor).moved
  book.cursors[name] = cursor
  if moved: book.versions[name] = book.versionOf(name) + 1
  let version = book.versionOf(name)
  let at = snapshot.indexOf(cursor.current)
  result = CursorAnswer(hasItem: at >= 0, visitedDepth: cursor.visited.len,
    cursorVersion: version, ahead: aheadOf(order, cursor, AheadDepth, version))
  if at >= 0: result.item = snapshot.items[at]

proc noticeOf*(book: CursorBook; name: string; snapshot: InboxSnapshot): InboxNotice =
  ## The `changed` notice a server sends when the cursor `name` moved.
  let cursor = book.cursorOf(name)
  let version = book.versionOf(name)
  InboxNotice(kind: inChanged, reasons: @["cursor"],
    cursors: @[CursorNotice(name: name, item: cursor.current, cursorVersion: version,
                            ahead: aheadOf(snapshot.orderOf, cursor, AheadDepth, version))])

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
    noticeSubscribers*: Subscribers[InboxNotice]
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

method loadInboxRead*(source: ScriptedActionSource; cursorName: string;
                      done: InboxReadCallback) =
  done(success(source.cursors.readOf(cursorName, source.inbox)))

method postInboxCursor*(source: ScriptedActionSource; name: string;
                        post: CursorPost; done: CursorAnswerCallback) =
  ## Moves the cursor, answers the press, then tells every viewmodel on the
  ## notice stream, as a server tells every device.
  let answer = source.cursors.move(name, source.inbox, post)
  done(success(answer))
  discard source.noticeSubscribers.broadcast(
    success(source.cursors.noticeOf(name, source.inbox)))

method subscribeInboxNotices*(source: ScriptedActionSource;
    callback: FeedCallback[InboxNotice]): Subscription[InboxNotice] =
  ## The cursor moves `postInboxCursor` makes.
  source.noticeSubscribers.subscribe(callback)

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

method testRunEffects*(source: ScriptedActionSource; action: OperatorAction) {.base.} =
  ## What a confirmed test-run or trace action does to the source's data:
  ## nothing here (this source holds no test runs); `ScriptedTestRunSource`
  ## applies it.
  discard

proc applyEffects(source: ScriptedActionSource; action: OperatorAction) =
  case action.kind
  of oaStartTestRun, oaCancelTestRun, oaOpenTraceReplay, oaDownloadTrace:
    source.testRunEffects(action)
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

# ---------------------------------------------------------------------------
# Test runs and trace links
# ---------------------------------------------------------------------------

type
  ScriptedTestRunSource* = ref object of ScriptedActionSource
    ## The scripted source of the Tests panel and the trace links: a
    ## `ScriptedActionSource` that also serves test runs and link spans and
    ## applies the test-run writes (see the module comment).
    sessionId*: string
      ## The session whose runs `runs` are ("" answers them for any session).
    offers*: seq[PlatformOffer]
    catalogs*: seq[PlatformCatalog]
    catalogErrors*: seq[(string, string)]
      ## A platform key whose catalog read fails, and the error.
    runs*: seq[TestRunState]
    testRunsError*: string
      ## When set, every test-run read (platforms, catalogs, runs) fails with it.
    linkSpans*: seq[(string, seq[MessageLinkSpans])]
      ## By session id.
    startScript*: seq[TestRunEvent]
      ## The events a confirmed start plays into its new run (their run id is
      ## the new run's).
    playOnStart*: bool
      ## Play `startScript` at once (a static story), else hold it for `playNext`.
    held*: seq[TestRunEvent]
    replayAnswers*: seq[(string, ActionRule)]
      ## By trace id: what an `open-trace-replay` of that trace is answered.
    downloadAnswers*: seq[(string, ActionRule)]
      ## By trace id: what a `download-trace` of that trace is answered.
    nextRun*: int
      ## The number the next started run takes (`run-<n>`).
    runSubscribers: seq[(string, Subscribers[TestRunUpdate])]

proc newScriptedTestRunSource*(label = "scripted test runs";
                               script: ActionScript = nil): ScriptedTestRunSource =
  ScriptedTestRunSource(label: label, effects: true, nextRun: 1,
                        script: (if script.isNil: newActionScript() else: script))

proc runAt(source: ScriptedTestRunSource; id: string): int =
  for i, run in source.runs:
    if run.id == id: return i
  -1

proc subscribersOf(source: ScriptedTestRunSource; id: string): int =
  for i, (runId, _) in source.runSubscribers:
    if runId == id: return i
  source.runSubscribers.add (id, Subscribers[TestRunUpdate]())
  source.runSubscribers.high

proc sendUpdate*(source: ScriptedTestRunSource; update: TestRunUpdate): seq[ProgressDelivery] =
  ## Applies an event to the run it names (so a later read answers the state
  ## after it, as a server's would), then sends the update to the run's
  ## subscribers: an event, a lost stream, a resumed one.
  if update.kind == truEvent:
    let i = source.runAt(update.testRunId)
    if i >= 0: discard source.runs[i].applyTestRunEvent(update.event)
  let s = source.subscribersOf(update.testRunId)
  source.runSubscribers[s][1].broadcast(success(update))

proc sendEvent*(source: ScriptedTestRunSource; event: TestRunEvent): seq[ProgressDelivery] =
  source.sendUpdate(TestRunUpdate(kind: truEvent, testRunId: event.testRunId, event: event))

proc playNext*(source: ScriptedTestRunSource): bool =
  ## Plays the next held event of a started run; false when none is held.
  if source.held.len == 0: return false
  let event = source.held[0]
  source.held.delete(0)
  discard source.sendEvent(event)
  true

proc playAll*(source: ScriptedTestRunSource) =
  while source.playNext(): discard

proc offerKeys(source: ScriptedTestRunSource): seq[string] =
  for o in source.offers: result.add platformKey(o.platform)

proc refusals(source: ScriptedTestRunSource; action: OperatorAction): seq[(string, string)] =
  ## The platforms of a start that no backend serves, with why.
  for (key, value) in action.params:
    if key == "platform":
      let why = runAbsence(source.offers, value.split('+'))
      if why.len > 0: result.add (platformKey(value.split('+')), why)

method testRunEffects*(source: ScriptedTestRunSource; action: OperatorAction) =
  case action.kind
  of oaStartTestRun:
    var platforms: seq[TestPlatform]
    var backends: seq[string]
    let refused = source.refusals(action)
    for (key, value) in action.params:
      if key != "platform": continue
      let k = platformKey(value.split('+'))
      var skip = false
      for (r, _) in refused:
        if r == k: skip = true
      if skip: continue
      for o in source.offers:
        if platformKey(o.platform) == k:
          platforms.add o.platform
          backends.add (if o.backends.len > 0: o.backends[0].backend else: "")
    if platforms.len == 0: return
    var record = rmNone
    var reuse = rpCertified
    for (key, value) in action.params:
      if key == "record":
        for m in RecordMode:
          if $m == value: record = m
      if key == "reuse" and value == "never": reuse = rpNever
    while source.runAt("run-" & $source.nextRun) >= 0: inc source.nextRun
    let id = "run-" & $source.nextRun
    inc source.nextRun
    source.runs.add initTestRunState(id, action.choices, platforms, backends, record, reuse)
    for e in source.startScript:
      var event = e
      event.testRunId = id
      source.held.add event
    if source.playOnStart: source.playAll()
  of oaCancelTestRun:
    var runId = ""
    for (key, value) in action.params:
      if key == "test-run": runId = value
    let i = source.runAt(runId)
    if i < 0: return
    let run = source.runs[i]
    for p in run.platformRuns:
      if p.isActive:
        discard source.sendEvent(TestRunEvent(kind: tekRunFinished, testRunId: runId,
          platform: p.platform.features, backend: p.backend, cancelled: true,
          reason: "cancelled by the operator"))
    # What a cancelled run would still have sent is never sent.
    var kept: seq[TestRunEvent]
    for e in source.held:
      if e.testRunId != runId: kept.add e
    source.held = kept
  else: discard   # a replay or a download changes nothing a read answers

proc answerFor(list: seq[(string, ActionRule)]; trace: string; fallback: ActionRule): ActionRule =
  for (id, rule) in list:
    if id == trace: return rule
  fallback

method submitAction*(source: ScriptedTestRunSource; action: OperatorAction;
                     done: ActionCallback) =
  ## As `ScriptedActionSource`'s, with a replay and a download answered per
  ## trace, and a start that no offered platform can serve refused, naming
  ## each platform; a start refused on some of its platforms is confirmed
  ## for the rest, its receipt naming the refused ones.
  source.script.record.add $action
  var rule = source.script.ruleFor(action.kind)
  var trace = ""
  for (key, value) in action.params:
    if key == "trace": trace = value
  case action.kind
  of oaOpenTraceReplay: rule = source.replayAnswers.answerFor(trace, rule)
  of oaDownloadTrace: rule = source.downloadAnswers.answerFor(trace, rule)
  of oaStartTestRun:
    if rule.receipt == rrConfirmed:
      let refused = source.refusals(action)
      var named = 0
      for (key, _) in action.params:
        if key == "platform": inc named
      var reasons: seq[string]
      for (_, why) in refused: reasons.add why
      if named > 0 and refused.len == named:
        rule = failedWith(reasons.join("; "))
      elif refused.len > 0:
        var words: seq[string]
        for (key, why) in refused:
          words.add "Not started on " & platformLabel(key.split('+')) & ": " & why
        rule = confirmedWith(words.join("; "))
  else: discard
  if rule.receipt == rrConfirmed and source.effects: source.applyEffects(action)
  source.script.answer(rule, action, done)

method loadTestPlatforms*(source: ScriptedTestRunSource; done: TestPlatformsCallback) =
  if source.testRunsError.len > 0:
    done(failure[seq[PlatformOffer]](source.testRunsError))
  else: done(success(source.offers))

method loadTestCatalog*(source: ScriptedTestRunSource; change: string;
                        platform: seq[string]; done: TestCatalogCallback) =
  let key = platformKey(platform)
  if source.testRunsError.len > 0:
    done(failure[PlatformCatalog](source.testRunsError))
    return
  for (k, error) in source.catalogErrors:
    if k == key:
      done(failure[PlatformCatalog](error))
      return
  for c in source.catalogs:
    if platformKey(c.platform) == key:
      done(success(c))
      return
  done(missingResult[PlatformCatalog]("no catalog for " & platformLabel(platform) &
                                      " in " & source.label))

method loadSessionTestRuns*(source: ScriptedTestRunSource; sessionId: string;
                            done: SessionTestRunsCallback) =
  if source.testRunsError.len > 0:
    done(failure[seq[TestRunState]](source.testRunsError))
  elif source.sessionId.len == 0 or source.sessionId == sessionId:
    done(success(source.runs))
  else:
    done(success(newSeq[TestRunState]()))

method loadTestRun*(source: ScriptedTestRunSource; id: string; done: TestRunCallback) =
  let i = source.runAt(id)
  if i < 0: done(missingResult[TestRunState]("no test run " & id & " in " & source.label))
  else: done(success(source.runs[i]))

method subscribeTestRun*(source: ScriptedTestRunSource; id: string;
                         callback: FeedCallback[TestRunUpdate]): Subscription[TestRunUpdate] =
  ## Sends what `sendUpdate`, `playNext` and the source's own effects send
  ## for the run.
  let s = source.subscribersOf(id)
  source.runSubscribers[s][1].subscribe(callback)

method loadLinkSpans*(source: ScriptedTestRunSource; sessionId: string;
                      done: LinkSpansCallback) =
  for (id, spans) in source.linkSpans:
    if id == sessionId:
      done(success(spans))
      return
  done(success(newSeq[MessageLinkSpans]()))
