## The live data source: the fleet of a real Agent Harbor server, over
## nim-agent-harbor's client (CTF-M3 slice 2).
##
## It serves the fleet and its lifecycle, which is what the session strip
## and the fleet panels read:
##
## - `loadFleet` answers from `GET /api/v1/sessions`: its first page, the
##   newest `fleetPageSize` sessions (200), with the server's `total`, so a
##   view can say it shows the newest N of M. A fleet can hold tens of
##   thousands of ended sessions, and reading every page takes minutes; the
##   sessions that are not ended will be added through the list's `status`
##   filter once the server answers it promptly. A refused or unreadable
##   listing answers an error, never an empty fleet.
## - `subscribeFleetFrames` delivers each frame of
##   `GET /api/v1/session-lifecycle/events` as a lifecycle `FleetFrame`.
## - `subscribeResets` delivers a `StreamReset` whenever the feed answers
##   `resync`: the server could not replay from the source's cursor (or the
##   source had none), so what a subscriber folded may be stale and it loads
##   again. The first connection always starts with one.
## - The inbox and its cursor (CTF-M7): `loadInboxRead` answers from
##   `GET /api/v1/inbox?cursor=<name>`; `postInboxCursor` sends
##   `POST /api/v1/inbox/cursors/{name}/next` or `/prev` on one poster worker,
##   in the order pressed, so a viewmodel never waits on it;
##   `subscribeInboxNotices` delivers each frame of
##   `GET /api/v1/inbox/events` as an `InboxNotice`, and a notice whose
##   `nextChangeAt` passes (an item's time-based warmth changes) as a
##   `changed` notice of its own, so a viewmodel reads the inbox again. The
##   inbox stream starts with its first subscriber; a server that answers it
##   404 has no inbox stream, which the source says (`lastError(skInbox)`)
##   and stops asking for.
## - Every other load and subscription answers through the base methods,
##   that the source does not provide it, so nothing renders as empty.
##
## **Threads.** Viewmodels are single-threaded and the feed blocks, so the
## network runs on worker threads and the host delivers on its own thread:
## one stream worker per followed stream for the source's life, and each
## `loadFleet` on a short-lived worker. Workers only read the network and post
## plain messages to a channel; nothing they hold is shared. The host calls
## `pump()` from its UI loop, which drains the channel and calls the
## subscribers and the load callbacks on the host's thread. No callback is
## ever called from a worker, and no load answers inside the load call.
##
## **Reconnecting.** When the feed ends, stalls past `readTimeoutMs` or is
## refused, the feed worker connects again with the last cursor it read, so
## the server replays what was missed and answers `caught_up`; only when the
## server cannot replay does a `resync`, and so a reset, follow. Between
## failed attempts it waits `minBackoffMs`, doubling to `maxBackoffMs`; a
## connection that delivered a frame resets the wait.
##
## **Closing.** `close()` returns at once: it tells the workers to stop and
## drops the subscribers, and nothing is delivered after it. A worker inside
## a blocking read leaves at that read's deadline (the feed's
## `readTimeoutMs`, a load's control deadline); the source keeps it, and its
## channel, until it has, and joins it then.
##
## **Streams.** Each followed stream is a `StreamKind` with its own worker,
## connection state and cursor; its messages carry the kind, and `pump()`
## dispatches on it. The lifecycle feed starts with the source; the inbox's
## starts with its first subscriber.
##
## Native only: the JavaScript front-end is fed by its host.

when defined(js):
  {.error: "the live Agent Harbor data source is native only".}

import std/[atomics, json, os, strutils, tables, times]
import nim_agent_harbor
import nim_agents/agent_harbor/[fleet_records, fleet_fold, inbox_cursor]
import ./data_source

type
  StreamKind* = enum
    ## A stream the source follows, each on its own worker.
    skLifecycle = "lifecycle"  ## `GET /api/v1/session-lifecycle/events`
    skInbox = "inbox"          ## `GET /api/v1/inbox/events`

  MessageKind = enum
    mkConnecting   ## the feed worker opens a connection
    mkConnected    ## that connection delivered its first frame
    mkDisconnected ## it ended or failed; `text` says why
    mkFrame        ## one feed frame: `event`, `data`, `id`
    mkFleet        ## a listing answered: `ok`, then `text` is the JSON body
                   ## or the error
    mkInboxRead    ## an inbox read answered (`loadId`), as `mkFleet`
    mkCursorAnswer ## a cursor post answered (`loadId` is the post's), as
                   ## `mkFleet`
    mkStreamGone   ## the server does not serve the stream: `text` says why

  Message = object
    kind: MessageKind
    stream: StreamKind     ## which stream posted it (stream messages)
    event, data, id: string
    ok: bool
    text: string
    loadId: int

  PostJob = object
    ## One cursor post for the poster worker.
    id: int
    cursorName: string
    direction: PressDirection
    expectedVersion: int64
    landedOn: string

  Shared = object
    ## What the host and the workers share. Allocated in shared memory and
    ## freed only when every worker that holds it has been joined.
    channel: Channel[Message]
    posts: Channel[PostJob]
      ## The cursor posts, in the order pressed, for the poster worker.
    stop: Atomic[bool]

  Connection = object
    baseUrl: string
    authKind: AuthKind
    token: string

  StreamArgs = object
    kind: StreamKind
    conn: Connection
    shared: ptr Shared
    after: string
    readTimeoutMs, minBackoffMs, maxBackoffMs: int

  LoadWork = enum
    lwFleet      ## read the newest page of sessions
    lwInboxRead  ## read the inbox with a cursor
    lwPoster     ## send the cursor posts until the source closes

  LoadArgs = object
    conn: Connection
    shared: ptr Shared
    loadId: int
    pageSize: int
    work: LoadWork
    cursorName: string

  StreamState = object
    connected: bool
    error: string
    connections: int
    cursor: string

  LiveDataSource* = ref object of AgentHarborDataSource
    conn: Connection
    shared: ptr Shared
    streams: seq[ref Thread[StreamArgs]]
    states: array[StreamKind, StreamState]
    loads: seq[ref Thread[LoadArgs]]
    pendingLoads: Table[int, FleetCallback]
    nextLoad: int
    pageSize: int
    frameSubscribers: Subscribers[FleetFrame]
    resetSubscribers: Subscribers[StreamReset]
    noticeSubscribers: Subscribers[InboxNotice]
    pendingReads: Table[int, InboxReadCallback]
    pendingPosts: Table[int, CursorAnswerCallback]
    streamArgs: StreamArgs
      ## The settings the source's streams start with.
    inboxStarted, posterStarted: bool
    nextInboxChangeMs: int64
      ## When the next item's warmth changes (0 for none known).
    closed: bool

  Retired = object
    ## A closed source's workers that had not finished, and their channel.
    shared: ptr Shared
    streams: seq[ref Thread[StreamArgs]]
    loads: seq[ref Thread[LoadArgs]]

var retired {.threadvar.}: seq[Retired]

proc nowMs(): int64 = int64(epochTime() * 1000)

proc clientOf(conn: Connection): HarborClient =
  newNativeHarborClient(conn.baseUrl,
    HarborAuth(kind: conn.authKind, token: conn.token))

proc stopping(shared: ptr Shared): bool = shared.stop.load()

proc post(shared: ptr Shared; message: sink Message) =
  shared.channel.send(message)

# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------

proc waitOrStop(shared: ptr Shared; ms: int) =
  var left = ms
  while left > 0 and not shared.stopping:
    sleep(min(left, 20))
    left -= 20

proc followLifecycle(args: StreamArgs) =
  ## Follows the lifecycle feed until told to stop, reconnecting from the
  ## last cursor read.
  block:
    var client = clientOf(args.conn)
    client.frameStreamTransport = nativeHarborFrameStream(args.readTimeoutMs)
    let shared = args.shared
    var cursor = args.after
    var wait = args.minBackoffMs
    while not shared.stopping:
      shared.post Message(kind: mkConnecting, stream: args.kind)
      var delivered = false
      try:
        client.followSessionLifecycle(proc(frame: SseFrame): bool =
          if shared.stopping: return false
          if not delivered:
            delivered = true
            shared.post Message(kind: mkConnected, stream: args.kind)
          # The cursor to resume from: a lifecycle frame's id, or the
          # cursor in a resync or caught_up frame's data.
          let decoded = lifecycleFrameOf(frame.event, frame.data, frame.id)
          if decoded.cursor.len > 0: cursor = decoded.cursor
          shared.post Message(kind: mkFrame, stream: args.kind, event: frame.event,
            data: frame.data, id: frame.id)
          true, after = cursor)
        if not shared.stopping:
          shared.post Message(kind: mkDisconnected, stream: args.kind,
            text: "the feed ended")
      except CatchableError as error:
        if not shared.stopping:
          shared.post Message(kind: mkDisconnected, stream: args.kind,
            text: error.msg)
      if delivered: wait = args.minBackoffMs
      shared.waitOrStop(wait)
      if not delivered: wait = min(wait * 2, args.maxBackoffMs)

proc followInboxStream(args: StreamArgs) =
  ## Follows the inbox stream until told to stop, reconnecting with the id of
  ## the last frame read (the stream starts over with a `resync` either way).
  ## A server that answers 404 has no inbox stream: said once, then left.
  block:
    var client = clientOf(args.conn)
    client.frameStreamTransport = nativeHarborFrameStream(args.readTimeoutMs)
    let shared = args.shared
    var lastId = args.after
    var wait = args.minBackoffMs
    while not shared.stopping:
      shared.post Message(kind: mkConnecting, stream: args.kind)
      var delivered = false
      try:
        client.followInbox(proc(frame: SseFrame): bool =
          if shared.stopping: return false
          if not delivered:
            delivered = true
            shared.post Message(kind: mkConnected, stream: args.kind)
          if frame.id.len > 0: lastId = frame.id
          shared.post Message(kind: mkFrame, stream: args.kind, event: frame.event,
            data: frame.data, id: frame.id)
          true, lastEventId = lastId)
        if not shared.stopping:
          shared.post Message(kind: mkDisconnected, stream: args.kind,
            text: "the inbox stream ended")
      except CatchableError as error:
        if shared.stopping: break
        if "(HTTP 404)" in error.msg:
          shared.post Message(kind: mkStreamGone, stream: args.kind,
            text: "the server does not serve the inbox stream: " & error.msg)
          break
        shared.post Message(kind: mkDisconnected, stream: args.kind,
          text: error.msg)
      if delivered: wait = args.minBackoffMs
      shared.waitOrStop(wait)
      if not delivered: wait = min(wait * 2, args.maxBackoffMs)

proc followStream(args: StreamArgs) {.thread.} =
  ## A stream worker: follows the stream its kind names.
  {.cast(gcsafe).}:
    case args.kind
    of skLifecycle: followLifecycle(args)
    of skInbox: followInboxStream(args)

proc readInbox(args: LoadArgs) =
  ## Reads the inbox with the cursor and posts the answer as JSON text.
  var message = Message(kind: mkInboxRead, loadId: args.loadId)
  try:
    message.text = $clientOf(args.conn).getInbox(
      InboxQuery(cursor: args.cursorName))
    message.ok = true
  except CatchableError as error:
    message.text = error.msg
  if not args.shared.stopping:
    args.shared.post message

proc sendPosts(args: LoadArgs) =
  ## The poster: sends the cursor posts one at a time, in the order they were
  ## pressed, until the source closes, and posts each answer as JSON text.
  let client = clientOf(args.conn)
  let shared = args.shared
  while not shared.stopping:
    let (got, job) = shared.posts.tryRecv()
    if not got:
      shared.waitOrStop(10)
      continue
    var message = Message(kind: mkCursorAnswer, loadId: job.id)
    try:
      let direction = if job.direction == pdNext: icNext else: icPrev
      message.text = $client.moveInboxCursor(job.cursorName,
        cursorMove(direction, job.expectedVersion, job.landedOn))
      message.ok = true
    except CatchableError as error:
      message.text = error.msg
    if not shared.stopping:
      shared.post message

proc listFleet(args: LoadArgs)

proc loadOnce(args: LoadArgs) {.thread.} =
  ## A load worker: a listing, an inbox read, or the poster.
  {.cast(gcsafe).}:
    case args.work
    of lwFleet: listFleet(args)
    of lwInboxRead: readInbox(args)
    of lwPoster: sendPosts(args)

proc listFleet(args: LoadArgs) =
  ## A listing: read the newest page and post it as JSON text, with the
  ## server's total.
  block:
    var message = Message(kind: mkFleet, loadId: args.loadId)
    try:
      let page = clientOf(args.conn).listSessions(
        SessionListQuery(page: 1, perPage: args.pageSize))
      var node = newJObject()
      var list = newJArray()
      for item in page.items: list.add item
      node["items"] = list
      node["total"] = %page.total
      message.ok = true
      message.text = $node
    except CatchableError as error:
      message.text = error.msg
    if not args.shared.stopping:
      args.shared.post message

# ---------------------------------------------------------------------------
# Retiring workers after close
# ---------------------------------------------------------------------------

proc finished[T](thread: ref Thread[T]): bool =
  thread.isNil or not thread[].running

proc reapRetired() =
  ## Joins the workers of closed sources that have finished, and frees their
  ## channel once all of a source's have.
  var kept: seq[Retired]
  for entry in retired.mitems:
    var loads: seq[ref Thread[LoadArgs]]
    for load in entry.loads:
      if load.finished: joinThread(load[]) else: loads.add load
    entry.loads = loads
    var streams: seq[ref Thread[StreamArgs]]
    for stream in entry.streams:
      if stream.finished: joinThread(stream[]) else: streams.add stream
    entry.streams = streams
    if entry.streams.len == 0 and entry.loads.len == 0:
      entry.shared.channel.close()
      entry.shared.posts.close()
      deallocShared(entry.shared)
    else:
      kept.add entry
  retired = kept

# ---------------------------------------------------------------------------
# The source
# ---------------------------------------------------------------------------

proc newLiveDataSource*(baseUrl: string; auth = HarborAuth(kind: akNone);
                        after = ""; readTimeoutMs = 30_000;
                        minBackoffMs = 250; maxBackoffMs = 30_000;
                        fleetPageSize = 200): LiveDataSource =
  ## A source over the server at `baseUrl`, starting its stream workers now.
  ## `after` resumes the lifecycle feed from a cursor a previous source
  ## applied ("" for none). `readTimeoutMs` is how long a stream may stay
  ## silent before its worker reconnects; a quiet fleet costs one reconnect
  ## per period. `fleetPageSize` is how many of the newest sessions
  ## `loadFleet` reads (the server's maximum page is 200).
  reapRetired()
  let shared = cast[ptr Shared](allocShared0(sizeof(Shared)))
  shared.channel.open()
  shared.posts.open()
  let conn = Connection(baseUrl: baseUrl, authKind: auth.kind, token: auth.token)
  result = LiveDataSource(label: "live: " & baseUrl, conn: conn,
    shared: shared, pendingLoads: initTable[int, FleetCallback](),
    pageSize: clamp(fleetPageSize, 1, 200),
    pendingReads: initTable[int, InboxReadCallback](),
    pendingPosts: initTable[int, CursorAnswerCallback](),
    streamArgs: StreamArgs(conn: conn, shared: shared,
      readTimeoutMs: readTimeoutMs, minBackoffMs: max(1, minBackoffMs),
      maxBackoffMs: max(minBackoffMs, maxBackoffMs)))
  result.states[skLifecycle].cursor = after
  for kind in [skLifecycle]:
    var thread: ref Thread[StreamArgs]
    new thread
    createThread(thread[], followStream, StreamArgs(kind: kind, conn: conn,
      shared: shared, after: (if kind == skLifecycle: after else: ""),
      readTimeoutMs: readTimeoutMs, minBackoffMs: max(1, minBackoffMs),
      maxBackoffMs: max(minBackoffMs, maxBackoffMs)))
    result.streams.add thread

proc connected*(source: LiveDataSource; stream = skLifecycle): bool =
  ## True while the stream's current connection has delivered a frame.
  source.states[stream].connected

proc lastError*(source: LiveDataSource; stream = skLifecycle): string =
  ## Why the stream's last connection ended ("" while connected).
  source.states[stream].error

proc connections*(source: LiveDataSource; stream = skLifecycle): int =
  ## The stream's connections opened so far, pumped.
  source.states[stream].connections

proc cursor*(source: LiveDataSource; stream = skLifecycle): string =
  ## The cursor of the stream's last frame delivered: for the lifecycle
  ## feed, what a later source passes as `after` to resume where this one
  ## stopped.
  source.states[stream].cursor

proc pending*(source: LiveDataSource): int =
  ## Messages the workers posted that `pump()` has not delivered yet.
  if source.closed: 0 else: source.shared.channel.peek()

proc stopped*(source: LiveDataSource): bool =
  ## True once every stream worker has finished (after `close`, at its read
  ## deadline).
  for stream in source.streams:
    if not stream.finished: return false
  true

proc deliverLifecycleFrame(source: LiveDataSource; message: Message) =
  let frame = lifecycleFrameOf(message.event, message.data, message.id)
  if frame.cursor.len > 0: source.states[skLifecycle].cursor = frame.cursor
  let at = nowMs()
  discard source.frameSubscribers.broadcast(
    success(lifecycleFrame(frame, if frame.atMs > 0: frame.atMs else: at)))
  if frame.event == "resync":
    discard source.resetSubscribers.broadcast(success(StreamReset(atMs: at,
      reason: "the server could not replay the feed (" & frame.reason & ")")))

proc deliverInboxFrame(source: LiveDataSource; message: Message) =
  let notice = inboxNoticeOf(message.event, message.data, message.id)
  if message.id.len > 0: source.states[skInbox].cursor = message.id
  if notice.nextChangeAtMs > 0: source.nextInboxChangeMs = notice.nextChangeAtMs
  discard source.noticeSubscribers.broadcast(success(notice))

proc deliverInboxTime(source: LiveDataSource) =
  ## When the next item's warmth changes, a `changed` notice of the source's
  ## own, so the subscribers read the inbox again.
  if source.nextInboxChangeMs <= 0 or nowMs() < source.nextInboxChangeMs: return
  source.nextInboxChangeMs = 0
  discard source.noticeSubscribers.broadcast(success(InboxNotice(kind: inChanged,
    reasons: @["nextChangeAt"])))

proc answerInboxRead(source: LiveDataSource; message: Message) =
  var done: InboxReadCallback
  if not source.pendingReads.pop(message.loadId, done): return
  if not message.ok:
    done(failure[InboxRead](message.text))
    return
  try:
    done(success(inboxReadFromJson(parseJson(message.text))))
  except CatchableError as error:
    done(failure[InboxRead]("unreadable inbox: " & error.msg))

proc answerCursorPost(source: LiveDataSource; message: Message) =
  var done: CursorAnswerCallback
  if not source.pendingPosts.pop(message.loadId, done): return
  if not message.ok:
    done(failure[CursorAnswer](message.text))
    return
  try:
    done(success(cursorAnswerFromJson(parseJson(message.text))))
  except CatchableError as error:
    done(failure[CursorAnswer]("unreadable cursor answer: " & error.msg))

proc pump*(source: LiveDataSource): int =
  ## Delivers what the workers have posted, on the caller's thread: frames
  ## and resets to the subscribers, listings to the loads waiting for them.
  ## Returns the number of messages handled. Call it from the UI loop; it
  ## never blocks.
  if source.closed: return 0
  var loads: seq[ref Thread[LoadArgs]]
  for load in source.loads:
    if load.finished: joinThread(load[]) else: loads.add load
  source.loads = loads
  while not source.closed:
    let (got, message) = source.shared.channel.tryRecv()
    if not got: break
    inc result
    case message.kind
    of mkConnecting:
      inc source.states[message.stream].connections
    of mkConnected:
      source.states[message.stream].connected = true
      source.states[message.stream].error = ""
    of mkDisconnected:
      source.states[message.stream].connected = false
      source.states[message.stream].error = message.text
    of mkFrame:
      case message.stream
      of skLifecycle: source.deliverLifecycleFrame(message)
      of skInbox: source.deliverInboxFrame(message)
    of mkStreamGone:
      source.states[message.stream].connected = false
      source.states[message.stream].error = message.text
    of mkInboxRead:
      source.answerInboxRead(message)
    of mkCursorAnswer:
      source.answerCursorPost(message)
    of mkFleet:
      var done: FleetCallback
      if source.pendingLoads.pop(message.loadId, done):
        if not message.ok:
          done(failure[FleetSnapshot](message.text))
        else:
          try:
            done(success(fleetSnapshotFromJson(parseJson(message.text),
              nowMs(), source.label)))
          except CatchableError as error:
            done(failure[FleetSnapshot]("unreadable session list: " & error.msg))
  if not source.closed: source.deliverInboxTime()

proc close*(source: LiveDataSource) =
  ## Stops the source: nothing is delivered after it returns, and waiting
  ## loads are never answered. It does not wait for a worker's blocking read.
  if source.closed: return
  source.closed = true
  source.shared.stop.store(true)
  source.pendingLoads.clear()
  source.pendingReads.clear()
  source.pendingPosts.clear()
  source.frameSubscribers = Subscribers[FleetFrame]()
  source.resetSubscribers = Subscribers[StreamReset]()
  source.noticeSubscribers = Subscribers[InboxNotice]()
  retired.add Retired(shared: source.shared, streams: source.streams,
    loads: source.loads)
  source.loads = @[]
  reapRetired()

method loadFleet*(source: LiveDataSource; done: FleetCallback) =
  ## Lists every session on a worker; `done` is called from `pump()`.
  if source.closed:
    done(failure[FleetSnapshot]("the live source is closed"))
    return
  inc source.nextLoad
  let id = source.nextLoad
  source.pendingLoads[id] = done
  var thread: ref Thread[LoadArgs]
  new thread
  createThread(thread[], loadOnce, LoadArgs(conn: source.conn,
    shared: source.shared, loadId: id, pageSize: source.pageSize))
  source.loads.add thread

method subscribeFleetFrames*(source: LiveDataSource;
    callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  source.frameSubscribers.subscribe(callback)

method subscribeResets*(source: LiveDataSource;
    callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  source.resetSubscribers.subscribe(callback)

# ---------------------------------------------------------------------------
# The inbox and its cursor
# ---------------------------------------------------------------------------

proc startWorker(source: LiveDataSource; args: LoadArgs) =
  var thread: ref Thread[LoadArgs]
  new thread
  createThread(thread[], loadOnce, args)
  source.loads.add thread

proc startInboxStream(source: LiveDataSource) =
  if source.inboxStarted or source.closed: return
  source.inboxStarted = true
  var args = source.streamArgs
  args.kind = skInbox
  var thread: ref Thread[StreamArgs]
  new thread
  createThread(thread[], followStream, args)
  source.streams.add thread

method loadInboxRead*(source: LiveDataSource; cursorName: string;
                      done: InboxReadCallback) =
  ## Reads the inbox with the cursor on a worker; `done` is called from
  ## `pump()`.
  if source.closed:
    done(failure[InboxRead]("the live source is closed"))
    return
  inc source.nextLoad
  let id = source.nextLoad
  source.pendingReads[id] = done
  source.startWorker(LoadArgs(conn: source.conn, shared: source.shared,
    loadId: id, work: lwInboxRead, cursorName: cursorName))

method postInboxCursor*(source: LiveDataSource; name: string;
                        post: CursorPost; done: CursorAnswerCallback) =
  ## Queues the post for the poster worker, which sends the posts in the
  ## order they were queued; `done` is called from `pump()`.
  if source.closed:
    done(failure[CursorAnswer]("the live source is closed"))
    return
  if not source.posterStarted:
    source.posterStarted = true
    source.startWorker(LoadArgs(conn: source.conn, shared: source.shared,
      work: lwPoster))
  inc source.nextLoad
  let id = source.nextLoad
  source.pendingPosts[id] = done
  source.shared.posts.send(PostJob(id: id, cursorName: name,
    direction: post.direction, expectedVersion: post.expectedVersion,
    landedOn: post.landedOn))

method subscribeInboxNotices*(source: LiveDataSource;
    callback: FeedCallback[InboxNotice]): Subscription[InboxNotice] =
  ## Starts the inbox stream with its first subscriber.
  source.startInboxStream()
  source.noticeSubscribers.subscribe(callback)
