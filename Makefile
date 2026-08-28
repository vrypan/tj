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

# Install the companion tools with the binary so documented workflows do not
# depend on reaching back into a source checkout.
install: build
	install -d $(PREFIX)/bin
	install -d $(PREFIX)/share/bash-completion/completions
	install -d $(PREFIX)/share/zsh/site-functions
	install -d $(PREFIX)/share/fish/vendor_completions.d
	install -m 755 zig-out/bin/tj $(PREFIX)/bin/
	install -m 755 contrib/tj-fence $(PREFIX)/bin/
	install -m 755 contrib/tj-grep $(PREFIX)/bin/
	install -m 755 contrib/tj-tape $(PREFIX)/bin/
	install -m 644 zig-out/share/bash-completion/completions/tj $(PREFIX)/share/bash-completion/completions/
	install -m 644 zig-out/share/zsh/site-functions/_tj $(PREFIX)/share/zsh/site-functions/
	install -m 644 zig-out/share/fish/vendor_completions.d/tj.fish $(PREFIX)/share/fish/vendor_completions.d/
	@echo "installed tj, companion tools, and shell completions under $(PREFIX)"

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

# Each target installs into its own prefix, so binaries and generated shell
# completions never overwrite another target's artifacts.
$(TARGETS):
	@echo "==> $@"
	$(ZIG) build -Dtarget=$@ -Doptimize=$(OPTIMIZE) --prefix $(DIST)/$@

package: all
	@for t in $(TARGETS); do \
		tar -czf $(DIST)/tj-$(VERSION)-$$t.tar.gz -C $(DIST)/$$t bin share || exit 1; \
		echo "$(DIST)/tj-$(VERSION)-$$t.tar.gz"; \
	done

# --- housekeeping -----------------------------------------------------------

list:
	@printf '%s\n' $(TARGETS)

clean:
	rm -rf zig-out .zig-cache $(DIST)
