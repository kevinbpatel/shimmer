#!/usr/bin/env python3
"""Extract Steam's controller glyphs into scripts/assets/steam-controller_<type>.svg.

Steam draws the pad in its Big Picture controller indicator with one React
component, `function Ve({type, partial, ...})` in steamui/sp.js: a ternary
chain `type=="ps5" ? <svg/> : type=="xbox" ? ... : <Se/>`, where `partial` picks
a half-transparent variant and `Se` is the generic pad. This turns the full
(non-partial) branch of each type, and `Se`, back into plain SVG files that
scripts/generate-controller-battery.swift bakes into menu-bar assets.

Valve's artwork carries no redistribution grant; using it to match Big Picture
is a deliberate choice by the repo's owner (see CREDITS.md).

Usage: python3 scripts/extract-steam-controller-glyphs.py <path/to/steamui/sp.js>
    (sp.js lives in ~/.local/share/Steam/steamui/ on a Linux Steam install)
"""
import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "assets"

ATTR = {
    "fillRule": "fill-rule", "clipRule": "clip-rule", "clipPath": "clip-path",
    "strokeLinecap": "stroke-linecap", "strokeLinejoin": "stroke-linejoin",
    "strokeWidth": "stroke-width", "strokeMiterlimit": "stroke-miterlimit",
    "className": None, "xmlnsXlink": "xmlns:xlink",
}


class Parser:
    """Just enough of a JS expression parser for `(0,e.jsx)("tag",{...})`."""

    def __init__(self, src: str, pos: int):
        self.s, self.i = src, pos

    def ws(self):
        while self.s[self.i] in " \n\t":
            self.i += 1

    def peek(self, text: str) -> bool:
        self.ws()
        return self.s.startswith(text, self.i)

    def eat(self, text: str):
        self.ws()
        if not self.s.startswith(text, self.i):
            raise ValueError(f"expected {text!r} at {self.s[self.i:self.i + 60]!r}")
        self.i += len(text)

    def string(self) -> str:
        self.ws()
        quote = self.s[self.i]
        end = self.s.index(quote, self.i + 1)
        value = self.s[self.i + 1:end]
        self.i = end + 1
        return value

    def ident(self) -> str:
        self.ws()
        m = re.compile(r"[A-Za-z_$][\w$]*").match(self.s, self.i)
        self.i = m.end()
        return m.group(0)

    def element(self):
        """(0,X.jsx)("tag",{props}) or (0,X.jsx)(Component,{props})."""
        self.eat("(0,")
        self.ident()
        self.eat(".")
        self.ident()          # jsx / jsxs
        self.eat(")(")
        tag = self.string() if self.peek('"') else ("component", self.ident())
        self.eat(",")
        props = self.obj()
        self.eat(")")
        return tag, props

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == '"':
            return self.string()
        if c == "[":
            self.i += 1
            items = []
            while not self.peek("]"):
                items.append(self.element())
                if self.peek(","):
                    self.eat(",")
            self.eat("]")
            return items
        if self.s.startswith("(0,", self.i):
            return self.element()
        return ("ref", self.ident())

    def obj(self):
        self.eat("{")
        props = {}
        while not self.peek("}"):
            if self.peek("..."):
                self.eat("...")
                self.ident()
            else:
                key = self.string() if self.peek('"') else self.ident()
                self.eat(":")
                props[key] = self.value()
            if self.peek(","):
                self.eat(",")
        self.eat("}")
        return props


def to_svg(node) -> str:
    tag, props = node
    attrs, children = [], props.get("children")
    for key, value in props.items():
        if key == "children":
            continue
        name = ATTR.get(key, key)
        if name is None:
            continue
        if isinstance(value, tuple):          # a variable: the clip-path id pair
            value = "url(#clip)" if key == "clipPath" else "clip"
        if value in ("currentColor", "white"):
            value = "#FFFFFF"
        attrs.append(f'{name}="{value}"')
    if tag == "svg" and not any(a.startswith("xmlns=") for a in attrs):
        attrs.insert(0, 'xmlns="http://www.w3.org/2000/svg"')
    if children is None:
        return f"<{tag} {' '.join(attrs)}/>"
    if not isinstance(children, list):
        children = [children]
    return f"<{tag} {' '.join(attrs)}>" + "".join(to_svg(c) for c in children) + f"</{tag}>"


def main():
    src = Path(sys.argv[1]).read_text(encoding="utf-8")
    start = src.index("{const{type:Un,partial:es")
    fn = src[start:src.index("function ", start)]
    written = []
    for m in re.finditer(r'Un=="([A-Za-z0-9_]+)"\?', fn):
        p = Parser(fn, m.end())
        if p.peek("es?"):                     # partial ? <half> : <full>
            p.eat("es?")
            p.element()
            p.eat(":")
        node = p.element()
        (OUT / f"steam-controller_{m.group(1)}.svg").write_text(to_svg(node) + "\n")
        written.append(m.group(1))
    # The fallback component is the generic pad. Minified names repeat across
    # the bundle, so take the definition nearest above this component; its
    # body is `none ? <crossed-out pad> : partial ? <half> : <full>`.
    tail = fn[fn.rindex(":(0,"):]
    fallback = re.search(r'jsx\)\(([A-Za-z_$][\w$]*),', tail).group(1)
    fstart = src.rindex(f"function {fallback}(", 0, start)
    p = Parser(src, src.index("return", fstart) + len("return"))
    p.ident()                                 # the `none` flag
    p.eat("?")
    p.element()                               # crossed-out "no controller"
    p.eat(":")
    if p.peek("es?"):
        p.eat("es?")
        p.element()
        p.eat(":")
    node = p.element()
    (OUT / "steam-controller_generic.svg").write_text(to_svg(node) + "\n")
    written.append("generic")
    print("wrote", ", ".join(written))


if __name__ == "__main__":
    main()
