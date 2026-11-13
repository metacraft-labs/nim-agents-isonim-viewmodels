## The playback scenario format: a run of an Agent Harbor fleet, written down
## as data a playback source (`playback_source.nim`) replays on a clock, so a
## story can be watched changing and a test can stop it at any moment.
##
## A scenario is:
##
## - its **first frame**: the fleet listing at the scenario's first moment
##   (`first`, a `FleetSnapshot` as `GET /api/v1/sessions` answers it) and the
##   initiatives then (`initiatives`, as the proposed `GET /api/v1/initiatives`
##   answers them);
## - its **entries** after that moment, in time order (`entries`), each
##   stamped with its moment (`atMs`, milliseconds since the Unix epoch) and
##   of one kind (`ScenarioEntryKind`): a lifecycle frame, a session's listing
##   entry, one event of a session's event stream, a resume (the operator's
##   input reached a waiting session), a progress event (a milestone's status
##   changed in a plan) or a recording-state change (a recording of an
##   initiative appeared loading, or turned ready or failed). Entries sharing
##   a moment are one moment: a player delivers them together, in their
##   order;
## - the **sessions** it names, each with its whole event history
##   (`sessions`: identity, start, removal, every event oldest first, those
##   before the first moment included), from which its listing at any moment
##   can be rebuilt and its event history answered.
##
## Any entry may carry a **named moment** (`moment`), unique in its scenario:
## a story or a test seeks to it by name, and captures are taken there.
##
## Scenarios are Nim values, built by constructors in Nim code
## (`playback_scenarios.nim`), not files: the same scenario loads on the C and
## JS targets, with no file IO and no parser. `buildScenario` is the
## authoring helper: given the sessions' histories and the entries no history
## implies (resumes, progress events, recording changes), it derives the
## first listing (each session replayed to the first moment by nim-agents'
## `sessionAt`) and the fleet entries a live feed would deliver after it:
## a new session's `session_created` frame and its listing entry, every event,
## a lifecycle frame beside every `status` event (the feed mirrors them), and
## removals. `problemsOf` checks a scenario's own invariants (entries in time
## order and after the first moment, every session introduced before it is
## named, named moments unique, progress and recording changes naming known
## initiatives and milestones, every resume matched by the session's own
## input event).
##
## Everything a scenario holds is invented; this format carries no captured
## data.

import std/[algorithm, json, sets, tables]
import nim_agents/agent_harbor/[session_replay, fleet_fold]
import ./data_source

export data_source

type
  ScenarioEntryKind* = enum
    sekLifecycle = "lifecycle"   ## a lifecycle-feed frame
    sekListing = "listing"       ## one session's listing entry
    sekEvent = "event"           ## one event of a session's event stream
    sekResume = "resume"         ## the operator's input reached a session
    sekProgress = "progress"     ## a milestone's status changed in a plan
    sekRecording = "recording"   ## a recording appeared or changed state

  ScenarioEntry* = object
    ## One timestamped entry of a scenario.
    atMs*: int64
    moment*: string
      ## A named moment ("" for none): the scenario's state once every entry
      ## at `atMs` has been delivered.
    case kind*: ScenarioEntryKind
    of sekLifecycle:
      lifecycle*: LifecycleFrame
    of sekListing:
      listing*: FleetSession
    of sekEvent:
      sessionId*: string
      event*: JsonNode
        ## As the session's event stream sends it: `type`, `timestamp` in
        ## microseconds since the session started, and its own fields.
      ordinal*: int
        ## The event's 1-based place in the session's history.
    of sekResume:
      resume*: ResumeEvent
    of sekProgress:
      progress*: ProgressEvent
    of sekRecording:
      recording*: RecordingEvent

  ScenarioSession* = object
    ## One session a scenario names.
    entry*: FleetSession
      ## What its listing says besides its state (id, prompt, agent, host,
      ## origin, initiative); its state comes from `history`.
    startMs*: int64
    removedAtMs*: int64          ## 0: never removed
    history*: seq[JsonNode]
      ## Every event, oldest first; `timestamp` in µs since `startMs`.

  PlaybackScenario* = object
    name*: string                ## an id: `front-ends`, `initiative-run`
    title*: string               ## what a story's chrome says it shows
    firstMs*: int64              ## the first moment
    first*: FleetSnapshot        ## the listing at the first moment
    initiatives*: seq[Initiative]
      ## The initiatives at the first moment.
    sessions*: seq[ScenarioSession]
    entries*: seq[ScenarioEntry]

# ---------------------------------------------------------------------------
# Reading a scenario
# ---------------------------------------------------------------------------

proc isFleetEntry*(entry: ScenarioEntry): bool =
  ## Whether the entry is one of the fleet's frames (lifecycle, listing,
  ## event), which a source delivers as a `FleetFrame`.
  entry.kind in {sekLifecycle, sekListing, sekEvent}

proc frameOf*(entry: ScenarioEntry): FleetFrame =
  ## A fleet entry as the fleet frame a source delivers, stamped with its
  ## moment. Raises `ValueError` for an entry of another kind.
  case entry.kind
  of sekLifecycle: lifecycleFrame(entry.lifecycle, entry.atMs)
  of sekListing: sessionFrame(entry.listing, entry.atMs)
  of sekEvent: eventFrame(entry.sessionId, entry.event, entry.ordinal, entry.atMs)
  else: raise newException(ValueError, "a " & $entry.kind & " entry is not a fleet frame")

proc `$`*(entry: ScenarioEntry): string =
  ## An entry as a failing check names it: its moment, kind and subject.
  result = $entry.atMs & " " & $entry.kind & " "
  case entry.kind
  of sekLifecycle, sekListing, sekEvent: result.add $entry.frameOf
  of sekResume: result.add entry.resume.sessionId
  of sekProgress:
    result.add entry.progress.initiativeId & "/" & entry.progress.milestoneId &
      " -> " & entry.progress.status
  of sekRecording:
    result.add entry.recording.initiativeId & "/" & entry.recording.entry.id &
      " -> " & $entry.recording.entry.state
  if entry.moment.len > 0: result.add " [" & entry.moment & "]"

proc momentNames*(scenario: PlaybackScenario): seq[string] =
  ## The named moments, in time order.
  for entry in scenario.entries:
    if entry.moment.len > 0: result.add entry.moment

proc momentMs*(scenario: PlaybackScenario; name: string): int64 =
  ## The time of a named moment; -1 when the scenario has none by that name.
  for entry in scenario.entries:
    if entry.moment == name: return entry.atMs
  -1

proc lastMs*(scenario: PlaybackScenario): int64 =
  ## The moment of the last entry (the first moment when there is none).
  if scenario.entries.len == 0: scenario.firstMs else: scenario.entries[^1].atMs

proc eventTimeOf*(session: ScenarioSession; event: JsonNode): int64 =
  ## When one of the session's events happened.
  session.startMs + event{"timestamp"}.getBiggestInt(0).int64 div 1000

proc findSession*(scenario: PlaybackScenario; id: string): int =
  ## The index of the named session in `sessions`, or -1.
  for i, s in scenario.sessions:
    if s.entry.id == id: return i
  -1

# ---------------------------------------------------------------------------
# Authoring
# ---------------------------------------------------------------------------

proc scenarioEvent*(startMs, atMs: int64; body: JsonNode): JsonNode =
  ## `body` as an event of a session started at `startMs`, happening at
  ## `atMs` (its `timestamp`, in µs since the start).
  result = body.copy
  result["timestamp"] = %((atMs - startMs) * 1000)

proc resumeEntry*(atMs: int64; sessionId: string; moment = ""): ScenarioEntry =
  ScenarioEntry(kind: sekResume, atMs: atMs, moment: moment,
                resume: ResumeEvent(sessionId: sessionId, atMs: atMs))

proc progressEntry*(atMs: int64; initiativeId, milestoneId, status: string;
                    moment = ""): ScenarioEntry =
  ScenarioEntry(kind: sekProgress, atMs: atMs, moment: moment,
                progress: ProgressEvent(initiativeId: initiativeId,
                                        milestoneId: milestoneId, status: status))

proc recordingEntry*(atMs: int64; initiativeId: string; recording: RecordingEntry;
                     moment = ""): ScenarioEntry =
  ScenarioEntry(kind: sekRecording, atMs: atMs, moment: moment,
                recording: RecordingEvent(initiativeId: initiativeId,
                                          entry: recording))

proc buildScenario*(name, title: string; firstMs: int64;
                    sessions: seq[ScenarioSession]; initiatives: seq[Initiative];
                    extras: seq[ScenarioEntry] = @[];
                    moments: openArray[(int64, string)] = []): PlaybackScenario =
  ## A scenario from its sessions' histories and the entries no history
  ## implies (`extras`: resumes, progress events, recording changes; any
  ## moment they carry is kept). The first listing holds every session
  ## started by `firstMs` and not removed by then, in `sessions`' order, each
  ## replayed to `firstMs` by nim-agents' `sessionAt`. After it come the fleet
  ## entries the sessions' histories imply (see the module comment) and the
  ## extras, in time order; at one moment the extras come first (a resume
  ## before the input event that carries it), and otherwise each keeps the
  ## order it was given in. `moments` names moments by time: the name goes
  ## on the last entry at that time. Run `problemsOf` on the result.
  result = PlaybackScenario(name: name, title: title, firstMs: firstMs,
                            initiatives: initiatives, sessions: sessions)
  result.first = FleetSnapshot(capturedAtMs: firstMs,
                               sourceLabel: "invented scenario: " & title)
  var timed: seq[(int64, int, int, ScenarioEntry)]   # time, rank, order, entry
  proc add(rank: int; entry: ScenarioEntry) =
    timed.add (entry.atMs, rank, timed.len, entry)
  for extra in extras: add(0, extra)
  for s in sessions:
    let id = s.entry.id
    if s.startMs <= firstMs and (s.removedAtMs == 0 or s.removedAtMs > firstMs):
      var count = 0
      for event in s.history:
        if s.eventTimeOf(event) <= firstMs: inc count
      result.first.sessions.add s.entry.sessionAt(s.history, count, s.startMs)
    if s.startMs > firstMs:
      add(1, ScenarioEntry(kind: sekLifecycle, atMs: s.startMs,
        lifecycle: LifecycleFrame(event: "lifecycle", kind: "session_created",
          sessionId: id, status: "queued", agent: s.entry.agentSoftware,
          atMs: s.startMs)))
      add(1, ScenarioEntry(kind: sekListing, atMs: s.startMs,
        listing: s.entry.sessionAt(s.history, 0, s.startMs)))
    for i, event in s.history:
      let t = s.eventTimeOf(event)
      if t <= firstMs: continue
      add(1, ScenarioEntry(kind: sekEvent, atMs: t, sessionId: id,
                           event: event, ordinal: i + 1))
      if event{"type"}.getStr == "status":
        let status = event{"status"}.getStr
        add(1, ScenarioEntry(kind: sekLifecycle, atMs: t,
          lifecycle: LifecycleFrame(event: "lifecycle",
            kind: (if parseFleetStatus(status).isActive: "session_status_changed"
                   else: "session_completed"),
            sessionId: id, status: status, atMs: t)))
    if s.removedAtMs > firstMs:
      add(1, ScenarioEntry(kind: sekLifecycle, atMs: s.removedAtMs,
        lifecycle: LifecycleFrame(event: "lifecycle", kind: "session_removed",
                                  sessionId: id, atMs: s.removedAtMs)))
  result.first.total = result.first.sessions.len
  timed.sort proc(a, b: (int64, int, int, ScenarioEntry)): int =
    cmp((a[0], a[1], a[2]), (b[0], b[1], b[2]))
  for t in timed: result.entries.add t[3]
  for (atMs, moment) in moments:
    var last = -1
    for i, entry in result.entries:
      if entry.atMs == atMs: last = i
    if last < 0:
      raise newException(ValueError, "scenario " & name & ": no entry at the moment " &
                         moment & " (" & $atMs & ")")
    result.entries[last].moment = moment

# ---------------------------------------------------------------------------
# A scenario's own invariants
# ---------------------------------------------------------------------------

proc problemsOf*(scenario: PlaybackScenario): seq[string] =
  ## What is wrong with a scenario, one line per problem; empty when it
  ## holds its invariants: the first listing is taken at the first moment
  ## and names each session once; entries come after the first moment, in
  ## time order; every session an entry names was introduced before (in the
  ## first listing, or by a `session_created` frame or a listing entry) and
  ## not removed since; a session's events come in its history's order;
  ## named moments are unique; progress events name a known initiative and
  ## milestone, recording changes a known initiative and a recording with an
  ## id; every resume is matched by the session's own input event
  ## (`user_input` or `session_resumed`) at the same moment, so a view that
  ## follows events and one that follows resumes agree.
  let label = "scenario " & scenario.name & ": "
  if scenario.first.capturedAtMs != scenario.firstMs:
    result.add label & "the first listing is taken at " &
      $scenario.first.capturedAtMs & ", not at the first moment " & $scenario.firstMs
  var known = initHashSet[string]()
  for s in scenario.first.sessions:
    if s.id in known: result.add label & "the first listing names " & s.id & " twice"
    known.incl s.id
  var removed = initHashSet[string]()
  var milestones = initTable[string, HashSet[string]]()
  for initiative in scenario.initiatives:
    var ids = initHashSet[string]()
    for m in initiative.progress.milestones: ids.incl m.id
    milestones[initiative.id] = ids
  var moments = initHashSet[string]()
  var lastOrdinal = initTable[string, int]()
  for s in scenario.sessions:
    var n = 0
    for event in s.history:
      if s.eventTimeOf(event) <= scenario.firstMs: inc n
    lastOrdinal[s.entry.id] = n
  var previous = scenario.firstMs
  proc named(i: int; entry: ScenarioEntry; id: string): string =
    if id.len == 0: return label & "entry " & $i & " (" & $entry & ") names no session"
    if id in removed:
      return label & "entry " & $i & " (" & $entry & ") names " & id & " after its removal"
    if id notin known:
      return label & "entry " & $i & " (" & $entry & ") names " & id &
        " before it is introduced"
    ""
  for i, entry in scenario.entries:
    if entry.atMs <= scenario.firstMs:
      result.add label & "entry " & $i & " (" & $entry & ") is not after the first moment"
    if entry.atMs < previous:
      result.add label & "entry " & $i & " (" & $entry & ") comes before the entry ahead of it"
    previous = max(previous, entry.atMs)
    if entry.moment.len > 0:
      if entry.moment in moments:
        result.add label & "the moment " & entry.moment & " is named twice"
      moments.incl entry.moment
    case entry.kind
    of sekLifecycle:
      let id = entry.lifecycle.sessionId
      if entry.lifecycle.kind == "session_created" and id.len > 0 and
          id notin removed:
        known.incl id
      let problem = named(i, entry, id)
      if problem.len > 0: result.add problem
      if entry.lifecycle.kind == "session_removed": removed.incl id
    of sekListing:
      if entry.listing.id.len > 0 and entry.listing.id notin removed:
        known.incl entry.listing.id
      let problem = named(i, entry, entry.listing.id)
      if problem.len > 0: result.add problem
    of sekEvent:
      let problem = named(i, entry, entry.sessionId)
      if problem.len > 0: result.add problem
      let expected = lastOrdinal.getOrDefault(entry.sessionId, 0) + 1
      if entry.ordinal != expected:
        result.add label & "entry " & $i & " (" & $entry & ") is event #" &
          $entry.ordinal & " of its session, expected #" & $expected
      lastOrdinal[entry.sessionId] = entry.ordinal
      if entry.event.isNil or entry.event.kind != JObject:
        result.add label & "entry " & $i & " is not a JSON object"
    of sekResume:
      let problem = named(i, entry, entry.resume.sessionId)
      if problem.len > 0: result.add problem
      if entry.resume.atMs != entry.atMs:
        result.add label & "entry " & $i & " (" & $entry & ") is stamped " &
          $entry.resume.atMs & " inside"
      var matched = false
      for other in scenario.entries:
        if other.kind == sekEvent and other.atMs == entry.atMs and
            other.sessionId == entry.resume.sessionId and
            other.event{"type"}.getStr in ["user_input", "session_resumed"]:
          matched = true
      if not matched:
        result.add label & "entry " & $i & " (" & $entry &
          ") has no input event of its session at its moment"
    of sekProgress:
      let p = entry.progress
      if p.initiativeId notin milestones:
        result.add label & "entry " & $i & " (" & $entry & ") names an unknown initiative"
      elif p.milestoneId notin milestones[p.initiativeId]:
        result.add label & "entry " & $i & " (" & $entry & ") names an unknown milestone"
    of sekRecording:
      if entry.recording.initiativeId notin milestones:
        result.add label & "entry " & $i & " (" & $entry & ") names an unknown initiative"
      if entry.recording.entry.id.len == 0:
        result.add label & "entry " & $i & " names a recording without an id"
  for s in scenario.sessions:
    if s.entry.id notin known and s.entry.id notin removed:
      result.add label & "the session " & s.entry.id & " is never introduced"
    var last = 0'i64
    for event in s.history:
      let t = s.eventTimeOf(event)
      if t < last:
        result.add label & "the history of " & s.entry.id & " is not in time order"
      last = t
