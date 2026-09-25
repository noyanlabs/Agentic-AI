# Shared helper for ppt/docx interpreters - converts Office Math (OMML) XML into LaTeX. Best effort, covers the common constructs.
from lxml import etree

M_NS = "http://schemas.openxmlformats.org/officeDocument/2006/math"
NS = {"m": M_NS}
GREEK = {"α": r"\alpha ", "β": r"\beta ", "γ": r"\gamma ", "δ": r"\delta ", "ε": r"\epsilon ", "θ": r"\theta ", "λ": r"\lambda ", "μ": r"\mu ",
         "π": r"\pi ", "σ": r"\sigma ", "φ": r"\phi ", "ω": r"\omega ", "Δ": r"\Delta ", "Σ": r"\Sigma ", "Ω": r"\Omega ", "Π": r"\Pi ",
         "∞": r"\infty ", "×": r"\times ", "±": r"\pm ", "≤": r"\leq ", "≥": r"\geq ", "≠": r"\neq ", "≈": r"\approx ", "→": r"\to ",
         "∑": r"\sum ", "∫": r"\int ", "∏": r"\prod ", "√": r"\sqrt ", "∂": r"\partial ", "∇": r"\nabla ", "·": r"\cdot ", "÷": r"\div ", "∈": r"\in "}


def _tag(el) -> str:
    return etree.QName(el).localname


def _children(el, name):
    return el.find(f"m:{name}", NS)


def _convert(el) -> str:
    tag = _tag(el)
    if tag == "t":
        return "".join(GREEK.get(ch, ch) for ch in (el.text or ""))
    if tag == "f":
        return r"\frac{" + _convert(_children(el, "num")) + "}{" + _convert(_children(el, "den")) + "}"
    if tag == "sSup":
        return "{" + _convert(_children(el, "e")) + "}^{" + _convert(_children(el, "sup")) + "}"
    if tag == "sSub":
        return "{" + _convert(_children(el, "e")) + "}_{" + _convert(_children(el, "sub")) + "}"
    if tag == "sSubSup":
        return "{" + _convert(_children(el, "e")) + "}_{" + _convert(_children(el, "sub")) + "}^{" + _convert(_children(el, "sup")) + "}"
    if tag == "rad":
        deg = _children(el, "deg")
        d = _convert(deg) if deg is not None else ""
        return (r"\sqrt[" + d + "]{" if d else r"\sqrt{") + _convert(_children(el, "e")) + "}"
    if tag == "nary":
        pr = _children(el, "naryPr")
        chr_el = pr.find("m:chr", NS) if pr is not None else None
        op = GREEK.get(chr_el.get(f"{{{M_NS}}}val"), r"\int ") if chr_el is not None else r"\int "
        sub, sup, body = _children(el, "sub"), _children(el, "sup"), _children(el, "e")
        out = op
        if sub is not None and _convert(sub):
            out += "_{" + _convert(sub) + "}"
        if sup is not None and _convert(sup):
            out += "^{" + _convert(sup) + "}"
        return out + " " + (_convert(body) if body is not None else "")
    if tag == "d":
        pr = _children(el, "dPr")
        beg, end = "(", ")"
        if pr is not None:
            b, e = pr.find("m:begChr", NS), pr.find("m:endChr", NS)
            beg = b.get(f"{{{M_NS}}}val", "(") if b is not None else "("
            end = e.get(f"{{{M_NS}}}val", ")") if e is not None else ")"
        inner = ",".join(_convert(x) for x in el.findall("m:e", NS))
        return r"\left" + beg + inner + r"\right" + end
    if tag == "func":
        return _convert(_children(el, "fName")) + " " + _convert(_children(el, "e"))
    if tag == "m":
        rows = [" & ".join(_convert(c) for c in r.findall("m:e", NS)) for r in el.findall("m:mr", NS)]
        return r"\begin{matrix}" + r" \\ ".join(rows) + r"\end{matrix}"
    return "".join(_convert(c) for c in el)


def omml_to_latex(el) -> str:
    try:
        return _convert(el).strip()
    except Exception:
        return "".join(el.itertext()).strip()


def find_math(xml_element) -> list:
    # returns every math expression found under an element, in document order
    found = []
    for node in xml_element.iter(f"{{{M_NS}}}oMath"):
        latex = omml_to_latex(node)
        if latex:
            found.append(latex)
    return found
