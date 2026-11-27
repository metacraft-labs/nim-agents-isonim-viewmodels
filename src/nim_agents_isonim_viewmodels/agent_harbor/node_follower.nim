## The host's half of a window's Agent Harbor source, on Node: it follows
## the server and posts what it reads as `host_messages`.
##
## In a desktop app the main process follows the server for every window
## (manager decision D92), and Electron's main process is JavaScript on
## Node, where the native `LiveDataSource` (worker threads, a blocking feed)
## cannot run. This follower does the same work with Node's own `fetch`:
##
## - `load` reads the newest page of `GET /api/v1/sessions` and posts an
##   `hmFleet` message with its id: `ok` and the page (`items`, `total`) as
##   JSON, or the error. A refusal (401) is an error, never an empty fleet.
## - From construction until `close`, it follows
##   `GET /api/v1/session-lifecycle/events`, posting `hmConnecting`, then
##   `hmConnected` with the first frame, every frame as sent (`hmFrame`), and
##   `hmDisconnected` with the reason when the feed ends, fails, is refused
##   or stays silent past `readTimeoutMs`. It then connects again from the
##   last cursor it read, so the server replays what was missed; between
##   attempts that delivered nothing it waits `minBackoffMs`, doubling to
##   `maxBackoffMs`, and a connection that delivered a frame resets the wait.
##
## Every message goes to the `HostPost` callback, on Node's event loop; the
## host forwards each to its windows (over IPC, as `encodeHostMessage`
## text), whose `HostFedDataSource` delivers it. Nothing is posted after
## `close` returns.
##
## The requests are nim-agent-harbor's (`listSessionsRequest`,
## `lifecycleRequest`), read the way its client reads them
## (`sessionListPageOf`, `SseReader`), so the wire is described there only.
## The key is whatever the host passes, which is only what is set through
## the front-end's own surfaces.
##
## JavaScript on Node only (Node 18 or later: `fetch`, `AbortController`,
## `TextDecoder`).

when not defined(js):
  {.error: "node_follower runs in a Node process; native hosts use live_source".}

import std/[json, strutils]
import nim_everywhere
import nim_agent_harbor
import nim_agents/agent_harbor/fleet_records
import ./host_messages

export host_messages

type
  HostPost* = proc(message: HostMessage) {.closure.}
    ## Receives each message the follower posts.

  NodeHarborFollower* = ref object
    client: HarborClient
    post: HostPost
    cursor: string
    readTimeoutMs, minBackoffMs, maxBackoffMs, wait: int
    connections: int
    stream: JsObjectRef   ## the open feed's AbortController
    timer: JsObjectRef    ## the reconnect timer
    closed: bool

  JsObjectRef = ref object  ## an opaque JavaScript object

# ---------------------------------------------------------------------------
# Node bindings: the three things the follower asks of Node
# ---------------------------------------------------------------------------

proc nodeFetchText(url: cstring; names, values: seq[cstring];
    done: proc(status: int; body, error: cstring)) {.importjs: """
  ((url, names, values, done) => {
    const headers = {};
    names.forEach((n, i) => { headers[n] = values[i]; });
    fetch(url, {method: 'GET', headers})
      .then(r => r.text().then(body => done(r.status, body, '')))
      .catch(e => done(0, '', String((e && e.message) || e)));
  })(#, #, #, #)""".}
  ## GET `url` and call `done` once: the status and body, or status 0 and
  ## why the request failed.

proc nodeFollowStream(url: cstring; names, values: seq[cstring]; stallMs: int;
    onRefused: proc(status: int; body: cstring);
    onText: proc(text: cstring);
    onEnd: proc(error: cstring)): JsObjectRef {.importjs: """
  ((url, names, values, stallMs, onRefused, onText, onEnd) => {
    const headers = {};
    names.forEach((n, i) => { headers[n] = values[i]; });
    const controller = new AbortController();
    let ended = false, stall = null, stalled = false;
    const finish = (why) => {
      if (ended) return;
      ended = true;
      if (stall) clearTimeout(stall);
      onEnd(why);
    };
    const arm = () => {
      if (stall) clearTimeout(stall);
      stall = setTimeout(() => { stalled = true; controller.abort(); }, stallMs);
    };
    arm();
    fetch(url, {method: 'GET', headers, signal: controller.signal})
      .then(async (r) => {
        if (r.status < 200 || r.status >= 300) {
          const body = await r.text().catch(() => '');
          if (!controller.signal.aborted || stalled) {
            ended = true;
            if (stall) clearTimeout(stall);
            onRefused(r.status, body);
          }
          return;
        }
        const reader = r.body.getReader();
        const decoder = new TextDecoder();
        for (;;) {
          const {done, value} = await reader.read();
          if (done) break;
          arm();
          if (!controller.signal.aborted) onText(decoder.decode(value, {stream: true}));
        }
        finish('the feed ended');
      })
      .catch(e => finish(stalled ? 'the feed stalled' :
                         String((e && e.message) || e)));
    controller.__stop = () => { ended = true; if (stall) clearTimeout(stall);
                                controller.abort(); };
    return controller;
  })(#, #, #, #, #, #, #)""".}
  ## Opens `url` as an event stream. A refusal calls `onRefused` once; the
  ## body arrives as text through `onText`; the end of the stream, a failure
  ## or `stallMs` without a byte calls `onEnd` once, with why. Returns the
  ## stream's AbortController.

proc nodeStop(controller: JsObjectRef) {.importjs: "#.__stop()".}
proc nodeSetTimeout(ms: int; callback: proc()): JsObjectRef {.importjs:
  "((ms, cb) => setTimeout(cb, ms))(#, #)".}
proc nodeClearTimeout(timer: JsObjectRef) {.importjs: "clearTimeout(#)".}

proc headerArrays(request: HttpRequest): (seq[cstring], seq[cstring]) =
  for item in request.headers:
    result[0].add cstring(item.name)
    result[1].add cstring(item.value)

# ---------------------------------------------------------------------------
# The follower
# ---------------------------------------------------------------------------

proc noTransport(): HttpTransport =
  ## The client only builds requests here; Node's `fetch` carries them.
  result = proc(req: HttpRequest): HttpResponse =
    raise newException(HarborError, "the Node follower carries its own requests")

proc send(follower: NodeHarborFollower; message: HostMessage) =
  if not follower.closed: follower.post(message)

proc connect(follower: NodeHarborFollower)

proc scheduleReconnect(follower: NodeHarborFollower; delivered: bool) =
  if follower.closed: return
  if delivered: follower.wait = follower.minBackoffMs
  let wait = follower.wait
  if not delivered:
    follower.wait = min(follower.wait * 2, follower.maxBackoffMs)
  let target = follower
  follower.timer = nodeSetTimeout(wait, proc() =
    target.timer = nil
    target.connect())

proc connect(follower: NodeHarborFollower) =
  if follower.closed: return
  inc follower.connections
  follower.send HostMessage(kind: hmConnecting, stream: hsLifecycle)
  let request = follower.client.lifecycleRequest(follower.cursor)
  let (names, values) = request.headerArrays
  let target = follower
  var reader = initSseReader()
  var frame: SseFrame
  var pending = ""
  var delivered = false
  var ended = false
  proc onLine(line: string) =
    if reader.feedLine(line, frame):
      if not delivered:
        delivered = true
        target.send HostMessage(kind: hmConnected, stream: hsLifecycle)
      # The cursor to resume from: a lifecycle frame's id, or the cursor in
      # a resync or caught_up frame's data.
      let decoded = lifecycleFrameOf(frame.event, frame.data, frame.id)
      if decoded.cursor.len > 0: target.cursor = decoded.cursor
      target.send HostMessage(kind: hmFrame, stream: hsLifecycle,
        event: frame.event, data: frame.data, id: frame.id)
      frame = SseFrame()
  proc ending(why: string) =
    if ended or target.closed: return
    ended = true
    target.stream = nil
    target.send HostMessage(kind: hmDisconnected, stream: hsLifecycle, text: why)
    target.scheduleReconnect(delivered)
  follower.stream = nodeFollowStream(cstring request.url, names, values,
    follower.readTimeoutMs,
    proc(status: int; body: cstring) =
      ending("Harbor session lifecycle feed failed (HTTP " & $status & "): " &
        $body),
    proc(text: cstring) =
      if target.closed: return
      pending.add $text
      while true:
        let at = pending.find('\n')
        if at < 0: break
        var line = pending[0 ..< at]
        pending = pending[at + 1 .. ^1]
        if line.endsWith('\r'): line.setLen(line.len - 1)
        onLine(line),
    proc(error: cstring) = ending($error))

proc newNodeHarborFollower*(baseUrl: string; post: HostPost;
                            auth = HarborAuth(kind: akNone); after = "";
                            readTimeoutMs = 30_000; minBackoffMs = 250;
                            maxBackoffMs = 30_000): NodeHarborFollower =
  ## A follower of the server at `baseUrl`, posting to `post`; it opens the
  ## lifecycle feed now. `after` resumes the feed from a cursor a previous
  ## follower read ("" for none). `readTimeoutMs` is how long the feed may
  ## stay silent before the follower reconnects.
  result = NodeHarborFollower(
    client: newHarborClient(baseUrl, noTransport(), auth), post: post,
    cursor: after, readTimeoutMs: max(1, readTimeoutMs),
    minBackoffMs: max(1, minBackoffMs),
    maxBackoffMs: max(max(1, minBackoffMs), maxBackoffMs))
  result.wait = result.minBackoffMs
  result.connect()

proc label*(follower: NodeHarborFollower): string =
  ## The server as a panel names it.
  "live: " & follower.client.baseUrl

proc cursor*(follower: NodeHarborFollower): string =
  ## The cursor of the last frame read: what a later follower passes as
  ## `after` to resume where this one stopped.
  follower.cursor

proc connections*(follower: NodeHarborFollower): int =
  ## The feed connections opened so far.
  follower.connections

proc closed*(follower: NodeHarborFollower): bool = follower.closed

proc load*(follower: NodeHarborFollower; loadId: int; pageSize = 200) =
  ## Reads the newest `pageSize` sessions (at most 200, the server's page)
  ## and posts the answer as an `hmFleet` message carrying `loadId`.
  if follower.closed: return
  let request = follower.client.listSessionsRequest(
    SessionListQuery(page: 1, perPage: clamp(pageSize, 1, 200)))
  let (names, values) = request.headerArrays
  let target = follower
  nodeFetchText(cstring request.url, names, values,
    proc(status: int; body, error: cstring) =
      var message = HostMessage(kind: hmFleet, loadId: loadId)
      if status == 0:
        message.text = "Harbor session list failed: " & $error
      else:
        try:
          let page = sessionListPageOf(HttpResponse(status: status, body: $body))
          var list = newJArray()
          for item in page.items: list.add item
          message.ok = true
          message.text = $(%*{"items": list, "total": page.total})
        except HarborError as failure:
          message.text = failure.msg
      target.send message)

proc close*(follower: NodeHarborFollower) =
  ## Stops following: the feed is aborted, no reconnect is made, waiting
  ## loads are dropped, and nothing is posted after it returns.
  if follower.closed: return
  follower.closed = true
  if not follower.timer.isNil:
    nodeClearTimeout(follower.timer)
    follower.timer = nil
  if not follower.stream.isNil:
    nodeStop(follower.stream)
    follower.stream = nil
