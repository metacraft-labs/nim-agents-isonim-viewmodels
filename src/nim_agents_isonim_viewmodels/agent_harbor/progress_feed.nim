## `ProgressFeed`: a viewmodel's subscription to its source's initiative
## progress events (`AgentHarborDataSource.subscribeProgress`), shared by the
## Initiatives and Initiative Progress viewmodels and the initiative tab
## strips, so that a source, not the host, moves them. It is the progress
## kind of the generic `SourceFeed` (`source_feed.nim`), which says how a
## feed opens, reports and closes.

import ./data_source
import ./source_feed

export source_feed

type
  ProgressFeed* = SourceFeed[ProgressEvent]

proc newProgressFeed*(): ProgressFeed =
  newSourceFeed[ProgressEvent]()

proc open*(feed: ProgressFeed; source: AgentHarborDataSource;
           apply: proc(event: ProgressEvent): bool) =
  ## Subscribes to `source`'s progress events, each applied by `apply` (true
  ## when it changed the viewmodel). Replaces the previous subscription; does
  ## nothing once the feed is closed.
  feed.openProgress(source, apply)
