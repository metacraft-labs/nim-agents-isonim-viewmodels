## The sessions family's tab-strip variant (`SessionTabStripVM`), the
## Initiatives and Initiative Progress viewmodels, and the working set and
## initiatives the fixture source assembles. Over the fixture set the build
## embedded (the private capture in this workspace, the synthetic set in
## public CI; `AGENT_HARBOR_FIXTURES=synthetic just test` runs both), the
## invented 40-session working set, and the seam's state sources.
##
## No mocks: the fixture source replays captures, and the snapshot, pending
## and failing sources are the seam's production implementations for the
## states no capture shows. Assertions about fixture contents are made
## against the manifest's own JSON, decoded independently here.
##
## The progress-event suite (last) adds two test doubles, both in-repo
## sources over invented plans built in this file. `InitiativesOnlySource`
## serves initiatives and leaves `subscribeProgress` to the base method: a
## server that lists plans without an event stream, which is the case the
## base method's "does not provide" answer exists for and which no
## production source in this repo is. `LeakySource` is a `SnapshotDataSource`
## that also keeps each subscriber's raw callback, so the test can deliver an
## event after the subscriber cancelled, as a source that ignores the
## cancellation would; no production source does that on demand.
## `AnswerThenSendSource` is a `SnapshotDataSource` that sends an event at
## once after answering the plans, as a server whose plan moves right after
## it answered would; it pins that a viewmodel subscribes before it loads, a
## race no production source in this repo can stage on demand. The
## sending source is the production `SnapshotDataSource` (`sendProgress`).
## The expected progress after each event is written out by hand in the
## test (counts, percentages, groups, current milestone), not computed
## through `applyMilestoneStatus` or `applyProgress`.

import std/[algorithm, json, sets, strutils, tables, unittest]
import isonim/core/[computation, owner, signals]
import nim_agents_isonim_viewmodels

const Now = 1_800_000_000_000'i64

proc withVM[T](build: proc(): T; body: proc(vm: T)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = build()
    body(vm)
    vm.dispose()
    disposeRoot()

suite "layout rules":
  test "the multi-line strip packs tabs into rows in order":
    check packTabRows([100, 100, 100], 250) == @[@[0, 1], @[2]]
    check packTabRows([100, 100, 100], 300) == @[@[0, 1, 2]]
    check packTabRows([100, 100, 100], 300, gap = 4) == @[@[0, 1], @[2]]
    # A tab wider than the strip gets a row of its own; none is lost.
    check packTabRows([50, 400, 50], 200) == @[@[0], @[1], @[2]]
    check packTabRows(newSeq[int](), 200).len == 0
    var widths: seq[int]
    for i in 0 ..< 40: widths.add 96 + (i mod 5) * 17
    var seen = 0
    for row in packTabRows(widths, 1200, 4):
      var used = 0
      for i in row: used += widths[i]
      used += 4 * (row.len - 1)
      check used <= 1200
      seen += row.len
    check seen == 40

  test "the single-line strip keeps the active tab visible":
    check singleLineCapacity(0) == high(int)
    check singleLineCapacity(760) == 4   # (760 - 102 + 4) div (160 + 4)
    check singleLineCapacity(80, tabMin = 12, gap = 1, controls = 6) == 5  # terminal cells
    var layout = singleLineLayout(10, 2, 4)
    check layout.visible == @[0, 1, 2, 3]
    check layout.overflow == @[4, 5, 6, 7, 8, 9]
    layout = singleLineLayout(10, 8, 4)
    check layout.visible == @[0, 1, 2, 8]
    check 8 notin layout.overflow
    check layout.overflow.len == 6
    check singleLineLayout(3, 0, high(int)).overflow.len == 0

suite "the working sets and initiatives of the fixture set":
  let fixtures = newFixtureDataSource()
  let manifest = fixtures.manifest
  var planVisibility = initTable[string, string]()
  var planId = initTable[string, string]()
  for plan in manifest{"plans"}.getElems:
    planVisibility[plan{"name"}.getStr] = plan{"visibility"}.getStr
    planId[plan{"name"}.getStr] = plan{"initiative", "id"}.getStr

  test "every working-set entry becomes one session, in order, with what it states":
    for kind in WorkingSetKind:
      let set = fixtures.workingSet(kind)
      let entries = manifest{"workingSets", $kind}.getElems
      check entries.len > 0
      check set.sessions.len == entries.len
      for i, entry in entries:
        check set.sessions[i].originFrontEnd == entry{"origin"}.getStr
        let plan = entry{"plan"}.getStr
        check set.sessions[i].planId == (if plan.len > 0: planId[plan] else: "")
        if entry{"from"}.getStr == "fleet":
          check set.sessions[i].id == entry{"sessionId"}.getStr

  test "each set is coherent: never real and invented data together":
    # Manager note 18: a story shows a real set or an invented one. The
    # scenario set is scenario runs and invented plans; the real set is fleet
    # sessions and real plans. (The synthetic fixture set is all invented.)
    for kind in WorkingSetKind:
      var froms = initHashSet[string]()
      for entry in manifest{"workingSets", $kind}.getElems:
        froms.incl entry{"from"}.getStr
        let plan = entry{"plan"}.getStr
        if plan.len > 0 and planVisibility[plan] != "synthetic":
          check (planVisibility[plan] == "invented") == (kind == wsScenario)
      check froms.len == 1
      check (if kind == wsScenario: "scenario" in froms else: "fleet" in froms)
      let set = fixtures.workingSet(kind)
      let initiatives = fixtures.initiativesOf(kind)
      var ids = initHashSet[string]()
      for initiative in initiatives: ids.incl initiative.id
      # Every session's plan is an initiative of the same set, and every
      # initiative of the set is of the set's provenance.
      for session in set.sessions:
        if session.planId.len > 0: check session.planId in ids
      for plan in manifest{"plans"}.getElems:
        if plan{"initiative", "id"}.getStr in ids and plan{"visibility"}.getStr != "synthetic":
          check (plan{"visibility"}.getStr == "invented") == (kind == wsScenario)

  test "a scenario run shown at its question waits for its answer":
    var asked = 0
    let set = fixtures.workingSet(wsScenario)
    for i, entry in manifest{"workingSets", "scenario"}.getElems:
      if entry{"at"}.getStr == "question":
        inc asked
        check set.sessions[i].awaitingInput
        check set.sessions[i].attentionOf(espIdlePromptApart) == saNeedsInput
    check asked > 0

  test "several front-ends of origin are represented":
    var origins = initHashSet[string]()
    for session in fixtures.workingSet(wsScenario).sessions:
      if session.originFrontEnd.len > 0: origins.incl session.originFrontEnd
    check origins.len >= 3

  test "each initiative is its plan, parsed, with the sessions launched for it":
    for kind in WorkingSetKind:
      let initiatives = fixtures.initiativesOf(kind)
      check initiatives.len >= 1
      let set = fixtures.workingSet(kind)
      for initiative in initiatives:
        check initiative.progress.milestones.len > 0
        check initiative.progress.summary.totalMilestones ==
          initiative.progress.milestones.len
        for id in initiative.sessionIds:
          var found = false
          for session in set.sessions:
            if session.id == id:
              found = true
              check session.planId == initiative.id
          check found
      for session in set.sessions:
        if session.planId.len > 0:
          var listed = 0
          for initiative in initiatives:
            if session.id in initiative.sessionIds: inc listed
          check listed == 1
    # A real server's answer is the real plans.
    var got: DataResult[seq[Initiative]]
    fixtures.loadInitiatives proc(a: DataResult[seq[Initiative]]) = got = a
    check got.ok
    check got.value.len == fixtures.initiativesOf(wsReal).len

suite "the invented working sets are coherent":
  # A story shows one coherent set: a session under an initiative works on
  # that initiative, no two sessions share a title, and no captured scenario
  # run is passed off as work of an invented initiative.
  let scenarioTitles = block:
    var titles = initHashSet[string]()
    for session in newFixtureDataSource().workingSet(wsScenario).sessions:
      titles.incl session.prompt
    titles

  # A template, not a proc: `check` inside a plain proc would not fail the
  # test that calls it.
  template checkCoherent(sessionCount, initiativeCount: int; long = false) =
    let generated = syntheticWorkingSet(sessionCount, initiativeCount, Now, long)
    let snapshot = generated.snapshot
    let plans = generated.initiatives
    var seen = initHashSet[string]()
    var planIds = initHashSet[string]()
    for plan in plans: planIds.incl plan.id
    for session in snapshot.sessions:
      check session.prompt notin seen
      seen.incl session.prompt
      check session.prompt notin scenarioTitles
      if session.planId.len > 0: check session.planId in planIds
      var belongs = false
      for title in syntheticTitlesOf(session.planId):
        if session.prompt == title or long and session.prompt.startsWith(title & " "):
          belongs = true
      if not belongs: echo "  incoherent: ", session.prompt, " under ", session.planId
      check belongs

  test "the default set":
    checkCoherent(DefaultSessions, DefaultInitiatives)
  test "forty sessions over five initiatives":
    checkCoherent(40, 5)
  test "long names":
    checkCoherent(4, 5, long = true)
  test "a small set":
    checkCoherent(3, 2)
  test "a set larger than its initiatives' titles still repeats none":
    var seen = initHashSet[string]()
    for session in syntheticWorkingSet(60, 2, Now).snapshot.sessions:
      check session.prompt notin seen
      seen.incl session.prompt
  test "every initiative of the default set has sessions, and one session has none":
    let (snapshot, plans) = defaultWorkingSet(Now)
    check plans.len == DefaultInitiatives
    for plan in plans: check plan.sessionIds.len > 0
    var loose = 0
    for session in snapshot.sessions:
      if session.planId.len == 0: inc loose
    check loose > 0

suite "the tab strip":
  test "tabs come in launch order, keep it, and the first becomes active":
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newWorkingSetDataSource())) do (vm: SessionTabStripVM):
      check vm.state.val == asIdle
      vm.load()
      check vm.state.val == asReady
      let tabs = vm.tabs
      var sessions = newFixtureDataSource().workingSet(wsScenario).sessions
      check tabs.len == sessions.len
      # Launch order: creation time, the id breaking ties.
      sessions.sort proc(a, b: FleetSession): int =
        result = cmp(a.createdAtMs, b.createdAtMs)
        if result == 0: result = cmp(a.id, b.id)
      for i, tab in tabs: check tab.id == sessions[i].id
      check tabs[0].active
      check vm.activeIndex == 0
      # A re-read listing in another order moves no tab.
      vm.load()
      for i, tab in vm.tabs: check tab.id == sessions[i].id

  test "effective status: an ended turn is idle, a question needs input":
    let snapshot = FleetSnapshot(capturedAtMs: Now, sessions: @[
      FleetSession(id: "idle", status: fsRunning, awaitingInput: true,
                   awaitingInputSource: "claude-stop-hook", createdAtMs: 1),
      FleetSession(id: "asks", status: fsRunning, awaitingInput: true,
                   awaitingInputSource: "asks:native-question:1", createdAtMs: 2),
      FleetSession(id: "runs", status: fsRunning, createdAtMs: 3),
      FleetSession(id: "done", status: fsCompleted, createdAtMs: 4)])
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newSnapshotDataSource(snapshot))) do (vm: SessionTabStripVM):
      vm.load()
      let tabs = vm.tabs
      check tabs[0].attention == saIdle
      check tabs[0].statusLabel == "idle"
      check tabs[1].attention == saNeedsInput
      check tabs[2].attention == saRunning
      check tabs[3].attention == saEnded
      check "next instruction" in tabs[0].tooltip
    # The WebUI's policy, passed by a host that wants it: both waits need input.
    withVM(proc(): SessionTabStripVM =
        var policy = tabStripSessionPolicy()
        policy.status = espNeedsInputWins
        newSessionTabStripVM(newSnapshotDataSource(snapshot), policy = policy)) do (vm: SessionTabStripVM):
      vm.load()
      check vm.tabs[0].attention == saNeedsInput

  test "titles fall back from a withheld prompt and are never empty":
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newWorkingSetDataSource())) do (vm: SessionTabStripVM):
      vm.load()
      var placeholders = 0
      for tab in vm.tabs:
        check tab.title.len > 0
        if tab.titleSource == lsId: inc placeholders
      # The captured sessions an operator works with are mostly named.
      check placeholders * 2 < vm.tabs.len

  test "activate, step, close and move":
    let (snapshot, _) = syntheticWorkingSet(5, 0, Now)
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newSnapshotDataSource(snapshot))) do (vm: SessionTabStripVM):
      vm.load()
      let ids = block:
        var s: seq[string]
        for t in vm.tabs: s.add t.id
        s
      check vm.activate(ids[2])
      check not vm.activate(ids[2])
      check not vm.activate("nope")
      check vm.step(1)
      check vm.activeId.val == ids[3]
      check vm.step(-4)
      check vm.activeId.val == ids[4]   # wraps
      check vm.close(ids[4])
      check vm.activeId.val == ids[3]   # the previous: it was the last tab
      check vm.tabs.len == 4
      check vm.move(ids[3], 0)
      check vm.tabs[0].id == ids[3]
      check vm.tabs[1].id == ids[0]
      check vm.close(ids[3])
      check vm.activeId.val == ids[0]   # the next one

  test "forty sessions over five initiatives: rows, overflow and groups":
    let (snapshot, initiatives) = syntheticWorkingSet(40, 5, Now)
    check initiatives.len == 5
    withVM(proc(): SessionTabStripVM =
        newSessionTabStripVM(newSnapshotDataSource(snapshot, "invented", initiatives))) do (vm: SessionTabStripVM):
      vm.load()
      check vm.tabs.len == 40
      vm.stripWidthPx.val = 760
      # (760 - 102 controls - 64 for the wider active tab + 4) div (160 + 4)
      var line = vm.singleLine
      check line.visible.len == 3
      check line.overflow.len == 37
      discard vm.activate(vm.tabs[30].id)
      line = vm.singleLine
      check 30 in line.visible
      check line.visible.len == 3
      vm.grouped.val = true
      let groups = vm.groups
      check groups.len == 6           # five initiatives and the unattached
      check groups[^1].planId == ""
      for i in 0 ..< 5: check groups[i].planId == initiatives[i].id
      check groups[0].title == initiatives[0].title
      var total = 0
      for g in groups:
        total += g.tabs.len
        var sum = 0
        for c in g.counts: sum += c
        check sum == g.tabs.len
        for tab in g.tabs: check tab.planId == g.planId
      check total == 40
      vm.grouped.val = false
      check vm.groups.len == 1

  test "a terminal sets every width in cells, the gap between tabs too":
    # The strip's widths are in the renderer's unit. A terminal that sets
    # cells must get a gap in cells: counted at the web's 4px, 80 cells keep
    # four 12-cell tabs where five fit.
    let (snapshot, initiatives) = syntheticWorkingSet(40, 5, Now)
    withVM(proc(): SessionTabStripVM =
        newSessionTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: SessionTabStripVM):
      vm.load()
      check vm.tabGap == TabGapPx       # the web's pixels by default
      vm.stripWidthPx.val = 80
      vm.tabMinWidth = 12
      vm.tabGap = 1
      vm.tabControlsWidth = 6
      vm.activeTabExtra = 0
      # 6 + 5 * 12 + 4 * 1 = 70 <= 80; a sixth tab needs 83.
      check vm.singleLine.visible.len == 5
      vm.stripWidthPx.val = 82
      check vm.singleLine.visible.len == 5
      vm.stripWidthPx.val = 83
      check vm.singleLine.visible.len == 6
      vm.tabGap = 0
      vm.stripWidthPx.val = 78
      check vm.singleLine.visible.len == 6   # 6 + 6 * 12 = 78

  test "focusing an initiative highlights and activates its tabs":
    let (snapshot, initiatives) = syntheticWorkingSet(12, 3, Now)
    withVM(proc(): SessionTabStripVM =
        newSessionTabStripVM(newSnapshotDataSource(snapshot, "invented", initiatives))) do (vm: SessionTabStripVM):
      vm.load()
      vm.focusInitiative(initiatives[2].id)
      var active: SessionItem
      for tab in vm.tabs:
        if tab.active: active = tab
      check active.planId == initiatives[2].id
      var focused = 0
      for tab in vm.tabs:
        if vm.isInFocus(tab): inc focused
      check focused == initiatives[2].sessionIds.len

  test "a lifecycle frame adds a tab at the end and updates it in place":
    let (snapshot, _) = syntheticWorkingSet(3, 0, Now)
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newSnapshotDataSource(snapshot))) do (vm: SessionTabStripVM):
      vm.load()
      vm.applyFrame(LifecycleFrame(event: "lifecycle", kind: "session_created",
                                   sessionId: "new-one", status: "queued"))
      check vm.tabs.len == 4
      check vm.tabs[^1].id == "new-one"
      check vm.tabs[^1].attention == saQueued
      vm.applyFrame(LifecycleFrame(event: "lifecycle", kind: "session_status_changed",
                                   sessionId: "new-one", status: "running"))
      check vm.tabs[^1].attention == saRunning

  test "loading, error and empty":
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newPendingDataSource())) do (vm: SessionTabStripVM):
      vm.load()
      check vm.state.val == asLoading
      check vm.tabs.len == 0
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newFailingDataSource("boom"))) do (vm: SessionTabStripVM):
      vm.load()
      check vm.state.val == asError
      check vm.error.val == "boom"
    withVM(proc(): SessionTabStripVM = newSessionTabStripVM(newSnapshotDataSource(FleetSnapshot()))) do (vm: SessionTabStripVM):
      vm.load()
      check vm.state.val == asReady
      check vm.tabs.len == 0
      check vm.activeId.val == ""
      check vm.summaryText == "0 sessions"

suite "initiatives and their progress":
  test "initiatives come by need, and their sessions too":
    let (snapshot, initiatives) = syntheticWorkingSet(30, 5, Now)
    withVM(proc(): InitiativesVM =
        newInitiativesVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativesVM):
      vm.load()
      let rows = vm.rows
      check rows.len == 5
      for i in 1 ..< rows.len: check ord(rows[i - 1].state) <= ord(rows[i].state)
      for row in rows:
        for i in 1 ..< row.sessions.len:
          check ord(row.sessions[i - 1].attention) <= ord(row.sessions[i].attention)

  test "the initiatives list their sessions with their states":
    withVM(proc(): InitiativesVM = newInitiativesVM(newWorkingSetDataSource())) do (vm: InitiativesVM):
      vm.load()
      check vm.state.val == asReady
      let rows = vm.rows
      check rows.len >= 2
      var withSessions = 0
      for row in rows:
        check row.title.len > 0
        check row.progressLong.contains("milestone")
        check row.progressText.contains("/")
        if row.sessions.len > 0: inc withSessions
        var sum = 0
        for c in row.sessionCounts: sum += c
        check sum == row.sessions.len
        var statuses = 0
        for c in row.statusCounts: statuses += c
        check statuses > 0
      check withSessions > 0

  test "progress counts match the plan's milestones":
    let (_, initiatives) = syntheticWorkingSet(10, 5, Now)
    withVM(proc(): InitiativeProgressVM =
        newInitiativeProgressVM(newSnapshotDataSource(FleetSnapshot(), "x", initiatives),
                                initiatives[3].id)) do (vm: InitiativeProgressVM):
      vm.load()
      check vm.found
      let p = initiatives[3].progress
      var completed = 0
      for m in p.milestones:
        if m.status == "completed": inc completed
      check vm.headline.startsWith($completed & " of " & $p.milestones.len)
      var listed = 0
      for g in vm.groups:
        listed += g.milestones.len
        check g.title.endsWith("(" & $g.milestones.len & ")")
        for m in g.milestones:
          check m.statusClass == g.status
          # The failing count a view marks as an error is the plan's own.
          for pm in p.milestones:
            if pm.id == m.id: check m.failing == pm.verifications.failing
      check listed == p.milestones.len
      check vm.groups[0].status == mscInProgress
      var currents = 0
      for g in vm.groups:
        for m in g.milestones:
          if m.current: inc currents
      check currents == 1

  test "a milestone completing updates the counts once":
    let (_, initiatives) = syntheticWorkingSet(10, 2, Now)
    withVM(proc(): InitiativeProgressVM =
        newInitiativeProgressVM(newSnapshotDataSource(FleetSnapshot(), "x", initiatives),
                                initiatives[0].id)) do (vm: InitiativeProgressVM):
      vm.load()
      let before = vm.statusCounts
      var runs = 0
      createEffect proc() =
        discard vm.groups
        inc runs
      let afterLoad = runs
      let current = vm.current.progress.currentMilestone
      check vm.applyProgress(initiatives[0].id, current, "completed")
      check runs == afterLoad + 1
      let after = vm.statusCounts
      check after[mscCompleted] == before[mscCompleted] + 1
      check after[mscInProgress] == before[mscInProgress] - 1
      check not vm.applyProgress(initiatives[0].id, current, "completed")
      check not vm.applyProgress("nope", current, "planned")
      check runs == afterLoad + 1

  test "an invented plan made ready for a completion reads done after the event":
    # The progress-event story: the milestone that completes has all its
    # deliverables and passing tests, and the executive summary names the
    # next milestone, as the plan reads after the event (the event itself
    # still moves the status and the current milestone).
    var (_, initiatives) = syntheticWorkingSet(14, 4, Now)
    let current = initiatives[0].progress.currentMilestone
    check current.len > 0
    let before = initiatives[0].executiveSummary
    check initiatives[0].readyForCompletion(current)
    check not initiatives[0].readyForCompletion("no-such-milestone")
    check initiatives[0].executiveSummary != before
    withVM(proc(): InitiativeProgressVM =
        newInitiativeProgressVM(newSnapshotDataSource(FleetSnapshot(), "x", initiatives),
                                initiatives[0].id)) do (vm: InitiativeProgressVM):
      vm.load()
      check vm.applyProgress(initiatives[0].id, current, "completed")
      var done: MilestoneLine
      var nowCurrent = ""
      for g in vm.groups:
        for m in g.milestones:
          if m.id == current: done = m
          if m.current: nowCurrent = m.id
      check done.id == current
      check done.statusClass == mscCompleted
      check not done.current
      var plan: MilestoneDetail
      for m in vm.current.progress.milestones:
        if m.id == current: plan = m
      check plan.deliverables.done == plan.deliverables.total
      check plan.verifications.pending == 0 and plan.verifications.failing == 0
      check plan.verifications.passing > 0
      check done.deliverablesText == $plan.deliverables.total & "/" &
        $plan.deliverables.total & " deliverables"
      check "pending" notin done.testsText and "passing" in done.testsText
      check nowCurrent.len > 0 and nowCurrent != current
      var nowTitle = ""
      for m in vm.current.progress.milestones:
        if m.id == nowCurrent: nowTitle = m.title
      check vm.current.executiveSummary.endsWith("the current one is " & nowTitle & ".")
      check vm.current.executiveSummary.contains(
        $vm.current.progress.summary.completedMilestones & " of ")

  test "an unknown initiative, a failing source, a pending one":
    withVM(proc(): InitiativeProgressVM =
        newInitiativeProgressVM(newSnapshotDataSource(FleetSnapshot()), "missing")) do (vm: InitiativeProgressVM):
      vm.load()
      check not vm.found
      check vm.groups.len == 0
    withVM(proc(): InitiativesVM = newInitiativesVM(newFailingDataSource("down"))) do (vm: InitiativesVM):
      vm.load()
      check vm.state.val == asError
    withVM(proc(): InitiativesVM = newInitiativesVM(newPendingDataSource())) do (vm: InitiativesVM):
      vm.load()
      check vm.state.val == asLoading

suite "the initiative tab bar":
  test "one tab per initiative with its state and n/m, then loose open sessions":
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newWorkingSetDataSource())) do (vm: InitiativeTabStripVM):
      vm.load()
      check vm.state.val == asReady
      var got: DataResult[seq[Initiative]]
      newWorkingSetDataSource().loadInitiatives proc(a: DataResult[seq[Initiative]]) = got = a
      let tabs = vm.tabs
      var initiativeTabs = 0
      for tab in tabs:
        if tab.kind == stkInitiative:
          inc initiativeTabs
          check tab.progressText.contains("/")
      check initiativeTabs == got.value.len
      check tabs[0].kind == stkInitiative
      check tabs[0].active
      # Every initiative's tab says its milestones done of planned.
      for i, initiative in got.value:
        let s = initiative.progress.summary
        check tabs[i].progressText == $s.completedMilestones & "/" & $s.totalMilestones

  test "an initiative's state comes from its sessions and its plan":
    let (snapshot, initiatives) = syntheticWorkingSet(10, 2, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      for tab in vm.tabs:
        if tab.kind != stkInitiative: continue
        var attentions: seq[SessionAttention]
        for item in vm.sessionsOf(tab.id): attentions.add item.attention
        var blocked = 0
        for initiative in initiatives:
          if initiative.id == tab.id: blocked = statusCounts(initiative.progress)[mscBlocked]
        var done = false
        for initiative in initiatives:
          if initiative.id == tab.id:
            done = planDone(initiative.progress.summary.completedMilestones,
                            initiative.progress.summary.totalMilestones)
        check tab.state == initiativeStateOf(attentions, blocked, done)
      # Synthetic session 0 waits on a question and belongs to the first plan.
      check vm.tabs[0].state == isNeedsInput

  test "sessions started elsewhere wait behind the count badge until opened":
    let (snapshot, _) = syntheticWorkingSet(12, 0, Now)   # no initiatives at all
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newSnapshotDataSource(snapshot))) do (vm: InitiativeTabStripVM):
      vm.load()
      var own, others = 0
      for s in snapshot.sessions:
        if s.originFrontEnd == OwnFrontEnd: inc own else: inc others
      check own > 0 and others > 1
      check vm.tabs.len == own
      check vm.elsewhereCount == others
      check vm.elsewhere.len == others
      # A count and its words, never bracketed; the tooltip says it whole.
      check vm.elsewhereLabel == "agent harbor sessions"
      check vm.elsewhereTooltip.startsWith($others & " agent harbor sessions started elsewhere")
      check '[' notin vm.elsewhereLabel and '[' notin vm.elsewhereTooltip
      for entry in vm.elsewhere: check entry.initiativeTitle == ""
      let chosen = vm.elsewhere[0].item.id
      check vm.openSession(chosen)
      check vm.elsewhere.len == others - 1
      check vm.activeTab.val == sessionKey(chosen)
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newSnapshotDataSource(FleetSnapshot()))) do (vm: InitiativeTabStripVM):
      vm.load()
      check vm.elsewhereCount == 0
      check vm.elsewhereLabel == ""

  test "a session of an initiative started elsewhere is listed with its initiative and opens inside its tab":
    let (snapshot, initiatives) = syntheticWorkingSet(DefaultSessions, DefaultInitiatives, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      var titles = initTable[string, string]()
      for initiative in initiatives: titles[initiative.id] = initiative.title
      var expected = 0
      for s in snapshot.sessions:
        if s.originFrontEnd != OwnFrontEnd: inc expected
      check vm.elsewhereCount == expected
      var ofInitiative = ""
      for entry in vm.elsewhere:
        var session: FleetSession
        for s in snapshot.sessions:
          if s.id == entry.item.id: session = s
        check session.originFrontEnd != OwnFrontEnd
        # Each entry names its initiative ("" for none) beside its state.
        check entry.initiativeTitle == titles.getOrDefault(session.planId, "")
        check entry.item.statusLabel.len > 0
        if ofInitiative.len == 0 and session.planId.len > 0: ofInitiative = session.id
      check ofInitiative.len > 0
      var plan = ""
      for s in snapshot.sessions:
        if s.id == ofInitiative: plan = s.planId
      let before = vm.tabs.len
      check vm.openSession(ofInitiative)
      # Brought into view inside its initiative's tab, not as a tab of its own.
      check vm.tabs.len == before
      check vm.activeTab.val == initiativeKey(plan)
      check vm.selectedSessionOf(plan) == ofInitiative
      check vm.elsewhereCount == expected - 1
      for entry in vm.elsewhere: check entry.item.id != ofInitiative

  test "Next and Previous walk the waiting sessions; auto-switch moves on":
    let (snapshot, initiatives) = syntheticWorkingSet(20, 3, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      let order = inboxOrder(snapshot.sessions)
      check order.len >= 3
      check vm.inboxCount == order.len
      check vm.stepInbox(1)
      check vm.activeSessionId == snapshot.sessions[order[0]].id
      check vm.inboxPosition == "1 of " & $order.len
      check vm.stepInbox(1)
      check vm.activeSessionId == snapshot.sessions[order[1]].id
      check vm.stepInbox(-1)
      check vm.activeSessionId == snapshot.sessions[order[0]].id
      # A session of an initiative is shown in its initiative's tab.
      let first = snapshot.sessions[order[0]]
      if first.planId.len > 0:
        check vm.activeTab.val == initiativeKey(first.planId)
        check vm.selectedSessionOf(first.planId) == first.id
      # Auto-switch: the instruction arrives, the view moves to the next.
      vm.autoSwitch.val = true
      vm.markResumed(first.id)
      check vm.activeSessionId == snapshot.sessions[order[1]].id
      vm.autoSwitch.val = false
      let inView = vm.activeSessionId
      vm.markResumed(inView)
      check vm.activeSessionId == inView     # off: the view stays

  test "the recording switcher: numbered, the active one always drawn":
    var entries: seq[RecordingEntry]
    for i in 0 ..< 12:
      entries.add RecordingEntry(id: "r" & $i, name: "trace " & $i, revision: "abc" & $i,
                                 origin: "ct test run",
                                 state: (if i == 2: rsLoading elif i == 3: rsFailed
                                         elif i == 4: rsMissing else: rsReady),
                                 error: (if i == 3: "replay server refused it"
                                         elif i == 4: "no longer on the server" else: ""))
    var b = recordingButtons(entries, "r0", 9)
    check b.buttons.len == 9
    check b.hidden == 3
    check b.buttons[0].number == 1 and b.buttons[0].active
    check b.buttons[2].state == rsLoading
    check "failed to load: replay server refused it" in b.buttons[3].tooltip
    # A missing recording is told apart from one that failed to load.
    check b.buttons[4].state == rsMissing
    check "(missing: no longer on the server)" in b.buttons[4].tooltip
    check "failed" notin b.buttons[4].tooltip
    b = recordingButtons(entries, "r11", 9)
    check b.buttons[^1].number == 12 and b.buttons[^1].active
    check recordingButtons(newSeq[RecordingEntry](), "", 9).buttons.len == 0
    let (snapshot, initiatives) = syntheticWorkingSet(4, 1, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      vm.setRecordings(initiatives[0].id, entries[0 .. 2])
      check vm.recordingButtonsOf(initiatives[0].id).buttons[0].active
      check vm.selectRecording(initiatives[0].id, "r1")
      check not vm.selectRecording(initiatives[0].id, "r1")
      check vm.recordingButtonsOf(initiatives[0].id).buttons[1].active
      # The tab's room decides how many buttons it draws: five on a wide
      # bar, only the active one on a compact bar; the rest behind `+N`.
      vm.setRecordings(initiatives[0].id, entries)
      check vm.selectRecording(initiatives[0].id, "r7")
      vm.stripWidth.val = 1440
      var wide = vm.recordingButtonsOf(initiatives[0].id)
      check wide.buttons.len == RecordingSlots
      check wide.hidden == entries.len - RecordingSlots
      check wide.buttons[^1].active and wide.buttons[^1].number == 8
      vm.stripWidth.val = 360
      let narrow = vm.recordingButtonsOf(initiatives[0].id)
      check narrow.buttons.len == 1
      check narrow.buttons[0].active and narrow.buttons[0].number == 8
      check narrow.hidden == entries.len - 1

  test "the hover popup carries the initiative's progress and sessions":
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newWorkingSetDataSource())) do (vm: InitiativeTabStripVM):
      vm.load()
      let first = vm.tabs[0]
      let popup = vm.popupOf(first.id)
      check popup.title == first.title
      check popup.headline.contains("milestone")
      var statuses = 0
      for c in popup.statusCounts: statuses += c
      check statuses > 0
      check popup.sessions.len == vm.sessionsOf(first.id).len
      check vm.popupOf("nope").title == ""

suite "the initiatives tree (sidebar and docked)":
  test "nodes carry the initiative's state and n/m, and fold":
    let (snapshot, initiatives) = syntheticWorkingSet(20, 3, Now)
    withVM(proc(): SessionTabStripVM =
        newSessionTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives), tsmSidebar)) do (vm: SessionTabStripVM):
      vm.load()
      let groups = vm.groups
      check groups[0].progressText ==
        $initiatives[0].progress.summary.completedMilestones & "/" &
        $initiatives[0].progress.summary.totalMilestones
      check not groups[0].collapsed
      vm.toggleGroup(groups[0].planId)
      check vm.groups[0].collapsed
      check vm.groups[0].tabs.len == groups[0].tabs.len   # folded, not dropped
      vm.toggleGroup(groups[0].planId)
      check not vm.groups[0].collapsed

  test "the initiative tab bar overflows, keeping the active tab drawn":
    let (snapshot, initiatives) = syntheticWorkingSet(40, 5, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      check vm.singleLine.overflow.len == 0        # unmeasured: all drawn
      vm.stripWidth.val = 760
      let line = vm.singleLine
      check line.visible.len >= 1
      check line.visible.len + line.overflow.len == vm.tabs.len
      check line.overflow.len > 0
      discard vm.activate(initiativeKey(initiatives[4].id))
      check 4 in vm.singleLine.visible
      # The bar's three widths: wide, the controls in full beside four tabs;
      # compact, the short controls beside two; stacked, the controls on a
      # line of their own and one tab with the overflow chip.
      vm.stripWidth.val = 1440
      check not vm.compact and not vm.stacked
      check vm.singleLine.visible.len == 4
      vm.stripWidth.val = 760
      check vm.compact and not vm.stacked
      check vm.singleLine.visible.len == 2
      vm.stripWidth.val = 360
      check vm.compact and vm.stacked
      check vm.singleLine.visible == @[4]   # the active tab, alone
      # The active tab is wider than the others by its recording buttons, and
      # the bar counts that room: at these widths it decides how many tabs
      # fit (without it, one more tab would be drawn than has room).
      vm.stripWidth.val = 1300
      check not vm.compact
      check vm.singleLine.visible.len == 3
      vm.stripWidth.val = 840
      check vm.compact and not vm.stacked
      check vm.singleLine.visible.len == 2

  test "a terminal sets the initiative bar's widths and thresholds in cells":
    # Every width the bar counts is a field in the renderer's unit. Left at
    # the web's pixels, a 160-column terminal would read as compact (below
    # 960) and stacked (below 480) and keep one tab where three fit.
    let (snapshot, initiatives) = syntheticWorkingSet(40, 5, Now)
    withVM(proc(): InitiativeTabStripVM =
        newInitiativeTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativeTabStripVM):
      vm.load()
      check vm.tabGap == TabGapPx
      check vm.compactBelow == InitiativeBarCompactBelowPx
      check vm.stackedBelow == InitiativeBarStackedBelowPx
      check vm.stackedControlsWidth == InitiativeBarChipPx
      vm.tabMinWidth = 24
      vm.tabGap = 1
      vm.controlsWidth = 50
      vm.compactControlsWidth = 20
      vm.stackedControlsWidth = 6
      vm.activeTabExtra = 12
      vm.compactActiveTabExtra = 4
      vm.compactBelow = 120
      vm.stackedBelow = 60
      vm.stripWidth.val = 160
      check not vm.compact and not vm.stacked
      # 50 + 12 + 4 * 24 + 3 * 1 = 161 > 160: three tabs; at 161, four.
      check vm.singleLine.visible.len == 3
      vm.stripWidth.val = 161
      check vm.singleLine.visible.len == 4
      vm.stripWidth.val = 100
      check vm.compact and not vm.stacked
      # 20 + 4 + 3 * 24 + 2 * 1 = 98 <= 100; a fourth tab needs 123.
      check vm.singleLine.visible.len == 3
      vm.stripWidth.val = 40
      check vm.compact and vm.stacked
      # Only the chip and "+" stay beside the tabs: 6 + 4 + 24 = 34.
      check vm.singleLine.visible.len == 1
      vm.stripWidth.val = 59
      check vm.singleLine.visible.len == 2   # 6 + 4 + 2 * 24 + 1 = 59
      # The active tab's recording buttons follow the threshold in cells too:
      # five on the 160-cell bar, which the web's 960px would call compact.
      var entries: seq[RecordingEntry]
      for i in 0 ..< 8:
        entries.add RecordingEntry(id: "r" & $i, name: "trace " & $i)
      vm.setRecordings(initiatives[0].id, entries)
      vm.stripWidth.val = 160
      check vm.recordingButtonsOf(initiatives[0].id).buttons.len == RecordingSlots
      vm.stripWidth.val = 100
      check vm.recordingButtonsOf(initiatives[0].id).buttons.len == RecordingSlotsCompact

  test "a list in attention order puts the most urgent initiative first":
    let (snapshot, initiatives) = syntheticWorkingSet(20, 3, Now)
    var policy = tabStripSessionPolicy()
    policy.order = soAttention
    withVM(proc(): SessionTabStripVM =
        newSessionTabStripVM(newSnapshotDataSource(snapshot, "x", initiatives),
                             tsmSidebar, policy)) do (vm: SessionTabStripVM):
      vm.load()
      let groups = vm.groups
      check groups[^1].planId == ""            # no initiative stays last
      proc best(g: SessionTabGroup): int =
        result = high(int)
        for a in SessionAttention:
          if g.counts[a] > 0: return ord(a)
      for i in 1 ..< groups.len - 1:
        check best(groups[i - 1]) <= best(groups[i])
      # Within a group, attention order too.
      for g in groups:
        for i in 1 ..< g.tabs.len:
          check ord(g.tabs[i - 1].attention) <= ord(g.tabs[i].attention)

suite "the initiatives tree":
  test "a node folds and expands, and only says so":
    let (snapshot, initiatives) = syntheticWorkingSet(40, 3, Now)
    withVM(proc(): InitiativesVM =
        newInitiativesVM(newSnapshotDataSource(snapshot, "x", initiatives))) do (vm: InitiativesVM):
      vm.load()
      let id = vm.rows[0].id
      check not vm.rows[0].folded and not vm.rows[0].expanded
      vm.toggleFolded(id)
      check vm.rows[0].folded
      check vm.rows[0].sessions.len > 0        # folded, not dropped
      vm.toggleFolded(id)
      vm.toggleExpanded(id)
      check vm.rows[0].expanded
      vm.toggleExpanded(id)
      check not vm.rows[0].expanded

# ---------------------------------------------------------------------------
# Progress events through the seam
# ---------------------------------------------------------------------------

type
  InitiativesOnlySource = ref object of AgentHarborDataSource
    ## Lists plans; has no progress event stream (the base method answers).
    initiatives: seq[Initiative]

  LeakySource = ref object of SnapshotDataSource
    ## A snapshot source that also keeps every raw callback it was given.
    rawCallbacks: seq[ProgressCallback]

  AnswerThenSendSource = ref object of SnapshotDataSource
    ## A snapshot source that, once it has answered the plans, at once sends
    ## the events queued in `afterAnswer` (each once).
    afterAnswer: seq[ProgressEvent]

method loadFleet(source: InitiativesOnlySource; done: FleetCallback) =
  done(success(FleetSnapshot(capturedAtMs: Now)))

method loadInitiatives(source: InitiativesOnlySource; done: InitiativesCallback) =
  done(success(source.initiatives))

method subscribeProgress(source: LeakySource;
                         callback: ProgressCallback): ProgressSubscription =
  source.rawCallbacks.add callback
  procCall subscribeProgress(SnapshotDataSource(source), callback)

method loadInitiatives(source: AnswerThenSendSource; done: InitiativesCallback) =
  done(success(source.initiatives))
  let queued = source.afterAnswer
  source.afterAnswer = @[]
  for queuedEvent in queued:
    discard source.sendProgress(queuedEvent)

const Dot = " \xC2\xB7 "

proc milestone(id, title, status: string): MilestoneDetail =
  MilestoneDetail(id: id, title: title, status: status)

proc handPlans(): seq[Initiative] =
  ## Two invented plans with their summaries written out by hand.
  @[Initiative(id: "plan-a", title: "Plan A", repository: "example/a",
               progress: MilestoneFileProgress(
                 path: "a.milestones.org", title: "Plan A", currentMilestone: "A2",
                 milestones: @[milestone("A1", "First", "completed"),
                               milestone("A2", "Second", "in_progress"),
                               milestone("A3", "Third", "planned"),
                               milestone("A4", "Fourth", "planned")],
                 summary: MilestoneSummary(totalMilestones: 4, completedMilestones: 1,
                                           progressPercent: 25,
                                           currentMilestoneTitle: "Second"))),
    Initiative(id: "plan-b", title: "Plan B", repository: "example/b",
               progress: MilestoneFileProgress(
                 path: "b.milestones.org", title: "Plan B", currentMilestone: "B1",
                 milestones: @[milestone("B1", "Bee one", "in_progress"),
                               milestone("B2", "Bee two", "planned")],
                 summary: MilestoneSummary(totalMilestones: 2, completedMilestones: 0,
                                           progressPercent: 0,
                                           currentMilestoneTitle: "Bee one")))]

type
  Moment = object
    ## What both viewmodels show at one moment, written out by hand.
    aHeadline: string          ## the Progress panel on plan-a
    aGroups: seq[string]
    aCurrent: string
    aRow, bRow: string         ## the Initiatives rows' n/m · %
    aRowCurrent, bRowCurrent: string
    bBlocked: int

const
  # Before any event: plan-a 1 of 4 done (25 %), A2 current; plan-b 0 of 2.
  AtLoad = Moment(aHeadline: "1 of 4 milestones" & Dot & "25%",
                  aGroups: @["In progress (1)", "Planned (2)", "Completed (1)"],
                  aCurrent: "A2", aRow: "1/4" & Dot & "25%", bRow: "0/2" & Dot & "0%",
                  aRowCurrent: "A2: Second", bRowCurrent: "B1: Bee one", bBlocked: 0)
  # A2 completed: 2 of 4 (50 %), "current" passes to A3, nothing in progress.
  AfterA2 = Moment(aHeadline: "2 of 4 milestones" & Dot & "50%",
                   aGroups: @["Planned (2)", "Completed (2)"],
                   aCurrent: "A3", aRow: "2/4" & Dot & "50%", bRow: "0/2" & Dot & "0%",
                   aRowCurrent: "A3: Third", bRowCurrent: "B1: Bee one", bBlocked: 0)
  # A3 started: still 2 of 4.
  AfterA3 = Moment(aHeadline: "2 of 4 milestones" & Dot & "50%",
                   aGroups: @["In progress (1)", "Planned (1)", "Completed (2)"],
                   aCurrent: "A3", aRow: "2/4" & Dot & "50%", bRow: "0/2" & Dot & "0%",
                   aRowCurrent: "A3: Third", bRowCurrent: "B1: Bee one", bBlocked: 0)
  # B1 blocked: plan-b still 0 of 2, B1 stays current, one blocked.
  AfterB1 = Moment(aHeadline: "2 of 4 milestones" & Dot & "50%",
                   aGroups: @["In progress (1)", "Planned (1)", "Completed (2)"],
                   aCurrent: "A3", aRow: "2/4" & Dot & "50%", bRow: "0/2" & Dot & "0%",
                   aRowCurrent: "A3: Third", bRowCurrent: "B1: Bee one", bBlocked: 1)

proc rowOf(vm: InitiativesVM; id: string): InitiativeRow =
  for row in vm.rows:
    if row.id == id: return row

proc currentLine(vm: InitiativeProgressVM): string =
  for g in vm.groups:
    for m in g.milestones:
      if m.current: return m.id

proc groupTitles(vm: InitiativeProgressVM): seq[string] =
  for g in vm.groups: result.add g.title

proc checkMoment(list: InitiativesVM; panel: InitiativeProgressVM;
                 expected: Moment; label: string) =
  checkpoint label
  check panel.headline == expected.aHeadline
  check panel.groupTitles == expected.aGroups
  check panel.currentLine == expected.aCurrent
  let a = list.rowOf("plan-a")
  let b = list.rowOf("plan-b")
  check a.progressText == expected.aRow
  check b.progressText == expected.bRow
  check a.currentMilestone == expected.aRowCurrent
  check b.currentMilestone == expected.bRowCurrent
  check b.statusCounts[mscBlocked] == expected.bBlocked

proc event(initiative, milestone, status: string): ProgressEvent =
  ProgressEvent(initiativeId: initiative, milestoneId: milestone, status: status)

suite "progress events through the data-source seam":
  test "test_ctf_p1c_progress_subscription_moves_the_viewmodels":
    createRoot proc(disposeRoot: proc()) =
      # -- A sending source moves both viewmodels, with no host call. -------
      let source = newSnapshotDataSource(FleetSnapshot(capturedAtMs: Now),
                                         "hand plans", handPlans())
      let list = newInitiativesVM(source)
      let panel = newInitiativeProgressVM(source, "plan-a")
      check list.progressState.val == asIdle
      list.load()
      panel.load()
      check list.state.val == asReady and panel.state.val == asReady
      check list.progressState.val == asReady and panel.progressState.val == asReady
      check source.progressSubscribers.activeCount == 2
      var listRuns, panelRuns = 0
      createEffect proc() =
        discard list.rows
        inc listRuns
      createEffect proc() =
        discard panel.groups
        inc panelRuns
      checkMoment(list, panel, AtLoad, "at load")
      check source.sendProgress(event("plan-a", "A2", "completed")) ==
        @[pdApplied, pdApplied]
      checkMoment(list, panel, AfterA2, "after A2 completed")
      check source.sendProgress(event("plan-a", "A3", "in_progress")) ==
        @[pdApplied, pdApplied]
      checkMoment(list, panel, AfterA3, "after A3 started")
      check source.sendProgress(event("plan-b", "B1", "blocked")) ==
        @[pdApplied, pdApplied]
      checkMoment(list, panel, AfterB1, "after B1 blocked")
      # Each event moved each viewmodel once; ones that change nothing (a
      # repeated status, an unknown initiative or milestone) move nothing.
      check listRuns == 1 + 3 and panelRuns == 1 + 3
      check source.sendProgress(event("plan-b", "B1", "blocked")) ==
        @[pdUnchanged, pdUnchanged]
      check source.sendProgress(event("plan-z", "Z1", "completed")) ==
        @[pdUnchanged, pdUnchanged]
      check source.sendProgress(event("plan-a", "A9", "completed")) ==
        @[pdUnchanged, pdUnchanged]
      check listRuns == 4 and panelRuns == 4
      checkMoment(list, panel, AfterB1, "after events that change nothing")
      check list.lateProgressEvents == 0 and panel.lateProgressEvents == 0

      # -- Several subscribers: a second panel, and reloads, which replace
      #    their own subscription rather than add one. ---------------------
      let panel2 = newInitiativeProgressVM(source, "plan-b")
      panel2.load()
      list.load()
      panel.load()
      check source.progressSubscribers.activeCount == 3
      # The source's own list followed the events, so the reloads read
      # the state after them.
      checkMoment(list, panel, AfterB1, "after the reloads")
      check panel2.headline == "0 of 2 milestones" & Dot & "0%"
      check source.sendProgress(event("plan-b", "B2", "completed")) ==
        @[pdApplied, pdApplied, pdApplied]
      # plan-b: B2 done, 1 of 2 (50 %); B1 (blocked) stays current.
      check panel2.headline == "1 of 2 milestones" & Dot & "50%"
      check panel2.groupTitles == @["Blocked (1)", "Completed (1)"]
      check panel2.currentLine == "B1"
      check list.rowOf("plan-b").progressText == "1/2" & Dot & "50%"
      check panel.headline == AfterB1.aHeadline   # plan-a is untouched

      # -- Disposal unsubscribes; a late event moves nothing. ---------------
      panel.dispose()
      check source.progressSubscribers.activeCount == 2
      check source.sendProgress(event("plan-a", "A3", "completed")) ==
        @[pdApplied, pdApplied]                  # list and panel2 only
      check panel.headline == AfterB1.aHeadline   # the disposed one did not move
      check panel.currentLine == "A3"
      # plan-a in the list: A3 done, 3 of 4 (75 %), A4 current.
      check list.rowOf("plan-a").progressText == "3/4" & Dot & "75%"
      check list.rowOf("plan-a").currentMilestone == "A4: Fourth"
      check panel.lateProgressEvents == 0
      list.dispose()
      panel2.dispose()
      check source.progressSubscribers.activeCount == 0
      check source.sendProgress(event("plan-a", "A4", "completed")).len == 0
      check list.rowOf("plan-a").progressText == "3/4" & Dot & "75%"
      disposeRoot()

    # -- A source that does not provide progress events says so. -----------
    createRoot proc(disposeRoot: proc()) =
      let bare = InitiativesOnlySource(label: "plans only", initiatives: handPlans())
      let list = newInitiativesVM(bare)
      let panel = newInitiativeProgressVM(bare, "plan-a")
      list.load()
      panel.load()
      # The panels still show their plans; the feed reports the gap.
      check list.state.val == asReady and panel.state.val == asReady
      for vm in [list.progressState, panel.progressState]:
        check vm.val == asError
      check list.progressError.val ==
        "the data source 'plans only' does not provide progress events"
      check panel.progressError.val == list.progressError.val
      checkMoment(list, panel, AtLoad, "over a source without progress events")
      # A failing source reports its own error on the feed as well.
      let failing = newFailingDataSource("connection refused")
      let failed = newInitiativeProgressVM(failing)
      failed.load()
      check failed.state.val == asError
      check failed.progressState.val == asError
      check failed.progressError.val == "connection refused"
      list.dispose()
      panel.dispose()
      failed.dispose()
      disposeRoot()

    # -- A source that never sends leaves the viewmodels as loaded. --------
    createRoot proc(disposeRoot: proc()) =
      let quiet = newSnapshotDataSource(FleetSnapshot(capturedAtMs: Now),
                                        "quiet", handPlans())
      let list = newInitiativesVM(quiet)
      let panel = newInitiativeProgressVM(quiet, "plan-a")
      list.load()
      panel.load()
      let listRevision = list.revision.val
      let panelRevision = panel.revision.val
      check list.progressState.val == asReady and panel.progressState.val == asReady
      check quiet.progressSubscribers.activeCount == 2
      checkMoment(list, panel, AtLoad, "over a source that never sends")
      check list.revision.val == listRevision and panel.revision.val == panelRevision
      # A pending source (the server never answers) holds the subscription
      # open and sends nothing; nothing loads, nothing moves.
      let pending = newPendingDataSource()
      let waiting = newInitiativeProgressVM(pending, "plan-a")
      waiting.load()
      check waiting.state.val == asLoading
      check waiting.progressState.val == asReady
      check pending.progressSubscribers.activeCount == 1
      check waiting.revision.val == 0
      check waiting.groups.len == 0
      # The fixture source's stream is open and quiet too.
      let fixturePanel = newInitiativeProgressVM(newFixtureDataSource())
      fixturePanel.load()
      let fixtureRevision = fixturePanel.revision.val
      check fixturePanel.progressState.val == asReady
      check fixturePanel.revision.val == fixtureRevision
      list.dispose()
      panel.dispose()
      waiting.dispose()
      fixturePanel.dispose()
      check quiet.progressSubscribers.activeCount == 0
      check pending.progressSubscribers.activeCount == 0
      disposeRoot()

    # -- The viewmodels subscribe before they load: an event sent right
    #    after the plans' answer is not lost between the two. -------------
    createRoot proc(disposeRoot: proc()) =
      let racing = AnswerThenSendSource(label: "answers, then sends",
                                        initiatives: handPlans(),
                                        snapshot: FleetSnapshot(capturedAtMs: Now),
                                        afterAnswer: @[event("plan-a", "A2", "completed")])
      let list = newInitiativesVM(racing)
      list.load()
      check racing.afterAnswer.len == 0
      check list.rowOf("plan-a").progressText == AfterA2.aRow
      check list.rowOf("plan-a").currentMilestone == AfterA2.aRowCurrent
      racing.afterAnswer = @[event("plan-a", "A3", "in_progress")]
      let panel = newInitiativeProgressVM(racing, "plan-a")
      panel.load()
      check panel.headline == AfterA3.aHeadline
      check panel.groupTitles == AfterA3.aGroups
      check panel.currentLine == AfterA3.aCurrent
      check list.rowOf("plan-a").currentMilestone == AfterA3.aRowCurrent
      list.dispose()
      panel.dispose()
      check racing.progressSubscribers.activeCount == 0
      disposeRoot()

    # -- A source that ignores the cancellation cannot move a disposed one.
    createRoot proc(disposeRoot: proc()) =
      let leaky = LeakySource(label: "leaky", initiatives: handPlans(),
                              snapshot: FleetSnapshot(capturedAtMs: Now))
      let list = newInitiativesVM(leaky)
      let panel = newInitiativeProgressVM(leaky, "plan-a")
      list.load()
      panel.load()
      check leaky.rawCallbacks.len == 2
      list.dispose()
      panel.dispose()
      let late = success(event("plan-a", "A2", "completed"))
      check leaky.rawCallbacks[0](late) == pdRefused
      check leaky.rawCallbacks[1](late) == pdRefused
      check list.lateProgressEvents == 1 and panel.lateProgressEvents == 1
      checkMoment(list, panel, AtLoad, "after events delivered past disposal")
      # A reload replaces the subscription: the old callback is refused too.
      let live = newInitiativeProgressVM(leaky, "plan-a")
      live.load()
      live.load()
      check leaky.rawCallbacks.len == 4
      check leaky.rawCallbacks[2](late) == pdRefused
      check live.lateProgressEvents == 1
      check live.headline == AtLoad.aHeadline
      check leaky.rawCallbacks[3](late) == pdApplied
      check live.headline == AfterA2.aHeadline
      live.dispose()
      disposeRoot()

  test "a subscription handle delivers until it is cancelled or its stream fails":
    var calls: seq[DataResult[ProgressEvent]]
    let callback = proc(answer: DataResult[ProgressEvent]): ProgressDelivery =
      calls.add answer
      pdUnchanged
    var subscribers: ProgressSubscribers
    let first = subscribers.subscribe(callback)
    let second = subscribers.subscribe(callback)
    check first.active and second.active
    check subscribers.broadcast(success(event("p", "m", "done"))) ==
      @[pdUnchanged, pdUnchanged]
    check calls.len == 2
    first.cancel()
    first.cancel()                                  # idempotent
    check not first.active
    check subscribers.activeCount == 1
    check subscribers.broadcast(success(event("p", "m", "done"))) == @[pdUnchanged]
    check calls.len == 3
    # Delivering through a cancelled handle calls nothing and is counted.
    check first.deliver(success(event("p", "m", "done"))) == pdRefused
    check first.refused == 1
    check calls.len == 3
    # An error answer is delivered once and ends the stream.
    check subscribers.broadcast(failure[ProgressEvent]("stream closed")) == @[pdUnchanged]
    check calls.len == 4 and not calls[3].ok and calls[3].error == "stream closed"
    check not second.active
    check subscribers.activeCount == 0
    check subscribers.broadcast(success(event("p", "m", "done"))).len == 0
    # The base method answers "does not provide" once, with an ended handle.
    let ended = AgentHarborDataSource(label: "bare").subscribeProgress(callback)
    check not ended.active
    check calls.len == 5
    check calls[4].error == "the data source 'bare' does not provide progress events"
