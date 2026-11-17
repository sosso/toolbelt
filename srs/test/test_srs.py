"""Checks that the cards can be won the way they claim, and only that way.

    /usr/bin/python3 -m unittest discover srs/test

Terminal cards: every template's par route is typed into the real zsh line
editor through a pseudo-terminal, and must land on the goal in exactly par
keystrokes. Lateral cards: every template must generate, its reference answer
must use LATERAL, and every wrong answer must run and come out different.
"""
import datetime
import importlib.machinery
import importlib.util
import os
import pty
import random
import select
import shutil
import tempfile
import time
import unittest

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin")
os.environ["SRS_HOME"] = tempfile.mkdtemp(prefix="srs-test-")
_loader = importlib.machinery.SourceFileLoader("srs", os.path.join(BIN, "srs"))
_spec = importlib.util.spec_from_loader("srs", _loader)
srs = importlib.util.module_from_spec(_spec)
_loader.exec_module(srs)

SEEDS = range(25)


def type_into_vared(card, typing_gap=0.04):
    """Runs srs-vared on a card's phases and types each phase's route, then
    Return. Returns [(text, keystrokes)] per phase."""
    out = tempfile.NamedTemporaryFile(delete=False)
    out.close()
    args = [os.path.join(BIN, "srs-vared"), out.name]
    for p in card["phases"]:
        args += [str(p["cursor"]), p["text"], ""]
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(args[0], args)

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            if select.select([fd], [], [], 0.02)[0]:
                try:
                    os.read(fd, 65536)
                except OSError:
                    return

    pump(0.4)
    for p in card["phases"]:
        for ch in p["route"] + "\r":
            os.write(fd, ch.encode())
            pump(typing_gap)
        pump(0.15)
    os.waitpid(pid, 0)
    os.close(fd)
    with open(out.name) as f:
        lines = f.read().split("\n")
    os.unlink(out.name)
    return [(lines[i * 3], int(lines[i * 3 + 1])) for i in range(len(card["phases"]))]


class KeysCards(unittest.TestCase):
    def test_par_route_reaches_the_goal_in_par(self):
        for tid, t in srs.KEYS.templates.items():
            gen = t.gen
            for seed in range(6):
                card = gen(random.Random(seed))
                with self.subTest(template=tid, seed=seed):
                    results = type_into_vared(card)
                    for p, (text, keys) in zip(card["phases"], results):
                        self.assertEqual(srs.norm(text), srs.norm(p["goal"]))
                        self.assertEqual(keys, p["par"])

    def test_cursor_starts_inside_the_line(self):
        for tid, t in srs.KEYS.templates.items():
            gen = t.gen
            for seed in SEEDS:
                for p in gen(random.Random(seed))["phases"]:
                    self.assertTrue(0 <= p["cursor"] <= len(p["text"]), (tid, seed))

    def test_the_goal_is_never_already_done(self):
        for tid, t in srs.KEYS.templates.items():
            gen = t.gen
            for seed in SEEDS:
                for p in gen(random.Random(seed))["phases"]:
                    self.assertNotEqual(srs.norm(p["text"]), srs.norm(p["goal"]), (tid, seed))


def type_into_ccprompt(card, editor=None):
    """Runs srs-ccprompt on a card, types each phase's route at a person's
    pace — Esc Esc as two presses, not one burst — then Enter. Returns
    [(text, keystrokes, used)] per phase."""
    import json
    work = tempfile.mkdtemp()
    spec_path, out_path = os.path.join(work, "spec.json"), os.path.join(work, "out.json")
    with open(spec_path, "w") as f:
        json.dump({"phases": [{"text": p["text"]} for p in card["phases"]],
                   "history": card.get("history", []), "undo": card.get("undo", []),
                   "kill": card.get("kill", "")}, f)
    pid, fd = pty.fork()
    if pid == 0:
        if editor:
            os.environ["EDITOR"] = editor
        os.execv(os.path.join(BIN, "srs-ccprompt"), [os.path.join(BIN, "srs-ccprompt"), spec_path, out_path])
    seen = b""

    def pump(seconds, until=None):
        nonlocal seen
        end = time.time() + seconds
        while time.time() < end:
            if until and until in seen:
                return
            if select.select([fd], [], [], 0.02)[0]:
                try:
                    seen += os.read(fd, 65536)
                except OSError:
                    return

    pump(5, until="╭".encode())
    for p in card["phases"]:
        for ch in p["route"]:
            os.write(fd, {"↑": b"\x1b[A"}.get(ch, ch.encode()))
            pump(0.15 if ch == "\x1b" else 0.04)
        pump(0.5 if ch == "\x07" else 0.05)
        os.write(fd, b"\r")
        pump(0.25)
    os.waitpid(pid, 0)
    os.close(fd)
    with open(out_path) as f:
        out = json.load(f)
    shutil.rmtree(work)
    return [(r["text"], r["keys"], r["used"]) for r in out["phases"]]


class ClaudeCodeCards(unittest.TestCase):
    def test_par_route_reaches_the_goal_in_par(self):
        for tid, t in srs.CC.templates.items():
            for seed in range(4):
                card = t.gen(random.Random(seed))
                editor = None
                if tid == "editor":
                    editor = os.path.join(tempfile.mkdtemp(), "add-line")
                    with open(editor, "w") as f:
                        f.write("#!/bin/sh\nprintf '\\n%s\\n' '" + card["phases"][0]["goal"].split("\n")[-1]
                                + "' >> \"$1\"\n")
                    os.chmod(editor, 0o755)
                with self.subTest(template=tid, seed=seed):
                    results = type_into_ccprompt(card, editor)
                    for p, (text, keys, used) in zip(card["phases"], results):
                        self.assertEqual(srs.cc_norm(text), srs.cc_norm(p["goal"]))
                        if p["par"] is None:
                            self.assertIn(p["require"], used)
                        else:
                            self.assertEqual(keys, p["par"])

    def test_the_goal_is_never_already_done(self):
        for tid, t in srs.CC.templates.items():
            for seed in SEEDS:
                for p in t.gen(random.Random(seed))["phases"]:
                    self.assertNotEqual(srs.cc_norm(p["text"]), srs.cc_norm(p["goal"]), (tid, seed))


@unittest.skipUnless(srs.duckdb_path(), "duckdb not installed")
class LateralCards(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_every_wrong_answer_runs_and_misses(self):
        for tid, t in srs.LATERAL.templates.items():
            gen = t.gen
            for seed in SEEDS:
                with self.subTest(template=tid, seed=seed):
                    sc = srs.make_scenario(gen, random.Random(seed), self.dir)
                    self.assertRegex(sc["solution"], r"(?i)\blateral\b")
                    self.assertTrue(sc["expected"])
                    for w in sc["wrong"]:
                        rows, err = srs.duck(sc["db"], w)
                        self.assertIsNone(err, w)
                        self.assertNotEqual(rows, sc["expected"], w)

    def test_scenarios_vary(self):
        for tid, t in srs.LATERAL.templates.items():
            gen = t.gen
            outputs = set()
            for seed in range(8):
                sc = srs.make_scenario(gen, random.Random(seed), self.dir)
                outputs.add(repr(sc["expected"]))
            self.assertGreaterEqual(len(outputs), 7, tid)

    def test_pretty_printing_keeps_the_query_the_same(self):
        for tid, t in srs.LATERAL.templates.items():
            for seed in range(5):
                with self.subTest(template=tid, seed=seed):
                    sc = srs.make_scenario(t.gen, random.Random(seed), self.dir)
                    pretty = srs.pretty_sql(sc["solution"])
                    self.assertGreater(pretty.count("\n"), 2)
                    self.assertEqual("".join(pretty.split()), "".join(sc["solution"].split()))
                    self.assertEqual(srs.duck(sc["db"], pretty)[0], sc["expected"])

    def test_multiple_statements_are_refused(self):
        sc = srs.make_scenario(srs.lateral_ranges, random.Random(1), self.dir)
        rows, err = srs.duck(sc["db"], "SELECT 1; SELECT 2")
        self.assertIsNone(rows)
        self.assertIn("one statement", err)


class Lessons(unittest.TestCase):
    def test_every_card_and_module_has_teaching(self):
        for module_id, module in srs.MODULES.items():
            self.assertTrue(module.primer.strip(), module_id)
            for tid, t in module.templates.items():
                self.assertTrue(t.lesson.strip().startswith("# "), tid)

    def test_a_session_brings_at_most_one_new_card(self):
        state = srs.with_defaults({})
        for module_id, module in srs.MODULES.items():
            for _ in range(10):
                session = srs.choose_session(state, module_id, practice=False, now=1)
                self.assertEqual(len(session), 1, module_id)

    def test_reviews_come_before_new_cards(self):
        state = srs.with_defaults({})
        cards = state["modules"]["keys"]["cards"]
        for tid in ["kill-to-end", "clear-line", "stash"]:
            cards[tid]["seen"] = 1
        session = srs.choose_session(state, "keys", practice=False, now=1)
        self.assertEqual(sorted(session), ["clear-line", "kill-to-end", "stash"])
        cards["stash"]["due"] = 10 ** 12
        session = srs.choose_session(state, "keys", practice=False, now=1)
        self.assertEqual(len(session), 3)
        self.assertEqual(sum(1 for t in session if cards[t]["seen"] == 0), 1)
        self.assertEqual(cards[session[0]]["seen"], 0)


class NextModule(unittest.TestCase):
    def test_offers_the_other_module_with_the_most_due(self):
        state = srs.with_defaults({})
        most = max((m for m in srs.MODULES if m != "keys"), key=lambda m: len(srs.MODULES[m].templates))
        self.assertEqual(srs.next_module(state, "keys", now=1), (most, len(srs.MODULES[most].templates)))

    def test_offers_practice_when_nothing_else_is_due(self):
        state = srs.with_defaults({})
        for m in srs.MODULES:
            if m != "keys":
                for c in state["modules"][m]["cards"].values():
                    c.update(seen=1, box=1, due=10 ** 12)
        offered, due = srs.next_module(state, "keys", now=1)
        self.assertNotEqual(offered, "keys")
        self.assertEqual(due, 0)

    def test_paused_modules_are_not_offered(self):
        state = srs.with_defaults({})
        for m in srs.MODULES:
            if m != "keys":
                state["modules"][m]["active"] = False
        self.assertIsNone(srs.next_module(state, "keys", now=1))


class Scheduling(unittest.TestCase):
    def test_six_perfects_graduate_a_card(self):
        card = srs.new_card()
        now = 1_000_000
        for _ in range(srs.LAST_BOX):
            srs.grade_card(card, "perfect", now)
            self.assertFalse(card["graduated"])
            now = card["due"]
        srs.grade_card(card, "perfect", now)
        self.assertTrue(card["graduated"])

    def test_perfects_climb_from_hours_to_weeks(self):
        card = srs.new_card()
        now = 0
        gaps = []
        for _ in range(srs.LAST_BOX):
            srs.grade_card(card, "perfect", now)
            gaps.append(card["due"] - now)
            now = card["due"]
        self.assertEqual(gaps[0], 3 * srs.HOUR)
        for gap, days in zip(gaps[1:], [1, 3, 7, 14]):
            self.assertAlmostEqual(gap / srs.DAY, days, delta=days * srs.JITTER + 1e-9)

    def test_a_miss_sends_it_back_to_the_start(self):
        card = srs.new_card()
        for _ in range(3):
            srs.grade_card(card, "perfect", 0)
        srs.grade_card(card, "miss", 100)
        self.assertEqual(card["box"], 0)
        self.assertEqual(card["due"], 100 + srs.MISS_RETRY)
        self.assertEqual(card["perfect_run"], 0)

    def test_ok_holds_the_box(self):
        card = srs.new_card()
        srs.grade_card(card, "perfect", 0)
        srs.grade_card(card, "ok", 0)
        self.assertEqual(card["box"], 1)

    def test_streak_counts_consecutive_days(self):
        state = srs.with_defaults({})
        day = 86400
        t = time.mktime(datetime.date(2026, 11, 2).timetuple()) + 12 * 3600
        srs.bump_streak(state, t)
        srs.bump_streak(state, t + 60)
        srs.bump_streak(state, t + day)
        self.assertEqual(srs.current_streak(state, t + day), 2)
        self.assertEqual(srs.current_streak(state, t + 2 * day), 2)  # alive until today ends
        self.assertEqual(srs.current_streak(state, t + 3 * day), 0)
        srs.bump_streak(state, t + 3 * day)
        self.assertEqual(state["streak"]["days"], 1)
        self.assertEqual(state["streak"]["best"], 2)


if __name__ == "__main__":
    unittest.main()
