#import "Peek.h"

static const CGFloat DPHintHeight = 26, DPHintPadX = 10, DPHintPadY = 5, DPHintLabelGap = 6, DPHintCapGap = 4, DPHintRightGap = 10;

@interface DPPeekButton : NSButton
@property (nonatomic, weak) NSView *pill;
@property (nonatomic, copy) NSString *hintText;
@property (nonatomic, copy) NSArray<NSString *> *hintKeys;
@property (nonatomic, strong) CAShapeLayer *circle;
@property (nonatomic, strong) CALayer *iconLayer;
@end

// A view's layer scales from its corner.
CATransform3D DPPeekScaled(NSView *view, CGFloat scale) {
    CGFloat cx = NSWidth(view.bounds) / 2, cy = NSHeight(view.bounds) / 2;
    return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(cx, cy, 0), scale, scale, 1), -cx, -cy, 0);
}

@implementation DPPeekButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)layout {
    [super layout];
    self.circle.frame = self.bounds;
    CGPathRef path = CGPathCreateWithEllipseInRect(self.bounds, NULL);
    self.circle.path = path;
    CGPathRelease(path);
    self.iconLayer.frame = self.bounds;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.circle.fillColor = [NSColor colorWithWhite:0.08 alpha:highlighted ? 0.7 : 0.9].CGColor;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
                                                         owner:self userInfo:nil]];
}

- (void)grow:(BOOL)hovered {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.12;
        context.allowsImplicitAnimation = YES;
        self.layer.transform = hovered ? DPPeekScaled(self, 1.12) : CATransform3DIdentity;
    }];
}

- (void)showHint {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.12;
        self.pill.animator.alphaValue = 1;
    }];
}

- (void)mouseEntered:(NSEvent *)event {
    [self grow:YES];
    [self performSelector:@selector(showHint) withObject:nil afterDelay:1.0];
}

- (void)mouseExited:(NSEvent *)event {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showHint) object:nil];
    [self grow:NO];
    self.pill.alphaValue = 0;
}
@end

static NSBitmapImageRep *DPPeekDraw(NSSize size, CGFloat scale, void (^draw)(void)) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size.width * scale pixelsHigh:size.height * scale
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}

// Symbol images aren't padded evenly, and their ink shifts with the scale they're drawn at.
static CGPoint DPPeekInkCentre(NSImage *symbol, CGFloat scale) {
    NSBitmapImageRep *bitmap = DPPeekDraw(symbol.size, scale, ^{ [symbol drawInRect:(NSRect){NSZeroPoint, symbol.size}]; });
    NSInteger minX = bitmap.pixelsWide, maxX = 0, minY = bitmap.pixelsHigh, maxY = 0;
    for (NSInteger y = 0; y < bitmap.pixelsHigh; y++)
        for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
            NSUInteger pixel[4];
            [bitmap getPixel:pixel atX:x y:y];
            if (pixel[3] < 77) continue;
            minX = MIN(minX, x), maxX = MAX(maxX, x), minY = MIN(minY, y), maxY = MAX(maxY, y);
        }
    return CGPointMake((minX + maxX + 1) / (2 * scale), symbol.size.height - (minY + maxY + 1) / (2 * scale));
}

static id DPPeekIcon(NSString *name, CGFloat side, CGFloat scale) {
    static NSMutableDictionary *icons;
    if (!icons) icons = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%@@%g", name, scale];
    if (icons[key]) return icons[key];
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                       imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold]];
    CGPoint ink = DPPeekInkCentre(symbol, scale);
    NSBitmapImageRep *bitmap = DPPeekDraw(NSMakeSize(side, side), scale, ^{
        [symbol drawInRect:(NSRect){{side / 2 - ink.x, side / 2 - ink.y}, symbol.size}];
        [NSColor.whiteColor set];
        NSRectFillUsingOperation(NSMakeRect(0, 0, side, side), NSCompositingOperationSourceAtop);
    });
    return icons[key] = (__bridge id)bitmap.CGImage;
}

static NSView *DPPeekKeycap(NSString *glyph) {
    static const CGFloat height = 17;
    NSTextField *label = [NSTextField labelWithString:glyph];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    label.textColor = [NSColor colorWithWhite:0.08 alpha:1];
    label.alignment = NSTextAlignmentCenter;
    [label sizeToFit];
    CGFloat width = MAX(height, NSWidth(label.frame) + 8);
    NSView *cap = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    cap.wantsLayer = YES;
    cap.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.95].CGColor;
    cap.layer.cornerRadius = 4;
    cap.layer.cornerCurve = kCACornerCurveContinuous;
    label.frame = NSMakeRect(0, (height - NSHeight(label.frame)) / 2, width, NSHeight(label.frame));
    [cap addSubview:label];
    return cap;
}

static NSSize DPPeekFit(NSTextField *label, CGFloat width) {
    NSSize size = [label.cell cellSizeForBounds:NSMakeRect(0, 0, width, 10000)];
    return NSMakeSize(ceil(size.width), ceil(size.height));
}

static NSView *DPPeekMakeHint(NSString *text, NSArray<NSString *> *keys, CGFloat maxWidth) {
    NSMutableArray<NSView *> *caps = [NSMutableArray array];
    CGFloat capsWidth = keys.count ? -DPHintCapGap : 0, capsHeight = 0;
    for (NSString *key in keys) {
        NSView *cap = DPPeekKeycap(key);
        [caps addObject:cap];
        capsWidth += NSWidth(cap.frame) + DPHintCapGap;
        capsHeight = NSHeight(cap.frame);
    }
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = NSColor.whiteColor;
    label.usesSingleLineMode = NO;
    label.cell.wraps = YES;
    label.cell.lineBreakMode = NSLineBreakByWordWrapping;

    BOOL stacked = caps.count && DPPeekFit(label, 10000).width + DPHintLabelGap + capsWidth > maxWidth;
    CGFloat capsBlock = caps.count && !stacked ? DPHintLabelGap + capsWidth : 0;
    NSSize fit = DPPeekFit(label, stacked ? MAX(MAX(40, capsWidth), maxWidth) : MAX(40, maxWidth - capsBlock));
    CGFloat content = stacked ? MAX(fit.width, capsWidth) : fit.width + capsBlock;
    CGFloat height = stacked ? 2 * DPHintPadY + fit.height + DPHintLabelGap + capsHeight
                             : MAX(DPHintHeight, MAX(fit.height, capsHeight) + 2 * DPHintPadY);

    NSView *pill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, content + 2 * DPHintPadX, height)];
    pill.wantsLayer = YES;
    pill.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.92].CGColor;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.cornerRadius = MIN(height / 2, 13);
    pill.alphaValue = 0;
    if (stacked) label.alignment = NSTextAlignmentCenter;
    label.frame = stacked ? NSMakeRect(DPHintPadX, height - DPHintPadY - fit.height, content, fit.height)
                          : NSMakeRect(DPHintPadX, (height - fit.height) / 2, fit.width, fit.height);
    [pill addSubview:label];
    CGFloat x = stacked ? DPHintPadX + (content - capsWidth) / 2 : NSMaxX(label.frame) + DPHintLabelGap;
    for (NSView *cap in caps) {
        cap.frame = NSMakeRect(x, stacked ? DPHintPadY : (height - NSHeight(cap.frame)) / 2, NSWidth(cap.frame), NSHeight(cap.frame));
        [pill addSubview:cap];
        x += NSWidth(cap.frame) + DPHintCapGap;
    }
    return pill;
}

void DPPeekLayoutHints(NSView *controls, CGFloat availableRight) {
    for (DPPeekButton *button in [controls.subviews copy]) {
        if (![button isKindOfClass:DPPeekButton.class]) continue;
        [button.pill removeFromSuperview];
        NSView *pill = DPPeekMakeHint(button.hintText, button.hintKeys, MAX(40, availableRight - DPHintRightGap - 2 * DPHintPadX));
        pill.frame = NSMakeRect(NSMaxX(button.frame) + DPHintRightGap, NSMidY(button.frame) - NSHeight(pill.frame) / 2, NSWidth(pill.frame), NSHeight(pill.frame));
        button.pill = pill;
        [controls addSubview:pill];
    }
}

// Not a stack view, which squeezed the circles out of shape.
NSView *DPPeekControls(id target, SEL action) {
    static const CGFloat side = 28, gap = 8;
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2;
    NSArray<NSDictionary *> *specs = @[
        @{@"symbol": @"xmark", @"a11y": @"Close Peek", @"hint": @"Close", @"keys": @[@"⌘", @"W"]},
        @{@"symbol": @"arrow.up.left.and.arrow.down.right", @"a11y": @"Open as Tab", @"hint": @"Expand", @"keys": @[@"⌘", @"O"]},
        @{@"symbol": @"rectangle.split.2x1", @"a11y": @"Create Split View", @"hint": @"Create Split View"},
    ];
    NSView *controls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, side, specs.count * side + (specs.count - 1) * gap)];
    controls.clipsToBounds = NO;
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSDictionary *spec = specs[i];
        DPPeekButton *button = [DPPeekButton buttonWithTitle:@"" target:target action:action];
        button.tag = i;
        button.bordered = NO;
        button.accessibilityLabel = spec[@"a11y"];
        button.hintText = spec[@"hint"];
        button.hintKeys = spec[@"keys"];
        button.wantsLayer = YES;
        button.frame = NSMakeRect(0, (specs.count - 1 - i) * (side + gap), side, side);

        button.circle = [CAShapeLayer layer];
        button.circle.fillColor = [NSColor colorWithWhite:0.08 alpha:0.9].CGColor;
        [button.layer addSublayer:button.circle];

        button.iconLayer = [CALayer layer];
        button.iconLayer.contents = DPPeekIcon(spec[@"symbol"], side, scale);
        button.iconLayer.contentsScale = scale;
        [button.layer addSublayer:button.iconLayer];

        [controls addSubview:button];
    }
    return controls;
}
