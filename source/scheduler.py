#!/usr/bin/env python3
"""Phone-local hourly GET scheduler. It never handles vehicle commands or UI receipts."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

BASE = Path('/data/adb/bmw-reareye-async-v3')
INTERVAL = 30
WORKER_TIMEOUT = 120  # Allow bounded local authorization sync before the read-only GET.
HISTORY_LIMIT = 128
CLOCK_RE = re.compile(r'(\d{4}-\d{2}-\d{2}) (\d{2}) (\d{2}) ([+-]\d{4})')
SLOT_RE = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}[+-]\d{4}')


@dataclass(frozen=True)
class LocalClock:
    day: str
    hour: int
    minute: int
    offset: str

    @property
    def minute_key(self):
        return f'{self.day}T{self.hour:02}:{self.minute:02}{self.offset}'

    @property
    def slot(self):
        return f'{self.day}T{self.hour:02}{self.offset}'


def parse_clock(text):
    match = CLOCK_RE.fullmatch(text.strip())
    if not match:
        raise ValueError('invalid phone clock')
    day, hour, minute, offset = match.groups()
    date.fromisoformat(day)
    hour, minute = int(hour), int(minute)
    if hour > 23 or minute > 59 or int(offset[1:3]) > 23 or int(offset[3:]) > 59:
        raise ValueError('invalid phone clock')
    return LocalClock(day, hour, minute, offset)


def phone_clock():
    # Android's date uses the phone timezone, irrespective of the Python process TZ.
    env = dict(os.environ)
    env.pop('TZ', None)
    result = subprocess.run(['/system/bin/date', '+%Y-%m-%d %H %M %z'],
        capture_output=True, text=True, timeout=3, check=True, env=env)
    return parse_clock(result.stdout)


class SlotPolicy:
    """No startup/catch-up refresh; one attempt per observed eligible local hour."""
    def __init__(self, slots=()):
        self.startup_minute = None
        self.slots = list(dict.fromkeys(slot for slot in slots
            if isinstance(slot, str) and SLOT_RE.fullmatch(slot)))[-HISTORY_LIMIT:]

    def due(self, clock):
        if self.startup_minute is None:
            self.startup_minute = clock.minute_key
            return None
        if clock.minute_key == self.startup_minute:
            return None
        if clock.minute != 0 or 2 <= clock.hour < 8 or clock.slot in self.slots:
            return None
        return clock.slot

    def mark(self, slot):
        if slot not in self.slots:
            self.slots.append(slot)
            self.slots = self.slots[-HISTORY_LIMIT:]


def read_json(path):
    try:
        if path.stat().st_size > 32768:
            return {}
        obj = json.loads(path.read_text())
        return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, obj):
    temp = path.with_name(path.name + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(obj, stream, ensure_ascii=True, separators=(',', ':'))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def version():
    try:
        value = (BASE / 'version').read_text()[:128].strip()
        return value if re.fullmatch(r'[a-f0-9]{64}', value) else 'unknown'
    except OSError:
        return 'unknown'


def worker_busy():
    with open(BASE / 'job.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(lock, fcntl.LOCK_UN)
        return False


def stop_child(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=2)


def start_worker():
    # Inherit the launcher-provided Termux HOME/PREFIX/PATH/library environment.
    # telemetry is GET-only, takes no nonce, and does not modify command receipts.
    return subprocess.Popen([sys.executable, str(BASE / 'worker.py'), 'telemetry'],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        close_fds=True)


def acquire_singleton(lock):
    for attempt in range(26):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            # updates_on may race the previous owner's final STOPPED write and
            # lock release. Wait briefly for that handoff rather than losing the
            # only restarted process. Ordinary active owners return immediately.
            previous = read_json(BASE / 'scheduler.json')
            if (previous.get('phase') != 'STOPPED' or
                    (BASE / 'scheduler.stop').exists() or attempt == 25):
                return False
            time.sleep(0.2)
    return False


def run():
    os.umask(0o077)
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(BASE / 'scheduler.lock', 'a') as lock:
        if not acquire_singleton(lock):
            return 0
        saved = read_json(BASE / 'scheduler_slots.json')
        policy = SlotPolicy(saved.get('slots', []) if isinstance(saved.get('slots', []), list) else [])
        loaded_version = version()
        state = {'phase': 'STARTING', 'started_at': time.time(), 'version': loaded_version,
            'last_slot': policy.slots[-1] if policy.slots else None, 'last_result': None}
        child = None
        deadline = None
        try:
            while True:
                now, monotonic = time.time(), time.monotonic()
                state['alive_at'] = now
                state['updated_at'] = now
                if (BASE / 'scheduler.stop').exists():
                    stop_child(child)
                    child, deadline = None, None
                    state['phase'] = 'STOPPED'
                    write_json(BASE / 'scheduler.json', state)
                    if (BASE / 'scheduler.stop').exists():
                        return 0
                    # Resumed before this owner released its lock. Keep the
                    # process alive, but suppress the resumed startup minute.
                    policy = SlotPolicy(policy.slots)
                    continue
                if version() != loaded_version:
                    stop_child(child)
                    child = None
                    state['phase'] = 'RESTARTING'
                    write_json(BASE / 'scheduler.json', state)
                    # Python's lock FD is close-on-exec; the new process reacquires it.
                    os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve())])
                if child is not None:
                    result = child.poll()
                    if result is not None:
                        state.update(last_result='EXIT_' + str(result), last_finished_at=now)
                        child, deadline = None, None
                    elif monotonic >= deadline:
                        stop_child(child)
                        child, deadline = None, None
                        state.update(last_result='TIMEOUT', last_finished_at=now)
                try:
                    clock = phone_clock()
                    state.update(local_minute=clock.minute_key, phase='RUNNING' if child else 'WAITING')
                    slot = policy.due(clock)
                    if slot is not None:
                        # Persist before launch/lock check: busy or failed slots are not retried.
                        policy.mark(slot)
                        write_json(BASE / 'scheduler_slots.json', {'slots': policy.slots,
                            'last_slot': slot, 'attempted_at': now})
                        state.update(last_slot=slot, last_attempt_at=now)
                        if child is not None or worker_busy():
                            state['last_result'] = 'BUSY_SKIPPED'
                        else:
                            child = start_worker()
                            deadline = time.monotonic() + WORKER_TIMEOUT
                            state.update(phase='RUNNING', last_result='STARTED')
                except (OSError, ValueError, subprocess.SubprocessError):
                    state['phase'] = 'CLOCK_OR_START_ERROR'
                write_json(BASE / 'scheduler.json', state)
                remaining_tick = max(0.1, INTERVAL - (time.monotonic() - monotonic))
                delay = remaining_tick if deadline is None else min(remaining_tick, max(0.1, deadline - time.monotonic()))
                time.sleep(delay)
        finally:
            stop_child(child)


if __name__ == '__main__':
    try:
        raise SystemExit(run())
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit(2)
