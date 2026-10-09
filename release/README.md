# Releases

Una release se pide con una versión y sale sola, o no sale:

**Actions → Release → Run workflow → `version: v1.0.0`** (o `v1.0.0-rc1`,
que se publica como pre-release)

`release.yml` corre `release/qualify.sh` en la máquina conectada a la placa:

1. **preflight** — la placa responde, corre el bitstream que fija
   `manifest.json` y el kernel para el que se compila el driver
2. **build** — driver, conversor nativo, decodificador de referencia
3. **deploy** — driver, `mpeg2fpgad` y las herramientas de regresión en la placa
4. **regresión** — `tools/regress` (hardware_development): conformidad contra
   `baseline.json`, determinismo, robustez, decode rate
5. **punta a punta** — `e2e_check.py` por el daemon y la librería: cada frame
   idéntico al baseline grabado (`e2e_baseline.json`), mediana de fps ≥ piso
6. **artefactos** — recién ahí: librería Python (wheel probado), user guide,
   bundle de la placa, el `.job` del bitstream, notas, `SHA256SUMS`

y sólo si todo pasó, el job `release` mergea en `master` **exactamente los
commits que se calificaron** de docs, hardware_development y
firmware_development (`--no-ff`; un conflicto aborta antes de pushear nada),
taggea cada rama como `vX.Y.Z-<rama>` y master como `vX.Y.Z`, y publica la
release con esos archivos adjuntos. Si algo falla, el reporte queda como
artifact `qualification-failure-vX.Y.Z` y no se publica nada.

`release.yml` vive en firmware_development y en master, y tiene que ser igual
en las dos: cada release mergea firmware_development en master.

A mano es lo mismo, sin publicar: `release/qualify.sh 1.0.0` deja todo en
`release/dist/1.0.0/`.

## Configuración, una sola vez

**Runner self-hosted** en la PC conectada a la placa (los runners de GitHub no
llegan a una red privada): Settings → Actions → Runners → New self-hosted
runner, con las etiquetas `self-hosted, linux, mpeg2fpga-board`.

**Variables del repositorio** (Settings → Secrets and variables → Variables):

| variable | ejemplo |
|---|---|
| `MPEG2FPGA_BOARD` | `root@192.168.18.5` |
| `MPEG2FPGA_STREAMS_DIR` | `/home/esbon/Proyectos/tandem/trunk/mpeg2fpga/tools/streams` |

y el secret `RELEASE_PAT` (token personal con scope `repo`), para que el merge,
los tags y la release queden a nombre de una persona y no del bot.

**En esa máquina:** clave ssh sin passphrase hacia la placa; el árbol del
kernel compilado (`~/kernel-src/linux4microchip-linux`, o `KERNEL_SRC`);
`riscv64-linux-gnu-gcc`; `python3.11` (librería, e2e) y `python3` con numpy
(`tools/regress`); los streams de conformidad (`tools/streams/retrieve`); los
bitstreams en `~/mpeg2fpga-bitstreams` (o `BITSTREAM_DIR`).

## Cuando cambia el bitstream

La síntesis no corre en la release (40 min de Libero, licencia): se hace una
vez y se fija.

1. Sintetizar y programar (`soc_build/build_mpeg2fpga_soc.tcl`, pasos
   SYNTHESIZE … PROGRAM). `build_id.v` lleva el commit al bitstream.
2. Exportar el `.job`: `SCRIPT_ARGS:EXPORT_FPE:<dir>` — el directorio **sin
   `+`**, que Libero usa como separador de argumentos — y moverlo a
   `~/mpeg2fpga-bitstreams/<hash>/`.
3. Actualizar `manifest.json` (build, dir, job, sha256).
4. Si los frames cambian a propósito, volver a grabar el baseline punta a
   punta: `e2e_check.py --record` (y `tools/regress/regress.py --record` del
   lado hardware), revisando antes que el cambio sea el esperado.

## El piso de fps

`manifest.json: fps_floor` (o el input `fps_floor` del workflow). Con el
bitstream `0.1.0+8004bc9` la mediana medida de punta a punta varía entre ~18.7
y ~20.3 fps según la corrida, así que un piso de 20 fallaría sin que nada haya
cambiado: está en 18.
