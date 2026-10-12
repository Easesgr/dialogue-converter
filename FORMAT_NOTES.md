# Native formats and compatibility

## Scope

0.4.0 converts visible user and assistant text between **local Claude Cowork tasks and local Codex desktop sessions**. This is an experimental adapter for versioned native formats. It creates a fresh destination snapshot; it does not update a running thread or synchronize every turn.

## Cowork sources

Discovery checks ~/Library/Application Support/Claude-3p/local-agent-mode-sessions and the equivalent Claude profile, or an explicitly selected root. Session metadata lives at <account>/<org>/local_<uuid>.json. The adapter validates the session and CLI UUIDs, then resolves the engine JSONL in full-ID, bare-ID or eight-character session directories. Resolved transcripts must stay inside the session metadata parent.

cliSessionId selects .claude/projects/<project>/<cliSessionId>.jsonl. Metadata cwd is an internal output folder, so it is not used as a shared Codex project. The user selects a real local project directory.

The last main-chain user/assistant leaf selects the active UUID chain. logicalParentUuid crosses compact_boundary records to preserve pre-compaction visible messages. Cycle/missing-link errors stop conversion. isMeta, isCompactSummary, sidechains, private thinking and tool blocks are excluded. Audit files and HMACs are not engine history and are not read or generated.

## Codex sources

Local rollout JSONL is discovered in sessions and archived_sessions, with titles from session_index.jsonl. The visible adapter supports response message items and mirrored user/agent events. Adjacent cross-representation echoes are deduplicated; repeated user requests are retained. The exact native importer marker <EXTERNAL SESSION IMPORTED> is omitted when it is an assistant message during native conversion.

System/developer items, tool calls/results, reasoning, encrypted state and compaction replacements are excluded. External/cloud-only conversations and legacy formats without accessible rollout files are unsupported.

## Codex destination

The installed desktop app's bundled codex app-server --stdio implements externalAgentConfig/import with SESSIONS. Conversion stages a fresh Claude-compatible transcript under a private staging HOME layout. An explicit CODEX_HOME selects the target while the staging HOME prevents detection from reading unrelated real Claude profiles.

Only session import is requested: no configuration, skills, MCP server, hook, permission or credential migration. No turn/start request is sent. After import completion, thread/read verifies the ordered visible roles and exact text. The app opens the resulting native thread ID. The importer adds its own visible import marker.

Tested locally with bundled codex-cli 0.162.0-alpha.17.2. The protocol is experimental; an older or changed version may reject it. Raw thread/resume.history is not used to manufacture history. The isolated integration check also invokes normal thread/resume by persisted ID without starting a model turn.

## Cowork destination

A ZIP contains exactly:

~~~text
claude-3p-export.json
local-agent-mode-sessions/<fresh-account-uuid>/<fresh-org-uuid>/local_<fresh-id>.json
local-agent-mode-sessions/<fresh-account-uuid>/<fresh-org-uuid>/local_<fresh-id>/.claude/projects/session/<fresh-cli-id>.jsonl
~~~

Manifest kind claude-desktop-export, version 1, counts {cowork:1,code:0,chat:0}. Metadata contains only the session and CLI IDs, title, creation/activity timestamps and archive flag. Engine messages have unique UUIDs and a consistent parent chain; every visible message retains its role and full text.

Import uses Claude's own **Import & Export** wizard. The application does not write into the live Claude profile, call internal renderer IPC externally, copy audit records, or mark imported sessions as already consented. Claude supplies destination storage, registration, resume consent and permissions. The converter can subsequently locate the CLI ID in local Cowork metadata and verify all original messages as an exact prefix.

The package layout has been checked against the installed Claude 2.31226.1 native importer and tested for role/text roundtrips. A local user confirmed successful synthetic ZIP import with visible history. Automatic lookup in the current local profile has not matched that test record. **Resumed model execution remains unverified in either application.** Availability is conditional on Claude's provider/account settings and version. First-party and third-party builds may expose different import routes.

## Receipts and failure handling

Each conversion stores a versioned receipt and complete visible messages. An identical content/provider/project fingerprint reuses the receipt. Changed history creates a new independent destination snapshot. Already imported Codex conversions return the original target ID.

An interrupted or failed import may have persisted a destination before reporting failure. Such receipts are marked uncertain and cannot blindly retry. Once Codex returns a target ID, it is saved before readback; native_verify can read that existing target again and verify its exact original message prefix without importing again. If no target ID was received, check the destination application first. Source files are never modified. Repeated roundtrips carry the whole visible history and may consume a substantial destination context.

## Legacy

The 0.3.0 bridge text/acknowledgement protocol remains readable for compatibility and regression checks, but the 0.4.0 application uses the native_* actions. Legacy prompt copying and link references are not the native conversion workflow.
