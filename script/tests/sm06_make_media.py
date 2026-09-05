"""Independent Pillow/reportlab fixture authoring; never imported by native tests.

Run manually using the bundled workspace Python. The manifest freezes acceptance
before native execution; this script adds source bytes, not native expectations.
"""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from pypdf import PdfReader, PdfWriter
from pypdf.generic import RectangleObject

root = Path("Tests/SlateSyncMediaTests/Fixtures/SM06")
font = ImageFont.truetype("/System/Library/Fonts/STHeiti Light.ttc", 42)
im = Image.new("RGBA", (800, 1000), (255,255,255,0))
d = ImageDraw.Draw(im)
d.rectangle((0,0,160,140), fill="red")
d.rectangle((640,860,799,999), fill="blue")
d.text((180,25), "场 镜 次 SLATE", font=font, fill="black")
for i in range(12):
    y = 170 + i * 55
    d.text((25,y), f"C{i+1:03}  12A  03  2  OK", font=font, fill="black")
    d.line((20,y+50,780,y+50), fill="black", width=2)
im.save(root / "slate-alpha.png")
rgb = Image.new("RGB",im.size,"white"); rgb.paste(im,mask=im.getchannel("A"))
rgb.save(root / "slate.jpg",quality=98)
rgb.save(root / "slate.webp",lossless=True)
exif=Image.Exif(); exif[274]=6
rgb.save(root / "slate-exif6.jpg",quality=98,exif=exif)
Image.new("RGB",(1,1),"white").save(root / "tiny.png")

for count in [1,20,21]:
    path=root / f"pages-{count}.pdf"
    pdf=canvas.Canvas(str(path),pagesize=(200,250),invariant=1)
    for i in range(count):
        pdf.setFillColorRGB(1,0,0);pdf.rect(0,215,40,35,fill=1,stroke=0)
        pdf.setFillColorRGB(0,0,1);pdf.rect(160,0,40,35,fill=1,stroke=0)
        pdf.setFillColorRGB(0,0,0);pdf.setFont("Helvetica",16);pdf.drawString(45,225,f"PAGE {i+1}")
        for j in range(8): pdf.drawString(10,190-j*20,f"C{j+1:03} 12A 03 2")
        pdf.showPage()
    pdf.save()
source=PdfReader(root/"pages-1.pdf")
for name,rotation,crop in [("rotated",90,None),("crop",0,[20,25,180,225])]:
    writer=PdfWriter();writer.add_page(source.pages[0]);page=writer.pages[0]
    if rotation: page.rotate(rotation)
    if crop: page.cropbox=RectangleObject(crop)
    writer.write(root/f"{name}.pdf")
writer=PdfWriter();writer.add_page(source.pages[0]);writer.encrypt("fixture-password");writer.write(root/"locked.pdf")
PdfWriter().write(root/"empty.pdf")
(root/"broken.pdf").write_bytes(b"%PDF-1.7\nnot-a-document")
# Independent size fixtures exercise bounded rendering without allocating a
# correspondingly large bitmap, and preserve explicitly invalid PDF bounds.
for name, bounds in [("huge-bounds", [0, 0, 1_000_000_000, 1_000_000_000]),
                     ("invalid-bounds", [0, 0, 0, 0])]:
    writer = PdfWriter(); writer.add_blank_page(width=100, height=100)
    writer.pages[0].mediabox = RectangleObject(bounds)
    writer.write(root/f"{name}.pdf")
manifest=json.loads((root/"manifest.json").read_text())
for path in sorted(root.iterdir()):
    if path.suffix in [".png",".jpg",".webp",".pdf"]:
        data=path.read_bytes();manifest["files"][path.name]={"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()}
(root/"manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+"\n")
