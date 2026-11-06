// Peek on Shift-Click, ported from JaceThings/DiaTweaks (src/dylib/Patches/Peek).
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define DPDiaContentPane "_TtC11ContentPane15ContentPaneView"
#define DPDiaBrowser "ArcBrowser"
#define DPDiaWebContents "ArcWebContents"
#define DPDiaBrowserContext "ArcBrowserContext"
#define DPDiaWebContentsConfiguration "ArcWebContentsConfiguration"
#define DPDiaWebContent "_TtC3ADK18WebContentChromium"  // A Swift class: look it up after launch.

void DPHook(const char *className, SEL sel, IMP replacement);
IMP DPOriginalIMP(id object, SEL sel, IMP replacement);
#define DPCallOriginal(hook, self, ...) ((__typeof__(&hook))DPOriginalIMP(self, _cmd, (IMP)hook))(self, _cmd, ##__VA_ARGS__)
NSView *DPFindView(NSView *root, BOOL (^match)(NSView *view));  // Root included.
NSArray<NSView *> *DPFindViews(const char *className);
BOOL DPIsKind(id object, const char *className);
id DPGet(id object, const void *key);
void DPSet(id object, const void *key, id value);

#import "PeekTweak.h"

typedef NS_ENUM(NSInteger, DPPeekExit) { DPPeekClose, DPPeekTab, DPPeekSplit };  // Also the controls' button tags.

// ArcWebContentsNavigationDisposition, numbered differently from Chromium's. A Shift-click arrives as a popup.
enum { DPIgnoreAction = 0, DPCurrentTab = 1, DPForegroundTab = 2, DPBackgroundTab = 3, DPNewWindow = 5, DPPopup = 6, DPSplitView = 9 };

@protocol DPPeekPage <NSObject>
- (NSView *)createPaneHostView;
- (void)attachToPaneHostView:(NSView *)host;
- (void)detachFromPaneHostView:(NSView *)host;
@end

@interface DPPeekCard : NSView
@property (nonatomic, strong) NSView *dim, *card, *shade, *clip, *host, *controls;
@property (nonatomic, strong) id<DPPeekPage> page;
@property (nonatomic, weak) id sourceDelegate, source;
@property (nonatomic, weak) NSView *pane;
@property (nonatomic, strong) id paneObserver, monitor;
@property (nonatomic) NSRect link;    // In the card's own coordinates.
@property (nonatomic) CGFloat grown;  // 0 at rest, 1 filling the page area.
@property (nonatomic) BOOL closing;
@property (nonatomic) NSInteger paneMoves;
- (NSRect)cardFrame;
- (void)close:(DPPeekExit)exit;
- (void)handOver;
@end

@interface DPPeekCard (Motion)
- (void)animateIn;
- (void)animateOut:(void (^)(void))completion;
- (void)animateExpand:(void (^)(void))completion;
@end

@interface DPPeekCard (Handoff)
- (void)finish:(DPPeekExit)exit;
@end

DPPeekCard *DPPeekCardIn(NSWindow *window);
DPPeekCard *DPPeekShowCard(NSWindow *window, id<DPPeekPage> page, NSView *warmHost, NSRect screenLink);
NSView *DPPeekWarmHost(NSWindow *window, id<DPPeekPage> page);

NSView *DPPeekControls(id target, SEL action);
void DPPeekLayoutHints(NSView *controls, CGFloat availableRight);
CATransform3D DPPeekScaled(NSView *view, CGFloat scale);
CASpringAnimation *DPPeekSpring(NSString *keyPath, CFTimeInterval response, CGFloat dampingRatio);

double DPPeekDarkness(void);
double DPPeekResponse(void);
BOOL DPPeekGenie(void);

void DPPeekInstallPages(void);
BOOL DPPeekCanOpen(id source);
BOOL DPPeekShows(id page);
void DPPeekLoad(id page, NSURL *url);
void DPPeekOpen(NSWindow *window, NSURL *url, NSPoint origin, id delegate, id source);
void DPPeekWarm(NSWindow *window, id source, NSURL *url);
void DPPeekCool(void);
