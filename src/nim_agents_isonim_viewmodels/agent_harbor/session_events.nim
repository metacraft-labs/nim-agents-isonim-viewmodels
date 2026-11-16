## Builders for invented Agent Harbor session events, in the wire shapes the
## session event stream and `GET /api/v1/sessions/{id}/events/history` use:
## a `type` and the event's own fields. The synthetic playback scenarios
## (`playback_scenarios.nim`) and the static invented timelines
## (`synthetic_timelines.nim`) write their sessions with them; a caller stamps
## each with its `timestamp` (µs since the session started).
##
## A tool call is a `tool_use` and its `tool_result`, paired by
## `tool_execution_id`. A shell command's result may carry a
## `command_trace`, the shape nim-agents' `activity_groups` proposes for the
## processes a command ran (Agent Harbor serves none yet).
##
## Every value these events carry is invented by their callers; nothing here
## is captured data.

import std/json

proc userInput*(text: string): JsonNode =
  ## The operator's input reaching the session.
  %*{"type": "user_input", "content": text}

proc thoughtEvent*(text: string): JsonNode =
  %*{"type": "thought", "thought": text}

proc fileRead*(path: string): JsonNode =
  %*{"type": "file_read", "file_path": path}

proc searchCall*(id, tool, pattern, path: string): JsonNode =
  ## A search tool's call (its result: `toolResult`).
  %*{"type": "tool_use", "status": "started", "tool_name": tool,
     "tool_execution_id": id, "tool_args": {"pattern": pattern, "path": path}}

proc commandCall*(id, command: string): JsonNode =
  ## A shell command's call: a tool whose arguments carry a `command`.
  %*{"type": "tool_use", "status": "started", "tool_name": "runCmd",
     "tool_execution_id": id, "tool_args": {"command": command}}

proc toolCall*(id, tool: string; args: JsonNode): JsonNode =
  ## Any other tool's call.
  %*{"type": "tool_use", "status": "started", "tool_name": tool,
     "tool_execution_id": id, "tool_args": args}

proc toolResult*(id, tool: string; exitCode: int; output: string;
                 trace: JsonNode = nil): JsonNode =
  ## A tool call's result: completed with exit 0, failed otherwise; a shell
  ## command's result may carry its `command_trace`.
  result = %*{"type": "tool_result", "tool_name": tool,
              "status": (if exitCode == 0: "completed" else: "failed"),
              "tool_execution_id": id, "exit_code": exitCode,
              "tool_output": output}
  if not trace.isNil: result["command_trace"] = trace

proc tracedProcess*(pid, ppid: int; argv: openArray[string]; startMs: int;
                    endMs = -1; exitCode = -1; stdout = ""; stderr = "";
                    cwd = "/work/upload-client"; exe = ""): JsonNode =
  ## One process of a command trace; `endMs` and `exitCode` -1 while it runs.
  result = %*{"pid": pid, "ppid": ppid, "argv": @argv, "cwd": cwd,
              "exe": (if exe.len > 0: exe else: "/usr/bin/" & argv[0]),
              "start_ms": startMs, "stdout": stdout, "stderr": stderr}
  if endMs >= 0: result["end_ms"] = %endMs
  if exitCode >= 0: result["exit_code"] = %exitCode

proc commandTrace*(processes: openArray[JsonNode]; rawOutput: string;
                   env: JsonNode): JsonNode =
  ## A command trace: its processes, raw output and environment.
  %*{"processes": @processes, "raw_output": rawOutput, "env": env}

proc fileEdit*(path: string; added, removed: int; description: string): JsonNode =
  %*{"type": "file_edit", "file_path": path, "lines_added": added,
     "lines_removed": removed, "description": description}

proc fileDeleted*(path: string): JsonNode =
  %*{"type": "file_edit", "file_path": path, "status": "deleted",
     "description": "Removed " & path}

proc diffEvent*(path: string; added, removed: int; patch: string): JsonNode =
  %*{"type": "diff", "file_path": path, "lines_added": added,
     "lines_removed": removed, "diff": patch}

proc planEvent*(steps: openArray[(string, string)]; update: bool): JsonNode =
  ## A plan: each step's text and status (`pending`, `in_progress`,
  ## `completed`).
  var entries = newJArray()
  for (content, status) in steps:
    entries.add %*{"content": content, "status": status}
  %*{"type": "plan", "is_update": update, "entries": entries}

proc agentQuestion*(prompt: string; options: openArray[string]): JsonNode =
  var choices = newJArray()
  for option in options: choices.add %*{"label": option}
  %*{"type": "agent_question", "kind": "single_choice", "prompt": prompt,
     "options": choices}

proc sessionResumed*(): JsonNode =
  %*{"type": "session_resumed", "deliverer": "operator"}

proc logLine*(text: string; level = "info"): JsonNode =
  %*{"type": "log", "level": level, "message": text}

proc agentReply*(text: string): JsonNode =
  ## An agent message, as Agent Harbor logs one (`assistant: …`).
  logLine("assistant: " & text)

proc agentFailure*(text: string): JsonNode =
  ## A failure the agent stops on: an error-level log line.
  logLine("error: " & text, "error")

proc awaitingInput*(request: string): JsonNode =
  ## A wait on the operator: a hook (`claude-stop-hook`) or a question.
  %*{"type": "session_awaiting_input", "request": request}

proc statusEvent*(status: string; message = ""): JsonNode =
  result = %*{"type": "status", "status": status}
  if message.len > 0: result["message"] = %message

proc modelRequest*(model: string; messages: int): JsonNode =
  %*{"type": "llm_request", "model": model, "messageCount": messages,
     "hasToolCalls": true}

proc harnessEvent*(kind, message: string): JsonNode =
  ## A sub-agent, delegation or orchestration event.
  case kind
  of "sub_agent": %*{"type": "sub_agent", "message": message}
  of "delegation": %*{"type": "delegation", "kind": "started",
                      "activeSubAgents": 1, "totalSubAgents": 2,
                      "description": message}
  else: %*{"type": "orchestration", "kind": "handoff", "description": message}
