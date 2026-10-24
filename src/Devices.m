#import "Devices.h"
#import "Config.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

// ── Plumbing ─────────────────────────────────────────────────────────────

NSData *NCRandomBytes(size_t n) {
  NSMutableData *d = [NSMutableData dataWithLength:n];
  if (SecRandomCopyBytes(kSecRandomDefault, n, d.mutableBytes) != 0) arc4random_buf(d.mutableBytes, n);
  return d;
}

NSData *NCHex(NSString *hex) {
  NSMutableData *d = [NSMutableData data];
  for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
    unsigned int b = 0;
    [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&b];
    uint8_t byte = b;
    [d appendBytes:&byte length:1];
  }
  return d;
}

static BOOL isHex(NSString *s, NSUInteger length) {
  if (s.length != length) return NO;
  NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
  return [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

NSArray<NSArray<NSString *> *> *NCEntries(NSString *spec) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *part in [spec componentsSeparatedByString:@","]) {
    NSRange eq = [part rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location == 0) continue;
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    [out addObject:@[[[part substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws],
                     [[part substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws]]];
  }
  return out;
}

static NSData *cat(NSArray<NSData *> *parts) {
  NSMutableData *d = [NSMutableData data];
  for (NSData *p in parts) [d appendData:p];
  return d;
}

static NSData *utf8(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

static NSData *sha256(NSData *d) {
  NSMutableData *out = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, out.mutableBytes);
  return out;
}

static NSData *md5(NSData *d) {
  NSMutableData *out = [NSMutableData dataWithLength:CC_MD5_DIGEST_LENGTH];
  CC_MD5(d.bytes, (CC_LONG)d.length, out.mutableBytes);
  return out;
}

/// AES-128; CBC with PKCS#7 when [iv] is given, else raw ECB on whole blocks.
static NSData *aes(BOOL encrypt, NSData *key, NSData *iv, NSData *data) {
  CCOptions opts = iv ? kCCOptionPKCS7Padding : kCCOptionECBMode;
  size_t cap = data.length + kCCBlockSizeAES128, moved = 0;
  NSMutableData *out = [NSMutableData dataWithLength:cap];
  CCCryptorStatus st = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES128, opts,
                               key.bytes, key.length, iv.bytes, data.bytes, data.length,
                               out.mutableBytes, cap, &moved);
  if (st != kCCSuccess) return nil;
  out.length = moved;
  return out;
}

static BOOL addressFor(NSString *host, int port, struct sockaddr_in *addr) {
  memset(addr, 0, sizeof(*addr));
  addr->sin_len = sizeof(*addr);
  addr->sin_family = AF_INET;
  addr->sin_port = htons(port);
  return inet_pton(AF_INET, host.UTF8String, &addr->sin_addr) == 1;
}

static void setTimeout(int fd, int option, double seconds) {
  struct timeval tv = {(int)seconds, (int)((seconds - (int)seconds) * 1e6)};
  setsockopt(fd, SOL_SOCKET, option, &tv, sizeof(tv));
}

NSData *NCUdpExchange(NSString *host, int port, NSData *data, int tries, double timeout) {
  struct sockaddr_in addr;
  if (!addressFor(host, port, &addr)) return nil;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return nil;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  setTimeout(fd, SO_RCVTIMEO, timeout);
  NSData *reply = nil;
  uint8_t buf[65536];
  for (int i = 0; i < tries && !reply; i++) {
    sendto(fd, data.bytes, data.length, 0, (struct sockaddr *)&addr, sizeof(addr));
    ssize_t n = recvfrom(fd, buf, sizeof(buf), 0, NULL, NULL);
    if (n > 0) reply = [NSData dataWithBytes:buf length:n];
  }
  close(fd);
  return reply;
}

int NCTcpConnect(NSString *host, int port, double timeout) {
  struct sockaddr_in addr;
  if (!addressFor(host, port, &addr)) return -1;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
  if (rc != 0) {
    fd_set w;
    FD_ZERO(&w);
    FD_SET(fd, &w);
    struct timeval tv = {(int)timeout, (int)((timeout - (int)timeout) * 1e6)};
    int err = 0;
    socklen_t len = sizeof(err);
    if (select(fd + 1, NULL, &w, NULL, &tv) != 1 ||
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0) {
      close(fd);
      return -1;
    }
  }
  fcntl(fd, F_SETFL, flags);
  setTimeout(fd, SO_RCVTIMEO, timeout);
  setTimeout(fd, SO_SNDTIMEO, timeout);
  return fd;
}

static BOOL sendAll(int fd, NSData *d) {
  const uint8_t *p = d.bytes;
  size_t left = d.length;
  while (left) {
    ssize_t n = send(fd, p, left, 0);
    if (n <= 0) return NO;
    p += n;
    left -= n;
  }
  return YES;
}

/// One HTTP/1.1 POST, written by hand: the Tapo bulb wants a fixed
/// Content-Length and matches header names case-sensitively. Returns the
/// body (nil on failure); *cookie gets TP_SESSIONID=… if the reply set one.
static NSData *httpPost(NSString *host, NSString *path, NSData *body, NSString *sendCookie,
                        NSString **cookie) {
  int fd = NCTcpConnect(host, 80, 3);
  if (fd < 0) return nil;
  NSMutableString *head = [NSMutableString stringWithFormat:
      @"POST %@ HTTP/1.1\r\nHost: %@\r\nContent-Type: application/octet-stream\r\n"
      @"Content-Length: %lu\r\nAccept: */*\r\n", path, host, (unsigned long)body.length];
  if (sendCookie) [head appendFormat:@"Cookie: %@\r\n", sendCookie];
  [head appendString:@"\r\n"];
  NSData *result = nil;
  if (sendAll(fd, cat(@[utf8(head), body]))) {
    NSMutableData *buf = [NSMutableData data];
    uint8_t chunk[4096];
    NSInteger headerEnd = -1, contentLength = -1;
    while (YES) {
      ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
      if (n <= 0) break;
      [buf appendBytes:chunk length:n];
      if (headerEnd < 0) {
        NSRange r = [buf rangeOfData:utf8(@"\r\n\r\n") options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) {
          headerEnd = r.location + 4;
          NSString *h = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                              encoding:NSISOLatin1StringEncoding];
          for (NSString *line in [h componentsSeparatedByString:@"\r\n"]) {
            if ([line.lowercaseString hasPrefix:@"content-length:"])
              contentLength = [[line substringFromIndex:15] integerValue];
          }
        }
      }
      if (headerEnd >= 0 && contentLength >= 0 && (NSInteger)buf.length >= headerEnd + contentLength) break;
    }
    if (headerEnd >= 0) {
      NSString *h = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, headerEnd)]
                                          encoding:NSISOLatin1StringEncoding];
      NSArray *lines = [h componentsSeparatedByString:@"\r\n"];
      NSArray *status = [lines.firstObject componentsSeparatedByString:@" "];
      if (status.count > 1 && [status[1] integerValue] == 200) {
        NSInteger len = contentLength >= 0 ? MIN(contentLength, (NSInteger)buf.length - headerEnd)
                                           : (NSInteger)buf.length - headerEnd;
        result = [buf subdataWithRange:NSMakeRange(headerEnd, len)];
        for (NSString *line in lines) {
          if (![line.lowercaseString hasPrefix:@"set-cookie:"]) continue;
          NSRange r = [line rangeOfString:@"TP_SESSIONID="];
          if (r.location == NSNotFound) continue;
          NSString *rest = [line substringFromIndex:r.location];
          NSRange semi = [rest rangeOfString:@";"];
          if (cookie) *cookie = semi.location == NSNotFound ? rest : [rest substringToIndex:semi.location];
        }
      }
    }
  }
  close(fd);
  return result;
}

static id jsonParse(NSData *d) {
  return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
}

/// JSON as the devices expect it. iOS writes "/" as "\/" (valid JSON, but
/// the Gree firmware's parser rejects it — base64 is full of slashes).
static NSData *jsonData(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return utf8([s stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]);
}

// ── Lights ───────────────────────────────────────────────────────────────

@implementation NCLight
- (instancetype)initWithName:(NSString *)name dimmable:(BOOL)dimmable {
  if ((self = [super init])) {
    _name = [name copy];
    _dimmable = dimmable;
    _queue = dispatch_queue_create("nightclock.light", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
- (BOOL)readOn:(BOOL *)on brightness:(NSInteger *)brightness { return NO; }
- (BOOL)setPower:(BOOL)on { return NO; }
- (BOOL)setBrightness:(NSInteger)percent { return NO; }
@end

/// A Tapo bulb on KLAP v2. The auth hash is sha256(sha1(email)+sha1(password)).
@interface NCTapoLight : NCLight
@end

@implementation NCTapoLight {
  NSString *_host;
  NSData *_auth;
  // The session: about a day long, dropped by a bulb reboot.
  NSString *_cookie;
  NSData *_key, *_ivBase, *_sig;
  int32_t _seq;
}

- (instancetype)initWithName:(NSString *)name host:(NSString *)host auth:(NSData *)auth dimmable:(BOOL)dimmable {
  if ((self = [super initWithName:name dimmable:dimmable])) {
    _host = host;
    _auth = auth;
  }
  return self;
}

- (BOOL)handshake {
  _cookie = nil;
  NSData *local = NCRandomBytes(16);
  NSString *cookie = nil;
  NSData *body = httpPost(_host, @"/app/handshake1", local, nil, &cookie);
  if (body.length < 48 || !cookie) return NO;
  NSData *remote = [body subdataWithRange:NSMakeRange(0, 16)];
  if (![sha256(cat(@[local, remote, _auth])) isEqualToData:[body subdataWithRange:NSMakeRange(16, 32)]])
    return NO;  // Wrong TAPO_HASH.
  if (!httpPost(_host, @"/app/handshake2", sha256(cat(@[remote, local, _auth])), cookie, NULL)) return NO;
  NSData *(^derive)(NSString *) = ^(NSString *label) { return sha256(cat(@[utf8(label), local, remote, self->_auth])); };
  _key = [derive(@"lsk") subdataWithRange:NSMakeRange(0, 16)];
  NSData *iv = derive(@"iv");
  _ivBase = [iv subdataWithRange:NSMakeRange(0, 12)];
  uint32_t seqBE;
  [iv getBytes:&seqBE range:NSMakeRange(28, 4)];
  _seq = (int32_t)ntohl(seqBE);
  _sig = [derive(@"ldk") subdataWithRange:NSMakeRange(0, 28)];
  _cookie = cookie;
  return YES;
}

- (NSDictionary *)request:(NSDictionary *)body {
  _seq += 1;
  uint32_t be = htonl((uint32_t)_seq);
  NSData *seqBytes = [NSData dataWithBytes:&be length:4];
  NSData *iv = cat(@[_ivBase, seqBytes]);
  NSData *cipher = aes(YES, _key, iv, jsonData(body));
  NSData *signature = sha256(cat(@[_sig, seqBytes, cipher]));
  NSString *path = [NSString stringWithFormat:@"/app/request?seq=%d", _seq];
  NSData *res = httpPost(_host, path, cat(@[signature, cipher]), _cookie, NULL);
  if (res.length <= 32) return nil;
  NSDictionary *json = jsonParse(aes(NO, _key, iv, [res subdataWithRange:NSMakeRange(32, res.length - 32)]));
  return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

/// One call, handshaking first if needed and once more on any failure.
- (NSDictionary *)call:(NSString *)method params:(NSDictionary *)params {
  for (int attempt = 0; attempt < 2; attempt++) {
    if (!_cookie && ![self handshake]) continue;
    NSMutableDictionary *body = [@{@"method": method,
                                   @"requestTimeMils": @((long long)([NSDate date].timeIntervalSince1970 * 1000))} mutableCopy];
    if (params) body[@"params"] = params;
    NSDictionary *res = [self request:body];
    if (res && [res[@"error_code"] isKindOfClass:NSNumber.class] && [res[@"error_code"] integerValue] == 0) {
      NSDictionary *result = res[@"result"];
      return [result isKindOfClass:NSDictionary.class] ? result : @{};
    }
    _cookie = nil;
  }
  return nil;
}

- (BOOL)readOn:(BOOL *)on brightness:(NSInteger *)brightness {
  NSDictionary *info = [self call:@"get_device_info" params:nil];
  if (!info) return NO;
  *on = [info[@"device_on"] boolValue];
  *brightness = [info[@"brightness"] isKindOfClass:NSNumber.class] ? [info[@"brightness"] integerValue] : -1;
  return YES;
}

- (BOOL)setPower:(BOOL)on {
  return [self call:@"set_device_info" params:@{@"device_on": on ? @YES : @NO}] != nil;
}

- (BOOL)setBrightness:(NSInteger)percent {
  return [self call:@"set_device_info"
             params:@{@"device_on": @YES, @"brightness": @(MAX(1, MIN(100, percent)))}] != nil;
}

@end

/// A Mi/Mijia bulb over miIO (UDP 54321). Newer bulbs speak MIoT
/// (set_properties, siid 2), older ones the legacy set_power/set_bright —
/// found on first use.
@interface NCMiLight : NCLight
@end

/// Why a Mi call failed: the bulb refused it (try the other dialect) or
/// didn't answer at all.
typedef NS_ENUM(NSInteger, NCMiResult) { NCMiOk, NCMiRefused, NCMiNoReply };

@implementation NCMiLight {
  NSString *_host;
  NSData *_token, *_key, *_iv;
  int _id;
  int _miot;  // -1 unknown, 0 legacy, 1 MIoT
}

- (instancetype)initWithName:(NSString *)name host:(NSString *)host token:(NSData *)token dimmable:(BOOL)dimmable {
  if ((self = [super initWithName:name dimmable:dimmable])) {
    _host = host;
    _token = token;
    _key = md5(token);
    _iv = md5(cat(@[_key, token]));
    _id = 1 + arc4random_uniform(9000);
    _miot = -1;
  }
  return self;
}

- (NCMiResult)send:(NSString *)method params:(NSArray *)params result:(id *)result {
  // The hello gives the device id and its clock, which every packet carries.
  uint8_t hello[32] = {0x21, 0x31, 0x00, 0x20};
  memset(hello + 4, 0xff, 28);
  NSData *h = NCUdpExchange(_host, 54321, [NSData dataWithBytes:hello length:32], 3, 1);
  if (h.length < 16) return NCMiNoReply;
  uint32_t deviceId, stamp;
  [h getBytes:&deviceId range:NSMakeRange(8, 4)];
  [h getBytes:&stamp range:NSMakeRange(12, 4)];
  stamp = htonl(ntohl(stamp) + 1);

  _id = _id >= 9999 ? 1 : _id + 1;
  NSData *payload = aes(YES, _key, _iv, jsonData(@{@"id": @(_id), @"method": method, @"params": params}));
  NSMutableData *packet = [NSMutableData dataWithLength:32];
  uint8_t *p = packet.mutableBytes;
  p[0] = 0x21; p[1] = 0x31;
  uint16_t len = htons(32 + payload.length);
  memcpy(p + 2, &len, 2);
  memcpy(p + 8, &deviceId, 4);
  memcpy(p + 12, &stamp, 4);
  NSData *sum = md5(cat(@[[packet subdataWithRange:NSMakeRange(0, 16)], _token, payload]));
  memcpy(p + 16, sum.bytes, 16);
  [packet appendData:payload];

  NSData *reply = NCUdpExchange(_host, 54321, packet, 3, 1);
  if (reply.length <= 32) return NCMiNoReply;
  NSData *plain = aes(NO, _key, _iv, [reply subdataWithRange:NSMakeRange(32, reply.length - 32)]);
  if (!plain) return NCMiNoReply;
  NSString *text = [[[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding]
      stringByReplacingOccurrencesOfString:@"\0" withString:@""];
  NSDictionary *res = jsonParse(utf8(text ?: @""));
  if (![res isKindOfClass:NSDictionary.class]) return NCMiNoReply;
  if (res[@"error"]) return NCMiRefused;
  if (result) *result = res[@"result"];
  return NCMiOk;
}

/// A MIoT property call; refused if any property reports a non-zero code.
- (NCMiResult)properties:(NSString *)method props:(NSArray *)props values:(NSArray **)values {
  id r = nil;
  NCMiResult res = [self send:method params:props result:&r];
  if (res != NCMiOk) return res;
  if (![r isKindOfClass:NSArray.class]) return NCMiRefused;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *prop in r) {
    if (![prop isKindOfClass:NSDictionary.class] || [prop[@"code"] integerValue] != 0) return NCMiRefused;
    [out addObject:prop[@"value"] ?: NSNull.null];
  }
  if (values) *values = out;
  return NCMiOk;
}

/// Runs [miot], falling back to [legacy] when the bulb refuses it, and
/// remembers which dialect worked.
- (BOOL)either:(NCMiResult (^)(void))miot legacy:(NCMiResult (^)(void))legacy {
  if (_miot == 0) return legacy() == NCMiOk;
  NCMiResult r = miot();
  if (r == NCMiOk) { _miot = 1; return YES; }
  if (r == NCMiNoReply || _miot == 1) return NO;
  if (legacy() == NCMiOk) { _miot = 0; return YES; }
  return NO;
}

- (BOOL)readOn:(BOOL *)on brightness:(NSInteger *)brightness {
  __block BOOL o = NO;
  __block NSInteger b = -1;
  BOOL ok = [self either:^NCMiResult {
    NSArray *v = nil;
    NCMiResult r = [self properties:@"get_properties"
                              props:@[@{@"did": @"on", @"siid": @2, @"piid": @1},
                                      @{@"did": @"bright", @"siid": @2, @"piid": @2}]
                             values:&v];
    if (r == NCMiOk && v.count == 2) {
      o = [v[0] isKindOfClass:NSNumber.class] && [v[0] boolValue];
      b = [v[1] isKindOfClass:NSNumber.class] ? [v[1] integerValue] : -1;
    }
    return r;
  } legacy:^NCMiResult {
    id r = nil;
    NCMiResult res = [self send:@"get_prop" params:@[@"power", @"bright"] result:&r];
    if (res == NCMiOk && [r isKindOfClass:NSArray.class] && [r count] >= 2) {
      o = [[r[0] description] isEqualToString:@"on"];
      b = [[r[1] description] integerValue];
    }
    return res;
  }];
  *on = o;
  *brightness = b;
  return ok;
}

- (BOOL)setPower:(BOOL)on {
  return [self either:^NCMiResult {
    return [self properties:@"set_properties"
                      props:@[@{@"did": @"on", @"siid": @2, @"piid": @1, @"value": on ? @YES : @NO}]
                     values:NULL];
  } legacy:^NCMiResult {
    return [self send:@"set_power" params:@[on ? @"on" : @"off"] result:NULL];
  }];
}

- (BOOL)setBrightness:(NSInteger)percent {
  NSInteger p = MAX(1, MIN(100, percent));
  return [self either:^NCMiResult {
    return [self properties:@"set_properties"
                      props:@[@{@"did": @"on", @"siid": @2, @"piid": @1, @"value": @YES},
                              @{@"did": @"bright", @"siid": @2, @"piid": @2, @"value": @(p)}]
                     values:NULL];
  } legacy:^NCMiResult {
    // Legacy bulbs refuse set_bright while off.
    NCMiResult r = [self send:@"set_power" params:@[@"on"] result:NULL];
    return r == NCMiOk ? [self send:@"set_bright" params:@[@(p)] result:NULL] : r;
  }];
}

@end

NSArray<NCLight *> *NCConfiguredLights(void) {
  NSMutableSet *dimmable = [NSMutableSet set];
  for (NSString *n in [@DIMMABLE_LIGHTS componentsSeparatedByString:@","])
    [dimmable addObject:[n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
  NSMutableArray *lights = [NSMutableArray array];
  // A key of the wrong shape is a config slip: skip that light.
  if (isHex(@TAPO_HASH, 64)) {
    for (NSArray *e in NCEntries(@TAPO_LIGHTS))
      [lights addObject:[[NCTapoLight alloc] initWithName:e[0] host:e[1] auth:NCHex(@TAPO_HASH)
                                                  dimmable:[dimmable containsObject:e[0]]]];
  }
  for (NSArray *e in NCEntries(@MI_LIGHTS)) {
    NSArray *parts = [e[1] componentsSeparatedByString:@"/"];
    if (parts.count != 2 || !isHex(parts[1], 32)) continue;
    [lights addObject:[[NCMiLight alloc] initWithName:e[0] host:parts[0] token:NCHex(parts[1])
                                              dimmable:[dimmable containsObject:e[0]]]];
  }
  return lights;
}

// ── Gree AC ──────────────────────────────────────────────────────────────

// One-shot AES-GCM: in libcommonCrypto since iOS 6, but not in the public
// headers.
extern CCCryptorStatus CCCryptorGCM(CCOperation op, CCAlgorithm alg, const void *key, size_t keyLength,
                                    const void *iv, size_t ivLen, const void *aData, size_t aDataLen,
                                    const void *dataIn, size_t dataInLength, void *dataOut,
                                    void *tagOut, size_t *tagLength);

static const uint8_t kGcmNonce[12] = {0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5a, 0x51, 0x6c, 0x5e, 0x63, 0x13};
static const char kGcmAad[] = "qualcomm-test";

/// AES-GCM with Gree's fixed nonce and AAD. Decrypting ignores the tag, as
/// greeclimate does. Returns the output; *tag gets the 16-byte tag.
static NSData *gcm(BOOL encrypt, NSData *key, NSData *data, NSData **tag) {
  NSMutableData *out = [NSMutableData dataWithLength:data.length];
  NSMutableData *t = [NSMutableData dataWithLength:16];
  size_t tagLen = 16;
  CCCryptorStatus st = CCCryptorGCM(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES128, key.bytes, key.length,
                                    kGcmNonce, 12, kGcmAad, strlen(kGcmAad), data.bytes, data.length,
                                    out.mutableBytes, t.mutableBytes, &tagLen);
  if (st != kCCSuccess) return nil;
  if (tag) *tag = t;
  return out;
}

@implementation NCAcState
@end

@implementation NCGreeAc {
  NSString *_host, *_mac;
  NSData *_key;
  BOOL _gcm;
}

- (instancetype)initWithName:(NSString *)name host:(NSString *)host {
  if ((self = [super init])) {
    _name = [name copy];
    _host = host;
    _queue = dispatch_queue_create("nightclock.ac", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

static NSData *genericKey(BOOL gcm) { return utf8(gcm ? @"{yxAHAY_Lm6pbC/<" : @"a3K8Bx%2r8Y7#xDh"); }

/// Decrypts a reply's pack: AES-ECB on old firmware, AES-GCM on new. The
/// JSON ends at the last brace; firmware pads inconsistently.
- (NSDictionary *)open:(NSData *)reply key:(NSData *)key gcm:(BOOL)useGcm {
  NSDictionary *msg = jsonParse(reply);
  if (![msg isKindOfClass:NSDictionary.class] || ![msg[@"pack"] isKindOfClass:NSString.class]) return nil;
  NSData *data = [[NSData alloc] initWithBase64EncodedString:msg[@"pack"] options:0];
  NSData *plain = useGcm ? gcm(NO, key, data, NULL) : data.length % 16 == 0 ? aes(NO, key, nil, data) : nil;
  NSString *text = [[NSString alloc] initWithData:plain ?: [NSData data] encoding:NSISOLatin1StringEncoding];
  NSRange end = [text rangeOfString:@"}" options:NSBackwardsSearch];
  if (end.location == NSNotFound) return nil;
  NSDictionary *pack = jsonParse([[text substringToIndex:end.location + 1] dataUsingEncoding:NSISOLatin1StringEncoding]);
  return [pack isKindOfClass:NSDictionary.class] ? pack : nil;
}

- (NSDictionary *)exchange:(NSDictionary *)pack key:(NSData *)key gcm:(BOOL)useGcm i:(int)i {
  NSMutableDictionary *full = [pack mutableCopy];
  full[@"mac"] = _mac;
  NSMutableDictionary *msg = [@{@"cid": @"app", @"i": @(i), @"t": @"pack", @"uid": @0, @"tcid": _mac} mutableCopy];
  if (useGcm) {
    NSData *tag = nil;
    NSData *sealed = gcm(YES, key, jsonData(full), &tag);
    if (!sealed) return nil;
    msg[@"pack"] = [sealed base64EncodedStringWithOptions:0];
    msg[@"tag"] = [tag base64EncodedStringWithOptions:0];
  } else {
    NSMutableData *plain = [jsonData(full) mutableCopy];
    uint8_t pad = 16 - plain.length % 16;
    for (int k = 0; k < pad; k++) [plain appendBytes:&pad length:1];
    msg[@"pack"] = [aes(YES, key, nil, plain) base64EncodedStringWithOptions:0];
  }
  NSData *reply = NCUdpExchange(_host, 7000, jsonData(msg), 3, 1.2);
  return reply ? [self open:reply key:key gcm:useGcm] : nil;
}

/// Finds the unit's MAC, then binds for its own key — AES-GCM first (the
/// user's units answer only that, though they report firmware V3.4), then
/// the older AES-ECB.
- (BOOL)bind {
  if (!_mac) {
    NSData *reply = NCUdpExchange(_host, 7000, utf8(@"{\"t\":\"scan\"}"), 3, 1.2);
    // Scan replies are always ECB.
    NSDictionary *pack = reply ? [self open:reply key:genericKey(NO) gcm:NO] : nil;
    NSString *mac = pack[@"mac"] ?: pack[@"cid"];
    if (![mac isKindOfClass:NSString.class]) return NO;
    _mac = mac;
  }
  for (int g = 1; g >= 0; g--) {
    NSDictionary *res = [self exchange:@{@"t": @"bind", @"uid": @0} key:genericKey(g) gcm:g i:1];
    if ([res[@"t"] isEqual:@"bindok"] && [res[@"key"] isKindOfClass:NSString.class]) {
      _key = utf8(res[@"key"]);
      _gcm = g;
      return YES;
    }
  }
  return NO;
}

/// A call with the unit's key, binding first; a rebooted unit may have a
/// new key, so a failure re-binds once.
- (NSDictionary *)call:(NSDictionary *)pack {
  for (int attempt = 0; attempt < 2; attempt++) {
    if (!_key && ![self bind]) continue;
    NSDictionary *res = [self exchange:pack key:_key gcm:_gcm i:0];
    if (res) return res;
    _key = nil;
  }
  return nil;
}

- (NCAcState *)state {
  NSArray *cols = @[@"Pow", @"SetTem", @"Mod", @"TemSen"];
  NSDictionary *res = [self call:@{@"cols": cols, @"t": @"status"}];
  NSArray *dat = res[@"dat"];
  if (![dat isKindOfClass:NSArray.class] || dat.count < cols.count) return nil;
  NCAcState *s = [NCAcState new];
  s.on = [dat[0] integerValue] == 1;
  s.setTemp = [dat[1] integerValue];
  s.mode = [dat[2] integerValue];
  // TemSen carries a +40 offset on most firmware; 0 means no sensor.
  NSInteger sensor = [dat[3] integerValue];
  s.roomTemp = sensor == 0 ? NSNotFound : (sensor >= 40 ? sensor - 40 : sensor);
  return s;
}

- (BOOL)command:(NSDictionary *)values {
  return [self call:@{@"opt": values.allKeys, @"p": [values objectsForKeys:values.allKeys notFoundMarker:@0],
                      @"t": @"cmd"}] != nil;
}

- (BOOL)setPower:(BOOL)on { return [self command:@{@"Pow": @(on ? 1 : 0)}]; }

- (BOOL)setTemp:(NSInteger)celsius {
  return [self command:@{@"TemUn": @0, @"SetTem": @(MAX(NCAcMinTemp, MIN(NCAcMaxTemp, celsius)))}];
}

@end

NSArray<NCGreeAc *> *NCConfiguredAcs(void) {
  NSMutableArray *acs = [NSMutableArray array];
  for (NSArray *e in NCEntries(@GREE_AC)) [acs addObject:[[NCGreeAc alloc] initWithName:e[0] host:e[1]]];
  return acs;
}
