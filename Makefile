# SPDX-License-Identifier: GPL-2.0-or-later
# Convenience targets from the repo root. The core itself is built with
# Quartus (see README "Building from Source"); this only runs the tests.
#   make test        all simulation tests (Verilator, C, Python, shell)

.PHONY: test clean
test:
	$(MAKE) -C sim test

clean:
	$(MAKE) -C sim clean
