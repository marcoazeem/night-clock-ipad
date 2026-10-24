"""Makes an old iPhoneOS SDK (theos/sdks) link with today's Apple linker.

1. Its .tbd stubs list simulator archs (i386, x86_64) beside the device
   ones; the new linker then takes them for simulator libraries ("built for
   'iOS-simulator'"). Drop the simulator archs.
2. libobjc's stub lacks the 32-bit-only objc_msgSend_stret family, which
   armv7 code calls for struct returns (CGRect etc.). Add them.

Usage: python3 fix_sdk.py <path to iPhoneOS10.3.sdk copy>
"""

import os
import re
import sys

root = sys.argv[1]
archs = re.compile(r'(archs:\s*\[)([^\]]*)(\])')


def keep_device(m):
    kept = [a.strip() for a in m.group(2).split(',')
            if a.strip() and a.strip() not in ('i386', 'x86_64')]
    return m.group(1) + ' ' + ', '.join(kept or ['armv7s']) + ' ' + m.group(3)


for d, _, files in os.walk(root):
    for f in files:
        if f.endswith('.tbd'):
            p = os.path.join(d, f)
            t = open(p, encoding='utf-8', errors='surrogateescape').read()
            u = archs.sub(keep_device, t)
            if u != t:
                open(p, 'w', encoding='utf-8', errors='surrogateescape').write(u)

objc = os.path.join(root, 'usr/lib/libobjc.A.tbd')
t = open(objc).read()
if '_objc_msgSend_stret' not in t:
    stret = """  - archs:                [ armv7, armv7s ]
    symbols:              [ _objc_msgSend_stret, _objc_msgSendSuper_stret,
                            _objc_msgSendSuper2_stret, _method_invoke_stret ]
"""
    open(objc, 'w').write(t.replace('exports:\n', 'exports:\n' + stret, 1))
print('SDK fixed:', root)
