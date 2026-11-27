## An inbox item's page (`InboxItemVM`) and the shared action tracker
## (`ActionTracker`): what each kind of page shows, the answer form's
## validation, the answer states, the viewing heartbeat, the sudo password,
## and that every press reaches the scripted action seam and nothing else.
##
## Test doubles, and why each is justified:
##
## - `ScriptedActionSource` is the prototypes' production source for writes:
##   the prototypes may not write to an Agent Harbor server, so every press
##   goes to this scripted seam, which answers from its script and records
##   what it received. Its record is what these tests read.
## - `SeamOnly` is an `AgentHarborDataSource` that serves one item's page and
##   leaves `submitAction` to the base: the case the base's "does not
##   provide" answer exists for (a source with no way to send an action must
##   never show one as sent).
## - IsoNim's `TestClock` drives the heartbeat; nothing reads wall time.
##
## Expected texts and records are written out by hand from the invented
## pages (`synthetic_inbox.nim`).

import std/[os, staticos, strutils, unittest]
import isonim/core/[owner, signals, clock]
import nim_agents_isonim_viewmodels

type SeamOnly = ref object of AgentHarborDataSource
  detail: InboxItemDetail

method loadInboxItemDetail(source: SeamOnly; item: InboxItemRef;
                           done: ItemDetailCallback) =
  done(success(source.detail))

proc pageOf(name: string; clock: ClockBase = nil;
            tracker: ActionTracker = nil): (ScriptedActionSource, InboxItemVM) =
  let f = itemFixture(name)
  let vm = newInboxItemVM(f.source, f.item, f.sessionId, tracker, clock)
  vm.load()
  (f.source, vm)

suite "what each page shows":
  test "questions, an ended turn, a permission gate, approvals, a login, feedback":
    createRoot proc(disposeRoot: proc()) =
      let (_, question) = pageOf("question")
      check question.state.val == asReady
      check question.banner == "Agent has stopped and is waiting for your answer"
      check question.detail.prompt.startsWith("The old cache and the new one disagree")
      let (_, single) = pageOf("question-single")
      check single.banner == "Agent is waiting for an answer"
      check single.detail.options.len == 2
      check single.optionsNotice == ""
      let (_, none) = pageOf("question-no-options")
      check none.optionsNotice == NoOptionsText
      let (_, ended) = pageOf("ended-turn")
      check ended.banner == ""
      check ended.detail.lastReply.startsWith("Done.")
      let (_, permission) = pageOf("permission")
      var labels: seq[string]
      for o in permission.detail.permissionOptions: labels.add o.label
      check labels == @["Allow once", "Allow always", "Reject once", "Reject always"]
      let (_, sudo) = pageOf("sudo")
      check sudo.approvalLines == @[
        "systemctl restart relay in order to: load the new queue limit",
        "chown relay /var/lib/relay in order to: let the relay write its shed log"]
      let (_, network) = pageOf("network")
      check network.approvalLines ==
        @["packages.example.org in order to: download the pinned benchmark tool"]
      # The same approvals split for the page: the subject (a command, a
      # domain) on a line of its own, the purpose as the agent gave it.
      check sudo.detail.approvals[0].approvalSubject == "systemctl restart relay"
      check sudo.detail.approvals[0].approvalPurpose == "load the new queue limit"
      check sudo.detail.approvals[1].approvalSubject == "chown relay /var/lib/relay"
      check network.detail.approvals[0].approvalSubject == "packages.example.org"
      check network.detail.approvals[0].approvalPurpose == "download the pinned benchmark tool"
      let (_, login) = pageOf("login")
      check login.loginText == LocalSignInText
      let (_, feedback) = pageOf("feedback")
      check feedback.detail.feedback.attachments[0].name == "draft-notes.md"
      check not feedback.detail.draft.present
      let (_, draft) = pageOf("draft")
      check draft.detail.draft.drafter == "release-manager"
      let (_, unfamiliar) = pageOf("unfamiliar")
      check unfamiliar.leadsWithSummary
      check not question.leadsWithSummary
      for vm in [question, single, none, ended, permission, sudo, network, login,
                 feedback, draft, unfamiliar]:
        vm.dispose()
      disposeRoot()

  test "an item the source does not hold cannot be loaded; a failing source shows its error":
    createRoot proc(disposeRoot: proc()) =
      let f = itemFixture("question")
      let missing = newInboxItemVM(f.source, InboxItemRef(id: "no-such-item"), "")
      missing.load()
      check missing.state.val == asError
      check missing.notice == "no item no-such-item in invented inbox item: question"
      let failing = newInboxItemVM(newFailingDataSource("the hub is restarting"),
                                   f.item, f.sessionId)
      failing.load()
      check failing.error.val == "the hub is restarting"
      check failing.notice == ""
      let pending = newInboxItemVM(newPendingDataSource(), f.item, f.sessionId)
      pending.load()
      check pending.notice == ItemLoadingNotice
      check not pending.submit()
      missing.dispose()
      failing.dispose()
      pending.dispose()
      disposeRoot()

  test "test_inbox_item_vm_login_states: pending, a carry error, cancelling, completed, failed, no request":
    createRoot proc(disposeRoot: proc()) =
      let (_, pending) = pageOf("login")
      check pending.hasLoginRequest
      check pending.loginState == lsPending
      check pending.loginText == LocalSignInText
      check pending.loginError == ""
      check pending.canCancelLogin
      check not pending.canContinueLogin
      # A carry error: the sign-in finished but the agent could not take it
      # up; the request stays pending, Cancel stays offered.
      let (_, carry) = pageOf("login-carry-error-pending")
      check carry.loginState == lsPending
      check carry.loginText == LocalSignInText
      check carry.loginError == LoginCarryErrorText
      check carry.canCancelLogin
      check not carry.canContinueLogin
      # The server's own states.
      let (cancellingSource, cancelling) = pageOf("login-cancelling")
      check cancelling.loginState == lsCancelling
      check cancelling.loginText == CancellingSignInText
      check not cancelling.canCancelLogin
      check not cancelling.canContinueLogin
      check not cancelling.cancelLogin()
      check cancellingSource.record.len == 0
      let (_, completed) = pageOf("login-completed")
      check completed.loginState == lsCompleted
      check completed.loginText ==
        "Signed in to Example Cloud \xE2\x80\x94 login complete"
      check completed.loginError == ""
      check not completed.canCancelLogin
      check completed.canContinueLogin           # moving on is the only press
      let (_, failed) = pageOf("login-failed")
      check failed.loginState == lsFailed
      check failed.loginText == SignInFailedText
      check failed.loginError == LoginFailedText
      check not failed.canCancelLogin
      check not failed.canContinueLogin
      # A login item that holds no request.
      let (emptySource, empty) = pageOf("login-none")
      check not empty.hasLoginRequest
      check empty.loginText == NoLoginRequestText
      check empty.loginError == ""
      check not empty.canCancelLogin
      check not empty.canContinueLogin
      check not empty.cancelLogin()
      check emptySource.record.len == 0
      # Another kind of page has no login line.
      let (_, question) = pageOf("question")
      check question.loginText == ""
      for vm in [pending, carry, cancelling, completed, failed, empty, question]:
        vm.dispose()
      disposeRoot()

  test "Cancel on a login request: cancelling while in flight, then no request, or refused and offered again":
    createRoot proc(disposeRoot: proc()) =
      let (source, login) = pageOf("login")
      source.script.setRule(oaCancelLogin, neverAnswered())
      check login.cancelLogin()
      check login.loginState == lsCancelling
      check login.loginText == CancellingSignInText
      check login.phaseText == ""                # the login line says it
      check not login.canCancelLogin
      check not login.cancelLogin()              # one in flight: nothing more sent
      check source.record.len == 1
      login.dispose()
      # Confirmed: the request is withdrawn and the page says there is none.
      let (confirmedSource, withdrawn) = pageOf("login")
      check withdrawn.cancelLogin()
      check not withdrawn.hasLoginRequest
      check withdrawn.loginText == NoLoginRequestText
      check withdrawn.phaseText == ""
      check not withdrawn.cancelLogin()
      check confirmedSource.record.len == 1
      withdrawn.dispose()
      # Refused: the request stays pending, the reason is shown, and Cancel
      # is offered again.
      let (refusedSource, refused) = pageOf("login")
      refusedSource.script.setRule(oaCancelLogin, failedWith("the sign-in window is busy"))
      check refused.cancelLogin()
      check refused.loginState == lsPending
      check refused.phaseText == CancelFailedText & ": the sign-in window is busy"
      check refused.canCancelLogin
      check refused.cancelLogin()
      check refusedSource.record.len == 2
      refused.dispose()
      disposeRoot()

suite "the answer form":
  test "validation: an empty answer, no option chosen, a confirmation undecided; nothing is sent":
    createRoot proc(disposeRoot: proc()) =
      let (source, question) = pageOf("question")
      check not question.submit()
      check question.validation.val == EmptyResponseText
      let (_, multi) = pageOf("question-multi")
      check not multi.submit()
      check multi.validation.val == SelectOptionText
      let (_, confirmation) = pageOf("question-confirmation")
      check not confirmation.submit()
      check confirmation.validation.val == DecideText
      let (_, feedback) = pageOf("feedback")
      feedback.setText("short")
      check not feedback.submit()
      check feedback.validation.val == "Response must be at least 10 characters"
      check source.record.len == 0
      check question.phase == ppIdle
      question.dispose()
      multi.dispose()
      confirmation.dispose()
      feedback.dispose()
      disposeRoot()

  test "an expired feedback request shows the badge, and a submission to it is refused with the message":
    createRoot proc(disposeRoot: proc()) =
      let clock = newTestClock(float64(InboxT0))
      let (source, expired) = pageOf("feedback-expired", clock)
      check expired.isExpired(InboxT0)
      check expired.expiredBadge(InboxT0) == ExpiredBadge
      expired.setText("No, leave it out of the notes.")
      check not expired.submit()
      check expired.validation.val == ExpiredText
      check source.record.len == 0
      let (_, live) = pageOf("feedback", clock)
      check live.expiredBadge(InboxT0) == ""
      check live.expiredBadge(InboxT0 + 3_600_000) == ExpiredBadge
      expired.dispose()
      live.dispose()
      disposeRoot()

  test "an answer goes to the scripted seam once, with what the form holds":
    createRoot proc(disposeRoot: proc()) =
      let (source, multi) = pageOf("question-multi")
      multi.toggleChoice("eu-west")
      multi.toggleChoice("ap-south")
      multi.toggleChoice("eu-west")
      check multi.choices.val == @["ap-south"]
      check multi.submit()
      check multi.phase == ppAnswered
      check multi.phaseText == AnswerSentText
      let (_, single) = pageOf("question-single")
      single.toggleChoice("sqlite")
      single.toggleChoice("rocks")
      check single.choices.val == @["rocks"]
      let (endedSource, ended) = pageOf("ended-turn")
      ended.setText("Now add a test for the logger.")
      check ended.submit()
      check source.record == @["answer-question session=" & sessionIdOf(1) &
        " item=inbox-item-question-multi request=q-14 choices=ap-south"]
      # An ended turn is answered with the next instruction.
      check endedSource.record == @["send-instruction session=" & sessionIdOf(2) &
        " item=inbox-item-ended-turn text=\"Now add a test for the logger.\""]
      check ended.tracker.entryOf("item::" & EndedTurnItem).action.kind == oaSendInstruction
      multi.dispose()
      single.dispose()
      ended.dispose()
      disposeRoot()

  test "submitting, then answered or failed, as the source answers":
    createRoot proc(disposeRoot: proc()) =
      let (source, question) = pageOf("question")
      source.script.setRule(oaAnswerQuestion, neverAnswered())
      question.setText("Keep the old order behind a flag.")
      check question.submit()
      check question.phase == ppSubmitting
      check question.phaseText == SubmittingText
      # One action in flight per item: a second press sends nothing.
      check not question.submit()
      check source.record.len == 1
      source.script.settle(0, ok = false, reason = "the session ended")
      check question.phase == ppFailed
      check question.phaseText == AnswerFailedText & ": the session ended"
      source.script.setRule(oaAnswerQuestion, confirmed())
      check question.submit()
      check question.phase == ppAnswered
      check source.record.len == 2
      question.dispose()
      disposeRoot()

  test "the page's buttons: a permission option, a draft, a login cancelled, a priority":
    createRoot proc(disposeRoot: proc()) =
      let (source, permission) = pageOf("permission")
      check not permission.choosePermission("allow_forever")
      check permission.validation.val == "Unknown option: allow_forever"
      check permission.choosePermission("reject_once")
      let (draftSource, draft) = pageOf("draft")
      check draft.sendDraft()
      let (loginSource, login) = pageOf("login")
      check login.cancelLogin()
      check login.setPriority(ipUrgent)
      check source.record == @[
        "decide-permission session=" & sessionIdOf(3) &
          " item=inbox-item-permission request=perm-31 decision=reject_once"]
      # The draft on a feedback request is that request's response, named by
      # the feedback's own id (a session-level request id would leave the
      # route without one).
      check draftSource.record.len == 1
      check draftSource.record[0].startsWith("respond-feedback session=" & sessionIdOf(4) &
        " task=")
      check " item=inbox-item-feedback request=" & draft.detail.feedback.id & " " in
        draftSource.record[0]
      check draft.detail.feedback.id.len > 0
      check draftSource.record[0].endsWith(
        " text=\"The route cache, the schema migration and the logging clean-up.\"")
      check loginSource.record == @[
        "cancel-login session=" & sessionIdOf(5) & " item=inbox-item-login request=login-51",
        "set-priority session=" & sessionIdOf(5) & " priority=urgent"]
      permission.dispose()
      draft.dispose()
      login.dispose()
      disposeRoot()

suite "secrets":
  test "a sudo password reaches the seam once and is never recorded, published or kept":
    createRoot proc(disposeRoot: proc()) =
      let (source, sudo) = pageOf("sudo")
      sudo.setPassword("correct horse")
      check sudo.passwordSet.val
      check sudo.decideApproval("sudo-71", adApprove)
      check source.record == @["decide-approval session=" & sessionIdOf(7) &
        " item=inbox-item-sudo request=sudo-71 decision=approve scope=sudo secret supplied"]
      check "correct horse" notin source.describeRecord
      check not sudo.passwordSet.val
      # The tracker keeps the action without it.
      check not sudo.tracker.entryOf("item::inbox-item-sudo").action.password.isSet
      # A denial carries no password; the second approval is still queued.
      check sudo.decideApproval("sudo-72", adDeny)
      check "secret" notin source.record[1]
      check not sudo.decideApproval("sudo-99", adApprove)
      sudo.dispose()
      disposeRoot()

suite "no write reaches anything but the seam":
  test "a source without actions answers that it does not provide them, and the page shows the press failed":
    createRoot proc(disposeRoot: proc()) =
      let f = itemFixture("question")
      var detail: InboxItemDetail
      for d in f.source.details:
        if d.itemId == f.item.id: detail = d
      let source = SeamOnly(label: "no actions", detail: detail)
      let vm = newInboxItemVM(source, f.item, f.sessionId)
      vm.load()
      vm.setText("Keep it.")
      check vm.submit()
      check vm.phase == ppFailed
      check vm.phaseText == AnswerFailedText &
        ": the data source 'no actions' does not provide operator actions"
      vm.dispose()
      disposeRoot()

  test "the prototypes' viewmodel and source modules import no transport":
    # The import statements of every module under `agent_harbor/` (listed
    # from the directory at compile time, so a new module is scanned
    # without being named here), each statement joined across its lines.
    # Positive controls first: the scan sees a transport in each form an
    # import can take.
    const Transports = ["httpclient", "asynchttpserver", "asyncnet", "net", "nativesockets",
                        "nim_agent_harbor", "websocket", "websockets", "ws", "jsfetch",
                        "puppy", "curly"]
    proc transportImports(text: string): seq[string] =
      var statement = ""
      var depth = 0
      for line in text.splitLines:
        let t = line.strip
        if statement.len == 0:
          if not (t.startsWith("import ") or t.startsWith("from ") or
                  t.startsWith("include ")):
            continue
        statement.add " " & t
        depth += t.count('[') - t.count(']')
        if depth > 0 or t.endsWith(","): continue
        var words: seq[string]
        for w in statement.split({' ', ',', '/', '[', ']', '.', '"'}):
          if w.len > 0: words.add w
        for word in Transports:
          if word in words:
            result.add statement.strip
            break
        statement = ""
        depth = 0
    check transportImports("import std/[json, strutils]\nimport std/httpclient\n") ==
      @["import std/httpclient"]
    check transportImports("import std/[json,\n  net, strutils]\n").len == 1
    check transportImports("import nim_agents/agent_harbor/[inbox,\n  fleet_fold]\n" &
                           "from nim_agent_harbor/client import get\n").len == 1
    check transportImports("## nothing here imports a network client\nimport std/json\n").len == 0
    const dir = currentSourcePath().parentDir.parentDir /
      "src/nim_agents_isonim_viewmodels/agent_harbor"
    const modules = block:
      var found: seq[(string, string)]
      for (kind, path) in staticWalkDir(dir):
        if kind == staticos.pcFile and path.endsWith(".nim"):
          found.add (path.extractFilename, staticRead(path))
      found
    var names: seq[string]
    for (name, _) in modules: names.add name
    checkpoint $names
    # The modules a P3 view or story loads its writes through are among them.
    for required in ["action_tracker.nim", "scripted_actions.nim", "changes_vm.nim",
                     "inbox_vm.nim", "inbox_item_vm.nim", "inbox_playback.nim",
                     "playback_source.nim", "synthetic_changes.nim",
                     "synthetic_inbox.nim", "data_source.nim", "fixture_source.nim"]:
      check required in names
    check modules.len >= 28
    # The live data sources are the deliberate transport users: the network
    # side of the seam every other module here reads through. `live_source.nim`
    # (CTF-M3) is native only; `node_follower.nim` (D92, a desktop app's main
    # process) is JavaScript on Node only. Each is exempt by name, and checked
    # to be what the exemption says (it imports a transport and refuses the
    # other backend), so the exemption cannot hide a new transport user or
    # outlive the module it names. The window's half, `host_fed_source.nim`,
    # is not exempt: it imports no transport.
    const TransportUsers = [("live_source.nim", "when defined(js):"),
                            ("node_follower.nim", "when not defined(js):")]
    for (user, _) in TransportUsers:
      check user in names
    for (name, text) in modules:
      checkpoint name
      check text.len > 0
      var refusal = ""
      for (user, guard) in TransportUsers:
        if user == name: refusal = guard
      if refusal.len > 0:
        check transportImports(text).len > 0
        check refusal in text and "{.error:" in text
      else:
        check transportImports(text).len == 0

suite "the viewing heartbeat":
  test "sent while the page is visible, every twenty seconds, and never after it is left":
    createRoot proc(disposeRoot: proc()) =
      let clock = newTestClock(0)
      let (source, vm) = pageOf("question", clock)
      clock.advance(60_000)
      check vm.heartbeats == 0          # not shown yet
      vm.setVisible(true)
      check vm.heartbeats == 1
      clock.advance(19_999)
      check vm.heartbeats == 1
      clock.advance(1)
      check vm.heartbeats == 2
      clock.advance(40_000)
      check vm.heartbeats == 4
      vm.setVisible(false)
      clock.advance(120_000)
      check vm.heartbeats == 4
      check source.record.len == 4
      check source.record[0] == "mark-viewing session=" & sessionIdOf(1)
      # Shown again, then disposed while shown: it stops with the page.
      vm.setVisible(true)
      check vm.heartbeats == 5
      vm.dispose()
      clock.advance(120_000)
      check vm.heartbeats == 5
      check source.record.len == 5
      disposeRoot()

  test "an inbox's page beats only while the host shows it":
    createRoot proc(disposeRoot: proc()) =
      let clock = newTestClock(0)
      let source = ScriptedActionSource(inboxFixture("populated"))
      let inbox = newInboxVM(source, clock = clock, showPages = true)
      inbox.load()
      check inbox.next()
      clock.advance(60_000)
      check inbox.page.heartbeats == 0
      inbox.setPagesVisible(true)
      clock.advance(20_000)
      check inbox.page.heartbeats == 2
      let first = inbox.page
      check inbox.next()          # a new page; the old one stops
      check first.heartbeats == 2
      check not first.isVisible
      check inbox.page.heartbeats == 1
      clock.advance(20_000)
      check first.heartbeats == 2
      check inbox.page.heartbeats == 2
      inbox.dispose()
      disposeRoot()
