# Build tj for every supported target.
#
# Zig cross-compiles these with nothing installed on the host, so `make all`
# works from any of them. The per-target builds are independent - use `make -j`
# to run them in parallel.

ZIG      ?= zig
OPTIMIZE ?= ReleaseSafe
STRIP    ?= true
DIST     ?= dist
VERSION  := $(shell sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)

TARGETS := \
	aarch64-macos \
	aarch64-linux-musl \
	x86_64-linux-musl

.DEFAULT_GOAL := build
.PHONY: build install uninstall test fmt fmt-check check all package clean list $(TARGETS)

PREFIX ?= $(HOME)/.local

# --- development ------------------------------------------------------------

build:
	$(ZIG) build

# Use the same install graph as cross-builds and release packages. Keeping one
# manifest prevents local installs from quietly containing more than archives.
install:
	$(ZIG) build --prefix $(PREFIX)
	@echo "installed tj, tjctl, zsh integration, companion tools, and shell completions under $(PREFIX)"

# Remove only files owned by TJ. Directory cleanup is best-effort and succeeds
# only when a directory is empty, so other software under PREFIX is untouched.
uninstall:
	rm -f \
		"$(PREFIX)/bin/tj" \
		"$(PREFIX)/bin/tjctl" \
		"$(PREFIX)/bin/tj-fence" \
		"$(PREFIX)/bin/tj-grep" \
		"$(PREFIX)/bin/tj-tape" \
		"$(PREFIX)/share/tj/tj.plugin.zsh" \
		"$(PREFIX)/share/bash-completion/completions/tj" \
		"$(PREFIX)/share/bash-completion/completions/tjctl" \
		"$(PREFIX)/share/zsh/site-functions/_tj" \
		"$(PREFIX)/share/zsh/site-functions/_tjctl" \
		"$(PREFIX)/share/fish/vendor_completions.d/tj.fish" \
		"$(PREFIX)/share/fish/vendor_completions.d/tjctl.fish"
	@rmdir \
		"$(PREFIX)/share/tj" \
		"$(PREFIX)/share/bash-completion/completions" \
		"$(PREFIX)/share/zsh/site-functions" \
		"$(PREFIX)/share/fish/vendor_completions.d" \
		2>/dev/null || true
	@rmdir \
		"$(PREFIX)/share/bash-completion" \
		"$(PREFIX)/share/zsh" \
		"$(PREFIX)/share/fish" \
		2>/dev/null || true
	@rmdir "$(PREFIX)/bin" "$(PREFIX)/share" 2>/dev/null || true
	@echo "uninstalled tj from $(PREFIX); journal data was not removed"

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
	$(ZIG) build -Dtarget=$@ -Doptimize=$(OPTIMIZE) -Dstrip=$(STRIP) --prefix $(DIST)/tj-$(VERSION)-$@

package: all
	@for t in $(TARGETS); do \
		root="tj-$(VERSION)-$$t"; \
		dir="$(DIST)/$$root"; \
		test -x "$$dir/bin/tj" || exit 1; \
		test -x "$$dir/bin/tjctl" || exit 1; \
		test -x "$$dir/bin/tj-fence" || exit 1; \
		test -x "$$dir/bin/tj-grep" || exit 1; \
		test -x "$$dir/bin/tj-tape" || exit 1; \
		test -r "$$dir/share/tj/tj.plugin.zsh" || exit 1; \
		test -r "$$dir/share/bash-completion/completions/tj" || exit 1; \
		test -r "$$dir/share/bash-completion/completions/tjctl" || exit 1; \
		test -r "$$dir/share/zsh/site-functions/_tj" || exit 1; \
		test -r "$$dir/share/zsh/site-functions/_tjctl" || exit 1; \
		test -r "$$dir/share/fish/vendor_completions.d/tj.fish" || exit 1; \
		test -r "$$dir/share/fish/vendor_completions.d/tjctl.fish" || exit 1; \
		tar -czf "$(DIST)/$$root.tar.gz" -C "$(DIST)" "$$root" || exit 1; \
		echo "$(DIST)/$$root.tar.gz"; \
	done

# --- housekeeping -----------------------------------------------------------

list:
	@printf '%s\n' $(TARGETS)

clean:
	rm -rf zig-out .zig-cache $(DIST)
