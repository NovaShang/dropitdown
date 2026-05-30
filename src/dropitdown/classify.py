from __future__ import annotations

import json
from dataclasses import dataclass

from openai import OpenAI

from dropitdown import ignore, rules
from dropitdown.config import Config
from dropitdown.ignore import TreeListing


@dataclass
class Classification:
    category_path: str
    summary: str
    is_new_category: bool
    cache_hit_tokens: int = 0
    cache_miss_tokens: int = 0


SYSTEM_RULES = """You are a file archivist. Given a file's name, content excerpt, and the user's existing directory structure, decide where to file it and produce a one-sentence Chinese summary.

Rules:
- Accuracy beats reuse. If the file genuinely belongs in an existing category, use it. If it doesn't clearly fit any existing one, confidently create a new category with a precise name — do not force it into a near-miss.
- A document's type (bill, contract, ID, transcript, receipt, immigration form, ...) must match the category. Don't sort by topic if the document type is different (e.g. an I-20 form is not a "Bill" just because it mentions money).
- category_path is forward-slash separated, relative (no leading slash). Keep depth shallow (1-3 levels typically).
- summary is one sentence, factual, in Chinese.

Tree listing format:
- Each line: `- path (Xd/Yf)` means X direct subdirs and Y direct files visible after ignore filtering.
- A `+deeper` marker means more subdirs exist below this entry but were cut off by the 3-level depth limit.
- Children are listed ABOVE their parent so you see the most specific category options first.
- If the tree header says "showing N of M", more directories at the root level were truncated.

If you need more detail on any branch (truncated entries, `+deeper` markers, or just to verify what's inside before deciding), call list_subtree with the relative path. Otherwise call classify directly.
"""


CLASSIFY_TOOL = {
    "type": "function",
    "function": {
        "name": "classify",
        "description": "Return the chosen archive path and a summary. Call once you've decided.",
        "parameters": {
            "type": "object",
            "properties": {
                "category_path": {
                    "type": "string",
                    "description": "Relative path under the archive root, e.g. 'Finance/Bill'.",
                },
                "summary": {
                    "type": "string",
                    "description": "One-sentence Chinese summary of the file.",
                },
                "is_new_category": {
                    "type": "boolean",
                    "description": "True if category_path is not in the existing tree.",
                },
            },
            "required": ["category_path", "summary", "is_new_category"],
        },
    },
}


LIST_SUBTREE_TOOL = {
    "type": "function",
    "function": {
        "name": "list_subtree",
        "description": (
            "Read-only: list the contents of a directory under the archive "
            "root, recursing up to 3 levels with the same ignore rules "
            "applied. Use when an entry in the main tree is marked +deeper, "
            "when the root header says results were truncated, or when you "
            "need to see what's inside a candidate folder before deciding."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Relative path under the archive root, e.g. 'Stanford/CEE 226' or '财务'.",
                },
            },
            "required": ["path"],
        },
    },
}


LIST_IGNORE_TOOL = {
    "type": "function",
    "function": {
        "name": "list_ignore_patterns",
        "description": "Return the current ignore patterns filtering the directory tree. Useful to check what's already excluded before adding new patterns.",
        "parameters": {"type": "object", "properties": {}, "required": []},
    },
}


ADD_IGNORE_TOOL = {
    "type": "function",
    "function": {
        "name": "add_ignore_patterns",
        "description": (
            "Add new patterns to permanently exclude noise from the directory tree. "
            "Patterns take effect on subsequent file drops (not this one). "
            "gitignore-style: bare name ('Larian Studios') matches any dir with that name; "
            "'/' anchors to archive root ('Stanford/CEE 146S/Reading Materials'); "
            "glob: * matches anything except /. "
            "Examples: 'Reading Materials', 'PSets', 'Module *', 'Stanford/*/Assignments/Week *'."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "patterns": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Patterns to add.",
                },
                "reason": {
                    "type": "string",
                    "description": "One sentence: what kind of noise these represent.",
                },
            },
            "required": ["patterns", "reason"],
        },
    },
}


def _build_system(archive_listing: TreeListing, md_listing: TreeListing) -> str:
    arch = ignore.format_listing(archive_listing, "Archive root directories")
    md = ignore.format_listing(md_listing, "Markdown root directories")
    learned = rules.active_rules()
    learned_section = ""
    if learned:
        bullets = "\n".join(f"- {r}" for r in learned)
        learned_section = (
            "\nRules learned from past corrections (HARD constraints, follow exactly):\n"
            f"{bullets}\n"
        )
    return f"{SYSTEM_RULES}{learned_section}\n{arch}\n\n{md}\n"


def classify(
    cfg: Config,
    filename: str,
    content: str,
    archive_listing: TreeListing,
    md_listing: TreeListing,
) -> Classification:
    client = OpenAI(api_key=cfg.api_key, base_url=cfg.base_url, timeout=60.0)

    system_msg = _build_system(archive_listing, md_listing)
    user_msg = f"Filename: {filename}\n\nContent excerpt:\n---\n{content}\n---"

    messages: list[dict] = [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_msg},
    ]
    tools = [CLASSIFY_TOOL, LIST_SUBTREE_TOOL]
    patterns = ignore.load()

    cache_hit = 0
    cache_miss = 0

    for _ in range(6):
        resp = client.chat.completions.create(
            model=cfg.model,
            messages=messages,
            tools=tools,
            tool_choice="auto",
            temperature=0.2,
        )

        usage = getattr(resp, "usage", None)
        if usage is not None:
            cache_hit += getattr(usage, "prompt_cache_hit_tokens", 0) or 0
            cache_miss += getattr(usage, "prompt_cache_miss_tokens", 0) or 0

        msg = resp.choices[0].message
        if not msg.tool_calls:
            raise RuntimeError(f"LLM did not return a tool call: {msg.content}")

        messages.append({
            "role": "assistant",
            "content": msg.content,
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                for tc in msg.tool_calls
            ],
        })

        classify_args = None
        for tc in msg.tool_calls:
            name = tc.function.name
            try:
                args = json.loads(tc.function.arguments)
            except json.JSONDecodeError:
                args = {}

            if name == "classify":
                classify_args = args
                tool_result = "OK"
            elif name == "list_subtree":
                rel = (args.get("path") or "").strip().strip("/")
                if not rel:
                    tool_result = "Error: 'path' is required."
                else:
                    tool_result = ignore.list_subtree(
                        cfg.archive_root, rel, patterns
                    )
            else:
                tool_result = f"Unknown tool: {name}"

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": tool_result,
            })

        if classify_args is not None:
            return Classification(
                category_path=classify_args["category_path"].strip("/"),
                summary=classify_args["summary"],
                is_new_category=bool(classify_args["is_new_category"]),
                cache_hit_tokens=cache_hit,
                cache_miss_tokens=cache_miss,
            )

    raise RuntimeError(
        "LLM exceeded tool iteration limit without calling classify"
    )


REVIEW_SYSTEM = """You are auditing a user's archive directory tree for noise. The user wants to use this tree as classification context for incoming files, so categories that aren't real user-curated archive folders should be ignored.

Definitely noise:
- Repeating template/scaffolding subfolders (Module 1..28, Week 1..N, PSets/PS1..PS6, output, Assignment1..AssignmentN, Lecture Slides, Problem Sets, Reading Materials, Solutions, transcripts, downloaded_videos)
- App data dumps (game saves, build outputs, caches)
- Deep tool-generated dirs (LevelCache, Previews, Vignettes/Illustrations)

Definitely NOT noise (do NOT add):
- Top-level user-curated folders (Archive, Notes, 财务, 票据, 个人项目, 个人信息, 资源, 归档, VoltReality, etc.)
- Semantically distinct subdirs that describe a real category (Finance/Bills, Immigration/Forms/I-20, 票据/差旅, etc.)

Prefer few, broad parent-anchored patterns over many leaf patterns. Use add_ignore_patterns to commit. You can iterate — review, add, then list to confirm before stopping. When nothing more should be ignored, respond with text only (no tool call).
"""


def review_tree(cfg: Config, archive_tree: list[str], md_tree: list[str]) -> list[str]:
    """Dedicated hygiene pass: ask the LLM to scan the tree and add ignores.
    Returns list of patterns added across the session."""
    client = OpenAI(api_key=cfg.api_key, base_url=cfg.base_url)
    arch = "\n".join(f"- {p}" for p in archive_tree) if archive_tree else "(empty)"
    md = "\n".join(f"- {p}" for p in md_tree) if md_tree else "(empty)"
    system_msg = (
        f"{REVIEW_SYSTEM}\n"
        f"Archive root directories ({len(archive_tree)} shown):\n{arch}\n\n"
        f"Markdown root directories ({len(md_tree)} shown):\n{md}\n"
    )
    user_msg = "Review the tree above. Add ignore patterns for any noise you see. Stop when the tree looks clean."

    messages: list[dict] = [
        {"role": "system", "content": system_msg},
        {"role": "user", "content": user_msg},
    ]
    tools = [LIST_IGNORE_TOOL, ADD_IGNORE_TOOL]
    added_total: list[str] = []

    for _ in range(6):
        resp = client.chat.completions.create(
            model=cfg.model,
            messages=messages,
            tools=tools,
            tool_choice="auto",
            temperature=0.2,
        )
        msg = resp.choices[0].message
        if not msg.tool_calls:
            break  # LLM signalled "done"

        messages.append({
            "role": "assistant",
            "content": msg.content,
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                for tc in msg.tool_calls
            ],
        })

        for tc in msg.tool_calls:
            try:
                args = json.loads(tc.function.arguments)
            except json.JSONDecodeError:
                args = {}
            if tc.function.name == "list_ignore_patterns":
                tool_result = "\n".join(ignore.load()) or "(none)"
            elif tc.function.name == "add_ignore_patterns":
                added = ignore.add(args.get("patterns", []), args.get("reason", ""))
                added_total.extend(added)
                tool_result = f"Added {len(added)} pattern(s)."
            else:
                tool_result = f"Unknown tool: {tc.function.name}"
            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": tool_result,
            })

    return added_total
