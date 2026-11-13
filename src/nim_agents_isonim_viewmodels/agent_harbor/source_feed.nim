## `SourceFeed[T]`: a viewmodel's subscription to one kind of its source's
## events (`AgentHarborDataSource.subscribeProgress`, `subscribeFleetFrames`,
## `subscribeResumes`, `subscribeRecordings`, `subscribeResets`), so that a
## source, not the host, moves the viewmodel.
##
## A viewmodel owns one feed per kind it follows. `open` subscribes
## (cancelling the previous subscription, so a reload never leaves two),
## `close` cancels for good; a viewmodel closes its feeds from its reactive
## root's cleanup, so disposing the viewmodel unsubscribes it. A feed reports
## in the viewmodels' usual style, an `AsyncState` and an error text: `asIdle`
## before the first `open`, `asReady` while the stream is open (whether or not
## it ever sends), `asError` with the source's reason when it does not provide
## the events or its stream ended with an error.
##
## An event that reaches the feed's callback after `close`, or after a newer
## `open` replaced the subscription, moves nothing: it is answered
## `pdRefused` and counted (`lateEvents`). Sources that deliver through
## `Subscription.deliver` cannot call it then at all; the guard is for a
## source that keeps the callback itself.

import isonim/core/signals
import isonim/viewmodel
import ./data_source

type
  SourceFeed*[T] = ref object
    subscription: Subscription[T]
    generation: int        ## moves on every `open` and on `close`
    closed: bool
    late: int
    state*: Signal[AsyncState]
    error*: Signal[string]

  Subscribe*[T] = proc(callback: FeedCallback[T]): Subscription[T]
    ## How a feed subscribes: one of the source's `subscribe…` methods,
    ## bound to the source.

proc newSourceFeed*[T](): SourceFeed[T] =
  SourceFeed[T](state: createSignal(asIdle), error: createSignal(""))

proc closed*[T](feed: SourceFeed[T]): bool = feed.closed

proc lateEvents*[T](feed: SourceFeed[T]): int =
  ## Events that reached the callback of a closed or replaced subscription;
  ## none of them moved the viewmodel.
  feed.late

proc subscribed*[T](feed: SourceFeed[T]): bool =
  ## True while the feed holds an active subscription.
  feed.subscription.active

proc open*[T](feed: SourceFeed[T]; subscribe: Subscribe[T];
              apply: proc(event: T): bool) =
  ## Subscribes through `subscribe`, each event applied by `apply` (true
  ## when it changed the viewmodel). Replaces the previous subscription;
  ## does nothing once the feed is closed.
  if feed.closed or subscribe.isNil: return
  feed.subscription.cancel()
  inc feed.generation
  let generation = feed.generation
  feed.error.val = ""
  feed.state.val = asReady
  let target = feed
  feed.subscription = subscribe proc(answer: DataResult[T]): ProgressDelivery =
    if target.closed or generation != target.generation:
      inc target.late
      return pdRefused
    if not answer.ok:
      target.error.val = answer.error
      target.state.val = asError
      return pdUnchanged
    if apply(answer.value): pdApplied else: pdUnchanged

proc close*[T](feed: SourceFeed[T]) =
  ## Unsubscribes for good; idempotent.
  feed.closed = true
  inc feed.generation
  feed.subscription.cancel()

# ---------------------------------------------------------------------------
# One feed per kind, bound to a source
# ---------------------------------------------------------------------------

proc openFleetFrames*(feed: SourceFeed[FleetFrame]; source: AgentHarborDataSource;
                      apply: proc(frame: FleetFrame): bool) =
  ## Follows `source`'s fleet frames.
  if source.isNil: return
  feed.open(proc(cb: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
    source.subscribeFleetFrames(cb), apply)

proc openResumes*(feed: SourceFeed[ResumeEvent]; source: AgentHarborDataSource;
                  apply: proc(event: ResumeEvent): bool) =
  ## Follows `source`'s session resumes.
  if source.isNil: return
  feed.open(proc(cb: FeedCallback[ResumeEvent]): Subscription[ResumeEvent] =
    source.subscribeResumes(cb), apply)

proc openRecordings*(feed: SourceFeed[RecordingEvent]; source: AgentHarborDataSource;
                     apply: proc(event: RecordingEvent): bool) =
  ## Follows `source`'s recording states.
  if source.isNil: return
  feed.open(proc(cb: FeedCallback[RecordingEvent]): Subscription[RecordingEvent] =
    source.subscribeRecordings(cb), apply)

proc openResets*(feed: SourceFeed[StreamReset]; source: AgentHarborDataSource;
                 apply: proc(event: StreamReset): bool) =
  ## Follows `source`'s resets.
  if source.isNil: return
  feed.open(proc(cb: FeedCallback[StreamReset]): Subscription[StreamReset] =
    source.subscribeResets(cb), apply)

proc openProgress*(feed: SourceFeed[ProgressEvent]; source: AgentHarborDataSource;
                   apply: proc(event: ProgressEvent): bool) =
  ## Follows `source`'s initiative progress events.
  if source.isNil: return
  feed.open(proc(cb: FeedCallback[ProgressEvent]): Subscription[ProgressEvent] =
    source.subscribeProgress(cb), apply)

# ---------------------------------------------------------------------------
# A viewmodel's feeds
# ---------------------------------------------------------------------------

type
  SourceFeeds* = ref object
    ## The feeds of one viewmodel, one per kind; a viewmodel opens those it
    ## follows on `load` and leaves the others idle.
    frames*: SourceFeed[FleetFrame]
    resumes*: SourceFeed[ResumeEvent]
    recordings*: SourceFeed[RecordingEvent]
    progress*: SourceFeed[ProgressEvent]
    resets*: SourceFeed[StreamReset]

proc newSourceFeeds*(): SourceFeeds =
  SourceFeeds(frames: newSourceFeed[FleetFrame](),
              resumes: newSourceFeed[ResumeEvent](),
              recordings: newSourceFeed[RecordingEvent](),
              progress: newSourceFeed[ProgressEvent](),
              resets: newSourceFeed[StreamReset]())

proc close*(feeds: SourceFeeds) =
  ## Unsubscribes every feed for good; idempotent.
  if feeds.isNil: return
  feeds.frames.close()
  feeds.resumes.close()
  feeds.recordings.close()
  feeds.progress.close()
  feeds.resets.close()

proc lateEvents*(feeds: SourceFeeds): int =
  ## Events of any kind that reached a closed or replaced subscription.
  feeds.frames.lateEvents + feeds.resumes.lateEvents +
    feeds.recordings.lateEvents + feeds.progress.lateEvents +
    feeds.resets.lateEvents
