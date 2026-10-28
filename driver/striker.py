#!/usr/bin/env python3
"""striker - USB driver for the in-app Striker console.

The console runs INSIDE the target app, bound to 127.0.0.1:<port>. Bridge that
port to your Mac over USB with usbmuxd's iproxy, then talk to it line by line:

    iproxy 45678 45678          # in another terminal: USB -> device loopback
    ./striker.py uitree         # run one command
    ./striker.py                # interactive REPL

Protocol: the client sends one command line (newline-terminated); the server
streams the UTF-8 result followed by a single 0x04 (EOT) byte, and keeps the
connection open for the next command.
"""
import argparse
import os
import socket
import sys

EOT = b"\x04"


class Striker:
    def __init__(self, host, port, timeout):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = b""

    def send(self, line):
        self.sock.sendall((line.rstrip("\n") + "\n").encode())
        out = bytearray()
        while True:
            i = self.buf.find(EOT)
            if i != -1:
                out += self.buf[:i]
                self.buf = self.buf[i + 1:]
                return out.decode("utf-8", "replace")
            out += self.buf
            self.buf = b""
            chunk = self.sock.recv(65536)
            if not chunk:
                return out.decode("utf-8", "replace")
            self.buf = chunk

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="USB driver for the in-app Striker console")
    ap.add_argument("command", nargs="*", help="command to run; omit for an interactive REPL")
    ap.add_argument("-p", "--port", type=int,
                    default=int(os.environ.get("STRIKER_PORT", "45678")))
    ap.add_argument("-H", "--host", default="127.0.0.1")
    ap.add_argument("-t", "--timeout", type=float, default=15.0)
    args = ap.parse_args()

    try:
        stk = Striker(args.host, args.port, args.timeout)
    except OSError as e:
        sys.exit(f"striker: cannot connect to {args.host}:{args.port} ({e}).\n"
                 f"Start `iproxy {args.port} {args.port}` and bring the app to the foreground "
                 f"(the console only answers while the app is foregrounded).")

    try:
        if args.command:
            sys.stdout.write(stk.send(" ".join(args.command)))
            if not sys.stdout.isatty():
                return
            sys.stdout.write("\n")
        else:
            print(f"striker REPL on {args.host}:{args.port} - 'quit' to exit, 'help' for commands")
            while True:
                try:
                    line = input("striker> ")
                except EOFError:
                    break
                if line.strip() in ("quit", "exit"):
                    break
                if not line.strip():
                    continue
                sys.stdout.write(stk.send(line))
                sys.stdout.flush()
    finally:
        stk.close()


if __name__ == "__main__":
    main()
