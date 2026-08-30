EMACS ?= emacs

SOURCES = parenting.el parenting-parent.el parenting-child.el parenting-remote.el

.PHONY: all compile test clean

all: compile test

# Byte-compile with warnings promoted to errors, so a warning under any
# supported Emacs fails the build.
compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SOURCES)

# Every test spawns a real child Emacs (the same binary) and drives it
# over the socket, so the suite needs a writable temporary directory.
test:
	$(EMACS) -Q --batch -L . \
	  -l test/parenting-test.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
