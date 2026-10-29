#ifndef STRIKER_H
#define STRIKER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Striker — an in-app Objective-C runtime console.
//
// Embed it in any iOS app/tweak. It opens a loopback-only TCP listener that you
// reach from a Mac over USB (usbmuxd / iproxy). It answers introspection and
// hooking commands against the live runtime: class/method/ivar listing, view
// and view-controller hierarchy dumps, typed objc_msgSend, raw memory, and
// selector/vtable hooks. No frida, no dyld injection — it runs in-process.
//
// It is a developer tool: gate it behind a debug/dev build so release builds
// never open the listener. The listener binds to 127.0.0.1 only; traffic
// reaches it solely through a USB-forwarded port you start explicitly.

#ifndef STRIKER_DEFAULT_PORT
#define STRIKER_DEFAULT_PORT 45678
#endif

// Starts the console on STRIKER_DEFAULT_PORT. Idempotent: later calls are no-ops
// once a listener is running. Safe to call from a tweak constructor / Tweak init.
void StrikerStart(void);

// Starts the console on a specific loopback port (idempotent; the first start
// wins). Use this when several Striker-equipped apps may run on one device, so
// each gets its own port.
void StrikerStartOnPort(uint16_t port);

// Stops accepting new connections; the listener closes its socket within ~0.5 s
// and a later StrikerStartOnPort() may reuse the port. In-flight connections
// finish their current command.
void StrikerStop(void);

// 1 while a listener is bound and accepting, else 0.
int StrikerIsRunning(void);

// The port of the current/last listener (0 before the first start).
uint16_t StrikerPort(void);

// Runs one command line on the CURRENT thread and returns a malloc'd UTF-8
// result the caller frees with StrikerFree(). This is the same dispatch the
// socket uses, exposed for a file-poller fallback or an in-app debug button.
char *StrikerRunLine(const char *line);
void StrikerFree(char *result);

// Appends the current key window's view + view-controller hierarchy to `path`
// (or NSTemporaryDirectory()/striker-dump.txt when NULL). Safe to call from any
// thread - UI reads marshal to the main thread. Lets a host tweak capture a
// screen's layout to a file without a live socket, e.g. from a lifecycle hook.
void StrikerDumpKeyWindow(const char *path);

// Appends the view tree rooted at `view` (a UIView *, passed as a raw pointer so
// this header stays plain C) to `path`, same format as uitree. Use it to capture
// one screen's subtree, e.g. a feed collection view, instead of the whole window.
void StrikerDumpView(void *view, const char *path);

#ifdef __cplusplus
}
#endif

#endif /* STRIKER_H */
