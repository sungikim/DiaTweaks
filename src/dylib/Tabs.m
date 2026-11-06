// Folders for Tidy tabs, ported from daypatch (https://github.com/TA3/daypatch), src/Tabs.m.
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
//
// Makes Dia folders from tabs through the tab-group call Dia's sidebar answers for Chromium
// (ArcBrowserDelegate). Web contents are tracked as Dia creates or restores them, with the
// ArcBrowser that owns them.
#import "Tabs.h"
#import <objc/message.h>
#import <objc/runtime.h>

static IMP hook(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    if (class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) return method_getImplementation(m);
    return method_setImplementation(m, imp);
}

static NSMapTable *gDelegates;   // ArcBrowser -> its delegate
static NSMapTable *gOwners;      // ArcWebContents -> ArcBrowser

static void (*origSetDelegate)(id, SEL, id);
static void hookedSetDelegate(id self, SEL _cmd, id delegate) {
    [gDelegates setObject:delegate forKey:self];
    origSetDelegate(self, _cmd, delegate);
}

static void (*origTakeOwnership)(id, SEL, id);
static void hookedTakeOwnership(id self, SEL _cmd, id webContents) {
    if (webContents) [gOwners setObject:self forKey:webContents];
    origTakeOwnership(self, _cmd, webContents);
}

static id (*origCreateWebContents)(id, SEL, id);
static id hookedCreateWebContents(id self, SEL _cmd, id params) {
    id webContents = origCreateWebContents(self, _cmd, params);
    if (webContents) [gOwners setObject:self forKey:webContents];
    return webContents;
}

static void (*origDidCreate)(id, SEL, id, id, BOOL);
static void hookedDidCreate(id self, SEL _cmd, id browser, id webContents, BOOL active) {
    if (browser && webContents) [gOwners setObject:browser forKey:webContents];
    origDidCreate(self, _cmd, browser, webContents, active);
}

static void (*origDidRestore)(id, SEL, id, id, id);
static void hookedDidRestore(id self, SEL _cmd, id browser, id webContents, id sessionId) {
    if (browser && webContents) [gOwners setObject:browser forKey:webContents];
    origDidRestore(self, _cmd, browser, webContents, sessionId);
}

static void installTracking(void) {
    gDelegates = [NSMapTable weakToWeakObjectsMapTable];
    gOwners = [NSMapTable weakToWeakObjectsMapTable];
    Class browser = NSClassFromString(@"ArcBrowser"), chromium = NSClassFromString(@"ADK.ChromiumBrowser");
    if (!browser || !chromium) { NSLog(@"[DiaPatches] ArcBrowser not found; tab sorting inactive"); return; }
    origSetDelegate = (void *)hook(browser, @selector(setDelegate:), (IMP)hookedSetDelegate);
    origTakeOwnership = (void *)hook(browser, @selector(takeOwnershipOfWebContents:), (IMP)hookedTakeOwnership);
    origCreateWebContents = (void *)hook(browser, @selector(createWebContents:), (IMP)hookedCreateWebContents);
    origDidCreate = (void *)hook(chromium, @selector(browser:didCreateNewWebContents:isActive:), (IMP)hookedDidCreate);
    origDidRestore = (void *)hook(chromium, @selector(browser:didRestoreWebContents:withSessionId:), (IMP)hookedDidRestore);
}

static BOOL tabsAvailable(void) {
    return origSetDelegate && origDidCreate && origDidRestore &&
        [NSClassFromString(@"ADK.ChromiumBrowser") instancesRespondToSelector:@selector(browser:createTabGroupWithSessionIds:properties:completion:)];
}

static NSString *urlString(id url) {
    if ([url isKindOfClass:NSURL.class]) return [url absoluteString];
    return [url isKindOfClass:NSString.class] ? url : nil;
}

// The site: "help.github.com" and "github.com" are both "github.com"; keeps one more
// label for two-letter country domains like "bbc.co.uk".
#pragma mark - Folders

// A Dia folder made from the window's tabs at `urls` (matched to Chromium's web contents by address), through the
// tab-group call Dia answers for Chromium. `done` gets the folder's ID, or nil.
static void createFolder(NSWindow *window, NSArray<NSString *> *urls, NSString *title, void (^done)(NSString *groupId)) {
    NSMutableArray *ids = [NSMutableArray array];
    id browser = nil;
    for (id wc in gOwners.keyEnumerator.allObjects) {
        id owner = [gOwners objectForKey:wc];
        @try {
            if (![[owner valueForKey:@"windowIdentifier"] isEqual:window.identifier]) continue;
            NSString *url = urlString([wc valueForKey:@"url"]);
            if (!url || ![urls containsObject:url]) continue;
            NSInteger sid = ((NSInteger (*)(id, SEL))objc_msgSend)([wc valueForKey:@"sessionId"], @selector(identifier));
            if (sid < 0 || (browser && browser != owner)) continue;
            browser = owner;
            [ids addObject:@(sid)];
        } @catch (__unused NSException *e) {}
    }
    id delegate = browser ? [gDelegates objectForKey:browser] : nil;
    if (!ids.count || ![delegate respondsToSelector:@selector(browser:createTabGroupWithSessionIds:properties:completion:)]) { done(nil); return; }
    id props = [NSClassFromString(@"ArcTabGroupProperties") new];
    [props setValue:title forKey:@"title"];
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(delegate, @selector(browser:createTabGroupWithSessionIds:properties:completion:),
        browser, ids, props, ^(id result) {
            BOOL ok = [result respondsToSelector:@selector(success)] && ((BOOL (*)(id, SEL))objc_msgSend)(result, @selector(success));
            NSString *groupId = ok && [result respondsToSelector:@selector(groupId)] ? ((id (*)(id, SEL))objc_msgSend)(result, @selector(groupId)) : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ done(groupId); });
        });
}

#pragma mark - Public

void DPTabsInstall(void) { installTracking(); }
BOOL DPTabsAvailable(void) { return tabsAvailable(); }
void DPTabsCreateFolder(NSWindow *window, NSArray<NSString *> *urls, NSString *title, void (^done)(NSString *groupId)) {
    createFolder(window, urls, title, done);
}

NSArray *DPTabsWebContents(void) {
    return gOwners.keyEnumerator.allObjects;
}
