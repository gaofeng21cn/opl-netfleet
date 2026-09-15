#!/usr/bin/env python3
"""Run SDK APK publication tools on Linux or a local Docker host.

Set NETFLEET_SDK to the prepared SDK. Supports verify, mkndx and adbdump;
absolute file paths preserve their meaning inside the container.
"""
import os
from pathlib import Path
import platform
import subprocess
import sys


def command(arguments):
    if not arguments or arguments[0] not in ('verify', 'mkndx', 'adbdump'):
        raise ValueError('expected verify, mkndx or adbdump')
    configured = os.environ.get('NETFLEET_SDK')
    if not configured:
        raise ValueError('set NETFLEET_SDK to the prepared SDK')
    sdk = Path(configured).resolve()
    apk = sdk / 'staging_dir/host/bin/apk'
    if not apk.is_file():
        raise ValueError('SDK host APK is unavailable')
    if platform.system() == 'Linux' and platform.machine() in ('x86_64', 'AMD64'):
        return [str(apk), *arguments]
    mounts = {str(sdk): 'ro'}
    normalized = list(arguments)
    for index, value in enumerate(arguments):
        previous = arguments[index - 1] if index else None
        path_argument = previous in ('--output', '--keys-dir', '--sign')
        if not path_argument and not value.startswith('/') and not Path(value).is_file():
            continue
        path = Path(value).absolute()
        parent = path if path.is_dir() else path.parent
        if not parent.is_dir():
            raise ValueError('APK path parent unavailable')
        normalized[index] = str(path)
        key = str(parent)
        mounts[key] = 'rw' if previous == '--output' or mounts.get(key) == 'rw' else 'ro'
    result = ['docker', 'run', '--rm', '--pull=never', '--platform', 'linux/amd64', '--user', '0:0']
    for path, mode in mounts.items():
        result += ['-v', f'{path}:{path}:{mode}']
    result += [os.environ.get('NETFLEET_SDK_IMAGE', 'opl-netfleet-openwrt-sdk-builder:latest'),
               str(apk), *normalized]
    return result


if __name__ == '__main__':
    try:
        sys.exit(subprocess.run(command(sys.argv[1:])).returncode)
    except (ValueError, OSError) as error:
        sys.exit(f'openwrt-apk: {error}')
