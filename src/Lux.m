#import "Lux.h"
#import "Energy.h"
#import "NC.h"

UIColor *NCLuxGold(BOOL night) { return NCHue(kLuxGold, night); }
UIColor *NCLuxIvory(BOOL night) { return night ? [NCRGB(kLuxIvory) colorWithAlphaComponent:0.65] : NCRGB(kLuxIvory); }
UIColor *NCLuxMuted(void) { return NCRGB(kLuxMuted); }

UIFont *NCLuxFont(NSString *name, CGFloat size) {
  return [UIFont fontWithName:name size:size] ?: [UIFont systemFontOfSize:size];
}

NSDictionary *NCLuxAttrs(UIFont *font, UIColor *color, CGFloat kern) {
  return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern)};
}

CGFloat NCLuxWidth(NSString *text, NSDictionary *attrs) { return [text sizeWithAttributes:attrs].width; }

CGFloat NCLuxLine(UIFont *font) { return font.ascender - font.descender; }

void NCLuxDraw(NSString *text, NSDictionary *attrs, CGFloat x, CGFloat y) {
  [text drawAtPoint:CGPointMake(x, y) withAttributes:attrs];
}

void NCLuxDrawMid(NSString *text, NSDictionary *attrs, CGFloat x, CGFloat cy) {
  UIFont *f = attrs[NSFontAttributeName];
  [text drawAtPoint:CGPointMake(x, cy - NCLuxLine(f) / 2) withAttributes:attrs];
}

NSDictionary *NCLuxLabel(CGFloat size, CGFloat kern, UIColor *color) {
  return NCLuxAttrs(NCLuxFont(@"Inter-Regular", size), color, kern);
}

// ── Icons: a small SVG path reader (M L H V C S Q Z A, either case) ─────

NSString *const NCLuxIconBulb = @"M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z";
NSString *const NCLuxIconMoon = @"M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z";
NSString *const NCLuxIconSun = @"M8 12a4 4 0 1 0 8 0a4 4 0 1 0-8 0z"
                               @"M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4";
NSString *const NCLuxIconFan = @"M10.5 12a1.5 1.5 0 1 0 3 0a1.5 1.5 0 1 0-3 0z"
                               @"M12 10.5C11 7 11.5 3.5 14 3.5c2 0 2.5 3-.5 7M13.5 12.5c3.3 1 5.8 3.6 4.5 5.6-1 1.7-3.8.6-5.2-3.6"
                               @"M10.5 12.5c-3.5.4-6.5-1-6-3.5.4-2 3.3-2 6 1.5";
NSString *const NCLuxIconCeiling = @"M12 3v5M6 14a6 6 0 0 1 12 0zM10 17a2 2 0 0 0 4 0";
NSString *const NCLuxIconMinus = @"M5 12h14";
NSString *const NCLuxIconPlus = @"M5 12h14M12 5v14";
NSString *const NCLuxIconPower = @"M12 3v8M6.3 6.3a8 8 0 1 0 11.4 0";
NSString *const NCLuxIconPlay = @"M8 5v14l11-7z";
NSString *const NCLuxIconUpDown = @"M8 9l4-4 4 4M8 15l4 4 4-4";

/// A circular arc from the current point (SVG's endpoint form, no rotation).
static void arcTo(UIBezierPath *p, CGPoint from, CGFloat rx, CGFloat ry, BOOL large, BOOL sweep, CGPoint to) {
  CGFloat r = (rx + ry) / 2;
  if (r <= 0 || CGPointEqualToPoint(from, to)) { [p addLineToPoint:to]; return; }
  CGFloat x1 = (from.x - to.x) / 2, y1 = (from.y - to.y) / 2;
  CGFloat lambda = (x1 * x1 + y1 * y1) / (r * r);
  if (lambda > 1) r *= sqrt(lambda);
  CGFloat num = r * r * r * r - r * r * y1 * y1 - r * r * x1 * x1, den = r * r * y1 * y1 + r * r * x1 * x1;
  CGFloat coef = (large != sweep ? 1 : -1) * sqrt(MAX(0, num / den));
  CGFloat cxp = coef * y1, cyp = -coef * x1;
  CGPoint c = CGPointMake(cxp + (from.x + to.x) / 2, cyp + (from.y + to.y) / 2);
  CGFloat t1 = atan2((y1 - cyp) / r, (x1 - cxp) / r), t2 = atan2((-y1 - cyp) / r, (-x1 - cxp) / r);
  CGFloat d = t2 - t1;
  if (!sweep && d > 0) d -= 2 * M_PI;
  if (sweep && d < 0) d += 2 * M_PI;
  [p addArcWithCenter:c radius:r startAngle:t1 endAngle:t1 + d clockwise:d > 0];
}

static UIBezierPath *svgPath(NSString *d) {
  static NSMutableDictionary<NSString *, UIBezierPath *> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  if (cache[d]) return cache[d];
  UIBezierPath *p = [UIBezierPath bezierPath];
  const char *s = d.UTF8String;
  size_t n = strlen(s);
  __block size_t i = 0;
  char cmd = 0;
  CGPoint cur = CGPointZero, start = CGPointZero, lastCtl = CGPointZero;
  char lastCmd = 0;
  // Reads the next number (or flag), skipping separators; NO at a command.
  BOOL (^num)(CGFloat *) = ^BOOL(CGFloat *out) {
    while (i < n && (s[i] == ' ' || s[i] == ',' || s[i] == '\n')) i++;
    if (i >= n) return NO;
    char c = s[i];
    if (!(c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9'))) return NO;
    size_t j = i;
    if (s[j] == '-' || s[j] == '+') j++;
    BOOL dot = NO;
    while (j < n && ((s[j] >= '0' && s[j] <= '9') || (s[j] == '.' && !dot))) {
      if (s[j] == '.') dot = YES;
      j++;
    }
    char buf[32];
    size_t len = MIN((size_t)31, j - i);
    memcpy(buf, s + i, len);
    buf[len] = 0;
    *out = atof(buf);
    i = j;
    return YES;
  };
  // A flag can be written with no separator: "a1 1 0 11 1".
  BOOL (^flag)(BOOL *) = ^BOOL(BOOL *out) {
    while (i < n && (s[i] == ' ' || s[i] == ',')) i++;
    if (i >= n || (s[i] != '0' && s[i] != '1')) return NO;
    *out = s[i] == '1';
    i++;
    return YES;
  };
  while (i < n) {
    while (i < n && (s[i] == ' ' || s[i] == ',')) i++;
    if (i >= n) break;
    char c = s[i];
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) { cmd = c; i++; }
    BOOL rel = cmd >= 'a';
    char up = rel ? cmd - 32 : cmd;
    CGFloat a[6];
    if (up == 'Z') {
      [p closePath];
      cur = start;
      lastCmd = 'Z';
      continue;
    }
    if (up == 'M' || up == 'L') {
      if (!num(&a[0]) || !num(&a[1])) break;
      CGPoint pt = rel ? CGPointMake(cur.x + a[0], cur.y + a[1]) : CGPointMake(a[0], a[1]);
      if (up == 'M') { [p moveToPoint:pt]; start = pt; cmd = rel ? 'l' : 'L'; }
      else [p addLineToPoint:pt];
      cur = pt;
    } else if (up == 'H' || up == 'V') {
      if (!num(&a[0])) break;
      if (up == 'H') cur.x = rel ? cur.x + a[0] : a[0];
      else cur.y = rel ? cur.y + a[0] : a[0];
      [p addLineToPoint:cur];
    } else if (up == 'C' || up == 'S') {
      int k = up == 'C' ? 6 : 4;
      BOOL ok = YES;
      for (int q = 0; q < k; q++) ok = ok && num(&a[q]);
      if (!ok) break;
      CGPoint c1, c2, end;
      CGFloat ox = rel ? cur.x : 0, oy = rel ? cur.y : 0;
      if (up == 'C') {
        c1 = CGPointMake(ox + a[0], oy + a[1]);
        c2 = CGPointMake(ox + a[2], oy + a[3]);
        end = CGPointMake(ox + a[4], oy + a[5]);
      } else {
        c1 = (lastCmd == 'C' || lastCmd == 'S') ? CGPointMake(2 * cur.x - lastCtl.x, 2 * cur.y - lastCtl.y) : cur;
        c2 = CGPointMake(ox + a[0], oy + a[1]);
        end = CGPointMake(ox + a[2], oy + a[3]);
      }
      [p addCurveToPoint:end controlPoint1:c1 controlPoint2:c2];
      lastCtl = c2;
      cur = end;
    } else if (up == 'A') {
      BOOL large, sweep;
      if (!num(&a[0]) || !num(&a[1]) || !num(&a[2]) || !flag(&large) || !flag(&sweep) || !num(&a[3]) || !num(&a[4])) break;
      CGPoint end = rel ? CGPointMake(cur.x + a[3], cur.y + a[4]) : CGPointMake(a[3], a[4]);
      arcTo(p, cur, a[0], a[1], large, sweep, end);
      cur = end;
    } else {
      break;  // not used by our icons
    }
    lastCmd = up;
  }
  cache[d] = p;
  return p;
}

void NCLuxIcon(NSString *svg, CGRect rect, UIColor *color, CGFloat stroke) {
  UIBezierPath *p = [svgPath(svg) copy];
  CGFloat k = rect.size.width / 24;
  CGAffineTransform t = CGAffineTransformMakeTranslation(rect.origin.x, rect.origin.y);
  t = CGAffineTransformScale(t, k, rect.size.height / 24);
  [p applyTransform:t];
  p.lineWidth = stroke * k;
  p.lineCapStyle = kCGLineCapRound;
  p.lineJoinStyle = kCGLineJoinRound;
  [color setStroke];
  [p stroke];
}

// ── Cards ────────────────────────────────────────────────────────────────

static void linear(CGContextRef ctx, NSArray<UIColor *> *colors, const CGFloat *stops, CGPoint a, CGPoint b) {
  NSMutableArray *cg = [NSMutableArray array];
  for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef g = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, stops);
  CGContextDrawLinearGradient(ctx, g, a, b, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
  CGGradientRelease(g);
  CGColorSpaceRelease(space);
}

void NCLuxCard(CGRect r, CGFloat radius, UIColor *top, UIColor *bottom, CGFloat stop) {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  radius = MIN(radius, MIN(r.size.width, r.size.height) / 2);
  UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
  CGContextSaveGState(ctx);
  [body addClip];
  linear(ctx, @[NCRGB(0xFF050505), NCRGB(0xFF020202)], NULL, r.origin, CGPointMake(r.origin.x, CGRectGetMaxY(r)));
  CGContextRestoreGState(ctx);
  // The border: CSS's linear-gradient(170deg, top, bottom stop%).
  CGRect er = CGRectInset(r, 0.5, 0.5);
  CGContextSaveGState(ctx);
  CGContextAddPath(ctx, [UIBezierPath bezierPathWithRoundedRect:er cornerRadius:MAX(0, radius - 0.5)].CGPath);
  CGContextSetLineWidth(ctx, 1);
  CGContextReplacePathWithStrokedPath(ctx);
  CGContextClip(ctx);
  CGFloat th = 170 * M_PI / 180, dx = sin(th), dy = -cos(th);
  CGFloat len = fabs(r.size.width * dx) + fabs(r.size.height * dy);
  CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
  CGPoint a = CGPointMake(c.x - dx * len / 2, c.y - dy * len / 2), b = CGPointMake(c.x + dx * len / 2, c.y + dy * len / 2);
  CGFloat stops[] = {0, stop};
  linear(ctx, @[top, bottom], stops, a, b);
  CGContextRestoreGState(ctx);
}

void NCLuxPlainCard(CGRect r, CGFloat radius, CGFloat strength) {
  UIColor *iv = NCRGB(kLuxIvory);
  NCLuxCard(r, radius, [iv colorWithAlphaComponent:strength], [iv colorWithAlphaComponent:strength * 0.2], 0.6);
}

void NCLuxDot(CGPoint c, CGFloat radius, UIColor *color, CGFloat glow) {
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSaveGState(ctx);
  if (glow > 0) CGContextSetShadowWithColor(ctx, CGSizeZero, glow, color.CGColor);
  [color setFill];
  [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - radius, c.y - radius, radius * 2, radius * 2)] fill];
  CGContextRestoreGState(ctx);
}

// ── Top bar ──────────────────────────────────────────────────────────────

@implementation NCTopBar

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}

- (void)setTitle:(NSString *)title { _title = [title copy]; [self setNeedsDisplay]; }
- (void)setShowScenes:(BOOL)s { _showScenes = s; [self setNeedsDisplay]; }
- (void)setNight:(BOOL)night { _night = night; [self setNeedsDisplay]; }
- (void)setRunning:(NSString *)running { _running = [running copy]; [self setNeedsDisplay]; }

- (NSDictionary *)sceneAttrs:(UIColor *)c { return NCLuxLabel(12, 3, c); }

/// A scene button's rect: icon 13, gap 8, the word.
- (CGRect)sceneRect:(BOOL)gn {
  CGFloat h = self.bounds.size.height;
  CGFloat wm = 13 + 8 + NCLuxWidth(@"MORNING", [self sceneAttrs:UIColor.whiteColor]);
  CGFloat wn = 13 + 8 + NCLuxWidth(@"NIGHT", [self sceneAttrs:UIColor.whiteColor]);
  CGFloat xm = self.bounds.size.width - wm;
  return gn ? CGRectMake(xm - 28 - wn, 0, wn, h) : CGRectMake(xm, 0, wm, h);
}

- (void)drawRect:(CGRect)rect {
  CGFloat h = self.bounds.size.height, cy = h / 2;
  NSDictionary *ta = NCLuxLabel(12, 4, NCLuxMuted());
  NCLuxDrawMid(self.title.uppercaseString ?: @"", ta, 0, cy);
  if (!self.showScenes) return;
  CGFloat fade = self.running ? 0.4 : 1;
  for (int i = 0; i < 2; i++) {
    BOOL gn = i == 0;
    UIColor *c = [(gn ? NCLuxMuted() : NCLuxGold(self.night)) colorWithAlphaComponent:fade];
    if ([self.running isEqualToString:gn ? @"gn" : @"gm"]) c = NCLuxIvory(self.night);
    CGRect r = [self sceneRect:gn];
    NCLuxIcon(gn ? NCLuxIconMoon : NCLuxIconSun, CGRectMake(r.origin.x, cy - 6.5, 13, 13), c, 1.25 * 24 / 13);
    NCLuxDrawMid(gn ? @"NIGHT" : @"MORNING", [self sceneAttrs:c], r.origin.x + 21, cy);
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  if (!self.showScenes || self.running || !self.onScene) return;
  CGPoint p = [g locationInView:self];
  if (CGRectContainsPoint(CGRectInset([self sceneRect:YES], -12, -14), p)) self.onScene(YES);
  else if (CGRectContainsPoint(CGRectInset([self sceneRect:NO], -12, -14), p)) self.onScene(NO);
}

@end

// ── Tabs ─────────────────────────────────────────────────────────────────

@implementation NCTabBar

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
  }
  return self;
}

- (void)setActive:(NSInteger)active { _active = active; [self setNeedsDisplay]; }
- (void)setNight:(BOOL)night { _night = night; [self setNeedsDisplay]; }

- (NSDictionary *)attrs:(NSInteger)i {
  BOOL on = i == self.active;
  return NCLuxAttrs(NCLuxFont(on ? @"Inter-Medium" : @"Inter-Regular", 10.5), on ? NCLuxIvory(self.night) : NCLuxMuted(), 3);
}

/// Each tab's rect, centred as a row with 64 between (less if it's tight).
- (NSArray<NSValue *> *)rects {
  NSUInteger n = self.titles.count;
  if (!n) return @[];
  CGFloat total = 0, widths[16];
  for (NSUInteger i = 0; i < n && i < 16; i++) {
    widths[i] = NCLuxWidth(self.titles[i].uppercaseString, [self attrs:i]);
    total += widths[i];
  }
  CGFloat gap = n > 1 ? MIN(64, (self.bounds.size.width - 32 - total) / (n - 1)) : 0;
  CGFloat x = (self.bounds.size.width - total - gap * (n - 1)) / 2;
  NSMutableArray *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < n && i < 16; i++) {
    [out addObject:[NSValue valueWithCGRect:CGRectMake(x, 0, widths[i], self.bounds.size.height)]];
    x += widths[i] + gap;
  }
  return out;
}

- (void)drawRect:(CGRect)rect {
  NSArray<NSValue *> *rects = self.rects;
  UIFont *f = NCLuxFont(@"Inter-Regular", 10.5);
  CGFloat line = NCLuxLine(f), itemH = 10 + line + 7 + 3 + 10;
  CGFloat top = (self.bounds.size.height - itemH) / 2 + 10;
  for (NSUInteger i = 0; i < rects.count; i++) {
    CGRect r = rects[i].CGRectValue;
    NCLuxDraw(self.titles[i].uppercaseString, [self attrs:i], r.origin.x, top);
    // CSS centres the dot under the text box, trailing letter-spacing included.
    if ((NSInteger)i == self.active) NCLuxDot(CGPointMake(CGRectGetMidX(r), top + line + 7 + 1.5), 1.5, NCLuxGold(self.night), 0);
  }
}

- (void)onTap:(UITapGestureRecognizer *)g {
  CGPoint p = [g locationInView:self];
  NSArray<NSValue *> *rects = self.rects;
  for (NSUInteger i = 0; i < rects.count; i++)
    if (CGRectContainsPoint(CGRectInset(rects[i].CGRectValue, -24, 0), p)) {
      if (self.onSelect) self.onSelect((NSInteger)i);
      return;
    }
}

@end

// ── Energy strip ─────────────────────────────────────────────────────────

static NSString *luxWatts(double w) {
  return w >= 1000 ? [NSString stringWithFormat:@"%.1f kW", w / 1000] : [NSString stringWithFormat:@"%ld W", lround(w)];
}

static NSString *luxMvr(double v) {
  NSNumberFormatter *f = [NSNumberFormatter new];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  f.maximumFractionDigits = 0;
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
  return [f stringFromNumber:@(lround(v))];
}

@implementation NCEnergyStrip

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
    _room = -1;
  }
  return self;
}

static const CGFloat kGraphH = 64;

+ (CGFloat)height {
  return NCLuxLine(NCLuxFont(@"Inter-Regular", 12)) + 8 + kGraphH + 4 + NCLuxLine(NCLuxFont(@"Inter-Regular", 9.5)) + 6;
}

- (void)drawRect:(CGRect)rect {
  NCEnergyTracker *e = self.energy;
  CGFloat w = self.bounds.size.width;
  BOOL night = self.night;
  UIColor *gold = NCLuxGold(night), *ivory = NCLuxIvory(night), *muted = NCLuxMuted();
  UIFont *vf = NCLuxFont(@"Inter-Regular", 12);
  CGFloat rowH = NCLuxLine(vf);
  // ENERGY on the label row's baseline, the figures right.
  NSDictionary *la = NCLuxLabel(10.5, 3.5, muted);
  UIFont *lf = la[NSFontAttributeName];
  NCLuxDraw(@"ENERGY", la, 0, vf.ascender - lf.ascender);
  BOOL known = e && e.totalWatts >= 0;
  double watts = !known ? -1
               : self.room < 0 ? e.totalWatts
               : self.room < (NSInteger)e.roomWatts.count ? [e.roomWatts[self.room] doubleValue] : -1;
  NSMutableAttributedString *fig = [NSMutableAttributedString new];
  void (^add)(NSString *, UIColor *) = ^(NSString *t, UIColor *c) {
    [fig appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:NCLuxAttrs(vf, c, 1.5)]];
  };
  add(watts >= 0 ? luxWatts(watts) : @"– W", ivory);
  if (known && e.bills.count) {
    add(@" · ", muted);
    add([@"≈ MVR " stringByAppendingString:luxMvr(e.projectedMvr)], ivory);
    add(@" THIS BILL", muted);
  }
  [fig drawAtPoint:CGPointMake(w - fig.size.width, 0)];

  // The bills, kWh a day, then this period's projection.
  NSMutableArray<NSArray *> *pts = [NSMutableArray array];  // date, kWh/day, projected
  for (NCBill *b in e.bills) [pts addObject:@[b.date, @(b.kwh / (double)MAX(1, b.days)), @NO]];
  BOOL projected = known && pts.count;
  if (projected) [pts addObject:@[e.periodEnd ?: [NSDate date], @(e.projectedKwh / MAX(1, e.periodDays)), @YES]];
  if (pts.count < 2) return;
  CGFloat gy = rowH + 8, gh = kGraphH;
  double lo = 1e9, hi = 0;
  for (NSArray *p in pts) {
    lo = MIN(lo, [p[1] doubleValue]);
    hi = MAX(hi, [p[1] doubleValue]);
  }
  if (hi - lo < 1) { hi += 0.5; lo -= 0.5; }
  // As the mock-up: the line between 20% and 66% down, the fill to 94%.
  CGFloat top = gy + gh * 0.18, bottom = gy + gh * 0.66, floorY = gy + gh * 0.94;
  CGFloat x0 = w * 10 / 480, x1 = w * 455 / 480;
  NSMutableArray<NSValue *> *xy = [NSMutableArray array];
  for (NSUInteger i = 0; i < pts.count; i++) {
    CGFloat x = x0 + (x1 - x0) * i / (pts.count - 1);
    CGFloat y = bottom - ([pts[i][1] doubleValue] - lo) / (hi - lo) * (bottom - top);
    [xy addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
  }
  NSUInteger nb = projected ? pts.count - 1 : pts.count;  // the bills (then the projection)
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  UIBezierPath *line = [UIBezierPath bezierPath];
  CGPoint prev = xy[0].CGPointValue;
  [line moveToPoint:prev];
  for (NSUInteger i = 1; i < nb; i++) {
    CGPoint pt = xy[i].CGPointValue;
    CGFloat dx = (pt.x - prev.x) / 2;
    [line addCurveToPoint:pt controlPoint1:CGPointMake(prev.x + dx, prev.y) controlPoint2:CGPointMake(pt.x - dx, pt.y)];
    prev = pt;
  }
  if (nb > 1) {
    UIBezierPath *fill = [line copy];
    [fill addLineToPoint:CGPointMake(prev.x, floorY)];
    [fill addLineToPoint:CGPointMake(xy[0].CGPointValue.x, floorY)];
    [fill closePath];
    CGContextSaveGState(ctx);
    [fill addClip];
    linear(ctx, @[[gold colorWithAlphaComponent:0.22], [gold colorWithAlphaComponent:0]], NULL, CGPointMake(0, top),
           CGPointMake(0, floorY));
    CGContextRestoreGState(ctx);
    line.lineWidth = 1.2;
    line.lineCapStyle = kCGLineCapRound;
    [gold setStroke];
    [line stroke];
  }
  // This period's projection: dashed on from the last bill to a hollow ring.
  if (projected) {
    CGPoint now = xy.lastObject.CGPointValue;
    UIBezierPath *dash = [UIBezierPath bezierPath];
    [dash moveToPoint:prev];
    [dash addLineToPoint:now];
    CGFloat pattern[] = {3, 4};
    [dash setLineDash:pattern count:2 phase:0];
    dash.lineWidth = 1;
    [gold setStroke];
    [dash stroke];
    UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(now.x - 4, now.y - 4, 8, 8)];
    [UIColor.blackColor setFill];
    [ring fill];
    ring.lineWidth = 1.2;
    [ring stroke];
  }

  // The months along the foot, under their points.
  NSDictionary *ma = NCLuxLabel(9.5, 2.5, muted);
  CGFloat my = gy + gh + 4;
  NSDateFormatter *mf = [NSDateFormatter new];
  mf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  mf.dateFormat = pts.count <= 8 ? @"MMM" : @"MMMMM";
  for (NSUInteger i = 0; i < pts.count; i++) {
    NSString *t = [pts[i][2] boolValue] ? @"NOW" : [mf stringFromDate:pts[i][0]].uppercaseString;
    CGFloat tw = NCLuxWidth(t, ma);
    CGFloat x = MAX(0, MIN(w - tw, xy[i].CGPointValue.x - tw / 2 + 1.25));
    NCLuxDraw(t, ma, x, my);
  }
}

@end
