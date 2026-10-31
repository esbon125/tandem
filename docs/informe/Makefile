# Informe final.  `make` -> build/informe.pdf
# Usa el mismo Tectonic fijado que la guía de usuario (firmware_development).
TECTONIC_VERSION = 0.15.0
TECTONIC_SHA256  = dfb82876f2986862996e564fa507a9e576e0c1e3bee63c2c1bd677c2543e6407
TECTONIC = .tools/tectonic

build/informe.pdf: informe.tex bibliografia.bib $(wildcard capitulos/*.tex anexos/*.tex portada/*.tex preambulo/* figuras/* figuras/*/*) $(TECTONIC)
	@mkdir -p build
	TEXINPUTS=preambulo: $(TECTONIC) -X compile --outdir build -Z search-path=preambulo $<

# Para la imprenta: `make imprenta`.
#   informe-interior.pdf -- el informe sin la tapa recortada (desde la portada interior)
#   informe-imprenta.pdf -- tapa extendida de Scribus (contratapa + lomo + tapa) + interior
imprenta: build/informe-imprenta.pdf build/informe-interior.pdf

build/informe-interior.pdf: build/informe.pdf
	rm -rf build/paginas && mkdir -p build/paginas
	pdfseparate -f 2 $< build/paginas/p-%03d.pdf
	pdfunite build/paginas/p-*.pdf $@
	rm -rf build/paginas

build/informe-imprenta.pdf: portada/tapa-scribus.pdf build/informe-interior.pdf
	pdfunite $^ $@

$(TECTONIC):
	@mkdir -p .tools
	curl -sSL -o .tools/tectonic.tar.gz \
	  "https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40$(TECTONIC_VERSION)/tectonic-$(TECTONIC_VERSION)-x86_64-unknown-linux-musl.tar.gz"
	echo "$(TECTONIC_SHA256)  .tools/tectonic.tar.gz" | sha256sum -c -
	tar -xzf .tools/tectonic.tar.gz -C .tools
	touch $@

clean:
	rm -rf build

.PHONY: clean imprenta
