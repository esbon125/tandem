# mpeg2fpga — guía de usuario (LaTeX)

```sh
make                    # build/mpeg2fpga-user-guide.pdf, versión dev+g<commit>
make VERSION=1.0.0      # como la arma el release
```

Compila con [Tectonic](https://tectonic-typesetting.github.io) 0.15.0 (XeTeX
autocontenido): el Makefile lo baja una vez a `.tools/` y verifica su sha256;
la primera compilación baja los paquetes TeX que usa (fancyhdr, titlesec,
tcolorbox, TikZ...). No hace falta una instalación de TeX Live.

Estilo en `mpeg2fpga-style.sty`, capítulos en `chapters/`.
