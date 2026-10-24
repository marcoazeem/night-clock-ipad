#import "TV.h"
#import "Config.h"
#import "Devices.h"
#import <Security/SecureTransport.h>
#import <Security/Security.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

// ── Wake-on-LAN ──────────────────────────────────────────────────────────

/// Six 0xFF then the MAC sixteen times, broadcast on [host]'s subnet and
/// sent to it directly, on ports 9 and 7.
static BOOL wakeOnLan(NSString *host, NSString *mac) {
  NSData *m = NCHex([mac stringByReplacingOccurrencesOfString:@":" withString:@""]);
  if (m.length != 6) return NO;
  NSMutableData *packet = [NSMutableData dataWithLength:6];
  memset(packet.mutableBytes, 0xFF, 6);
  for (int i = 0; i < 16; i++) [packet appendData:m];
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return NO;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
  NSString *subnet = [host substringToIndex:[host rangeOfString:@"." options:NSBackwardsSearch].location];
  for (NSString *dst in @[[subnet stringByAppendingString:@".255"], @"255.255.255.255", host]) {
    for (NSNumber *port in @[@9, @7]) {
      struct sockaddr_in a = {.sin_len = sizeof(a), .sin_family = AF_INET, .sin_port = htons(port.intValue)};
      inet_pton(AF_INET, dst.UTF8String, &a.sin_addr);
      sendto(fd, packet.bytes, packet.length, 0, (struct sockaddr *)&a, sizeof(a));
    }
  }
  close(fd);
  return YES;
}

// ── TLS over a plain socket (Secure Transport) ───────────────────────────

static OSStatus tlsRead(SSLConnectionRef c, void *data, size_t *len) {
  int fd = (int)(intptr_t)c;
  size_t want = *len, got = 0;
  while (got < want) {
    ssize_t n = recv(fd, (uint8_t *)data + got, want - got, 0);
    if (n > 0) { got += n; continue; }
    *len = got;
    if (n == 0) return errSSLClosedGraceful;
    return (errno == EAGAIN || errno == EWOULDBLOCK) ? errSSLWouldBlock : errSSLClosedAbort;
  }
  *len = got;
  return noErr;
}

static OSStatus tlsWrite(SSLConnectionRef c, const void *data, size_t *len) {
  int fd = (int)(intptr_t)c;
  size_t want = *len, put = 0;
  while (put < want) {
    ssize_t n = send(fd, (const uint8_t *)data + put, want - put, 0);
    if (n > 0) { put += n; continue; }
    *len = put;
    return (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? errSSLWouldBlock : errSSLClosedAbort;
  }
  *len = put;
  return noErr;
}

/// A TLS client session; the TV's certificate is Hisense's own self-signed
/// one, so it isn't checked.
@interface NCTls : NSObject
- (instancetype)initWithHost:(NSString *)host port:(int)port timeout:(double)timeout;
- (BOOL)write:(NSData *)data;
/// Up to [max] bytes, waiting until [deadline]; nil on close or timeout.
- (NSData *)readUntil:(NSDate *)deadline;
@end

@implementation NCTls {
  int _fd;
  SSLContextRef _ctx;
}

- (instancetype)initWithHost:(NSString *)host port:(int)port timeout:(double)timeout {
  if (!(self = [super init])) return nil;
  _fd = NCTcpConnect(host, port, timeout);
  if (_fd < 0) return nil;
  _ctx = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
  SSLSetIOFuncs(_ctx, tlsRead, tlsWrite);
  SSLSetConnection(_ctx, (SSLConnectionRef)(intptr_t)_fd);
  SSLSetSessionOption(_ctx, kSSLSessionOptionBreakOnServerAuth, true);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  OSStatus st;
  do {
    st = SSLHandshake(_ctx);
  } while ((st == errSSLServerAuthCompleted || st == errSSLWouldBlock) && deadline.timeIntervalSinceNow > 0);
  if (st != noErr) return nil;
  return self;
}

- (void)dealloc {
  if (_ctx) {
    SSLClose(_ctx);
    CFRelease(_ctx);
  }
  if (_fd >= 0) close(_fd);
}

- (BOOL)write:(NSData *)data {
  size_t done = 0;
  return SSLWrite(_ctx, data.bytes, data.length, &done) == noErr && done == data.length;
}

- (NSData *)readUntil:(NSDate *)deadline {
  uint8_t buf[4096];
  while (deadline.timeIntervalSinceNow > 0) {
    size_t n = 0;
    OSStatus st = SSLRead(_ctx, buf, sizeof(buf), &n);
    if (n > 0) return [NSData dataWithBytes:buf length:n];
    if (st != errSSLWouldBlock) return nil;
  }
  return nil;
}

@end

// ── Hisense TV (MQTT 3.1.1, by hand) ─────────────────────────────────────

/// The client id the TV was paired with (Oct 2026). Pairing is per id.
static NSString *const kTvClientId = @"nightclock";

static void mqttString(NSMutableData *d, NSString *s) {
  NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding];
  uint8_t len[2] = {(uint8_t)(b.length >> 8), (uint8_t)(b.length & 0xFF)};
  [d appendBytes:len length:2];
  [d appendData:b];
}

static NSData *mqttPacket(uint8_t header, NSData *body) {
  NSMutableData *p = [NSMutableData dataWithBytes:&header length:1];
  NSUInteger n = body.length;
  do {
    uint8_t byte = n % 128;
    n /= 128;
    if (n > 0) byte |= 0x80;
    [p appendBytes:&byte length:1];
  } while (n > 0);
  [p appendData:body];
  return p;
}

@implementation NCHisenseTv {
  NSString *_host, *_mac;
}

- (instancetype)initWithName:(NSString *)name host:(NSString *)host mac:(NSString *)mac {
  if ((self = [super init])) {
    _name = [name copy];
    _host = host;
    _mac = mac;
    _queue = dispatch_queue_create("nightclock.tv", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)isOn {
  int fd = NCTcpConnect(_host, 36669, 2);
  if (fd < 0) return NO;
  close(fd);
  return YES;
}

- (BOOL)setPower:(BOOL)on {
  if (on) return wakeOnLan(_host, _mac);
  return [self isOn] ? [self sendKey:@"KEY_POWER"] : YES;
}

/// Logs in (fixed RemoteNOW credentials), publishes one key, disconnects.
- (BOOL)sendKey:(NSString *)key {
  NCTls *tls = [[NCTls alloc] initWithHost:_host port:36669 timeout:3];
  if (!tls) return NO;
  NSMutableData *connect = [NSMutableData data];
  mqttString(connect, @"MQTT");
  uint8_t flags[4] = {4, 0xC2, 0x00, 60};  // 3.1.1; user + password + clean session; keepalive 60 s
  [connect appendBytes:flags length:4];
  mqttString(connect, kTvClientId);
  mqttString(connect, @"hisenseservice");
  mqttString(connect, @"multimqttservice");
  if (![tls write:mqttPacket(0x10, connect)]) return NO;
  // CONNACK: 0x20 0x02 flags rc — rc 0 is accepted.
  NSMutableData *ack = [NSMutableData data];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
  while (ack.length < 4) {
    NSData *d = [tls readUntil:deadline];
    if (!d) return NO;
    [ack appendData:d];
  }
  const uint8_t *a = ack.bytes;
  if ((a[0] >> 4) != 2 || a[3] != 0) return NO;
  NSMutableData *publish = [NSMutableData data];
  mqttString(publish, [NSString stringWithFormat:@"/remoteapp/tv/remote_service/%@/actions/sendkey", kTvClientId]);
  [publish appendData:[key dataUsingEncoding:NSUTF8StringEncoding]];
  BOOL ok = [tls write:mqttPacket(0x30, publish)];
  uint8_t disconnect[2] = {0xE0, 0x00};
  [tls write:[NSData dataWithBytes:disconnect length:2]];
  return ok;
}

@end

// ── ADB ──────────────────────────────────────────────────────────────────

static NSString *const kAdbKeyTag = @"mv.seastack.nightclock.adbkey";

/// Our RSA key for ADB: made once, kept in the keychain. The box asks
/// "Allow debugging?" the first time it sees it.
static SecKeyRef adbKey(void) {
  NSData *tag = [kAdbKeyTag dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *query = @{(id)kSecClass: (id)kSecClassKey, (id)kSecAttrApplicationTag: tag,
                          (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA, (id)kSecReturnRef: @YES};
  CFTypeRef found = NULL;
  if (SecItemCopyMatching((CFDictionaryRef)query, &found) == errSecSuccess) return (SecKeyRef)found;
  SecKeyRef pub = NULL, priv = NULL;
  NSDictionary *params = @{(id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeySizeInBits: @2048,
                           (id)kSecPrivateKeyAttrs: @{(id)kSecAttrIsPermanent: @YES, (id)kSecAttrApplicationTag: tag}};
  if (SecKeyGeneratePair((CFDictionaryRef)params, &pub, &priv) != errSecSuccess) return NULL;
  if (pub) CFRelease(pub);
  return priv;
}

/// The modulus, little-endian 32-bit words, from the public key's PKCS#1
/// DER (SEQUENCE { INTEGER n, INTEGER e }).
static BOOL modulusWords(SecKeyRef priv, uint32_t n[64]) {
  SecKeyRef pub = SecKeyCopyPublicKey(priv);
  if (!pub) return NO;
  CFDataRef der = SecKeyCopyExternalRepresentation(pub, NULL);
  CFRelease(pub);
  if (!der) return NO;
  const uint8_t *p = CFDataGetBytePtr(der), *end = p + CFDataGetLength(der);
  BOOL ok = NO;
  // SEQUENCE header, then INTEGER header.
  if (p < end && *p++ == 0x30) {
    if (*p & 0x80) p += 1 + (*p & 0x7F); else p++;
    if (p < end && *p++ == 0x02) {
      size_t len = 0;
      if (*p & 0x80) { int k = *p++ & 0x7F; while (k--) len = (len << 8) | *p++; } else len = *p++;
      while (len > 256 && *p == 0) { p++; len--; }
      if (len == 256 && p + len <= end) {
        for (int i = 0; i < 64; i++) {
          const uint8_t *w = p + 256 - 4 * (i + 1);
          n[i] = (uint32_t)w[0] << 24 | (uint32_t)w[1] << 16 | (uint32_t)w[2] << 8 | w[3];
        }
        ok = YES;
      }
    }
  }
  CFRelease(der);
  return ok;
}

/// The public key in adbd's format (Android's RSAPublicKey struct, base64)
/// and a name for the box's prompt.
static NSData *adbPublicKey(SecKeyRef priv) {
  uint32_t n[64];
  if (!modulusWords(priv, n)) return nil;
  // n0inv = -1 / n[0] mod 2^32 (Newton's iteration).
  uint32_t inv = 1;
  for (int i = 0; i < 5; i++) inv *= 2 - n[0] * inv;
  uint32_t n0inv = (uint32_t)(0 - inv);
  // rr = 2^4096 mod n, by doubling 4096 times.
  uint32_t rr[65] = {1};
  for (int step = 0; step < 4096; step++) {
    uint32_t carry = 0;
    for (int i = 0; i < 65; i++) {
      uint32_t v = rr[i];
      rr[i] = (v << 1) | carry;
      carry = v >> 31;
    }
    // if rr >= n: rr -= n
    BOOL ge = rr[64] != 0;
    if (!ge) {
      ge = YES;
      for (int i = 63; i >= 0; i--) {
        if (rr[i] != n[i]) { ge = rr[i] > n[i]; break; }
      }
    }
    if (ge) {
      int64_t borrow = 0;
      for (int i = 0; i < 64; i++) {
        int64_t d = (int64_t)rr[i] - n[i] - borrow;
        borrow = d < 0;
        rr[i] = (uint32_t)d;
      }
      rr[64] -= (uint32_t)borrow;
    }
  }
  NSMutableData *s = [NSMutableData data];
  uint32_t words = 64, e = 65537;
  [s appendBytes:&words length:4];  // little-endian on ARM
  [s appendBytes:&n0inv length:4];
  [s appendBytes:n length:256];
  [s appendBytes:rr length:256];
  [s appendBytes:&e length:4];
  NSMutableData *out = [[[s base64EncodedStringWithOptions:0] stringByAppendingString:@" nightclock@ipad"]
                           dataUsingEncoding:NSASCIIStringEncoding].mutableCopy;
  uint8_t zero = 0;
  [out appendBytes:&zero length:1];
  return out;
}

enum : uint32_t {
  kCnxn = 0x4e584e43, kAuth = 0x48545541, kOpen = 0x4e45504f,
  kOkay = 0x59414b4f, kClse = 0x45534c43, kWrte = 0x45545257,
};

static BOOL adbSend(int fd, uint32_t cmd, uint32_t a0, uint32_t a1, NSData *data) {
  uint32_t sum = 0;
  const uint8_t *b = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) sum += b[i];
  uint32_t h[6] = {cmd, a0, a1, (uint32_t)data.length, sum, cmd ^ 0xFFFFFFFF};
  NSMutableData *m = [NSMutableData dataWithBytes:h length:24];
  if (data) [m appendData:data];
  const uint8_t *p = m.bytes;
  size_t left = m.length;
  while (left) {
    ssize_t n = send(fd, p, left, 0);
    if (n <= 0) return NO;
    p += n;
    left -= n;
  }
  return YES;
}

/// The next whole ADB message, waiting until [deadline].
static BOOL adbNext(int fd, NSMutableData *buf, NSDate *deadline, uint32_t *cmd, uint32_t *a0, NSData **data) {
  while (YES) {
    if (buf.length >= 24) {
      uint32_t h[6];
      [buf getBytes:h length:24];
      if (buf.length >= 24 + h[3]) {
        *cmd = h[0];
        *a0 = h[1];
        *data = [buf subdataWithRange:NSMakeRange(24, h[3])];
        [buf replaceBytesInRange:NSMakeRange(0, 24 + h[3]) withBytes:NULL length:0];
        return YES;
      }
    }
    if (deadline.timeIntervalSinceNow <= 0) return NO;
    uint8_t chunk[4096];
    ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
    if (n > 0) [buf appendBytes:chunk length:n];
    else if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) return NO;
  }
}

/// Runs shell:[command] on the box and returns its output; *result says
/// why not (unreachable boxes read as NCBoxFailed with *unreachable set).
static NSString *adbShell(NSString *host, NSString *command, double approval, NCBoxResult *result, BOOL *unreachable) {
  *unreachable = NO;
  SecKeyRef key = adbKey();
  NSLog(@"NCADB key %@", key ? @"ok" : @"MISSING");
  if (!key) { *result = NCBoxFailed; return nil; }
  int fd = NCTcpConnect(host, 5555, 3);
  if (fd < 0) {
    CFRelease(key);
    *result = NCBoxFailed;
    *unreachable = YES;
    return nil;
  }
  NSMutableData *buf = [NSMutableData data];
  NSString *output = nil;
  *result = NCBoxFailed;
  // Version 0x01000000: below the one that asks for TLS.
  adbSend(fd, kCnxn, 0x01000000, 4096, [@"host::\0" dataUsingEncoding:NSASCIIStringEncoding]);
  BOOL signed_ = NO, offered = NO, connected = NO;
  while (YES) {
    uint32_t cmd = 0, a0 = 0;
    NSData *data = nil;
    BOOL got = adbNext(fd, buf, [NSDate dateWithTimeIntervalSinceNow:offered ? approval : 5], &cmd, &a0, &data);
    NSLog(@"NCADB got=%d cmd=%08x a0=%u len=%lu", got, cmd, a0, (unsigned long)data.length);
    if (!got) {
      if (offered) *result = NCBoxNeedsApproval;
      break;
    }
    if (cmd == kCnxn) { connected = YES; break; }
    if (cmd != kAuth || a0 != 1) continue;  // 1: TOKEN
    if (!signed_) {
      signed_ = YES;
      // PKCS#1 v1.5 over the 20-byte token as a SHA-1 digest — adbd's check.
      uint8_t sig[256];
      size_t sigLen = sizeof(sig);
#if TARGET_OS_IPHONE
      if (SecKeyRawSign(key, kSecPaddingPKCS1SHA1, data.bytes, data.length, sig, &sigLen) != errSecSuccess) break;
#else  // macOS (only for testing this file on the Mac)
      CFDataRef s = SecKeyCreateSignature(key, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, (CFDataRef)data, NULL);
      if (!s) break;
      sigLen = CFDataGetLength(s);
      memcpy(sig, CFDataGetBytePtr(s), sigLen);
      CFRelease(s);
#endif
      adbSend(fd, kAuth, 2, 0, [NSData dataWithBytes:sig length:sigLen]);
    } else if (!offered) {
      // Not trusted yet: offer the key; the TV asks the user.
      offered = YES;
      NSData *pk = adbPublicKey(key);
      NSLog(@"NCADB offering key len=%lu", (unsigned long)pk.length);
      adbSend(fd, kAuth, 3, 0, pk);
    }
  }
  if (connected) {
    // OPEN's payload ends in a NUL.
    NSMutableData *open = [[[NSString stringWithFormat:@"shell:%@", command] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    uint8_t nul = 0;
    [open appendBytes:&nul length:1];
    adbSend(fd, kOpen, 1, 0, open);
    NSMutableData *out = [NSMutableData data];
    while (YES) {
      uint32_t cmd = 0, a0 = 0;
      NSData *data = nil;
      if (!adbNext(fd, buf, [NSDate dateWithTimeIntervalSinceNow:8], &cmd, &a0, &data) || cmd == kClse) break;
      if (cmd == kWrte) {
        [out appendData:data];
        adbSend(fd, kOkay, 1, a0, nil);
      }
    }
    output = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
    *result = NCBoxOk;
  }
  close(fd);
  CFRelease(key);
  return output;
}

@implementation NCTvBox {
  NSString *_host, *_mac;
}

- (instancetype)initWithName:(NSString *)name host:(NSString *)host mac:(NSString *)mac {
  if ((self = [super init])) {
    _name = [name copy];
    _host = host;
    _mac = mac;
    // One command at a time, so a waiting approval prompt isn't stacked.
    _queue = dispatch_queue_create("nightclock.box", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)canWake { return _mac.length > 0; }

- (NCBoxResult)readOn:(BOOL *)on {
  NCBoxResult r;
  BOOL unreachable;
  // Long enough to walk to the TV and accept the prompt.
  NSString *out = adbShell(_host, @"dumpsys power | grep mWakefulness=", 60, &r, &unreachable);
  if (unreachable) { *on = NO; return NCBoxOk; }  // asleep
  *on = [out containsString:@"Awake"];
  return r;
}

- (NCBoxResult)setPower:(BOOL)on {
  if (on) return self.canWake && wakeOnLan(_host, _mac) ? NCBoxOk : NCBoxFailed;
  NCBoxResult r;
  BOOL unreachable;
  adbShell(_host, @"input keyevent KEYCODE_SLEEP", 60, &r, &unreachable);
  return r;
}

@end

NSArray<NCHisenseTv *> *NCConfiguredTvs(void) {
  NSMutableArray *tvs = [NSMutableArray array];
  for (NSArray *e in NCEntries(@HISENSE_TV)) {
    NSArray *parts = [e[1] componentsSeparatedByString:@"/"];
    if (parts.count == 2) [tvs addObject:[[NCHisenseTv alloc] initWithName:e[0] host:parts[0] mac:parts[1]]];
  }
  return tvs;
}

NSArray<NCTvBox *> *NCConfiguredBoxes(void) {
  NSMutableArray *boxes = [NSMutableArray array];
  for (NSArray *e in NCEntries(@BEYOND_TV)) {
    NSArray *parts = [e[1] componentsSeparatedByString:@"/"];
    [boxes addObject:[[NCTvBox alloc] initWithName:e[0] host:parts[0] mac:parts.count > 1 ? parts[1] : nil]];
  }
  return boxes;
}
