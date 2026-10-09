# mpeg2fpga user guide.
#   make                      -> build/mpeg2fpga-user-guide.pdf
#   make VERSION=1.2.0        -> stamped with that release version (CI does this)
# Uses Tectonic (a self-contained XeTeX), fetched once into .tools/ at a pinned
# version and checksum; it downloads the TeX packages it needs on first use.
TECTONIC_VERSION = 0.15.0
TECTONIC_SHA256  = dfb82876f2986862996e564fa507a9e576e0c1e3bee63c2c1bd677c2543e6407
TECTONIC = .tools/tectonic
# a release passes VERSION explicitly; a local build is labelled with the commit
VERSION ?= dev+g$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE ?= $(shell date +%Y-%m-%d)

PDF = build/mpeg2fpga-user-guide.pdf
SRC = mpeg2fpga-user-guide.tex mpeg2fpga-style.sty $(wildcard chapters/*.tex)

all: $(PDF)

$(PDF): $(SRC) $(TECTONIC) FORCE
	@mkdir -p build
	@printf '\\newcommand{\\productversion}{\\detokenize{%s}}\n\\newcommand{\\productdate}{%s}\n' '$(VERSION)' '$(DATE)' > version.tex
	$(TECTONIC) -X compile --outdir build mpeg2fpga-user-guide.tex
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
