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
from urllib.parse import urlencode

from .client import HydraClient
from .errors import (
    HydraAuthError, HydraConnectionError, HydraError, HydraNotFoundError,
    HydraServerError,
)

log = logging.getLogger("hydra_client.worker")

_REPORT_RETRIES = 3
_DEFAULT_MAX_OUTPUT_BYTES = 1_000_000


class Worker:
    def __init__(self, server: str, device_id: str | None = None,
                 capabilities: list[str] | None = None,
                 max_concurrent: int = 1,
                 reconnect_max_backoff: float = 30.0,
                 api_key: str | None = None,
                 term_grace: float = 5.0,
                 max_output_bytes: int = _DEFAULT_MAX_OUTPUT_BYTES):
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
        self.max_output_bytes = max_output_bytes
        self._pool = ThreadPoolExecutor(max_workers=max_concurrent)
        self._procs: dict[str, subprocess.Popen] = {}
        self._procs_lock = threading.Lock()
        # task.cancel 이 도착했지만 아직 시작 전인 task 를 기록 — 큐 대기중이거나
        # task.assign 과 Popen 등록 사이의 틈에서 취소되면 _kill 이 아무것도 찾지
        # 못해 조용히 무시되던 문제(§E1)를 막는다. _procs_lock 을 재사용해 잠근다.
        self._cancelled: set[str] = set()
        self._stop = threading.Event()
        self._conn = None  # 현재 살아있는 WS 커넥션 — stop() 이 강제로 닫을 수 있게 보관
        self._conn_lock = threading.Lock()

    # ── 수신 루프 ────────────────────────────────────────────────
    def run(self) -> None:
        """WS 접속·수신 블로킹 루프. 끊기면 지수 백오프로 재접속."""
        from websockets.sync.client import connect as ws_connect

        scheme = "wss" if self.server.startswith("https") else "ws"
        host = self.server.split("://", 1)[1]
        query = urlencode({"device_id": self.device_id})
        url = f"{scheme}://{host}/ws?{query}"
        headers = {"X-API-Key": self.client.api_key} if self.client.api_key else None
        backoff = 1.0
        try:
            while not self._stop.is_set():
                try:
                    with ws_connect(url, max_size=512 * 1024,
                                     additional_headers=headers) as conn:
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
            # KeyboardInterrupt 등 어떤 경로로 빠지든 풀은 반드시 정리한다.
            # cancel_futures=True (3.9+) 로 아직 시작 안 한 future 를 버려
            # stop() 이후 새로 spawn 되는 걸 막는다 — 실행 중인 것은 execute_task
            # 상단의 _stop 체크와 stop() 의 kill 루프가 정리한다.
            self._pool.shutdown(wait=True, cancel_futures=True)

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
        # 실행 중인 subprocess 를 방치하면 run() 의 finally 에서
        # pool.shutdown(wait=True) 가 장시간 task 에 걸려 멈출 수 있다 —
        # 스냅샷을 떠서 각각 기존 TERM→grace→KILL 로직으로 정리한다.
        with self._procs_lock:
            task_ids = list(self._procs.keys())
        for task_id in task_ids:
            self._kill(task_id)

    def handle_message(self, msg: dict) -> None:
        mtype = msg.get("type")
        if mtype == "task.assign":
            task = msg.get("payload") or {}
            if isinstance(task, str):  # 방어: RawMessage 가 문자열로 올 경우
                task = json.loads(task)
            self._pool.submit(self.execute_task, task)
        elif mtype == "task.cancel":
            task_id = msg.get("taskId", "")
            # _kill 보다 먼저 tombstone 을 남긴다 — 아직 큐에 있거나 막 시작하려는
            # task 가 이 시점 이후 execute_task 에 진입해도 취소를 관측하게 한다.
            with self._procs_lock:
                self._cancelled.add(task_id)
            self._kill(task_id)
        # ping/pong 등은 websockets 가 처리, 나머지는 무시

    # ── 실행 ────────────────────────────────────────────────────
    def execute_task(self, task: dict) -> None:
        task_id = task.get("id", "")
        if self._stop.is_set():
            # 워커가 종료 중 — 새 프로세스를 스폰하지 않는다 (§E2).
            log.info("execute_task skipped (worker stopping): %s", task_id)
            return
        with self._procs_lock:
            was_cancelled = task_id in self._cancelled
            self._cancelled.discard(task_id)
        if was_cancelled:
            # 시작 전에 취소됨 — 서버는 이미 취소로 처리했으니 실행하지 않는다 (§E1).
            log.info("execute_task skipped (cancelled before start): %s", task_id)
            return
        command = (task.get("payload") or {}).get("command")
        self._try_report_status(task_id, "running")
        if not command:
            self._report(task_id, {"stdout": "", "stderr": "no command in payload",
                                   "exitCode": 1, "timedOut": False},
                         failed=True, duration_ns=0)
            with self._procs_lock:
                self._cancelled.discard(task_id)
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
                # 등록과 같은 락 안에서 tombstone 을 재확인한다 — "running" 보고 +
                # Popen 사이의 틈(§TOCTOU)에 task.cancel 이 도착하면 handle_message
                # 는 _procs_lock 을 잡고 _cancelled 에 추가한 뒤 _kill 을 호출하는데,
                # 그 시점엔 아직 _procs 에 없어 _kill 이 아무것도 못 찾고 조용히
                # 리턴해버린다. 여기서 등록 직후 같은 락으로 재확인하면 그 틈이
                # 사라진다: cancel 이 먼저 락을 잡았으면 우리가 cancelled_mid=True 로
                # 보고, cancel 이 나중에 락을 잡으면 이미 _procs 에 있는 proc 을
                # 정상적으로 찾아 _kill 한다 — 어느 순서든 누락이 없다.
                cancelled_mid = task_id in self._cancelled
            if cancelled_mid:
                # lock 밖에서 kill — _kill 자체가 락을 다시 잡고, TERM→grace→KILL
                # 동안 network/blocking 호출을 락 안에 두지 않기 위함.
                log.info("execute_task cancelled mid-start, killing: %s", task_id)
                self._kill(task_id)
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
                    self._cancelled.discard(task_id)
        except Exception as e:  # noqa: BLE001 — Popen 등 실행 경로 실패도 반드시 서버에 보고
            # 이 가드는 실행(env/Popen/communicate) 경로만 감싼다 — 성공 경로의
            # _report 호출까지 감싸면, 보고 자체가 던진 비-HydraError(예: 2xx
            # 응답의 JSON 파싱 실패)가 여기서 잡혀 성공한 task 를 다시
            # failed 로 보고하게 된다.
            duration_ns = int((time.monotonic() - start) * 1e9)
            stderr, err_truncated = self._cap_output(f"worker exception: {e}")
            self._report(task_id,
                         {"stdout": "", "stderr": stderr,
                          "exitCode": -1, "timedOut": False,
                          "truncated": err_truncated},
                         failed=True, duration_ns=duration_ns)
            with self._procs_lock:
                self._cancelled.discard(task_id)
            return

        duration_ns = int((time.monotonic() - start) * 1e9)
        exit_code = proc.returncode
        failed = timed_out or exit_code != 0
        stdout, out_truncated = self._cap_output(stdout)
        stderr, err_truncated = self._cap_output(stderr)
        self._report(task_id,
                     {"stdout": stdout, "stderr": stderr,
                      "exitCode": exit_code, "timedOut": timed_out,
                      "truncated": out_truncated or err_truncated},
                     failed=failed, duration_ns=duration_ns)

    def _cap_output(self, text: str) -> tuple[str, bool]:
        """stdout/stderr 를 max_output_bytes 로 캡 — 보고 payload 만 제한한다.

        communicate() 가 이미 완성된 문자열을 반환한 뒤라 자식 프로세스의
        피크 메모리 사용량 자체를 줄이지는 못한다 (chatty task 는 여전히
        그만큼 메모리를 쓴다) — 서버로 올라가는 보고 크기만 제한한다.
        """
        encoded = text.encode("utf-8", errors="surrogateescape")
        if len(encoded) <= self.max_output_bytes:
            return text, False
        tail = encoded[-self.max_output_bytes:]
        return tail.decode("utf-8", errors="replace"), True

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
            except HydraAuthError as e:
                # 401 은 재시도로 해결되지 않는다 — 즉시 포기하고 실패를
                # 빨리 드러낸다 (무의미한 3회 백오프로 지연시키지 않는다)
                log.error("report dropped: auth failed: %s", e)
                return
            except (HydraConnectionError, HydraServerError) as e:
                # 일시적 오류(연결 끊김/5xx)만 재시도 대상
                if attempt == _REPORT_RETRIES - 1:
                    log.error("report failed after %d attempts: %s",
                              _REPORT_RETRIES, e)
                    return
                time.sleep(backoff)
                backoff = min(backoff * 2, 10.0)
            except HydraError as e:
                # 그 외(예: 4xx) 는 재시도로 해결되지 않는 요청 자체의 문제 — 즉시 포기
                log.error("report dropped: non-retryable error: %s", e)
                return


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
