"""hydra 워커 — task.assign 을 받아 실행하고 결과를 보고하는 실행 루프.

서버의 실행-보고 루프가 비어 있던 부분(설계 스펙 §7)을 채운다:
  /ws 접속 → capability 등록 → task.assign 수신 → subprocess 실행
  → PUT /result 보고 (exit≠0 이면 이어서 PUT /status failed).
결과를 WS 가 아니라 REST 로 보고하는 이유: 서버에 task.result WS 수신
처리가 없어, 기존 REST 엔드포인트가 Go 변경 없이 완결되는 경로라서다.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from .client import HydraClient
from .errors import HydraError, HydraNotFoundError

log = logging.getLogger("hydra_client.worker")

_REPORT_RETRIES = 3


class Worker:
    def __init__(self, server: str, device_id: str | None = None,
                 capabilities: list[str] | None = None,
                 max_concurrent: int = 1,
                 reconnect_max_backoff: float = 30.0,
                 api_key: str | None = None,
                 term_grace: float = 5.0):
        if "://" not in server:
            raise ValueError(
                "server URL must include http:// or https://"
                f" (got: {server!r})")
        self.server = server.rstrip("/")
        self.device_id = device_id or socket.gethostname()
        self.capabilities = capabilities or ["compute"]
        self.client = HydraClient(self.server, api_key=api_key)
        self.reconnect_max_backoff = reconnect_max_backoff
        self.term_grace = term_grace  # SIGTERM 후 SIGKILL 까지 유예(초)
        self._pool = ThreadPoolExecutor(max_workers=max_concurrent)
        self._procs: dict[str, subprocess.Popen] = {}
        self._procs_lock = threading.Lock()
        self._stop = threading.Event()
        self._conn = None  # 현재 살아있는 WS 커넥션 — stop() 이 강제로 닫을 수 있게 보관
        self._conn_lock = threading.Lock()

    # ── 수신 루프 ────────────────────────────────────────────────
    def run(self) -> None:
        """WS 접속·수신 블로킹 루프. 끊기면 지수 백오프로 재접속."""
        from websockets.sync.client import connect as ws_connect

        scheme = "wss" if self.server.startswith("https") else "ws"
        host = self.server.split("://", 1)[1]
        url = f"{scheme}://{host}/ws?device_id={self.device_id}"
        backoff = 1.0
        try:
            while not self._stop.is_set():
                try:
                    with ws_connect(url, max_size=512 * 1024) as conn:
                        with self._conn_lock:
                            self._conn = conn
                        try:
                            log.info("connected to %s as %s", url, self.device_id)
                            backoff = 1.0
                            # 재접속마다 재등록 — 서버 재시작에도 능력 정보 유지
                            self.client.register_capabilities(
                                self.device_id, self.capabilities)
                            for raw in conn:
                                self.handle_message(json.loads(raw))
                        finally:
                            with self._conn_lock:
                                if self._conn is conn:
                                    self._conn = None
                except Exception as e:  # noqa: BLE001 — 루프는 죽지 않는다
                    if self._stop.is_set():
                        break
                    log.warning("ws error: %s (reconnect in %.0fs)", e, backoff)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, self.reconnect_max_backoff)
        finally:
            # KeyboardInterrupt 등 어떤 경로로 빠지든 풀은 반드시 정리한다
            self._pool.shutdown(wait=True)

    def stop(self) -> None:
        self._stop.set()
        # for raw in conn: 이 블로킹 recv 에 갇혀 있을 수 있으니 강제로 깨운다
        with self._conn_lock:
            conn = self._conn
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001 — best-effort, 이미 닫혔을 수도 있음
                pass

    def handle_message(self, msg: dict) -> None:
        mtype = msg.get("type")
        if mtype == "task.assign":
            task = msg.get("payload") or {}
            if isinstance(task, str):  # 방어: RawMessage 가 문자열로 올 경우
                task = json.loads(task)
            self._pool.submit(self.execute_task, task)
        elif mtype == "task.cancel":
            self._kill(msg.get("taskId", ""))
        # ping/pong 등은 websockets 가 처리, 나머지는 무시

    # ── 실행 ────────────────────────────────────────────────────
    def execute_task(self, task: dict) -> None:
        task_id = task.get("id", "")
        command = (task.get("payload") or {}).get("command")
        self._try_report_status(task_id, "running")
        if not command:
            self._report(task_id, {"stdout": "", "stderr": "no command in payload",
                                   "exitCode": 1, "timedOut": False},
                         failed=True, duration_ns=0)
            return

        start = time.monotonic()
        try:
            env = os.environ.copy()
            gpu_indexes = task.get("assignedGpuIndexes")
            if gpu_indexes:
                env["CUDA_VISIBLE_DEVICES"] = ",".join(str(i) for i in gpu_indexes)

            timeout_ns = task.get("timeout") or 0
            timeout_s = timeout_ns / 1e9 if timeout_ns else None

            proc = subprocess.Popen(
                command, shell=True, start_new_session=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env=env)
            with self._procs_lock:
                self._procs[task_id] = proc
            timed_out = False
            try:
                stdout, stderr = proc.communicate(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                timed_out = True
                self._kill(task_id)
                stdout, stderr = proc.communicate()
            finally:
                with self._procs_lock:
                    self._procs.pop(task_id, None)
        except Exception as e:  # noqa: BLE001 — Popen 등 실행 경로 실패도 반드시 서버에 보고
            # 이 가드는 실행(env/Popen/communicate) 경로만 감싼다 — 성공 경로의
            # _report 호출까지 감싸면, 보고 자체가 던진 비-HydraError(예: 2xx
            # 응답의 JSON 파싱 실패)가 여기서 잡혀 성공한 task 를 다시
            # failed 로 보고하게 된다.
            duration_ns = int((time.monotonic() - start) * 1e9)
            self._report(task_id,
                         {"stdout": "", "stderr": f"worker exception: {e}",
                          "exitCode": -1, "timedOut": False},
                         failed=True, duration_ns=duration_ns)
            return

        duration_ns = int((time.monotonic() - start) * 1e9)
        exit_code = proc.returncode
        failed = timed_out or exit_code != 0
        self._report(task_id,
                     {"stdout": stdout, "stderr": stderr,
                      "exitCode": exit_code, "timedOut": timed_out},
                     failed=failed, duration_ns=duration_ns)

    def _kill(self, task_id: str) -> None:
        with self._procs_lock:
            proc = self._procs.get(task_id)
        if proc is None or proc.poll() is not None:
            return
        try:
            pgid = os.getpgid(proc.pid)
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            # poll() 확인과 getpgid/killpg 사이에 프로세스가 이미 회수됨 — 이미 죽었으니 완료 처리
            return
        deadline = time.monotonic() + self.term_grace
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.1)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            return

    # ── 보고 ────────────────────────────────────────────────────
    def _report(self, task_id: str, output: dict, *, failed: bool,
                duration_ns: int) -> None:
        # 순서 중요: 결과(output) 먼저 보존 — SetResult 가 completed 로
        # 만들기 때문에, 실패면 이어서 status=failed 로 덮는다.
        self._retry(lambda: self.client.set_task_result(
            task_id, device_id=self.device_id, device_name=self.device_id,
            output=output, duration_ns=duration_ns))
        if failed:
            self._try_report_status(task_id, "failed")

    def _try_report_status(self, task_id: str, status: str) -> None:
        self._retry(lambda: self.client.update_task_status(task_id, status))

    def _retry(self, fn) -> None:
        backoff = 1.0
        for attempt in range(_REPORT_RETRIES):
            try:
                fn()
                return
            except HydraNotFoundError:
                # 서버가 재할당/삭제했을 수 있음 — 폐기
                log.warning("report dropped: task gone from server")
                return
            except HydraError as e:
                if attempt == _REPORT_RETRIES - 1:
                    log.error("report failed after %d attempts: %s",
                              _REPORT_RETRIES, e)
                    return
                time.sleep(backoff)
                backoff = min(backoff * 2, 10.0)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="python -m hydra_client.worker",
        description="hydra task 실행 워커")
    parser.add_argument("--server", required=True, help="예: http://head:8080")
    parser.add_argument("--device-id", default=None)
    parser.add_argument("--capabilities", default="compute",
                        help="쉼표 구분, 예: gpu,cuda")
    parser.add_argument("--max-concurrent", type=int, default=1)
    parser.add_argument("--api-key", default=None)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    worker = Worker(args.server, device_id=args.device_id,
                    capabilities=args.capabilities.split(","),
                    max_concurrent=args.max_concurrent,
                    api_key=args.api_key)
    try:
        worker.run()
    except KeyboardInterrupt:
        worker.stop()


if __name__ == "__main__":
    main()
