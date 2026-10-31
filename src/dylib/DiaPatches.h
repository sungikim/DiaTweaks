#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

typedef struct DPPatch DPPatch;
struct DPPatch {
    __unsafe_unretained NSString *key;
    BOOL defaultOn;
    __unsafe_unretained NSString *title, *detail, *symbol;
    NSColor *(*tint)(void);
    DPPatch *requires;    // Settings shows the row only while this patch is on.
    DPPatch *disabledBy;  // Settings disables the switch while this patch is on.
    void (*install)(void);
    void (*apply)(DPPatch *patch);  // Applies a toggle at once. Without it, `progress` eases toward `on` while every patch's `relayout` runs each frame.
    void (*relayout)(void);
    BOOL on;
    CGFloat progress;
};

extern DPPatch DPEdgeToEdge, DPSquareSidebarCorners, DPHideToolbar, DPRevealToolbarOnHover, DPHideSidebarButton, DPHideChatButton, DPHideChatsButton, DPHideRecentTabsButton;
extern DPPatch *const DPPatches[];
extern const NSUInteger DPPatchCount;

void DPSetPatch(DPPatch *patch, BOOL on);

// Hooks on the same method chain: each replacement's DPCallOriginal calls what was there when it was installed. It finds
// that by the replacement's name (__func__), so pass DPHook the function itself and call DPCallOriginal directly in it,
// not from a block or helper.
#define DPHook(cls, sel, function) DPHookFunction(cls, sel, (IMP)function, #function)
void DPHookFunction(Class cls, SEL sel, IMP replacement, const char *name);
IMP DPOriginalIMP(id object, SEL sel, const char *name);

#define DPCallOriginal(type, object, sel, ...) ((type)DPOriginalIMP(object, sel, __func__))(object, sel, ##__VA_ARGS__)

NSView *DPFindView(NSView *root, BOOL (^match)(NSView *));

void DPInstallButtons(void);
void DPApplyButtons(DPPatch *patch);

void DPInstallSettings(void);

void DPInstallGroupTabs(void);

void DPInstallUpdates(void);
void DPRunCLI(NSArray<NSString *> *args, void (^completion)(NSString *output));
void DPCheckForUpdates(void (^completion)(NSDictionary *status));
void DPHandOffAndQuit(NSString *command);

// 0: normal. 1: Dia died twice right after launching, so no patch or command hooks. 2: it kept dying, so nothing at all.
extern NSInteger DPSafeMode;
void DPBeginLaunch(void);
void DPLeaveSafeMode(void);
