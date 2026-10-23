# The mpeg2fpga Reference Manual (Doxygen, HTML): the technical manual of the
# driver, the service and the client library.
#
#   make                        build/html/index.html, version dev+g<commit>
#   make VERSION=1.0.0          as the release builds it
#   make tarball VERSION=1.0.0  build/mpeg2fpga-reference-manual-1.0.0.tar.gz
#
# Uses the system doxygen when there is one. Otherwise builds the pinned
# release from source into .tools/ once (needs cmake, flex, bison, g++ and
# ~5 min): the prebuilt Linux binaries need a newer glibc than RHEL 8's.
# Graphs need Graphviz (dot).

DOXYGEN_VERSION = 1.9.8
DOXYGEN_SHA256  = 05e3d228e8384b5f3af9c8fd6246d22804acb731a3a24ce285c8986ed7e14f62
VERSION ?= dev+g$(shell git rev-parse --short=7 HEAD)

DOXYGEN := $(or $(shell command -v doxygen 2>/dev/null),.tools/doxygen/bin/doxygen)

.PHONY: all tarball clean
all: build/html/index.html

build/html/index.html: Doxyfile mainpage.md kerneldoc_filter.py $(DOXYGEN) \
		$(shell find ../driver/mpeg2fpga ../daemon/native ../daemon/mpeg2fpgad ../api/python/src/mpeg2fpga \
		        -name '*.[ch]' -o -name '*.py' 2>/dev/null)
	@mkdir -p build
	MPEG2FPGA_VERSION=$(VERSION) $(DOXYGEN) Doxyfile
	@if [ -s build/warnings.log ]; then echo "doxygen warnings:"; cat build/warnings.log; fi

tarball: build/html/index.html
	tar -C build -czf build/mpeg2fpga-reference-manual-$(VERSION).tar.gz \
	    --transform 's,^html,mpeg2fpga-reference-manual-$(VERSION),' html

.tools/doxygen/bin/doxygen:
	@mkdir -p .tools
	curl -sSL -o .tools/doxygen-src.tar.gz \
	  "https://github.com/doxygen/doxygen/releases/download/Release_$(subst .,_,$(DOXYGEN_VERSION))/doxygen-$(DOXYGEN_VERSION).src.tar.gz"
	echo "$(DOXYGEN_SHA256)  .tools/doxygen-src.tar.gz" | sha256sum -c -
	tar -xzf .tools/doxygen-src.tar.gz -C .tools
	cmake -S .tools/doxygen-$(DOXYGEN_VERSION) -B .tools/doxygen-build \
	  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$(CURDIR)/.tools/doxygen >/dev/null
	$(MAKE) -C .tools/doxygen-build -j$$(nproc) >/dev/null
	$(MAKE) -C .tools/doxygen-build install >/dev/null
	rm -rf .tools/doxygen-build .tools/doxygen-$(DOXYGEN_VERSION) .tools/doxygen-src.tar.gz

clean:
	rm -rf build
