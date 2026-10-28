#import "NC.h"

// Proportions from lib/main.dart, all in units of the digit size d — the
// face's layout unit: the time's ink stands kInkBottom × d tall, and the
// hairline, date and weather are sized from d.
/// The digits' ink ends here, down from the face's top; the hairline
/// follows from it.
#define kInkBottom 0.79
/// Chakra Petch's figures stand this many em on the baseline, flat (measured
/// from the phone's render of the same TTF), so the time's font is a little
/// bigger than d.
#define kCapHeight 0.703
#define kFontScale (kInkBottom / kCapHeight)
/// The slots the time's glyphs are centred in, in em: Chakra Petch's figures
/// are proportional (a "1" is 0.382, a "0" 0.652), so each gets a slot the
/// width of the widest, and the time's width never changes with the minutes
/// — the same slots as the phone's.
#define kDigitAdvance 0.652
#define kColonAdvance 0.232
#define kTimeWidth (kFontScale * (4 * kDigitAdvance + kColonAdvance))
/// Where Chakra Petch's baseline sits down a 1 em line box on the phone
/// (TextStyle height 1.0). UIKit's line box is taller (ascender +
/// descender), so every line here is placed by its baseline to land where
/// the phone's does.
#define kBaseline 0.7631
static const CGFloat kGap = 0.07;
static const CGFloat kDateSize = 0.2, kDateSpacing = 0.012;
static const CGFloat kIcon = 0.46;
static const CGFloat kTempSize = 0.42, kTempGap = 0.12;

/// The face's font — the time, date and temperature are all Chakra Petch
/// Bold, from the bundle (Info.plist's UIAppFonts), else the system's bold.
static UIFont *clockFont(CGFloat size) {
  return [UIFont fontWithName:@"ChakraPetch-Bold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

static NSDictionary *attrs(UIFont *font, UIColor *color, CGFloat kern) {
  return @{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern)};
}

/// [text]'s width in em of the face's font, with [kern] em after each character.
static CGFloat emWidth(NSString *text, CGFloat kern) {
  const CGFloat probe = 100;
  return [text sizeWithAttributes:attrs(clockFont(probe), UIColor.whiteColor, kern * probe)].width / probe;
}

/// Draws one line of [text] with its baseline at [baseline].
static void drawOnBaseline(NSString *text, NSDictionary *a, CGFloat x, CGFloat baseline) {
  UIFont *f = a[NSFontAttributeName];
  [text drawAtPoint:CGPointMake(x, baseline - f.ascender) withAttributes:a];
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
- (CGFloat)dateScaleFor:(NSString *)date {
  CGFloat w = kDateSize * emWidth(date, kDateSpacing / kDateSize);
  return MIN(1.0, kTimeWidth * 0.85 / w);
}

- (CGFloat)faceHeight:(CGFloat)dateScale {
  return kInkBottom + kGap + 0.0045 + kGap + kDateSize * dateScale;
}

- (CGFloat)cardHeight {
  return kIcon;
}

- (void)drawRect:(CGRect)rect {
  if (!self.now) return;
  BOOL night = NCIsNight(self.now);
  UIColor *color = NCClockColor(self.now, self.weather.raining);
  NSString *date = [self dateText];
  CGFloat dateScale = [self dateScaleFor:date];
  CGFloat faceH = [self faceHeight:dateScale];
  BOOL hasCard = self.weather != nil;
  NSString *temp = hasCard ? [NSString stringWithFormat:@"%ld°C", (long)self.weather.temp] : @"";
  // The weather: the icon, a gap, then the temperature.
  CGFloat cardW = hasCard ? kIcon + kTempGap + kTempSize * emWidth(temp, 0) : 0;

  // Natural size at d = 1, two ways: the weather beside the clock or under
  // it. Whichever lets the digits grow bigger wins.
  CGFloat rowW = kTimeWidth + (hasCard ? 0.2 + cardW : 0);
  CGFloat rowH = MAX(faceH, hasCard ? self.cardHeight : 0);
  CGFloat colW = MAX(kTimeWidth, cardW);
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

  // Time: HH:MM, every glyph centred in a fixed slot, on a baseline at the
  // foot of the ink's box.
  NSDateFormatter *tf = [NSDateFormatter new];
  tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  tf.dateFormat = @"HH:mm";
  NSString *time = [tf stringFromDate:self.now];
  UIFont *font = clockFont(kFontScale * d);
  NSDictionary *ta = attrs(font, color, 0);
  CGFloat baseline = fy + kInkBottom * d, x = fx;
  for (NSUInteger i = 0; i < time.length; i++) {
    NSString *ch = [time substringWithRange:NSMakeRange(i, 1)];
    CGFloat slot = ([ch isEqualToString:@":"] ? kColonAdvance : kDigitAdvance) * font.pointSize;
    CGFloat adv = [ch sizeWithAttributes:ta].width;
    drawOnBaseline(ch, ta, x + (slot - adv) / 2, baseline);
    x += slot;
  }

  // Hairline: fades in and out, 0.61 of the time's width.
  CGFloat y = fy + d * (kInkBottom + kGap);
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

  // Date: "FRI  ·  OCT 23", centred, the clock's font and colour.
  y += lineH + kGap * d;
  CGFloat ds = kDateSize * dateScale * d;
  NSDictionary *da = attrs(clockFont(ds), color, kDateSpacing * dateScale * d);
  CGFloat dw = [date sizeWithAttributes:da].width;
  drawOnBaseline(date, da, fx + (kTimeWidth * d - dw) / 2, y + kBaseline * ds);

  if (!hasCard) return;

  // Weather: the icon beside the temperature (the low - high was removed).
  CGFloat cx = row ? x0 + (kTimeWidth + 0.2) * d : x0 + (totalW - cardW * d) / 2;
  CGFloat cy = row ? y0 + (totalH - self.cardHeight * d) / 2 : fy + (faceH + 2 * kGap) * d;
  CGFloat s = kIcon * d;
  // Meteocons (Bas Milius, MIT), as on the phone: full colour, the art
  // fills ~70% of its box so it's drawn a little larger than the slot.
  NSString *wx = self.weather.icon ?: @"clear-day";
  UIImage *img = weatherImage(wx, night);
  if (img) [img drawInRect:CGRectInset(CGRectMake(cx, cy, s, s), -s * 0.18, -s * 0.18)];
  // The temperature, its digits' ink centred on the icon.
  CGFloat ts = kTempSize * d;
  drawOnBaseline(temp, attrs(clockFont(ts), color, 0), cx + (kIcon + kTempGap) * d,
                 cy + s / 2 + kCapHeight * ts / 2);
}

@end
