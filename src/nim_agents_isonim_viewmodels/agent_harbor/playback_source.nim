## `PlaybackDataSource`: an `AgentHarborDataSource` that replays a playback
## scenario (`playback_scenario.nim`) on a clock, so the viewmodels over it --
## and the stories over them -- can be watched changing, paused, stepped
## and sought, with no server.
##
## **What it answers.** Its loads answer the scenario's state at the playback
## head: before anything is played that is the scenario's first frame (the
## first listing, its initiatives); later, the state after the entries
## delivered so far. `loadFleet` folds those entries with nim-agents' fleet
## reducer (`FleetFold`), `loadInitiatives` applies their progress events
## with `applyMilestoneStatus`, `loadLifecycle` is the lifecycle frames
## delivered, and `loadSessionEvents` a session's events up to the head. A
## viewmodel loaded before playing gets the first frame; one loaded later
## gets the same state the earlier ones folded their way to.
##
## **What it sends.** Each entry once, when the head reaches its moment, in
## the scenario's order, through the seam's subscriptions: lifecycle frames,
## listing entries and session events to `subscribeFleetFrames`, resumes to
## `subscribeResumes`, progress events (milestone statuses) to
## `subscribeProgress`, recording-state changes to `subscribeRecordings` (a
## new subscriber first receives each recording's state at the head). The
## source replays; it never decides what an entry means to a viewmodel --
## the viewmodels' reducers fold what it sends.
##
## **The controls.** `play` moves the head with the clock; `pause` holds it;
## `step` pauses and moves the head to the next entry's moment, delivering
## every entry at that moment; `seek` moves the head to a moment (a time, or
## a named moment with `seekMoment`), delivering what lies between when it
## goes forward. Going backwards past a delivered entry rebuilds from the
## first frame: the source's own state returns to the first frame, every
## subscriber is told to start over (`subscribeResets`, a `StreamReset`),
## and the entries up to the target are delivered again. So a seek backwards
## ends in the state a fresh playback stepped to the same moment shows.
##
## **The clock.** Time comes from an injected IsoNim clock (`ClockBase`,
## `isonim/core/clock`): a `TestClock` in tests and captures, which moves
## only when the test advances it, and a `RealClock` in a host that plays in
## real time. Playing anchors the scenario's time to the clock's: the head is
## at `anchorMs + (clock.now - anchorClock)`, and the source schedules one
## timer, at the next entry's moment. Nothing reads wall time, so the same
## steps give the same deliveries on every run.

import isonim/core/clock
import nim_agents/agent_harbor/fleet_fold
import ./data_source
import ./playback_scenario

export clock, playback_scenario

type
  PlaybackDataSource* = ref object of AgentHarborDataSource
    scenario: PlaybackScenario
    clock: ClockBase
    position: int
      ## Entries delivered: `scenario.entries[0 ..< position]`.
    headMs: int64
      ## The head's moment while paused (while playing, `currentMs`).
    playing: bool
    anchorClock: float64
    anchorMs: int64
    timer: int
    hasTimer: bool
    fold: FleetFold
    initiatives: seq[Initiative]
    recordings: seq[RecordingEvent]
      ## Each recording's latest state, in the order the recordings appeared.
    resetCount: int
    frameSubscribers*: Subscribers[FleetFrame]
    resumeSubscribers*: Subscribers[ResumeEvent]
    recordingSubscribers*: Subscribers[RecordingEvent]
    progressSubscribers*: ProgressSubscribers
    resetSubscribers*: Subscribers[StreamReset]

proc rebuildState(source: PlaybackDataSource) =
  ## The source's own state at the first frame.
  source.position = 0
  source.headMs = source.scenario.firstMs
  source.fold = initFleetFold(source.scenario.first)
  source.initiatives = source.scenario.initiatives
  source.recordings = @[]

proc newPlaybackDataSource*(scenario: PlaybackScenario; clock: ClockBase;
                            label = ""): PlaybackDataSource =
  ## A paused playback of `scenario` at its first frame, on `clock`. The
  ## label defaults to `playback: <scenario title>`.
  result = PlaybackDataSource(
    scenario: scenario, clock: clock,
    label: (if label.len > 0: label else: "playback: " & scenario.title))
  result.rebuildState()

# ---------------------------------------------------------------------------
# Where the head is
# ---------------------------------------------------------------------------

proc scenario*(source: PlaybackDataSource): PlaybackScenario = source.scenario
proc clock*(source: PlaybackDataSource): ClockBase = source.clock

proc position*(source: PlaybackDataSource): int =
  ## How many of the scenario's entries have been delivered.
  source.position

proc playing*(source: PlaybackDataSource): bool = source.playing

proc finished*(source: PlaybackDataSource): bool =
  ## Every entry has been delivered.
  source.position >= source.scenario.entries.len

proc resets*(source: PlaybackDataSource): int =
  ## How many times the source rebuilt from the first frame.
  source.resetCount

proc currentMs*(source: PlaybackDataSource): int64 =
  ## The head's moment in the scenario's time.
  if source.playing:
    source.anchorMs + int64(source.clock.now - source.anchorClock)
  else:
    source.headMs

proc nextMs*(source: PlaybackDataSource): int64 =
  ## The moment of the next entry; -1 when every entry has been delivered.
  if source.finished: -1 else: source.scenario.entries[source.position].atMs

proc currentMoment*(source: PlaybackDataSource): string =
  ## The named moment the head is at ("" when it is at none): the last
  ## delivered entry's moment, when it carries a name and the head has not
  ## moved past its time.
  if source.position == 0: return ""
  let last = source.scenario.entries[source.position - 1]
  if last.moment.len > 0 and source.currentMs == last.atMs: last.moment else: ""

# ---------------------------------------------------------------------------
# Delivery
# ---------------------------------------------------------------------------

proc deliver(source: PlaybackDataSource; entry: ScenarioEntry) =
  ## Updates the source's own state (what its loads answer), counts the
  ## entry delivered, then sends it to the subscribers of its kind; so a
  ## subscriber that loads while it is called reads the state after it.
  inc source.position
  case entry.kind
  of sekLifecycle, sekListing, sekEvent:
    let frame = entry.frameOf
    discard source.fold.apply(frame)
    discard source.frameSubscribers.broadcast(success(frame))
  of sekResume:
    discard source.resumeSubscribers.broadcast(success(entry.resume))
  of sekProgress:
    discard source.initiatives.applyProgressEvent(entry.progress)
    discard source.progressSubscribers.broadcast(success(entry.progress))
  of sekRecording:
    var found = false
    for held in source.recordings.mitems:
      if held.initiativeId == entry.recording.initiativeId and
          held.entry.id == entry.recording.entry.id:
        held = entry.recording
        found = true
    if not found: source.recordings.add entry.recording
    discard source.recordingSubscribers.broadcast(success(entry.recording))

proc deliverThrough(source: PlaybackDataSource; atMs: int64) =
  ## Delivers, in order, every entry not yet delivered whose moment is at or
  ## before `atMs`.
  while not source.finished and source.scenario.entries[source.position].atMs <= atMs:
    source.deliver(source.scenario.entries[source.position])

proc cancelTimer(source: PlaybackDataSource) =
  if source.hasTimer:
    source.clock.cancel(source.timer)
    source.hasTimer = false

proc scheduleNext(source: PlaybackDataSource)

proc onTimer(source: PlaybackDataSource) =
  source.hasTimer = false
  if not source.playing: return
  let now = source.currentMs
  source.deliverThrough(now)
  if source.finished:
    # The run is over: the head rests at the clock's moment, paused.
    source.headMs = max(now, source.scenario.lastMs)
    source.playing = false
  else:
    source.scheduleNext()

proc scheduleNext(source: PlaybackDataSource) =
  ## One timer, at the next entry's moment on the clock.
  source.cancelTimer()
  if source.finished or not source.playing: return
  let due = source.anchorClock + float64(source.nextMs - source.anchorMs)
  let delay = max(0.0, due - source.clock.now)
  let target = source
  source.timer = source.clock.schedule(proc() = target.onTimer(), delay)
  source.hasTimer = true

# ---------------------------------------------------------------------------
# The controls
# ---------------------------------------------------------------------------

proc play*(source: PlaybackDataSource): bool =
  ## Moves the head with the clock from where it is, delivering each entry
  ## when the clock reaches its moment. False, and nothing changes, when
  ## already playing or when every entry has been delivered.
  if source.playing or source.finished: return false
  source.anchorClock = source.clock.now
  source.anchorMs = source.headMs
  source.playing = true
  source.scheduleNext()
  true

proc pause*(source: PlaybackDataSource): bool =
  ## Holds the head where the clock has moved it. False when not playing.
  if not source.playing: return false
  source.headMs = source.currentMs
  source.playing = false
  source.cancelTimer()
  # A clock whose timer has not fired yet (a real one, late) may have passed
  # an entry: the head never rests past an entry it has not delivered.
  source.deliverThrough(source.headMs)
  true

proc step*(source: PlaybackDataSource): bool =
  ## Pauses, then moves the head to the next entry's moment and delivers
  ## every entry at that moment. False when every entry has been delivered.
  discard source.pause()
  if source.finished: return false
  let atMs = source.nextMs
  source.deliverThrough(atMs)
  source.headMs = atMs
  true

proc rebuild(source: PlaybackDataSource) =
  ## Back to the first frame: the source's state, then every subscriber
  ## told to start over (each reloads, reading the first frame).
  inc source.resetCount
  source.rebuildState()
  discard source.resetSubscribers.broadcast(success(StreamReset(
    atMs: source.scenario.firstMs, reason: "the playback was sought backwards")))

proc seek*(source: PlaybackDataSource; atMs: int64) =
  ## Moves the head to `atMs` (never before the first moment). Forward, it
  ## delivers every entry up to it, as stepping there would. Backwards past
  ## a delivered entry, it rebuilds from the first frame (every subscriber
  ## starts over) and delivers the entries up to `atMs` again. A playing
  ## source goes on playing from there.
  let wasPlaying = source.playing
  discard source.pause()
  let target = max(atMs, source.scenario.firstMs)
  if source.position > 0 and source.scenario.entries[source.position - 1].atMs > target:
    source.rebuild()
  source.deliverThrough(target)
  source.headMs = target
  if wasPlaying: discard source.play()

proc seekMoment*(source: PlaybackDataSource; moment: string): bool =
  ## `seek` to a named moment of the scenario. False, and nothing changes,
  ## for a name the scenario does not have.
  let atMs = source.scenario.momentMs(moment)
  if atMs < 0: return false
  source.seek(atMs)
  true

proc rewind*(source: PlaybackDataSource) =
  ## Back to the first frame, paused (a seek to the first moment).
  discard source.pause()
  source.seek(source.scenario.firstMs)

# ---------------------------------------------------------------------------
# The seam
# ---------------------------------------------------------------------------

method loadFleet*(source: PlaybackDataSource; done: FleetCallback) =
  ## The listing at the head (the scenario's first listing before anything
  ## is played).
  var snapshot = source.fold.snapshot
  snapshot.sourceLabel = source.scenario.first.sourceLabel
  done(success(snapshot))

method loadInitiatives*(source: PlaybackDataSource; done: InitiativesCallback) =
  ## The initiatives at the head, their progress events applied.
  done(success(source.initiatives))

method loadLifecycle*(source: PlaybackDataSource; done: LifecycleCallback) =
  ## The lifecycle frames delivered so far, in order.
  var frames: seq[LifecycleFrame]
  for i in 0 ..< source.position:
    if source.scenario.entries[i].kind == sekLifecycle:
      frames.add source.scenario.entries[i].lifecycle
  done(success(frames))

method loadSessionEvents*(source: PlaybackDataSource; sessionId: string;
                          done: EventsCallback) =
  ## A session's event history up to the head, newest first (as the server
  ## lists it); an error for a session the fleet does not hold at the head.
  let at = source.scenario.findSession(sessionId)
  if at < 0 or source.fold.find(sessionId) < 0:
    done(failure[SessionEventHistory]("no session " & sessionId &
                                      " at this moment of the playback"))
    return
  let s = source.scenario.sessions[at]
  let upTo = if source.position == 0: source.scenario.firstMs
             else: max(source.scenario.firstMs,
                       source.scenario.entries[source.position - 1].atMs)
  var history = SessionEventHistory(sessionId: sessionId)
  for i in countdown(s.history.high, 0):
    let event = s.history[i]
    let t = s.eventTimeOf(event)
    if t <= upTo:
      var line = activityFromJson(event)
      line.timestampMs = t
      history.events.add line
  history.totalCount = history.events.len
  done(success(history))

method subscribeFleetFrames*(source: PlaybackDataSource;
                             callback: FeedCallback[FleetFrame]): Subscription[FleetFrame] =
  source.frameSubscribers.subscribe(callback)

method subscribeResumes*(source: PlaybackDataSource;
                         callback: FeedCallback[ResumeEvent]): Subscription[ResumeEvent] =
  source.resumeSubscribers.subscribe(callback)

method subscribeProgress*(source: PlaybackDataSource;
                          callback: ProgressCallback): ProgressSubscription =
  source.progressSubscribers.subscribe(callback)

method subscribeRecordings*(source: PlaybackDataSource;
                            callback: FeedCallback[RecordingEvent]): Subscription[RecordingEvent] =
  ## Subscribes, then delivers each recording's state at the head to the new
  ## subscription alone, so a subscriber that comes late starts where the
  ## others are.
  result = source.recordingSubscribers.subscribe(callback)
  for held in source.recordings:
    discard result.deliver(success(held))

method subscribeResets*(source: PlaybackDataSource;
                        callback: FeedCallback[StreamReset]): Subscription[StreamReset] =
  source.resetSubscribers.subscribe(callback)
