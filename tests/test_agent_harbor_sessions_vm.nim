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

  test "sessions started elsewhere wait behind [N agent harbor sessions] until opened":
    let (snapshot, _) = syntheticWorkingSet(12, 0, Now)   # no initiatives at all
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newSnapshotDataSource(snapshot))) do (vm: InitiativeTabStripVM):
      vm.load()
      var own, others = 0
      for s in snapshot.sessions:
        if s.originFrontEnd == OwnFrontEnd: inc own else: inc others
      check vm.tabs.len == own
      check vm.elsewhere.len == others
      check vm.elsewhereLabel == "[" & $others & " agent harbor sessions]"
      let chosen = vm.elsewhere[0].item.id
      check vm.openSession(chosen)
      check vm.elsewhere.len == others - 1
      check vm.activeTab.val == sessionKey(chosen)
    withVM(proc(): InitiativeTabStripVM = newInitiativeTabStripVM(newSnapshotDataSource(FleetSnapshot()))) do (vm: InitiativeTabStripVM):
      vm.load()
      check vm.elsewhereLabel == ""

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
