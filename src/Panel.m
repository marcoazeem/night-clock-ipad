#import "Panel.h"
#import "Devices.h"
#import "NC.h"
#import "TV.h"

// ── Palette (lib/main.dart) ──────────────────────────────────────────────
static const uint32_t kTvViolet = 0xFFB69CFF, kBoxBlue = 0xFF5EC8FF;
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
  [NCNabla.shared drawIcon:name in:CGRectMake(center.x - size / 2, center.y - size / 2, size, size) color:color];
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

/// A square tile: a big power button that fills left to right with the
/// brightness and, for a dimmable light, a 1 / 25 / 50 / 100% bar.
@interface NCLightTile : NCTile
@property (nonatomic, strong) NCLight *light;
@property (nonatomic) BOOL known, on, offline, busy;
@property (nonatomic) NSInteger level;  // -1 unknown
- (void)run:(BOOL (^)(NCLight *l))action expectOn:(BOOL)on level:(NSInteger)level done:(void (^)(void))done;
@end

@implementation NCLightTile {
  UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithLight:(NCLight *)light {
  if ((self = [super initWithFrame:CGRectZero])) {
    _light = light;
    _level = -1;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];
  }
  return self;
}

- (UIColor *)hue {
  NSString *n = self.light.name.lowercaseString;
  BOOL cool = [n containsString:@"white"] || [n containsString:@"cool"];
  return NCHue(cool ? kCool : kWarm, self.night);
}

- (CGFloat)pad { return self.unit * 1.1; }
- (CGRect)inner { return CGRectInset(self.bounds, self.pad, self.pad); }
- (CGRect)powerRect {
  CGRect in = self.inner;
  if (self.light.dimmable) in.size.height -= self.unit * 3.7;
  return in;
}
- (CGRect)barRect {
  CGRect in = self.inner;
  return CGRectMake(in.origin.x, CGRectGetMaxY(in) - self.unit * 3, in.size.width, self.unit * 3);
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect p = self.powerRect;
  _spinner.center = CGPointMake(CGRectGetMidX(p), CGRectGetMidY(p));
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *hue = self.hue;
  BOOL on = self.known && self.on;
  [self setGlow:hue on:on];
  drawCard(self.bounds, hue, on, self.offline, u);

  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGRect pr = self.powerRect;
  CGFloat radius = u * 1.25;
  UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:pr cornerRadius:radius];
  CGContextSaveGState(ctx);
  [shape addClip];
  [alpha(hue, on ? 0.14 : 0.06) setFill];
  UIRectFill(pr);
  // Fills left to right with the brightness, never so little that "on"
  // stops reading as on.
  CGFloat fill = !on ? 0 : MAX(0.15, (self.level >= 0 ? self.level : 100) / 100.0);
  if (fill > 0) {
    CGRect f = pr;
    f.size.width *= fill;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, f);
    fillGradient(ctx, @[alpha(hue, 0.75), hue], NULL, f.origin, CGPointMake(CGRectGetMaxX(f), f.origin.y));
    CGContextRestoreGState(ctx);
  }
  CGContextRestoreGState(ctx);
  [(self.offline ? alpha(NCRGB(kRed), 0.4) : alpha(hue, on ? 0.6 : 0.18)) setStroke];
  shape.lineWidth = 1;
  [shape stroke];

  BOOL iconOnFill = fill >= 0.6;
  NSString *status = self.offline ? @"Offline" : !self.known ? @"Connecting…" : nil;
  CGPoint c = CGPointMake(CGRectGetMidX(pr), CGRectGetMidY(pr) - (status ? u * 0.6 : 0));
  _spinner.color = iconOnFill ? UIColor.blackColor : NCRGB(kWhite);
  if (!self.busy) {
    UIColor *ic = self.offline ? NCRGB(kRed) : !on ? alpha(hue, 0.55) : iconOnFill ? UIColor.blackColor : NCRGB(kWhite);
    drawIcon(self.offline ? @"wifioff" : @"power", c, u * 3, ic);
  }
  if (status) {
    drawCentered(status, textAttrs(inter(@"Regular", u * 0.8), self.offline ? NCRGB(kRed) : white(0.5), 0),
                 CGPointMake(c.x, c.y + u * 2.3));
  }

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
  if (self.busy) return;
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

- (void)onTap:(UITapGestureRecognizer *)g {
  if (self.busy) return;
  CGPoint p = [g locationInView:self];
  if (CGRectContainsPoint(self.powerRect, p)) {
    BOOL to = !(self.known && self.on);
    [self run:^BOOL(NCLight *l) { return [l setPower:to]; } expectOn:to level:-1 done:nil];
  } else if (self.light.dimmable && CGRectContainsPoint(self.barRect, p)) {
    CGRect bar = self.barRect;
    int i = MAX(0, MIN(3, (int)((p.x - bar.origin.x) / (bar.size.width / 4))));
    NSInteger pct = kPresets[i];
    [self run:^BOOL(NCLight *l) { return [l setBrightness:pct]; } expectOn:YES level:pct done:nil];
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
  return CGRectMake(self.pad, self.bounds.size.height - self.pad - s, s, s);
}
- (CGRect)plusRect {
  CGFloat s = self.unit * 2.6;
  return CGRectMake(self.bounds.size.width - self.pad - s, self.bounds.size.height - self.pad - s, s, s);
}
- (CGRect)dialRect {
  CGFloat u = self.unit, w = self.bounds.size.width, h = self.bounds.size.height, pad = self.pad;
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
    NSString *room = [NSString stringWithFormat:@"%ld°", (long)self.state.roomTemp];
    NSDictionary *ra = textAttrs(inter(@"Medium", u * 0.8), white(0.6), 0);
    CGSize rs = [room sizeWithAttributes:ra];
    CGFloat total = u * 0.9 + rs.width, cy = CGRectGetMidY(self.minusRect);
    CGFloat x = self.bounds.size.width / 2 - total / 2;
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

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
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
- (CGRect)volumeRect {
  if (!self.tv) return CGRectZero;
  CGFloat u = self.unit;
  return CGRectMake(self.bounds.size.width - self.pad - u * 9, self.pad, u * 9, self.side);
}
- (CGRect)tvRect {
  if (!self.tv) return CGRectZero;
  return CGRectMake(self.volumeRect.origin.x - self.unit * 0.6 - self.side, self.pad, self.side, self.side);
}
- (CGRect)boxRect {
  if (!self.box) return CGRectZero;
  CGFloat right = self.tv ? self.tvRect.origin.x - self.unit * 0.6 : self.bounds.size.width - self.pad;
  return CGRectMake(self.pad, self.pad, right - self.pad, self.side);
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
    CGRect r = self.boxRect;
    drawButton(r, boxHue, boxOn, u);
    UIColor *fg = boxOn ? UIColor.blackColor : alpha(boxHue, _boxKnown ? 0.65 : 0.3);
    NSString *status = _boxProblem ?: (!_boxKnown ? @"Connecting…" : boxOn ? @"On" : @"Off");
    UIColor *sc = _boxProblem ? NCRGB(kRed) : boxOn ? [UIColor colorWithWhite:0 alpha:0.65] : white(0.45);
    // Icon and text as one group, centred in the button; the text shrinks
    // (both lines alike) only if the group wouldn't fit.
    CGFloat icon = u * 2.1, gap = u * 0.6, room = r.size.width - u * 1.6 - icon - gap;
    CGFloat k = 1;
    NSDictionary *na = textAttrs(inter(@"SemiBold", u * 1.05), fg, 0);
    NSDictionary *sa = textAttrs(inter(@"Medium", u * 0.78), sc, 0);
    CGFloat textW = MAX([self.box.name sizeWithAttributes:na].width, [status sizeWithAttributes:sa].width);
    if (textW > room) {
      k = room / textW;
      na = textAttrs(inter(@"SemiBold", u * 1.05 * k), fg, 0);
      sa = textAttrs(inter(@"Medium", u * 0.78 * k), sc, 0);
      textW = room;
    }
    CGSize ns = [self.box.name sizeWithAttributes:na], ss = [status sizeWithAttributes:sa];
    CGFloat gx = CGRectGetMidX(r) - (icon + gap + textW) / 2;
    drawIcon(@"power", CGPointMake(gx + icon / 2, CGRectGetMidY(r)), icon, fg);
    CGFloat tx = gx + icon + gap, ty = CGRectGetMidY(r) - (ns.height + ss.height) / 2;
    [self.box.name drawAtPoint:CGPointMake(tx, ty) withAttributes:na];
    [status drawAtPoint:CGPointMake(tx, ty + ns.height) withAttributes:sa];
  }
  if (self.tv) {
    CGRect r = self.tvRect;
    drawButton(r, hue, tvOn, u);
    UIColor *fg = tvOn ? UIColor.blackColor : alpha(hue, _tvKnown ? 0.65 : 0.25);
    drawIcon(@"tv", CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r) - u * 0.7), u * 1.7, fg);
    drawIcon(@"power", CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r) + u * 0.85), u * 1.2, fg);
    CGRect v = self.volumeRect;
    drawSurface(v, u * 1.25);
    CGFloat third = v.size.width / 3, cy = CGRectGetMidY(v);
    drawIcon(@"minus", CGPointMake(v.origin.x + third * 0.5, cy), u * 1.8, white(tvOn ? 0.85 : 0.25));
    drawIcon(@"volume", CGPointMake(v.origin.x + third * 1.5, cy), u * 1.2, alpha(hue, tvOn ? 0.8 : 0.25));
    drawIcon(@"plus", CGPointMake(v.origin.x + third * 2.5, cy), u * 1.8, white(tvOn ? 0.85 : 0.25));
  }
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
    if (to && !self.box.canWake) {
      // Asleep, the box is off the network; only its remote wakes it.
      _boxProblem = @"Use the remote to turn on";
      [self setNeedsDisplay];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self->_boxProblem isEqualToString:@"Use the remote to turn on"]) {
          self->_boxProblem = nil;
          [self setNeedsDisplay];
        }
      });
      return;
    }
    _boxOn = to;
    _boxSwitched = [NSDate date];
    [self setNeedsDisplay];
    NCTvBox *box = self.box;
    dispatch_async(box.queue, ^{
      NCBoxResult r = [box setPower:to];
      if (r != NCBoxOk) dispatch_async(dispatch_get_main_queue(), ^{
        self->_boxSwitched = nil;
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
  } else if (self.tv && CGRectContainsPoint(self.volumeRect, p) && _tvOn) {
    CGRect v = self.volumeRect;
    CGFloat x = p.x - v.origin.x;
    NSString *key = x < v.size.width / 3 ? @"KEY_VOLUMEDOWN" : x > v.size.width * 2 / 3 ? @"KEY_VOLUMEUP" : nil;
    if (!key) return;
    NCHisenseTv *tv = self.tv;
    dispatch_async(tv.queue, ^{ [tv sendKey:key]; });
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
         [label sizeWithAttributes:textAttrs(inter(@"SemiBold", u * 0.8), UIColor.whiteColor, u * 0.08)].width;
}
- (CGRect)gmRect {
  CGFloat w = [self pillWidth:@"GM"];
  return CGRectMake(self.bounds.size.width - w, 0, w, self.unit * 2.6);
}
- (CGRect)gnRect {
  CGFloat w = [self pillWidth:@"GN"];
  return CGRectMake(self.gmRect.origin.x - self.unit * 0.5 - w, 0, w, self.unit * 2.6);
}

- (void)drawRect:(CGRect)rect {
  CGFloat u = self.unit;
  if (u <= 0) return;
  UIColor *label = white(self.night ? 0.4 : 0.55);
  CGFloat cy = u * 1.3;
  drawIcon(@"home", CGPointMake(u * 0.6, cy), u * 1.2, label);
  NSDictionary *a = textAttrs(inter(@"SemiBold", u * 0.85), label, u * 0.2);
  CGSize s = [@"ROOM DASHBOARD" sizeWithAttributes:a];
  [@"ROOM DASHBOARD" drawAtPoint:CGPointMake(u * 1.7, cy - s.height / 2) withAttributes:a];
  for (int i = 0; i < 2; i++) {
    CGRect r = i == 0 ? self.gnRect : self.gmRect;
    UIColor *fg = white(self.running ? 0.3 : 0.8);
    drawSurface(CGRectInset(r, 0.5, 0.5), u * 1.3);
    drawIcon(i == 0 ? @"bedtime" : @"sunny", CGPointMake(r.origin.x + u * 0.9 + u * 0.6, cy), u * 1.2, fg);
    NSDictionary *pa = textAttrs(inter(@"SemiBold", u * 0.8), fg, u * 0.08);
    NSString *t = i == 0 ? @"GN" : @"GM";
    CGSize ts = [t sizeWithAttributes:pa];
    [t drawAtPoint:CGPointMake(r.origin.x + u * 0.9 + u * 1.6, cy - ts.height / 2) withAttributes:pa];
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  if (self.running) return;
  CGPoint p = [g locationInView:self];
  if (CGRectContainsPoint(self.gnRect, p)) self.onScene(YES);
  else if (CGRectContainsPoint(self.gmRect, p)) self.onScene(NO);
}

@end

@implementation NCPanelView {
  NCHeader *_header;
  NSArray<NCLightTile *> *_lightTiles;
  NSArray<NCAcTile *> *_acTiles;
  NCTvCard *_tvCard;
  NSTimer *_poll;
  CGFloat _unit;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.clearColor;
    _header = [NCHeader new];
    __weak NCPanelView *weak = self;
    _header.onScene = ^(BOOL gn) { [weak runScene:gn]; };
    [self addSubview:_header];
    NSMutableArray *lt = [NSMutableArray array];
    for (NCLight *l in NCConfiguredLights()) {
      NCLightTile *t = [[NCLightTile alloc] initWithLight:l];
      [self addSubview:t];
      [lt addObject:t];
    }
    _lightTiles = lt;
    NSMutableArray *at = [NSMutableArray array];
    for (NCGreeAc *ac in NCConfiguredAcs()) {
      NCAcTile *t = [[NCAcTile alloc] initWithAc:ac];
      [self addSubview:t];
      [at addObject:t];
    }
    _acTiles = at;
    NCHisenseTv *tv = NCConfiguredTvs().firstObject;
    NCTvBox *box = NCConfiguredBoxes().firstObject;
    if (tv || box) {
      _tvCard = [NCTvCard new];
      _tvCard.tv = tv;
      _tvCard.box = box;
      [self addSubview:_tvCard];
    }
  }
  return self;
}

- (BOOL)hasDevices { return _lightTiles.count + _acTiles.count > 0 || _tvCard; }

- (void)setNight:(BOOL)night {
  _night = night;
  _header.night = night;
  for (NCTile *t in _lightTiles) t.night = night;
  for (NCTile *t in _acTiles) t.night = night;
  _tvCard.night = night;
}

static const CGFloat kGapU = 0.8, kTileU = (26 - 0.8) / 2;

- (CGFloat)heightInUnits {
  CGFloat h = 2.6;
  NSUInteger lightRows = (_lightTiles.count + 1) / 2, acRows = (_acTiles.count + 1) / 2;
  if (lightRows) h += kGapU + lightRows * kTileU + (lightRows - 1) * kGapU;
  if (acRows) h += kGapU + acRows * kTileU * 1.3 + (acRows - 1) * kGapU;
  if (_tvCard) h += kGapU + 7.2;
  return h;
}

- (void)layoutForUnit:(CGFloat)u {
  _unit = u;
  CGFloat gap = u * kGapU, tile = u * kTileU, y = 0;
  _header.unit = u;
  _header.frame = CGRectMake(0, 0, u * 26, u * 2.6);
  y = u * 2.6;
  for (NSUInteger i = 0; i < _lightTiles.count; i++) {
    if (i % 2 == 0) y += gap + (i ? tile : 0);
    NCLightTile *t = _lightTiles[i];
    t.unit = u;
    t.frame = CGRectMake((i % 2) * (tile + gap), y, tile, tile);
  }
  if (_lightTiles.count) y += tile;
  for (NSUInteger i = 0; i < _acTiles.count; i++) {
    if (i % 2 == 0) y += gap + (i ? tile * 1.3 : 0);
    NCAcTile *t = _acTiles[i];
    t.unit = u;
    t.frame = CGRectMake((i % 2) * (tile + gap), y, tile, tile * 1.3);
  }
  if (_acTiles.count) y += tile * 1.3;
  if (_tvCard) {
    _tvCard.unit = u;
    _tvCard.frame = CGRectMake(0, y + gap, u * 26, u * 7.2);
  }
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
