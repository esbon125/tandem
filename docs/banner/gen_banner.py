#!/usr/bin/env python3
"""Genera banner.svg (90 x 190 cm) como punto de partida para Inkscape.

Unidades de usuario = mm. Todo el texto es <text>/<tspan> comun (sin flowed
text) para que Inkscape y cualquier visor lo muestren igual.
"""
import sys
import segno

OUT = sys.argv[1]
W, H = 900, 1900
M = 50  # margen lateral

NAVY, BLUE, TEAL, AMBER, RED, GREY, PAPER = (
    "#14213D", "#1D4E89", "#0F7173", "#E09F3E", "#9E2A2B", "#5C6B73", "#F4F6F8")
WHITE = "#FFFFFF"
FONT = "Montserrat"

LOGO_PATH = ("m246.6 0h102v190.8c80.8-22.4 140.4-96.7 140.4-184.4h106.3c0 146.5-106.8 "
             "268.9-246.6 293.2v4.4h233.9v104.2h-214.4c130 31.8 227 149.5 227 289.1h-106.2c0"
             "-87.7-59.6-162-140.3-184.4v186.5h-102v-186.5c-80.7 22.4-140.3 96.7-140.3 184.4h"
             "-106.4c0-139.6 97-257.3 227-289.1h-214.2v-104.2h233.9v-4.4c-139.9-24.3-246.7"
             "-146.7-246.7-293.2h106.3c0 87.7 59.6 162 140.3 184.4z")

out = []
def e(s): out.append(s)

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def text(x, y, lines, size, fill=NAVY, weight=400, anchor="start", lh=1.3, ident=None):
    """lines: lista de str, o de listas de (texto, fill, weight) para mezclar estilos."""
    idattr = f' id="{ident}"' if ident else ""
    e(f'<text{idattr} x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
      f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" xml:space="preserve">')
    for i, ln in enumerate(lines):
        dy = 0 if i == 0 else round(size * lh, 2)
        if isinstance(ln, str):
            e(f'<tspan x="{x}" dy="{dy}">{esc(ln)}</tspan>')
        else:
            e(f'<tspan x="{x}" dy="{dy}">' + "".join(
                f'<tspan fill="{f}" font-weight="{w}">{esc(t)}</tspan>' for t, f, w in ln) + "</tspan>")
    e("</text>")

def layer(label, hidden=False, locked=False):
    st = ' style="display:none"' if hidden else ""
    lk = ' sodipodi:insensitive="true"' if locked else ""
    e(f'<g inkscape:groupmode="layer" inkscape:label="{label}"{st}{lk}>')

def section_title(y, label):
    text(M, y, [label], 30, NAVY, 800)
    e(f'<rect x="{M}" y="{y + 9}" width="70" height="4" fill="{AMBER}"/>')

def box(x, y, w, h, fill, stroke=None, r=6, sw=1.5, dash=None):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    if dash:
        s += f' stroke-dasharray="{dash}"'
    e(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"{s}/>')

def arrow(x1, y1, x2, y2, both=False):
    ms = ' marker-start="url(#flecha-ini)"' if both else ""
    e(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{GREY}" stroke-width="2.4"'
      f'{ms} marker-end="url(#flecha)"/>')

# ---------------------------------------------------------------- cabecera SVG
e('<?xml version="1.0" encoding="UTF-8"?>')
e(f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
  f'xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" '
  f'xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" '
  f'width="{W}mm" height="{H}mm" viewBox="0 0 {W} {H}" version="1.1">')
e('<title>Banner - Decodificador MPEG-2 en SoC FPGA con Linux</title>')
e('<sodipodi:namedview id="namedview" inkscape:document-units="mm" pagecolor="#ffffff" '
  'bordercolor="#666666" showgrid="false"/>')
e('<defs>')
# Paleta como muestras (Inkscape: Relleno y borde > Muestras)
for name, col in [("m2navy", NAVY), ("m2blue", BLUE), ("m2teal", TEAL), ("m2amber", AMBER),
                  ("m2red", RED), ("m2grey", GREY), ("m2paper", PAPER)]:
    e(f'<linearGradient id="{name}" inkscape:swatch="solid" inkscape:label="{name}">'
      f'<stop offset="0" style="stop-color:{col};stop-opacity:1"/></linearGradient>')
e(f'<marker id="flecha" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" '
  f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{GREY}"/></marker>')
e(f'<marker id="flecha-ini" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="5" markerHeight="5" '
  f'orient="auto"><path d="M10,0 L0,5 L10,10 z" fill="{GREY}"/></marker>')
e('</defs>')

# ---------------------------------------------------------------- fondo
layer("Fondo", locked=True)
e(f'<rect x="0" y="0" width="{W}" height="{H}" fill="{PAPER}"/>')
e(f'<rect x="0" y="0" width="{W}" height="500" fill="{NAVY}"/>')
e(f'<rect x="0" y="500" width="{W}" height="8" fill="{AMBER}"/>')
e(f'<rect x="0" y="1770" width="{W}" height="{H - 1770}" fill="{NAVY}"/>')
e('</g>')

layer("Contenido")
# ---------------------------------------------------------------- encabezado
e('<g id="encabezado">')
lh = 115
e(f'<g id="logo-utn" transform="translate({M},{M}) scale({lh / 699.4:.5f})">'
  f'<path d="{LOGO_PATH}" fill="{WHITE}" fill-rule="evenodd"/></g>')
lx = round(M + 595.3 * lh / 699.4 + 28, 1)
text(lx, M + 30, ["Universidad Tecnológica Nacional", "Facultad Regional La Rioja"], 24, WHITE, 700, lh=1.35)
text(lx, M + 105, ["Ingeniería Electrónica · Proyecto Final"], 19, AMBER, 500)

text(M, 268, ["Decodificador de video",
              [("MPEG-2", AMBER, 800), (" en SoC FPGA", WHITE, 800)],
              "con Linux"], 58, WHITE, 800, lh=1.12, ident="titulo")
text(M, 432, ["Desarrollo integral de un producto de propiedad intelectual"], 23, "#9FD3D4", 500,
     ident="subtitulo")
text(M, 474, [[("Esteban Adriel Bustamante", WHITE, 700),
               ("   ·   Tutor: Ing. Ricardo Maldonado", "#C9D1DC", 400)]], 19, ident="autores")
e('</g>')

# Fila central: bajada + QR a la izquierda, foto vertical (3:4) a la derecha
RY = 548
pw, ph = 345, 460
px = W - M - pw
cw = px - 30 - M  # ancho de la columna izquierda

# ---------------------------------------------------------------- bajada
text(M, RY + 18, ["Un decodificador de video MPEG-2",
                  "(ISO/IEC 13818-2) hecho en hardware",
                  "sobre un SoC FPGA PolarFire,",
                  "manejado desde Linux y llevado a",
                  "producto: RTL, driver, protocolo de",
                  "red, documentación y versiones",
                  "firmadas."],
     19, NAVY, 500, lh=1.45, ident="bajada")

# ---------------------------------------------------------------- foto del setup
e(f'<clipPath id="recorte-foto"><rect x="{px}" y="{RY}" width="{pw}" height="{ph}" rx="10"/></clipPath>')
e(f'<image id="foto-setup" x="{px}" y="{RY}" width="{pw}" height="{ph}" preserveAspectRatio="xMidYMid slice" '
  f'clip-path="url(#recorte-foto)" xlink:href="placa.jpg"/>')
text(px, RY + ph + 22, ["La Discovery Kit en su caja, con la",
                        "demostración web corriendo de fondo"], 14, GREY, 500, lh=1.35,
     ident="epigrafe-foto")

# ---------------------------------------------------------------- QR
qx, qw = M, cw
qy, qh = RY + 210, 250
e('<g id="qr-demo">')
box(qx, qy, qw, qh, WHITE, r=10)
e(f'<path d="M{qx},{qy + 50}v-40a10,10 0 0 1 10,-10h{qw - 20}a10,10 0 0 1 10,10v40z" fill="{TEAL}"/>')
text(qx + 20, qy + 34, ["Probalo en vivo"], 23, WHITE, 800)
qr = segno.make("https://esbon125.github.io/tandem/", error="m")
mat = list(qr.matrix)
n = len(mat)
qsz = 176
mod = qsz / n
ox, oy = qx + 18, qy + 62
d = []
for r, row in enumerate(mat):
    c = 0
    while c < n:
        if row[c]:
            s = c
            while c < n and row[c]:
                c += 1
            d.append(f"M{ox + s * mod:.3f},{oy + r * mod:.3f}h{(c - s) * mod:.3f}v{mod:.3f}h{-(c - s) * mod:.3f}z")
        else:
            c += 1
e(f'<path id="qr" d="{"".join(d)}" fill="{NAVY}"/>')
text(ox + qsz + 20, oy + 40, ["Escaneá, subí", "un video y", "decodificalo", "en la FPGA", "desde el celular"],
     17, NAVY, 600, lh=1.4)
e('</g>')

# ---------------------------------------------------------------- arquitectura
section_title(1100, "Cómo funciona")
e('<g id="diagrama">')
cy = 1125
box(M + 150, cy, 500, 62, WHITE, BLUE, sw=2)
text(W / 2, cy + 28, ["Navegador · biblioteca Python"], 20, BLUE, 700, anchor="middle")
text(W / 2, cy + 50, ["envía el video y recibe las imágenes"], 14.5, GREY, 400, anchor="middle")
arrow(W / 2 - 60, cy + 66, W / 2 - 60, cy + 100)
arrow(W / 2 + 60, cy + 100, W / 2 + 60, cy + 66)
text(W / 2 - 75, cy + 89, ["flujo MPEG-2"], 15, GREY, 600, anchor="end")
text(W / 2 + 75, cy + 89, ["imágenes"], 15, GREY, 600)
text(W / 2, cy + 89, ["red"], 14, GREY, 400, anchor="middle")
sy = cy + 104
box(M, sy, W - 2 * M, 200, "#E4E9EF", NAVY, r=10, sw=2)
text(M + 18, sy + 28, ["PolarFire SoC"], 18, NAVY, 800)
bw, by, bh = 345, sy + 40, 143
box(M + 18, by, bw, bh, WHITE, BLUE, sw=2)
e(f'<rect x="{M + 18}" y="{by}" width="{bw}" height="40" rx="6" fill="{BLUE}"/>')
text(M + 18 + bw / 2, by + 27, ["5 núcleos RISC-V"], 19, WHITE, 700, anchor="middle")
text(M + 36, by + 70, ["Linux", "driver de kernel con pruebas", "servicio de red, protocolo v1"],
     16, NAVY, 500, lh=1.45)
fx = W - M - 18 - bw
box(fx, by, bw, bh, WHITE, TEAL, sw=2)
e(f'<rect x="{fx}" y="{by}" width="{bw}" height="40" rx="6" fill="{TEAL}"/>')
text(fx + bw / 2, by + 27, ["Lógica FPGA"], 19, WHITE, 700, anchor="middle")
text(fx + 18, by + 70, ["núcleo decodificador MPEG-2", "VLD → IDCT → compensación", "puentes APB y AXI4, DMA"],
     16, NAVY, 500, lh=1.45)
mx1, mx2 = M + 18 + bw, fx
arrow(mx1 + 4, by + 95, mx2 - 4, by + 95, both=True)
text((mx1 + mx2) / 2, by + 85, ["regs"], 13, GREY, 600, anchor="middle")
text((mx1 + mx2) / 2, by + 117, ["IRQ"], 13, GREY, 600, anchor="middle")
dy_ = sy + 224
box(M + 150, dy_, 500, 60, WHITE, GREY, sw=2)
text(W / 2, dy_ + 26, ["Memoria DDR4"], 19, NAVY, 700, anchor="middle")
text(W / 2, dy_ + 48, ["buffer de video y memoria de cuadros"], 14.5, GREY, 400, anchor="middle")
arrow(M + 18 + bw / 2, by + bh + 4, M + 18 + bw / 2, dy_ - 4, both=True)
arrow(fx + bw / 2, by + bh + 4, fx + bw / 2, dy_ - 4, both=True)
e('</g>')

# ---------------------------------------------------------------- resultados
section_title(1557, "Resultados")
tiles = [
    ("bit a bit", "hardware idéntico a la", "simulación del diseño original"),
    ("37 / 37", "flujos de conformidad", "dentro de la norma"),
    ("2,2×", "tiempo real en CIF", "53,7 imágenes por segundo"),
    ("IEEE 1180", "la IDCT cumple las", "seis condiciones del estándar"),
    ("68 mW", "consumo estimado", "del decodificador"),
    ("USD 133", "costo total", "del hardware"),
]
gap = 16
tw = (W - 2 * M - 2 * gap) / 3
th = 86
ty0 = 1580
e('<g id="cifras">')
for i, (big, l1, l2) in enumerate(tiles):
    tx = M + (i % 3) * (tw + gap)
    ty = ty0 + (i // 3) * (th + 10)
    box(round(tx, 2), ty, round(tw, 2), th, WHITE, r=8)
    e(f'<rect x="{tx:.2f}" y="{ty}" width="6" height="{th}" fill="{AMBER if i % 2 == 0 else TEAL}"/>')
    text(round(tx + 22, 2), ty + 40, [big], 32, NAVY, 800)
    text(round(tx + 22, 2), ty + 62, [l1, l2], 13.5, GREY, 500, lh=1.3)
e('</g>')
e('</g>')  # capa Contenido

# ---------------------------------------------------------------- pie
layer("Pie")
text(M, 1820, [[("Licencias abiertas: ", AMBER, 700), ("CERN-OHL-S (hardware) · MIT (software)", WHITE, 500)],
               [("Entregables: ", AMBER, 700), ("versiones firmadas · manual de usuario · manual de referencia", WHITE, 500)]],
     16, lh=1.5)
text(M, 1876, ["Herramientas: Icarus Verilog · Linux · Python · FFmpeg · KUnit · Renode · Git · Libero SoC"],
     13.5, "#9FB0C3", 400)
e('</g>')

# ---------------------------------------------------------------- guias (no imprimir)
layer("Guias (no imprimir)", hidden=True, locked=True)
e(f'<rect x="{M}" y="{M}" width="{W - 2 * M}" height="{H - 2 * M}" fill="none" stroke="#FF00FF" '
  f'stroke-width="1" stroke-dasharray="8 6"/>')
e('</g>')
e('</svg>')

open(OUT, "w", encoding="utf-8").write("\n".join(out))
