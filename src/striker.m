// Striker - an in-app Objective-C runtime console. See README.md.
//
// Design notes:
//  - Loopback-only TCP listener; one detached pthread per client connection.
//  - Each command runs in its own @autoreleasepool wrapped in @try/@catch, so a
//    bad command cannot leak across commands or take down the listener.
//  - Wire protocol: client sends one '\n'-terminated line; server replies with
//    the UTF-8 result followed by a single 0x04 (EOT) byte, then waits for the
//    next line on the same connection.
//  - UI commands marshal onto the main thread with a timeout (never dispatch_sync
//    from here, to avoid deadlocking against the main run loop).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import "striker.h"

#pragma mark - small helpers

static NSArray<NSString *> *stk_tokens(const char *line) {
    NSString *s = [NSString stringWithUTF8String:(line ?: "")] ?: @"";
    NSMutableArray<NSString *> *r = [NSMutableArray array];
    for (NSString *p in [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (p.length) [r addObject:p];
    }
    return r;
}

static uintptr_t stk_addr(NSString *t) { return (uintptr_t)strtoull(t.UTF8String, NULL, 0); }

// A token is an object when it starts with a digit (an address), otherwise it is
// treated as a class name.
static id stk_resolve(NSString *t) {
    if (!t.length) return nil;
    unichar c = [t characterAtIndex:0];
    if (c == '0' || (c >= '1' && c <= '9')) return (__bridge id)(void *)stk_addr(t);
    return NSClassFromString(t);
}

static void stk_run_on_main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) { block(); return; }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { block(); } @catch (NSException *e) { NSLog(@"[Striker] main-thread exception: %@", e); }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
}

static NSString *stk_safe_desc(id obj) {
    @try {
        NSString *d = [obj description];
        if (d.length > 200) d = [[d substringToIndex:200] stringByAppendingString:@"..."];
        return d ?: @"(nil description)";
    } @catch (NSException *e) {
        return @"(description threw)";
    }
}

#pragma mark - runtime introspection

static void stk_help(NSMutableString *out) {
    [out appendString:
     @"Striker commands (implemented):\n"
     "  help                         this list\n"
     "  images                       loaded Mach-O images\n"
     "  classes [filter]             class names (substring filter)\n"
     "  class <Name>                 superclass chain, sizes, protocols\n"
     "  methods <Name> [filter]      instance + class methods\n"
     "  method <Name> <sel>          one method's type encoding + IMP\n"
     "  ivars <Name>                 ivar names, offsets, types\n"
     "  instances <Name> [max]       live heap instances (experimental)\n"
     "  obj <addr>                   class chain + ivar values\n"
     "  uitree [depth] [nodes] [all] view hierarchy (frames, a11y id, owning VC)\n"
     "  uivc                         view-controller / presentation tree\n"
     "  uidump [depth] [nodes]       write the view tree to a JSON file\n"
     "  send <obj|Class> <sel> [a..] typed objc_msgSend via NSInvocation\n"
     "  sendq <obj|Class> <sel> [a.] same, dispatched on the main queue\n"
     "  read <addr> <len>            hex dump memory\n"
     "  write <addr> <hex>           write bytes to memory\n"
     "  vt <addr> <count>            print a pointer table\n"
     "  ls <path>                    list a directory\n"
     "  home                         sandbox home / Documents / tmp paths\n"
     "  logtail [n] [path]           tail the striker log (or a file)\n"
     "Roadmap (not in this build): watch, hooksel, hookvt, unhook, scanmem, sqlite, http\n"];
}

static void stk_images(NSMutableString *out) {
    uint32_t n = _dyld_image_count();
    [out appendFormat:@"%u images\n", n];
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        const void *hdr = _dyld_get_image_header(i);
        [out appendFormat:@"  %p  %s\n", hdr, name ?: "?"];
    }
}

static void stk_classes(NSMutableString *out, NSString *filter) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) { [out appendString:@"(none)\n"]; return; }
    const char *f = filter.length ? filter.lowercaseString.UTF8String : NULL;
    int shown = 0, matched = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *cn = class_getName(list[i]);
        if (f) {
            NSString *lc = [NSString stringWithUTF8String:cn].lowercaseString;
            if (![lc containsString:[NSString stringWithUTF8String:f]]) continue;
        }
        matched++;
        if (shown < 1000) { [out appendFormat:@"  %s\n", cn]; shown++; }
    }
    free(list);
    [out appendFormat:@"%d match(es)%@\n", matched, shown < matched ? @" (truncated to 1000)" : @""];
}

static void stk_class(NSMutableString *out, NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { [out appendFormat:@"no such class: %@\n", name]; return; }
    [out appendFormat:@"%@  (instance size %zu bytes)\n", name, class_getInstanceSize(cls)];
    [out appendString:@"superclasses:"];
    for (Class c = class_getSuperclass(cls); c; c = class_getSuperclass(c))
        [out appendFormat:@" -> %s", class_getName(c)];
    [out appendString:@"\n"];
    unsigned int pc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(cls, &pc);
    if (pc) {
        [out appendString:@"protocols:"];
        for (unsigned int i = 0; i < pc; i++) [out appendFormat:@" %s", protocol_getName(protos[i])];
        [out appendString:@"\n"];
    }
    if (protos) free(protos);
    unsigned int mc = 0; Method *im = class_copyMethodList(cls, &mc); if (im) free(im);
    unsigned int cc = 0; Method *cm = class_copyMethodList(object_getClass(cls), &cc); if (cm) free(cm);
    [out appendFormat:@"%u instance method(s), %u class method(s)\n", mc, cc];
}

static void stk_methods(NSMutableString *out, NSString *name, NSString *filter) {
    Class cls = NSClassFromString(name);
    if (!cls) { [out appendFormat:@"no such class: %@\n", name]; return; }
    const char *f = filter.length ? filter.UTF8String : NULL;
    for (int pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? cls : object_getClass(cls);
        char prefix = pass == 0 ? '-' : '+';
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(target, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            const char *sn = sel_getName(method_getName(ms[i]));
            if (f && !strcasestr(sn, f)) continue;
            const char *types = method_getTypeEncoding(ms[i]);
            [out appendFormat:@"  %c %s  %s\n", prefix, sn, types ?: ""];
        }
        if (ms) free(ms);
    }
}

static void stk_method(NSMutableString *out, NSString *name, NSString *selName) {
    Class cls = NSClassFromString(name);
    if (!cls) { [out appendFormat:@"no such class: %@\n", name]; return; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    char kind = '-';
    if (!m) { m = class_getClassMethod(cls, sel); kind = '+'; }
    if (!m) { [out appendFormat:@"%@ has no method %@\n", name, selName]; return; }
    const char *types = method_getTypeEncoding(m);
    [out appendFormat:@"%c[%@ %@]  types=%s  imp=%p\n", kind, name, selName, types ?: "", (void *)method_getImplementation(m)];
}

static void stk_ivars(NSMutableString *out, NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { [out appendFormat:@"no such class: %@\n", name]; return; }
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int ic = 0;
        Ivar *iv = class_copyIvarList(c, &ic);
        if (ic) [out appendFormat:@"-- %s --\n", class_getName(c)];
        for (unsigned int i = 0; i < ic; i++) {
            [out appendFormat:@"  +%ld  %s  %s\n",
             ivar_getOffset(iv[i]), ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: ""];
        }
        if (iv) free(iv);
    }
}

static void stk_obj(NSMutableString *out, NSString *addrTok) {
    void *p = (void *)stk_addr(addrTok);
    if (!p) { [out appendString:@"usage: obj <addr>\n"]; return; }
    @try {
        id obj = (__bridge id)p;
        Class cls = object_getClass(obj);
        [out appendFormat:@"%p  %s\n", p, class_getName(cls)];
        [out appendFormat:@"desc: %@\n", stk_safe_desc(obj)];
        for (Class c = cls; c; c = class_getSuperclass(c)) {
            unsigned int ic = 0;
            Ivar *iv = class_copyIvarList(c, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *ty = ivar_getTypeEncoding(iv[i]);
                const char *nm = ivar_getName(iv[i]);
                ptrdiff_t off = ivar_getOffset(iv[i]);
                if (ty && ty[0] == '@') {
                    id val = object_getIvar(obj, iv[i]);
                    [out appendFormat:@"  +%td %s = %@ <%p>\n", off, nm,
                     val ? NSStringFromClass([val class]) : @"nil", (void *)val];
                } else {
                    long long raw = 0;
                    memcpy(&raw, (uint8_t *)p + off, MIN((size_t)8, (size_t)8));
                    [out appendFormat:@"  +%td %s (%s) = 0x%llx\n", off, nm, ty ?: "?", raw];
                }
            }
            if (iv) free(iv);
        }
    } @catch (NSException *e) {
        [out appendFormat:@"exception reading object: %@\n", e.reason];
    }
}

#pragma mark - UI hierarchy

static void stk_dump_view(NSMutableString *out, UIView *v, int depth, int maxDepth, int *budget, BOOL all) {
    if (*budget <= 0 || depth > maxDepth) return;
    (*budget)--;
    CGRect f = v.window ? [v convertRect:v.bounds toView:nil] : v.frame;
    NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    NSString *vc = @"";
    for (UIResponder *r = [v nextResponder]; r; r = [r nextResponder]) {
        if ([r isKindOfClass:[UIViewController class]]) { vc = [NSString stringWithFormat:@" vc=%@", NSStringFromClass([r class])]; break; }
    }
    NSString *aid = v.accessibilityIdentifier.length ? [NSString stringWithFormat:@" id=%@", v.accessibilityIdentifier] : @"";
    [out appendFormat:@"%@%@ <%p> {%.0f,%.0f,%.0f,%.0f}%@%@%@\n", ind, NSStringFromClass([v class]), v,
     f.origin.x, f.origin.y, f.size.width, f.size.height, v.hidden ? @" hidden" : @"", aid, vc];
    if (!all && v.hidden) return;
    for (UIView *s in v.subviews) stk_dump_view(out, s, depth + 1, maxDepth, budget, all);
}

static NSArray<UIWindow *> *stk_all_windows(void) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)sc).windows) [wins addObject:w];
    }
    return wins;
}

static void stk_uitree(NSMutableString *out, int maxDepth, int maxNodes, BOOL all) {
    stk_run_on_main_sync(^{
        int budget = maxNodes;
        NSArray<UIWindow *> *wins = stk_all_windows();
        [out appendFormat:@"%lu window(s)\n", (unsigned long)wins.count];
        for (UIWindow *w in wins) {
            [out appendFormat:@"== window %@ <%p> key=%d ==\n", NSStringFromClass([w class]), w, w.isKeyWindow];
            stk_dump_view(out, w, 0, maxDepth, &budget, all);
        }
    });
}

static void stk_dump_vc(NSMutableString *out, UIViewController *vc, int depth, int *budget) {
    if (*budget <= 0 || !vc) return;
    (*budget)--;
    NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ <%p>%@\n", ind, NSStringFromClass([vc class]), vc,
     vc.isViewLoaded ? @"" : @" (view not loaded)"];
    for (UIViewController *c in vc.childViewControllers) stk_dump_vc(out, c, depth + 1, budget);
    if (vc.presentedViewController) {
        [out appendFormat:@"%@  presented:\n", ind];
        stk_dump_vc(out, vc.presentedViewController, depth + 1, budget);
    }
}

static void stk_uivc(NSMutableString *out, int budgetNodes) {
    stk_run_on_main_sync(^{
        int budget = budgetNodes;
        for (UIWindow *w in stk_all_windows()) {
            if (!w.rootViewController) continue;
            [out appendFormat:@"== window %@ ==\n", NSStringFromClass([w class])];
            stk_dump_vc(out, w.rootViewController, 0, &budget);
        }
    });
}

static NSDictionary *stk_view_json(UIView *v, int depth, int maxDepth, int *budget) {
    if (*budget <= 0 || depth > maxDepth) return nil;
    (*budget)--;
    CGRect f = v.window ? [v convertRect:v.bounds toView:nil] : v.frame;
    NSMutableArray *kids = [NSMutableArray array];
    for (UIView *s in v.subviews) {
        NSDictionary *k = stk_view_json(s, depth + 1, maxDepth, budget);
        if (k) [kids addObject:k];
    }
    return @{
        @"class": NSStringFromClass([v class]),
        @"ptr": [NSString stringWithFormat:@"%p", v],
        @"frame": @[@(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height)],
        @"hidden": @(v.hidden),
        @"accessibilityIdentifier": v.accessibilityIdentifier ?: @"",
        @"subviews": kids,
    };
}

static void stk_uidump(NSMutableString *out, int maxDepth, int maxNodes) {
    __block NSString *path = [(NSString *)NSTemporaryDirectory() stringByAppendingPathComponent:@"striker-uidump.json"];
    stk_run_on_main_sync(^{
        int budget = maxNodes;
        NSMutableArray *windows = [NSMutableArray array];
        for (UIWindow *w in stk_all_windows()) {
            NSDictionary *tree = stk_view_json(w, 0, maxDepth, &budget);
            if (tree) [windows addObject:tree];
        }
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"windows": windows}
                                                       options:NSJSONWritingPrettyPrinted error:&err];
        if (data && [data writeToFile:path atomically:YES]) {
            [out appendFormat:@"wrote %lu bytes to %@\n", (unsigned long)data.length, path];
        } else {
            [out appendFormat:@"uidump failed: %@\n", err.localizedDescription ?: @"unknown"];
        }
    });
}

#pragma mark - typed messaging (NSInvocation)

static void stk_set_arg(NSInvocation *inv, NSUInteger idx, const char *ty, NSString *val) {
    while (*ty && strchr("rnNoORV", *ty)) ty++;
    switch (ty[0]) {
        case '@': {
            id o;
            if ([val hasPrefix:@"@\""] && val.length >= 3) o = [val substringWithRange:NSMakeRange(2, val.length - 3)];
            else {
                unichar c = val.length ? [val characterAtIndex:0] : 0;
                if (c == '0' || (c >= '1' && c <= '9')) o = (__bridge id)(void *)stk_addr(val);
                else { Class cls = NSClassFromString(val); o = cls ? (id)cls : (id)val; }
            }
            [inv setArgument:&o atIndex:idx]; break;
        }
        case 'B': case 'c': {
            char v = (char)([val isEqualToString:@"1"] || [val caseInsensitiveCompare:@"true"] == NSOrderedSame
                            || [val caseInsensitiveCompare:@"yes"] == NSOrderedSame ? 1 : (char)strtoll(val.UTF8String, NULL, 0));
            [inv setArgument:&v atIndex:idx]; break;
        }
        case 'i': { int v = (int)strtoll(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 's': { short v = (short)strtoll(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'l': { long v = (long)strtoll(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'q': { long long v = strtoll(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'C': { unsigned char v = (unsigned char)strtoull(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'I': { unsigned int v = (unsigned int)strtoull(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'S': { unsigned short v = (unsigned short)strtoull(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'L': { unsigned long v = (unsigned long)strtoull(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'Q': { unsigned long long v = strtoull(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
        case 'f': { float v = strtof(val.UTF8String, NULL); [inv setArgument:&v atIndex:idx]; break; }
        case 'd': { double v = strtod(val.UTF8String, NULL); [inv setArgument:&v atIndex:idx]; break; }
        case ':': { SEL s = NSSelectorFromString(val); [inv setArgument:&s atIndex:idx]; break; }
        case '#': { Class c = NSClassFromString(val); [inv setArgument:&c atIndex:idx]; break; }
        case '^': case '*': { void *v = (void *)stk_addr(val); [inv setArgument:&v atIndex:idx]; break; }
        default: { long long v = strtoll(val.UTF8String, NULL, 0); [inv setArgument:&v atIndex:idx]; break; }
    }
}

static void stk_print_return(NSMutableString *out, NSInvocation *inv) {
    const char *rt = inv.methodSignature.methodReturnType;
    while (*rt && strchr("rnNoORV", *rt)) rt++;
    switch (rt[0]) {
        case 'v': [out appendString:@"(void)\n"]; break;
        case '@': { __unsafe_unretained id r = nil; [inv getReturnValue:&r];
            [out appendFormat:@"<%p> %@: %@\n", (void *)r, r ? NSStringFromClass([r class]) : @"nil", r ? stk_safe_desc(r) : @""]; break; }
        case '#': { Class r = Nil; [inv getReturnValue:&r]; [out appendFormat:@"Class %s\n", r ? class_getName(r) : "nil"]; break; }
        case 'B': case 'c': { char r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%d\n", r]; break; }
        case 'i': { int r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%d\n", r]; break; }
        case 's': { short r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%d\n", r]; break; }
        case 'l': { long r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%ld\n", r]; break; }
        case 'q': { long long r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%lld (0x%llx)\n", r, r]; break; }
        case 'C': case 'I': case 'S': case 'L': case 'Q': {
            unsigned long long r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%llu (0x%llx)\n", r, r]; break; }
        case 'f': { float r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%f\n", r]; break; }
        case 'd': { double r = 0; [inv getReturnValue:&r]; [out appendFormat:@"%f\n", r]; break; }
        case '^': case '*': { void *r = NULL; [inv getReturnValue:&r]; [out appendFormat:@"%p\n", r]; break; }
        case '{': {
            if (strncmp(rt, "{CGRect", 7) == 0) { CGRect r = CGRectZero; [inv getReturnValue:&r];
                [out appendFormat:@"{%.1f,%.1f,%.1f,%.1f}\n", r.origin.x, r.origin.y, r.size.width, r.size.height]; }
            else { [out appendFormat:@"(struct %s, %lu bytes)\n", rt, (unsigned long)inv.methodSignature.methodReturnLength]; }
            break;
        }
        default: [out appendFormat:@"(return type %s)\n", rt]; break;
    }
}

static void stk_send(NSMutableString *out, NSArray<NSString *> *a, BOOL onMain) {
    if (a.count < 2) { [out appendString:@"usage: send <obj|Class> <selector> [args...]\n"]; return; }
    id target = stk_resolve(a[0]);
    if (!target) { [out appendFormat:@"no such object/class: %@\n", a[0]]; return; }
    SEL sel = NSSelectorFromString(a[1]);
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) { [out appendFormat:@"%@ does not respond to %@\n", a[0], a[1]]; return; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target; inv.selector = sel;
    NSUInteger provided = a.count - 2;
    for (NSUInteger i = 2; i < sig.numberOfArguments && (i - 2) < provided; i++)
        stk_set_arg(inv, i, [sig getArgumentTypeAtIndex:i], a[2 + (i - 2)]);
    void (^go)(void) = ^{ @try { [inv invoke]; } @catch (NSException *e) { [out appendFormat:@"exception: %@\n", e.reason]; } };
    if (onMain) stk_run_on_main_sync(go); else go();
    [out appendString:@"=> "];
    @try { stk_print_return(out, inv); } @catch (NSException *e) { [out appendFormat:@"(return read threw: %@)\n", e.reason]; }
}

#pragma mark - memory

static void stk_read(NSMutableString *out, uintptr_t addr, size_t len) {
    if (!addr || !len) { [out appendString:@"usage: read <addr> <len>\n"]; return; }
    if (len > 4096) len = 4096;
    @try {
        const uint8_t *p = (const uint8_t *)addr;
        for (size_t i = 0; i < len; i += 16) {
            [out appendFormat:@"%p  ", (void *)(addr + i)];
            for (size_t j = 0; j < 16 && i + j < len; j++) [out appendFormat:@"%02x ", p[i + j]];
            [out appendString:@"\n"];
        }
    } @catch (NSException *e) { [out appendFormat:@"read failed: %@\n", e.reason]; }
}

static void stk_write(NSMutableString *out, uintptr_t addr, NSString *hex) {
    if (!addr || !hex.length) { [out appendString:@"usage: write <addr> <hexbytes>\n"]; return; }
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@" " withString:@""] lowercaseString];
    if (clean.length % 2) { [out appendString:@"hex must be whole bytes\n"]; return; }
    @try {
        uint8_t *p = (uint8_t *)addr;
        for (NSUInteger i = 0; i < clean.length; i += 2)
            p[i / 2] = (uint8_t)strtoul([clean substringWithRange:NSMakeRange(i, 2)].UTF8String, NULL, 16);
        [out appendFormat:@"wrote %lu byte(s) to %p\n", (unsigned long)clean.length / 2, (void *)addr];
    } @catch (NSException *e) { [out appendFormat:@"write failed: %@\n", e.reason]; }
}

static void stk_vt(NSMutableString *out, uintptr_t addr, size_t count) {
    if (!addr) { [out appendString:@"usage: vt <addr> <count>\n"]; return; }
    if (count == 0 || count > 256) count = 16;
    @try {
        void **p = (void **)addr;
        for (size_t i = 0; i < count; i++) {
            Dl_info info;
            if (dladdr(p[i], &info) && info.dli_sname)
                [out appendFormat:@"  [%zu] +0x%zx = %p  %s\n", i, i * sizeof(void *), p[i], info.dli_sname];
            else
                [out appendFormat:@"  [%zu] +0x%zx = %p\n", i, i * sizeof(void *), p[i]];
        }
    } @catch (NSException *e) { [out appendFormat:@"vt failed: %@\n", e.reason]; }
}

#pragma mark - heap instances (experimental)

static Class g_inst_target;
static int g_inst_max;
static NSMutableArray<NSString *> *g_inst_results;
static CFMutableSetRef g_class_set;

static void stk_build_class_set(void) {
    if (g_class_set) return;
    g_class_set = CFSetCreateMutable(NULL, 0, NULL);
    unsigned int n = 0; Class *cl = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) CFSetAddValue(g_class_set, (__bridge const void *)cl[i]);
    if (cl) free(cl);
}

static kern_return_t stk_reader(task_t task, vm_address_t addr, vm_size_t size, void **ptr) {
    (void)task; (void)size; *ptr = (void *)addr; return KERN_SUCCESS;
}

static void stk_range_cb(task_t task, void *ctx, unsigned type, vm_range_t *ranges, unsigned count) {
    (void)task; (void)ctx; (void)type;
    for (unsigned i = 0; i < count; i++) {
        if ((int)g_inst_results.count >= g_inst_max) return;
        vm_range_t r = ranges[i];
        if (r.size < 16) continue;
        @try {
            void *isaPtr = *(void **)r.address;
            if (!CFSetContainsValue(g_class_set, isaPtr)) continue;
            id obj = (__bridge id)(void *)r.address;
            if ([obj isKindOfClass:g_inst_target])
                [g_inst_results addObject:[NSString stringWithFormat:@"%p  %s", (void *)r.address, class_getName(object_getClass(obj))]];
        } @catch (NSException *e) { /* skip candidate */ }
    }
}

static void stk_instances(NSMutableString *out, NSString *name, int max) {
    Class t = NSClassFromString(name);
    if (!t) { [out appendFormat:@"no such class: %@\n", name]; return; }
    stk_build_class_set();
    g_inst_target = t; g_inst_max = max > 0 ? max : 50; g_inst_results = [NSMutableArray array];
    vm_address_t *zones = NULL; unsigned int zc = 0;
    malloc_get_all_zones(mach_task_self(), stk_reader, &zones, &zc);
    for (unsigned int i = 0; i < zc; i++) {
        malloc_zone_t *z = (malloc_zone_t *)zones[i];
        if (z && z->introspect && z->introspect->enumerator) {
            @try { z->introspect->enumerator(mach_task_self(), NULL, MALLOC_PTR_IN_USE_RANGE_TYPE,
                                              (vm_address_t)z, stk_reader, stk_range_cb); }
            @catch (NSException *e) { /* zone skipped */ }
        }
    }
    [out appendFormat:@"%lu instance(s) of %@:\n", (unsigned long)g_inst_results.count, name];
    for (NSString *s in g_inst_results) [out appendFormat:@"  %@\n", s];
    g_inst_results = nil;
}

#pragma mark - files

static void stk_ls(NSMutableString *out, NSString *path) {
    if (!path.length) path = NSHomeDirectory();
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    if (!items) { [out appendFormat:@"ls failed: %@\n", err.localizedDescription]; return; }
    for (NSString *it in [items sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *full = [path stringByAppendingPathComponent:it];
        BOOL dir = NO; [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&dir];
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
        [out appendFormat:@"  %@%@  %@\n", it, dir ? @"/" : @"", dir ? @"" : [NSString stringWithFormat:@"(%@ bytes)", attr[NSFileSize] ?: @"?"]];
    }
}

static void stk_home(NSMutableString *out) {
    [out appendFormat:@"home: %@\n", NSHomeDirectory()];
    [out appendFormat:@"docs: %@\n", NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"?"];
    [out appendFormat:@"tmp:  %@\n", NSTemporaryDirectory()];
    [out appendFormat:@"bundle: %@\n", [NSBundle mainBundle].bundlePath];
}

static void stk_logtail(NSMutableString *out, size_t want, NSString *path) {
    if (!path.length) path = [(NSString *)NSTemporaryDirectory() stringByAppendingPathComponent:@"striker.log"];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content) { [out appendFormat:@"no file at %@\n", path]; return; }
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSUInteger n = want ?: 40;
    NSUInteger start = lines.count > n ? lines.count - n : 0;
    for (NSUInteger i = start; i < lines.count; i++) [out appendFormat:@"%@\n", lines[i]];
}

#pragma mark - dispatch + server

static void stk_dispatch(const char *line, NSMutableString *out) {
    NSArray<NSString *> *t = stk_tokens(line);
    if (t.count == 0) return;
    NSString *cmd = t[0];
    NSArray<NSString *> *a = [t subarrayWithRange:NSMakeRange(1, t.count - 1)];
    NSString *(^arg)(NSUInteger) = ^NSString *(NSUInteger i) { return i < a.count ? a[i] : @""; };

    if ([cmd isEqualToString:@"help"]) stk_help(out);
    else if ([cmd isEqualToString:@"images"]) stk_images(out);
    else if ([cmd isEqualToString:@"classes"]) stk_classes(out, arg(0));
    else if ([cmd isEqualToString:@"class"]) stk_class(out, arg(0));
    else if ([cmd isEqualToString:@"methods"]) stk_methods(out, arg(0), arg(1));
    else if ([cmd isEqualToString:@"method"]) stk_method(out, arg(0), arg(1));
    else if ([cmd isEqualToString:@"ivars"]) stk_ivars(out, arg(0));
    else if ([cmd isEqualToString:@"instances"]) stk_instances(out, arg(0), (int)stk_addr(arg(1)));
    else if ([cmd isEqualToString:@"obj"]) stk_obj(out, arg(0));
    else if ([cmd isEqualToString:@"uitree"]) stk_uitree(out, a.count > 0 ? (int)stk_addr(arg(0)) : 40, a.count > 1 ? (int)stk_addr(arg(1)) : 4000, [arg(2) isEqualToString:@"all"]);
    else if ([cmd isEqualToString:@"uivc"]) stk_uivc(out, 4000);
    else if ([cmd isEqualToString:@"uidump"]) stk_uidump(out, a.count > 0 ? (int)stk_addr(arg(0)) : 60, a.count > 1 ? (int)stk_addr(arg(1)) : 20000);
    else if ([cmd isEqualToString:@"send"]) stk_send(out, a, NO);
    else if ([cmd isEqualToString:@"sendq"]) stk_send(out, a, YES);
    else if ([cmd isEqualToString:@"read"]) stk_read(out, stk_addr(arg(0)), (size_t)stk_addr(arg(1)));
    else if ([cmd isEqualToString:@"write"]) stk_write(out, stk_addr(arg(0)), arg(1));
    else if ([cmd isEqualToString:@"vt"]) stk_vt(out, stk_addr(arg(0)), (size_t)stk_addr(arg(1)));
    else if ([cmd isEqualToString:@"ls"]) stk_ls(out, arg(0));
    else if ([cmd isEqualToString:@"home"]) stk_home(out);
    else if ([cmd isEqualToString:@"logtail"]) stk_logtail(out, (size_t)stk_addr(arg(0)), arg(1));
    else [out appendFormat:@"unknown command: %@ (try 'help')\n", cmd];
}

char *StrikerRunLine(const char *line) {
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        @try { stk_dispatch(line ?: "", out); }
        @catch (NSException *e) { [out appendFormat:@"!! %@: %@\n", e.name, e.reason]; }
        return strdup(out.UTF8String ?: "");
    }
}

void StrikerFree(char *result) { if (result) free(result); }

static int g_listen_fd = -1;
static volatile int g_running = 0;
static uint16_t g_port = 0;

static void stk_send_all(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) { ssize_t n = send(fd, buf + off, len - off, 0); if (n <= 0) break; off += (size_t)n; }
}

static void *stk_client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    struct timeval tv = { .tv_sec = 300, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char line[16384];
    while (g_running) {
        size_t len = 0; int ok = 0;
        while (len < sizeof(line) - 1) {
            char c; ssize_t n = recv(fd, &c, 1, 0);
            if (n <= 0) { ok = -1; break; }
            if (c == '\n') { ok = 1; break; }
            if (c != '\r') line[len++] = c;
        }
        if (ok <= 0) break;
        line[len] = '\0';
        char *res = (len == 0) ? strdup("") : StrikerRunLine(line);
        if (res) { stk_send_all(fd, res, strlen(res)); StrikerFree(res); }
        char eot = 0x04; stk_send_all(fd, &eot, 1);
    }
    close(fd);
    return NULL;
}

static void *stk_listen_thread(void *arg) {
    (void)arg;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { g_running = 0; return NULL; }
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_port = htons(g_port); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); g_running = 0; return NULL; }
    if (listen(fd, 4) < 0) { close(fd); g_running = 0; return NULL; }
    g_listen_fd = fd;
    NSLog(@"[Striker] listening on 127.0.0.1:%u", g_port);
    while (g_running) {
        int cfd = accept(fd, NULL, NULL);
        if (cfd < 0) { if (g_running) continue; else break; }
        pthread_t th; if (pthread_create(&th, NULL, stk_client_thread, (void *)(intptr_t)cfd) == 0) pthread_detach(th);
        else close(cfd);
    }
    close(fd); g_listen_fd = -1;
    return NULL;
}

void StrikerStartOnPort(uint16_t port) {
    if (g_running) return;
    g_running = 1;
    g_port = port ? port : STRIKER_DEFAULT_PORT;
    pthread_t th;
    if (pthread_create(&th, NULL, stk_listen_thread, NULL) == 0) pthread_detach(th);
    else g_running = 0;
}

void StrikerStart(void) { StrikerStartOnPort(STRIKER_DEFAULT_PORT); }

void StrikerStop(void) {
    g_running = 0;
    if (g_listen_fd >= 0) { close(g_listen_fd); g_listen_fd = -1; }
}
