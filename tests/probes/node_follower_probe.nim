## A Node host for `test_node_follower.nim`: one `NodeHarborFollower` over
## the server the test started, standing in for a desktop app's main process.
##
## Arguments: `<baseUrl> <apiKey or -> <outFile> [after] [readTimeoutMs]`.
## Every message the follower posts is appended to `outFile` as one line of
## the text IPC would carry (`encodeHostMessage`), so the test reads exactly
## what a window would receive. The probe's own lines are `{"probe": ...}`.
##
## Commands, one per line on stdin: `load <id> <pageSize>`, `close` (the
## follower stops; the probe writes `{"probe":"closed"}` once `close`
## returns) and `exit`.
##
## Compile: `nim js -d:nodejs`; run: `node <probe>.js ...`.

import std/strutils
import nim_agent_harbor
import nim_agents_isonim_viewmodels/agent_harbor/node_follower

proc argv(i: int): cstring {.importjs: "(process.argv[# + 2] || '')".}
proc appendLine(path, line: cstring) {.importjs:
  "require('fs').appendFileSync(#, # + '\\n')".}
proc onStdinLine(callback: proc(line: cstring)) {.importjs: """
  ((cb) => {
    let buffered = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      buffered += chunk;
      let at;
      while ((at = buffered.indexOf('\n')) >= 0) {
        cb(buffered.slice(0, at));
        buffered = buffered.slice(at + 1);
      }
    });
  })(#)""".}
proc exitNow() {.importjs: "process.exit(0)@".}

let
  baseUrl = $argv(0)
  key = $argv(1)
  outFile = argv(2)
  after = $argv(3)
  readTimeout = $argv(4)

let auth = if key.len == 0 or key == "-": HarborAuth(kind: akNone)
           else: apiKeyAuth(key)
let follower = newNodeHarborFollower(baseUrl,
  proc(message: HostMessage) = appendLine(outFile, cstring encodeHostMessage(message)),
  auth = auth, after = after,
  readTimeoutMs = (if readTimeout.len > 0: parseInt(readTimeout) else: 30_000),
  minBackoffMs = 100, maxBackoffMs = 1_000)
appendLine(outFile, """{"probe":"started"}""")

onStdinLine(proc(line: cstring) =
  let words = ($line).strip.splitWhitespace
  if words.len == 0: return
  case words[0]
  of "load":
    follower.load(parseInt(words[1]), parseInt(words[2]))
  of "close":
    follower.close()
    appendLine(outFile, """{"probe":"closed"}""")
  of "exit":
    exitNow()
  else:
    appendLine(outFile, """{"probe":"unknown command"}"""))
