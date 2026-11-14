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

import nim_agents/agent_harbor/[initiatives, fleet_fold]
import ./records
import ./recording_switcher

export records, initiatives, fleet_fold, recording_switcher

type
  DataResult*[T] = object
    ## The answer to one load: a value, or the reason there is none.
    ok*: bool
    value*: T
    error*: string

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
  ## One session's event history (`GET /api/v1/sessions/{id}/events/history`).
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
# State sources: the states no capture shows
# ---------------------------------------------------------------------------

type
  PendingDataSource* = ref object of AgentHarborDataSource
    ## Never answers: a server that accepted the request and has not replied.
    ## Holds the callbacks so a test can prove none was called.
    pendingFleet*: seq[FleetCallback]
    pendingInitiatives*: seq[InitiativesCallback]
    progressSubscribers*: ProgressSubscribers
      ## Accepted and never sent to: a server whose event stream is open and
      ## silent.

  FailingDataSource* = ref object of AgentHarborDataSource
    ## Answers every load with the same error.
    error*: string

  SnapshotDataSource* = ref object of AgentHarborDataSource
    ## Answers the session list with a given snapshot (an empty fleet, or a
    ## synthetic one larger than any capture), and the initiatives with given
    ## ones. Its progress stream sends only what the host sends through it
    ## (`sendProgress`); left alone, it never sends.
    snapshot*: FleetSnapshot
    initiatives*: seq[Initiative]
    progressSubscribers*: ProgressSubscribers

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

proc newSnapshotDataSource*(snapshot: FleetSnapshot;
                            label = "synthetic fleet";
                            initiatives: seq[Initiative] = @[]): SnapshotDataSource =
  SnapshotDataSource(label: label, snapshot: snapshot, initiatives: initiatives)

method loadFleet*(source: SnapshotDataSource; done: FleetCallback) =
  done(success(source.snapshot))

method loadInitiatives*(source: SnapshotDataSource; done: InitiativesCallback) =
  done(success(source.initiatives))

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
