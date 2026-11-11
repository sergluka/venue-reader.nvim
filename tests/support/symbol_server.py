"""Controlled stdio peer for document-symbol event-sequence tests."""

import json
import sys

requests = {}
order = []
cancelled = []


def send(message):
    payload = json.dumps(message, separators=(",", ":")).encode()
    sys.stdout.buffer.write(
        f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload
    )
    sys.stdout.buffer.flush()


def reply(request_id, result=None, error=None):
    message = {"jsonrpc": "2.0", "id": request_id}
    message["error" if error else "result"] = error or result
    send(message)


def progress(token, value):
    send(
        {
            "jsonrpc": "2.0",
            "method": "$/progress",
            "params": {"token": token, "value": value},
        }
    )


def symbol(name, line=0):
    region = {
        "start": {"line": line, "character": 0},
        "end": {"line": line, "character": 1},
    }
    return {"name": name, "kind": 12, "range": region, "selectionRange": region}


while True:
    length = None
    while True:
        header = sys.stdin.buffer.readline()
        if not header:
            sys.exit(0)
        if header in (b"\r\n", b"\n"):
            break
        key, _, value = header.partition(b":")
        if key.lower() == b"content-length":
            length = int(value)
    if length is None:
        sys.exit(1)
    message = json.loads(sys.stdin.buffer.read(length))
    method = message.get("method", "")
    params = message.get("params") or {}
    request_id = message.get("id")
    if method == "initialize":
        reply(
            request_id,
            {
                "serverInfo": {
                    "name": "symbol-test",
                    "version": sys.argv[1] if len(sys.argv) > 1 else "0.3.0",
                },
                "capabilities": {
                    "textDocumentSync": 1,
                    "documentSymbolProvider": {"workDoneProgress": True},
                },
            },
        )
    elif method == "shutdown":
        reply(request_id)
    elif method in ("exit", "test/exit"):
        sys.exit(0)
    elif method == "textDocument/documentSymbol":
        requests[request_id] = params
        order.append({"id": request_id, "params": params})
    elif method == "$/cancelRequest":
        cancelled.append(params["id"])
    elif method == "test/state":
        reply(request_id, {"requests": order, "cancelled": cancelled})
    elif method.startswith("test/"):
        target = params.get("request", order[-1]["id"] if order else None)
        target_params = requests.get(target, {})
        if method == "test/chunk":
            progress(target_params["partialResultToken"], params["symbols"])
        elif method == "test/progress":
            progress(target_params["workDoneToken"], params["value"])
        elif method == "test/unrelated":
            progress("unrelated-work", {"kind": "begin", "title": "Other work"})
        elif method == "test/final":
            reply(target, params.get("result", []), params.get("error"))
        elif method == "test/burst":
            total = params.get("total", 50000)
            batch = params.get("batch", 256)
            for offset in range(0, total, batch):
                progress(
                    target_params["partialResultToken"],
                    [
                        symbol(f"Burst{index:06d}")
                        for index in range(offset, min(total, offset + batch))
                    ],
                )
            if params.get("finish", True):
                reply(target, [])
        if request_id is not None:
            reply(request_id, True)
    elif request_id is not None:
        reply(request_id, None)
