#!/usr/bin/env python3
"""Genera banner.svg (90 x 190 cm), un poster de conferencia, como base para Inkscape.

Uso: python gen_banner.py banner.svg   (requiere `segno` y la fuente Montserrat)

Unidades de usuario = mm. Todo el texto es <text>/<tspan> comun (sin flowed
text) para que Inkscape y cualquier visor lo muestren igual. Las imagenes
(placa.jpg, comparacion.png) se enlazan con ruta relativa: deben quedar al lado
del SVG.

Estructura de poster: cabecera institucional, banda de cifras clave, secciones
numeradas (motivacion, objetivo, metodologia, arquitectura, resultados,
conclusiones), llamada a la accion con QR y pie con referencias.
"""
import sys
import segno

OUT = sys.argv[1]
W, H = 900, 1900
M = 45  # margen lateral
CW = W - 2 * M

NAVY, DEEP, BLUE, TEAL, AMBER, RED, GREY, PAPER = (
    "#14213D", "#0B1428", "#1D4E89", "#0F7173", "#E09F3E", "#9E2A2B", "#5C6B73", "#F4F6F8")
INK = "#22303F"     # texto de cuerpo
LINE = "#D5DCE4"    # filetes y bordes suaves
MINT = "#9FD3D4"
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

def text(x, y, lines, size, fill=INK, weight=400, anchor="start", lh=1.3, ident=None, ls=None, halo=None):
    """lines: lista de str, o de listas de (texto, fill, weight) para mezclar estilos."""
    idattr = f' id="{ident}"' if ident else ""
    lsattr = f' letter-spacing="{ls}"' if ls else ""
    if halo:
        lsattr += f' stroke="{halo}" stroke-width="3" stroke-linejoin="round" paint-order="stroke"'
    e(f'<text{idattr} x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
      f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{lsattr} xml:space="preserve">')
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

def box(x, y, w, h, fill, stroke=None, r=6, sw=1.5, dash=None):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    if dash:
        s += f' stroke-dasharray="{dash}"'
    e(f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" rx="{r}" fill="{fill}"{s}/>')

def arrow(x1, y1, x2, y2, both=False, col=GREY):
    ms = ' marker-start="url(#flecha-ini)"' if both else ""
    e(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col}" stroke-width="2.4"'
      f'{ms} marker-end="url(#flecha)"/>')

def section(x, y, n, label, w):
    """Encabezado de seccion de poster: numero en circulo + titulo + filete."""
    e(f'<g id="sec-{n}">')
    e(f'<circle cx="{x + 17}" cy="{y - 10}" r="17" fill="{AMBER}"/>')
    text(x + 17, y - 2.5, [str(n)], 21, NAVY, 800, anchor="middle")
    text(x + 46, y, [label], 27, NAVY, 800)
    e(f'<rect x="{x}" y="{y + 16}" width="{w}" height="1.6" fill="{LINE}"/>')
    e('</g>')

def figlabel(x, y, n, caption, w_lines=None, size=12.5):
    """Epigrafe numerado estilo paper: 'Fig. n. texto'."""
    lines = caption if isinstance(caption, list) else [caption]
    first = [(f"Fig. {n}. ", NAVY, 700), (lines[0], GREY, 500)]
    text(x, y, [first] + lines[1:], size, GREY, 500, lh=1.35)

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
for name, col in [("m2navy", NAVY), ("m2deep", DEEP), ("m2blue", BLUE), ("m2teal", TEAL),
                  ("m2amber", AMBER), ("m2red", RED), ("m2grey", GREY), ("m2paper", PAPER),
                  ("m2ink", INK)]:
    e(f'<linearGradient id="{name}" inkscape:swatch="solid" inkscape:label="{name}">'
      f'<stop offset="0" style="stop-color:{col};stop-opacity:1"/></linearGradient>')
e(f'<marker id="flecha" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" '
  f'orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker>')
e(f'<marker id="flecha-ini" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="5" markerHeight="5" '
  f'orient="auto"><path d="M10,0 L0,5 L10,10 z" fill="context-stroke"/></marker>')
# Trama de "macrobloques" 8x8 para la cabecera: guiño a la DCT por bloques
e(f'<pattern id="bloques" width="24" height="24" patternUnits="userSpaceOnUse">'
  f'<rect width="24" height="24" fill="none" stroke="{WHITE}" stroke-opacity="0.05" stroke-width="0.8"/>'
  f'</pattern>')
e(f'<linearGradient id="fundido" x1="0" y1="0" x2="1" y2="0">'
  f'<stop offset="0" stop-color="{NAVY}" stop-opacity="1"/>'
  f'<stop offset="0.55" stop-color="{NAVY}" stop-opacity="0.6"/>'
  f'<stop offset="1" stop-color="{NAVY}" stop-opacity="0"/></linearGradient>')
e('</defs>')

# ---------------------------------------------------------------- geometria de bandas
HEAD_H = 400          # cabecera azul
STATS_Y, STATS_H = HEAD_H, 122   # banda de cifras clave
BODY_Y = STATS_Y + STATS_H
FOOT_Y = 1840

# ---------------------------------------------------------------- fondo
layer("Fondo", locked=True)
e(f'<rect x="0" y="0" width="{W}" height="{H}" fill="{PAPER}"/>')
e(f'<rect x="0" y="0" width="{W}" height="{HEAD_H}" fill="{NAVY}"/>')
e(f'<rect x="0" y="0" width="{W}" height="{HEAD_H}" fill="url(#bloques)"/>')
e(f'<rect x="0" y="{STATS_Y}" width="{W}" height="{STATS_H}" fill="{DEEP}"/>')
e(f'<rect x="0" y="{STATS_Y}" width="{W}" height="6" fill="{AMBER}"/>')
e(f'<rect x="0" y="{FOOT_Y}" width="{W}" height="{H - FOOT_Y}" fill="{NAVY}"/>')
e('</g>')

layer("Contenido")
# ---------------------------------------------------------------- encabezado
e('<g id="encabezado">')
lh = 84
e(f'<g id="logo-utn" transform="translate({M},{M}) scale({lh / 699.4:.5f})">'
  f'<path d="{LOGO_PATH}" fill="{WHITE}" fill-rule="evenodd"/></g>')
lx = round(M + 595.3 * lh / 699.4 + 24, 1)
text(lx, M + 28, ["Universidad Tecnológica Nacional", "Facultad Regional La Rioja"], 20, WHITE, 700, lh=1.35)
text(lx, M + 82, ["Ingeniería Electrónica · Proyecto Final de Carrera"], 15.5, AMBER, 600)

e('<g id="etiqueta-area">')
tw_ = 92
for i, lab in enumerate(["FPGA", "RISC-V", "LINUX"]):
    ty_ = M + 2 + i * 32
    box(W - M - tw_, ty_, tw_, 26, "none", MINT, r=13, sw=1.4)
    text(W - M - tw_ / 2, ty_ + 18, [lab], 11.5, MINT, 700, anchor="middle", ls=1)
e('</g>')

text(M, 208, ["Decodificador de video",
              [("MPEG-2", AMBER, 800), (" en SoC FPGA", WHITE, 800)],
              "con Linux"], 52, WHITE, 800, lh=1.06, ident="titulo")
text(M, 352, ["Desarrollo integral de un producto de propiedad intelectual"], 21, MINT, 500,
     ident="subtitulo")
text(M, 383, [[("Esteban Adriel Bustamante", WHITE, 700),
               ("   ·   Tutor: Ing. Ricardo Maldonado", "#C9D1DC", 400)]], 17, ident="autores")
e('</g>')

# ---------------------------------------------------------------- banda de cifras clave
e('<g id="cifras-clave">')
text(M, STATS_Y + 28, ["EN UNA PLACA DE USD 133, ESTE DECODIFICADOR LOGRA"], 12, MINT, 700, ls=1.2)
stats = [
    ("bit a bit", "idéntico a la simulación", "del diseño original"),
    ("37 / 37", "flujos de conformidad", "MPEG-2 dentro de la norma"),
    ("2,2×", "tiempo real en CIF", "53,7 imágenes/s"),
    ("68 mW", "consumo estimado", "del decodificador"),
]
sw_ = CW / 4
for i, (big, l1, l2) in enumerate(stats):
    sx = M + i * sw_
    if i:
        e(f'<rect x="{sx - 1:.2f}" y="{STATS_Y + 44}" width="1.2" height="64" fill="{WHITE}" fill-opacity="0.18"/>')
    px_ = sx + (0 if i == 0 else 18)
    text(round(px_, 2), STATS_Y + 75, [big], 35, AMBER if i % 2 == 0 else WHITE, 800)
    text(round(px_, 2), STATS_Y + 95, [l1, l2], 12, "#C9D1DC", 500, lh=1.3)
e('</g>')

# ================================================================ cuerpo
GAP = 22
# ---------------------------------------------------------------- fila A: motivacion | objetivo
AY = BODY_Y + 54
hw = (CW - 40) / 2
section(M, AY, 1, "Motivación", hw)
text(M, AY + 48, ["MPEG-2 sigue vivo en DVD, TV digital",
                  "y archivos broadcast. Los núcleos de",
                  "hardware abiertos que lo decodifican",
                  "están atados a un fabricante y nunca",
                  [("se llevaron a un ", INK, 500), ("producto", NAVY, 800), (" listo para usar.", INK, 500)]],
     14.5, INK, 500, lh=1.42, ident="texto-motivacion")
ox_ = M + hw + 40
section(ox_, AY, 2, "Objetivo", hw)
text(ox_, AY + 48, ["Portar el núcleo abierto mpeg2fpga a",
                    "un SoC FPGA PolarFire, controlarlo",
                    "desde Linux y recorrer el camino",
                    "completo de un producto de PI:",
                    "licencias, versiones y manuales."],
     14.5, INK, 500, lh=1.42, ident="texto-objetivo")

# ---------------------------------------------------------------- fila B: arquitectura | metodologia
BY = AY + 46 + 4 * 14.5 * 1.42 + GAP + 44
AW = 480
section(M, BY, 3, "Arquitectura", AW)
e('<g id="diagrama">')
cy = BY + 34
box(M, cy, AW, 44, WHITE, BLUE, sw=2)
text(M + AW / 2, cy + 19, ["Navegador · biblioteca Python"], 16, BLUE, 700, anchor="middle")
text(M + AW / 2, cy + 36, ["envía el video y recibe las imágenes"], 12, GREY, 500, anchor="middle")
acx = M + AW / 2
arrow(acx - 40, cy + 48, acx - 40, cy + 76)
arrow(acx + 40, cy + 76, acx + 40, cy + 48)
text(acx - 52, cy + 67, ["flujo MPEG-2"], 12, GREY, 600, anchor="end")
text(acx + 52, cy + 67, ["imágenes · red"], 12, GREY, 600)
sy = cy + 80
sh = 150
box(M, sy, AW, sh, "#E4E9EF", NAVY, r=10, sw=2)
text(M + 14, sy + 22, ["PolarFire SoC"], 14, NAVY, 800)
ib_gap = 44
bw = (AW - 28 - ib_gap) / 2
by, bh = sy + 30, 108
for bx, col, head, lines in [
        (M + 14, BLUE, "RISC-V · Linux", ["driver de kernel", "(pruebas KUnit)", "servicio de red v1"]),
        (M + 14 + bw + ib_gap, TEAL, "Lógica FPGA", ["núcleo MPEG-2", "VLD → IDCT → MC", "APB · AXI4 · DMA"])]:
    box(bx, by, bw, bh, WHITE, col, sw=2)
    e(f'<rect x="{bx:.2f}" y="{by:.2f}" width="{bw:.2f}" height="32" rx="6" fill="{col}"/>')
    text(round(bx + bw / 2, 2), by + 22, [head], 15, WHITE, 700, anchor="middle")
    text(round(bx + 12, 2), by + 52, lines, 13, INK, 500, lh=1.4)
mx1, mx2 = M + 14 + bw, M + 14 + bw + ib_gap
arrow(round(mx1 + 4, 2), by + 70, round(mx2 - 4, 2), by + 70, both=True)
text(round((mx1 + mx2) / 2, 2), by + 60, ["regs"], 10.5, GREY, 700, anchor="middle")
text(round((mx1 + mx2) / 2, 2), by + 88, ["IRQ"], 10.5, GREY, 700, anchor="middle")
dy_ = sy + sh + 26
arrow(acx, sy + sh + 2, acx, dy_ - 2, both=True)
box(M, dy_, AW, 44, WHITE, GREY, sw=2)
text(M + AW / 2, dy_ + 19, ["Memoria DDR4"], 15, NAVY, 700, anchor="middle")
text(M + AW / 2, dy_ + 36, ["buffer de video y memoria de cuadros"], 12, GREY, 500, anchor="middle")
e('</g>')
arch_end = dy_ + 44

MX = M + AW + 40
MW = W - M - MX
section(MX, BY, 4, "Metodología", MW)
steps = [("Simular", "el núcleo original (Icarus)"),
         ("Portar", "memorias y reloj a PolarFire"),
         ("Integrar", "APB, AXI4 y DMA con el MSS"),
         ("Firmware", "driver Linux, servicio de red"),
         ("Calificar", "39 flujos de conformidad"),
         ("Publicar", "versión firmada + manuales")]
e('<g id="metodologia">')
st_y0, st_dy = BY + 52, (arch_end - BY - 60) / (len(steps) - 1)
e(f'<line x1="{MX + 13}" y1="{st_y0}" x2="{MX + 13}" y2="{st_y0 + st_dy * (len(steps) - 1):.2f}" '
  f'stroke="{LINE}" stroke-width="3"/>')
for i, (t, dsc) in enumerate(steps):
    yy = st_y0 + i * st_dy
    col = AMBER if i == len(steps) - 1 else (TEAL if i >= 3 else BLUE)
    e(f'<circle cx="{MX + 13}" cy="{yy:.2f}" r="13" fill="{col}"/>')
    text(MX + 13, round(yy + 5, 2), [str(i + 1)], 13, WHITE if col != AMBER else NAVY, 800, anchor="middle")
    text(MX + 38, round(yy + 1, 2), [t], 16, NAVY, 800)
    text(MX + 38, round(yy + 20, 2), [dsc], 12.5, GREY, 500)
e('</g>')

# ---------------------------------------------------------------- fila C: resultados
SY = arch_end + GAP + 44
section(M, SY, 5, "Resultados", CW)
fy = SY + 34
fh = round(CW * 268 / 1776, 2)
e('<g id="fig-comparacion">')
e(f'<clipPath id="recorte-comp"><rect x="{M}" y="{fy}" width="{CW}" height="{fh}" rx="8"/></clipPath>')
e(f'<image x="{M}" y="{fy}" width="{CW}" height="{fh}" preserveAspectRatio="none" '
  f'clip-path="url(#recorte-comp)" xlink:href="comparacion.png"/>')
for i, (lab, col, wl) in enumerate([("FPGA", AMBER, 66), ("Referencia (software)", WHITE, 192),
                                    ("Diferencia ×32", MINT, 140)]):
    lx_ = M + i * CW / 3 + 10
    e(f'<rect x="{lx_:.2f}" y="{fy + 10}" width="{wl}" height="26" rx="13" fill="{DEEP}" fill-opacity="0.85"/>')
    text(round(lx_ + wl / 2, 2), fy + 28, [lab], 13, col, 700, anchor="middle")
text(round(M + 5 * CW / 6, 2), round(fy + fh / 2 + 5, 2), ["negro = sin diferencia visible"],
     13, "#8A97A6", 600, anchor="middle")
e('</g>')
figlabel(M, fy + fh + 20, 1, "Un cuadro decodificado por la FPGA y por el decodificador de referencia mpeg2decode.", size=12)

gy = fy + fh + 58
gw = (CW - 50) / 2
e('<g id="fig-conformidad">')
text(M, gy, ["Conformidad · 39 flujos de prueba"], 15.5, NAVY, 800)
bar_y, bar_h = gy + 16, 38
x_ = M
for n, col, lab in [(3, NAVY, "3"), (34, TEAL, "34"), (2, "#B7C1CC", "")]:
    wseg = gw * n / 39
    e(f'<rect x="{x_:.2f}" y="{bar_y}" width="{wseg:.2f}" height="{bar_h}" fill="{col}"/>')
    if lab:
        text(round(x_ + wseg / 2, 2), bar_y + 26, [lab], 16, WHITE, 800, anchor="middle")
    x_ += wseg
for i, (col, lab) in enumerate([(NAVY, "bit-exactos"), (TEAL, "dentro de la tolerancia de la norma"),
                                ("#B7C1CC", "MPEG-1, fuera de alcance")]):
    lyy = bar_y + bar_h + 22 + i * 18
    e(f'<rect x="{M}" y="{lyy - 10}" width="11" height="11" rx="2" fill="{col}"/>')
    text(M + 18, lyy, [lab], 12, INK, 500)
text(M, bar_y + bar_h + 92, [[("0 con deriva", NAVY, 800), ("  ·  IDCT cumple IEEE 1180", GREY, 600)]], 12.5)
e('</g>')

e('<g id="fig-rendimiento">')
rx0 = M + gw + 50
text(rx0, gy, ["Velocidad · veces el tiempo real"], 15.5, NAVY, 800)
lab_w = 108
scale = (gw - lab_w - 52) / 2.24
rtx = rx0 + lab_w + scale
e(f'<line x1="{rtx:.2f}" y1="{gy + 10}" x2="{rtx:.2f}" y2="{gy + 118}" stroke="{RED}" stroke-width="1.8" stroke-dasharray="5 4"/>')
for i, (lab, v, col, vl) in enumerate([("CIF 352×288", 2.24, AMBER, "2,24×"),
                                       ("SD 704×480", 0.79, BLUE, "0,79×"),
                                       ("SD 720×576", 0.52, BLUE, "0,52×")]):
    ry = gy + 18 + i * 32
    text(rx0, ry + 17, [lab], 12, INK, 600)
    e(f'<rect x="{rx0 + lab_w}" y="{ry}" width="{v * scale:.2f}" height="24" rx="3" fill="{col}"/>')
    text(round(rx0 + lab_w + v * scale + 6, 2), ry + 17, [vl], 12.5, NAVY, 800, halo=PAPER)
text(round(rtx + 6, 2), gy + 116, ["tiempo real"], 11.5, RED, 700)
text(rx0, bar_y + bar_h + 92, [[("3,1× más rápido", NAVY, 800), (" tras optimizar en SD", GREY, 600)]], 12.5)
e('</g>')
figlabel(M, bar_y + bar_h + 120, 2, "Conformidad con ISO/IEC 13818-2 (izq.) y tasa medida en la placa (der.).", size=12)
res_end = bar_y + bar_h + 120

# ---------------------------------------------------------------- fila D: conclusiones | probalo
CY = res_end + GAP + 44
cwl = 400
section(M, CY, 6, "Conclusiones", cwl)
concl = [["El port reproduce el diseño", "original bit a bit en hardware."],
         ["Se corrigieron dos errores del", "núcleo original: 3 líneas de RTL."],
         ["Tiempo real en CIF; en SD el", "límite es la reconstrucción."],
         ["Producto abierto, versionado y", "calificado en la placa real."]]
for i, (a, b) in enumerate(concl):
    yy = CY + 46 + i * 47
    e(f'<path d="M{M + 2},{yy - 7} l5,5 l10,-11" fill="none" stroke="{TEAL}" stroke-width="3.2" '
      f'stroke-linecap="round" stroke-linejoin="round"/>')
    text(M + 26, yy, [a, b], 14, INK, 500, lh=1.35)

# Llamada a la accion: foto de la placa + QR al repositorio
qx = M + cwl + 30
qw = W - M - qx
qy = CY - 30
qh = FOOT_Y - 22 - qy
e('<g id="explora">')
box(qx, qy, qw, qh, NAVY, r=12)
pw = 170
e(f'<clipPath id="recorte-foto"><rect x="{qx}" y="{qy}" width="{pw}" height="{qh}" rx="12"/></clipPath>')
e(f'<image id="foto-setup" x="{qx}" y="{qy}" width="{pw}" height="{qh}" preserveAspectRatio="xMidYMid slice" '
  f'clip-path="url(#recorte-foto)" xlink:href="placa.jpg"/>')
e(f'<rect x="{qx + pw - 12}" y="{qy}" width="12" height="{qh}" fill="{NAVY}"/>')
kx = qx + pw + 6
kw = qx + qw - kx
text(round(kx + kw / 2, 2), qy + 36, ["EXPLORÁ EL PROYECTO EN:"], 12.5, AMBER, 800, anchor="middle")
qsz = 110
ox, oy = round(kx + (kw - qsz) / 2, 2), qy + 56
box(ox - 7, oy - 7, qsz + 14, qsz + 14, WHITE, r=7)
qr = segno.make("https://github.com/esbon125/tandem", error="m")
mat = list(qr.matrix)
n = len(mat)
mod = qsz / n
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
text(round(kx + kw / 2, 2), oy + qsz + 27, ["github.com/", "esbon125/tandem"],
     13, WHITE, 700, anchor="middle", lh=1.32)
e('</g>')
e('</g>')  # capa Contenido

# ---------------------------------------------------------------- pie
layer("Pie")
text(M, FOOT_Y + 25, [[("Referencias  ", AMBER, 700),
                       ("ISO/IEC 13818-2 · K. De Vleeschauwer, mpeg2fpga · IEEE 1180-1990", "#C9D1DC", 500),
                       ("     Abierto  ", AMBER, 700), ("CERN-OHL-S · MIT", WHITE, 600)]], 11.5)
text(M, FOOT_Y + 46, [[("Código  ", AMBER, 700), ("github.com/esbon125/tandem", WHITE, 700),
                       ("     Icarus Verilog · Linux · Python · FFmpeg · KUnit · Renode · Git · Libero SoC", "#9FB0C3", 400)]],
     11.5)
e('</g>')

# ---------------------------------------------------------------- guias (no imprimir)
layer("Guias (no imprimir)", hidden=True, locked=True)
e(f'<rect x="{M}" y="{M}" width="{CW}" height="{H - 2 * M}" fill="none" stroke="#FF00FF" '
  f'stroke-width="1" stroke-dasharray="8 6"/>')
e('</g>')
e('</svg>')

open(OUT, "w", encoding="utf-8").write("\n".join(out))
