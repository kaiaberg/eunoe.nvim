# Reduce a Claude Code transcript to the fields eunoe's parser reads, to
# turn a real session into a test fixture:
#   jq -c -f scripts/scrub-transcript.jq <id>.jsonl > tests/fixtures/claude/<name>.jsonl
# Drops cwd, git branch, attachments, API requests, tool input and output,
# and thinking. Prompt and reply text is kept: check it by hand before
# committing, and use sessions with harmless content only.
def block:
  if .type == "text" then {type, text}
  elif .type == "tool_use" then {type, id, name}
  elif .type == "tool_result" then {type, tool_use_id, content: "(scrubbed)"}
  elif .type == "thinking" then {type, thinking: "(scrubbed)"}
  else {type} end;
def content:
  if type == "array" then map(block) else . end;
{type, subtype, uuid, parentUuid, logicalParentUuid, isSidechain, isMeta,
 isCompactSummary, timestamp}
+ (if .type == "user" or .type == "assistant"
   then {message: {role: .message.role, content: (.message.content | content)}}
   else {} end)
| with_entries(select(.value != null))
