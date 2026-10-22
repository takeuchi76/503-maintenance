#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import print_function
import os, re, sys, subprocess, tempfile

CONF_DIR = '/etc/httpd/conf.d'
SOURCE = os.path.join(CONF_DIR, 'ssl.cms.conf')
DISABLED = SOURCE + '.disabled'
DEST = os.path.join(CONF_DIR, 'ssl.maintenance.conf')
TEMPLATE = '/tmp/ssl.maintenance.conf.template'

ALLOWED = ('ServerName', 'ServerAlias', 'SSLCertificateFile',
           'SSLCertificateKeyFile', 'SSLCertificateChainFile',
           'SSLCACertificateFile', 'SSLProtocol', 'SSLCipherSuite',
           'SSLHonorCipherOrder', 'SSLVerifyClient', 'SSLVerifyDepth')

def fail(message):
    sys.stderr.write('ERROR: %s\n' % message)
    sys.exit(1)

def run(*args):
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = p.communicate()[0]
    return p.returncode, output

if os.geteuid() != 0:
    fail('Run as root')
if not os.path.isfile(SOURCE):
    fail('Missing %s' % SOURCE)
if os.path.exists(DISABLED):
    fail('Backup already exists: %s' % DISABLED)
if os.path.exists(DEST):
    fail('Target already exists: %s (remove or rename it manually)' % DEST)
if not os.path.isfile(TEMPLATE):
    fail('Missing template: %s' % TEMPLATE)

with open(SOURCE) as f:
    original = f.read()
with open(TEMPLATE) as f:
    template = f.read()
if template.count('#SSL_SETTINGS#') != 1:
    fail('Template must contain exactly one #SSL_SETTINGS#')
match = re.search(r'(?ims)^\s*<VirtualHost\s+[^>]+>.*?^\s*</VirtualHost\s*>', template)
if not match:
    fail('Template must contain a VirtualHost block')
header = template[:match.start()]
block = template[match.start():match.end()]
footer = template[match.end():]

# Keep one certificate identity per original VirtualHost, never merge them.
source_blocks = re.findall(r'(?ims)^\s*<VirtualHost\s+[^>]+>(.*?)^\s*</VirtualHost\s*>', original)
if not source_blocks:
    fail('No VirtualHost blocks found')
rendered = []
for idx, source_block in enumerate(source_blocks):
    directives = []
    seen = {}
    for raw_line in source_block.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'^([A-Za-z][A-Za-z0-9]*)\s+(.+)$', line)
        if not m:
            continue
        name = m.group(1)
        if name.lower() in [x.lower() for x in ALLOWED]:
            if name.lower() != 'serveralias' and name.lower() in seen:
                fail('Repeated %s in source VirtualHost %d' % (name, idx + 1))
            seen[name.lower()] = True
            directives.append('    ' + line)
    for required in ('servername', 'sslcertificatefile', 'sslcertificatekeyfile'):
        if required not in seen:
            fail('Missing %s in source VirtualHost %d' % (required, idx + 1))
    rendered.append(block.replace('#SSL_SETTINGS#', '\n'.join(directives)))

output = header + '\n\n'.join(rendered) + footer
fd, tmp = tempfile.mkstemp(prefix='.maintenance-ssl-', dir=CONF_DIR)
try:
    os.write(fd, output)
    os.fchmod(fd, 0o644)
finally:
    os.close(fd)

# The source must be disabled for Apache to validate the new configuration.
try:
    os.rename(SOURCE, DISABLED)
    os.rename(tmp, DEST)
    rc, message = run('/usr/sbin/httpd', '-t')
    if rc:
        os.unlink(DEST)
        os.rename(DISABLED, SOURCE)
        fail('Apache configtest failed, original restored:\n%s' % message)
    print('Created %s with %d VirtualHost(s)' % (DEST, len(rendered)))
    print('Original preserved as %s' % DISABLED)
    print('Apache syntax OK. Reload manually after checking httpd -S.')
except Exception as e:
    if os.path.exists(tmp):
        os.unlink(tmp)
    if os.path.exists(DISABLED) and not os.path.exists(SOURCE) and not os.path.exists(DEST):
        os.rename(DISABLED, SOURCE)
    fail(str(e))
