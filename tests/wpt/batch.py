#!/usr/bin/env python3
"""Discover immutable WPT batches and delegate scheduling to GNU Parallel."""
from __future__ import annotations

import argparse
import contextlib
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import fcntl
import json
import os
from pathlib import Path
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile

import run as runner


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prepare(args):
    if args.size < 1:
        raise ValueError('batch size must be positive')
    inventory = runner.discover_wpt_inventory()
    cases = (runner._cases_from_inventory(inventory, mode=args.mode) if args.all
             else runner.load_cases(args.manifest, inventory=inventory))
    directories = [runner._normalize_directory(d) for d in args.directory]
    cases = [c for c in cases if runner._mode_matches(c.mode, args.mode) and
             (not directories or any(runner._path_in_directory(
                 runner._case_scope_path(c), d) for d in directories))]
    if not cases:
        raise ValueError('selection contains no cases')
    # Sorting freezes joblog sequence numbers independently of discovery order.
    cases.sort(key=lambda c: (c.mode, c.path))
    plan = {
        'coverage': [asdict(c) for c in runner._cases_from_inventory(inventory, mode=args.mode)]
                    if getattr(args, 'full_suite', False) else None,
        'version': 1, 'started_at': datetime.now(timezone.utc).isoformat(),
        'browser': args.browser, 'browser_sha256': digest(args.browser),
        'manifest': str(args.manifest), 'mode': args.mode,
        'adapter_sha256': {str(p): digest(p) for p in sorted(Path('tests/wpt').glob('*.py'))},
        'source_sha256': {runner._case_scope_path(c): digest(runner.UPSTREAM / runner._case_scope_path(c))
                          for c in cases if (runner.UPSTREAM / runner._case_scope_path(c)).is_file()},
        'batches': [[asdict(c) for c in cases[i:i + args.size]]
                    for i in range(0, len(cases), args.size)],
    }
    args.directory_path.mkdir(parents=True, exist_ok=False)
    (args.directory_path / 'plan.json').write_text(json.dumps(plan) + '\n')
    print(f"Prepared {len(cases)} cases in {len(plan['batches'])} batches")


def worker(plan_path, index):
    plan = json.loads(plan_path.read_text())
    if digest(plan['browser']) != plan['browser_sha256']:
        raise ValueError('browser differs from the prepared run; prepare a new run')
    cases = plan['batches'][index]
    for path, expected in plan['adapter_sha256'].items():
        if digest(path) != expected:
            raise ValueError(f'runner changed since preparation: {path}')
    for case in cases:
        source = case.get('source_path') or case['path']
        expected = plan['source_sha256'].get(source)
        if expected and digest(runner.UPSTREAM / source) != expected:
            raise ValueError(f'WPT source changed since preparation: {source}')
    with tempfile.TemporaryDirectory(prefix='zibra-wpt-batch-') as temporary:
        manifest = Path(temporary) / 'manifest.json'
        report = Path(temporary) / 'report.json'
        manifest.write_text(json.dumps({'version': 1, 'tests': cases}))
        # stdout is the transport for the report, including over SSH.
        with contextlib.redirect_stdout(sys.stderr):
            code = runner.main([str(manifest), '--mode', plan['mode'], '--jobs', '1',
                                '--checkpoint-every', '0', '--report', str(report),
                                '--browser', plan['browser']])
        if code or not report.exists():
            return code or 1
        result = json.loads(report.read_text())
        if not result.get('complete') or len(result.get('tests', [])) != len(cases):
            return 1
        result['batch'] = index
        result['plan_sha256'] = digest(plan_path)
        print(json.dumps(result))
    return 0


def collect(directory):
    plan_path = directory / 'plan.json'
    plan = json.loads(plan_path.read_text())
    results = []
    plan_hash = digest(plan_path)
    finished = 0
    for index, batch in enumerate(plan['batches']):
        path = directory / 'results' / '1' / str(index) / 'stdout'
        if not path.exists():
            continue
        try:
            report = json.loads(path.read_text())
        except (ValueError, OSError):
            continue  # Interrupted stdout is not a completed batch.
        if report.get('plan_sha256') != plan_hash or report.get('batch') != index:
            raise ValueError(f'foreign batch result: {path}')
        items = report['tests']
        expected = {(c['mode'], c['path']) for c in batch}
        if (not report.get('complete') or len(items) != len(batch) or
                {(c['mode'], c['path']) for c in items} != expected):
            continue
        by_key = {(c['mode'], c['path']): runner.Case(**c) for c in batch}
        for item in items:
            results.append(runner.CaseResult(
                case=by_key[(item['mode'], item['path'])], status=item['status'],
                ok=item['ok'], record=item,
                infrastructure_error=item.get('infrastructure_error'),
                diagnostics=item.get('diagnostics'), stdout=item.get('stdout', ''),
                stderr=item.get('stderr', '')))
        finished += 1
    all_cases = [runner.Case(**c) for batch in plan['batches'] for c in batch]
    coverage = [runner.Case(**c) for c in plan['coverage']] if plan.get('coverage') is not None else all_cases
    report_path = directory.parent / (directory.name + '.json')
    runner.write_run_report(
        report_path, manifest=Path(plan['manifest']), mode=plan['mode'],
        browser=[plan['browser']], started_at=datetime.fromisoformat(plan['started_at']),
        finished_at=datetime.now(timezone.utc), results=results,
        complete=finished == len(plan['batches']), expected_cases=len(all_cases),
        coverage_cases=coverage, suite='all' if plan.get('coverage') is not None else 'focused')
    print(f"Collected {finished}/{len(plan['batches'])} batches into {report_path}")
    return finished == len(plan['batches'])


def execute(args):
    if not shutil.which('parallel'):
        raise ValueError('GNU Parallel is required (macOS: brew install parallel)')
    plan_path = args.directory_path / 'plan.json'
    plan = json.loads(plan_path.read_text())
    command = ['parallel', '--plain', '--jobs', str(args.jobs),
               '--joblog', str(args.directory_path / 'joblog.tsv'),
               '--results', str(args.directory_path / 'results')]
    if args.resume:
        command.append('--resume-failed')
    elif (args.directory_path / 'joblog.tsv').exists():
        raise ValueError('run already started; use --resume')
    if args.sshlogin:
        if not args.workdir or plan_path.is_absolute() or Path(plan['browser']).is_absolute():
            raise ValueError('SSH requires --workdir and repository-relative run and browser paths')
        command += ['--sshlogin', args.sshlogin, '--workdir', args.workdir,
                    '--basefile', str(plan_path)]
    worker_command = shlex.join(['python3', 'tests/wpt/batch.py', 'worker',
                                 str(args.directory_path)]) + ' {}'
    command += [worker_command, ':::', *map(str, range(len(plan['batches'])))]
    # Isolate workers from terminal Ctrl+C; only the coordinator handles it.
    process = None
    paused = False

    def pause(signum, frame):
        nonlocal paused
        if not paused:
            paused = True
            print('Pausing: finishing active batches and saving progress. Run task wpt to continue.', flush=True)
            if process is not None and process.poll() is None:
                process.send_signal(signal.SIGHUP)

    previous = {sig: signal.signal(sig, pause) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, start_new_session=True)
        if paused:
            process.send_signal(signal.SIGHUP)
        print('Running WPT. Press Ctrl+C to pause.', flush=True)
        code = process.wait()
        complete = collect(args.directory_path)
        return 0 if paused else code or (0 if complete else 1)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def checkout_stamp():
    """Detect checkout additions and resource edits without rereading every asset."""
    stamp = hashlib.sha256()
    for root, directories, files in os.walk(runner.UPSTREAM):
        directories[:] = sorted(d for d in directories if d not in
                                ('.git', '_venv3', '__pycache__', '.pytest_cache'))
        for name in sorted(files):
            if name.endswith('.pyc'):
                continue
            path = Path(root) / name
            stat = path.stat()
            stamp.update(f'{path.relative_to(runner.UPSTREAM)}:{stat.st_size}:{stat.st_mtime_ns}\n'.encode())
    return stamp.hexdigest()


def automatic(args):
    """Own the current-run pointer; preserve older reports and paused runs."""
    args.results.mkdir(parents=True, exist_ok=True)
    with (args.results / '.wpt.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('WPT is already running')
        if not shutil.which('parallel'):
            raise ValueError('GNU Parallel is required (macOS: brew install parallel)')
        if args.build:
            subprocess.run(['zig', 'build', '-Doptimize=ReleaseSafe', '-j1'], check=True)
        pointer = args.results / '.wpt-current'
        directory = args.results / pointer.read_text().strip() if pointer.exists() else None
        if directory is not None:
            report = directory.parent / (directory.name + '.json')
            if report.exists() and json.loads(report.read_text()).get('complete'):
                directory = None
        identity = {
            'browser': digest(args.browser), 'manifest': digest(args.manifest),
            'checkout': checkout_stamp(),
            'adapters': {str(p): digest(p) for p in sorted(Path('tests/wpt').glob('*.py'))},
        }
        if directory is not None and not args.fresh:
            saved = json.loads((directory / 'identity.json').read_text())
            if saved != identity:
                raise ValueError('Browser, tests, or runner changed. This run cannot resume; use task wpt-fresh. Previous results are preserved.')
            print('Resuming unfinished WPT run.', flush=True)
        else:
            directory = args.results / datetime.now(timezone.utc).strftime('wpt-%Y%m%dT%H%M%S.%fZ')
            prepare(argparse.Namespace(directory_path=directory, size=25, all=False,
                                      mode='all', manifest=args.manifest, directory=[],
                                      browser=args.browser, full_suite=True))
            (directory / 'identity.json').write_text(json.dumps(identity))
            temporary = pointer.with_suffix('.tmp')
            temporary.write_text(directory.name)
            temporary.replace(pointer)
        options = argparse.Namespace(directory_path=directory, jobs=args.jobs,
                                     resume=(directory / 'joblog.tsv').exists(),
                                     sshlogin=args.sshlogin, workdir=args.workdir)
        with (directory / 'coordinator.lock').open('a') as run_lock:
            try:
                fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('this run already has an active coordinator')
            return execute(options)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    start_parser = sub.add_parser('start')
    start_parser.add_argument('--results', type=Path, default=Path('tests/wpt/results'))
    start_parser.add_argument('--manifest', type=Path, default=runner.DEFAULT_MANIFEST)
    start_parser.add_argument('--browser', default='./zig-out/bin/zibra')
    start_parser.add_argument('--jobs', default='8')
    start_parser.add_argument('--fresh', action='store_true')
    start_parser.add_argument('--build', action='store_true')
    start_parser.add_argument('--sshlogin')
    start_parser.add_argument('--workdir')
    prepare_parser = sub.add_parser('prepare')
    prepare_parser.add_argument('directory_path', type=Path)
    prepare_parser.add_argument('--manifest', type=Path, default=runner.DEFAULT_MANIFEST)
    prepare_parser.add_argument('--all', action='store_true')
    prepare_parser.add_argument('--full-suite', action='store_true')
    prepare_parser.add_argument('--directory', action='append', default=[])
    prepare_parser.add_argument('--mode', choices=('all', *runner.CONFORMANCE_MODES), default='all')
    prepare_parser.add_argument('--size', type=int, default=25)
    prepare_parser.add_argument('--browser', default='./zig-out/bin/zibra')
    execute_parser = sub.add_parser('run')
    execute_parser.add_argument('directory_path', type=Path)
    execute_parser.add_argument('--jobs', default='8')
    execute_parser.add_argument('--resume', action='store_true')
    execute_parser.add_argument('--sshlogin')
    execute_parser.add_argument('--workdir')
    worker_parser = sub.add_parser('worker')
    worker_parser.add_argument('directory_path', type=Path)
    worker_parser.add_argument('index', type=int)
    sub.add_parser('collect').add_argument('directory_path', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == 'start':
            return automatic(args)
        if args.action == 'prepare':
            prepare(args)
            return 0
        if args.action == 'worker':
            return worker(args.directory_path / 'plan.json', args.index)
        if args.action == 'collect':
            return 0 if collect(args.directory_path) else 1
        with (args.directory_path / 'coordinator.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('this run already has an active coordinator')
            return execute(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'WPT batches: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
