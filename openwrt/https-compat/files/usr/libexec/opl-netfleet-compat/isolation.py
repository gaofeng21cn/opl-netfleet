"""Least-privilege engine launch; the controller retains all network writes."""
import ctypes
import grp
import os
from pathlib import Path
import pwd
import resource
import stat

ACCOUNT = "netfleet-compat"
CGROUP = Path("/sys/fs/cgroup/netfleet-compat")
BUDGETS = {"memory.max": str(192 * 1024 * 1024), "memory.swap.max": "0",
           "memory.oom.group": "1", "pids.max": "32", "cpu.max": "50000 100000"}


def account():
    user, group = pwd.getpwnam(ACCOUNT), grp.getgrnam(ACCOUNT)
    if (user.pw_uid == 0 or group.gr_gid == 0 or user.pw_gid != group.gr_gid
            or any(item.pw_uid == user.pw_uid and item.pw_name != ACCOUNT for item in pwd.getpwall())
            or any(item.gr_gid == group.gr_gid and item.gr_name != ACCOUNT for item in grp.getgrall())):
        raise ValueError("engine_identity_invalid")
    return user.pw_uid, group.gr_gid


def prepare(base, run):
    _, gid = account()
    projected = run / "ca"
    projected.mkdir(mode=0o750, exist_ok=True)
    for path in (projected, run):
        if path.is_symlink() or not path.is_dir() or path.stat().st_uid != 0:
            raise ValueError("engine_directory_unsafe")
        os.chown(path, 0, gid)
        os.chmod(path, 0o750)
    for path in (base / "ca").iterdir():
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode) or path.stat().st_uid != 0:
            raise ValueError("engine_ca_unsafe")
        target = projected / path.name
        if target.is_symlink():
            raise ValueError("engine_ca_unsafe")
        if not target.exists() or target.read_bytes() != path.read_bytes():
            temporary = target.with_suffix(".new")
            with temporary.open("wb") as stream:
                os.fchmod(stream.fileno(), 0o640)
                os.fchown(stream.fileno(), 0, gid)
                stream.write(path.read_bytes())
            temporary.replace(target)
        os.chown(target, 0, gid)
        os.chmod(target, 0o640)
    effective = run / "effective.json"
    if effective.is_symlink() or effective.stat().st_uid != 0:
        raise ValueError("engine_config_unsafe")
    os.chown(effective, 0, gid)
    os.chmod(effective, 0o640)
    engine = run / "engine"
    if engine.is_symlink():
        raise ValueError("engine_directory_unsafe")
    engine.mkdir(mode=0o700, exist_ok=True)
    os.chown(engine, *account())
    os.chmod(engine, 0o700)


def constrain():
    root = CGROUP.parent
    required = {"memory", "cpu", "pids"}
    if not required <= set((root / "cgroup.controllers").read_text().split()):
        raise ValueError("engine_resource_isolation_unavailable")
    missing = required - set((root / "cgroup.subtree_control").read_text().split())
    if missing:
        (root / "cgroup.subtree_control").write_text(" ".join("+" + name for name in sorted(missing)))
    if CGROUP.is_symlink():
        raise ValueError("engine_cgroup_unsafe")
    CGROUP.mkdir(exist_ok=True)
    os.chmod(CGROUP, 0o755)
    if (CGROUP / "cgroup.procs").read_text().strip():
        raise ValueError("engine_already_running")
    for name, value in BUDGETS.items():
        path = CGROUP / name
        path.write_text(value)
        if path.read_text().strip() != value:
            raise ValueError("engine_resource_limit_failed")
    (CGROUP / "cgroup.procs").write_text(str(os.getpid()))
    resource.setrlimit(resource.RLIMIT_NOFILE, (512, 512))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024 * 1024, 8 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    uid, gid = account()
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
    if ctypes.CDLL(None, use_errno=True).prctl(38, 1, 0, 0, 0) != 0:
        raise OSError("engine_no_new_privileges_failed")
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"


def status():
    try:
        values = {name: (CGROUP / name).read_text().strip() for name in BUDGETS}
        return {"supported": True, "enforced": values == BUDGETS, "limits": values}
    except OSError:
        return {"supported": False, "enforced": False}
