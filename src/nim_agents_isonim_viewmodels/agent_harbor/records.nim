## Signal-free records for an Agent Harbor fleet, decoded from the JSON the
## Agent Harbor REST server returns:
##
## - `GET /api/v1/sessions` (`{"items": [...], "total": N, "nextPage": ...}`),
## - `GET /api/v1/sessions/{id}/events/history`
##   (`{"events": [...], "has_more": bool, "total_count": N, ...}`),
## - `GET /api/v1/session-lifecycle/events`, a Server-Sent Events stream of
##   `lifecycle`, `resync` and `caught_up` frames
##   (https://html.spec.whatwg.org/multipage/server-sent-events.html).
##
## These records are prototype-local: they exist so the front-end prototypes
## can be built over captured data before the typed client in
## `nim-agent-harbor` and the reducers in `nim-agents` grow the same
## endpoints. They hold no signals and import no IsoNim module, so moving them
## down a layer later is a move, not a rewrite.
##
## Decoding is deliberately lenient (a missing field reads as its zero value,
## an unknown status as `fsUnknown`): the server adds fields freely and a
## front-end must keep rendering what it understands.

import std/[json, strutils]

type
  FleetStatus* = enum
    ## The session states the server reports. `fsUnknown` keeps a status the
    ## prototype does not know yet renderable instead of dropping the row.
    fsQueued = "queued"
    fsProvisioning = "provisioning"
    fsRunning = "running"
    fsPausing = "pausing"
    fsPaused = "paused"
    fsResuming = "resuming"
    fsStopping = "stopping"
    fsCompleted = "completed"
    fsFinished = "finished"
    fsReclaimed = "reclaimed"
    fsStopped = "stopped"
    fsFailed = "failed"
    fsCancelled = "cancelled"
    fsUnknown = "unknown"

  FleetCategory* = enum
    ## How a front-end groups sessions at a glance, in display order: a
    ## session that waits for a person comes first, an ended one last.
    fcNeedsInput = "needs-input"
    fcRunning = "running"
    fcQueued = "queued"
    fcFailed = "failed"
    fcEnded = "ended"

  FleetActivityKind* = enum
    fakQuestion          ## `agent_question`
    fakAwaitingInput     ## `session_awaiting_input`
    fakResumed           ## `session_resumed`
    fakStatus            ## `status`
    fakLog               ## `log`
    fakOrchestration     ## `orchestration`
    fakAntiHalting       ## `anti_halting_resume_confirmed`
    fakOther             ## anything else, shown by its wire type

  FleetActivity* = object
    ## One session event, reduced to what an activity line shows.
    kind*: FleetActivityKind
    eventType*: string     ## the wire `type`, kept for unknown kinds
    text*: string          ## the line a front-end prints
    level*: string         ## `log` events: `info`, `warn`, `error`
    timestampMs*: int64

  FleetSession* = object
    ## One entry of `GET /api/v1/sessions`.
    id*: string
    prompt*: string
    promptWithheld*: bool  ## the server withheld the prompt from this caller
    agentSoftware*: string
    agentVersion*: string
    model*: string
    agentCount*: int
    runtime*: string
    host*: string
    repoUrl*: string
    branch*: string
    commit*: string
    rawStatus*: string
    status*: FleetStatus
    createdAtMs*: int64
    updatedAtMs*: int64
    startedAtMs*: int64
    endedAtMs*: int64
    awaitingInput*: bool
    awaitingInputSource*: string
    priority*: string
    withheld*: seq[string]
    executorId*: string
    recent*: seq[FleetActivity]
    # What a person calls the session, for when its prompt is withheld. The
    # session list carries none of these for a caller outside the session's
    # scope; a data source fills them from what it knows besides (the
    # workspace path the server lists, the front-end that started the session,
    # a capture's label table). Empty when unknown.
    name*: string          ## the session's own name (a window or tab title)
    workspaceName*: string ## the workspace or checkout it works in
    initiative*: string    ## the campaign or plan it belongs to
    labelSource*: string   ## where the label came from, for a tooltip
    failureReason*: string
      ## Why it failed, when a source knows more than the listing's few
      ## recent events (their last log lines are usually status changes).

  FleetSnapshot* = object
    ## A whole fleet listing as one value. `capturedAtMs` is the instant the
    ## listing was taken; relative times ("12m ago") are measured from it, so
    ## a replayed snapshot renders the same on every run.
    capturedAtMs*: int64
    sourceLabel*: string
    total*: int
    sessions*: seq[FleetSession]

  LifecycleFrame* = object
    ## One frame of the session lifecycle feed. `event` is the SSE event
    ## name (`lifecycle`, `resync`, `caught_up`); the other fields are those
    ## of its JSON `data`.
    event*: string
    kind*: string
    sessionId*: string
    status*: string
    previousStatus*: string
    agent*: string
    executor*: string
    reason*: string
    atMs*: int64
    cursor*: string

  SessionEventHistory* = object
    ## `GET /api/v1/sessions/{id}/events/history`.
    sessionId*: string
    totalCount*: int
    hasMore*: bool
    events*: seq[FleetActivity]

# ---------------------------------------------------------------------------
# Field access
# ---------------------------------------------------------------------------

proc str(node: JsonNode; key: string): string =
  ## A string field, or "" when it is absent, null or not a string.
  if node.isNil or node.kind != JObject: return ""
  let value = node.getOrDefault(key)
  if value.isNil or value.kind != JString: "" else: value.getStr

proc num(node: JsonNode; key: string): int64 =
  if node.isNil or node.kind != JObject: return 0
  let value = node.getOrDefault(key)
  if value.isNil: return 0
  case value.kind
  of JInt: value.getBiggestInt.int64
  of JFloat: value.getFloat.int64
  else: 0

proc flag(node: JsonNode; key: string): bool =
  if node.isNil or node.kind != JObject: return false
  let value = node.getOrDefault(key)
  not value.isNil and value.kind == JBool and value.getBool

proc child(node: JsonNode; key: string): JsonNode =
  if node.isNil or node.kind != JObject: return nil
  node.getOrDefault(key)

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

proc daysFromCivil(y, m, d: int64): int64 =
  ## Days since 1970-01-01 of a proleptic Gregorian date. Howard Hinnant's
  ## algorithm (https://howardhinnant.github.io/date_algorithms.html#days_from_civil),
  ## used instead of `std/times` so the result is identical on the C and JS
  ## targets and needs no time-zone database.
  let yy = if m <= 2: y - 1 else: y
  let era = (if yy >= 0: yy else: yy - 399) div 400
  let yoe = yy - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc parseIsoMs*(text: string): int64 =
  ## Milliseconds since the Unix epoch of an RFC 3339 UTC timestamp such as
  ## `2026-11-03T18:34:17.310422349Z` (https://www.rfc-editor.org/rfc/rfc3339).
  ## Returns 0 for an empty or malformed value; offsets other than `Z` are
  ## honoured.
  let s = text.strip
  if s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] notin {'T', 't', ' '} or
      s[13] != ':' or s[16] != ':':
    return 0
  try:
    let year = parseInt(s[0 ..< 4]).int64
    let month = parseInt(s[5 ..< 7]).int64
    let day = parseInt(s[8 ..< 10]).int64
    let hour = parseInt(s[11 ..< 13]).int64
    let minute = parseInt(s[14 ..< 16]).int64
    let second = parseInt(s[17 ..< 19]).int64
    var i = 19
    var millis = 0'i64
    if i < s.len and s[i] == '.':
      inc i
      var digits = 0
      while i < s.len and s[i] in Digits:
        if digits < 3:
          millis = millis * 10 + (ord(s[i]) - ord('0')).int64
        inc digits
        inc i
      while digits < 3:
        millis *= 10
        inc digits
    var offsetMin = 0'i64
    if i < s.len and s[i] in {'+', '-'}:
      if i + 6 > s.len: return 0
      let sign = if s[i] == '-': -1'i64 else: 1'i64
      offsetMin = sign * (parseInt(s[i + 1 .. i + 2]).int64 * 60 +
        parseInt(s[i + 4 .. i + 5]).int64)
    if month < 1 or month > 12 or day < 1 or day > 31: return 0
    let days = daysFromCivil(year, month, day)
    result = ((days * 24 + hour) * 60 + minute - offsetMin) * 60_000 +
      second * 1000 + millis
  except ValueError:
    result = 0

proc ageLabel*(nowMs, thenMs: int64): string =
  ## Compact elapsed time, the way CodeTracer's VCS panel abbreviates commit
  ## ages: `now`, `45s`, `12m`, `3h`, `2d`, `5w`. Empty when `thenMs` is 0.
  if thenMs <= 0: return ""
  let delta = max(0'i64, nowMs - thenMs) div 1000
  if delta < 10: "now"
  elif delta < 60: $delta & "s"
  elif delta < 3600: $(delta div 60) & "m"
  elif delta < 86_400: $(delta div 3600) & "h"
  elif delta < 14 * 86_400: $(delta div 86_400) & "d"
  else: $(delta div (7 * 86_400)) & "w"

proc durationLabel*(fromMs, toMs: int64): string =
  ## `1h 05m`, `12m`, `40s`; empty when either end is missing.
  if fromMs <= 0 or toMs <= 0 or toMs < fromMs: return ""
  let secs = (toMs - fromMs) div 1000
  if secs < 60: $secs & "s"
  elif secs < 3600: $(secs div 60) & "m"
  else:
    let minutes = (secs mod 3600) div 60
    $(secs div 3600) & "h " & (if minutes < 10: "0" else: "") & $minutes & "m"

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

proc parseFleetStatus*(text: string): FleetStatus =
  for status in FleetStatus:
    if $status == text: return status
  fsUnknown

proc isActive*(status: FleetStatus): bool =
  ## The session still holds an agent: it can run, pause or ask for input.
  status in {fsQueued, fsProvisioning, fsRunning, fsPausing, fsPaused,
             fsResuming, fsStopping}

proc category*(session: FleetSession): FleetCategory =
  ## Waiting for a person outranks every other state of a live session.
  if session.status.isActive and (session.awaitingInput or
      session.status == fsPaused):
    fcNeedsInput
  else:
    case session.status
    of fsRunning, fsProvisioning, fsResuming, fsPausing, fsStopping: fcRunning
    of fsQueued: fcQueued
    of fsFailed, fsCancelled: fcFailed
    else: fcEnded

proc categoryCounts*(sessions: openArray[FleetSession]): array[FleetCategory, int] =
  for session in sessions:
    inc result[session.category]

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc agentLabel*(software, version: string): string =
  ## `Claude 2.1.312`; a version of `latest` or empty is left out.
  result = software
  if version.len > 0 and version != "latest":
    result.add(" " & version)

proc requestLabel*(request: string): string =
  ## A readable name for an input request id. The server names a request
  ## either by its source (`claude-stop-hook`) or as
  ## `<session id>:<kind>:<sequence>`; the ids and sequence numbers mean
  ## nothing to a reader, so only the words are kept, dashes as spaces
  ## (`native question`, `claude stop hook`).
  var words: seq[string]
  for part in request.split(':'):
    let p = part.strip
    if p.len == 0 or p.allCharsInSet(Digits): continue
    # A UUID (8-4-4-4-12 hex digits) names a session, not a request kind.
    if p.len == 36 and p.count('-') == 4 and
        p.allCharsInSet(HexDigits + {'-'}): continue
    words.add(p.replace('-', ' ').replace('_', ' '))
  words.join(" ")

proc activityFromJson*(node: JsonNode): FleetActivity =
  ## One activity line from a session event. The text is built from the
  ## event's structured fields only; a question's own prompt and options are
  ## never echoed, because they may quote private prompt text.
  let eventType = node.str("type")
  result = FleetActivity(eventType: eventType,
                         timestampMs: node.num("timestamp"),
                         level: node.str("level"))
  case eventType
  of "agent_question":
    result.kind = fakQuestion
    let kind = node.str("kind").replace('_', '-')
    result.text = "Asked a " & (if kind.len > 0: kind else: "") &
      (if kind.len > 0: " question" else: "question")
  of "session_awaiting_input":
    result.kind = fakAwaitingInput
    let request = requestLabel(node.str("request"))
    result.text = "Waiting for input" &
      (if request.len > 0: " (" & request & ")" else: "")
  of "session_resumed":
    result.kind = fakResumed
    let by = node.str("deliverer")
    result.text = "Resumed" & (if by.len > 0: " by " & by else: "")
  of "status":
    result.kind = fakStatus
    result.text = "Status: " & node.str("status")
  of "log":
    result.kind = fakLog
    result.text = node.str("message")
  of "orchestration":
    result.kind = fakOrchestration
    result.text = node.str("description")
    let payload = node.child("payload")
    let model = payload.str("model")
    if model.len > 0:
      result.text.add(": " & model)
  of "anti_halting_resume_confirmed":
    result.kind = fakAntiHalting
    let stall = node.str("stallType").replace('_', ' ')
    result.text = "Anti-halting resumed a stalled turn" &
      (if stall.len > 0 and stall != "unknown": " (" & stall & ")" else: "")
  else:
    result.kind = fakOther
    result.text = eventType.replace('_', ' ')

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

proc fleetSessionFromJson*(node: JsonNode): FleetSession =
  let agentNode = node.child("agent")
  let software = agentNode.child("agent")
  let workspace = node.child("workspace")
  let vcs = node.child("vcs")
  let task = node.child("task")
  result = FleetSession(
    id: node.str("id"),
    prompt: task.str("prompt"),
    agentSoftware: software.str("software"),
    agentVersion: software.str("version"),
    model: agentNode.str("model"),
    agentCount: max(1, agentNode.num("count").int),
    runtime: node.child("runtime").str("type"),
    host: workspace.str("host"),
    repoUrl: vcs.str("repo_url"),
    branch: vcs.str("branch"),
    commit: vcs.str("commit"),
    rawStatus: node.str("status"),
    createdAtMs: parseIsoMs(node.str("createdAt")),
    updatedAtMs: parseIsoMs(node.str("updatedAt")),
    startedAtMs: parseIsoMs(node.str("started_at")),
    endedAtMs: parseIsoMs(node.str("ended_at")),
    awaitingInput: node.flag("awaiting_input"),
    awaitingInputSource: node.str("awaiting_input_source"),
    priority: node.str("priority"),
    executorId: task.child("labels").str("agentHarbor.executorId"),
  )
  let mountPath = workspace.str("mountPath")
  if mountPath.len > 0:
    result.workspaceName = mountPath.strip(chars = {'/'}).split('/')[^1]
    result.labelSource = "the session list"
  result.status = parseFleetStatus(result.rawStatus)
  let withheld = node.child("withheld")
  if not withheld.isNil and withheld.kind == JArray:
    for item in withheld:
      if item.kind == JString: result.withheld.add(item.getStr)
  result.promptWithheld = "prompt" in result.withheld
  let recent = node.child("recent_events")
  if not recent.isNil and recent.kind == JArray:
    for event in recent:
      result.recent.add(activityFromJson(event))

type
  SessionLabel* = object
    ## One entry of a label table: what is known of a session besides the
    ## wire listing.
    name*: string
    workspaceName*: string
    branch*: string
    initiative*: string
    source*: string

proc sessionLabelsFromJson*(node: JsonNode): seq[(string, SessionLabel)] =
  ## A label table: `{"<session id>": {"name", "workspace", "branch",
  ## "initiative", "source"}}`.
  if node.isNil or node.kind != JObject: return
  for id, entry in node.pairs:
    result.add((id, SessionLabel(name: entry.str("name"),
                                 workspaceName: entry.str("workspace"),
                                 branch: entry.str("branch"),
                                 initiative: entry.str("initiative"),
                                 source: entry.str("source"))))

proc failureReasonOf*(newestFirst: openArray[FleetActivity]): string =
  ## The reason a history gives for a failure: its newest error-level log
  ## line, else its newest log line of any level (`[exit] status=143`).
  for event in newestFirst:
    if event.kind == fakLog and event.level == "error": return event.text
  for event in newestFirst:
    if event.kind == fakLog and event.text.strip.len > 0 and
        not event.text.startsWith("[scrubbed"):
      return event.text
  ""

proc applyLabel*(session: var FleetSession; label: SessionLabel) =
  ## Fills what the listing left empty; a field the listing carries wins.
  if session.name.len == 0: session.name = label.name
  if session.workspaceName.len == 0: session.workspaceName = label.workspaceName
  if session.branch.len == 0: session.branch = label.branch
  if session.initiative.len == 0: session.initiative = label.initiative
  if label.source.len > 0 and session.labelSource.len == 0:
    session.labelSource = label.source

proc effectiveStatusLabel*(session: FleetSession): string =
  ## The status a front-end shows (inventory INV-P2-13, INV-P2-14, INV-P2-19):
  ## a live session that waits for a person shows "needs input" -- whatever
  ## its wire status says -- and "needs input (estimated)" when the server
  ## only inferred the wait from a settle heuristic. Otherwise the wire status,
  ## or the raw text of one this front-end does not know.
  if session.category == fcNeedsInput:
    if session.awaitingInput and
        "settle" in session.awaitingInputSource.toLowerAscii:
      "needs input (estimated)"
    else:
      "needs input"
  elif session.status == fsUnknown:
    session.rawStatus
  else:
    $session.status

proc fleetSnapshotFromJson*(node: JsonNode; capturedAtMs: int64;
                            sourceLabel = ""): FleetSnapshot =
  ## A listing page (or several merged into one `items` array).
  result = FleetSnapshot(capturedAtMs: capturedAtMs, sourceLabel: sourceLabel)
  let items = node.child("items")
  if not items.isNil and items.kind == JArray:
    for item in items:
      result.sessions.add(fleetSessionFromJson(item))
  result.total = max(result.sessions.len, node.num("total").int)

proc sessionEventHistoryFromJson*(sessionId: string;
                                  node: JsonNode): SessionEventHistory =
  result = SessionEventHistory(sessionId: sessionId,
                               totalCount: node.num("total_count").int,
                               hasMore: node.flag("has_more"))
  let events = node.child("events")
  if not events.isNil and events.kind == JArray:
    for event in events:
      result.events.add(activityFromJson(event))

proc parseLifecycleSse*(text: string): seq[LifecycleFrame] =
  ## Frames of an SSE capture of the lifecycle feed. Implements the parts of
  ## the event-stream format the feed uses: `event:`, `data:` (joined by
  ## newlines when repeated), `id:`, comments, and blank-line dispatch.
  var event = ""
  var data = ""
  var id = ""
  proc dispatch(frames: var seq[LifecycleFrame]) =
    if data.len == 0 and event.len == 0: return
    var frame = LifecycleFrame(event: if event.len > 0: event else: "message",
                               cursor: id)
    try:
      let node = parseJson(data)
      frame.kind = node.str("kind")
      frame.sessionId = node.str("sessionId")
      frame.status = node.str("status")
      frame.previousStatus = node.str("previousStatus")
      frame.agent = node.str("agent")
      frame.executor = node.str("executor")
      frame.reason = node.str("reason")
      frame.atMs = parseIsoMs(node.str("at"))
      if frame.cursor.len == 0: frame.cursor = node.str("cursor")
    except JsonParsingError, ValueError:
      discard
    frames.add(frame)
    event = ""
    data = ""
  for rawLine in text.splitLines:
    let line = rawLine
    if line.len == 0:
      dispatch(result)
    elif line.startsWith(':'):
      discard
    else:
      let colon = line.find(':')
      let field = if colon < 0: line else: line[0 ..< colon]
      var value = if colon < 0: "" else: line[colon + 1 .. ^1]
      if value.startsWith(' '): value = value[1 .. ^1]
      case field
      of "event": event = value
      of "data":
        if data.len > 0: data.add('\n')
        data.add(value)
      of "id": id = value
      else: discard
  dispatch(result)
