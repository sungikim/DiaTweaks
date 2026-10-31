#import "Settings.h"

static NSView *DPGroup(NSArray<NSView *> *rows) {
    NSStackView *stack = [NSStackView new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 0;
    [rows enumerateObjectsUsingBlock:^(NSView *row, NSUInteger i, BOOL *_) {
        if (i > 0) {
            NSBox *line = [NSBox new];
            line.boxType = NSBoxSeparator;
            [stack addArrangedSubview:line];
            [line.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
        }
        [stack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }];
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0;
    box.cornerRadius = 10;
    box.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.04];
    box.contentViewMargins = NSZeroSize;
    box.contentView = stack;
    return box;
}

static NSView *DPRow(NSView *leading, NSView *trailing) {
    NSView *row = [NSView new];
    for (NSView *v in @[leading, trailing]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:v];
    }
    [trailing setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [leading.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [leading.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [leading.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10],
        [trailing.leadingAnchor constraintGreaterThanOrEqualToAnchor:leading.trailingAnchor constant:12],
        [trailing.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [trailing.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

static NSTextField *DPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

static NSView *DPIconTile(NSString *symbol, NSColor *color) {
    NSView *tile = [NSView new];
    tile.wantsLayer = YES;
    tile.layer.backgroundColor = color.CGColor;
    tile.layer.cornerRadius = 5;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    NSImageView *glyph = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
    glyph.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
    glyph.contentTintColor = NSColor.whiteColor;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [tile.widthAnchor constraintEqualToConstant:20],
        [tile.heightAnchor constraintEqualToConstant:20],
        [glyph.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
    ]];
    return tile;
}

NSToolbarItemIdentifier const DPSearchItemIdentifier = @"DiaPatchesSearch";

@interface DPFlippedView : NSView
@end
@implementation DPFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface DPPaneView () <NSSearchFieldDelegate>
@property (nonatomic, strong) NSArray<NSSwitch *> *toggles;
@property (nonatomic, strong) NSArray<NSArray *> *sections;  // header, group, rows
@property (nonatomic, strong) NSMapTable<NSView *, NSString *> *searchText;
@property (nonatomic, strong) NSTextField *noResults, *notice;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSButton *checkButton;
@property (nonatomic, strong) NSButton *relaunchButton;
@end

@implementation DPPaneView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _searchText = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<NSView *> *patchRows = [NSMutableArray new];
    NSMutableArray<NSSwitch *> *toggles = [NSMutableArray new];
    for (NSUInteger i = 0; i < DPPatchCount; i++) {
        DPPatch *patch = DPPatches[i];
        NSStackView *text = [NSStackView stackViewWithViews:@[
            DPLabel(patch->title, 13, NSFontWeightRegular, NSColor.labelColor),
            DPLabel(patch->unavailable ? @"Unavailable on this Dia version." : patch->detail, 11, NSFontWeightRegular, NSColor.secondaryLabelColor),
        ]];
        text.orientation = NSUserInterfaceLayoutOrientationVertical;
        text.alignment = NSLayoutAttributeLeading;
        text.spacing = 2;
        NSStackView *leading = [NSStackView stackViewWithViews:@[DPIconTile(patch->symbol, patch->tint()), text]];
        leading.spacing = 10;
        leading.alignment = NSLayoutAttributeCenterY;
        NSSwitch *toggle = [NSSwitch new];
        toggle.controlSize = NSControlSizeSmall;
        toggle.state = patch->on;
        toggle.tag = i;
        toggle.target = self;
        toggle.action = @selector(toggle:);
        [toggles addObject:toggle];
        NSView *row = DPRow(leading, toggle);
        [_searchText setObject:[NSString stringWithFormat:@"%@ %@", patch->title, patch->detail] forKey:row];
        [patchRows addObject:row];
    }
    _toggles = toggles;

    _status = DPLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _checkButton = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(checkForUpdates:)];
    _relaunchButton = [NSButton buttonWithTitle:@"Relaunch to Update" target:self action:@selector(relaunchToUpdate:)];
    _relaunchButton.bezelColor = NSColor.controlAccentColor;
    _relaunchButton.hidden = YES;
    NSView *updateRow = DPRow(_status, [NSStackView stackViewWithViews:@[_relaunchButton, _checkButton]]);
    NSView *restoreRow = DPRow(DPLabel(@"Restore the original Dia without patches.", 13, NSFontWeightRegular, NSColor.labelColor),
                               [NSButton buttonWithTitle:@"Restore…" target:self action:@selector(restore:)]);
    [_searchText setObject:@"Check for updates version" forKey:updateRow];
    [_searchText setObject:@"Restore the original Dia without patches uninstall" forKey:restoreRow];
    NSMutableArray<NSArray *> *groups = [NSMutableArray arrayWithArray:@[@[@"Interface", patchRows], @[@"Updates", @[updateRow, restoreRow]]]];
    if (DPSafeMode) {
        NSView *safeModeRow = DPRow(DPLabel(@"Patches are off because Dia quit unexpectedly twice right after opening.", 13, NSFontWeightRegular, NSColor.labelColor),
                                    [NSButton buttonWithTitle:@"Turn Patches Back On" target:self action:@selector(leaveSafeMode:)]);
        [_searchText setObject:@"Safe mode patches off crashed quit unexpectedly turn back on" forKey:safeModeRow];
        [groups insertObject:@[@"Safe Mode", @[safeModeRow]] atIndex:0];
    }

    _searchItem = [[NSSearchToolbarItem alloc] initWithItemIdentifier:DPSearchItemIdentifier];
    _searchItem.searchField.delegate = self;
    _noResults = DPLabel(@"No results", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _notice = DPLabel(@"DiaPatches is unofficial and not affiliated with The Browser Company.", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSMutableArray<NSView *> *views = [NSMutableArray new];
    NSMutableArray<NSArray *> *sections = [NSMutableArray new];
    for (NSArray *section in groups) {
        NSTextField *header = DPLabel(section[0], 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
        NSView *group = DPGroup(section[1]);
        [views addObjectsFromArray:@[header, group]];
        [sections addObject:@[header, group, section[1]]];
    }
    [views addObjectsFromArray:@[_noResults, _notice]];
    _sections = sections;

    NSStackView *content = [NSStackView stackViewWithViews:views];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 8;
    for (NSView *v in content.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    // Dia's Settings window doesn't grow, so the pane scrolls below the window's title.
    DPFlippedView *document = [DPFlippedView new];
    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = document;
    [document addSubview:content];
    [self addSubview:scroll];
    for (NSView *v in @[content, document, scroll]) v.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *fill = [content.widthAnchor constraintEqualToAnchor:document.widthAnchor constant:-48];
    fill.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.topAnchor constant:52],
        [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [content.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20],
        [content.centerXAnchor constraintEqualToAnchor:document.centerXAnchor],
        [content.widthAnchor constraintLessThanOrEqualToConstant:560],
        fill,
    ]];
    [self updateRows];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor; }

// Unhandled events would reach Dia's pane underneath via the responder chain.
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {}
- (void)rightMouseDown:(NSEvent *)event {}
- (void)rightMouseUp:(NSEvent *)event {}
- (void)otherMouseDown:(NSEvent *)event {}
- (void)otherMouseUp:(NSEvent *)event {}
- (void)scrollWheel:(NSEvent *)event {}
- (NSMenu *)menuForEvent:(NSEvent *)event { return nil; }

- (BOOL)matches:(NSView *)row words:(NSArray<NSString *> *)words {
    NSString *text = [self.searchText objectForKey:row];
    for (NSString *word in words) if (word.length && ![text localizedStandardContainsString:word]) return NO;
    return YES;
}

- (void)updateRows {
    NSString *query = self.searchItem.searchField.stringValue;
    NSArray<NSString *> *words = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL searching = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0;
    NSMutableSet<NSView *> *hiddenRows = [NSMutableSet set];
    for (NSSwitch *toggle in self.toggles) {
        DPPatch *patch = DPPatches[toggle.tag];
        toggle.enabled = !patch->unavailable && !(patch->disabledBy && patch->disabledBy->on);
        if (patch->requires && !patch->requires->on) [hiddenRows addObject:toggle.superview];
    }
    BOOL anything = NO;
    for (NSArray *section in self.sections) {
        BOOL any = NO;
        for (NSView *row in section[2]) {
            BOOL visible = ![hiddenRows containsObject:row] && [self matches:row words:words];
            NSArray<NSView *> *arranged = ((NSStackView *)row.superview).arrangedSubviews;
            NSUInteger index = [arranged indexOfObject:row];
            row.hidden = !visible;
            if (index > 0) arranged[index - 1].hidden = !visible || !any;
            any |= visible;
        }
        for (NSView *view in @[section[0], section[1]]) view.hidden = !any;
        anything |= any;
    }
    self.noResults.hidden = anything;
    self.notice.hidden = searching;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self updateRows];
}

- (void)toggle:(NSSwitch *)sender {
    DPSetPatch(DPPatches[sender.tag], sender.state == NSControlStateValueOn);
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.allowsImplicitAnimation = YES;
        [self updateRows];
        [self layoutSubtreeIfNeeded];
    }];
}

- (void)showStatus:(NSDictionary *)status {
    NSString *running = [NSString stringWithFormat:@"Dia %@ (%@)",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
    id staged = status[@"staged"];
    BOOL ready = [staged isKindOfClass:NSString.class];
    self.status.stringValue = !status ? [running stringByAppendingString:@" · couldn’t check for updates"]
                            : ready   ? [NSString stringWithFormat:@"Dia %@ installs when you quit", staged]
                                      : [running stringByAppendingString:@" · up to date"];
    self.relaunchButton.hidden = !ready;
    self.checkButton.enabled = YES;
}

- (void)checkForUpdates:(NSButton *)sender {
    sender.enabled = NO;
    self.status.stringValue = @"Checking for updates…";
    __weak DPPaneView *weakSelf = self;
    DPCheckForUpdates(^(NSDictionary *status) { [weakSelf showStatus:status]; });
}

- (void)refresh {
    __weak DPPaneView *weakSelf = self;
    DPRunCLI(@[@"status", @"--json"], ^(NSString *output) {
        id status = output ? [NSJSONSerialization JSONObjectWithData:[output dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        [weakSelf showStatus:[status isKindOfClass:NSDictionary.class] ? status : nil];
    });
}

- (void)relaunchToUpdate:(id)sender {
    DPHandOffAndQuit(@"apply");
}

- (void)leaveSafeMode:(id)sender {
    DPLeaveSafeMode();
    DPHandOffAndQuit(@"apply");
}

- (void)restore:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Restore the original Dia?";
    alert.informativeText = @"Dia will relaunch without patches, and its own updater takes over again. Run the installer to patch it again later.";
    [alert addButtonWithTitle:@"Restore and Relaunch"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) DPHandOffAndQuit(@"uninstall");
    }];
}
@end
