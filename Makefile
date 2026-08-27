# Build tj for every supported target.
#
# Zig cross-compiles these with nothing installed on the host, so `make all`
# works from any of them. The per-target builds are independent - use `make -j`
# to run them in parallel.

ZIG      ?= zig
OPTIMIZE ?= ReleaseSafe
DIST     ?= dist
VERSION  := $(shell sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)

TARGETS := \
	aarch64-macos \
	x86_64-macos \
	aarch64-linux-musl \
	x86_64-linux-musl \
	aarch64-linux-gnu \
	x86_64-linux-gnu

.DEFAULT_GOAL := build
.PHONY: build install test fmt fmt-check check all package clean list $(TARGETS)

PREFIX ?= $(HOME)/.local

# --- development ------------------------------------------------------------

build:
	$(ZIG) build

# Both, because the agent wrappers pipe one into the other and a missing
# tj-fence fails as an unhelpful "command not found".
install: build
	install -d $(PREFIX)/bin
	install -m 755 zig-out/bin/tj $(PREFIX)/bin/
	install -m 755 contrib/tj-fence $(PREFIX)/bin/
	install -m 755 contrib/tj-tape $(PREFIX)/bin/
	@echo "installed tj, tj-fence and tj-tape in $(PREFIX)/bin"

test:
	$(ZIG) build test

fmt:
	$(ZIG) fmt .

fmt-check:
	$(ZIG) fmt --check .

# The gates every change has to pass.
check: fmt-check test

# --- release ----------------------------------------------------------------

all: $(TARGETS)

# Each target installs into its own prefix, so the binaries never overwrite
# one another: $(DIST)/<target>/bin/tj
$(TARGETS):
	@echo "==> $@"
	$(ZIG) build -Dtarget=$@ -Doptimize=$(OPTIMIZE) --prefix $(DIST)/$@

package: all
	@for t in $(TARGETS); do \
		tar -czf $(DIST)/tj-$(VERSION)-$$t.tar.gz -C $(DIST)/$$t/bin tj || exit 1; \
		echo "$(DIST)/tj-$(VERSION)-$$t.tar.gz"; \
	done

# --- housekeeping -----------------------------------------------------------

list:
	@printf '%s\n' $(TARGETS)

clean:
	rm -rf zig-out .zig-cache $(DIST)
