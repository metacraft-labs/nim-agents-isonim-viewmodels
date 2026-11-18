## The data-source seam of the Agent Harbor viewmodels.
##
## Every Agent Harbor viewmodel in this package reads its data through an
## `AgentHarborDataSource`, never from a client or a file directly. Three
## kinds of source implement it:
##
## - the fixture source (`fixture_source.nim`), which replays data captured
##   from a real fleet and from real tool runs, so prototypes and tests are
##   deterministic;
## - the state sources below (`newPendingDataSource`, `newFailingDataSource`,
##   `newSnapshotDataSource`), which produce the states no capture can show:
##   a load that has not answered, a load that failed, an empty or synthetic
##   fleet;
## - later, a live source over `nim-agent-harbor`'s typed client. It answers
##   the same calls from the network; a viewmodel built on this seam does not
##   change when it is swapped in.
##
## Each load is asynchronous by contract: the source calls `done` exactly once,
## possibly before the load call returns (the fixture source does), possibly
## much later (a live source will), and possibly never (the pending source,
## which is what a hung server looks like). A viewmodel must therefore show a
## loading state between the call and the answer, and must not assume the
## answer arrives inside the call.
##
## Base methods answer with an error naming the missing capability, so a
## source that serves only part of the surface fails loudly and visibly
## rather than rendering an empty panel that looks like an empty fleet.
##
## Besides the loads, a source may deliver initiative progress events as they
## happen (`subscribeProgress`): a milestone's status changed in a plan. A
## subscriber is called once per event, for as long as its subscription is
## active, and answers what the event did to it (`ProgressDelivery`). The
## subscription is a handle the subscriber cancels (a viewmodel does so when
## it is disposed); once cancelled, the handle drops the subscriber's callback,
## so a source that delivers through the handle (`deliver`, `broadcast`)
## cannot reach the subscriber any more, and the attempt is counted on the
## handle and answered `pdRefused`.
##
## The same subscription pattern carries everything else a source delivers
## as it happens (`Subscription[T]`, `Subscribers[T]`, one `subscribe…`
## method per kind, each base method answering once that the source does not
## provide it):
##
## - `subscribeFleetFrames`: the fleet's frames (`FleetFrame`, nim-agents'
##   fleet-fold input) -- lifecycle frames, a new or changed session's
##   listing entry, and the events of each session's event stream;
## - `subscribeResumes`: the operator's input reached a waiting session
##   (`ResumeEvent`), what auto-switch moves on from;
## - `subscribeRecordings`: a recording of an initiative appeared or changed
##   state (`RecordingEvent`: loading, then ready or failed);
## - `subscribeResets`: the source started over (`StreamReset`): everything a
##   subscriber folded is void, and it reloads. A playback source sends one
##   when it seeks backwards; a live source may send one after it lost its
##   place in a feed.
##
## A viewmodel subscribes to the kinds it follows before it loads (so nothing
## falls between its load's answer and its subscription) and cancels when it
## is disposed.
##
## **Changes and the inbox.** A change's review record (`loadReviewRecord`),
## its diff relative to a base (`loadChangeDiff`, the file list; and
## `loadFileDiff`, one file's hunks, loaded when a reader opens the file), the
## operator's inbox in the server's order (`loadInbox`, then its events through
## `subscribeInbox`), the inbox cursor the server keeps per user and cursor
## name (`loadInboxCursor`, `moveInboxCursor`: Previous and Next ask the
## source, which answers the item landed on; a view keeps no order and no
## stack of its own), one item's page (`loadInboxItemDetail`), and the
## operator's actions (`submitAction`). An action is the only way anything is
## asked of a server: the base answers that the source does not provide it, so
## a source that has no way to send an action can never report one sent. The
## prototypes' sources answer actions from a script and never reach a server
## (`scripted_actions.nim`).

import std/json
import nim_agents/agent_harbor/[initiatives, fleet_fold, review_record,
                                change_diff, inbox, operator_actions]
import ./records
import ./recording_switcher

export records, initiatives, fleet_fold, recording_switcher, review_record,
  change_diff, inbox, operator_actions

type
  DataResult*[T] = object
    ## The answer to one load: a value, or the reason there is none.
    ok*: bool
    value*: T
    error*: string
    missing*: bool
      ## With `ok` false: what was asked for does not exist at the source
      ## (an unknown session, a 404), rather than the read failing. A view
      ## says the thing cannot be loaded, not that the server failed.

  PlanFile* = object
    ## A milestone plan of a running campaign: the file's own text, unparsed.
    name*: string          ## file name, e.g. `….milestones.org`
    campaign*: string      ## human label of the campaign it plans
    text*: string

  BranchDiff* = object
    ## A branch's change against its base, as `git diff` prints it.
    name*: string
    repository*: string    ## repository label (not a URL)
    baseRef*: string
    headRef*: string
    baseCommit*: string
    headCommit*: string
    filesChanged*: int
    insertions*: int
    deletions*: int
    unifiedDiff*: string   ## the patch text (https://git-scm.com/docs/diff-format)

  TestRunCapture* = object
    ## One test run, kept in two shapes: the events the runner emitted
    ## (`ct test run --events` JSON lines) and the same run in the test-run
    ## event shape Agent Harbor's front-ends consume.
    name*: string
    description*: string
    runnerEventsJsonl*: string
    testRunEventsJson*: string

  ScenarioRunCapture* = object
    ## What an Agent Harbor server served while an agent ran a scenario file:
    ## the session as listed, and the session's event stream.
    name*: string
    scenario*: string      ## scenario file name
    sessionJson*: string
    eventsJson*: string

  FleetCallback* = proc(answer: DataResult[FleetSnapshot]) {.closure.}
  LifecycleCallback* = proc(answer: DataResult[seq[LifecycleFrame]]) {.closure.}
  EventsCallback* = proc(answer: DataResult[SessionEventHistory]) {.closure.}
  PlansCallback* = proc(answer: DataResult[seq[PlanFile]]) {.closure.}
  DiffsCallback* = proc(answer: DataResult[seq[BranchDiff]]) {.closure.}
  TestRunsCallback* = proc(answer: DataResult[seq[TestRunCapture]]) {.closure.}
  ScenarioRunsCallback* = proc(answer: DataResult[seq[ScenarioRunCapture]]) {.closure.}
  InitiativesCallback* = proc(answer: DataResult[seq[Initiative]]) {.closure.}

  ReviewScope* = object
    ## Which change a Changes panel reviews: a task (whose plan holds the
    ## review record) and the session whose diff is the Code tab.
    taskId*: string
    sessionId*: string

  SpecApprovalRequest* = object
    ## A feedback request open for approving one spec change: what makes a
    ## pending card's `Approve` available. A plan's record says only that the
    ## change is pending; the request is the server's.
    milestoneId*: string
    spec*: string
    feedbackId*: string

  TaskReview* = object
    ## The answer to `loadReviewRecord`: the record of the task's plan and
    ## the approval requests open for its spec changes. `hasPlan` false is a
    ## task with no plan: the panel shows only Code, and Spec Changes read
    ## from the diff.
    record*: ReviewRecord
    hasPlan*: bool
    approvalRequests*: seq[SpecApprovalRequest]

  DiffBase* = object
    ## What a change is shown against: `id` is what `loadChangeDiff` takes
    ## ("" is the merge base with the landing branch), `label` what the base
    ## selector says (`Since main`, `Session changes`, a branch name).
    id*: string
    label*: string

  SessionDiff* = object
    ## The answer to `loadChangeDiff`: the change's file list against `base`
    ## (its files' hunks are loaded one file at a time, `loadFileDiff`), and
    ## the bases the base selector offers.
    diff*: ChangeDiff
    base*: DiffBase
    bases*: seq[DiffBase]

  CursorDirection* = enum
    cdNext = "next"
    cdPrev = "prev"

  CursorPosition* = object
    ## Where an inbox cursor is, as the source keeps it: the item on screen
    ## (`current.id` empty for none), whether the last move moved, and
    ## whether Previous has an item to go back to.
    moved*: bool
    current*: InboxItemRef
    canPrev*: bool

  ActionReceipt* = object
    ## The answer to a submitted action: the action as received (its
    ## secrets forgotten) and what the source said.
    action*: OperatorAction
    message*: string

  ReviewCallback* = proc(answer: DataResult[TaskReview]) {.closure.}
  SessionDiffCallback* = proc(answer: DataResult[SessionDiff]) {.closure.}
  FileDiffCallback* = proc(answer: DataResult[ChangedFile]) {.closure.}
  InboxCallback* = proc(answer: DataResult[InboxSnapshot]) {.closure.}
  CursorCallback* = proc(answer: DataResult[CursorPosition]) {.closure.}
  ItemDetailCallback* = proc(answer: DataResult[InboxItemDetail]) {.closure.}
  ActionCallback* = proc(answer: DataResult[ActionReceipt]) {.closure.}

  ProgressEvent* = object
    ## One initiative progress event: the milestone `milestoneId` of the
    ## initiative `initiativeId` now has the status `status`, as the plan
    ## writes it (`planned`, `in_progress`, `completed`, ...).
    ##
    ## With `hasCounts`, the event also carries the milestone's deliverable
    ## and test counts as the plan now reads them. A plan's scan reads a
    ## milestone's status and its counts together, and a status alone cannot
    ## keep them coherent: a milestone that was planned when the initiatives
    ## were loaded and completes later would otherwise read "completed" beside
    ## "0/2 deliverables". Without `hasCounts` the counts are left as they are.
    initiativeId*: string
    milestoneId*: string
    status*: string
    hasCounts*: bool
    deliverables*: DeliverableCounts
    verifications*: VerificationCounts

  ResumeEvent* = object
    ## The operator's input reached a waiting session (the session's events
    ## say so: `session_resumed`, `user_input`): it no longer waits.
    sessionId*: string
    atMs*: int64

  RecordingEvent* = object
    ## A recording of an initiative appeared, or its state changed (a
    ## recording loading turns ready, or fails). `entry.id` names it; an
    ## unknown id is a new recording, a known one is replaced.
    initiativeId*: string
    entry*: RecordingEntry

  StreamReset* = object
    ## The source started over: every frame and event delivered so far is
    ## void. A subscriber drops what it folded and loads again.
    atMs*: int64           ## the source's moment after the reset
    reason*: string

  ProgressDelivery* = enum
    ## What one delivered event did to its subscriber (for every kind of
    ## subscription, not only progress events).
    pdApplied = "applied"
      ## It changed the subscriber's state.
    pdUnchanged = "unchanged"
      ## It reached the subscriber and changed nothing (an initiative or
      ## milestone the subscriber does not hold, a status it already has, or
      ## an error answer).
    pdRefused = "refused"
      ## It did not reach a live subscriber: the subscription was cancelled
      ## (the subscriber disposed) before the event was delivered. Nothing
      ## moved.

  FeedCallback*[T] = proc(event: DataResult[T]): ProgressDelivery {.closure.}
    ## Called once per event. An error answer (`ok == false`) ends the
    ## stream: the source delivers nothing more on that subscription.

  Subscription*[T] = ref object
    ## A subscriber's handle on one kind of a source's events. `cancel` ends
    ## it; a source delivers through `deliver` (or `broadcast`), which
    ## reaches the subscriber only while the handle is active.
    callback: FeedCallback[T]
    cancelled: bool
    refused: int

  Subscribers*[T] = object
    ## The subscriptions a source holds for one kind, in the order they were
    ## made; the bookkeeping a source needs to implement a `subscribe…`
    ## method.
    subscriptions: seq[Subscription[T]]

  ProgressCallback* = FeedCallback[ProgressEvent]
  ProgressSubscription* = Subscription[ProgressEvent]
  ProgressSubscribers* = Subscribers[ProgressEvent]

  AgentHarborDataSource* = ref object of RootObj
    ## The interface. `label` names the source in a panel's chrome ("fleet
    ## snapshot, 2026-11-03 18:40 UTC", "live: <server>").
    label*: string

proc success*[T](value: T): DataResult[T] =
  DataResult[T](ok: true, value: value)

proc failure*[T](error: string): DataResult[T] =
  DataResult[T](ok: false, error: error)

proc missingResult*[T](reason: string): DataResult[T] =
  ## The answer for something the source does not hold (`missing`).
  DataResult[T](ok: false, error: reason, missing: true)

proc unsupported(source: AgentHarborDataSource; what: string): string =
  "the data source '" & source.label & "' does not provide " & what

method loadFleet*(source: AgentHarborDataSource; done: FleetCallback) {.base.} =
  ## The session listing (`GET /api/v1/sessions`).
  done(failure[FleetSnapshot](source.unsupported("the session list")))

method loadLifecycle*(source: AgentHarborDataSource;
                      done: LifecycleCallback) {.base.} =
  ## The lifecycle feed, as frames (`GET /api/v1/session-lifecycle/events`).
  done(failure[seq[LifecycleFrame]](source.unsupported("the lifecycle feed")))

method loadSessionEvents*(source: AgentHarborDataSource; sessionId: string;
                          done: EventsCallback) {.base.} =
  ## One session's event history (`GET /api/v1/sessions/{id}/events/history`):
  ## each event's line (`events`, newest first) and, where the source has
  ## them, the events themselves (`rawEvents`, oldest first), which a view
  ## that shows each event's details folds. A session the source does not
  ## hold is answered `missing`.
  done(failure[SessionEventHistory](source.unsupported("session events")))

method loadPlans*(source: AgentHarborDataSource; done: PlansCallback) {.base.} =
  done(failure[seq[PlanFile]](source.unsupported("campaign plans")))

method loadDiffs*(source: AgentHarborDataSource; done: DiffsCallback) {.base.} =
  done(failure[seq[BranchDiff]](source.unsupported("branch diffs")))

method loadTestRuns*(source: AgentHarborDataSource;
                     done: TestRunsCallback) {.base.} =
  done(failure[seq[TestRunCapture]](source.unsupported("test runs")))

method loadScenarioRuns*(source: AgentHarborDataSource;
                         done: ScenarioRunsCallback) {.base.} =
  done(failure[seq[ScenarioRunCapture]](source.unsupported("scenario runs")))

method loadInitiatives*(source: AgentHarborDataSource;
                        done: InitiativesCallback) {.base.} =
  ## The running plans the server knows, each with its progress and the
  ## sessions launched for it (the proposed `GET /api/v1/initiatives`).
  done(failure[seq[Initiative]](source.unsupported("initiatives")))

# ---------------------------------------------------------------------------
# Progress events
# ---------------------------------------------------------------------------

proc newSubscription*[T](callback: FeedCallback[T]): Subscription[T] =
  ## An active subscription that delivers to `callback`.
  Subscription[T](callback: callback)

proc newProgressSubscription*(callback: ProgressCallback): ProgressSubscription =
  ## An active progress subscription that delivers to `callback`.
  newSubscription[ProgressEvent](callback)

proc active*[T](subscription: Subscription[T]): bool =
  ## True until the subscription is cancelled or its stream ended.
  not subscription.isNil and not subscription.cancelled

proc refused*[T](subscription: Subscription[T]): int =
  ## How many deliveries were attempted after the subscription ended; none of
  ## them reached the subscriber.
  if subscription.isNil: 0 else: subscription.refused

proc cancel*[T](subscription: Subscription[T]) =
  ## Ends the subscription; idempotent. The callback is dropped, so nothing
  ## delivered through the handle afterwards can reach the subscriber, and
  ## the source no longer keeps the subscriber alive.
  if subscription.isNil: return
  subscription.cancelled = true
  subscription.callback = nil

proc deliver*[T](subscription: Subscription[T];
                 event: DataResult[T]): ProgressDelivery =
  ## Delivers one answer. On an ended subscription it calls nothing, counts
  ## the attempt (`refused`) and answers `pdRefused`. An error answer is
  ## delivered and then ends the subscription.
  if not subscription.active:
    if not subscription.isNil: inc subscription.refused
    return pdRefused
  let callback = subscription.callback
  if not event.ok: subscription.cancel()
  callback(event)

proc endedSubscription*[T](callback: FeedCallback[T];
                           error: string): Subscription[T] =
  ## Answers `callback` once with `error` and returns the ended subscription:
  ## what a source that cannot deliver this kind of event returns.
  result = newSubscription[T](callback)
  discard result.deliver(failure[T](error))

proc endedProgressSubscription*(callback: ProgressCallback;
                                error: string): ProgressSubscription =
  ## `endedSubscription` for progress events.
  endedSubscription[ProgressEvent](callback, error)

proc prune[T](subscribers: var Subscribers[T]) =
  var kept: seq[Subscription[T]]
  for subscription in subscribers.subscriptions:
    if subscription.active: kept.add subscription
  subscribers.subscriptions = kept

proc subscribe*[T](subscribers: var Subscribers[T];
                   callback: FeedCallback[T]): Subscription[T] =
  ## A new active subscription, held until it ends. Ended subscriptions are
  ## dropped first, so a source that never sends does not accumulate the
  ## handles of subscribers that came and went.
  subscribers.prune()
  result = newSubscription[T](callback)
  subscribers.subscriptions.add result

proc activeCount*[T](subscribers: Subscribers[T]): int =
  ## The subscriptions still active.
  for subscription in subscribers.subscriptions:
    if subscription.active: inc result

proc broadcast*[T](subscribers: var Subscribers[T];
                   event: DataResult[T]): seq[ProgressDelivery] =
  ## Delivers one answer to every active subscription, in subscription order,
  ## and returns what it did to each. Ended subscriptions are dropped first,
  ## so a cancelled subscriber is never called. A subscriber that cancels
  ## another during the delivery is honoured: the other is refused, not
  ## called. A subscription made during the delivery does not receive it.
  subscribers.prune()
  let current = subscribers.subscriptions
  for subscription in current:
    result.add subscription.deliver(event)
  subscribers.prune()

proc applyProgressEvent*(initiatives: var seq[Initiative];
                         event: ProgressEvent): bool =
  ## Applies one progress event to the initiative it names, through
  ## nim-agents' `applyMilestoneStatus` (the reducer every count derives
  ## from). True when it changed something; an unknown initiative or
  ## milestone, or a repeated status, changes nothing.
  ## An event that carries counts (`hasCounts`) also sets the milestone's
  ## deliverable and test counts; it changed something when either its status
  ## or its counts did.
  for initiative in initiatives.mitems:
    if initiative.id == event.initiativeId:
      result = initiative.progress.applyMilestoneStatus(event.milestoneId,
                                                        event.status)
      if event.hasCounts:
        for m in initiative.progress.milestones.mitems:
          if m.id == event.milestoneId and
              (m.deliverables != event.deliverables or
               m.verifications != event.verifications):
            m.deliverables = event.deliverables
            m.verifications = event.verifications
            result = true
      return
  false

method subscribeProgress*(source: AgentHarborDataSource;
                          callback: ProgressCallback): ProgressSubscription {.base.} =
  ## Initiative progress events as they happen (a milestone's status changed
  ## in a plan; the proposed initiative event stream). Returns the
  ## subscription, which the subscriber cancels when it no longer wants the
  ## events. The base answers `callback` once with an error naming the
  ## missing capability and returns an ended subscription.
  endedProgressSubscription(callback, source.unsupported("progress events"))

method subscribeFleetFrames*(source: AgentHarborDataSource;
                             callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] {.base.} =
  ## The fleet's frames as they happen: lifecycle frames
  ## (`GET /api/v1/session-lifecycle/events`), a new or changed session's
  ## listing entry, and each session's events (its event stream), in the
  ## order they happened. The base answers once that the source does not
  ## provide them.
  endedSubscription[FleetFrame](callback, source.unsupported("fleet frames"))

method subscribeResumes*(source: AgentHarborDataSource;
                         callback: FeedCallback[ResumeEvent]): Subscription[ResumeEvent] {.base.} =
  ## Waiting sessions resumed by the operator's input, as it reaches them.
  ## The base answers once that the source does not provide them.
  endedSubscription[ResumeEvent](callback, source.unsupported("session resumes"))

method subscribeRecordings*(source: AgentHarborDataSource;
                            callback: FeedCallback[RecordingEvent]): Subscription[RecordingEvent] {.base.} =
  ## The recordings of each initiative as they appear and change state. A
  ## source that holds recordings delivers the state of each one it holds at
  ## once, on subscribing, then every change. The base answers once that the
  ## source does not provide them.
  endedSubscription[RecordingEvent](callback, source.unsupported("recording states"))

method subscribeResets*(source: AgentHarborDataSource;
                        callback: FeedCallback[StreamReset]): Subscription[StreamReset] {.base.} =
  ## Told when the source starts over (a playback source seeking backwards):
  ## everything delivered so far is void and the subscriber loads again. The
  ## base answers once that the source does not provide resets: it never
  ## starts over.
  endedSubscription[StreamReset](callback, source.unsupported("stream resets"))

# ---------------------------------------------------------------------------
# Changes and the inbox
# ---------------------------------------------------------------------------

const MergeBase* = ""
  ## `DiffBase.id` of the merge base with the landing branch.

method loadReviewRecord*(source: AgentHarborDataSource; scope: ReviewScope;
                         done: ReviewCallback) {.base.} =
  ## The review record of a task's plan (the proposed
  ## `GET /api/v1/tasks/{id}/review-record`); `missing` for a task the source
  ## does not hold.
  done(failure[TaskReview](source.unsupported("review records")))

method loadChangeDiff*(source: AgentHarborDataSource; sessionId: string;
                       base: string; done: SessionDiffCallback) {.base.} =
  ## A session's change against `base` (`MergeBase`, or an id of
  ## `SessionDiff.bases`), as a file list with totals and no hunks (the
  ## proposed `GET /api/v1/sessions/{id}/diff?base=<rev>`); `missing` for a
  ## session the source does not hold.
  done(failure[SessionDiff](source.unsupported("change diffs")))

method loadFileDiff*(source: AgentHarborDataSource; sessionId, base,
                     path: string; done: FileDiffCallback) {.base.} =
  ## One file of that change, with its hunks; `missing` for a path the change
  ## does not touch.
  done(failure[ChangedFile](source.unsupported("file diffs")))

method loadInbox*(source: AgentHarborDataSource; done: InboxCallback) {.base.} =
  ## The operator's inbox, in the server's order (`GET /api/v1/inbox`).
  done(failure[InboxSnapshot](source.unsupported("the inbox")))

method subscribeInbox*(source: AgentHarborDataSource;
                       callback: FeedCallback[InboxEvent]): Subscription[InboxEvent] {.base.} =
  ## The inbox's changes as they happen (the proposed
  ## `GET /api/v1/inbox/events`): an item added, updated or resolved, and the
  ## order after it. The base answers once that the source does not provide
  ## them.
  endedSubscription[InboxEvent](callback, source.unsupported("inbox events"))

method loadInboxCursor*(source: AgentHarborDataSource; name: string;
                        done: CursorCallback) {.base.} =
  ## Where the inbox cursor `name` is (the proposed
  ## `GET /api/v1/inbox/cursors/{name}`), so a front-end that opens later
  ## joins the operator where they are.
  done(failure[CursorPosition](source.unsupported("inbox cursors")))

method moveInboxCursor*(source: AgentHarborDataSource; name: string;
                        direction: CursorDirection; done: CursorCallback) {.base.} =
  ## Moves the inbox cursor `name` (the proposed
  ## `POST /api/v1/inbox/cursors/{name}/next` and `/prev`) and answers where
  ## it landed: Next goes to the top of the current order excluding the item
  ## on screen, Previous back along the items visited.
  done(failure[CursorPosition](source.unsupported("inbox cursors")))

method loadInboxItemDetail*(source: AgentHarborDataSource; item: InboxItemRef;
                            done: ItemDetailCallback) {.base.} =
  ## One item's page (a proposed read); `missing` for an item the source
  ## does not hold.
  done(failure[InboxItemDetail](source.unsupported("inbox item pages")))

method submitAction*(source: AgentHarborDataSource; action: OperatorAction;
                     done: ActionCallback) {.base.} =
  ## Asks the server to do what the operator pressed (`routeOf` names the
  ## route). The base sends nothing and answers that the source does not
  ## provide actions: a view then shows the press as failed, never as sent.
  done(failure[ActionReceipt](source.unsupported("operator actions")))

# ---------------------------------------------------------------------------
# State sources: the states no capture shows
# ---------------------------------------------------------------------------

type
  PendingDataSource* = ref object of AgentHarborDataSource
    ## Never answers: a server that accepted the request and has not replied.
    ## Holds the callbacks so a test can prove none was called.
    pendingFleet*: seq[FleetCallback]
    pendingInitiatives*: seq[InitiativesCallback]
    pendingReviews*: seq[ReviewCallback]
    pendingDiffs*: seq[SessionDiffCallback]
    pendingInbox*: seq[InboxCallback]
    pendingActions*: seq[ActionCallback]
    inboxSubscribers*: Subscribers[InboxEvent]
    progressSubscribers*: ProgressSubscribers
      ## Accepted and never sent to: a server whose event stream is open and
      ## silent.

  FailingDataSource* = ref object of AgentHarborDataSource
    ## Answers every load with the same error.
    error*: string

  SnapshotDataSource* = ref object of AgentHarborDataSource
    ## Answers the session list with a given snapshot (an empty fleet, or a
    ## synthetic one larger than any capture), the initiatives with given
    ## ones, and a session's event history with given events
    ## (`sessionEvents`, each session's events oldest first; a session it
    ## does not hold is answered `missing`). Its progress stream sends only
    ## what the host sends through it (`sendProgress`); left alone, it never
    ## sends.
    snapshot*: FleetSnapshot
    initiatives*: seq[Initiative]
    sessionEvents*: seq[(string, seq[JsonNode])]
    progressSubscribers*: ProgressSubscribers

  TimelineDataSource* = ref object of SnapshotDataSource
    ## A `SnapshotDataSource` that also has a fleet-frame stream, which sends
    ## only what the host sends through it (`sendFrame`): one session's
    ## events arriving after its history was read, for the timeline's
    ## stories and tests.
    frameSubscribers*: Subscribers[FleetFrame]

proc newPendingDataSource*(label = "waiting for the server"): PendingDataSource =
  PendingDataSource(label: label)

method loadFleet*(source: PendingDataSource; done: FleetCallback) =
  source.pendingFleet.add(done)

method loadLifecycle*(source: PendingDataSource; done: LifecycleCallback) =
  discard

method loadSessionEvents*(source: PendingDataSource; sessionId: string;
                          done: EventsCallback) =
  discard

method loadInitiatives*(source: PendingDataSource; done: InitiativesCallback) =
  source.pendingInitiatives.add(done)

method subscribeProgress*(source: PendingDataSource;
                          callback: ProgressCallback): ProgressSubscription =
  ## Accepted; never sends.
  source.progressSubscribers.subscribe(callback)

method loadReviewRecord*(source: PendingDataSource; scope: ReviewScope;
                         done: ReviewCallback) =
  source.pendingReviews.add done

method loadChangeDiff*(source: PendingDataSource; sessionId, base: string;
                       done: SessionDiffCallback) =
  source.pendingDiffs.add done

method loadInbox*(source: PendingDataSource; done: InboxCallback) =
  source.pendingInbox.add done

method subscribeInbox*(source: PendingDataSource;
                       callback: FeedCallback[InboxEvent]): Subscription[InboxEvent] =
  ## Accepted; never sends.
  source.inboxSubscribers.subscribe(callback)

method loadInboxCursor*(source: PendingDataSource; name: string;
                        done: CursorCallback) =
  discard

method moveInboxCursor*(source: PendingDataSource; name: string;
                        direction: CursorDirection; done: CursorCallback) =
  discard

method loadInboxItemDetail*(source: PendingDataSource; item: InboxItemRef;
                            done: ItemDetailCallback) =
  discard

method loadFileDiff*(source: PendingDataSource; sessionId, base, path: string;
                     done: FileDiffCallback) =
  discard

method submitAction*(source: PendingDataSource; action: OperatorAction;
                     done: ActionCallback) =
  ## Accepted; never answered: an action that stays `submitting`.
  source.pendingActions.add done

proc newFailingDataSource*(error: string;
                           label = "unreachable server"): FailingDataSource =
  FailingDataSource(label: label, error: error)

method loadFleet*(source: FailingDataSource; done: FleetCallback) =
  done(failure[FleetSnapshot](source.error))

method loadLifecycle*(source: FailingDataSource; done: LifecycleCallback) =
  done(failure[seq[LifecycleFrame]](source.error))

method loadSessionEvents*(source: FailingDataSource; sessionId: string;
                          done: EventsCallback) =
  done(failure[SessionEventHistory](source.error))

method loadInitiatives*(source: FailingDataSource; done: InitiativesCallback) =
  done(failure[seq[Initiative]](source.error))

method subscribeProgress*(source: FailingDataSource;
                          callback: ProgressCallback): ProgressSubscription =
  ## Answers once with the source's error; the subscription is ended.
  endedProgressSubscription(callback, source.error)

method subscribeFleetFrames*(source: FailingDataSource;
                             callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  endedSubscription[FleetFrame](callback, source.error)

method subscribeResumes*(source: FailingDataSource;
                         callback: FeedCallback[ResumeEvent]): Subscription[ResumeEvent] =
  endedSubscription[ResumeEvent](callback, source.error)

method subscribeRecordings*(source: FailingDataSource;
                            callback: FeedCallback[RecordingEvent]): Subscription[RecordingEvent] =
  endedSubscription[RecordingEvent](callback, source.error)

method subscribeResets*(source: FailingDataSource;
                        callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  endedSubscription[StreamReset](callback, source.error)

method loadReviewRecord*(source: FailingDataSource; scope: ReviewScope;
                         done: ReviewCallback) =
  done(failure[TaskReview](source.error))

method loadChangeDiff*(source: FailingDataSource; sessionId, base: string;
                       done: SessionDiffCallback) =
  done(failure[SessionDiff](source.error))

method loadFileDiff*(source: FailingDataSource; sessionId, base, path: string;
                     done: FileDiffCallback) =
  done(failure[ChangedFile](source.error))

method loadInbox*(source: FailingDataSource; done: InboxCallback) =
  done(failure[InboxSnapshot](source.error))

method subscribeInbox*(source: FailingDataSource;
                       callback: FeedCallback[InboxEvent]): Subscription[InboxEvent] =
  endedSubscription[InboxEvent](callback, source.error)

method loadInboxCursor*(source: FailingDataSource; name: string;
                        done: CursorCallback) =
  done(failure[CursorPosition](source.error))

method moveInboxCursor*(source: FailingDataSource; name: string;
                        direction: CursorDirection; done: CursorCallback) =
  done(failure[CursorPosition](source.error))

method loadInboxItemDetail*(source: FailingDataSource; item: InboxItemRef;
                            done: ItemDetailCallback) =
  done(failure[InboxItemDetail](source.error))

method submitAction*(source: FailingDataSource; action: OperatorAction;
                     done: ActionCallback) =
  done(failure[ActionReceipt](source.error))

proc newSnapshotDataSource*(snapshot: FleetSnapshot;
                            label = "synthetic fleet";
                            initiatives: seq[Initiative] = @[]): SnapshotDataSource =
  SnapshotDataSource(label: label, snapshot: snapshot, initiatives: initiatives)

method loadFleet*(source: SnapshotDataSource; done: FleetCallback) =
  done(success(source.snapshot))

method loadInitiatives*(source: SnapshotDataSource; done: InitiativesCallback) =
  done(success(source.initiatives))

proc historyOf*(sessionId: string; eventsOldestFirst: openArray[JsonNode];
                startMs = 0'i64): SessionEventHistory =
  ## A session's event history as a server answers it: the events' lines
  ## newest first (timestamps placed by `startMs`, the session's start), and
  ## the events themselves oldest first.
  result = SessionEventHistory(sessionId: sessionId,
                               totalCount: eventsOldestFirst.len)
  for i in countdown(eventsOldestFirst.high, 0):
    var line = activityFromJson(eventsOldestFirst[i])
    line.timestampMs = startMs + eventsOldestFirst[i]{"timestamp"}.getBiggestInt(0).int64 div 1000
    result.events.add line
  for event in eventsOldestFirst: result.rawEvents.add event

method loadSessionEvents*(source: SnapshotDataSource; sessionId: string;
                          done: EventsCallback) =
  ## The session's given events; `missing` for a session it does not hold.
  for (id, events) in source.sessionEvents:
    if id == sessionId:
      done(success(historyOf(sessionId, events)))
      return
  done(missingResult[SessionEventHistory]("no session " & sessionId &
                                          " in " & source.label))

proc newTimelineDataSource*(sessionEvents: seq[(string, seq[JsonNode])];
                            label = "invented timeline"): TimelineDataSource =
  ## Serves each session's given events (oldest first), and sends the frames
  ## the host sends through `sendFrame`.
  TimelineDataSource(label: label, sessionEvents: sessionEvents)

method subscribeFleetFrames*(source: TimelineDataSource;
                             callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  ## Accepted; sends what the host sends through `sendFrame`.
  source.frameSubscribers.subscribe(callback)

proc sendFrame*(source: TimelineDataSource;
                frame: FleetFrame): seq[ProgressDelivery] =
  ## Delivers one fleet frame to every active subscriber. An event frame is
  ## also added to the session's events, so a later `loadSessionEvents`
  ## answers the history after it, as a server's would.
  if frame.kind == ffEvent:
    var found = false
    for entry in source.sessionEvents.mitems:
      if entry[0] == frame.sessionId:
        entry[1].add frame.event
        found = true
    if not found: source.sessionEvents.add (frame.sessionId, @[frame.event])
  source.frameSubscribers.broadcast(success(frame))

method subscribeProgress*(source: SnapshotDataSource;
                          callback: ProgressCallback): ProgressSubscription =
  ## Accepted; sends what the host sends through `sendProgress`, nothing
  ## otherwise.
  source.progressSubscribers.subscribe(callback)

proc sendProgress*(source: SnapshotDataSource;
                   event: ProgressEvent): seq[ProgressDelivery] =
  ## Applies one progress event to the source's own `initiatives` (so a
  ## later `loadInitiatives` answers the state after it, as a server's list
  ## would), then delivers it to every active subscriber, in subscription
  ## order, and returns what it did to each.
  discard source.initiatives.applyProgressEvent(event)
  source.progressSubscribers.broadcast(success(event))
