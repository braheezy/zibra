"""Batch discovery, durable collection, and GNU Parallel integration checks."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import batch


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.browser = self.root / 'browser'
        self.browser.write_text('fixture')
        self.run = self.root / 'run'
        self.cases = [batch.runner.Case(path=f'css/{i}.html', mode='testharness', reason='fixture')
                      for i in range(5)]

    def test_invalid_jobs_fail_before_build_or_run_creation(self):
        for action in (['start', '--build', '--fresh', '--results', str(self.run)],
                       ['run', str(self.run)]):
            for value in ('8re', '0', '-1', '1.5', '100%', '1_000', ''):
                with self.subTest(action=action[0], jobs=value), \
                     patch.object(batch, 'automatic') as automatic, \
                     patch.object(batch, 'execute') as execute, \
                     contextlib.redirect_stderr(io.StringIO()) as error:
                    with self.assertRaises(SystemExit) as stopped:
                        batch.main([*action, '--jobs', value])
                    self.assertEqual(2, stopped.exception.code)
                    self.assertIn('positive whole-number worker count', error.getvalue())
                    automatic.assert_not_called()
                    execute.assert_not_called()
                    self.assertFalse(self.run.exists())

    def test_start_accepts_default_and_explicit_worker_counts(self):
        for options, expected in (([], 8), (['--jobs', '12'], 12)):
            with patch.object(batch, 'automatic', return_value=0) as automatic:
                self.assertEqual(0, batch.main(['start', *options]))
                self.assertEqual(expected, automatic.call_args.args[0].jobs)

    def test_progress_tails_new_lines_without_replaying_saved_output(self):
        log = self.run / 'results/1/0/stderr'
        log.parent.mkdir(parents=True)
        log.write_text('[1/25] old progress\n')
        output = io.StringIO()
        progress = batch.BatchProgress(self.run, output)
        progress.update()
        self.assertEqual('', output.getvalue())
        with log.open('ab') as f:
            f.write('[2/25] PASS caf'.encode() + b'\xc3')
        progress.update()
        self.assertEqual('', output.getvalue())
        with log.open('ab') as f:
            f.write(b'\xa9.html\n')
        progress.update()
        self.assertEqual('[batch 1] [2/25] PASS café.html\n', output.getvalue())
        progress.update()
        self.assertEqual(1, len(output.getvalue().splitlines()))
        log.write_text('WPT all: 25 cases\n')
        progress.update()
        self.assertIn('[batch 1] WPT all: 25 cases', output.getvalue())

    @unittest.skipUnless(shutil.which('parallel'), 'GNU Parallel is not installed')
    def test_detached_parallel_progress_arrives_before_job_finishes(self):
        import subprocess
        import time
        gate = self.root / 'release'
        script = self.root / 'worker.py'
        script.write_text("import sys,time,pathlib\n"
                          "print('[1/25] PASS live', file=sys.stderr, flush=True)\n"
                          "while not pathlib.Path(sys.argv[1]).exists(): time.sleep(.01)\n")
        output = io.StringIO()
        progress = batch.BatchProgress(self.run, output)
        process = subprocess.Popen(['parallel', '--plain', '--jobs', '1', '--results',
                                    str(self.run / 'results'), sys.executable, str(script), str(gate), ':::', '0'],
                                   start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not output.getvalue() and time.monotonic() < deadline:
                progress.update()
                time.sleep(.01)
            self.assertIn('[batch 1] [1/25] PASS live', output.getvalue())
            self.assertIsNone(process.poll())
        finally:
            gate.touch()
            _, stderr = process.communicate(timeout=5)
        self.assertEqual(0, process.returncode)
        self.assertNotIn(b'/dev/tty', stderr)

    def prepare(self):
        with patch.object(batch.runner, 'discover_wpt_inventory', return_value=[]), \
             patch.object(batch.runner, 'load_cases', return_value=list(reversed(self.cases))):
            self.assertEqual(batch.main(['prepare', str(self.run), '--size', '2',
                                         '--browser', str(self.browser)]), 0)
        return json.loads((self.run / 'plan.json').read_text())

    def save_result(self, index, cases, status='FAIL'):
        path = self.run / 'results' / '1' / str(index) / 'stdout'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            'batch': index, 'plan_sha256': batch.digest(self.run / 'plan.json'),
            'complete': True, 'tests': [dict(c, status=status, ok=status == 'PASS') for c in cases]}))
        return path

    def test_discovery_partitions_once_and_refuses_overwrite(self):
        plan = self.prepare()
        self.assertEqual([len(b) for b in plan['batches']], [2, 2, 1])
        self.assertEqual([c['path'] for b in plan['batches'] for c in b],
                         [c.path for c in self.cases])
        with self.assertRaises(FileExistsError):
            with patch.object(batch.runner, 'discover_wpt_inventory', return_value=[]), \
                 patch.object(batch.runner, 'load_cases', return_value=self.cases):
                batch.prepare(type('Args', (), dict(size=2, all=False, mode='all',
                    manifest=Path('x'), directory=[], browser=str(self.browser),
                    directory_path=self.run))())

    def test_partial_collection_and_failures_are_completed_work(self):
        plan = self.prepare()
        self.save_result(0, plan['batches'][0])
        self.assertFalse(batch.collect(self.run))
        for i in (1, 2):
            self.save_result(i, plan['batches'][i])
        self.assertTrue(batch.collect(self.run))
        report = json.loads((self.run.parent / (self.run.name + '.json')).read_text())
        self.assertEqual(report['summary']['fail'], 5)
        self.assertTrue(report['complete'])

    def test_truncated_and_foreign_results(self):
        plan = self.prepare()
        path = self.save_result(0, plan['batches'][0])
        path.write_text('{')
        self.assertFalse(batch.collect(self.run))
        self.save_result(0, plan['batches'][0])
        data = json.loads(path.read_text()); data['plan_sha256'] = 'wrong'
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'foreign'):
            batch.collect(self.run)

    def test_worker_rejects_changed_browser(self):
        self.prepare()
        self.browser.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'browser differs'):
            batch.worker(self.run / 'plan.json', 0)

    def test_worker_transports_failures_without_failing_scheduler_job(self):
        self.prepare()
        def fake_main(argv):
            report = Path(argv[argv.index('--report') + 1])
            report.write_text(json.dumps({'complete': True, 'tests': [{}, {}], 'summary': {'fail': 2}}))
            print('progress must go to stderr')
            return 0
        out = io.StringIO()
        with patch.object(batch.runner, 'main', side_effect=fake_main), contextlib.redirect_stdout(out):
            self.assertEqual(batch.worker(self.run / 'plan.json', 0), 0)
        self.assertEqual(json.loads(out.getvalue())['summary']['fail'], 2)

    def automatic_command(self, *extra):
        manifest = self.root / 'manifest.yaml'
        if not manifest.exists():
            manifest.write_text('tests: []\n')
        return ['start', '--results', str(self.root / 'automatic'),
                '--manifest', str(manifest), '--browser', str(self.browser), *extra]

    def test_automatic_start_resume_fresh_and_completed_run(self):
        with patch.object(batch.runner, 'discover_wpt_inventory', return_value=[]), \
             patch.object(batch.runner, 'load_cases', return_value=self.cases), \
             patch.object(batch, 'checkout_stamp', return_value='checkout'), \
             patch.object(batch.shutil, 'which', return_value='/fixture/parallel'), \
             patch.object(batch, 'execute', return_value=0) as execute:
            self.assertEqual(batch.main(self.automatic_command()), 0)
            first = execute.call_args.args[0].directory_path
            (first / 'joblog.tsv').write_text('fixture')
            self.assertEqual(batch.main(self.automatic_command()), 0)
            self.assertEqual(execute.call_args.args[0].directory_path, first)
            self.assertTrue(execute.call_args.args[0].resume)
            self.assertEqual(batch.main(self.automatic_command('--fresh')), 0)
            second = execute.call_args.args[0].directory_path
            self.assertNotEqual(first, second)
            self.assertTrue((first / 'plan.json').exists())
            (second.parent / (second.name + '.json')).write_text('{"complete":true}')
            self.assertEqual(batch.main(self.automatic_command()), 0)
            self.assertNotEqual(execute.call_args.args[0].directory_path, second)

    def test_automatic_changed_inputs_refuse_resume_before_dispatch(self):
        with patch.object(batch.runner, 'discover_wpt_inventory', return_value=[]), \
             patch.object(batch.runner, 'load_cases', return_value=self.cases), \
             patch.object(batch, 'checkout_stamp', return_value='checkout') as stamp, \
             patch.object(batch.shutil, 'which', return_value='/fixture/parallel'), \
             patch.object(batch, 'execute', return_value=0) as execute:
            self.assertEqual(batch.main(self.automatic_command()), 0)
            self.browser.write_text('different')
            self.assertEqual(batch.main(self.automatic_command()), 2)
            self.browser.write_text('fixture')
            stamp.return_value = 'changed-checkout'
            self.assertEqual(batch.main(self.automatic_command()), 2)
            self.assertEqual(execute.call_count, 1)

    @unittest.skipUnless(shutil.which('parallel') and shutil.which('task'), 'GNU Parallel and Task required')
    def test_task_terminal_interrupt_finishes_active_job(self):
        import subprocess
        import signal
        import time
        import shlex
        self.prepare()
        child = self.root / 'child.py'
        child.write_text("import sys,time\nfrom pathlib import Path\n"
                         "p=Path(sys.argv[1]); p.with_suffix('.started').touch()\n"
                         "time.sleep(0.8); p.with_suffix('.finished').touch()\n")
        command = ['parallel', '--plain', '--jobs', '1',
                   shlex.join([sys.executable, str(child)]) + ' {}', ':::',
                   str(self.root / 'first'), str(self.root / 'second')]
        harness = self.root / 'harness.py'
        harness.write_text(
            "import sys\nfrom pathlib import Path\nfrom types import SimpleNamespace\n"
            f"sys.path.insert(0, {str(Path(batch.__file__).parent.resolve())!r})\n"
            "import batch\noriginal=batch.subprocess.Popen\n"
            f"batch.subprocess.Popen=lambda command, **kw: original({command!r}, **kw)\n"
            f"batch.collect=lambda directory: Path({str(self.root / 'collected')!r}).touch()\n"
            f"sys.exit(batch.execute(SimpleNamespace(directory_path=Path({str(self.run)!r}), "
            "jobs=1, resume=False, sshlogin=None, workdir=None)))\n")
        taskfile = self.root / 'Taskfile.yml'
        taskfile.write_text('version: "3"\ntasks:\n  wpt:\n    cmds:\n      - ' +
                            json.dumps(shlex.join([sys.executable, str(harness)])) + '\n')
        with (self.root / 'task.log').open('w') as log:
            process = subprocess.Popen(['task', '--taskfile', str(taskfile), 'wpt'],
                                       start_new_session=True, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 8
                while not (self.root / 'first.started').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((self.root / 'first.started').exists())
                os.killpg(process.pid, signal.SIGINT)
                process.wait(timeout=8)
                self.assertTrue((self.root / 'first.finished').exists())
                self.assertTrue((self.root / 'collected').exists())
                self.assertFalse((self.root / 'second.started').exists())
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_ctrl_c_drains_an_isolated_worker_and_collects(self):
        import signal
        from types import SimpleNamespace
        self.prepare()
        observed = {}
        class Process:
            def poll(self):
                return None
            def send_signal(self, sig):
                observed['signal'] = sig
            def wait(self, timeout=None):
                signal.raise_signal(signal.SIGINT)
                signal.raise_signal(signal.SIGINT)
                return 0
        with patch.object(batch.shutil, 'which', return_value='/fixture/parallel'), \
             patch.object(batch.subprocess, 'Popen', return_value=Process()) as popen, \
             patch.object(batch, 'collect', return_value=False) as collect:
            self.assertEqual(batch.execute(SimpleNamespace(directory_path=self.run, jobs=1,
                             resume=False, sshlogin=None, workdir=None)), 0)
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual(observed['signal'], signal.SIGHUP)
            collect.assert_called_once_with(self.run)

    @unittest.skipUnless(shutil.which('parallel'), 'GNU Parallel is not installed')
    def test_end_to_end_collection_and_resume(self):
        self.cases = [batch.runner.Case(path='css/zibra-nonexistent-batch-fixture.html',
                                        mode='testharness', reason='missing source fixture')]
        self.prepare()
        self.assertEqual(batch.main(['run', str(self.run), '--jobs', '1']), 0)
        report = json.loads((self.run.parent / (self.run.name + '.json')).read_text())
        self.assertTrue(report['complete'])
        self.assertEqual(report['summary']['infra'], 1)
        result = self.run / 'results/1/0/stdout'
        modified = result.stat().st_mtime_ns
        self.assertEqual(batch.main(['run', str(self.run), '--jobs', '1', '--resume']), 0)
        self.assertEqual(result.stat().st_mtime_ns, modified)

    @unittest.skipUnless(shutil.which('parallel'), 'GNU Parallel is not installed')
    def test_real_parallel_drains_and_resumes_pending_batches(self):
        import subprocess
        import time
        import signal
        import shlex
        script = self.root / 'job.py'
        script.write_text("import sys,time\nfrom pathlib import Path\n"
                          "p=Path(sys.argv[1]); p.write_text('started'); time.sleep(0.3)\n")
        command = ['parallel', '--plain', '--jobs', '1', '--joblog', str(self.root / 'log'),
                   shlex.join([sys.executable, str(script)]) + ' {}', ':::',
                   *[str(self.root / f'job-{i}') for i in range(3)]]
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'job-0').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / 'job-0').exists())
            process.send_signal(signal.SIGHUP)
            process.wait(timeout=5)
            self.assertFalse((self.root / 'job-1').exists())
            before = (self.root / 'job-0').stat().st_mtime_ns
            subprocess.run(command[:1] + ['--resume-failed'] + command[1:],
                           check=True, capture_output=True, timeout=5)
            self.assertTrue((self.root / 'job-2').exists())
            self.assertEqual((self.root / 'job-0').stat().st_mtime_ns, before)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()

    @unittest.skipUnless(shutil.which('parallel'), 'GNU Parallel is not installed')
    def test_real_parallel_resume_does_not_repeat_completed_batches(self):
        # Use the real scheduler and output layout, without browser/server work.
        import subprocess
        output = self.root / 'results'
        log = self.root / 'joblog'
        command = ['parallel', '--plain', '--jobs', '1', '--joblog', str(log),
                   '--results', str(output), 'echo {}', ':::', '0', '1']
        subprocess.run(command, check=True, capture_output=True)
        before = (output / '1/0/stdout').stat().st_mtime_ns
        subprocess.run(command[:1] + ['--resume-failed'] + command[1:], check=True, capture_output=True)
        self.assertEqual((output / '1/0/stdout').stat().st_mtime_ns, before)
        self.assertEqual((output / '1/1/stdout').read_text().strip(), '1')


if __name__ == '__main__':
    unittest.main()
