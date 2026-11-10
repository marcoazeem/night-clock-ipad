#import "Panel.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import "Devices.h"
#import "Energy.h"
#import "NC.h"
#import "TV.h"
#import "Lux.h"

// ── Palette (lib/main.dart) ──────────────────────────────────────────────
static const uint32_t kTvViolet = 0xFFB69CFF;
static const uint32_t kWarm = 0xFFFFB547, kRed = 0xFFFF453A, kWhite = 0xFFE8E8E8;
static const uint32_t kAcModeHues[] = {0xFF5EEAD4, 0xFF4FD8EB, 0xFF7CB8FF, 0xFF6EE7A0, 0xFFFF8A4C};
static NSString *const kAcModeNames[] = {@"Auto", @"Cool", @"Dry", @"Fan", @"Heat"};
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

/// The card every device sits on — the luxury look's black card with a
/// brushed-metal hairline edge, gold-edged while [on] (red on [alert]).
/// [flat] is no longer different: the page is black already.
static void drawCardStyle(CGRect r, UIColor *hue, BOOL on, BOOL alert, CGFloat u, BOOL flat) {
  CGFloat radius = MIN(24, u * 1.8);
  if (alert) NCLuxCard(r, radius, alpha(NCRGB(kRed), 0.45), alpha(NCRGB(kRed), 0.06), 0.6);
  else if (on) NCLuxCard(r, radius, alpha(hue, 0.55), alpha(hue, 0.08), 0.6);
  else NCLuxPlainCard(r, radius, 0.22);
}

static void drawCard(CGRect r, UIColor *hue, BOOL on, BOOL alert, CGFloat u) {
  drawCardStyle(r, hue, on, alert, u, NO);
}

void NCDrawCard(CGRect r, UIColor *hue, BOOL on, BOOL alert, CGFloat u, BOOL flat) {
  drawCardStyle(r, hue, on, alert, u, flat);
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

@class NCLightTile;

@interface NCPanelView ()
/// A tile's offline / connecting state changed.
- (void)statusChanged;
/// A light tile redrew: so does the dimmer row.
- (void)lightChanged;
/// A light tile was tapped: it becomes the dimmer row's light.
- (void)lightTapped:(NCLightTile *)tile;
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
/// Standby: flat on black, no glow.
@property (nonatomic) BOOL standby;
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
- (void)setStandby:(BOOL)standby { _standby = standby; [self setNeedsDisplay]; }
- (void)setUnit:(CGFloat)unit { _unit = unit; [self setNeedsDisplay]; }
/// No glow cards in the luxury look.
- (void)setGlow:(UIColor *)hue on:(BOOL)on {}
- (void)onTap:(UITapGestureRecognizer *)g {}
- (void)refresh {}
@end

// ── Light tile ───────────────────────────────────────────────────────────

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

/// The colour-temperature sheet (press and hold a colour bulb's tile) —
/// port of _KelvinSheet: the name and kelvin, a thick warm → cool slider,
/// and the presets, over a dimmed screen. Tap outside to close.
@interface NCKelvinSheet : UIView
- (instancetype)initWithTile:(NCLightTile *)tile;
- (void)showIn:(UIView *)host;
@end

/// A light (the luxury look, Nov 2026): a tall black tile, the bulb drawn
/// in a thin line, the name and "ON · 100%" at its foot. On, its edge,
/// icon and state turn gold, with a faint gold glow and a dot top-right.
/// A tap toggles it (and makes it the dimmer row's light); press and hold
/// a colour bulb for its colour temperature.
@interface NCLightTile : NCTile <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NCLight *light;
@property (nonatomic) BOOL known, on, offline, busy;
@property (nonatomic) NSInteger level;  // -1 unknown
/// The kelvin being set in the sheet, or 0.
@property (nonatomic) NSInteger dragKelvin;
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
    _spinner.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [self addSubview:_spinner];
    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onHold:)];
    hold.minimumPressDuration = 0.4;
    hold.delegate = self;
    [self addGestureRecognizer:hold];
  }
  return self;
}

- (NSInteger)kelvin { return self.dragKelvin ?: self.light.kelvin; }

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

/// Every redraw of the tile redraws the dimmer row too (it shows this
/// light's level when it's the row's light).
- (void)setNeedsDisplay {
  [super setNeedsDisplay];
  [self.panel lightChanged];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _spinner.center = CGPointMake(self.bounds.size.width - 25, 23);
}

- (void)drawRect:(CGRect)rect {
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  if (W <= 0) return;
  BOOL on = self.known && self.on, night = self.night;
  UIColor *gold = NCLuxGold(night), *muted = NCLuxMuted();
  CGFloat radius = 24;
  if (on) {
    NCLuxCard(self.bounds, radius, alpha(gold, 0.6), alpha(gold, 0.10), 0.6);
    // A faint gold glow from the upper left (radial 120% × 90% at 30% 20%).
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:radius - 1] addClip];
    CGContextTranslateCTM(ctx, W * 0.3, H * 0.2);
    CGContextScaleCTM(ctx, 1, (H * 0.9) / (W * 1.2));
    NSArray *cols = @[(id)alpha(gold, 0.10).CGColor, (id)alpha(gold, 0).CGColor];
    CGFloat stops[] = {0, 0.6};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cols, stops);
    CGContextDrawRadialGradient(ctx, g, CGPointZero, 0, CGPointZero, W * 1.2, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(ctx);
    if (!self.busy) NCLuxDot(CGPointMake(W - 25, 23), 3, gold, 9);
  } else if (self.offline) {
    NCLuxCard(self.bounds, radius, alpha(NCRGB(kRed), 0.45), alpha(NCRGB(kRed), 0.06), 0.6);
  } else {
    NCLuxCard(self.bounds, radius, NCRGBA(kLuxIvory, 0.22), NCRGBA(kLuxIvory, 0.04), 0.6);
  }
  NCLuxIcon(NCLuxIconBulb, CGRectMake(24, 22, 36, 36), on ? gold : muted, 1);

  NSString *status = self.offline ? @"OFFLINE"
                   : !self.known ? @"CONNECTING…"
                   : !on ? @"OFF"
                   : self.light.dimmable && self.level >= 0 ? [NSString stringWithFormat:@"ON · %ld%%", (long)self.level]
                   : @"ON";
  NSDictionary *sa = NCLuxLabel(10.5, 3, self.offline ? NCRGB(kRed) : on ? gold : muted);
  UIFont *nf = NCLuxFont(@"Inter-Regular", 18);
  CGFloat sy = H - 22 - NCLuxLine(sa[NSFontAttributeName]), ny = sy - 5 - NCLuxLine(nf);
  drawLine(self.light.name, nf, NCLuxIvory(night), CGRectMake(24, ny, W - 48, NCLuxLine(nf)));
  NCLuxDraw(status, sa, 24, sy);
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

/// Press and hold a colour bulb's tile for its sheet; nothing else here
/// begins on a hold.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
  if (![g isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
  return self.light.hasKelvin && self.known;
}

- (void)onHold:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan || !self.window) return;
  NCKelvinSheet *sheet = [[NCKelvinSheet alloc] initWithTile:self];
  [sheet showIn:self.window];
}

- (void)onTap:(UITapGestureRecognizer *)g {
  [self.panel lightTapped:self];
  if (self.busy || !self.known) return;
  BOOL to = !self.on;
  [self run:^BOOL(NCLight *l) { return [l setPower:to]; } expectOn:to level:-1 done:nil];
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
  NCLuxPlainCard(card, 24, 0.24);

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
  NSDictionary *ka = textAttrs(inter(@"Regular", u * 1.5), hue, 0);
  NSString *kt = [NSString stringWithFormat:@"%ld K", (long)_kelvin];
  CGSize ks = [kt sizeWithAttributes:ka];
  [kt drawAtPoint:CGPointMake(CGRectGetMaxX(in) - ks.width, CGRectGetMidY(bulb) - ks.height / 2) withAttributes:ka];
  CGFloat tx = CGRectGetMaxX(bulb) + u * 0.9, tw = CGRectGetMaxX(in) - ks.width - u * 0.5 - tx;
  UIFont *nf = inter(@"Medium", u * 1.15), *sf = inter(@"Medium", u * 0.75);
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
                 textAttrs(inter(@"Medium", u * 0.85), i == index ? UIColor.blackColor : white(0.75), 0),
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

// ── AC card ──────────────────────────────────────────────────────────────

/// One AC as a wide row (the luxury look, Nov 2026): AIR CON, its name and
/// "OFF · ROOM 29°" on the left; − setpoint + and power on the right.
@interface NCAcTile : NCTile
@property (nonatomic, strong) NCGreeAc *ac;
@property (nonatomic, strong) NCAcState *state;
@property (nonatomic) BOOL offline, busy;
@property (nonatomic) NSInteger pending;  // setpoint being dialled in, or 0
@end

@implementation NCAcTile {
  NSTimer *_send;
  UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithAc:(NCGreeAc *)ac {
  if ((self = [super initWithFrame:CGRectZero])) {
    _ac = ac;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    _spinner.transform = CGAffineTransformMakeScale(0.8, 0.8);
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
- (BOOL)isOn { return self.state.on; }
- (NSInteger)temp { return self.pending ?: (self.state ? self.state.setTemp : 24); }

- (CGRect)powerRect {
  CGFloat H = self.bounds.size.height;
  return CGRectMake(self.bounds.size.width - 12 - 52, (H - 52) / 2, 52, 52);
}
- (CGRect)plusRect { return CGRectOffset(self.powerRect, -8 - 52, 0); }
- (CGRect)tempRect {
  CGRect p = self.plusRect;
  return CGRectMake(p.origin.x - 84, 0, 84, self.bounds.size.height);
}
- (CGRect)minusRect { return CGRectMake(self.tempRect.origin.x - 52, self.plusRect.origin.y, 52, 52); }

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect p = self.powerRect;
  _spinner.center = CGPointMake(CGRectGetMidX(p), CGRectGetMidY(p));
}

- (void)drawRect:(CGRect)rect {
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  if (W <= 0) return;
  BOOL on = self.isOn, night = self.night;
  UIColor *gold = NCLuxGold(night), *muted = NCLuxMuted(), *ivory = NCLuxIvory(night);
  if (self.offline) NCLuxCard(self.bounds, 24, alpha(NCRGB(kRed), 0.45), alpha(NCRGB(kRed), 0.06), 0.6);
  else if (on) NCLuxCard(self.bounds, 24, alpha(gold, 0.55), alpha(gold, 0.08), 0.6);
  else NCLuxCard(self.bounds, 24, NCRGBA(kLuxIvory, 0.24), NCRGBA(kLuxIvory, 0.05), 0.55);

  // AIR CON / the name / the state, as one group centred on the card.
  NSDictionary *la = NCLuxLabel(10.5, 3.5, muted);
  UIFont *nf = NCLuxFont(@"Inter-Regular", 17);
  NSString *room = self.state && self.state.roomTemp != NSNotFound
      ? [NSString stringWithFormat:@" · ROOM %ld°", (long)self.state.roomTemp] : @"";
  NSString *status = self.offline ? @"OFFLINE"
                   : !self.state ? @"CONNECTING…"
                   : on ? [kAcModeNames[self.mode].uppercaseString stringByAppendingString:room]
                   : [@"OFF" stringByAppendingString:room];
  NSDictionary *sa = NCLuxLabel(10, 3, self.offline ? NCRGB(kRed) : on ? gold : muted);
  CGFloat l1 = NCLuxLine(la[NSFontAttributeName]), l2 = NCLuxLine(nf), l3 = NCLuxLine(sa[NSFontAttributeName]);
  CGFloat y = (H - (l1 + 5 + l2 + 5 + l3)) / 2, textW = self.minusRect.origin.x - 26 - 8;
  NCLuxDraw(@"AIR CON", la, 26, y);
  drawLine(self.ac.name, nf, ivory, CGRectMake(26, y + l1 + 5, textW, l2));
  NCLuxDraw(status, sa, 26, y + l1 + 5 + l2 + 5);

  // − 24° + and power.
  CGRect m = self.minusRect, p = self.plusRect, t = self.tempRect, pw = self.powerRect;
  NCLuxIcon(NCLuxIconMinus, CGRectMake(CGRectGetMidX(m) - 9, CGRectGetMidY(m) - 9, 18, 18), muted, 1.2 * 24 / 18);
  NCLuxIcon(NCLuxIconPlus, CGRectMake(CGRectGetMidX(p) - 9, CGRectGetMidY(p) - 9, 18, 18), muted, 1.2 * 24 / 18);
  NSString *temp = [NSString stringWithFormat:@"%ld°", (long)self.temp];
  NSDictionary *ta = NCLuxAttrs(NCLuxFont(@"Jost-Light", 48), self.pending ? gold : ivory, 0);
  NCLuxDrawMid(temp, ta, CGRectGetMidX(t) - NCLuxWidth(temp, ta) / 2, CGRectGetMidY(t));
  if (!self.busy)
    NCLuxIcon(NCLuxIconPower, CGRectMake(CGRectGetMidX(pw) - 10, CGRectGetMidY(pw) - 10, 20, 20), on ? gold : muted,
              1.2 * 24 / 20);
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

/// Moves the setpoint now and tells the unit 0.7 s after the last change,
/// so a run of taps is one command.
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
  if (CGRectContainsPoint(CGRectInset(self.powerRect, -4, -20), p)) [self togglePower];
  else if (CGRectContainsPoint(CGRectInset(self.minusRect, -4, -20), p)) [self dial:self.temp - 1];
  else if (CGRectContainsPoint(CGRectInset(self.plusRect, 0, -20), p)) [self dial:self.temp + 1];
}

@end

// ── TV strip ─────────────────────────────────────────────────────────────

/// A TV or a set-top box as a slim pill (the luxury look, Nov 2026): its
/// name and state on the left; volume − (OK) volume + and power on the
/// right. The Hisense TV is [tv]; an Android TV box (Beyond TV, Haam's
/// TCL) is [box] — one of the two per strip.
@interface NCTvCard : NCTile
@property (nonatomic, strong) NCHisenseTv *tv;
@property (nonatomic, strong) NCTvBox *box;
/// Volume buttons on this strip (a box's only when its room has no TV).
@property (nonatomic) BOOL hasVolume;
/// The gold play / pause ring — the M&M's Room TV's OK (a TV with no box).
@property (nonatomic) BOOL hasOk;
@end

@implementation NCTvCard {
  BOOL _known, _on;
  NSString *_problem;
  NSDate *_switched;
}

- (CGRect)powerRect {
  CGFloat H = self.bounds.size.height;
  return CGRectMake(self.bounds.size.width - 10 - 48, (H - 48) / 2, 48, 48);
}
- (CGRect)plusRect { return self.hasVolume ? CGRectOffset(self.powerRect, -6 - 48, 0) : CGRectZero; }
- (CGRect)okRect {
  if (!self.hasOk) return CGRectZero;
  CGRect p = self.plusRect;
  CGFloat H = self.bounds.size.height;
  return CGRectMake(p.origin.x - 6 - 42, (H - 42) / 2, 42, 42);
}
- (CGRect)minusRect {
  if (!self.hasVolume) return CGRectZero;
  CGFloat x = self.hasOk ? self.okRect.origin.x - 6 : self.plusRect.origin.x;
  return CGRectMake(x - 48, self.plusRect.origin.y, 48, 48);
}
- (BOOL)live { return _known && _on; }

- (void)drawRect:(CGRect)rect {
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  if (W <= 0) return;
  BOOL night = self.night, on = self.live;
  UIColor *gold = NCLuxGold(night), *muted = NCLuxMuted();
  if (on) NCLuxCard(self.bounds, H / 2, alpha(gold, 0.45), alpha(gold, 0.06), 0.6);
  else NCLuxCard(self.bounds, H / 2, NCRGBA(kLuxIvory, 0.18), NCRGBA(kLuxIvory, 0.04), 0.6);

  NSString *name = (self.tv ? self.tv.name : self.box.name).uppercaseString;
  NSString *state = _problem ? _problem.uppercaseString : !_known ? @"CONNECTING…" : on ? @"ON" : @"OFF";
  NSDictionary *la = NCLuxLabel(10.5, 3.5, muted);
  CGFloat left = (self.hasVolume ? self.minusRect.origin.x : self.powerRect.origin.x) - 26 - 8;
  NSMutableAttributedString *label = [[NSMutableAttributedString alloc] initWithString:[name stringByAppendingString:@" · "]
                                                                            attributes:la];
  [label appendAttributedString:[[NSAttributedString alloc]
                                    initWithString:state
                                        attributes:NCLuxLabel(10.5, 3.5, _problem ? NCRGB(kRed) : on ? gold : muted)]];
  NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  [label addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, label.length)];
  CGFloat lh = NCLuxLine(la[NSFontAttributeName]);
  [label drawInRect:CGRectMake(26, (H - lh) / 2, left, lh)];

  UIColor *keys = on ? muted : alpha(muted, 0.35);
  if (self.hasVolume) {
    CGRect m = self.minusRect, p = self.plusRect;
    NCLuxIcon(NCLuxIconMinus, CGRectMake(CGRectGetMidX(m) - 8, CGRectGetMidY(m) - 8, 16, 16), keys, 1.2 * 24 / 16);
    NCLuxIcon(NCLuxIconPlus, CGRectMake(CGRectGetMidX(p) - 8, CGRectGetMidY(p) - 8, 16, 16), keys, 1.2 * 24 / 16);
  }
  if (self.hasOk) {
    CGRect o = self.okRect;
    UIColor *ring = on ? gold : alpha(gold, 0.35);
    UIBezierPath *c = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(o, 0.5, 0.5)];
    c.lineWidth = 1;
    [ring setStroke];
    [c stroke];
    NCLuxIcon(NCLuxIconPlay, CGRectMake(CGRectGetMidX(o) - 7, CGRectGetMidY(o) - 7, 14, 14), ring, 1.4 * 24 / 14);
  }
  CGRect pw = self.powerRect;
  NCLuxIcon(NCLuxIconPower, CGRectMake(CGRectGetMidX(pw) - 9, CGRectGetMidY(pw) - 9, 18, 18),
            on ? gold : _known ? muted : alpha(muted, 0.5), 1.2 * 24 / 18);
}

- (void)refresh {
  NCHisenseTv *tv = self.tv;
  // The TV's broker takes a few seconds to go down or come up: polls just
  // after a tap would undo it.
  if (tv && !(_switched && -_switched.timeIntervalSinceNow < 20)) {
    dispatch_async(tv.queue, ^{
      BOOL on = [tv isOn];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_switched && -self->_switched.timeIntervalSinceNow < 20) return;
        self->_known = YES;
        self->_on = on;
        [self setNeedsDisplay];
      });
    });
  }
  NCTvBox *box = self.box;
  // Not while a tap settles, nor while it boots after a Wake-on-LAN (off
  // the network until it's up).
  if (box && !(_switched && -_switched.timeIntervalSinceNow < 6)
      && !(box.wokeAt && -box.wokeAt.timeIntervalSinceNow < 45)) {
    NSDate *woke = box.wokeAt;
    dispatch_async(box.queue, ^{
      BOOL on = NO;
      NCBoxResult r = [box readOn:&on];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (r == NCBoxOk) {
          self->_known = YES;
          self->_on = on;
          self->_problem = nil;
          if (woke) {
            box.wokeAt = nil;
            // Its boot time is up and it's still not there: the magic
            // packet didn't reach it, or it can't wake on LAN.
            if (!on) [self flashProblem:@"Didn't wake — use the remote"];
          }
        } else {
          self->_problem = r == NCBoxNeedsApproval ? @"Allow on TV" : @"Offline";
        }
        [self setNeedsDisplay];
      });
    });
  }
}

/// Shows [text] in place of the state for 4 s.
- (void)flashProblem:(NSString *)text {
  _problem = text;
  [self setNeedsDisplay];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if ([self->_problem isEqualToString:text]) {
      self->_problem = nil;
      [self setNeedsDisplay];
    }
  });
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  CGFloat slop = -4;
  if (CGRectContainsPoint(CGRectInset(self.powerRect, slop, slop), p)) {
    if (!_known) return;
    BOOL to = !_on;
    _on = to;
    _switched = [NSDate date];
    [self setNeedsDisplay];
    if (self.box) {
      NCTvBox *box = self.box;
      dispatch_async(box.queue, ^{
        NCBoxResult r = [box setPower:to];
        if (r != NCBoxOk) dispatch_async(dispatch_get_main_queue(), ^{
          self->_switched = nil;
          if (to && !box.canWake) {
            // Asleep and off the network: only its remote wakes it.
            self->_on = NO;
            [self flashProblem:@"Use the remote to turn on"];
            return;
          }
          [self refresh];
        });
      });
    } else {
      NCHisenseTv *tv = self.tv;
      dispatch_async(tv.queue, ^{
        if (![tv setPower:to]) dispatch_async(dispatch_get_main_queue(), ^{
          self->_switched = nil;
          [self refresh];
        });
      });
    }
  } else if (self.hasOk && CGRectContainsPoint(CGRectInset(self.okRect, -3, -3), p) && self.live) {
    // Play / pause on the box behind the TV (MEDIA_BOX): the TV's own OK
    // never reaches its HDMI input. Without one, the TV's OK.
    NCTvBox *media = NCConfiguredMediaBoxes()[self.tv.name];
    if (media) {
      dispatch_async(media.queue, ^{ [media sendKey:@"KEYCODE_MEDIA_PLAY_PAUSE"]; });
    } else {
      NCHisenseTv *tv = self.tv;
      dispatch_async(tv.queue, ^{ [tv sendKey:@"KEY_OK"]; });
    }
  } else if (self.hasVolume && self.live) {
    BOOL down = CGRectContainsPoint(CGRectInset(self.minusRect, slop, slop), p);
    BOOL up = CGRectContainsPoint(CGRectInset(self.plusRect, slop, slop), p);
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

/// A section's small-caps label ("LIGHTS", "ENTER PASSCODE").
@interface NCCaption : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIColor *color;  // default muted
@end

@implementation NCCaption
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
  }
  return self;
}
- (void)setText:(NSString *)text { _text = [text copy]; [self setNeedsDisplay]; }
- (void)setColor:(UIColor *)color { _color = color; [self setNeedsDisplay]; }
+ (CGFloat)height { return NCLuxLine(NCLuxFont(@"Inter-Regular", 10.5)); }
- (void)drawRect:(CGRect)rect {
  NCLuxDraw(self.text.uppercaseString ?: @"", NCLuxLabel(10.5, 3.5, self.color ?: NCLuxMuted()), 4, 0);
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
  else if (!self.down.count) { rightIcon = @"shield"; rightColor = NCLuxGold(self.night); right = @"All systems nominal"; }
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

/// A Sonoff switch: a small tile with a thin fan or lamp icon and its
/// name. Not wired up yet — a tap does nothing.
@interface NCSwitchTile : NCTile
@property (nonatomic, strong) NCSonoffSwitch *sw;
/// The name shown: without the room's prefix ("Haam's Ceiling 1" →
/// "Ceiling 1" in Haam's Room).
@property (nonatomic, copy) NSString *label;
@end

@implementation NCSwitchTile
- (void)drawRect:(CGRect)rect {
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  if (W <= 0) return;
  NCLuxCard(self.bounds, 18, NCRGBA(kLuxIvory, 0.18), NCRGBA(kLuxIvory, 0.04), 0.6);
  // Not set up yet: greyed a little further.
  UIColor *c = self.sw.isSetUp ? NCLuxMuted() : alpha(NCLuxMuted(), 0.7);
  NSString *n = self.sw.name.lowercaseString;
  NSDictionary *na = NCLuxAttrs(NCLuxFont(@"Inter-Regular", 12), c, 0);
  NSString *name = self.label ?: self.sw.name;
  CGFloat nw = MIN(NCLuxWidth(name, na), W - 20 - 10 - 20);
  CGFloat x = (W - (20 + 10 + nw)) / 2, cy = H / 2;
  CGRect icon = CGRectMake(x, cy - 10, 20, 20);
  if (self.sw.isFan) NCLuxIcon(NCLuxIconFan, icon, c, 1.1);
  else if ([n containsString:@"ceiling"]) NCLuxIcon(NCLuxIconCeiling, icon, c, 1.1);
  else {
    NSString *g = [n containsString:@"wall"] ? @"walllight"
                : [n containsString:@"cabinet"] ? @"cabinet"
                : [n containsString:@"hanging"] ? @"hanging"
                : @"lamp";
    [NCGlyphs.shared drawIcon:g in:CGRectInset(icon, 1, 1) color:c];
  }
  UIFont *f = na[NSFontAttributeName];
  drawLine(name, f, c, CGRectMake(x + 30, cy - NCLuxLine(f) / 2, nw, NCLuxLine(f)));
}
@end

// ── Dimmer row ───────────────────────────────────────────────────────────

/// Under the light tiles: the light it dims in gold (tap to move on to the
/// next dimmable light) and 1 / 25 / 50 / 100 — the light's nearest level
/// ivory over a glowing gold line. A level turns the light on with it.
@interface NCDimmerRow : UIView
@property (nonatomic, weak) NCLightTile *target;
@property (nonatomic, copy) NSArray<NCLightTile *> *lights;  // the dimmable ones
@property (nonatomic) BOOL night;
@end

@implementation NCDimmerRow

static const CGFloat kPresetW[] = {64, 64, 64, 70};

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}

- (CGRect)presetRect:(int)i {
  CGFloat x = self.bounds.size.width - 12;
  for (int k = 3; k >= i; k--) x -= kPresetW[k];
  return CGRectMake(x, (self.bounds.size.height - 48) / 2, kPresetW[i], 48);
}

- (void)drawRect:(CGRect)rect {
  CGFloat H = self.bounds.size.height;
  NCLuxPlainCard(self.bounds, H / 2, 0.24);
  NCLightTile *t = self.target;
  if (!t) return;
  UIColor *gold = NCLuxGold(self.night), *muted = NCLuxMuted();
  NSDictionary *na = NCLuxLabel(10.5, 3.5, gold);
  NSString *name = t.light.name.uppercaseString;
  CGFloat nameRoom = [self presetRect:0].origin.x - 26 - (self.lights.count > 1 ? 19 : 0) - 4;
  CGFloat nw = MIN(NCLuxWidth(name, na), nameRoom);
  UIFont *nf = na[NSFontAttributeName];
  NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  NSMutableDictionary *nat = [na mutableCopy];
  nat[NSParagraphStyleAttributeName] = ps;
  [name drawInRect:CGRectMake(26, H / 2 - NCLuxLine(nf) / 2, nw, NCLuxLine(nf)) withAttributes:nat];
  if (self.lights.count > 1)
    NCLuxIcon(NCLuxIconUpDown, CGRectMake(26 + nw + 8, H / 2 - 5.5, 11, 11), muted, 1.5 * 24 / 11);

  NSInteger index = -1;
  if (t.known && t.on && t.level >= 0) {
    NSInteger best = 0;
    for (int i = 1; i < 4; i++)
      if (labs(kPresets[i] - t.level) < labs(kPresets[best] - t.level)) best = i;
    index = best;
  }
  for (int i = 0; i < 4; i++) {
    CGRect r = [self presetRect:i];
    BOOL on = i == index;
    NSString *s = [NSString stringWithFormat:@"%ld", (long)kPresets[i]];
    NSDictionary *a = NCLuxAttrs(NCLuxFont(on ? @"Inter-Regular" : @"Inter-Light", 15),
                                 on ? NCLuxIvory(self.night) : alpha(muted, t.busy ? 0.5 : 1), 1);
    UIFont *f = a[NSFontAttributeName];
    CGFloat lh = NCLuxLine(f), tw = NCLuxWidth(s, a);
    CGFloat cy = CGRectGetMidY(r), top = on ? cy - (lh + 6 + 1) / 2 : cy - lh / 2;
    NCLuxDraw(s, a, CGRectGetMidX(r) - tw / 2, top);
    if (on) {
      CGContextRef ctx = UIGraphicsGetCurrentContext();
      CGContextSaveGState(ctx);
      CGContextSetShadowWithColor(ctx, CGSizeZero, 7, gold.CGColor);
      [gold setFill];
      UIRectFill(CGRectMake(CGRectGetMidX(r) - 11, top + lh + 6, 22, 1));
      CGContextRestoreGState(ctx);
    }
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  NCLightTile *t = self.target;
  if (!t) return;
  if (p.x < [self presetRect:0].origin.x) {
    // The name: on to the next dimmable light, nothing switched.
    NSUInteger i = [self.lights indexOfObject:t];
    if (self.lights.count > 1) self.target = self.lights[(i == NSNotFound ? 0 : i + 1) % self.lights.count];
    [self setNeedsDisplay];
    return;
  }
  if (t.busy) return;
  for (int i = 0; i < 4; i++)
    if (CGRectContainsPoint(CGRectInset([self presetRect:i], 0, -4), p)) {
      NSInteger pct = kPresets[i];
      [t run:^BOOL(NCLight *l) { return [l setBrightness:pct]; } expectOn:YES level:pct done:nil];
      return;
    }
}

@end

@implementation NCPanelView {
  NCRoom *_room;
  NCNote *_note;
  NCCaption *_lightsLabel;
  NSArray<NCLightTile *> *_lightTiles;
  NCDimmerRow *_dimmer;
  NSArray<NCAcTile *> *_acTiles;
  NSArray<NCSwitchTile *> *_switchTiles;  // fans first, then lights
  NSArray<NCTvCard *> *_tvCards;
  NSTimer *_poll;
}

- (instancetype)initWithRoom:(NCRoom *)room {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _room = room;
    NSMutableArray *lt = [NSMutableArray array], *dimmable = [NSMutableArray array];
    for (NCLight *l in room.lights) {
      NCLightTile *t = [[NCLightTile alloc] initWithLight:l];
      t.panel = self;
      [self addSubview:t];
      [lt addObject:t];
      if (l.dimmable) [dimmable addObject:t];
    }
    _lightTiles = lt;
    if (lt.count) {
      _lightsLabel = [NCCaption new];
      _lightsLabel.text = @"Lights";
      [self addSubview:_lightsLabel];
    }
    if (dimmable.count) {
      _dimmer = [NCDimmerRow new];
      _dimmer.lights = dimmable;
      _dimmer.target = dimmable.firstObject;
      [self addSubview:_dimmer];
    }
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
    // A strip per TV and per box. Volume goes to the TV when there is one;
    // the TV's OK (play / pause) only where there's no box (M&M's Room).
    NSMutableArray *tc = [NSMutableArray array];
    for (NCHisenseTv *tv in room.tvs) {
      NCTvCard *c = [NCTvCard new];
      c.tv = tv;
      c.hasVolume = YES;
      c.hasOk = room.boxes.count == 0;
      [tc addObject:c];
    }
    for (NCTvBox *box in room.boxes) {
      NCTvCard *c = [NCTvCard new];
      c.box = box;
      c.hasVolume = room.tvs.count == 0;
      [tc addObject:c];
    }
    for (NCTvCard *c in tc) {
      c.panel = self;
      [self addSubview:c];
    }
    _tvCards = tc;
    // Scenes only in the room that has their devices.
    BOOL scenes = NO;
    for (NCLightTile *t in _lightTiles) {
      NSString *n = t.light.name.lowercaseString;
      if ([n containsString:@"white"] || [n containsString:@"warm"]) scenes = YES;
    }
    for (NCAcTile *t in _acTiles)
      if ([t.ac.name.lowercaseString isEqualToString:@"bedroom"]) scenes = YES;
    _hasScenes = scenes;
    if (room.isEmpty) {
      _note = [NCNote new];
      _note.text = @"Nothing to control here yet";
      [self addSubview:_note];
    }
  }
  return self;
}

- (NSArray<NCTile *> *)cards {
  NSMutableArray *all = [NSMutableArray arrayWithArray:_lightTiles];
  [all addObjectsFromArray:_switchTiles];
  [all addObjectsFromArray:_acTiles];
  [all addObjectsFromArray:_tvCards];
  return all;
}

- (void)statusChanged {}

- (void)lightChanged { [_dimmer setNeedsDisplay]; }

- (void)lightTapped:(NCLightTile *)tile {
  if (!tile.light.dimmable || _dimmer.target == tile) return;
  _dimmer.target = tile;
  [_dimmer setNeedsDisplay];
}

- (void)setNight:(BOOL)night {
  _night = night;
  _note.night = night;
  [_note setNeedsDisplay];
  _dimmer.night = night;
  [_dimmer setNeedsDisplay];
  for (NCTile *t in self.cards) t.night = night;
}

/// Standby: nothing to change — the page is black already.
- (void)setStandby:(BOOL)standby {
  _standby = standby;
}

static const CGFloat kGap = 14, kLightH = 150, kDimmerH = 56, kSwitchH = 56, kSwitchGap = 10, kAcH = 96, kTvH = 56;

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

/// Lays everything out top down; returns the height used.
- (CGFloat)layoutAt:(CGFloat)w apply:(BOOL)apply {
  CGFloat y = 0;
  BOOL first = YES;
  // Each section starts a gap below the last.
  if (_lightTiles.count) {
    if (apply) _lightsLabel.frame = CGRectMake(0, y, w, [NCCaption height]);
    y += [NCCaption height];
    CGFloat tw = (w - kGap) / 2;
    for (NSUInteger i = 0; i < _lightTiles.count; i++) {
      if (i % 2 == 0) y += kGap + (i ? kLightH : 0);
      if (apply) _lightTiles[i].frame = CGRectMake((i % 2) * (tw + kGap), y, tw, kLightH);
    }
    y += kLightH;
    first = NO;
  }
  if (_dimmer) {
    y += first ? 0 : kGap;
    if (apply) _dimmer.frame = CGRectMake(0, y, w, kDimmerH);
    y += kDimmerH;
    first = NO;
  }
  CGFloat sw = (w - 2 * kSwitchGap) / 3;
  NSArray *rows = self.switchRows;
  for (NSUInteger r = 0; r < rows.count; r++) {
    y += first ? 0 : r == 0 ? kGap : kSwitchGap;
    NSArray<NCSwitchTile *> *row = rows[r];
    for (NSUInteger i = 0; i < row.count; i++)
      if (apply) row[i].frame = CGRectMake(i * (sw + kSwitchGap), y, sw, kSwitchH);
    y += kSwitchH;
    first = NO;
  }
  for (NCAcTile *t in _acTiles) {
    y += first ? 0 : kGap;
    if (apply) t.frame = CGRectMake(0, y, w, kAcH);
    y += kAcH;
    first = NO;
  }
  for (NCTvCard *c in _tvCards) {
    y += first ? 0 : kGap;
    if (apply) c.frame = CGRectMake(0, y, w, kTvH);
    y += kTvH;
    first = NO;
  }
  if (_note) {
    if (apply) {
      _note.unit = 19;
      _note.frame = CGRectMake(0, y, w, 76);
    }
    y += 76;
  }
  return y;
}

- (CGFloat)heightForWidth:(CGFloat)width { return [self layoutAt:width apply:NO]; }

- (void)layoutForWidth:(CGFloat)width {
  [self layoutAt:width apply:YES];
  // The colour-temperature sheet still sizes itself in the old units.
  for (NCTile *t in self.cards) t.unit = width / 26;
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
  for (NCTile *t in _tvCards) [t refresh];
}

- (BOOL)isDialAt:(CGPoint)point {
  // A colour bulb's tile: press and hold opens its sheet, not the dimmer.
  for (NCLightTile *t in _lightTiles)
    if (t.light.hasKelvin && CGRectContainsPoint(t.bounds, [self convertPoint:point toView:t])) return YES;
  return NO;
}

/// GN (good night): White Light off, Warm Light on at 1%, Bedroom AC on at
/// 24°. GM (good morning): Bedroom AC off, Warm Light 100%, White Light on.
/// All at once; a device that fails just shows Offline.
- (void)runScene:(BOOL)goodNight {
  if (self.running) return;
  NCLightTile *(^light)(NSString *) = ^NCLightTile *(NSString *word) {
    for (NCLightTile *t in self->_lightTiles)
      if ([t.light.name.lowercaseString containsString:word]) return t;
    return nil;
  };
  NCLightTile *whiteTile = light(@"white"), *warmTile = light(@"warm");
  NCAcTile *acTile = _acTiles.firstObject;
  for (NCAcTile *t in _acTiles)
    if ([t.ac.name.lowercaseString isEqualToString:@"bedroom"]) acTile = t;

  _running = goodNight ? @"gn" : @"gm";
  if (self.onSceneChange) self.onSceneChange();
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
    self->_running = nil;
    if (self.onSceneChange) self.onSceneChange();
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
// ── The house (home page) ───────────────────────────────────────────────
// Port of _HouseView: the apartment render (blueprint.png, the user's own)
// with a label hung from a stem at each room — tap the floor or the label
// to open it — a glow pooling in a room with something on (amber by the
// brightest light, a cyan halo while an AC cools, violet on a TV that's
// on), and a sideways drag that turns the plan in perspective and lets it
// spring back. The render is one texture, so the tilt is cheap even here.

/// Where a room sits on the render, in fractions of the image — the same
/// table as _plots in lib/main.dart.
typedef struct {
  const char *keys;     // words in a room's name that put it here, '|'-separated
  const char *generic;  // words that only place a room nothing else claimed
  CGPoint floor[6];     // the floor to tap
  int corners;
  CGPoint centre, foot;  // the glow; where the label's stem lands
  BOOL right;            // the label hangs to the left of its stem
  CGPoint screens[2];    // TVs, lit when a screen is on
  int nScreens;
} NCPlot;

static const NCPlot kPlots[] = {
    // The smaller bedroom, top left.
    {"haam", "bed", {{0.060, 0.050}, {0.450, 0.045}, {0.450, 0.410}, {0.055, 0.415}}, 4,
     {0.27, 0.23}, {0.20, 0.36}, NO, {{0.105, 0.265}}, 1},
    // The master bedroom, top right.
    {"m&m|master", "bed", {{0.680, 0.050}, {0.955, 0.045}, {0.955, 0.550}, {0.680, 0.545}}, 4,
     {0.82, 0.24}, {0.73, 0.47}, YES, {{0.905, 0.275}}, 1},
    // The sitting room, bottom left, with the hall.
    {"sitting|living|lounge", "", {{0.055, 0.420}, {0.620, 0.415}, {0.620, 0.860}, {0.055, 0.860}}, 4,
     {0.33, 0.63}, {0.19, 0.76}, NO, {{0.115, 0.635}}, 1},
    // The kitchen, bottom right.
    {"kitchen", "", {{0.630, 0.600}, {0.955, 0.600}, {0.955, 0.920}, {0.630, 0.900}}, 4,
     {0.80, 0.80}, {0.76, 0.82}, YES, {{0, 0}}, 0},
};
enum { kPlotCount = sizeof(kPlots) / sizeof(kPlots[0]) };
/// The render's width over its height, and so the house's height in units.
static const CGFloat kBlueprintAspect = 1448.0 / 1086.0, kHouseU = 26 / (1448.0 / 1086.0);

static BOOL plotMatches(const char *words, NSString *text) {
  if (!words[0]) return NO;
  for (NSString *w in [@(words) componentsSeparatedByString:@"|"])
    if ([text containsString:w]) return YES;
  return NO;
}

/// Each room's plot (-1 for none): the first unclaimed one a word of its
/// name picks, then the generic words ("bed") for what's left.
static NSArray<NSNumber *> *plotRooms(NSArray<NCRoom *> *rooms) {
  NSMutableArray *plotOf = [NSMutableArray array];
  for (NSUInteger i = 0; i < rooms.count; i++) [plotOf addObject:@(-1)];
  BOOL used[kPlotCount] = {NO};
  for (int pass = 0; pass < 2; pass++) {
    for (NSUInteger i = 0; i < rooms.count; i++) {
      if ([plotOf[i] intValue] >= 0) continue;
      NSString *text = [NSString stringWithFormat:@"%@ %@", rooms[i].name ?: @"", rooms[i].subtitle ?: @""].lowercaseString;
      for (int p = 0; p < kPlotCount; p++) {
        if (used[p]) continue;
        if (plotMatches(pass == 0 ? kPlots[p].keys : kPlots[p].generic, text)) {
          plotOf[i] = @(p);
          used[p] = YES;
          break;
        }
      }
    }
  }
  return plotOf;
}

static BOOL plotContains(const NCPlot *p, CGPoint pt) {
  BOOL inside = NO;
  for (int i = 0, j = p->corners - 1; i < p->corners; j = i++) {
    CGPoint a = p->floor[i], b = p->floor[j];
    if ((a.y > pt.y) != (b.y > pt.y) && pt.x < (b.x - a.x) * (pt.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}

static void fillRadial(CGContextRef ctx, NSArray<UIColor *> *colors, const CGFloat *stops, CGPoint c, CGFloat r) {
  NSMutableArray *cg = [NSMutableArray array];
  for (UIColor *col in colors) [cg addObject:(id)col.CGColor];
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, stops);
  CGContextDrawRadialGradient(ctx, g, c, 0, c, r, 0);
  CGGradientRelease(g);
  CGColorSpaceRelease(space);
}

/// The render with every channel scaled (the dimmed and night looks:
/// _HouseView's colour matrices), at a size the panel can use.
static UIImage *tintedRender(UIImage *src, CGFloat r, CGFloat g, CGFloat b) {
  CGSize size = CGSizeMake(1000, round(1000 / kBlueprintAspect));
  CGRect rect = {CGPointZero, size};
  UIGraphicsBeginImageContextWithOptions(size, NO, 1);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  [src drawInRect:rect];
  // Multiply the colour, then cut the result back to the render's shape
  // (the multiply paints the clear parts too).
  CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
  CGContextSetRGBFillColor(ctx, r, g, b, 1);
  CGContextFillRect(ctx, rect);
  [src drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1];
  UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return out;
}

/// A room's callout: its number and name (and a lock when it asks for a
/// code), then what's on in it — or what's in it when nothing is.
@interface NCRoomLabel : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *name, *meta;
@property (nonatomic) BOOL locked, lit, night;
@property (nonatomic, strong) UIColor *hue;
- (CGSize)sizeForMaxWidth:(CGFloat)maxWidth;
@end

@implementation NCRoomLabel

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;  // the house handles the tap
  }
  return self;
}

- (UIFont *)numberFont { return inter(@"Medium", self.unit * 0.56); }
- (UIFont *)nameFont { return inter(@"Medium", self.unit * 0.74); }
- (UIFont *)metaFont { return inter(@"Medium", self.unit * 0.56); }
- (NSString *)number { return [NSString stringWithFormat:@"%02ld", (long)(self.index + 1)]; }

- (CGSize)sizeForMaxWidth:(CGFloat)maxWidth {
  CGFloat u = self.unit;
  CGFloat top = [self.number sizeWithAttributes:@{NSFontAttributeName: self.numberFont}].width + u * 0.5 +
                [self.name sizeWithAttributes:@{NSFontAttributeName: self.nameFont}].width +
                (self.locked ? u * 1.05 : 0);
  CGFloat meta = [self.meta sizeWithAttributes:@{NSFontAttributeName: self.metaFont}].width;
  CGFloat w = MIN(maxWidth, MAX(top, meta) + u * 1.3);
  CGFloat h = u * 0.45 + self.nameFont.lineHeight + u * 0.3 + self.metaFont.lineHeight + u * 0.5;
  return CGSizeMake(ceil(w), ceil(h));
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  CGRect r = CGRectInset(self.bounds, 0.5, 0.5);
  UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:u * 0.55];
  [[NCRGB(0xFF14171B) colorWithAlphaComponent:0.93] setFill];
  [p fill];
  [alpha(self.hue, self.lit ? 0.75 : 0.3) setStroke];
  p.lineWidth = 1;
  [p stroke];
  CGFloat x = u * 0.65, y = u * 0.45, right = self.bounds.size.width - u * 0.65;
  UIFont *nf = self.numberFont, *tf = self.nameFont, *mf = self.metaFont;
  NSString *n = self.number;
  CGFloat nw = [n sizeWithAttributes:@{NSFontAttributeName: nf}].width;
  [n drawAtPoint:CGPointMake(x, y + (tf.lineHeight - nf.lineHeight) / 2 + u * 0.03)
      withAttributes:textAttrs(nf, self.hue, 0)];
  CGFloat nameX = x + nw + u * 0.5, nameW = right - nameX - (self.locked ? u * 1.05 : 0);
  drawLine(self.name, tf, white(self.night ? 0.8 : 1), CGRectMake(nameX, y, nameW, tf.lineHeight));
  if (self.locked) drawIcon(@"lock", CGPointMake(right - u * 0.35, y + tf.lineHeight / 2), u * 0.7, white(0.45));
  drawLine(self.meta, mf, self.lit ? self.hue : NCRGB(0xFF8E939C),
           CGRectMake(x, y + tf.lineHeight + u * 0.3, right - x, mf.lineHeight));
}

@end

/// The plan itself: a contact shadow, the render, the rooms' glows and
/// the labels' stems. The labels sit on it as subviews, and the whole
/// thing is what tilts.
@interface NCHousePlan : UIView
@property (nonatomic) CGFloat unit;
@property (nonatomic, strong) UIImage *image;
/// @[@(x), @(y), @(radius), colour] each, in points; a glow's colour
/// carries its peak alpha. Halos ring a room being cooled.
@property (nonatomic, copy) NSArray<NSArray *> *glows, *halos;
/// @[@(x), @(y), @(length), colour] each.
@property (nonatomic, copy) NSArray<NSArray *> *stems;
@end

@implementation NCHousePlan

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
  }
  return self;
}

- (void)drawRect:(CGRect)rect {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height, u = self.unit;
  // The contact shadow, so the plan sits on the sky rather than floating.
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, w * 0.5, h * 0.86);
  CGContextScaleCTM(ctx, 1, (0.25 * h) / (0.525 * w));
  CGFloat shadowStops[] = {0.3, 1};
  fillRadial(ctx, @[[UIColor colorWithWhite:0 alpha:0.55], [UIColor colorWithWhite:0 alpha:0]], shadowStops,
             CGPointZero, w * 0.525);
  CGContextRestoreGState(ctx);
  [self.image drawInRect:self.bounds];
  CGFloat glowStops[] = {0.08, 1};
  for (NSArray *g in self.glows) {
    UIColor *c = g[3];
    fillRadial(ctx, @[c, alpha(c, 0)], glowStops, CGPointMake([g[0] doubleValue], [g[1] doubleValue]), [g[2] doubleValue]);
  }
  CGFloat haloStops[] = {0.45, 0.78, 1};
  for (NSArray *g in self.halos) {
    UIColor *c = g[3];
    fillRadial(ctx, @[alpha(c, 0), c, alpha(c, 0)], haloStops, CGPointMake([g[0] doubleValue], [g[1] doubleValue]),
               [g[2] doubleValue]);
  }
  for (NSArray *s in self.stems) {
    CGPoint foot = CGPointMake([s[0] doubleValue], [s[1] doubleValue]);
    CGFloat len = [s[2] doubleValue];
    UIColor *c = s[3];
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(foot.x - 0.5, foot.y, 1, len));
    fillGradient(ctx, @[alpha(c, 0.15), alpha(c, 0.85)], NULL, foot, CGPointMake(foot.x, foot.y + len));
    CGContextRestoreGState(ctx);
    [alpha(c, 0.22) setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(foot.x - u * 0.45, foot.y - u * 0.45, u * 0.9, u * 0.9)] fill];
    [c setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(foot.x - u * 0.2, foot.y - u * 0.2, u * 0.4, u * 0.4)] fill];
  }
}

@end

@interface NCHouseView : UIView <UIGestureRecognizerDelegate>
- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms here:(NSInteger)here;
/// NO when the render isn't in the bundle: the home page shows cards.
@property (nonatomic, readonly) BOOL available;
/// Rooms with no place on the render (the home page shows those as cards).
@property (nonatomic, readonly) NSArray<NSNumber *> *unplotted;
@property (nonatomic) CGFloat unit;
@property (nonatomic) BOOL night, dim;
@property (nonatomic, copy) NSArray<NCRoomState *> *states;
@property (nonatomic, copy) void (^onOpen)(NSInteger room);
@end

@implementation NCHouseView {
  NSArray<NCRoom *> *_rooms;
  NSInteger _here;
  NSArray<NSNumber *> *_plotOf;
  UIImage *_render;
  NSMutableDictionary<NSString *, UIImage *> *_tinted;
  UIView *_holder;  // carries the perspective
  NCHousePlan *_plan;
  NSMutableDictionary<NSNumber *, NCRoomLabel *> *_labels;  // by room
  CGFloat _yaw, _yawAtStart;  // -1 (dragged left) to 1
}

- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms here:(NSInteger)here {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _rooms = rooms;
    _here = here;
    _plotOf = plotRooms(rooms);
    _render = [UIImage imageNamed:@"blueprint"];
    _tinted = [NSMutableDictionary dictionary];
    _holder = [UIView new];
    _holder.backgroundColor = UIColor.clearColor;
    CATransform3D perspective = CATransform3DIdentity;
    perspective.m34 = -1.0 / 650;
    _holder.layer.sublayerTransform = perspective;
    [self addSubview:_holder];
    _plan = [NCHousePlan new];
    [_holder addSubview:_plan];
    _labels = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < rooms.count; i++) {
      if ([_plotOf[i] intValue] < 0) continue;
      NCRoomLabel *l = [NCRoomLabel new];
      l.index = (NSInteger)i;
      l.name = rooms[i].name;
      l.locked = rooms[i].pin.length && (NSInteger)i != here;
      [_plan addSubview:l];
      _labels[@(i)] = l;
    }
    [_plan addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    // Sideways only, so it never fights the dimmer's press-and-hold.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    [_plan addGestureRecognizer:pan];
  }
  return self;
}

- (BOOL)available { return _render != nil; }

- (NSArray<NSNumber *> *)unplotted {
  NSMutableArray *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < _rooms.count; i++)
    if ([_plotOf[i] intValue] < 0) [out addObject:@(i)];
  return out;
}

/// The render for the time of day: as is, dimmed after dark, dark red in
/// night mode (made once each).
- (UIImage *)image {
  if (!_render) return nil;
  if (!self.night && !self.dim) return _render;
  NSString *key = self.night ? @"night" : @"dim";
  UIImage *img = _tinted[key];
  if (!img) {
    img = self.night ? tintedRender(_render, 0.42, 0.18, 0.16) : tintedRender(_render, 0.55, 0.55, 0.60);
    _tinted[key] = img;
  }
  return img;
}

- (void)setNight:(BOOL)night {
  _night = night;
  [self refresh];
}

- (void)setDim:(BOOL)dim {
  _dim = dim;
  [self refresh];
}

- (void)setStates:(NSArray<NCRoomState *> *)states {
  _states = [states copy];
  [self refresh];
}

- (void)setUnit:(CGFloat)unit {
  _unit = unit;
  [self refresh];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _holder.frame = self.bounds;
  _plan.frame = self.bounds;
  [self refresh];
}

/// Lays the glows, stems and labels out for the state and size now.
- (void)refresh {
  CGFloat u = self.unit, w = self.bounds.size.width, h = self.bounds.size.height;
  if (u <= 0 || w <= 0) return;
  BOOL night = self.night;
  UIColor *amber = NCHue(kWarm, night);
  CGFloat stem = u * 1.6;
  NSMutableArray *glows = [NSMutableArray array], *halos = [NSMutableArray array], *stems = [NSMutableArray array];
  for (NSUInteger i = 0; i < _rooms.count; i++) {
    int pi = [_plotOf[i] intValue];
    if (pi < 0) continue;
    const NCPlot *plot = &kPlots[pi];
    NCRoomState *s = i < self.states.count ? self.states[i] : nil;
    CGPoint centre = CGPointMake(plot->centre.x * w, plot->centre.y * h);
    if (s.cooling) [halos addObject:@[@(centre.x), @(centre.y), @(w * 0.17), alpha(NCHue(kAcModeHues[1], night), 0.45)]];
    if (s.lightsOn)
      [glows addObject:@[@(centre.x), @(centre.y), @(w * 0.13),
                         alpha(amber, 0.3 + 0.45 * (s.level >= 0 ? s.level : 100) / 100.0)]];
    if (s.screensOn)
      for (int k = 0; k < plot->nScreens; k++)
        [glows addObject:@[@(plot->screens[k].x * w), @(plot->screens[k].y * h), @(w * 0.05),
                           alpha(NCHue(kTvViolet, night), 0.7)]];
    CGPoint foot = CGPointMake(plot->foot.x * w, plot->foot.y * h);
    [stems addObject:@[@(foot.x), @(foot.y), @(stem), amber]];
    NCRoomLabel *l = _labels[@(i)];
    l.unit = u;
    l.night = night;
    l.hue = amber;
    l.lit = s && !s.quiet;
    NSString *what = s.line ?: _rooms[i].summary;
    l.meta = (NSInteger)i == _here ? [@"Here · " stringByAppendingString:what] : what;
    CGSize size = [l sizeForMaxWidth:w * 0.46];
    CGFloat x = plot->right ? foot.x + u * 0.7 - size.width : foot.x - u * 0.7;
    l.frame = CGRectMake(round(x), round(foot.y + stem), size.width, size.height);
    [l setNeedsDisplay];
  }
  _plan.unit = u;
  _plan.image = self.image;
  _plan.glows = glows;
  _plan.halos = halos;
  _plan.stems = stems;
  [_plan setNeedsDisplay];
}

// ── Touch ────────────────────────────────────────────────────────────────

- (void)tapped:(UITapGestureRecognizer *)g {
  if (!self.onOpen) return;
  CGPoint p = [g locationInView:_plan];
  for (NSNumber *i in _labels)
    if (CGRectContainsPoint(_labels[i].frame, p)) {
      self.onOpen(i.integerValue);
      return;
    }
  CGFloat w = _plan.bounds.size.width, h = _plan.bounds.size.height;
  if (w <= 0 || h <= 0) return;
  CGPoint f = CGPointMake(p.x / w, p.y / h);
  for (NSUInteger i = 0; i < _rooms.count; i++) {
    int pi = [_plotOf[i] intValue];
    if (pi >= 0 && plotContains(&kPlots[pi], f)) {
      self.onOpen((NSInteger)i);
      return;
    }
  }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
  if (![g isKindOfClass:UIPanGestureRecognizer.class]) return YES;
  CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:_plan];
  return fabs(v.x) > fabs(v.y);
}

static CATransform3D yawTransform(CGFloat yaw) {
  CATransform3D t = CATransform3DMakeRotation(yaw * 0.3, 0, 1, 0);
  return CATransform3DRotate(t, fabs(yaw) * 0.06, 1, 0, 0);
}

- (void)panned:(UIPanGestureRecognizer *)g {
  CGFloat w = _plan.bounds.size.width;
  if (w <= 0) return;
  switch (g.state) {
    case UIGestureRecognizerStateBegan: {
      // Catch it where the spring has got to.
      CALayer *shown = _plan.layer.presentationLayer ?: _plan.layer;
      [_plan.layer removeAllAnimations];
      _yawAtStart = _yaw;
      if (shown != _plan.layer) {
        // Back out the yaw from the presented rotation (its y-axis entries).
        CATransform3D t = shown.transform;
        _yawAtStart = atan2(t.m13, t.m11) / 0.3;
      }
      break;
    }
    case UIGestureRecognizerStateChanged: {
      _yaw = MAX(-1, MIN(1, _yawAtStart + [g translationInView:_plan].x / w * 2.4));
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      _plan.layer.transform = yawTransform(_yaw);
      [CATransaction commit];
      break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed: {
      CASpringAnimation *a = [CASpringAnimation animationWithKeyPath:@"transform"];
      a.fromValue = [NSValue valueWithCATransform3D:yawTransform(_yaw)];
      a.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
      a.mass = 1;
      a.stiffness = 90;
      a.damping = 7;
      a.duration = a.settlingDuration;
      _yaw = 0;
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      _plan.layer.transform = CATransform3DIdentity;
      [CATransaction commit];
      [_plan.layer addAnimation:a forKey:@"spring"];
      break;
    }
    default:
      break;
  }
}

@end

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
  UIColor *amber = NCLuxGold(self.night);
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
    UIFont *bf = inter(@"Medium", u * 0.65);
    CGFloat bw = [@"Here" sizeWithAttributes:@{NSFontAttributeName: bf}].width + u * 1.2;
    CGRect badge = CGRectMake(w - p - bw, CGRectGetMidY(chip) - u * 0.6, bw, u * 1.2);
    [alpha(amber, 0.15) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:u * 0.6] fill];
    drawCentered(@"Here", textAttrs(bf, amber, 0), CGPointMake(CGRectGetMidX(badge), CGRectGetMidY(badge)));
  }
  UIFont *nf = inter(@"Medium", u * 1.0), *sf = inter(@"Medium", u * 0.72);
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
  UIColor *amber = NCLuxGold(self.night), *red = NCHue(kRed, self.night);
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
  NSDictionary *ka = textAttrs(inter(@"Medium", u * 1.2), white(self.night ? 0.7 : 0.92), 0);
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
  NCCaption *_caption;
  NCPinPad *_pad;
  NSString *_typed;
}

- (instancetype)initWithRoom:(NCRoom *)room {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _room = room;
    _typed = @"";
    _caption = [NCCaption new];
    _caption.text = @"Enter passcode";
    [self addSubview:_caption];
    _pad = [NCPinPad new];
    _pad.length = MAX(1, room.pin.length);
    __weak NCPinView *weak = self;
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
  _caption.text = @"Wrong passcode";
  _caption.color = NCRGB(kRed);
  [_pad setNeedsDisplay];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    self->_typed = @"";
    self->_pad.typed = 0;
    self->_pad.wrong = NO;
    self->_caption.text = @"Enter passcode";
    self->_caption.color = nil;
    [self->_pad setNeedsDisplay];
  });
}

- (void)setNight:(BOOL)night {
  _night = night;
  _pad.night = night;
  [_pad setNeedsDisplay];
}

- (CGFloat)heightForWidth:(CGFloat)width {
  return [NCCaption height] + 14 + width / 26 * [NCPinPad heightInUnits];
}

- (void)layoutForWidth:(CGFloat)width {
  CGFloat u = width / 26;
  _caption.frame = CGRectMake(0, 0, width, [NCCaption height]);
  _pad.unit = u;
  _pad.frame = CGRectMake(0, [NCCaption height] + 14, width, u * [NCPinPad heightInUnits]);
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
  uint32_t hues[3] = {kLuxGold, 0xFF4FD8EB, 0xFFB69CFF};
  NSString *icons[3] = {@"bulb", @"mode1", @"tv"};
  NSString *labels[3] = {@"lights on", @"cooling", @"screens on"};
  UIFont *nf = inter(@"Medium", u * 1.3), *lf = inter(@"Medium", u * 0.65);
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

/// One point per bill, then this period's projection: date, kWh,
/// projected?, days.
NSArray<NSArray *> *NCEnergyPoints(NCEnergyTracker *e) {
  NSMutableArray *p = [NSMutableArray array];
  for (NCBill *b in e.bills) [p addObject:@[b.date, @(b.kwh), @NO, @(b.days)]];
  if (e.totalWatts >= 0) [p addObject:@[e.periodEnd, @(e.projectedKwh), @YES, @(e.periodDays)]];
  return p;
}

/// Each point's x in [r]: evenly spaced, an extra step before a gap of
/// > 45 days.
NSArray<NSNumber *> *NCEnergyXs(NSArray<NSArray *> *pts, CGRect r, CGFloat unit) {
  NSMutableArray *steps = [NSMutableArray arrayWithObject:@0];
  for (NSUInteger i = 1; i < pts.count; i++) {
    BOOL gap = [pts[i][0] timeIntervalSinceDate:pts[i - 1][0]] > 45 * 86400;
    [steps addObject:@([steps.lastObject doubleValue] + (gap ? 1.6 : 1))];
  }
  CGFloat span = MAX(1, [steps.lastObject doubleValue]);
  CGFloat l = r.origin.x + unit * 2.6, rr = CGRectGetMaxX(r) - unit * 0.6;
  NSMutableArray *xs = [NSMutableArray array];
  for (NSNumber *s in steps) [xs addObject:@(l + (rr - l) * s.doubleValue / span)];
  return xs;
}

/// The bills' line graph (the energy card's; the clock face draws it
/// too): kWh a day per bill on a round scale, a smooth line over a soft
/// fill per run of bills, this period's projection as a hollow point
/// dashed on from the last bill, the months along the foot. [picked]
/// highlights one point (-1: none).
void NCDrawEnergyGraph(NCEnergyTracker *e, CGRect r, CGFloat unit, UIColor *hue, NSInteger picked) {
  NSArray<NSArray *> *pts = NCEnergyPoints(e);
  if (!pts.count) return;
  CGFloat u = unit;
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGFloat top = r.origin.y + u * 0.6, bottom = CGRectGetMaxY(r) - u * 1.2;
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
  NSArray<NSNumber *> *xs = NCEnergyXs(pts, r, u);
  UIFont *af = inter(@"Regular", u * 0.55);
  for (double v = yMin; v <= yMax + step / 2; v += step) {
    CGFloat gy = Y(v);
    [white(0.08) setStroke];
    UIBezierPath *gl = [UIBezierPath bezierPath];
    [gl moveToPoint:CGPointMake(r.origin.x + u * 2.2, gy)];
    [gl addLineToPoint:CGPointMake(CGRectGetMaxX(r), gy)];
    gl.lineWidth = 1;
    [gl stroke];
    NSString *t = [NSString stringWithFormat:@"%ld", lround(v)];
    [t drawAtPoint:CGPointMake(r.origin.x, gy - af.lineHeight / 2) withAttributes:textAttrs(af, white(0.4), 0)];
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
    fillGradient(ctx, @[alpha(hue, 0.28), alpha(hue, 0)], NULL, CGPointMake(0, top), CGPointMake(0, bottom));
    CGContextRestoreGState(ctx);
    line.lineWidth = 2;
    line.lineCapStyle = kCGLineCapRound;
    line.lineJoinStyle = kCGLineJoinRound;
    [hue setStroke];
    [line stroke];
  }
  // Points, the guide, and the month initials.
  static NSString *const initials[] = {@"J", @"F", @"M", @"A", @"M", @"J", @"J", @"A", @"S", @"O", @"N", @"D"};
  for (NSUInteger i = 0; i < pts.count; i++) {
    NSArray *p = pts[i];
    BOOL proj = [p[2] boolValue], pick = (NSInteger)i == picked;
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
      [alpha(hue, 0.7) setStroke];
      [link stroke];
    }
    if (proj) {
      [alpha(hue, 0.18) setFill];
      [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.9 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
      UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:c radius:u * 0.38 startAngle:0 endAngle:2 * M_PI clockwise:YES];
      [NCRGB(0xFF15171C) setFill];
      [ring fill];
      ring.lineWidth = 2;
      [hue setStroke];
      [ring stroke];
    } else if (pick) {
      [NCRGB(0xFF15171C) setFill];
      [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.42 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
      [hue setFill];
      [[UIBezierPath bezierPathWithArcCenter:c radius:u * 0.3 startAngle:0 endAngle:2 * M_PI clockwise:YES] fill];
    }
    // The bill's month, three letters when there's room.
    static NSString *const names[] = {@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun",
                                      @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"};
    NSInteger month = [NSCalendar.currentCalendar component:NSCalendarUnitMonth fromDate:p[0]];
    NSString *lab = proj ? @"now" : pts.count <= 8 ? names[month - 1] : initials[month - 1];
    NSDictionary *la = textAttrs(inter(proj ? @"Medium" : @"Regular", u * 0.55), white(pick || proj ? 0.85 : 0.4), 0);
    CGSize s = [lab sizeWithAttributes:la];
    [lab drawAtPoint:CGPointMake(c.x - s.width / 2, bottom + u * 0.35) withAttributes:la];
  }
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

- (NSArray<NSArray *> *)points { return NCEnergyPoints(self.energy); }

- (CGRect)chartRect {
  CGFloat u = self.unit, pad = u * 1.1;
  CGFloat top = pad + u * 2.4 + u * 0.9 + u * 2.1 + u * 0.9 + u * 1.2;
  return CGRectMake(pad, top, self.bounds.size.width - 2 * pad, u * kChartU);
}

- (NSArray<NSNumber *> *)xsFor:(NSArray<NSArray *> *)pts in:(CGRect)r { return NCEnergyXs(pts, r, self.unit); }

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
  UIColor *amber = NCLuxGold(self.night);
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
  UIFont *tf = inter(@"Medium", u * 0.8), *sf = inter(@"Regular", u * 0.62);
  CGFloat tx = CGRectGetMaxX(chip) + u * 0.7, ty = CGRectGetMidY(chip) - (tf.lineHeight + sf.lineHeight) / 2;
  [@"ENERGY" drawAtPoint:CGPointMake(tx, ty) withAttributes:textAttrs(tf, NCRGB(kWhite), u * 0.15)];
  [[NSString stringWithFormat:@"Estimate · bill from %@", [df stringFromDate:e.periodStart ?: [NSDate date]]]
      drawAtPoint:CGPointMake(tx, ty + tf.lineHeight) withAttributes:textAttrs(sf, white(0.5), 0)];
  NSDictionary *big = textAttrs(inter(@"Medium", u * 1.5), NCRGB(kWhite), 0);
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
  UIFont *lf = inter(@"Medium", u * 0.65), *vf = inter(@"Medium", u * 1.15), *uf = inter(@"Medium", u * 0.7);
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
  NCDrawEnergyGraph(e, cr, u, amber, _picked);

  // ACs · Lights · Screens · Other
  if (!known) return;
  CGFloat by = CGRectGetMaxY(cr) + u * 0.7, bx = x0;
  NSArray *parts = @[@[@0xFF4FD8EB, @"ACs", @(e.acWatts)], @[@(kWarm), @"Lights", @(e.lightWatts)],
                     @[@(kTvViolet), @"Screens", @(e.screenWatts)], @[@0xFFC8A97E, @"Fridge & heater", @(e.applianceWatts)],
                     @[@0xFF9AA0AA, @"Other", @(e.otherWatts)]];
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
  NCHouseView *_house;  // nil without the render
  NCHomeStats *_stats;
  NCEnergyCard *_energyCard;
  NCStatusLine *_status;
  NSTimer *_wifiTimer;
  NSArray<NSNumber *> *_carded;  // the rooms shown as cards
  NSArray<NCRoomCard *> *_cards;
}

static const CGFloat kRoomCardU = 9;
static const CGFloat kHomeGapU = 0.8;

- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms here:(NSInteger)here {
  if ((self = [super initWithFrame:CGRectZero])) {
    self.backgroundColor = UIColor.clearColor;
    _rooms = rooms;
    __weak NCHomeView *weak = self;
    // The house, when the render is in the bundle; rooms it has no place
    // for (or all of them without it) are cards.
    NCHouseView *house = [[NCHouseView alloc] initWithRooms:rooms here:here];
    NSMutableArray *carded = [NSMutableArray array];
    if (house.available) {
      _house = house;
      _house.onOpen = ^(NSInteger i) { if (weak.onOpen) weak.onOpen(i); };
      [self addSubview:_house];
      [carded addObjectsFromArray:house.unplotted];
    } else {
      for (NSUInteger i = 0; i < rooms.count; i++) [carded addObject:@(i)];
    }
    _carded = carded;
    _stats = [NCHomeStats new];
    [self addSubview:_stats];
    _energyCard = [NCEnergyCard new];
    _energyCard.hidden = YES;
    [self addSubview:_energyCard];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(energyUpdated)
                                               name:NCEnergyUpdatedNotification object:nil];
    NSMutableArray *cards = [NSMutableArray array];
    for (NSNumber *n in carded) {
      NSInteger i = n.integerValue;
      NCRoomCard *c = [NCRoomCard new];
      c.room = rooms[i];
      c.here = i == here;
      c.onTap = ^{ if (weak.onOpen) weak.onOpen(i); };
      [self addSubview:c];
      [cards addObject:c];
    }
    _cards = cards;
    // The same foot as before, with Wi-Fi read from the iPad itself (no
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

- (void)setStandby:(BOOL)standby { _standby = standby; }

- (void)setNight:(BOOL)night {
  _night = night;
  _house.night = night;
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

- (void)setDim:(BOOL)dim {
  _dim = dim;
  _house.dim = dim;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// The card shows only with bills to go on.
- (BOOL)showsEnergy { return self.energy.bills.count > 0; }

- (void)setEnergy:(NCEnergyTracker *)energy {
  _energy = energy;
  _energyCard.energy = energy;
  _energyCard.hidden = !self.showsEnergy;
  [self energyUpdated];
}

/// A new round from the house-wide poll: the house, the counts and the card.
- (void)energyUpdated {
  NCEnergyTracker *e = self.energy;
  if (!e) return;
  _house.states = e.roomStates;
  _stats.lights = e.lightsOn;
  _stats.cooling = e.cooling;
  _stats.screens = e.screensOn;
  [_stats setNeedsDisplay];
  [_energyCard setNeedsDisplay];
}

/// The house, any cards, the counts, the energy card, the foot — in the
/// old 26-unit grid, scaled to the width.
- (CGFloat)heightInUnits {
  NSUInteger rows = (_cards.count + 1) / 2;
  return (_house ? kHouseU + kHomeGapU : 0) + (rows ? rows * kRoomCardU + (rows - 1) * kHomeGapU + kHomeGapU : 0) +
         [NCHomeStats heightInUnits] + (self.showsEnergy ? kHomeGapU + [NCEnergyCard heightInUnits] : 0) + kHomeGapU + 2.0;
}

- (CGFloat)heightForWidth:(CGFloat)width { return width / 26 * [self heightInUnits]; }

- (void)layoutForWidth:(CGFloat)width {
  CGFloat u = width / 26;
  CGFloat gap = u * kHomeGapU, tile = (width - gap) / 2, h = u * kRoomCardU;
  CGFloat top = 0;
  if (_house) {
    _house.frame = CGRectMake(0, top, width, u * kHouseU);
    _house.unit = u;
    top += u * kHouseU + gap;
  }
  for (NSUInteger i = 0; i < _cards.count; i++) {
    _cards[i].unit = u;
    _cards[i].frame = CGRectMake((i % 2) * (tile + gap), top + (i / 2) * (h + gap), tile, h);
  }
  if (_cards.count) top += ((_cards.count + 1) / 2) * (h + gap);
  _stats.unit = u;
  _stats.frame = CGRectMake(0, top, width, u * [NCHomeStats heightInUnits]);
  _energyCard.unit = u;
  _energyCard.frame = CGRectMake(0, CGRectGetMaxY(_stats.frame) + gap, width, u * [NCEnergyCard heightInUnits]);
  _status.unit = u;
  _status.frame = CGRectMake(0, u * ([self heightInUnits] - 2.0), width, u * 2.0);
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
