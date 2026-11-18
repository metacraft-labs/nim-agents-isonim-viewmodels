## Invented inboxes for the Inbox panel's and the item pages' stories and
## tests, written in the served inbox shape (`GET /api/v1/inbox`) and read
## through nim-agents' lenient readers (`inboxFromJson`,
## `inboxItemDetailFromJson`), so the stories see what a server's answer
## would give them. Every session, prompt, host, server and person in this
## module is invented.
##
## The populated inbox (`populatedInbox`) holds one item of each served
## kind, in the server's order -- a permission gate, a blocked question, an
## ended turn, a login request and an async feedback request -- with every
## priority, a boosted item, each warmth state and a draft. Each item has a
## page (`inboxDetails`); further pages hold the variants a story shows one
## at a time: each question form, no options, sudo and network approvals
## (two queued), each feedback type, an expired request, a draft, an
## unfamiliar session, and the login request in each of its other states
## (cancelling, completed, failed, a carry error, and a login item that
## holds no request). `inboxFixture` builds the source of each story
## (`InboxFixtureNames`), and `itemFixture` the source and item of each item
## page's story (`ItemFixtureNames`); every source that holds an inbox is
## a `ScriptedActionSource` (`loading` and `error` are the seam's pending
## and failing sources).

import std/json
import ./data_source
import ./scripted_actions

export data_source, scripted_actions

const
  InboxT0* = 1_800_000_000_000'i64
    ## The invented inboxes' moment: 2027-01-15 08:00 UTC.
  InboxT0Text = "2027-01-15T08:00:00Z"

  PermissionItem* = "inbox-item-permission"
  QuestionItem* = "inbox-item-question"
  EndedTurnItem* = "inbox-item-ended-turn"
  LoginItem* = "inbox-item-login"
  FeedbackItem* = "inbox-item-feedback"

  InboxFixtureNames* = ["populated", "long", "fleet", "empty", "cursor-middle",
                        "manager-held", "loading", "error"]
    ## Every Inbox panel story's fixture.
  ItemFixtureNames* = ["question", "question-single", "question-multi",
                       "question-confirmation", "question-no-options", "ended-turn",
                       "permission", "sudo", "network", "login", "feedback",
                       "feedback-options", "feedback-expired", "draft", "unfamiliar",
                       "login-cancelling", "login-completed", "login-failed",
                       "login-carry-error-pending", "login-none"]
    ## Every item page story's fixture.
  InboxErrorText* = "GET /api/v1/inbox answered 502: the hub is restarting"
  LoginCarryErrorText* = "Signed in, but the agent's browser profile has not " &
    "picked up the session yet. Try signing in again."
    ## The invented carry error of `login-carry-error-pending`.
  LoginFailedText* = "The sign-in window was closed before the sign-in finished."
    ## The invented reason of `login-failed`.

proc iso(offsetSeconds: int): string =
  ## The invented moment `offsetSeconds` after `InboxT0`, as ISO-8601.
  let total = 8 * 3600 + offsetSeconds
  proc two(x: int): string = (if x < 10: "0" else: "") & $x
  if total < 0 or total >= 86400: return InboxT0Text
  "2027-01-15T" & two(total div 3600) & ":" & two((total mod 3600) div 60) & ":" &
    two(total mod 60) & "Z"

proc sessionJson(n: int; title, agent, host: string): JsonNode =
  %*{"id": "5ca1ab1e-0b0" & $n & "-4b00-8000-00000000b00" & $n, "title": title,
     "host": host, "agent": agent, "status": "running", "label": title}

proc sessionIdOf*(n: int): string =
  ## The invented session id of the `n`th inbox session (1-9).
  "5ca1ab1e-0b0" & $n & "-4b00-8000-00000000b00" & $n

proc itemJson(id, kind: string; session: JsonNode; priority, effective: string;
              explanation: string; enteredAgo: int; warmth: JsonNode;
              boost: JsonNode = nil; question = ""): JsonNode =
  result = %*{"id": id, "kind": kind, "session": session, "priority": priority,
              "effectivePriority": effective, "explanation": explanation,
              "enteredAt": iso(-enteredAgo), "cacheWarmth": warmth}
  if not boost.isNil: result["boost"] = boost
  if question.len > 0: result["question"] = %question

proc populatedItems(): seq[JsonNode] =
  @[
    itemJson(PermissionItem, "permission_gate",
             sessionJson(3, "Migrate the cache schema", "Claude Code", "build-03"),
             "urgent", "urgent",
             "Urgent: the migration holds a write lock until you decide.", 95,
             %*{"state": "warm", "deadline": iso(192), "confidence": "exact"}),
    itemJson(QuestionItem, "blocked_question",
             sessionJson(1, "Port the route cache", "Claude Code", "build-01"),
             "normal", "high",
             "Raised: its model cache is warm for three more minutes.", 240,
             %*{"state": "warm", "deadline": iso(180), "confidence": "estimated"},
             %*{"reason": "cache_warm", "reasons": ["cache_warm", "recent"],
                "deadline": iso(180)},
             question = "Keep the old cache behind a flag?"),
    itemJson(EndedTurnItem, "ended_turn",
             sessionJson(2, "Tidy the upload client's logging", "Codex", "build-02"),
             "normal", "normal", "Waiting longest of the normal items.", 1260,
             %*{"state": "expiring", "confidence": "exact"}),
    itemJson(LoginItem, "login_request",
             sessionJson(5, "Benchmark the cache", "Gemini CLI", "build-05"),
             "normal", "normal", "Blocked until someone signs in.", 600,
             %*{"state": "cold"}),
    itemJson(FeedbackItem, "async_feedback",
             sessionJson(4, "Write the release notes", "Claude Code", "build-04"),
             "low", "low", "Low priority; draft ready.", 3000,
             %*{"state": "neutral"})]

proc inboxOf(items: seq[JsonNode]; degraded: JsonNode = nil): InboxSnapshot =
  var node = %*{"items": items, "generatedAt": InboxT0Text, "nextChangeAt": iso(180)}
  var arr = newJArray()
  for i, item in items:
    var it = item.copy
    it["position"] = %(i + 1)
    arr.add it
  node["items"] = arr
  if not degraded.isNil: node["degraded"] = degraded
  inboxFromJson(node)

proc populatedInbox*(): InboxSnapshot =
  ## One item of each served kind, in the server's order.
  inboxOf(populatedItems())

proc longInbox*(count = 40): InboxSnapshot =
  ## `count` waiting items, long session titles among them.
  var items: seq[JsonNode]
  for i in 1 .. count:
    let title = if i mod 5 == 0:
        "Port the route cache's eviction policy to the new storage layer and keep " &
          "the old one behind a flag until the migration has run on every region"
      else: "Invented session " & $i
    items.add itemJson("inbox-item-" & $i, (if i mod 3 == 0: "ended_turn" else: "blocked_question"),
                       %*{"id": "5ca1ab1e-0d" & $i, "title": title, "host": "build-0" & $(i mod 9),
                          "agent": "Claude Code", "status": "running", "label": title},
                       "normal", "normal", "Waiting " & $(i * 2) & " minutes.", i * 120,
                       %*{"state": "unknown"})
  inboxOf(items)

proc fleetInbox*(): InboxSnapshot =
  ## Items from two servers, one of which could not be read.
  var items = populatedItems()[0 .. 2]
  items[1]["server"] = %"relay-lab"
  items[2]["server"] = %"relay-lab"
  inboxOf(items, %*[{"server": "orbit-west", "reason": "connection refused"}])

proc managerHeldInbox*(): InboxSnapshot =
  ## An item whose agent died, held by a manager; one that needs the
  ## operator; and an item of a kind this front-end does not know, kept in
  ## its place.
  var items = populatedItems()[0 .. 1]
  items[0]["heldBy"] = %"manager"
  items[1]["heldBy"] = %"operator"
  items.insert(itemJson("inbox-item-budget", "budget_approval",
                        sessionJson(6, "Re-run the nightly benchmarks", "Codex", "build-06"),
                        "high", "high", "Asks to spend past its daily budget.", 400,
                        %*{"state": "unknown"}), 1)
  inboxOf(items)

# ---------------------------------------------------------------------------
# Item pages
# ---------------------------------------------------------------------------

proc detail(node: JsonNode): InboxItemDetail = inboxItemDetailFromJson(node)

proc loginJson(state: string; error = ""): JsonNode =
  ## The populated inbox's login request (`login-51`) in `state`.
  result = %*{"requestId": "login-51", "provider": "Example Cloud",
              "prompt": "Sign in to read the benchmark bucket.",
              "mode": "local_desktop", "state": state}
  if error.len > 0: result["error"] = %error

proc inboxDetails*(): seq[InboxItemDetail] =
  ## The page of every item of `populatedInbox`.
  @[
    detail(%*{"itemId": PermissionItem, "sessionId": sessionIdOf(3),
              "kind": "permission_gate", "requestId": "perm-31",
              "prompt": "Run `psql -f migrations/0042_cache.sql` against the staging database?",
              "permissionOptions": [
                {"id": "allow_once", "kind": "allow_once"},
                {"id": "allow_always", "kind": "allow_always"},
                {"id": "reject_once", "kind": "reject_once"},
                {"id": "reject_always", "kind": "reject_always"}],
              "familiar": true}),
    detail(%*{"itemId": QuestionItem, "sessionId": sessionIdOf(1),
              "kind": "blocked_question", "blocked": true, "requestId": "q-11",
              "prompt": "Keep the old cache behind a flag?", "form": "free_form",
              "familiar": true}),
    detail(%*{"itemId": EndedTurnItem, "sessionId": sessionIdOf(2),
              "kind": "ended_turn",
              "lastReply": "Done. The upload client logs through its module logger now; " &
                           "the old print calls are gone.",
              "familiar": true}),
    detail(%*{"itemId": LoginItem, "sessionId": sessionIdOf(5),
              "kind": "login_request",
              "login": loginJson("pending"),
              "familiar": true}),
    detail(%*{"itemId": FeedbackItem, "sessionId": sessionIdOf(4),
              "kind": "async_feedback",
              "feedback": {"id": "fb-41", "taskId": "release-notes", "type": "question",
                           "prompt": "Which changes belong in the highlights?",
                           "minLength": 10, "maxLength": 400, "expiresAt": iso(3600),
                           "attachments": [{"name": "draft-notes.md", "kind": "text"}]},
              "draft": {"text": "The route cache, the schema migration and the logging clean-up.",
                        "rationale": "These three changed behaviour users see.",
                        "confidence": "high", "drafter": "release-manager"},
              "familiar": true})]

proc variantDetail(name: string): InboxItemDetail =
  ## The page a single item story shows, by fixture name.
  let id = "inbox-item-" & name
  case name
  of "login-cancelling", "login-completed", "login-failed", "login-carry-error-pending":
    let login = case name
      of "login-cancelling": loginJson("cancelling")
      of "login-completed": loginJson("completed")
      of "login-failed": loginJson("failed", LoginFailedText)
      else: loginJson("pending", LoginCarryErrorText)
    detail(%*{"itemId": id, "sessionId": sessionIdOf(5), "kind": "login_request",
              "login": login, "familiar": true})
  of "login-none":
    # A login item whose request is gone (withdrawn or resolved before the
    # page read it): the page holds no request.
    detail(%*{"itemId": id, "sessionId": sessionIdOf(5), "kind": "login_request",
              "familiar": true})
  of "question":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(1), "kind": "blocked_question",
              "blocked": true, "requestId": "q-12", "form": "free_form", "familiar": true,
              "prompt": "The old cache and the new one disagree on the eviction order for " &
                        "entries written in the same millisecond. Keep the old order behind " &
                        "a flag, or take the new one everywhere and note it in the changelog?"})
  of "question-single":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(1), "kind": "blocked_question",
              "requestId": "q-13", "form": "single_choice", "familiar": true,
              "prompt": "Which storage layer should the cache use?",
              "options": [{"id": "sqlite", "label": "SQLite"},
                          {"id": "rocks", "label": "RocksDB"}]})
  of "question-multi":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(1), "kind": "blocked_question",
              "requestId": "q-14", "form": "multi_choice", "familiar": true,
              "prompt": "Which regions should run the migration first?",
              "options": ["eu-west", "us-east", "ap-south"]})
  of "question-confirmation":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(1), "kind": "blocked_question",
              "blocked": true, "requestId": "q-15", "form": "confirmation", "familiar": true,
              "prompt": "Delete the old cache tables now?"})
  of "question-no-options":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(1), "kind": "blocked_question",
              "requestId": "q-16", "form": "single_choice", "familiar": true,
              "prompt": "Which of these should I keep?"})
  of "sudo":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(7), "kind": "permission_gate",
              "familiar": true,
              "approvals": [
                {"requestId": "sudo-71", "scope": "sudo",
                 "command": "systemctl restart relay", "reason": "load the new queue limit"},
                {"requestId": "sudo-72", "scope": "sudo",
                 "command": "chown relay /var/lib/relay", "reason": "let the relay write its shed log"}]})
  of "network":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(8), "kind": "permission_gate",
              "familiar": true,
              "approvals": [{"requestId": "net-81", "scope": "network",
                             "domain": "packages.example.org",
                             "reason": "download the pinned benchmark tool"}]})
  of "feedback-options":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(4), "kind": "async_feedback",
              "familiar": true,
              "feedback": {"id": "fb-42", "taskId": "release-notes", "type": "options",
                           "prompt": "Which sections should the notes have?",
                           "options": ["Highlights", "Fixes", "Known issues"]}})
  of "feedback-expired":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(4), "kind": "async_feedback",
              "familiar": true,
              "feedback": {"id": "fb-43", "taskId": "release-notes", "type": "question",
                           "prompt": "Should the notes mention the old cache?",
                           "expiresAt": iso(-60)}})
  of "unfamiliar":
    detail(%*{"itemId": id, "sessionId": sessionIdOf(9), "kind": "blocked_question",
              "blocked": true, "requestId": "q-91", "form": "free_form", "familiar": false,
              "executiveSummary": "Ports the route cache to the new storage layer; three " &
                                  "of five milestones done; it now needs a decision on " &
                                  "eviction order.",
              "prompt": "Keep the old eviction order behind a flag?"})
  else:
    raise newException(ValueError, "no item page fixture named " & name)

proc inboxSource*(inbox: InboxSnapshot; details: seq[InboxItemDetail];
                  label: string): ScriptedActionSource =
  result = newScriptedActionSource(label)
  result.inbox = inbox
  result.details = details

proc inboxFixture*(name: string): AgentHarborDataSource =
  ## The source of the Inbox story `name` (`InboxFixtureNames`). Raises
  ## `ValueError` for an unknown name.
  case name
  of "populated": inboxSource(populatedInbox(), inboxDetails(), "invented inbox")
  of "long": inboxSource(longInbox(), @[], "invented inbox: a long list")
  of "fleet": inboxSource(fleetInbox(), inboxDetails(), "invented fleet inbox")
  of "empty": inboxSource(InboxSnapshot(generatedAtMs: InboxT0), @[], "invented inbox: empty")
  of "cursor-middle":
    # The operator walked the first two items with Next and is on the third.
    let s = inboxSource(populatedInbox(), inboxDetails(), "invented inbox: mid-walk")
    let order = s.inbox.orderOf
    s.setCursor("default", InboxCursor(current: order[2], visited: @[order[0], order[1]]))
    s
  of "manager-held":
    inboxSource(managerHeldInbox(), inboxDetails(), "invented inbox: held items")
  of "loading": newPendingDataSource("waiting for the inbox")
  of "error": newFailingDataSource(InboxErrorText)
  else: raise newException(ValueError, "no Inbox fixture named " & name)

proc itemFixture*(name: string): tuple[source: ScriptedActionSource,
                                       item: InboxItemRef, sessionId: string] =
  ## The source of the item page story `name` (`ItemFixtureNames`), the item
  ## it shows and its session. Raises `ValueError` for an unknown name.
  let populated = inboxDetails()
  var d: InboxItemDetail
  case name
  of "ended-turn": d = populated[2]
  of "permission": d = populated[0]
  of "login": d = populated[3]
  of "feedback", "draft": d = populated[4]
  else: d = variantDetail(name)
  if name == "feedback":
    d.draft = Draft()   # the plain request; `draft` shows the same with its draft
  var details = populated
  var replaced = false
  for x in details.mitems:
    if x.itemId == d.itemId:
      x = d
      replaced = true
  if not replaced: details.add d
  (inboxSource(populatedInbox(), details, "invented inbox item: " & name),
   InboxItemRef(id: d.itemId), d.sessionId)
