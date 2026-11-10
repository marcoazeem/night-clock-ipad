#import "NC.h"
#import "Lux.h"
#import "Lottie.h"

// The clock column's top (the luxury look, Nov 2026): the date in small
// caps, HH:MM in Jost ExtraLight, a fading hairline carrying the next
// holiday, and a weather row — icon, temperature, a thin rule, "MALÉ ·
// CLEAR". Sizes are the approved mock-up's, in points.

/// Where the weather is (WEATHER_AT holds only the coordinates).
static NSString *const kPlace = @"MALÉ";
static const CGFloat kTimeSize = 142, kTimeLine = 146, kTimeKern = 3;
static const CGFloat kIconBox = 42;

static UIFont *timeFont(void) { return NCLuxFont(@"Jost-ExtraLight", kTimeSize); }

/// The weather in a word, from the WMO code.
static NSString *conditionWord(NCWeather *w) {
  NSInteger c = w.code;
  if (FORCE_RAIN) return @"RAIN";
  if (c >= 95) return @"STORM";
  if (c >= 85 || (c >= 71 && c <= 77)) return @"SNOW";
  if (c >= 61) return @"RAIN";
  if (c >= 51) return @"DRIZZLE";
  if (w.raining) return @"RAIN";
  if (c >= 45) return @"FOG";
  if (c == 3) return @"CLOUDY";
  if (c == 2) return @"PARTLY CLOUDY";
  return w.isDay ? @"SUNNY" : @"CLEAR";
}

/// A weather icon from the bundle (wx_<name>.png, rendered by
/// tool/glyphs_test.dart), multiplied towards the dashboard's red in night
/// mode — made once per icon and mode.
static UIImage *weatherImage(NSString *name, BOOL night) {
  static NSMutableDictionary<NSString *, UIImage *> *cache;
  if (!cache) cache = [NSMutableDictionary dictionary];
  NSString *key = [NSString stringWithFormat:@"%@/%d", name, night];
  if (cache[key]) return cache[key];
  UIImage *img = [UIImage imageNamed:[@"wx_" stringByAppendingString:name]];
  if (!img || !night) return cache[key] = img;
  UIGraphicsBeginImageContextWithOptions(img.size, NO, img.scale);
  CGRect r = {CGPointZero, img.size};
  [img drawInRect:r];
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
  [NCHue(0xFFE8E8E8, YES) setFill];
  CGContextFillRect(ctx, r);
  [img drawInRect:r blendMode:kCGBlendModeDestinationIn alpha:1];
  UIImage *tinted = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return cache[key] = tinted;
}

/// A 1 px line fading from [a] to [b] alpha (ivory) across [r].
static void hairline(CGRect r, CGFloat a, CGFloat mid, CGFloat b) {
  CGFloat cr, cg, cb, ca;
  [NCRGB(kLuxIvory) getRed:&cr green:&cg blue:&cb alpha:&ca];
  CGFloat comps[] = {cr, cg, cb, a, cr, cg, cb, mid, cr, cg, cb, b};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 3);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSaveGState(ctx);
  CGContextClipToRect(ctx, r);
  CGContextDrawLinearGradient(ctx, grad, r.origin, CGPointMake(CGRectGetMaxX(r), r.origin.y), 0);
  CGContextRestoreGState(ctx);
  CGGradientRelease(grad);
  CGColorSpaceRelease(space);
}

@implementation NCFaceView {
  /// The weather icon, animated (Meteocons' Lottie file) outside night
  /// mode; hidden and stopped in it, where a still red-tinted copy is drawn
  /// instead — the user asked for the animation to stop with the red tint.
  LOTAnimationView *_anim;
  NSString *_animName;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
  }
  return self;
}

// Rows, top down: date, time (a 146 pt line box), the hairline row, the
// weather row.
/// The date: bigger and heavier than the mock-up's 11.5 pt label, so it reads
/// at the standby backlight (the user, 10 Nov 2026: "still unreadable").
static CGFloat dateLine(void) { return NCLuxLine(NCLuxFont(@"Inter-Medium", 15)); }
static CGFloat timeTop(void) { return dateLine() + 4; }
static CGFloat ruleTop(void) { return timeTop() + kTimeLine + 2; }
static CGFloat ruleLine(void) { return NCLuxLine(NCLuxFont(@"Inter-Regular", 11)); }
static CGFloat weatherTop(void) { return ruleTop() + ruleLine() + 18; }
static CGFloat weatherLine(void) { return MAX(kIconBox, NCLuxLine(NCLuxFont(@"Jost-Light", 32))); }

+ (CGFloat)height { return weatherTop() + weatherLine(); }

/// Plays [name]'s animation over [box]; NO if the bundle hasn't got it.
- (BOOL)showAnimation:(NSString *)name in:(CGRect)box {
  if (![name isEqualToString:_animName]) {
    [_anim removeFromSuperview];
    _anim = nil;
    _animName = name;
    if (![[NSBundle mainBundle] pathForResource:name ofType:@"json"]) return NO;
    _anim = [LOTAnimationView animationNamed:name];
    _anim.contentMode = UIViewContentModeScaleAspectFit;
    _anim.loopAnimation = YES;
    _anim.userInteractionEnabled = NO;
    [self addSubview:_anim];
  }
  if (!_anim) return NO;
  if (!CGRectEqualToRect(_anim.frame, box)) _anim.frame = box;
  if (_anim.hidden || !_anim.isAnimationPlaying) {
    _anim.hidden = NO;
    [_anim play];
  }
  return YES;
}

- (void)hideAnimation {
  if (!_anim || _anim.hidden) return;
  [_anim pause];
  _anim.hidden = YES;
}

- (void)setNow:(NSDate *)now { _now = now; [self setNeedsDisplay]; }
- (void)setWeather:(NCWeather *)weather { _weather = weather; [self setNeedsDisplay]; }
- (void)setStandby:(BOOL)standby { _standby = standby; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
  if (!self.now) return;
  BOOL night = NCIsNight(self.now);
  CGFloat W = self.bounds.size.width;
  // Ivory; in red night mode the old slate (NCClockColor's night).
  UIColor *clock = night ? NCClockColor(self.now, NO) : NCRGB(kLuxIvory);
  // Dimmed (standby, 20% backlight) the slate and thin ivory are hard to
  // read: the time goes bright red at night, gold by day (the user asked,
  // 10 Nov 2026).
  if (self.standby) clock = night ? NCRGB(0xFFFF4A3D) : NCRGB(0xFFE0BC85);
  UIColor *muted = NCLuxMuted();

  // TUESDAY · 10 NOVEMBER
  NSDateFormatter *df = [NSDateFormatter new];
  df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  df.dateFormat = @"EEEE' · 'd MMMM";
  NSString *date = [df stringFromDate:self.now].uppercaseString;
  // In standby the backlight drops to 20%, where muted grey all but
  // vanishes — the date goes ivory then (the user asked, 10 Nov 2026).
  NSDictionary *da = NCLuxAttrs(NCLuxFont(@"Inter-Medium", 15), self.standby ? NCLuxIvory(night) : muted, 4);
  NCLuxDraw(date, da, (W - NCLuxWidth(date, da)) / 2, 0);

  // HH:MM, each figure centred in a slot as wide as the widest (Jost's
  // figures are proportional), so the time never shifts with the minutes.
  NSDateFormatter *tf = [NSDateFormatter new];
  tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  tf.dateFormat = @"HH:mm";
  NSString *time = [tf stringFromDate:self.now];
  // Heavier strokes when dimmed, so the time reads at the low backlight.
  UIFont *font = self.standby ? NCLuxFont(@"Jost-Light", kTimeSize) : timeFont();
  NSDictionary *ta = NCLuxAttrs(font, clock, 0);
  CGFloat slot = 0;
  for (int d = 0; d <= 9; d++) slot = MAX(slot, NCLuxWidth([NSString stringWithFormat:@"%d", d], ta));
  CGFloat colon = NCLuxWidth(@":", ta);
  CGFloat total = 4 * slot + colon + 5 * kTimeKern;
  CGFloat x = (W - total) / 2;
  // CSS centres the font's content box in the 146 pt line box.
  CGFloat baseline = timeTop() + (kTimeLine - (font.ascender - font.descender)) / 2 + font.ascender;
  for (NSUInteger i = 0; i < time.length; i++) {
    NSString *ch = [time substringWithRange:NSMakeRange(i, 1)];
    CGFloat s = [ch isEqualToString:@":"] ? colon : slot;
    CGFloat adv = NCLuxWidth(ch, ta);
    [ch drawAtPoint:CGPointMake(x + (s - adv) / 2, baseline - font.ascender) withAttributes:ta];
    x += s + kTimeKern;
  }

  // The hairline, carrying the next holiday when one is near.
  CGFloat ry = ruleTop() + ruleLine() / 2;
  NSString *holiday = [[NCHolidays lineFor:self.now] stringByReplacingOccurrencesOfString:@"  ·  " withString:@" · "];
  if (holiday.length) {
    CGFloat size = 11;
    NSDictionary *ha = NCLuxLabel(size, 3.5, NCRGB(kLuxHoliday));
    while (NCLuxWidth(holiday, ha) > W - 2 * (14 + 36) && size > 7) {
      size -= 0.5;
      ha = NCLuxLabel(size, 3.5 * size / 11, NCRGB(kLuxHoliday));
    }
    CGFloat hw = NCLuxWidth(holiday, ha), hx = (W - hw) / 2;
    NCLuxDrawMid(holiday, ha, hx, ry);
    hairline(CGRectMake(0, floor(ry), hx - 14, 1), 0, 0.11, 0.22);
    hairline(CGRectMake(hx + hw + 14, floor(ry), W - hx - hw - 14, 1), 0.22, 0.11, 0);
  } else {
    hairline(CGRectMake(0, floor(ry), W, 1), 0, 0.22, 0);
  }

  // Weather: icon, temperature, a thin rule, "MALÉ · CLEAR".
  NCWeather *w = self.weather;
  if (!w) { [self hideAnimation]; return; }
  CGFloat cy = weatherTop() + weatherLine() / 2;
  NSString *temp = [NSString stringWithFormat:@"%ld°", (long)w.temp];
  NSDictionary *tempA = NCLuxAttrs(NCLuxFont(@"Jost-Light", 32), clock, 0);
  NSString *word = [NSString stringWithFormat:@"%@ · %@", kPlace, conditionWord(w)];
  NSDictionary *wa = NCLuxLabel(11, 3, muted);
  CGFloat tw = NCLuxWidth(temp, tempA), ww = NCLuxWidth(word, wa);
  CGFloat rowW = kIconBox + 16 + tw + 16 + 1 + 16 + ww;
  CGFloat rx = (W - rowW) / 2;
  CGRect box = CGRectMake(rx, cy - kIconBox / 2, kIconBox, kIconBox);
  NSString *wx = w.icon ?: @"clear-day";
  // The icon stands still only in night mode (the user: no animation with
  // the red tint); in standby it keeps moving (the user asked, 6 Nov 2026).
  if (night || ![self showAnimation:wx in:box]) {
    [self hideAnimation];
    UIImage *img = weatherImage(wx, night);
    if (img) [img drawInRect:box];
  }
  rx += kIconBox + 16;
  NCLuxDrawMid(temp, tempA, rx, cy);
  rx += tw + 16;
  [NCRGB(0xFF2A2723) setFill];
  UIRectFill(CGRectMake(rx, cy - 11, 1, 22));
  rx += 1 + 16;
  NCLuxDrawMid(word, wa, rx, cy);
}

@end
