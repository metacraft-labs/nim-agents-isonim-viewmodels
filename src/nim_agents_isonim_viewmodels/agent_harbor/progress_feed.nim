## `ProgressFeed`: a viewmodel's subscription to its source's initiative
## progress events (`AgentHarborDataSource.subscribeProgress`), shared by the
## Initiatives and Initiative Progress viewmodels so that a source, not the
## host, moves them.
##
## A viewmodel owns one feed. `open` subscribes (cancelling the previous
## subscription, so a reload never leaves two), `close` cancels for good; a
## viewmodel closes its feed from its reactive root's cleanup, so disposing
## the viewmodel unsubscribes it. The feed reports in the viewmodels' usual
## style, an `AsyncState` and an error text: `asIdle` before the first
## `open`, `asReady` while the stream is open (whether or not it ever sends),
## `asError` with the source's reason when it does not provide the events or
## its stream ended with an error.
##
## An event that reaches the feed's callback after `close`, or after a newer
## `open` replaced the subscription, moves nothing: it is answered
## `pdRefused` and counted (`lateEvents`). Sources that deliver through
## `ProgressSubscription.deliver` cannot call it then at all; the guard is
## for a source that keeps the callback itself.

import isonim/core/signals
import isonim/viewmodel
import ./data_source

type
  ProgressFeed* = ref object
    subscription: ProgressSubscription
    generation: int        ## moves on every `open` and on `close`
    closed: bool
    late: int
    state*: Signal[AsyncState]
    error*: Signal[string]

proc newProgressFeed*(): ProgressFeed =
  ProgressFeed(state: createSignal(asIdle), error: createSignal(""))

proc closed*(feed: ProgressFeed): bool = feed.closed

proc lateEvents*(feed: ProgressFeed): int =
  ## Events that reached the callback of a closed or replaced subscription;
  ## none of them moved the viewmodel.
  feed.late

proc subscribed*(feed: ProgressFeed): bool =
  ## True while the feed holds an active subscription.
  feed.subscription.active

proc open*(feed: ProgressFeed; source: AgentHarborDataSource;
           apply: proc(event: ProgressEvent): bool) =
  ## Subscribes to `source`'s progress events, each applied by `apply` (true
  ## when it changed the viewmodel). Replaces the previous subscription; does
  ## nothing once the feed is closed.
  if feed.closed or source.isNil: return
  feed.subscription.cancel()
  inc feed.generation
  let generation = feed.generation
  feed.error.val = ""
  feed.state.val = asReady
  let target = feed
  feed.subscription = source.subscribeProgress proc(
      answer: DataResult[ProgressEvent]): ProgressDelivery =
    if target.closed or generation != target.generation:
      inc target.late
      return pdRefused
    if not answer.ok:
      target.error.val = answer.error
      target.state.val = asError
      return pdUnchanged
    if apply(answer.value): pdApplied else: pdUnchanged

proc close*(feed: ProgressFeed) =
  ## Unsubscribes for good; idempotent.
  feed.closed = true
  inc feed.generation
  feed.subscription.cancel()
