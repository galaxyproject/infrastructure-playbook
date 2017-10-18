"""Extract and relay messages from the systemd journal
"""
from __future__ import print_function

import argparse
import errno
import datetime
import json
import os
import os.path
import re
#import select
import smtplib
import sys
from email.mime.text import MIMEText
from socket import gethostname

from systemd import journal
from systemd.id128 import get_boot


MUTEX = os.path.expanduser(os.path.join('~', '.journal-notify.lock'))
OOM_MESSAGE_START = re.compile('^.* invoked oom-killer: .*$')
OOM_MESSAGE_END = re.compile('^Killed process .*')


class timedelta(datetime.timedelta):
    # there's a bug in systemd.journal that attempts to access this method
    def totalseconds(self):
        return self.total_seconds()


def _exit(msg, *args, **kwargs):
    ec = kwargs.pop('ec', 1)
    print(msg.format(*args, **kwargs), file=sys.stderr)
    sys.exit(ec)


class LockFile(object):
    def __init__(self):
        self.__fname = MUTEX
        self.__fd = None

    def __open(self, flags, ignore=None, callback=None):
        try:
            return os.open(self.__fname, flags)
        except (IOError, OSError) as exc:
            if exc.errno not in ignore or ():
                _exit('Unable to acquire lock {}: {}', self.__fname, str(exc))
            if callback:
                return callback()
            return -1

    def __acquire(self, first_attempt=True):
        kwargs = {}
        if first_attempt:
            kwargs.update({'ignore': (errno.EEXIST,), 'callback': self.__handle_stale})
        self.__fd = self.__open(os.O_WRONLY | os.O_CREAT | os.O_EXCL, **kwargs)
        return self.__fd

    def __handle_stale(self):
        fd = self.__open(os.O_RDONLY, (errno.ENOENT,), lambda: self.__acquire(False))
        if self.__fd is not None:
            # second self.__acquire succeeded
            return self.__fd
        pid = os.read(fd, 5)
        try:
            assert not os.read(fd, 1), 'Contains extra data'
            pid = int(pid)
        except Exception as exc:
            _exit('Lockfile {} contents malformed: {}', self.__fname, str(exc))
        try:
            os.kill(pid, 0)
        except OSError:
            print('Removing stale lock file: {}'.format(self.__fname), file=sys.stderr)
            os.unlink(self.__fname)
            return self.__acquire(False)
        else:
            _exit('Process is still running: {}', pid)


    def __enter__(self):
        self.__acquire()
        os.write(self.__fd, str(os.getpid()))
        os.fsync(self.__fd)
        os.lseek(self.__fd, 0, 0)

    def __exit__(self, exc_type, exc_val, traceback):
        os.close(self.__fd)
        os.unlink(self.__fname)


class JournalReader(object):
    def __init__(self, **kwargs):
        self._state = None
        self._process = kwargs.get('process', True)
        self._mails = kwargs.get('mails', True)
        self._multiline_match = False
        self._reader = journal.Reader()
        for match in kwargs.get('matches', []):
            self.add_match(match)
        if kwargs.get('dmesg', False):
            self.dmesg()
        if kwargs.get('oom', False):
            self.dmesg()
            self.add_multiline_match(OOM_MESSAGE_START, OOM_MESSAGE_END)
        self._load_state()

    @property
    def _state_file(self):
        return os.path.expanduser(os.path.join('~', '.journal-notify.state'))

    def _load_state(self):
        try:
            with open(self._state_file, 'r') as fh:
                self._state = json.load(fh)
        except (IOError, OSError) as exc:
            if exc.errno == errno.ENOENT:
                self._state = {}
            else:
                raise

    def _dump_state(self):
        with open(self._state_file, 'w') as fh:
            json.dump(self._state, fh)

    def dmesg(self):
        self._reader.this_boot()
        self.add_match('_TRANSPORT=kernel')

    def add_match(self, match):
        self._reader.add_match(match)

    def add_multiline_match(self, start_msg, end_msg):
        self._multiline_match = True
        self._match_start = start_msg
        self._match_end = end_msg

    def _next_multiline_match(self):
        match = []
        for event in self._reader:
            if not match and re.match(self._match_start, event['MESSAGE']):
                match.append(event)
            elif match and re.match(self._match_end, event['MESSAGE']):
                match.append(event)
                yield match
                match = []
            elif match:
                match.append(event)

    def _last_monotonic(self, boot_id=None):
        if not boot_id:
            boot_id = get_boot()
        return timedelta(0, self._state.get(str(boot_id), 0))

    def get_matching_events(self, boot_id=None):
        r = []
        if not boot_id:
            boot_id = get_boot()
        last_monotonic = self._last_monotonic()
        self._reader.seek_monotonic(last_monotonic)
        if self._multiline_match:
            for match in self._next_multiline_match():
                last_monotonic = match[-1]['__MONOTONIC_TIMESTAMP'][0]
                r.append(match)
        if self._process:
            self._state[str(boot_id)] = last_monotonic.total_seconds()
        self._dump_state()
        return r

    def output_matching_events(self, boot_id=None):
        parts = []
        for event in self.get_matching_events(boot_id=boot_id):
            parts.append('>>> at {}:\n{}\n'.format(str(event[0]['__REALTIME_TIMESTAMP']), '\n'.join([e['MESSAGE'] for e in event])))
        if not parts:
            return
        if self._mails:
            msg = MIMEText('\n'.join(parts))
            msg['Subject'] = '{}: found {} matching journal events since last run'.format(gethostname(), len(parts))
            msg['To'] = ', '.join(self._mails)
            msg['From'] = 'root@{}'.format(gethostname())
            s = smtplib.SMTP('localhost')
            s.sendmail(msg['From'], self._mails, msg.as_string())
        else:
            [print(part) for part in parts]


def parse_arguments():
    parser = argparse.ArgumentParser(description="Watch systemd journal")
    parser.add_argument('--dmesg', action='store_true', help='journalctl -k/--dmesg')
    parser.add_argument('--oom', action='store_true', help='locate OOM Killer messages (implies --dmesg)')
    parser.add_argument('--match', action='append', dest='matches', default=[], help='Match on FIELD=value')
    parser.add_argument('--no-process', action='store_false', dest='process', default=True, help='Do not process messages and move pointer')
    parser.add_argument('--mail', action='append', dest='mails', default=[], help='Send mail to address')
    return parser.parse_args()


def reader_kwargs(args):
    return vars(args)


def main():
    args = parse_arguments()
    kwargs = reader_kwargs(args)
    with LockFile():
        reader = JournalReader(**kwargs)
        reader.output_matching_events()


if __name__ == '__main__':
    main()
