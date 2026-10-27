#import "Panel.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import "Devices.h"
#import "Energy.h"
#import "NC.h"
#import "TV.h"

// ── Palette (lib/main.dart) ──────────────────────────────────────────────
static const uint32_t kTvViolet = 0xFFB69CFF, kBoxBlue = 0xFF5EC8FF, kFanGreen = 0xFF6EE7A0;
static const uint32_t kWarm = 0xFFFFB547, kCool = 0xFFBFE0FF, kRed = 0xFFFF453A, kWhite = 0xFFE8E8E8;
static const uint32_t kAcModeHues[] = {0xFF5EEAD4, 0xFF4FD8EB, 0xFF7CB8FF, 0xFF6EE7A0, 0xFFFF8A4C};
static NSString *const kAcModeNames[] = {@"Auto", @"Cool", @"Dry", @"Fan", @"Heat"};
/// The setpoint dial, 16° to 30°: cyan, mint, yellow, orange.
static const uint32_t kDialStops[] = {0xFF4FD8EB, 0xFF6EE7A0, 0xFFFFD166, 0xFFFF8A4C};
static const NSInteger kPresets[] = {1, 25, 50, 100};

static UIColor *white(CGFloat a) { return [NCRGB(kWhite) colorWithAlphaComponent:a]; }
static UIColor *alpha(UIColor *c, CGFloat a) { return [c colorWithAlphaComponent:a]; }

/// [fg] composited over [bg] (Color.alphaBlend).
static UIColor *blend(UIColor *fg, UIColor *bg) {
  CGFloat fr, fgr, fb, fa, br, bgr, bb, ba;
  [fg getRed:&fr green:&fgr blue:&fb alpha:&fa];
  [bg getRed:&br green:&bgr blue:&bb alpha:&ba];
  CGFloat a = fa + ba * (1 - fa);
  if (a <= 0) return UIColor.clearColor;
  return [UIColor colorWithRed:(fr * fa + br * ba * (1 - fa)) / a
                         green:(fgr * fa + bgr * ba * (1 - fa)) / a
                          blue:(fb * fa + bb * ba * (1 - fa)) / a
                         alpha:a];
}

static UIColor *lerp(UIColor *a, UIColor *b, CGFloat t) {
  CGFloat ar, ag, ab, aa, br, bg, bb, ba;
  [a getRed:&ar green:&ag blue:&ab alpha:&aa];
  [b getRed:&br green:&bg blue:&bb alpha:&ba];
  return [UIColor colorWithRed:ar + (br - ar) * t green:ag + (bg - ag) * t
                          blue:ab + (bb - ab) * t alpha:aa + (ba - aa) * t];
}

static UIFont *inter(NSString *weight, CGFloat size) {
  return [UIFont fontWithName:[@"Inter-" stringByAppendingString:weight] size:size]
      ?: [UIFont systemFontOfSize:size];
}

static NSDictionary *textAttrs(UIFont *font, UIColor *color, CGFloat kern) {
  return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern)};
}

/// Draws [text] centred on [center].
static void drawCentered(NSString *text, NSDictionary *attrs, CGPoint center) {
  CGSize s = [text sizeWithAttributes:attrs];
  [text drawAtPoint:CGPointMake(center.x - s.width / 2, center.y - s.height / 2) withAttributes:attrs];
}

static void fillGradient(CGContextRef ctx, NSArray<UIColor *> *colors, const CGFloat *stops, CGPoint from, CGPoint to) {
  NSMutableArray *cg = [NSMutableArray array];
  for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, stops);
  CGContextDrawLinearGradient(ctx, g, from, to, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  CGGradientRelease(g);
  CGColorSpaceRelease(space);
}

/// The frosted card every device sits on (_GlowCard): a diagonal wash of
/// the device's hue, and a border bright at the top-left, fading out.
static void drawCard(CGRect r, UIColor *hue, BOOL on, BOOL alert, CGFloat u) {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGFloat radius = u * 1.8;
  UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
  CGContextSaveGState(ctx);
  [path addClip];
  fillGradient(ctx, @[blend(alpha(hue, on ? 0.22 : 0.07), white(0.09)), blend(alpha(hue, on ? 0.06 : 0), white(0.035))],
               NULL, r.origin, CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)));
  CGContextRestoreGState(ctx);

  UIColor *edge = alert ? NCRGB(kRed) : hue;
  CGFloat strength = on ? 0.85 : 0.4;
  CGFloat w = 1.2;
  CGRect er = CGRectInset(r, w / 2, w / 2);
  CGContextSaveGState(ctx);
  CGContextAddPath(ctx, [UIBezierPath bezierPathWithRoundedRect:er cornerRadius:radius - w / 2].CGPath);
  CGContextSetLineWidth(ctx, w);
  CGContextReplacePathWithStrokedPath(ctx);
  CGContextClip(ctx);
  CGFloat stops[] = {0, 0.55, 1};
  fillGradient(ctx, @[alpha(edge, strength), alpha(edge, strength * 0.15), white(0.08)], stops,
               er.origin, CGPointMake(CGRectGetMaxX(er), CGRectGetMaxY(er)));
  CGContextRestoreGState(ctx);
}

/// A rounded "surface" control: faint fill, faint edge.
static void drawSurface(CGRect r, CGFloat radius) {
  UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
  [white(0.06) setFill];
  [p fill];
  [white(0.10) setStroke];
  p.lineWidth = 1;
  [p stroke];
}

static void drawIcon(NSString *name, CGPoint center, CGFloat size, UIColor *color) {
  [NCGlyphs.shared drawIcon:name in:CGRectMake(center.x - size / 2, center.y - size / 2, size, size) color:color];
}

@interface NCPanelView ()
/// A tile's offline / connecting state changed: redraw the status line.
- (void)statusChanged;
@end

/// Draws [text] in [r], one line, cut off with … if too long.
static void drawLine(NSString *text, UIFont *font, UIColor *color, CGRect r) {
  NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  [text drawInRect:r withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color,
                                      NSParagraphStyleAttributeName: ps}];
}

/// Base for the tiles: glow shadow, night flag, unit.
@interface NCTile : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic, weak) NCPanelView *panel;
- (void)setGlow:(UIColor *)hue on:(BOOL)on;
- (void)refresh;
@end

@implementation NCTile
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}
- (void)setNight:(BOOL)night { _night = night; [self setNeedsDisplay]; }
- (void)setUnit:(CGFloat)unit { _unit = unit; [self setNeedsDisplay]; }
- (void)setGlow:(UIColor *)hue on:(BOOL)on {
  self.layer.shadowColor = hue.CGColor;
  self.layer.shadowOpacity = on ? 0.28 : 0;
  self.layer.shadowRadius = self.unit * 1.3;
  self.layer.shadowOffset = CGSizeZero;
  self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.unit * 1.8].CGPath;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.unit * 1.8].CGPath;
}
- (void)onTap:(UITapGestureRecognizer *)g {}
- (void)refresh {}
@end

// ── Light tile ───────────────────────────────────────────────────────────

/// A square tile: one big power button carrying the bulb icon, the name
/// and its state ("Warm Glow · 50%"), and for a dimmable light a
/// 1 / 25 / 50 / 100% bar. From the user's mock-up (Oct 2026).
/// A colour temperature as a colour (Tanner Helland's fit, pulled towards
/// the app's amber at the warm end) — matches _kelvinColor in main.dart.
static UIColor *kelvinColor(NSInteger kelvin) {
  double t = kelvin / 100.0, r, g, b;
  if (t <= 66) {
    r = 255;
    g = 99.47 * log(t) - 161.12;
    b = t <= 19 ? 0 : 138.52 * log(t - 10) - 305.04;
  } else {
    r = 329.7 * pow(t - 60, -0.1332);
    g = 288.12 * pow(t - 60, -0.0755);
    b = 255;
  }
  UIColor *raw = [UIColor colorWithRed:MAX(0, MIN(255, r)) / 255 green:MAX(0, MIN(255, g)) / 255
                                  blue:MAX(0, MIN(255, b)) / 255 alpha:1];
  double warmth = MAX(0, MIN(1, (3500 - kelvin) / 1800.0));
  double coolness = MAX(0, MIN(1, (kelvin - 4500) / 2000.0));
  return lerp(lerp(raw, NCRGB(kWarm), warmth * 0.6), NCRGB(0xFFA8D4FF), coolness * 0.7);
}


@class NCLightTile;

/// The colour-temperature sheet (press and hold a colour bulb's box) —
/// port of _KelvinSheet: the name and kelvin, a thick warm → cool slider,
/// and the presets, over a dimmed screen. Tap outside to close.
@interface NCKelvinSheet : UIView
- (instancetype)initWithTile:(NCLightTile *)tile;
- (void)showIn:(UIView *)host;
@end

/// A light as a lightbox (from the Rive "Lightbox" design by Gary Simon,
/// CC BY 4.0 — port of _tile in main.dart): a shadow box with a wall
/// switch and a bulb. The box — switch included — turns it on or off; on,
/// the bulb lights and its glow fills the box. A Yeelight gets a warm →
/// cool strip across the top of the box. Name, state, then the presets.
@interface NCLightTile : NCTile <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NCLight *light;
@property (nonatomic) BOOL known, on, offline, busy;
@property (nonatomic) NSInteger level;  // -1 unknown
/// The kelvin being set in the sheet, or 0.
@property (nonatomic) NSInteger dragKelvin;
- (CGRect)boxRect;
- (void)run:(BOOL (^)(NCLight *l))action expectOn:(BOOL)on level:(NSInteger)level done:(void (^)(void))done;
@end

@implementation NCLightTile {
  UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithLight:(NCLight *)light {
  if ((self = [super initWithFrame:CGRectZero])) {
    _light = light;
    _level = -1;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];
    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onHold:)];
    hold.minimumPressDuration = 0.4;
    hold.delegate = self;
    [self addGestureRecognizer:hold];
  }
  return self;
}

- (BOOL)isCool {
  NSString *n = self.light.name.lowercaseString;
  return [n containsString:@"white"] || [n containsString:@"cool"];
}
- (NSInteger)kelvin { return self.dragKelvin ?: self.light.kelvin; }
- (UIColor *)glow {
  if (self.light.hasKelvin) return kelvinColor(self.kelvin);
  return NCRGB(self.isCool ? kCool : kWarm);
}
- (UIColor *)hue {
  CGFloat r, g, b, a;
  [self.glow getRed:&r green:&g blue:&b alpha:&a];
  uint32_t argb = 0xFF000000 | ((uint32_t)lround(r * 255) << 16) | ((uint32_t)lround(g * 255) << 8) | (uint32_t)lround(b * 255);
  return NCHue(argb, self.night);
}

- (void)setOffline:(BOOL)offline {
  BOOL changed = offline != _offline;
  _offline = offline;
  if (changed) [self.panel statusChanged];
}
- (void)setKnown:(BOOL)known {
  BOOL changed = known != _known;
  _known = known;
  if (changed) [self.panel statusChanged];
}

- (CGFloat)pad { return self.unit * 0.8; }
- (CGRect)inner { return CGRectInset(self.bounds, self.pad, self.pad); }
- (CGRect)barRect {
  CGRect in = self.inner;
  return CGRectMake(in.origin.x, CGRectGetMaxY(in) - self.unit * 2.9, in.size.width, self.unit * 2.9);
}
/// The shadow box: everything above the name.
- (CGRect)boxRect {
  CGFloat u = self.unit;
  CGRect in = self.inner;
  CGFloat bottom = CGRectGetMaxY(in) - (self.light.dimmable ? u * 3.4 : 0) - u * 2.55;
  return CGRectMake(in.origin.x, in.origin.y, in.size.width, bottom - in.origin.y);
}
- (CGRect)openingIn:(CGRect)r { return CGRectInset(r, self.unit * 0.55, self.unit * 0.55); }
- (CGRect)backWallIn:(CGRect)r {
  CGRect o = [self openingIn:r];
  CGFloat d = MIN(o.size.width, o.size.height) * 0.12;
  return CGRectMake(o.origin.x + d, o.origin.y + d * 0.8, o.size.width - 2 * d, o.size.height - d * 2.1);
}
- (CGRect)switchRect {
  CGRect b = [self backWallIn:self.boxRect];
  return CGRectMake(b.origin.x + b.size.width * 0.12, CGRectGetMidY(b) - b.size.height * 0.24,
                    b.size.height * 0.32, b.size.height * 0.48);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect sw = self.switchRect;
  _spinner.center = CGPointMake(CGRectGetMidX(sw), CGRectGetMidY(sw));
}

static void fillQuad(CGPoint a, CGPoint b, CGPoint c, CGPoint d, UIColor *color) {
  UIBezierPath *p = [UIBezierPath bezierPath];
  [p moveToPoint:a];
  [p addLineToPoint:b];
  [p addLineToPoint:c];
  [p addLineToPoint:d];
  [p closePath];
  [color setFill];
  [p fill];
}

- (void)drawBox:(CGRect)r hue:(UIColor *)hue on:(BOOL)on {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGFloat u = self.unit, level = self.level >= 0 ? self.level / 100.0 : 1;
  CGFloat glow = on ? 0.35 + 0.65 * level : 0;
  CGRect o = [self openingIn:r], b = [self backWallIn:r];
  UIColor *(^wall)(CGFloat) = ^UIColor *(CGFloat shade) {
    return blend(alpha(hue, glow * 0.45 * shade), lerp(NCRGB(0xFF15171C), NCRGB(0xFF2A2D35), shade));
  };
  // Frame.
  UIBezierPath *frame = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:u * 0.9];
  CGContextSaveGState(ctx);
  [frame addClip];
  fillGradient(ctx, @[blend(alpha(hue, glow * 0.25), white(0.16)), white(0.05)], NULL, r.origin,
               CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)));
  CGContextRestoreGState(ctx);
  CGContextSaveGState(ctx);
  [[UIBezierPath bezierPathWithRoundedRect:o cornerRadius:u * 0.4] addClip];
  CGPoint otl = o.origin, otr = CGPointMake(CGRectGetMaxX(o), o.origin.y);
  CGPoint obl = CGPointMake(o.origin.x, CGRectGetMaxY(o)), obr = CGPointMake(CGRectGetMaxX(o), CGRectGetMaxY(o));
  CGPoint btl = b.origin, btr = CGPointMake(CGRectGetMaxX(b), b.origin.y);
  CGPoint bbl = CGPointMake(b.origin.x, CGRectGetMaxY(b)), bbr = CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b));
  fillQuad(otl, otr, btr, btl, wall(0.15));
  fillQuad(otl, btl, bbl, obl, wall(0.45));
  fillQuad(otr, obr, bbr, btr, wall(0.35));
  fillQuad(bbl, bbr, obr, obl, wall(0.75));
  [wall(0.55) setFill];
  UIRectFill(b);
  if (on) {
    CGPoint c = CGPointMake(b.origin.x + b.size.width * 0.62, b.origin.y + b.size.height * 0.42);
    CGFloat rad = MAX(b.size.width, b.size.height) * (0.55 + 0.35 * level);
    NSArray *cols = @[(id)alpha(lerp(hue, UIColor.whiteColor, 0.35), glow).CGColor,
                      (id)alpha(hue, 0.4 * glow).CGColor, (id)alpha(hue, 0).CGColor];
    CGFloat stops[] = {0, 0.45, 1};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cols, stops);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, rad, 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
  }
  [[UIColor colorWithWhite:0 alpha:0.25] setStroke];
  UIRectFrame(b);
  CGContextRestoreGState(ctx);
  if (self.offline) {
    UIBezierPath *edge = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 0.6, 0.6) cornerRadius:u * 0.9];
    edge.lineWidth = 1.2;
    [alpha(NCRGB(kRed), 0.5) setStroke];
    [edge stroke];
  }

  // The wall switch: a plate with a rocker, up and lit when on.
  CGRect sw = self.switchRect;
  CGFloat w = sw.size.width, h = sw.size.height;
  UIBezierPath *plate = [UIBezierPath bezierPathWithRoundedRect:sw cornerRadius:w * 0.14];
  CGContextSaveGState(ctx);
  CGContextSetShadowWithColor(ctx, CGSizeMake(w * 0.05, w * 0.08), w * 0.2, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
  [white(0.15) setFill];
  [plate fill];
  CGContextRestoreGState(ctx);
  [white(0.18) setStroke];
  [plate stroke];
  CGRect slot = CGRectMake(CGRectGetMidX(sw) - w * 0.21, CGRectGetMidY(sw) - h * 0.26, w * 0.42, h * 0.52);
  [[UIColor colorWithWhite:0 alpha:0.35] setFill];
  [[UIBezierPath bezierPathWithRoundedRect:slot cornerRadius:w * 0.08] fill];
  if (!self.busy) {
    CGRect s2 = CGRectInset(slot, w * 0.04, w * 0.04);
    CGFloat rh = h * 0.27;
    CGRect rocker = CGRectMake(s2.origin.x, on ? s2.origin.y : CGRectGetMaxY(s2) - rh, s2.size.width, rh);
    CGContextSaveGState(ctx);
    if (on) CGContextSetShadowWithColor(ctx, CGSizeZero, w * 0.25, alpha(hue, 0.7).CGColor);
    [(on ? hue : white(0.55)) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:rocker cornerRadius:w * 0.06] fill];
    CGContextRestoreGState(ctx);
  }

  // The bulb, standing in the right of the box.
  CGFloat bulbH = b.size.height * 0.86;
  CGRect bulb = CGRectMake(b.origin.x + b.size.width * 0.62 - bulbH * 0.3, CGRectGetMaxY(b) - bulbH - b.size.height * 0.02,
                           bulbH * 0.6, bulbH);
  UIImage *img = [UIImage imageNamed:on ? @"bulb_lit" : @"bulb_unlit"];
  [img drawInRect:bulb blendMode:kCGBlendModeNormal alpha:on ? 1 : 0.55];

}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *hue = self.hue;
  BOOL on = self.known && self.on;
  [self setGlow:hue on:on];
  drawCard(self.bounds, hue, on, self.offline, u);
  CGRect box = self.boxRect;
  [self drawBox:box hue:hue on:on];

  // The name, and its state under it.
  NSString *status = self.offline ? @"Offline"
                   : !self.known ? @"Connecting…"
                   : !on ? @"Off"
                   : self.light.dimmable && self.level >= 0 ? [NSString stringWithFormat:@"On · %ld%%", (long)self.level]
                   : @"On";
  UIFont *nameFont = inter(@"SemiBold", u * 0.95), *statusFont = inter(@"Medium", u * 0.7);
  CGFloat x = box.origin.x, tw = box.size.width, ny = CGRectGetMaxY(box) + u * 0.5;
  drawLine(self.light.name, nameFont, NCRGB(kWhite), CGRectMake(x, ny, tw, nameFont.lineHeight));
  drawLine(status, statusFont, self.offline ? NCRGB(kRed) : white(on ? 0.75 : 0.5),
           CGRectMake(x, ny + nameFont.lineHeight, tw, statusFont.lineHeight));

  if (!self.light.dimmable) return;
  // 1 · 25 · 50 · 100 in one pill; the preset nearest the bulb's level lights up.
  CGRect bar = self.barRect;
  drawSurface(bar, u * 1.3);
  NSInteger index = -1;
  if (on && self.level >= 0) {
    NSInteger best = 0;
    for (int i = 1; i < 4; i++)
      if (labs(kPresets[i] - self.level) < labs(kPresets[best] - self.level)) best = i;
    index = best;
  }
  CGRect in = CGRectInset(bar, u * 0.22, u * 0.22);
  CGFloat seg = in.size.width / 4;
  if (index >= 0) {
    [hue setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(in.origin.x + seg * index, in.origin.y, seg, in.size.height)
                                cornerRadius:u * 1.1] fill];
  }
  for (int i = 0; i < 4; i++) {
    UIColor *tc = i == index ? UIColor.blackColor : white(self.busy ? 0.3 : 0.7);
    drawCentered([NSString stringWithFormat:@"%ld%%", (long)kPresets[i]],
                 textAttrs(inter(@"SemiBold", u * 0.75), tc, -u * 0.02),
                 CGPointMake(in.origin.x + seg * (i + 0.5), CGRectGetMidY(in)));
  }
}

- (void)setBusy:(BOOL)busy {
  _busy = busy;
  busy ? [_spinner startAnimating] : [_spinner stopAnimating];
  [self setNeedsDisplay];
}

- (void)refresh {
  if (self.busy || self.dragKelvin) return;
  NCLight *light = self.light;
  dispatch_async(light.queue, ^{
    BOOL on = NO;
    NSInteger level = -1;
    BOOL ok = [light readOn:&on brightness:&level];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.busy) return;
      if (ok) {
        self.known = YES;
        self.on = on;
        self.level = level;
        self.offline = NO;
      } else {
        self.offline = YES;
      }
      [self setNeedsDisplay];
    });
  });
}

/// Sends [action], shows the expected state at once if it went through,
/// then reads the bulb back to confirm.
- (void)run:(BOOL (^)(NCLight *))action expectOn:(BOOL)on level:(NSInteger)level done:(void (^)(void))done {
  self.busy = YES;
  NCLight *light = self.light;
  dispatch_async(light.queue, ^{
    BOOL ok = action(light);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) {
        self.known = YES;
        self.on = on;
        if (level >= 0) self.level = level;
        self.offline = NO;
      } else {
        self.offline = YES;
      }
      self.busy = NO;
      [self refresh];
      if (done) done();
    });
  });
}

/// Press and hold a colour bulb's box for its sheet; nothing else here
/// begins on a hold.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
  if (![g isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
  return self.light.hasKelvin && self.known && CGRectContainsPoint(self.boxRect, [g locationInView:self]);
}

- (void)onHold:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan || !self.window) return;
  NCKelvinSheet *sheet = [[NCKelvinSheet alloc] initWithTile:self];
  [sheet showIn:self.window];
}

- (void)onTap:(UITapGestureRecognizer *)g {
  if (self.busy) return;
  CGPoint p = [g locationInView:self];
  if (CGRectContainsPoint(self.boxRect, p)) {
    if (!self.known) return;
    BOOL to = !self.on;
    [self run:^BOOL(NCLight *l) { return [l setPower:to]; } expectOn:to level:-1 done:nil];
  } else if (self.light.dimmable && CGRectContainsPoint(self.barRect, p)) {
    CGRect bar = self.barRect;
    int i = MAX(0, MIN(3, (int)((p.x - bar.origin.x) / (bar.size.width / 4))));
    NSInteger pct = kPresets[i];
    [self run:^BOOL(NCLight *l) { return [l setBrightness:pct]; } expectOn:YES level:pct done:nil];
  }
}

@end

// ── Colour-temperature sheet ─────────────────────────────────────────────

@implementation NCKelvinSheet {
  __weak NCLightTile *_tile;
  NSInteger _kelvin;
  CFTimeInterval _sent;
  BOOL _failed;
}

- (instancetype)initWithTile:(NCLightTile *)tile {
  if ((self = [super initWithFrame:CGRectZero])) {
    _tile = tile;
    _kelvin = tile.light.kelvin > 0 ? tile.light.kelvin : 4000;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
  }
  return self;
}

- (CGFloat)unit { return _tile.unit; }
- (BOOL)on { return _tile.known && _tile.on; }

- (void)showIn:(UIView *)host {
  self.frame = host.bounds;
  self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.alpha = 0;
  [host addSubview:self];
  [UIView animateWithDuration:0.2 animations:^{ self.alpha = 1; }];
}

- (void)close {
  [UIView animateWithDuration:0.2 animations:^{ self.alpha = 0; } completion:^(BOOL done) {
    [self removeFromSuperview];
    self->_tile.dragKelvin = 0;
    [self->_tile refresh];
  }];
}

- (CGRect)card {
  CGFloat u = self.unit, w = MIN(self.bounds.size.width - 32, u * 34);
  CGFloat h = u * (1.4 * 2 + 2.8 + 1.6 + 3.8 + 0.6 + 1.2 + (_tile.light.dimmable ? 1.4 + 2.8 : 0));
  return CGRectMake((self.bounds.size.width - w) / 2, self.bounds.size.height - h - u * 1.2, w, h);
}
- (CGRect)inner { return CGRectInset(self.card, self.unit * 1.4, self.unit * 1.4); }
- (CGRect)track {
  CGFloat u = self.unit;
  CGRect in = self.inner;
  CGFloat knob = u * 3.8, th = u * 3.2;
  return CGRectMake(in.origin.x, in.origin.y + u * 2.8 + u * 1.6 + (knob - th) / 2, in.size.width, th);
}
- (CGRect)presetRow {
  CGFloat u = self.unit;
  CGRect in = self.inner;
  return CGRectMake(in.origin.x, CGRectGetMaxY(in) - u * 2.8, in.size.width, u * 2.8);
}

static UIColor *opaqueHue(UIColor *c, BOOL night) {
  CGFloat r, g, b, a;
  [c getRed:&r green:&g blue:&b alpha:&a];
  return NCHue(0xFF000000 | ((uint32_t)lround(r * 255) << 16) | ((uint32_t)lround(g * 255) << 8) | (uint32_t)lround(b * 255), night);
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  BOOL night = _tile.night, on = self.on;
  [[UIColor colorWithWhite:0 alpha:0.45] setFill];
  UIRectFill(self.bounds);

  UIColor *hue = opaqueHue(kelvinColor(_kelvin), night);
  CGRect card = self.card;
  UIBezierPath *cp = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:u * 1.8];
  CGContextSaveGState(ctx);
  [cp addClip];
  fillGradient(ctx, @[blend(alpha(hue, on ? 0.22 : 0.08), NCRGB(0xF21A1C22)), NCRGB(0xF5121318)], NULL, card.origin,
               CGPointMake(CGRectGetMaxX(card), CGRectGetMaxY(card)));
  CGContextRestoreGState(ctx);
  [white(0.12) setStroke];
  [cp stroke];

  // Header: a glowing bulb, the name, the kelvin.
  CGRect in = self.inner;
  CGRect bulb = CGRectMake(in.origin.x, in.origin.y, u * 2.8, u * 2.8);
  CGContextSaveGState(ctx);
  if (on) CGContextSetShadowWithColor(ctx, CGSizeZero, u * 1.2, alpha(hue, 0.6).CGColor);
  [alpha(hue, on ? 0.9 : 0.15) setFill];
  [[UIBezierPath bezierPathWithOvalInRect:bulb] fill];
  CGContextRestoreGState(ctx);
  drawIcon(@"bulb", CGPointMake(CGRectGetMidX(bulb), CGRectGetMidY(bulb)), u * 1.5,
           on ? [UIColor colorWithWhite:0 alpha:0.75] : hue);
  NSDictionary *ka = textAttrs(inter(@"Light", u * 1.5), hue, 0);
  NSString *kt = [NSString stringWithFormat:@"%ld K", (long)_kelvin];
  CGSize ks = [kt sizeWithAttributes:ka];
  [kt drawAtPoint:CGPointMake(CGRectGetMaxX(in) - ks.width, CGRectGetMidY(bulb) - ks.height / 2) withAttributes:ka];
  CGFloat tx = CGRectGetMaxX(bulb) + u * 0.9, tw = CGRectGetMaxX(in) - ks.width - u * 0.5 - tx;
  UIFont *nf = inter(@"SemiBold", u * 1.15), *sf = inter(@"Medium", u * 0.75);
  CGFloat ty = CGRectGetMidY(bulb) - (nf.lineHeight + sf.lineHeight) / 2;
  drawLine(_tile.light.name, nf, NCRGB(kWhite), CGRectMake(tx, ty, tw, nf.lineHeight));
  drawLine(_failed ? @"Not answering" : on ? @"Colour temperature" : @"Off — the colour applies when it turns on",
           sf, _failed ? NCRGB(kRed) : white(0.55), CGRectMake(tx, ty + nf.lineHeight, tw, sf.lineHeight));

  // The slider: a glass rod from candle to daylight, a big knob in the colour.
  CGRect tr = self.track;
  UIBezierPath *rod = [UIBezierPath bezierPathWithRoundedRect:tr cornerRadius:tr.size.height / 2];
  CGContextSaveGState(ctx);
  CGContextSetShadowWithColor(ctx, CGSizeMake(0, u * 0.1), u * 0.4, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
  [UIColor.blackColor setFill];
  [rod fill];
  CGContextRestoreGState(ctx);
  CGContextSaveGState(ctx);
  [rod addClip];
  NSMutableArray *cols = [NSMutableArray array];
  for (NSNumber *k in @[@1700, @2400, @3200, @4200, @5200, @6500])
    [cols addObject:opaqueHue(kelvinColor(k.integerValue), night)];
  fillGradient(ctx, cols, NULL, tr.origin, CGPointMake(CGRectGetMaxX(tr), tr.origin.y));
  CGFloat hs[] = {0, 0.5, 1};
  fillGradient(ctx, @[[UIColor colorWithWhite:1 alpha:0.28], [UIColor colorWithWhite:1 alpha:0], [UIColor colorWithWhite:0 alpha:0.12]],
               hs, tr.origin, CGPointMake(tr.origin.x, CGRectGetMaxY(tr)));
  CGContextRestoreGState(ctx);
  CGFloat knob = u * 3.8;
  CGFloat t = MAX(0, MIN(1, (_kelvin - NCMinKelvin) / (CGFloat)(NCMaxKelvin - NCMinKelvin)));
  CGRect kr = CGRectMake(tr.origin.x + t * (tr.size.width - knob), CGRectGetMidY(tr) - knob / 2, knob, knob);
  UIBezierPath *kp = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(kr, u * 0.14, u * 0.14)];
  CGContextSaveGState(ctx);
  CGContextSetShadowWithColor(ctx, CGSizeMake(0, u * 0.15), u * 0.7, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
  [hue setFill];
  [kp fill];
  CGContextRestoreGState(ctx);
  kp.lineWidth = u * 0.28;
  [UIColor.whiteColor setStroke];
  [kp stroke];

  // Candle … Daylight
  CGFloat ly = CGRectGetMidY(tr) + knob / 2 + u * 0.6;
  NSDictionary *la = textAttrs(inter(@"Medium", u * 0.75), white(0.55), 0);
  drawIcon(@"flame", CGPointMake(in.origin.x + u * 0.45, ly + u * 0.5), u * 0.9, opaqueHue(kelvinColor(1700), night));
  [@"Candle" drawAtPoint:CGPointMake(in.origin.x + u * 1.2, ly) withAttributes:la];
  CGSize ds = [@"Daylight" sizeWithAttributes:la];
  drawIcon(@"sunny", CGPointMake(CGRectGetMaxX(in) - u * 0.45, ly + u * 0.5), u * 0.9, opaqueHue(kelvinColor(6500), night));
  [@"Daylight" drawAtPoint:CGPointMake(CGRectGetMaxX(in) - u * 1.2 - ds.width, ly) withAttributes:la];

  if (!_tile.light.dimmable) return;
  CGRect row = self.presetRow;
  CGFloat gap = u * 0.6, w = (row.size.width - gap * 3) / 4;
  NSInteger index = -1;
  if (on && _tile.level >= 0) {
    NSInteger best = 0;
    for (int i = 1; i < 4; i++)
      if (labs(kPresets[i] - _tile.level) < labs(kPresets[best] - _tile.level)) best = i;
    index = best;
  }
  for (int i = 0; i < 4; i++) {
    CGRect b = CGRectMake(row.origin.x + i * (w + gap), row.origin.y, w, row.size.height);
    UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:u * 1.4];
    [(i == index ? hue : white(0.06)) setFill];
    [bp fill];
    [white(0.10) setStroke];
    [bp stroke];
    drawCentered([NSString stringWithFormat:@"%ld%%", (long)kPresets[i]],
                 textAttrs(inter(@"SemiBold", u * 0.85), i == index ? UIColor.blackColor : white(0.75), 0),
                 CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)));
  }
}

- (void)setKelvinAt:(CGFloat)x {
  CGRect tr = self.track;
  CGFloat t = MAX(0, MIN(1, (x - tr.origin.x) / tr.size.width));
  NSInteger k = lround(NCMinKelvin + t * (NCMaxKelvin - NCMinKelvin));
  _kelvin = lround(k / 50.0) * 50;
  _tile.dragKelvin = _kelvin;
  [self setNeedsDisplay];
  [_tile setNeedsDisplay];
}

/// Sends the kelvin — at most every 0.4 s while dragging, always at the end.
- (void)send:(BOOL)force {
  CFTimeInterval now = CACurrentMediaTime();
  if (!force && now - _sent < 0.4) return;
  _sent = now;
  NSInteger k = _kelvin;
  NCLight *light = _tile.light;
  dispatch_async(light.queue, ^{
    BOOL ok = [light setKelvin:k];
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_failed = !ok;
      [self setNeedsDisplay];
      [self->_tile setNeedsDisplay];
    });
  });
}

- (void)onPan:(UIPanGestureRecognizer *)g {
  [self setKelvinAt:[g locationInView:self].x];
  if (g.state == UIGestureRecognizerStateEnded) [self send:YES];
  else [self send:NO];
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  CGFloat u = self.unit;
  if (!CGRectContainsPoint(self.card, p)) { [self close]; return; }
  if (CGRectContainsPoint(CGRectInset(self.track, 0, -u * 0.6), p)) {
    [self setKelvinAt:p.x];
    [self send:YES];
  } else if (_tile.light.dimmable && CGRectContainsPoint(self.presetRow, p) && !_tile.busy) {
    CGRect row = self.presetRow;
    int i = MAX(0, MIN(3, (int)((p.x - row.origin.x) / (row.size.width / 4))));
    NSInteger pct = kPresets[i];
    [_tile run:^BOOL(NCLight *l) { return [l setBrightness:pct]; } expectOn:YES level:pct done:^{
      [self setNeedsDisplay];
    }];
    [self setNeedsDisplay];
  }
}

@end

// ── AC tile ──────────────────────────────────────────────────────────────

/// Name and mode top-left, power top-right, the setpoint dial in the
/// middle (press and hold, then slide), − / room temp / + along the foot.
@interface NCAcTile : NCTile <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NCGreeAc *ac;
@property (nonatomic, strong) NCAcState *state;
@property (nonatomic) BOOL offline, busy;
@property (nonatomic) NSInteger pending;  // setpoint being dialled in, or 0
/// The only AC in its room: one card across the panel — name, mode and
/// room temperature left, the dial in the middle, power and − / + right.
@property (nonatomic) BOOL wide;
- (CGRect)dialRect;
@end

@implementation NCAcTile {
  NSTimer *_send;
  NSInteger _dialFrom;
  CGFloat _dialY;
  UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithAc:(NCGreeAc *)ac {
  if ((self = [super initWithFrame:CGRectZero])) {
    _ac = ac;
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onDial:)];
    press.minimumPressDuration = 0.3;
    press.delegate = self;
    [self addGestureRecognizer:press];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];
  }
  return self;
}

- (void)setOffline:(BOOL)offline {
  BOOL changed = offline != _offline;
  _offline = offline;
  if (changed) [self.panel statusChanged];
}

- (NSInteger)mode { return self.state ? MAX(0, MIN(4, self.state.mode)) : 1; }
- (UIColor *)hue { return NCHue(kAcModeHues[self.mode], self.night); }
- (BOOL)isOn { return self.state.on; }
- (NSInteger)temp { return self.pending ?: (self.state ? self.state.setTemp : 24); }
- (CGFloat)pad { return self.unit * 1.1; }

- (CGRect)powerRect {
  CGFloat u = self.unit, s = u * 3.2;
  return CGRectMake(self.bounds.size.width - self.pad - s, self.pad, s, s);
}
- (CGRect)minusRect {
  CGFloat s = self.unit * 2.6;
  if (self.wide) {
    CGRect p = self.plusRect;
    return CGRectMake(p.origin.x - self.unit * 0.6 - s, p.origin.y, s, s);
  }
  return CGRectMake(self.pad, self.bounds.size.height - self.pad - s, s, s);
}
- (CGRect)plusRect {
  CGFloat s = self.unit * 2.6;
  return CGRectMake(self.bounds.size.width - self.pad - s, self.bounds.size.height - self.pad - s, s, s);
}
- (CGRect)dialRect {
  CGFloat u = self.unit, w = self.bounds.size.width, h = self.bounds.size.height, pad = self.pad;
  if (self.wide) {
    CGFloat size = (h - 2 * pad) / 0.86;
    return CGRectMake((w - size) / 2, pad, size, size * 0.86);
  }
  CGFloat size = MIN(w - 2 * pad, (h - 2 * pad - u * 3.2 - u * 2.6 - u * 0.8) / 0.86);
  CGFloat top = pad + u * 3.2, bottom = h - pad - u * 2.6;
  return CGRectMake((w - size) / 2, top + (bottom - top - size * 0.86) / 2, size, size * 0.86);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect p = self.powerRect;
  _spinner.center = CGPointMake(CGRectGetMidX(p), CGRectGetMidY(p));
}

/// The colour at [f] (0–1) along [colors].
static UIColor *colorAt(NSArray<UIColor *> *colors, CGFloat f) {
  CGFloat x = MAX(0, MIN(1, f)) * (colors.count - 1);
  NSInteger i = MIN((NSInteger)floor(x), (NSInteger)colors.count - 2);
  return lerp(colors[i], colors[i + 1], x - i);
}

- (void)drawDial:(CGRect)box value:(CGFloat)value colors:(NSArray<UIColor *> *)colors unit:(CGFloat)unit {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGPoint c = CGPointMake(CGRectGetMidX(box), box.origin.y + box.size.width / 2);
  CGFloat r = box.size.width / 2 - unit * 0.8;
  CGFloat start = 3 * M_PI / 4, sweep = 3 * M_PI / 2;
  UIBezierPath *track = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:start endAngle:start + sweep clockwise:YES];
  track.lineWidth = unit * 0.3;
  track.lineCapStyle = kCGLineCapRound;
  [white(0.10) setStroke];
  [track stroke];
  // The set part, shaded cold to hot in short steps (no sweep gradients on iOS 10).
  int steps = MAX(1, (int)(value * 90));
  for (int i = 0; i < steps; i++) {
    CGFloat f0 = value * i / steps, f1 = value * (i + 1) / steps;
    UIBezierPath *seg = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:start + sweep * f0
                                                     endAngle:start + sweep * f1 + 0.01 clockwise:YES];
    seg.lineWidth = unit * 0.3;
    seg.lineCapStyle = (i == 0 || i == steps - 1) ? kCGLineCapRound : kCGLineCapButt;
    [colorAt(colors, (f0 + f1) / 2) setStroke];
    [seg stroke];
  }
  for (int i = 0; i <= 36; i++) {
    CGFloat f = i / 36.0, a = start + sweep * f;
    CGPoint dir = CGPointMake(cos(a), sin(a));
    UIBezierPath *t = [UIBezierPath bezierPath];
    CGFloat r0 = r - unit * 1.2, r1 = r - unit * (i % 3 == 0 ? 2.1 : 1.7);
    [t moveToPoint:CGPointMake(c.x + dir.x * r0, c.y + dir.y * r0)];
    [t addLineToPoint:CGPointMake(c.x + dir.x * r1, c.y + dir.y * r1)];
    t.lineWidth = unit * 0.16;
    t.lineCapStyle = kCGLineCapRound;
    [(f <= value + 1e-6 ? alpha(colorAt(colors, f), 0.85) : white(0.12)) setStroke];
    [t stroke];
  }
  UIColor *knob = colorAt(colors, value);
  CGFloat ka = start + sweep * value;
  CGPoint k = CGPointMake(c.x + cos(ka) * r, c.y + sin(ka) * r);
  CGContextSaveGState(ctx);
  CGContextSetShadowWithColor(ctx, CGSizeZero, unit * 1.2, alpha(knob, 0.6).CGColor);
  [knob setFill];
  [[UIBezierPath bezierPathWithArcCenter:k radius:unit * 0.6 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
  CGContextRestoreGState(ctx);
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  BOOL on = self.isOn;
  UIColor *hue = self.hue;
  [self setGlow:hue on:on];
  drawCard(self.bounds, hue, on, self.offline, u);
  CGFloat pad = self.pad;

  // Name and the badge: the mode while on, otherwise why there isn't one.
  [self.ac.name drawAtPoint:CGPointMake(pad, pad - u * 0.15)
             withAttributes:textAttrs(inter(@"SemiBold", u * 1.05), white(on ? 0.95 : 0.7), 0)];
  NSString *badge;
  UIColor *bc;
  NSString *icon = nil;
  if (self.offline) { badge = @"Offline"; bc = NCRGB(kRed); icon = @"wifioff"; }
  else if (!self.state) { badge = @"Connecting…"; bc = white(0.5); }
  else if (!on) { badge = @"Off"; bc = white(0.5); }
  else { badge = kAcModeNames[self.mode]; bc = hue; icon = [NSString stringWithFormat:@"mode%ld", (long)self.mode]; }
  NSDictionary *ba = textAttrs(inter(@"SemiBold", u * 0.7), bc, 0);
  CGSize bs = [badge sizeWithAttributes:ba];
  CGFloat bw = u * 1.0 + (icon ? u * 1.05 : 0) + bs.width, bh = u * 0.3 + MAX(bs.height, u * 0.8);
  CGRect br = CGRectMake(pad, pad + u * 1.6, bw, bh);
  [alpha(bc, 0.14) setFill];
  [[UIBezierPath bezierPathWithRoundedRect:br cornerRadius:u] fill];
  CGFloat bx = br.origin.x + u * 0.5;
  if (icon) {
    drawIcon(icon, CGPointMake(bx + u * 0.4, CGRectGetMidY(br)), u * 0.8, bc);
    bx += u * 1.05;
  }
  [badge drawAtPoint:CGPointMake(bx, CGRectGetMidY(br) - bs.height / 2) withAttributes:ba];

  // Power: a circle in the mode's colour while on.
  CGRect pr = self.powerRect;
  UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:pr];
  CGContextSaveGState(ctx);
  if (on) CGContextSetShadowWithColor(ctx, CGSizeZero, u, alpha(hue, 0.45).CGColor);
  [(on ? hue : alpha(hue, 0.06)) setFill];
  [circle fill];
  CGContextRestoreGState(ctx);
  [alpha(hue, on ? 1 : 0.25) setStroke];
  circle.lineWidth = 1;
  [circle stroke];
  _spinner.color = on ? UIColor.blackColor : NCRGB(kWhite);
  if (!self.busy)
    drawIcon(@"power", CGPointMake(CGRectGetMidX(pr), CGRectGetMidY(pr)), u * 1.6, on ? UIColor.blackColor : alpha(hue, 0.6));

  // The dial, cold to hot along the arc.
  NSInteger temp = self.temp;
  NSMutableArray *colors = [NSMutableArray array];
  for (int i = 0; i < 4; i++) [colors addObject:on ? NCHue(kDialStops[i], self.night) : white(0.3)];
  CGRect dial = self.dialRect;
  [self drawDial:dial value:(temp - NCAcMinTemp) / (CGFloat)(NCAcMaxTemp - NCAcMinTemp) colors:colors unit:u * 0.5];
  drawCentered([NSString stringWithFormat:@"%ld°", (long)temp],
               textAttrs(inter(@"Light", u * 2.4), white(on ? 1 : 0.5), -u * 0.05),
               CGPointMake(CGRectGetMidX(dial), dial.origin.y + dial.size.width / 2));

  // − / room temperature / +
  for (int i = 0; i < 2; i++) {
    CGRect b = i == 0 ? self.minusRect : self.plusRect;
    UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:b];
    [white(0.06) setFill];
    [p fill];
    [white(0.10) setStroke];
    p.lineWidth = 1;
    [p stroke];
    drawIcon(i == 0 ? @"minus" : @"plus", CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)), u * 1.3, white(0.85));
  }
  if (self.state && self.state.roomTemp != NSNotFound) {
    NSString *room = [NSString stringWithFormat:self.wide ? @"Room %ld°" : @"%ld°", (long)self.state.roomTemp];
    NSDictionary *ra = textAttrs(inter(@"Medium", u * 0.8), white(0.6), 0);
    CGSize rs = [room sizeWithAttributes:ra];
    CGFloat total = u * 0.9 + rs.width, cy = CGRectGetMidY(self.minusRect);
    CGFloat x = self.wide ? pad : self.bounds.size.width / 2 - total / 2;
    drawIcon(@"thermostat", CGPointMake(x + u * 0.45, cy), u * 0.9, white(0.5));
    [room drawAtPoint:CGPointMake(x + u * 0.9, cy - rs.height / 2) withAttributes:ra];
  }
}

- (void)setBusy:(BOOL)busy {
  _busy = busy;
  busy ? [_spinner startAnimating] : [_spinner stopAnimating];
  [self setNeedsDisplay];
}

- (void)refresh {
  NCGreeAc *ac = self.ac;
  dispatch_async(ac.queue, ^{
    NCAcState *s = [ac state];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (s) {
        self.state = s;
        self.offline = NO;
      } else {
        self.offline = YES;
      }
      [self setNeedsDisplay];
    });
  });
}

- (void)togglePower {
  if (self.busy || !self.state) return;
  BOOL to = !self.state.on;
  self.busy = YES;
  NCGreeAc *ac = self.ac;
  dispatch_async(ac.queue, ^{
    BOOL ok = [ac setPower:to];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) self.state.on = to;
      self.offline = !ok;
      self.busy = NO;
      [self refresh];
    });
  });
}

/// Moves the dial now and tells the unit 0.7 s after the last change, so
/// a slide or a run of taps is one command.
- (void)dial:(NSInteger)temp {
  NSInteger t = MAX(NCAcMinTemp, MIN(NCAcMaxTemp, temp));
  if (t == self.temp) return;
  self.pending = t;
  [self setNeedsDisplay];
  [_send invalidate];
  _send = [NSTimer scheduledTimerWithTimeInterval:0.7 target:self selector:@selector(sendPending) userInfo:nil repeats:NO];
}

- (void)sendPending {
  NSInteger t = self.pending;
  if (!t) return;
  NCGreeAc *ac = self.ac;
  dispatch_async(ac.queue, ^{
    BOOL ok = [ac setTemp:t];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) self.state.setTemp = t;
      self.offline = !ok;
      if (self.pending == t) self.pending = 0;
      [self refresh];
    });
  });
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  CGFloat slop = self.unit * 0.6;
  if (CGRectContainsPoint(CGRectInset(self.powerRect, -slop, -slop), p)) [self togglePower];
  else if (CGRectContainsPoint(CGRectInset(self.minusRect, -slop, -slop), p)) [self dial:self.temp - 1];
  else if (CGRectContainsPoint(CGRectInset(self.plusRect, -slop, -slop), p)) [self dial:self.temp + 1];
}

/// UIView asks this for *every* recognizer on the tile, the tap included —
/// so only the dial's press-and-hold is limited to the dial. (Limiting all
/// of them left power and − / + dead on the iPad.)
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
  if (![g isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
  return CGRectContainsPoint(self.dialRect, [g locationInView:self]);
}

/// Press and hold, then slide up for warmer, down for cooler.
- (void)onDial:(UILongPressGestureRecognizer *)g {
  CGFloat y = [g locationInView:self].y;
  if (g.state == UIGestureRecognizerStateBegan) {
    _dialFrom = self.temp;
    _dialY = y;
  } else if (g.state == UIGestureRecognizerStateChanged) {
    [self dial:lround(_dialFrom - (y - _dialY) / (self.unit * 1.4))];
  }
}

@end

// ── TV card ──────────────────────────────────────────────────────────────

/// The set-top box's big power button, the TV's small square power button,
/// then the volume pill (volume goes to the TV, live only while it's on).
@interface NCTvCard : NCTile
@property (nonatomic, strong) NCHisenseTv *tv;
@property (nonatomic, strong) NCTvBox *box;
@end

@implementation NCTvCard {
  BOOL _tvKnown, _tvOn, _boxKnown, _boxOn;
  NSString *_boxProblem;
  NSDate *_tvSwitched, *_boxSwitched;
}

- (CGFloat)pad { return self.unit * 1.1; }
- (CGFloat)side { return self.unit * 5; }
/// Volume, at the right: to the Hisense when there is one, else to the
/// Android TV over ADB.
- (CGRect)volumeRect {
  CGFloat u = self.unit;
  return CGRectMake(self.bounds.size.width - self.pad - u * 9, self.pad, u * 9, self.side);
}
/// The Hisense: a small square beside a box, the wide button on its own.
- (CGRect)tvRect {
  if (!self.tv) return CGRectZero;
  CGFloat vx = self.volumeRect.origin.x - self.unit * 0.6;
  if (!self.box) return CGRectMake(self.pad, self.pad, vx - self.pad, self.side);
  return CGRectMake(vx - self.side, self.pad, self.side, self.side);
}
- (CGRect)boxRect {
  if (!self.box) return CGRectZero;
  CGFloat right = self.tv ? self.tvRect.origin.x - self.unit * 0.6 : self.volumeRect.origin.x - self.unit * 0.6;
  return CGRectMake(self.pad, self.pad, right - self.pad, self.side);
}
- (BOOL)volumeLive { return self.tv ? _tvKnown && _tvOn : _boxKnown && _boxOn; }

static void drawButton(CGRect r, UIColor *color, BOOL on, CGFloat u);

/// A wide power button: the power icon with the name and a state line, as
/// one group centred in it; the text shrinks only if it wouldn't fit.
static void drawWide(CGRect r, NSString *name, NSString *status, UIColor *color, BOOL on, UIColor *fg,
                     BOOL problem, CGFloat u) {
  drawButton(r, color, on, u);
  UIColor *sc = problem ? NCRGB(kRed) : on ? [UIColor colorWithWhite:0 alpha:0.65] : white(0.45);
  CGFloat icon = u * 2.1, gap = u * 0.6, room = r.size.width - u * 1.6 - icon - gap;
  NSDictionary *na = textAttrs(inter(@"SemiBold", u * 1.05), fg, 0);
  NSDictionary *sa = textAttrs(inter(@"Medium", u * 0.78), sc, 0);
  CGFloat textW = MAX([name sizeWithAttributes:na].width, [status sizeWithAttributes:sa].width);
  if (textW > room) {
    CGFloat k = room / textW;
    na = textAttrs(inter(@"SemiBold", u * 1.05 * k), fg, 0);
    sa = textAttrs(inter(@"Medium", u * 0.78 * k), sc, 0);
    textW = room;
  }
  CGSize ns = [name sizeWithAttributes:na], ss = [status sizeWithAttributes:sa];
  CGFloat gx = CGRectGetMidX(r) - (icon + gap + textW) / 2;
  drawIcon(@"power", CGPointMake(gx + icon / 2, CGRectGetMidY(r)), icon, fg);
  CGFloat tx = gx + icon + gap, ty = CGRectGetMidY(r) - (ns.height + ss.height) / 2;
  [name drawAtPoint:CGPointMake(tx, ty) withAttributes:na];
  [status drawAtPoint:CGPointMake(tx, ty + ns.height) withAttributes:sa];
}

/// A power button in [color]: filled while on, a tinted outline off.
static void drawButton(CGRect r, UIColor *color, BOOL on, CGFloat u) {
  UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:u * 1.25];
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  if (on) {
    CGContextSaveGState(ctx);
    [p addClip];
    fillGradient(ctx, @[alpha(color, 0.8), color], NULL, r.origin, CGPointMake(CGRectGetMaxX(r), r.origin.y));
    CGContextRestoreGState(ctx);
  } else {
    [alpha(color, 0.06) setFill];
    [p fill];
  }
  [alpha(color, on ? 0.8 : 0.18) setStroke];
  p.lineWidth = 1;
  [p stroke];
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *hue = NCHue(kTvViolet, self.night), *boxHue = NCHue(kBoxBlue, self.night);
  BOOL tvOn = _tvKnown && _tvOn, boxOn = _boxKnown && _boxOn;
  UIColor *cardHue = boxOn || !tvOn ? boxHue : hue;
  [self setGlow:cardHue on:tvOn || boxOn];
  drawCard(self.bounds, cardHue, tvOn || boxOn, NO, u);

  if (self.box) {
    UIColor *fg = boxOn ? UIColor.blackColor : alpha(boxHue, _boxKnown ? 0.65 : 0.3);
    NSString *status = _boxProblem ?: (!_boxKnown ? @"Connecting…" : boxOn ? @"On" : @"Off");
    drawWide(self.boxRect, self.box.name, status, boxHue, boxOn, fg, _boxProblem != nil, u);
  }
  if (self.tv && !self.box) {
    UIColor *fg = tvOn ? UIColor.blackColor : alpha(hue, _tvKnown ? 0.65 : 0.25);
    NSString *status = !_tvKnown ? @"Connecting…" : tvOn ? @"On" : @"Off";
    drawWide(self.tvRect, self.tv.name, status, hue, tvOn, fg, NO, u);
  } else if (self.tv) {
    CGRect r = self.tvRect;
    drawButton(r, hue, tvOn, u);
    UIColor *fg = tvOn ? UIColor.blackColor : alpha(hue, _tvKnown ? 0.65 : 0.25);
    drawIcon(@"tv", CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r) - u * 0.7), u * 1.7, fg);
    drawIcon(@"power", CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r) + u * 0.85), u * 1.2, fg);
  }
  BOOL live = self.volumeLive;
  CGRect v = self.volumeRect;
  drawSurface(v, u * 1.25);
  CGFloat third = v.size.width / 3, cy = CGRectGetMidY(v);
  drawIcon(@"minus", CGPointMake(v.origin.x + third * 0.5, cy), u * 1.8, white(live ? 0.85 : 0.25));
  drawIcon(@"volume", CGPointMake(v.origin.x + third * 1.5, cy), u * 1.2,
           alpha(self.tv ? hue : boxHue, live ? 0.8 : 0.25));
  drawIcon(@"plus", CGPointMake(v.origin.x + third * 2.5, cy), u * 1.8, white(live ? 0.85 : 0.25));
}

- (void)refresh {
  NCHisenseTv *tv = self.tv;
  // The TV's broker takes a few seconds to go down or come up: polls just
  // after a tap would undo it.
  if (tv && !(_tvSwitched && -_tvSwitched.timeIntervalSinceNow < 20)) {
    dispatch_async(tv.queue, ^{
      BOOL on = [tv isOn];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_tvSwitched && -self->_tvSwitched.timeIntervalSinceNow < 20) return;
        self->_tvKnown = YES;
        self->_tvOn = on;
        [self setNeedsDisplay];
      });
    });
  }
  NCTvBox *box = self.box;
  if (box && !(_boxSwitched && -_boxSwitched.timeIntervalSinceNow < 6)) {
    dispatch_async(box.queue, ^{
      BOOL on = NO;
      NCBoxResult r = [box readOn:&on];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (r == NCBoxOk) {
          self->_boxKnown = YES;
          self->_boxOn = on;
          self->_boxProblem = nil;
        } else {
          self->_boxProblem = r == NCBoxNeedsApproval ? @"Allow on TV" : @"Offline";
        }
        [self setNeedsDisplay];
      });
    });
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  if (self.box && CGRectContainsPoint(self.boxRect, p) && _boxKnown) {
    BOOL to = !_boxOn;
    _boxOn = to;
    _boxSwitched = [NSDate date];
    [self setNeedsDisplay];
    NCTvBox *box = self.box;
    dispatch_async(box.queue, ^{
      NCBoxResult r = [box setPower:to];
      if (r != NCBoxOk) dispatch_async(dispatch_get_main_queue(), ^{
        self->_boxSwitched = nil;
        if (to && !box.canWake) {
          // Asleep and off the network: only its remote wakes it.
          self->_boxOn = NO;
          self->_boxProblem = @"Use the remote to turn on";
          [self setNeedsDisplay];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if ([self->_boxProblem isEqualToString:@"Use the remote to turn on"]) {
              self->_boxProblem = nil;
              [self setNeedsDisplay];
            }
          });
          return;
        }
        [self refresh];
      });
    });
  } else if (self.tv && CGRectContainsPoint(self.tvRect, p) && _tvKnown) {
    BOOL to = !_tvOn;
    _tvOn = to;
    _tvSwitched = [NSDate date];
    [self setNeedsDisplay];
    NCHisenseTv *tv = self.tv;
    dispatch_async(tv.queue, ^{
      if (![tv setPower:to]) dispatch_async(dispatch_get_main_queue(), ^{
        self->_tvSwitched = nil;
        [self refresh];
      });
    });
  } else if (CGRectContainsPoint(self.volumeRect, p) && self.volumeLive) {
    CGRect v = self.volumeRect;
    CGFloat x = p.x - v.origin.x;
    BOOL down = x < v.size.width / 3, up = x > v.size.width * 2 / 3;
    if (!down && !up) return;
    if (self.tv) {
      NCHisenseTv *tv = self.tv;
      NSString *key = down ? @"KEY_VOLUMEDOWN" : @"KEY_VOLUMEUP";
      dispatch_async(tv.queue, ^{ [tv sendKey:key]; });
    } else {
      NCTvBox *box = self.box;
      NSString *key = down ? @"KEYCODE_VOLUME_DOWN" : @"KEYCODE_VOLUME_UP";
      dispatch_async(box.queue, ^{ [box sendKey:key]; });
    }
  }
}

@end

// ── Panel ────────────────────────────────────────────────────────────────

/// The GN / GM scene pills and the header text.
@interface NCHeader : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic) NSString *running;  // @"gn", @"gm" or nil
@property (nonatomic, copy) void (^onScene)(BOOL goodNight);
@property (nonatomic, copy) NSString *title, *subtitle;
@property (nonatomic) BOOL showScenes;
/// The house icon: back to the home page (nil: not a button).
@property (nonatomic, copy) void (^onHome)(void);
@end

@implementation NCHeader

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}

- (CGFloat)pillWidth:(NSString *)label {
  CGFloat u = self.unit;
  return u * 0.9 * 2 + u * 1.2 + u * 0.4 +
         [label sizeWithAttributes:textAttrs(inter(@"SemiBold", u * 0.8), UIColor.whiteColor, u * 0.04)].width;
}
- (CGRect)gmRect {
  CGFloat w = [self pillWidth:@"GM"];
  return CGRectMake(self.bounds.size.width - w - 2, self.unit * 0.1, w, self.unit * 2.6);
}
- (CGRect)gnRect {
  CGFloat w = [self pillWidth:@"GN"];
  return CGRectMake(self.gmRect.origin.x - self.unit * 0.5 - w, self.unit * 0.1, w, self.unit * 2.6);
}

/// The home icon in its own tile, ROOM DASHBOARD with the room under it,
/// then the scenes: GN deep navy with a lavender moon, GM a glowing amber
/// sunrise. From the user's mock-up.
- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  UIColor *amber = NCHue(kWarm, self.night);
  CGRect home = CGRectMake(0.5, 0.5, u * 2.8 - 1, u * 2.8 - 1);
  UIBezierPath *hp = [UIBezierPath bezierPathWithRoundedRect:home cornerRadius:u * 0.8];
  [white(0.07) setFill];
  [hp fill];
  [white(0.10) setStroke];
  [hp stroke];
  drawIcon(@"home", CGPointMake(CGRectGetMidX(home), CGRectGetMidY(home)), u * 1.4, amber);

  UIFont *tf = inter(@"SemiBold", u * 0.8), *sf = inter(@"Medium", u * 0.7);
  CGFloat tx = u * 3.5, ty = u * 1.4 - (tf.lineHeight + sf.lineHeight) / 2;
  CGContextSaveGState(ctx);
  CGContextSetShadowWithColor(ctx, CGSizeZero, u * 0.6, [UIColor colorWithWhite:0 alpha:0.8].CGColor);
  if (!self.subtitle.length) ty = u * 1.4 - tf.lineHeight / 2;
  CGFloat textW = (self.showScenes ? self.gnRect.origin.x - u * 0.5 : self.bounds.size.width) - tx;
  NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  NSMutableDictionary *ta = [textAttrs(tf, white(self.night ? 0.55 : 0.8), u * 0.2) mutableCopy];
  ta[NSParagraphStyleAttributeName] = ps;
  [(self.title ?: @"ROOM DASHBOARD").uppercaseString drawInRect:CGRectMake(tx, ty, textW, tf.lineHeight) withAttributes:ta];
  if (self.subtitle.length)
    drawLine(self.subtitle, sf, white(self.night ? 0.4 : 0.7), CGRectMake(tx, ty + tf.lineHeight, textW, sf.lineHeight));
  CGContextRestoreGState(ctx);
  if (!self.showScenes) return;

  CGFloat fade = self.running ? 0.4 : 1;
  for (int i = 0; i < 2; i++) {
    BOOL gn = i == 0;
    CGRect r = gn ? self.gnRect : self.gmRect;
    UIBezierPath *pp = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:u * 1.3];
    UIColor *fg;
    if (gn) {
      [alpha(NCRGB(0xE60D1030), 0.9 * fade) setFill];
      [pp fill];
      [alpha(NCRGB(0x664A4A9A), fade) setStroke];
      fg = alpha(NCRGB(0xFFB9B4FF), fade);
    } else {
      CGContextSaveGState(ctx);
      if (!self.night && !self.running)
        CGContextSetShadowWithColor(ctx, CGSizeZero, u * 1.0, alpha(amber, 0.45).CGColor);
      [amber setFill];
      [pp fill];  // the glow
      CGContextRestoreGState(ctx);
      CGContextSaveGState(ctx);
      [pp addClip];
      fillGradient(ctx, @[alpha(amber, fade), alpha(lerp(amber, NCRGB(0xFFFF6A1A), 0.4), fade)], NULL,
                   r.origin, CGPointMake(CGRectGetMaxX(r), r.origin.y));
      CGContextRestoreGState(ctx);
      [white(0.25 * fade) setStroke];
      fg = [UIColor colorWithWhite:0 alpha:0.85 * fade];
    }
    pp.lineWidth = 1;
    [pp stroke];
    CGFloat cy = CGRectGetMidY(r);
    drawIcon(gn ? @"bedtime" : @"sunny", CGPointMake(r.origin.x + u * 0.9 + u * 0.6, cy), u * 1.2, fg);
    NSDictionary *pa = textAttrs(inter(@"SemiBold", u * 0.8), fg, u * 0.04);
    NSString *t = gn ? @"GN" : @"GM";
    CGSize ts = [t sizeWithAttributes:pa];
    [t drawAtPoint:CGPointMake(r.origin.x + u * 0.9 + u * 1.6, cy - ts.height / 2) withAttributes:pa];
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  if (p.x < self.unit * 3.2) {
    if (self.onHome) self.onHome();
    return;
  }
  if (self.running || !self.showScenes) return;
  if (CGRectContainsPoint(self.gnRect, p)) self.onScene(YES);
  else if (CGRectContainsPoint(self.gmRect, p)) self.onScene(NO);
}

@end

/// The panel's foot (from the user's mock-up): the network on the left,
/// green while the devices answer, and "All systems nominal" on the right
/// — or which devices stopped answering.
@interface NCStatusLine : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic, copy) NSArray<NSString *> *down;
@property (nonatomic) BOOL checking, allDown;
/// What the left side says when [allDown] (default "No devices answering").
@property (nonatomic, copy) NSString *offlineLabel;
@end

@implementation NCStatusLine

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
  }
  return self;
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  CGFloat w = self.bounds.size.width;
  [white(0.08) setFill];
  UIRectFill(CGRectMake(0, 0, w, 1));
  // A soft dark halo so the line reads over a bright video.
  CGContextSetShadowWithColor(UIGraphicsGetCurrentContext(), CGSizeZero, u * 0.6,
                              [UIColor colorWithWhite:0 alpha:0.8].CGColor);
  UIFont *font = inter(@"Medium", u * 0.72);
  UIColor *text = white(self.night ? 0.4 : 0.6);
  CGFloat cy = u * 0.7 + u * 0.6, icon = u * 1.05, half = (w - u * 0.8) / 2;

  NSString *leftIcon = self.allDown ? @"wifioff" : @"wifi";
  UIColor *leftColor = self.allDown ? NCRGB(kRed) : NCHue(0xFF34D399, self.night);
  NSString *left = self.allDown ? (self.offlineLabel ?: @"No devices answering") : @"Connected · Home Wi-Fi";
  drawIcon(leftIcon, CGPointMake(icon / 2, cy), icon, leftColor);
  drawLine(left, font, text, CGRectMake(icon + u * 0.4, cy - font.lineHeight / 2, half - icon - u * 0.4, font.lineHeight));

  NSString *rightIcon, *right;
  UIColor *rightColor;
  if (self.checking) { rightIcon = @"sync"; rightColor = text; right = @"Checking devices…"; }
  else if (!self.down.count) { rightIcon = @"shield"; rightColor = NCHue(kWarm, self.night); right = @"All systems nominal"; }
  else {
    rightIcon = @"warning"; rightColor = NCRGB(kRed);
    right = self.down.count == 1 ? [self.down[0] stringByAppendingString:@" offline"]
                                 : [NSString stringWithFormat:@"%lu devices offline", (unsigned long)self.down.count];
  }
  CGFloat tw = MIN(half - icon - u * 0.4, ceil([right sizeWithAttributes:@{NSFontAttributeName: font}].width));
  CGFloat tx = w - tw;
  drawLine(right, font, text, CGRectMake(tx, cy - font.lineHeight / 2, tw, font.lineHeight));
  drawIcon(rightIcon, CGPointMake(tx - u * 0.4 - icon / 2, cy), icon, rightColor);
}

@end

/// A plain card with one line of text — an empty room.
@interface NCNote : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic, copy) NSString *text;
@end

@implementation NCNote
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
  }
  return self;
}
- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  drawCard(self.bounds, NCHue(kWarm, self.night), NO, NO, u);
  UIFont *f = inter(@"Regular", u * 0.8);
  drawLine(self.text, f, white(0.5), CGRectMake(u * 1.1, (self.bounds.size.height - f.lineHeight) / 2,
                                                self.bounds.size.width - u * 2.2, f.lineHeight));
}
@end

// ── Sonoff switch tile ───────────────────────────────────────────────────

/// A Sonoff switch: a small tile with a fan or lamp icon, its name and
/// state. Not wired up yet — every one reads "Not set up", and a tap does
/// nothing.
@interface NCSwitchTile : NCTile
@property (nonatomic, strong) NCSonoffSwitch *sw;
/// The name shown: without the room's prefix ("Haam's Ceiling 1" →
/// "Ceiling 1" in Haam's Room).
@property (nonatomic, copy) NSString *label;
@end

@implementation NCSwitchTile
- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  NSString *n = self.sw.name.lowercaseString;
  NSString *icon = self.sw.isFan ? @"fan"
      : [n containsString:@"wall"] ? @"walllight"
      : [n containsString:@"cabinet"] ? @"cabinet"
      : [n containsString:@"hanging"] ? @"hanging"
      : [n containsString:@"ceiling"] ? @"ceiling"
      : @"lamp";
  UIColor *hue = NCHue(self.sw.isFan ? kFanGreen : kWarm, self.night);
  drawCard(self.bounds, hue, NO, NO, u);
  CGFloat dim = self.sw.isSetUp ? 1 : 0.55, p = u * 0.8, w = self.bounds.size.width;
  CGRect chip = CGRectMake(p, p, u * 2.2, u * 2.2);
  drawSurface(chip, u * 0.7);
  drawIcon(icon, CGPointMake(CGRectGetMidX(chip), CGRectGetMidY(chip)), u * 1.4, alpha(hue, dim));
  drawIcon(@"power", CGPointMake(w - p - u * 0.5, p + u * 0.5), u * 1.0, white(0.4 * dim));
  UIFont *nf = inter(@"Bold", u * 0.78), *sf = inter(@"Medium", u * 0.62);
  CGFloat h = self.bounds.size.height;
  CGFloat sy = h - p - sf.lineHeight, ny = sy - nf.lineHeight;
  drawLine(self.label ?: self.sw.name, nf, white(dim), CGRectMake(p, ny, w - 2 * p, nf.lineHeight));
  drawLine(self.sw.isSetUp ? @"Off" : @"Not set up", sf, white(0.5 * dim), CGRectMake(p, sy, w - 2 * p, sf.lineHeight));
}
@end

@implementation NCPanelView {
  NCRoom *_room;
  NCNote *_note;
  NSMutableArray<UIVisualEffectView *> *_frost;  // one behind each card
  NCStatusLine *_status;
  NCHeader *_header;
  NSArray<NCLightTile *> *_lightTiles;
  NSArray<NCAcTile *> *_acTiles;
  NSArray<NCSwitchTile *> *_switchTiles;  // fans first, then lights
  NCTvCard *_tvCard;
  NSTimer *_poll;
  CGFloat _unit;
}

- (instancetype)initWithRoom:(NCRoom *)room {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _room = room;
    _header = [NCHeader new];
    _header.title = room.name;
    _header.subtitle = room.name ? room.subtitle : nil;
    __weak NCPanelView *weak = self;
    _header.onScene = ^(BOOL gn) { [weak runScene:gn]; };
    [self addSubview:_header];
    NSMutableArray *lt = [NSMutableArray array];
    for (NCLight *l in room.lights) {
      NCLightTile *t = [[NCLightTile alloc] initWithLight:l];
      t.panel = self;
      [self addSubview:t];
      [lt addObject:t];
    }
    _lightTiles = lt;
    NSMutableArray *st = [NSMutableArray array];
    for (NSNumber *fans in @[@YES, @NO])
      for (NCSonoffSwitch *s in room.switches) {
        if (s.isFan != fans.boolValue) continue;
        NCSwitchTile *t = [NCSwitchTile new];
        t.sw = s;
        NSString *prefix = [[room.name componentsSeparatedByString:@" "].firstObject.lowercaseString
            stringByAppendingString:@" "];
        if (room.name.length && [s.name.lowercaseString hasPrefix:prefix] && s.name.length > prefix.length)
          t.label = [s.name substringFromIndex:prefix.length];
        t.panel = self;
        [self addSubview:t];
        [st addObject:t];
      }
    _switchTiles = st;
    NSMutableArray *at = [NSMutableArray array];
    for (NCGreeAc *ac in room.acs) {
      NCAcTile *t = [[NCAcTile alloc] initWithAc:ac];
      t.panel = self;
      [self addSubview:t];
      [at addObject:t];
    }
    _acTiles = at;
    NCHisenseTv *tv = room.tvs.firstObject;
    NCTvBox *box = room.boxes.firstObject;
    if (tv || box) {
      _tvCard = [NCTvCard new];
      _tvCard.tv = tv;
      _tvCard.box = box;
      [self addSubview:_tvCard];
    }
    // Real frosted glass behind every card (the drawn wash alone was too
    // thin over the bright video to read the buttons).
    _frost = [NSMutableArray array];
    for (UIView *card in self.cards) {
      UIVisualEffectView *f =
          [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
      f.userInteractionEnabled = NO;
      f.clipsToBounds = YES;
      f.alpha = 0.85;
      [self insertSubview:f belowSubview:card];
      [_frost addObject:f];
    }
    // Scenes only in the room that has their devices.
    BOOL scenes = NO;
    for (NCLightTile *t in _lightTiles) {
      NSString *n = t.light.name.lowercaseString;
      if ([n containsString:@"white"] || [n containsString:@"warm"]) scenes = YES;
    }
    for (NCAcTile *t in _acTiles)
      if ([t.ac.name.lowercaseString isEqualToString:@"bedroom"]) scenes = YES;
    _header.showScenes = scenes;
    if (room.isEmpty) {
      _note = [NCNote new];
      _note.text = @"Nothing to control here yet";
      [self addSubview:_note];
    } else {
      _status = [NCStatusLine new];
      [self addSubview:_status];
      [self statusChanged];
    }
  }
  return self;
}

- (void)setOnHome:(void (^)(void))onHome {
  _onHome = [onHome copy];
  _header.onHome = _onHome;
}

- (NSArray<UIView *> *)cards {
  NSMutableArray *all = [NSMutableArray arrayWithArray:_lightTiles];
  [all addObjectsFromArray:_switchTiles];
  [all addObjectsFromArray:_acTiles];
  if (_tvCard) [all addObject:_tvCard];
  return all;
}

- (void)statusChanged {
  NSMutableArray *down = [NSMutableArray array];
  BOOL checking = NO;
  for (NCLightTile *t in _lightTiles) {
    if (t.offline) [down addObject:t.light.name];
    else if (!t.known) checking = YES;
  }
  for (NCAcTile *t in _acTiles)
    if (t.offline) [down addObject:t.ac.name];
  NSUInteger total = _lightTiles.count + _acTiles.count;
  _status.down = down;
  _status.checking = checking && !down.count;
  _status.allDown = total > 0 && down.count == total;
  [_status setNeedsDisplay];
}


- (void)setNight:(BOOL)night {
  _night = night;
  _header.night = night;
  _status.night = night;
  [_status setNeedsDisplay];
  _note.night = night;
  [_note setNeedsDisplay];
  for (NCTile *t in _lightTiles) t.night = night;
  for (NCTile *t in _acTiles) t.night = night;
  for (NCTile *t in _switchTiles) t.night = night;
  _tvCard.night = night;
}

static const CGFloat kGapU = 0.8, kTileU = (26 - 0.8) / 2, kLightH = kTileU * 1.32, kWideAcU = 10.5;
/// Switch tiles: three to a row, a little wider than tall.
static const CGFloat kSwitchU = (26 - 0.8 * 2) / 3, kSwitchH = kSwitchU * 0.82;

/// Rows of switch tiles, three to a row; with more than three, fans get
/// a row of their own.
- (NSArray<NSArray<NCSwitchTile *> *> *)switchRows {
  NSMutableArray *rows = [NSMutableArray array];
  NSMutableArray *row = nil;
  BOOL lastFan = NO;
  for (NCSwitchTile *t in _switchTiles) {
    if (!row || row.count == 3 || (_switchTiles.count > 3 && t.sw.isFan != lastFan)) {
      row = [NSMutableArray array];
      [rows addObject:row];
    }
    [row addObject:t];
    lastFan = t.sw.isFan;
  }
  return rows;
}

- (CGFloat)heightInUnits {
  CGFloat h = 2.8;
  NSUInteger lightRows = (_lightTiles.count + 1) / 2, acRows = (_acTiles.count + 1) / 2;
  if (lightRows) h += kGapU + lightRows * kLightH + (lightRows - 1) * kGapU;
  h += self.switchRows.count * (kGapU + kSwitchH);
  if (_acTiles.count == 1) h += kGapU + kWideAcU;
  else if (acRows) h += kGapU + acRows * kTileU * 1.3 + (acRows - 1) * kGapU;
  if (_tvCard) h += kGapU + 7.2;
  if (_note) return h + kGapU + 4.0;
  return h + kGapU + 2.0;  // the status line
}

- (void)layoutForUnit:(CGFloat)u {
  _unit = u;
  CGFloat gap = u * kGapU, tile = u * kTileU, y = 0;
  _header.unit = u;
  _header.frame = CGRectMake(0, 0, u * 26, u * 2.8);
  y = u * 2.8;
  for (NSUInteger i = 0; i < _lightTiles.count; i++) {
    if (i % 2 == 0) y += gap + (i ? u * kLightH : 0);
    NCLightTile *t = _lightTiles[i];
    t.unit = u;
    t.frame = CGRectMake((i % 2) * (tile + gap), y, tile, u * kLightH);
  }
  if (_lightTiles.count) y += u * kLightH;
  for (NSArray<NCSwitchTile *> *row in self.switchRows) {
    y += gap;
    for (NSUInteger i = 0; i < row.count; i++) {
      row[i].unit = u;
      row[i].frame = CGRectMake(i * (u * kSwitchU + gap), y, u * kSwitchU, u * kSwitchH);
    }
    y += u * kSwitchH;
  }
  if (_acTiles.count == 1) {
    // Alone in its room, the AC gets the whole width.
    NCAcTile *t = _acTiles[0];
    t.unit = u;
    t.wide = YES;
    t.frame = CGRectMake(0, y + gap, u * 26, u * kWideAcU);
    y += gap + u * kWideAcU;
  } else {
    for (NSUInteger i = 0; i < _acTiles.count; i++) {
      if (i % 2 == 0) y += gap + (i ? tile * 1.3 : 0);
      NCAcTile *t = _acTiles[i];
      t.unit = u;
      t.frame = CGRectMake((i % 2) * (tile + gap), y, tile, tile * 1.3);
    }
    if (_acTiles.count) y += tile * 1.3;
  }
  if (_tvCard) {
    _tvCard.unit = u;
    _tvCard.frame = CGRectMake(0, y + gap, u * 26, u * 7.2);
    y += gap + u * 7.2;
  }
  NSArray *cards = self.cards;
  for (NSUInteger i = 0; i < cards.count; i++) {
    _frost[i].frame = [cards[i] frame];
    _frost[i].layer.cornerRadius = u * 1.8;
  }
  _status.unit = u;
  _status.frame = CGRectMake(0, y + gap, u * 26, u * 2.0);
  _note.unit = u;
  _note.frame = CGRectMake(0, y + gap, u * 26, u * 4.0);
  for (UIView *v in self.subviews) [v setNeedsDisplay];
}

- (void)startPolling {
  [_poll invalidate];
  [self refreshAll];
  _poll = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(refreshAll) userInfo:nil repeats:YES];
}

- (void)stopPolling {
  [_poll invalidate];
  _poll = nil;
}

- (void)refreshAll {
  for (NCTile *t in _lightTiles) [t refresh];
  for (NCTile *t in _acTiles) [t refresh];
  [_tvCard refresh];
}

- (BOOL)isDialAt:(CGPoint)point {
  for (NCAcTile *t in _acTiles)
    if (CGRectContainsPoint(t.dialRect, [self convertPoint:point toView:t])) return YES;
  // A colour bulb's box: press and hold opens its sheet, not the dimmer.
  for (NCLightTile *t in _lightTiles)
    if (t.light.hasKelvin && CGRectContainsPoint(t.boxRect, [self convertPoint:point toView:t])) return YES;
  return NO;
}

/// GN (good night): White Light off, Warm Light on at 1%, Bedroom AC on at
/// 24°. GM (good morning): Bedroom AC off, Warm Light 100%, White Light on.
/// All at once; a device that fails just shows Offline.
- (void)runScene:(BOOL)goodNight {
  NCLightTile *(^light)(NSString *) = ^NCLightTile *(NSString *word) {
    for (NCLightTile *t in self->_lightTiles)
      if ([t.light.name.lowercaseString containsString:word]) return t;
    return nil;
  };
  NCLightTile *whiteTile = light(@"white"), *warmTile = light(@"warm");
  NCAcTile *acTile = _acTiles.firstObject;
  for (NCAcTile *t in _acTiles)
    if ([t.ac.name.lowercaseString isEqualToString:@"bedroom"]) acTile = t;

  _header.running = goodNight ? @"gn" : @"gm";
  [_header setNeedsDisplay];
  dispatch_group_t group = dispatch_group_create();
  void (^lightJob)(NCLightTile *, BOOL (^)(NCLight *), BOOL, NSInteger) =
      ^(NCLightTile *t, BOOL (^action)(NCLight *), BOOL on, NSInteger level) {
        if (!t) return;
        dispatch_group_enter(group);
        [t run:action expectOn:on level:level done:^{ dispatch_group_leave(group); }];
      };
  if (goodNight) {
    lightJob(whiteTile, ^BOOL(NCLight *l) { return [l setPower:NO]; }, NO, -1);
    lightJob(warmTile, ^BOOL(NCLight *l) { return [l setBrightness:1]; }, YES, 1);
  } else {
    lightJob(warmTile, ^BOOL(NCLight *l) { return [l setBrightness:100]; }, YES, 100);
    lightJob(whiteTile, ^BOOL(NCLight *l) { return [l setPower:YES]; }, YES, -1);
  }
  if (acTile) {
    NCGreeAc *ac = acTile.ac;
    dispatch_group_enter(group);
    dispatch_async(ac.queue, ^{
      if (goodNight) {
        if ([ac setPower:YES]) [ac setTemp:24];
      } else {
        [ac setPower:NO];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        [acTile refresh];
        dispatch_group_leave(group);
      });
    });
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    self->_header.running = nil;
    [self->_header setNeedsDisplay];
  });
}

@end

// ── Rooms and the home page ──────────────────────────────────────────────

@implementation NCRoom

- (BOOL)isEmpty {
  return !self.lights.count && !self.acs.count && !self.tvs.count && !self.boxes.count && !self.switches.count;
}

- (NSString *)summary {
  NSString *(^n)(NSUInteger, NSString *) = ^NSString *(NSUInteger count, NSString *one) {
    return [NSString stringWithFormat:@"%lu %@%@", (unsigned long)count, one, count == 1 ? @"" : @"s"];
  };
  NSMutableArray *parts = [NSMutableArray array];
  NSUInteger fans = 0;
  for (NCSonoffSwitch *s in self.switches) fans += s.isFan;
  NSUInteger lamps = self.lights.count + self.switches.count - fans;
  if (lamps) [parts addObject:n(lamps, @"light")];
  if (fans) [parts addObject:n(fans, @"fan")];
  if (self.acs.count) [parts addObject:n(self.acs.count, @"AC")];
  if (self.tvs.count + self.boxes.count) [parts addObject:n(self.tvs.count + self.boxes.count, @"TV")];
  return parts.count ? [parts componentsJoinedByString:@" · "] : @"No devices yet";
}

@end

NSArray<NCRoom *> *NCConfiguredRooms(void) {
  NSArray *lights = NCConfiguredLights(), *acs = NCConfiguredAcs();
  NSArray *tvs = NCConfiguredTvs(), *boxes = NCConfiguredBoxes();
  NSArray *switches = NCConfiguredSwitches();
  NSString *spec = [@ROOMS stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  // ROOM_PINS: "Room=1234; Other Room=5678" — rooms that ask for a code.
  NSMutableDictionary *pins = [NSMutableDictionary dictionary];
  for (NSString *p in [@ROOM_PINS componentsSeparatedByString:@";"]) {
    NSRange eq = [p rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    NSString *code = [[p substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
    if (code.length)
      pins[[[p substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws].lowercaseString] = code;
  }
  NSMutableArray *rooms = [NSMutableArray array];
  for (NSString *part in [spec componentsSeparatedByString:@";"]) {
    NSRange eq = [part rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    NSString *head = [[part substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
    NSString *subtitle = nil;
    NSRange open = [head rangeOfString:@"("];
    if (open.location != NSNotFound && [head hasSuffix:@")"]) {
      subtitle = [head substringWithRange:NSMakeRange(open.location + 1, head.length - open.location - 2)];
      head = [[head substringToIndex:open.location] stringByTrimmingCharactersInSet:ws];
    }
    NSMutableSet *names = [NSMutableSet set];
    for (NSString *n in [[part substringFromIndex:eq.location + 1] componentsSeparatedByString:@","]) {
      NSString *t = [n stringByTrimmingCharactersInSet:ws].lowercaseString;
      if (t.length) [names addObject:t];
    }
    NSArray *(^pick)(NSArray *) = ^NSArray *(NSArray *all) {
      NSMutableArray *out = [NSMutableArray array];
      for (id d in all)
        if ([names containsObject:[[d name] lowercaseString]]) [out addObject:d];
      return out;
    };
    NCRoom *room = [NCRoom new];
    room.name = head;
    room.subtitle = subtitle;
    room.pin = pins[head.lowercaseString];
    room.lights = pick(lights);
    room.acs = pick(acs);
    room.tvs = pick(tvs);
    room.boxes = pick(boxes);
    room.switches = pick(switches);
    [rooms addObject:room];
  }
  if (!rooms.count) {
    NCRoom *all = [NCRoom new];
    all.lights = lights;
    all.acs = acs;
    all.tvs = tvs;
    all.boxes = boxes;
    all.switches = switches;
    [rooms addObject:all];
  }
  return rooms;
}

/// One room on the home page: its icon, a "Here" badge on this iPad's own
/// room, the name and its subtitle (or what's in it).
@interface NCRoomCard : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night, here;
@property (nonatomic, strong) NCRoom *room;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation NCRoomCard

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
  }
  return self;
}

- (void)tapped { if (self.onTap) self.onTap(); }

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *amber = NCHue(kWarm, self.night);
  drawCard(self.bounds, amber, NO, NO, u);
  CGFloat p = u * 1.1, w = self.bounds.size.width, h = self.bounds.size.height;
  CGRect chip = CGRectMake(p, p, u * 2.6, u * 2.6);
  [white(0.07) setFill];
  [[UIBezierPath bezierPathWithRoundedRect:chip cornerRadius:u * 0.8] fill];
  NSString *n = self.room.name.lowercaseString;
  NSString *icon = [n containsString:@"kitchen"] ? @"kitchen"
                 : [n containsString:@"sitting"] || [n containsString:@"living"] || [n containsString:@"lounge"] ? @"sofa"
                 : @"bed";
  drawIcon(icon, CGPointMake(CGRectGetMidX(chip), CGRectGetMidY(chip)), u * 1.5,
           self.room.isEmpty ? white(0.4) : amber);
  if (self.room.pin && !self.here)
    drawIcon(@"lock", CGPointMake(w - p - u * 0.6, CGRectGetMidY(chip)), u * 1.1, white(0.45));
  if (self.here) {
    UIFont *bf = inter(@"SemiBold", u * 0.65);
    CGFloat bw = [@"Here" sizeWithAttributes:@{NSFontAttributeName: bf}].width + u * 1.2;
    CGRect badge = CGRectMake(w - p - bw, CGRectGetMidY(chip) - u * 0.6, bw, u * 1.2);
    [alpha(amber, 0.15) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:u * 0.6] fill];
    drawCentered(@"Here", textAttrs(bf, amber, 0), CGPointMake(CGRectGetMidX(badge), CGRectGetMidY(badge)));
  }
  UIFont *nf = inter(@"SemiBold", u * 1.0), *sf = inter(@"Medium", u * 0.72);
  CGFloat sy = h - p - sf.lineHeight;
  drawLine(self.room.subtitle ?: self.room.summary, sf, white(0.5), CGRectMake(p, sy, w - 2 * p, sf.lineHeight));
  drawLine(self.room.name, nf, NCRGB(kWhite), CGRectMake(p, sy - nf.lineHeight, w - 2 * p, nf.lineHeight));
}

@end

/// The dots and keypad of the passcode pad, drawn in one card.
@interface NCPinPad : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night, wrong;
@property (nonatomic) NSUInteger length, typed;
@property (nonatomic, copy) void (^onKey)(NSString *key);  // a digit, or @"<"
@end

@implementation NCPinPad

static NSString *const kPinKeys[12] = {@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"", @"0", @"<"};

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}

/// Key [i] (0–11, row by row) in this view.
- (CGRect)keyRect:(NSInteger)i {
  CGFloat u = self.unit, p = u * 1.1, gap = u * 0.6;
  CGFloat kw = (self.bounds.size.width - 2 * p - 2 * gap) / 3, kh = u * 2.8;
  CGFloat top = p + u * 0.9 + u * 1.2;
  return CGRectMake(p + (i % 3) * (kw + gap), top + (i / 3) * (kh + gap), kw, kh);
}

+ (CGFloat)heightInUnits { return 1.1 * 2 + 0.9 + 1.2 + 4 * 2.8 + 3 * 0.6; }

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *amber = NCHue(kWarm, self.night), *red = NCHue(kRed, self.night);
  drawCard(self.bounds, self.wrong ? red : amber, NO, self.wrong, u);
  // The dots: one per digit, filled as they're typed.
  CGFloat d = u * 0.9, step = d + u * 0.9;
  CGFloat x0 = (self.bounds.size.width - (self.length * step - u * 0.9)) / 2, y = u * 1.1;
  for (NSUInteger i = 0; i < self.length; i++) {
    CGRect r = CGRectInset(CGRectMake(x0 + i * step, y, d, d), u * 0.06, u * 0.06);
    UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:r];
    dot.lineWidth = u * 0.12;
    if (self.wrong || i < self.typed) {
      [(self.wrong ? red : amber) setFill];
      [dot fill];
    }
    [(self.wrong ? red : alpha(amber, 0.6)) setStroke];
    [dot stroke];
  }
  NSDictionary *ka = textAttrs(inter(@"SemiBold", u * 1.2), white(self.night ? 0.7 : 0.92), 0);
  for (NSInteger i = 0; i < 12; i++) {
    NSString *k = kPinKeys[i];
    CGRect r = [self keyRect:i];
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    if ([k isEqualToString:@"<"]) {
      drawIcon(@"backspace", c, u * 1.2, white(0.6));
    } else if (k.length) {
      UIBezierPath *kp = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 0.5, 0.5) cornerRadius:u * 0.9];
      [white(0.07) setFill];
      [kp fill];
      [white(0.10) setStroke];
      [kp stroke];
      drawCentered(k, ka, c);
    }
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  for (NSInteger i = 0; i < 12; i++)
    if (kPinKeys[i].length && CGRectContainsPoint(CGRectInset([self keyRect:i], -self.unit * 0.3, -self.unit * 0.3), p)) {
      if (self.onKey) self.onKey(kPinKeys[i]);
      return;
    }
}

@end

@implementation NCPinView {
  NCRoom *_room;
  NCHeader *_header;
  NCPinPad *_pad;
  UIVisualEffectView *_frost;
  NSString *_typed;
}

- (instancetype)initWithRoom:(NCRoom *)room {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _room = room;
    _typed = @"";
    _header = [NCHeader new];
    _header.title = room.name;
    _header.subtitle = @"Enter passcode";
    __weak NCPinView *weak = self;
    _header.onHome = ^{ if (weak.onCancel) weak.onCancel(); };
    [self addSubview:_header];
    _frost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _frost.userInteractionEnabled = NO;
    _frost.clipsToBounds = YES;
    _frost.alpha = 0.85;
    [self addSubview:_frost];
    _pad = [NCPinPad new];
    _pad.length = MAX(1, room.pin.length);
    _pad.onKey = ^(NSString *key) { [weak press:key]; };
    [self addSubview:_pad];
  }
  return self;
}

- (void)press:(NSString *)key {
  if (_pad.wrong) return;
  if ([key isEqualToString:@"<"]) {
    if (_typed.length) _typed = [_typed substringToIndex:_typed.length - 1];
  } else {
    _typed = [_typed stringByAppendingString:key];
  }
  _pad.typed = _typed.length;
  [_pad setNeedsDisplay];
  if (_typed.length < _room.pin.length) return;
  if ([_typed isEqualToString:_room.pin]) {
    if (self.onUnlock) self.onUnlock();
    return;
  }
  // Wrong: the dots flash red, then clear.
  _pad.wrong = YES;
  _header.subtitle = @"Wrong passcode";
  [_header setNeedsDisplay];
  [_pad setNeedsDisplay];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    self->_typed = @"";
    self->_pad.typed = 0;
    self->_pad.wrong = NO;
    self->_header.subtitle = @"Enter passcode";
    [self->_header setNeedsDisplay];
    [self->_pad setNeedsDisplay];
  });
}

- (void)setNight:(BOOL)night {
  _night = night;
  _header.night = night;
  _pad.night = night;
  [_header setNeedsDisplay];
  [_pad setNeedsDisplay];
}

- (CGFloat)heightInUnits { return 2.8 + kGapU + [NCPinPad heightInUnits]; }

- (void)layoutForUnit:(CGFloat)u {
  _header.unit = u;
  _header.frame = CGRectMake(0, 0, u * 26, u * 2.8);
  CGRect r = CGRectMake(0, u * (2.8 + kGapU), u * 26, u * [NCPinPad heightInUnits]);
  _pad.unit = u;
  _pad.frame = r;
  _frost.frame = r;
  _frost.layer.cornerRadius = u * 1.8;
  [_header setNeedsDisplay];
  [_pad setNeedsDisplay];
}

- (void)startPolling {}
- (void)stopPolling {}
- (BOOL)isDialAt:(CGPoint)point { return NO; }

@end

/// The home page's tally of the whole house: lights on, ACs cooling and
/// screens (TVs and boxes) on — "–" until the first count is in. Port of
/// _HomeStats.
@interface NCHomeStats : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic) NSInteger lights, cooling, screens;  // -1: not yet
@end

@implementation NCHomeStats

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
    _lights = _cooling = _screens = -1;
  }
  return self;
}

+ (CGFloat)heightInUnits { return 4.4; }

/// Where each of the three tiles goes (the frost views sit behind them).
- (CGRect)tile:(NSInteger)i {
  CGFloat u = self.unit, gap = u * 0.6, w = (self.bounds.size.width - 2 * gap) / 3;
  return CGRectMake(i * (w + gap), 0, w, self.bounds.size.height);
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  NSInteger counts[3] = {self.lights, self.cooling, self.screens};
  uint32_t hues[3] = {kWarm, 0xFF4FD8EB, 0xFFB69CFF};
  NSString *icons[3] = {@"bulb", @"mode1", @"tv"};
  NSString *labels[3] = {@"lights on", @"cooling", @"screens on"};
  UIFont *nf = inter(@"SemiBold", u * 1.3), *lf = inter(@"Medium", u * 0.65);
  for (NSInteger i = 0; i < 3; i++) {
    CGRect r = [self tile:i];
    UIColor *c = NCHue(hues[i], self.night);
    BOOL lit = counts[i] > 0;
    drawCard(r, c, lit, NO, u);
    CGFloat p = u * 1.1, cy = CGRectGetMidY(r), icon = u * 1.4;
    drawIcon(icons[i], CGPointMake(r.origin.x + p + icon / 2, cy), icon, lit ? c : alpha(c, 0.5));
    CGFloat tx = r.origin.x + p + icon + u * 0.5, tw = CGRectGetMaxX(r) - p - tx;
    NSString *n = counts[i] < 0 ? @"–" : [NSString stringWithFormat:@"%ld", (long)counts[i]];
    CGFloat top = cy - (nf.lineHeight + lf.lineHeight) / 2;
    drawLine(n, nf, NCRGB(kWhite), CGRectMake(tx, top, tw, nf.lineHeight));
    drawLine(labels[i], lf, white(0.55), CGRectMake(tx, top + nf.lineHeight, tw, lf.lineHeight));
  }
}

@end

// ── Energy card ──────────────────────────────────────────────────────────

static NSString *kwText(double w) {
  return w >= 1000 ? [NSString stringWithFormat:@"%.1f kW", w / 1000] : [NSString stringWithFormat:@"%ld W", lround(w)];
}

static NSString *mvrText(double v) {
  NSNumberFormatter *f = [NSNumberFormatter new];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  f.maximumFractionDigits = 0;
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  return [f stringFromNumber:@(lround(v))];
}

/// Port of _EnergyCard: the draw now, today, this billing period and its
/// projected bill, a line graph of the bills (touch it for one month's
/// figures), and the draw split by kind.
@interface NCEnergyCard : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night;
@property (nonatomic, weak) NCEnergyTracker *energy;
+ (CGFloat)heightInUnits;
@end

@implementation NCEnergyCard {
  NSInteger _picked;  // -1: none
  NSTimer *_unpick;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    _picked = -1;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTouch:)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onTouch:)]];
  }
  return self;
}

+ (CGFloat)heightInUnits { return 18.6; }

static const CGFloat kChartU = 7;

/// One point per bill, then this period's projection: date, kWh, projected?
- (NSArray<NSArray *> *)points {
  NSMutableArray *p = [NSMutableArray array];
  for (NCBill *b in self.energy.bills) [p addObject:@[b.date, @(b.kwh), @NO, @(b.days)]];
  if (self.energy.totalWatts >= 0)
    [p addObject:@[self.energy.periodEnd, @(self.energy.projectedKwh), @YES, @(self.energy.periodDays)]];
  return p;
}

- (CGRect)chartRect {
  CGFloat u = self.unit, pad = u * 1.1;
  CGFloat top = pad + u * 2.4 + u * 0.9 + u * 2.1 + u * 0.9 + u * 1.2;
  return CGRectMake(pad, top, self.bounds.size.width - 2 * pad, u * kChartU);
}

/// Each point's x: evenly spaced, an extra step before a gap of > 45 days.
- (NSArray<NSNumber *> *)xsFor:(NSArray<NSArray *> *)pts in:(CGRect)r {
  NSMutableArray *steps = [NSMutableArray arrayWithObject:@0];
  for (NSUInteger i = 1; i < pts.count; i++) {
    BOOL gap = [pts[i][0] timeIntervalSinceDate:pts[i - 1][0]] > 45 * 86400;
    [steps addObject:@([steps.lastObject doubleValue] + (gap ? 1.6 : 1))];
  }
  CGFloat span = MAX(1, [steps.lastObject doubleValue]);
  CGFloat l = r.origin.x + self.unit * 2.6, rr = CGRectGetMaxX(r) - self.unit * 0.6;
  NSMutableArray *xs = [NSMutableArray array];
  for (NSNumber *s in steps) [xs addObject:@(l + (rr - l) * s.doubleValue / span)];
  return xs;
}

- (void)onTouch:(UIGestureRecognizer *)g {
  NSArray *pts = self.points;
  if (!pts.count) return;
  NSArray *xs = [self xsFor:pts in:self.chartRect];
  CGFloat x = [g locationInView:self].x;
  NSInteger best = 0;
  for (NSUInteger i = 1; i < xs.count; i++)
    if (fabs([xs[i] doubleValue] - x) < fabs([xs[best] doubleValue] - x)) best = i;
  _picked = best;
  [_unpick invalidate];
  if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
    _unpick = [NSTimer scheduledTimerWithTimeInterval:4 target:self selector:@selector(clearPick) userInfo:nil repeats:NO];
  [self setNeedsDisplay];
}

- (void)clearPick {
  _picked = -1;
  [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  NCEnergyTracker *e = self.energy;
  if (u <= 0 || !e) return;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  UIColor *amber = NCHue(kWarm, self.night);
  drawCard(self.bounds, amber, NO, NO, u);
  CGFloat pad = u * 1.1, x0 = pad, w = self.bounds.size.width - 2 * pad, y = pad;
  BOOL known = e.totalWatts >= 0;

  // Header: bolt, ENERGY, the period; the draw now on the right.
  CGRect chip = CGRectMake(x0, y, u * 2.4, u * 2.4);
  [alpha(amber, 0.14) setFill];
  [[UIBezierPath bezierPathWithRoundedRect:chip cornerRadius:u * 0.7] fill];
  drawIcon(@"bolt", CGPointMake(CGRectGetMidX(chip), CGRectGetMidY(chip)), u * 1.5, amber);
  NSDateFormatter *df = [NSDateFormatter new];
  df.dateFormat = @"d MMM";
  UIFont *tf = inter(@"SemiBold", u * 0.8), *sf = inter(@"Regular", u * 0.62);
  CGFloat tx = CGRectGetMaxX(chip) + u * 0.7, ty = CGRectGetMidY(chip) - (tf.lineHeight + sf.lineHeight) / 2;
  [@"ENERGY" drawAtPoint:CGPointMake(tx, ty) withAttributes:textAttrs(tf, NCRGB(kWhite), u * 0.15)];
  [[NSString stringWithFormat:@"Estimate · bill from %@", [df stringFromDate:e.periodStart ?: [NSDate date]]]
      drawAtPoint:CGPointMake(tx, ty + tf.lineHeight) withAttributes:textAttrs(sf, white(0.5), 0)];
  NSDictionary *big = textAttrs(inter(@"SemiBold", u * 1.5), NCRGB(kWhite), 0);
  NSString *now = known ? kwText(e.totalWatts) : @"–";
  CGSize ns = [now sizeWithAttributes:big];
  [now drawAtPoint:CGPointMake(x0 + w - ns.width, y) withAttributes:big];
  CGSize ls = [@"now" sizeWithAttributes:textAttrs(sf, white(0.5), 0)];
  [@"now" drawAtPoint:CGPointMake(x0 + w - ls.width, y + ns.height) withAttributes:textAttrs(sf, white(0.5), 0)];
  y += u * 2.4 + u * 0.9;

  // Today · This bill · Projected
  double projected = known ? e.projectedKwh : 0;
  NSArray *figs = @[
    @[@"Today", known ? [NSString stringWithFormat:@"%.1f", e.dayKwh] : @"–", @"kWh"],
    @[@"This bill", known ? [NSString stringWithFormat:@"%ld", lround(e.periodKwh)] : @"–", @"kWh"],
    @[@"Projected", known ? mvrText(NCBillMvr(projected, e.periodDays)) : @"–", @"MVR"],
  ];
  UIFont *lf = inter(@"Medium", u * 0.65), *vf = inter(@"SemiBold", u * 1.15), *uf = inter(@"Medium", u * 0.7);
  for (int i = 0; i < 3; i++) {
    CGFloat fx = x0 + i * w / 3;
    [figs[i][0] drawAtPoint:CGPointMake(fx, y) withAttributes:textAttrs(lf, white(0.55), 0)];
    NSDictionary *va = textAttrs(vf, NCRGB(kWhite), 0);
    CGSize vs = [figs[i][1] sizeWithAttributes:va];
    CGFloat vy = y + lf.lineHeight;
    [figs[i][1] drawAtPoint:CGPointMake(fx, vy) withAttributes:va];
    [[@" " stringByAppendingString:figs[i][2]] drawAtPoint:CGPointMake(fx + vs.width, vy + vf.ascender - uf.ascender)
                                             withAttributes:textAttrs(uf, white(0.6), 0)];
  }
  y += u * 2.1 + u * 0.9;

  // Caption: the picked point's figures, or how to read the graph.
  NSArray<NSArray *> *pts = self.points;
  NSString *cap = @"kWh a day, per bill · touch for details";
  if (_picked >= 0 && _picked < (NSInteger)pts.count) {
    NSArray *p = pts[_picked];
    double kwh = [p[1] doubleValue];
    NSString *when;
    if ([p[2] boolValue]) when = @"This bill (projected)";
    else {
      NSDateFormatter *mf = [NSDateFormatter new];
      mf.dateFormat = @"d MMM";
      when = [[mf stringFromDate:p[0]] stringByAppendingString:@" bill"];
    }
    cap = [NSString stringWithFormat:@"%@ · %.1f kWh/day · %@ kWh · MVR %@", when, kwh / MAX(1, [p[3] doubleValue]),
                                     mvrText(kwh), mvrText(NCBillMvr(kwh, [p[3] integerValue]))];
  }
  [cap drawAtPoint:CGPointMake(x0, y + u * 0.2) withAttributes:textAttrs(inter(@"Medium", u * 0.62), white(_picked >= 0 ? 0.85 : 0.45), 0)];

  // The graph.
  CGRect cr = self.chartRect;
  if (pts.count) {
    CGFloat top = cr.origin.y + u * 0.6, bottom = CGRectGetMaxY(cr) - u * 1.2;
    // Bills run 12 to 33 days, so the graph is kWh a day.
    double (^perDay)(NSArray *) = ^double(NSArray *p) { return [p[1] doubleValue] / MAX(1, [p[3] doubleValue]); };
    double hi = 0, lo = 1e9;
    for (NSArray *p in pts) {
      hi = MAX(hi, perDay(p));
      lo = MIN(lo, perDay(p));
    }
    // A round scale, about three grid lines.
    double step = 1000;
    for (NSNumber *n in @[@1, @2, @5, @10, @20, @50, @100, @200, @500])
      if (MAX(1, hi - lo) / n.doubleValue <= 3.5) { step = n.doubleValue; break; }
    double yMin = MAX(0, floor(lo / step) * step), yMax = MAX(yMin + step, ceil(hi / step) * step);
    CGFloat (^Y)(double) = ^CGFloat(double k) { return bottom - (k - yMin) / (yMax - yMin) * (bottom - top); };
    NSArray<NSNumber *> *xs = [self xsFor:pts in:cr];
    UIFont *af = inter(@"Regular", u * 0.55);
    for (double v = yMin; v <= yMax + step / 2; v += step) {
      CGFloat gy = Y(v);
      [white(0.08) setStroke];
      UIBezierPath *gl = [UIBezierPath bezierPath];
      [gl moveToPoint:CGPointMake(cr.origin.x + u * 2.2, gy)];
      [gl addLineToPoint:CGPointMake(CGRectGetMaxX(cr), gy)];
      gl.lineWidth = 1;
      [gl stroke];
      NSString *t = [NSString stringWithFormat:@"%ld", lround(v)];
      [t drawAtPoint:CGPointMake(cr.origin.x, gy - af.lineHeight / 2) withAttributes:textAttrs(af, white(0.4), 0)];
    }
    // Runs of bills with no gap between: a smooth line over a soft fill.
    NSMutableArray<NSMutableArray<NSNumber *> *> *runs = [NSMutableArray arrayWithObject:[NSMutableArray array]];
    for (NSUInteger i = 0; i < pts.count; i++) {
      BOOL brk = i > 0 && ([pts[i][0] timeIntervalSinceDate:pts[i - 1][0]] > 45 * 86400 || [pts[i][2] boolValue]);
      if (brk && runs.lastObject.count) [runs addObject:[NSMutableArray array]];
      [runs.lastObject addObject:@(i)];
    }
    for (NSArray<NSNumber *> *run in runs) {
      if (!run.count || [pts[run.firstObject.integerValue][2] boolValue]) continue;
      UIBezierPath *line = [UIBezierPath bezierPath];
      CGPoint prev = CGPointZero;
      for (NSUInteger k = 0; k < run.count; k++) {
        NSInteger i = run[k].integerValue;
        CGPoint pt = CGPointMake(xs[i].doubleValue, Y(perDay(pts[i])));
        if (k == 0) [line moveToPoint:pt];
        else {
          CGFloat dx = (pt.x - prev.x) / 3;
          [line addCurveToPoint:pt controlPoint1:CGPointMake(prev.x + dx, prev.y) controlPoint2:CGPointMake(pt.x - dx, pt.y)];
        }
        prev = pt;
      }
      UIBezierPath *fill = [line copy];
      CGFloat fx0 = xs[run.firstObject.integerValue].doubleValue;
      [fill addLineToPoint:CGPointMake(prev.x, bottom)];
      [fill addLineToPoint:CGPointMake(fx0, bottom)];
      [fill closePath];
      CGContextSaveGState(ctx);
      [fill addClip];
      fillGradient(ctx, @[alpha(amber, 0.28), alpha(amber, 0)], NULL, CGPointMake(0, top), CGPointMake(0, bottom));
      CGContextRestoreGState(ctx);
      line.lineWidth = 2;
      line.lineCapStyle = kCGLineCapRound;
      line.lineJoinStyle = kCGLineJoinRound;
      [amber setStroke];
      [line stroke];
    }
    // Points, the guide, and the month initials.
    static NSString *const initials[] = {@"J", @"F", @"M", @"A", @"M", @"J", @"J", @"A", @"S", @"O", @"N", @"D"};
    for (NSUInteger i = 0; i < pts.count; i++) {
      NSArray *p = pts[i];
      BOOL proj = [p[2] boolValue], pick = (NSInteger)i == _picked;
      CGPoint c = CGPointMake(xs[i].doubleValue, Y(perDay(p)));
      if (pick) {
        UIBezierPath *guide = [UIBezierPath bezierPath];
        [guide moveToPoint:CGPointMake(c.x, top)];
        [guide addLineToPoint:CGPointMake(c.x, bottom)];
        guide.lineWidth = 1;
        [white(0.3) setStroke];
        [guide stroke];
      }
      if (proj && i > 0 && [p[0] timeIntervalSinceDate:pts[i - 1][0]] <= 45 * 86400) {
        CGPoint a = CGPointMake(xs[i - 1].doubleValue, Y(perDay(pts[i - 1])));
        UIBezierPath *link = [UIBezierPath bezierPath];
        [link moveToPoint:a];
        [link addLineToPoint:c];
        CGFloat dash[] = {6, 6};
        [link setLineDash:dash count:2 phase:0];
        link.lineWidth = 2;
        [alpha(amber, 0.7) setStroke];
        [link stroke];
      }
      if (proj) {
        [alpha(amber, 0.18) setFill];
        [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.9 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:c radius:u * 0.38 startAngle:0 endAngle:2 * M_PI clockwise:YES];
        [NCRGB(0xFF15171C) setFill];
        [ring fill];
        ring.lineWidth = 2;
        [amber setStroke];
        [ring stroke];
      } else if (pick) {
        [NCRGB(0xFF15171C) setFill];
        [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.42 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
        [amber setFill];
        [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.3 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
      }
      // The bill's month, three letters when there's room.
      static NSString *const names[] = {@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun",
                                        @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"};
      NSInteger month = [NSCalendar.currentCalendar component:NSCalendarUnitMonth fromDate:p[0]];
      NSString *lab = proj ? @"now" : pts.count <= 8 ? names[month - 1] : initials[month - 1];
      NSDictionary *la = textAttrs(inter(proj ? @"SemiBold" : @"Regular", u * 0.55), white(pick || proj ? 0.85 : 0.4), 0);
      CGSize s = [lab sizeWithAttributes:la];
      [lab drawAtPoint:CGPointMake(c.x - s.width / 2, bottom + u * 0.35) withAttributes:la];
    }
  }

  // ACs · Lights · Screens · Other
  if (!known) return;
  CGFloat by = CGRectGetMaxY(cr) + u * 0.7, bx = x0;
  NSArray *parts = @[@[@0xFF4FD8EB, @"ACs", @(e.acWatts)], @[@(kWarm), @"Lights", @(e.lightWatts)],
                     @[@(kTvViolet), @"Screens", @(e.screenWatts)], @[@0xFF9AA0AA, @"Other", @(e.otherWatts)]];
  NSDictionary *pa = textAttrs(inter(@"Medium", u * 0.62), white(0.7), 0);
  for (NSArray *p in parts) {
    NSString *t = [NSString stringWithFormat:@"%@ %@", p[1], kwText([p[2] doubleValue])];
    CGSize s = [t sizeWithAttributes:pa];
    [NCHue((uint32_t)[p[0] unsignedIntValue], self.night) setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(bx, by + s.height / 2 - u * 0.25, u * 0.5, u * 0.5)] fill];
    [t drawAtPoint:CGPointMake(bx + u * 0.8, by) withAttributes:pa];
    bx += u * 0.8 + s.width + u * 0.9;
  }
}

@end

/// Whether this iPad is on Wi-Fi: en0 has an IPv4 address.
static BOOL NCOnWifi(void) {
  struct ifaddrs *all = NULL;
  if (getifaddrs(&all) != 0) return NO;
  BOOL on = NO;
  for (struct ifaddrs *i = all; i; i = i->ifa_next)
    if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && !strcmp(i->ifa_name, "en0") && (i->ifa_flags & IFF_UP))
      on = YES;
  freeifaddrs(all);
  return on;
}

@implementation NCHomeView {
  NSArray<NCRoom *> *_rooms;
  NCHomeStats *_stats;
  NSArray<UIVisualEffectView *> *_statsFrost;
  NCEnergyCard *_energyCard;
  UIVisualEffectView *_energyFrost;
  NCStatusLine *_status;
  NSTimer *_wifiTimer;
  NCHeader *_header;
  NSArray<NCRoomCard *> *_cards;
  NSArray<UIVisualEffectView *> *_frost;
}

static const CGFloat kRoomCardU = 9;

- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms here:(NSInteger)here {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _header = [NCHeader new];
    _header.title = @"Home";
    _header.subtitle = [NSString stringWithFormat:@"%lu rooms", (unsigned long)rooms.count];
    [self addSubview:_header];
    _rooms = rooms;
    NSMutableArray *sf = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
      UIVisualEffectView *f =
          [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
      f.userInteractionEnabled = NO;
      f.clipsToBounds = YES;
      f.alpha = 0.85;
      [self addSubview:f];
      [sf addObject:f];
    }
    _statsFrost = sf;
    _stats = [NCHomeStats new];
    [self addSubview:_stats];
    _energyFrost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _energyFrost.userInteractionEnabled = NO;
    _energyFrost.clipsToBounds = YES;
    _energyFrost.alpha = 0.85;
    _energyFrost.hidden = YES;
    [self addSubview:_energyFrost];
    _energyCard = [NCEnergyCard new];
    _energyCard.hidden = YES;
    [self addSubview:_energyCard];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(energyUpdated)
                                               name:NCEnergyUpdatedNotification object:nil];
    NSMutableArray *cards = [NSMutableArray array], *frost = [NSMutableArray array];
    __weak NCHomeView *weak = self;
    for (NSUInteger i = 0; i < rooms.count; i++) {
      UIVisualEffectView *f =
          [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
      f.userInteractionEnabled = NO;
      f.clipsToBounds = YES;
      f.alpha = 0.85;
      [self addSubview:f];
      [frost addObject:f];
      NCRoomCard *c = [NCRoomCard new];
      c.room = rooms[i];
      c.here = (NSInteger)i == here;
      c.onTap = ^{ if (weak.onOpen) weak.onOpen(i); };
      [self addSubview:c];
      [cards addObject:c];
    }
    _cards = cards;
    _frost = frost;
    // The same foot as a room's, with Wi-Fi read from the iPad itself (no
    // device is polled on the home page).
    _status = [NCStatusLine new];
    _status.offlineLabel = @"No Wi-Fi";
    [self addSubview:_status];
    [self checkWifi];
  }
  return self;
}

- (void)checkWifi {
  BOOL off = !NCOnWifi();
  if (off == _status.allDown) return;
  _status.allDown = off;
  [_status setNeedsDisplay];
}

- (void)setNight:(BOOL)night {
  _night = night;
  _header.night = night;
  [_header setNeedsDisplay];
  for (NCRoomCard *c in _cards) {
    c.night = night;
    [c setNeedsDisplay];
  }
  _status.night = night;
  [_status setNeedsDisplay];
  _stats.night = night;
  [_stats setNeedsDisplay];
  _energyCard.night = night;
  [_energyCard setNeedsDisplay];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// The card shows only with bills to go on.
- (BOOL)showsEnergy { return self.energy.bills.count > 0; }

- (void)setEnergy:(NCEnergyTracker *)energy {
  _energy = energy;
  _energyCard.energy = energy;
  _energyCard.hidden = _energyFrost.hidden = !self.showsEnergy;
  [self energyUpdated];
}

/// A new round from the house-wide poll: the counts and the card.
- (void)energyUpdated {
  NCEnergyTracker *e = self.energy;
  if (!e) return;
  _stats.lights = e.lightsOn;
  _stats.cooling = e.cooling;
  _stats.screens = e.screensOn;
  [_stats setNeedsDisplay];
  [_energyCard setNeedsDisplay];
}

- (CGFloat)heightInUnits {
  NSUInteger rows = (_cards.count + 1) / 2;
  return 2.8 + kGapU + [NCHomeStats heightInUnits] + (self.showsEnergy ? kGapU + [NCEnergyCard heightInUnits] : 0) +
         (rows ? kGapU + rows * kRoomCardU + (rows - 1) * kGapU : 0) + kGapU + 2.0;
}

- (void)layoutForUnit:(CGFloat)u {
  CGFloat gap = u * kGapU, tile = u * kTileU, h = u * kRoomCardU;
  _header.unit = u;
  _header.frame = CGRectMake(0, 0, u * 26, u * 2.8);
  for (NSUInteger i = 0; i < _cards.count; i++) {
    CGFloat top = u * 2.8 + gap + u * [NCHomeStats heightInUnits] + gap +
                  (self.showsEnergy ? u * [NCEnergyCard heightInUnits] + gap : 0);
    CGRect r = CGRectMake((i % 2) * (tile + gap), top + (i / 2) * (h + gap), tile, h);
    _cards[i].unit = u;
    _cards[i].frame = r;
    _frost[i].frame = r;
    _frost[i].layer.cornerRadius = u * 1.8;
  }
  _status.unit = u;
  _status.frame = CGRectMake(0, u * ([self heightInUnits] - 2.0), u * 26, u * 2.0);
  _stats.unit = u;
  _stats.frame = CGRectMake(0, u * 2.8 + gap, u * 26, u * [NCHomeStats heightInUnits]);
  CGRect er = CGRectMake(0, CGRectGetMaxY(_stats.frame) + gap, u * 26, u * [NCEnergyCard heightInUnits]);
  _energyCard.unit = u;
  _energyCard.frame = er;
  _energyFrost.frame = er;
  _energyFrost.layer.cornerRadius = u * 1.8;
  for (int i = 0; i < 3; i++) {
    CGRect r = [_stats tile:i];
    _statsFrost[i].frame = CGRectOffset(r, 0, _stats.frame.origin.y);
    _statsFrost[i].layer.cornerRadius = u * 1.8;
  }
  for (UIView *v in self.subviews) [v setNeedsDisplay];
}

- (void)startPolling {
  [self energyUpdated];
  [self checkWifi];
  [_wifiTimer invalidate];
  _wifiTimer = [NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(checkWifi)
                                              userInfo:nil repeats:YES];
}
- (void)stopPolling {
  [_wifiTimer invalidate];
  _wifiTimer = nil;
}
- (BOOL)isDialAt:(CGPoint)point { return NO; }

@end
