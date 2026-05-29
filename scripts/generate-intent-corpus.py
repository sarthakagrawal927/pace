#!/usr/bin/env python3
"""
generate-intent-corpus.py — produce labeled (transcript, intent) pairs
for training Pace's intent classifier (task #113).

Why this exists
---------------
A real on-device intent classifier (Create ML text classifier, ~50KB
.mlmodel) would let Pace skip the VLM call on pure-knowledge turns
("what is HTML") and skip the planner call on chitchat ("hi pace"),
saving ~1500ms and ~2200ms respectively. We don't have a real user-
labeled corpus yet, so this script produces a synthetic seed corpus
the user can spot-check and augment.

Output: evals/intent-corpus/seed.csv (Create ML format) AND
evals/intent-corpus/seed.jsonl (one record per line, for any
Python/Swift tool that prefers JSONL).

Coverage targets
----------------
- pureKnowledge: factual questions answerable without seeing the screen
- screenDescription: "what's on screen" / "summarise this" — VLM needed,
  but no action follows
- screenAction: "click X" / "type Y" — VLM + planner + action exec
- chitchat: greetings / closure / social filler — no VLM, no planner,
  canned response

Aim for ~50 examples per class; the generator emits 200+ in total via
templated substitution. Real user logs should be added later (the
classifier's behavior on synthetic-only data won't match production).

Usage
-----
  ./scripts/generate-intent-corpus.py
  ./scripts/generate-intent-corpus.py --count 100  # per-class target
"""

from __future__ import annotations

import argparse
import csv
import json
import random
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
OUTPUT_DIR = PROJECT_DIR / "evals" / "intent-corpus"

INTENT_CLASS_PURE_KNOWLEDGE = "pureKnowledge"
INTENT_CLASS_SCREEN_DESCRIPTION = "screenDescription"
INTENT_CLASS_SCREEN_ACTION = "screenAction"
INTENT_CLASS_CHITCHAT = "chitchat"


# Topic words for pure-knowledge questions. Drawn from things Pace
# users plausibly ask about while at their Mac — programming concepts,
# common general-knowledge prompts, plus a few "explain like I'm five"
# style ones.
PURE_KNOWLEDGE_TOPICS = [
    "html", "css", "javascript", "python", "swift", "react", "git",
    "docker", "kubernetes", "tcp", "udp", "dns", "https", "json",
    "regex", "async await", "closures", "the kernel", "memory mapping",
    "garbage collection", "the heap", "the stack", "machine learning",
    "neural networks", "transformers", "attention", "embeddings",
    "newton's laws", "photosynthesis", "the krebs cycle", "entropy",
    "the speed of light", "general relativity", "evolution",
    "the federal reserve", "compound interest", "options trading",
    "the constitution", "world war two", "the renaissance",
    "the silk road", "espresso", "sourdough", "mitochondria",
    "the gulf stream", "plate tectonics", "ipv6", "tls",
    "the law of demeter", "currying",
]

PURE_KNOWLEDGE_PATTERNS = [
    "what is {}",
    "explain {}",
    "tell me about {}",
    "how does {} work",
    "can you describe {}",
    "what's the deal with {}",
    "give me a quick intro to {}",
    "remind me what {} means",
    "what does {} actually do",
    "in plain english what is {}",
]


# Templates for screen-description requests. The user is asking Pace
# to make sense of what's on screen without taking any action.
SCREEN_DESCRIPTION_TEMPLATES = [
    "what's on the screen",
    "what am i looking at",
    "describe what i'm looking at",
    "describe this",
    "summarise this page",
    "summarize what's here",
    "what does this show",
    "what does this say",
    "what's happening on screen",
    "read this to me",
    "what's in front of me",
    "give me the gist of this",
    "what can you see right now",
    "tell me what's open",
    "what's this window about",
    "walk me through what's here",
    "what's visible on this screen",
    "scan the screen and tell me",
    "what's on display",
    "what page am i on",
    "what app is this",
    "explain what's shown",
    "describe my current view",
    "what's this all about",
    "lay out what's on the screen",
]


# Action templates: deictic ("click that") and named ("click the save
# button"). Mix verbs and targets so the classifier sees variety.
SCREEN_ACTION_VERBS = [
    "click", "tap", "press", "hit", "open", "launch", "choose",
    "select", "focus", "toggle",
]

SCREEN_ACTION_TARGETS = [
    "the save button", "the file menu", "the close button",
    "the search bar", "this link", "that field", "the first tab",
    "the second tab", "the send button", "the back button",
    "settings", "preferences", "the inbox", "the menu icon",
]

SCREEN_ACTION_TYPING_TARGETS = [
    "hello world", "my email address", "the password", "yes please",
    "thanks", "no thanks", "this is a test", "pizza", "lorem ipsum",
]

SCREEN_ACTION_KEY_REQUESTS = [
    "press command s to save",
    "press cmd s",
    "save with the keyboard shortcut",
    "press escape",
    "hit enter",
    "press return",
    "press cmd q",
    "quit the app with cmd q",
    "press cmd c to copy",
    "press cmd v to paste",
    "select all with cmd a",
    "press cmd z to undo",
]

SCREEN_ACTION_SCROLL_REQUESTS = [
    "scroll down a bit",
    "scroll up",
    "scroll to the top",
    "scroll to the bottom",
    "page down",
    "page up",
    "scroll down five lines",
    "scroll up three lines",
]


# Chitchat — greetings, closure, gratitude, micro-pleasantries.
CHITCHAT_PHRASES = [
    "hi pace",
    "hello pace",
    "hey there",
    "hi there",
    "good morning",
    "good evening",
    "what's up",
    "how are you",
    "how's it going",
    "thanks",
    "thank you",
    "thanks a lot",
    "appreciate it",
    "you're great",
    "you're awesome",
    "good job",
    "nice work",
    "bye for now",
    "talk later",
    "catch you later",
    "later pace",
    "see you",
    "alright",
    "okay cool",
    "got it",
    "sounds good",
    "perfect",
    "nice",
]


def build_pure_knowledge_examples(per_class_count: int, rng: random.Random) -> list[dict]:
    examples: list[dict] = []
    used = set()
    while len(examples) < per_class_count:
        topic = rng.choice(PURE_KNOWLEDGE_TOPICS)
        pattern = rng.choice(PURE_KNOWLEDGE_PATTERNS)
        transcript = pattern.format(topic)
        if transcript in used:
            continue
        used.add(transcript)
        examples.append({"transcript": transcript, "intent": INTENT_CLASS_PURE_KNOWLEDGE})
    return examples


def build_screen_description_examples(per_class_count: int, rng: random.Random) -> list[dict]:
    examples: list[dict] = []
    used = set()
    # Use templates directly, with light shuffling. If we run out of
    # unique templates, recycle with prefixes like "uh," "hey," etc.
    speech_prefixes = ["", "uh ", "hey ", "ok ", "alright "]
    while len(examples) < per_class_count:
        prefix = rng.choice(speech_prefixes)
        base = rng.choice(SCREEN_DESCRIPTION_TEMPLATES)
        transcript = (prefix + base).strip()
        if transcript in used:
            continue
        used.add(transcript)
        examples.append({"transcript": transcript, "intent": INTENT_CLASS_SCREEN_DESCRIPTION})
    return examples


def build_screen_action_examples(per_class_count: int, rng: random.Random) -> list[dict]:
    examples: list[dict] = []
    used = set()

    # Three flavors of action: click-style, type-style, key/scroll-style.
    # Mix proportions so the classifier sees the full action vocabulary
    # rather than just "click the X".
    while len(examples) < per_class_count:
        choice = rng.choices(
            population=["click", "type", "key", "scroll"],
            weights=[0.45, 0.20, 0.20, 0.15],
            k=1,
        )[0]
        if choice == "click":
            verb = rng.choice(SCREEN_ACTION_VERBS)
            target = rng.choice(SCREEN_ACTION_TARGETS)
            transcript = f"{verb} {target}"
        elif choice == "type":
            target = rng.choice(SCREEN_ACTION_TYPING_TARGETS)
            transcript = f"type {target}"
        elif choice == "key":
            transcript = rng.choice(SCREEN_ACTION_KEY_REQUESTS)
        else:  # scroll
            transcript = rng.choice(SCREEN_ACTION_SCROLL_REQUESTS)

        if transcript in used:
            continue
        used.add(transcript)
        examples.append({"transcript": transcript, "intent": INTENT_CLASS_SCREEN_ACTION})
    return examples


def build_chitchat_examples(per_class_count: int, rng: random.Random) -> list[dict]:
    examples: list[dict] = []
    used = set()
    while len(examples) < per_class_count:
        transcript = rng.choice(CHITCHAT_PHRASES)
        if transcript in used:
            # Out of unique phrases — augment with adjective prefix
            transcript = rng.choice(["really ", "okay ", "well ", ""]) + transcript
            transcript = transcript.strip()
            if transcript in used:
                continue
        used.add(transcript)
        examples.append({"transcript": transcript, "intent": INTENT_CLASS_CHITCHAT})
    return examples


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--count",
        type=int,
        default=50,
        help="Target number of examples per class (default 50, total ~200).",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducible corpus generation.",
    )
    args = parser.parse_args(argv)

    rng = random.Random(args.seed)
    per_class = args.count

    all_examples: list[dict] = []
    all_examples.extend(build_pure_knowledge_examples(per_class, rng))
    all_examples.extend(build_screen_description_examples(per_class, rng))
    all_examples.extend(build_screen_action_examples(per_class, rng))
    all_examples.extend(build_chitchat_examples(per_class, rng))

    rng.shuffle(all_examples)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    csv_path = OUTPUT_DIR / "seed.csv"
    with csv_path.open("w", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=["transcript", "intent"])
        writer.writeheader()
        writer.writerows(all_examples)

    jsonl_path = OUTPUT_DIR / "seed.jsonl"
    with jsonl_path.open("w") as jsonl_file:
        for example in all_examples:
            jsonl_file.write(json.dumps(example) + "\n")

    # Print a class-distribution summary so the human running this can
    # eyeball the corpus balance.
    counts: dict[str, int] = {}
    for example in all_examples:
        counts[example["intent"]] = counts.get(example["intent"], 0) + 1

    print(f"Wrote {len(all_examples)} examples to:")
    print(f"  {csv_path}")
    print(f"  {jsonl_path}")
    print("\nClass distribution:")
    for intent_class, count in sorted(counts.items()):
        print(f"  {intent_class:24s}  {count}")
    print(
        "\nNext: open the CSV in Create ML's Text Classifier template "
        "(File → New Project → Text Classification → Add Training Data "
        "→ pick this CSV), train, drop the .mlmodel into Pace's bundle."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
