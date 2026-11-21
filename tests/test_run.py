"""Exercise launcher interruption without booting a VM: python3 -m unittest discover -s tests."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ['TEST_ROOT'])
command = Path(sys.argv[0]).name
if command == 'qemu-img':
    if sys.argv[1] == 'info':
        print('{"format":"qcow2"}')
    else:
        Path(sys.argv[-1]).touch()
elif command == 'jq':
    sys.stdin.read()
    print('qcow2')
elif command == 'qemu-system-x86_64':
    if os.environ['TEST_CASE'] == 'forced':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    serial = sys.argv[sys.argv.index('-serial') + 1]
    Path(serial.removeprefix('file:')).write_text('test console\n')
    (root / 'qemu.pid').write_text(str(os.getpid()))
    if os.environ['TEST_CASE'] == 'startup':
        os.kill(os.getppid(), signal.SIGINT)
    if os.environ['TEST_CASE'] == 'collision':
        time.sleep(0.15)
        sys.exit(1)
    while True:
        time.sleep(1)
elif command == 'ss':
    pid_file = root / 'qemu.pid'
    if os.environ['TEST_CASE'] in ('startup', 'collision'):
        print('users:(("qemu",pid=1,fd=5))')
    elif pid_file.exists():
        print(f'users:(("qemu",pid={pid_file.read_text()},fd=5))')
elif command == 'ssh':
    if sys.argv[-1] == 'sudo systemctl poweroff':
        (root / 'shutdown').touch()
        if os.environ['TEST_CASE'] == 'forced':
            sys.exit(1)
        time.sleep(0.3)
        os.kill(int((root / 'qemu.pid').read_text()), signal.SIGTERM)
    else:
        (root / 'probe').touch()
        time.sleep(0.1)
        sys.exit(1)
'''


class RunInterruptionTests(unittest.TestCase):
    def wait_for(self, predicate, process):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            if process.poll() is not None:
                self.fail('launcher exited before reaching the expected startup stage')
            time.sleep(0.01)
        self.fail('launcher did not reach the expected startup stage')

    def interrupt(self, case):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            images = root / 'images'
            bin_dir.mkdir()
            images.mkdir()
            for name in ('arch-agent-base.qcow2', 'workspace.qcow2', 'agent-ssh-key'):
                (images / name).touch()
            for name in ('qemu-img', 'qemu-system-x86_64', 'jq', 'ssh', 'ss'):
                path = bin_dir / name
                path.write_text(MOCK)
                path.chmod(0o755)
            # Shorten shutdown polling without changing launcher timeout logic.
            (bin_dir / 'sleep').write_text('#!/bin/sh\nexec /usr/bin/sleep 0.01\n')
            (bin_dir / 'sleep').chmod(0o755)
            env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                       ARCH_AGENT_IMAGE_DIR=str(images), ARCH_AGENT_LOG_DIR=str(root / 'logs'),
                       TMPDIR=str(root), TEST_ROOT=str(root), TEST_CASE=case)
            process = subprocess.Popen(['bash', str(REPO / 'run.sh')], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                self.wait_for(lambda: (root / 'qemu.pid').exists(), process)
                if case in ('repeated', 'forced'):
                    self.wait_for(lambda: (root / 'probe').exists(), process)
                    # Model Ctrl+C from the terminal, which signals the whole group.
                    os.killpg(process.pid, signal.SIGINT)
                if case in ('repeated', 'forced'):
                    self.wait_for(lambda: (root / 'shutdown').exists(), process)
                if case == 'repeated':
                    os.killpg(process.pid, signal.SIGINT)
                    time.sleep(0.05)
                    os.killpg(process.pid, signal.SIGINT)
                output, _ = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 1 if case == 'collision' else 130, output.decode())
                if case in ('startup', 'collision'):
                    self.assertFalse((root / 'shutdown').exists())
                    self.assertFalse((root / 'probe').exists())
                pid = int((root / 'qemu.pid').read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                with (images / 'workspace.lock').open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertTrue((images / 'workspace.qcow2').exists())
                self.assertFalse(list(root.glob('arch-agent-vm.*')))
                self.assertEqual(len(list((root / 'logs').glob('run-*.log'))), 1)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
                if (root / 'qemu.pid').exists():
                    try:
                        os.kill(int((root / 'qemu.pid').read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_interrupt_at_qemu_startup(self):
        self.interrupt('startup')

    def test_port_owned_by_another_vm(self):
        self.interrupt('collision')

    def test_repeated_ctrl_c_during_cleanup(self):
        self.interrupt('repeated')

    def test_unresponsive_vm_is_killed_and_reaped(self):
        self.interrupt('forced')


if __name__ == '__main__':
    unittest.main()
