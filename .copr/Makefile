# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# COPR SCM build entry point.
#
# COPR's "Make srpm" source method runs
#   make -f .copr/Makefile srpm outdir="<path>"
# from the root of a fresh clone, and expects exactly one .src.rpm in $(outdir).
# See https://docs.pagure.org/copr.copr/user_documentation.html#make-srpm
#
# This file installs the tooling the SRPM step needs and hands over to the
# repository's own `srpm` target, so there is one implementation of the SRPM
# build for both COPR and local use. The per-chroot package build that follows
# does not run any of this: it runs the spec embedded in the SRPM.

outdir ?= $(CURDIR)/build/srpm/SRPMS

.PHONY: srpm
srpm:
	dnf -y install golang git make rpm-build tar gzip
	$(MAKE) srpm SRPM_OUTPUT_DIR="$(outdir)"
