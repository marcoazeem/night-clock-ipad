#import "NC.h"

// Proportions from lib/main.dart, all in units of the digit size d.
static const CGFloat kDigitSlot = 0.52;   // each digit's fixed slot
static const CGFloat kColonSlot = 0.312;  // the colon's
static const CGFloat kTimeWidth = 4 * kDigitSlot + kColonSlot;
static const CGFloat kGap = 0.07;
static const CGFloat kDateSize = 0.2, kDateSpacing = 0.012;
static const CGFloat kCardWidth = 1.5;     // weather: icon + temperature
static const CGFloat kIcon = 0.46;
static const CGFloat kTempSize = 0.42;
/// Nabla's 3D tops reach this far above the line box (measured from the
/// rendered glyphs) — room is kept for it, or the view clips the digits.
static const CGFloat kInkAbove = 0.24;

@implementation NCFaceView

- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    self.userInteractionEnabled = NO;
  }
  return self;
}

- (void)setNow:(NSDate *)now { _now = now; [self setNeedsDisplay]; }
- (void)setWeather:(NCWeather *)weather { _weather = weather; [self setNeedsDisplay]; }

- (NSString *)dateText {
  NSDateFormatter *f = [NSDateFormatter new];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.dateFormat = @"EEE'  ·  'MMM d";
  return [[f stringFromDate:self.now] uppercaseString];
}

/// The date's font size: shrunk if it would run wider than 0.85 of the time.
- (CGFloat)dateScaleFor:(NSString *)date night:(BOOL)night {
  NCNabla *n = NCNabla.shared;
  CGFloat w = [n widthOf:date size:kDateSize spacing:kDateSpacing night:night];
  return MIN(1.0, kTimeWidth * 0.85 / w);
}

- (CGFloat)faceHeight:(CGFloat)dateScale {
  return kInkAbove + 1.0 + kGap + 0.0045 + kGap + kDateSize * dateScale;
}

- (CGFloat)cardHeight {
  return kIcon;
}

- (void)drawRect:(CGRect)rect {
  if (!self.now) return;
  BOOL night = NCIsNight(self.now);
  NCNabla *n = NCNabla.shared;
  NSString *date = [self dateText];
  CGFloat dateScale = [self dateScaleFor:date night:night];
  CGFloat faceH = [self faceHeight:dateScale];
  BOOL hasCard = self.weather != nil;

  // Natural size at d = 1, two ways: the weather beside the clock or under
  // it. Whichever lets the digits grow bigger wins.
  CGFloat rowW = kTimeWidth + (hasCard ? 0.2 + kCardWidth : 0);
  CGFloat rowH = MAX(faceH, hasCard ? self.cardHeight : 0);
  CGFloat colW = MAX(kTimeWidth, hasCard ? kCardWidth : 0);
  CGFloat colH = faceH + (hasCard ? 2 * kGap + self.cardHeight : 0);
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  CGFloat dRow = MIN(W / rowW, H / rowH), dCol = MIN(W / colW, H / colH);
  BOOL row = dRow >= dCol;
  CGFloat d = row ? dRow : dCol;
  CGFloat totalW = (row ? rowW : colW) * d, totalH = (row ? rowH : colH) * d;
  CGFloat x0 = (W - totalW) / 2, y0 = (H - totalH) / 2;

  // The face column: its own top-left.
  CGFloat fx = row ? x0 : x0 + (totalW - kTimeWidth * d) / 2;
  CGFloat fy = row ? y0 + (totalH - faceH * d) / 2 : y0;

  // Time: HH:MM, every glyph centred in a fixed slot.
  NSDateFormatter *tf = [NSDateFormatter new];
  tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  tf.dateFormat = @"HH:mm";
  NSString *time = [tf stringFromDate:self.now];
  CGFloat x = fx;
  fy += kInkAbove * d;
  for (NSUInteger i = 0; i < time.length; i++) {
    unichar c = [time characterAtIndex:i];
    CGFloat slot = (c == ':' ? kColonSlot : kDigitSlot) * d;
    CGFloat adv = [n advanceOf:c size:d night:night];
    [n drawChar:c at:CGPointMake(x + (slot - adv) / 2, fy) size:d night:night];
    x += slot;
  }

  // Hairline: fades in and out, 0.61 of the time's width.
  CGFloat y = fy + d * (1 + kGap);
  CGFloat lineW = kTimeWidth * 0.61 * d, lineH = MAX(1.5, d * 0.0045);
  CGRect line = CGRectMake(fx + (kTimeWidth * d - lineW) / 2, y, lineW, lineH);
  UIColor *tc = night ? NCRGB(0xFFFF8A75) : NCRGB(0xFFE8E8E8);
  CGFloat r, g, b, a;
  [tc getRed:&r green:&g blue:&b alpha:&a];
  CGFloat comps[] = {r, g, b, 0, r, g, b, 0.55, r, g, b, 0};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, NULL, 3);
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGContextSaveGState(ctx);
  CGContextClipToRect(ctx, line);
  CGContextDrawLinearGradient(ctx, grad, CGPointMake(CGRectGetMinX(line), 0),
                              CGPointMake(CGRectGetMaxX(line), 0), 0);
  CGContextRestoreGState(ctx);
  CGGradientRelease(grad);
  CGColorSpaceRelease(space);

  // Date: "FRI  ·  OCT 23", centred.
  y += lineH + kGap * d;
  CGFloat ds = kDateSize * dateScale * d, dsp = kDateSpacing * dateScale * d;
  CGFloat dw = [n widthOf:date size:ds spacing:dsp night:night];
  [n drawText:date at:CGPointMake(fx + (kTimeWidth * d - dw) / 2, y) size:ds spacing:dsp night:night];

  if (!hasCard) return;

  // Weather: the icon beside the temperature (the low - high was removed).
  CGFloat cx = row ? x0 + (kTimeWidth + 0.2) * d : x0 + (totalW - kCardWidth * d) / 2;
  CGFloat cy = row ? y0 + (totalH - self.cardHeight * d) / 2 : fy - kInkAbove * d + (faceH + 2 * kGap) * d;
  CGFloat s = kIcon * d;
  NSInteger hour = NCHour(self.now);
  if (self.weather.raining) {
    CGFloat cs = s * 0.82;
    [n drawIcon:@"cloud" in:CGRectMake(cx + (s - cs) / 2, cy, cs, cs) color:NCRGB(0xEBE8E8E8)];
    CGFloat ds2 = s * 0.24;
    for (int i = 0; i < 3; i++)
      [n drawIcon:@"drop" in:CGRectMake(cx + (s - 3 * ds2) / 2 + i * ds2, cy + s - ds2, ds2, ds2)
            color:NCHue(0xFF7CC4FF, night)];
  } else if (hour >= 6 && hour < 18) {
    [n drawIcon:@"sun" in:CGRectMake(cx, cy, s, s) color:NCHue(0xFFFFC94D, night)];
  } else {
    [n drawIcon:@"moon" in:CGRectMake(cx, cy, s, s) color:NCHue(0xFFD5DCFF, night)];
  }
  // Nabla's ink sits high in its line (centre ≈ 0.30 of the size down), so
  // the line is lowered until the digits centre on the icon.
  CGFloat tx = cx + s + 0.12 * d, ts = kTempSize * d;
  NSString *temp = [NSString stringWithFormat:@"%ld°C", (long)self.weather.temp];
  [n drawText:temp at:CGPointMake(tx, cy + s / 2 - 0.30 * ts) size:ts spacing:0 night:night];
}

@end
