"""Search the PC philanthropy report PDF for elasticity / $1.50 / uplift passages."""
import os
import re
import sys

from pypdf import PdfReader

sys.stdout.reconfigure(encoding="utf-8")
PDF = os.path.join(os.environ["TEMP"], "pc_philanthropy.pdf")

r = PdfReader(PDF)
print("pages:", len(r.pages))

pattern = re.compile(r"elasticit|price of giving|1\.50|tax-price", re.I)
pages = {}
for i, p in enumerate(r.pages):
    t = p.extract_text() or ""
    if pattern.search(t):
        pages[i] = t

print("hit pages:", sorted(pages))

if len(sys.argv) > 1:
    for a in sys.argv[1:]:
        i = int(a)
        t = r.pages[i].extract_text() or ""
        print(f"\n===== PAGE {i} =====\n{t}")
