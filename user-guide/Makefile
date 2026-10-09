# mpeg2fpga user guide.
#   make                      -> build/mpeg2fpga-user-guide{,-en}.pdf (Spanish, English)
#   make VERSION=1.2.0        -> stamped with that release version (CI does this)
# Uses Tectonic (a self-contained XeTeX), fetched once into .tools/ at a pinned
# version and checksum; it downloads the TeX packages it needs on first use.
TECTONIC_VERSION = 0.15.0
TECTONIC_SHA256  = dfb82876f2986862996e564fa507a9e576e0c1e3bee63c2c1bd677c2543e6407
TECTONIC = .tools/tectonic
# a release passes VERSION explicitly; a local build is labelled with the commit
VERSION ?= dev+g$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE ?= $(shell date +%Y-%m-%d)

PDFS = build/mpeg2fpga-user-guide.pdf build/mpeg2fpga-user-guide-en.pdf
COMMON = mpeg2fpga-style.sty titlepage.tex $(TECTONIC)

all: $(PDFS)

version.tex: FORCE
	@printf '\\newcommand{\\productversion}{\\detokenize{%s}}\n\\newcommand{\\productdate}{%s}\n' '$(VERSION)' '$(DATE)' > $@

build/mpeg2fpga-user-guide.pdf: mpeg2fpga-user-guide.tex $(wildcard chapters/es/*.tex) $(COMMON) version.tex
	@mkdir -p build
	$(TECTONIC) -X compile --outdir build $<
	@echo "built $@ (version $(VERSION))"

build/mpeg2fpga-user-guide-en.pdf: mpeg2fpga-user-guide-en.tex $(wildcard chapters/en/*.tex) $(COMMON) version.tex
	@mkdir -p build
	$(TECTONIC) -X compile --outdir build $<
	@echo "built $@ (version $(VERSION))"

$(TECTONIC):
	@mkdir -p .tools
	curl -sSL -o .tools/tectonic.tar.gz \
	  "https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%40$(TECTONIC_VERSION)/tectonic-$(TECTONIC_VERSION)-x86_64-unknown-linux-musl.tar.gz"
	echo "$(TECTONIC_SHA256)  .tools/tectonic.tar.gz" | sha256sum -c -
	tar -xzf .tools/tectonic.tar.gz -C .tools
	touch $@

clean:
	rm -rf build version.tex

FORCE:
.PHONY: all clean FORCE
