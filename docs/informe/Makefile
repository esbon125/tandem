# Informe final.  `make` -> build/informe.pdf
# Usa el mismo Tectonic fijado que la guía de usuario (firmware_development).
TECTONIC_VERSION = 0.15.0
TECTONIC_SHA256  = dfb82876f2986862996e564fa507a9e576e0c1e3bee63c2c1bd677c2543e6407
TECTONIC = .tools/tectonic

build/informe.pdf: informe.tex bibliografia.bib $(wildcard capitulos/*.tex anexos/*.tex portada/*.tex preambulo/*) $(TECTONIC)
	@mkdir -p build
	TEXINPUTS=preambulo: $(TECTONIC) -X compile --outdir build -Z search-path=preambulo $<

$(TECTONIC):
	@mkdir -p .tools
	curl -sSL -o .tools/tectonic.tar.gz \
	  "https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40$(TECTONIC_VERSION)/tectonic-$(TECTONIC_VERSION)-x86_64-unknown-linux-musl.tar.gz"
	echo "$(TECTONIC_SHA256)  .tools/tectonic.tar.gz" | sha256sum -c -
	tar -xzf .tools/tectonic.tar.gz -C .tools
	touch $@

clean:
	rm -rf build

.PHONY: clean
