#!/usr/bin/env python3
"""
Run an application N times per build configuration with TSan reporting enabled
and collect the reports for the P2 (benchmark-level preservation) experiment.

Unlike the benchmark scripts (which all set TSAN_OPTIONS=report_bugs=0), every
run here uses
    TSAN_OPTIONS="log_path=<out>/logs/<app>.<cfg>.<run> exitcode=0 [external_symbolizer_path=...]"
so TSan writes one file per process, <app>.<cfg>.<run>.<pid>, that
tsan_reports.py can aggregate.  Workloads reproduce the paper's benchmark
scripts (see the per-app adapters below); --scale smoke shrinks them for
plumbing checks.

Examples
  ./run_preservation.py --app sqlite --configs tsan,tsan-sound,tsan-dom_peeling-ea-lo-st-swmr --runs 10
  ./run_preservation.py --app memcached --configs tsan,tsan-sound,tsan-all --runs 10
  ./run_preservation.py --app redis --configs tsan,ea-lo-st-swmr,dom_peeling-ea-lo-st-swmr --runs 10
  ./run_preservation.py --app ffmpeg --configs tsan,tsan-sound,tsan-dom_peeling-ea-lo-st-swmr --runs 10
  ./run_preservation.py --app mysql --configs tsan,tsan-sound,tsan-dompeeling-ea-lo-st-swmr --runs 10 --mysql-seconds 60
then
  ./tsan_reports.py aggregate --results-dir <out>/logs --baseline tsan

Every invocation writes <out>/manifest.json (compiler tree/branch/HEAD, binary
hashes, workload parameters) and <out>/runs.jsonl (one line per executed step).
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

HERE = Path(__file__).resolve().parent
EXP_ROOT = HERE.parent.parent                      # ~/tsan-experiments
DEFAULT_LLVM_ROOT = Path("/home/alexey/dev/llvm-project-focs-lab/llvm/build")


def now() -> str:
    return dt.datetime.now().isoformat(timespec="seconds")


def elf_compilers(path: Path) -> List[str]:
    """Distinct 'clang version ...' / 'GCC: ...' strings from the ELF .comment section."""
    try:
        r = subprocess.run(["readelf", "-p", ".comment", str(path)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    for line in r.stdout.splitlines():
        if "]" in line:
            txt = line.split("]", 1)[1].strip()
            if txt and txt not in out:
                out.append(txt)
    return out


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sh(cmd: List[str], cwd: Optional[Path] = None, timeout: int = 60) -> str:
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception as e:  # noqa: BLE001
        return f"<error: {e}>"


# --------------------------------------------------------------------------- #
# Run context
# --------------------------------------------------------------------------- #

class Ctx:
    def __init__(self, args):
        self.args = args
        self.app = args.app
        self.scale = args.scale
        self.dry = args.dry_run
        self.build_root = Path(args.build_root).resolve() if args.build_root else None  # runs use a per-run cwd
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        # absolute: log_path is handed to processes that run in a scratch cwd which is deleted afterwards
        self.out = Path(args.out).resolve() if args.out else HERE / "results" / args.app / stamp
        self.logs = self.out / "logs"
        self.stdio = self.out / "stdio"
        self.work = Path(args.workdir) if args.workdir else Path("/dev/shm") / f"preservation-{args.app}"
        for d in (self.logs, self.stdio, self.work):
            d.mkdir(parents=True, exist_ok=True)
        self.runs_log = open(self.out / "runs.jsonl", "a")
        # Deliberately NOT taken from $LLVM_ROOT_PATH: ~/.bashrc points it at ~/dev/llvm-project, which
        # is now a symlink to the unrelated llvm-capstone tree.
        self.llvm_root = Path(args.llvm_root)
        env_root = os.environ.get("LLVM_ROOT_PATH")
        if env_root and Path(env_root).resolve() != self.llvm_root.resolve():
            print(f"[warn] $LLVM_ROOT_PATH={env_root} differs from --llvm-root={self.llvm_root}; "
                  f"the manifest describes the latter", file=sys.stderr)
        self.symbolizer = args.symbolizer or str(self.llvm_root / "bin" / "llvm-symbolizer")
        if not Path(self.symbolizer).is_file():
            print(f"[warn] symbolizer {self.symbolizer} not found; TSan will use llvm-symbolizer from PATH", file=sys.stderr)
            self.symbolizer = None

    # TSan environment for the instrumented process of (cfg, run).
    def tsan_env(self, cfg: str, run: int, extra: str = "") -> Dict[str, str]:
        env = dict(os.environ)
        opts = [f"log_path={self.logs / f'{self.app}.{cfg}.{run}'}", "exitcode=0"]
        if self.symbolizer:
            opts.append(f"external_symbolizer_path={self.symbolizer}")
        if self.args.tsan_options:
            opts.append(self.args.tsan_options)
        if extra:
            opts.append(extra)
        env["TSAN_OPTIONS"] = " ".join(opts)
        return env

    # Plain environment for helper processes (clients/benchmark drivers).
    @staticmethod
    def plain_env(**kw) -> Dict[str, str]:
        env = dict(os.environ)
        env["TSAN_OPTIONS"] = "report_bugs=0"   # for instrumented clients (mysql, mysqladmin)
        env.update(kw)
        return env

    def log_step(self, **rec):
        rec.setdefault("ts", now())
        self.runs_log.write(json.dumps(rec) + "\n")
        self.runs_log.flush()

    def stdio_paths(self, cfg: str, run: int, tag: str):
        base = self.stdio / f"{self.app}.{cfg}.{run}.{tag}"
        return open(f"{base}.out", "ab"), open(f"{base}.err", "ab")

    # -- process helpers ---------------------------------------------------- #
    def run_cmd(self, cmd: List[str], *, cfg: str, run: int, tag: str, cwd: Optional[Path] = None,
                env: Optional[Dict[str, str]] = None, timeout: int = 7200) -> int:
        print(f"[{now()}] {self.app}/{cfg}/run{run}/{tag}: {' '.join(shlex.quote(c) for c in cmd)}"
              + (f"  (cwd={cwd})" if cwd else ""))
        if self.dry:
            return 0
        out, err = self.stdio_paths(cfg, run, tag)
        t0 = time.time()
        try:
            p = subprocess.run(cmd, cwd=cwd, env=env, stdout=out, stderr=err, timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = -999
            print(f"  !! timeout after {timeout}s", file=sys.stderr)
        finally:
            out.close()
            err.close()
        self.log_step(cfg=cfg, run=run, step=tag, cmd=cmd, cwd=str(cwd) if cwd else None,
                      rc=rc, seconds=round(time.time() - t0, 1))
        if rc != 0:
            print(f"  -> rc={rc}", file=sys.stderr)
        return rc

    def start_server(self, cmd: List[str], *, cfg: str, run: int, tag: str, cwd: Optional[Path],
                     env: Dict[str, str]) -> Optional[subprocess.Popen]:
        print(f"[{now()}] {self.app}/{cfg}/run{run}/{tag}: START {' '.join(shlex.quote(c) for c in cmd)}"
              + (f"  (cwd={cwd})" if cwd else ""))
        if self.dry:
            return None
        out, err = self.stdio_paths(cfg, run, tag)
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=out, stderr=err, start_new_session=True)
        p._t0 = time.time()  # type: ignore[attr-defined]
        p._logs = (out, err)  # type: ignore[attr-defined]  (closed in stop_server)
        self.log_step(cfg=cfg, run=run, step=f"{tag}:start", cmd=cmd, cwd=str(cwd) if cwd else None, pid=p.pid)
        return p

    def stop_server(self, p: Optional[subprocess.Popen], *, cfg: str, run: int, tag: str,
                    grace: int = 300, sig=signal.SIGTERM, pre_stop=None) -> Optional[int]:
        if p is None:
            return None
        rc = None
        try:
            if pre_stop is not None:
                pre_stop()
            if p.poll() is None:
                os.killpg(p.pid, sig)
            try:
                rc = p.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                print(f"  !! {tag} did not exit within {grace}s after {sig.name}; SIGKILL", file=sys.stderr)
                os.killpg(p.pid, signal.SIGKILL)
                rc = p.wait(timeout=60)
        finally:
            for f in getattr(p, "_logs", ()):
                f.close()
        self.log_step(cfg=cfg, run=run, step=f"{tag}:stop", pid=p.pid, rc=rc,
                      seconds=round(time.time() - getattr(p, "_t0", time.time()), 1))
        return rc

    def require_port_free(self, port: int, what: str, host="127.0.0.1"):
        """Abort instead of killing whatever holds the port (it may be another runner's server)."""
        if self.dry:
            return
        try:
            with socket.create_connection((host, port), timeout=1):
                pass
        except OSError:
            return
        sys.exit(f"port {port} is already open: a {what} (another runner or a stray server) is running; "
                 f"stop it by pid before starting this run")

    def wait_port(self, port: int, p: Optional[subprocess.Popen], timeout: int = 900, host="127.0.0.1") -> bool:
        if self.dry:
            return True
        t0 = time.time()
        while time.time() - t0 < timeout:
            if p is not None and p.poll() is not None:
                print(f"  !! server exited early with rc={p.returncode}", file=sys.stderr)
                return False
            try:
                with socket.create_connection((host, port), timeout=1):
                    return True
            except OSError:
                time.sleep(0.5)
        print(f"  !! port {port} not open after {timeout}s", file=sys.stderr)
        return False


# --------------------------------------------------------------------------- #
# Application adapters
# --------------------------------------------------------------------------- #

class App:
    name = ""
    default_threads = os.cpu_count() or 8

    def __init__(self, ctx: Ctx):
        self.ctx = ctx
        self.threads = ctx.args.threads or self.default_threads

    def binary(self, cfg: str) -> Path:
        raise NotImplementedError

    def artifacts(self, cfg: str) -> List[Path]:
        return [self.binary(cfg)]

    def workload(self) -> dict:
        return {}

    def prepare(self):
        pass

    def run_once(self, cfg: str, run: int):
        raise NotImplementedError


class Sqlite(App):
    name = "sqlite"
    root = EXP_ROOT / "sql" / "sqlite"

    def binary(self, cfg):
        # --build-root: e.g. sql/sqlite/build/paper-compiler (A/B builds with another compiler)
        return (self.ctx.build_root or self.root / "build") / f"test-{cfg}" / "threadtest3"

    def workload(self):
        # Paper: run_sqlite_test.sh runs threadtest3 with no arguments (all 15 tests).
        tests = ["walthread1"] if self.ctx.scale == "smoke" else []
        return {"tests": tests or "all", "cwd": "fresh dir per run under workdir"}

    def run_once(self, cfg, run):
        wd = self.ctx.work / f"{cfg}.{run}"
        if wd.exists():
            subprocess.run(["rm", "-rf", str(wd)])
        wd.mkdir(parents=True)
        cmd = [str(self.binary(cfg))]
        if self.ctx.scale == "smoke":
            cmd += ["--w1-threads", "4", "walthread1"]
        self.ctx.run_cmd(cmd, cfg=cfg, run=run, tag="threadtest3", cwd=wd, env=self.ctx.tsan_env(cfg, run),
                         timeout=3 * 3600)
        subprocess.run(["rm", "-rf", str(wd)])


class Ffmpeg(App):
    name = "ffmpeg"
    root = EXP_ROOT / "projects" / "ffmpeg"
    # bench_ffmpeg_all.sh CODECS
    CODECS = {
        "h264_libx264": ("-c:v libx264 -preset medium -crf 23", "mp4"),
        "h265_libx265": ("-c:v libx265 -preset medium -crf 28 -tag:v hvc1", "mp4"),
        "mjpeg": ("-c:v mjpeg -pix_fmt yuvj420p -q:v 2", "avi"),
        "copy_passthrough": ("-c:v copy -c:a copy", "mkv"),
    }

    def prefix(self, cfg):
        # --build-root: directory holding ffmpeg-<cfg>/ trees other than projects/ffmpeg
        return (self.ctx.build_root or self.root) / f"ffmpeg-{cfg}"

    def binary(self, cfg):
        return self.prefix(cfg) / "bin" / "ffmpeg"

    def artifacts(self, cfg):
        libdir = self.prefix(cfg) / "lib"
        return [self.binary(cfg)] + sorted(p for p in libdir.glob("lib*.so.*") if not p.is_symlink())

    def workload(self):
        codecs = list(self.CODECS) if self.ctx.scale == "paper" else ["copy_passthrough", "mjpeg"]
        return {"input": str(self.root / "input" / "WatchingEyeTexture.mkv"), "threads": self.threads,
                "codecs": codecs, "smoke_duration_s": 3 if self.ctx.scale == "smoke" else None}

    def run_once(self, cfg, run):
        wl = self.workload()
        env = self.ctx.tsan_env(cfg, run)
        env["LD_LIBRARY_PATH"] = f"{self.prefix(cfg) / 'lib'}:" + env.get("LD_LIBRARY_PATH", "")
        for codec in wl["codecs"]:
            params, ext = self.CODECS[codec]
            out = self.ctx.work / f"out.{cfg}.{run}.{ext}"
            cmd = [str(self.binary(cfg)), "-hide_banner", "-i", wl["input"], "-threads", str(self.threads), "-y"]
            if wl["smoke_duration_s"]:
                cmd += ["-t", str(wl["smoke_duration_s"])]
            cmd += params.split() + ["-loglevel", "error", str(out)]
            self.ctx.run_cmd(cmd, cfg=cfg, run=run, tag=codec, cwd=self.root, env=env, timeout=4 * 3600)
            out.unlink(missing_ok=True)


class Memcached(App):
    name = "memcached"
    root = EXP_ROOT / "nosql" / "memcached"
    port = 7777

    def binary(self, cfg):
        # --build-root: directory holding memcached-<cfg>/ trees other than nosql/memcached
        return (self.ctx.build_root or self.root) / f"memcached-{cfg}" / "memcached"

    def workload(self):
        # run-memcached.sh: memcached -c 4096 -t $(nproc) -p 7777
        # run-bench.sh:     memtier_benchmark --hide-histogram -t 10 -p 7777 -x 25 --pipeline 16 -P memcache_text --random-data
        smoke = self.ctx.scale == "smoke"
        return {"server_threads": self.threads, "memtier_threads": 10, "memtier_x": 1 if smoke else 25,
                "memtier_extra": ["--requests", "2000"] if smoke else [], "pipeline": 16,
                "server_extra": "-U 0 (UDP off; not in run-memcached.sh, no effect on the memtier TCP workload)"}

    def run_once(self, cfg, run):
        wl = self.workload()
        self.ctx.require_port_free(self.port, "memcached")
        srv = self.ctx.start_server([str(self.binary(cfg)), "-c", "4096", "-t", str(wl["server_threads"]),
                                     "-p", str(self.port), "-U", "0"],
                                    cfg=cfg, run=run, tag="memcached", cwd=self.root, env=self.ctx.tsan_env(cfg, run))
        try:
            if not self.ctx.wait_port(self.port, srv):
                return
            time.sleep(1)
            memtier = self.root / "memtier_benchmark-2.1.1" / "memtier_benchmark"
            cmd = [str(memtier), "--hide-histogram", "-t", str(wl["memtier_threads"]), "-p", str(self.port),
                   "-x", str(wl["memtier_x"]), "--pipeline", str(wl["pipeline"]), "-P", "memcache_text",
                   "--random-data", *wl["memtier_extra"]]
            self.ctx.run_cmd(cmd, cfg=cfg, run=run, tag="memtier", cwd=self.root, env=self.ctx.plain_env(),
                             timeout=4 * 3600)
        finally:
            # SIGTERM as in run-bench.sh (kill `cat memcached_pid`); memcached handles it and exits.
            self.ctx.stop_server(srv, cfg=cfg, run=run, tag="memcached")


class Redis(App):
    name = "redis"
    root = EXP_ROOT / "nosql" / "redis"
    polygon = root / "redis-polygon"
    port = 6379
    # redis.sh benchmark loop (paper): (test, requests)
    TESTS = [("PING_INLINE", 1000000), ("PING_MBULK", 1000000), ("SET", 1000000), ("GET", 1000000),
             ("INCR", 1000000), ("RPUSH", 1000000), ("LPOP", 1000000), ("RPOP", 1000000), ("SADD", 1000000),
             ("HSET", 1000000), ("SPOP", 1000000), ("ZADD", 1000000), ("ZPOPMIN", 1000000), ("LPUSH", 1000000),
             ("LRANGE_100", 50000), ("LRANGE_300", 10000), ("LRANGE_500", 5000), ("LRANGE_600", 3000),
             ("MSET", 100000)]

    def binary(self, cfg):
        return (self.ctx.build_root or self.polygon) / f"redis-{cfg}" / "src" / "redis-server"

    def workload(self):
        smoke = self.ctx.scale == "smoke"
        tests = [(t, max(200, n // 5000)) for t, n in self.TESTS[:6]] if smoke else self.TESTS
        return {"conf": str(self.polygon / "redis.conf"), "tests": tests, "pipeline": 1024}

    def run_once(self, cfg, run):
        wl = self.workload()
        self.ctx.require_port_free(self.port, "redis-server")
        wd = self.ctx.work / f"{cfg}.{run}"
        wd.mkdir(parents=True, exist_ok=True)
        srv = self.ctx.start_server([str(self.binary(cfg)), wl["conf"]], cfg=cfg, run=run, tag="redis-server",
                                    cwd=wd, env=self.ctx.tsan_env(cfg, run))
        try:
            if not self.ctx.wait_port(self.port, srv):
                return
            time.sleep(2)
            bench = self.polygon / "redis-benchmark" / "src" / "redis-benchmark"
            for test, n in wl["tests"]:
                cmd = [str(bench), "-P", str(wl["pipeline"]), "-n", str(n), "-t", test]
                rc = self.ctx.run_cmd(cmd, cfg=cfg, run=run, tag=f"bench-{test}", cwd=wd, env=self.ctx.plain_env(),
                                      timeout=2 * 3600)
                if rc != 0:
                    break
        finally:
            # redis.sh stops the server with SIGTERM (graceful shutdown).
            self.ctx.stop_server(srv, cfg=cfg, run=run, tag="redis-server")
        subprocess.run(["rm", "-rf", str(wd)])


class Mysql(App):
    name = "mysql"
    root = EXP_ROOT / "sql" / "mysql"
    bench = root / "benchmysql"
    datadir = Path("/tmp/mysql-benchmarks-datadir")
    socket = "/tmp/mysql.sock"
    SCRIPTS = ["oltp_read_write.lua", "oltp_read_only.lua", "oltp_write_only.lua",
               "select_random_ranges.lua", "select_random_points.lua"]

    def binary(self, cfg):
        return (self.ctx.build_root or self.root) / f"mysql-{cfg}" / "bin" / "mysqld"

    def workload(self):
        smoke = self.ctx.scale == "smoke"
        secs = self.ctx.args.mysql_seconds or (20 if smoke else 180)
        threads = self.ctx.args.threads or (os.cpu_count() or 8) * 3 // 4
        return {"scripts": self.SCRIPTS[:1] if smoke else self.SCRIPTS, "sysbench_seconds": secs,
                "sysbench_threads": threads, "datadir": str(self.datadir)}

    def _client_env(self, cfg, script, secs, threads):
        return self.ctx.plain_env(MYSQL_DIR=str(self.root / f"mysql-{cfg}" / "bin"), MYSQL_DATA_DIR=str(self.datadir),
                                  SYSBENCH_SCRIPT_FILENAME=script, SYSBENCH_RUN_SECONDS=str(secs),
                                  SYSBENCH_RUN_THREADS=str(threads))

    def _ping(self, cfg) -> bool:
        mysqladmin = self.root / f"mysql-{cfg}" / "bin" / "mysqladmin"
        r = subprocess.run([str(mysqladmin), "--user=root", f"--socket={self.socket}", "ping"],
                           env=self.ctx.plain_env(), capture_output=True, timeout=60)
        return r.returncode == 0

    def prepare(self):
        if self.ctx.dry:
            return
        cfg = self.ctx.args.configs.split(",")[0]
        if not self.datadir.exists():
            print(f"[{now()}] initializing MySQL datadir {self.datadir} with mysql-{cfg}")
            errlog = self.ctx.out / "datadir-init.stderr.log"
            with open(errlog, "wb") as eh:
                r = subprocess.run([str(self.binary(cfg)), "--initialize-insecure", f"--datadir={self.datadir}"],
                                   env=self.ctx.plain_env(), timeout=3600, stdout=subprocess.DEVNULL, stderr=eh)
            if r.returncode != 0:
                sys.exit(f"mysqld --initialize-insecure failed (rc={r.returncode}); see {errlog}")

    def run_once(self, cfg, run):
        wl = self.workload()
        for script in wl["scripts"]:
            tag = script.replace(".lua", "").replace("_", "-")
            cenv = self._client_env(cfg, script, wl["sysbench_seconds"], wl["sysbench_threads"])
            srv = self.ctx.start_server([str(self.binary(cfg)), f"--datadir={self.datadir}", f"--socket={self.socket}"],
                                        cfg=cfg, run=run, tag=f"mysqld-{tag}", cwd=self.bench,
                                        env=self.ctx.tsan_env(cfg, run))
            try:
                if not self.ctx.dry:
                    t0 = time.time()
                    while not self._ping(cfg):
                        if srv.poll() is not None or time.time() - t0 > 1800:
                            print("  !! mysqld did not come up", file=sys.stderr)
                            return
                        time.sleep(1)
                for step in ("bench-init.sh", "bench-run.sh", "bench-cleanup.sh"):
                    rc = self.ctx.run_cmd([f"./{step}"], cfg=cfg, run=run, tag=f"{step[:-3]}-{tag}", cwd=self.bench,
                                          env=cenv, timeout=4 * 3600)
                    if rc != 0 and step != "bench-cleanup.sh":
                        break
            finally:
                mysqladmin = self.root / f"mysql-{cfg}" / "bin" / "mysqladmin"

                def shutdown():
                    subprocess.run([str(mysqladmin), "--user=root", f"--socket={self.socket}", "shutdown"],
                                   env=self.ctx.plain_env(), capture_output=True, timeout=600)
                self.ctx.stop_server(srv, cfg=cfg, run=run, tag=f"mysqld-{tag}", grace=900, pre_stop=shutdown)


APPS = {c.name: c for c in (Sqlite, Ffmpeg, Memcached, Redis, Mysql)}


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #

def compiler_info(llvm_root: Path, check_ninja: bool) -> dict:
    tree = llvm_root.parent.parent   # <tree>/llvm/build
    info = {"llvm_root": str(llvm_root), "tree": str(tree)}
    clang = llvm_root / "bin" / "clang"
    info["clang_version"] = sh([str(clang), "--version"]).splitlines()[0] if clang.exists() else "<missing>"
    info["clang_mtime"] = dt.datetime.fromtimestamp(clang.stat().st_mtime).isoformat() if clang.exists() else None
    rt = list(llvm_root.glob("lib/clang/*/lib/*/libclang_rt.tsan.a"))
    info["tsan_rt_mtime"] = dt.datetime.fromtimestamp(rt[0].stat().st_mtime).isoformat() if rt else None
    if (tree / ".git").exists():
        info["git_branch"] = sh(["git", "-C", str(tree), "branch", "--show-current"])
        info["git_head"] = sh(["git", "-C", str(tree), "rev-parse", "HEAD"])
        info["git_dirty_files"] = len(sh(["git", "-C", str(tree), "status", "--porcelain", "--untracked-files=no"]).splitlines())
    if check_ninja:
        # Dry run only; tells whether the binaries are current w.r.t. the sources.
        info["ninja_pending"] = sh(["ninja", "-n", "-C", str(llvm_root)], timeout=300).splitlines()[-1:] or ["<none>"]
    return info


def write_manifest(ctx: Ctx, app: App, configs: List[str]):
    m = {
        "app": ctx.app, "created": now(), "host": socket.gethostname(), "cpus": os.cpu_count(),
        "argv": sys.argv, "scale": ctx.scale, "out": str(ctx.out), "workload": app.workload(),
        "tsan_options_template": ctx.tsan_env("<cfg>", 0)["TSAN_OPTIONS"],
        "compiler": compiler_info(ctx.llvm_root, not ctx.args.no_ninja_check),
        "configs": {},
    }
    for cfg in configs:
        arts = []
        for p in app.artifacts(cfg):
            if p.exists():
                arts.append({"path": str(p), "mtime": dt.datetime.fromtimestamp(p.stat().st_mtime).isoformat(),
                             "size": p.stat().st_size, "sha256": sha256_of(p), "compilers": elf_compilers(p)})
            else:
                arts.append({"path": str(p), "missing": True})
        m["configs"][cfg] = {"artifacts": arts}
        # build_info.txt is written by the (adapted) build scripts: flags, compiler, summaries used.
        for cand in (app.binary(cfg).parent / "build_info.txt", app.binary(cfg).parent.parent / "build_info.txt"):
            if cand.exists():
                m["configs"][cfg]["build_info"] = cand.read_text()
                break
    with open(ctx.out / "manifest.json", "w") as fh:
        json.dump(m, fh, indent=1)
    return m


# --------------------------------------------------------------------------- #

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", required=True, choices=sorted(APPS))
    ap.add_argument("--configs", required=True, help="comma-separated build config names (as in the build dir names)")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--first-run", type=int, default=1, help="run index to start from (resume)")
    ap.add_argument("--scale", choices=["paper", "smoke"], default="paper")
    ap.add_argument("--threads", type=int, help="worker threads for the workload (default: paper setting)")
    ap.add_argument("--mysql-seconds", type=int, help="sysbench --time per script (paper: 180)")
    ap.add_argument("--out", help="output dir (default: tools/preservation/results/<app>/<timestamp>)")
    ap.add_argument("--workdir", help="scratch dir for databases/outputs (default: /dev/shm/preservation-<app>)")
    ap.add_argument("--llvm-root", default=str(DEFAULT_LLVM_ROOT),
                    help="build dir of the compiler the binaries were built with (recorded in the manifest, "
                         "provides llvm-symbolizer)")
    ap.add_argument("--symbolizer", help="external_symbolizer_path (default: <llvm-root>/bin/llvm-symbolizer)")
    ap.add_argument("--build-root", help="directory holding the per-config build dirs instead of the default "
                                         "(sqlite: <build-root>/test-<cfg>/threadtest3; memcached/ffmpeg/mysql: "
                                         "<build-root>/<app>-<cfg>/...; redis: <build-root>/redis-<cfg>/src/redis-server)")
    ap.add_argument("--tsan-options", help="extra TSAN_OPTIONS appended verbatim")
    ap.add_argument("--order", choices=["config-major", "run-major"], default="run-major",
                    help="run-major interleaves configs (run 1 of every config, then run 2, ...) so that drift in "
                         "machine state affects all configs alike")
    ap.add_argument("--no-ninja-check", action="store_true", help="skip 'ninja -n' staleness check of the compiler")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    ctx = Ctx(args)
    app = APPS[args.app](ctx)
    configs = args.configs.split(",")
    missing = [cfg for cfg in configs if not app.binary(cfg).exists()]
    if missing and not args.dry_run:
        sys.exit(f"missing binaries for configs: {missing} (expected e.g. {app.binary(missing[0])})")

    m = write_manifest(ctx, app, configs)
    print(f"output: {ctx.out}")
    print(f"compiler: {m['compiler'].get('clang_version')} branch={m['compiler'].get('git_branch')} "
          f"head={m['compiler'].get('git_head', '')[:12]} ninja={m['compiler'].get('ninja_pending')}")
    print(f"TSAN_OPTIONS template: {m['tsan_options_template']}")
    app.prepare()

    runs = range(args.first_run, args.first_run + args.runs)
    plan = [(cfg, r) for r in runs for cfg in configs] if args.order == "run-major" else \
           [(cfg, r) for cfg in configs for r in runs]
    t0 = time.time()
    for i, (cfg, r) in enumerate(plan, 1):
        print(f"=== [{i}/{len(plan)}] {args.app} cfg={cfg} run={r}  (elapsed {int(time.time() - t0)}s)")
        app.run_once(cfg, r)
        n = len(list(ctx.logs.glob(f"{args.app}.{cfg}.{r}.*")))
        if n == 0 and not args.dry_run:
            # TSan creates log_path.<pid> only when it has something to print; record the run anyway.
            (ctx.logs / f"{args.app}.{cfg}.{r}.noreports").touch()
        print(f"    log files for this run: {n}")
    print(f"done in {int(time.time() - t0)}s. Aggregate with:\n  {HERE / 'tsan_reports.py'} aggregate "
          f"--results-dir {ctx.logs} --baseline {configs[0]}")


if __name__ == "__main__":
    main()
