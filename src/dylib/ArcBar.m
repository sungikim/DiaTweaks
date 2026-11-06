// Arc-style sidebar URL bar (with back/forward/reload by the traffic lights) and command bar
// (⌘T new tab, ⌘L current tab): open tabs, history, bookmarks, Dia's menu commands, chrome:// pages.
//
// Ported from daypatch (https://github.com/TA3/daypatch), src/Sidebar.m, src/CommandBar.m,
// src/CommandSources.m and parts of src/Common.m and src/NavBar.m.
//
// MIT License
//
// Copyright (c) 2026 The daypatch contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
// associated documentation files (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge, publish, distribute,
// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
// NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#import "ArcBar.h"
#import <objc/runtime.h>
#include <sqlite3.h>

static BOOL gSidebarOn, gCommandOn, gExtensionsOn;

static NSColor *dyn(CGFloat dw, CGFloat da, CGFloat lw, CGFloat la) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [[a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:dw alpha:da] : [NSColor colorWithWhite:lw alpha:la];
    }];
}

#pragma mark - Helpers

static NSView *childOfClass(NSView *parent, NSString *className) {
    for (NSView *s in parent.subviews)
        if ([NSStringFromClass(s.class) isEqualToString:className]) return s;
    return nil;
}

static NSView *descendantOfClass(NSView *root, NSString *className) {
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (NSView *s in root.subviews) {
        NSView *hit = descendantOfClass(s, className);
        if (hit) return hit;
    }
    return nil;
}

static void collectOfClass(NSView *root, NSString *className, NSMutableArray<NSView *> *out) {
    if ([NSStringFromClass(root.class) isEqualToString:className]) [out addObject:root];
    for (NSView *s in root.subviews) collectOfClass(s, className, out);
}

static Class findClass(NSString *prefix, NSString *suffix) {
    // Private Swift classes carry a per-build hash, so scan by prefix and suffix.
    unsigned n = 0;
    Class *all = objc_copyClassList(&n);
    Class found = nil;
    for (unsigned i = 0; i < n && !found; i++) {
        const char *name = class_getName(all[i]);
        if (strncmp(name, prefix.UTF8String, prefix.length) == 0 && [@(name) hasSuffix:suffix]) found = all[i];
    }
    free(all);
    return found;
}

// isKindOfClass: rather than the class name, which KVO observers change.
static BOOL isBrowserWindow(NSWindow *window) {
    static Class cls;
    cls = cls ?: NSClassFromString(@"Window.PlatformWindow");
    return window && cls && [window isKindOfClass:cls];
}

// Dia's scripting bridge: the active tab object for a window (DiaAppleScriptTab), or nil.
static id activeTabForWindow(NSWindow *window) {
    NSString *wid = window.identifier;
    if (!wid) return nil;
    @try {
        for (id sw in [NSApp valueForKey:@"appleScriptWindows"])
            if ([[sw valueForKey:@"windowId"] isEqual:wid]) return [sw valueForKey:@"activeTab"];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *urlForWindow(NSWindow *window) {
    @try {
        id u = [activeTabForWindow(window) valueForKey:@"URL"];
        return [u isKindOfClass:NSString.class] ? u : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// "host" or "host:port" from the start of a scheme-less address, and its port ("" if none).
// IPv6 hosts keep their brackets: "[::1]:8080" -> "[::1]", "8080".
static NSString *splitHost(NSString *s, NSString **port) {
    NSString *authority = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]].firstObject lowercaseString];
    *port = @"";
    if ([authority hasPrefix:@"["]) {
        NSRange close = [authority rangeOfString:@"]"];
        if (close.location == NSNotFound) return authority;
        NSString *rest = [authority substringFromIndex:NSMaxRange(close)];
        if ([rest hasPrefix:@":"]) *port = [rest substringFromIndex:1];
        else if (rest.length) *port = rest;   // junk after "]": not a valid port
        return [authority substringToIndex:NSMaxRange(close)];
    }
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) return authority;
    *port = [authority substringFromIndex:colon.location + 1];
    return [authority substringToIndex:colon.location];
}

static BOOL isPort(NSString *p) {
    return p.length && p.length <= 5 && [p rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

// Hosts on this machine or the local network, which usually only speak http.
static BOOL isLocalHost(NSString *host) {
    if ([host hasPrefix:@"["]) return YES;   // IPv6 literal, e.g. [::1]
    if ([host isEqualToString:@"localhost"] || ![host containsString:@"."]) return YES;   // "localhost", "nas"
    for (NSString *suffix in @[@".localhost", @".local", @".lan", @".home", @".home.arpa", @".internal", @".localdomain", @".test"])
        if ([host hasSuffix:suffix]) return YES;
    NSArray *octets = [host componentsSeparatedByString:@"."];
    if (octets.count != 4) return NO;
    for (NSString *o in octets) if (!isPort(o)) return NO;   // digits only
    NSInteger a = [octets[0] integerValue], b = [octets[1] integerValue];
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127);
}

// "https://x", "about:blank", "view-source:...": typed with a scheme, opened as is.
static BOOL hasScheme(NSString *s) {
    static NSRegularExpression *scheme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ scheme = [NSRegularExpression regularExpressionWithPattern:@"^([a-zA-Z][a-zA-Z0-9+.-]*):(//)?\\S*$" options:0 error:nil]; });
    NSTextCheckingResult *m = [scheme firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return NO;
    if ([m rangeAtIndex:2].location != NSNotFound) return YES;
    return [@[@"about", @"chrome", @"file", @"mailto", @"javascript", @"data", @"blob", @"view-source", @"tel"]
               containsObject:[s substringWithRange:[m rangeAtIndex:1]].lowercaseString];
}

// "github.com", "localhost:3000", "nas:5000/x", "10.0.0.2", "[::1]".
static BOOL looksLikeAddress(NSString *s) {
    if (!s.length || [s rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) return NO;
    if (hasScheme(s)) return YES;
    NSString *port, *host = splitHost(s, &port);
    if (port.length && !isPort(port)) return NO;
    if ([host hasPrefix:@"["]) return [host hasSuffix:@"]"] && host.length > 2;
    if (!host.length || [host hasPrefix:@"."] || [host hasSuffix:@"."]) return NO;
    if ([host isEqualToString:@"localhost"] || port.length) return YES;
    NSArray *octets = [host componentsSeparatedByString:@"."];
    if (octets.count == 4 && [[octets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *o, id b) { return isPort(o) && o.length <= 3; }]] count] == 4)
        return YES;
    NSRange dot = [host rangeOfString:@"." options:NSBackwardsSearch];
    return dot.location != NSNotFound && host.length - dot.location - 1 >= 2;
}

// Typed text -> URL, or nil if it reads as a search. Local hosts get http, others https.
static NSString *resolveURL(NSString *input) {
    NSString *s = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!looksLikeAddress(s)) return nil;
    if (hasScheme(s)) return s;
    NSString *port;
    return [(isLocalHost(splitHost(s, &port)) ? @"http://" : @"https://") stringByAppendingString:s];
}

// Same, but a search falls back to Google.
static NSString *resolveInput(NSString *input) {
    NSString *url = resolveURL(input);
    if (url) return url;
    NSString *s = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length) return nil;
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    NSString *q = [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];  // nil for a lone UTF-16 surrogate
    return q ? [@"https://www.google.com/search?q=" stringByAppendingString:q] : nil;
}

static void navigateWindow(NSWindow *window, NSString *url) {
    id tab = activeTabForWindow(window);
    if (!url.length || !tab) return;
    @try { [tab setValue:url forKey:@"URL"]; }
    @catch (NSException *e) { NSLog(@"[DiaPatches] navigate failed: %@", e); }
}

static NSString *scriptString(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// Dia's scripting interface, called in-process (AppleEvents to self need no permission).
static void runScript(NSString *source) {
    NSDictionary *error = nil;
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    if (error) NSLog(@"[DiaPatches] script failed: %@", error[NSAppleScriptErrorMessage]);
}

// This app by path, not bundle ID: with another Dia running (the original, or a second copy),
// the bundle ID could reach the wrong one.
static NSString *selfApp(void) {
    return [NSString stringWithFormat:@"application \"%@\"", scriptString(NSBundle.mainBundle.bundlePath)];
}

static void openInNewTab(NSWindow *window, NSString *url) {
    if (!window.identifier || !url.length) return;
    runScript([NSString stringWithFormat:@"tell %@\n"
               "  tell (first window whose id is \"%@\") to make new tab with properties {URL:\"%@\"}\n"
               "end tell", selfApp(), scriptString(window.identifier), scriptString(url)]);
}

static void focusTab(NSString *windowId, NSString *tabId) {
    if (!windowId || !tabId) return;
    runScript([NSString stringWithFormat:@"tell %@\n"
               "  focus (first tab of (first window whose id is \"%@\") whose id is \"%@\")\n"
               "end tell", selfApp(), scriptString(windowId), scriptString(tabId)]);
}

#pragma mark - Back, forward, reload

static NSView *focusedPane(NSWindow *window) {
    NSMutableArray<NSView *> *panes = [NSMutableArray array];
    collectOfClass(window.contentView, @"ContentPane.ContentPaneView", panes);
    id responder = window.firstResponder;
    NSView *fallback = nil;
    for (NSView *pane in panes) {
        if (pane.isHiddenOrHasHiddenAncestor) continue;
        if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:pane]) return pane;
        if (!fallback) fallback = pane;
    }
    return fallback;
}

static void navigationPerform(NSWindow *window, NSInteger index) {  // 0 back, 1 forward, 2 reload
    // Dia's own buttons in the (possibly hidden) toolbar, so behaviour matches the stock bar.
    NSView *pane = focusedPane(window);
    NSView *bar = childOfClass(pane, @"NavigationBar.NavigationBarView");
    NSMutableArray<NSControl *> *controls = [NSMutableArray array];
    for (NSView *row in bar.subviews)
        for (NSView *v in row.subviews)
            if ([NSStringFromClass(v.class) containsString:@"InteractiveIconControl"] && [v isKindOfClass:NSControl.class])
                [controls addObject:(NSControl *)v];
    if (index < (NSInteger)controls.count && controls[index].action) {
        [controls[index] sendAction:controls[index].action to:controls[index].target];
        return;
    }
    if (index < 2) {
        SEL sel = NSSelectorFromString(index == 0 ? @"navigateTabBack:" : @"navigateTabForward:");
        NSView *web = descendantOfClass(pane, @"WebContentsPaneHostView");
        for (NSResponder *r = web ?: window.firstResponder; r; r = r.nextResponder)
            if ([r respondsToSelector:sel]) { [NSApp sendAction:sel to:r from:nil]; return; }
    } else {
        NSString *url = urlForWindow(window);
        if (url) navigateWindow(window, url);
    }
}

#pragma mark - Command bar sources

typedef NS_ENUM(NSInteger, DPItemKind) {
    DPItemSearch,
    DPItemURL,       // what was typed, when it looks like an address
    DPItemCommand,   // a Dia menu command
    DPItemPage,      // a chrome:// page
    DPItemTab,       // an open tab
    DPItemBookmark,
    DPItemHistory,
};

@interface DPCommandItem : NSObject
@property (nonatomic) DPItemKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;     // URL, shortcut, or "Switch to Tab"
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *symbol;     // SF Symbol when there's no favicon
@property (nonatomic, strong) NSMenuItem *menuItem;
@property (nonatomic, copy) NSString *tabId;
@property (nonatomic, copy) NSString *windowId;
@property (nonatomic) double score;
@property (nonatomic) double frecency;            // history/bookmark/tab prior
@end

@implementation DPCommandItem
@end

// The profile Dia used last, where its History, Bookmarks and Favicons live.
static NSString *profileDir(void) {
    NSString *userData = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Dia/User Data"];
    NSData *data = [NSData dataWithContentsOfFile:[userData stringByAppendingPathComponent:@"Local State"]];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id profile = [state isKindOfClass:NSDictionary.class] ? state[@"profile"] : nil;
    id last = [profile isKindOfClass:NSDictionary.class] ? profile[@"last_used"] : nil;
    BOOL isDir = NO;
    if ([last isKindOfClass:NSString.class] && [last length] && ![last hasPrefix:@"."] && ![last containsString:@"/"] &&
        [NSFileManager.defaultManager fileExistsAtPath:[userData stringByAppendingPathComponent:last] isDirectory:&isDir] && isDir)
        return [userData stringByAppendingPathComponent:last];
    return [userData stringByAppendingPathComponent:@"Default"];
}

// How well `words` match an item: every word must appear in the title or URL; word-prefix
// and host-prefix hits count more than mid-word hits.
static double matchScore(NSArray<NSString *> *words, NSString *title, NSString *url) {
    NSString *t = title.lowercaseString ?: @"";
    NSString *u = url.lowercaseString ?: @"";
    NSString *host = [NSURL URLWithString:url].host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    double score = 0;
    for (NSString *w in words) {
        double best = 0;
        if ([host hasPrefix:w]) best = 4;
        else if ([t hasPrefix:w]) best = 4;
        else if ([t rangeOfString:[@" " stringByAppendingString:w]].location != NSNotFound) best = 3;
        else if ([t containsString:w]) best = 1.5;
        else if ([host containsString:w]) best = 1.5;
        else if ([u containsString:w]) best = 0.8;
        if (best == 0) return 0;
        score += best;
    }
    NSString *q = [words componentsJoinedByString:@" "];
    if ([t isEqualToString:q]) score += 4;
    else if ([t hasPrefix:q]) score += 2;
    return score;
}

static NSString *shortcutString(NSMenuItem *item) {
    if (!item.keyEquivalent.length) return @"";
    NSMutableString *s = [NSMutableString string];
    NSEventModifierFlags m = item.keyEquivalentModifierMask;
    if (m & NSEventModifierFlagControl) [s appendString:@"⌃"];
    if (m & NSEventModifierFlagOption) [s appendString:@"⌥"];
    if (m & NSEventModifierFlagShift) [s appendString:@"⇧"];
    if (m & NSEventModifierFlagCommand) [s appendString:@"⌘"];
    NSString *k = item.keyEquivalent;
    NSDictionary *names = @{@"\r": @"↩", @"\t": @"⇥", @" ": @"Space", @"\x1b": @"⎋", @"\x7f": @"⌫",
                            [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]: @"←",
                            [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]: @"→",
                            [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]: @"↑",
                            [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]: @"↓"};
    [s appendString:names[k] ?: k.uppercaseString];
    return s;
}

static NSString *likeEscape(NSString *s) {
    return [[[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"%" withString:@"\\%"]
            stringByReplacingOccurrencesOfString:@"_" withString:@"\\_"];
}

@interface DPCommandSources : NSObject
- (void)useCurrentProfile;
- (NSImage *)faviconFor:(NSString *)url;
+ (void)learnSiteIcons;
@end

@implementation DPCommandSources {
    NSArray<DPCommandItem *> *_commands, *_pages, *_tabs, *_bookmarks;
    NSString *_searchTemplate, *_activeURL, *_profile;
    dispatch_queue_t _queue;
    _Atomic NSUInteger _generation;  // read on the history queue to skip superseded queries
    NSCache<NSString *, id> *_icons;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("DiaPatches.history", DISPATCH_QUEUE_SERIAL);
        _icons = [NSCache new];
    }
    return self;
}

// Snapshot of commands, tabs and bookmarks taken when the bar opens.
- (void)prepareForWindow:(NSWindow *)window {
    [self useCurrentProfile];
    _commands = [self loadCommands];
    _pages = [self loadPages];
    _tabs = [self loadTabs];
    _bookmarks = [self loadBookmarks];              // new bookmarks and search engine changes show up
    _searchTemplate = [self loadSearchTemplate];
    _activeURL = urlForWindow(window);
    [_icons removeAllObjects];   // drop remembered misses: sites may have icons by now
    [DPCommandSources learnSiteIcons];
}

// Every enabled, visible command in Dia's menus, including submenus.
- (NSArray<DPCommandItem *> *)loadCommands {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSSet *skipMenus = [NSSet setWithArray:@[@"Services", @"Open Recent", @"Help"]];
    NSSet *topTitles = [NSSet setWithArray:[NSApp.mainMenu.itemArray valueForKey:@"title"]];
    __block void (^walk)(NSMenu *, NSString *) = nil;
    void (^__block __weak weakWalk)(NSMenu *, NSString *);
    weakWalk = walk = ^(NSMenu *menu, NSString *path) {
        [menu update];  // runs Dia's validation so isEnabled is current
        for (NSMenuItem *i in menu.itemArray) {
            if (i.isSeparatorItem || i.isHidden || !i.title.length) continue;
            if (i.submenu) {
                if (![skipMenus containsObject:i.title]) weakWalk(i.submenu, i.title);
                continue;
            }
            if (!i.action || !i.isEnabled || i.action == @selector(makeKeyAndOrderFront:)) continue;
            // Never offer quitting: a stray Return on a loose match closed Dia.
            if (i.action == @selector(terminate:) || [i.keyEquivalent isEqualToString:@"q"]) continue;
            NSString *title = [i.title stringByReplacingOccurrencesOfString:@"…" withString:@""];
            if (![topTitles containsObject:path]) title = [NSString stringWithFormat:@"%@ › %@", path, title];
            if ([seen containsObject:title]) continue;
            [seen addObject:title];
            DPCommandItem *it = [DPCommandItem new];
            it.kind = DPItemCommand;
            it.title = title;
            it.detail = shortcutString(i);
            it.menuItem = i;
            it.symbol = [self symbolForCommand:title];
            [out addObject:it];
        }
    };
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        if (top.submenu) walk(top.submenu, top.title);
    walk = nil;
    return out;
}

- (NSString *)symbolForCommand:(NSString *)t {
    NSDictionary *map = @{@"Settings": @"gearshape", @"New Window": @"macwindow.badge.plus", @"New Tab": @"plus.square",
                          @"Close Tab": @"xmark.square", @"Reopen Closed Tab": @"arrow.uturn.backward.square",
                          @"Print": @"printer", @"Copy URL": @"link", @"Find": @"magnifyingglass", @"Reload": @"arrow.clockwise",
                          @"Downloads": @"arrow.down.circle", @"History": @"clock", @"Bookmarks": @"bookmark",
                          @"Extensions": @"puzzlepiece.extension", @"Quit Dia": @"power", @"Zoom In": @"plus.magnifyingglass",
                          @"Zoom Out": @"minus.magnifyingglass", @"Developer Tools": @"hammer", @"Task Manager": @"chart.bar"};
    for (NSString *k in map) if ([t hasPrefix:k]) return map[k];
    return @"command";
}

- (NSArray<DPCommandItem *> *)loadPages {
    NSArray *pages = @[
        @[@"Chrome Flags", @"chrome://flags", @"flag"],
        @[@"Extensions", @"chrome://extensions", @"puzzlepiece.extension"],
        @[@"Downloads", @"chrome://downloads", @"arrow.down.circle"],
        @[@"History", @"chrome://history", @"clock"],
        @[@"Bookmarks", @"chrome://bookmarks", @"bookmark"],
        @[@"Passwords", @"chrome://password-manager", @"key"],
        @[@"Clear Browsing Data", @"chrome://settings/clearBrowserData", @"trash"],
        @[@"Privacy and Security", @"chrome://settings/privacy", @"hand.raised"],
        @[@"Site Settings", @"chrome://settings/content", @"slider.horizontal.3"],
        @[@"Cookies and Site Data", @"chrome://settings/cookies", @"circle.hexagongrid"],
        @[@"Search Engines", @"chrome://settings/searchEngines", @"magnifyingglass"],
        @[@"Autofill and Addresses", @"chrome://settings/addresses", @"person.text.rectangle"],
        @[@"Payment Methods", @"chrome://settings/payments", @"creditcard"],
        @[@"Version", @"chrome://version", @"info.circle"],
        @[@"GPU", @"chrome://gpu", @"cpu"],
        @[@"Inspect Devices", @"chrome://inspect", @"hammer"],
        @[@"Net Internals", @"chrome://net-internals", @"network"],
    ];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *p in pages) {
        DPCommandItem *it = [DPCommandItem new];
        it.kind = DPItemPage;
        it.title = p[0];
        it.url = p[1];
        it.detail = p[1];
        it.symbol = p[2];
        [out addObject:it];
    }
    return out;
}

- (NSArray<DPCommandItem *> *)loadTabs {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        for (id sw in [NSApp valueForKey:@"appleScriptWindows"]) {
            NSString *wid = [sw valueForKey:@"windowId"];
            for (id tab in [sw valueForKey:@"appleScriptTabs"]) {
                NSString *url = [tab valueForKey:@"URL"];
                if (![url isKindOfClass:NSString.class] || !url.length || [url hasPrefix:@"dia://"]) continue;
                DPCommandItem *it = [DPCommandItem new];
                it.kind = DPItemTab;
                it.title = [tab valueForKey:@"title"] ?: url;
                it.url = url;
                it.detail = @"Switch to Tab";
                it.tabId = [tab valueForKey:@"tabId"];
                it.windowId = wid;
                it.symbol = @"square.on.square";
                it.frecency = 3.0;  // open tabs are usually what you're looking for
                [out addObject:it];
            }
        }
    } @catch (__unused NSException *e) {}
    return out;
}

- (NSArray<DPCommandItem *> *)loadBookmarks {
    NSData *data = [NSData dataWithContentsOfFile:[_profile stringByAppendingPathComponent:@"Bookmarks"]];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray *out = [NSMutableArray array];
    __block void (^walk)(NSDictionary *) = nil;
    void (^__block __weak weakWalk)(NSDictionary *);
    weakWalk = walk = ^(NSDictionary *node) {
        if ([node[@"type"] isEqual:@"url"] && [node[@"url"] isKindOfClass:NSString.class]) {
            DPCommandItem *it = [DPCommandItem new];
            it.kind = DPItemBookmark;
            it.title = node[@"name"];
            it.url = node[@"url"];
            it.detail = node[@"url"];
            it.symbol = @"bookmark";
            it.frecency = 1.0;
            [out addObject:it];
        }
        for (NSDictionary *c in node[@"children"]) if ([c isKindOfClass:NSDictionary.class]) weakWalk(c);
    };
    if ([json isKindOfClass:NSDictionary.class])
        for (NSDictionary *root in [json[@"roots"] allValues]) if ([root isKindOfClass:NSDictionary.class]) walk(root);
    walk = nil;
    return out;
}

// Dia's default search engine, from the profile's Preferences and Web Data.
- (NSString *)loadSearchTemplate {
    NSString *fallback = @"https://www.google.com/search?q={searchTerms}";
    NSData *prefs = [NSData dataWithContentsOfFile:[_profile stringByAppendingPathComponent:@"Preferences"]];
    NSDictionary *p = prefs ? [NSJSONSerialization JSONObjectWithData:prefs options:0 error:nil] : nil;
    NSString *guid = [p isKindOfClass:NSDictionary.class] ? p[@"default_search_provider"][@"guid"] : nil;
    if (![guid isKindOfClass:NSString.class]) return fallback;
    __block NSString *url = nil;
    [self sqlite:@"Web Data" query:@"SELECT url FROM keywords WHERE sync_guid = ?1 LIMIT 1" bind:@[guid] row:^(sqlite3_stmt *s) {
        url = @((const char *)sqlite3_column_text(s, 0) ?: "");
    }];
    return url.length ? url : fallback;
}

- (NSString *)searchURLFor:(NSString *)text {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    // nil for a lone surrogate; replacing with nil would throw.
    NSString *q = [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString *u = [_searchTemplate ?: @"https://www.google.com/search?q={searchTerms}" stringByReplacingOccurrencesOfString:@"{searchTerms}" withString:q];
    u = [u stringByReplacingOccurrencesOfString:@"{google:baseURL}" withString:@"https://www.google.com/"];
    NSRegularExpression *placeholder = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}" options:0 error:nil];
    u = [placeholder stringByReplacingMatchesInString:u options:0 range:NSMakeRange(0, u.length) withTemplate:@""];
    while ([u hasSuffix:@"&"]) u = [u substringToIndex:u.length - 1];
    return u;
}

- (NSString *)searchEngineName {
    NSString *host = [NSURL URLWithString:[self searchURLFor:@"x"]].host;
    for (NSString *n in @[@"Google", @"DuckDuckGo", @"Bing", @"Brave", @"Ecosia", @"Kagi", @"Perplexity", @"Startpage", @"Naver"])
        if ([host.lowercaseString containsString:n.lowercaseString]) return n;
    return host ?: @"the web";
}

// Read-only and immutable, so Dia's databases are never locked.
- (void)sqlite:(NSString *)file query:(NSString *)sql bind:(NSArray *)args row:(void (^)(sqlite3_stmt *))row {
    NSString *path = [_profile stringByAppendingPathComponent:file];
    NSString *uri = [NSString stringWithFormat:@"file:%@?immutable=1", [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) { sqlite3_close(db); return; }
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
        for (int i = 0; i < (int)args.count; i++) {
            if ([args[i] isKindOfClass:NSNumber.class]) sqlite3_bind_int64(st, i + 1, [args[i] longLongValue]);
            else sqlite3_bind_text(st, i + 1, [args[i] UTF8String], -1, SQLITE_TRANSIENT);
        }
        while (sqlite3_step(st) == SQLITE_ROW) row(st);
    }
    sqlite3_finalize(st);
    sqlite3_close(db);
}

- (NSArray<DPCommandItem *> *)historyFor:(NSArray<NSString *> *)words {
    if (!words.count) return @[];
    // Every word must appear in the URL or title; ranked by typed count, visits, recency.
    NSMutableString *where = [NSMutableString stringWithString:@"hidden = 0"];
    NSMutableArray *args = [NSMutableArray array];
    for (NSString *w in words) {
        // SQLite's LIKE folds ASCII case only, so non-ASCII words also try their upper and capitalized forms.
        NSArray *forms = [w canBeConvertedToEncoding:NSASCIIStringEncoding] ? @[w] : @[w, w.uppercaseString, w.capitalizedString];
        NSMutableString *any = [NSMutableString string];
        for (NSString *f in forms) {
            [args addObject:[NSString stringWithFormat:@"%%%@%%", likeEscape(f)]];
            [any appendFormat:@"%@url LIKE ?%lu ESCAPE '\\' OR title LIKE ?%lu ESCAPE '\\'", any.length ? @" OR " : @"", (unsigned long)args.count, (unsigned long)args.count];
        }
        [where appendFormat:@" AND (%@)", any];
    }
    NSString *sql = [NSString stringWithFormat:@"SELECT url, title, visit_count, typed_count, last_visit_time FROM urls WHERE %@ "
                     "ORDER BY typed_count * 2 + visit_count DESC, last_visit_time DESC LIMIT 80", where];
    NSMutableArray *out = [NSMutableArray array];
    double nowChrome = (NSDate.date.timeIntervalSince1970 + 11644473600.0) * 1e6;  // µs since 1601
    [self sqlite:@"History" query:sql bind:args row:^(sqlite3_stmt *s) {
        DPCommandItem *it = [DPCommandItem new];
        it.kind = DPItemHistory;
        it.url = @((const char *)sqlite3_column_text(s, 0) ?: "");
        NSString *title = @((const char *)sqlite3_column_text(s, 1) ?: "");
        it.title = title.length ? title : it.url;
        it.detail = it.url;
        it.symbol = @"globe";
        double visits = sqlite3_column_int(s, 2), typed = sqlite3_column_int(s, 3);
        double ageDays = MAX(0, (nowChrome - sqlite3_column_int64(s, 4)) / 8.64e10);
        it.frecency = log2(visits + 1) * 0.6 + log2(typed + 1) * 0.8 + 1.5 / (1 + ageDays / 7.0);
        [out addObject:it];
    }];
    return out;
}

// Ranked results. History is queried off the main thread; `done` runs on main.
- (void)query:(NSString *)text done:(void (^)(NSArray<DPCommandItem *> *))done {
    NSString *q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    NSUInteger gen = ++_generation;
    if (!q.length) {
        done([_tabs subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, _tabs.count))]);  // open tabs, like Arc
        return;
    }
    NSArray *words = [[q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSArray *commands = _commands, *pages = _pages, *tabs = _tabs, *bookmarks = _bookmarks;
    NSString *activeURL = _activeURL;
    // _searchTemplate is replaced on each open, so read it here on main, not on the queue.
    NSString *searchURL = [self searchURLFor:text], *engine = [self searchEngineName];
    dispatch_async(_queue, ^{
        if (gen != self->_generation) return;  // typed past; don't scan History for this one
        NSMutableArray<DPCommandItem *> *all = [NSMutableArray array];
        // A command, page or tab named by prefix beats history; history ranks by match plus frecency.
        void (^add)(NSArray<DPCommandItem *> *, double, double, double) = ^(NSArray<DPCommandItem *> *list, double minMatch, double weight, double prefixBonus) {
            for (DPCommandItem *it in list) {
                double m = matchScore(words, it.title, it.kind == DPItemCommand ? nil : it.url);
                if (m < minMatch) continue;
                double coverage = MIN(1.0, 2.0 * q.length / MAX((NSUInteger)1, it.title.length));
                BOOL named = m >= 4 * words.count && (it.kind == DPItemTab || q.length >= 3);
                it.score = m * weight + it.frecency + (named ? prefixBonus * coverage : 0);
                [all addObject:it];
            }
        };
        add(commands, 2.5, 1.2, 15.0);
        add(pages, 2.5, 1.2, 14.0);
        add(tabs, 0.8, 1.25, 2.5);
        add(bookmarks, 1.0, 1.1, 1.0);
        NSArray<DPCommandItem *> *history = [self historyFor:words];
        add(history, 0.8, 1.0, 0);

        // A site open in a tab is offered as "Switch to Tab", with its history weight.
        NSMutableDictionary<NSString *, DPCommandItem *> *historyByURL = [NSMutableDictionary dictionary];
        for (DPCommandItem *h in history) if (h.url) historyByURL[h.url] = h;
        for (DPCommandItem *t in all)
            if (t.kind == DPItemTab && historyByURL[t.url]) t.score = MAX(t.score, historyByURL[t.url].score + 0.5);

        [all sortUsingComparator:^NSComparisonResult(DPCommandItem *a, DPCommandItem *b) {
            return a.score > b.score ? NSOrderedAscending : a.score < b.score ? NSOrderedDescending : NSOrderedSame;
        }];
        // De-duplicate URLs (an open tab beats a bookmark beats history), at most two history rows per site.
        NSMutableArray<DPCommandItem *> *ranked = [NSMutableArray array];
        NSMutableSet *urls = [NSMutableSet set];
        NSCountedSet *perSite = [NSCountedSet set], *perTitle = [NSCountedSet set];
        for (DPCommandItem *it in all) {
            NSString *key = it.url ? [it.url stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] : it.title;
            if (it.kind == DPItemTab && [it.url isEqualToString:activeURL]) continue;
            if ([urls containsObject:key]) continue;
            NSString *site = [NSURL URLWithString:it.url].host;
            if (it.kind == DPItemHistory && site && [perSite countForObject:site] >= 2) continue;
            if (it.kind == DPItemHistory && it.title && [perTitle countForObject:it.title] >= 2) continue;
            if (site) [perSite addObject:site];
            if (it.title) [perTitle addObject:it.title];
            [urls addObject:key];
            [ranked addObject:it];
        }

        // What was typed, as an address or a search: second unless nothing else is strong.
        DPCommandItem *typed = [DPCommandItem new];
        typed.title = text;
        if (looksLikeAddress(q)) {
            typed.kind = DPItemURL;
            typed.url = resolveInput(text);
            typed.detail = @"Open";
            typed.symbol = @"globe";
        } else {
            typed.kind = DPItemSearch;
            typed.url = searchURL;
            typed.detail = [@"Search " stringByAppendingString:engine];
            typed.symbol = @"magnifyingglass";
        }
        BOOL strongTop = ranked.count && ranked[0].score >= 5;
        [ranked insertObject:typed atIndex:strongTop ? 1 : 0];

        NSArray *items = [ranked subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, ranked.count))];
        dispatch_async(dispatch_get_main_queue(), ^{ if (gen == self->_generation) done(items); });
    });
}

// The site to complete inline, from the top-ranked page only ("git" -> "github.com", "home" ->
// "homeassistant.local:8123"), and in `url` the address it stands for, keeping http and the port.
- (NSString *)completionFor:(NSString *)text inItems:(NSArray<DPCommandItem *> *)items url:(NSString **)url {
    NSString *q = text.lowercaseString;
    if (!q.length || [q rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) return nil;
    for (DPCommandItem *it in items) {
        if (it.kind != DPItemHistory && it.kind != DPItemTab && it.kind != DPItemBookmark) continue;
        NSURLComponents *c = [NSURLComponents componentsWithString:it.url];
        NSString *host = c.host.lowercaseString;
        if (!host.length || !c.scheme.length) break;
        NSString *site = [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
        if (c.port) site = [site stringByAppendingFormat:@":%@", c.port];
        if (site.length > q.length && [site hasPrefix:q]) {
            *url = [NSString stringWithFormat:@"%@://%@%@/", c.scheme.lowercaseString, host, c.port ? [@":" stringByAppendingString:c.port.stringValue] : @""];
            return site;
        }
        break;
    }
    return nil;
}

- (void)useCurrentProfile {
    NSString *profile = profileDir();
    if ([profile isEqualToString:_profile]) return;
    _profile = profile;
    _bookmarks = nil;
    _searchTemplate = nil;
    [_icons removeAllObjects];
}

// Dia's Chromium forgets which page used which favicon a day or two after a visit, and drops
// the images too. So we keep a copy of each site's icon, saved while the site was recent.
static NSString *siteKey(NSURL *u) {
    NSString *host = u.host.lowercaseString;
    if (!host.length) return nil;
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return u.port ? [NSString stringWithFormat:@"%@_%@", host, u.port] : host;
}

static NSString *siteIconPath(NSString *site) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DiaPatches/site-icons"];
    return [dir stringByAppendingPathComponent:[site stringByAppendingPathExtension:@"png"]];
}

// Saves the largest current icon of every site Chromium still links, in the background.
+ (void)learnSiteIcons {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("DiaPatches.site-icons", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        DPCommandSources *s = [DPCommandSources new];
        [s useCurrentProfile];
        NSMutableDictionary<NSString *, NSData *> *best = [NSMutableDictionary dictionary];
        [s sqlite:@"Favicons" query:@"SELECT m.page_url, b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id "
                                     "WHERE length(b.image_data) > 0 ORDER BY m.id, b.width" bind:@[] row:^(sqlite3_stmt *st) {
            NSString *key = siteKey([NSURL URLWithString:@((const char *)sqlite3_column_text(st, 0) ?: "")]);
            if (key) best[key] = [NSData dataWithBytes:sqlite3_column_blob(st, 1) length:sqlite3_column_bytes(st, 1)];
        }];
        NSFileManager *fm = NSFileManager.defaultManager;
        if (best.count) [fm createDirectoryAtPath:siteIconPath(@"x").stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [best enumerateKeysAndObjectsUsingBlock:^(NSString *site, NSData *png, BOOL *stop) {
            NSString *path = siteIconPath(site);
            if (![[NSData dataWithContentsOfFile:path] isEqualToData:png]) [png writeToFile:path atomically:YES];
        }];
    });
}

- (NSImage *)faviconFor:(NSString *)url {
    if (!url.length) return nil;
    id cached = [_icons objectForKey:url];
    if (cached) return cached == NSNull.null ? nil : cached;
    NSURL *u = [NSURL URLWithString:url];
    NSString *host = u.port ? [NSString stringWithFormat:@"%@:%@", u.host, u.port] : u.host;
    // The page itself, then any page on the same host, while Chromium still has them.
    __block NSData *png = nil;
    [self sqlite:@"Favicons" query:@"SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id "
                                    "WHERE (m.page_url = ?1 OR m.page_url LIKE ?2) AND length(b.image_data) > 0 ORDER BY (m.page_url = ?1) DESC, b.width DESC LIMIT 1"
            bind:@[url, [NSString stringWithFormat:@"%%://%@/%%", host ?: @"-"]] row:^(sqlite3_stmt *s) {
        png = [NSData dataWithBytes:sqlite3_column_blob(s, 0) length:sqlite3_column_bytes(s, 0)];
    }];
    // Otherwise the icon saved from an earlier visit.
    NSString *site = siteKey(u);
    if (!png.length && site) png = [NSData dataWithContentsOfFile:siteIconPath(site)];
    NSImage *img = png.length ? [[NSImage alloc] initWithData:png] : nil;
    [_icons setObject:img ?: (id)NSNull.null forKey:url];
    return img;
}

@end

#pragma mark - Command bar

static const CGFloat kBarWidth = 760;
static const CGFloat kInputHeight = 64;
static const CGFloat kResultHeight = 44;
static const CGFloat kListInset = 8;
static const NSUInteger kMaxRows = 8;

// Secondary text (URLs, "— Search Google", shortcuts): ~6.4:1 contrast on the bar in both modes.
static NSColor *detailColor(void) { return dyn(1, 0.58, 0, 0.64); }

@class DPResultsView;
@protocol DPResultsViewDelegate
- (void)resultsView:(DPResultsView *)v activate:(NSInteger)row;
- (NSImage *)iconForItem:(DPCommandItem *)item;
@end

@interface DPResultsView : NSView
@property (nonatomic, copy) NSArray<DPCommandItem *> *items;
@property (nonatomic) NSInteger selected;
@property (nonatomic, weak) id<DPResultsViewDelegate> delegate;
@property (nonatomic) BOOL compact;  // smaller rows, for the sidebar's suggestions
- (CGFloat)rowHeight;
- (CGFloat)inset;
@end

@implementation DPResultsView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)setItems:(NSArray<DPCommandItem *> *)items { _items = [items copy]; _selected = items.count ? 0 : -1; self.needsDisplay = YES; }
- (void)setSelected:(NSInteger)s { _selected = s; self.needsDisplay = YES; }

- (CGFloat)rowHeight { return self.compact ? 32 : kResultHeight; }
- (CGFloat)inset { return self.compact ? 5 : kListInset; }

- (NSRect)rectForRow:(NSInteger)r {
    return NSMakeRect(self.inset, self.inset + r * self.rowHeight, NSWidth(self.bounds) - self.inset * 2, self.rowHeight);
}

- (NSInteger)rowAt:(NSPoint)p {
    for (NSInteger r = 0; r < (NSInteger)self.items.count; r++) if (NSPointInRect(p, [self rectForRow:r])) return r;
    return -1;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)e {
    NSInteger r = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (r >= 0 && r != self.selected) self.selected = r;
}

- (void)mouseDown:(NSEvent *)e {
    NSInteger r = [self rowAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (r >= 0) [self.delegate resultsView:self activate:r];
}

- (void)drawRect:(NSRect)dirty {
    CGFloat size = self.compact ? 13 : 15, iconSize = self.compact ? 16 : 20;
    NSFont *titleFont = [NSFont systemFontOfSize:size weight:NSFontWeightMedium];
    NSFont *detailFont = [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
    NSMutableParagraphStyle *trunc = [NSMutableParagraphStyle new];
    trunc.lineBreakMode = NSLineBreakByTruncatingMiddle;
    for (NSInteger r = 0; r < (NSInteger)self.items.count; r++) {
        DPCommandItem *it = self.items[r];
        NSRect row = [self rectForRow:r];
        BOOL selected = r == self.selected;
        if (selected) {
            [dyn(1, 0.10, 0, 0.07) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:row xRadius:10 yRadius:10] fill];
        }

        // Icon: a favicon, or a symbol (commands get a filled tile, like Arc).
        NSRect iconRect = NSMakeRect(NSMinX(row) + (self.compact ? 9 : 14), NSMidY(row) - iconSize / 2, iconSize, iconSize);
        NSImage *icon = [self.delegate iconForItem:it];
        if (it.kind == DPItemCommand || it.kind == DPItemPage) {
            [(it.kind == DPItemCommand ? NSColor.labelColor : dyn(1, 0.14, 0, 0.08)) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(iconRect, -4, -4) xRadius:7 yRadius:7] fill];
            NSImage *sym = [[NSImage imageWithSystemSymbolName:it.symbol accessibilityDescription:nil]
                            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
            [self drawSymbol:sym in:iconRect tint:it.kind == DPItemCommand ? NSColor.windowBackgroundColor : NSColor.labelColor];
        } else if (icon) {
            if (selected) {
                [NSColor.whiteColor setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(iconRect, -4, -4) xRadius:7 yRadius:7] fill];
            }
            [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        } else {
            NSImage *sym = [[NSImage imageWithSystemSymbolName:it.symbol accessibilityDescription:nil]
                            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular]];
            [self drawSymbol:sym in:iconRect tint:NSColor.secondaryLabelColor];
        }

        // Title — detail, with the detail truncated first.
        CGFloat x = NSMaxX(iconRect) + (self.compact ? 10 : 16), maxX = NSMaxX(row) - (self.compact ? 10 : 16);
        if (it.kind == DPItemTab && self.compact) {  // no room for "Switch to Tab"
            NSImage *arrow = [[NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:@"Switch to Tab"]
                              imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold]];
            [self drawSymbol:arrow in:NSMakeRect(maxX - 14, NSMidY(row) - 7, 14, 14) tint:NSColor.secondaryLabelColor];
            maxX -= 22;
        } else if (it.kind == DPItemTab) {
            NSRect chip = NSMakeRect(maxX - 24, NSMidY(row) - 14, 28, 28);
            [(selected ? NSColor.labelColor : dyn(1, 0.16, 0, 0.09)) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:7 yRadius:7] fill];
            NSImage *arrow = [[NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:@"Switch to Tab"]
                              imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold]];
            [self drawSymbol:arrow in:chip tint:selected ? NSColor.windowBackgroundColor : NSColor.secondaryLabelColor];
            NSDictionary *ra = @{NSFontAttributeName: selected ? titleFont : detailFont,
                                 NSForegroundColorAttributeName: selected ? NSColor.labelColor : detailColor()};
            NSSize rs = [it.detail sizeWithAttributes:ra];
            [it.detail drawAtPoint:NSMakePoint(NSMinX(chip) - 12 - rs.width, NSMidY(row) - rs.height / 2) withAttributes:ra];
            maxX = NSMinX(chip) - 12 - rs.width - 16;
        }
        if (it.kind == DPItemCommand && it.detail.length) {
            NSDictionary *ra = @{NSFontAttributeName: detailFont, NSForegroundColorAttributeName: detailColor()};
            NSSize rs = [it.detail sizeWithAttributes:ra];
            [it.detail drawAtPoint:NSMakePoint(maxX - rs.width, NSMidY(row) - rs.height / 2) withAttributes:ra];
            maxX -= rs.width + 16;
        }
        BOOL hasDetail = it.kind == DPItemHistory || it.kind == DPItemBookmark || it.kind == DPItemPage || it.kind == DPItemSearch || it.kind == DPItemURL;
        NSDictionary *ta = @{NSFontAttributeName: titleFont, NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: trunc};
        NSString *title = it.title ?: @"";
        NSSize ts = [title sizeWithAttributes:ta];
        CGFloat titleW = MIN(ts.width, (maxX - x) * (hasDetail ? 0.6 : 1));
        [title drawInRect:NSMakeRect(x, NSMidY(row) - ts.height / 2, titleW, ts.height) withAttributes:ta];
        NSString *detail = it.kind == DPItemSearch || it.kind == DPItemURL ? it.detail : hasDetail ? [self prettyURL:it.url] : nil;
        if (detail.length) {
            NSDictionary *da = @{NSFontAttributeName: detailFont, NSForegroundColorAttributeName: detailColor(), NSParagraphStyleAttributeName: trunc};
            NSString *d = [@"— " stringByAppendingString:detail];
            NSSize ds = [d sizeWithAttributes:da];
            CGFloat dx = x + titleW + 8;
            [d drawInRect:NSMakeRect(dx, NSMidY(row) - ds.height / 2, MAX(0, maxX - dx), ds.height) withAttributes:da];
        }
    }
}

- (void)drawSymbol:(NSImage *)sym in:(NSRect)r tint:(NSColor *)tint {
    if (!sym) return;
    NSImage *tinted = [NSImage imageWithSize:sym.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        [sym drawInRect:dst];
        [tint set];
        NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
        return YES;
    }];
    NSRect fit = NSMakeRect(NSMidX(r) - sym.size.width / 2, NSMidY(r) - sym.size.height / 2, sym.size.width, sym.size.height);
    [tinted drawInRect:fit fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (NSString *)prettyURL:(NSString *)u {
    NSString *s = u;
    for (NSString *p in @[@"https://", @"http://"]) if ([s hasPrefix:p]) s = [s substringFromIndex:p.length];
    if ([s hasPrefix:@"www."]) s = [s substringFromIndex:4];
    if ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    return s;
}

@end

@interface DPCommandPanel : NSPanel
@end

@implementation DPCommandPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// The sidebar's suggestions: never key, so typing stays in the sidebar field.
@interface DPSuggestionPanel : NSPanel
@end

@implementation DPSuggestionPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface DPCommandBar : NSObject <NSTextFieldDelegate, NSWindowDelegate, DPResultsViewDelegate>
@property (nonatomic, strong) DPCommandPanel *panel;
@property (nonatomic, strong) NSVisualEffectView *background;
@property (nonatomic, strong) NSView *tint;
@property (nonatomic, strong) NSTextField *field;
@property (nonatomic, strong) NSImageView *fieldIcon;
@property (nonatomic, strong) NSBox *divider;
@property (nonatomic, strong) DPResultsView *results;
@property (nonatomic, strong) DPCommandSources *sources;
@property (nonatomic, weak) NSWindow *host;
@property (nonatomic) BOOL newTab;                 // ⌘T: results open in a new tab
@property (nonatomic, copy) NSString *typed;       // what was typed, without the inline completion
@property (nonatomic) BOOL suppressCompletion;     // after a deletion
@property (nonatomic, copy) NSString *completionText;   // the field with the inline completion accepted
@property (nonatomic, copy) NSString *completionURL;    // where that goes
@property (nonatomic, copy) NSString *shownQuery;       // the query the listed results belong to
@end

@implementation DPCommandBar

+ (instancetype)shared {
    static DPCommandBar *bar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bar = [DPCommandBar new]; });
    return bar;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _sources = [DPCommandSources new];
    _panel = [[DPCommandPanel alloc] initWithContentRect:NSMakeRect(0, 0, kBarWidth, kInputHeight)
                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskFullSizeContentView
                                                 backing:NSBackingStoreBuffered defer:YES];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.level = NSFloatingWindowLevel;
    _panel.delegate = self;
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = YES;

    _background = [[NSVisualEffectView alloc] initWithFrame:_panel.contentView.bounds];
    _background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _background.state = NSVisualEffectStateActive;
    _background.wantsLayer = YES;
    _background.layer.cornerRadius = 16;
    _background.layer.cornerCurve = kCACornerCurveContinuous;
    _background.layer.masksToBounds = YES;
    _background.layer.borderWidth = 1;
    // The layer's corners don't clip the blur of what's behind the window; a mask image does.
    NSImage *mask = [NSImage imageWithSize:NSMakeSize(33, 33) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:16 yRadius:16] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    _background.maskImage = mask;
    _panel.contentView = _background;

    // A mostly opaque wash over the blur, so text stays readable over bright pages.
    _tint = [[NSView alloc] initWithFrame:_background.bounds];
    _tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _tint.wantsLayer = YES;
    _tint.layer.cornerRadius = 16;  // the mask image covers only the material, not subviews
    _tint.layer.cornerCurve = kCACornerCurveContinuous;
    [_background addSubview:_tint];

    _fieldIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _fieldIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightRegular];
    _fieldIcon.contentTintColor = NSColor.secondaryLabelColor;
    [_background addSubview:_fieldIcon];

    _field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = [NSFont systemFontOfSize:22 weight:NSFontWeightMedium];
    _field.textColor = dyn(1, 0.95, 0, 0.88);  // not labelColor, which goes vibrant and washes out
    _field.placeholderString = @"Search or enter URL";
    _field.cell.scrollable = YES;
    _field.cell.wraps = NO;
    _field.delegate = self;
    [_background addSubview:_field];

    _divider = [[NSBox alloc] initWithFrame:NSZeroRect];
    _divider.boxType = NSBoxSeparator;
    [_background addSubview:_divider];

    _results = [[DPResultsView alloc] initWithFrame:NSZeroRect];
    _results.delegate = self;
    [_background addSubview:_results];
    return self;
}

- (void)showInWindow:(NSWindow *)window newTab:(BOOL)newTab {
    if (self.panel.isVisible) [self close];
    self.host = window;
    self.newTab = newTab;
    self.panel.appearance = window.effectiveAppearance;
    // The HUD material is always dark; the popover material keeps text readable in light mode.
    BOOL dark = [[window.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
    self.background.material = dark ? NSVisualEffectMaterialHUDWindow : NSVisualEffectMaterialPopover;
    [self.background.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.background.layer.borderColor = dyn(1, 0.12, 0, 0.10).CGColor;
        self.tint.layer.backgroundColor = dyn(0.15, 0.85, 1, 0.85).CGColor;
    }];
    [self.sources prepareForWindow:window];

    NSString *initial = @"";
    if (!newTab) {
        NSString *u = urlForWindow(window);
        if (u.length && ![u hasPrefix:@"dia://"]) initial = u;
    }
    self.field.stringValue = initial;
    self.typed = initial;
    self.completionText = nil;
    self.completionURL = nil;
    self.shownQuery = nil;
    [self layoutForRows:0];
    [window addChildWindow:self.panel ordered:NSWindowAbove];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.field];
    ((NSTextView *)self.field.currentEditor).selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [NSColor.controlAccentColor colorWithAlphaComponent:0.45],
        NSForegroundColorAttributeName: self.field.textColor,
    };
    [self.field.currentEditor selectAll:nil];
    // ⌘L starts with the URL selected and no list, like Arc.
    if (newTab) [self runQuery];
    else [self showItems:@[]];
}

- (void)layoutForRows:(NSUInteger)rows {
    NSRect wf = self.host.frame;
    CGFloat width = MIN(kBarWidth, NSWidth(wf) - 80);
    CGFloat listH = rows ? rows * kResultHeight + kListInset * 2 : 0;
    CGFloat height = kInputHeight + (rows ? 1 + listH : 0);
    CGFloat top = NSMaxY(wf) - NSHeight(wf) * 0.20;  // about a fifth of the way down
    [self.panel setFrame:NSMakeRect(NSMidX(wf) - width / 2, top - height, width, height) display:YES];
    self.fieldIcon.frame = NSMakeRect(22, height - kInputHeight / 2 - 12, 24, 24);
    self.field.frame = NSMakeRect(58, height - kInputHeight / 2 - 15, width - 58 - 22, 30);
    self.divider.hidden = rows == 0;
    self.divider.frame = NSMakeRect(0, height - kInputHeight - 1, width, 1);
    self.results.frame = NSMakeRect(0, 0, width, listH);
    [self.panel invalidateShadow];  // otherwise the shadow keeps the old size's square outline
}

- (void)close {
    [self.host removeChildWindow:self.panel];
    [self.panel orderOut:nil];
    [self.host makeKeyAndOrderFront:nil];
}

- (void)windowDidResignKey:(NSNotification *)n {
    // Clicking outside closes it, like Arc; the window that took key keeps it.
    if (!self.panel.isVisible) return;
    [self.host removeChildWindow:self.panel];
    [self.panel orderOut:nil];
}

- (void)runQuery {
    NSString *q = self.typed ?: @"";
    __weak typeof(self) weakSelf = self;
    [self.sources query:q done:^(NSArray<DPCommandItem *> *items) {
        typeof(self) s = weakSelf;
        if (![s.typed isEqualToString:q]) return;
        s.shownQuery = q;
        [s showItems:items];
        [s applyCompletionFrom:items];
    }];
}

- (void)showItems:(NSArray<DPCommandItem *> *)items {
    self.results.items = items;
    [self layoutForRows:MIN(kMaxRows, items.count)];
    [self updateFieldIcon];
}

- (void)updateFieldIcon {
    DPCommandItem *top = self.results.selected >= 0 ? self.results.items[self.results.selected] : nil;
    NSImage *img = top ? [self iconForItem:top] : nil;
    // While typing, show the site the field will open: its inline completion, or the address typed.
    if (self.results.selected <= 0) {
        NSString *field = self.field.currentEditor.string.lowercaseString ?: self.field.stringValue.lowercaseString;
        NSString *site = self.completionURL && [field isEqualToString:self.completionText] ? self.completionURL
                       : (looksLikeAddress(field) ? resolveInput(field) : nil);
        NSImage *favicon = site ? [self.sources faviconFor:site] : nil;
        if (favicon) { self.fieldIcon.image = favicon; return; }
    }
    if (!img || top.kind == DPItemCommand || top.kind == DPItemPage)
        img = [NSImage imageWithSystemSymbolName:top ? top.symbol : @"magnifyingglass" accessibilityDescription:nil];
    self.fieldIcon.image = img;
}

// Inline completion: "git" -> "git|hub.com" with the suffix selected.
- (void)applyCompletionFrom:(NSArray<DPCommandItem *> *)items {
    if (self.suppressCompletion) return;
    NSString *url = nil;
    NSString *host = [self.sources completionFor:self.typed inItems:items url:&url];
    NSText *editor = self.field.currentEditor;
    if (!host || !editor || ![editor.string isEqualToString:self.typed]) return;
    self.completionText = host;
    self.completionURL = url;
    NSString *suffix = [host substringFromIndex:self.typed.length];
    editor.string = [self.typed stringByAppendingString:suffix];
    editor.selectedRange = NSMakeRange(self.typed.length, suffix.length);
    [self updateFieldIcon];
}

- (void)controlTextDidChange:(NSNotification *)n {
    NSString *now = self.field.stringValue;
    // Don't re-complete a deletion (Backspace on a completion leaves the text the same length).
    self.suppressCompletion = now.length <= self.typed.length && [self.typed hasPrefix:now];
    self.typed = now;
    [self runQuery];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    NSInteger n = self.results.items.count;
    if (sel == @selector(moveDown:) || sel == @selector(moveUp:)) {
        if (!n) return YES;
        self.results.selected = (self.results.selected + (sel == @selector(moveDown:) ? 1 : -1) + n) % n;
        [self updateFieldIcon];
        return YES;
    }
    if (sel == @selector(insertTab:)) {  // accept the inline completion
        tv.selectedRange = NSMakeRange(tv.string.length, 0);
        self.typed = tv.string;
        [self runQuery];
        return YES;
    }
    if (sel == @selector(insertNewline:)) {
        BOOL newTab = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand) != 0;
        BOOL completed = ![tv.string isEqualToString:self.typed] && self.results.selected == 0;
        // Results for what's typed haven't arrived yet: the listed rows are for older text.
        BOOL stale = ![self.shownQuery isEqualToString:self.typed];
        [self activateRow:completed || stale ? -1 : self.results.selected forceNewTab:newTab];
        return YES;
    }
    if (sel == @selector(cancelOperation:)) { [self close]; return YES; }
    return NO;
}

- (void)resultsView:(DPResultsView *)v activate:(NSInteger)row { [self activateRow:row forceNewTab:NO]; }

- (void)activateRow:(NSInteger)row forceNewTab:(BOOL)forceNewTab {
    NSWindow *w = self.host;
    DPCommandItem *it = row >= 0 && row < (NSInteger)self.results.items.count ? self.results.items[row] : nil;
    NSString *typedText = self.field.stringValue, *query = self.typed;
    [self close];
    if (!it) {
        if (!typedText.length) return;
        it = [DPCommandItem new];
        it.kind = DPItemURL;
        it.url = resolveURL(typedText) ?: [self.sources searchURLFor:typedText];  // the user's search engine, not Google
    }
    // An inline completion, accepted or not, goes where its page was (keeping http and the port).
    BOOL completion = self.completionURL && [typedText.lowercaseString isEqualToString:self.completionText];
    switch (it.kind) {
        case DPItemCommand: {
            NSMenuItem *m = it.menuItem;
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp sendAction:m.action to:m.target from:m]; });
            break;
        }
        case DPItemTab:
            focusTab(it.windowId, it.tabId);
            break;
        default: {
            NSString *url = it.url;
            if (it.kind == DPItemURL && ![typedText isEqualToString:it.title])
                url = resolveURL(typedText) ?: [self.sources searchURLFor:typedText];
            if (it.kind == DPItemURL && completion) url = self.completionURL;
            // A Search row clicked before its results refreshed searches what's typed now (without the completion).
            if (it.kind == DPItemSearch && ![query isEqualToString:it.title]) url = [self.sources searchURLFor:query];
            if (!url) return;
            if (self.newTab || forceNewTab) openInNewTab(w, url);
            else navigateWindow(w, url);
        }
    }
}

- (NSImage *)iconForItem:(DPCommandItem *)item {
    if (item.kind == DPItemCommand || item.kind == DPItemPage || item.kind == DPItemSearch) return nil;
    return [self.sources faviconFor:item.url];
}

@end

static BOOL showCommandBar(NSWindow *window, BOOL newTab) {
    if (!isBrowserWindow(window)) return NO;
    [[DPCommandBar shared] showInWindow:window newTab:newTab];
    return YES;
}

#pragma mark - Sidebar URL bar

static NSString *const kHeaderClass = @"TabSidebar.SidebarHeaderView";
static const CGFloat kURLRowHeight = 40;  // pill 30 + 2 top + 8 bottom
static const CGFloat kPillHeight = 30;
static const CGFloat kSideInset = 10;
static char kBarKey, kNavKey, kGapKey;

@interface DPSidebarURLBar : NSView <NSTextFieldDelegate, DPResultsViewDelegate>
@property (nonatomic, strong) NSTextField *editor;   // while typing an address in place
@property (nonatomic, strong) id clickMonitor;
@property (nonatomic, strong) DPSuggestionPanel *suggestions;  // below the pill while typing
@property (nonatomic, strong) DPResultsView *results;
@property (nonatomic, copy) NSString *typed;
@property (nonatomic, copy) NSString *shownQuery;   // the query the listed results belong to
@property (nonatomic, strong) NSView *pill;
@property (nonatomic, strong) NSImageView *icon;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSButton *extensions;
@property (nonatomic, copy) NSString *currentURL;
@property (nonatomic) BOOL hovering;
@end

@implementation DPSidebarURLBar

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _pill = [[NSView alloc] initWithFrame:NSZeroRect];
    _pill.wantsLayer = YES;
    _pill.layer.cornerRadius = 9;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_pill];

    _icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightMedium];
    _icon.contentTintColor = NSColor.secondaryLabelColor;
    [_pill addSubview:_icon];

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    _label.textColor = NSColor.labelColor;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.placeholderString = @"Search or enter URL";
    [_pill addSubview:_label];

    _extensions = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"Extensions"]
                                     target:self action:@selector(showExtensions:)];
    _extensions.bordered = NO;
    _extensions.identifier = @"DiaPatchesSidebarExtensions";
    _extensions.toolTip = @"Extensions";
    _extensions.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium];
    _extensions.contentTintColor = NSColor.labelColor;
    [_pill addSubview:_extensions];
    [self updateAppearance];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    self.pill.frame = NSMakeRect(kSideInset, 2, NSWidth(self.bounds) - kSideInset * 2, kPillHeight);
    self.icon.frame = NSMakeRect(9, (kPillHeight - 14) / 2, 14, 14);
    CGFloat buttonWidth = gExtensionsOn ? 26 : 0;
    self.extensions.hidden = !gExtensionsOn;
    self.extensions.frame = NSMakeRect(NSWidth(self.pill.frame) - buttonWidth - 2, 0, buttonWidth, kPillHeight);
    self.label.frame = NSMakeRect(27, (kPillHeight - 17) / 2, NSWidth(self.pill.frame) - 27 - 8 - buttonWidth, 17);
    self.editor.frame = self.label.frame;
}

- (void)showExtensions:(NSButton *)sender { DPShowExtensionsMenu(sender); }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)e { self.hovering = YES; [self updateAppearance]; }
- (void)mouseExited:(NSEvent *)e { self.hovering = NO; [self updateAppearance]; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self updateAppearance]; }

- (void)mouseDown:(NSEvent *)e { [self beginEditing]; }

// Clicking the pill turns it into a field holding the full address, selected, like Arc's sidebar address bar.
// Return opens what's typed (⌘Return in a new tab); Esc or a click elsewhere puts the address back.
- (void)beginEditing {
    if (self.editor) return;
    DPCommandSources *sources = [DPCommandBar shared].sources;
    [sources prepareForWindow:self.window];  // the profile's search engine
    NSString *u = urlForWindow(self.window);
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.stringValue = u.length && ![u isEqualToString:@"about:blank"] && ![u hasPrefix:@"dia://"] ? u : @"";
    field.placeholderString = @"Search or enter URL";
    field.font = self.label.font;
    field.textColor = NSColor.labelColor;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.cell.scrollable = YES;
    field.cell.wraps = NO;
    field.delegate = self;
    self.editor = field;
    self.label.hidden = YES;
    [self.pill addSubview:field];
    [self layout];
    [self.window makeFirstResponder:field];
    [field.currentEditor selectAll:nil];
    self.typed = nil;
    self.shownQuery = nil;
    __weak typeof(self) weakSelf = self;
    self.clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown
                                                              handler:^NSEvent *(NSEvent *click) {
        typeof(self) bar = weakSelf;
        NSTextField *f = bar.editor;
        if (click.window && click.window == bar.suggestions) return click;
        NSPoint p = click.window == f.window ? [f convertPoint:click.locationInWindow fromView:nil] : NSMakePoint(-1, -1);
        if (f && !NSPointInRect(p, f.bounds)) [bar endEditing];
        return click;
    }];
}

- (void)endEditing {
    if (!self.editor) return;
    if (self.clickMonitor) [NSEvent removeMonitor:self.clickMonitor];
    self.clickMonitor = nil;
    NSTextField *field = self.editor;
    self.editor = nil;
    [self showItems:@[]];
    [field removeFromSuperview];
    self.label.hidden = NO;
    if (self.window.firstResponder == field.currentEditor || self.window.firstResponder == field) [self.window makeFirstResponder:nil];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(cancelOperation:)) { [self endEditing]; return YES; }
    NSInteger n = self.results.items.count;
    if (sel == @selector(moveDown:) || sel == @selector(moveUp:)) {
        if (n) self.results.selected = (self.results.selected + (sel == @selector(moveDown:) ? 1 : -1) + n) % n;
        return YES;
    }
    if (sel != @selector(insertNewline:)) return NO;
    // Rows listed for older text don't count: open what's typed.
    BOOL current = n && [self.shownQuery isEqualToString:self.typed];
    [self activateRow:current ? self.results.selected : -1 newTab:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand) != 0];
    return YES;
}

- (void)controlTextDidChange:(NSNotification *)n {
    NSString *q = self.editor.stringValue;
    self.typed = q;
    if (![q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) { [self showItems:@[]]; return; }
    __weak typeof(self) weakSelf = self;
    [[DPCommandBar shared].sources query:q done:^(NSArray<DPCommandItem *> *items) {
        typeof(self) bar = weakSelf;
        if (!bar.editor || ![bar.typed isEqualToString:q]) return;
        bar.shownQuery = q;
        [bar showItems:items];
    }];
}

- (void)showItems:(NSArray<DPCommandItem *> *)items {
    NSWindow *w = self.window;
    if (!items.count || !w) {
        if (self.suggestions.parentWindow) [self.suggestions.parentWindow removeChildWindow:self.suggestions];
        [self.suggestions orderOut:nil];
        self.results.items = @[];
        return;
    }
    if (!self.suggestions) {
        DPSuggestionPanel *panel = [[DPSuggestionPanel alloc] initWithContentRect:NSZeroRect
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.hasShadow = YES;
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = YES;
        NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        bg.material = NSVisualEffectMaterialMenu;
        bg.state = NSVisualEffectStateActive;
        NSImage *mask = [NSImage imageWithSize:NSMakeSize(21, 21) flipped:NO drawingHandler:^BOOL(NSRect r) {
            [[NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10] fill];
            return YES;
        }];
        mask.capInsets = NSEdgeInsetsMake(10, 10, 10, 10);
        bg.maskImage = mask;
        panel.contentView = bg;
        DPResultsView *results = [[DPResultsView alloc] initWithFrame:NSZeroRect];
        results.compact = YES;
        results.delegate = self;
        results.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [bg addSubview:results];
        self.suggestions = panel;
        self.results = results;
    }
    self.suggestions.appearance = w.effectiveAppearance;
    self.results.items = items;
    // Under the pill, at least wide enough to read a title and its address.
    NSRect pill = [w convertRectToScreen:[self.pill convertRect:self.pill.bounds toView:nil]];
    CGFloat width = MAX(NSWidth(pill), 320), height = items.count * self.results.rowHeight + self.results.inset * 2;
    [self.suggestions setFrame:NSMakeRect(NSMinX(pill), NSMinY(pill) - 4 - height, width, height) display:NO];
    self.results.frame = self.suggestions.contentView.bounds;
    if (self.suggestions.parentWindow != w) [w addChildWindow:self.suggestions ordered:NSWindowAbove];
    [self.suggestions orderFront:nil];
    [self.suggestions invalidateShadow];
}

- (void)resultsView:(DPResultsView *)v activate:(NSInteger)row { [self activateRow:row newTab:NO]; }

- (NSImage *)iconForItem:(DPCommandItem *)item {
    if (item.kind == DPItemCommand || item.kind == DPItemPage || item.kind == DPItemSearch) return nil;
    return [[DPCommandBar shared].sources faviconFor:item.url];
}

// Opens a suggestion, or with row -1 what's typed (⌘Return in a new tab).
- (void)activateRow:(NSInteger)row newTab:(BOOL)newTab {
    DPCommandItem *it = row >= 0 && row < (NSInteger)self.results.items.count ? self.results.items[row] : nil;
    NSString *text = [self.editor.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSWindow *w = self.window;
    [self endEditing];
    if (it.kind == DPItemCommand) {
        NSMenuItem *m = it.menuItem;
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp sendAction:m.action to:m.target from:m]; });
        return;
    }
    if (it.kind == DPItemTab) { focusTab(it.windowId, it.tabId); return; }
    NSString *url = it ? it.url : text.length ? resolveURL(text) ?: [[DPCommandBar shared].sources searchURLFor:text] : nil;
    if (!url) return;
    if (newTab) openInNewTab(w, url);
    else navigateWindow(w, url);
    [self forceRefresh];
}

- (void)controlTextDidEndEditing:(NSNotification *)n { [self endEditing]; }

- (void)updateAppearance {
    NSColor *bg = self.hovering ? dyn(1, 0.12, 0, 0.08) : dyn(1, 0.08, 0, 0.055);
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{ self.pill.layer.backgroundColor = bg.CGColor; }];
}

- (void)refresh {
    NSString *u = urlForWindow(self.window);
    if ([u isEqualToString:self.currentURL] && self.label.stringValue.length) return;
    self.currentURL = u;
    NSString *text = @"";
    if (u.length && ![u isEqualToString:@"about:blank"]) {
        NSURL *url = [NSURL URLWithString:u];
        NSString *host = url.host;
        text = !host.length ? u : [host hasPrefix:@"www."] ? [host substringFromIndex:4] : host;
        // Local services differ only by port: "localhost:3000", not "localhost".
        if (host.length && url.port) text = [text stringByAppendingFormat:@":%@", url.port];
    }
    self.label.stringValue = text;
    NSString *symbol = !u.length ? @"magnifyingglass" : [u hasPrefix:@"https://"] ? @"lock.fill" : @"globe";
    self.icon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
}

- (void)forceRefresh { self.currentURL = nil; self.label.stringValue = @""; [self refresh]; }

@end

@interface DPNavButtons : NSView
@end

@implementation DPNavButtons

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSArray *symbols = @[@"chevron.left", @"chevron.right", @"arrow.clockwise"];
    NSArray *labels = @[@"Back", @"Forward", @"Reload"];
    for (NSUInteger i = 0; i < symbols.count; i++) {
        NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:labels[i]]
                                         target:self action:@selector(tap:)];
        b.bordered = NO;
        b.tag = i;
        b.toolTip = labels[i];
        b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
        b.contentTintColor = NSColor.secondaryLabelColor;
        [self addSubview:b];
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat x = 0;
    for (NSView *b in self.subviews) { b.frame = NSMakeRect(x, 0, 26, NSHeight(self.bounds)); x += 26; }
}

- (void)tap:(NSButton *)sender { navigationPerform(self.window, sender.tag); }

@end

// Dia's window title follows the active tab's page title, so a title change means the URL may have too.
@interface DPTitleObserver : NSObject
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, strong) NSHashTable<NSWindow *> *watched;
- (void)watch:(NSWindow *)w;
@end

@implementation DPTitleObserver
- (instancetype)init {
    if ((self = [super init])) _watched = [NSHashTable weakObjectsHashTable];
    return self;
}
- (void)watch:(NSWindow *)w {
    if (!isBrowserWindow(w) || [self.watched containsObject:w]) return;
    [self.watched addObject:w];
    [w addObserver:self forKeyPath:@"title" options:0 context:NULL];
    __weak typeof(self) weakSelf = self;
    __weak NSWindow *weakWindow = w;
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(__unused NSNotification *n) {
        [weakWindow removeObserver:weakSelf forKeyPath:@"title"];
        [weakSelf.watched removeObject:weakWindow];
        [NSNotificationCenter.defaultCenter removeObserver:token];
        token = nil;  // breaks the token -> block -> token cycle
    }];
}
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    // The title often changes just before the URL settles: refresh now and once more shortly after.
    if (self.onChange) self.onChange();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (self.onChange) self.onChange(); });
}
@end

static void (*origContainerLayout)(id, SEL);
static NSHashTable<NSView *> *gContainers;
static DPTitleObserver *gTitleObserver;

static DPSidebarURLBar *barFor(NSView *container) { return objc_getAssociatedObject(container, &kBarKey); }

static NSView *bodyFor(NSView *container, NSView *header) {
    for (NSView *s in container.subviews)
        if (s != header && s != barFor(container) && [NSStringFromClass(s.class) isEqualToString:@"ARCUI.FlippedView"]) return s;
    return nil;
}

// Dia's downloads button sits in the sidebar header, where it lands between the back and forward buttons.
// With downloads at the bottom it moves to the sidebar's bottom right, just left of the footer's ⌄ button.
// Dia puts it back in the header when it updates the header, so this runs every time the button lays out.
static BOOL gDownloadsOn;
static NSHashTable<NSView *> *gDownloadsButtons;
static char kDownloadsStackKey, kDownloadsIndexKey, kDownloadsSizeKey, kDownloadsWantsHiddenKey;
static void (*origDownloadsSetHidden)(id, SEL, BOOL);

static NSView *ancestorOfClass(NSView *view, NSString *className) {
    for (NSView *v = view.superview; v; v = v.superview)
        if ([NSStringFromClass(v.class) isEqualToString:className]) return v;
    return nil;
}

static void placeDownloadsButton(NSView *button) {
    NSView *header = ancestorOfClass(button, kHeaderClass);
    NSStackView *stack = objc_getAssociatedObject(button, &kDownloadsStackKey);
    if (!gDownloadsOn) {  // back where Dia had it, shown only when Dia wants it
        NSNumber *wantsHidden = objc_getAssociatedObject(button, &kDownloadsWantsHiddenKey);
        if (wantsHidden) origDownloadsSetHidden(button, @selector(setHidden:), wantsHidden.boolValue);
        if (header || !stack || !button.window) return;
        [NSLayoutConstraint deactivateConstraints:objc_getAssociatedObject(button, &kDownloadsSizeKey)];
        [button removeFromSuperview];
        NSUInteger i = MIN([objc_getAssociatedObject(button, &kDownloadsIndexKey) unsignedIntegerValue], stack.arrangedSubviews.count);
        [stack insertArrangedSubview:button atIndex:i];
        return;
    }
    if (button.hidden) origDownloadsSetHidden(button, @selector(setHidden:), NO);
    NSView *container = header.superview;
    if (!header || !container || !button.window) return;
    if ([button.superview isKindOfClass:NSStackView.class]) {
        objc_setAssociatedObject(button, &kDownloadsStackKey, button.superview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, &kDownloadsIndexKey, @([((NSStackView *)button.superview).arrangedSubviews indexOfObject:button]),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSView *footer = descendantOfClass(container, @"TabSidebar.SidebarContainerFooterView")
                  ?: descendantOfClass(button.window.contentView, @"TabSidebar.SidebarContainerFooterView");
    // Bottom left: after the library button when it shows.
    NSView *library = footer ? descendantOfClass(footer, @"TabSidebar.LibraryCellView") : nil;
    if (library.isHiddenOrHasHiddenAncestor || NSWidth(library.frame) > 60) library = nil;
    NSLog(@"[DiaPatches] downloads button moved from %s to %s", NSStringFromClass(button.superview.class).UTF8String,
          library ? "beside the footer's library button" : footer ? "the footer's left end" : "the sidebar's bottom left");
    NSView *host = footer ?: container;
    // The header held its size; keep it.
    NSSize size = NSWidth(button.frame) > 0 ? button.frame.size : NSMakeSize(24, 24);
    [button removeFromSuperview];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:button positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint deactivateConstraints:objc_getAssociatedObject(button, &kDownloadsSizeKey)];
    NSArray *sizing = @[[button.widthAnchor constraintEqualToConstant:size.width], [button.heightAnchor constraintEqualToConstant:size.height]];
    [NSLayoutConstraint activateConstraints:sizing];
    objc_setAssociatedObject(button, &kDownloadsSizeKey, sizing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [NSLayoutConstraint activateConstraints:@[
        library ? [button.leadingAnchor constraintEqualToAnchor:library.trailingAnchor constant:2]
                : [button.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:8],
        footer ? [button.centerYAnchor constraintEqualToAnchor:footer.centerYAnchor]
               : [button.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];
}

// Dia removes the button from its header stack, as on a space switch, but it's moved out of that stack, and
// NSStackView throws for a view it doesn't hold. Do what Dia meant: take it out of the window.
static void (*origStackRemoveView)(id, SEL, NSView *, BOOL, BOOL);

static void hookedStackRemoveView(NSStackView *self, SEL _cmd, NSView *view, BOOL animated, BOOL fromHierarchy) {
    if ([gDownloadsButtons containsObject:view] && view.superview != self) {
        if (fromHierarchy) [view removeFromSuperview];
        return;
    }
    origStackRemoveView(self, _cmd, view, animated, fromHierarchy);
}

// A button Dia hid before the hooks went in never lays out, so find it in the window.
static void adoptDownloadsButtons(NSWindow *window) {
    if (!gDownloadsButtons || !window.contentView) return;
    NSMutableArray<NSView *> *found = [NSMutableArray array];
    collectOfClass(window.contentView, @"TabSurface.DownloadsButtonView", found);
    for (NSView *b in found) {
        if ([gDownloadsButtons containsObject:b]) continue;
        [gDownloadsButtons addObject:b];
        NSLog(@"[DiaPatches] downloads button found, %s, in header: %s", b.hidden ? "hidden" : "shown",
              ancestorOfClass(b, kHeaderClass) ? "yes" : "no");
        placeDownloadsButton(b);
    }
}

// Dia hides the button while there are no downloads; at the bottom it always shows.
static void hookedDownloadsSetHidden(NSView *self, SEL _cmd, BOOL hidden) {
    objc_setAssociatedObject(self, &kDownloadsWantsHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gDownloadsButtons addObject:self];
    origDownloadsSetHidden(self, _cmd, hidden && !gDownloadsOn);
    if (gDownloadsOn && ancestorOfClass(self, kHeaderClass)) {
        __weak NSView *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf) placeDownloadsButton(weakSelf); });
    }
}

static void (*origDownloadsLayout)(id, SEL);

static void hookedDownloadsLayout(NSView *self, SEL _cmd) {
    origDownloadsLayout(self, _cmd);
    [gDownloadsButtons addObject:self];
    if (gDownloadsOn != (ancestorOfClass(self, kHeaderClass) != nil)) return;
    // Not while the view tree is laying out.
    __weak NSView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf) placeDownloadsButton(weakSelf); });
}

// The pill sits right under the sidebar header and pushes the tab list down by its height.
static void applyContainer(NSView *c) {
    NSView *header = childOfClass(c, kHeaderClass);
    NSView *body = header ? bodyFor(c, header) : nil;
    if (!header || !body || !c.isFlipped) return;

    CGFloat headerBottom = NSMaxY(header.frame), height = NSHeight(c.bounds);
    if (NSMinY(body.frame) == headerBottom)  // the gap Dia leaves below the body, while unshifted
        objc_setAssociatedObject(c, &kGapKey, @(height - NSMaxY(body.frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat gap = [objc_getAssociatedObject(c, &kGapKey) doubleValue];

    BOOL on = gSidebarOn && !c.isHiddenOrHasHiddenAncestor;
    DPSidebarURLBar *bar = barFor(c);
    if (on && !bar) {
        bar = [[DPSidebarURLBar alloc] initWithFrame:NSZeroRect];
        objc_setAssociatedObject(c, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (on && bar.superview != c) [c addSubview:bar positioned:NSWindowAbove relativeTo:header];
    if (!on) [bar removeFromSuperview];

    CGFloat top = headerBottom + (on ? kURLRowHeight : 0);
    NSRect bodyFrame = NSMakeRect(NSMinX(body.frame), top, NSWidth(body.frame), MAX(0, height - top - gap));
    if (!NSEqualRects(bodyFrame, body.frame)) body.frame = bodyFrame;
    if (on) {
        bar.frame = NSMakeRect(0, headerBottom, NSWidth(c.bounds), kURLRowHeight);
        [bar refresh];
    }

    DPNavButtons *nav = objc_getAssociatedObject(header, &kNavKey);
    if (on && !nav) {
        nav = [[DPNavButtons alloc] initWithFrame:NSZeroRect];
        objc_setAssociatedObject(header, &kNavKey, nav, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (on) {
        if (nav.superview != header) [header addSubview:nav];
        NSView *stack = header.subviews.firstObject;  // the traffic lights
        CGFloat mid = stack ? NSMidY(stack.frame) : NSHeight(header.bounds) / 2;
        nav.frame = NSMakeRect(NSWidth(header.bounds) - 78 - 8, mid - 13, 78, 26);
    } else {
        [nav removeFromSuperview];
    }
}

static void hookedContainerLayout(NSView *self, SEL _cmd) {
    origContainerLayout(self, _cmd);
    [gContainers addObject:self];
    applyContainer(self);
}

static void refreshAll(void) {
    for (NSView *c in gContainers.allObjects) [barFor(c) refresh];
}

static void (*origSendEvent)(id, SEL, NSEvent *);

static void hookedSendEvent(NSApplication *self, SEL _cmd, NSEvent *e) {
    if (gCommandOn && e.type == NSEventTypeKeyDown && !e.isARepeat) {
        NSEventModifierFlags mods = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
        // Key codes, so ⌘T and ⌘L work with any input source (with Korean, the characters are ㅅ and ㅣ).
        BOOL t = e.keyCode == 17, l = e.keyCode == 37;
        NSWindow *w = e.window ?: self.keyWindow;
        if (mods == NSEventModifierFlagCommand && (t || l) && showCommandBar(w, t)) return;
    }
    origSendEvent(self, _cmd, e);
}

#pragma mark - Public

NSString *DPArcBarSiteKey(NSString *url) { return url.length ? siteKey([NSURL URLWithString:url]) : nil; }

NSImage *DPArcBarFavicon(NSString *url) {
    DPCommandSources *sources = [DPCommandBar shared].sources;
    [sources useCurrentProfile];
    return [sources faviconFor:url];
}

void DPArcBarConfigure(BOOL sidebarURLBar, BOOL commandBar, BOOL extensionsButton, BOOL downloadsAtBottom) {
    gSidebarOn = sidebarURLBar;
    gCommandOn = commandBar;
    gExtensionsOn = extensionsButton;
    gDownloadsOn = downloadsAtBottom;
    for (NSWindow *w in NSApp.windows) adoptDownloadsButtons(w);
    for (NSView *b in gDownloadsButtons.allObjects) placeDownloadsButton(b);
    for (NSView *c in gContainers.allObjects) {
        applyContainer(c);
        barFor(c).needsLayout = YES;
        [barFor(c) forceRefresh];
    }
}

void DPArcBarInstall(void) {
    Class cls = findClass(@"_TtC10TabSidebar", @"SidebarContainerRootView");
    if (cls) {
        gContainers = [NSHashTable weakObjectsHashTable];
        Method m = class_getInstanceMethod(cls, @selector(layout));
        if (!class_addMethod(cls, @selector(layout), (IMP)hookedContainerLayout, method_getTypeEncoding(m)))
            origContainerLayout = (void *)method_setImplementation(m, (IMP)hookedContainerLayout);
        else
            origContainerLayout = (void *)method_getImplementation(m);
    }
    Class downloads = NSClassFromString(@"_TtC10TabSurface19DownloadsButtonView");
    Method dl = downloads ? class_getInstanceMethod(downloads, @selector(layout)) : NULL;
    if (dl) {
        gDownloadsButtons = [NSHashTable weakObjectsHashTable];
        if (!class_addMethod(downloads, @selector(layout), (IMP)hookedDownloadsLayout, method_getTypeEncoding(dl)))
            origDownloadsLayout = (void *)method_setImplementation(dl, (IMP)hookedDownloadsLayout);
        else
            origDownloadsLayout = (void *)method_getImplementation(dl);
        Method sh = class_getInstanceMethod(downloads, @selector(setHidden:));
        if (!class_addMethod(downloads, @selector(setHidden:), (IMP)hookedDownloadsSetHidden, method_getTypeEncoding(sh)))
            origDownloadsSetHidden = (void *)method_setImplementation(sh, (IMP)hookedDownloadsSetHidden);
        else
            origDownloadsSetHidden = (void *)method_getImplementation(sh);
    }
    Method rm = gDownloadsButtons ? class_getInstanceMethod(NSStackView.class, NSSelectorFromString(@"_removeView:animated:removeFromViewHierarchy:")) : NULL;
    if (rm) origStackRemoveView = (void *)method_setImplementation(rm, (IMP)hookedStackRemoveView);
    if (gDownloadsButtons)
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeMainNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { adoptDownloadsButtons(note.object); }];
    gTitleObserver = [DPTitleObserver new];
    gTitleObserver.onChange = ^{ refreshAll(); };
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification, NSWindowDidUpdateNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (!gSidebarOn) return;
            if (name == NSWindowDidUpdateNotification) [gTitleObserver watch:note.object];
            else refreshAll();
        }];
    // Pages that change URL without changing their title.
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(__unused NSTimer *t) { if (gSidebarOn) refreshAll(); }];
    timer.tolerance = 1;
    // Chromium keeps a site's favicon only a day or two after the last visit: save copies often.
    NSTimer *icons = [NSTimer scheduledTimerWithTimeInterval:15 * 60 repeats:YES block:^(__unused NSTimer *t) {
        if (gCommandOn) [DPCommandSources learnSiteIcons];
    }];
    icons.tolerance = 60;

    // Chromium routes key equivalents before local event monitors see them, so ⌘T and ⌘L are taken
    // in the application's sendEvent:.
    Class app = object_getClass(NSApp);
    Method send = class_getInstanceMethod(app, @selector(sendEvent:));
    if (send && !class_addMethod(app, @selector(sendEvent:), (IMP)hookedSendEvent, method_getTypeEncoding(send)))
        origSendEvent = (void *)method_setImplementation(send, (IMP)hookedSendEvent);
    else if (send)
        origSendEvent = (void *)method_getImplementation(send);
}
