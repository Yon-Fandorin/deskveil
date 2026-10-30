#!/usr/bin/env python3
"""Isolated socket/protocol tests. Never sign, kill, launch, or update a real app."""
import importlib.util
import itertools
import json
import os
import plistlib
import shutil
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("update_app", ROOT / "Tools/update-app.py")
update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update)


class DeferredUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-update-test-")
        self.addCleanup(self.temporary.cleanup)
        self.job = Path(self.temporary.name)

    def message(self, server, pid, state):
        server.sendall(json.dumps(dict(pid=pid, state=state, reason="input blocking")).encode()+b"\n")

    def test_waiting_does_not_approve_until_owner_sends_ready(self):
        client, server = socket.socketpair()
        self.addCleanup(server.close)
        completed = threading.Event()
        approved = []
        failures = []
        def work():
            try:
                update.wait_for_idle({42:self.job}, "1.2.3", self.job, connector=lambda _:client, on_ready=approved.append)
            except BaseException as error:
                failures.append(error)
            finally:
                completed.set()
        thread = threading.Thread(target=work)
        thread.start()
        self.assertIn(b'"command": "defer"', server.recv(1024))
        self.message(server,42,"waiting")
        self.assertFalse(completed.wait(.1))
        self.assertEqual(approved,[])
        self.message(server,42,"ready")
        self.assertTrue(completed.wait(2))
        thread.join(2)
        self.assertEqual(failures,[])
        self.assertEqual(approved,[42])
        self.assertIn(b'"commit"',server.recv(1024))

    def test_all_peers_prepare_before_any_commit_is_sent(self):
        pairs={pid:socket.socketpair() for pid in (42,43)}
        for _, server in pairs.values(): self.addCleanup(server.close)
        failures=[]
        approved=[]
        def work():
            try:
                update.wait_for_idle({pid:self.job for pid in pairs},"1.2.3",self.job,
                    connector=lambda pid:pairs[pid][0],on_ready=approved.append)
            except BaseException as error: failures.append(error)
        thread=threading.Thread(target=work)
        thread.start()
        for _, server in pairs.values(): server.recv(1024)
        self.message(pairs[42][1],42,"ready")
        self.message(pairs[43][1],43,"waiting")
        self.message(pairs[43][1],43,"ready")
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures,[])
        self.assertCountEqual(approved,[42,43])
        for _,server in pairs.values(): self.assertIn(b'"commit"',server.recv(1024))

    def test_disconnect_without_ready_never_authorizes_publication(self):
        client, server=socket.socketpair()
        server.close()
        approved=[]
        with self.assertRaises((update.UpdateError,BrokenPipeError)):
            update.wait_for_idle({42:self.job},"1.2.3",self.job,connector=lambda _:client,on_ready=approved.append)
        self.assertEqual(approved,[])

    def test_ready_peer_lease_is_renewed_while_another_peer_remains_blocked(self):
        pairs={pid:socket.socketpair() for pid in (42,43)}
        for _,server in pairs.values(): self.addCleanup(server.close)
        failures=[]
        approved=[]
        def work():
            try:
                update.wait_for_idle({pid:self.job for pid in pairs},'1.2.3',self.job,
                    connector=lambda pid:pairs[pid][0],on_ready=approved.append,renewal_interval=.02)
            except BaseException as error: failures.append(error)
        thread=threading.Thread(target=work)
        thread.start()
        for _,server in pairs.values(): server.recv(1024)
        first=pairs[42][1]
        first.settimeout(.15)  # A short fixture lease; owner has a 30-second lease.
        self.message(first,42,'ready')
        self.message(pairs[43][1],43,'waiting')
        renewals=0
        try:
            deadline=time.monotonic()+.4
            while time.monotonic()<deadline:
                data=first.recv(1024)
                self.assertNotIn(b'commit',data)
                renewals+=data.count(b'renew')
            self.assertGreater(renewals,1)
            self.assertEqual(approved,[])
            self.message(pairs[43][1],43,'ready')
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(failures,[])
            self.assertCountEqual(approved,[42,43])
        finally:
            (self.job/'cancel').touch()
            thread.join(2)

    def test_cancel_pending_request_never_authorizes_publication(self):
        client, server=socket.socketpair()
        self.addCleanup(server.close)
        (self.job/'cancel').touch()
        approved=[]
        with self.assertRaisesRegex(update.UpdateError,'cancelled'):
            update.wait_for_idle({42:self.job},"1.2.3",self.job,connector=lambda _:client,on_ready=approved.append)
        self.assertEqual(approved,[])
        self.assertEqual(server.recv(2048).count(b'defer'),1)
        self.assertEqual(server.recv(2048),b'')

    def test_precommit_verification_keeps_ready_lease_alive(self):
        client,server=socket.socketpair()
        self.addCleanup(server.close)
        server.settimeout(.15)
        errors=[]
        renewals=[]
        def owner():
            try:
                server.recv(1024)
                self.message(server,42,'ready')
                buffer=b''
                while True:
                    buffer+=server.recv(1024)
                    while b'\n' in buffer:
                        line,buffer=buffer.split(b'\n',1)
                        command=json.loads(line)['command']
                        if command=='commit': return
                        renewals.append(command)
            except BaseException as error: errors.append(error)
        thread=threading.Thread(target=owner)
        thread.start()
        try:
            update.wait_for_idle({42:self.job},'1.2.3',self.job,connector=lambda _:client,
                before_commit=lambda:time.sleep(.4),renewal_interval=.02)
        finally: thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors,[])
        self.assertGreater(len(renewals),1)
        self.assertEqual(set(renewals),{'renew'})

    def test_legacy_running_app_is_never_forced_to_quit(self):
        with patch.object(update.subprocess,'run') as run:
            with self.assertRaisesRegex(update.UpdateError,'left untouched'):
                update.wait_for_idle({42:self.job},"1.2.3",self.job,connector=lambda _:None)
            run.assert_not_called()

    def test_ready_response_pid_must_match_authenticated_peer(self):
        client,server=socket.socketpair()
        self.addCleanup(server.close)
        self.message(server,999,"ready")
        with self.assertRaisesRegex(update.UpdateError,'PID differs'):
            update.wait_for_idle({42:self.job},"1.2.3",self.job,connector=lambda _:client)

    def test_still_running_after_ready_is_not_replaced_or_terminated(self):
        target=self.job/'SoftLock.app'
        candidate={'version':'1.2.3'}
        (self.job/'plan.json').write_text(json.dumps(dict(targets=[str(target)],candidate=candidate)))
        def ready(processes,version,job,on_ready,before_commit):
            before_commit(); on_ready(42)
        with patch.object(update,'inspect_release',return_value=(candidate,{str(target):{}})), \
             patch.object(update,'live_processes',return_value={42:target}), \
             patch.object(update,'wait_for_idle',side_effect=ready), \
             patch.object(update,'acquire_build_lock') as build_lock, \
             patch.object(update.time,'monotonic',side_effect=itertools.count(0,16)), \
             patch.object(update.guard,'publish_app') as publish, \
             patch.object(update.subprocess,'run') as run:
            with self.assertRaisesRegex(update.UpdateError,'exit not confirmed'):
                update.apply(self.job)
            publish.assert_not_called()
            run.assert_not_called()

    def test_partial_commit_failure_waits_for_exiting_owner_then_relaunches(self):
        target=self.job/'Installed.app'
        candidate={'version':'1.2.3'}
        previous={'version':'1.2.2'}
        (self.job/'plan.json').write_text(json.dumps(dict(targets=[str(target)],candidate=candidate)))
        def partial(processes,version,job,on_ready,before_commit):
            before_commit()
            on_ready(42)  # This owner was committed; the next peer's send fails.
            raise BrokenPipeError('another peer disconnected during commit')
        with patch.object(update,'inspect_release',return_value=(candidate,{str(target):previous})), \
             patch.object(update,'live_processes',side_effect=[{42:target},{42:target},{}]), \
             patch.object(update,'wait_for_idle',side_effect=partial), \
             patch.object(update,'acquire_build_lock'), \
             patch.object(update.guard,'inspect_bundle',return_value=previous), \
             patch.object(update.guard,'publish_app') as publish, \
             patch.object(update.time,'sleep'), \
             patch.object(update.subprocess,'run') as run:
            with self.assertRaises(BrokenPipeError): update.apply(self.job)
            publish.assert_not_called()
            run.assert_called_once_with(['/usr/bin/open','-g','-n',str(target)],check=True)

    def test_cancel_after_prepare_before_commit_does_not_authorize_exit(self):
        client,server=socket.socketpair()
        self.addCleanup(server.close)
        self.message(server,42,'ready')
        approved=[]
        def cancel(): (self.job/'cancel').touch()
        with self.assertRaisesRegex(update.UpdateError,'cancelled'):
            update.wait_for_idle({42:self.job},'1.2.3',self.job,connector=lambda _:client,
                on_ready=approved.append,before_commit=cancel)
        self.assertEqual(approved,[])
        data=server.recv(2048)
        self.assertNotIn(b'commit',data)

    def test_cancel_while_waiting_for_build_lock_is_observed(self):
        (self.job/'.build').mkdir()
        with patch.object(update,'ROOT',self.job), \
             patch.object(update.fcntl,'flock',side_effect=BlockingIOError), \
             patch.object(update.time,'sleep',side_effect=lambda _: (self.job/'cancel').touch()):
            with self.assertRaisesRegex(update.UpdateError,'cancelled'):
                update.acquire_build_lock(self.job)

    def fake_app(self, path, payload):
        (path/'Contents/MacOS').mkdir(parents=True)
        (path/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundlePackageType='APPL',
            CFBundleIdentifier='dev.local.softlock',CFBundleExecutable='SoftLock')))
        (path/'Contents/MacOS/SoftLock').write_text('fixture; never execute')
        os.chmod(path/'Contents/MacOS/SoftLock',0o755)
        (path/'payload').write_text(payload)

    def test_committed_copy_rolls_back_to_verified_backup(self):
        target=self.job/'Installed.app'
        self.fake_app(target,'new')
        self.fake_app(self.job/'backup-0.app','old')
        inspect=lambda p:{'value':(Path(p)/'payload').read_text()}
        with patch.object(update,'live_processes',return_value={}), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect):
            errors=update.rollback([target],[target],{str(target):{'value':'old'}},{'value':'new'},self.job)
        self.assertEqual(errors,[])
        self.assertEqual((target/'payload').read_text(),'old')
        self.assertEqual((self.job/'backup-0.app/payload').read_text(),'old')

    def test_rollback_preserves_foreign_changes_and_original_archive(self):
        target=self.job/'Installed.app'
        self.fake_app(target,'foreign')
        self.fake_app(self.job/'backup-0.app','old')
        inspect=lambda p:{'value':(Path(p)/'payload').read_text()}
        with patch.object(update,'live_processes',return_value={}), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect):
            errors=update.rollback([target],[target],{str(target):{'value':'old'}},{'value':'new'},self.job)
        self.assertEqual(len(errors),1)
        self.assertEqual((target/'payload').read_text(),'foreign')
        self.assertEqual((self.job/'backup-0.app/payload').read_text(),'old')

    def test_rollback_rejects_destination_replaced_during_archive_copy(self):
        target=self.job/'Installed.app'
        self.fake_app(target,'new')
        self.fake_app(self.job/'backup-0.app','old')
        inspect=lambda p:{'value':(Path(p)/'payload').read_text()}
        original=shutil.copytree
        def copy(source,destination,*args,**kwargs):
            result=original(source,destination,*args,**kwargs)
            if Path(destination).name=='restore.app': (target/'payload').write_text('foreign')
            return result
        with patch.object(update,'live_processes',return_value={}), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect), \
             patch.object(update.shutil,'copytree',side_effect=copy):
            errors=update.rollback([target],[target],{str(target):{'value':'old'}},{'value':'new'},self.job)
        self.assertEqual(len(errors),1)
        self.assertEqual((target/'payload').read_text(),'foreign')

    def test_worker_retains_detailed_rollback_failure_record(self):
        value=dict(state='failed',reason='publication failed',rollbackErrors=['destination changed'])
        (self.job/'status.json').write_text(json.dumps(value))
        update.record_worker_failure(self.job,update.UpdateError('wrapper error'))
        self.assertEqual(json.loads((self.job/'status.json').read_text()),value)

    def publication_fixture(self):
        target=self.job/'Installed.app'
        self.fake_app(target,'old')
        self.fake_app(self.job/'candidate.app','new')
        (self.job/'.build').mkdir()
        inspect=lambda p:{'value':(Path(p)/'payload').read_text(),'version':'1.2.3'}
        candidate=inspect(self.job/'candidate.app')
        (self.job/'plan.json').write_text(json.dumps(dict(targets=[str(target)],candidate=candidate)))
        def release(source,targets,expected=None):
            value=inspect(source)
            if expected is not None: self.assertEqual(value,expected)
            return value,{str(t):inspect(t) if t.exists() else None for t in targets}
        return target,inspect,release

    def test_failure_after_publication_rename_is_included_in_rollback(self):
        target,inspect,release=self.publication_fixture()
        original=shutil.rmtree
        failed=[]
        def cleanup(path,*args,**kwargs):
            if Path(path).name=='previous.app' and not failed:
                failed.append(True)
                raise OSError('fixture backup cleanup failed after commit')
            return original(path,*args,**kwargs)
        with patch.object(update,'ROOT',self.job), \
             patch.object(update,'live_processes',return_value={}), \
             patch.object(update,'inspect_release',side_effect=release), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect), \
             patch.object(update.shutil,'rmtree',side_effect=cleanup):
            with self.assertRaisesRegex(OSError,'after commit'): update.apply(self.job)
        self.assertEqual((target/'payload').read_text(),'old')
        self.assertEqual(json.loads((self.job/'status.json').read_text())['rollbackErrors'],[])

    def test_cancel_during_staging_is_checked_before_any_publication(self):
        target,inspect,release=self.publication_fixture()
        original=shutil.copytree
        def copy(source,destination,*args,**kwargs):
            result=original(source,destination,*args,**kwargs)
            if Path(destination).name=='next.app': (self.job/'cancel').touch()
            return result
        with patch.object(update,'ROOT',self.job), \
             patch.object(update,'live_processes',return_value={}), \
             patch.object(update,'inspect_release',side_effect=release), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect), \
             patch.object(update.shutil,'copytree',side_effect=copy), \
             patch.object(update.guard,'publish_app') as publish:
            with self.assertRaisesRegex(update.UpdateError,'cancelled'): update.apply(self.job)
            publish.assert_not_called()
        self.assertEqual((target/'payload').read_text(),'old')

    def test_second_destination_failure_restores_first_destination(self):
        first,inspect,release=self.publication_fixture()
        second=self.job/'Second.app'
        self.fake_app(second,'old')
        plan=json.loads((self.job/'plan.json').read_text())
        plan['targets']=[str(first),str(second)]
        (self.job/'plan.json').write_text(json.dumps(plan))
        original=update.guard.publish_app
        def publish(source,target,stamp,backup):
            if target==second: raise OSError('fixture second destination failed')
            return original(source,target,stamp,backup)
        with patch.object(update,'ROOT',self.job), \
             patch.object(update,'live_processes',return_value={}), \
             patch.object(update,'inspect_release',side_effect=release), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect), \
             patch.object(update.guard,'publish_app',side_effect=publish):
            with self.assertRaisesRegex(OSError,'second destination'): update.apply(self.job)
        self.assertEqual((first/'payload').read_text(),'old')
        self.assertEqual((second/'payload').read_text(),'old')
        self.assertEqual(json.loads((self.job/'status.json').read_text())['rollbackErrors'],[])

    def brand_transition(self, fail=False):
        original, inspect, release = self.publication_fixture()
        legacy = original.with_name('SoftLock.app')
        original.rename(legacy)
        renamed = original.with_name('DeskVeil.app')
        (self.job/'plan.json').write_text(json.dumps(dict(
            targets=[str(renamed),str(legacy)], candidate=inspect(self.job/'candidate.app'))))
        def ready(processes, version, job, on_ready, before_commit):
            self.assertEqual(processes, {42:legacy})
            before_commit(); on_ready(42)
        publish = update.guard.publish_app
        def publish_or_fail(source, target, stamp, backup):
            if fail and target == legacy: raise OSError('brand transition interrupted')
            return publish(source,target,stamp,backup)
        with patch.object(update,'ROOT',self.job), \
             patch.object(update,'live_processes',side_effect=lambda _: {42:legacy} if live.call_count == 1 else {}) as live, \
             patch.object(update,'wait_for_idle',side_effect=ready), \
             patch.object(update,'inspect_release',side_effect=release), \
             patch.object(update.guard,'inspect_bundle',side_effect=inspect), \
             patch.object(update.guard,'publish_app',side_effect=publish_or_fail), \
             patch.object(update.subprocess,'run') as run:
            if fail:
                with self.assertRaisesRegex(OSError,'brand transition interrupted'): update.apply(self.job)
                self.assertFalse(renamed.exists())
                self.assertEqual((legacy/'payload').read_text(),'old')
            else:
                update.apply(self.job)
                self.assertEqual((renamed/'payload').read_text(),'new')
                self.assertEqual((legacy/'payload').read_text(),'new')
            run.assert_called_once_with(['/usr/bin/open','-g','-n',str(legacy if fail else renamed)],check=True)

    def test_brand_transition_relaunches_new_name_after_old_owner_approves(self):
        self.brand_transition()

    def test_brand_transition_failure_restores_and_reopens_legacy_app(self):
        self.brand_transition(fail=True)


if __name__=='__main__': unittest.main()
