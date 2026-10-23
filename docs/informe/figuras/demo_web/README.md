# Capturas de la demo web (para el informe final)

Página: https://esbon125.github.io/tandem/ (rama `gh-pages`). Capturadas el
2026-10-13 con `tools/demo-clip/capture_screenshots.js` (rama
`firmware_development`), Chrome headless, tema claro, densidad 2x (3x la de
celular), bitstream `0.1.0+8004bc9`, pasando por la entrada pública del
Tailscale Funnel como cualquier visitante. Cada captura de la demo en vivo es
una decodificación real en la placa; las cifras que se ven son las de esa
corrida.

Para regenerarlas (la demo en vivo tiene que estar en línea):

```sh
NODE_PATH=<dir con puppeteer-core>/node_modules node capture_screenshots.js OUTDIR \
    --resolve mpeg2fpga.tail5099f3.ts.net=$(dig +short @8.8.8.8 mpeg2fpga.tail5099f3.ts.net | head -1) \
    --upload <un video cualquiera>
```

| archivo | qué muestra | epígrafe sugerido |
|---|---|---|
| `demo_vista_general.png` | la página al entrar, demo en línea | Página pública de la demo: la demo en vivo arriba y el resultado verificado abajo. |
| `demo_reproduciendo.png` | clip de la batalla reproduciéndose a tiempo real mientras siguen llegando cuadros | Demo en vivo: el FPGA decodifica el clip y los cuadros se reproducen a tiempo real mientras siguen llegando. |
| `demo_buffer_red_lenta.png` | red emulada a 0.5 Mbit/s: la placa a 2.05x, la red a 0.70x, la página cargando buffer | Con una conexión lenta la placa sigue decodificando a 2.05x tiempo real; la página mide la red (0.70x) y carga el buffer justo para reproducir sin cortes. |
| `demo_resultado.png` | corrida terminada, pausada en el cuadro 241 | Resultado de una corrida: decodificación a 2.01x tiempo real en la placa, MAD medio 0.081 y error pico 3/255 frente a la referencia. |
| `demo_metricas.png` | solo las cuatro métricas | Métricas de la corrida: tasa de la placa, tasa de llegada, MAD y error pico. |
| `demo_grafico_mad.png` | solo el MAD por cuadro | MAD por cuadro frente al decodificador de referencia; el patrón periódico es el GOP (I/P/B). |
| `demo_video_subido.png` | un .mov H.264 1280x534 de 30 s, con audio, normalizado a MPEG-2 352x288 24 fps, 20 s | Un video arbitrario subido por el usuario se normaliza al régimen medido antes de mandarlo a la placa. |
| `demo_comparacion_referencia.png` | FPGA, mpeg2decode y diferencia x32, cuadro de los 14 s | Salida del FPGA (izq.), decodificador de referencia mpeg2decode (centro) y diferencia absoluta amplificada x32 (der.). |
| `demo_movil.png` | la demo en un celular (390 px) | La demo en un celular. |
| `demo_cliente_remoto_batalla.png` | captura manual (tema oscuro) desde un escritorio remoto, fuera de la red de la placa, 2026-10-14: placa 2.12x, llegada 2.06x | Desde una red externa, el clip de la batalla llega a 2.06x tiempo real; con la primera versión (cuadros en JPEG y el decoder frenado por la red) el mismo cliente veía 0.9x. |

Nota para el texto: lo que se ve en el video llega recomprimido (H.264) para el
viaje hasta el navegador; MAD y error pico se calculan sobre la salida cruda del
decodificador, antes de esa recompresión.

## LaTeX

```latex
% en el preámbulo
\usepackage{graphicx}
\graphicspath{{figuras/demo_web/}}

\begin{figure}[htbp]
  \centering
  \includegraphics[width=0.8\linewidth]{demo_buffer_red_lenta}
  \caption{Con una conexión lenta la placa sigue decodificando a 2.05$\times$
    tiempo real; la página mide la red (0.70$\times$) y carga el buffer justo
    para reproducir sin cortes.}
  \label{fig:demo-buffer}
\end{figure}

% dos capturas lado a lado (requiere \usepackage{subcaption})
\begin{figure}[htbp]
  \centering
  \begin{subfigure}{0.48\linewidth}
    \includegraphics[width=\linewidth]{demo_resultado}
    \caption{Clip precargado.}
  \end{subfigure}\hfill
  \begin{subfigure}{0.48\linewidth}
    \includegraphics[width=\linewidth]{demo_video_subido}
    \caption{Video subido y normalizado.}
  \end{subfigure}
  \caption{Demo en vivo.}
  \label{fig:demo-vivo}
\end{figure}

\begin{figure}[htbp]
  \centering
  \includegraphics[width=\linewidth]{demo_comparacion_referencia}
  \caption{Salida del FPGA (izq.), decodificador de referencia
    \texttt{mpeg2decode} (centro) y diferencia absoluta amplificada
    $\times$32 (der.).}
  \label{fig:demo-comparacion}
\end{figure}
```

Contenido de los clips: *Tears of Steel*, © Blender Foundation |
mango.blender.org, CC BY 3.0. Citarlo en el informe junto a las figuras que lo
muestran.
