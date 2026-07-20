#!/usr/bin/env python3
"""
Build a faithful 20-page CRG Solar Proposal as a `presentation`-schema JSON
for the Zig PDF generator (`pdf-gen --presentation <this.json> out.pdf`).

The reference is crgdirect.co.uk/example-solar-proposal.pdf (dompdf 2.0.1).
We reproduce it on an A4 canvas with absolute-positioned text/tables/images.

Data-driven: the QUOTE dict at the bottom holds every customer/system value,
so a server action can fill it per-lead and regenerate. Brand assets live in
assets/ and are inlined as base64.
"""
import base64, json, math, pathlib

HERE = pathlib.Path(__file__).parent
# Brand assets are canonical under the generator's src/ (so the Zig module can
# @embedFile them); this builder reads the same copy.
ASSETS = HERE.parent.parent / "src" / "crg_assets"

# ---- A4 canvas (points, top-left origin) -----------------------------------
PW, PH = 595.28, 841.89
ML, MR = 45.0, 45.0            # left / right margins
CW = PW - ML - MR              # content width ~505

# ---- palette (sampled from the reference) ----------------------------------
GREEN   = "#38761D"            # section headings (srgb 56,118,29)
BODY    = "#000000"
GREY    = "#3a3a3a"
LINK    = "#1155cc"
BAND_LT = "#ededed"            # perf-table section-header band
BAND_MD = "#bfbfbf"            # figures / wind-loading header band
BLUE_LT = "#dce6f1"           # perf-table shaded data rows
HAIR    = "#000000"

# ---- Helvetica / Helvetica-Bold AFM widths (units per 1000 em) -------------
_HELV = {
' ':278,'!':278,'"':355,'#':556,'$':556,'%':889,'&':667,"'":191,'(':333,')':333,
'*':389,'+':584,',':278,'-':333,'.':278,'/':278,'0':556,'1':556,'2':556,'3':556,
'4':556,'5':556,'6':556,'7':556,'8':556,'9':556,':':278,';':278,'<':584,'=':584,
'>':584,'?':556,'@':1015,'A':667,'B':667,'C':722,'D':722,'E':667,'F':611,'G':778,
'H':722,'I':278,'J':500,'K':667,'L':556,'M':833,'N':722,'O':778,'P':667,'Q':778,
'R':722,'S':667,'T':611,'U':722,'V':667,'W':944,'X':667,'Y':667,'Z':611,'[':278,
'\\':278,']':278,'^':469,'_':556,'`':333,'a':556,'b':556,'c':500,'d':556,'e':556,
'f':278,'g':556,'h':556,'i':222,'j':222,'k':500,'l':222,'m':833,'n':556,'o':556,
'p':556,'q':556,'r':333,'s':500,'t':278,'u':556,'v':500,'w':722,'x':500,'y':500,
'z':500,'{':334,'|':260,'}':334,'~':584,'£':556,'–':556,'—':1000,
'’':191,'‘':191,'“':333,'”':333,'°':400,'•':350,
}
_HELVB = {
' ':278,'!':333,'"':474,'#':556,'$':556,'%':889,'&':722,"'":238,'(':333,')':333,
'*':389,'+':584,',':278,'-':333,'.':278,'/':278,'0':556,'1':556,'2':556,'3':556,
'4':556,'5':556,'6':556,'7':556,'8':556,'9':556,':':333,';':333,'<':584,'=':584,
'>':584,'?':611,'@':975,'A':722,'B':722,'C':722,'D':722,'E':667,'F':611,'G':778,
'H':722,'I':278,'J':556,'K':722,'L':611,'M':833,'N':722,'O':778,'P':667,'Q':778,
'R':722,'S':667,'T':611,'U':722,'V':667,'W':944,'X':667,'Y':667,'Z':611,'[':333,
'\\':278,']':333,'^':584,'_':556,'`':333,'a':556,'b':611,'c':556,'d':611,'e':556,
'f':333,'g':611,'h':611,'i':278,'j':278,'k':556,'l':278,'m':889,'n':611,'o':611,
'p':611,'q':611,'r':389,'s':556,'t':333,'u':611,'v':556,'w':778,'x':556,'y':556,
'z':500,'{':389,'|':280,'}':389,'~':584,'£':556,'–':556,'—':1000,
'’':238,'‘':238,'“':474,'”':474,'°':400,'•':350,
}

def text_width(s, size, bold=False):
    t = _HELVB if bold else _HELV
    return sum(t.get(c, 556) for c in s) * size / 1000.0

def wrap(s, size, maxw, bold=False):
    """Greedy word-wrap into lines fitting maxw. Honours explicit \n."""
    out = []
    for hard in s.split("\n"):
        if hard == "":
            out.append("")
            continue
        words, line = hard.split(" "), ""
        for w in words:
            cand = w if line == "" else line + " " + w
            if text_width(cand, size, bold) <= maxw or line == "":
                line = cand
            else:
                out.append(line)
                line = w
        out.append(line)
    return out

def b64(name):
    d = (ASSETS / name).read_bytes()
    ext = name.rsplit(".", 1)[1].lower()
    mime = "jpeg" if ext in ("jpg", "jpeg") else "png"
    return f"data:image/{mime};base64," + base64.b64encode(d).decode()

# ---- element builders ------------------------------------------------------
class Page:
    def __init__(self, bg="#ffffff"):
        self.els = []
        self.bg = bg
        self.y = 50.0          # cursor: baseline of the NEXT line

    def dict(self):
        return {"background_color": self.bg, "elements": self.els}

    # raw baseline text. Alignment is resolved HERE with our own AFM metrics
    # (the engine's measureTextWidth mis-centres long strings), so we always
    # emit left-aligned at a precomputed x.
    def text(self, x, y, s, size=10.5, color=BODY, bold=False, italic=False, align="left"):
        if align == "center":
            x = x - text_width(s, size, bold) / 2
        elif align == "right":
            x = x - text_width(s, size, bold)
        e = {"type": "text", "content": s, "x": x, "y": y, "font_size": size,
             "color": color}
        if bold: e["font_weight"] = "bold"
        if italic: e["font_style"] = "italic"
        self.els.append(e)
        return e

    def image(self, name, x, y, w, h):
        self.els.append({"type": "image", "base64": b64(name),
                         "x": x, "y": y, "width": w, "height": h})

    def rect(self, x, y, w, h, fill=None, stroke=None, sw=1):
        # explicit null => no fill / no stroke (engine honours JSON null)
        self.els.append({"type": "shape", "shape": "rectangle", "x": x, "y": y,
                         "width": w, "height": h, "fill_color": fill,
                         "stroke_color": stroke, "stroke_width": sw})

    def hline(self, x1, x2, y, color=HAIR, w=1.0):
        self.els.append({"type": "shape", "shape": "line", "x": x1, "y": y,
                         "width": x2 - x1, "height": 0, "stroke_color": color,
                         "stroke_width": w})

    # --- flowing helpers (advance self.y, which is the baseline) ---
    def gap(self, dy):
        self.y += dy

    def heading(self, s, size=21, color=GREEN, gap_before=0, gap_after=14):
        self.y += gap_before + size
        self.text(ML, self.y, s, size=size, color=color)
        self.y += gap_after

    def para(self, s, size=10.5, color=BODY, bold=False, italic=False,
             x=ML, maxw=CW, lh=1.32, gap_after=8, align="left"):
        lines = wrap(s, size, maxw, bold)
        step = size * lh
        # text() treats the anchor as: left->left edge, center->centre, right->right edge
        anchor = x if align == "left" else (x + maxw / 2 if align == "center" else x + maxw)
        for ln in lines:
            self.y += step
            self.text(anchor, self.y, ln, size=size, color=color, bold=bold,
                      italic=italic, align=align)
        self.y += gap_after
        return self.y

    def bullets(self, items, size=10.5, color=BODY, x=ML, maxw=CW, lh=1.3,
                gap_after=8, indent=16):
        step = size * lh
        for it in items:
            lines = wrap(it, size, maxw - indent, False)
            first = True
            for ln in lines:
                self.y += step
                if first:
                    self.text(x + 3, self.y, "•", size=size, color=color)
                    first = False
                self.text(x + indent, self.y, ln, size=size, color=color)
            self.y += 2
        self.y += gap_after

    def link(self, url, size=10.5, x=ML, gap_after=6):
        self.y += size * 1.3
        self.text(x, self.y, url, size=size, color=LINK)
        self.y += gap_after

    # Full-fidelity table built from primitives. The presentation `table`
    # element ignores per-cell bg/align/color, so we draw cells ourselves.
    # rows: list of dicts {h, cells:[{t,align,bg,bold,color,size}], widths?}.
    # `widths` overrides col_w for that row (used for full-width section bands).
    def grid(self, x, col_w, rows, y=None, border="#000000", sw=0.7,
             size=9.5, pad=5, lh=1.12, valign="center", min_h=0):
        if y is None:
            y = self.y
        yc = y
        for row in rows:
            widths = row.get("widths", col_w)
            h = row.get("h")
            if h is None:                       # auto-size to tallest wrapped cell
                maxln = 1
                for i, c in enumerate(row["cells"]):
                    t = c.get("t", "")
                    if t:
                        csz = c.get("size", size)
                        maxln = max(maxln, len(wrap(t, csz, widths[i] - 2 * pad,
                                                    c.get("bold", False))))
                h = max(min_h, maxln * size * lh + 2 * pad + 4)
            cx = x
            for i, c in enumerate(row["cells"]):
                w = widths[i]
                bg = c.get("bg")
                if bg:
                    self.rect(cx, yc, w, h, fill=bg)
                if border:
                    self.rect(cx, yc, w, h, stroke=border, sw=sw)
                t = c.get("t", "")
                if t != "":
                    csize = c.get("size", size)
                    cbold = c.get("bold", False)
                    ccolor = c.get("color", BODY)
                    lines = wrap(t, csize, w - 2 * pad, cbold)
                    step = csize * lh
                    block = step * len(lines)
                    if valign == "center":
                        base = yc + (h - block) / 2 + csize * 0.80
                    else:
                        base = yc + csize + pad
                    for k, ln in enumerate(lines):
                        ly = base + k * step
                        al = c.get("align", "left")
                        if al == "left":
                            tx = cx + pad
                        elif al == "center":
                            tx = cx + w / 2
                        else:
                            tx = cx + w - pad
                        self.text(tx, ly, ln, size=csize, color=ccolor,
                                  bold=cbold, align=al)
                cx += w
            yc += h
        self.y = yc
        return yc

    # generic bordered table (grid look, matches perf/figures/wind tables)
    def table(self, x, cols, rows, col_w, y=None, header_bg=BAND_MD,
              header_fg=BODY, row_bg="#ffffff", alt_bg=None, size=9.5,
              header_size=9.5, row_h=20, header_h=20, border="#000000",
              padding=5):
        if y is None:
            y = self.y
        t = {"type": "table", "x": x, "y": y, "columns": cols, "rows": rows,
             "column_widths": col_w, "header_bg_color": header_bg,
             "header_text_color": header_fg, "row_bg_color": row_bg,
             "text_color": BODY, "border_color": border, "border_width": 0.8,
             "font_size": size, "header_font_size": header_size,
             "padding": padding, "row_height": row_h, "header_height": header_h}
        if alt_bg: t["alt_row_bg_color"] = alt_bg
        self.els.append(t)
        self.y = y + header_h + len(rows) * row_h
        return self.y


def cell(s, align="left", color=None, bg=None):
    c = {"content": s, "text_align": align}
    if color: c["color"] = color
    if bg: c["bg_color"] = bg
    return c


pages = []

# ============================================================================
# PAGE 1 — COVER
# ============================================================================
def page_cover(q):
    # The reference page-1 image is a fully-designed cover JPEG (title, logo and
    # URL already baked in). Place it full-bleed — no overlays.
    p = Page()
    p.image("cover_house.jpg", 0, 0, PW, PH)
    return p

# ============================================================================
# PAGE 2 — INTRODUCTION
# ============================================================================
def page_intro(q):
    p = Page()
    p.heading("Introduction", gap_after=6)
    p.y = 430
    p.para("Welcome to CRG Direct. Here’s your bespoke solar quote. In this "
           "quote, you’ll find the cost of your system, your estimated savings "
           "using MCS calculations, and more information about your recommended "
           "solar system.", size=16, lh=1.28, gap_after=26)
    top = p.y
    colw = (CW - 30) / 2
    # left column
    p.y = top
    p.para("At CRG Direct, we believe in delivering quality service that goes "
           "above and beyond for our customers. Our dedicated team works "
           "tirelessly to ensure that every installation is done efficiently and "
           "with the utmost care. We understand the importance of clear "
           "communication and transparency, which is why we make sure our "
           "pricing is always straightforward and competitive.",
           size=9.5, x=ML, maxw=colw, gap_after=8)
    p.para("Customer satisfaction is our top priority, and we are proud of our "
           "5-star reviews on Google. These reviews are a testament to our "
           "commitment to excellence and our unwavering dedication to providing "
           "the best service possible.", size=9.5, x=ML, maxw=colw)
    # right column
    p.y = top
    rx = ML + colw + 30
    p.para("If you are considering CRG Direct for your next project, we encourage "
           "you to visit our website at www.crgdirect.co.uk for more information. "
           "And remember, if you have any questions at all, our friendly team is "
           "always here to help. Thank you for considering CRG Direct for your "
           "solar and home improvement needs.", size=9.5, x=rx, maxw=colw)
    return p

# ============================================================================
# PAGE 3 — YOUR QUOTE
# ============================================================================
def page_quote(q):
    p = Page()
    p.heading("Your quote", gap_after=10)
    p.hline(ML, PW - MR, p.y)
    p.gap(24)
    p.text(PW / 2, p.y, "Recommended System Option", size=15, align="center")
    p.gap(30)
    # 4-column metric row
    labels = [("%s kW" % q["kw"], "System Size"),
              ("£ %s" % q["annual_saving"], "Estimated Annual\nElectricity Bill Savings"),
              ("£ %s" % q["total_price"], "Total System Price"),
              ("£ %s" % q["net_price"], "Net System Price")]
    n = len(labels)
    colc = [ML + CW * (i + 0.5) / n for i in range(n)]
    vy = p.y
    for cx, (val, lab) in zip(colc, labels):
        p.text(cx, vy, val, size=15, align="center")
        ly = vy + 26
        for j, part in enumerate(lab.split("\n")):
            p.text(cx, ly + j * 11, part, size=8, color=GREY, align="center")
    p.y = vy + 52
    # left-aligned summary lines
    for line in ["System Size: %s KWp" % q["kw"],
                 "Total System Price:  £ %s" % q["total_price"],
                 "Estimated Annual Electricity Bill Savings:  £ %s" % q["annual_saving"],
                 "Estimated Lifetime Savings:  £ %s" % q["lifetime_saving"]]:
        p.gap(20); p.text(ML, p.y, line, size=12.5)
    p.gap(16)
    p.hline(ML, PW - MR, p.y)
    p.gap(22)
    p.text(ML, p.y, "Your system is made up of:", size=10.5)
    for line in ["%s %s Panels" % (q["panel_count"], q["panel_model"]),
                 q["battery"], q["inverter"]]:
        p.gap(18); p.text(ML, p.y, line, size=10.5)
    p.gap(16)
    p.para("We’ve estimated you’ll save £ %s over the lifetime of your "
           "system using regulated MCS calculations. You’ll see a breakdown of "
           "this on page 7." % q["lifetime_saving"], size=10.5, gap_after=6)
    p.para("Your total cost includes installation fees and more. We’ll also "
           "handle your DNO application. All equipment is MCS certified.", gap_after=6)
    p.para("These modules comply with the following international standards:", gap_after=6)
    p.para("Carry CE mark", gap_after=6)
    p.para("You are using %s of electricity per year at %sp. We estimate your new "
           "system will produce %s KWH of electricity per annum, giving approx’ "
           "£ %s worth of savings per annum." %
           (q["annual_usage_kwh"], q["tariff_p"], q["annual_gen_kwh"], q["annual_saving"]),
           gap_after=6)
    p.para("The total cost of the system is £ %s MCS calculations predict you "
           "will use 95%% of the energy produced." % q["total_price_dec"], gap_after=6)
    # bottom install photo, full width
    ph_h = 150
    p.image("quote_photo.jpg", 0, PH - ph_h, PW, ph_h)
    return p

# ============================================================================
# PAGE 4 — REVIEWS (screenshot)
# ============================================================================
def page_reviews(q):
    p = Page()
    p.heading("You're in good hands", gap_after=6)
    p.image("medal.png", ML + 250, 34, 40, 41)
    p.para("Before we get to your quote, we’d love to show you our amazing "
           "reviews for our brilliant customer service.", size=9.5, maxw=360, gap_after=12)
    # reviews.jpg is 1100 x ~2769*1100/1953 = 1560 tall -> fit width
    iw = CW
    ih = iw * (2769 / 1953)
    p.image("reviews.jpg", ML, p.y, iw, min(ih, PH - p.y - 30))
    return p

# ============================================================================
# PAGE 5 — DETAILS & INFO
# ============================================================================
def page_details(q):
    p = Page()
    p.heading("Details & Info", gap_after=10)
    p.image("logo.png", PW - MR - 150, 34, 150, 65)
    p.gap(4)
    p.text(ML, p.y, "CRG Direct Ltd", size=10.5, color=GREEN); p.gap(22)
    p.text(ML, p.y, "Integrated Management System", size=10.5, color=GREEN); p.gap(24)
    rows = [
        ("Document Title :", "Customer Quote"),
        ("Ref. No. :", q["ref"]),
        ("Next Review Date :", "One Year"),
        ("MCS Accredited Company:", "CRG DIRECT LTD"),
        ("MCS Accredited Number", "NIC600310(Company Registration Number: 10546909)"),
        ("Registered Office Address:", "Wey Court West Union Road, Farnham, GU9 7PT"),
        ("Principal Trading Address:", "172 Sea Front Hayling Island PO11 9HP"),
        ("Contact Details:", "Tel: 0330 133 2497/07955568287\nadmin@crgdirect.co.uk"),
        ("Website:", "www.crgdirect.co.uk"),
        ("HIES Membership Number:", "CRG/A/088"),
        ("MCS Accredited Company:", "CRG DIRECT LTD"),
        ("Trustmark", "2855428"),
        ("MCS Certification Number:", "NIC600310"),
        ("Project Reference:", q["ref"]),
        ("Client:", q["client"]),
        ("Address:", q["address"]),
        ("Postcode:", q["postcode"]),
        ("Date:", q["date"]),
    ]
    vx = ML + 175
    for lab, val in rows:
        vlines = val.split("\n")
        p.text(ML, p.y, lab, size=9.5, color=GREEN)
        for j, vl in enumerate(vlines):
            p.text(vx, p.y + j * 12, vl, size=9.5, color=BODY)
        p.gap(19 + (len(vlines) - 1) * 12)
    p.gap(6)
    p.para("Really nice to meet you and thanks for allowing me the opportunity to "
           "provide a quotation for your proposed Solar PV installation.", size=9.5, gap_after=8)
    p.para("We endeavour to deliver the equipment as specified but due to global "
           "pressure these may have to be amended.We are obligated to provide you "
           "with certain Pre-Sale Information as part of our compliance with the "
           "Microgeneration Certification Scheme and in particular the Solar PV "
           "Standard MIS-3002 and MIS-3012 The Battery Standard including "
           "performance estimates and potential shade effects (if any).", size=9.5, gap_after=8)
    p.text(ML, p.y + 6, "Quote Reference: %s" % q["ref"], size=10.5); p.gap(6)
    # accreditation logos strip along the bottom
    aw = CW
    ah = aw * (106 / 902)
    p.image("accreditation.png", ML, PH - 55, aw, ah)
    return p

# ============================================================================
# PAGE 6 — OVERVIEW / SYSTEM DETAIL
# ============================================================================
def page_overview(q):
    p = Page()
    p.y = 46
    p.para("All our work is backed by HIES, the Home Insulation and Energy "
           "Systems insurance backed guarantee and we are fully MCS accredited.",
           size=10.5, gap_after=8)
    p.heading("OVERVIEW:", size=17, gap_before=2, gap_after=8)
    p.bullets([
        "%s canadian_solar %s %s,output per panel is %s" %
            (q["panel_count"], q["panel_model_raw"], q["panel_watt"], q["panel_watt"]),
        "watts Inverter is a %s" % q["inverter_raw"],
        "Total system generation of%s KWp" % q["kw"],
        "System cost is £%s" % q["total_price_dec"],
        "Predicted annual electricity produce is %s Kwh" % q["annual_gen_kwh"],
        "If you also have opted for a battery it is",
        "Battery Storage System %s" % q["battery_kwh"],
    ], size=10.5, gap_after=6)
    p.heading("SYSTEM DETAIL:", size=17, gap_before=2, gap_after=8)
    p.para("Having visited your property we are able to fit %s panels on your "
           "South facing roof by using %s panels creating a %s KWH system.We are "
           "proposing to supply MCS approved canadian_solar %s %s panels. These "
           "panels achieve a higher cell efficiency which means more energy per "
           "square meter. Use of first-class materials result in an increased "
           "durability so they reach a higher reliability, assured by a 25 year "
           "performance guarantee." %
           (q["panel_count"], q["panel_watt"], q["kw"], q["panel_model_raw"], q["panel_watt"]),
           size=10.5, gap_after=8)
    p.para("These modules comply with the following international standards:",
           size=10.5, gap_after=4)
    p.bullets(["IEC 61730 – Safety Qualification", "IEC 61215", "Carry CE mark"],
              size=10.5, gap_after=8)
    p.para("You are using %s of electricity per year at %sp. We estimate your new "
           "system will produce %s KWH of electricity per annum, giving approx’ "
           "£%s worth of savings per annum." %
           (q["annual_usage_kwh"], q["tariff_p"], q["annual_gen_kwh"], q["annual_saving"]),
           size=10.5, gap_after=8)
    p.para("The total cost of the system is £%s MCS calculations predict you "
           "will use 95%% of the energy produced." % q["total_price_dec"],
           size=10.5, gap_after=10)
    # datasheet images: canadian1 left (with text right), canadian2 spec below
    img_y = p.y
    dw = 250; dh = dw * (1754 / 1240)
    if img_y + dh > PH - 30:
        dh = PH - 30 - img_y; dw = dh * (1240 / 1754)
    p.image("canadian1.jpg", ML, img_y, dw, dh)
    tx = ML + dw + 18
    p.y = img_y - 4
    p.para("The panels would be mounted on your roof using an aluminium mounting "
           "frame system certified by MCS complete with the required hooks, "
           "connectors and clamps to ensure a quality finish to your system.",
           size=10.5, x=tx, maxw=PW - MR - tx, gap_after=10)
    p.para("A generation meter will also be installed in the property so you can "
           "see what energy you are producing.", size=10.5, x=tx, maxw=PW - MR - tx,
           gap_after=12)
    dw2 = PW - MR - tx; dh2 = dw2 * (1754 / 1240)
    if p.y + dh2 > PH - 30: dh2 = PH - 30 - p.y; dw2 = dh2 * (1240 / 1754)
    p.image("canadian2.jpg", tx, p.y, dw2, dh2)
    return p

# ============================================================================
# PAGE 7 — INVERTER
# ============================================================================
def page_inverter(q):
    p = Page()
    p.heading("INVERTER", size=17, gap_after=8)
    p.para("The inverter we are proposing is a %s panels on your inverter. The "
           "data sheet below shows the capabilities and limitations of your "
           "inverter, be advised if you have an inverter that does not support "
           "battery storage and at some point in the future you require battery "
           "storage you will need to upgrade your inverter.." % q["inverter_raw"],
           size=10.5, gap_after=16)
    iw = 430; ih = iw * (1600 / 1131)
    if p.y + ih > PH - 30: ih = PH - 30 - p.y; iw = ih * (1131 / 1600)
    p.image("sunsynk_inverter.jpg", (PW - iw) / 2, p.y, iw, ih)
    return p

# ============================================================================
# PAGE 8 — PRICE
# ============================================================================
def page_price(q):
    p = Page()
    p.y = 170
    p.heading("PRICE", size=17, gap_after=10)
    p.para("The price for this %s Kwh system fully fitted including VAT (where "
           "applicable) is  £%s" % (q["kw"], q["total_price"]), size=10.5, gap_after=10)
    p.para("This price includes the following:", size=10.5, gap_after=4)
    p.bullets([
        "Battery Storage System %s" % q["battery_kwh"],
        "Panels, inverter, mounting frame",
        "Additional electrical work, cabling etc",
        "Delivery", "Fitting Cost", "Scaffolding", "Roof Survey",
        "Generation Meter – a means of recording and displaying the total AC generation",
        "Handover Pack and MCS Certificate (if a valid Mpan is submitted)",
        "Guarantees and Warranties", "Registration with DNO", "iBoost",
        "BirdGuard no", "Number of optimisers to be installed 0", "EPS no", "UPS no",
    ], size=10.5, gap_after=12)
    p.heading("SCHEDULE FOR PAYMENT", size=17, gap_after=10)
    p.para("This price includes the following:", size=10.5, gap_after=4)
    p.bullets(["Deposit of 15% upon placing of order.",
               "Stage payment of 40% on agreed install date",
               "Final payment of balance on completion of install and commissioning"],
              size=10.5, gap_after=10)
    p.para("Our estimated costs include the supply, delivery, installation, "
           "testing and commissioning of the solar array, including any works to "
           "the existing electrical consumer unit to enable the installation of "
           "the solar system. Our costs also include scaffolding as required while "
           "carrying out works on the roof.", size=10.5, gap_after=8)
    p.para("All systems we supply are installed by professional fitters. An MCS "
           "Certificate will be provided.", size=10.5, gap_after=10)
    p.text(ML, p.y, "Account Details:", size=10.5); p.gap(20)
    p.text(ML, p.y, "Bank", size=9.5); p.text(ML + 70, p.y, "Natwest", size=9.5)
    p.text(ML + 300, p.y, "Sort Code", size=9.5); p.text(ML + 375, p.y, "52-41-20", size=9.5)
    p.gap(24)
    p.text(ML, p.y, "Account", size=9.5); p.text(ML, p.y + 11, "Name", size=9.5)
    p.text(ML + 70, p.y, "CRG Direct Ltd", size=9.5)
    p.text(ML + 300, p.y, "Account", size=9.5); p.text(ML + 300, p.y + 11, "No.", size=9.5)
    p.text(ML + 375, p.y, "43634435", size=9.5)
    p.gap(24)
    # Payment Terms band header
    p.rect(ML, p.y - 12, CW, 20, fill=BAND_LT, stroke="#999999", sw=0.6)
    p.text(PW / 2, p.y + 2, "Payment Terms", size=10.5, align="center")
    return p

# ============================================================================
# PAGE 9 — PAYMENT TERMS TABLE + CANCELLATION + SIGNATURE
# ============================================================================
def page_terms(q):
    p = Page()
    p.y = 40
    cw3 = [78, 350, CW - 428]
    rows = [
        {"cells": [{"t": "Deposit:"}, {"t": "Deposit (Maximum 15% of the total sum inc VAT) payable on confirmation of order"}, {"t": "£%s" % q["deposit"], "align": "right"}]},
        {"cells": [{"t": "Advance\nPayment:"}, {"t": "Further advance payment payable when an install date agreed 40% of the total sum inc VAT"}, {"t": "£%s" % q["stage"], "align": "right"}]},
        {"cells": [{"t": "Balance:"}, {"t": "Balance payable following final commissioning"}, {"t": "£%s" % q["balance"], "align": "right"}]},
    ]
    p.grid(ML, cw3, rows, y=p.y, border="#888888", sw=0.7, size=9.0, pad=6)
    p.gap(8)
    p.para("It is important that this quotation is read in conjunction with the "
           "full performance estimate that forms part of it in the following "
           "pages. If you require clarification on any point please do not "
           "hesitate to contact us", size=9.5, gap_after=16)
    p.gap(6)
    p.para("All quotes valid for 14 days and subject to our terms and conditions",
           size=13, color=GREEN, align="center", gap_after=34)
    for para in [
        "This quotation has been based on us being able to install your system as "
        "described without interruption. Should there be circumstances beyond our "
        "control which cause an interruption to the installation process we will "
        "discuss with you the implications of such a delay.",
        "Should you decide to make any changes to the agreed installation within "
        "your cancellation period, we will produce another full quotation which "
        "takes into account these changes. You will be given a further cancellation "
        "period to consider this quotation.",
        "Should you wish to make any changes to the agreed installation after your "
        "cancellation period has expired, again we will prepare a new quotation for "
        "you, but we reserve the right to charge for any reasonable costs we have "
        "incurred in working towards the original installation details.",
        "If, during the installation process, we come across any situation that we "
        "could not reasonably be expected to foresee, for example, remedial "
        "electrical or building work, we will discuss with you the implications and "
        "costs involved in rectifying the problem.",
        "Should you request any changes after the installation process has begun "
        "that involve additional cost we will provide you with a quotation based on "
        "the daily or hourly rate of our installers.",
    ]:
        p.para(para, size=10.5, gap_after=8)
    p.gap(6)
    p.text(ML, p.y, "Yours sincerely,", size=10.5); p.gap(6)
    p.image("signature.png", ML, p.y, 120, 32); p.gap(40)
    p.text(ML, p.y, "Lance Pearson – Managing Director", size=10.5)
    return p

# ============================================================================
# PAGE 10 — PERFORMANCE ESTIMATION (big table)
# ============================================================================
def page_perf(q):
    p = Page()
    p.heading("PERFORMANCE ESTIMATION", size=17, gap_after=10)
    p.para("Please see the following section which shows an estimate of the annual "
           "total generation of the proposed system calculated using the "
           "methodology recommended in the MIS-3002 specification and MGD 003 "
           "“Determining the Electrical Self-Consumption of Domestic Solar "
           "Photovoltaic (PV) Installations with and without Electrical Energy "
           "Storage”.", size=10, gap_after=8)
    p.para("Electricity Per Year – %s Kwh solar PV array." % q["kw"],
           size=10, gap_after=10)
    p.para("PV PERFORMANCE ESTIMATION", size=13, gap_after=8)
    lc, rc = CW * 0.62, CW * 0.38
    SZ = 9.0
    def band(title):
        return {"cells": [{"t": title, "align": "center", "bg": BAND_LT, "size": SZ}],
                "widths": [CW], "h": 18}
    def dr(label, val, shade):
        bg = BLUE_LT if shade else None
        return {"cells": [{"t": label, "bg": bg, "size": SZ},
                          {"t": val, "bg": bg, "size": SZ}]}
    rows = [
        band("A. Installation Cost"),
        dr("Installed capacity of PV system - kWP (stc)", "%s Kwh" % q["kw"], True),
        dr("Orientation of the PV system - degrees from South", "", False),
        dr("Inclination of system - degrees from horizontal", "35°", True),
        dr("Postcode region", "SOUTHERN ENGLAND", False),
        band("B. Performance Calculations"),
        dr("kWh/kWp (Kk) from table", "0", True),
        dr("Shade factor (SF)", "0 %", False),
        dr("Estimated annual output (kWp x Kk x SF)", "0", True),
        band("C. Estimated PV self-consumption-PV Only"),
        dr("Assumed occupancy archetype", "Out all day", True),
        dr("Assumed annual electricity consumption, kWh", "%s" % q["annual_usage_kwh"], False),
        dr("Assumed annual electricity generation from solar PV system, kWh", "0", True),
        dr("Expected solar PV self-consumption (PV Only)", "0", False),
        dr("Grid electricity independence /Self-sufficiency (PV Only)", "0%", True),
        band("D. Estimated PV self-consumption-with EESS"),
        dr("Assumed usable capacity of electrical energy storage device, which is used for self-consumption, kWh", "Battery Storage System %s" % q["battery_kwh"], True),
        dr("Expected solar PV self-consumption (with EESS) Kwh", "0", False),
        dr("Grid electricity independence /Self-sufficiency (with EESS)", "0%", True),
        band("E. Additional benefits from PV and EESS"),
        dr("EESS capacity NOT used for self-consumption", "0", True),
        dr("Total energy discharged per annum approx (will degrade annually)", "1855", False),
        dr("Additional self-consumption from EV, heat pumps, diverters (only when presnt)", "0", True),
    ]
    p.grid(ML, [lc, rc], rows, y=p.y, border="#c8c8c8", sw=0.6, size=SZ, pad=5, min_h=26)
    return p

# ============================================================================
# PAGE 11 — performance notes + THE FIGURES
# ============================================================================
def page_figures(q):
    p = Page()
    p.y = 40
    for para in [
        "“Important Note: The performance of solar PV systems is impossible to "
        "predict with certainty due to the variability in the amount of solar "
        "radiation (sunlight) from location to location and from year to year. "
        "This estimate is based upon the standard MCS procedure is given as "
        "guidance only for the first year of generation. It should not be "
        "considered as a guarantee of performance.",
        "The solar PV self-consumption has been calculated in accordance with the "
        "most relevant methodology for your system. There are a number of external "
        "factors that can have a significant effect on the amount of energy that is "
        "self-consumed so this figure should not be considered as a guarantee of "
        "the amount of energy that will be self-consumed. It does not account for "
        "the impact of power diverters, electric space heating, electric water "
        "heating or electric vehicle charging.”",
        "Where the shade factor (SF) is less than 1 Shading will be present on your "
        "system that will reduce its output to the factor stated. This factor was "
        "calculated using the MCS shading methodology and we believe that this will "
        "yield results within 10% of the actual energy estimate stated for most "
        "systems.",
        "Important Note: The energy performance and benefits of EESS is impossible "
        "to predict with certainty due to the numerous functions a system can be "
        "programmed to perform. This estimate is based upon the standard MCS "
        "procedure and is given as guidance only. It should not be considered as a "
        "guarantee of performance.",
        "Where occupancy archetype is not known (e.g. new build) then both sections "
        "C & D in the above table can be omitted (or marked as N/A).",
    ]:
        p.para(para, size=9.5, gap_after=8)
    p.heading("THE FIGURES", size=15, gap_before=2, gap_after=8)
    p.para("If the system performs in line with our predictions the following "
           "would apply, remember, we have assumed that you are Out all day We have "
           "assumed you will self-consume 0% of the energy produced by your PV "
           "system, as determined by the method set out in MGD 003, therefore "
           "exporting 100%", size=9.5, gap_after=10)
    w3 = [CW - 90, 45, 45]
    rows = [
        {"cells": [{"t": "ANNUAL BENEFITS", "align": "center", "bg": BAND_MD, "size": 9.5}], "widths": [CW], "h": 20},
        {"cells": [{"t": "Grid independence: Estimated annual electricity savings % grid independence of PV output = total x electricity tariff (p/kWh) / 100 (e.g. 22% (grid independence) of 2491 (PV output) = 548.02 x 15p (electricity tariff) /100 = £82.20", "bg": "#d9d9d9", "size": 8.3},
                   {"t": "0", "align": "center", "bg": "#d9d9d9"}, {"t": "per\nyear", "align": "center", "bg": "#d9d9d9"}]},
        {"cells": [{"t": '"Annual income generated from Smart Export Guarantee % export of PV output x SEG rate from Energy Provider / 100 e.g. 69% (to be exported) of 2491 (PV output)) = 1,718.79 x 5.5p (SEG rate) / 100 = £94.53"', "bg": "#d9d9d9", "size": 8.3},
                   {"t": "0", "align": "center", "bg": "#d9d9d9"}, {"t": "per\nyear", "align": "center", "bg": "#d9d9d9"}]},
        {"cells": [{"t": "SMART EXPORT GUARANTEE RATE", "bg": "#d9d9d9", "size": 8.3},
                   {"t": "£0.32", "align": "center", "bg": "#d9d9d9"}, {"t": "per\nkwh", "align": "center", "bg": "#d9d9d9"}], "h": 40},
    ]
    p.grid(ML, w3, rows, y=p.y, border="#7f7f7f", sw=0.7, size=8.3, pad=5)
    return p

# ============================================================================
# PAGE 12 — PAYBACK PERIOD + wind/snow tables
# ============================================================================
def page_payback(q):
    p = Page()
    p.y = 40
    p.para("Note: Smart Export Guarantee rates differ between energy providers and "
           "can change at their discretion. Please also be aware there is no current "
           "set minimum number of years of eligibility for the Smart Export "
           "Guarantee. The amount above is per annum based on your energy provider's "
           "current SEG rates.", size=9.5, gap_after=10)
    p.heading("PAYBACK PERIOD", size=15, gap_after=6)
    p.para("HOW LONG WILL IT TAKE FOR THE SYSTEM TO PAY FOR ITSELF?", size=10.5, gap_after=10)
    box = [
        {"cells": [{"t": "None of us can predict accurately what will happen in the future when it comes to inflation and electricity prices, so for the payback time we have assumed no increases in electricity prices. This is only a rough guide, as there may be maintenance costs to be considered.", "bg": "#d9d9d9", "size": 9.0}]},
        {"cells": [{"t": "To calculate how long the system will take to pay for itself, we can divide the total cost you have paid for the system and divide it by the estimated benefit you will receive each year.", "bg": "#d9d9d9", "size": 9.0}]},
    ]
    p.grid(ML, [CW], box, y=p.y, border="#bfbfbf", sw=0.7, size=9.0, pad=7)
    p.gap(2)
    half = [CW * 0.5, CW * 0.5]
    rows = [
        {"cells": [{"t": "Total Installation cost :", "bg": "#d9d9d9"}, {"t": "£%s" % q["total_price"]}], "h": 30},
        {"cells": [{"t": "Estimated Annual Benefit :", "bg": "#d9d9d9"}, {"t": "£%s" % q["annual_saving"]}], "h": 30},
        {"cells": [{"t": "Payback Period (installation cost divided by estimated annual benefit) :", "bg": "#d9d9d9"}, {"t": "%s Years" % q["payback_years"]}], "h": 36},
    ]
    p.grid(ML, half, rows, y=p.y, border="#bfbfbf", sw=0.7, size=9.5, pad=7)
    p.gap(6)
    p.text(ML, p.y, "Array Surface Area =%s Sqm" % q["array_sqm"], size=10); p.gap(16)
    wind = [{"cells": [{"t": "MCS Wind Loading Calculation", "align": "center", "bg": BLUE_LT, "size": 10}], "widths": [CW], "h": 22}]
    for lab, val in [("Wind Zone:", "1-SU"), ("Peak Pressure:", "1,009Pa"),
                     ("Altitude Correction Factor:", "NONE"),
                     ("Typography Correction Factor:", "NONE"),
                     ("Peak Velocity Pressure:", "1009Pa"),
                     ("Pressure Coefficient:", "-0.5"), ("Wind Pressure:", "-681Pa")]:
        wind.append({"cells": [{"t": lab}, {"t": val}], "h": 24})
    p.grid(ML, half, wind, y=p.y, border="#a6a6a6", sw=0.7, size=9.5, pad=7)
    p.gap(4)
    snow = [{"cells": [{"t": "Snow Landing Calculation", "align": "center", "bg": BLUE_LT, "size": 10}], "widths": [CW], "h": 22}]
    for lab, val in [("Snow Load:", "500Pa"), ("Altitude Correction:", "NONE"),
                     ("Pitch Adjustment:", "1000"), ("Adjust Snow Load:", "500Pa")]:
        snow.append({"cells": [{"t": lab}, {"t": val}], "h": 24})
    p.grid(ML, half, snow, y=p.y, border="#a6a6a6", sw=0.7, size=9.5, pad=7)
    return p

# ============================================================================
# PAGE 13 — SUN PATH + SEG TARIFF
# ============================================================================
def page_sunpath(q):
    p = Page()
    p.y = 30
    iw = 430; ih = iw * (226 / 577)
    p.image("sunpath.png", (PW - iw) / 2, p.y, iw, ih)
    p.y += ih + 20
    p.text(ML, p.y, "Sun Path Chart - 0%", size=11); p.gap(14)
    p.para("This shade assessment has been undertaken using the standard MCS "
           "procedure – it is estimated that this method will yield results within "
           "10% of the actual annual yield or most systems. Where there is an "
           "obvious clear horizon and no near or far shading, the assessment of SF "
           "has been omitted and an SF value of 1 used.", size=10, gap_after=12)
    p.heading("SMART EXPORT GUARANTEE (SEG) TARIFF", size=14, gap_after=10)
    for para in [
        "The Smart Export Guarantee is a support mechanism designed to ensure "
        "small-scale generators are paid for the renewable electricity they export "
        "to the grid. It has been in place since 1st January 2020.",
        "Under the scheme, all licensed energy companies with 150,000 or more "
        "customers must provide at least one SEG tariff. Smaller suppliers can offer "
        "a tariff if they want to on a voluntary basis. All suppliers can also "
        "choose to offer other means of making payments for exported electricity, "
        "separate to the SEG arrangements.",
        "The technology and installer used by householders must be certified under "
        "the Microgeneration Certification Scheme (MCS) or equivalent and the solar "
        "PV system must be grid connected. Energy suppliers may ask for the MCS "
        "certificate to prove the installation meets the standard which we will "
        "provide for you.",
        "You also need a registered Smart Meter that records your exported "
        "electricity, even if you’re not signing up to a smart tariff.",
        "SEG payments are not linked to other financial support around renewable "
        "energy installations. This means that, if eligible, you could combine SEG "
        "payments with other financial support. In Scotland, for example you could "
        "combine SEG payments with the Home Energy Scotland loan.",
        "You will not be able to receive SEG from more than one supplier.",
        "Octopus Energy offer Outgoing Octopus which is described as a smart export "
        "tariff and their successor to the feed-in tariff (FIT). Perfect for homes "
        "with solar panels, battery storage, or any other way of sharing energy back "
        "to the grid. Outgoing Octopus comes in two flavours – Fixed or Agile. "
        "Outgoing Fixed guarantees 5.5p per kWh for every unit you export. Outgoing "
        "Agile matches your half-hourly prices with day-ahead wholesale rates, "
        "helping you make the most of the energy you generate.",
    ]:
        p.para(para, size=9.5, gap_after=7)
    p.link("https://octopus.energy/outgoing/")
    p.para("Here is a list of energy suppliers who provide SEG. Some are mandated "
           "and some have chosen to offer this.", size=9.5, gap_after=2)
    p.link("https://www.ofgem.gov.uk/publications/seg-supplier-list")
    p.para("The Energy Saving Trust provide a Solar Energy Calculator to provide "
           "estimates for fuel bill saving and financial payments you may receive by "
           "installing a solar PV system.", size=9.5, gap_after=2)
    return p

# ============================================================================
# PAGE 14
# ============================================================================
def page_14(q):
    p = Page()
    p.y = 30
    p.link("https://www.pvfitcalculator.energysavingtrust.org.uk/")
    p.heading("SEG and ELECTRICAL ENERGY STORAGE (Battery Storage)", size=13, gap_after=10)
    for para in [
        "If you’ve included an energy storage system in your renewables "
        "installation, you can still apply for SEG, but there might be a few rules, "
        "depending on your SEG contract. Your battery could store electricity from "
        "the grid (known as brown electricity) before exporting it later on.",
        "Energy suppliers do not have to pay you for brown electricity exported to "
        "the grid but they may choose to do so.",
        "Some suppliers may only pay the SEG for green electricity, ie the "
        "electricity your low-carbon system generates itself. If this is the case, "
        "the supplier may ask you to show how you separate the green electricity you "
        "generate from any imported brown electricity.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("PITCHED ROOF WORK", size=13, gap_after=10)
    p.para("On all roof types there should not be a need to drill tiles.\n"
           "On slate roofs it is sometimes necessary to cut a portion of the slate "
           "out or remove a slate so that the surrounding slates sit back down, the "
           "area that would be removed would maintain its waterproof integrity "
           "through the use of lead flashing kits.\n"
           "In the case of tiles a small channel is cut out on the underside to "
           "allow the tile to sit flush with the roof again, the integrity of the "
           "tile is maintained.\n"
           "The mounting anchors are fixed to the roof joists using appropriate "
           "fixings and the tile or slate sits back in place or where necessary "
           "flashing kit used.\n"
           "Whenever any roof covering is modified the water proof integrity is "
           "always maintained in the most appropriate way possible, with little or "
           "no visual impact.\n"
           "Decra roofing installation, Metasole+ brackets or Solar limpet fixings "
           "will be used drilled direct into roofing material through the tiling "
           "these are an MCS accredited fixing", size=10, gap_after=6)
    p.para("The link has more information on the product", size=10, gap_after=2)
    p.link("https://www.renusol.com/en/solar-panel-mounting/metal-roof/ms-msp/")
    p.para("It is part of MCS (Micro Generation Certification Scheme) rules and "
           "regulations that the roof offers the same or better waterproofing once "
           "the contractor has left site.", size=10, gap_after=8)
    p.para("We should be able to demonstrate that the installation of the modules "
           "has not affected the fire performance of the roof. This can be "
           "demonstrated by mounting the panels above an existing non-combustible "
           "roof covering (pitched roofs).", size=10, gap_after=10)
    p.heading("PLANNING CONSENT, PERMISSIONS AND APPROVAL", size=13, gap_after=10)
    for para in [
        "We shall ensure your building is assessed by a competent professional "
        "experienced in solar photovoltaic systems to ensure that it is suitable for "
        "the installation and, by undertaking the proposed works, the building’s "
        "compliance with the Building Regulations (in particular those relating to "
        "energy efficiency) is not compromised. Where work is undertaken that is "
        "notifiable under the Building Regulations we shall make this clear to you "
        "and who shall be responsible for this notification.",
        "We are registered with a Competent Persons Scheme (CPS) and able to "
        "self-certify our work.",
        "It is not a requirement to contact your local planning authority and advise "
        "them of your intention to install a solar electrical system. Legislation "
        "changed in April of 2008 so that now, in most cases the installation will "
        "be considered a ‘permitted development’; however in some cases planning "
        "permission may be required, usually in a conservation area or on a listed "
        "building. It is advisable if you are in any doubt for you to just check and "
        "clear this before your installation.",
    ]:
        p.para(para, size=10, gap_after=8)
    return p

# ============================================================================
# PAGE 15
# ============================================================================
def page_15(q):
    p = Page()
    p.y = 30
    for para in [
        "On a pitched roof the solar PV array must not protrude more than 200 mm "
        "above the roof line.",
        "On a flat roof the highest part of the solar PV array must be less than 1 "
        "meter higher than the highest part of the roof (excluding any chimney).",
        "The PV array must be sited more than 200mm away from the external edges of "
        "the roof and as far as practicable the PV array should be sited to minimise "
        "the effect on the external appearance of the building.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("STRUCTURAL STABILITY", size=13, gap_after=10)
    for para in [
        "Most roofs are more than adequate to cope with a solar array being mounted "
        "as the weight of the load is spread across the large surface area. A wind "
        "and snow loading calculation has been provided within this quotation.",
        "PV Systems should not adversely affect the weather tightness or structural "
        "integrity of the building to which they are fitted. The system should be "
        "designed and installed to ensure this is maintained for the life of the "
        "system.",
        "IMPORTANT: Where the existing roof covering is under warranty, then the roof "
        "warranty provider should be consulted to establish if warranties will be "
        "invalidated by the installation.",
        "Where an existing warranty may be invalidated by the proposed installation, "
        "we shall notify the customer in writing and obtain explicit written "
        "agreement from the customer if the installation is to proceed.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("NOTIFICATION TO THE DISTRIBUTION NETWORK OPERATOR (DNO)", size=12.5, gap_after=10)
    p.para("We will carry out the necessary liaison regarding connection to the "
           "local grid, and completion of the G98 or G99 paperwork.", size=10, gap_after=10)
    p.heading("SAFETY AND DURABILITY", size=13, gap_after=10)
    for para in [
        "Suitable and sufficient risk assessments shall be conducted before any work "
        "on site commences and an installation method statement will be carried out "
        "and issued prior to the commencement of any work and our installers will "
        "have carried out relevant health and safety training courses in line with "
        "the type of work.",
        "As an MCS contractor we shall be able to demonstrate that the installation "
        "of the modules has not affected the fire performance of the roof such as "
        "mounting above an existing non-combustible roof covering (pitched roofs).",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("INSURANCE", size=13, gap_after=10)
    p.para("Our advice with reference to your building insurance is that you do need "
           "to inform your insurers, however most insurers will add solar panels to "
           "your policy at no additional cost (It will be down to the insurance "
           "company as to how they view this).", size=10, gap_after=10)
    p.heading("MAINS POWER FAILURE", size=13, gap_after=10)
    p.para("If there is a power cut or the mains power is switched off deliberately "
           "the solar electric system will automatically disconnect from the main "
           "supply. This means that an engineer working on the electrical system "
           "will be in no danger. When the power is switched back on the system will "
           "automatically connect.", size=10, gap_after=8)
    return p

# ============================================================================
# PAGE 16
# ============================================================================
def page_16(q):
    p = Page()
    p.heading("INSTALLATION", size=13, gap_before=0, gap_after=10)
    p.y = max(p.y, 46)
    for para in [
        "The Installation will be carried out to comply with all applicable "
        "legislation and directives and the necessary standards including MCS "
        "installation requirements, Electrical Safety, Quality and continuity "
        "Regulations 2002 and the Consumer Code.",
        "Once the installation is complete you will be issued with a handover file "
        "consisting of all test documentation, user instructions, circuit diagrams, "
        "Energy Performance Certificate, warranties and contact details.",
        "Where work is undertaken that is notifiable under the Building Regulations "
        "it shall be made clear to the customer who shall be responsible for the "
        "notification.",
        "Where responsible for notification under the Building Regulations, the MCS "
        "Contractor shall ensure notification has been completed prior to handing "
        "over the installation.",
        "Note: Where notification under the Building Regulations is to be undertaken "
        "by others (e.g. the developer of a new-build project) then it is "
        "permissible for the MCS Contractor to handover the installation immediately "
        "following commissioning.",
        "Self-certification, in lieu of building control approval, is only permitted "
        "where installation and commissioning is undertaken by an entity registered "
        "with a Competent Persons Scheme (CPS) approved by the relevant government "
        "department for the scope of work being undertaken.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("ADDITIONAL MEASURES THAT MAY BE BENEFICIAL TO THE PERFORMANCE AND "
              "DURABILITY OF THE SYSTEM", size=12.5, gap_after=10)
    for para in [
        "Cleaning of your Solar Panels. The first thing you want to do is to check "
        "with your solar panel manufacturer. They might have specific "
        "recommendations for cleaning. There are solar panel cleaning companies "
        "available and so check your local area for details.",
        "Solar panels can become incredibly hot in sunshine. Either clean your solar "
        "panels in the morning/afternoon, or pick a relatively cool day. Warm water "
        "and soap – no other special equipment is needed. Clean the surface of the "
        "solar panel with a soft cloth or sponge. You do not have to clean the wiring "
        "underneath.",
        "The installation of solar panels can provide shelter for nesting birds with "
        "pigeons nesting under solar panels and so you may want to consider specific "
        "bird-proofing measures designed to solve this problem which are available.",
        "Take care to keep clean, as airborne dust particles, sticky tree and plant "
        "sap, lichen, soot and bird droppings are just a few of the things that can "
        "contribute to a build-up of dirt on your panels. Accumulation creates "
        "shading and will prevent daylight reaching the cells of the panels.",
        "The solar panels we install for you will be positioned to gain the maximum "
        "amount of sunlight. However, you should be aware that the future growth of "
        "trees, large shrubs and their spreading foliage could cause the panels to "
        "be shaded, thereby reducing the performance of the system.",
        "You should also consider how any future building work that takes place on "
        "your property would affect the shading of the solar panels.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("ENVIRONMENT", size=13, color="#000000", gap_after=10)
    p.para("We recycle most of the waste materials from your installation. We also "
           "endeavour to keep our travelling to a minimum by carrying out the works "
           "over as few journeys as possible.", size=10, gap_after=8)
    return p

# ============================================================================
# PAGE 17
# ============================================================================
def page_17(q):
    p = Page()
    p.heading("WARRANTIES", size=13, gap_before=0, gap_after=10)
    p.y = max(p.y, 46)
    for para in [
        "Your equipment will be guaranteed by its manufacturer, but you should "
        "contact us in the first instance if anything appears to be operating "
        "incorrectly.",
        "In addition to the product guarantees, our work will be covered by a "
        "workmanship warranty. This workmanship warranty will be transferable to the "
        "new legal owner of the property if it is sold during the warranty period.",
        "As signatories to a Consumer Code we are required to ensure that should we "
        "cease trading, due to receivership, administration or bankruptcy, that the "
        "workmanship warranty that we have in place for your installation will still "
        "be honoured.",
        "When you confirm the order and we have received any requested deposit, we "
        "will register your name, address and the total value of the contract, "
        "within two working days on the Job Registration System.",
        "A leaflet explaining the scheme is enclosed. If you are not content for us "
        "to register your details in this way, please let us know. The insurance "
        "provider will send the policy documents direct to you. This policy will be "
        "at no additional cost to you.",
        "Should we cause any damage, either to installed equipment or to your "
        "property we will rectify such damage without charge to you.",
    ]:
        p.para(para, size=10, gap_after=8)
    p.heading("HIES CONSUMER CODE", size=13, gap_after=10)
    p.para("We are signatories to the HIES Consumer Code, membership number and the "
           "membership number is displayed on the bottom of our letterhead. This "
           "document is prepared in accordance with the HIES Consumer Code.",
           size=10, gap_after=6)
    p.para("A leaflet describing the HIES Consumer Code is at the link below.",
           size=10, gap_after=2)
    p.link("https://www.hiesscheme.org.uk/regulation/hies-scheme-rules-code-of-practice/")
    p.heading("COMPLAINTS", size=13, gap_after=10)
    p.para("We hope you won't have any reason to complain about any aspect of our "
           "service. But if you do, please contact us.", size=10, gap_after=6)
    p.para("You may contact us by telephone, letter or e mail, and you will find our "
           "contact details on this quotation. We will acknowledge and attempt to "
           "resolve your complaint promptly. Where we need to investigate the "
           "complaint, we will report to you our progress on any investigation "
           "within seven working days.", size=10, gap_after=6)
    p.para("If we are unable resolve your complaint, you may be able to complain to "
           "HIES. You can read about this here:", size=10, gap_after=2)
    p.link("https://www.hiesscheme.org.uk/what-we-do/alternative-dispute-resolution/=how-to-complain-and-who-to-complain-to")
    p.para("VAT - This is charged at the reduced rate of 0% on the installation of "
           "solar panels in, or in the curtilage of residential accommodation.",
           size=10, gap_after=6)
    p.para("DELIVERY - Approximately 2 to 3 weeks from order, subject to "
           "availability of components. To be confirmed at the time of order.",
           size=10, gap_after=6)
    p.para("PRIVACY - Using Your Personal Information", size=10, gap_after=4)
    p.bullets(["We will use the personal information you provide to us in accordance "
               "with the Data Protection Act 2018 ,General Data Protection "
               "Regulations and more specifically to:"], size=10, gap_after=2)
    p.bullets(["Supply the Goods and Services to you",
               "Process any payments that you make for the Goods and Services, "
               "including if necessary conducting credit reference check;"],
              size=10, x=ML + 24, gap_after=6)
    return p

# ============================================================================
# PAGE 18
# ============================================================================
def page_18(q):
    p = Page()
    p.y = 30
    p.bullets(["Register your installation with any relevant bodies, including your "
               "deposit protection and insurance backed guarantee and any competent "
               "persons scheme;",
               "Address any concerns or complaints that you have about the Goods and "
               "Services, including liaison with HIES and QA Scheme Support Services "
               "Limited or The Dispute Resolution Ombudsman where the law requires us "
               "to share."], size=10, x=ML + 24, gap_after=8)
    p.para("Where you have indicated that you would like to receive further "
           "information on offers, products and services, you can change this at any "
           "point by contacting us.", size=10, gap_after=10)
    p.heading("CANCELLATION RIGHTS", size=13, gap_after=10)
    p.para("Your cancellation rights will vary depending on whether the contract you "
           "agree with us is considered to have been agreed on or away from trade "
           "premises.", size=10, gap_after=6)
    p.para("For contracts considered to have been agreed on trade premises you will "
           "be given a fourteen day cancellation period from the day that the "
           "contract was signed.\n"
           "For contracts considered to have been agreed away from trade premises, "
           "your cancellation rights are as set out in the Consumer Contracts "
           "(Information, Cancellation and Additional Charges) Regulations. These "
           "regulations give you the right to cancel from the time that the contract "
           "is signed until fourteen days after the delivery of the last of the "
           "goods.", size=10, gap_after=10)
    p.heading("BATTERY STORAGE (EESS)", size=13, gap_after=10)
    p.para("The system is a off-the-shelf Packaged EESS. The battery is capable of "
           "charging from, storing and subsequently discharging electrical energy "
           "from a domestic solar PV system. and is to be installed within the same "
           "domestic electrical system as the solar PV system and loads i.e. on the "
           "domestic side of the utility meter. The electrical energy storage is "
           "operated for provision of increasing self-consumption. This will be "
           "installed as new and not been previously used.", size=10, gap_after=10)
    iw = 200; ih = iw * (380 / 276)
    p.image("battery.jpg", (PW - iw) / 2, p.y, iw, ih)
    p.y += ih + 12
    p.para("The battery type is Lithium Iron Phosphate cells resulting in safe and "
           "reliable battery and special precautions should be taken such as "
           "ventilation and fire safety.", size=10, gap_after=6)
    return p

# ============================================================================
# PAGE 19
# ============================================================================
def page_19(q):
    p = Page()
    p.y = 30
    p.bullets(["The system size is",
               "Battery Storage System %s" % q["battery_kwh"]], size=10, gap_after=2)
    p.para("Kwh and if the battery developes a problem you must inform the "
           "manufacturer immediately see data sheet for all specifications.",
           size=10, gap_after=8)
    p.para("The battery will be situated in the {%loc_battery%}", size=10, gap_after=8)
    p.para("The useable storage capacity in kilowatt-hours (kWh) accounting for the "
           "maximum allowable depth of discharge.", size=10, gap_after=8)
    p.para("Battery Modules can be stacked up to three high and a Power Module that "
           "controls them is placed on top. When connected to a compatible inverter "
           "this gives the following energy storage capacity and continuous power "
           "output:", size=10, gap_after=6)
    p.bullets(["Battery Module = 5 kilowatt-hour of energy storage and 2.5 kilowatts of power output.",
               "Battery Modules = 10 kilowatt-hours of energy storage and 5 kilowatts of power output.",
               "Battery Modules = 15 kilowatt-hours of energy storage and 5 kilowatts of power output."],
              size=10, gap_after=10)
    for para in [
        "Note: if the inverter is under 5 kilowatts the power output will be limited "
        "by the inverter’s capacity.",
        "If you want more than 15 kilowatt-hours of storage, two Luna2000s can be "
        "installed in parallel to provide up to 30 kilowatt-hours of storage. More "
        "modules won’t improve the power output beyond 5 kilowatts:",
        "Each 5 kilowatt-hour Battery Module operates separately from the others. "
        "This means if a fault develops in one module the others can still be used "
        "until the defective unit is repaired or replaced.",
        "The independent operation makes it easy to add an extra module to expand "
        "storage capacity or compensate for capacity deteriorating over time. As each "
        "battery module is covered by its own warranty, adding a new one to an "
        "existing system won’t create a warranty issue.",
        "The Battery is water-resistant and can be installed outdoors. Its IP rating "
        "— or Ingress Protection rating — is IP66. This means it’s dust-tight and "
        "able to resist jets of water from all directions. This means if your idiot "
        "cousin decides to hose down your home battery, it should be fine.",
        "Note: It would be helpful for consumers if the useable storage capacity "
        "could be expressed in terms of the time that particular devices could be "
        "run. Use the formula (10 x battery capacity in amp hours) divided by "
        "(appliance load in watts)",
        "If capable (or not) of running in Island mode (during loss of grid power) "
        "and limitations in terms of maximum load in kW. Battery fault on module auto "
        "isolates to keep system safe.",
        "Warranties applying to the system and its storage capacity (degradation, "
        "number of cycles, energy throughput etc.)",
        "How the EESS indicates its current usable capacity or state of health (thus "
        "indicating if it is ending its life or the storage capacity is below the "
        "warranted capacity).",
        "End of life, recycling, arrangements should be carried out in accordance "
        "with the Waste Electrical Electronic Equipment (WEE, 2012/19/EU) and the "
        "Battery Directive (2006/66/EC).",
        "Where the EES is to be remotely controlled by third parties, the terms of "
        "that arrangement including the terms applying should the consumer wish to "
        "terminate the arrangement and assume full control of their system. Penalties "
        "for early termination shall be clearly stated.",
        "If the EESS can be controlled to respond to time of use electricity tariffs "
        "and, if so, how it shall be highlighted whether this is a manual process "
        "(manually setting charge and discharge times) or can be automated (such that "
        "charge and discharge times change automatically when tariffs change).",
        "The EESS is intended to increase the self-consumption of Solar PV and "
        "therefore is within the scope of MGD 003.",
    ]:
        p.para(para, size=9.5, gap_after=6)
    p.bullets(["The EESS is serving a domestic building",
               "The annual electricity consumption is between 1500 kWh and 6000 kWh "
               "(excluding consumption attributable to electric vehicles and "
               "electrified space heating)."], size=9.5, gap_after=4)
    return p

# ============================================================================
# PAGE 20
# ============================================================================
def page_20(q):
    p = Page()
    p.y = 30
    p.bullets(["The estimated annual generation of the solar PV system (calculated "
               "in accordance with MIS 3002) is between 1500 kWh and 6000 kWh",
               "There are no other forms of local electricity generation serving the "
               "building (other than the solar PV)"], size=10, gap_after=10)
    p.para("Following the procedure outlined in MGD 003 Sections C and D have been "
           "completed.", size=10, gap_after=10)
    p.para("If you wish us to begin work within the cancellation period you must give "
           "us express permission, in writing, to do so.", size=10, gap_after=8)
    p.para("You can find full details of your cancellation rights within the contract "
           "we will ask you to sign and also on the Cancellation Form we will issue "
           "to you.", size=10, gap_after=10)
    p.heading("CONTRACT TERMS", size=13, gap_after=10)
    p.para("We have enclosed a copy of our contract with this quotation. Please read "
           "this carefully, and as always, please contact us if you require further "
           "clarification.", size=10, gap_after=10)
    p.text(ML, p.y, "Customer Declaration:", size=11); p.gap(16)
    p.para("I confirm that I wish to continue with the installation process with "
           "this quotation, and to the costs set out in this quote. I confirm that I "
           "have obtained any planning permission for the proposed works (if "
           "applicable) and that there are no restrictions in relation to my property "
           "being in an area of outstanding natural beauty or conservation area. I "
           "would like to proceed with the installation at my property.",
           size=10, gap_after=12)
    decl = [
        {"cells": [{"t": "Name:", "align": "center", "bg": "#d9d9d9"}, {"t": q["client"]}], "h": 30},
        {"cells": [{"t": "Signature:", "align": "center", "bg": "#d9d9d9"}, {"t": ""}], "h": 30},
        {"cells": [{"t": "Date:", "align": "center", "bg": "#d9d9d9"}, {"t": ""}], "h": 30},
    ]
    p.grid(ML, [CW * 0.4, CW * 0.6], decl, y=p.y, border="#7f7f7f", sw=0.7, size=10, pad=7)
    p.gap(6)
    p.text(ML, p.y, "The next steps", size=10.5); p.gap(13)
    p.para("Below are the steps both of us will take to give you a complete solar "
           "system under your control.", size=10, gap_after=8)
    p.para("Check the quotation ensure everything suits your needs and you are happy "
           "with the costings", size=10, gap_after=12)
    p.text(ML, p.y, "Sign the attached agreement and return to us with your deposit of 15%", size=10)
    p.text(PW - MR, p.y, "£%s" % q["deposit"], size=10, align="right"); p.gap(20)
    p.text(ML, p.y, "Once we have an install date we will contact you and take the second payment of 40%", size=10)
    p.text(PW - MR, p.y, "£%s" % q["stage"], size=10, align="right"); p.gap(18)
    p.para("Day of installation; Teams arrive and brief you on the plan then install "
           "and commission your system, install team will then demonstrate and answer "
           "any questions you may have on your system. Final payment of the "
           "outstanding balance is due at this point.", size=10, gap_after=8)
    p.para("Within 14 days of install post installation pack warranties, product "
           "information and post install support certification delivered to you.",
           size=10, gap_after=8)
    p.text(ML, p.y, "Your Surveyor was: -", size=10); p.gap(24)
    p.text(PW / 2, p.y, "Many thanks for your time and for your interest in our "
           "products.", size=13, color=GREEN, align="center")
    return p

ALL_BUILDERS = [page_cover, page_intro, page_quote, page_reviews, page_details,
                page_overview, page_inverter, page_price, page_terms, page_perf,
                page_figures, page_payback, page_sunpath, page_14, page_15,
                page_16, page_17, page_18, page_19, page_20]


# ---- QUOTE DATA (sample = the reference PDF's Joe Bloggs / 4.92kW system) ---
QUOTE = {
    "ref": "PO4 Joe", "client": "Joe Bloggs", "address": "N/A", "postcode": "PO4 9nx",
    "date": "2026-03-05",
    "kw": "4.92", "annual_saving": "0", "total_price": "7,430", "net_price": "7,430",
    "total_price_dec": "7430.00", "lifetime_saving": "0",
    "panel_count": "12", "panel_model": "Cs3l-355ms-ab", "panel_model_raw": "cs3l-355ms-ab",
    "panel_watt": "410", "battery": "5.3 Sunsynk Battery", "battery_kwh": "5.3Kw",
    "inverter": "Sun-3.6-ecco Inverter", "inverter_raw": "sunsynk sun-3.6-ecco",
    "annual_usage_kwh": "7450", "tariff_p": "0.34", "annual_gen_kwh": "0",
    "deposit": "1,115", "stage": "2,972", "balance": "3,344",
    "payback_years": "0", "array_sqm": "22.44",
}

def main():
    ps = [b(QUOTE) for b in ALL_BUILDERS]
    doc = {"page_size": {"width": PW, "height": PH},
           "pages": [p.dict() for p in ps]}
    out = HERE / "crg_solar_report.json"
    out.write_text(json.dumps(doc))
    print("wrote %s  (%d pages, %.2f MB)" %
          (out, len(ps), out.stat().st_size / 1048576))

if __name__ == "__main__":
    main()
